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

run_karpathy_like() {
  local dir="$1"
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
