# Handoff: NVIDIA Driver Missing After Kernel Upgrade

**Generated**: 2026-05-23
**Branch**: main
**Status**: Blocked — awaiting `sudo apt install` to restore GPU access

## Goal

Restore GPU access on the DGX Spark GB10 so that `docker-llm-switch comfyui` (and all other GPU workloads) work again. Immediate trigger was `nvidia-container-cli: initialization error: nvml error: driver not loaded`.

## Completed

- [x] Diagnosed root cause: kernel ABI bumped `6.17.0-1014` → `6.17.0-1018` but matching NVIDIA open module package was never installed
- [x] Confirmed fix package exists in Ubuntu repos: `linux-modules-nvidia-580-open-6.17.0-1018-nvidia` (version `6.17.0-1018.18+1`)
- [x] Verified the issue is not documented anywhere in the repo

## Not Yet Done

- [ ] Install the missing module package (requires `sudo`)
- [ ] Load the module without rebooting (`sudo modprobe nvidia`)
- [ ] Verify with `nvidia-smi`
- [ ] Re-run `docker-llm-switch comfyui` to confirm GPU access works
- [ ] Consider pinning HWE metapackage to prevent recurrence (see Warnings)

## Failed Approaches (Don't Repeat These)

None — pure diagnostic session. No fix attempted yet.

## Current State

**Working**: Everything except GPU. Docker, systemd services, and `docker-llm-switch` logic are all fine.

**Broken**: `nvidia-smi` fails. No `/dev/nvidia*` devices. No NVIDIA kernel modules in `lsmod`. All GPU-dependent workloads fail with the same `nvml error: driver not loaded`.

**Uncommitted Changes**: None — clean working tree.

## Diagnostic Evidence

```
lsmod | grep nvidia  →  (empty)
ls /dev/nvidia*      →  No such file or directory
modinfo nvidia       →  Module nvidia not found.
nvidia-smi           →  NVIDIA-SMI has failed — couldn't communicate with NVIDIA driver.
```

Package gap:
```
ii   linux-modules-nvidia-580-open-6.17.0-1014-nvidia   ← installed (wrong ABI)
     linux-modules-nvidia-580-open-6.17.0-1018-nvidia   ← NOT installed (running kernel)
```

## Resume Instructions

1. **Install the missing module package**:
   ```bash
   sudo apt install linux-modules-nvidia-580-open-6.17.0-1018-nvidia
   ```
   Expected: installs `.ko.zst` files into `/lib/modules/6.17.0-1018-nvidia/`.

2. **Load without rebooting**:
   ```bash
   sudo modprobe nvidia
   ```
   Expected: no output. If it errors → skip to step 4.

3. **Verify**:
   ```bash
   nvidia-smi
   ```
   Expected: table showing GB10 GPU, driver 580.x, CUDA 13.x.

4. **Test Docker GPU access**:
   ```bash
   docker-llm-switch comfyui
   ```
   Expected: ComfyUI starts on port 8188 without `nvml error`.

   If modprobe failed → `sudo reboot`, then verify with `nvidia-smi` after login.

5. **(Optional) Prevent recurrence**:
   ```bash
   apt-cache policy linux-modules-nvidia-580-open-nvidia-hwe-24.04
   ```
   If `Installed` still ends in `1014`, install the HWE metapackage so future kernel upgrades pull matching modules automatically.

## Warnings

- `nvidia-fs.ko.zst` is present for `1018` — only the main `nvidia` module was missing. Don't be confused by it showing up in `/lib/modules/6.17.0-1018-nvidia/ubuntu/nvidia-fs/`.
- This is a host-level fix. Don't modify container configs or `docker-llm-switch`.
- After `modprobe nvidia` succeeds, Docker picks up `/dev/nvidia*` immediately — no daemon restart needed.

---

## Previous Session Context (Model Download — still pending)

- Download: `hf download unsloth/Qwen3.6-27B-MTP-GGUF Qwen3.6-27B-UD-Q4_K_XL.gguf --local-dir ~/models`
- Do NOT use `Qwen3.6-27B-MTP-UD-Q4_K_XL.gguf` — "MTP" is repo name only, not in filenames
- After download: update `--model` in `~/.config/systemd/user/llm-coder.service` + `systemctl --user daemon-reload`
