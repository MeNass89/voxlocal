#!/usr/bin/env bash
set -Eeuo pipefail

# VoxLocal RunPod image entrypoint.
#
# At every boot it installs the runtime scripts into the persistent volume,
# makes sure an API token and a TLS certificate exist, pulls the models if they
# are absent, writes the Caddy edge configuration, then hands over to
# start-all.sh, which supervises whisper-server, llama-server and Caddy.
#
# Only Caddy listens on a non-loopback address (:8443, TLS 1.3, Bearer token
# required). The token is never printed and never placed on a command line.
ROOT_DIR="${VOXLOCAL_ROOT:-/workspace/voxlocal}"
IMAGE_DIR="${VOXLOCAL_IMAGE_DIR:-/opt/voxlocal}"
MODELS_DIR="${VOXLOCAL_MODELS_DIR:-/models}"
TOKEN_FILE="$ROOT_DIR/api-token"
RUN_DIR="$ROOT_DIR/run"
TLS_DIR="$ROOT_DIR/tls"
EDGE_PORT="${VOXLOCAL_EDGE_PORT:-8443}"

# Defaults are pinned to a Hugging Face revision and verified by SHA-256. They
# are a starting point for the GPU benchmark, not a clinical model choice.
DEFAULT_WHISPER_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin"
DEFAULT_LLM_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/7dabda4d13d513e3e842b20f0d435c732f172cbe/qwen2.5-3b-instruct-q4_k_m.gguf"
WHISPER_MODEL_URL="${WHISPER_MODEL_URL:-$DEFAULT_WHISPER_MODEL_URL}"
LLM_MODEL_URL="${LLM_MODEL_URL:-$DEFAULT_LLM_MODEL_URL}"
WHISPER_MODEL="${WHISPER_MODEL:-ggml-large-v3-turbo.bin}"
LLM_MODEL="${LLM_MODEL:-qwen2.5-3b-instruct-q4_k_m.gguf}"
# Unset means "the default model's hash"; an explicit empty value skips the check.
WHISPER_MODEL_SHA256="${WHISPER_MODEL_SHA256-1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69}"
LLM_MODEL_SHA256="${LLM_MODEL_SHA256-626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-fr}"
LLM_ENABLED="${VOXLOCAL_LLM:-on}"

log() { echo "voxlocal-entrypoint: $*"; }
die() { echo "voxlocal-entrypoint: $*" >&2; exit 2; }

