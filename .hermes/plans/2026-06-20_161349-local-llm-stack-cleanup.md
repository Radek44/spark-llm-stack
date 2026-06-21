# Local LLM stack cleanup and June 2026 best-practice rebuild plan

## Goal

Clean up the current DGX Spark local LLM setup and evolve it into a safer, faster, maintainable hybrid local/frontier agent stack aligned with the end-of-June-2026 direction in the provided notes:

- DGX Spark remains the private always-on local agent/runtime box.
- vLLM becomes the primary local serving path for NVIDIA-optimized models.
- llama.cpp remains available as a proven fallback/bench harness where it is already stable.
- Hermes Agent remains the personal/project agent layer.
- LiteLLM becomes the single routing gateway for local and paid API models.
- NemoClaw/OpenShell become the desired security boundary before giving agents broad file/shell/network authority.
- No multiple heavyweight checkpoint services run at the same time.
- All changes are staged, benchmarked, reversible, and memory-safe.

## Current context observed on 2026-06-20 16:13

Read-only checks performed:

- Host memory: `121Gi` total, `36Gi` used, `85Gi` available, `15Gi` swap free.
- Running model process: one llama-server service:
  - `qwen35-mtp.service`
  - model: `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Q4_K_XL`
  - port: `8154`
  - alias: `qwen3.6-35b-architect`
  - effective tuned runtime args already include `-b 4096 -ub 1024 --threads 16 --threads-batch 24 --presence-penalty 0.0`.
- Hermes CLI is currently running, so do not restart or disrupt the active model/session during implementation without explicit approval.
- User services visible:
  - `qwen35-mtp.service`: active/running and enabled at boot.
  - `qwen27-mtp.service`: inactive/disabled.
  - `gemma-31b.service`, `gemma-vision.service`, `gptoss-20b.service`, `flux-klein.service`, `comfyui.service`: disabled.
  - `hermes-gateway.service`: enabled but currently auto-restarting.
- Existing hardening is present and effective for `qwen35-mtp.service`:
  - `MemoryHigh=70G`, `MemoryMax=80G`, `OOMPolicy=stop`, `Restart=on-failure`, heavyweight `Conflicts=...`.
- Repo status has 10 existing modified files before this plan:
  - `drop-ins/gemma-31b.service.d/override.conf`
  - `drop-ins/gptoss-20b.service.d/override.conf`
  - `drop-ins/qwen27-mtp.service.d/override.conf`
  - `drop-ins/qwen35-mtp.service.d/override.conf`
  - `flux-klein.service`
  - `gemma-31b.service`
  - `gemma-vision.service`
  - `gptoss-20b.service`
  - `qwen27-mtp.service`
  - `qwen35-mtp.service`

Relevant existing repo files:

- `README.md`: documents current llama.cpp-first stack, llm-switch, hardening, and FLUX.2-klein.
- `POSTMORTEM.md`: documents the prior OOM boot-loop incident and required safety practices.
- `llm-switch`: current service switcher with runtime and boot-state management.
- `harden-llm-stack.sh`: applies user/system drop-ins for memory caps, OOM policy, and conflicts.
- `hermes-config-snippet.yaml`: currently points Hermes directly at local llama.cpp services on ports `8152` and `8154`.
- `qwen35-mtp.service`, `qwen27-mtp.service`, `gemma-31b.service`, `gptoss-20b.service`, `gemma-vision.service`, `flux-klein.service`: systemd units.

## Important assumptions and constraints

