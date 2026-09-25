#!/usr/bin/env python3
"""Local, machine-readable API/CLI for VoxLocal agent harnesses.

The daemon binds to loopback by default, keeps requests in memory only, and
requires a bearer token even on loopback.  It deliberately contains no RunPod
provider-specific code: voice/LLM URLs are explicit HTTPS configuration so a
hospital can choose its approved deployment and data-processing terms.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import hmac
import json
import logging
import re
import os
import secrets
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional

SERVICE = "voxlocal-agent-api"
API_VERSION = "1"
MAX_BODY = 64 * 1024 * 1024
# Allows the documented 32-message chat contract while staying small enough
# that an authenticated local client cannot allocate unbounded parser memory.
MAX_JSON = 2 * 1024 * 1024
MAX_TEXT = 96 * 1024
MAX_MESSAGES = 32
MAX_MESSAGE_TEXT = 32 * 1024
DEFAULT_TIMEOUT = 120.0
MIN_TIMEOUT = 1.0
MAX_TIMEOUT = 300.0
MAX_MODEL_NAME = 128
DEFAULT_MAX_CONCURRENT = 4
logger = logging.getLogger(SERVICE)


class APIError(Exception):
    def __init__(self, code: str, message: str, status: int = 400, retryable: bool = False):
        super().__init__(message)
        self.code, self.message, self.status, self.retryable = code, message, status, retryable


def _timeout(value: Any, name: str = "timeout") -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"{name} invalide.") from None
    if not MIN_TIMEOUT <= parsed <= MAX_TIMEOUT:
        raise ValueError(f"{name} compris entre {MIN_TIMEOUT:g} et {MAX_TIMEOUT:g} secondes.")
    return parsed


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")


def _safe_json(raw: bytes, max_bytes: int = MAX_JSON) -> dict[str, Any]:
    if len(raw) > max_bytes:
        raise APIError("request_too_large", "La requête est trop volumineuse.", 413)
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError("non-finite")))
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise APIError("invalid_json", "JSON invalide.") from None
    if not isinstance(value, dict):
        raise APIError("invalid_json", "Un objet JSON est requis.")
    return value


def _text(value: Any, name: str = "text", limit: int = MAX_TEXT) -> str:
    if not isinstance(value, str) or not value.strip() or len(value.encode("utf-8")) > limit:
        raise APIError("invalid_text", f"Champ {name} invalide.")
    return value


def _validate_https_url(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Les endpoints distants doivent être HTTPS sans identifiants, query ni fragment.")
    try:
        parsed.port
    except ValueError as exc:
        raise ValueError("Port distant invalide.") from exc
    return value.rstrip("/")


def _validate_api_url(value: str) -> str:
    """Validate the local CLI/API base URL without leaking a bearer over HTTP.

    The agent itself is loopback-only, but the CLI accepts an explicit URL so
    harnesses can use a reviewed TLS reverse proxy.  Plain HTTP therefore only
    makes sense for loopback smoke tests; accepting an arbitrary HTTP URL here
    would silently put the agent token (and potentially clinical text) on the
    network.
    """
    parsed = urllib.parse.urlsplit(value)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment):
        raise ValueError("L’URL de l’API agent doit être HTTP(S), sans identifiants, query ni fragment.")
    try:
        parsed.port
    except ValueError as exc:
        raise ValueError("Port de l’API agent invalide.") from exc
    host = parsed.hostname.lower().rstrip(".")
    loopback = host in ("localhost", "127.0.0.1", "::1")
    if parsed.scheme == "http" and not loopback:
        raise ValueError("L’API agent distante doit utiliser HTTPS; HTTP est réservé à localhost.")
    return value.rstrip("/")


def _response_ok(request_id: str, data: Any) -> dict[str, Any]:
    return {"ok": True, "apiVersion": API_VERSION, "requestId": request_id, "data": data}


def _response_error(request_id: str, error: APIError) -> dict[str, Any]:
    return {"ok": False, "apiVersion": API_VERSION, "requestId": request_id,
            "error": {"code": error.code, "message": error.message, "retryable": error.retryable}}


def _validate_language(value: Any) -> Optional[str]:
    if value is None:
        return None
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?", value) is None:
        raise APIError("invalid_language", "Code de langue invalide.")
    return value


def _validate_model(value: str, name: str = "model") -> str:
    if not isinstance(value, str) or not value or len(value) > MAX_MODEL_NAME or any(c in value for c in "\r\n"):
        raise ValueError(f"Nom de {name} invalide.")
    return value


def _normalise_whitespace(text: str) -> str:
    # Safe offline fallback: no lexical substitutions that could change a drug,
    # dose, negation or clinical meaning.
    return " ".join(text.replace("\r\n", "\n").replace("\r", "\n").split())


def _wav_to_pcm(data: bytes) -> bytes:
    try:
        with wave.open(__import__("io").BytesIO(data), "rb") as wav:
            if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getframerate() != 16_000 or wav.getcomptype() != "NONE":
                raise APIError("unsupported_audio_format", "WAV PCM mono 16 kHz 16 bits requis.")
            frames = wav.readframes(wav.getnframes())
    except (wave.Error, EOFError):
        raise APIError("invalid_audio", "Fichier WAV invalide.") from None
    if not frames or len(frames) > MAX_BODY:
        raise APIError("invalid_audio", "Audio vide ou trop volumineux.")
    return frames


def _audio_from_request(handler: BaseHTTPRequestHandler, body: bytes) -> tuple[bytes, Optional[str]]:
    content_type = handler.headers.get("Content-Type", "").split(";", 1)[0].lower()
    language = handler.headers.get("X-VoxLocal-Language")
    language = _validate_language(language)
    if content_type in ("audio/wav", "audio/x-wav"):
        return _wav_to_pcm(body), language
    if content_type == "application/json":
        obj = _safe_json(body)
        encoded = obj.get("audioBase64")
        if not isinstance(encoded, str) or len(encoded) > MAX_BODY * 2:
            raise APIError("invalid_audio", "audioBase64 requis.")
        try:
            raw = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error):
            raise APIError("invalid_audio", "audioBase64 invalide.") from None
        fmt = obj.get("format", "wav")
        if fmt == "wav":
            pcm = _wav_to_pcm(raw)
        elif fmt == "pcm_s16le_16k_mono":
            pcm = raw
            if not pcm or len(pcm) % 2:
                raise APIError("invalid_audio", "PCM invalide.")
        else:
            raise APIError("unsupported_audio_format", "Format audio non supporté.")
        return pcm, _validate_language(obj.get("language") or language)
    if content_type == "application/octet-stream":
        if handler.headers.get("X-VoxLocal-Audio-Format") != "pcm_s16le_16k_mono":
            raise APIError("unsupported_audio_format", "Déclarez X-VoxLocal-Audio-Format.")
        if not body or len(body) % 2:
            raise APIError("invalid_audio", "PCM invalide.")
        return body, language
    raise APIError("unsupported_media_type", "Utilisez audio/wav, application/octet-stream ou application/json.", 415)


class HTTPSJSONClient:
    def __init__(self, base_url: str, token: Optional[str], timeout: float = DEFAULT_TIMEOUT):
        self.base_url = _validate_https_url(base_url)
        if token and any(c in token for c in "\r\n"):
            raise ValueError("Token distant invalide.")
        if not MIN_TIMEOUT <= timeout <= MAX_TIMEOUT:
            raise ValueError(f"Timeout distant compris entre {MIN_TIMEOUT:g} et {MAX_TIMEOUT:g} secondes.")
        self.token, self.timeout = token, timeout
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()),
            _NoRedirect(),
        )

    def post(self, path: str, payload: bytes, content_type: str, request_id: Optional[str] = None) -> dict[str, Any]:
        headers = {"Content-Type": content_type, "Accept": "application/json", "Cache-Control": "no-store",
                   "X-Remote-Scribe-ZDR": "required"}
        if request_id:
            # Request IDs are random support handles; never put PHI in this header.
            headers["X-Request-ID"] = request_id
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(self.base_url + path, data=payload, headers=headers, method="POST")
        try:
            with self.opener.open(req, timeout=self.timeout) as response:
                data = response.read(MAX_JSON + 1)
            if len(data) > MAX_JSON:
                raise ValueError("oversized response")
            obj = json.loads(data.decode("utf-8"))
            if not isinstance(obj, dict):
                raise ValueError("invalid response")
            return obj
        except urllib.error.HTTPError as exc:
            # Do not relay a provider body: it may contain prompts, transcripts or
            # vendor-specific details.  Only the operational class crosses the
            # local API boundary.
            if exc.code in (401, 403):
                raise APIError("upstream_auth", "Le moteur distant a refusé l'authentification.", 502) from None
            if exc.code == 404:
                raise APIError("upstream_route", "La route du moteur distant est introuvable.", 502) from None
            raise APIError("upstream_unavailable", "Le moteur distant est indisponible.", 503, exc.code == 429 or exc.code >= 500) from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError, json.JSONDecodeError):
            raise APIError("upstream_unavailable", "Le moteur distant est indisponible.", 503, True) from None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


class VoiceProvider:
    def __init__(self, url: Optional[str], token: Optional[str], model: str, mock: bool,
                 timeout: float = DEFAULT_TIMEOUT):
        self.url, self.token, self.model, self.mock = url, token, _validate_model(model), mock
        self.client = HTTPSJSONClient(url, token, timeout) if url else None

    def transcribe(self, pcm: bytes, language: Optional[str], request_id: Optional[str] = None) -> str:
        if self.mock:
            return f"[TEST SYNTHÉTIQUE — aucun modèle] {len(pcm)} octets reçus."
        if not self.client:
            raise APIError("capability_unavailable", "Aucun moteur vocal n'est configuré.", 503)
        import io
        out = io.BytesIO()
        with wave.open(out, "wb") as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16_000); wav.writeframes(pcm)
        boundary = "----VoxLocalAgent" + secrets.token_hex(12)
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{self.model}\r\n".encode()
                + f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".encode()
                + out.getvalue() + f"\r\n--{boundary}--\r\n".encode())
        if language:
            body = body[:-len(f"--{boundary}--\r\n".encode())] + f"--{boundary}\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n{language}\r\n--{boundary}--\r\n".encode()
        result = self.client.post("/v1/audio/transcriptions", body, f"multipart/form-data; boundary={boundary}", request_id)
        text = result.get("text")
        return _text(text, "text")


class AgentService:
    def __init__(self, *, voice: VoiceProvider, llm: Optional[HTTPSJSONClient], llm_model: str,
                 chat_enabled: bool, auth_token: str, clean_llm: Optional[HTTPSJSONClient] = None,
                 clean_model: Optional[str] = None, max_concurrent: int = DEFAULT_MAX_CONCURRENT):
        if not isinstance(auth_token, str) or not 16 <= len(auth_token) <= 256 or any(c in auth_token for c in "\r\n"):
            raise ValueError("Token local invalide (16 à 256 caractères).")
        if not 1 <= max_concurrent <= 16:
            raise ValueError("max_concurrent doit être compris entre 1 et 16.")
        self.voice, self.llm = voice, llm
        self.llm_model = _validate_model(llm_model, "modèle LLM")
        self.clean_llm = clean_llm if clean_llm is not None else llm
        self.clean_model = _validate_model(clean_model or llm_model, "modèle de nettoyage")
        self.chat_enabled, self.auth_token = chat_enabled, auth_token
        self.started_at = time.time()
        self.lock = threading.Lock()
        self.capacity = threading.BoundedSemaphore(max_concurrent)
        self.max_concurrent = max_concurrent
        self.requests = 0

    def authenticate(self, handler: BaseHTTPRequestHandler) -> None:
        value = handler.headers.get("Authorization", "")
        supplied = value[7:] if value.startswith("Bearer ") else ""
        if not supplied or not hmac.compare_digest(supplied, self.auth_token):
            raise APIError("unauthorized", "Bearer token requis.", 401)

    def call(self, method: str, path: str, handler: BaseHTTPRequestHandler, body: bytes, request_id: str) -> Any:
        with self.lock:
            self.requests += 1
        if method != "POST":
            raise APIError("method_not_allowed", "Méthode non supportée.", 405)
        if not self.capacity.acquire(blocking=False):
            raise APIError("server_busy", "Le service est momentanément saturé.", 429, True)
        try:
            if path == "/v1/transcribe":
                pcm, language = _audio_from_request(handler, body)
                if len(pcm) > MAX_BODY:
                    raise APIError("request_too_large", "Audio trop volumineux.", 413)
                text = self.voice.transcribe(pcm, language, request_id)
                return {"text": text, "backend": "mock" if self.voice.mock else "remote", "persisted": False}
            if path == "/v1/clean":
                obj = _safe_json(body)
                text = _text(obj.get("text"))
                cleaned = _normalise_whitespace(text)
                if self.clean_llm:
                    cleaned = self._llm_clean(text, request_id)
                return {"text": text, "cleanedText": cleaned, "backend": "remote" if self.clean_llm else "offline-safe", "persisted": False}
            if path == "/v1/chat":
                if not self.chat_enabled:
                    raise APIError("capability_disabled", "Chat désactivé par politique.", 403)
                obj = _safe_json(body)
                messages = obj.get("messages")
                if not isinstance(messages, list) or not 1 <= len(messages) <= MAX_MESSAGES:
                    raise APIError("invalid_messages", "messages doit contenir 1 à 32 éléments.")
                normalised = []
                for item in messages:
                    if not isinstance(item, dict) or item.get("role") not in ("system", "user", "assistant"):
                        raise APIError("invalid_messages", "Rôle de message invalide.")
                    normalised.append({"role": item["role"], "content": _text(item.get("content"), "content", MAX_MESSAGE_TEXT)})
                if not self.llm:
                    raise APIError("capability_unavailable", "Aucun LLM n'est configuré.", 503)
                result = self.llm.post("/v1/chat/completions", _json_bytes({"model": self.llm_model, "messages": normalised, "temperature": 0, "store": False}), "application/json", request_id)
                try:
                    answer = result["choices"][0]["message"]["content"]
                except (KeyError, IndexError, TypeError):
                    raise APIError("upstream_invalid", "Réponse LLM invalide.", 502) from None
                return {"text": _text(answer, "content"), "persisted": False}
            raise APIError("not_found", "Endpoint inconnu.", 404)
        finally:
            self.capacity.release()

    def _llm_clean(self, text: str, request_id: Optional[str] = None) -> str:
        result = self.clean_llm.post("/v1/chat/completions", _json_bytes({
            "model": self.clean_model, "temperature": 0, "store": False,
            "messages": [{"role": "system", "content": "Corrige uniquement ponctuation et fautes. Préserve négations, nombres, unités et médicaments. N'ajoute rien. Retourne uniquement le texte."}, {"role": "user", "content": text}],
        }), "application/json", request_id)
        try:
            return _text(result["choices"][0]["message"]["content"], "content")
        except (KeyError, IndexError, TypeError):
            raise APIError("upstream_invalid", "Réponse LLM invalide.", 502) from None

    def capabilities(self) -> dict[str, Any]:
        return {"service": SERVICE, "apiVersion": API_VERSION, "zdr": True,
                "transcribe": True, "clean": True, "chat": bool(self.chat_enabled and self.llm),
                "voiceBackend": "mock" if self.voice.mock else ("https" if self.voice.client else None),
                "cleanBackend": "https" if self.clean_llm else "offline-safe",
                "llmBackend": "https" if self.llm else None,
                "maxConcurrent": self.max_concurrent}


class AgentHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    def __init__(self, address, service: AgentService):
        super().__init__(address, AgentRequestHandler)
        self.service = service


class AgentRequestHandler(BaseHTTPRequestHandler):
    server: AgentHTTPServer
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        # Bound header/body reads so an authenticated or local client cannot
        # occupy a worker indefinitely with a slow upload.
        self.connection.settimeout(30.0)

    def log_message(self, fmt, *args):
        # Keep query strings out of logs; agents must never put PHI or secrets in URLs.
        path = urllib.parse.urlsplit(self.path).path
        status = args[1] if len(args) > 1 else "?"
        logger.info("http method=%s path=%s status=%s", self.command, path, status)

    def _write(self, status: int, body: dict[str, Any], request_id: str):
        data = _json_bytes(body)
        self.send_response(status); self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(data))); self.send_header("X-Request-ID", request_id); self.end_headers(); self.wfile.write(data)

    def do_GET(self):
        request_id = uuid.uuid4().hex
        try:
            self.server.service.authenticate(self)
            if self.path == "/healthz":
                data = {"service": SERVICE, "apiVersion": API_VERSION, "status": "ready", "zdr": True, "uptimeSeconds": int(time.time() - self.server.service.started_at)}
            elif self.path == "/v1/capabilities":
                data = self.server.service.capabilities()
            elif self.path == "/v1/status":
                data = {"status": "ready", "requests": self.server.service.requests, **self.server.service.capabilities()}
            else:
                raise APIError("not_found", "Endpoint inconnu.", 404)
            self._write(200, _response_ok(request_id, data), request_id)
        except APIError as exc:
            self._write(exc.status, _response_error(request_id, exc), request_id)

    def do_POST(self):
        request_id = uuid.uuid4().hex
        try:
            self.server.service.authenticate(self)
            length = int(self.headers.get("Content-Length", "-1"))
            if length < 0 or length > MAX_BODY:
                raise APIError("request_too_large", "Content-Length requis et limité.", 413)
            body = self.rfile.read(length)
            data = self.server.service.call("POST", self.path, self, body, request_id)
            self._write(200, _response_ok(request_id, data), request_id)
        except (ValueError, OverflowError):
            self._write(400, _response_error(request_id, APIError("invalid_content_length", "Content-Length invalide.")), request_id)
        except APIError as exc:
            self._write(exc.status, _response_error(request_id, exc), request_id)
        except Exception:
            logger.exception("request_failed")
            self._write(500, _response_error(request_id, APIError("internal_error", "Erreur interne.", 500, True)), request_id)


def _request(url: str, token: str, method: str, path: str, body: Optional[bytes] = None, content_type: str = "application/json", extra_headers: Optional[dict[str, str]] = None) -> dict[str, Any]:
    try:
        base = _validate_api_url(url)
    except ValueError as exc:
        return {"ok": False, "error": {"code": "invalid_url", "message": str(exc), "retryable": False}}
    full = base + path
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    if body is not None:
        headers["Content-Type"] = content_type
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(full, data=body, headers=headers, method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    try:
        with opener.open(req, timeout=DEFAULT_TIMEOUT) as response:
            data = response.read(MAX_JSON + 1)
            if len(data) > MAX_JSON:
                return {"ok": False, "error": {"code": "response_too_large", "message": "Réponse API trop volumineuse.", "retryable": False}}
            return _safe_json(data)
    except urllib.error.HTTPError as exc:
        try:
            data = exc.read(MAX_JSON + 1)
            if len(data) > MAX_JSON:
                raise ValueError("oversized")
            return _safe_json(data)
        except Exception: return {"ok": False, "error": {"code": "http_error", "message": str(exc)}}
    except (APIError, ValueError, UnicodeDecodeError, json.JSONDecodeError):
        return {"ok": False, "error": {"code": "invalid_response", "message": "Réponse API invalide.", "retryable": True}}
    except Exception:
        return {"ok": False, "error": {"code": "connection_error", "message": "API inaccessible."}}


def _print(value: Any, pretty: bool):
    print(json.dumps(value, ensure_ascii=False, indent=2 if pretty else None, separators=None if pretty else (",", ":")))


def _build_service(args) -> AgentService:
    token = args.auth_token or os.environ.get("VOXLOCAL_AGENT_TOKEN")
    if not token:
        raise ValueError("VOXLOCAL_AGENT_TOKEN ou --auth-token est obligatoire; aucun secret ne sera imprimé dans les logs.")
    voice_url = args.voice_url or os.environ.get("VOXLOCAL_GPU_URL")
    llm_url = args.llm_url or os.environ.get("VOXLOCAL_LLM_URL")
    clean_url = args.clean_url or os.environ.get("VOXLOCAL_CLEAN_URL")
    if args.mock and any((voice_url, llm_url, clean_url)):
        raise ValueError("Le mode mock refuse tout endpoint distant; supprimez les URLs GPU/LLM ou désactivez --mock.")
    timeout = _timeout(args.upstream_timeout or os.environ.get("VOXLOCAL_UPSTREAM_TIMEOUT", DEFAULT_TIMEOUT), "Timeout distant")
    voice = VoiceProvider(voice_url, args.voice_token or os.environ.get("VOXLOCAL_GPU_TOKEN"), args.voice_model, args.mock, timeout)
    llm = HTTPSJSONClient(llm_url, args.llm_token or os.environ.get("VOXLOCAL_LLM_TOKEN"), timeout) if llm_url else None
    clean = HTTPSJSONClient(clean_url, args.clean_token or os.environ.get("VOXLOCAL_CLEAN_TOKEN"), timeout) if clean_url else llm
    clean_model = args.clean_model or os.environ.get("VOXLOCAL_CLEAN_MODEL") or args.llm_model
    return AgentService(voice=voice, llm=llm, llm_model=args.llm_model, clean_llm=clean,
                        clean_model=clean_model, chat_enabled=args.enable_chat, auth_token=token,
                        max_concurrent=args.max_concurrent)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="voxlocal-agent", description="CLI/API local VoxLocal pour harness d'agents")
    parser.add_argument("--url", default=os.environ.get("VOXLOCAL_AGENT_URL", "http://127.0.0.1:47366"))
    parser.add_argument("--token", dest="global_token", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--pretty", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve"); serve.add_argument("--host", default="127.0.0.1"); serve.add_argument("--port", type=int, default=47366); serve.add_argument("--auth-token", help=argparse.SUPPRESS); serve.add_argument("--mock", action="store_true"); serve.add_argument("--voice-url"); serve.add_argument("--voice-token", help=argparse.SUPPRESS); serve.add_argument("--voice-model", default=os.environ.get("VOXLOCAL_VOICE_MODEL", "large-v3")); serve.add_argument("--clean-url"); serve.add_argument("--clean-token", help=argparse.SUPPRESS); serve.add_argument("--clean-model", default=os.environ.get("VOXLOCAL_CLEAN_MODEL", "small-cleaner")); serve.add_argument("--llm-url"); serve.add_argument("--llm-token", help=argparse.SUPPRESS); serve.add_argument("--llm-model", default=os.environ.get("VOXLOCAL_LLM_MODEL", "qwen2.5-3b-instruct")); serve.add_argument("--upstream-timeout", type=float, help=argparse.SUPPRESS); serve.add_argument("--enable-chat", action="store_true"); serve.add_argument("--max-concurrent", type=int, default=DEFAULT_MAX_CONCURRENT)
    status = sub.add_parser("status"); status.add_argument("--pretty", dest="pretty_local", action="store_true")
    doctor = sub.add_parser("doctor"); doctor.add_argument("--pretty", dest="pretty_local", action="store_true")
    tr = sub.add_parser("transcribe"); tr.add_argument("file", type=Path); tr.add_argument("--language"); tr.add_argument("--pretty", dest="pretty_local", action="store_true")
    cl = sub.add_parser("clean"); cl.add_argument("text", nargs="?"); cl.add_argument("--stdin", dest="read_stdin", action="store_true", help="lit le texte depuis stdin, sans l'exposer dans la liste des processus"); cl.add_argument("--pretty", dest="pretty_local", action="store_true")
    ch = sub.add_parser("chat"); ch.add_argument("prompt", nargs="?"); ch.add_argument("--stdin", dest="read_stdin", action="store_true", help="lit le prompt depuis stdin, sans l'exposer dans la liste des processus"); ch.add_argument("--pretty", dest="pretty_local", action="store_true")
    args = parser.parse_args(argv)
    try:
        args.url = _validate_api_url(args.url)
    except ValueError as exc:
        parser.error(str(exc))
    if args.command == "serve" and any(getattr(args, name, None) for name in ("auth_token", "voice_token", "clean_token", "llm_token")):
        parser.error("Les secrets doivent venir de l'environnement/coffre, jamais des arguments du processus.")
    if args.global_token is not None:
        parser.error("Le token doit venir de VOXLOCAL_AGENT_TOKEN, jamais des arguments du processus.")
    pretty = args.pretty or getattr(args, "pretty_local", False)
    if args.command == "serve":
        if not (1 <= args.port <= 65535): parser.error("--port invalide")
        if args.host not in ("127.0.0.1", "::1", "localhost"):
            parser.error("L'API agent reste loopback-only; utilisez 127.0.0.1, ::1 ou localhost.")
        try: service = _build_service(args)
        except ValueError as exc: parser.error(str(exc))
        httpd = AgentHTTPServer((args.host, args.port), service)
        logger.info("agent_api_ready host=%s port=%d zdr=true", args.host, args.port)
        try: httpd.serve_forever()
        except KeyboardInterrupt: pass
        finally: httpd.server_close()
        return 0
    if args.command == "doctor":
        configured_voice = bool(os.environ.get("VOXLOCAL_GPU_URL")); configured_llm = bool(os.environ.get("VOXLOCAL_LLM_URL"))
        _print({"ok": True, "apiVersion": API_VERSION, "data": {"python": sys.version.split()[0], "zdr": True, "loopbackDefault": True, "voiceConfigured": configured_voice, "llmConfigured": configured_llm, "runpodProviderSpecific": False, "warnings": ([] if configured_voice else ["Aucun moteur vocal HTTPS configuré; utilisez --mock pour un test synthétique."])}}, pretty); return 0
    token = os.environ.get("VOXLOCAL_AGENT_TOKEN", "")
    if not token: _print({"ok": False, "error": {"code": "missing_token", "message": "VOXLOCAL_AGENT_TOKEN requis.", "retryable": False}}, pretty); return 2
    if args.command == "status": out = _request(args.url, token, "GET", "/v1/status")
    elif args.command == "transcribe":
        try:
            if args.file.stat().st_size > MAX_BODY:
                raise ValueError("oversized")
            data = args.file.read_bytes()
        except OSError: _print({"ok": False, "error": {"code": "file_error", "message": "Fichier inaccessible.", "retryable": False}}, pretty); return 2
        except ValueError: _print({"ok": False, "error": {"code": "request_too_large", "message": "Fichier audio trop volumineux.", "retryable": False}}, pretty); return 2
        suffix = args.file.suffix.lower()
        if suffix in (".wav", ".wave"):
            headers = "audio/wav"; extra = {"X-VoxLocal-Language": args.language} if args.language else None
        elif suffix in (".pcm", ".raw"):
            headers = "application/octet-stream"; extra = {"X-VoxLocal-Audio-Format": "pcm_s16le_16k_mono"}
            if args.language: extra["X-VoxLocal-Language"] = args.language
        else:
            _print({"ok": False, "error": {"code": "unsupported_audio_format", "message": "Utilisez un fichier .wav ou .pcm/.raw s16le mono 16 kHz.", "retryable": False}}, pretty); return 2
        out = _request(args.url, token, "POST", "/v1/transcribe", data, headers, extra)
    elif args.command == "clean":
        text = sys.stdin.read() if args.read_stdin else args.text
        if not text: _print({"ok": False, "error": {"code": "missing_text", "message": "Texte requis (utilisez --stdin pour éviter les arguments contenant des données sensibles).", "retryable": False}}, pretty); return 2
        out = _request(args.url, token, "POST", "/v1/clean", _json_bytes({"text": text}))
    else:
        prompt = sys.stdin.read() if args.read_stdin else args.prompt
        if not prompt: _print({"ok": False, "error": {"code": "missing_prompt", "message": "Prompt requis (utilisez --stdin pour éviter les arguments contenant des données sensibles).", "retryable": False}}, pretty); return 2
        out = _request(args.url, token, "POST", "/v1/chat", _json_bytes({"messages": [{"role": "user", "content": prompt}]}))
    _print(out, pretty); return 0 if out.get("ok") else 1


if __name__ == "__main__": raise SystemExit(main())
