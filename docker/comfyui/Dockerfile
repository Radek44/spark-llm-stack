# ComfyUI for NVIDIA DGX Spark (GB10 Grace Blackwell, aarch64, SM 12.1).
# Listens on :8188; bind to 0.0.0.0 so Tailscale traffic on the host's
# tailscale0 interface reaches the server.
#
# Build (from repo root):
#   docker build -f docker/comfyui/Dockerfile -t spark-llm-comfyui .
#   docker build -f docker/comfyui/Dockerfile --build-arg COMFYUI_REF=<sha> \
#     -t spark-llm-comfyui .
#
# Blackwell aarch64 notes (consensus across DGX Spark community work):
# - TORCH_CUDA_ARCH_LIST=12.1a targets sm_121a SASS specifically.
# - SageAttention is the only working fast-attention kernel on GB10
#   (FlashAttention 2/3 has no sm_121 aarch64 wheels). Pinned to v2.2.0
#   because v3 has confirmed mosaic artifacts on GB10 (thu-ml/SageAttention#321).
# - torch.compile emits broken SASS for sm_121a → TORCH_COMPILE_DISABLE=1.
# - PYTORCH_NO_CUDA_MEMORY_CACHING=1 lets Grace's UMA fabric reclaim freed
#   pages cleanly — without it, PyTorch's caching allocator hoards pages.
# - comfy-aimdo installed for NVIDIA DynamicVRAM allocator (ComfyUI auto-
#   detects and enables async weight offload when importable).
# - --disable-pinned-memory mitigates the ComfyUI VAE Decode RAM spike
#   (Comfy-Org/ComfyUI#11106); --reserve-vram 8.0 is community-validated
#   headroom for heavy FLUX/LTX workflows (Triplany/comfyui-dgx-spark).
# See docs/architecture/DECISIONS.md for the rationale on each choice.

ARG CUDA_VERSION=13.2.0
ARG UBUNTU_VERSION=24.04

# ── builder ────────────────────────────────────────────────────────────────────
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

ARG COMFYUI_REPO=https://github.com/comfyanonymous/ComfyUI
ARG COMFYUI_REF=master
ARG SAGE_REPO=https://github.com/thu-ml/SageAttention
# v2.2.0 — v3 has reported mosaic artifacts on GB10 (thu-ml/SageAttention#321).
ARG SAGE_REF=v2.2.0
ARG TORCH_VERSION=2.9.1
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu130

ENV DEBIAN_FRONTEND=noninteractive \
    VENV=/opt/venv \
    PATH=/opt/venv/bin:/usr/local/cuda/bin:$PATH \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    TORCH_CUDA_ARCH_LIST=12.1a \
    TORCH_COMPILE_DISABLE=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    git \
    ninja-build \
    build-essential \
    cmake \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ENV LD_LIBRARY_PATH=/usr/local/cuda-13/compat:${LD_LIBRARY_PATH}

RUN python3.12 -m venv ${VENV} && \
    pip install --upgrade pip setuptools wheel

# PyTorch first so SageAttention links against the same ABI.
RUN pip install --index-url ${TORCH_INDEX} \
      torch==${TORCH_VERSION} torchvision torchaudio

# ComfyUI itself — hard-fail on bad ref (same pattern as the llama Dockerfile).
WORKDIR /build
RUN git clone --depth 1 --branch ${COMFYUI_REF} ${COMFYUI_REPO} ComfyUI
WORKDIR /build/ComfyUI
RUN pip install -r requirements.txt

# NVIDIA-backed DynamicVRAM allocator (aarch64 wheels on PyPI since 0.3.0).
# ComfyUI auto-detects it; enables async weight offload + prevents memory
# creep across workflow switches on unified memory.
RUN pip install 'comfy-aimdo>=0.3.0'

# Patch comfy/model_management.py for DGX Spark unified memory.
#
# Problem: cudaMemGetInfo() under-reports free memory on GB10 when another
# CUDA process (e.g. llama-server) is resident — it may show ~6 GB free when
# 40+ GB are actually available, causing ComfyUI to partially offload the text
# encoder and slow inference ~2×.
#
# Fix: replace the CUDA call with psutil.virtual_memory().available, which
# reads /proc/meminfo and returns the true host available RAM. On GB10 this is
# the ground truth because system RAM = GPU memory (unified pool).
RUN python3 -c "
import pathlib, sys
f = pathlib.Path('comfy/model_management.py')
if not f.exists():
    print('WARNING: comfy/model_management.py not found — skipping patch', file=sys.stderr)
    sys.exit(0)
old = 'mem_free_cuda, _ = torch.cuda.mem_get_info(dev)'
new = 'import psutil as _psutil; mem_free_cuda = _psutil.virtual_memory().available'
txt = f.read_text()
if old not in txt:
    print('WARNING: patch target not found (already patched or upstream changed)', file=sys.stderr)
    sys.exit(0)
f.write_text(txt.replace(old, new, 1))
print('model_management.py patched: cudaMemGetInfo -> psutil.virtual_memory().available')
"

# SageAttention with sm_121a SASS. FlashAttention 2/3 has no working
# aarch64 wheel for SM 12.1; SageAttention v3 is the consensus alternative.
WORKDIR /build
RUN git clone --depth 1 --branch ${SAGE_REF} ${SAGE_REPO} SageAttention
WORKDIR /build/SageAttention
RUN NVCC_APPEND_FLAGS="-gencode=arch=compute_121a,code=sm_121a" \
    pip install .

# ── runtime ────────────────────────────────────────────────────────────────────
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    VENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TORCH_COMPILE_DISABLE=1 \
    CUDA_MANAGED_FORCE_DEVICE_ALLOC=1 \
    PYTORCH_ALLOC_CONF=expandable_segments:True \
    PYTORCH_NO_CUDA_MEMORY_CACHING=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.12 \
    git \
    curl \
    tini \
    libgomp1 \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ENV LD_LIBRARY_PATH=/usr/local/cuda-13/compat:${LD_LIBRARY_PATH}

# Application
COPY --from=builder /opt/venv      /opt/venv
COPY --from=builder /build/ComfyUI /opt/ComfyUI

# Default custom_nodes live OUTSIDE the bind-mount target so they don't
# get shadowed when the user mounts ~/comfyui/custom_nodes over
# /opt/ComfyUI/custom_nodes. entrypoint.sh seeds them on first run.
RUN git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager \
      /opt/comfy-defaults/custom_nodes/ComfyUI-Manager

COPY docker/comfyui/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /opt/ComfyUI

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8188/system_stats || exit 1

EXPOSE 8188

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD [ \
  "--listen", "0.0.0.0", \
  "--port", "8188", \
  "--disable-pinned-memory", \
  "--reserve-vram", "8.0" \
]
