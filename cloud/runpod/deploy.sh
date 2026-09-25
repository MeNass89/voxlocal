#!/usr/bin/env bash
set -Eeuo pipefail

# One-command RunPod deployment of the VoxLocal GPU runtime.
#
#   VOXLOCAL_IMAGE=docker.io/<you>/voxlocal-runpod:2026-09-25 \
#   VOXLOCAL_TOKEN_SECRET=<RunPod secret name> \
#   RUNPOD_API_KEY=... bash cloud/runpod/deploy.sh
#
# Steps: build and push the image (linux/amd64) -> create a Pod template with a
# persistent volume and TCP 8443 -> create the Pod on VOXLOCAL_GPU -> wait for
# the public address -> read the TLS fingerprint from the Pod log -> fetch the
# certificate over the network, check it matches, and save it for the hosts.
#
# The API token comes from the RunPod secret named by VOXLOCAL_TOKEN_SECRET
# (required) and is never read, stored or printed here.
# RUNPOD_API_KEY is read from the environment only and never put on a command
# line of this script.
#
# Optional environment:
#   VOXLOCAL_GPU               RunPod GPU id (default "NVIDIA GeForce RTX 4090";
#                              list: runpodctl gpu list)
#   VOXLOCAL_CLOUD_TYPE        SECURE (default) or COMMUNITY
#   VOXLOCAL_VOLUME_GB         persistent volume on /workspace (default 30)
#   VOXLOCAL_DISK_GB           container disk (default 20)
#   VOXLOCAL_NETWORK_VOLUME_ID attach an existing network volume instead
#   VOXLOCAL_DATA_CENTER       data center id (e.g. EU-RO-1), useful for GDPR
#   VOXLOCAL_REGISTRY_AUTH_ID  runpodctl registry auth id for a private image
#   VOXLOCAL_SKIP_BUILD=1      use an image that is already pushed
#   VOXLOCAL_POD_NAME          default voxlocal-<UTC timestamp>
#   VOXLOCAL_WAIT_SECONDS      overall wait for address, fingerprint, edge (default 1800)
#   VOXLOCAL_DEPLOY_DIR        where the Pod certificate is saved
#                              (default ~/.voxlocal/runpod)
#   WHISPER_MODEL, WHISPER_MODEL_URL, WHISPER_MODEL_SHA256, WHISPER_LANGUAGE,
#   LLM_MODEL, LLM_MODEL_URL, LLM_MODEL_SHA256, VOXLOCAL_LLM (on|off)
#                              forwarded to the Pod (see entrypoint.sh). A model
#                              URL with a query string, token= or credentials is
#                              refused (it would sit in runpodctl's argv); use a
#                              RunPod secret reference for a signed URL.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GPU="${VOXLOCAL_GPU:-NVIDIA GeForce RTX 4090}"
CLOUD_TYPE="${VOXLOCAL_CLOUD_TYPE:-SECURE}"
VOLUME_GB="${VOXLOCAL_VOLUME_GB:-30}"
DISK_GB="${VOXLOCAL_DISK_GB:-20}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
POD_NAME="${VOXLOCAL_POD_NAME:-voxlocal-$STAMP}"
DEPLOY_DIR="${VOXLOCAL_DEPLOY_DIR:-$HOME/.voxlocal/runpod}"
EDGE_PORT=8443
# Covers image pull, first-boot model download (about 3.7 GB) and edge start.
WAIT_SECONDS="${VOXLOCAL_WAIT_SECONDS:-1800}"

log() { echo "voxlocal-deploy: $*" >&2; }
die() { echo "voxlocal-deploy: $*" >&2; exit "${2:-1}"; }

# --- Guards (exit 2 = missing prerequisite) ---------------------------------
if ! command -v runpodctl >/dev/null 2>&1; then
  cat >&2 <<'MSG'
voxlocal-deploy: runpodctl is not installed. Install it with one of:
  curl -sSL https://cli.runpod.net | bash
  brew install runpod/runpodctl/runpodctl
MSG
  exit 2
fi
if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
  cat >&2 <<'MSG'
voxlocal-deploy: RUNPOD_API_KEY is not set. Create a key in the RunPod console, then:
  export RUNPOD_API_KEY=<key>
MSG
  exit 2
