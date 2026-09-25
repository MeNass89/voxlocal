#!/usr/bin/env bash
set -Eeuo pipefail

# Minimal, provider-neutral supervisor for a RunPod Pod.  It deliberately does
# not create a Pod, download a model, or print the API token.  The image owner
# supplies the commands and keeps the token file inside the Pod.
#
# Optional VOXLOCAL_EDGE_CMD is the TLS edge (Caddy in the VoxLocal image); it is
# started last and supervised like the model services.  VOXLOCAL_TLS_CERT and
# VOXLOCAL_TLS_KEY, when set, are validated here and passed through to every
# child so the edge can read them; only their paths ever reach the log.
ROOT_DIR="${VOXLOCAL_ROOT:-/workspace/voxlocal}"
TOKEN_FILE="${VOXLOCAL_TOKEN_FILE:-$ROOT_DIR/api-token}"
RUN_DIR="${VOXLOCAL_RUN_DIR:-$ROOT_DIR/run}"
LOG_DIR="${VOXLOCAL_LOG_DIR:-$ROOT_DIR/logs}"

die() { echo "runpod-runtime: $*" >&2; exit 2; }
[[ -r "$TOKEN_FILE" && -f "$TOKEN_FILE" ]] || die "token file is missing: $TOKEN_FILE"
TOKEN_MODE="$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || stat -f '%Lp' "$TOKEN_FILE")"
if [[ ! "$TOKEN_MODE" =~ ^[0-7]+$ ]] || (( 10#$TOKEN_MODE % 100 != 0 )); then
  die "token file must not be group/world accessible"
fi
TOKEN="$(<"$TOKEN_FILE")"
[[ -n "$TOKEN" && "$TOKEN" != *$'\n'* && "$TOKEN" != *$'\r'* ]] || die "token file is empty or malformed"

VOICE_CMD="${VOXLOCAL_VOICE_CMD:-}"
CLEAN_CMD="${VOXLOCAL_CLEAN_CMD:-}"
LLM_CMD="${VOXLOCAL_LLM_CMD:-}"
EDGE_CMD="${VOXLOCAL_EDGE_CMD:-}"
[[ -n "$VOICE_CMD" ]] || die "VOXLOCAL_VOICE_CMD is required"

TLS_CERT="${VOXLOCAL_TLS_CERT:-}"
TLS_KEY="${VOXLOCAL_TLS_KEY:-}"
if [[ -n "$TLS_CERT" || -n "$TLS_KEY" ]]; then
  [[ -n "$TLS_CERT" && -n "$TLS_KEY" ]] || die "VOXLOCAL_TLS_CERT and VOXLOCAL_TLS_KEY must be set together"
  [[ -f "$TLS_CERT" && -r "$TLS_CERT" ]] || die "TLS certificate is missing: $TLS_CERT"
  [[ -f "$TLS_KEY" && -r "$TLS_KEY" ]] || die "TLS key is missing: $TLS_KEY"
  KEY_MODE="$(stat -c '%a' "$TLS_KEY" 2>/dev/null || stat -f '%Lp' "$TLS_KEY")"
  if [[ ! "$KEY_MODE" =~ ^[0-7]+$ ]] || (( 10#$KEY_MODE % 100 != 0 )); then
    die "TLS key must not be group/world accessible"
  fi
  export VOXLOCAL_TLS_CERT="$TLS_CERT" VOXLOCAL_TLS_KEY="$TLS_KEY"
  echo "runpod-runtime: TLS certificate $TLS_CERT"
fi
umask 077
mkdir -p "$RUN_DIR" "$LOG_DIR"
declare -a PIDS=()

cleanup() {
  trap - TERM INT EXIT
  for pid in "${PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in "${PIDS[@]:-}"; do wait "$pid" 2>/dev/null || true; done
  unset TOKEN VOXLOCAL_API_TOKEN
}
trap cleanup TERM INT EXIT

start_service() {
  local name="$1" command="$2"
  local log="$LOG_DIR/$name.log"
  # Commands are operator-supplied image configuration.  They are run with a
  # dedicated name and a shared token only through the child environment; the
  # token never enters the command line or logs.
  ( export VOXLOCAL_API_TOKEN="$TOKEN" VOXLOCAL_SERVICE="$name"
    exec bash -lc "$command" ) >>"$log" 2>&1 &
  local pid="$!"
  PIDS+=("$pid")
  echo "runpod-runtime: started $name (pid $pid)"
}

start_service voice "$VOICE_CMD"
[[ -z "$CLEAN_CMD" ]] || start_service clean "$CLEAN_CMD"
[[ -z "$LLM_CMD" ]] || start_service llm "$LLM_CMD"
[[ -z "$EDGE_CMD" ]] || start_service edge "$EDGE_CMD"

while ((${#PIDS[@]})); do
  for pid in "${PIDS[@]}"; do
    # A child that has exited can remain a zombie until its parent reaps it;
    # kill -0 alone therefore is not a reliable liveness check.
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    if [[ -z "$state" || "$state" == Z* ]]; then
      wait "$pid" || die "service exited (pid $pid)"
      die "service exited cleanly (pid $pid)"
    fi
  done
  sleep 1
done
