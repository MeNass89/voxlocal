# syntax=docker/dockerfile:1
#
# VoxLocal RunPod image: whisper-server and llama-server (CUDA) behind a Caddy
# TLS 1.3 edge on :8443. Build from the repository root:
#
#   docker build --platform linux/amd64 -f cloud/runpod/Dockerfile -t <image> .
#
# WHISPER_CPP_COMMIT and LLAMA_CPP_COMMIT MUST equal the submodule gitlinks of
# mac/VoxLocal/Vendor/src/whisper.cpp (tag v1.9.3) and
# mac/VoxLocal/Vendor/src/llama.cpp, so the Mac and the GPU run the same
# inference code. tests/test_runpod_runtime.py enforces this.
#
# No secret is baked into any layer: the API token and the TLS key are created
# (or provisioned from a RunPod secret) by entrypoint.sh at first boot, on the
# persistent /workspace volume.

ARG CUDA_VERSION=12.4.1
ARG UBUNTU_VERSION=22.04

FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS build

ARG WHISPER_CPP_REPO=https://github.com/ggml-org/whisper.cpp
ARG WHISPER_CPP_COMMIT=371b5a7561823ab2bb32142d2751e35e7534727b
ARG LLAMA_CPP_REPO=https://github.com/ggml-org/llama.cpp
ARG LLAMA_CPP_COMMIT=a298422da78eb75e440a7de0ca408af64d323d93
# 80 = A100, 86 = RTX 3090 / A6000 / A40, 89 = RTX 4090 / L4 / L40S, 90 = H100.
ARG CUDA_ARCHITECTURES="80;86;89;90"

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates cmake git \
 && rm -rf /var/lib/apt/lists/*

# A shallow clone only contains the branch tip, so `clone --depth 1 && checkout
# <sha>` breaks as soon as upstream moves. Fetch the exact commit instead and
# refuse to build anything else.
RUN set -eux; \
    fetch_commit() { \
      mkdir -p "$1"; \
      git -C "$1" init -q; \
      git -C "$1" remote add origin "$2"; \
      git -C "$1" fetch -q --depth 1 origin "$3"; \
      git -C "$1" checkout -q --detach FETCH_HEAD; \
      test "$(git -C "$1" rev-parse HEAD)" = "$3"; \
    }; \
    fetch_commit /src/whisper.cpp "${WHISPER_CPP_REPO}" "${WHISPER_CPP_COMMIT}"; \
    fetch_commit /src/llama.cpp "${LLAMA_CPP_REPO}" "${LLAMA_CPP_COMMIT}"

# GGML_NATIVE=OFF: the build host CPU is not the Pod CPU.
# --allow-shlib-undefined: libcuda.so.1 is provided by the host driver at run
# time; only the toolkit stub exists here (same flag as upstream .devops).
RUN cmake -S /src/whisper.cpp -B /build/whisper \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DGGML_NATIVE=OFF \
      -DGGML_CUDA=ON \
      -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
      -DWHISPER_BUILD_TESTS=OFF \
      -DWHISPER_BUILD_EXAMPLES=ON \
      -DWHISPER_BUILD_SERVER=ON \
      -DWHISPER_SDL2=OFF \
      -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined \
 && cmake --build /build/whisper --config Release --target whisper-server -j"$(nproc)"

# The embedded web UI is not served (the edge only routes the OpenAI API), so
# it is not built: no npm, no build-time download from Hugging Face.
RUN cmake -S /src/llama.cpp -B /build/llama \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF \
      -DGGML_NATIVE=OFF \
      -DGGML_CUDA=ON \
      -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
      -DLLAMA_BUILD_TESTS=OFF \
      -DLLAMA_BUILD_EXAMPLES=OFF \
      -DLLAMA_BUILD_SERVER=ON \
      -DLLAMA_BUILD_UI=OFF \
      -DLLAMA_USE_PREBUILT_UI=OFF \
      -DLLAMA_OPENSSL=OFF \
      -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined \
 && cmake --build /build/llama --config Release --target llama-server -j"$(nproc)"

RUN install -d /out \
 && install -m 0755 /build/whisper/bin/whisper-server /build/llama/bin/llama-server /out/


FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION}

ARG CADDY_VERSION=2.11.4

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# python3.11 runs the stdlib-only tools (benchmark, readiness check); procps
# provides the `ps` used by start-all.sh; libgomp1 is the OpenMP runtime of the
# ggml CPU backend. Caddy comes from its signed apt repository, version pinned.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg libgomp1 openssl procps python3.11 \
 && curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
 && curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
      -o /etc/apt/sources.list.d/caddy-stable.list \
 && chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends "caddy=${CADDY_VERSION}" \
 && apt-get purge -y --auto-remove gnupg \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /usr/bin/python3.11 /usr/local/bin/python3

COPY --from=build /out/whisper-server /out/llama-server /usr/local/bin/
COPY cloud/runpod/*.sh cloud/runpod/*.py /opt/voxlocal/

# RunPod mounts the persistent volume on /workspace, which hides anything the
# image places there. The scripts therefore ship in /opt/voxlocal and
# entrypoint.sh installs them into /workspace/voxlocal at every boot; /models
# points into the volume so models survive Pod restarts.
RUN chmod 0755 /opt/voxlocal/*.sh /opt/voxlocal/*.py \
 && mkdir -p /workspace \
 && ln -s /workspace/models /models

ENV VOXLOCAL_ROOT=/workspace/voxlocal \
    VOXLOCAL_IMAGE_DIR=/opt/voxlocal \
    VOXLOCAL_MODELS_DIR=/models

EXPOSE 8443/tcp
ENTRYPOINT ["/bin/bash", "/opt/voxlocal/entrypoint.sh"]
