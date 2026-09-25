#!/bin/zsh
set -euo pipefail

WEB_DIR="${0:A:h}"
DATA_DIR="${REMOTE_SCRIBE_WEB_DATA_DIR:-$HOME/Library/Application Support/RemoteScribe/web}"
LOCAL_NAME="${REMOTE_SCRIBE_LOCAL_NAME:-$(scutil --get LocalHostName)}"

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"

if [[ ! -s "$DATA_DIR/web-access.key" ]]; then
  openssl rand -hex 24 > "$DATA_DIR/web-access.key"
  chmod 600 "$DATA_DIR/web-access.key"
fi

if [[ -f "$DATA_DIR/server.crt" && -f "$DATA_DIR/server.key" && -f "$DATA_DIR/remote-scribe-ca.cer" ]]; then
  print "Certificat Remote Scribe déjà présent dans : $DATA_DIR"
  exit 0
fi

openssl genrsa -out "$DATA_DIR/remote-scribe-ca.key" 3072
openssl req -x509 -new -key "$DATA_DIR/remote-scribe-ca.key" -sha256 -days 3650 \
  -subj "/CN=Remote Scribe Local CA/O=VoxLocal" -out "$DATA_DIR/remote-scribe-ca.crt"

openssl genrsa -out "$DATA_DIR/server.key" 2048
openssl req -new -key "$DATA_DIR/server.key" -subj "/CN=${LOCAL_NAME}.local/O=VoxLocal" -out "$DATA_DIR/server.csr"

CONFIG="$DATA_DIR/server-extensions.cnf"
print "subjectAltName=DNS:${LOCAL_NAME}.local,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment" > "$CONFIG"
openssl x509 -req -in "$DATA_DIR/server.csr" -CA "$DATA_DIR/remote-scribe-ca.crt" \
  -CAkey "$DATA_DIR/remote-scribe-ca.key" -CAcreateserial -out "$DATA_DIR/server.crt" \
  -days 825 -sha256 -extfile "$CONFIG"
openssl x509 -in "$DATA_DIR/remote-scribe-ca.crt" -outform der -out "$DATA_DIR/remote-scribe-ca.cer"

chmod 600 "$DATA_DIR"/*.key
print "HTTPS privé prêt pour https://${LOCAL_NAME}.local:8443/"
