#!/bin/zsh
# Measures VoxLocal's local inference on this Mac with the runtimes the app ships:
#   - whisper-cli with the app's flags (-fa, -t <cores>, -bs 5), 3 runs;
#   - the "Medical" mode rewrite through a cold llama-cli (model loaded per
#     dictation, the pre-2.3 path), 3 runs;
#   - the same rewrite through one warm llama-server (model loaded once), 3 runs.
# Writes docs/superpowers/evidence/<date>-mac-bench.json with p50 seconds per stage.
#
# Usage: scripts/bench-mac-inference.sh <whisper-model.bin> <llm-model.gguf> [note]
# Env:   VOXLOCAL_RUNTIME_DIR (default mac/VoxLocal/Vendor/bin), BENCH_RUNS (default 3),
#        BENCH_OUTPUT (default docs/superpowers/evidence/<date>-mac-bench.json)
set -euo pipefail

ROOT=${0:A:h:h}
WHISPER_MODEL=${1:?Usage: $0 <whisper-model.bin> <llm-model.gguf> [note]}
LLM_MODEL=${2:?Usage: $0 <whisper-model.bin> <llm-model.gguf> [note]}
NOTE=${3:-}
RUNTIME_DIR=${VOXLOCAL_RUNTIME_DIR:-$ROOT/mac/VoxLocal/Vendor/bin}
RUNS=${BENCH_RUNS:-3}
DATE=$(date +%Y-%m-%d)
OUTPUT=${BENCH_OUTPUT:-$ROOT/docs/superpowers/evidence/$DATE-mac-bench.json}
WORK=$(mktemp -d /tmp/vox-bench.XXXXXX)
SERVER_PID=""
cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
    /bin/rm -rf -- "$WORK"
}
trap cleanup EXIT INT TERM

for runtime in whisper-cli llama-cli llama-server; do
    [[ -x "$RUNTIME_DIR/$runtime" ]] || { print -u2 "Runtime manquant : $RUNTIME_DIR/$runtime (lancer mac/VoxLocal/build-runtimes.sh)"; exit 3; }
done
[[ -f "$WHISPER_MODEL" ]] || { print -u2 "Modèle Whisper introuvable : $WHISPER_MODEL"; exit 2; }
[[ -f "$LLM_MODEL" ]] || { print -u2 "Modèle GGUF introuvable : $LLM_MODEL"; exit 2; }

zmodload zsh/datetime
# Wall clock in the shell itself: no helper process inside the measured interval.
now() { print -r -- "$EPOCHREALTIME"; }
elapsed() { printf '%.3f' $(( $2 - $1 )); }

# 1. Synthetic French clinical dictation (~20 s), 16 kHz mono s16le like the app records.
PHRASE="Douleur thoracique apparue ce matin, sans irradiation. Tension artérielle quatorze huit, fréquence cardiaque quatre-vingt-douze par minute. Pas de dyspnée, pas de fièvre. Électrocardiogramme sans sus-décalage. Antécédent d'hypertension traitée. On surveille la troponine à six heures et on réévalue la douleur en fin de matinée."
/usr/bin/say -v Thomas -o "$WORK/vox-bench.aiff" "$PHRASE"
/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/vox-bench.aiff" "$WORK/vox-bench.wav"
AUDIO_SECONDS=$(/usr/bin/afinfo "$WORK/vox-bench.wav" | /usr/bin/awk '/estimated duration/ {print $3}')

# 2. Whisper, with the flags WhisperEngine passes.
THREADS=$(/usr/sbin/sysctl -n hw.logicalcpu)
WHISPER_TIMES=()
for i in $(seq 1 "$RUNS"); do
    t0=$(now)
    "$RUNTIME_DIR/whisper-cli" -m "$WHISPER_MODEL" -f "$WORK/vox-bench.wav" -l fr -fa -t "$THREADS" -bs 5 \
        -oj -of "$WORK/whisper" -np >/dev/null 2>"$WORK/whisper.err"
    t1=$(now)
    WHISPER_TIMES+=("$(elapsed "$t0" "$t1")")
