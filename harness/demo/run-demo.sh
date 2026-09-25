#!/usr/bin/env bash
# End-to-end demo of the clinical agent harness on the recorded portal (macOS / Linux dev).
#
#   harness/demo/run-demo.sh --check                 verify prerequisites only, exit 0 when all pass
#   harness/demo/run-demo.sh                          start the stack, print the URLs, wait for Ctrl-C
#   harness/demo/run-demo.sh --drive --shots DIR      start, drive the web chat headless, save 5 PNGs, stop
#
# Options:
#   --provider scripted|local|pod   model behind the agent (default scripted)
#       scripted  OpenAI-compatible stub replaying H4's scripted turns (deterministic; the demo)
#       local     llama-server on this Mac with a small GGUF (default Qwen2.5-0.5B: it cannot
#                 follow the tool protocol, so the turn will not reach a draft)
#       pod       the real target: Qwen3.8-27B on the RunPod edge, from VOXLOCAL_LLM_URL /
#                 VOXLOCAL_LLM_TOKEN in the environment
#   --seed-dictation FILE           synthetic dictation injected into the agent API in mock mode
#                                   (default harness/bridge/fixtures/transcript_entorse.txt)
#   --patient ID --encounter ID     patient declared before dictating (default pat-001 / enc-001-urg)
#   --dictation-source api|file     how the bridge reads the delivered dictation to check quotes:
#                                   api (default) GET /v1/dictations/<id> on the agent API;
#                                   file = a dictation-<id>.json copy (fallback)
#   --port N                        dsh web port (default 3081)
#   --drive / --shots DIR           headless run of the 90-second script with screenshots
#
# Everything this script starts is stopped on exit. Runtime files live in a fresh temp dir.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_DIR="$(cd "$DEMO_DIR/.." && pwd)"
REPO_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
PROFILE_DIR="$HARNESS_DIR/profile"

CHECK=0 DRIVE=0 SHOTS="" PROVIDER=scripted WEB_PORT=3081
SEED="$HARNESS_DIR/bridge/fixtures/transcript_entorse.txt"
PATIENT=pat-001 ENCOUNTER=enc-001-urg DICTATION_SOURCE=api
AGENT_PORT=47366 BRIDGE_PORT=47368 LLM_PORT=47381
LLAMA_SERVER="${LLAMA_SERVER:-/tmp/vox-w2-3-build/llama/bin/llama-server}"
LOCAL_MODEL="${VOXLOCAL_LOCAL_MODEL:-/tmp/vox-models/qwen2.5-0.5b-instruct-q4_k_m.gguf}"
HEADLESS_SHELL="${HEADLESS_SHELL:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --drive) DRIVE=1 ;;
    --shots) SHOTS="$2"; shift ;;
    --provider) PROVIDER="$2"; shift ;;
    --seed-dictation) SEED="$2"; shift ;;
    --patient) PATIENT="$2"; shift ;;
    --encounter) ENCOUNTER="$2"; shift ;;
    --dictation-source) DICTATION_SOURCE="$2"; shift ;;
    --port) WEB_PORT="$2"; shift ;;
    -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "option inconnue : $1 (voir --help)" >&2; exit 2 ;;
  esac
  shift
done
case "$PROVIDER" in scripted|local|pod) ;; *) echo "--provider : scripted, local ou pod" >&2; exit 2 ;; esac
case "$DICTATION_SOURCE" in api|file) ;; *) echo "--dictation-source : api ou file" >&2; exit 2 ;; esac

# Same check as harness/run-web.sh (keep the two copies identical; harness/tests/test_launchers.py compares them).
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
if [ "$PROVIDER" = pod ] && [ -n "${VOXLOCAL_LLM_URL:-}" ]; then
  check_llm_url VOXLOCAL_LLM_URL "$VOXLOCAL_LLM_URL" || exit 2
fi
[ "$DRIVE" = 0 ] || [ -n "$SHOTS" ] || SHOTS="$PWD/demo-shots"

if [ -z "$HEADLESS_SHELL" ]; then
  HEADLESS_SHELL="$(ls -d "$HOME"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell \
    "$HOME"/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-*/chrome-headless-shell 2>/dev/null | tail -1 || true)"
fi

# ------------------------------------------------------------------------ prerequisites
FAILED=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=1; }
port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