- [ASSUMPTION] NVIDIA's June 2026 DGX Spark guidance in the attached notes is accurate: vLLM with `nvidia/Qwen3.6-35B-A3B-NVFP4` is the preferred local model-serving baseline for Hermes on DGX Spark.
- [ASSUMPTION] NemoClaw/OpenShell packages/docs are available on this machine or via NVIDIA's current DGX OS tooling. The implementation phase must verify exact install commands before applying them.
- [ASSUMPTION] The existing llama.cpp stack is still worth keeping as a fallback because it is already working, hardened, and tuned on this host.
- Do not run more than one heavyweight checkpoint model simultaneously.
- Do not restart the currently active model while Hermes is using it unless the user explicitly approves a planned maintenance window.
- Make config-only changes first where possible; defer restarts to explicit switch/test steps.
- Preserve the OOM lessons from `POSTMORTEM.md`: no parallel boot autostart, no `--no-mmap`, no `--mlock`, cgroup caps on every memory-heavy service, `OOMPolicy=stop`, and systemd-level mutual exclusion.
- Do not put API keys in repo files; secrets stay in `~/.hermes/.env`, LiteLLM env, or credential stores.

## Target architecture

```text
DGX Spark local AI appliance
├── System safety baseline
│   ├── no heavyweight parallel autostart
│   ├── cgroup MemoryHigh/MemoryMax on every model service
│   ├── systemd Conflicts for heavyweight services
│   ├── llm-switch / ai-stack switcher with health checks
│   └── memory telemetry before and after each switch
├── Primary local serving
│   ├── vLLM service: nvidia/Qwen3.6-35B-A3B-NVFP4
│   ├── optional vLLM/NIM service: Nemotron 3 Nano/Super
│   └── OpenAI-compatible localhost endpoints only
├── Fallback/local specialists
│   ├── existing llama.cpp qwen35 architect fallback
│   ├── existing llama.cpp qwen27 coder fallback or retire after vLLM benchmark
│   ├── FLUX.2-klein direct sd.cpp service / subprocess path
│   └── ComfyUI manual-only for workflows, not autostart
├── Routing layer
│   ├── LiteLLM single gateway on localhost
│   ├── aliases: fast_local, private_local, code_frontier, research, cheap_cloud
│   ├── fallback policy local -> frontier only where allowed
│   └── budget/logging controls
├── Agent layer
│   ├── Hermes CLI/TUI/Desktop
│   ├── Hermes Gateway/Telegram with allowlisted user IDs
│   ├── Hermes cron jobs and memory/skills
│   └── Hermes provider config points to LiteLLM aliases, not raw model ports
├── Security boundary
│   ├── NemoClaw/OpenShell policy for long-running/high-authority agents
│   ├── file allowlists for /srv/ai and selected repos
│   ├── network allowlists for docs/GitHub/package registries/selected APIs
│   └── approval gates for write/delete/install/push/send actions
└── RAG/UI layer
    ├── Qdrant
    ├── local embedding model
    ├── document ingestion directory
    ├── Open WebUI or AnythingLLM
    └── optional LibreChat if multi-provider browser UI is desired
```

## Proposed approach

Use a staged migration rather than a big-bang rewrite:

1. Freeze and document the current working llama.cpp setup.
2. Tighten safety and cleanup obvious stale pieces.
3. Add vLLM as a new manual-only service on a new port.
4. Benchmark vLLM against the current llama.cpp architect service.
5. Add LiteLLM as the stable routing front door.
6. Point Hermes to LiteLLM aliases after the router is tested.
7. Add NemoClaw/OpenShell policy before granting always-on agents wider authority.
8. Add RAG/UI services after the inference/routing layer is stable.
9. Retire or archive superseded llama.cpp units only after vLLM proves better in real use.

## Step-by-step implementation plan

### Phase 0 — preflight and backup

1. Capture baseline state:
   - `git status --short`
   - `free -h`
   - `systemctl --user list-units --type=service --all | grep -Ei 'qwen|gemma|gptoss|flux|comfy|vllm|litellm|hermes'`
   - `systemctl --user list-unit-files | grep -Ei 'qwen|gemma|gptoss|flux|comfy|vllm|litellm|hermes'`
   - `ps aux | grep -E 'llama-server|vllm|ollama|litellm|hermes' | grep -v grep`
   - `journalctl --list-boots | tail -10`
   - `journalctl --since '24h ago' -k | grep -iE 'oom|killed process|out of memory' || true`
