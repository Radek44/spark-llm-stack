#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
launcher="$repo_root/scripts/run-sglang-qwen38"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/hf"
: > "$test_root/template.jinja"

cat > "$test_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >> "$DOCKER_LOG"
if [[ "$1" = info ]]; then
  printf ' cdi: nvidia.com/gpu=all\n'
fi
EOF
cat > "$test_root/bin/dgx-gpu-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "$CAPTURE"
EOF
chmod +x "$test_root/bin/docker" "$test_root/bin/dgx-gpu-run"

run_launcher() {
  PATH="$test_root/bin:$PATH" \
  DGX_GPU_RUN="$test_root/bin/dgx-gpu-run" \
  HOST_HF_HOME="$test_root/hf" \
  CHAT_TEMPLATE_HOST="$test_root/template.jinja" \
  CONTAINER_NAME="qwen38-launcher-test" \
  CAPTURE="$test_root/capture" \
  DOCKER_LOG="$test_root/docker.log" \
  QWEN38_SPECULATIVE=false \
  "$launcher"
}

assert_has() {
  grep -Fzx -- "$1" "$test_root/capture" >/dev/null ||
    { echo "missing launcher argument: $1" >&2; exit 1; }
}
assert_not_has() {
  if grep -Fzx -- "$1" "$test_root/capture" >/dev/null; then
    echo "unexpected launcher argument: $1" >&2
    exit 1
  fi
}

run_launcher
assert_not_has --enable-torch-compile
assert_has --sleep-on-idle
assert_has extra_buffer_lazy
assert_has bfloat16
assert_has 2048
assert_has --disable-flashinfer-autotune
assert_not_has --disable-cuda-graph
assert_not_has --torch-compile-max-bs

rm -f "$test_root/capture" "$test_root/docker.log"
ENABLE_TORCH_COMPILE=true \
CHUNKED_PREFILL_SIZE=2048 \
MAMBA_SSM_DTYPE=bfloat16 \
MAMBA_STRATEGY=no_buffer \
MAX_RUNNING_REQUESTS=3 \
CUDA_GRAPH_MAX_BS=8 \
DISABLE_FLASHINFER_AUTOTUNE=true \
SLEEP_ON_IDLE=false \
run_launcher
assert_has --enable-torch-compile
assert_has --torch-compile-max-bs
assert_has --chunked-prefill-size
assert_has 2048
assert_has --mamba-ssm-dtype
assert_has bfloat16
assert_has no_buffer
assert_has --max-running-requests
assert_has 3
assert_has --cuda-graph-max-bs
assert_has 8
assert_has --disable-flashinfer-autotune
assert_not_has --sleep-on-idle

rm -f "$test_root/docker.log"
if PATH="$test_root/bin:$PATH" \
  DGX_GPU_RUN="$test_root/bin/dgx-gpu-run" \
  HOST_HF_HOME="$test_root/hf" \
  CHAT_TEMPLATE_HOST="$test_root/template.jinja" \
  DOCKER_LOG="$test_root/docker.log" \
  ENABLE_TORCH_COMPILE=invalid \
  "$launcher" >"$test_root/invalid.out" 2>"$test_root/invalid.err"; then
  echo "invalid ENABLE_TORCH_COMPILE unexpectedly succeeded" >&2
  exit 1
fi
grep -F 'ENABLE_TORCH_COMPILE must be exactly true or false' "$test_root/invalid.err" >/dev/null
[[ ! -e "$test_root/docker.log" ]] ||
  { echo "invalid configuration reached docker preflight" >&2; exit 1; }

for bad in CHUNKED_PREFILL_SIZE=0 MAX_RUNNING_REQUESTS=-1 CUDA_GRAPH_MAX_BS=1.5 MAMBA_SSM_DTYPE=fp16 MAMBA_STRATEGY=unknown SLEEP_ON_IDLE=maybe DISABLE_FLASHINFER_AUTOTUNE=maybe TORCH_COMPILE_MAX_BS=0; do
  rm -f "$test_root/docker.log"
  if env PATH="$test_root/bin:$PATH" DGX_GPU_RUN="$test_root/bin/dgx-gpu-run" HOST_HF_HOME="$test_root/hf" CHAT_TEMPLATE_HOST="$test_root/template.jinja" DOCKER_LOG="$test_root/docker.log" ENABLE_TORCH_COMPILE=true "$bad" "$launcher" >"$test_root/invalid.out" 2>"$test_root/invalid.err"; then
    echo "invalid control unexpectedly succeeded: $bad" >&2; exit 1
  else
    code=$?
    [[ "$code" = 78 ]] || { echo "unexpected rejection code: $code" >&2; exit 1; }
  fi
  grep -F "${bad%%=*} must be" "$test_root/invalid.err" >/dev/null
  [[ ! -e "$test_root/docker.log" ]] || { echo "invalid control reached docker" >&2; exit 1; }
done

# A kernel cache contains executable artifacts; only an explicit private
# directory owned by the operator may be mounted into the container.
mkdir -m 700 "$test_root/kernel-cache"
mkdir -m 755 "$test_root/public-cache"
ln -s "$test_root/kernel-cache" "$test_root/cache-link"
for bad_cache in relative "$test_root/missing" "$test_root/template.jinja" "$test_root/public-cache" "$test_root/cache-link"; do
  rm -f "$test_root/docker.log"
  if QWEN38_KERNEL_CACHE_DIR="$bad_cache" run_launcher >"$test_root/cache.out" 2>&1; then
    echo "invalid kernel cache unexpectedly accepted: $bad_cache" >&2; exit 1
  else
    code=$?
    [[ "$code" = 78 ]] || { cat "$test_root/cache.out"; exit 1; }
  fi
  [[ ! -e "$test_root/docker.log" ]] || { echo "invalid cache reached docker" >&2; exit 1; }
done
QWEN38_KERNEL_CACHE_DIR="$test_root/kernel-cache" run_launcher
assert_has "type=bind,src=$test_root/kernel-cache,dst=/root/.cache"
QWEN38_KERNEL_CACHE_DIR= run_launcher
assert_not_has "type=bind,src=$test_root/kernel-cache,dst=/root/.cache"