check() {
  echo "Prérequis (fournisseur : $PROVIDER)"
  if command -v node >/dev/null && node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=19)?0:1)'; then
    ok "node $(node --version) (≥ 22.19)"
  else fail "node ≥ 22.19 introuvable"; fi
  if command -v pnpm >/dev/null; then ok "pnpm $(pnpm --version)"; else fail "pnpm introuvable"; fi
  if command -v python3 >/dev/null && python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))'; then
    ok "python3 $(python3 -c 'import platform; print(platform.python_version())') (≥ 3.11)"
  else fail "python3 ≥ 3.11 introuvable"; fi
  if [ -x "$PROFILE_DIR/node_modules/.bin/dsh" ]; then
    ok "dsh $("$PROFILE_DIR/node_modules/.bin/dsh" --version 2>/dev/null) installé dans harness/profile"
  else fail "dsh absent : (cd harness/profile && pnpm install --frozen-lockfile)"; fi
  if [ -f "$SEED" ]; then ok "dictée synthétique : ${SEED#"$REPO_DIR"/}"; else fail "dictée introuvable : $SEED"; fi
  for pair in "agent API:$AGENT_PORT" "pont portail:$BRIDGE_PORT" "dsh web:$WEB_PORT"; do
    if port_free "${pair##*:}"; then ok "port ${pair##*:} libre (${pair%%:*})"; else fail "port ${pair##*:} occupé (${pair%%:*})"; fi
  done
  case "$PROVIDER" in
    scripted|local)
      if port_free "$LLM_PORT"; then ok "port $LLM_PORT libre (modèle)"; else fail "port $LLM_PORT occupé (modèle)"; fi ;;
  esac
  case "$PROVIDER" in
    local)
      if [ -x "$LLAMA_SERVER" ]; then ok "llama-server : $LLAMA_SERVER"; else fail "llama-server introuvable (LLAMA_SERVER=$LLAMA_SERVER)"; fi
      if [ -f "$LOCAL_MODEL" ]; then ok "modèle local : $LOCAL_MODEL"; else fail "modèle introuvable (VOXLOCAL_LOCAL_MODEL=$LOCAL_MODEL)"; fi ;;
    pod)
      if [ -n "${VOXLOCAL_LLM_URL:-}" ]; then ok "VOXLOCAL_LLM_URL défini"; else fail "VOXLOCAL_LLM_URL absent (passerelle du Pod, se termine par /v1)"; fi
      if [ -n "${VOXLOCAL_LLM_TOKEN:-}" ]; then ok "VOXLOCAL_LLM_TOKEN défini"; else fail "VOXLOCAL_LLM_TOKEN absent"; fi ;;
  esac
  if [ "$DRIVE" = 1 ] || [ "$CHECK" = 1 ]; then
    if [ -x "$HEADLESS_SHELL" ]; then ok "chrome-headless-shell (pour --drive) : $HEADLESS_SHELL"
    elif [ "$DRIVE" = 1 ]; then fail "chrome-headless-shell introuvable (npx playwright install chromium-headless-shell, ou HEADLESS_SHELL=…)"
    else echo "  info  chrome-headless-shell absent : --drive indisponible, la démo manuelle reste possible"; fi
  fi
  return "$FAILED"
}

if [ "$CHECK" = 1 ]; then
  if check; then echo "Tout est prêt."; exit 0; else echo "Prérequis manquants."; exit 1; fi
fi
check || { echo "Prérequis manquants : corriger puis relancer." >&2; exit 1; }

# ------------------------------------------------------------------------ stack
RUN="$(mktemp -d "${TMPDIR:-/tmp}/voxlocal-demo.XXXXXX")"
mkdir -p "$RUN/logs" "$RUN/dictations" "$RUN/audit" "$RUN/dsh-home/profiles"
PIDS=()
cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true; done
  echo "Arrêté. Journaux et audit conservés dans $RUN"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

rand() { python3 -c 'import secrets; print(secrets.token_hex(24))'; }
export VOXLOCAL_AGENT_TOKEN; VOXLOCAL_AGENT_TOKEN="$(rand)"
export PORTAIL_BRIDGE_TOKEN; PORTAIL_BRIDGE_TOKEN="$(rand)"
export PORTAIL_BRIDGE_APPROVER_TOKEN; PORTAIL_BRIDGE_APPROVER_TOKEN="$(rand)"
export PORTAIL_BRIDGE_URL="http://127.0.0.1:$BRIDGE_PORT/"
export SCRIBE_CLINICIAN="${SCRIBE_CLINICIAN:-dr.demo}"
export SCRIBE_APPROVALS_AUDIT="$RUN/audit/approvals.jsonl"
export DSH_TELEMETRY_MODE=DISABLED
unset DEEPSEEK_API_KEY OPENAI_API_KEY