fi
command -v python3 >/dev/null 2>&1 || die "python3 is required to read runpodctl JSON" 2
command -v openssl >/dev/null 2>&1 || die "openssl is required to check the Pod certificate" 2
[[ -n "${VOXLOCAL_IMAGE:-}" ]] || die "set VOXLOCAL_IMAGE to the registry reference to push, e.g. docker.io/<you>/voxlocal-runpod:$STAMP" 2
[[ "$VOXLOCAL_IMAGE" =~ ^[A-Za-z0-9./:@_-]+$ ]] || die "VOXLOCAL_IMAGE contains invalid characters" 2
[[ "$VOLUME_GB" =~ ^[0-9]+$ && "$DISK_GB" =~ ^[0-9]+$ ]] || die "VOXLOCAL_VOLUME_GB and VOXLOCAL_DISK_GB must be integers" 2
[[ "$CLOUD_TYPE" == SECURE || "$CLOUD_TYPE" == COMMUNITY ]] || die "VOXLOCAL_CLOUD_TYPE must be SECURE or COMMUNITY" 2
if [[ -z "${VOXLOCAL_TOKEN_SECRET:-}" ]]; then
  cat >&2 <<'MSG'
voxlocal-deploy: VOXLOCAL_TOKEN_SECRET is not set. The image runs no SSH server, so
a token generated inside the Pod could not be read back. Create the token first:
  openssl rand -hex 32        # store it in the host's vault (Keychain, Credential Manager)
then create a RunPod secret with that value (console: Secrets > Create Secret) and:
  export VOXLOCAL_TOKEN_SECRET=<secret name>
MSG
  exit 2