2. Export effective systemd configs for every current model service:
   - `systemctl --user cat qwen35-mtp.service`
   - `systemctl --user cat qwen27-mtp.service`
   - `systemctl --user cat gemma-31b.service`
   - `systemctl --user cat gptoss-20b.service`
   - `systemctl --user cat gemma-vision.service`
   - `systemctl --user cat flux-klein.service`
   - `systemctl --user cat comfyui.service`
3. Save backups outside the repo, e.g. under `~/backups/spark-llm-stack/YYYY-MM-DD_HHMMSS/`:
   - `~/.config/systemd/user/*.service`
   - `~/.config/systemd/user/*.service.d/override.conf`
   - `~/.hermes/config.yaml` with secrets reviewed/redacted before any sharing
   - LiteLLM config if already present
4. Confirm boot safety before any new service is added:
   - Either keep exactly one safe default (`qwen35-mtp`) or switch to no model autostart.
   - Preferred during migration: `llm-switch boot-safe`, then manually start services during tests.
5. Do not stop/restart the currently running `qwen35-mtp.service` until an agreed test window.

### Phase 1 — repo cleanup and safety normalization

1. Update the repo to reflect reality and June 2026 target direction:
   - `README.md`: change from llama.cpp-first to hybrid vLLM-first + llama.cpp fallback.
   - `README.md`: move old May 2026 benchmark numbers into a legacy/current-baseline section.
   - `POSTMORTEM.md`: keep as required safety doctrine; add a short note that all new vLLM/NIM/LiteLLM services must follow the same boot/OOM constraints.
2. Normalize service units in the repo before copying them into `~/.config/systemd/user`:
   - Remove `GGML_CUDA_FORCE_CUBLAS_COMPUTE_16F=1` from quality-critical GB10 llama.cpp services unless benchmarking shows it is needed.
   - Keep `CUDA_SCALE_LAUNCH_QUEUES=4x` and `GGML_CUDA_GRAPH_OPT=1` for llama.cpp services.
   - Ensure `qwen35-mtp.service` repo file matches the effective tuned runtime currently running:
     - `-b 4096`
     - `-ub 1024`
     - `--threads 16`
     - `--threads-batch 24`
     - `--presence-penalty 0.0`
   - Apply the same batch/thread cleanup to `qwen27-mtp.service`, `gemma-31b.service`, and `gptoss-20b.service` unless a model-specific benchmark justifies otherwise.
   - For `flux-klein.service`, consider `--type bf16 --max-vram 90` if supported by the installed stable-diffusion.cpp build; verify with `sd-server --help` first.
3. Update `harden-llm-stack.sh`:
   - Add future `vllm-qwen36-35b-nvfp4.service`, `vllm-nemotron.service`, and `litellm.service` entries where applicable.
   - Ensure all heavyweight vLLM/NIM/llama.cpp services conflict with each other by default.
   - Keep RAG/UI services separate from heavyweight model conflict pool unless they load large GPU checkpoints.
4. Update `llm-switch` or replace it with a broader `ai-stack` switcher:
   - Add slots for `vllm-local`, `llama-architect`, `llama-coder`, `nemotron`, `rag`, `imagine`, `comfyui`.
   - Keep existing user muscle memory: `llm-switch architect`, `llm-switch off`, `llm-switch status`, `llm-switch boot-safe`.
   - Add memory gate before starting any heavyweight service: if `MemAvailable` is below a threshold, stop and print clear instructions.
   - Remove or hard-disable `llm-switch both` by default, or require an explicit `--unsafe` flag.

### Phase 2 — install/verify vLLM baseline without disrupting current service

1. Verify prerequisites:
   - DGX OS / NVIDIA Sync status.
   - NVIDIA driver and CUDA versions.
   - Python version and current PyTorch CUDA support.
   - Whether vLLM already exists in a venv/container.
2. Prefer containerized vLLM if NVIDIA's DGX Spark recipe provides a maintained image for GB10/NVFP4; otherwise create a dedicated venv under a clear path such as:
   - `/opt/ai/vllm` for system-managed install, or
   - `~/src/vllm-gb10` / `~/venvs/vllm-gb10` for user-managed install.
