# RunPod runtime runbook

This runbook covers the VoxLocal RunPod image and its supervisor. The
deployment guide for hospital IT and operators is
[`cloud-deployment.md`](cloud-deployment.md). No endpoint URL, token, region,
retention or ZDR/DPA claim is encoded in this repository, and no Pod has been
provisioned yet.

## What is delivered

`cloud/runpod/Dockerfile` builds `whisper-server` and `llama-server` with CUDA
at the same commits as the Mac submodules (whisper.cpp `v1.9.3`
= `371b5a7`, llama.cpp `a298422`; `tests/test_runpod_runtime.py` fails if they
drift), plus Caddy as the TLS edge. `cloud/runpod/entrypoint.sh` prepares the
token, the certificate, the models and the Caddyfile at boot, then execs
`start-all.sh`, which supervises four commands:

* `VOXLOCAL_VOICE_CMD` (required): `whisper-server` on `127.0.0.1:8001`
* `VOXLOCAL_CLEAN_CMD` (optional, not used by the image)
* `VOXLOCAL_LLM_CMD` (optional, `VOXLOCAL_LLM=off` disables it): `llama-server`
  on `127.0.0.1:8003`, `--api-key-file` on the same token
* `VOXLOCAL_EDGE_CMD` (optional): Caddy on `:8443`, TLS 1.3, Bearer token
  required, routes `/voice/*`, `/llm/*` and the unprefixed OpenAI routes. In
  the image it first runs `wait-ready.sh`, which polls the `/health` of
  `whisper-server` and `llama-server` for up to 60 s (`VOXLOCAL_READY_TIMEOUT`)
  so the first request does not meet a 502. With `VOXLOCAL_LLM=off`, `/llm/*`
  and `/v1/chat/completions` answer a JSON `404`

If any child exits, the supervisor stops the others and exits with status 2, so
the Pod stops rather than serving half a runtime. `VOXLOCAL_TLS_CERT` and
`VOXLOCAL_TLS_KEY` are validated (both or neither; key not group/world
accessible) and passed through to every child. The token file must not be
group/world readable and is never printed. `cloud/runpod/runtime.env.example`
remains a placeholder for images that bring their own servers.

`cloud/runpod/deploy.sh` performs the RunPod control-plane steps with
`runpodctl` (build and push, template, Pod, fingerprint check); see the
deployment guide.

From a Pod shell, readiness can be checked with synthetic metadata only:

```bash
python3 /workspace/voxlocal/check-services.py \
  --service voice http://127.0.0.1:8001 \
  --service llm http://127.0.0.1:8003
```

`whisper-server` has no `/v1/models` route, so this probe reports the voice
service as not ready on its loopback port; through the edge
(`https://127.0.0.1:8443/voice`) it succeeds, because Caddy answers that route.

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
python3 cloud/runpod/benchmark.py --iterations 5 --timeout 30 > benchmark.json
python3 cloud/runpod/bench-report.py benchmark.json
```

`--voice-url`, `--clean-url`, `--llm-url`, or repeated `--service NAME URL`
(where `NAME` is `voice`, `clean`, or `llm`) may be used instead. A
service-specific `VOXLOCAL_<CAPABILITY>_API_TOKEN` or
`VOXLOCAL_<CAPABILITY>_TOKEN_FILE` takes precedence over the shared token.
Tokens are accepted only through environment variables or private files; they
are never command-line arguments or output. Token files must not be readable by
group or other users.

`--iterations N` (1 to 100) repeats every operation; the JSON reports each
sample and, per operation, min/mean/p50/p95/max latency (nearest-rank over
successful samples) and, for chat, `tokens_per_second` =
`usage.completion_tokens` / request latency. `--ca-file` trusts a private or
self-signed edge certificate; `--note` stores a one-line operator note (hardware,
model files). The schema is documented in the `benchmark.py` docstring.

The voice check calls `/v1/models` once and `/v1/audio/transcriptions` with a
deterministic 250 ms silent WAV and a deterministic 10 s tone WAV. Cleanup and
LLM checks call `/v1/models` and `/v1/chat/completions` with a fixed synthetic
French clinical sentence. No input file, prompt, response text, audio, or token
is printed or stored; only status, latency and token counts. Response
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
