#!/usr/bin/env bash
# harden-llm-stack.sh
# Apply memory caps, restart policy, and mutual-exclusion (Conflicts=) to
# managed DGX Spark local AI services.
#
# Usage:
#   ./harden-llm-stack.sh                    apply drop-ins
#   ./harden-llm-stack.sh --dry-run          show planned changes, do nothing
#   ./harden-llm-stack.sh --revert           remove only drop-ins we created

set -uo pipefail

DRYRUN=0
REVERT=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRYRUN=1 ;;
    --revert)  REVERT=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

USER_DIR="$HOME/.config/systemd/user"
MARKER="# managed-by:harden-llm-stack"

# format: unit | MemoryHigh | MemoryMax | MemorySwapMax | heavyweight (1 = in Conflicts pool)
SERVICES=(
  "vllm-qwen36-35b-nvfp4.service|65G|80G|4G|1"
  "gemma4-v2-coder.service|24G|32G|2G|1"
  "flux-klein.service|12G|16G|1G|0"
  "comfyui.service|30G|40G|2G|0"
  "litellm.service|2G|4G|512M|0"
)

HEAVY=()
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r unit _ _ _ heavy <<<"$entry"
  [[ "$heavy" = "1" ]] && HEAVY+=("$unit")
done

dropin_path() { printf '%s/%s.d/override.conf' "$USER_DIR" "$1"; }
unit_file_path() { printf '%s/%s' "$USER_DIR" "$1"; }
unit_present() { [[ -f "$(unit_file_path "$1")" ]]; }

build_override() {
  local unit="$1" hi="$2" mx="$3" sw="$4" heavy="$5" conflicts=""
  if [[ "$heavy" = "1" ]]; then
    local cs=()
    for h in "${HEAVY[@]}"; do [[ "$h" != "$unit" ]] && cs+=("$h"); done
    conflicts="${cs[*]}"
  fi

  cat <<EOF
$MARKER
# Generated $(date -Iseconds) by harden-llm-stack.sh
# Revert: ./harden-llm-stack.sh --revert  (or rm this whole .d dir)

[Unit]
$( [[ -n "$conflicts" ]] && echo "Conflicts=$conflicts" )
StartLimitBurst=3
StartLimitIntervalSec=600

[Service]
MemoryHigh=$hi
MemoryMax=$mx
MemorySwapMax=$sw
OOMPolicy=stop
OOMScoreAdjust=200
Restart=on-failure
RestartSec=15
EOF
}

write_dropin() {
  local unit="$1" hi="$2" mx="$3" sw="$4" heavy="$5" target dir
  target=$(dropin_path "$unit")
  dir=$(dirname "$target")
  printf '  + %-35s  cap=%s/%s swap=%s conflicts=%s\n' "$unit" "$hi" "$mx" "$sw" "$([[ $heavy = 1 ]] && echo yes || echo no)"
  [[ "$DRYRUN" = "1" ]] && return
  mkdir -p "$dir"
  build_override "$unit" "$hi" "$mx" "$sw" "$heavy" >"$target"
}

revert_dropin() {
  local unit="$1" target dir
  target=$(dropin_path "$unit")
  dir=$(dirname "$target")
  [[ -f "$target" ]] || return
  if ! grep -q "$MARKER" "$target" 2>/dev/null; then
    printf '  ⚠ %s  (no marker — not ours, skipped)\n' "$target"
    return
  fi
  printf '  - %s\n' "$target"
  [[ "$DRYRUN" = "1" ]] && return
  rm -f "$target"
  rmdir "$dir" 2>/dev/null || true
}

reload_daemon() {
  [[ "$DRYRUN" = "1" ]] && { echo "  (dry-run: skipping daemon-reload)"; return; }
  echo "  reloading user systemd..."
  systemctl --user daemon-reload
}

echo
if [[ "$REVERT" = "1" ]]; then
  echo "▶ REVERT mode — removing drop-ins created by this script"
else
  echo "▶ APPLY mode$( [[ $DRYRUN = 1 ]] && echo ' (DRY-RUN)' )"
  echo "  • ${#HEAVY[@]} heavyweight service(s) in mutual-exclusion pool"
  echo "  • all managed services get MemoryHigh/MemoryMax + OOMPolicy=stop + StartLimitBurst=3"
fi
echo

missing=()
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r unit hi mx sw heavy <<<"$entry"
  if ! unit_present "$unit"; then
    missing+=("$unit")
    continue
  fi
  if [[ "$REVERT" = "1" ]]; then
    revert_dropin "$unit"
  else
    write_dropin "$unit" "$hi" "$mx" "$sw" "$heavy"
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo
  echo "  (skipped — unit file not found:)"
  for m in "${missing[@]}"; do echo "    $m"; done
fi

echo
reload_daemon

echo
cat <<'EOF'
Next: verify the drop-ins took effect.

  for u in vllm-qwen36-35b-nvfp4 gemma4-v2-coder flux-klein comfyui litellm; do
    echo "=== $u ==="
    systemctl --user show "$u" -p MemoryHigh,MemoryMax,MemorySwapMax,OOMPolicy,Restart,StartLimitBurst,Conflicts | sed 's/^/  /'
  done
EOF
echo
