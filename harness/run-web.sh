#!/usr/bin/env bash
# Launch the dsh web UI on the VoxLocal "scribe" profile (macOS / Linux dev).
# Usage: VOXLOCAL_LLM_URL=https://<pod>:8443/llm/v1 VOXLOCAL_LLM_TOKEN=... harness/run-web.sh [dsh web flags]
# Extra arguments reach the web app (for example --port 3081).
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="$HARNESS_DIR/profile"
export DSH_HOME="$HARNESS_DIR/.dsh-home"
# Keep the operator's personal ~/.agents skills and instructions out of the
# clinical agent: dsh scans $DSH_AGENTS_HOME (default ~/.agents) for skills.
export DSH_AGENTS_HOME="$DSH_HOME/agents"

: "${VOXLOCAL_LLM_URL:?set VOXLOCAL_LLM_URL to the OpenAI-compatible base URL (ending in /v1)}"
: "${VOXLOCAL_LLM_TOKEN:?set VOXLOCAL_LLM_TOKEN to the GPU edge bearer token}"
export VOXLOCAL_LLM_URL VOXLOCAL_LLM_TOKEN

# Same rule as run-web.ps1: the GPU token and the record text never travel in clear to another host.
# Accepts https://<host>, or http:// on 127.0.0.1, localhost or [::1]; never credentials in the URL.
check_llm_url() {  # name value -> 0, or message on stderr and 2
  local name="$1" url="$2" scheme rest authority host
  case "$url" in *://*) ;; *) echo "$name must be an absolute http(s) URL without credentials: $url" >&2; return 2 ;; esac
  scheme="$(printf '%s' "${url%%://*}" | tr '[:upper:]' '[:lower:]')"
  rest="${url#*://}"
  authority="${rest%%[/?#]*}"
  case "$authority" in
    *@*|'') echo "$name must be an absolute http(s) URL without credentials: $url" >&2; return 2 ;;
  esac
  case "$authority" in
    \[*) host="${authority%%]*}]" ;;
    *) host="${authority%%:*}" ;;
  esac
  host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$scheme" in
    https) [ -n "$host" ] && return 0 ;;
    http)
      case "$host" in 127.0.0.1|localhost|'[::1]') return 0 ;; esac
      echo "$name uses plaintext HTTP to a remote host; use https:// or 127.0.0.1: $url" >&2; return 2 ;;
  esac
  echo "$name must be an absolute http(s) URL without credentials: $url" >&2; return 2
}
check_llm_url VOXLOCAL_LLM_URL "$VOXLOCAL_LLM_URL" || exit 2

# Install the pinned dsh exactly as locked.
if [ ! -x "$PROFILE_DIR/node_modules/.bin/dsh" ]; then
  (cd "$PROFILE_DIR" && pnpm install --frozen-lockfile)
fi

# dsh looks up profiles under $DSH_HOME/profiles/<name>; point "scribe" at the
# tracked profile directory so the repository stays the single source.
mkdir -p "$DSH_HOME/profiles"
if [ ! -e "$DSH_HOME/profiles/scribe" ]; then
  ln -s "$PROFILE_DIR" "$DSH_HOME/profiles/scribe"
fi

exec "$PROFILE_DIR/node_modules/.bin/dsh" --profile scribe --no-open "$@"
