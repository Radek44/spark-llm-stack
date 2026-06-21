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
cp vllm-qwen36-35b-nvfp4.service gemma4-v2-coder.service litellm.service flux-klein.service ~/.config/systemd/user/
[ -f comfyui.service ] && cp comfyui.service ~/.config/systemd/user/
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

1. Install vLLM in `~/venvs/vllm-gb10` or create a drop-in overriding `VLLM_PYTHON`.
2. Keep `vllm-qwen36-35b-nvfp4.service` disabled at boot.
3. Start vLLM on demand only:
   ```bash
   llm-switch fast_local
   curl -s http://127.0.0.1:8170/v1/models
   ```
4. Benchmark before even considering a heavyweight boot default. Prefer `llm-switch boot-router` for normal operation.

## LiteLLM

1. LiteLLM lives in `~/venvs/litellm` unless overridden.
2. Start the router:
   ```bash
   llm-switch litellm
   curl -s http://127.0.0.1:8180/v1/models
   ```
3. Point Hermes at `hermes-config-snippet.yaml` only after vLLM is verified.
4. Do not configure cloud fallbacks for `private_local`.

## Small coder experiment

`small_coder` is a manual-only llama.cpp service for `yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF` Q4_K_M.

```bash
llm-switch small_coder
curl -s http://127.0.0.1:8190/v1/models
```

This slot conflicts with the heavyweight vLLM service, so switching to it stops `fast_local` first. Keep it disabled at boot; use it for coding subagent experiments and compare results before making it part of regular routing.

## Safe autostart policy

Recommended boot policy for this DGX Spark:

```bash
llm-switch boot-router
```

This enables only `litellm.service` at boot. Model/media services (`fast_local`, `small_coder`, `imagine`, `comfyui`) stay disabled and are started explicitly with `llm-switch` after memory checks. `llm-switch boot-default <heavy-slot>` refuses heavyweight boot defaults unless `--force-heavy` is provided.

Avoid socket-activating vLLM directly on port 8170: a health probe or accidental request could load the full checkpoint and reproduce the previous memory-pressure failure mode.

## Cleaning old HF cache

Old removed GGUF caches can be purged with:

```bash
hf cache ls
hf cache rm model/unsloth/Qwen3.6-35B-A3B-MTP-GGUF \
  model/unsloth/Qwen3.6-35B-A3B-GGUF \
  model/unsloth/Qwen3.6-27B-MTP-GGUF \
  model/unsloth/gemma-4-31B-it-GGUF \
  model/unsloth/gemma-4-E4B-it-GGUF \
  model/ggml-org/gpt-oss-20b-GGUF \
  model/Zyphra/ZAYA1-8B \
  --yes
```

## Emergency recovery

```bash
llm-switch off
llm-switch boot-safe
systemctl --user --failed
journalctl --user -u vllm-qwen36-35b-nvfp4.service -n 100 --no-pager
journalctl --user -u litellm.service -n 100 --no-pager
journalctl --since '24h ago' -k | grep -iE 'oom|killed process|out of memory' || true
free -h
```
