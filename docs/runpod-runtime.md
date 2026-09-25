# RunPod runtime runbook

This runbook prepares the existing Pod bootstrap without provisioning a Pod or
spending GPU credits. It is intentionally provider neutral: the image owner
chooses and benchmarks the voice model, the optional small cleanup model, and
the later Qwen-like LLM. No endpoint URL, token, region, retention or ZDR/DPA
claim is encoded in this repository.

## What is delivered

Copy `cloud/runpod/start-all.sh` into `/workspace/voxlocal/` and run it from
the Pod. It supervises three operator-supplied commands:

* `VOXLOCAL_VOICE_CMD` (required, typically Whisper `large-v3`)
* `VOXLOCAL_CLEAN_CMD` (optional, a separate small text correction service)
* `VOXLOCAL_LLM_CMD` (optional, enabled only after a separate benchmark)

Each command must bind to `127.0.0.1` and serve an OpenAI-compatible
`/v1/models` route. Only the reviewed Pod HTTPS edge should be exposed. The
script reads `/workspace/voxlocal/api-token` inside the Pod, requires no
group/world permissions, and never prints its contents. `cloud/runpod/
runtime.env.example` is a placeholder configuration; replace angle-bracket
values only in a Pod-local file.

From a second Pod shell, readiness can be checked with synthetic metadata only:

```bash
python cloud/runpod/check-services.py \
  --service voice http://127.0.0.1:8001 \
  --service clean http://127.0.0.1:8002
```

The checker sends a bearer token read from a service-specific environment/file
(`VOXLOCAL_VOICE_API_TOKEN` or `VOXLOCAL_VOICE_TOKEN_FILE`, and the equivalent
`CLEAN`/`LLM` names) when configured, then falls back to the shared Pod-local
token. It prints only `ready` or a generic failure and rejects plain HTTP to
non-loopback hosts. The checker does not send audio or text and is not a
model-quality test.

## Synthetic capability benchmark

Before choosing models or exposing a Pod port, run the provider-neutral
benchmark against synthetic-only service URLs. It makes no RunPod API or
control-plane call and cannot start a Pod or spend GPU credits. Configure one
or more capability URLs with environment variables:

```bash
export VOXLOCAL_VOICE_URL=https://voice.example.invalid
export VOXLOCAL_CLEAN_URL=https://clean.example.invalid
export VOXLOCAL_LLM_URL=https://llm.example.invalid
export VOXLOCAL_TOKEN_FILE=/workspace/voxlocal/api-token
python cloud/runpod/benchmark.py --timeout 5 > benchmark.json
```

`--voice-url`, `--clean-url`, `--llm-url`, or repeated `--service NAME URL`
(where `NAME` is `voice`, `clean`, or `llm`) may be used instead. A
service-specific `VOXLOCAL_<CAPABILITY>_API_TOKEN` or
`VOXLOCAL_<CAPABILITY>_TOKEN_FILE` takes precedence over the shared token.
Tokens are accepted only through environment variables or private files; they
are never command-line arguments or output. Token files must not be readable by
group or other users.

The voice check calls `/v1/models` and `/v1/audio/transcriptions`. Cleanup and
LLM checks call `/v1/models` and `/v1/chat/completions`. Every request carries
only a deterministic 250 ms silent PCM WAV or the fixed synthetic text fixture;
no input file, prompt, response body, audio, or token is printed. Response
reads are capped at 64 KiB and each request has a bounded timeout (at most 30
seconds). The benchmark rejects credentials, query strings, and fragments in
URLs, and permits plain HTTP only for loopback hosts; all remote endpoints
must use HTTPS.

Machine-readable results are emitted as one JSON document on stdout. The
concise pass/fail and per-operation latency summary goes to stderr, so the JSON
can be stored or piped without parsing human text. Exit status `0` means all
configured checks passed, `1` means a service check failed, and `2` means
configuration was rejected.

For a local smoke check without a model or network dependency, point all three
capabilities at a stdlib mock HTTP server that returns bounded JSON for GET
`/v1/models` and both POST routes. This proves request shape, auth handling,
latency/status reporting, URL policy, and response caps without sending any
real recording or clinical text.

## RunPod control-plane setup

The official Agent skills guide documents installation with
`npx skills add runpod/runpod-plugins-official`, the `runpodctl` installation,
and `RUNPOD_API_KEY` authentication. See the [RunPod Agent skills guide](https://docs.runpod.io/get-started/agent-skills).
The user-provided `https://docs.runpod.io/agent-setup.md` path was not
reachable during this audit; do not treat it as a source of deployment facts.
RunPod's [expose ports documentation](https://docs.runpod.io/pods/configuration/expose-ports)
must be checked against the selected Pod before opening any port.

Do not run control-plane commands from this repository until an administrator
has authenticated the approved RunPod account. A read-only endpoint/Pod list is
the first verification step. Starting a Pod, attaching a volume, downloading a
model, or exposing an endpoint is an operational change and remains outside
this local test.

## Acceptance checks before clinical data

Record the image digest, CUDA/driver versions, exact model revisions, VRAM,
latency, region, certificate chain, request/body logging settings, retention,
deletion behavior, and the approved DPA/ZDR position for each capability.
Exercise synthetic audio and text through voice, cleanup, and LLM separately;
then test timeout, network loss, service restart, malformed responses, and
saturation. Confirm that raw and corrected text remain separately reviewable.
The local server still requires its own TLS and pairing controls; the RunPod
token must never be copied to a workstation, harness, prompt, or Git file.
