#!/usr/bin/env bash
# Launch a spark-llm-stack slot via docker-llm-switch.
#
# This is a thin wrapper that delegates to docker-llm-switch so the mutual
# exclusion invariant (stop all other spark-llm-* containers before starting
# a new one) is always enforced. See CLAUDE.md and POSTMORTEM.md for why
# running two heavyweight slots simultaneously bricks the box.
#
# Tailscale access: containers run with --network=host, reachable at
# http://<tailscale-ip>:<port>/.
#
# Usage:
#   ./run.sh                 # coder slot (default)
#   ./run.sh architect       # any slot name: coder|architect|gemma|vision|gptoss
#   ./run.sh off|status|boot-safe|boot-default <slot>|boot-status
#
# First-time model download (one-off, writes into ~/models via the volume):
#   docker run --rm --gpus=all --network=host \
#     --memory=80g --memory-swap=80g \
#     --oom-score-adj=200 \
#     --ulimit memlock=-1:-1 --shm-size=1g \
#     -v ~/models:/models \
#     -e HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN}" \
#     spark-llm-stack \
#     -hf unsloth/Qwen3.6-27B-MTP-GGUF:UD-Q4_K_XL \
#     --alias qwen3.6-27b-coder --host 0.0.0.0 --port 8152 \
#     -ngl 999 -fa on -c 262144 \
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

SWITCH="${DOCKER_LLM_SWITCH:-docker-llm-switch}"

if ! command -v "$SWITCH" >/dev/null 2>&1; then
  echo "error: '$SWITCH' not found on PATH" >&2
  echo "install it: cp docker/docker-llm-switch ~/.local/bin/ && chmod +x ~/.local/bin/docker-llm-switch" >&2
  exit 1
fi

exec "$SWITCH" "${1:-coder}" "${@:2}"
