# RunPod runtime bootstrap

`start-all.sh` is a deliberately small supervisor for the existing Pod
bootstrap (`bash /workspace/voxlocal/start-all.sh`). It does not call the
RunPod control plane and it does not select a GPU or a model. The image owner
provides `VOXLOCAL_VOICE_CMD` and, when approved, separate `VOXLOCAL_CLEAN_CMD`
and `VOXLOCAL_LLM_CMD` commands. Each command must bind to loopback and expose
an OpenAI-compatible `/v1/models` route. The Pod's reviewed HTTPS edge is the
only externally reachable interface.

The token is read from `/workspace/voxlocal/api-token` inside the Pod. The
bootstrap rejects group/world-readable token files, never puts the token in a
command line, and never prints it. Keep service logs under the private `logs`
directory and configure model servers not to log request bodies. `check-services.py`
performs a synthetic readiness check and redacts all response details.

Example (inside the Pod, after the image owner has installed the model
servers):

```bash
chmod 700 /workspace/voxlocal/start-all.sh
chmod 600 /workspace/voxlocal/api-token
export VOXLOCAL_VOICE_CMD='python -m voice_server --host 127.0.0.1 --port 8001 --model large-v3'
export VOXLOCAL_CLEAN_CMD='python -m clean_server --host 127.0.0.1 --port 8002 --model <approved-small-model>'
bash /workspace/voxlocal/start-all.sh
```

Then, from a second Pod shell, run `python cloud/runpod/check-services.py
--service voice http://127.0.0.1:8001 --service clean
http://127.0.0.1:8002`. Replace placeholders only after benchmarking and
registering the real model, VRAM, region, certificate, retention and DPA
controls. No RunPod endpoint or compliance claim is encoded here.
