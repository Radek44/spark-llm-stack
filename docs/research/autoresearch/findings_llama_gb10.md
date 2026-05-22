# llama.cpp / llama-server on GB10 — Research Findings

Research date: 2026-05-22  
Sources: NVIDIA forums, Arm Learning Paths, Dao-AILab/flash-attention, LMSYS blog, community benchmarks

---

## Build Configuration for SM_121

GB10 is compute capability **12.1 (sm_121)** — distinct from the discrete Blackwell GPUs (sm_100a). Mainline prebuilt llama.cpp binaries target sm_80–sm_100 and emit a kernel-arch mismatch error at runtime. Must build from source.

### Required CMake flags
```bash
mkdir -p build-gpu && cd build-gpu
cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=ON \
  -DGGML_CUDA_F16=ON \
  -DCMAKE_CUDA_ARCHITECTURES=121 \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -DCMAKE_CUDA_COMPILER=nvcc
make -j$(nproc)
```

| Flag | Purpose | Validity |
|---|---|---|
| `-DGGML_CUDA=ON` | Enable CUDA backend, offload matrix ops to GPU | Confirmed |
| `-DGGML_CUDA_F16=ON` | FP16 CUDA kernels — reduces memory, increases throughput | Confirmed |
| `-DCMAKE_CUDA_ARCHITECTURES=121` | Generate native PTX/SASS for sm_121 | Confirmed |

**CUDA version:** must be 13.0+ (matches DGX OS driver stack 580.x). Confirmed.

**ARM toolchain:** if multiple CUDA versions are installed, explicitly set compilers to prevent CMake mismatches. Confirmed.

### Build variant: MTP branch
Service files in this repo point to `%h/src/llama.cpp-mtp/build/bin/llama-server`. MTP (multi-token prediction) branch reportedly outperforms mainline on GB10. *Note: Community anecdotal performance reports indicate ~20-25% improvement, though specific metrics depend heavily on model quantization.*

---

## Flash Attention on GB10

**Dao-AILab/flash-attention does NOT support sm_121 natively as of May 2026.** [Source: Dao-AILab/flash-attention#1969]

Status as of 2026-05-22:
- **Dao-AILab/flash-attention:** Does not officially whitelist `sm_121`.
- **Workaround:** Compile with `export TORCH_CUDA_ARCH_LIST="12.0"` for binary compatibility (sm_120). [Confirmed]
- **Recommended Alternative:** Use PyTorch native `scaled_dot_product_attention` (SDPA) with cuDNN 9.x, which often achieves better performance as it natively supports `sm_121` instructions. [Confirmed]

**llama.cpp internal flash attention** (`--flash-attn` flag) is a separate implementation (ggml-based) and DOES work natively on `sm_121` without workarounds. [Confirmed]

---

## KV Cache Quantization — DGX Spark Benchmarks

Tested: Nemotron-3-Nano-30B-A3B, 128K context. [Source: NVIDIA forums #365138]

### Prompt processing throughput (tok/s)
| Context | f16 | q8_0 | q4_0 |
|---|---|---|---|
| ~8K | 371 | ~368 | 363 |
| ~16K | 361 | ~355 | 346 |
| ~32K | 328 | ~323 | 317 |
| ~64K | 283 | ~278 | **21** ← cliff |

### Generation throughput (tok/s)
| Context | f16 | q8_0 | q4_0 |
|---|---|---|---|
| ~8K | 14.7 | ~14.5 | 14.2 |
| ~16K | 13.9 | ~13.5 | 12.7 |
| ~32K | 13.5 | ~12.8 | 11.0 |
| ~64K | 13.3 | ~12.9 | **8.6** |

### Findings assessment
- **Memory impact:** q4_0 can use MORE memory than f16 for the KV cache due to metadata overhead on specific context lengths. [Likely/Contested - dependent on implementation details, requires further validation]
- **The 64K cliff:** Confirmed behavioral characteristic on DGX Spark due to dequantization overhead in the KV cache scanning mechanism during decode.

---

## Flags: What NOT to Use in Service Files

Per `CLAUDE.md` and community validation:

| Flag | Reason to avoid |
|---|---|
| `--no-mmap` | Forces weights into anonymous pages (not evictable on unified memory). |
| `--mlock` | Pins model permanently, starves other services; catastrophic on 128 GB shared pool. |

---

## Threading and Batch Recommendations

GB10 hardware: 20 ARM cores (10 Cortex-X925 + 10 Cortex-A725).

- **Threading:** Conservative: `--threads 8`. Scaling testing recommended up to 20. Do not set threads > 20 as it causes significant context-switching overhead on ARM. [Corrected based on hardware specs]

---

## vLLM on GB10

vLLM officially requires patch/recompile for `sm_121` as of early 2026.
- **Config:** `--gpu-memory-utilization 0.85` (crucial for UMA headroom).
- **Docker image:** `vllm/vllm-openai:gemma4-cu130` includes native `sm_121` support.

---

## Sources
- https://learn.arm.com/learning-paths/laptops-and-desktops/dgx_spark_llamacpp/2_gb10_llamacpp_gpu
- https://forums.developer.nvidia.com/t/kv-cache-quantization-benchmarks-on-dgx-spark-q4-0-vs-q8-0-vs-f16-llama-cpp-nemotron-30b-128k-context/365138
- https://github.com/Memoriant/dgx-spark-kv-cache-benchmark
- https://github.com/Dao-AILab/flash-attention/issues/1969
- https://medium.com/@rakshith.d26/flash-attention-on-sm-121-solving-pytorch-compatibility-on-blackwell-gb10
- https://forums.developer.nvidia.com/t/building-llama-cpp-container-images-for-spark-gb10/353664
- https://github.com/ggml-org/llama.cpp/discussions/20969 (TurboQuant)
- https://www.lmsys.org/blog/2025-10-13-nvidia-dgx-spark/
