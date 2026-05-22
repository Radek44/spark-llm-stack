# DGX Spark LLM Stack — Research Notes

Research compiled 2026-05-22. Sources cited inline. Covers ComfyUI, FLUX/stable-diffusion.cpp,
and vLLM configuration for the NVIDIA DGX Spark GB10 (Grace Blackwell, aarch64, SM 12.1).

---

## 1. ComfyUI Configuration Review

### What we have

```
CMD: --listen 0.0.0.0 --port 8188 --disable-pinned-memory --reserve-vram 2.0
ENV: CUDA_MANAGED_FORCE_DEVICE_ALLOC=1
     PYTORCH_ALLOC_CONF=expandable_segments:True
     TORCH_COMPILE_DISABLE=1
     HF_HUB_ENABLE_HF_TRANSFER=1
SageAttention: built with NVCC_APPEND_FLAGS="-gencode=arch=compute_121a,code=sm_121a"
```

### Finding 1: `--reserve-vram 2.0` is likely too low — community uses 8.0

**Source:** [Triplany/comfyui-dgx-spark](https://github.com/Triplany/comfyui-dgx-spark) README (2026-04-30, tested on DGX Spark 128 GB, driver 580.95)

The most actively maintained GB10-specific ComfyUI optimization kit sets `--reserve-vram 8`:

> "Headroom for activations. Bumped above ComfyUI's auto-reserve to avoid late-iteration
> allocation failures on heavy workflows."

Our current value of `2.0` is the argument to the flag we got from the ComfyUI issue #11106
(VAE-Decode RAM spike). Triplany's kit runs Flux1, Flux2, Qwen 2512, Wan 2.2, and LTX 2.3
reliably with `--reserve-vram 8` on the same 128 GB pool.

**Recommendation**: Raise `--reserve-vram` from `2.0` to `8` in `docker/docker-llm-switch`
and `docker/comfyui/Dockerfile` CMD. Low risk — this is headroom for activations, not a
memory cap.

### Finding 2: SageAttention v3 has reported mosaic artifacts on DGX Spark — stay on v2.2

**Source:** [Triplany/comfyui-dgx-spark](https://github.com/Triplany/comfyui-dgx-spark),
referencing upstream [thu-ml/SageAttention#321](https://github.com/thu-ml/SageAttention/issues/321)

> "Don't use SageAttention 3. I haven't tried it. Upstream issue thu-ml/SageAttention#321
> reports mosaic visual artifacts on Spark, so I stayed on 2.2 to avoid the risk."

Our Dockerfile uses `SAGE_REF=main`. If the `main` branch of SageAttention has advanced past
2.2.x to 3.x, this is a latent bug. The SparkyUI project also pins to 2.2.0.

**Recommendation**: Change `ARG SAGE_REF=main` to `ARG SAGE_REF=v2.2.0` in
`docker/comfyui/Dockerfile`. This guards against upstream moving main to v3.

### Finding 3: `--use-sage-attention` CLI flag not needed by default

**Source:** [Triplany/comfyui-dgx-spark](https://github.com/Triplany/comfyui-dgx-spark)

> "A/B bench on Flux1-dev and Flux2 FULL bf16 showed per-step delta within 1–2% of
> pytorch attention (both directions, noise-level), with a ~3s cold init penalty.
> SageAttention's sm_121 native build still installs (via build/sage.sh), it's just
> not enabled by default."

Our setup installs SageAttention but does not pass `--use-sage-attention`. This matches
the community consensus: install the native kernels, let ComfyUI elect to use them per-model.

**Status: Our approach is correct.**

### Finding 4: `PYTORCH_NO_CUDA_MEMORY_CACHING=1` vs our `PYTORCH_ALLOC_CONF`

**Source:** [ecarmen16/SparkyUI](https://github.com/ecarmen16/SparkyUI/),
[Triplany/comfyui-dgx-spark](https://github.com/Triplany/comfyui-dgx-spark)

Both community projects set:
```
PYTORCH_NO_CUDA_MEMORY_CACHING=1
```

Rationale from SparkyUI:
> "Let the unified-memory fabric manage allocations rather than PyTorch's caching
> allocator hoarding pages the OS could hand out."

We set `PYTORCH_ALLOC_CONF=expandable_segments:True` instead. These serve different purposes:
- `PYTORCH_NO_CUDA_MEMORY_CACHING=1` tells PyTorch not to cache freed GPU memory at all
- `expandable_segments:True` tells PyTorch's allocator to use expandable segments

On unified memory, `PYTORCH_NO_CUDA_MEMORY_CACHING=1` is arguably more correct because the
"free" memory is still accessible to the OS/Grace CPU — PyTorch's caching allocator fights
the fabric.

**Recommendation**: Add `PYTORCH_NO_CUDA_MEMORY_CACHING=1` to the runtime ENV in
`docker/comfyui/Dockerfile`. Keep `expandable_segments:True` as well (they're compatible).

### Finding 5: Global precision flags broke LTX 2.3 — confirmed our approach is right

**Source:** [Triplany/comfyui-dgx-spark](https://github.com/Triplany/comfyui-dgx-spark)

> "Don't add to this launcher, even if some guide tells you to:
> --gpu-only, --disable-mmap, --fp16-unet/vae/text-enc (globally), --force-fp16"
>
> "Forcing --fp16-vae produced all-black LTX 2.3 video — no error, the gen looked
> like it succeeded. Removing the global force eliminated the failure."

We don't pass any global precision flags. **Status: Correct.**

SparkyUI conversely recommends `--force-fp16 --fp16-unet --fp16-vae --fp16-text-enc`.
These two projects disagree. Triplany's is more recent (2026-04-30), explicitly ran LTX 2.3,
and shows evidence. Avoid global precision flags unless targeting a single-model deployment.

### Finding 6: comfy-aimdo DynamicVRAM allocator — missing from our stack

**Source:** [Triplany/comfyui-dgx-spark](https://github.com/Triplany/comfyui-dgx-spark)

[comfy-aimdo](https://github.com/Comfy-Org/comfy-aimdo) is an NVIDIA-backed DynamicVRAM
memory allocator for ComfyUI. As of v0.3.0 (2026-04-29), it ships aarch64 wheels on PyPI —
no source build needed.

When installed and importable, ComfyUI logs:
```
aimdo: comfy-aimdo inited for GPU: NVIDIA GB10 (VRAM: 124546 MB)
DynamicVRAM support detected and enabled
```

This was described as significant for preventing memory creep across workflow switches.

**Recommendation**: Add `pip install comfy-aimdo>=0.3.0` to the ComfyUI Dockerfile's
requirements install step. It's a pip wheel; no source build needed for aarch64 now.

### Finding 7: ONNX Runtime sm_121 wheel missing — DWPose / controlnet preprocessors fall back to CPU

**Source:** [Triplany/comfyui-dgx-spark](https://github.com/Triplany/comfyui-dgx-spark),
referencing [Jay0515 HuggingFace wheel](https://huggingface.co/Jay0515/onnxruntime-gpu-aarch64-cuda13-sm121)

PyPI does not ship `onnxruntime-gpu` with sm_121 / aarch64 / cu13 support. Without the
correct wheel, any custom node using ONNX (DWPose, controlnet preprocessors) silently falls
back to CPU inference.

The only known working wheel: `Jay0515/onnxruntime-gpu-aarch64-cuda13-sm121` on HuggingFace.

**Note**: This only matters if you use controlnet/DWPose nodes. If the ComfyUI use case
is pure FLUX generation without controlnet, the default ONNX wheel is fine.

### Finding 8: GPU clock locking for stability — host-level, not in Docker

**Source:** [ecarmen16/SparkyUI](https://github.com/ecarmen16/SparkyUI/),
[NVIDIA forums "Unlocking the Power of the Spark In ComfyUI"](https://forums.developer.nvidia.com/t/unlocking-the-power-of-the-spark-in-comfyui-no-crashes/360336)

Hard crashes (full system reboot) during LTX Video generation were traced to **GPU power
spikes**, not memory. The fix was host-level GPU clock locking:

```bash
# Lock GPU clocks to maximum (3003 MHz) - prevents throttling and power spikes
sudo nvidia-smi -lgc 3003,3003

# Enable core clock boost (GPU core > memory clock for compute workloads)
sudo nvidia-smi boost-slider --vboost 1

# Enable persistence mode (reduces driver load latency)
sudo nvidia-smi -pm 1

# Verify
nvidia-smi --query-gpu=clocks.sm,clocks.max.sm,persistence_mode --format=csv
```

**Caveat**: These do NOT persist across reboots on GB10. Must be re-applied after each boot.
The NVIDIA forums thread notes this is firmware behavior, not a bug.

**Recommendation**: Add to `docker/SMOKE-TESTS.md` as a pre-run host setup step.
Consider adding to the main README "Before you begin" section.

### Finding 9: async weight offloading now on by default in ComfyUI

**Source:** [Triplany/comfyui-dgx-spark](https://github.com/Triplany/comfyui-dgx-spark)

ComfyUI PR #10953 (merged 2025-11-27) enabled async weight offloading by default on Nvidia.
No `--async-offload` flag needed — it's on automatically when comfy-aimdo is importable.

Also: the old psutil-based free-memory reporting patch (to fix underreporting on unified
memory) is now obsolete as of ComfyUI commit `9d8a8179` — the upstream PRs addressed it.

### Finding 10: LTX 2.3 audio NaN clamp still needed (upstream unfixed)

**Source:** [Triplany/comfyui-dgx-spark](https://github.com/Triplany/comfyui-dgx-spark),
[Lightricks/ComfyUI-LTXVideo#430](https://github.com/Lightricks/ComfyUI-LTXVideo/issues/430)

LTX 2.3's audio VAE sometimes outputs NaN/Inf values → AAC encoder rejects with error 22.
The community workaround is to clamp NaN/Inf to 0 before the encode. Upstream issue is
open without a fix as of 2026-04-30.

This only affects the ComfyUI-LTXVideo custom node, not FLUX generation.

---

## 2. stable-diffusion.cpp / FLUX Configuration Review

### What we have

```
CMD_imagine:
  --diffusion-model /models/flux2-klein/flux-2-klein-4b.safetensors
  --llm /models/flux2-klein/text_encoder/qwen_3_4b.safetensors
  --vae /models/flux2-klein/ae.safetensors
  --listen-ip 0.0.0.0 --listen-port 8160
  --diffusion-fa
  --type f16
  --threads 8
ENV: CUDA_SCALE_LAUNCH_QUEUES=4x
```

### Finding 1: Quantization options — `--type f16` is correct for safetensors, GGUF unlocks more

**Source:** [leejet/stable-diffusion.cpp quantization_and_gguf.md](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/quantization_and_gguf.md),
[leejet/stable-diffusion.cpp flux2.md](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/flux2.md)

The `--type` parameter applies **on-the-fly quantization** when loading safetensors. Options:
- `f16` — 16-bit float (what we use, correct for the safetensors model)
- `f32` — 32-bit float (larger, slower)
- `q8_0` — 8-bit integer (saves ~50% vs f16, slight quality loss)
- `q5_0` / `q5_1` — 5-bit (smaller, more quality loss)
- `q4_0` / `q4_1` — 4-bit (smallest, visible quality loss on FLUX)

**Alternative approach**: Download GGUF pre-quantized versions of FLUX.2-klein from
[leejet/FLUX.2-klein-4B-GGUF](https://huggingface.co/leejet/FLUX.2-klein-4B-GGUF). Then
`--type` controls the weight precision of the *loading*, not conversion. With Q8_0 GGUF,
you'd get ~6–7 GB vs ~9 GB for f16 safetensors, with modest quality tradeoff.

With 128 GB unified memory and MEMCAP set to 16g, size is not the constraint here.
**Keep `--type f16`.** Quality > compression at this memory budget.

### Finding 2: `--diffusion-fa` confirmed correct — saves memory AND speeds up on CUDA

**Source:** [leejet/stable-diffusion.cpp performance.md](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/performance.md)

> "For most backends, it slows things down, but for cuda it generally speeds it up too."
> "flux 768x768 ~600mb [saved]"

Our use of `--diffusion-fa` is correct and beneficial on CUDA (GB10).

**Status: Correct.**

### Finding 3: `--threads 8` may be conservative — GB10 has 20 ARM cores

**Source:** [shamily/vllm-gb10](https://github.com/shamily/vllm-gb10) README, 
[Arm Learning Path: Build llama.cpp on GB10](https://learn.arm.com/learning-paths/laptops-and-desktops/dgx_spark_llamacpp/2_gb10_llamacpp_gpu/)

The GB10 Grace CPU has 20 cores (10× Cortex-X925 + 10× Cortex-A725). The Arm Learning
Path builds use `make -j"$(nproc)"` (all 20). The SparkyUI sets `OMP_NUM_THREADS=20`
(later dropped as the OS handles it).

The `--threads` flag in stable-diffusion.cpp controls CPU-side computation (text encoder,
VAE decode on CPU). Since FLUX.2-klein is small enough to run fully on GPU, and we're
using `--diffusion-fa` (CUDA path), the CPU thread count primarily affects the Qwen text
encoder computation.

**Recommendation**: Test `--threads 16` or `--threads $(nproc)` and compare generation
latency. This is a low-risk change. Add to SMOKE-TESTS.md as a tuning note.

### Finding 4: `--offload-to-cpu` not used — may not be needed but worth knowing

**Source:** [leejet/stable-diffusion.cpp flux2.md](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/flux2.md),
[leejet/stable-diffusion.cpp performance.md](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/performance.md)

The upstream examples for FLUX.2-klein all include `--offload-to-cpu`:
```
sd-cli ... --offload-to-cpu --diffusion-fa
```

With 128 GB unified memory and a 16g container cap (MEMCAP[imagine]=16g), FLUX.2-klein-4B
at f16 fits comfortably. `--offload-to-cpu` is meant to save VRAM on discrete GPUs.
On unified memory it may be a no-op or even slightly slower (extra copies).

**Status: Omitting `--offload-to-cpu` is likely correct for GB10.**

### Finding 5: `cfg-scale` and `--steps` are not in our server CMD

**Source:** [leejet/stable-diffusion.cpp flux2.md](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/flux2.md)

FLUX.2-klein is a distilled (flow-matching) model. The upstream examples use:
- `--steps 4` (not the sd-server default of 20)
- `--cfg-scale 1.0` (flow-matching doesn't use CFG)

These are request-time parameters passed by the client (`flux-gen`), not server startup
flags. The sd-server CMD sets server behavior; per-generation parameters come in the request.

**Status: Correct architecture (request-time params belong to flux-gen, not sd-server CMD).**
However, `flux-gen` should be documented as using `--steps 4 --cfg-scale 1.0` for klein.

### Finding 6: `CUDA_SCALE_LAUNCH_QUEUES=4x` — no community reports found

**Source:** No specific DGX Spark community references found for this env var.

This variable appears in the sd-server Dockerfile's runtime ENV. It's not documented in
stable-diffusion.cpp. It may be a CUDA/NCCL internal knob. Without empirical evidence of
its effect on GB10, it's a low-risk "leave it in" situation — it doesn't appear in any
"don't use this" lists.

### Finding 7: TAESD fast decoder available — not currently used

**Source:** [leejet/stable-diffusion.cpp TAESD guide](https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/taesd.md)

stable-diffusion.cpp supports TAESD (Tiny AutoEncoder for Stable Diffusion) via `--tae`.
This provides faster latent decoding with small quality loss. Not typically useful when
generation speed is already limited by the diffusion steps.

**Status: Not needed for our use case.**

---

## 3. vLLM on DGX Spark — Future Reference

### Finding 1: Stock vLLM images don't work on GB10 — must use CUDA 13.x builds

**Source:** [Avarok blog: DGX Spark, Nemotron3, and NVFP4](https://blog.avarok.net/dgx-spark-nemotron3-and-nvfp4-getting-to-65-tps-8c5569025eb6) (Dec 2025),
[shamily/vllm-gb10](https://github.com/shamily/vllm-gb10)

> "The stock vLLM image is built for older CUDA architectures and doesn't support SM 12.1."

Working image options (as of 2026-05):

| Image | vLLM | CUDA | Notes |
|-------|------|------|-------|
| `vllm/vllm-openai:v0.18.0-cu130` | 0.18.0 | 13.0 | Current community default |
| `avarok/vllm-dgx-spark:v11` | custom | 13.0.2 | Best-tested, includes non-gated activation fix |
| `nvcr.io/nvidia/vllm:26.01-py3` | 0.13.0 | 13.1.1 | NVIDIA NGC official, older models |
| `scitrera/dgx-spark-vllm:0.14.1-t4` | 0.14.1 | 13.1.0 | **AVOID** — FlashInfer `non_blocking=None` bug |

### Finding 2: Critical env var — `VLLM_FLASHINFER_MOE_BACKEND=latency`

**Source:** [Avarok blog](https://blog.avarok.net/dgx-spark-nemotron3-and-nvfp4-getting-to-65-tps-8c5569025eb6)

> "Instead of `throughput` mode (which uses problematic CUTLASS grouped GEMM kernels),
> `latency` mode uses a different kernel path that's compatible with SM 12.1."

Without this, MoE models crash during CUDA graph capture with:
```
RuntimeError: Failed to initialize cutlass TMA WS grouped gemm
```

### Finding 3: GPU memory utilization — keep ≤ 0.80-0.85

**Source:** [shamily/vllm-gb10](https://github.com/shamily/vllm-gb10),
[jdaln/dgx-spark-inference-stack](https://github.com/jdaln/dgx-spark-inference-stack)

> "GB10 unified memory OOM affects the whole system, not just the container."
> Keep `--gpu-memory-utilization` at 0.75–0.80 for safety. 0.85 with headroom for CUDA
> graph capture (Avarok's confirmed working setting with CUDA graphs enabled).

If `num_gpu_blocks=0` appears: raise utilization slightly or reduce `--max-model-len`.

### Finding 4: Quantization recommendations for vLLM on GB10

**Source:** [shamily/vllm-gb10 benchmarks](https://github.com/shamily/vllm-gb10)

Dense FP16/BF16 models are **bandwidth-bottlenecked** on GB10 (LPDDR5X ≈ 273 GB/s vs
HBM3 3.3 TB/s). Measured results:

| Model | Quant | tok/s (single) |
|-------|-------|---------------|
| Qwen2.5-Coder-7B | BF16 | 13 |
| Qwen2.5-Coder-7B-AWQ | AWQ 4-bit | 46 |
| Qwen3-Coder-Next (80B MoE) | AWQ 4-bit | 33.7 |

**Key insight**: AWQ 4-bit is ~3.5× faster than BF16 for the same model because the memory
bandwidth is the bottleneck, and 4-bit halves the bytes transferred per weight.

NVFP4 (4-bit floating point via NVIDIA modelopt) with CUDA graphs: 65+ tok/s on Nemotron-3-Nano.

### Finding 5: Flash attention backend — use FLASH_ATTN, not FLASHINFER

**Source:** [shamily/vllm-gb10](https://github.com/shamily/vllm-gb10)

> "vLLM 0.18.0 auto-selects FLASH_ATTN on GB10 (FlashAttention 2). FLASHINFER is listed
> as an option but has a known bug in the community builds (`non_blocking=None` TypeError
> on warmup)."

vLLM auto-selects correctly; no need to override.

### Finding 6: `--ipc=host` required for shared memory

**Source:** [Avarok blog](https://blog.avarok.net/dgx-spark-nemotron3-and-nvfp4-getting-to-65-tps-8c5569025eb6)

vLLM requires `--ipc=host` (Docker flag) for proper shared memory access. Add to
`CMD_vllm` when/if we add a vLLM slot to `docker-llm-switch`.

### Finding 7: Community vLLM stacks worth studying

| Repo | Stars | Notes |
|------|-------|-------|
| [jdaln/dgx-spark-inference-stack](https://github.com/jdaln/dgx-spark-inference-stack) | 41 | Full production stack: waker service, API gateway, model catalog, smoke tests |
| [shamily/vllm-gb10](https://github.com/shamily/vllm-gb10) | 0 | Minimal, clean, benchmarked; good starting point |
| [avarok/vllm-dgx-spark](https://huggingface.co/Avarok/vllm-dgx-spark) | — | Best for MoE/NVFP4 models, includes the non-gated activation fix |
| [eugr/spark-vllm-docker](https://github.com/eugr/spark-vllm-docker) | — | Original community reference, TF5-track Gemma 4 support |

---

## 4. Summary of Recommended Changes

### Apply immediately (low risk, clear community consensus):

| Item | Change | File(s) |
|------|--------|---------|
| `--reserve-vram 2.0 → 8` | Community tested; avoids late-iteration allocation failures | `docker/docker-llm-switch` CMD_comfyui, `docker/comfyui/Dockerfile` CMD |
| Pin SageAttention to v2.2 | `SAGE_REF=main` may pull v3 which has mosaic artifact reports | `docker/comfyui/Dockerfile` ARG |
| Add `PYTORCH_NO_CUDA_MEMORY_CACHING=1` | Two community projects use this for unified memory | `docker/comfyui/Dockerfile` runtime ENV |
| Add GPU clock locking to pre-run docs | Host-level fix for power-spike hard crashes | `docker/SMOKE-TESTS.md`, README |

### Investigate / test before applying:

| Item | What to check |
|------|--------------|
| `--threads 8 → 16` or `$(nproc)` in sd-server | Time generation latency with higher thread count |
| comfy-aimdo v0.3.0 installation | `pip install comfy-aimdo` in Dockerfile — check if it auto-enables DynamicVRAM |
| SageAttention `12.1a` vs `12.1` arch target | SparkyUI uses `12.1`, we use `compute_121a,code=sm_121a`. Functionally same for SASS; verify no compile errors |

### Not recommended:

| Item | Why |
|------|-----|
| Global `--force-fp16 / --fp16-vae` etc. | Broke LTX 2.3 (all-black output, no error). ComfyUI auto-detects per model |
| `--gpu-only` | Fights unified memory fabric. Community consensus: avoid |
| `--disable-mmap` | Forces full read-and-copy at load; slower than page-map on unified memory |
| SageAttention v3 | Reported mosaic visual artifacts on Spark (issue #321, unfixed as of 2026-04) |
| NVFP4 for image diffusion | Only proven for LLMs; image diffusion models ship their own dtype |

---

## 5. Sources

| URL | Date accessed | What it contributed |
|-----|--------------|---------------------|
| https://github.com/Triplany/comfyui-dgx-spark | 2026-05-22 | Most detailed GB10 ComfyUI config; `--reserve-vram 8`, SageAttention 2.2 pin, aimdo, memory env vars, patch audit |
| https://github.com/ecarmen16/SparkyUI | 2026-05-22 | Docker-based ComfyUI setup; GPU clock locking procedure |
| https://forums.developer.nvidia.com/t/unlocking-the-power-of-the-spark-in-comfyui-no-crashes/360336 | 2026-05-22 | Hard crash diagnosis (power spike, not memory); GPU clock locking fix |
| https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/performance.md | 2026-05-22 | `--diffusion-fa` confirmed CUDA speedup; `--offload-to-cpu` notes |
| https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/quantization_and_gguf.md | 2026-05-22 | `--type` flag options; GGUF conversion |
| https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/flux2.md | 2026-05-22 | FLUX.2-klein usage examples; `--steps 4 --cfg-scale 1.0` |
| https://blog.avarok.net/dgx-spark-nemotron3-and-nvfp4-getting-to-65-tps-8c5569025eb6 | 2026-05-22 | vLLM on GB10; `VLLM_FLASHINFER_MOE_BACKEND=latency`; CUDA graph config |
| https://github.com/shamily/vllm-gb10 | 2026-05-22 | vLLM benchmarks on GB10; AWQ vs BF16 throughput comparison |
| https://github.com/jdaln/dgx-spark-inference-stack | 2026-05-22 | Production vLLM stack for DGX Spark; image catalog; waker service |
| https://learn.arm.com/learning-paths/laptops-and-desktops/dgx_spark_llamacpp/2_gb10_llamacpp_gpu/ | 2026-05-22 | Official ARM/NVIDIA llama.cpp build guide for GB10; thread counts |
| https://build.nvidia.com/spark/comfy-ui | 2026-05-22 | NVIDIA official ComfyUI playbook for DGX Spark |
| https://forums.developer.nvidia.com/t/whats-your-media-generation-stack/359964 | 2026-05-22 | Community media generation stack survey; ComfyUI as primary tool |