3. Add a manual-only user service:
   - `vllm-qwen36-35b-nvfp4.service`
   - localhost only, e.g. port `8170`.
   - model: `nvidia/Qwen3.6-35B-A3B-NVFP4`.
   - no autostart initially.
   - cgroup memory cap, OOM policy, restart limit, and heavyweight conflicts.
4. Before first start, stop other heavyweight services during an approved maintenance window:
   - `llm-switch off`
   - confirm `free -h` and `ps aux` show no model checkpoint still resident.
5. Start vLLM manually and verify:
   - service reaches healthy state.
   - `curl http://127.0.0.1:8170/v1/models` works.
   - a short chat completion works.
   - memory stays within cap.
6. Benchmark against existing llama.cpp qwen35 service using the same prompts:
   - short technical answer.
   - coding patch prompt.
   - long-context summarization prompt.
   - tool-call-style JSON response if supported.
7. Record results in a new repo doc, e.g. `benchmarks/2026-06-20-vllm-vs-llamacpp.md`.
8. Only after vLLM is stable, decide whether it becomes the boot default or remains manual-only.

### Phase 3 — LiteLLM routing layer

1. Create a LiteLLM config, likely `litellm/config.yaml` in repo as a template with no secrets.
2. Add aliases:
   - `fast_local`: vLLM `nvidia/Qwen3.6-35B-A3B-NVFP4` on port `8170`.
   - `private_local`: local-only route; initially same vLLM model, later Nemotron/Qwen local.
   - `llama_architect_fallback`: existing llama.cpp qwen35 on port `8154`.
   - `llama_coder_fallback`: existing llama.cpp qwen27 on port `8152` if retained.
   - `code_frontier`: OpenAI/Anthropic API via env-provided keys.
   - `research`: OpenAI API or a placeholder that reminds the user to use ChatGPT Deep Research manually when not API-backed.
   - `cheap_cloud`: OpenRouter or hosted open-model route if configured.
3. Add a local-only `litellm.service`:
   - bind to `127.0.0.1`, e.g. port `8180`.
   - start after network.
   - restart on failure.
   - no GPU checkpoint in the service itself, so no heavyweight conflict required.
4. Configure fallback carefully:
   - Private aliases must never fall back to cloud.
   - Frontier aliases may use OpenAI/Anthropic only when explicitly selected.
   - Do not silently send local/private tasks to cloud.
5. Verify:
   - `/v1/models` through LiteLLM.
   - `fast_local` completion.
   - local backend failure behavior.
   - no secrets printed in logs.

### Phase 4 — Hermes integration

1. Update `hermes-config-snippet.yaml`:
   - Replace direct raw llama.cpp providers with LiteLLM aliases.
   - Keep raw providers in a fallback/debug section, commented or clearly marked.
   - Increase local `extra_body.max_tokens` from `4096` to at least `16384` for normal tool use; use `65536` where the model and context support it.
2. Update actual `~/.hermes/config.yaml` only after backing it up and with user approval.
3. Ensure Hermes has model aliases aligned with usage:
   - `/model fast_local` for local routine agent work.
   - `/model private_local` for private docs/data.
   - `/model code_frontier` for frontier coding through API when desired.
4. Fix or investigate `hermes-gateway.service` auto-restart separately:
   - inspect `~/.hermes/logs/gateway.log`.
   - check `systemctl --user status hermes-gateway.service`.
   - verify Telegram allowed user IDs and credentials.
5. Do not restart Hermes gateway or current CLI session mid-task unless approved; prepare commands and execute in a maintenance window.

### Phase 5 — NemoClaw/OpenShell security boundary

