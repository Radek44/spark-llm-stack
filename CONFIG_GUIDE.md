# Configuration Guide: Spark LLM Stack on NVIDIA DGX Spark GB10

**Comprehensive configuration reference for llama.cpp, stable-diffusion.cpp, ComfyUI, vLLM, and Hermes on Grace Blackwell unified memory.**

Research compiled 2026-05-22. GB10 = 128GB LPDDR5X unified memory, SM 12.1a, 72 Grace ARM cores.

---

## 1. Quantization Decision Matrix

### When to use each quantization level:

| Quantization | Model Size Impact | Quality | Speed | Memory | Best For |
|---|---|---|---|---|---|
| **F32** | 1.0x | 100% (baseline) | 1.0x | ~2x F16 | Reference runs, quality comparison, single inference |
| **F16** | 0.5x | ~99% | ~1.2x (slower load) | 1.0x (baseline) | **Default for image/text, balanced approach** |
| **BF16** | 0.5x | ~99% | ~0.9x (faster compute) | 1.0x | Code gen, long sequences (compute > memory-bound) |
| **Q8** (8-bit) | 0.25x | ~98% | ~1.5x | 0.5x | Long-form generation, memory-constrained |
| **Q6_K (GGUF)** | ~0.375x | ~99% | ~1.3x | 0.375x | High-quality quantization, good speed tradeoff |
| **Q5_K (GGUF)** | ~0.3125x | ~97% | ~1.8x | 0.3125x | Balanced quality/compression |
| **Q4_K_M (GGUF)** | 0.25x | ~95% | ~2.2x | 0.25x | **Recommended for compute models (vLLM)** |
| **AWQ 4-bit** | 0.25x | ~96% | ~2.5x | 0.25x | **Best for throughput (3.5x speedup vs FP16 on GB10)** |
| **GPTQ 4-bit** | 0.25x | ~96% | ~2.3x | 0.25x | Latency-critical inference |
| **FP8 KV-Cache** | 0.2x (KV) | ~99% | ~2.0x (attention) | 0.2x (KV) | Long context windows, reduces KV bottleneck |

### GB10-Specific Note on Quantization:
GB10's LPDDR5X memory (273 GB/s) is **bandwidth-limited**, not compute-limited. AWQ 4-bit is **3.5× faster** than BF16 on the same model because fewer bytes transfer from memory. This favors quantization for LLM inference.

---

## 2. llama.cpp / llama-server Configuration Reference

### Essential Parameters

| Parameter | Our Default | Alternative | Impact | Notes |
|---|---|---|---|---|
| **Quantization** | Q5_K (GGUF) | Q4_K_M, Q6_K | Memory ↓ / Quality ↓ | Q4_K matches AWQ on code tasks; Q6_K for highest quality |
| **--threads** | 8 | 16-32 | Speed ↑ | Grace has 72 cores. Test 16-32 range |
| **--threads-batch** | (default) | = --threads | Parallel request handling | Batch inference tuning |
| **Flash Attention** | --fa on | --fa off | Speed ↑ 3-12% | Confirmed working on Blackwell |
| **--ctx-size** | Model default | 2048-4096 | Memory ↑ / Context ↑ | Adjust per-model; Grace unified memory allows large contexts |
| **--rope-freq-scale** | 1.0 | 0.5-2.0 | Context extrapolation | For models claiming 4K+ support on 2K training |
| **Batching** | Single | Batch N | Throughput ↑ | Use `--batch` or multi-slot with different models |

### KV Cache Optimization (TurboQuant)

```bash
# Extreme KV cache quantization (available via MTP branch)
llama-server ... \
  --cache-type-k turbo3 \
  --cache-type-v turbo3 \
  --spec-type mtp

# Compression: 4.57× → 5.12× with turbo3
# Trade: Slight numerical precision loss, significant memory savings
```

**Decision Tree:**
- Fitting model comfortably? → Skip KV cache quant
- Memory pressure on long contexts? → Try `turbo3`
- Ultra-long sequences (>16K)? → Use `turbo3` + `--rope-freq-scale 2.0`

---

## 3. stable-diffusion.cpp (FLUX) Configuration Reference

### Essential Parameters

