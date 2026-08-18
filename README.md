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
├── SGLang                       # alternate local model, mutually exclusive
│   └── RadixArk/Qwen3.8-27B-NVFP4 + DSpark on :8171  (qwen38)
├── LiteLLM                      # local router on :8180
│   ├── fast_local / private_local
│   ├── qwen38
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
| `qwen38` | `sglang-qwen38-nvfp4.service` | `RadixArk/Qwen3.8-27B-NVFP4` + DSpark | 8171 | Alternate local LLM (conflicts with `fast_local`) |
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

## SGLang Qwen3.8-27B service

Template: `sglang-qwen38-nvfp4.service`. Launcher: `scripts/run-sglang-qwen38`.

```text
http://127.0.0.1:8171/v1
served model alias: qwen38
model: RadixArk/Qwen3.8-27B-NVFP4  (pinned 52d1adc5...)
draft: RadixArk/Qwen3.8-27B-DSpark (pinned 923ed3a8..., 1.36B BF16)
```

Qwen3.8-27B is a dense 27B hybrid (Gated DeltaNet + Gated Attention, 64 layers), multimodal,
Apache 2.0, 262,144 native context.

### Why SGLang

The engine was chosen on **supportedness**, not on a benchmark. The NVFP4 model card names
SGLang as its serving engine, and the DSpark draft card states the speculator was trained
with SpecForge and is served with SGLang, down to the exact flags. That is the whole
argument, and it is enough on its own.

What is **measured here on this GB10**, from the acceptance canary and the engine's own
telemetry, is the SGLang row only:

| Stack | Decode (batch-1) | Provenance |
|---|---:|---|
| SGLang + NVFP4 + DSpark | 27.9-40.6 tok/s | measured on this machine |
| llama.cpp + MTP | unmeasured | never run here |
| vLLM + DSpark | unmeasured | supported, never run here |

Two corrections to earlier drafts of this file, recorded so they are not repeated:

- An earlier table quoted llama.cpp+MTP at ~27 tok/s and vLLM+MTP at ~24.5 tok/s as though
  measured. **They were not measured on this hardware** and should not be cited as if they
  were. The published NVFP4 benchmarks are on 4x B300/GB300 with TP4, which says nothing
  about a single GB10.
- vLLM was described as limited to MTP. That is **false**: vLLM 0.26.0, already installed
  here and already serving Laguna, implements both `dspark` and `dflash`. vLLM is a
  legitimate alternative runtime for this checkpoint; it simply is not the one the model
  card documents, and it has not been benchmarked here. Laguna already runs DFlash on vLLM
  on this box, so the mechanism is known to work on GB10.

Decode rate is strongly content-dependent — math/reasoning 42-47, code 26-41, free prose
12-18 tok/s — because DSpark acceptance varies with how predictable the text is. Non-English
prose degrades sharply (German drops to roughly 1.3-1.5 accepted tokens per verify step
against 4.4-4.8 for structured English). Benchmark on your own workload, not on a headline.

### Configuration constraints

The launcher refuses unsafe values rather than starting a service that looks healthy:

- **`--attention-backend flashinfer`, not `fa3`.** The generic SGLang cookbook selects `fa3`
  plus the FP8 checkpoint; both are Hopper-tuned and are the wrong choice on sm_121.
- **`SGLANG_ENABLE_JIT_DEEPGEMM` is left at its default (on), deliberately.** Advice circulates
  to set it to `0` on DGX Spark because JIT DeepGEMM can crash on this architecture. The
  premise is half right: SGLang's own guard excludes `sm_version == 120`, and GB10 reports
  **121**, so the flag really is enabled here. It is nonetheless inert for this checkpoint.
  Checked 2026-08-17: the model declares `quant_method: modelopt`, so it loads through
  `modelopt_quant`, which contains zero `deep_gemm` references; DeepGEMM serves the
  blockwise-FP8 and MoE grouped-GEMM paths, and this is a dense model with
  `USE_DEEPGEMM_MEGA_MOE=False` and `USE_DEEPGEMM_BMM=False`. After 20+ hours of uptime and a
  full canary there is no DeepGEMM JIT cache anywhere on the box -- every compiled `.cubin`
  under `~/.cache/sglang/triton/` came from the torch.compile path. Setting it to `0` would
  change nothing measurable, so it is not set. Revisit if the checkpoint ever moves to
  blockwise FP8 or a MoE architecture.

  Worth knowing when reading that advice: this checkpoint is **not** uniformly NVFP4. It has
  two quant groups -- 208 targets at FP8 W8A8 (the `linear_attn` / Gated DeltaNet projections)
  and 193 at NVFP4 W4A4, group size 16.
