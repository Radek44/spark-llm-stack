# Autoresearch Containers

## Overview
This stack launches upstream autoresearch-style projects in isolated containers without code folding.
Each mode clones/fetches upstream code into `upstreams/` and writes runtime artifacts into `runs/`.

## Files
- `docker/autoresearch/Dockerfile.base`
- `docker/autoresearch/docker-compose.autoresearch.yml`
- `docker/autoresearch/scripts/autoresearch-switch`
- `docker/autoresearch/scripts/entrypoint.sh`
- `.env.autoresearch`

## Bootstrap
```bash
rtk docker --version
./docker/autoresearch/scripts/autoresearch-switch bootstrap
```

## Build and Start
```bash
./docker/autoresearch/scripts/autoresearch-switch start karpathy
./docker/autoresearch/scripts/autoresearch-switch status
```

Other profiles:
```bash
./docker/autoresearch/scripts/autoresearch-switch start dgx
./docker/autoresearch/scripts/autoresearch-switch start nauto-orch
./docker/autoresearch/scripts/autoresearch-switch start nauto-worker
./docker/autoresearch/scripts/autoresearch-switch start gemini
./docker/autoresearch/scripts/autoresearch-switch start autokernel
```

## Runtime Model
- Intra-stack mutually exclusive: starting one profile force-stops other autoresearch profiles.
- Cross-stack admission gate: every `autoresearch-switch start` and every `docker-llm-switch <slot>` now acquires a shared `flock` on `/var/run/spark-mem.lock`, checks `MemAvailable`, and force-stops the *other* stack if the new workload's projected cap would exceed the safe headroom.
- All exclusive containers carry the Docker label `spark.exclusive=true` so `docker ps --filter "label=spark.exclusive=true"` shows the canonical cross-stack view.
- Runtime watchdog: `systemd/units/spark-earlyoom.service` enforces a last-resort kill at MemAvailable < 8 % (SIGTERM) / < 4 % (SIGKILL); see `docs/research/autoresearch/findings_failsafe_design.md` for the full design and the NVIDIA-forum citations that motivate it.
- Containers run with `--network=host` and `--gpus=all`.
- Per-profile memory caps are configured in `.env.autoresearch`. They are *planning budgets* — cgroup hard caps do not enforce on GB10 UMA. Real enforcement comes from the admission gate + earlyoom watchdog + `spark-panic`.

## Mounts
- `upstreams/` -> `/workspace/upstreams`
- `runs/` -> `/workspace/runs`
- `work/` -> `/workspace/work`
- `secrets/` -> `/secrets` (read-only)

## Secrets
Place only required credentials/config in `secrets/`.
The mount is read-only in containers.

## Logs and Stop
```bash
./docker/autoresearch/scripts/autoresearch-switch logs karpathy
./docker/autoresearch/scripts/autoresearch-switch off
./docker/autoresearch/scripts/autoresearch-switch panic   # cross-stack emergency stop
```
