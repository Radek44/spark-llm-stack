# spark-llm-stack

Lean local AI inference and agent runtime stack for **NVIDIA DGX Spark (GB10 Grace Blackwell)**.

Current target: **vLLM + LiteLLM + Hermes**, with old llama.cpp/GGUF LLM services removed from the managed stack. Image generation remains separate via FLUX.2-klein / ComfyUI.

> Running more than one heavyweight checkpoint service simultaneously can OOM the host. Boot defaults are intentionally conservative: auto-start LiteLLM only; keep heavyweight model/media services manual/on-demand.

---

## Hardware requirements

- NVIDIA GB10 Grace Blackwell Superchip
- 128 GB unified CPU+GPU memory
- CUDA 13.0+, driver 580+
- SM 12.1 / 121a — not discrete Blackwell RTX SM100

---

## Target architecture

```text
DGX Spark
├── vLLM                         # primary local model serving
│   └── nvidia/Qwen3.6-35B-A3B-NVFP4 on :8170  (fast_local/private_local)
├── LiteLLM                      # local router on :8180
│   ├── fast_local / private_local / small_coder
│   └── optional explicit frontier/API aliases
├── Hermes Agent                 # CLI/TUI/Desktop/gateway/cron/memory/skills
├── FLUX.2-klein direct service  # image generation on :8160
├── ComfyUI                      # manual workflow UI on :8188
└── optional RAG/UI/security     # Qdrant, Open WebUI/AnythingLLM, NemoClaw/OpenShell
```

Do not expose model endpoints on the LAN by default. Service templates bind to `127.0.0.1`.

---

## Managed service roster

| Slot | Service | Model / app | Port | Role |
|---|---|---|---:|---|
| `fast_local` | `vllm-qwen36-35b-nvfp4.service` | `nvidia/Qwen3.6-35B-A3B-NVFP4` | 8170 | Primary local LLM |
| `small_coder` | `gemma4-v2-coder.service` | `yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF` Q4_K_M | 8190 | Manual coding subagent experiment |
| `litellm` | `litellm.service` | LiteLLM router | 8180 | Unified model gateway |
| `imagine` | `flux-klein.service` | `black-forest-labs/FLUX.2-klein-4B` | 8160 | Direct image generation |
| `comfyui` | `comfyui.service` | existing ComfyUI install | 8188 | Diffusion workflows |

Old llama.cpp model services (`qwen35-mtp`, `qwen27-mtp`, `gemma-*`, `gptoss-20b`) were intentionally removed from this repo's managed stack. Historical notes remain in `POSTMORTEM.md` and backups.

---

## Model candidates

See `MODEL_CANDIDATES.md` for Hugging Face Hub evidence and recommended next models.

Shortlist:

1. `nvidia/Qwen3.6-35B-A3B-NVFP4` — default local Hermes model.
2. `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4` — NVIDIA-native alternate after Qwen is stable.
3. `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` or vLLM/AWQ quant — optional coding specialist.
4. `yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF` — manual small coding subagent experiment.
5. `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` — experimental large reasoning model, one checkpoint at a time.
6. `openai/gpt-oss-20b` — optional cheap/general route if a small local fallback is needed.

---

## vLLM primary service

Template: `vllm-qwen36-35b-nvfp4.service`.

Expected runtime:

```text
http://127.0.0.1:8170/v1
served model aliases: fast_local, qwen3.6-35b-a3b-nvfp4
model: nvidia/Qwen3.6-35B-A3B-NVFP4
```

The template expects vLLM at `%h/venvs/vllm-gb10/bin/python`. Override `VLLM_PYTHON` in a systemd drop-in if your install path differs.

Keep this service manual/on-demand only. The unit has an `ExecCondition` requiring about 90,000,000 KiB `MemAvailable` before a raw `systemctl --user start` can load the checkpoint, and the drop-in caps the service at `MemoryHigh=65G`, `MemoryMax=80G`, `MemorySwapMax=4G`.

---

## LiteLLM gateway

Template service: `litellm.service`.
Template config: `litellm/config.example.yaml`.

Recommended aliases:

| Alias | Route | Cloud fallback? |
|---|---|---|
| `fast_local` | vLLM Qwen3.6-35B NVFP4 on `:8170` | No |
| `private_local` | same local-only route for private docs/data | No |
| `small_coder` | llama.cpp Gemma4 12B v2 coder on `:8190` | No |
| `code_frontier` | OpenAI API, only if configured privately | Explicit only |
| `claude_frontier` | Anthropic API, only if configured privately | Explicit only |

