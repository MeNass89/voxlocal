#!/usr/bin/env bash
# Generate the TLS identity of a VoxLocal Python host (macOS or Linux).
#
# Same certificate as VoxLocal.app (RemoteScribeTLSIdentity): RSA 2048,
# self-signed, 3650 days, SAN DNS:<host>.local, DNS:localhost, IP:127.0.0.1.
# The iPhone pins the SHA-256 of the DER certificate; this script prints it in
# base64 (Bonjour TXT "fp", server log) and in grouped hex (what the phone shows).
#
# Usage: scripts/make-tls-identity.sh [--force] OUTPUT_DIR [HOSTNAME]
# An existing identity is never overwritten without --force: the script prints
# its fingerprint and exits 0, so it is safe to run again.
set -euo pipefail

usage() {
  echo "Usage : $0 [--force] DOSSIER_SORTIE [NOM_HOTE]" >&2
  exit 2
}

FORCE=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) usage ;;
    -*) echo "Option inconnue : $arg" >&2; usage ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done
[[ ${#POSITIONAL[@]} -ge 1 && ${#POSITIONAL[@]} -le 2 ]] || usage

OUT_DIR="${POSITIONAL[0]}"
HOST_NAME="${POSITIONAL[1]:-}"
if [[ -z "$HOST_NAME" ]]; then
  HOST_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo voxlocal)"
fi
HOST_NAME="${HOST_NAME%.local}"
# The name is interpolated into -subj and -addext: accept a DNS label only.
if [[ ! "$HOST_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
  echo "Nom d'hôte invalide : '$HOST_NAME' (lettres, chiffres et tirets uniquement)." >&2
  exit 2
fi

OPENSSL="${OPENSSL:-$(command -v openssl || true)}"
if [[ -z "$OPENSSL" || ! -x "$OPENSSL" ]]; then
  echo "openssl introuvable." >&2
  exit 2
fi

KEY="$OUT_DIR/server.key.pem"
CERT="$OUT_DIR/server.cert.pem"

print_fingerprints() {
  local b64 hex
  b64="$("$OPENSSL" x509 -in "$CERT" -outform der | "$OPENSSL" dgst -sha256 -binary | "$OPENSSL" base64 -A)"
  hex="$("$OPENSSL" x509 -in "$CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'a-f' 'A-F')"
  echo "Certificat : $CERT"
  echo "Clé privée : $KEY"
  echo "Empreinte SHA-256 (base64) : $b64"
  echo "Empreinte SHA-256 (à comparer sur l'iPhone) : $(printf '%s' "$hex" | sed -e 's/..../& /g' -e 's/ $//')"
}

umask 077
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

if [[ -e "$KEY" || -e "$CERT" ]] && [[ $FORCE -eq 0 ]]; then
  if [[ -f "$KEY" && -f "$CERT" ]]; then
    echo "Identité TLS existante conservée (--force pour la remplacer ; l'iPhone devra alors la réapprouver)."
    chmod 600 "$KEY"
    print_fingerprints
    exit 0
  fi
  echo "Identité TLS incomplète dans $OUT_DIR ; relancez avec --force pour la régénérer." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "$OUT_DIR/.tls-identity.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP_DIR/server.key.pem" -out "$TMP_DIR/server.cert.pem" -days 3650 \
  -subj "/CN=$HOST_NAME.local/O=VoxLocal" \
  -addext "subjectAltName=DNS:$HOST_NAME.local,DNS:localhost,IP:127.0.0.1" 2>/dev/null
chmod 600 "$TMP_DIR/server.key.pem"
chmod 644 "$TMP_DIR/server.cert.pem"
mv -f "$TMP_DIR/server.key.pem" "$KEY"
mv -f "$TMP_DIR/server.cert.pem" "$CERT"

echo "Identité TLS créée pour $HOST_NAME.local."
print_fingerprints
