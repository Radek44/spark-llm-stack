# ComfyUI Memory Configuration for DGX Spark

Research date: 2026-05-22  
Sources: NVIDIA developer forums (luix93, unlocking-the-power, my-comfyui-setup), GitHub (AEON-7/comfyui-aeon-spark, ecarmen16/SparkyUI)

---

## TL;DR

**`--highvram` is a trap on DGX Spark.** It pins every model GPU-side permanently. On unified memory this is catastrophic: LTX Video (15 GB) + VAE (2.3 GB) + GFPGAN + RIFE + an LLM pushes past 80 GB and OOMs. The correct approach is to let ComfyUI's async weight offloader do its job — on unified memory the "offload" is essentially a pointer update, nearly free.

---

## Flags: What NOT to Use on DGX Spark

| Flag | Why harmful on unified memory |
|---|---|
| `--highvram` | Pins all models GPU-side permanently; no eviction. Fills pool. |
| `--gpu-only` | Same as highvram — forces everything resident |
| `--cache-none` | Defeats LRU eviction; forces cold loads every inference |
| `--disable-mmap` | Forces copies instead of pointer remaps; doubles memory usage on UMA |
| `--reserve-vram N` | Conflicts with Dynamic VRAM; causes OOM on systems where the dynamic system works |
| `--disable-async-offload` | Prevents the offloader from managing model placement; increases peak memory |

---

## Flags: Recommended Working Configuration

```bash
python main.py \
  --listen 0.0.0.0 \
  --bf16-unet \
  --bf16-vae \
  --bf16-text-enc \
  --use-sage-attention \
  --disable-dynamic-vram
```

**Why `--disable-dynamic-vram`?**  
Dynamic VRAM was designed for discrete GPU + system RAM systems. On unified memory it behaves unexpectedly: it may attempt to "evict to CPU" which on UMA is a no-op pointer change, but the bookkeeping overhead causes stuttering and incorrect memory pressure calculations. Community consensus (forum thread "ComfyUI setup optimized for DGX Spark") is to disable it and rely on async offload instead.

**Why BF16?**  
BF16 is native to Blackwell tensor cores. Using FP32 wastes 2× memory with no quality benefit. FP8 is available via `comfy_kitchen` (NVFP4 quantization plugin for Blackwell) for even larger savings.

**Why `--use-sage-attention`?**  
SageAttention 2 compiled from source against `sm_121` provides hardware attention acceleration on the GB10. Standard `torch.compile` and `torch.compile(max-autotune)` can fail or produce PTX-JIT paths on sm_121 with significant first-run latency.

---

## Critical Patches for Unified Memory

### Patch 1: `model_management.py` — fix `get_free_memory()`

**Problem:** `cudaMemGetInfo()` under-reports free memory on unified memory systems. When another CUDA process (e.g., llama-server) is resident, reported free memory can be ~6 GB when the host actually has 40+ GB available. ComfyUI then partially offloads the text encoder and sampling slows ~2×.

**Fix:** Replace the CUDA call with `psutil.virtual_memory().available`:

```python
# In comfy/model_management.py, find:
mem_free_cuda, _ = torch.cuda.mem_get_info(dev)

# Replace with:
import psutil as _psutil
mem_free_cuda = _psutil.virtual_memory().available
```

This is safe on GB10 because system RAM = GPU memory — the host available RAM is the ground truth.

### Patch 2: `tensor.to()` — prevent copy doubling

**Problem:** `tensor.to(device)` with default `copy=True` creates a temporary copy during transfer, doubling memory for the duration of the copy. On a system where 128 GB is already the ceiling this causes spurious OOM spikes.

**Fix:**
```python
# In comfy/utils.py, change tensor.to() calls to:
tensor.to(device, copy=False)
```

---

## CUDA Environment Variables

Add to container environment:

```bash
CUDA_MANAGED_FORCE_DEVICE_ALLOC=1   # UMA-aware allocation
PYTORCH_NO_CUDA_MEMORY_CACHING=1    # Don't speculatively reserve pool
OMP_NUM_THREADS=20                  # Cap to GB10's 20 ARM cores
```

**Do NOT set** `PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:N` — this allocator hint was designed for discrete GPU fragmentation and doesn't apply to UMA.

---

## Memory Footprints (observed benchmarks, DGX Spark)

| Workload | Memory Used | Notes |
|---|---|---|
| Flux2-dev full (bf16) | ~93.8 GB | Mistral-3-small at bf16 co-loaded |
| Flux2-dev fp8mixed | ~68 GB | — |
| Flux1-dev full + T5xxl fp16 | ~32.2 GB | — |
| LTX 2.3 22B fp8 (video) | ~44.7 GB | 1280×720, 5s |
| WAN 2.2 14B fp8 (video) | ~18 GB | 640×640, 5s |
| zimage t2i bf16 | ~43.5 GB | — |
| ComfyUI idle (no model) | ~1.3 GB | — |
| ComfyUI + llama-server (Qwen3-VL-8B Q6_K) + FastAPI | ~93 GB peak | 3 services, zero OOM |

---

## Coexistence with llama-server

ComfyUI and llama-server CAN coexist on a single DGX Spark if:
1. No `--highvram` / `--gpu-only` in ComfyUI
2. llama-server uses a ≤10 GB model (e.g., Qwen3-VL-8B Q6_K at ~9 GB)
3. Total peak stays under ~100–105 GB (leaving headroom for OS + CUDA context)

Reported stable configuration:
- ComfyUI with LTX Video (idle ~1.3 GB, peaks during generation) on `:8188`
- llama-server Qwen3-VL-8B Q6_K (~9 GB) on `:8080`
- Peak: ~93 GB / 119 GB usable — no OOM

This is relevant for the `comfyui` slot in the main `docker-llm-switch` stack (not autoresearch), but applies equally.

---

## SageAttention Build Note

SageAttention must be compiled **from source on the DGX Spark itself** against `sm_121`:
```bash
git clone https://github.com/thu-ml/SageAttention
cd SageAttention
python setup.py install
```
GitHub Actions cannot build for ARM64 + sm_121 (hosted runners are x86). Pre-built wheels for linux_aarch64+sm_121 do not exist.

---

## Sources
- https://forums.developer.nvidia.com/t/comfyui-setup-optimized-for-dgx-spark/364846
- https://forums.developer.nvidia.com/t/unlocking-the-power-of-the-spark-in-comfyui-no-crashes/360336
- https://forums.developer.nvidia.com/t/my-comfyui-setup-and-patches/368344
- https://github.com/AEON-7/comfyui-aeon-spark
- https://github.com/ecarmen16/SparkyUI
- https://github.com/Comfy-Org/ComfyUI/discussions/12699 (Dynamic VRAM)
- https://apatero.com/blog/vram-optimization-flags-comfyui-explained-guide-2025