wait_http() {  # url [auth-token] ; 30 s. The token goes to curl on stdin (-K -), never in argv.
  local i
  for i in $(seq 1 60); do
    if [ -n "${2:-}" ]; then
      if printf 'header = "Authorization: Bearer %s"\n' "$2" | curl -fsS -o /dev/null -K - "$1" 2>/dev/null; then return 0; fi
    elif curl -fsS -o /dev/null "$1" 2>/dev/null; then return 0; fi
    sleep 0.5
  done
  echo "pas de réponse de $1 (voir $RUN/logs)" >&2; return 1
}

cd "$REPO_DIR"

# 1. VoxLocal agent API, mock mode: the dictation source when no iPhone is in the room.
python3 -m agent.voxlocal_agent_api serve --mock --port "$AGENT_PORT" >"$RUN/logs/agent-api.log" 2>&1 &
PIDS+=($!)
wait_http "http://127.0.0.1:$AGENT_PORT/healthz" "$VOXLOCAL_AGENT_TOKEN"

# 2. Feeder, one pass: declare the patient, inject the synthetic dictation, deliver it.
#    VoxLocal delivers cleaned prose, not a hard-wrapped file: unwrap the seed first.
python3 - "$SEED" "$RUN/seed.txt" <<'PY'
import re, sys
lines = [l for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if not l.lstrip().startswith("#")]
open(sys.argv[2], "w", encoding="utf-8").write(re.sub(r"\s+", " ", " ".join(lines)).strip() + "\n")
PY
VOXLOCAL_API_TOKEN="$VOXLOCAL_AGENT_TOKEN" python3 harness/ingest/dictation_feeder.py \
  --api-url "http://127.0.0.1:$AGENT_PORT" --state-file "$RUN/feeder/state.json" \
  --once --backend dryrun --seed-file "$RUN/seed.txt" --patient-context "patient=$PATIENT rencontre=$ENCOUNTER" \
  >"$RUN/logs/feeder.log" 2>&1
DICTATION_ID="$(python3 - "$RUN/feeder/dryrun.jsonl" "$RUN/message.txt" <<'PY'
import json, sys
line = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()][-1]
text = line["text"] + ("\n\nPréparez les modifications du dossier (examen clinique et orientation), "
                       "puis appliquez-les après mon feu vert.")
open(sys.argv[2], "w", encoding="utf-8").write(text)
print(line["dictationId"])
PY
)"

# 3. The bridge checks every quote against the dictation it came from. By default it reads that
#    dictation from the agent API (GET /v1/dictations/<id>; patient and encounter from the declared
#    « patient=… rencontre=… »). Fallback (--dictation-source file): hand it a copy.
if [ "$DICTATION_SOURCE" = file ]; then
  python3 - "$RUN/dictations" "$DICTATION_ID" "$RUN/seed.txt" "$PATIENT" "$ENCOUNTER" <<'PY'
import json, shutil, sys
from pathlib import Path
out, did, seed, patient, encounter = Path(sys.argv[1]), *sys.argv[2:]
shutil.copyfile(seed, out / "dictation.txt")
(out / f"dictation-{did}.json").write_text(json.dumps({
    "synthetic": True, "dictation_id": did, "text_file": "dictation.txt",
    "patient_context": {"patient_id": patient, "encounter_id": encounter}}, ensure_ascii=False))
PY
fi

# 4. Portal bridge on the recorded mock, with its own drafts, audit and portal state. Exports in a
#    subshell, not `env VAR=…`: the API token never appears in a process's arguments.
(
  export PORTAIL_BRIDGE_DRAFTS="$RUN/bridge/drafts.jsonl" PORTAIL_BRIDGE_AUDIT="$RUN/audit/portal-writes.jsonl"
  export PORTAIL_BRIDGE_STATE_DIR="$RUN/bridge/state"
  if [ "$DICTATION_SOURCE" = file ]; then
    export PORTAIL_DICTATION_DIR="$RUN/dictations"
  else
    export VOXLOCAL_API_URL="http://127.0.0.1:$AGENT_PORT" VOXLOCAL_API_TOKEN="$VOXLOCAL_AGENT_TOKEN"
  fi
  exec python3 -m harness.bridge.portail_bridge --backend mock --port "$BRIDGE_PORT"
) >"$RUN/logs/bridge.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do grep -q "127.0.0.1:$BRIDGE_PORT" "$RUN/logs/bridge.log" 2>/dev/null && break; sleep 0.5; done
grep -q "127.0.0.1:$BRIDGE_PORT" "$RUN/logs/bridge.log" || { echo "le pont n'a pas démarré (voir $RUN/logs/bridge.log)" >&2; exit 1; }