| Parameter | Our Default | Alternative | Impact | Notes |
|---|---|---|---|---|
| **--type** | f16 | q8_0, q5_0, q4_0 | VRAM ↓ / Speed ↑ / Quality ↓ | f16 recommended for FLUX (safetensors); try q8_0 for 50% VRAM savings |
| **--diffusion-fa** | enabled | disabled | Speed ↑ 10-12% | CUDA-specific win; saves ~600 MB VRAM on FLUX |
| **--threads** | 8 | 16-32 | Qwen encoder speed ↑ | Text encoder is CPU-side; test higher thread count |
| **--offload-to-cpu** | disabled | enabled | VRAM ↓ / Speed ↓ | Not needed on unified memory; may slow things down |
| **--scheduler** | (default) | DDIM, Euler, LMS | Speed ↑ / Quality varies | Not currently configurable per-request in server CMD |
| **--guidance-scale** | (per-request) | 7.5, 15.0 | Generation style | Flow-matching: 1.0 recommended for FLUX |
| **--steps** | (per-request) | 4, 8, 16 | Latency ↔ Quality | FLUX.2-klein: 4 steps optimal |

### FLUX.2-klein Optimal Configuration

```bash
sd-server \
  --diffusion-model flux-2-klein-4b.safetensors \
  --llm qwen_3_4b.safetensors \
  --vae ae.safetensors \
  --listen-ip 0.0.0.0 --listen-port 8160 \
  --diffusion-fa \
  --type f16 \
  --threads 32  # Test; Grace has 72 cores, text encoder is CPU work
```

**Request-time parameters** (via API):
```json
{
  "prompt": "...",
  "steps": 4,
  "cfg_scale": 1.0,
  "guidance_scale": 1.0,
  "seed": 42,
  "scheduler": "euler"
}
```

---

## 4. ComfyUI Advanced Configuration Reference

### Memory Tuning Parameters

| Parameter | Our Default | Alternative | Impact | Notes |
|---|---|---|---|---|
| **--reserve-vram** | 2.0 GB | 4.0, 8.0 | Activation headroom ↑ | Triplany uses 8.0; avoids late-workflow OOM |
| **--memory-mode** | (auto) | lowvram, normalvram, highvram | Memory/Speed tradeoff | Let ComfyUI detect; test if needed |
| **--disable-pinned-memory** | enabled | disabled | Unified memory ↑ | Required for GB10; VAE decode spikes |
| **PYTORCH_ALLOC_CONF** | expandable_segments:True | (none) | Dynamic allocation ↓ | Keep enabled |
| **PYTORCH_NO_CUDA_MEMORY_CACHING** | (missing) | 1 | OS-level allocation | Add: avoids PyTorch caching hoarding on unified memory |
| **TORCH_COMPILE_DISABLE** | 1 | 0 | torch.compile broken on sm_121a | Keep disabled; torch.compile broken on Grace |
| **Dynamic VRAM** | (auto-detect) | --disable-dynamic-vram | Smart VRAM allocation | Leave auto; comfy-aimdo enables it automatically |

### Sampler and Model Parameters

| Parameter | Default | Tested Values | Effect |
|---|---|---|---|
| **Sampler Type** | Euler | DDIM, LMS, Heun | Quality/speed tradeoff |
| **Scheduler** | Karras | Exponential, Linear, Simple | CFG scaling curve |
| **Batch Size** | (model-dependent) | Follow 4n+1 | Memory efficiency: 1, 5, 9, 13, 17... |
| **Denoise Strength** | 1.0 | 0.7-0.95 | Inpainting control |
| **Guidance Scale** | 7.5 | 1.0-15.0 | Prompt adherence |

### Batch Size Optimization (Critical Formula)

ComfyUI and many diffusion models are optimized for batch sizes following the **4n+1 formula**:

| n | Batch Size | Notes |
|---|---|---|
| 0 | 1 | Single inference (default) |
| 1 | 5 | First optimized batch |
| 2 | 9 | |
| 3 | 13 | |
| 4 | 17 | |
| 5 | 21 | |

**GB10 recommendation:** For parallel workflows, use batch_size=5 or 9 for 2-3 parallel image workflows.

### SageAttention Configuration

```bash
# Current setup (correct)
ENV TORCH_CUDA_ARCH_LIST=12.1a
ENV NVCC_APPEND_FLAGS="-gencode=arch=compute_121a,code=sm_121a"
ARG SAGE_REF=v2.2.0  # Pin to v2.2.0, avoid main (might have v3)
```

**Status**: v2.2.0 confirmed working; v3 has reported mosaic artifacts on GB10.

---

