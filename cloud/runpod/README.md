# RunPod runtime

One image, one command, one exposed port. Full guide (French):
[`docs/cloud-deployment.md`](../../docs/cloud-deployment.md). Operator runbook:
[`docs/runpod-runtime.md`](../../docs/runpod-runtime.md).

| File | Role |
| --- | --- |
| `Dockerfile` | CUDA 12.4.1 / Ubuntu 22.04 image: `whisper-server` and `llama-server` built at the submodule commits, Caddy edge, Python 3.11 tools |
| `entrypoint.sh` | image entrypoint: token, TLS certificate, model download (SHA-256 checked), Caddyfile, then `start-all.sh` |
| `start-all.sh` | provider-neutral supervisor for the voice, clean, LLM and edge commands |
| `deploy.sh` | `runpodctl` deployment: build and push, template, Pod, fingerprint check, host configuration |
| `benchmark.py` | synthetic benchmark (`--iterations`, p50/p95, tokens/s); JSON schema in its docstring |
| `bench-report.py` | renders the benchmark JSON as a Markdown table |
| `check-services.py` | readiness probe of `/v1/models` |
| `wait-ready.sh` | holds the edge until `whisper-server` and `llama-server` answer `/health` (60 s by default, `VOXLOCAL_READY_TIMEOUT`) |
| `runtime.env.example` | placeholder commands for an image that is not this one |

```bash
export RUNPOD_API_KEY=<key>
export VOXLOCAL_IMAGE=docker.io/<you>/voxlocal-runpod:<tag>
bash cloud/runpod/deploy.sh
```

Only Caddy listens outside loopback (`:8443`, TLS 1.3). Every request must carry
`Authorization: Bearer <token>`; anything else gets `401`. The token lives in
`/workspace/voxlocal/api-token` (mode `600`), generated at first boot or taken
from a RunPod secret; no script prints it, puts it on a command line, or writes
it into the Caddyfile. `whisper-server` and `llama-server` bind to
`127.0.0.1:8001` and `127.0.0.1:8003`; `llama-server` checks the token too.

`start-all.sh` still works on its own with operator-supplied commands
(`VOXLOCAL_VOICE_CMD`, optional `VOXLOCAL_CLEAN_CMD`, `VOXLOCAL_LLM_CMD`,
`VOXLOCAL_EDGE_CMD`). It rejects group/world-readable token files, and when
`VOXLOCAL_TLS_CERT`/`VOXLOCAL_TLS_KEY` are set it checks that both exist and
that the key is private before passing both paths to every child.

Local proof without a GPU: build the two servers from the submodules (Metal),
run `entrypoint.sh` with `VOXLOCAL_ROOT`, `VOXLOCAL_IMAGE_DIR`,
`VOXLOCAL_MODELS_DIR` and `VOXLOCAL_EDGE_PORT` pointing at a scratch directory,
then run `benchmark.py --iterations 3 --ca-file <scratch>/voxlocal/tls/cert.pem`
against `https://127.0.0.1:<port>/voice` and `/llm`. Result of 2026-09-25:
`docs/superpowers/evidence/2026-09-25-cloud-bench-local.json`.
