#!/bin/sh
# Seed default custom nodes (ComfyUI-Manager etc.) into the bind-mounted
# /opt/ComfyUI/custom_nodes/ on first run. `cp -n` is no-clobber so
# anything the user installed via the Manager UI is preserved across
# container restarts and image rebuilds.
set -e

if [ -d /opt/comfy-defaults/custom_nodes ]; then
  cp -rn /opt/comfy-defaults/custom_nodes/. /opt/ComfyUI/custom_nodes/ 2>/dev/null || true
fi

exec python /opt/ComfyUI/main.py "$@"