# 5. The model.
case "$PROVIDER" in
  scripted)
    python3 -m harness.demo.scripted_provider --port "$LLM_PORT" --delay "${SCRIPTED_DELAY:-1.5}" >"$RUN/logs/model.log" 2>&1 &
    PIDS+=($!)
    export VOXLOCAL_LLM_URL="http://127.0.0.1:$LLM_PORT/v1" VOXLOCAL_LLM_TOKEN=scripted-demo
    wait_http "$VOXLOCAL_LLM_URL/models" ;;
  local)
    export VOXLOCAL_LLM_TOKEN; VOXLOCAL_LLM_TOKEN="$(rand)"
    (umask 077; printf '%s\n' "$VOXLOCAL_LLM_TOKEN" >"$RUN/llm-key")  # file, not argv: stays out of ps
    "$LLAMA_SERVER" -m "$LOCAL_MODEL" --host 127.0.0.1 --port "$LLM_PORT" -c 16384 --jinja \
      --api-key-file "$RUN/llm-key" >"$RUN/logs/model.log" 2>&1 &
    PIDS+=($!)
    export VOXLOCAL_LLM_URL="http://127.0.0.1:$LLM_PORT/v1"
    wait_http "$VOXLOCAL_LLM_URL/models" "$VOXLOCAL_LLM_TOKEN" ;;
  pod)
    export VOXLOCAL_LLM_URL VOXLOCAL_LLM_TOKEN ;;
esac

# 6. dsh web on the scribe profile, in a fresh Harness home (no sessions from earlier demos).
#    dsh writes UI settings back into the profile layer (clicking « Continue » on its preview
#    notice rewrites cordis.patch.yml), so boot a copy of the tracked profile, not a symlink:
#    the repository stays untouched. node_modules is shared (same pinned install).
export DSH_HOME="$RUN/dsh-home" DSH_AGENTS_HOME="$RUN/dsh-home/agents"
mkdir -p "$DSH_HOME/profiles/scribe"
cp "$PROFILE_DIR/package.json" "$PROFILE_DIR/cordis.patch.yml" "$DSH_HOME/profiles/scribe/"
ln -s "$PROFILE_DIR/node_modules" "$DSH_HOME/profiles/scribe/node_modules"
"$PROFILE_DIR/node_modules/.bin/dsh" --profile scribe --no-open --port "$WEB_PORT" >"$RUN/logs/dsh-web.log" 2>&1 &
PIDS+=($!)
WEB_URL=""
for _ in $(seq 1 120); do
  WEB_URL="$(sed -n 's/.*dsh web: \(http[^ ]*\).*/\1/p' "$RUN/logs/dsh-web.log" | head -1)"
  [ -n "$WEB_URL" ] && break; sleep 0.5
done
[ -n "$WEB_URL" ] || { echo "dsh web n'a pas démarré (voir $RUN/logs/dsh-web.log)" >&2; exit 1; }

cat <<EOF

Démo prête (fournisseur : $PROVIDER).
  Chat du médecin (dsh web)   $WEB_URL
  API dictées (mock)          http://127.0.0.1:$AGENT_PORT
  Pont portail (mock)         $PORTAIL_BRIDGE_URL
  Modèle                      $VOXLOCAL_LLM_URL
  Dictée livrée               $DICTATION_ID (patient $PATIENT, rencontre $ENCOUNTER)
  Message à coller            $RUN/message.txt
  Audit                       $RUN/audit/approvals.jsonl, $RUN/audit/portal-writes.jsonl
Pod (cible réelle, Qwen3.8-27B) : VOXLOCAL_LLM_URL=https://<pod>:8443/llm/v1 VOXLOCAL_LLM_TOKEN=… $0 --provider pod
EOF

if [ "$DRIVE" = 1 ]; then
  mkdir -p "$SHOTS"
  # The web token stays out of argv: drive-ui reads it from DSH_WEB_TOKEN and appends ?token= itself.
  DSH_WEB_TOKEN="$(printf '%s' "$WEB_URL" | sed -n 's/.*[?&]token=\([^&#]*\).*/\1/p')" \
    node "$DEMO_DIR/drive-ui.mjs" --url "${WEB_URL%%\?*}" --message "$RUN/message.txt" --out "$SHOTS" \
    --browser "$HEADLESS_SHELL" --profile-dir "$RUN/chrome" | tee "$RUN/logs/drive.log"
  echo "Écritures au portail (mock) :"
  python3 -c 'import json,sys; [print("  ", r["event"], r["result"], r["draft_id"], r.get("backup_id") or "") for r in map(json.loads, open(sys.argv[1]))]' \
    "$RUN/audit/portal-writes.jsonl" 2>/dev/null || echo "  (aucune)"
  exit 0
fi

command -v pbcopy >/dev/null && pbcopy <"$RUN/message.txt" && echo "(message copié dans le presse-papier)"
echo "Ctrl-C pour tout arrêter."
wait
