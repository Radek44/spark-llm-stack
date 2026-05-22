# Autoresearch Container Smoke Tests

This checklist validates the multi-profile launcher on a DGX Spark host.

## 0. Prerequisites

- NVIDIA Container Toolkit works (`docker run --rm --gpus all nvidia/cuda:13.2.0-runtime-ubuntu24.04 nvidia-smi`)
- Docker Compose plugin is installed
- Repo root is current working directory

## 1. Bootstrap runtime directories

```bash
./docker/autoresearch/scripts/autoresearch-switch bootstrap
```

Expected:
- `upstreams/`, `runs/`, `work/`, `secrets/` exist

## 2. Baseline switch sanity

```bash
./docker/autoresearch/scripts/autoresearch-switch status
./docker/autoresearch/scripts/autoresearch-switch off
```

Expected:
- `status` shows no running profile after `off`

## 3. karpathy profile smoke

```bash
./docker/autoresearch/scripts/autoresearch-switch start karpathy
./docker/autoresearch/scripts/autoresearch-switch logs karpathy
```

Expected:
- Repo cloned/fetched into `upstreams/karpathy-autoresearch`
- `uv sync` runs
- `prepare.py` starts
- bounded `train.py` starts or exits cleanly within timeout

Capture:
```bash
./docker/autoresearch/scripts/autoresearch-switch logs karpathy | tee runs/karpathy-smoke.log
```

## 4. dgx profile smoke

```bash
./docker/autoresearch/scripts/autoresearch-switch start dgx
./docker/autoresearch/scripts/autoresearch-switch logs dgx
```

Expected:
- Repo cloned/fetched into `upstreams/autoresearch-dgx-spark`
- `uv sync` + `prepare.py` + bounded `train.py` flow

Capture:
```bash
./docker/autoresearch/scripts/autoresearch-switch logs dgx | tee runs/dgx-smoke.log
```

## 5. n-autoresearch orchestrator smoke

```bash
./docker/autoresearch/scripts/autoresearch-switch start nauto-orch
./docker/autoresearch/scripts/autoresearch-switch logs nauto-orch
```

Expected:
- Repo cloned/fetched into `upstreams/n-autoresearch`
- orchestrator process starts (or clear missing-script message)

Capture:
```bash
./docker/autoresearch/scripts/autoresearch-switch logs nauto-orch | tee runs/nauto-orch-smoke.log
```

## 6. n-autoresearch worker smoke

```bash
./docker/autoresearch/scripts/autoresearch-switch start nauto-worker
./docker/autoresearch/scripts/autoresearch-switch logs nauto-worker
```

Expected:
- worker process starts (or clear missing-script message)

Capture:
```bash
./docker/autoresearch/scripts/autoresearch-switch logs nauto-worker | tee runs/nauto-worker-smoke.log
```

## 7. gemini profile smoke

```bash
./docker/autoresearch/scripts/autoresearch-switch start gemini
./docker/autoresearch/scripts/autoresearch-switch logs gemini
```

Expected:
- Repo cloned/fetched into `upstreams/gemini-autoresearch`
- container stays alive for host-driven Gemini CLI usage

Capture:
```bash
./docker/autoresearch/scripts/autoresearch-switch logs gemini | tee runs/gemini-smoke.log
```

## 8. autokernel profile smoke

```bash
# optional: set stage in .env.autoresearch first (profile|extract|bench|verify)
./docker/autoresearch/scripts/autoresearch-switch start autokernel
./docker/autoresearch/scripts/autoresearch-switch logs autokernel
```

Expected:
- Repo cloned/fetched into `upstreams/autokernel`
- selected stage attempts execution, or emits clear missing-script notice

Capture:
```bash
./docker/autoresearch/scripts/autoresearch-switch logs autokernel | tee runs/autokernel-smoke.log
```

## 9. Mutual exclusion invariant

Run this sequence:

```bash
./docker/autoresearch/scripts/autoresearch-switch start karpathy
./docker/autoresearch/scripts/autoresearch-switch start dgx
./docker/autoresearch/scripts/autoresearch-switch status
```

Expected:
- only `dgx` is running
- previous profile container is stopped/removed

## 10. Memory/OOM tuning loop

1. Start a profile.
2. Watch logs for OOM/kill signals.
3. Check container exit reason:

```bash
docker inspect spark-autoresearch-karpathy --format '{{.State.OOMKilled}} {{.State.ExitCode}}'
```

4. Adjust relevant `*_MEM_LIMIT` and `*_MEM_RESERVATION` in `.env.autoresearch`.
5. Re-run smoke for that profile.

## 11. Cleanup

```bash
./docker/autoresearch/scripts/autoresearch-switch off
./docker/autoresearch/scripts/autoresearch-switch status
```

Expected:
- no running autoresearch profile containers