done
TRANSCRIPT=$(/usr/bin/python3 -c 'import json,sys; print(" ".join(s["text"].strip() for s in json.load(open(sys.argv[1]))["transcription"]).strip())' "$WORK/whisper.json")

# 3. The Medical mode prompt, exactly as DictationPipeline builds it.
SYSTEM="Tu es le moteur d’écriture privé et hors ligne d’une application de dictée. N’ajoute jamais de faits absents de la transcription. Suis exactement l’instruction du mode.

INSTRUCTION DU MODE :
Nettoie cette note clinique sans inventer aucun fait. Préserve exactement les termes médicaux, mesures, négations et incertitudes. Structure le texte en paragraphes lisibles et retourne uniquement la note corrigée."
print -rn -- "$SYSTEM" > "$WORK/system.txt"
print -rn -- "$TRANSCRIPT" > "$WORK/prompt.txt"
CONTEXT=4096

# 4. Cold path: one llama-cli process per dictation (the model loads every time).
CLI_TIMES=()
for i in $(seq 1 "$RUNS"); do
    t0=$(now)
    "$RUNTIME_DIR/llama-cli" -m "$LLM_MODEL" -sysf "$WORK/system.txt" -f "$WORK/prompt.txt" -c "$CONTEXT" -n 2048 \
        --temp 0 --single-turn --no-display-prompt --no-show-timings --log-disable </dev/null >"$WORK/cli.out" 2>"$WORK/cli.err"
    t1=$(now)
    CLI_TIMES+=("$(elapsed "$t0" "$t1")")
done

# 5. Warm path: one llama-server, started as LLMServerController does, then requests.
PORT=$(/usr/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
API_KEY=$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)
t0=$(now)
LLAMA_API_KEY="$API_KEY" "$RUNTIME_DIR/llama-server" --host 127.0.0.1 --port "$PORT" --model "$LLM_MODEL" \
    -ngl 99 -fa on -c "$CONTEXT" --no-webui --log-disable >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
for attempt in $(seq 1 240); do
    [[ "$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health")" == 200 ]] && break
    kill -0 "$SERVER_PID" 2>/dev/null || { print -u2 "llama-server s'est arrêté :"; tail -20 "$WORK/server.log" >&2; exit 4; }
    sleep 0.25
done
t1=$(now)
SERVER_START=$(elapsed "$t0" "$t1")
/usr/bin/python3 - "$WORK/system.txt" "$WORK/prompt.txt" > "$WORK/request.json" <<'PY'
import json, sys
print(json.dumps({"messages": [{"role": "system", "content": open(sys.argv[1]).read()},
                               {"role": "user", "content": open(sys.argv[2]).read()}],
                  "stream": False, "temperature": 0, "max_tokens": 2048}))
PY
SERVER_TIMES=()
for i in $(seq 1 "$RUNS"); do
    t0=$(now)
    /usr/bin/curl -sf "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $API_KEY" --data-binary @"$WORK/request.json" >"$WORK/server.out"
    t1=$(now)
    SERVER_TIMES+=("$(elapsed "$t0" "$t1")")
done
kill "$SERVER_PID" 2>/dev/null || true; SERVER_PID=""

# 6. Report. Values travel through the environment, never through shell interpolation.
/bin/mkdir -p "${OUTPUT:h}"
print -rn -- "$TRANSCRIPT" > "$WORK/transcript.txt"
BENCH_ROOT="$ROOT" BENCH_WORK="$WORK" BENCH_DATE="$DATE" BENCH_RUNTIME_DIR="$RUNTIME_DIR" \
BENCH_WHISPER_MODEL="$WHISPER_MODEL" BENCH_LLM_MODEL="$LLM_MODEL" BENCH_NOTE="$NOTE" \
BENCH_AUDIO_SECONDS="$AUDIO_SECONDS" BENCH_RUNS="$RUNS" BENCH_THREADS="$THREADS" BENCH_CONTEXT="$CONTEXT" \
BENCH_WHISPER_TIMES="${WHISPER_TIMES[*]}" BENCH_CLI_TIMES="${CLI_TIMES[*]}" BENCH_SERVER_TIMES="${SERVER_TIMES[*]}" \
BENCH_SERVER_START="$SERVER_START" \
/usr/bin/python3 - "$OUTPUT" <<'PY'
import hashlib, json, os, platform, statistics, subprocess, sys
e = os.environ
work = e["BENCH_WORK"]
def floats(key): return [float(x) for x in e[key].split()]
def read(name): return open(os.path.join(work, name), encoding="utf-8").read()
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 23), b""): h.update(chunk)
    return h.hexdigest()
