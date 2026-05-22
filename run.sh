#!/usr/bin/env bash
# Launch the spark-llm-stack container.
#
# Tailscale access: the container runs with --network=host so it shares the
# DGX Spark's network namespace. Any service on the Tailscale network can
# reach it at http://<tailscale-ip>:<port>/. No in-container Tailscale needed.
#
# OOM guard: --memory=80g mirrors the MemoryMax=80G systemd drop-in from the
# POSTMORTEM hardening. Run only one container at a time (no Conflicts= here,
# just don't start a second one).
#
# Usage:
#   ./run.sh                        # coder slot (default CMD in Dockerfile)
#   ./run.sh architect              # architect slot (see below)
#   ./run.sh <extra llama-server args>
#
# First-time model download (runs once, writes into ~/models via the volume):
#   docker run --rm --gpus=all --network=host \
#     --memory=80g --memory-swap=80g \
#     -v ~/models:/models \
#     -e HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN}" \
#     spark-llm-stack \
#     -hf unsloth/Qwen3.6-27B-MTP-GGUF:UD-Q4_K_XL \
#     --alias qwen3.6-27b-coder --host 0.0.0.0 --port 8152 \
#     -ngl 999 -fa on -c 131072 \
#     --cache-type-k q8_0 --cache-type-v q8_0 --kv-unified \
#     --cache-ram 49152 --cache-idle-slots \
#     --ctx-checkpoints 128 --cache-reuse 1024 \
#     -b 32768 -ub 8192 --parallel 1 \
#     --threads 8 --threads-batch 16 --threads-http 4 \
#     --prio 3 --poll 100 \
#     --spec-type draft-mtp --spec-draft-n-max 5 \
#     --spec-draft-n-min 1 --spec-draft-p-min 0.75 \
#     --reasoning off --jinja \
#     --temp 0.6 --top-k 20 --top-p 0.95 --min-p 0.0 \
#     --presence-penalty 0.0 --keep -1 --metrics --slots

set -euo pipefail

IMAGE="${SPARK_IMAGE:-spark-llm-stack}"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"

BASE_ARGS=(
  --rm
  --gpus=all
  --network=host
  --memory=80g
  --memory-swap=80g
  -v "${MODELS_DIR}:/models"
  -e "HUGGING_FACE_HUB_TOKEN=${HUGGING_FACE_HUB_TOKEN:-}"
)

# Slot shortcuts — override the default CMD with the architect slot.
# Add more slots here as needed (see README model roster).
case "${1:-}" in
  architect)
    shift
    exec docker run "${BASE_ARGS[@]}" "${IMAGE}" \
      -m /models/Qwen3.6-35B-A3B-MTP-Q4_K_XL.gguf \
      --alias qwen3.6-35b-architect \
      --host 0.0.0.0 --port 8154 \
      -ngl 999 -fa on -c 131072 \
      --cache-type-k q8_0 --cache-type-v q8_0 --kv-unified \
      --cache-ram 49152 --cache-idle-slots \
      --ctx-checkpoints 64 --cache-reuse 1024 \
      -b 16384 -ub 4096 --parallel 1 \
      --threads 8 --cpu-range 0-9 \
      --threads-batch 16 --cpu-range-batch 10-19 \
      --threads-http 4 \
      --prio 2 --poll 50 \
      --reasoning on --reasoning-budget 4000 --reasoning-format deepseek \
      --jinja \
      --temp 1.0 --top-k 20 --top-p 0.95 --min-p 0.0 \
      --presence-penalty 0.5 --keep -1 --metrics --slots \
      "$@"
    ;;
  *)
    # Default: coder slot (Dockerfile CMD), or pass-through arbitrary args.
    exec docker run "${BASE_ARGS[@]}" "${IMAGE}" "$@"
    ;;
esac
