# Operations runbook

## Golden rules

- Never run multiple heavyweight checkpoint services unless deliberately testing and memory budget is confirmed.
- Prefer `llm-switch` over raw `systemctl start` for model/media services.
- Check `free -h` before and after model switches.
- Keep endpoints bound to `127.0.0.1`.
- Keep API keys out of repo files.

## Baseline checks

```bash
git status --short
free -h
llm-switch status
llm-switch boot-status
systemctl --user list-units --type=service --all | grep -Ei 'flux|comfy|vllm|litellm|hermes'
systemctl --user list-unit-files | grep -Ei 'flux|comfy|vllm|litellm|hermes'
journalctl --list-boots | tail -10
journalctl --since '24h ago' -k | grep -iE 'oom|killed process|out of memory' || true
```

## Install/update templates

```bash
mkdir -p ~/.config/systemd/user
cp vllm-laguna-s21-nvfp4.service sglang-qwen38-nvfp4.service \
  qwen-sglang-broker-lifecycle.service litellm.service flux-klein.service comfyui.service \
  ~/.config/systemd/user/
for d in drop-ins/*/; do
  svc=$(basename "$d")
  mkdir -p ~/.config/systemd/user/$svc
  cp "$d/override.conf" ~/.config/systemd/user/$svc/
done
cp llm-switch ~/.local/bin/ && chmod +x ~/.local/bin/llm-switch
cp flux-gen ~/.local/bin/ && chmod +x ~/.local/bin/flux-gen
chmod +x scripts/check-memavailable-kib
systemctl --user daemon-reload
```

## vLLM

1. Install vLLM 0.26.0 in `~/venvs/vllm-laguna-0.26.0`.
2. Download the revision-pinned Spark-safe Laguna target (`07614121...`) and matched DFlash draft (`4cdcc6e9...`) into `~/models/huggingface`. Do not point this unit at the rejected 92.85 GiB `f8fdfcdc...` target.
3. Keep the vLLM service disabled at boot.
4. Start the accepted eager+DFlash service on demand:
   ```bash
   llm-switch fast_local
   curl -s http://127.0.0.1:8170/v1/models
   ```
   Keep `KV_CACHE_MEMORY_BYTES=4294967296` and `KV_CACHE_DTYPE=bfloat16`. Do not replace it with
   `--gpu-memory-utilization`: vLLM's percentage heuristic attempted a roughly
   29 GiB cache on this unified-memory host and triggered NVIDIA allocation
   failures. A larger cache is a separate monitored promotion gate. The local
   vLLM 0.26.0 FP8-KV canary also failed its output-quality gate with severe
   repetition, so FP8 KV must remain off until separately requalified. Keep
   `PYTORCH_ALLOC_CONF=expandable_segments:False`; the experimental
   allocator caused driver allocation errors while DFlash attached.
5. Verify thinking on/off and tool calls directly and through LiteLLM.
6. Verify nonzero DFlash accepted-token metrics and a clean kernel log from the service start time.
7. Benchmark before even considering a heavyweight boot default. Prefer `llm-switch boot-router` for normal operation.

## LiteLLM

1. LiteLLM lives in `~/venvs/litellm` unless overridden.
2. Start the router:
   ```bash
   llm-switch litellm
   curl -s http://127.0.0.1:8180/v1/models
   ```
3. Point Hermes at `hermes-config-snippet.yaml` only after vLLM is verified.
4. Do not configure cloud fallbacks for `private_local`.

## Safe autostart policy

Recommended boot policy for this DGX Spark:

```bash
llm-switch boot-router
```

This enables only `litellm.service` at boot. Model/media services (`fast_local`, `imagine`, `comfyui`) stay disabled and are started explicitly with `llm-switch` after memory checks. `llm-switch boot-default <heavy-slot>` refuses heavyweight boot defaults unless `--force-heavy` is provided.

Avoid socket-activating vLLM directly on port 8170: a health probe or accidental request could load the full checkpoint and reproduce the previous memory-pressure failure mode.

## Qwen broker residency (not yet activated)

The tracked Qwen adapter is default-off. Merely copying its unit does not register a
residency, enable Qwen, or change the registry's `off` policy. Before any opt-in:

1. Run `scripts/check-qwen-sglang-broker-lifecycle.py` and `scripts/validate-stack`.
2. Complete the Linux cgroup, `MainPID`, CUDA, `/proc/locks`, and broker kill-point spike
   required by `~/ai-agent-os/docs/DGX-GPU-BROKER.md` from an isolated clean worktree.
   In particular, prove that `dgx-gpu-run` is the unit `MainPID` and exact flock holder, and
   that the rootful Docker CUDA PID is visible inside the user unit's cgroup. A
   `resident-process-count-mismatch` is a stop condition, not an exception to waive.
3. Confirm `agentos gpu residencies` has no contradictory active row and Qwen remains disabled.
4. Create the owner-only environment file and enable only
   `qwen-sglang-broker-lifecycle.service` as documented in `README.md`. This recovery oneshot
   does not enable or start Qwen.

The lifecycle state file is durable recovery evidence, not a second GPU exclusion authority.
The canonical flock remains the sole exclusion lock, and generations must never be hand-edited
or reused. Registration requires systemd plus HTTP readiness and the broker's exact service,
holder, CUDA-count, lease, and flock proof. Release waits for `MainPID=0`, exact holder death,
an empty global CUDA set, and disappearance of the recorded WRITE FLOCK; any missing proof
fails closed. Run `scripts/qwen-sglang-broker-lifecycle status` and
`agentos gpu residencies` to reconcile failures.

Do not set the global broker policy to `enforced` for Qwen. Resident bootstrap is circular in
v1 and remains an explicit contract blocker; this adapter supports only the reviewed per-run
shadow transition.

## Unified-memory safety

Every GPU service must run through `~/ai-agent-os/bin/dgx-gpu-run`. The launcher holds one machine-wide lease and monitors `MemAvailable` while the child is running; it terminates the process group before the profile floor is exhausted. Systemd cgroup limits are secondary because NVIDIA allocations are not guaranteed to be charged in time to protect a unified-memory host.

GPU services wait at most 30 seconds for the lease. Contention exits with status 75 and never leaves a unit waiting to start later; readiness timeouts also stop the target unit.

`llm-switch status` reports systemd slots, the shared lease, and Asset Forge GPU containers. Use `llm-switch all-off` before a high-memory canary to stop TRELLIS/rig containers while leaving the CPU-only Asset Forge control plane available.

Promote Laguna one variable at a time: target-only eager at 32K, DFlash plus eager at 32K, DFlash plus graph capture at 32K, then longer context. Never combine a cold DFlash load, cold kernel compilation, graph capture, and a context increase in one canary.

The 2026-08-01 superseding Poolside target reached 19.3 GiB `MemAvailable` and was terminated by the 20 GiB floor. Its local cache was removed after the Spark-safe pin passed acceptance. Do not lower the floor to force it onto this host.

The Spark-safe target itself fits, but percentage-based KV auto-sizing tried to
reserve roughly 29 GiB after the 67 GiB weight load and crossed the same floor,
with NVIDIA allocation errors in the kernel log. The explicit 4 GiB BF16 KV cache
replaces that heuristic; continue filtering kernel logs from each canary's start
time because the earlier errors remain in the current boot journal. Keep
`expandable_segments:False`; this removed the DFlash draft-attachment errors.

ComfyUI must not use `--gpu-only` or `--highvram` on this machine. The deployed service disables pinned memory, reserves OS headroom, uses disk-backed offload, uses PyTorch's current `PYTORCH_ALLOC_CONF` name, and has no automatic restart. Run `scripts/validate-stack` after editing any unit.

## Legacy cleanup

After Laguna acceptance, the rollback Qwen, Gemma coder, two Qwen GGUF caches,
old vLLM environment/cache, and the rejected oversized Laguna revision were
removed. Image/video assets and their text encoders were deliberately retained.
Use exact cache IDs and `hf cache rm --dry-run` before any future model purge.

## Emergency recovery

```bash
llm-switch all-off
llm-switch boot-safe
systemctl --user --failed
journalctl --user -u vllm-laguna-s21-nvfp4.service -n 100 --no-pager
journalctl --user -u litellm.service -n 100 --no-pager
journalctl --since '24h ago' -k | grep -iE 'oom|killed process|out of memory' || true
free -h
```
