#!/usr/bin/env python3
"""Synthetic, provider-neutral benchmark for the VoxLocal service split.

The benchmark only sends a generated WAV fixture and a fixed text fixture. It
does not contact a provider control plane, select a Pod, or print response
bodies. JSON results are written to stdout; the short human summary is written
to stderr so stdout can be piped to a machine.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import io
import json
import os
import stat
import sys
import time
import urllib.error
import urllib.request
import wave
from urllib.parse import urlsplit


BENCHMARK_ID = "voxlocal-runpod-synthetic-v1"
SYNTHETIC_TEXT = "Synthetic benchmark text: alpha bravo charlie."
MAX_RESPONSE_BYTES = 64 * 1024
MAX_TIMEOUT_SECONDS = 30.0
LOOPBACK_NAMES = {"localhost"}


class ConfigurationError(ValueError):
    """A safe, user-actionable configuration error."""


def _loopback(hostname: str) -> bool:
    host = hostname.lower().rstrip(".")
    if host in LOOPBACK_NAMES:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def validate_base_url(value: str) -> str:
    """Validate a service URL without allowing credentials or unsafe HTTP."""
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ConfigurationError("service URL must use http(s) and include a host")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ConfigurationError("service URL must not contain credentials, query, or fragment")
    try:
        parsed.port  # Force validation of an invalid port.
    except ValueError as exc:
        raise ConfigurationError("service URL has an invalid port") from exc
    if parsed.scheme == "http" and not _loopback(parsed.hostname):
        raise ConfigurationError("plain HTTP is allowed only on loopback")
    return value.rstrip("/")


def _read_token_file(path: str) -> str:
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
        if mode & 0o077:
            raise ConfigurationError("token file must not be group/world accessible")
        with open(path, encoding="utf-8") as handle:
            token = handle.read().strip()
    except FileNotFoundError as exc:
        raise ConfigurationError("token file is unavailable") from exc
    except OSError as exc:
        raise ConfigurationError("token file cannot be read") from exc
    if not token or any(char in token for char in "\r\n"):
        raise ConfigurationError("token is empty or malformed")
    return token


def _token_from_env(name: str) -> str | None:
    value = os.environ.get(name)
    if value is None:
        return None
    value = value.strip()
    if not value or any(char in value for char in "\r\n"):
        raise ConfigurationError("token environment variable is empty or malformed")
    return value


def resolve_token(service: str, global_token_file: str | None) -> str | None:
    """Resolve a token without accepting it as a command-line argument."""
    prefix = f"VOXLOCAL_{service.upper()}_API_TOKEN"
    token = _token_from_env(prefix)
    if token is not None:
        return token
    token = _token_from_env("VOXLOCAL_API_TOKEN")
    if token is not None:
        return token
    service_file = os.environ.get(f"VOXLOCAL_{service.upper()}_TOKEN_FILE")
    path = service_file or global_token_file
    return _read_token_file(path) if path else None


def synthetic_wav() -> bytes:
    """Return a deterministic 250 ms, 16 kHz mono PCM WAV fixture."""
    sample_rate = 16_000
    frames = sample_rate // 4
    # Silence is deterministic PCM data and keeps the fixture free of any user
    # recording.
    pcm = b"\x00\x00" * frames
    output = io.BytesIO()
    with wave.open(output, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm)
    return output.getvalue()


def _auth_headers(token: str | None) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"} if token else {}


def _read_capped(response, cap: int = MAX_RESPONSE_BYTES) -> bytes:
    body = response.read(cap + 1)
    if len(body) > cap:
        raise ValueError("response_too_large")
    return body


def _request(url: str, method: str, token: str | None, body: bytes | None,
             content_type: str | None, timeout: float) -> dict[str, object]:
    headers = {"Accept": "application/json", **_auth_headers(token)}
    if content_type:
        headers["Content-Type"] = content_type
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = int(response.status)
            payload = _read_capped(response)
        result: dict[str, object] = {
            "status": "ok" if 200 <= status < 300 else "http_error",
            "http_status": status,
            "latency_ms": round((time.monotonic() - started) * 1000, 2),
            "response_bytes": len(payload),
        }
        if result["status"] == "ok":
            try:
                value = json.loads(payload)
            except (UnicodeDecodeError, json.JSONDecodeError):
                result["status"] = "invalid_json"
            else:
                # Do not retain or print values from the response. The shape
                # check catches an HTML proxy/error page without exposing it.
                if not isinstance(value, dict):
                    result["status"] = "invalid_json"
        return result
    except urllib.error.HTTPError as exc:
        return {
            "status": "http_error",
            "http_status": int(exc.code),
            "latency_ms": round((time.monotonic() - started) * 1000, 2),
        }
    except ValueError as exc:
        return {
            "status": str(exc),
            "latency_ms": round((time.monotonic() - started) * 1000, 2),
        }
    except (OSError, urllib.error.URLError, TimeoutError):
        return {
            "status": "unavailable",
            "latency_ms": round((time.monotonic() - started) * 1000, 2),
        }


def _multipart_wav(audio: bytes) -> tuple[bytes, str]:
    boundary = "----voxlocal-synthetic-boundary"
    prefix = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="synthetic.wav"\r\n'
        "Content-Type: audio/wav\r\n\r\n"
    ).encode("ascii")
    suffix = f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nsynthetic\r\n--{boundary}--\r\n".encode("ascii")
    return prefix + audio + suffix, f"multipart/form-data; boundary={boundary}"


def _chat_body() -> bytes:
    # Keep this literal fixed: callers cannot accidentally benchmark patient
    # text by passing a prompt or input file to this tool.
    payload = {
        "model": "synthetic",
        "messages": [{"role": "user", "content": SYNTHETIC_TEXT}],
        "max_tokens": 16,
        "temperature": 0,
    }
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def run_service(name: str, base_url: str, token: str | None, timeout: float,
                audio: bytes) -> dict[str, object]:
    models = _request(f"{base_url}/v1/models", "GET", token, None, None, timeout)
    if name == "voice":
        body, content_type = _multipart_wav(audio)
        operation_name = "audio_transcriptions"
        operation = _request(
            f"{base_url}/v1/audio/transcriptions", "POST", token,
            body, content_type, timeout,
        )
    else:
        operation_name = "chat_completions"
        operation = _request(
            f"{base_url}/v1/chat/completions", "POST", token,
            _chat_body(), "application/json", timeout,
        )
    checks = [
        {"operation": "models", **models},
        {"operation": operation_name, **operation},
    ]
    return {"name": name, "ok": all(check["status"] == "ok" for check in checks), "checks": checks}


def _timeout(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("timeout must be a number") from exc
    if not 0 < parsed <= MAX_TIMEOUT_SECONDS:
        raise argparse.ArgumentTypeError("timeout must be greater than 0 and at most 30 seconds")
    return parsed


def _configured_services(args: argparse.Namespace) -> list[tuple[str, str]]:
    values: dict[str, str] = {}
    for name, value in (
        ("voice", args.voice_url or os.environ.get("VOXLOCAL_VOICE_URL")),
        ("clean", args.clean_url or os.environ.get("VOXLOCAL_CLEAN_URL")),
        ("llm", args.llm_url or os.environ.get("VOXLOCAL_LLM_URL")),
    ):
        if value:
            values[name] = value
    for name, value in args.service:
        if name not in {"voice", "clean", "llm"}:
            raise ConfigurationError("service name must be voice, clean, or llm")
        if name in values:
            raise ConfigurationError(f"service configured more than once: {name}")
        values[name] = value
    if not values:
        raise ConfigurationError("configure at least one service URL")
    return [(name, validate_base_url(values[name])) for name in ("voice", "clean", "llm") if name in values]


def _summary(result: dict[str, object]) -> str:
    parts = []
    for service in result.get("services", []):
        checks = service["checks"]
        details = ", ".join(
            f"{check['operation']}={check['status']} {check.get('latency_ms', 0):.2f}ms"
            for check in checks
        )
        parts.append(f"{service['name']}={'PASS' if service['ok'] else 'FAIL'} ({details})")
    return f"synthetic benchmark: {'; '.join(parts)}; overall={'PASS' if result['ok'] else 'FAIL'}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--voice-url", help="voice service base URL (or VOXLOCAL_VOICE_URL)")
    parser.add_argument("--clean-url", help="cleanup service base URL (or VOXLOCAL_CLEAN_URL)")
    parser.add_argument("--llm-url", help="LLM service base URL (or VOXLOCAL_LLM_URL)")
    parser.add_argument("--service", action="append", nargs=2, metavar=("NAME", "URL"), default=[],
                        help="additional capability URL; NAME is voice, clean, or llm")
    parser.add_argument("--token-file", default=os.environ.get("VOXLOCAL_TOKEN_FILE"),
                        help="private token file; service-specific *_TOKEN_FILE takes precedence")
    parser.add_argument("--timeout", type=_timeout, default=5.0,
                        help="per-request timeout in seconds (maximum 30)")
    args = parser.parse_args(argv)
    try:
        services = _configured_services(args)
        audio = synthetic_wav()
        results = []
        for name, url in services:
            results.append(run_service(name, url, resolve_token(name, args.token_file), args.timeout, audio))
        result: dict[str, object] = {
            "benchmark": BENCHMARK_ID,
            "ok": all(service["ok"] for service in results),
            "timeout_seconds": args.timeout,
            "synthetic": {
                "audio_format": "wav/pcm_s16le/mono/16000hz/250ms",
                "audio_bytes": len(audio),
                "text_sha256": hashlib.sha256(SYNTHETIC_TEXT.encode("utf-8")).hexdigest(),
            },
            "services": results,
        }
    except ConfigurationError as exc:
        result = {"benchmark": BENCHMARK_ID, "ok": False, "error": str(exc)}
        print(json.dumps(result, sort_keys=True), file=sys.stdout)
        print(f"synthetic benchmark: configuration error ({exc})", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True), file=sys.stdout)
    print(_summary(result), file=sys.stderr)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
