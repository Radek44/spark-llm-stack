#!/usr/bin/env bash
# harden-llm-stack.sh
# Apply memory caps, restart policy, and mutual-exclusion (Conflicts=) to
# llama-server / model services on DGX Spark.
#
# Default mode: drop-ins only — never touches original unit files.
# Optional --clean-execstart: also sed out --no-mmap and --swa-full from
# the original units (timestamped .bak backups).
#
# Usage:
#   ./harden-llm-stack.sh                    apply drop-ins
#   ./harden-llm-stack.sh --dry-run          show planned changes, do nothing
#   ./harden-llm-stack.sh --clean-execstart  also remove --no-mmap / --swa-full
#   ./harden-llm-stack.sh --revert           remove only drop-ins we created
#                                            (manual revert needed for ExecStart
#                                            edits — use the .bak files)
#
# Run as your normal user (radek). The script sudo's for system unit changes.

set -uo pipefail

DRYRUN=0
CLEAN_EXECSTART=0
REVERT=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)          DRYRUN=1 ;;
    --clean-execstart)  CLEAN_EXECSTART=1 ;;
    --revert)           REVERT=1 ;;
    -h|--help)          sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

USER_DIR="$HOME/.config/systemd/user"
SYS_DIR="/etc/systemd/system"
MARKER="# managed-by:harden-llm-stack"

# format: scope | unit | MemoryHigh | MemoryMax | heavyweight (1 = in Conflicts pool)
SERVICES=(
  "system|qwen36-27b-smart.service|40G|50G|1"
  "system|qwen36-35b-fast.service|45G|55G|1"
  "user|qwen27-mtp.service|70G|80G|1"
  "user|qwen35-mtp.service|70G|80G|1"
  "user|gemma-31b.service|70G|80G|1"
  "user|gptoss-20b.service|30G|40G|1"
  "user|gemma-vision.service|15G|20G|0"
  "user|flux-klein.service|12G|16G|0"
  "user|comfyui.service|30G|40G|0"
)

# Build the heavyweight pool for Conflicts=
HEAVY=()
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r _ unit _ _ heavy <<<"$entry"
  [[ "$heavy" = "1" ]] && HEAVY+=("$unit")
done

# ---------- helpers ----------

dropin_path() {
  local scope="$1" unit="$2"
  if [[ "$scope" = "system" ]]; then
    printf '%s/%s.d/override.conf' "$SYS_DIR" "$unit"
  else
    printf '%s/%s.d/override.conf' "$USER_DIR" "$unit"
  fi
}

unit_file_path() {
  local scope="$1" unit="$2"
  if [[ "$scope" = "system" ]]; then
    printf '%s/%s' "$SYS_DIR" "$unit"
  else
    printf '%s/%s' "$USER_DIR" "$unit"
  fi
}

unit_present() {
  local scope="$1" unit="$2"
  [[ -f "$(unit_file_path "$scope" "$unit")" ]]
}

build_override() {
  local unit="$1" hi="$2" mx="$3" heavy="$4"
  local conflicts=""
  if [[ "$heavy" = "1" ]]; then
    local cs=()
    for h in "${HEAVY[@]}"; do
      [[ "$h" != "$unit" ]] && cs+=("$h")
    done
    conflicts="${cs[*]}"
  fi

  cat <<EOF
$MARKER
# Generated $(date -Iseconds) by harden-llm-stack.sh
# Revert: ./harden-llm-stack.sh --revert  (or rm this whole .d dir)

[Unit]
$( [[ -n "$conflicts" ]] && echo "Conflicts=$conflicts" )

[Service]
# memory cap — when hit, kernel OOMs this cgroup only, host untouched
MemoryHigh=$hi
MemoryMax=$mx
OOMPolicy=stop
OOMScoreAdjust=200

# restart with a hard burst limit (3 fails in 10 min → systemd gives up)
Restart=on-failure
RestartSec=15
StartLimitBurst=3
StartLimitIntervalSec=600
EOF
}

write_dropin() {
  local scope="$1" unit="$2" hi="$3" mx="$4" heavy="$5"
  local target dir
  target=$(dropin_path "$scope" "$unit")
  dir=$(dirname "$target")

  printf '  + %-35s  cap=%s/%s  conflicts=%s\n' \
    "$unit" "$hi" "$mx" "$([[ $heavy = 1 ]] && echo yes || echo no)"
  [[ "$DRYRUN" = "1" ]] && return

  if [[ "$scope" = "system" ]]; then
    sudo mkdir -p "$dir"
    build_override "$unit" "$hi" "$mx" "$heavy" | sudo tee "$target" >/dev/null
  else
    mkdir -p "$dir"
    build_override "$unit" "$hi" "$mx" "$heavy" >"$target"
  fi
}

