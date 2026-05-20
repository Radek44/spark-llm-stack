# spark-llm-stack

Local LLM inference stack for **NVIDIA DGX Spark (GB10 Grace Blackwell)**.  
Two-service design: fast coder + deep reasoning architect, on-demand switching.  
Benchmarked and tuned May 2026. All performance numbers are real.

> **Before enabling any service, read the [hardening section](#hardening).**  
> Running more than one heavyweight service simultaneously will OOM the host.

---

## Hardware requirements

- NVIDIA GB10 Grace Blackwell Superchip
- 128 GB unified CPU+GPU memory (no PCIe bottleneck)
- Grace CPU: 10× Cortex-X925 (4 GHz) + 10× Cortex-A725 (2.8 GHz), Armv9/SVE2
- CUDA 13.0+, driver 580+
- SM 12.1 — **not** the same as discrete Blackwell RTX (SM 100); build flags matter

---

## Model roster

| Slot | Model | HF repo | Port | Role |
|---|---|---|---|---|
| `coder` | Qwen3.6-27B dense | `unsloth/Qwen3.6-27B-MTP-GGUF:UD-Q4_K_XL` | 8152 | Fast coding, MTP |
| `architect` | Qwen3.6-35B-A3B MoE | `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Q4_K_XL` | 8154 | Deep reasoning |
| `vision` | Gemma-4-E4B | `unsloth/gemma-4-E4B-it-GGUF:UD-Q4_K_XL` | 8155 | Fast vision + audio |
| `gemma` | Gemma-4-31B | `unsloth/gemma-4-31B-it-GGUF:UD-Q4_K_XL` | 8156 | Alt reasoning + image |
| `gptoss` | GPT-OSS-20B | built-in (`--gpt-oss-20b-default`) | 8157 | Fast general |
| `imagine` | FLUX.2-klein-4B | `black-forest-labs/FLUX.2-klein-4B` (Apache 2.0) | 8160 | Image generation |
| `comfyui` | ComfyUI | your existing install | 8188 | Diffusion workflows |

---

## Performance (measured, greedy decode, 8 runs, GB10)

| Model | tg t/s avg | tg stdev | MTP accept | pp t/s |
|---|---|---|---|---|
| Qwen3.6-27B coder | 23.9 | 0.8 | 66–70% | 110–120 |
| Qwen3.6-35B architect | 58.5 | 0.5 | n/a (MTP removed) | 435 |

Memory at rest: ~8.5 GB. Peak per service: 27B ~61 GB, 35B ~48 GB.  
Both services fit simultaneously (~77 GB combined) but exclusive operation is recommended.

---

## Build: llama.cpp (GB10-specific flags)

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

| Flag | Why it matters |
|---|---|
| `121a-real` | Native GB10 SASS — no JIT at load time. `121` alone generates generic PTX. |
| `GGML_CPU_KLEIDIAI=ON` | ARM KleidiAI SVE2 GEMM kernels on Grace CPU. Biggest single flag on aarch64. |
| `GGML_CUDA_FA_ALL_QUANTS=ON` | Flash Attention for q8_0 KV cache. Without this, FA is silently disabled. |
| `GGML_CUDA_FORCE_MMQ=ON` | Quantized matmul path — faster on Blackwell for quantized models. |

> **Binary note (May 2026):** MTP merged into llama.cpp mainline (PR #22673 by @am17an).  
> However, mainline currently underperforms the pre-merge branch on GB10 (~23 t/s vs ~28 t/s).  
> The service files point to the MTP branch binary. Watch `src/llama-mtp.cpp` commits for fixes.

### CUDA environment variables (add to every service unit)

```ini
Environment="CUDA_SCALE_LAUNCH_QUEUES=4x"
Environment="GGML_CUDA_GRAPH_OPT=1"
Environment="GGML_CUDA_FORCE_CUBLAS_COMPUTE_16F=1"
```

---

## Build: stable-diffusion.cpp (for FLUX.2-klein)

```bash
git clone --recursive https://github.com/leejet/stable-diffusion.cpp
cd stable-diffusion.cpp
git submodule update --init --recursive

cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DSD_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="121" \
  -DSD_FLASH_ATTN=ON

cmake --build build --config Release -j20
```

### FLUX.2-klein model files (~17 GB total)

```bash
mkdir -p ~/models/flux2-klein/text_encoder

# Main model (~8 GB, Apache 2.0)
hf download black-forest-labs/FLUX.2-klein-4B \
  flux-2-klein-4b.safetensors --local-dir ~/models/flux2-klein

# VAE (~335 MB)
hf download Comfy-Org/flux2-dev \
  split_files/vae/flux2-vae.safetensors --local-dir ~/models/flux2-klein

# Text encoder shards (~8 GB total)
hf download black-forest-labs/FLUX.2-klein-4B \
  text_encoder/ --local-dir ~/models/flux2-klein/text_encoder

# Merge shards into single file (required once)
python3 -c "
from safetensors.torch import save_file, load_file
base = 'text_encoder'
s1 = load_file(f'{base}/model-00001-of-00002.safetensors')
s2 = load_file(f'{base}/model-00002-of-00002.safetensors')
save_file({**s1, **s2}, f'{base}/qwen_3_4b.safetensors')
print('Done')
" 
```

---

## Installation

Service files use the `%h` systemd specifier (expands to your home directory).  
You only need to adjust two things:

1. **`ExecStart` binary path** — edit each `.service` to point at your llama.cpp build.  
   Default: `%h/src/llama.cpp-mtp/build/bin/llama-server`

2. **`flux-klein.service` model paths** — edit to match your download location.  
   Default: `%h/models/flux2-klein/...`

```bash
# Install service files
mkdir -p ~/.config/systemd/user
cp *.service ~/.config/systemd/user/

# Install drop-ins (memory caps + mutual exclusion) — recommended
bash harden-llm-stack.sh

# Or manually:
for d in drop-ins/*/; do
  svc=$(basename "$d")
  mkdir -p ~/.config/systemd/user/$svc
  cp "$d/override.conf" ~/.config/systemd/user/$svc/
done

systemctl --user daemon-reload

# Install CLI tools
cp llm-switch ~/.local/bin/ && chmod +x ~/.local/bin/llm-switch
cp flux-gen ~/.local/bin/ && chmod +x ~/.local/bin/flux-gen
```

---

## llm-switch

On-demand model switching. Stops the current service before starting the next,
giving each model the full 128 GB pool. Blocks until the model is serving.

```bash
llm-switch coder        # Qwen3.6-27B  — fast coding, MTP
llm-switch architect    # Qwen3.6-35B  — deep reasoning, MoE
llm-switch gemma        # Gemma-4-31B  — alt reasoning + image input
llm-switch vision       # Gemma-4-E4B  — fast vision + audio input
llm-switch imagine      # FLUX.2-klein — image generation
llm-switch gptoss       # GPT-OSS-20B  — fast general
llm-switch comfyui      # ComfyUI      — diffusion UI + workflows
llm-switch both         # coder + architect (accepts some contention)
llm-switch off          # stop everything
llm-switch status       # show running state + memory

# Boot state management
llm-switch boot-default architect   # set one slot to autostart at boot
llm-switch boot-safe                # disable all model autostart
llm-switch boot-status              # check what starts at boot
```

---

## Harness

[Hermes](https://github.com/nousresearch/hermes-agent) (NousResearch) as agentic harness.  
Provider config: `hermes-config-snippet.yaml`.

Key Hermes settings for local providers:
- `extra_body.max_tokens: 4096` — prevents response cutoff on long codegen
- `extra_body.temperature` — set per-model (0.6 coder, 1.0 architect/gemma)
- `extra_body.top_k` — 20 for Qwen models, 64 for Gemma models

---

## FLUX.2-klein API

sd-server uses an async job API, not OpenAI-compatible:

```bash
# Submit job
curl -s http://127.0.0.1:8160/sdcpp/v1/img_gen \
  -H "Content-Type: application/json" \
  -d '{"prompt":"...", "width":512, "height":512,
       "sample_params":{"sample_steps":4, "sample_method":"euler",
                        "guidance":{"txt_cfg":1.0,"distilled_guidance":3.5}}}'

# Poll until completed
curl -s http://127.0.0.1:8160/sdcpp/v1/jobs/{id}
# result.images[0].b64_json contains the PNG

# Or use the CLI wrapper
flux-gen "pixel art sword icon, white background" 512 512 4 42
```

> Use 4 steps with `cfg_scale=1.0` for the distilled 4B model.  
> The built-in web UI is available at `http://127.0.0.1:8160/` when the service is running.

---

## Hardening

> **Critical on GB10.** Running multiple heavyweight services simultaneously  
> exceeds 128 GB and causes a systemd OOM respawn loop that bricks the host.  
> See [POSTMORTEM.md](POSTMORTEM.md) for the full incident report.

### Drop-ins applied by `harden-llm-stack.sh`

Each service gets:
- `MemoryMax` — kernel OOMs the cgroup only, host stays up
- `OOMPolicy=stop` — OOM = deliberate halt, not respawn into more pressure
- `Conflicts=` — systemd stops conflicting services automatically
- `StartLimitBurst=3` — gives up after 3 failures in 10 minutes

| Service | MemoryHigh | MemoryMax |
|---|---|---|
| qwen27-mtp, qwen35-mtp, gemma-31b | 70G | 80G |
| gptoss-20b, comfyui | 30G | 40G |
| gemma-vision | 15G | 20G |
| flux-klein | 12G | 16G |

```bash
bash harden-llm-stack.sh          # apply
bash harden-llm-stack.sh --revert # remove all drop-ins
```

### Flag notes

| Flag | Status | Reason |
|---|---|---|
| `--no-mmap` | **removed** | Anonymous pages can't be evicted on unified memory. Page cache is safer. |
| `--mlock` | **removed** | Pins entire model permanently, starves other services. |
| `-c 262144` | optional | Lower to `131072` for typical tasks; 256K context is rarely needed. |

### Pre-reboot checklist

```bash
llm-switch boot-status              # confirm only one service autostarts
journalctl --list-boots | tail -5   # should grow ~1/day
```

---

## Open questions — improvements welcome

- Better MTP tuning for the 35B MoE (currently disabled, was 1.15–1.25× gain)
- Whether `--swa-full` improves long-context quality on hybrid attention layers
- Mainline llama.cpp MTP regression — watching `src/llama-mtp.cpp` for fixes
- Alternative harnesses to Hermes with better tool-call streaming

---

## Credits

- MTP support: [PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673) by [@am17an](https://github.com/am17an) — merged mainline May 2026
- Model GGUFs: [Unsloth](https://huggingface.co/unsloth) — Dynamic 2.0 quantization
- FLUX.2-klein: [Black Forest Labs](https://github.com/black-forest-labs/flux2) — Apache 2.0
- stable-diffusion.cpp: [leejet](https://github.com/leejet/stable-diffusion.cpp)
- Harness: [NousResearch Hermes](https://github.com/nousresearch)
- GB10 build insights: [NVIDIA DGX Spark developer forums](https://forums.developer.nvidia.com/c/accelerated-computing/dgx-spark-gb10/719)
