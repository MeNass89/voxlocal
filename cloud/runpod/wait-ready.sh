#!/usr/bin/env bash
set -Eeuo pipefail

# Wait until every local model server answers its health URL, then return.
#
#   wait-ready.sh <timeout-seconds> <url> [<url> ...]
#
# The edge starts after this, so the first client request after boot reaches a
# loaded model instead of a 502. whisper-server and llama-server both answer
# 503 while the model loads and 200 once it is ready. On timeout the script
# warns and returns 0: the edge still starts (conservative cold start), and
# check-services.py reports which service is not ready yet.
die() { echo "wait-ready: $*" >&2; exit 2; }
(($# >= 2)) || die "usage: wait-ready.sh <timeout-seconds> <url> [<url> ...]"
TIMEOUT="$1"
shift
[[ "$TIMEOUT" =~ ^[0-9]{1,4}$ ]] || die "timeout must be a whole number of seconds"
for url in "$@"; do
  [[ "$url" =~ ^http://127\.0\.0\.1:[0-9]{2,5}/[A-Za-z0-9/._-]*$ ]] || die "only loopback health URLs are polled: $url"
done

deadline=$((SECONDS + TIMEOUT))
pending=("$@")
while ((${#pending[@]})); do
  still=()
  for url in "${pending[@]}"; do
    if curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; then
      echo "wait-ready: ready $url"
    else
      still+=("$url")
    fi
  done
  pending=("${still[@]+"${still[@]}"}")
  ((${#pending[@]})) || break
  if ((SECONDS >= deadline)); then
    echo "wait-ready: WARNING not ready after ${TIMEOUT}s: ${pending[*]}; starting the edge anyway" >&2
    break
  fi
  sleep 1
done