1. Verify current NVIDIA/DGX OS installation path for NemoClaw/OpenShell.
2. Install only after reviewing official docs and package source.
3. Create a conservative default policy:
   - Allow files:
     - `/srv/ai/inbox`
     - `/srv/ai/projects`
     - selected cloned repos explicitly named by the user
   - Deny files:
     - `~/.ssh`
     - browser profiles
     - password stores
     - broad home directory access
     - `.env` files unless explicitly approved for a task
   - Allow network:
     - GitHub
     - docs sites
     - package registries
     - configured APIs
   - Deny network:
     - LAN scanning
     - cloud metadata endpoints
     - arbitrary exfiltration-like destinations
   - Shell policy:
     - allow read/list/search/git status by default
     - require approval for write/delete/install/push/send
     - deny credential scraping patterns
4. Run Hermes long-lived/high-authority modes through this boundary once stable.
5. Keep normal supervised CLI development usable; do not over-sandbox interactive pairing unless the user wants that.

### Phase 6 — RAG and UI layer

1. Pick one primary local RAG/UI path first:
   - Open WebUI for general local-model chat and family/internal usage, or
   - AnythingLLM for easier document collections, or
   - LibreChat if multi-provider browser UI is important.
2. Add Qdrant as local vector store:
   - bind localhost or Tailscale-only.
   - persistent data under `/srv/ai/qdrant` or another explicitly approved path.
3. Choose local embeddings:
   - start with a compact embedding model that does not load a huge checkpoint concurrently with Qwen.
   - benchmark ingestion/search quality later.
4. Create document ingestion directories:
   - `/srv/ai/inbox`
   - `/srv/ai/rag`
   - `/srv/ai/projects`
5. Add service units only after inference/LiteLLM is stable.
6. Validate that private RAG queries route through `private_local` only.

### Phase 7 — cleanup and retirement

1. After vLLM has passed real workload tests, decide what to retire:
   - Keep `qwen35-mtp.service` as known-good fallback for one release cycle.
   - Retire or archive `qwen27-mtp.service` if vLLM Qwen is faster/better for coding.
   - Retire `gemma-31b.service` if it is not materially useful.
   - Keep `gemma-vision.service` only if it fills a local multimodal gap.
   - Keep `gptoss-20b.service` only if it is faster/cheaper for a real route.
   - Keep `flux-klein.service` as the direct image path; keep ComfyUI manual-only.
2. Move retired units to an `archive/` directory in repo rather than deleting immediately.
3. Update `README.md` to show the new recommended default and legacy fallback.
4. Update `POSTMORTEM.md` and/or a new `OPERATIONS.md` with recovery commands.

## Files likely to change

Repo files:

- `README.md`
  - Reframe stack as vLLM-first + LiteLLM + Hermes + NemoClaw/OpenShell.
  - Preserve llama.cpp fallback and safety guidance.
- `POSTMORTEM.md`
  - Add a note that the same OOM/boot-loop rules apply to vLLM/NIM/RAG GPU services.
- `llm-switch`
  - Add vLLM/Nemotron/LiteLLM awareness or reduce to model-only switching with no unsafe `both` default.
- `harden-llm-stack.sh`
  - Add vLLM/NIM services to safety policy.
  - Keep current cgroup/OOM patterns.
- `hermes-config-snippet.yaml`
  - Replace raw model endpoints with LiteLLM alias guidance.
- Existing service files:
  - `qwen35-mtp.service`
  - `qwen27-mtp.service`
  - `gemma-31b.service`
  - `gptoss-20b.service`
  - `gemma-vision.service`
  - `flux-klein.service`
- Existing drop-ins:
  - `drop-ins/*.service.d/override.conf`
- New likely files:
  - `vllm-qwen36-35b-nvfp4.service`
  - `vllm-nemotron.service` if installed
  - `litellm.service`
  - `litellm/config.example.yaml`
  - `docs/OPERATIONS.md` or `OPERATIONS.md`
  - `benchmarks/2026-06-20-vllm-vs-llamacpp.md`
  - optional `archive/` for retired unit files

External/user config files to modify only with explicit approval and backup:

- `~/.config/systemd/user/*.service`
- `~/.config/systemd/user/*.service.d/override.conf`
- `~/.hermes/config.yaml`
- `~/.hermes/.env`
- LiteLLM runtime config path if outside repo
- NemoClaw/OpenShell policy files