def cli_answer(output, user):
    # Same extraction as LLMEngine.answer(fromCLIOutput:user:): drop the banner,
    # the echoed prompt and the trailing "Exiting...".
    exit = output.rfind("Exiting...")
    if exit >= 0: output = output[:exit]
    echo = output.rfind("> " + user.strip())
    if user.strip() and echo >= 0: output = output[echo + 2 + len(user.strip()):]
    return output.strip()
def sysctl(key): return subprocess.run(["/usr/sbin/sysctl", "-n", key], capture_output=True, text=True).stdout.strip()
whisper, cli, server = floats("BENCH_WHISPER_TIMES"), floats("BENCH_CLI_TIMES"), floats("BENCH_SERVER_TIMES")
audio = float(e["BENCH_AUDIO_SECONDS"])
p50 = statistics.median
threads, context = e["BENCH_THREADS"], e["BENCH_CONTEXT"]
report = {
    "date": e["BENCH_DATE"],
    "script": "scripts/bench-mac-inference.sh",
    "machine": {"chip": sysctl("machdep.cpu.brand_string"), "logical_cpus": int(sysctl("hw.logicalcpu")),
                "memory_gb": round(int(sysctl("hw.memsize")) / 2**30), "macos": platform.mac_ver()[0],
                "load_average_at_end": [round(x, 2) for x in os.getloadavg()]},
    "runtimes": {"dir": os.path.relpath(e["BENCH_RUNTIME_DIR"], e["BENCH_ROOT"]), "build": "Metal + GGML_NATIVE=ON, arm64"},
    "models": {"whisper": {"file": os.path.basename(e["BENCH_WHISPER_MODEL"]), "sha256": sha(e["BENCH_WHISPER_MODEL"])},
               "llm": {"file": os.path.basename(e["BENCH_LLM_MODEL"]), "sha256": sha(e["BENCH_LLM_MODEL"])}},
    "audio": {"seconds": round(audio, 2), "format": "WAV 16 kHz mono s16le", "voice": "say -v Thomas"},
    "runs_per_stage": int(e["BENCH_RUNS"]),
    "flags": {"whisper": f"-l fr -fa -t {threads} -bs 5 -oj -np",
              "llama_cli": f"-c {context} -n 2048 --temp 0 --single-turn --no-display-prompt --no-show-timings --log-disable",
              "llama_server": f"--host 127.0.0.1 -ngl 99 -fa on -c {context} --no-webui --log-disable"},
    "p50_seconds": {
        "whisper_transcription": round(p50(whisper), 3),
        "llm_medical_cold_llama_cli": round(p50(cli), 3),
        "llm_medical_warm_llama_server": round(p50(server), 3),
        "llama_server_startup_once": round(float(e["BENCH_SERVER_START"]), 3),
    },
    "runs_seconds": {"whisper_transcription": whisper, "llm_medical_cold_llama_cli": cli, "llm_medical_warm_llama_server": server},
    "warm_speedup_llm": round(p50(cli) / p50(server), 2) if p50(server) > 0 else None,
    "real_time_factor_whisper": round(p50(whisper) / audio, 3),
    "transcript": read("transcript.txt"),
    "outputs": {"llama_cli": cli_answer(read("cli.out"), read("transcript.txt")),
                "llama_server": json.loads(read("server.out"))["choices"][0]["message"]["content"].strip()},
    "note": e["BENCH_NOTE"],
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2); f.write("\n")
print(json.dumps(report["p50_seconds"], indent=2))
PY
print "Benchmark écrit : $OUTPUT"
