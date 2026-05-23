# DGX Spark LLM Stack — Incident Report

**Incident:** NVIDIA driver fails to load after `apt upgrade` — GPU workloads
all return `nvml error: driver not loaded`
**Hardware:** DGX Spark GB10, Ubuntu 24.04, kernel `6.17.0-1018-nvidia`,
driver 580-open
**Severity:** High — no GPU access on the host; every Docker/systemd LLM
slot, ComfyUI, FLUX, and `nvidia-smi` itself are dead until fixed
**Status:** Resolved on this host, hardened in docs

---

## Summary

After a routine `sudo apt update && sudo apt upgrade`, the next reboot left
the host with **no working NVIDIA driver**. `nvidia-smi` printed *"NVIDIA-SMI
has failed because it couldn't communicate with the NVIDIA driver"*, `lsmod
| grep nvidia` was empty, `/dev/nvidia*` did not exist, and `modinfo nvidia`
reported the module was not found. Everything in this repo that touches the
GPU — `llm-switch`, `docker-llm-switch`, FLUX, ComfyUI — failed identically
with `nvidia-container-cli: initialization error: nvml error: driver not
loaded`.

The userland driver was intact. The CUDA libraries were intact. What was
missing was the **kernel module package matching the new kernel ABI**.

---

## Root cause: kernel ABI / module package mismatch

On DGX Spark, the 580-open driver is delivered in two parts:

1. The userland driver, libraries, and tools
   (`nvidia-driver-580-open`, `libnvidia-*`, `nvidia-utils-*`).
2. A separate **kernel-ABI-locked** module package
   (`linux-modules-nvidia-580-open-<KVER>-nvidia`) — one package per kernel
   ABI such as `6.17.0-1014-nvidia`, `6.17.0-1018-nvidia`, etc.

When `apt upgrade` advanced the kernel ABI from `6.17.0-1014` to
`6.17.0-1018`, the matching module package
(`linux-modules-nvidia-580-open-6.17.0-1018-nvidia`) **was not pulled in
automatically**. After reboot the host was running a kernel that had no
NVIDIA `.ko` files installed for it.

```
factor                                              category         severity
──────────────────────────────────────────────────  ───────────────  ────────
1. Kernel ABI bumped 1014 → 1018                    apt upgrade      HIGH
2. Matching linux-modules-nvidia-580-open pkg       missing dep      HIGH
   for the new ABI was NOT installed
3. No HWE metapackage holding modules in lockstep   pkg topology     HIGH
4. No nvidia-driver-pinning-580 enforcing           pkg topology     MEDIUM
   consistent userland/module versions
5. Reboot triggered before anyone noticed the gap   ops              LOW
```

---

## How the failure looked

```
$ uname -r
6.17.0-1018-nvidia

$ nvidia-smi
NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.

$ lsmod | grep nvidia        # (empty)
$ ls /dev/nvidia*            # No such file or directory
$ modinfo nvidia             # Module nvidia not found.

$ dpkg -l | grep linux-modules-nvidia-580-open
ii  linux-modules-nvidia-580-open-6.17.0-1014-nvidia   # OLD kernel
                                                       # (nothing for -1018)