## Tests and validation

### Safety validation

- `free -h` before and after every model switch.
- `systemctl --user list-unit-files | grep -Ei 'qwen|gemma|gptoss|flux|comfy|vllm|litellm'` shows no unsafe multi-model autostart.
- `systemctl --user show <service> -p MemoryHigh,MemoryMax,OOMPolicy,Restart,Conflicts` for every heavyweight service.
- `journalctl --since '24h ago' -k | grep -iE 'oom|killed process|out of memory' || true` stays clean.
- `journalctl --list-boots | tail -10` shows no reboot loop.

### Service validation

For each local OpenAI-compatible endpoint:

- `curl -s http://127.0.0.1:<port>/v1/models`
- short non-streaming chat completion.
- streaming chat completion if expected.
- metrics endpoint where available.
- systemd restart behavior on deliberate stop/start.

For LiteLLM:

- `curl -s http://127.0.0.1:8180/v1/models`
- call each alias explicitly.
- verify private aliases do not fall back to cloud.
- verify cloud aliases fail clearly when keys are absent rather than silently rerouting.

For Hermes:

- `hermes config check`
- `hermes doctor`
- one short CLI query through `fast_local`.
- one tool-using query through `fast_local`.
- gateway status after fixing/restarting in approved window.

### Benchmark validation

Use the same prompts across llama.cpp and vLLM:

- 200-token technical explanation.
- 1,000-token code review / patch planning prompt.
- long-context repo/doc summary.
- JSON/tool-call-style response.

Record:

- prompt tokens/sec.
- generated tokens/sec.
- first-token latency.
- memory used / MemAvailable after load.
- qualitative instruction following.
- tool-call formatting reliability.
- crash/OOM/log anomalies.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| vLLM/NVFP4 install path is not mature on GB10 | Install as manual-only service first; keep llama.cpp fallback untouched. |
| OOM or memory pressure during migration | Stop heavyweight services before vLLM tests; enforce MemoryMax/OOMPolicy/Conflicts; check `free -h`. |
| Active Hermes session depends on running qwen35 | Do not restart qwen35 until user approves a maintenance window. |
| LiteLLM accidentally sends private data to cloud | Define `private_local` with no cloud fallback; test backend failure behavior. |
| Gateway exposes agent to unauthorized users | Restrict platform user IDs; review logs; do not enable public endpoints. |
| NemoClaw/OpenShell install details differ from notes | Verify official docs before install; mark unresolved commands as `[NEEDS_RESEARCH]` until confirmed. |
| Existing repo has uncommitted changes | Inspect diffs before editing; avoid overwriting unrelated user work. |
| Service files and effective systemd files drift | Use `systemctl --user cat` and update repo/system copies deliberately. |

## Open questions for the user before execution

1. Should the new default be `vLLM Qwen3.6-35B-A3B-NVFP4` as soon as it benchmarks well, or should `qwen35-mtp.service` remain the boot default until several days of testing?
2. Do you want all heavyweight model services manual-only at boot during migration, or keep `qwen35-mtp.service` as the single autostart default?
3. Which UI should be installed first: Hermes Desktop, Open WebUI, AnythingLLM, or LibreChat?
4. Should LiteLLM be local-only initially, or should OpenAI/Anthropic API routes be configured in the first pass?
5. Which directories should NemoClaw/OpenShell allow Hermes to access by default?
6. Should old Gemma/GPT-OSS services be archived aggressively after vLLM is stable, or retained as experimental slots?

## Recommended first execution batch

If approved, the safest first batch is:

1. Backup current systemd and Hermes configs.
2. Set migration boot policy to no heavyweight autostart or one explicit default.
3. Update repo docs and service templates to reflect the new architecture.
4. Add vLLM service template and hardening, but do not enable it.
5. Add LiteLLM config template and service template, but do not route Hermes through it yet.
6. Run a controlled maintenance-window test of vLLM with qwen35 stopped.
7. Benchmark and report before changing the default provider.

This keeps the current working local model intact while creating the path to the stronger June 2026 setup.
