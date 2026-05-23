# docker/

Docker path for spark-llm-stack. Same seven-slot model roster as the systemd
path, containerized. Three images: `spark-llm-stack` (llama slots),
`spark-llm-imagine` (FLUX via sd-server), `spark-llm-comfyui` (ComfyUI).

For the autoresearch launcher see [`autoresearch/README.md`](autoresearch/README.md).

---

## Before you begin (read — it prevents a brick)

- **Single-slot rule**: running more than one heavyweight slot exhausts the
  128 GB unified memory pool and triggers an OOM respawn brick loop. Always
  use `docker-llm-switch` or `./run.sh` — never raw `docker run`. See
  [gremlins/00_POSTMORTEM.md](../gremlins/00_POSTMORTEM.md).
- **Requirements**: NVIDIA driver 580+, CUDA 13.0+, NVIDIA Container Toolkit,
  Docker with `--gpus=all` working (`docker run --rm --gpus=all nvidia/cuda:13.2.0-base-ubuntu24.04 nvidia-smi`).
- **Disk**: ~20 GB for all three images + model weights (~80 GB full roster).

---

## Model downloads (one-time, before first run)

Models live on the host at `~/models/` and are bind-mounted into containers at `/models`.

### Download all llama models at once (~61 GB total)

```bash
mkdir -p ~/models

# NOTE: "MTP" appears in HuggingFace repo names but NOT in the filenames inside.
huggingface-cli download unsloth/Qwen3.6-27B-MTP-GGUF  Qwen3.6-27B-UD-Q4_K_XL.gguf      --local-dir ~/models --local-dir-use-symlinks False  # coder     ~17 GB
huggingface-cli download unsloth/Qwen3.6-35B-A3B-MTP-GGUF Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf --local-dir ~/models --local-dir-use-symlinks False  # architect ~22 GB
huggingface-cli download unsloth/gemma-4-31B-it-GGUF    gemma-4-31B-it-UD-Q4_K_XL.gguf   --local-dir ~/models --local-dir-use-symlinks False  # gemma     ~19 GB
huggingface-cli download unsloth/gemma-4-E4B-it-GGUF    gemma-4-E4B-it-UD-Q4_K_XL.gguf   --local-dir ~/models --local-dir-use-symlinks False  # vision    ~3 GB
```

Notes:
- `gptoss` uses `--gpt-oss-20b-default` — a built-in flag in the MTP llama.cpp
  binary; no GGUF download needed.
