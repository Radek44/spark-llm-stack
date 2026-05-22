#!/usr/bin/env bash
# spark-mem.sh — Cross-stack memory failsafe helpers for DGX Spark (GB10).
#
# Sourced by docker/docker-llm-switch and
# docker/autoresearch/scripts/autoresearch-switch. Also sourced by
# tools/spark-panic.
#
# Why this exists
# ───────────────
# DGX Spark has 128 GB LPDDR5X unified memory shared by CPU and GPU. Docker
# `--memory` flags and cgroup `memory.max` do NOT enforce on CUDA allocations
# (confirmed: NVIDIA forum #264689, #353752). The CUDA driver allocates via
# /dev/nvidia-uvm which bypasses cgroup reclaim. So we need:
#
#   1. an admission gate (preflight memory check)         — Layer 1
#   2. a flock'd cross-stack mutex so concurrent switch     ↑
#      invocations don't race                               │
#   3. a "panic" function that stops ALL exclusive          │
#      containers across BOTH stacks                        │
#                                                           │
# Plus earlyoom as the runtime watchdog (Layer 2; separate systemd unit).
#
# Conventions
# ───────────
# - All exclusive containers (both stacks) carry Docker label
#   `spark.exclusive=true`. spark_exclusive_set queries that label.
# - A second label `spark.stack=llm|autoresearch` lets us debug which side
#   started a container.
# - Lock at /var/run/spark-mem.lock (falls back to /tmp if /var/run is not
#   writable for the current user). FD 200 is the canonical flock pattern.

# Defensive: this file is meant to be sourced, not executed.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "spark-mem.sh: meant to be sourced, not executed directly" >&2
  echo "usage: . /path/to/spark-mem.sh" >&2
  exit 64
fi

# ── tunables (overridable via environment) ────────────────────────────────────

SPARK_EXCLUSIVE_LABEL="${SPARK_EXCLUSIVE_LABEL:-spark.exclusive=true}"
SPARK_LOCK_PATH="${SPARK_LOCK_PATH:-/var/run/spark-mem.lock}"
SPARK_LOCK_FD="${SPARK_LOCK_FD:-200}"
SPARK_LOCK_WAIT_SEC="${SPARK_LOCK_WAIT_SEC:-30}"
# Headroom kept free of any single new admission (in GiB). 8 GiB matches the
# safe-zone used by `autoresearch-switch start` post-drop-caches on a 128 GiB
# host (typical free pool 105–115 GiB, minus active OS + buffer cache).
SPARK_HEADROOM_GB="${SPARK_HEADROOM_GB:-8}"

# Fall back to /tmp if /var/run isn't writable (non-root operator without sudo
# permissions on /var/run). The lock still works across both switches as long
# as both processes use the same path.
if ! { : >> "$SPARK_LOCK_PATH"; } 2>/dev/null; then
  SPARK_LOCK_PATH="/tmp/spark-mem.lock"
fi

# ── small helpers ─────────────────────────────────────────────────────────────

spark_log() { printf '[spark-mem] %s\n' "$*" >&2; }

# Parse a docker-style memory string ("80g", "60G", "1024m", "2048k", or a
# bare byte count) into integer GiB (rounded down). Empty or unrecognised
# input returns 0.
# tr-based lowercase keeps this portable across bash 3 (macOS) and bash 4+
# (DGX host), even though the rest of the repo already relies on bash 4+.
spark_parse_gb() {
  local raw="${1:-0}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    ''|0) echo 0 ;;
    *gb|*g) echo "${raw%%g*}" ;;
    *mb|*m) echo $(( ${raw%%m*} / 1024 )) ;;
    *kb|*k) echo $(( ${raw%%k*} / 1048576 )) ;;
    *[!0-9]*) echo 0 ;;
    *) echo $(( raw / 1073741824 )) ;;
  esac
}

# ── flock-based cross-stack mutex ─────────────────────────────────────────────
#
# Both switch scripts must call spark_acquire_lock before touching containers.
# This serialises concurrent invocations across stacks so e.g. an in-flight
# `autoresearch-switch start dgx` can't race a `docker-llm-switch coder` and
# leave both running. flock releases when the holding process exits.
spark_acquire_lock() {
  # Avoid double-acquire if already held (function is idempotent).
  if [ "${SPARK_LOCK_HELD:-0}" = "1" ]; then
    return 0
  fi
  # `eval` so we can use the dynamic FD number from SPARK_LOCK_FD.
  eval "exec ${SPARK_LOCK_FD}>\"\$SPARK_LOCK_PATH\"" || {
    spark_log "failed to open lockfile $SPARK_LOCK_PATH"
    return 1
  }
  if ! flock -w "$SPARK_LOCK_WAIT_SEC" "$SPARK_LOCK_FD"; then
    spark_log "timed out (${SPARK_LOCK_WAIT_SEC}s) waiting for $SPARK_LOCK_PATH — another spark switch is in progress"
    return 1
  fi
  SPARK_LOCK_HELD=1
  # Defensive: log every exit path so an operator watching journalctl sees
  # the lock release (the OS releases the flock when the FD closes on exit,
  # but the log line confirms the script didn't die silently mid-critical-section).
  trap 'spark_log "lock released ($SPARK_LOCK_PATH)"' EXIT
  return 0
}

