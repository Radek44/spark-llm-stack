#!/usr/bin/env bash
set -euo pipefail

PROFILE="${AUTORESEARCH_PROFILE:-}"
UPSTREAM_ROOT="${UPSTREAM_ROOT:-/workspace/upstreams}"
RUNS_ROOT="${RUNS_ROOT:-/workspace/runs}"
WORK_ROOT="${WORK_ROOT:-/workspace/work}"

mkdir -p "$UPSTREAM_ROOT" "$RUNS_ROOT" "$WORK_ROOT"

log() { printf '[%s] %s\n' "$PROFILE" "$*"; }

repo_dir() {
  case "$PROFILE" in
    karpathy) echo "$UPSTREAM_ROOT/karpathy-autoresearch" ;;
    dgx) echo "$UPSTREAM_ROOT/autoresearch-dgx-spark" ;;
    nauto-orch|nauto-worker) echo "$UPSTREAM_ROOT/n-autoresearch" ;;
    gemini) echo "$UPSTREAM_ROOT/gemini-autoresearch" ;;
    autokernel) echo "$UPSTREAM_ROOT/autokernel" ;;
    *) echo "" ;;
  esac
}

repo_url() {
  case "$PROFILE" in
    karpathy) echo "${REPO_KARPATHY_URL:-https://github.com/karpathy/autoresearch.git}" ;;
    dgx) echo "${REPO_DGX_URL:-https://github.com/David-Barnes-Data-Imaginations/autoresearch-DGX-Spark.git}" ;;
    nauto-orch|nauto-worker) echo "${REPO_NAUTO_URL:-https://github.com/iii-experimental/n-autoresearch.git}" ;;
    gemini) echo "${REPO_GEMINI_URL:-https://github.com/supratikpm/gemini-autoresearch.git}" ;;
    autokernel) echo "${REPO_AUTOKERNEL_URL:-https://github.com/RightNow-AI/autokernel.git}" ;;
    *) echo "" ;;
  esac
}

bootstrap_repo() {
  local dir url
  dir="$(repo_dir)"
  url="$(repo_url)"

  if [ -z "$PROFILE" ] || [ -z "$dir" ] || [ -z "$url" ]; then
    echo "AUTORESEARCH_PROFILE is invalid or unset: '$PROFILE'" >&2
    exit 1
  fi

  if [ ! -d "$dir/.git" ]; then
    log "cloning $url -> $dir"
    git clone "$url" "$dir"
  else
    log "fetching latest for $dir"
    git -C "$dir" fetch --all --prune || true
  fi

  echo "$dir"
}

setup_uv() {
  local dir="$1"
  if [ -f "$dir/pyproject.toml" ]; then
    log "uv sync in $dir"
    (cd "$dir" && uv sync)
  fi
}

# Apply the two GB10-specific patches to karpathy/autoresearch.
# The dgx profile (David-Barnes fork) ships these fixes already; skip for it.
#
# Patch 1 — Flash Attention 3 removal
#   FA3 (Dao-AILab/flash-attention) has no sm_121 aarch64 wheel and fails to
#   build from source ("kernel built for sm80–sm100, running on sm121").
#   Remove it from pyproject.toml so `uv sync` doesn't attempt the build.
#   llama.cpp SDPA (scaled_dot_product_attention) is the correct replacement.
#
# Patch 2 — FLOPS constant: H100 990 → GB10 213
#   The karpathy autoresearch agent uses this constant for time-budget
#   reasoning inside the training loop. The upstream value (990 TFLOPS) is
#   H100 BF16 peak; the GB10 measured value is 213 TFLOPS. Using the wrong
#   value causes the agent to size models and set step counts for a ~5×
#   faster GPU, leading to suboptimal experiments on GB10.
#   Community-measured optimum: depth=3, dim=384, batch=2^16, ~6 GB VRAM.
#
# References:
#   https://github.com/Dao-AILab/flash-attention/issues/1969
#   https://forums.developer.nvidia.com/t/karpathys-autoresearch-customised-for-spark/362949
#   https://rundatarun.io/p/the-overnight-loop
patch_karpathy_for_gb10() {
  local dir="$1"

  # Patch 1: remove flash-attn from pyproject.toml
  local pyproject="$dir/pyproject.toml"
  if [ -f "$pyproject" ] && grep -qiE 'flash.?attn|flash.?attention' "$pyproject"; then
    log "GB10 patch: removing flash-attn from pyproject.toml (no sm_121 support)"
    sed -i '/flash.attn\|flash.attention/Id' "$pyproject"
  else
    log "GB10 patch: flash-attn not in pyproject.toml (already clean)"
  fi

  # Patch 2: replace FLOPS constant in train.py
  local trainpy="$dir/train.py"
  if [ ! -f "$trainpy" ]; then
    log "GB10 patch: train.py not found, skipping FLOPS patch"
    return 0
  fi

  # Try the scientific-notation form first (990e12), then the bare integer.
  if grep -q '990e12' "$trainpy"; then
    log "GB10 patch: train.py FLOPS 990e12 → 213e12 (H100 → GB10)"
    sed -i 's/990e12/213e12/g' "$trainpy"
  elif grep -qw '990' "$trainpy"; then
    log "GB10 patch: train.py FLOPS 990 → 213 (H100 → GB10)"
    sed -i 's/\b990\b/213/g' "$trainpy"
  else
    log "GB10 patch: FLOPS constant not found in train.py (already patched or upstream changed)"
  fi
}