$ docker-llm-switch comfyui
nvidia-container-cli: initialization error: nvml error: driver not loaded
```

The `.ko` files for the running kernel were simply not on disk:

```
$ ls /lib/modules/$(uname -r)/kernel/drivers/ | grep -i nvidia
# (empty)
```

---

## Why each factor mattered

### Userland driver alone is not enough

The 580-open `nvidia` kernel module is **not** built from DKMS sources on
DGX Spark — it is delivered prebuilt, one binary blob per kernel ABI. If the
matching `linux-modules-nvidia-580-open-<KVER>-nvidia` package is absent, no
amount of `nvidia-driver-580-open` will produce `/dev/nvidia*`.

### `apt upgrade` does not always pull the matching modules

This is the surprising part. Ubuntu's apt resolver pulled the new kernel
package but did not pull the corresponding 580-open module package, because
the dependency that should chain them — the
`linux-modules-nvidia-580-open-nvidia-hwe-24.04` HWE metapackage — was not
installed on this host. Without that metapackage, there is no `Depends:`
edge tying "kernel ABI X" to "NVIDIA modules for ABI X".

### `nvidia-driver-pinning-580` was not installed

Driver 580+ introduces a *pinning* package (`nvidia-driver-pinning-580`)
specifically to keep userland and module packages on consistent versions.
Without it, partial upgrades like this one are possible — userland advances,
module package does not.

### Diagnosis is non-obvious if you only look at the userland

`apt list --installed | grep nvidia-driver` shows the driver as present.
`nvidia-smi --version` does not work because the kernel module is missing.
You have to compare `uname -r` against
`dpkg -l | grep linux-modules-nvidia-580-open` to see the gap.

---

## Remediation

### Immediate fix (no reinstall, no reboot if it works)

```bash
sudo apt update
sudo apt install linux-modules-nvidia-580-open-$(uname -r)
sudo modprobe nvidia
nvidia-smi    # GB10 table should print
```

NVIDIA support recommends the same shape of fix on the DGX Spark forum,
sometimes pinning the userland version explicitly to match the modules:

```bash
sudo apt install \
    nvidia-driver-580-open=<exact-version> \
    linux-modules-nvidia-580-open-$(uname -r)
```

If `modprobe nvidia` fails after install, reboot — the initramfs needs to
pick up the new modules.

### Prevention (apply once, holds across future upgrades)

```bash
# 1. HWE metapackage — apt now pulls matching modules on every kernel bump
sudo apt install linux-modules-nvidia-580-open-nvidia-hwe-24.04

# 2. Pinning package — keeps userland and module packages on consistent versions
sudo apt install nvidia-driver-pinning-580
```

After these are installed, future `apt upgrade` runs will keep the module
package in lockstep with the running kernel.

### Pre-upgrade discipline

```bash
# Before any apt upgrade that includes a kernel:
apt list --upgradable 2>/dev/null | grep -E 'linux-image|linux-modules-nvidia'
# If you see a new linux-image without a matching linux-modules-nvidia-580-open:
#   STOP. Investigate before rebooting.
```

### Post-upgrade verification (before reboot)

```bash
NEW_KVER=$(dpkg -l | awk '/^ii .* linux-image-.*-nvidia/ {print $2}' \
           | sed 's/linux-image-//' | sort -V | tail -1)