fi
[[ "$VOXLOCAL_TOKEN_SECRET" =~ ^[A-Za-z0-9_-]+$ ]] || die "VOXLOCAL_TOKEN_SECRET must be a RunPod secret name" 2
# runpodctl takes the Pod environment inline (--env JSON), so every value below
# appears in its argv. A signed or tokenised model URL would leak there: refuse
# it before anything runs. Put such a URL in a RunPod secret and pass the
# reference instead, e.g. WHISPER_MODEL_URL='{{ RUNPOD_SECRET_whisper_url }}'.
for name in WHISPER_MODEL_URL LLM_MODEL_URL; do
  value="${!name:-}"
  if [[ "$value" == *\?* || "$value" == *token=* || "$value" =~ ^[A-Za-z]+://[^/]*@ ]]; then
    die "$name must be a public URL: a query string, token= or user:password@ would appear in runpodctl's arguments; store the URL in a RunPod secret and set $name='{{ RUNPOD_SECRET_<name> }}'" 2
  fi
done
unset value
if [[ "${VOXLOCAL_SKIP_BUILD:-0}" != 1 ]] && ! command -v docker >/dev/null 2>&1; then
  die "docker is required to build the image (or set VOXLOCAL_SKIP_BUILD=1 for an image already pushed)" 2
fi

# san_names_ip <openssl certificate text> <ip>: the SAN lists exactly this
# address. A plain substring test would accept 203.0.113.45 for 203.0.113.4.
san_names_ip() {
  local text="$1" needle="IP Address:$2"
  [[ "$text" == *"$needle" || "$text" == *"$needle,"* || "$text" == *"$needle"[[:space:]]* ]]
}

json_field() {
  # json_field <top-level key>: reads a JSON object on stdin, prints the value or nothing.
  python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get(sys.argv[1])
except Exception:
    value = None
if value is not None:
    print(value)
' "$1"
}

# --- 1. Image ---------------------------------------------------------------
IMAGE_REF="$VOXLOCAL_IMAGE"
if [[ "${VOXLOCAL_SKIP_BUILD:-0}" != 1 ]]; then
  log "building $VOXLOCAL_IMAGE (linux/amd64; CUDA compile takes a while)"
  docker build --platform linux/amd64 -f "$REPO_ROOT/cloud/runpod/Dockerfile" -t "$VOXLOCAL_IMAGE" "$REPO_ROOT"
  log "pushing $VOXLOCAL_IMAGE"
  push_log="$(docker push "$VOXLOCAL_IMAGE" | tee /dev/stderr)"
  digest="$(grep -oE 'digest: sha256:[0-9a-f]{64}' <<<"$push_log" | tail -n 1 | cut -d' ' -f2 || true)"
  [[ -n "$digest" ]] || die "pushed, but no digest in the docker push output; rerun with VOXLOCAL_SKIP_BUILD=1 and VOXLOCAL_IMAGE=<repo>@sha256:<digest>"
  repo="$VOXLOCAL_IMAGE"
  # Drop the tag (a colon in the last path segment), never a registry port.
  [[ "${repo##*/}" != *:* ]] || repo="${repo%:*}"
  IMAGE_REF="${repo%@*}@$digest"
  log "image pinned by digest: $IMAGE_REF"
fi

# --- 2. Template ------------------------------------------------------------
ENV_JSON="$(python3 - <<'PY'
import json, os
env = {}
for name in ("WHISPER_MODEL", "WHISPER_MODEL_URL", "WHISPER_MODEL_SHA256", "WHISPER_LANGUAGE",
             "LLM_MODEL", "LLM_MODEL_URL", "LLM_MODEL_SHA256", "VOXLOCAL_LLM"):
    if name in os.environ:
        env[name] = os.environ[name]
# A reference resolved by RunPod at Pod start; the value never passes here.
env["VOXLOCAL_API_TOKEN_INIT"] = "{{ RUNPOD_SECRET_%s }}" % os.environ["VOXLOCAL_TOKEN_SECRET"]
print(json.dumps(env, separators=(",", ":")))
PY
)"
template_args=(template create --name "$POD_NAME" --image "$IMAGE_REF"
  --ports "$EDGE_PORT/tcp" --container-disk-in-gb "$DISK_GB" --env "$ENV_JSON"
  --readme "VoxLocal GPU runtime: whisper-server + llama-server behind a TLS 1.3 Bearer edge on $EDGE_PORT/tcp.")
[[ -n "${VOXLOCAL_NETWORK_VOLUME_ID:-}" ]] || template_args+=(--volume-in-gb "$VOLUME_GB" --volume-mount-path /workspace)
[[ -z "${VOXLOCAL_REGISTRY_AUTH_ID:-}" ]] || template_args+=(--registry-auth-id "$VOXLOCAL_REGISTRY_AUTH_ID")
log "creating template $POD_NAME"
template_json="$(runpodctl -o json "${template_args[@]}")" || die "template creation failed"
TEMPLATE_ID="$(json_field id <<<"$template_json")"
[[ -n "$TEMPLATE_ID" ]] || die "template created but no id was returned; check 'runpodctl template list --type user'"
log "template id: $TEMPLATE_ID"

# --- 3. Pod -----------------------------------------------------------------
pod_args=(pod create --template-id "$TEMPLATE_ID" --name "$POD_NAME" --gpu-id "$GPU" --gpu-count 1
  --cloud-type "$CLOUD_TYPE" --container-disk-in-gb "$DISK_GB" --ports "$EDGE_PORT/tcp")
if [[ -n "${VOXLOCAL_NETWORK_VOLUME_ID:-}" ]]; then
  pod_args+=(--network-volume-id "$VOXLOCAL_NETWORK_VOLUME_ID" --volume-mount-path /workspace)
else
  pod_args+=(--volume-in-gb "$VOLUME_GB" --volume-mount-path /workspace)
fi
[[ "$CLOUD_TYPE" != COMMUNITY ]] || pod_args+=(--public-ip)
[[ -z "${VOXLOCAL_DATA_CENTER:-}" ]] || pod_args+=(--data-center-ids "$VOXLOCAL_DATA_CENTER")
[[ -z "${VOXLOCAL_REGISTRY_AUTH_ID:-}" ]] || pod_args+=(--registry-auth-id "$VOXLOCAL_REGISTRY_AUTH_ID")
log "creating Pod on \"$GPU\" ($CLOUD_TYPE)"
pod_json="$(runpodctl -o json "${pod_args[@]}")" || die "Pod creation failed (GPU stock? try another VOXLOCAL_GPU or VOXLOCAL_DATA_CENTER)"
POD_ID="$(json_field id <<<"$pod_json")"
[[ -n "$POD_ID" ]] || die "Pod created but no id was returned; check 'runpodctl pod list'"
log "Pod id: $POD_ID (billing runs until 'runpodctl pod stop $POD_ID' or 'runpodctl pod delete $POD_ID')"
cost="$(json_field costPerHr <<<"$pod_json")"
[[ -z "$cost" ]] || log "cost: \$$cost/h"

# --- 4. Public address ------------------------------------------------------
# runpodctl does not expose portMappings; read them from the REST API with the
# key taken from the environment inside python (never argv).
pod_address() {
  python3 - "$1" "$EDGE_PORT" <<'PY'
import json, os, sys, urllib.request
pod_id, port = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    f"https://rest.runpod.io/v1/pods/{pod_id}",
    headers={"Authorization": "Bearer " + os.environ["RUNPOD_API_KEY"], "Accept": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        pod = json.load(resp)
except Exception:
    sys.exit(0)
ip = pod.get("publicIp") or ""
mapped = (pod.get("portMappings") or {}).get(port)
if ip and mapped:
    print(f"{ip} {mapped}")
PY
}

deadline=$((SECONDS + WAIT_SECONDS))
ADDRESS=""
while ((SECONDS < deadline)); do
  ADDRESS="$(pod_address "$POD_ID" || true)"
  [[ -z "$ADDRESS" ]] || break
  sleep 10
done
[[ -n "$ADDRESS" ]] || die "no public address for $EDGE_PORT/tcp after ${WAIT_SECONDS}s; inspect with 'runpodctl pod get $POD_ID' and 'runpodctl pod logs $POD_ID'"
PUBLIC_IP="${ADDRESS% *}"
PUBLIC_PORT="${ADDRESS#* }"
log "edge address: $PUBLIC_IP:$PUBLIC_PORT"

# --- 5. Fingerprint from the Pod log ----------------------------------------
FINGERPRINT=""
while ((SECONDS < deadline)); do
  FINGERPRINT="$(runpodctl -o json pod logs "$POD_ID" --source container --tail 1000 2>/dev/null \
    | python3 -c '
import json, re, sys
found = ""
for raw in sys.stdin:
    try:
        line = json.loads(raw).get("line", "")
    except Exception:
        line = raw
    m = re.search(r"TLS certificate SHA-256 fingerprint: ([0-9A-F]{2}(?::[0-9A-F]{2}){31})", line)
    if m:
        found = m.group(1)
print(found)
' || true)"
  [[ -z "$FINGERPRINT" ]] || break
  sleep 10
done
[[ -n "$FINGERPRINT" ]] || die "the TLS fingerprint did not appear in the Pod log; inspect with 'runpodctl pod logs $POD_ID'"
echo "TLS fingerprint (from the Pod log): $FINGERPRINT"

# --- 6. Pin the certificate -------------------------------------------------
mkdir -p "$DEPLOY_DIR"
chmod 700 "$DEPLOY_DIR"
CERT_FILE="$DEPLOY_DIR/$POD_ID-edge.pem"
served=""
while ((SECONDS < deadline)); do
  # s_client's exit status is not reliable (LibreSSL returns 1 after a good
  # handshake), so judge by whether a certificate can be parsed from its output.
  handshake="$(openssl s_client -connect "$PUBLIC_IP:$PUBLIC_PORT" -tls1_3 </dev/null 2>/dev/null || true)"
  if openssl x509 -outform PEM >"$CERT_FILE.tmp" 2>/dev/null <<<"$handshake"; then
    served="$(openssl x509 -in "$CERT_FILE.tmp" -noout -fingerprint -sha256 | cut -d= -f2)"
    break
  fi
  sleep 10
done
[[ -n "$served" ]] || { rm -f "$CERT_FILE.tmp"; die "could not reach the TLS edge at $PUBLIC_IP:$PUBLIC_PORT"; }
if [[ "$served" != "$FINGERPRINT" ]]; then
  rm -f "$CERT_FILE.tmp"
  die "certificate served at $PUBLIC_IP:$PUBLIC_PORT ($served) does not match the Pod log ($FINGERPRINT); do not use this endpoint"
fi
mv -f "$CERT_FILE.tmp" "$CERT_FILE"
log "certificate matches the Pod log; saved to $CERT_FILE"
cert_text="$(openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null || true)"
if ! san_names_ip "$cert_text" "$PUBLIC_IP"; then
  log "WARNING: the certificate does not name $PUBLIC_IP (RUNPOD_PUBLIC_IP was unset at boot); restart the Pod once, or provide VOXLOCAL_TLS_CERT/KEY for a DNS name"
fi

token_hint="the value of the RunPod secret $VOXLOCAL_TOKEN_SECRET"
cat <<MSG

VoxLocal GPU runtime deployed (Pod $POD_ID). Models download at first boot;
the endpoint answers once 'runpodctl pod logs $POD_ID' shows "started edge".

Host configuration (Mac, Windows, agent):
  VOXLOCAL_GPU_URL=https://$PUBLIC_IP:$PUBLIC_PORT/voice
  VOXLOCAL_LLM_URL=https://$PUBLIC_IP:$PUBLIC_PORT/llm
  VOXLOCAL_GPU_TOKEN / VOXLOCAL_LLM_TOKEN = $token_hint
  --gpu-ca-file $CERT_FILE    (pins this Pod's certificate)

Benchmark:
  VOXLOCAL_API_TOKEN=<token> python3 cloud/runpod/benchmark.py --iterations 5 --timeout 30 \\
    --ca-file $CERT_FILE --voice-url https://$PUBLIC_IP:$PUBLIC_PORT/voice --llm-url https://$PUBLIC_IP:$PUBLIC_PORT/llm
MSG