- `huggingface-cli` is the HuggingFace CLI. Install with: `pip install huggingface_hub[cli]`
- For FLUX/imagine model files (~17 GB) see the [FLUX section](#flux2-klein-model-files) below.

---

## Quickstart

Run from the **repo root**.

```bash
# 1. Build all three images (llama / imagine / comfyui).
#    Build context is the repo root so tools/flux-gen is reachable.
#    Override LLAMA_REF / COMFYUI_REF / SD_REF via --build-arg to pin a commit.
docker compose -f docker/docker-compose.yml build
# Build a single image:
# docker compose -f docker/docker-compose.yml build comfyui

# 2. Install docker-llm-switch on PATH (one-time).
#    ln -sf keeps it live — edits to the repo script take effect immediately.
ln -sf "$(pwd)/docker/docker-llm-switch" ~/.local/bin/docker-llm-switch
chmod +x "$(pwd)/docker/docker-llm-switch"

# 3. Start a slot (stops every other spark-llm-* container first).
./docker/run.sh                  # coder (Qwen3.6-27B, :8152)
./docker/run.sh architect        # architect (Qwen3.6-35B MoE, :8154)
./docker/run.sh gemma            # gemma 31B (:8156)
./docker/run.sh vision           # gemma vision 4B (:8155)
./docker/run.sh gptoss           # GPT-OSS-20B (:8157)
./docker/run.sh imagine          # FLUX.2-klein via sd-server (:8160)
./docker/run.sh comfyui          # ComfyUI (:8188)

# 4. Proof of life — /health returns {"status":"ok"} once the model is fully loaded.
curl -s http://127.0.0.1:8152/health          # coder
curl -s http://127.0.0.1:8188/system_stats    # comfyui
curl -s http://127.0.0.1:8160/health          # imagine
```

---

## Slot roster

| Slot | Model | Port | Image |
|---|---|---|---|
| `coder` | Qwen3.6-27B dense (MTP) | 8152 | `spark-llm-stack` |
| `architect` | Qwen3.6-35B-A3B MoE | 8154 | `spark-llm-stack` |
| `vision` | Gemma-4-E4B | 8155 | `spark-llm-stack` |
| `gemma` | Gemma-4-31B | 8156 | `spark-llm-stack` |
| `gptoss` | GPT-OSS-20B (built-in) | 8157 | `spark-llm-stack` |
| `imagine` | FLUX.2-klein-4B | 8160 | `spark-llm-imagine` |
| `comfyui` | ComfyUI | 8188 | `spark-llm-comfyui` |

---

## Managing state

```bash
docker-llm-switch status                    # what's running, ports, restart policy
docker-llm-switch off                       # stop everything

# Auto-start one slot when the Docker daemon starts
docker-llm-switch boot-default architect    # only one slot ever has a restart policy
docker-llm-switch boot-status              # show what starts at daemon boot
docker-llm-switch boot-safe               # clear all restart policies
```

---

## ComfyUI installation (Docker path)

Everything is already wired up. The image builds from `docker/comfyui/Dockerfile`.

**1. Build the image**

```bash
# From repo root
docker compose -f docker/docker-compose.yml build comfyui
```

This takes a while — it compiles SageAttention from source with `sm_121a` SASS.

**2. Put your models in `~/models/`**

ComfyUI expects the standard subdirectory layout inside its `models/` folder.
The container bind-mounts `~/models` → `/opt/ComfyUI/models`:

```
~/models/
  checkpoints/   ← diffusion models (.safetensors)
  vae/
  clip/
  loras/
  ...
```

**3. Start it**

```bash
docker-llm-switch comfyui
# or: ./docker/run.sh comfyui
```

First model load takes 60–90 s — the `wait_ready` loop polls `/system_stats`
and prints dots until ready. Access at `http://localhost:8188`.

**4. Custom nodes persist automatically**

The entrypoint seeds ComfyUI-Manager into `~/comfyui/custom_nodes/` on first
run (using `cp -n` so existing nodes are never clobbered). Three bind-mounts
survive image rebuilds:

```
~/comfyui/custom_nodes/  ↔  /opt/ComfyUI/custom_nodes
~/comfyui/output/        ↔  /opt/ComfyUI/output
~/comfyui/user/          ↔  /opt/ComfyUI/user
```

Install new nodes through the Manager web UI or by `git clone`-ing into
`~/comfyui/custom_nodes/` and restarting the container.

**GB10-specific notes**

- The `model_management.py` patch in the Dockerfile replaces `cudaMemGetInfo()`
  with `psutil.virtual_memory().available`. On GB10's unified memory, CUDA's
  query can report ~6 GB free when 40+ GB are actually available (it sees
  another process's reservation, not the physical pool). Without the patch,
  ComfyUI would partially offload models unnecessarily.
- SageAttention is pinned to v2.2.0 (not v3) — v3 produces mosaic artifacts
  on GB10 (thu-ml/SageAttention#321). FlashAttention 2/3 has no working
  aarch64 wheel for SM 12.1 at all.

**Env overrides**

`COMFY_DIR` defaults to `~/comfyui`, `MODELS_DIR` to `~/models`. Both can be
overridden if your layout differs.

---

## FLUX.2-klein model files

```bash
mkdir -p ~/models/flux2-klein

# Main model (~8 GB, Apache 2.0)
huggingface-cli download black-forest-labs/FLUX.2-klein-4B \
  flux-2-klein-4b.safetensors --local-dir ~/models/flux2-klein --local-dir-use-symlinks False

# VAE (~335 MB) — rename to ae.safetensors (path expected by docker-llm-switch)
huggingface-cli download Comfy-Org/flux2-dev \
  split_files/vae/flux2-vae.safetensors --local-dir ~/models/flux2-klein --local-dir-use-symlinks False && \
  mv ~/models/flux2-klein/split_files/vae/flux2-vae.safetensors ~/models/flux2-klein/ae.safetensors

# Text encoder shards (~8 GB total)
huggingface-cli download black-forest-labs/FLUX.2-klein-4B \
  text_encoder/ --local-dir ~/models/flux2-klein --local-dir-use-symlinks False

# Merge shards into single file (required once; run from ~/models/flux2-klein)
cd ~/models/flux2-klein && python3 -c "
from safetensors.torch import save_file, load_file
base = 'text_encoder'
s1 = load_file(f'{base}/model-00001-of-00002.safetensors')
s2 = load_file(f'{base}/model-00002-of-00002.safetensors')
save_file({**s1, **s2}, f'{base}/qwen_3_4b.safetensors')
print('Done')
"
```

---

## Smoke tests

See [`SMOKE-TESTS.md`](SMOKE-TESTS.md) for the manual checklist required before
changes under `docker/` are considered shippable (build, mutual exclusion,
Tailscale reachability, hardening parity, end-to-end FLUX gen, custom-node
persistence, daemon-restart survival).

---

## What came from where

`Dockerfile`, `run.sh`, and `docker-llm-switch` were built by synthesising
three sources:

**[eugr/spark-vllm-docker](https://github.com/eugr/spark-vllm-docker)** —
confirmed `nvidia/cuda:13.2.0-devel-ubuntu24.04` as the right base for GB10
aarch64; contributed the multi-stage build pattern and `BUILD_JOBS` parallelism
arg.

**This repo's `.service` files + gremlins/00_POSTMORTEM.md** — every llama.cpp flag, env
var, and memory limit was translated line-for-line from `ExecStart` blocks.
`--host 0.0.0.0` is the only deliberate delta (needed for Tailscale access).

**[AEON-7/comfyui-aeon-spark](https://github.com/AEON-7/comfyui-aeon-spark)**,
**[luix93/DGX-Spark-ComfyUI](https://github.com/luix93/DGX-Spark-ComfyUI)**,
**[mmartial/ComfyUI-Nvidia-Docker](https://github.com/mmartial/ComfyUI-Nvidia-Docker)**
— Blackwell-specific tuning for ComfyUI: `TORCH_CUDA_ARCH_LIST=12.1a`,
SageAttention `compute_121a` flags, `TORCH_COMPILE_DISABLE=1`, unified-memory
env vars, ComfyUI-Manager auto-bootstrap pattern. See the root README for full
provenance detail.
