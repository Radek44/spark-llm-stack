# spark-llm-stack

Local LLM inference stack for NVIDIA DGX Spark (GB10 Grace Blackwell).
Two-service setup: fast coder + deep reasoning architect, on-demand switching.

Built and tuned in May 2026. Performance numbers are real — collected live during setup.

> **Note:** MTP support ([PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673) by [@am17an](https://github.com/am17an)) merged into llama.cpp mainline May 2026.
> You no longer need a custom branch — just clone mainline and build with the flags below.

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

## Build

MTP is now in llama.cpp mainline — just clone and build:

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp

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

### Why each flag matters on GB10

| Flag | Impact |
|---|---|
| `121a-real` | Native GB10 SASS — eliminates JIT compile at load time. `121` without `a-real` generates generic PTX. |
| `GGML_CPU_KLEIDIAI=ON` | ARM KleidiAI micro-kernels: SVE2-optimized GEMM for the Grace CPU. Biggest single flag on aarch64. |
| `GGML_CUDA_FA_ALL_QUANTS=ON` | Flash Attention for all KV cache types including `q8_0`. Without this, FA is **silently disabled** if you're not using f16 KV. You'd never know from the logs. |
| `GGML_CUDA_FORCE_MMQ=ON` | Forces quantized matmul path — faster on Blackwell for quantized models. |

### CUDA environment variables (add to systemd units)

```ini
Environment="CUDA_SCALE_LAUNCH_QUEUES=4x"
Environment="GGML_CUDA_GRAPH_OPT=1"
Environment="GGML_CUDA_FORCE_CUBLAS_COMPUTE_16F=1"
```

## Service configuration

See `qwen27-mtp.service` and `qwen35-mtp.service`.

Key decisions:
- `--no-mmap` is **mandatory** on unified memory — page faults cripple performance otherwise
- f16 KV on 27B was slower than q8_0 despite the hybrid arch (only 16/65 layers use KV) — bandwidth pressure wins at 262K context when both services share the pool
- `--spec-draft-n-max 5` on dense 27B, `--spec-draft-n-max 2` on MoE 35B — MoE gets less benefit from high draft counts
- `--reasoning-budget 4000` on architect — uncapped budget causes the model to exhaust `max_tokens` on thinking before emitting a response

## llm-switch

On-demand model switching. Stops one service before starting the other to give the
active model the full 128GB pool. Blocks until the model is actually serving.

```bash
cp llm-switch ~/.local/bin/
chmod +x ~/.local/bin/llm-switch

llm-switch coder       # stop architect, start coder
llm-switch architect   # stop coder, start architect
llm-switch both        # run both (some memory bandwidth sharing)
llm-switch off         # stop everything
llm-switch status      # show what's running + memory
```

## Harness

[Hermes](https://github.com/nousresearch/hermes-agent) (NousResearch) as agentic harness.
Provider config in `hermes-config-snippet.yaml`.

## Journey / lessons learned

1. **Ollama** — tried first, convenient but too slow for serious agentic work
2. **llama.cpp with default build** — much better, but missing the four flags above
3. **llama.cpp + correct GB10 flags + MTP** — where we are now

The unified memory on GB10 is genuinely different from discrete GPU setups.
The entire model, KV cache, and OS coexist in one pool at full bandwidth.
No PCIe transfers. No VRAM/RAM boundary. Changes what's possible context-window-wise.

## Open questions — improvements welcome

- Better MTP tuning for the 35B MoE — curious about acceptance rates at n=2 vs n=3
- Whether `--swa-full` improves long-context quality on the hybrid attention layers
- Anyone running the 35B at 262K context — what's the memory ceiling with MTP heads loaded?
- Alternative harnesses to Hermes for agentic coding with better tool-call streaming

## Credits

- MTP support merged into llama.cpp mainline: [PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673) by [@am17an](https://github.com/am17an)
- Model GGUFs: [Unsloth](https://huggingface.co/unsloth) — Dynamic 2.0 quantization
- GB10 build insights: [NVIDIA DGX Spark developer forums](https://forums.developer.nvidia.com/c/accelerated-computing/dgx-spark-gb10/719)
- Hermes harness: [NousResearch](https://github.com/nousresearch)

## Binary note (May 2026)

MTP merged into llama.cpp mainline on May 16, 2026 (PR #22673).
However, benchmarking shows the mainline binary currently underperforms
the pre-merge fork at commit `08b147428` on GB10:

| Binary | tg t/s | MTP acceptance |
|---|---|---|
| Fork `08b147428` | 28–30 | 75% |
| Mainline post-merge | 23 | 54% |

We are using the fork until the regression is resolved upstream.
Watch commits touching `src/llama-mtp.cpp` for fixes.

## Binary note (May 2026)

MTP merged into llama.cpp mainline on May 16, 2026 (PR #22673).
However, benchmarking shows the mainline binary currently underperforms
the pre-merge fork at commit `08b147428` on GB10:

| Binary | tg t/s | MTP acceptance |
|---|---|---|
| Fork `08b147428` | 28–30 | 75% |
| Mainline post-merge | 23 | 54% |

We are using the fork until the regression is resolved upstream.
Watch commits touching `src/llama-mtp.cpp` for fixes.

## Benchmark results (May 2026, GB10, exclusive operation)

Measured with greedy decoding (temp=0, deterministic), 8 timed runs after 6 warmup runs.

### 27B coder
| metric | value |
|---|---|
| tg t/s avg | 23.9 |
| tg t/s stdev | 0.6 |
| MTP acceptance avg | 66.5% |
| prefill avg | 110 t/s |

### 35B architect
| metric | value |
|---|---|
| tg t/s avg | 59.9 |
| tg t/s stdev | 3.5 (still warming, trending up) |
| MTP acceptance avg | 64.8% |
| prefill avg | 349 t/s |

### Memory profile
- 27B resident: ~61 GB
- 35B resident: ~48 GB
- Model switch (llm-switch): clean eviction, 8 GB floor between loads
- Swap: 3 GB constant (OS, not model pressure)

### Binary
Both services run `ggml-org/llama.cpp` branch `qwen-mtp` at commit `08b147428` (version 9172).
Mainline post-merge tested and found ~20% slower on GB10 — tracking upstream for fixes.


## FLUX.2-klein image generation

FLUX.2-klein 4B (Apache 2.0) via stable-diffusion.cpp for local image generation.

**Model files (~17GB total):**
- `flux-2-klein-4b.safetensors` — diffusion model (~8GB)
- `text_encoder/qwen_3_4b.safetensors` — merged Qwen3-4B encoder (~8GB)
- `ae.safetensors` — VAE (~335MB)

**Build:**
Build stable-diffusion.cpp with `-DSD_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=121 -DSD_FLASH_ATTN=ON`
See full build instructions in the repo.

**API** — async job system, not OpenAI-compatible:
- `POST /sdcpp/v1/img_gen` — submit job, returns job ID
- `GET /sdcpp/v1/jobs/{id}` — poll until completed, get b64_json images

**CLI:** `flux-gen "prompt" [width] [height] [steps] [seed]`

**Performance:** 4 steps, sub-10s on GB10, 15GB VRAM

**Note:** Use `llm-switch imagine` to load. Health endpoint is `/sdcpp/v1/capabilities` not `/health`.