- **`--mem-fraction-static 0.50`.** Higher values either fail CUDA graph capture or fall back
  to eager mode *silently*, costing roughly 25% throughput with no error. Override only via
  `QWEN38_ALLOW_LARGER_MEM_FRACTION=true` under a monitored gate.
- **Context 262,144** — the model's native maximum, promoted from 65,536 on 2026-08-17
  after a measured gate (`acceptance/qwen38-27b-context-262144-20260817.json`).
  The promotion was nearly free because the KV pool is sized from `mem-fraction-static`
  at startup and is independent of context length: it did not shrink (408,653 -> 416,882
  tokens), and the 1.6 GB that went away was CUDA graph capture. Needle retrieval was
  exact at 231,822 tokens with `MemAvailable` never below 38.63 GiB against a 20 GiB floor.
  The binding cost is *time*, not memory, and it is concentrated entirely in prefill.
  Measured 2026-08-17 (`acceptance/qwen38-27b-longcontext-profile-20260817.json`):
  decode falls only 21.9 -> 16.4 tok/s from 2k to 223k tokens, while prefill throughput
  falls 2,256 -> 711 tok/s and TTFT goes superlinear (0.9s -> 313s). At 223k, 93% of
  wall clock is prefill. DSpark acceptance is flat with depth (~2.6), so the slowdown is
  attention cost, not speculative collapse.

  **So do not minimize prompt size -- minimize prefix churn.** An identical prefix turns
  98k tokens of prefill into 0.53s, a 171x speedup. Changing a single token near the top
  of that prompt forfeits all 90 seconds, even with 99.9% of the content unchanged: reuse
  is near-total but strictly prefix-anchored. Anything that mutates the head of the prompt
  per attempt -- embedded timestamps, retry counters, elapsed-time banners, reordered tool
  lists, a rotating system preamble -- pays full prefill every attempt.
  `QWEN38_ALLOW_LARGER_CONTEXT=true` now only gates going *beyond* native, which would
  need RoPE scaling this service does not configure.
- **`HF_HUB_OFFLINE=1` is rejected.** SGLang performs a remote probe at startup and hard-fails
  offline even with every weight cached.
- **Container capped at `--memory=100g`**, matching the systemd budget, and removed via
  `ExecStopPost` so a stray container cannot hold the GPU after the slot reads as free.

Cold start takes roughly nine minutes for torch.compile plus CUDA graph capture; the unit
allows 30. This is not a hang.

### Docker prerequisite

The legacy `nvidia` runtime is **not** registered with Docker here, and does not need to be.
Docker 29 exposes the GPU through CDI instead — `docker info` lists `cdi: nvidia.com/gpu=all`
from `/var/run/cdi/nvidia.yaml` — so plain `--gpus all` resolves without any daemon change.
Verified: `docker run --rm --gpus all ubuntu:24.04 nvidia-smi -L` prints the GB10.

This means **no `nvidia-ctk runtime configure` and no `systemctl restart docker`** — the
Asset Forge containers never need to be bounced to run this service.

The launcher checks passthrough and exits 78 with the fix rather than failing obscurely
inside the container. It matches `cdi: nvidia.com/gpu=all` or a real `Runtimes: … nvidia`
entry specifically — a bare `grep nvidia` over `docker info` is a false pass, since
`Kernel Version: 6.17.0-1029-nvidia` matches on a host with no GPU support at all.

