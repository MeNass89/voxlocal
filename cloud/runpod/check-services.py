#!/usr/bin/env python3
"""Check local OpenAI-compatible services without exposing credentials."""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from urllib.parse import urlsplit


def check(base: str, token: str, timeout: float) -> tuple[bool, str]:
    if not 0 < timeout <= 30:
        return False, "timeout must be greater than 0 and at most 30 seconds"
    parsed = urlsplit(base)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        return False, "invalid endpoint URL"
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        return False, "endpoint URL must not contain credentials/query/fragment"
    if parsed.scheme == "http" and parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
        return False, "plain HTTP is allowed only on loopback"
    req = urllib.request.Request(base.rstrip("/") + "/v1/models", headers={
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
        "Cache-Control": "no-store",
        "X-Remote-Scribe-ZDR": "required",
    })
    try:
        context = ssl.create_default_context()
        with urllib.request.urlopen(req, timeout=timeout, context=context) as response:
            if response.status != 200:
                return False, f"HTTP {response.status}"
            body = response.read(65537)
        if len(body) > 65536:
            return False, "oversized /v1/models response"
        value = json.loads(body)
        if not isinstance(value, dict) or not isinstance(value.get("data"), list):
            return False, "invalid /v1/models response"
        return True, "ready"
    except (OSError, ValueError, urllib.error.URLError):
        return False, "unavailable or invalid response"


def _read_token(path: str) -> str | None:
    try:
        mode = os.stat(path).st_mode
        if mode & 0o077:
            return None
        with open(path, encoding="utf-8") as handle:
            value = handle.read().strip()
    except OSError:
        return None
    return value if value and not any(char in value for char in "\r\n") else None


def _token_for(service: str, global_path: str | None) -> str | None:
    """Prefer least-privilege service credentials, then Pod-wide fallback."""
    prefix = service.upper()
    value = os.environ.get(f"VOXLOCAL_{prefix}_API_TOKEN")
    if value is not None:
        value = value.strip()
        return value if value and not any(char in value for char in "\r\n") else None
    path = os.environ.get(f"VOXLOCAL_{prefix}_TOKEN_FILE") or global_path
    return _read_token(path) if path else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--service", action="append", nargs=2, metavar=("NAME", "URL"), required=True)
    parser.add_argument("--token-file", default=os.environ.get("VOXLOCAL_TOKEN_FILE", "/workspace/voxlocal/api-token"))
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()
    failed = False
    for name, url in args.service:
        token = _token_for(name, args.token_file)
        if not token:
            print(f"{name}: token unavailable or permissive", file=sys.stderr)
            failed = True
            continue
        ok, detail = check(url, token, args.timeout)
        print(f"{name}: {detail}")
        failed |= not ok
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