run_karpathy_like() {
  local dir="$1"
  # karpathy/autoresearch targets H100; apply GB10 patches before uv sync.
  # The dgx fork (David-Barnes) ships these fixes already.
  if [ "$PROFILE" = "karpathy" ]; then
    patch_karpathy_for_gb10 "$dir"
  fi
  setup_uv "$dir"
  if [ -f "$dir/prepare.py" ]; then
    log "running prepare.py"
    (cd "$dir" && uv run prepare.py)
  fi
  if [ -f "$dir/train.py" ]; then
    log "running bounded train command"
    (cd "$dir" && timeout "${TRAIN_TIMEOUT:-600}" uv run train.py)
  else
    log "no train.py found; sleeping"
    sleep infinity
  fi
}

run_nauto() {
  local dir="$1"
  setup_uv "$dir"
  local role="${NAUTO_ROLE:-orchestrator}"
  if [ "$PROFILE" = "nauto-worker" ]; then
    role="worker"
  fi

  if [ "$role" = "orchestrator" ]; then
    if [ -f "$dir/workers/orchestrator/orchestrator.py" ]; then
      log "starting n-autoresearch orchestrator"
      (cd "$dir" && uv run python workers/orchestrator/orchestrator.py)
    else
      log "orchestrator script not found; sleeping"
      sleep infinity
    fi
  else
    if [ -f "$dir/workers/worker/worker.py" ]; then
      log "starting n-autoresearch worker"
      (cd "$dir" && uv run python workers/worker/worker.py)
    else
      log "worker script not found; sleeping"
      sleep infinity
    fi
  fi
}

run_gemini() {
  local dir="$1"
  log "gemini-autoresearch is a skill package; keeping container alive for host-driven CLI sessions"
  log "repo cloned at: $dir"
  sleep infinity
}

run_autokernel() {
  local dir="$1"
  setup_uv "$dir"
  log "autokernel stage: ${AUTOKERNEL_STAGE:-profile}"
  case "${AUTOKERNEL_STAGE:-profile}" in
    profile)
      if [ -f "$dir/profile.py" ]; then
        (cd "$dir" && uv run python profile.py ${AUTOKERNEL_PROFILE_ARGS:-})
      else
        log "profile.py not found; sleeping"
        sleep infinity
      fi
      ;;
    extract)
      if [ -f "$dir/extract.py" ]; then
        (cd "$dir" && uv run python extract.py ${AUTOKERNEL_EXTRACT_ARGS:-})
      else
        log "extract.py not found; sleeping"
        sleep infinity
      fi
      ;;
    bench)
      if [ -f "$dir/bench.py" ]; then
        (cd "$dir" && uv run python bench.py ${AUTOKERNEL_BENCH_ARGS:-})
      else
        log "bench.py not found; sleeping"
        sleep infinity
      fi
      ;;
    verify)
      if [ -f "$dir/verify.py" ]; then
        (cd "$dir" && uv run python verify.py ${AUTOKERNEL_VERIFY_ARGS:-})
      else
        log "verify.py not found; sleeping"
        sleep infinity
      fi
      ;;
    *)
      log "unknown AUTOKERNEL_STAGE='${AUTOKERNEL_STAGE:-}'"
      sleep infinity
      ;;
  esac
}

main() {
  local dir
  dir="$(bootstrap_repo)"

  case "$PROFILE" in
    karpathy|dgx)
      run_karpathy_like "$dir"
      ;;
    nauto-orch|nauto-worker)
      run_nauto "$dir"
      ;;
    gemini)
      run_gemini "$dir"
      ;;
    autokernel)
      run_autokernel "$dir"
      ;;
    *)
      echo "Unsupported profile: '$PROFILE'" >&2
      exit 1
      ;;
  esac
}

main "$@"