dpkg -l | grep "linux-modules-nvidia-580-open-${NEW_KVER}" || {
    echo "MISSING: linux-modules-nvidia-580-open-${NEW_KVER}"
    echo "Do not reboot. Run: sudo apt install linux-modules-nvidia-580-open-${NEW_KVER}"
}
```

---

## Why we are confident in this diagnosis

This is not speculation. The exact symptom — `nvidia-smi` failing after a
clean `apt upgrade` on a DGX Spark — and the exact fix
(`apt install linux-modules-nvidia-580-open-<KVER>-nvidia`) are documented
by NVIDIA staff and reproduced by multiple DGX Spark users:

- **NVIDIA Developer Forum #371099** — *"nvidia-smi does not work after
  update/upgrade from terminal"*. NVIDIA-recommended fix is literally
  `sudo apt install nvidia-driver-580-open=580.159.03-0ubuntu0.24.04.1
  linux-modules-nvidia-580-open-6.17.0-1018-nvidia` — same kernel ABI, same
  package name we identified.
  https://forums.developer.nvidia.com/t/nvidia-smi-does-not-work-after-update-upgrade-from-terminal/371099

- **NVIDIA Developer Forum #352122** — *"DGX Spark – Unable to Load NVIDIA
  Drivers / DGX Dashboard Updates Stuck"*. Same symptom class; NVIDIA staff
  walked the reporter through `dpkg -l | grep 580` to identify missing
  module packages.
  https://forums.developer.nvidia.com/t/dgx-spark-unable-to-load-nvidia-drivers-dgx-dashboard-updates-stuck/352122

- **NVIDIA Developer Forum #351828** — *"DGX Spark NVIDIA driver issue"*.
  Another instance of post-upgrade driver loss.
  https://forums.developer.nvidia.com/t/dgx-spark-nvidia-driver-issue/351828

- **NVIDIA Developer Forum #351579** — *"Reinstalling the NVIDIA driver on
  DGX Spark"*. NVIDIA-documented reinstall path; confirms the userland +
  per-kernel-modules split.
  https://forums.developer.nvidia.com/t/reinstalling-the-nvidia-driver-on-dgx-spark/351579

- **NVIDIA Developer Forum #365280** — *"DGX Spark Boot Hang at 'EFI stub'
  after Kernel 6.17 / Driver 570-server Upgrade Issue"*. Related class of
  failure: kernel upgrade on DGX Spark moves faster than the driver
  packaging, leaving systems in broken states.
  https://forums.developer.nvidia.com/t/dgx-spark-boot-hang-at-efi-stub-after-kernel-6-17-driver-570-server-upgrade-issue/365280

- **NVIDIA Aerial install guide** — DGX Spark driver install procedure
  explicitly installs `nvidia-driver-pinning-580` *before* the driver,
  acknowledging that 580+ packaging requires a pinning package to stay
  consistent.
  https://docs.nvidia.com/aerial/cuda-accelerated-ran/latest/install_guide/installing_tools_spark.html

- **NVIDIA DGX OS 7 User Guide — Managing OS and Software Updates** —
  documents that the DGX OS update path is the supported one and that
  ad-hoc apt operations can produce inconsistent states.
  https://docs.nvidia.com/dgx/dgx-os-7-user-guide/additional_software.html

The combination of (a) NVIDIA staff prescribing the *exact* apt command for
the *exact* kernel ABI we saw, and (b) the 580-driver-pinning package
existing specifically to prevent this class of inconsistency, makes the
diagnosis very high confidence.

---

## Lessons learned

**1. On DGX Spark, the NVIDIA "driver" is two packages, not one.**
Userland (`nvidia-driver-580-open`) and per-kernel-ABI modules
(`linux-modules-nvidia-580-open-<KVER>-nvidia`) must both be present for
`nvidia-smi` to work. `dpkg -l | grep nvidia-driver` alone is not enough to
prove the driver is healthy.

**2. `apt upgrade` is not safe-by-default for the NVIDIA stack.**
Without the HWE metapackage and the pinning package, apt can advance the
kernel and leave the matching NVIDIA module package uninstalled. The system
boots fine; only GPU workloads fail.

**3. Always install the HWE metapackage and the pinning package on
day one.** They are the only mechanism that guarantees kernel/module
co-installation across future upgrades:
- `linux-modules-nvidia-580-open-nvidia-hwe-24.04`
- `nvidia-driver-pinning-580`

**4. The diagnostic fingerprint is small and worth memorising.**
`lsmod | grep nvidia` empty + `dpkg -l | grep linux-modules-nvidia-580-open`
not matching `uname -r` ⇒ ABI mismatch. Don't go looking for Docker bugs,
container runtime bugs, or CUDA bugs first — check the module package.

**5. This is not a one-off — it's a recurring DGX Spark class of failure.**
Multiple NVIDIA-staffed forum threads describe the same symptom and the
same fix. Treat it as a known gremlin, document it in the repo, and warn
operators before the next `apt upgrade`.

---

## Useful diagnostic commands

```bash
# Quick triage — is the kernel module even on disk for this kernel?
uname -r
dpkg -l | grep linux-modules-nvidia-580-open
ls /lib/modules/$(uname -r)/kernel/drivers/ 2>/dev/null | grep -i nvidia

# Is anything loaded?
lsmod | grep nvidia
ls /dev/nvidia*

# Userland sanity
dpkg -l | grep -E 'nvidia-driver|nvidia-utils|libnvidia'
apt-cache policy nvidia-driver-pinning-580
apt-cache policy linux-modules-nvidia-580-open-nvidia-hwe-24.04

# Try to load without reboot once the package is installed
sudo modprobe nvidia && nvidia-smi

# Docker GPU access (should work as soon as /dev/nvidia* exists)
docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
```