Do not silently fall back from private/local aliases to cloud providers.

---

## Installation / update

```bash
mkdir -p ~/.config/systemd/user
cp vllm-qwen36-35b-nvfp4.service gemma4-v2-coder.service litellm.service flux-klein.service ~/.config/systemd/user/
[ -f comfyui.service ] && cp comfyui.service ~/.config/systemd/user/

for d in drop-ins/*/; do
  svc=$(basename "$d")
  mkdir -p ~/.config/systemd/user/$svc
  cp "$d/override.conf" ~/.config/systemd/user/$svc/
done

cp llm-switch ~/.local/bin/ && chmod +x ~/.local/bin/llm-switch
cp flux-gen ~/.local/bin/ && chmod +x ~/.local/bin/flux-gen
chmod +x scripts/check-memavailable-kib
systemctl --user daemon-reload
```

---

## llm-switch

```bash
llm-switch fast_local    # vLLM Qwen3.6-35B NVFP4
llm-switch small_coder   # Gemma4 12B v2 coding-specialist GGUF
llm-switch litellm       # LiteLLM router; does not stop model services
llm-switch imagine       # FLUX.2-klein image generation
llm-switch comfyui       # ComfyUI workflows
llm-switch off           # stop model/media services; leaves LiteLLM alone
llm-switch status        # show state + MemAvailable/swap

llm-switch boot-safe
llm-switch boot-router  # recommended: LiteLLM auto-starts, heavyweight services manual
llm-switch boot-default fast_local --force-heavy  # dangerous; only after sustained benchmarks
llm-switch boot-status
```

---

## Hermes Agent

Provider config template: `hermes-config-snippet.yaml`.

Recommended path:

```text
Hermes -> local-litellm provider -> http://127.0.0.1:8180/v1 -> fast_local/private_local
```

Key settings:

- Use LiteLLM for normal routing.
- Use `extra_body.max_tokens: 16384` or higher for tool-heavy coding sessions.
- Keep secrets out of this repo; use `~/.hermes/.env`, Hermes auth, or service env.

---

## FLUX.2-klein API

sd-server uses an async job API, not OpenAI-compatible:

```bash
curl -s http://127.0.0.1:8160/sdcpp/v1/img_gen \
  -H "Content-Type: application/json" \
  -d '{"prompt":"...", "width":512, "height":512,
       "sample_params":{"sample_steps":4, "sample_method":"euler",
                        "guidance":{"txt_cfg":1.0,"distilled_guidance":3.5}}}'

curl -s http://127.0.0.1:8160/sdcpp/v1/jobs/{id}
flux-gen "pixel art sword icon, white background" 512 512 4 42
```

The service template uses `--type bf16 --max-vram 90` when supported by the installed `sd-server`.

---

## Hardening

Each managed service gets:

- `MemoryMax` — kernel OOMs the cgroup only, host stays up.
- `OOMPolicy=stop` — OOM = deliberate halt, not respawn into more pressure.
- `Conflicts=` for heavyweight model services.
- `StartLimitBurst=3` in `[Unit]`.

| Service | MemoryHigh | MemoryMax | MemorySwapMax |
|---|---:|---:|---:|
| `vllm-qwen36-35b-nvfp4` | 65G | 80G | 4G |
| `gemma4-v2-coder` | 24G | 32G | 2G |
| `comfyui` | 30G | 40G | 2G |
| `flux-klein` | 12G | 16G | 1G |
| `litellm` | 2G | 4G | 512M |

```bash
bash harden-llm-stack.sh           # apply
bash harden-llm-stack.sh --dry-run # preview
bash harden-llm-stack.sh --revert  # remove generated drop-ins
```

### Pre-reboot checklist

```bash
llm-switch boot-status
journalctl --list-boots | tail -5
free -h
```

---

## Security boundary roadmap

Before giving Hermes broad always-on authority, run high-authority modes through NemoClaw/OpenShell or equivalent policy controls:

- allow only selected project/data directories;
- deny SSH keys, browser profiles, password stores, and broad home access;
- allow GitHub/docs/package registries/selected APIs;
- deny LAN scanning and metadata/secret endpoints;
- require approval for write/delete/install/push/send actions.
