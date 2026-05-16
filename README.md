# spark-llm-stack

Local LLM inference stack for NVIDIA DGX Spark (GB10 Grace Blackwell).
Two-service setup: fast coder + deep reasoning architect, on-demand switching.

Built and tuned in May 2026. Performance numbers are real — collected live during setup.

## Hardware

- NVIDIA GB10 Grace Blackwell Superchip
- 128GB unified CPU+GPU memory (no PCIe bottleneck — full bandwidth from both sides)
- Grace CPU: 10× Cortex-X925 (4GHz) + 10× Cortex-A725 (2.8GHz), Armv9 / SVE2
- SM 12.1 — **not** the same as discrete Blackwell RTX (SM 100). Build flags matter.
- CUDA 13.0

## Models

| Service | Model | Port | Role |
|---|---|---|---|
| qwen27-mtp | Qwen3.6-27B dense, unsloth UD-Q4_K_XL MTP | 8152 | Coding |
| qwen35-mtp | Qwen3.6-35B-A3B MoE, unsloth Q4_K_XL MTP | 8154 | Architecture / design |

Both served via [llama.cpp PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673)
(MTP support by [@am17an](https://github.com/am17an), branch `08b147428`).

Model GGUFs by the [Unsloth team](https://huggingface.co/unsloth).

## Performance (measured, not estimated)

**27B Coder**
- Prefill: ~86–108 t/s (cache reuse via `--cache-reuse 1024`)
- Generation: 30–33 t/s sustained
- MTP draft acceptance: **70.4%** at `--spec-draft-n-max 5`
- Decode step reduction: **2.09×** fewer forward passes
- ms/token: ~30ms

**35B Architect**
- Prefill: ~100 t/s
- Generation: **64–67 t/s** (MoE ~3B active params per step)
- Reasoning: enabled, 4000-token budget

Both services fit simultaneously in the 128GB pool (~77GB combined).

## The build flags that actually matter on GB10

This is the part that took iteration. Default builds leave significant throughput on the table.

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp

# Fetch the MTP PR branch
git fetch origin pull/22673/head:qwen-mtp
git checkout qwen-mtp

cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON \
  -DGGML_CUDA=ON \
  -DGGML_CURL=ON \
  -DCMAKE_CUDA_ARCHITECTURES="121a-real" \
  -DGGML_CUDA_FA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DGGML_CUDA_FORCE_MMQ=ON \
  -DGGML_CPU_KLEIDIAI=ON

cmake --build build --config Release -j20 --target llama-server llama-bench
```

### Why each flag matters

| Flag | Impact |
|---|---|
| `121a-real` | Native GB10 SASS — eliminates JIT compile at load time. `121` without `a-real` generates generic PTX. |
| `GGML_CPU_KLEIDIAI=ON` | Enables ARM KleidiAI micro-kernels: SVE2-optimized GEMM for the Grace CPU. Biggest single flag on aarch64. |
| `GGML_CUDA_FA_ALL_QUANTS=ON` | Flash Attention for all KV cache types including `q8_0`. Without this, FA is silently disabled if you're not using f16 KV. You'd never know from the logs. |
| `GGML_CUDA_FORCE_MMQ=ON` | Forces quantized matmul path — faster on Blackwell for quantized models. |

## Service configuration

See `qwen27-mtp.service` and `qwen35-mtp.service`.

Key decisions:
- `--no-mmap` is **mandatory** on unified memory — page faults otherwise cripple performance
- f16 KV on 27B was slower than q8_0 despite the hybrid arch (only 16/65 layers use KV) — bandwidth pressure wins over quality at 262K context when both services share the pool
- `--spec-draft-n-max 5` on dense 27B, `--spec-draft-n-max 2` on MoE 35B — MoE gets less benefit from high draft counts
- `--reasoning-budget 4000` on architect — uncapped budget causes the model to exhaust `max_tokens` on thinking before emitting a response

### CUDA environment variables (add to systemd units)

```ini
Environment="CUDA_SCALE_LAUNCH_QUEUES=4x"
Environment="GGML_CUDA_GRAPH_OPT=1"
Environment="GGML_CUDA_FORCE_CUBLAS_COMPUTE_16F=1"
```

## llm-switch

On-demand model switching script. Stops one service before starting the other to give
the active model the full 128GB pool. Includes a `wait_ready` loop so it blocks until
the model is actually serving before returning.

```bash
# Install
cp llm-switch ~/.local/bin/
chmod +x ~/.local/bin/llm-switch

# Usage
llm-switch coder       # stop architect, start coder
llm-switch architect   # stop coder, start architect
llm-switch both        # run both (some memory bandwidth sharing)
llm-switch off         # stop everything
llm-switch status      # show what's running + memory
```

## Harness

[Hermes](https://github.com/nousresearch/hermes-agent) (NousResearch) as agentic harness.
Provider config in `hermes-config-snippet.yaml`.

Relevant Hermes config for local providers:

```yaml
providers:
  local-coder-mtp:
    api: http://127.0.0.1:8152/v1
    default_model: qwen3.6-27b-mtp-coder
    name: Coder - Qwen3.6 27B Dense
    models:
    - qwen3.6-27b-mtp-coder
    extra_body:
      max_tokens: 4096
      temperature: 0.6
      top_p: 0.95
      top_k: 20

  local-agent-mtp:
    api: http://127.0.0.1:8154/v1
    default_model: qwen3.6-35b-a3b-mtp
    name: Architect - Qwen3.6 35B MoE
    models:
    - qwen3.6-35b-a3b-mtp
    extra_body:
      max_tokens: 4096
      temperature: 1.0
      top_p: 0.95
      top_k: 20
```

## Journey / lessons learned

1. **Ollama** — tried first, convenient but too slow for serious agentic work
2. **llama.cpp default build** — much better, but missing the four flags above
3. **llama.cpp + correct GB10 flags** — where we are now

The unified memory on the GB10 is genuinely different from discrete GPU setups.
The entire model, KV cache, and OS coexist in one pool at full bandwidth.
No PCIe transfers, no VRAM/RAM boundary. Changes what's possible context-window-wise.

## What I'd love feedback on

- Better MTP tuning for the 35B MoE — 37% acceptance on the old config, haven't benchmarked new n=2 properly yet
- Whether `--swa-full` improves long-context quality on the hybrid attention layers
- Anyone running the 35B at 262K context — curious about the memory ceiling with MTP heads loaded
- Alternative harnesses to Hermes for agentic coding — especially anything with better tool-call streaming

## Credits

- MTP support in llama.cpp: [PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673) by [@am17an](https://github.com/am17an)
- Model GGUFs: [Unsloth](https://huggingface.co/unsloth) — Dynamic 2.0 quantization
- GB10 build insights: [NVIDIA DGX Spark developer forums](https://forums.developer.nvidia.com/c/accelerated-computing/dgx-spark-gb10/719)
- Hermes harness: [NousResearch](https://github.com/nousresearch)