revert_dropin() {
  local scope="$1" unit="$2"
  local target dir
  target=$(dropin_path "$scope" "$unit")
  dir=$(dirname "$target")

  [[ -f "$target" ]] || return

  if ! grep -q "$MARKER" "$target" 2>/dev/null; then
    printf '  ⚠ %s  (no marker — not ours, skipped)\n' "$target"
    return
  fi

  printf '  - %s\n' "$target"
  [[ "$DRYRUN" = "1" ]] && return

  if [[ "$scope" = "system" ]]; then
    sudo rm -f "$target"
    sudo rmdir "$dir" 2>/dev/null || true
  else
    rm -f "$target"
    rmdir "$dir" 2>/dev/null || true
  fi
}

clean_execstart() {
  local scope="$1" unit="$2"
  local file
  file=$(unit_file_path "$scope" "$unit")
  [[ -f "$file" ]] || return

  # only operate if at least one of the flags is present, on its own line
  if ! grep -qE '^[[:space:]]*--(no-mmap|swa-full)[[:space:]]*\\?[[:space:]]*$' "$file"; then
    return
  fi

  local backup="${file}.bak-$(date +%Y%m%d-%H%M%S)"
  printf '  ✎ %s  (removing --no-mmap, --swa-full)\n' "$file"
  printf '    backup: %s\n' "$backup"

  [[ "$DRYRUN" = "1" ]] && return

  if [[ "$scope" = "system" ]]; then
    sudo cp -a "$file" "$backup"
    sudo sed -i -E '/^[[:space:]]*--(no-mmap|swa-full)[[:space:]]*\\?[[:space:]]*$/d' "$file"
  else
    cp -a "$file" "$backup"
    sed -i -E '/^[[:space:]]*--(no-mmap|swa-full)[[:space:]]*\\?[[:space:]]*$/d' "$file"
  fi
}

reload_daemons() {
  [[ "$DRYRUN" = "1" ]] && { echo "  (dry-run: skipping daemon-reload)"; return; }
  echo "  reloading systemd..."
  sudo systemctl daemon-reload
  systemctl --user daemon-reload
}

# ---------- main ----------

echo
if [[ "$REVERT" = "1" ]]; then
  echo "▶ REVERT mode — removing drop-ins created by this script"
else
  echo "▶ APPLY mode$( [[ $DRYRUN = 1 ]] && echo ' (DRY-RUN)' )"
  echo "  • $(printf '%s ' "${HEAVY[@]}" | wc -w) heavyweight services will conflict with each other"
  echo "  • all services get MemoryHigh/MemoryMax + OOMPolicy=stop + StartLimitBurst=3"
fi
echo

missing=()
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r scope unit hi mx heavy <<<"$entry"

  if ! unit_present "$scope" "$unit"; then
    missing+=("[$scope] $unit")
    continue
  fi

  if [[ "$REVERT" = "1" ]]; then
    revert_dropin "$scope" "$unit"
  else
    write_dropin "$scope" "$unit" "$hi" "$mx" "$heavy"
    [[ "$CLEAN_EXECSTART" = "1" ]] && clean_execstart "$scope" "$unit"
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo
  echo "  (skipped — unit file not found:)"
  for m in "${missing[@]}"; do echo "    $m"; done
fi

echo
reload_daemons

echo
echo "▶ done."
echo
if [[ "$REVERT" != "1" && "$DRYRUN" != "1" ]]; then
cat <<'EOF'
Next: verify the drop-ins took effect.

  # System services
  for u in qwen36-27b-smart qwen36-35b-fast; do
    echo "=== $u ==="
    systemctl show "$u" -p MemoryMax,OOMPolicy,Restart,StartLimitBurst,Conflicts | sed 's/^/  /'
  done

  # User services
    echo "=== $u ==="
    systemctl --user show "$u" -p MemoryMax,OOMPolicy,Restart,StartLimitBurst,Conflicts | sed 's/^/  /'
  done

Then test mutual exclusion:

  llm-switch coder
  systemctl --user is-active qwen27-mtp.service    # active
  llm-switch architect
  systemctl --user is-active qwen27-mtp.service    # inactive  (Conflicts= fired)
EOF
fi
echo
