# llama.cpp MTP inference server for NVIDIA DGX Spark (GB10 Grace Blackwell)
# Exposes ports on host network; access via the host's Tailscale IP.
#
# Build:
#   docker build -t spark-llm-stack .
#   docker build --build-arg BUILD_JOBS=20 -t spark-llm-stack .
#
# PERFORMANCE WARNING — LLAMA_REF default:
#   The default LLAMA_REF=master ships mainline llama.cpp, which currently
#   underperforms on GB10 (~23 vs ~28 t/s on Qwen3.6-27B). The systemd
#   *.service files use a pre-merge MTP branch. For full perf:
#     docker build --build-arg LLAMA_REF=<mtp-commit-or-branch> -t spark-llm-stack .
#   Pin to a SHA — branch HEADs drift and break reproducibility.

ARG CUDA_VERSION=13.2.0
ARG UBUNTU_VERSION=24.04

# ── builder ────────────────────────────────────────────────────────────────────
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

ARG BUILD_JOBS=16
ARG LLAMA_REPO=https://github.com/ggml-org/llama.cpp
ARG LLAMA_REF=master

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    build-essential \
    ninja-build \
    libcurl4-openssl-dev \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# CUDA driver compat shim — stock nvidia/cuda images omit /usr/local/cuda-13/compat
# from LD_LIBRARY_PATH, which holds libcuda.so.1. Without this, the build can
# fail to link or runtime hits "CUDA driver not found" even with --gpus=all.
# See: https://forums.developer.nvidia.com/t/building-llama-cpp-container-images-for-spark-gb10/353664
ENV LD_LIBRARY_PATH=/usr/local/cuda-13/compat:${LD_LIBRARY_PATH}

WORKDIR /build
RUN git clone --depth 1 --branch ${LLAMA_REF} ${LLAMA_REPO} llama.cpp 2>/dev/null \
 || git clone --depth 1 ${LLAMA_REPO} llama.cpp && \
    cd llama.cpp && \
    git fetch --depth 1 origin ${LLAMA_REF} && \
    git checkout FETCH_HEAD 2>/dev/null || true

WORKDIR /build/llama.cpp
RUN cmake -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_NATIVE=ON \
      -DGGML_CUDA=ON \
      -DGGML_CURL=ON \
      -DCMAKE_CUDA_ARCHITECTURES="121a-real" \
      -DGGML_CUDA_FA=ON \
      -DGGML_CUDA_FA_ALL_QUANTS=ON \
      -DGGML_CUDA_FORCE_MMQ=ON \
      -DGGML_CPU_KLEIDIAI=ON && \
    cmake --build build --config Release -j${BUILD_JOBS} \
      --target llama-server llama-bench

# ── runtime ────────────────────────────────────────────────────────────────────
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    libcurl4 \
    ca-certificates \
    python3 \
    python3-requests \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/llama.cpp/build/bin/llama-server  /usr/local/bin/llama-server
COPY --from=builder /build/llama.cpp/build/bin/llama-bench   /usr/local/bin/llama-bench

# flux-gen is bundled so you can: docker exec <ctr> flux-gen "prompt"
# It's an HTTP client; set FLUX_HOST=http://<addr>:8160 to target a remote server.
COPY flux-gen /usr/local/bin/flux-gen
RUN chmod +x /usr/local/bin/flux-gen

# CUDA driver compat shim — see builder stage for rationale.
ENV LD_LIBRARY_PATH=/usr/local/cuda-13/compat:${LD_LIBRARY_PATH}

# GB10 performance tuning (from qwen27-mtp.service and qwen35-mtp.service)
ENV CUDA_SCALE_LAUNCH_QUEUES=4x
ENV GGML_CUDA_GRAPH_OPT=1
ENV GGML_CUDA_FORCE_CUBLAS_COMPUTE_16F=1

# Model weights are bind-mounted from the host at runtime — never baked in.
# First-time download: pass -hf <repo>:<file> instead of -m.
VOLUME ["/models"]

# All model slot ports (see README model roster table)
EXPOSE 8152 8154 8155 8156 8157 8160

ENTRYPOINT ["/usr/local/bin/llama-server"]

# Default: Qwen3.6-27B coder slot.
# --host 0.0.0.0 (not 127.0.0.1) so Tailscale traffic on tailscale0 reaches it.
# Override CMD to switch slots; see run.sh for per-slot examples.
CMD [ \
  "-m", "/models/Qwen3.6-27B-MTP-UD-Q4_K_XL.gguf", \
  "--alias", "qwen3.6-27b-coder", \
  "--host", "0.0.0.0", \
  "--port", "8152", \
  "-ngl", "999", \
  "-fa", "on", \
  "-c", "131072", \
  "--cache-type-k", "q8_0", \
  "--cache-type-v", "q8_0", \
  "--kv-unified", \
  "--cache-ram", "49152", \
  "--cache-idle-slots", \
  "--ctx-checkpoints", "128", \
  "--cache-reuse", "1024", \
  "-b", "32768", \
  "-ub", "8192", \
  "--parallel", "1", \
  "--threads", "8", \
  "--threads-batch", "16", \
  "--threads-http", "4", \
  "--prio", "3", \
  "--poll", "100", \
  "--spec-type", "draft-mtp", \
  "--spec-draft-n-max", "5", \
  "--spec-draft-n-min", "1", \
  "--spec-draft-p-min", "0.75", \
  "--reasoning", "off", \
  "--jinja", \
  "--temp", "0.6", \
  "--top-k", "20", \
  "--top-p", "0.95", \
  "--min-p", "0.0", \
  "--presence-penalty", "0.0", \
  "--keep", "-1", \
  "--metrics", \
  "--slots" \
]
