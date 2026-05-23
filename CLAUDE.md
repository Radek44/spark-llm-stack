# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A systemd user-service LLM inference stack for NVIDIA DGX Spark GB10 (Grace Blackwell, aarch64, SM 12.1). The primary tools are:

- `llm-switch` — runtime service manager; starts one slot, stops all others
- `harden-llm-stack.sh` — generates systemd drop-ins (memory caps, OOM policy, `Conflicts=`)
- `flux-gen` — CLI wrapper for the FLUX.2-klein async image API
- `docker-llm-switch` — Docker-native mirror of `llm-switch`; manages `spark-llm-*` containers

## Key architectural constraint

Running multiple heavyweight services simultaneously exhausts 128 GB unified memory and causes an OOM respawn brick loop (see `reference-previous/POSTMORTEM.md`). `harden-llm-stack.sh` applies `Conflicts=` drop-ins to enforce mutual exclusion at the systemd level. `docker-llm-switch` enforces the same via `stop_all_except` before every `docker run`.

## How slots are defined (the mirroring pattern)

Each model slot (e.g. `coder`) is defined in **four parallel places** that must stay in sync when adding or changing a slot:

| File | Role |
|---|---|
| `systemd/units/*.service` | Systemd unit; `ExecStart` is the authoritative arg set |
| `systemd/llm-switch` | `SVCS[]`, `PORTS[]`, `ROLES[]` maps + wait logic |
| `docker/docker-llm-switch` | `CMD_<slot>` array mirrors `ExecStart` with `--host 0.0.0.0`; `IMAGE[<slot>]` picks which image runs the slot |
| `systemd/harden-llm-stack.sh` | `SERVICES=()` array with `MemoryHigh/Max` and heavyweight flag |

Llama slots all share `spark-llm-stack`. The `imagine` and `comfyui` slots use their own images (`spark-llm-imagine` from `docker/sd-server/`, `spark-llm-comfyui` from `docker/comfyui/`) — set in `IMAGE[]` in `docker/docker-llm-switch`. The Dockerfile `CMD` is the coder-slot default only (not per-slot); `docker/run.sh` is a thin wrapper that delegates to `docker-llm-switch`.

## Installation workflow

Service files use `%h` (systemd home specifier) and must be installed before use:

```bash
cp systemd/units/*.service ~/.config/systemd/user/
# Edit ExecStart binary path in each .service (default: %h/src/llama.cpp-mtp/build/bin/llama-server)
bash systemd/harden-llm-stack.sh  # generates drop-ins in ~/.config/systemd/user/*.d/
systemctl --user daemon-reload
cp systemd/llm-switch tools/flux-gen ~/.local/bin/ && chmod +x ~/.local/bin/llm-switch ~/.local/bin/flux-gen
```

The `reference-previous/drop-ins/` directory is a **reference copy** of the generated drop-ins. The live drop-ins are at `~/.config/systemd/user/<unit>.d/override.conf`. `systemd/harden-llm-stack.sh` writes (and reverts) those live files directly.

## MTP binary note

Service files point to `%h/src/llama.cpp-mtp/build/bin/llama-server` (pre-merge MTP branch), not mainline. Mainline llama.cpp currently underperforms on GB10 (~23 vs ~28 t/s). The Dockerfile builds from `LLAMA_REF=master` by default — override with `--build-arg LLAMA_REF=<commit>` to pin the MTP branch.

## Flags that must never appear in service files

- `--no-mmap` — forces weights into anonymous pages (not evictable on unified memory)
- `--mlock` — pins the model permanently, starving other services

## Build flags (GB10-specific)

`121a-real` is required for native SASS. Using `121` alone generates generic PTX and incurs JIT overhead at load time. The `stable-diffusion.cpp` build (FLUX) uses `121` — that's intentional, it's not a GB10-optimised build.

## Docker workflow

```bash
# Build all three images (llama / sd-server / comfyui)
docker compose -f docker/docker-compose.yml build

cp docker/docker-llm-switch ~/.local/bin/ && chmod +x ~/.local/bin/docker-llm-switch
./docker/run.sh                   # coder slot (llama)
./docker/run.sh imagine           # FLUX.2-klein via sd-server
./docker/run.sh comfyui           # ComfyUI on :8188
docker-llm-switch status          # manage running containers
```

All seven slots (coder/architect/gemma/vision/gptoss/imagine/comfyui) are now in the Docker path. `imagine` and `comfyui` have their own Dockerfiles under `docker/sd-server/` and `docker/comfyui/`; llama slots share `docker/Dockerfile`. ComfyUI bind-mounts `~/comfyui/{custom_nodes,output,user}` so user-installed nodes survive image rebuilds.

## Hermes harness config

Copy the relevant provider stanzas from `config/hermes-config-snippet.yaml` into `~/.hermes/config.yaml`. The critical fields are `max_tokens: 4096` (prevents cutoff) and per-model `temperature`/`top_k` (Qwen: `0.6`/`20`; Gemma: `1.0`/`64`).