## 5. vLLM Configuration for GB10

### Docker Image Selection

| Image | vLLM | CUDA | GPU Support | Status | Notes |
|---|---|---|---|---|---|
| `vllm/vllm-openai:v0.18.0-cu130` | 0.18.0 | 13.0 | FLASH_ATTN | ✅ Current default | Best community option |
| `avarok/vllm-dgx-spark:v11` | custom | 13.0.2 | Fixed | ✅ Best for MoE | Non-gated activation fix included |
| `nvcr.io/nvidia/vllm:26.01-py3` | 0.13.0 | 13.1.1 | Limited | ⚠️ Older | Official NGC; limited arch support |
| `scitrera/dgx-spark-vllm:0.14.1` | 0.14.1 | 13.1.0 | Broken | ❌ AVOID | FlashInfer `non_blocking=None` bug |

### Runtime Configuration

```bash
docker run --rm \
  --gpus=all \
  --ipc=host \
  -e VLLM_FLASHINFER_MOE_BACKEND=latency \
  -e TORCH_CUDA_ARCH_LIST=12.1a \
  -p 8000:8000 \
  vllm/vllm-openai:v0.18.0-cu130 \
  vllm serve model-name \
    --dtype float16 \
    --quantization awq \
    --max-model-len 4096 \
    --gpu-memory-utilization 0.80 \
    --tensor-parallel-size 1
```

### Quantization Recommendations for vLLM on GB10

| Model Class | Quantization | Throughput Gain | Recommended For |
|---|---|---|---|
| Dense FP16 (7B) | BF16 (baseline) | 1.0x | Baseline |
| Dense (7B) | AWQ 4-bit | **3.5x** | **Default choice** |
| Dense (7B) | GPTQ 4-bit | 3.2x | Latency optimization |
| Dense (7B) | FP8 | 2.0x | Long context (reduce KV) |
| MoE (80B) | AWQ 4-bit | 2.5-3.0x | Sparse models |
| MoE (80B) | NVFP4 | 4.5-5.0x | Extreme: CUDA graphs + NVFP4 |

### Memory Utilization Safe Ranges

```
Recommended: --gpu-memory-utilization 0.75-0.80
Testing range: 0.80-0.85 (may OOM under concurrent requests)
Danger zone: >0.85 (can crash entire system on GB10)
```

**Decision Tree:**
- Inference only → 0.80
- Mixed (batch + requests) → 0.75
- Very large model (70B+) → 0.70
- If `num_gpu_blocks=0` appears → Lower by 0.05

---

## 6. Hermes Configuration Reference

### Provider Configuration Pattern (CORRECT)

```yaml
# File: ~/.hermes/config.yaml
providers:
  - name: local_spark
    provider: custom  # Use "custom", NOT "vllm" alias!
    base_url: http://127.0.0.1:8000
    api_key: ""  # vLLM default (no auth)

models:
  - name: coder-7b
    provider: local_spark
    model_id: coder-7b
    temperature: 0.6
    top_k: 20
    top_p: 0.9
    context_window: 32000

  - name: flux-generate
    provider: custom
    base_url: http://127.0.0.1:8160  # sd-server on :8160
    temperature: 1.0
    guidance_scale: 7.5
```

### Parameter Passthrough Reference

| Model Type | Recommended Temperature | top_k | top_p | Notes |
|---|---|---|---|---|
| Code generation | 0.6-0.7 | 20-40 | 0.9-0.95 | Deterministic, coherent |
| Creative writing | 0.8-1.0 | 40-100 | 0.9-0.98 | Higher temperature for variety |
| Instruction following | 0.5-0.7 | 10-20 | 0.85-0.95 | Lower for consistency |
| Math/reasoning | 0.3-0.5 | 5-10 | 0.7-0.85 | Very conservative |
| Multi-turn chat | 0.7-0.9 | 20-50 | 0.9-0.95 | Balanced |

### Known Issues and Workarounds

| Issue | Symptom | Fix |
|---|---|---|
| **Non-loopback URL fallback** | Falls back to OpenRouter silently | Use `provider: custom` instead of alias |
| **vLLM connection fails** | Connection refused or timeout | Check `base_url` with curl first; ensure vLLM is running |
| **Parameter not applied** | Model uses default values | Ensure model is in `models:` section with params |
| **Auth error 401** | "AuthenticationError [HTTP 401]" | Using `vllm` alias with non-loopback URL → use `custom` |

