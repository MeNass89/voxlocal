#!/bin/zsh
set -euo pipefail

WEB_DIR="${0:A:h}"
REMOTE_DIR="${WEB_DIR:h}"
BACKEND="superwhisper"
SHOW_QR="false"
BACKGROUND="false"
GATEWAY_ARGS=()
while (( $# > 0 )); do
  case "$1" in
    --backend) BACKEND="${2:-superwhisper}"; shift 2 ;;
    --show-qr) SHOW_QR="true"; shift ;;
    --background) BACKGROUND="true"; shift ;;
    *) GATEWAY_ARGS+=("$1"); shift ;;
  esac
done
if [[ "$BACKEND" != "superwhisper" && "$BACKEND" != "voxlocal" ]]; then
  print -u2 "Backend attendu : superwhisper ou voxlocal"
  exit 2
fi

"$WEB_DIR/setup-local-https.sh"

WEB_DATA_DIR="${REMOTE_SCRIBE_WEB_DATA_DIR:-${HOME}/Library/Application Support/RemoteScribe/web}"
LOCAL_NAME="${REMOTE_SCRIBE_LOCAL_NAME:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}"
ONBOARDING_PORT="8080"
for (( index = 1; index <= ${#GATEWAY_ARGS}; index++ )); do
  if [[ "${GATEWAY_ARGS[$index]}" == "--onboarding-port" ]]; then
    ONBOARDING_PORT="${GATEWAY_ARGS[$(( index + 1 ))]:-8080}"
  fi
done
ACCESS_KEY="$(<"$WEB_DATA_DIR/web-access.key")"
ONBOARDING_URL="http://${LOCAL_NAME}.local:${ONBOARDING_PORT}/?key=${ACCESS_KEY}"
QR_PATH="$WEB_DATA_DIR/remote-scribe-iphone-qr.png"
QR_URL_PATH="$WEB_DATA_DIR/remote-scribe-iphone-qr.url"

cd "$REMOTE_DIR"
if [[ ! -f "$QR_PATH" || ! -f "$QR_URL_PATH" || "$(<"$QR_URL_PATH")" != "$ONBOARDING_URL" ]]; then
  swift build -c release --product RemoteScribeQRCode
  "$REMOTE_DIR/.build/release/RemoteScribeQRCode" "$ONBOARDING_URL" "$QR_PATH"
  print -r -- "$ONBOARDING_URL" > "$QR_URL_PATH"
  SHOW_QR="true"
fi
print "Nom du PC : $LOCAL_NAME"
print "QR code stable : $QR_PATH"

HOST_PID=""
GATEWAY_PID=""
if ! nc -z 127.0.0.1 47365 >/dev/null 2>&1; then
  swift build -c release --product RemoteScribeHost
  "$REMOTE_DIR/.build/release/RemoteScribeHost" --backend "$BACKEND" &
  HOST_PID=$!
  sleep 1
fi

cleanup() {
  if [[ -n "$GATEWAY_PID" ]]; then kill "$GATEWAY_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$HOST_PID" ]]; then kill "$HOST_PID" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT INT TERM

python3 "$WEB_DIR/gateway.py" "${GATEWAY_ARGS[@]}" --name "$LOCAL_NAME" &
GATEWAY_PID=$!
sleep 1
if [[ "$SHOW_QR" == "true" && "$BACKGROUND" != "true" ]]; then
  /usr/bin/open "$QR_PATH" >/dev/null 2>&1 || true
fi
wait "$GATEWAY_PID"