<!-- rtk-instructions v2 -->
# RTK (Rust Token Killer) - Token-Optimized Commands

## Golden Rule

**Always prefix commands with `rtk`**. If RTK has a dedicated filter, it uses it. If not, it passes through unchanged. This means RTK is always safe to use.

**Important**: Even in command chains with `&&`, use `rtk`:
```bash
# ❌ Wrong
git add . && git commit -m "msg" && git push

# ✅ Correct
rtk git add . && rtk git commit -m "msg" && rtk git push
```

## RTK Commands by Workflow

### Build & Compile (80-90% savings)
```bash
rtk cargo build         # Cargo build output
rtk cargo check         # Cargo check output
rtk cargo clippy        # Clippy warnings grouped by file (80%)
rtk tsc                 # TypeScript errors grouped by file/code (83%)
rtk lint                # ESLint/Biome violations grouped (84%)
rtk prettier --check    # Files needing format only (70%)
rtk next build          # Next.js build with route metrics (87%)
```

### Test (60-99% savings)
```bash
rtk cargo test          # Cargo test failures only (90%)
rtk go test             # Go test failures only (90%)
rtk jest                # Jest failures only (99.5%)
rtk vitest              # Vitest failures only (99.5%)
rtk playwright test     # Playwright failures only (94%)
rtk pytest              # Python test failures only (90%)
rtk rake test           # Ruby test failures only (90%)
rtk rspec               # RSpec test failures only (60%)
rtk test <cmd>          # Generic test wrapper - failures only
```

### Git (59-80% savings)
```bash
rtk git status          # Compact status
rtk git log             # Compact log (works with all git flags)
rtk git diff            # Compact diff (80%)
rtk git show            # Compact show (80%)
rtk git add             # Ultra-compact confirmations (59%)
rtk git commit          # Ultra-compact confirmations (59%)
rtk git push            # Ultra-compact confirmations
rtk git pull            # Ultra-compact confirmations
rtk git branch          # Compact branch list
rtk git fetch           # Compact fetch
rtk git stash           # Compact stash
rtk git worktree        # Compact worktree
```

Note: Git passthrough works for ALL subcommands, even those not explicitly listed.

### GitHub (26-87% savings)
```bash
rtk gh pr view <num>    # Compact PR view (87%)
rtk gh pr checks        # Compact PR checks (79%)
rtk gh run list         # Compact workflow runs (82%)
rtk gh issue list       # Compact issue list (80%)
rtk gh api              # Compact API responses (26%)
```

### JavaScript/TypeScript Tooling (70-90% savings)
```bash
rtk pnpm list           # Compact dependency tree (70%)
rtk pnpm outdated       # Compact outdated packages (80%)
rtk pnpm install        # Compact install output (90%)
rtk npm run <script>    # Compact npm script output
rtk npx <cmd>           # Compact npx command output
rtk prisma              # Prisma without ASCII art (88%)
```

### Files & Search (60-75% savings)
```bash
rtk ls <path>           # Tree format, compact (65%)
rtk read <file>         # Code reading with filtering (60%)
rtk grep <pattern>      # Search grouped by file (75%). Format flags (-c, -l, -L, -o, -Z) run raw.
rtk find <pattern>      # Find grouped by directory (70%)
```

### Analysis & Debug (70-90% savings)
```bash
rtk err <cmd>           # Filter errors only from any command
rtk log <file>          # Deduplicated logs with counts
rtk json <file>         # JSON structure without values
rtk deps                # Dependency overview
rtk env                 # Environment variables compact
rtk summary <cmd>       # Smart summary of command output
rtk diff                # Ultra-compact diffs
```

### Infrastructure (85% savings)
```bash
rtk docker ps           # Compact container list
rtk docker images       # Compact image list
rtk docker logs <c>     # Deduplicated logs
rtk kubectl get         # Compact resource list
rtk kubectl logs        # Deduplicated pod logs
```

### Network (65-70% savings)
```bash
rtk curl <url>          # Compact HTTP responses (70%)
rtk wget <url>          # Compact download output (65%)
```

### Meta Commands
```bash
rtk gain                # View token savings statistics
rtk gain --history      # View command history with savings
rtk discover            # Analyze Claude Code sessions for missed RTK usage
rtk proxy <cmd>         # Run command without filtering (for debugging)
rtk init                # Add RTK instructions to CLAUDE.md
rtk init --global       # Add RTK to ~/.claude/CLAUDE.md
```

## Token Savings Overview

| Category | Commands | Typical Savings |
|----------|----------|-----------------|
| Tests | vitest, playwright, cargo test | 90-99% |
| Build | next, tsc, lint, prettier | 70-87% |
| Git | status, log, diff, add, commit | 59-80% |
| GitHub | gh pr, gh run, gh issue | 26-87% |
| Package Managers | pnpm, npm, npx | 70-90% |
| Files | ls, read, grep, find | 60-75% |
| Infrastructure | docker, kubectl | 85% |
| Network | curl, wget | 65-70% |

Overall average: **60-90% token reduction** on common development operations.
<!-- /rtk-instructions -->