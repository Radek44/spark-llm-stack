# spark-llm-stack

Lean local AI inference and agent runtime stack for **NVIDIA DGX Spark (GB10 Grace Blackwell)**.

Current target: **Laguna S 2.1 + vLLM + LiteLLM + Hermes**, with DFlash speculative decoding and all large GPU services manual/on-demand. Image generation remains separate via FLUX.2-klein / ComfyUI.

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
│   └── poolside/Laguna-S-2.1-NVFP4 on :8170  (fast_local/private_local)
├── LiteLLM                      # local router on :8180
│   ├── fast_local / private_local
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
| `fast_local` | `vllm-laguna-s21-nvfp4.service` | `poolside/Laguna-S-2.1-NVFP4` + DFlash | 8170 | Primary local LLM |
| `litellm` | `litellm.service` | LiteLLM router | 8180 | Unified model gateway |
| `imagine` | `flux-klein.service` | `black-forest-labs/FLUX.2-klein-4B` | 8160 | Direct image generation |
| `comfyui` | `comfyui.service` | existing ComfyUI install | 8188 | Diffusion workflows |

Legacy Qwen/Gemma services, drop-ins, model caches, and the old vLLM environment were retired after Laguna passed direct, routed, thinking, tool-call, DFlash, memory, and clean-release gates. Historical notes remain in `POSTMORTEM.md` and backups.

---

## Model candidates

See `MODEL_CANDIDATES.md` for Hugging Face Hub evidence and recommended next models.

Shortlist:

1. `poolside/Laguna-S-2.1-NVFP4` — accepted default local Hermes model with matched DFlash.
2. `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` or vLLM/AWQ quant — optional future coding specialist only if benchmarks justify another cache.
3. `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` — experimental large reasoning model, one checkpoint at a time.

---

## vLLM primary service

Template: `vllm-laguna-s21-nvfp4.service`.

Expected runtime:

```text
http://127.0.0.1:8170/v1
served model aliases: fast_local, laguna-s-2.1-nvfp4
model: poolside/Laguna-S-2.1-NVFP4
```

The template expects vLLM 0.26.0 at `%h/venvs/vllm-laguna-0.26.0/bin/python`. It pins the last DGX-sized official target (`07614121...`, 66.98 GiB) and its spinquant-removal DFlash draft (`4cdcc6e9...`). Poolside replaced the target on 2026-08-01 with revision `f8fdfcdc...` (92.85 GiB) while its card still described roughly 71 GB. That newer target crossed the 20 GiB safety floor during weight loading before DFlash, KV allocation, or graph capture, so its local cache was removed after the safe pin passed acceptance.

Run `scripts/check-vllm-laguna-env` before serving. NVIDIA publishes cuSPARSELt for this host with the SBSA wheel tag; current Python packaging tools report that tag as unsupported even though the installed shared library is AArch64. The check permits only that exact known mismatch and fails on every other dependency problem. A cold FlashInfer 0.6.14 cache remains a first-start risk, so the eager canary keeps compilation at `MAX_JOBS<=2` and must run in isolation.

Laguna uses its matched DFlash draft model, not Qwen-style MTP. The accepted service uses eager execution, one sequence, a conservative 32,768-token context, an explicit 4 GiB BF16 KV cache, and `expandable_segments:False`. Percentage-based `gpu-memory-utilization` auto-sizing is prohibited: it attempted a roughly 29 GiB cache after model load. Poolside's checkpoint advertises FP8 KV, but vLLM 0.26.0 produced severely repetitive output and NVIDIA allocation errors with FP8 KV locally. DFlash then produced three allocation errors while attaching under PyTorch's experimental expandable allocator; disabling it eliminated those errors. The clean DFlash canary held at least 36.6 GiB `MemAvailable`, generated correct code in 5.79 seconds, and accepted 185/252 draft tokens. Direct and LiteLLM-routed normal, thinking, and tool-call checks passed. The launcher rejects a larger KV cache unless a separate promotion gate explicitly sets `LAGUNA_ALLOW_LARGER_KV_CACHE=true`. Graph capture and longer context remain separate future gates. The shared launcher requires 110 GiB `MemAvailable`, waits at most 30 seconds for the machine-wide GPU lease, and stops the process below 20 GiB. The drop-in caps the service at `MemoryHigh=100G`, `MemoryMax=108G`, with swap disabled.