### Acceptance

```bash
llm-switch qwen38
scripts/run-qwen38-canary          # live: measures, writes acceptance/*.json, asserts floors
scripts/validate-qwen38-acceptance # replay: re-checks a recorded report and its journal
```

The canary asserts a decode floor rather than just HTTP 200, because the eager-mode fallback
is silent. It also exercises tool calls, thinking mode, vision, LiteLLM routing, and the two
known chat-template breakages for OpenAI-compatible clients (mid-conversation system messages
and `reasoning_effort: high`) — both of which the Pi harness triggers.

### Pi harness (runs on the Mac, not here)

Pi is a BYOK CLI coding agent driving this stack over an SSH tunnel. The router binds
`127.0.0.1` only, so the tunnel is the sole path in — add to the Mac's `~/.ssh/config`:

```
Host spark
  LocalForward 8180 127.0.0.1:8180
  ExitOnForwardFailure no        # a second ssh session must not fail on a busy port
```

Then `~/.pi/agent/models.json` on the Mac defines one `litellm` provider at
`http://127.0.0.1:8180/v1` with `qwen38`, `fast_local`, and `private_local`.
(`small_coder` is gone — that route was disabled and unreachable on `:8190`.)

The `reasoning_effort` breakage is fixed **client-side**, not by patching the chat template.
Pi's `thinkingFormat: "chat-template"` moves the field out of the top-level OpenAI body and
into `chat_template_kwargs`, where Qwen3.8's template accepts it:

```json
"compat": {
  "supportsReasoningEffort": false,
  "thinkingFormat": "chat-template",
  "chatTemplateKwargs": {
    "enable_thinking":  { "$var": "thinking.enabled" },
    "reasoning_effort": { "$var": "thinking.effort", "omitWhenOff": true }
  }
}
```

A `thinkingLevelMap` also clamps Pi's `xhigh`/`max` levels down to the `low|medium|high` the
model actually understands. Preferring the client fix keeps the checkpoint stock, so a model
revision bump does not silently re-break the harness.

Sampling follows the model card: thinking `temp 1.0 / top_p 0.95 / top_k 20`; the instruct
profile is `temp 0.7 / top_p 0.80 / top_k 20 / presence_penalty 1.5`. The config carries the
thinking profile, since `reasoning: true` is the default path for agent work.

```bash
ssh -fN spark        # bring the tunnel up
pi --provider litellm --model qwen38
```

---

## LiteLLM gateway

Template service: `litellm.service`.
Template config: `litellm/config.example.yaml`.

Recommended aliases:

| Alias | Route | Cloud fallback? |
|---|---|---|
| `fast_local` | vLLM Laguna S 2.1 NVFP4 on `:8170` | No |
| `private_local` | same local-only route for private docs/data | No |
| `qwen38` | SGLang Qwen3.8-27B NVFP4 on `:8171` | No |
| `code_frontier` | OpenAI API, only if configured privately | Explicit only |
| `claude_frontier` | Anthropic API, only if configured privately | Explicit only |

`fast_local`/`private_local` and `qwen38` are mutually exclusive: only one heavyweight
checkpoint runs at a time, so exactly one of `:8170` and `:8171` answers. Requests to the
idle alias fail rather than silently rerouting. Switch with `llm-switch`.

Do not silently fall back from private/local aliases to cloud providers.
The router uses a 1,200-second local inference timeout and does not silently drop unsupported request parameters; thinking and tool controls must either reach vLLM or fail visibly.

---

## Installation / update

```bash
mkdir -p ~/.config/systemd/user
cp vllm-laguna-s21-nvfp4.service sglang-qwen38-nvfp4.service litellm.service \
  flux-klein.service comfyui.service \
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
llm-switch qwen38        # SGLang Qwen3.8-27B NVFP4 + DSpark (stops Laguna)
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
| `sglang-qwen38-nvfp4` | 100G | 108G | 0 |
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