[[ "$WHISPER_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "WHISPER_MODEL must be a plain file name"
[[ "$LLM_MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "LLM_MODEL must be a plain file name"
[[ "$WHISPER_LANGUAGE" =~ ^([a-z]{2,3}|auto)$ ]] || die "WHISPER_LANGUAGE must be an ISO code such as fr, or auto"
[[ "$LLM_ENABLED" == on || "$LLM_ENABLED" == off ]] || die "VOXLOCAL_LLM must be on or off"
[[ "$EDGE_PORT" =~ ^[0-9]{2,5}$ ]] || die "VOXLOCAL_EDGE_PORT must be a port number"
READY_TIMEOUT="${VOXLOCAL_READY_TIMEOUT:-60}"
[[ "$READY_TIMEOUT" =~ ^[0-9]{1,4}$ ]] || die "VOXLOCAL_READY_TIMEOUT must be a whole number of seconds"

umask 077
mkdir -p "$ROOT_DIR" "$RUN_DIR" "$TLS_DIR"
# /models is a symlink into the volume; create its target, not the link.
mkdir -p "$(readlink -f "$MODELS_DIR" 2>/dev/null || echo "$MODELS_DIR")"
chmod 700 "$ROOT_DIR"

# The volume hides anything the image puts under /workspace: install the
# scripts from the image at every boot so the image stays the source of truth.
for script in "$IMAGE_DIR"/*.sh "$IMAGE_DIR"/*.py; do
  [[ -f "$script" ]] || continue
  cp -f "$script" "$ROOT_DIR/"
  chmod 700 "$ROOT_DIR/$(basename "$script")"
done
[[ -f "$ROOT_DIR/start-all.sh" ]] || die "start-all.sh is missing from $IMAGE_DIR"

if command -v nvidia-smi >/dev/null 2>&1; then
  log "GPU $(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | head -n 1 || echo unknown)"
fi

# --- API token --------------------------------------------------------------
# VOXLOCAL_API_TOKEN_INIT is meant to hold a RunPod secret reference
# ({{ RUNPOD_SECRET_<name> }}), so the operator knows the token without a Pod
# shell. It replaces the stored token at every boot (rotation = edit the secret
# and restart). Without it, a random token is generated once.
if [[ -n "${VOXLOCAL_API_TOKEN_INIT:-}" ]]; then
  token="$VOXLOCAL_API_TOKEN_INIT"
  unset VOXLOCAL_API_TOKEN_INIT
  [[ "$token" =~ ^[A-Za-z0-9._~-]{32,256}$ ]] || die "VOXLOCAL_API_TOKEN_INIT must be 32 to 256 URL-safe characters"
  printf '%s\n' "$token" >"$TOKEN_FILE.tmp"
  unset token
  chmod 600 "$TOKEN_FILE.tmp"
  mv -f "$TOKEN_FILE.tmp" "$TOKEN_FILE"
  log "API token installed from VOXLOCAL_API_TOKEN_INIT (not printed)"
elif [[ ! -s "$TOKEN_FILE" ]]; then
  openssl rand -hex 32 >"$TOKEN_FILE.tmp"
  chmod 600 "$TOKEN_FILE.tmp"
  mv -f "$TOKEN_FILE.tmp" "$TOKEN_FILE"
  log "API token generated in $TOKEN_FILE (not printed; read it from a Pod shell)"
fi
chmod 600 "$TOKEN_FILE"

# --- TLS --------------------------------------------------------------------
print_fingerprint() {
  log "TLS certificate SHA-256 fingerprint: $(openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2)"
}

ensure_self_signed() {
  local cert="$1" key="$2" ip="${RUNPOD_PUBLIC_IP:-}" san="DNS:localhost,IP:127.0.0.1"
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || ip=""
  [[ -z "$ip" ]] || san="$san,IP:$ip"
  if [[ ! -s "$key" ]]; then
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$key.tmp" 2>/dev/null
    chmod 600 "$key.tmp"
    mv -f "$key.tmp" "$key"
  fi
  if [[ -s "$cert" ]] \
     && openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null 2>&1 \
     && [[ "$(openssl x509 -in "$cert" -noout -pubkey)" == "$(openssl pkey -in "$key" -pubout)" ]] \
     && { [[ -z "$ip" ]] || [[ "$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null)" == *"IP Address:$ip"* ]]; }; then
    return 0
  fi
  # A new certificate keeps the same key; the fingerprint changes and is
  # printed so clients can re-pin it.
  openssl req -x509 -new -key "$key" -sha256 -days 825 -subj "/CN=voxlocal-runpod" \
    -addext "subjectAltName=$san" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=serverAuth" \
    -out "$cert.tmp" 2>/dev/null
  chmod 644 "$cert.tmp"
  mv -f "$cert.tmp" "$cert"
  log "TLS self-signed certificate generated for $san"
}

TLS_CERT="${VOXLOCAL_TLS_CERT:-}"
TLS_KEY="${VOXLOCAL_TLS_KEY:-}"
if [[ -z "$TLS_CERT" && -z "$TLS_KEY" ]]; then
  TLS_CERT="$TLS_DIR/cert.pem"
  TLS_KEY="$TLS_DIR/key.pem"
  ensure_self_signed "$TLS_CERT" "$TLS_KEY"
elif [[ -z "$TLS_CERT" || -z "$TLS_KEY" ]]; then
  die "VOXLOCAL_TLS_CERT and VOXLOCAL_TLS_KEY must be set together"
fi
[[ -s "$TLS_CERT" ]] || die "TLS certificate is missing: $TLS_CERT"
# Once per boot: the fingerprint is public and is what clients pin.
print_fingerprint "$TLS_CERT"
export VOXLOCAL_TLS_CERT="$TLS_CERT" VOXLOCAL_TLS_KEY="$TLS_KEY"

# --- Models -----------------------------------------------------------------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch_model() {
  local name="$1" url="$2" sha="$3" target="$MODELS_DIR/$1"
  if [[ -s "$target" ]]; then
    log "model present: $name"
    return 0
  fi
  [[ "$url" == https://* ]] || die "model URL for $name must use https"
  # The URL is not logged: a signed or tokenised URL must not reach the log.
  log "downloading model $name"
  curl -fsSL --proto '=https' --retry 3 --retry-delay 5 -o "$target.partial" "$url" \
    || { rm -f "$target.partial"; die "download failed for $name"; }
  if [[ -n "$sha" ]]; then
    local got
    got="$(sha256_of "$target.partial")"
    if [[ "$got" != "$sha" ]]; then
      rm -f "$target.partial"
      die "SHA-256 mismatch for $name (expected $sha, got $got); set the matching *_MODEL_SHA256, or an empty value to skip the check"
    fi
    log "model verified: $name sha256=$got"
  else
    log "WARNING: model $name was not verified (empty *_MODEL_SHA256)"
  fi
  chmod 644 "$target.partial"
  mv -f "$target.partial" "$target"
}

fetch_model "$WHISPER_MODEL" "$WHISPER_MODEL_URL" "$WHISPER_MODEL_SHA256"
[[ "$LLM_ENABLED" == off ]] || fetch_model "$LLM_MODEL" "$LLM_MODEL_URL" "$LLM_MODEL_SHA256"

# --- Edge -------------------------------------------------------------------
# Every request needs the exact Bearer token ({env.*} is resolved by Caddy at
# request time, so the token is never written to this file or to Caddy's
# autosave). Only the OpenAI routes the hosts use are forwarded, under /voice,
# /llm, or unprefixed; everything else authenticated gets 404, everything
# unauthenticated gets 401. No access log is configured, so no request line or
# body is logged by the edge.
cat >"$RUN_DIR/Caddyfile" <<'CADDYFILE'
{
	admin off
	auto_https off
	persist_config off
	servers {
		protocols h1 h2
	}
}

:{$VOXLOCAL_EDGE_PORT} {
	tls {$VOXLOCAL_TLS_CERT} {$VOXLOCAL_TLS_KEY} {
		protocols tls1.3
	}

	@auth header Authorization "Bearer {env.VOXLOCAL_API_TOKEN}"
	handle @auth {
		# whisper-server has no /v1/models route; the edge answers it.
		@voice_models {
			method GET
			path /voice/v1/models
		}
		handle @voice_models {
			header Content-Type application/json
			header Cache-Control no-store
			respond `{"object":"list","data":[{"id":"{$VOXLOCAL_WHISPER_MODEL_ID}","object":"model","owned_by":"voxlocal"}]}` 200
		}

		@voice_transcribe {
			method POST
			path /voice/v1/audio/transcriptions
		}
		handle @voice_transcribe {
			request_body {
				max_size 64MB
			}
			uri strip_prefix /voice
			reverse_proxy 127.0.0.1:8001
		}

		# VOXLOCAL_LLM=off: no llama-server behind the edge, so the LLM routes
		# answer a JSON 404 instead of a 502 from an empty upstream.
		@llm_off {
			path /llm/* /v1/chat/completions
			expression `{env.VOXLOCAL_LLM_ENABLED} == "off"`
		}
		handle @llm_off {
			header Content-Type application/json
			header Cache-Control no-store
			respond `{"error":{"message":"LLM disabled on this runtime (VOXLOCAL_LLM=off)","type":"not_found","code":404}}` 404
		}

		@llm {
			path /llm/v1/models /llm/v1/chat/completions
		}
		handle @llm {
			request_body {
				max_size 1MB
			}
			uri strip_prefix /llm
			reverse_proxy 127.0.0.1:8003
		}

		# Unprefixed routes for hosts configured with a single base URL (the
		# Mac app): transcription goes to Whisper, chat to the LLM, and the
		# model list names both.
		@root_models {
			method GET
			path /v1/models
		}
		handle @root_models {
			header Content-Type application/json
			header Cache-Control no-store
			respond `{"object":"list","data":[{$VOXLOCAL_MODELS_DATA}]}` 200
		}

		@root_transcribe {
			method POST
			path /v1/audio/transcriptions
		}
		handle @root_transcribe {
			request_body {
				max_size 64MB
			}
			reverse_proxy 127.0.0.1:8001
		}

		@root_chat {
			method POST
			path /v1/chat/completions
		}
		handle @root_chat {
			request_body {
				max_size 1MB
			}
			reverse_proxy 127.0.0.1:8003
		}

		respond 404
	}

	respond 401
}
CADDYFILE
chmod 600 "$RUN_DIR/Caddyfile"
# Model names are validated file names ([A-Za-z0-9._-]), so they are safe
# inside the JSON bodies of the Caddyfile.
models_data="{\"id\":\"$WHISPER_MODEL\",\"object\":\"model\",\"owned_by\":\"voxlocal\"}"
[[ "$LLM_ENABLED" == off ]] || models_data+=",{\"id\":\"$LLM_MODEL\",\"object\":\"model\",\"owned_by\":\"voxlocal\"}"
export VOXLOCAL_EDGE_PORT="$EDGE_PORT" VOXLOCAL_WHISPER_MODEL_ID="$WHISPER_MODEL" VOXLOCAL_MODELS_DATA="$models_data"

# --- Services ---------------------------------------------------------------
printf -v whisper_path '%q' "$MODELS_DIR/$WHISPER_MODEL"
printf -v llm_path '%q' "$MODELS_DIR/$LLM_MODEL"
printf -v token_path '%q' "$TOKEN_FILE"
printf -v caddyfile_path '%q' "$RUN_DIR/Caddyfile"

export VOXLOCAL_VOICE_CMD="whisper-server --host 127.0.0.1 --port 8001 -m $whisper_path -l $WHISPER_LANGUAGE --request-path /v1/audio/transcriptions --inference-path \"\""
if [[ "$LLM_ENABLED" == on ]]; then
  # llama-server checks the same token itself (defence in depth behind Caddy);
  # --no-slots keeps prompts out of the slot monitoring endpoint.
  export VOXLOCAL_LLM_CMD="llama-server --host 127.0.0.1 --port 8003 -m $llm_path -ngl 99 -fa on --no-webui --no-slots --api-key-file $token_path"
else
  unset VOXLOCAL_LLM_CMD
fi
if [[ -n "${VOXLOCAL_LLM_CMD:-}" ]]; then
  export VOXLOCAL_LLM_ENABLED=on
else
  export VOXLOCAL_LLM_ENABLED=off
fi
# The edge waits (up to 60 s) for the model servers to answer /health, so the
# first request after boot does not meet a 502 while a model is still loading.
# whisper-server serves /health under its --request-path.
health_urls="http://127.0.0.1:8001/v1/audio/transcriptions/health"
[[ "$VOXLOCAL_LLM_ENABLED" == off ]] || health_urls+=" http://127.0.0.1:8003/health"
printf -v wait_path '%q' "$ROOT_DIR/wait-ready.sh"
export VOXLOCAL_EDGE_CMD="bash $wait_path $READY_TIMEOUT $health_urls && exec caddy run --config $caddyfile_path --adapter caddyfile"
export VOXLOCAL_ROOT="$ROOT_DIR" VOXLOCAL_TOKEN_FILE="$TOKEN_FILE"

log "starting services; edge on :$EDGE_PORT (TLS 1.3, Bearer token required)"
exec bash "$ROOT_DIR/start-all.sh"
