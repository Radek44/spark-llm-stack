# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A systemd user-service LLM inference stack for NVIDIA DGX Spark GB10 (Grace Blackwell, aarch64, SM 12.1). The primary tools are:

- `llm-switch` — runtime service manager; starts one slot, stops all others
- `harden-llm-stack.sh` — generates systemd drop-ins (memory caps, OOM policy, `Conflicts=`)
- `flux-gen` — CLI wrapper for the FLUX.2-klein async image API
- `docker-llm-switch` — Docker-native mirror of `llm-switch`; manages `spark-llm-*` containers

## Key architectural constraint

Running multiple heavyweight services simultaneously exhausts 128 GB unified memory and causes an OOM respawn brick loop (see `POSTMORTEM.md`). `harden-llm-stack.sh` applies `Conflicts=` drop-ins to enforce mutual exclusion at the systemd level. `docker-llm-switch` enforces the same via `stop_all_except` before every `docker run`.

## How slots are defined (the mirroring pattern)

Each model slot (e.g. `coder`) is defined in **four parallel places** that must stay in sync when adding or changing a slot:

| File | Role |
|---|---|
| `*.service` | Systemd unit; `ExecStart` is the authoritative arg set |
| `llm-switch` | `SVCS[]`, `PORTS[]`, `ROLES[]` maps + wait logic |
| `docker-llm-switch` | `CMD_<slot>` array mirrors `ExecStart` with `--host 0.0.0.0` |
| `harden-llm-stack.sh` | `SERVICES=()` array with `MemoryHigh/Max` and heavyweight flag |

The Dockerfile `CMD` and `run.sh` are coder-slot defaults only (not per-slot).

## Installation workflow

Service files use `%h` (systemd home specifier) and must be installed before use:

```bash
cp *.service ~/.config/systemd/user/
# Edit ExecStart binary path in each .service (default: %h/src/llama.cpp-mtp/build/bin/llama-server)
bash harden-llm-stack.sh          # generates drop-ins in ~/.config/systemd/user/*.d/
systemctl --user daemon-reload
cp llm-switch flux-gen ~/.local/bin/ && chmod +x ~/.local/bin/llm-switch ~/.local/bin/flux-gen
```

The `drop-ins/` directory in this repo is a **reference copy** of the generated drop-ins. The live drop-ins are at `~/.config/systemd/user/<unit>.d/override.conf`. `harden-llm-stack.sh` writes (and reverts) those live files directly.

## MTP binary note

Service files point to `%h/src/llama.cpp-mtp/build/bin/llama-server` (pre-merge MTP branch), not mainline. Mainline llama.cpp currently underperforms on GB10 (~23 vs ~28 t/s). The Dockerfile builds from `LLAMA_REF=master` by default — override with `--build-arg LLAMA_REF=<commit>` to pin the MTP branch.

## Flags that must never appear in service files

- `--no-mmap` — forces weights into anonymous pages (not evictable on unified memory)
- `--mlock` — pins the model permanently, starving other services

## Build flags (GB10-specific)

`121a-real` is required for native SASS. Using `121` alone generates generic PTX and incurs JIT overhead at load time. The `stable-diffusion.cpp` build (FLUX) uses `121` — that's intentional, it's not a GB10-optimised build.

## Docker workflow

```bash
docker build -t spark-llm-stack .
./run.sh                   # coder slot
./run.sh architect         # architect slot
docker-llm-switch status   # manage running containers
```

`docker-llm-switch` does not cover `imagine` (FLUX) or `comfyui` — those require separate images.

## Hermes harness config

Copy the relevant provider stanzas from `hermes-config-snippet.yaml` into `~/.hermes/config.yaml`. The critical fields are `max_tokens: 4096` (prevents cutoff) and per-model `temperature`/`top_k` (Qwen: `0.6`/`20`; Gemma: `1.0`/`64`).
