#!/usr/bin/env python3
"""Synthetic, provider-neutral benchmark for the VoxLocal service split.

The benchmark only sends generated WAV fixtures and a fixed synthetic French
clinical sentence. It does not contact a provider control plane, select a Pod,
or print response bodies. JSON results are written to stdout; the short human
summary is written to stderr so stdout can be piped to a machine.

Every capability is measured ``--iterations`` times (default 1):

* voice: ``POST /v1/audio/transcriptions`` with a 250 ms silent WAV and with a
  10 s deterministic tone WAV (non-silent signal over a realistic dictation
  length). Whisper pads every input to a 30 s window, so encoder cost is the
  same for both; decoder cost depends on the content (silence can trigger
  temperature fallbacks and be slower than the tone). Neither fixture measures
  transcript quality;
* clean / llm: ``POST /v1/chat/completions`` with the fixed text fixture;
  ``tokens_per_second`` is ``usage.completion_tokens / latency`` per request,
  latency being the full request time (prefill included).

``GET /v1/models`` is probed once per capability.

JSON schema (``voxlocal-runpod-synthetic-v2``)::

    {
      "benchmark": "voxlocal-runpod-synthetic-v2",
      "ok": true,                      # every request of every service passed
      "iterations": 3,
      "timeout_seconds": 30.0,
      "started_at": "2026-09-25T10:00:00Z",
      "note": "free text from --note, or null",
      "client": {"python": "3.11.9", "platform": "..."},
      "synthetic": {
        "audio": [{"id": "250ms", "format": "wav/pcm_s16le/mono/16000hz",
                   "duration_ms": 250, "bytes": 8044, "sha256": "..."},
                  {"id": "10s", ...}],
        "text_sha256": "...",
        "max_tokens": 96
      },
      "services": [{
        "name": "voice" | "clean" | "llm",
        "ok": true,
        "operations": [{
          "operation": "models" | "audio_transcriptions_250ms"
                       | "audio_transcriptions_10s" | "chat_completions",
          "iterations": 3,
          "ok_count": 3,
          "samples": [{"status": "ok", "http_status": 200, "latency_ms": 812.4,
                       # chat only, when the server returns usage:
                       "completion_tokens": 42, "tokens_per_second": 51.7}],
          "latency_ms": {"min": ..., "mean": ..., "p50": ..., "p95": ..., "max": ...},
          "tokens_per_second": {"min": ..., "mean": ..., "p50": ..., "p95": ..., "max": ...}
        }]
      }]
    }

Statistics use successful samples only and are ``null`` when there are none.
Percentiles use the nearest-rank method: the p-th percentile of n sorted values
is the value at rank ``ceil(p / 100 * n)``. With 3 iterations p50 is the median
and p95 is the maximum. ``status`` is one of ``ok``, ``http_error``,
``invalid_json``, ``response_too_large`` or ``unavailable``.
"""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import io
import json
import math
import os
import platform
import ssl
import stat
import struct
import sys
import time
import urllib.error
import urllib.request
import wave
from datetime import datetime, timezone
from urllib.parse import urlsplit


BENCHMARK_ID = "voxlocal-runpod-synthetic-v2"
# Synthetic dictation only: never replace this with a real recording or note.
SYNTHETIC_SYSTEM = (
    "Corrige uniquement la ponctuation et les fautes de transcription. "
    "Préserve les négations, nombres, unités et noms de médicaments. "
    "Retourne uniquement le texte corrigé."
)
SYNTHETIC_TEXT = (
    "douleur thoracique apparue ce matin sans irradiation pas de fievre "
    "tension arterielle treize huit frequence cardiaque quatre vingt douze "
    "saturation quatre vingt dix sept pour cent en air ambiant "
    "paracetamol un gramme donne a huit heures"
)
MAX_TOKENS = 96
MAX_RESPONSE_BYTES = 64 * 1024
MAX_TIMEOUT_SECONDS = 30.0
MAX_ITERATIONS = 100
MAX_NOTE_CHARS = 1000
SAMPLE_RATE = 16_000
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


def _wav(pcm: bytes) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(SAMPLE_RATE)
        wav_file.writeframes(pcm)
    return output.getvalue()


