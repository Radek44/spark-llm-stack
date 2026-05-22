# stable-diffusion.cpp sd-server for NVIDIA DGX Spark (GB10 Grace Blackwell).
# Serves FLUX.2-klein-4B as an async HTTP job API on :8160.
#
# Build (from repo root):
#   docker build -f docker/sd-server/Dockerfile -t spark-llm-imagine .
#   docker build -f docker/sd-server/Dockerfile --build-arg SD_REF=<sha-or-tag> -t spark-llm-imagine .
#
# Note: CMAKE_CUDA_ARCHITECTURES=121 (not 121a-real). stable-diffusion.cpp
# is not GB10-SASS-optimised; generic Blackwell PTX is the intended path,
# per CLAUDE.md.

ARG CUDA_VERSION=13.2.0
ARG UBUNTU_VERSION=24.04

# ── builder ────────────────────────────────────────────────────────────────────
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

ARG BUILD_JOBS=16
ARG SD_REPO=https://github.com/leejet/stable-diffusion.cpp
ARG SD_REF=master

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    build-essential \
    ninja-build \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ENV LD_LIBRARY_PATH=/usr/local/cuda-13/compat:${LD_LIBRARY_PATH}

WORKDIR /build
# Hard-fail on bad SD_REF — silent fallback would mask perf regressions.
# `--branch` accepts both branches and tags.
RUN git clone --depth 1 --recursive --branch ${SD_REF} ${SD_REPO} stable-diffusion.cpp

WORKDIR /build/stable-diffusion.cpp
RUN cmake -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DSD_CUDA=ON \
      -DSD_BUILD_SERVER=ON \
      -DCMAKE_CUDA_ARCHITECTURES=121 && \
    cmake --build build --config Release -j${BUILD_JOBS} --target sd-server

# ── runtime ────────────────────────────────────────────────────────────────────
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/stable-diffusion.cpp/build/bin/sd-server /usr/local/bin/sd-server

ENV LD_LIBRARY_PATH=/usr/local/cuda-13/compat:${LD_LIBRARY_PATH}
ENV CUDA_SCALE_LAUNCH_QUEUES=4x

VOLUME ["/models"]
EXPOSE 8160

ENTRYPOINT ["/usr/local/bin/sd-server"]

# Default: FLUX.2-klein-4B served on :8160 with --listen-ip 0.0.0.0
# (instead of the 127.0.0.1 used in flux-klein.service — host network
# means we still need to bind to all interfaces so Tailscale traffic on
# tailscale0 reaches the server).
CMD [ \
  "--diffusion-model", "/models/flux2-klein/flux-2-klein-4b.safetensors", \
  "--llm", "/models/flux2-klein/text_encoder/qwen_3_4b.safetensors", \
  "--vae", "/models/flux2-klein/ae.safetensors", \
  "--listen-ip", "0.0.0.0", \
  "--listen-port", "8160", \
  "--diffusion-fa", \
  "--type", "f16", \
  "--threads", "8" \
]