# ── exclusive-set enumeration (cross-stack) ───────────────────────────────────

# Emits currently-RUNNING containers carrying the exclusive label, one name
# per line.
spark_exclusive_set() {
  docker ps --filter "label=${SPARK_EXCLUSIVE_LABEL}" --format '{{.Names}}' 2>/dev/null
}

# Emits ALL containers (running OR stopped) with the exclusive label. Used by
# the panic stop to also clean up exited boot-default containers whose restart
# policy might bring them back.
spark_exclusive_set_all() {
  docker ps -a --filter "label=${SPARK_EXCLUSIVE_LABEL}" --format '{{.Names}}' 2>/dev/null
}

# ── memory signal ─────────────────────────────────────────────────────────────

# MemAvailable from /proc/meminfo, in KiB. This is the kernel's own best
# estimate of how much memory can be allocated to a new workload without
# swapping — superior to MemFree because it accounts for reclaimable cache.
spark_memavailable_kb() {
  awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null
}

# Returns 0 if (MemAvailable_MiB - SPARK_HEADROOM_GB*1024) >= projected_cap_GiB*1024.
# Returns 1 otherwise. Computed in MiB (not GiB) to avoid integer-division
# rounding errors at the boundary (e.g. MemAvailable=87.9GiB shouldn't reject
# an 80g workload when headroom is 8 GiB).
spark_admission_check() {
  local projected_gb="${1:-0}"
  local mem_kb mem_mib projected_mib headroom_mib available_mib
  mem_kb=$(spark_memavailable_kb)
  if [ -z "$mem_kb" ]; then
    spark_log "admission: could not read /proc/meminfo; allowing by default"
    return 0
  fi
  mem_mib=$(( mem_kb / 1024 ))
  projected_mib=$(( projected_gb * 1024 ))
  headroom_mib=$(( SPARK_HEADROOM_GB * 1024 ))
  available_mib=$(( mem_mib - headroom_mib ))

  spark_log "admission: MemAvailable=$(( mem_mib / 1024 ))GiB headroom=${SPARK_HEADROOM_GB}GiB projected=${projected_gb}GiB available=$(( available_mib / 1024 ))GiB"

  if [ "$available_mib" -ge "$projected_mib" ]; then
    return 0
  fi
  return 1
}

# ── drop_caches ───────────────────────────────────────────────────────────────

# Flush Linux page/dentry/inode cache. On DGX Spark the buffer cache can hold
# 8–20 GiB after prior workloads. Without this the effective working headroom
# is smaller than `free -h` suggests.
spark_drop_caches() {
  spark_log "flushing buffer cache (reclaims 8–20 GiB of unified memory)"
  if [ "$(id -u)" = "0" ]; then
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    return 0
  fi
  # `-n` keeps sudo non-interactive: if the operator's sudoers entry doesn't
  # have NOPASSWD for this command, fail fast instead of hanging on a password
  # prompt (especially harmful inside an SSH-without-TTY or cron path, where
  # admission would silently proceed against unflushed memory).
  # Install requires this sudoers line (see README "Cross-stack memory failsafe"):
  #   <operator> ALL=(root) NOPASSWD: /bin/sh -c sync; echo 3 > /proc/sys/vm/drop_caches
  sudo -n sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || {
    spark_log "drop_caches failed (sudo -n required; configure NOPASSWD); continuing without flush"
    return 0
  }
}

# ── cross-stack stop (force-serial fallback for the admission gate) ───────────

# Stops every container in the exclusive set EXCEPT $keep. Clears the restart
# policy first so docker doesn't bring them back. Idempotent.
spark_cross_stack_stop_others() {
  local keep="${1:-}"
  local name stopped=0
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    [ "$name" = "$keep" ] && continue
    spark_log "cross-stack stop: $name"
    docker update --restart=no "$name" >/dev/null 2>&1 || true
    docker stop -t 10 "$name" >/dev/null 2>&1 || true
    stopped=$(( stopped + 1 ))
  done < <(spark_exclusive_set)
  if [ "$stopped" -gt 0 ]; then
    spark_log "stopped $stopped cross-stack container(s)"
  fi
}

# ── panic ─────────────────────────────────────────────────────────────────────
#
# Emergency cross-stack stop. Called by:
#   - operator: `docker-llm-switch panic` / `autoresearch-switch panic` /
#               `spark-panic`
#   - earlyoom -N hook before SIGKILL
# Idempotent; safe to call repeatedly.
spark_panic_stop_all() {
  spark_log "PANIC: stopping all containers with label ${SPARK_EXCLUSIVE_LABEL}"
  command -v logger >/dev/null 2>&1 && \
    logger -t spark-panic "stopping all containers with label ${SPARK_EXCLUSIVE_LABEL}" 2>/dev/null || true

  local name stopped=0
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    docker update --restart=no "$name" >/dev/null 2>&1 || true
    docker stop -t 10 "$name" >/dev/null 2>&1 || true
    spark_log "  stopped $name"
    stopped=$(( stopped + 1 ))
  done < <(spark_exclusive_set_all)

  spark_drop_caches
  spark_log "panic complete: stopped $stopped container(s)"
  free -h 2>/dev/null | awk '/^Mem:/{printf "[spark-mem] memory after panic: %s used / %s total / %s available\n", $3, $2, $7}' >&2 || true
}