def synthetic_wav() -> bytes:
    """Return a deterministic 250 ms, 16 kHz mono PCM WAV fixture (silence)."""
    # Silence is deterministic PCM data and keeps the fixture free of any user
    # recording.
    return _wav(b"\x00\x00" * (SAMPLE_RATE // 4))


def synthetic_tone_wav(seconds: int = 10) -> bytes:
    """Return a deterministic tone WAV: 16 kHz mono PCM, pitch changes every 0.5 s.

    It is generated arithmetically (no recording) and is byte-identical on
    every run. It is a load fixture, not speech.
    """
    pitches = (220.0, 277.18, 329.63, 440.0, 329.63, 277.18)
    frames = []
    for index in range(SAMPLE_RATE * seconds):
        pitch = pitches[(index // (SAMPLE_RATE // 2)) % len(pitches)]
        t = index / SAMPLE_RATE
        # 4 Hz amplitude envelope, peak about -6 dBFS.
        envelope = 0.5 * (0.6 + 0.4 * math.sin(2 * math.pi * 4 * t))
        value = envelope * (0.7 * math.sin(2 * math.pi * pitch * t)
                            + 0.3 * math.sin(2 * math.pi * 2 * pitch * t))
        frames.append(int(round(value * 32767)))
    return _wav(struct.pack(f"<{len(frames)}h", *frames))


def percentile(values: list[float], pct: float) -> float | None:
    """Nearest-rank percentile of ``values`` (``None`` when empty)."""
    if not values:
        return None
    if not 0 < pct <= 100:
        raise ValueError("percentile must be in (0, 100]")
    ordered = sorted(values)
    rank = max(1, math.ceil(pct / 100 * len(ordered)))
    return ordered[rank - 1]


def summarize(values: list[float]) -> dict[str, float] | None:
    if not values:
        return None
    return {
        "min": round(min(values), 2),
        "mean": round(sum(values) / len(values), 2),
        "p50": round(percentile(values, 50), 2),
        "p95": round(percentile(values, 95), 2),
        "max": round(max(values), 2),
    }


def _auth_headers(token: str | None) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"} if token else {}


def _read_capped(response, cap: int = MAX_RESPONSE_BYTES) -> bytes:
    body = response.read(cap + 1)
    if len(body) > cap:
        raise ValueError("response_too_large")
    return body


def _request(url: str, method: str, token: str | None, body: bytes | None,
             content_type: str | None, timeout: float,
             context: ssl.SSLContext | None = None) -> dict[str, object]:
    """Send one request; return status/latency and, for chat, numeric usage only."""
    headers = {"Accept": "application/json", **_auth_headers(token)}
    if content_type:
        headers["Content-Type"] = content_type
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            status = int(response.status)
            payload = _read_capped(response)
        elapsed = time.monotonic() - started
        result: dict[str, object] = {
            "status": "ok" if 200 <= status < 300 else "http_error",
            "http_status": status,
            "latency_ms": round(elapsed * 1000, 2),
        }
        if result["status"] == "ok":
            try:
                value = json.loads(payload)
            except (UnicodeDecodeError, json.JSONDecodeError):
                result["status"] = "invalid_json"
            else:
                # Do not retain or print text from the response. The shape
                # check catches an HTML proxy/error page without exposing it;
                # only the numeric token count is kept.
                if not isinstance(value, dict):
                    result["status"] = "invalid_json"
                else:
                    usage = value.get("usage")
                    tokens = usage.get("completion_tokens") if isinstance(usage, dict) else None
                    if isinstance(tokens, int) and not isinstance(tokens, bool) and tokens >= 0:
                        result["completion_tokens"] = tokens
                        if elapsed > 0:
                            result["tokens_per_second"] = round(tokens / elapsed, 2)
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
        "messages": [
            {"role": "system", "content": SYNTHETIC_SYSTEM},
            {"role": "user", "content": SYNTHETIC_TEXT},
        ],
        "max_tokens": MAX_TOKENS,
        "temperature": 0,
        "store": False,
    }
    return json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def _operation(name: str, samples: list[dict[str, object]]) -> dict[str, object]:
    ok = [sample for sample in samples if sample["status"] == "ok"]
    result: dict[str, object] = {
        "operation": name,
        "iterations": len(samples),
        "ok_count": len(ok),
        "samples": samples,
        "latency_ms": summarize([float(sample["latency_ms"]) for sample in ok]),
    }
    rates = [float(sample["tokens_per_second"]) for sample in ok if "tokens_per_second" in sample]
    if rates:
        result["tokens_per_second"] = summarize(rates)
    return result


def run_service(name: str, base_url: str, token: str | None, timeout: float,
                fixtures: list[tuple[str, bytes]], iterations: int = 1,
                context: ssl.SSLContext | None = None) -> dict[str, object]:
    operations = [_operation("models", [
        _request(f"{base_url}/v1/models", "GET", token, None, None, timeout, context)
    ])]
    if name == "voice":
        for fixture_id, audio in fixtures:
            body, content_type = _multipart_wav(audio)
            operations.append(_operation(f"audio_transcriptions_{fixture_id}", [
                _request(f"{base_url}/v1/audio/transcriptions", "POST", token,
                         body, content_type, timeout, context)
                for _ in range(iterations)
            ]))
    else:
        body = _chat_body()
        operations.append(_operation("chat_completions", [
            _request(f"{base_url}/v1/chat/completions", "POST", token,
                     body, "application/json", timeout, context)
            for _ in range(iterations)
        ]))
    ok = all(op["ok_count"] == op["iterations"] for op in operations)
    return {"name": name, "ok": ok, "operations": operations}


def _iterations(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("iterations must be an integer") from exc
    if not 1 <= parsed <= MAX_ITERATIONS:
        raise argparse.ArgumentTypeError(f"iterations must be between 1 and {MAX_ITERATIONS}")
    return parsed


def _note(value: str) -> str:
    if len(value) > MAX_NOTE_CHARS or any(char in value for char in "\r\n"):
        raise argparse.ArgumentTypeError(f"note must be one line of at most {MAX_NOTE_CHARS} characters")
    return value


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
        details = []
        for op in service["operations"]:
            latency = op["latency_ms"]
            text = f"{op['operation']} {op['ok_count']}/{op['iterations']}"
            if latency:
                text += f" p50={latency['p50']:.2f}ms p95={latency['p95']:.2f}ms"
            if op.get("tokens_per_second"):
                text += f" {op['tokens_per_second']['p50']:.1f}tok/s"
            details.append(text)
        parts.append(f"{service['name']}={'PASS' if service['ok'] else 'FAIL'} ({', '.join(details)})")
    return f"synthetic benchmark: {'; '.join(parts)}; overall={'PASS' if result['ok'] else 'FAIL'}"


def _ssl_context(ca_file: str | None) -> ssl.SSLContext | None:
    if not ca_file:
        return None
    try:
        return ssl.create_default_context(cafile=ca_file)
    except (OSError, ssl.SSLError) as exc:
        raise ConfigurationError("CA file cannot be loaded") from exc


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
    parser.add_argument("--iterations", type=_iterations, default=1,
                        help=f"requests per operation, 1 to {MAX_ITERATIONS} (default 1)")
    parser.add_argument("--ca-file", default=os.environ.get("VOXLOCAL_CA_FILE"),
                        help="PEM certificate(s) to trust for HTTPS, e.g. the Pod's self-signed edge certificate")
    parser.add_argument("--note", type=_note, default=None,
                        help="one-line operator note stored in the JSON (hardware, model files); never patient data")
    args = parser.parse_args(argv)
    try:
        services = _configured_services(args)
        context = _ssl_context(args.ca_file)
        fixtures = [("250ms", synthetic_wav()), ("10s", synthetic_tone_wav(10))]
        started_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        results = []
        for name, url in services:
            results.append(run_service(name, url, resolve_token(name, args.token_file), args.timeout,
                                       fixtures, args.iterations, context))
        result: dict[str, object] = {
            "benchmark": BENCHMARK_ID,
            "ok": all(service["ok"] for service in results),
            "iterations": args.iterations,
            "timeout_seconds": args.timeout,
            "started_at": started_at,
            "note": args.note,
            "client": {"python": platform.python_version(), "platform": platform.platform()},
            "synthetic": {
                "audio": [
                    {
                        "id": fixture_id,
                        "format": "wav/pcm_s16le/mono/16000hz",
                        "duration_ms": 250 if fixture_id == "250ms" else 10_000,
                        "bytes": len(audio),
                        "sha256": hashlib.sha256(audio).hexdigest(),
                    }
                    for fixture_id, audio in fixtures
                ],
                "text_sha256": hashlib.sha256(SYNTHETIC_TEXT.encode("utf-8")).hexdigest(),
                "max_tokens": MAX_TOKENS,
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
