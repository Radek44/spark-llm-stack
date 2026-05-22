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
- Mutually exclusive by default.
- Starting one profile force-stops the others.
- Containers run with `--network=host` and `--gpus=all`.
- Per-profile memory caps are configured in `.env.autoresearch`.

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
```