---

## 7. GPU Hardware Optimization on GB10

### Pre-run Setup (Host-level, Required for Stability)

```bash
# Lock GPU clocks to prevent power throttling
sudo nvidia-smi -lgc 3003,3003

# Enable vboost (GPU core > memory clock for compute)
sudo nvidia-smi boost-slider --vboost 1

# Enable persistence mode (reduce driver load latency)
sudo nvidia-smi -pm 1

# Verify
nvidia-smi --query-gpu=clocks.sm,clocks.max.sm,persistence_mode --format=csv
# Expected: 3003, 3003, Enabled
```

**Important:** These settings do NOT persist across reboots on GB10. Must be re-applied after each boot or system restart.

### Monitoring Unified Memory Usage

```bash
# Monitor grace CPU memory and GPU memory simultaneously
watch -n 1 "echo '=== Grace CPU Memory ===' && free -h && echo '=== Blackwell GPU ===' && nvidia-smi --query-gpu=memory.used,memory.total --format=csv,nounits"
```

---

## 8. Decision Trees

### When to increase --reserve-vram in ComfyUI?

```
Does your workflow often hit OOM errors on the last iteration?
├─ YES → Increase from 2.0 to 4.0
│         Still OOM? → Increase to 8.0
├─ NO → Leave at 2.0 or increase preventatively to 4.0
```

### Which quantization for my LLM inference?

```
What's my primary constraint?
├─ Memory (model too large) → AWQ or GPTQ 4-bit
├─ Throughput (need fast batch) → AWQ 4-bit (3.5x speedup on GB10)
├─ Latency (need fast single) → GPTQ 4-bit or FP16 BF16
├─ Quality (accuracy critical) → FP16 or BF16
└─ Long context (>8K tokens) → FP8 KV-cache + FP16 weights
```

### Which sampler for ComfyUI diffusion?

```
Model type?
├─ FLUX (flow-matching) → Euler or simple (not DDIM)
├─ SD3 → DPM++ or Karras schedulers
├─ Stable Diffusion 1.5 → DPM++, Euler, or DDIM
├─ Video (LTX) → Use node defaults, avoid global flags
└─ Not sure → Default/Karras + test locally
```

---

## 9. Quick Tuning Checklist

- [ ] GPU clock locked (`nvidia-smi -lgc 3003,3003`)
- [ ] ComfyUI `--reserve-vram` set to 4.0 or 8.0
- [ ] SageAttention pinned to v2.2.0
- [ ] `PYTORCH_NO_CUDA_MEMORY_CACHING=1` added
- [ ] Batch size follows 4n+1 formula (1, 5, 9, 13, ...)
- [ ] vLLM `--gpu-memory-utilization` set to 0.75-0.80
- [ ] Hermes using `provider: custom` for non-loopback URLs
- [ ] llama.cpp `--threads` tested at 16+ for Grace
- [ ] sd-server `--threads` tested at 16+ for Qwen encoder

---

## 10. Unified Memory Performance Tips

**GB10 unified memory best practices:**

1. **Avoid `--gpu-only`** — fights the fabric's coherency
2. **Avoid `--disable-mmap`** — forces copy, slower than page-mapping
3. **Prefer memory streaming** — load/unload models dynamically
4. **Use async offload** — ComfyUI PR #10953 enabled by default
5. **Monitor memory fragmentation** — long-running workflows can fragment
6. **Prefer quantization** — 4-bit is 3.5× faster due to bandwidth bottleneck
7. **Set `PYTORCH_NO_CUDA_MEMORY_CACHING=1`** — OS can reclaim freed memory
8. **Test batch sizes** — 4n+1 formula empirically validates on your hardware

---

## References

- NVIDIA Grace Performance Tuning Guide: https://docs.nvidia.com/dccpu/grace-perf-tuning-guide/
- Arm Learning Paths GB10: https://learn.arm.com/learning-paths/laptops-and-desktops/dgx_spark_llamacpp/
- Triplany/comfyui-dgx-spark: https://github.com/Triplany/comfyui-dgx-spark
- shamily/vllm-gb10: https://github.com/shamily/vllm-gb10
- vLLM Quantization: https://docs.vllm.ai/en/stable/features/quantization/
- stable-diffusion.cpp Performance: https://github.com/leejet/stable-diffusion.cpp/blob/master/docs/performance.md

**Last updated:** 2026-05-22