---

## LiteLLM gateway

Template service: `litellm.service`.
Template config: `litellm/config.example.yaml`.

Recommended aliases:

| Alias | Route | Cloud fallback? |
|---|---|---|
| `fast_local` | vLLM Laguna S 2.1 NVFP4 on `:8170` | No |
| `private_local` | same local-only route for private docs/data | No |
| `code_frontier` | OpenAI API, only if configured privately | Explicit only |
| `claude_frontier` | Anthropic API, only if configured privately | Explicit only |

Do not silently fall back from private/local aliases to cloud providers.
The router uses a 1,200-second local inference timeout and does not silently drop unsupported request parameters; thinking and tool controls must either reach vLLM or fail visibly.

---

## Installation / update

```bash
mkdir -p ~/.config/systemd/user
cp vllm-laguna-s21-nvfp4.service litellm.service flux-klein.service comfyui.service \
  ~/.config/systemd/user/

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
llm-switch fast_local    # vLLM Laguna S 2.1 NVFP4 + matched DFlash
llm-switch litellm       # LiteLLM router; does not stop model services
llm-switch imagine       # FLUX.2-klein image generation
llm-switch comfyui       # ComfyUI workflows
llm-switch off           # stop model/media services; leaves LiteLLM alone
llm-switch all-off       # also stop Asset Forge TRELLIS/rig workers
llm-switch status        # show systemd, lease, containers, memory, and router state

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

The dormant service template uses `--type bf16 --max-vram 12`, stays disabled at boot, and must pass a separately monitored quality/performance canary before promotion.

---

## Hardening

Each managed service gets:

- `MemoryMax` — a secondary CPU-memory boundary; GPU allocations on unified memory also require the shared runtime watchdog.
- `OOMPolicy=stop` — OOM = deliberate halt, not respawn into more pressure.
- `Conflicts=` for heavyweight model services.
- `StartLimitBurst=2` over 30 minutes for heavyweight services.

| Service | MemoryHigh | MemoryMax | MemorySwapMax |
|---|---:|---:|---:|
| `vllm-laguna-s21-nvfp4` | 100G | 108G | 0 |
| `comfyui` | 76G | 84G | 0 |
| `flux-klein` | 12G | 16G | 1G |
| `litellm` | 2G | 4G | 512M |

```bash
bash harden-llm-stack.sh           # apply
bash harden-llm-stack.sh --dry-run # preview
bash harden-llm-stack.sh --revert  # remove generated drop-ins
scripts/validate-stack             # verify launch and memory-safety invariants
```

ComfyUI intentionally avoids `--gpu-only` and `--highvram` on DGX Spark. It disables pinned memory, reserves 32 GiB plus 8 GiB of dynamic headroom, uses disk-backed offload, and is terminated by the shared launcher if `MemAvailable` falls below 24 GiB.

The canonical application is the stable `v0.29.2` checkout at `~/ComfyUI`, with an isolated environment at `~/venvs/comfyui-0.29.2`. Models live outside the Git checkout at `~/models/comfyui` and are registered by `comfyui-extra-model-paths.yaml`; do not replace the checkout's tracked `models/` directory with a symlink. Install custom-node requirements with `constraints/comfyui-0.29.2.txt` so LTX Video retains its required Kornia API.

Use `scripts/run-comfyui-canary` for the low-risk acceptance image. It runs the existing 2 GiB SD 1.5 checkpoint at 512 px, requests `/free`, and stops a service it started. The much larger FLUX.2 Dev workflow is a separate high-memory gate and must not be used as the first post-upgrade test.

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
