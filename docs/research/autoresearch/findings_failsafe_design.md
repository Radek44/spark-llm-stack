# Cross-Stack Memory Failsafe — Research & Design

Research date: 2026-05-22
Scope: Why cgroup hard caps don't enforce on DGX Spark UMA, what NVIDIA recommends instead, and the layered design we built on top.

---

## 1. The problem

DGX Spark (GB10, 128 GB LPDDR5X unified memory) runs **two independent Docker stacks** managed by two independent switch scripts:

| Stack | Switch | Containers |
|---|---|---|
| `spark-llm-*` | `docker/docker-llm-switch` | coder, architect, gemma, vision, gptoss, imagine, comfyui |
| `spark-autoresearch-*` | `docker/autoresearch/scripts/autoresearch-switch` | karpathy, dgx, nauto-orch, nauto-worker, gemini, autokernel |

Each switch enforces **intra-stack mutual exclusion** via `stop_all_except`. Nothing prevents a `docker-llm-switch coder` running alongside `autoresearch-switch start dgx`, and once both load weights the host can OOM. On UMA, OOM doesn't mean a Python traceback — it means a kernel-level memory starvation that hangs the host so badly that SSH freezes (a hard power cycle is needed for recovery).

## 2. Why we can't just set `--memory` / `mem_limit` / `MemoryMax=`

The cgroup-based enforcement that works on H100 hosts is **bypassed on GB10** because CUDA's unified-memory allocations go through `/dev/nvidia-uvm`, which is not accounted by cgroup memory controllers. Three primary sources confirm this:

### NVIDIA Forum #264689 — *CUDA unified memory usage is not accounted by Linux cgroup*

> *"Did a simple test by using cuda unified memory to allocate GPU memory with over-subscription, and run that test binary under a linux cgroup with memory constraints of 500MB ... After running this binary, we could see that even with more than 500MB being touched and consumed in this binary, it is not OOM'ed by the linux cgroup, while inspecting the pmap of that process saw the big rss usage."*

The post shows a process mmapping 4 GiB of `/dev/nvidia-uvm` while its containing cgroup has `memory.limit_in_bytes = 500M`. The kernel sees the mapping but doesn't account it against the cgroup. Quote: *"oversubscribed GPU memory by cuda unified memory will not be constrained by the Linux cgroup."*

Source: https://forums.developer.nvidia.com/t/cuda-unified-memory-usage-is-not-accounted-by-linux-cgroup/264689

### NVIDIA Forum #353752 — *DGX Spark becomes unresponsive ("zombie") instead of throwing CUDA OOM*

> *"We tried the `systemd-run` cgroup approach recommended in various guides: `sudo systemd-run --scope -p MemoryMax=100G -p MemorySwapMax=0 docker run --gpus all ...` ... inspecting cgroups from inside the container shows `memory.max` is correctly applied at scope level, but CUDA allocations still see `0::/` with `memory.max = max`. The cgroup tree is doubly broken for this use case. The CUDA driver context lives at the root hierarchy where no limit is imposed."*

Same mechanism, but with the operationally tempting `systemd-run --scope -p MemoryMax=...G` wrapper: still ineffective. The driver runs at the root cgroup and bypasses the imposed limit. Also confirms `MemAvailable` reporting is partially misleading under burst-allocation conditions because of reclaim latency.

Source: https://forums.developer.nvidia.com/t/dgx-spark-becomes-unresponsive-zombie-instead-of-throwing-cuda-oom/353752

### NVIDIA Forum #358951 — *Spark hangs, requires hard reset*

NVIDIA staff response, verbatim:

> *"The behavior difference versus H100 comes down to memory architecture. On H100, GPU memory is discrete — an OOM is contained to the CUDA context and the host stays up. On GB10, CPU and GPU share the same physical memory pool, so an OOM event can starve the kernel itself before the OOM killer gets a chance to act. While waiting for the OS-level fix, the earlyoom approach documented here is a practical mitigation."*

This is the **decisive recommendation**: NVIDIA's official position is that until a DGXos fix lands, earlyoom is the right mitigation for DGX Spark OOM brick-loops.

Source: https://forums.developer.nvidia.com/t/spark-hangs-requires-a-hard-reset-physically-unplugging/358951

## 3. Conclusion: enforcement requires userspace kill authority + mutual exclusion

`mem_limit` and `--memory` remain useful as **planning budgets** and **documentation**. They are not enforcement. The actual safety mechanisms are:

1. **Mutual exclusion**: ensure at most one heavyweight workload owns the memory budget at any given time (or admit only if budgets fit).
2. **Userspace OOM watchdog** with kill authority: detect rising pressure (via PSI or `/proc/meminfo`) and stop containers gracefully *before* the kernel reaches its own OOM threshold (where the host can hang).
3. **Panic / recovery**: a one-shot command that stops everything and reclaims caches.

We already had (1) intra-stack but not cross-stack. We had nothing for (2) or (3).

## 4. Design choices

### Watchdog: earlyoom (chosen) vs systemd-oomd vs custom

| Option | Pro | Con |
|---|---|---|
| **earlyoom** ✅ | NVIDIA-recommended for DGX Spark. ~2 MiB RSS, mlock-ed. Supports `-N` preempt hook to call our `spark-panic` *before* SIGKILL — so we stop containers gracefully instead of leaving zombie CUDA contexts. Single binary, single systemd unit. Works regardless of cgroup membership. | Polls `/proc/meminfo` rather than PSI — slightly less accurate signal, but the user-space hook makes that moot here. |
| systemd-oomd | Uses PSI directly (kernel's own delay-percentage signal). Cgroup-leaf-aware kill candidates. | Requires putting Docker containers into a managed slice — non-trivial reconfiguration of dockerd. Less useful on UMA where the cgroup signal is partially decoupled from real allocation pressure. |
| Custom daemon | Maximally tunable. | More code to own. earlyoom already covers the use case. |

**Decision**: earlyoom, with `-N /usr/local/bin/spark-panic` to chain into our cross-stack cleanup. Thresholds `-m 8,4` (SIGTERM at MemAvailable < 8%, SIGKILL at < 4%) chosen so containers stop while the host still has ~5 GiB headroom — early enough that SSH stays responsive.

### Cross-stack policy: gate + force-serial fallback (chosen) vs strict serial vs preflight-only

`autoresearch-switch start <X>` and `docker-llm-switch <slot>` both now:

1. Acquire a shared `flock` on `/var/run/spark-mem.lock` (FD 200, 30 s timeout) — serialises concurrent switch invocations across stacks.
2. Read `MemAvailable` from `/proc/meminfo`.
3. Compute projected cap (from `MEMCAP[]` in docker-llm-switch, or `${PROFILE}_MEM_LIMIT` env var for autoresearch).
4. **If `MemAvailable - 8 GiB >= projected_cap`** → admit; let other-stack containers keep running.
5. **Else** → call `spark_cross_stack_stop_others <new_container_name>` to stop everything else with the `spark.exclusive=true` label, then `drop_caches`, then proceed.

This lets small workloads (e.g. `vision` ~20 GiB + `gemini` ~8 GiB) coexist while still being safe when something heavy (e.g. `architect` ~70 GiB or `autokernel` ~70 GiB) needs to load.

### Cross-stack enumeration: Docker labels

Both stacks now stamp containers with:

```
spark.exclusive=true
spark.stack=llm|autoresearch
spark.slot=<slot>   # docker-llm-switch only
```

`docker ps --filter "label=spark.exclusive=true"` gives the single canonical view across both stacks. The autoresearch stack adds the labels through the compose `x-common` block; `docker-llm-switch` adds them via the shared `docker_run_slot` helper.

## 5. Architecture summary

```
┌─ Layer 1: Admission gate (docker/lib/spark-mem.sh, sourced by both switches)
│  acquire flock → check MemAvailable → if won't fit, stop cross-stack set
│
├─ Layer 2: Watchdog (systemd/units/spark-earlyoom.service)
│  earlyoom polls /proc/meminfo at -m 8,4; on threshold:
│  -N hook calls /usr/local/bin/spark-panic BEFORE SIGKILL
│
└─ Layer 3: Panic (tools/spark-panic)
   docker ps --filter "label=spark.exclusive=true" → stop -t 10 each
   docker update --restart=no  → prevent auto-restart cascade
   sync; echo 3 > /proc/sys/vm/drop_caches
```

Triggers and call paths:

```
operator:        spark-panic ──────────────────────────┐
                                                       │
operator:        docker-llm-switch panic ──┐           │
                                            ├──> spark_panic_stop_all
operator:        autoresearch-switch panic ┘           ▲
                                                       │
runtime:         earlyoom -N /usr/local/bin/spark-panic┘
```

## 6. What this can't do

- **Stop a single allocation that exceeds available memory in one syscall.** If a process calls `cudaMallocManaged(120 GiB)` on a host with 100 GiB free, the driver attempt may hang the kernel before earlyoom can fire. The admission gate prevents the *container* from starting in that state, but a misbehaving container that is already running can still cause this. The mitigation is to keep `mem_limit` accurate (planning budget) and trust the watchdog as the secondary line of defence.
- **Stop a workload running outside Docker.** earlyoom kills the offender regardless, but `spark-panic` only sees containers. If you `uv run train.py` directly on the host, it's outside the failsafe scope — use the autoresearch container or run with `systemd-run` so earlyoom can target it.
- **Resurrect work.** Panic is destructive: stopped containers are not restarted. Auto-recovery (restart preferred slot after panic) is out of scope for v1.

## 7. References

- https://forums.developer.nvidia.com/t/cuda-unified-memory-usage-is-not-accounted-by-linux-cgroup/264689 — primary cgroup-bypass evidence
- https://forums.developer.nvidia.com/t/dgx-spark-becomes-unresponsive-zombie-instead-of-throwing-cuda-oom/353752 — `systemd-run --scope` ineffective on UMA
- https://forums.developer.nvidia.com/t/spark-hangs-requires-a-hard-reset-physically-unplugging/358951 — NVIDIA recommends earlyoom
- https://forums.developer.nvidia.com/t/dgx-spark-os-crash-on-llama4-launch/362648 — `cudaMemGetInfo` under-reports on UMA; drop_caches helps
- https://github.com/rfjakob/earlyoom — earlyoom README, `-N` hook semantics, mlockall behaviour
- https://docs.kernel.org/admin-guide/cgroup-v2.html — `memory.high` vs `memory.max` (high is throttle, never invokes OOM killer)
- https://dev.to/lyraalishaikh/stop-linux-memory-death-spirals-early-practical-systemd-oomd-with-psi-and-cgroup-policy-369j — practical PSI thresholds
- https://www.karltarvas.com/bash-using-flock-to-ensure-parallel-scripts-perform-an-action-only-once — canonical bash flock idiom
- `docs/research/autoresearch/findings_dgx_spark_memory.md` — pre-existing repo research on UMA cgroup non-enforcement

---

## 8. Implementation summary (branch `cr1`, uncommitted)

The 3-layer failsafe described above is implemented in this branch. Status as of 2026-05-22.

### New files (4)

| File | Role |
|---|---|
| `docker/lib/spark-mem.sh` | Shared bash library. Exposes `spark_acquire_lock` (flock on `/var/run/spark-mem.lock`, 30 s timeout), `spark_admission_check` (MiB-precision check against `/proc/meminfo MemAvailable` minus 8 GiB headroom), `spark_cross_stack_stop_others`, `spark_drop_caches` (uses `sudo -n` so it never blocks on a password prompt), `spark_panic_stop_all`, `spark_parse_gb`. Sourced by both switches and by `tools/spark-panic`. |
| `tools/spark-panic` | Cross-stack emergency stop. Locates the lib via `$SPARK_MEM_LIB` → repo-relative → `/usr/local/lib/spark-mem.sh` → `/etc/spark-llm-stack/spark-mem.sh`. Stops every container with `label=spark.exclusive=true`, clears restart policies, drops page cache. Idempotent. Wired into earlyoom via `-N`. |
| `systemd/units/spark-earlyoom.service` | System-level earlyoom unit. Thresholds `-m 8,4` (SIGTERM at MemAvailable < 8%, SIGKILL at < 4%), `-N /usr/local/bin/spark-panic` preempt hook (so containers stop gracefully before SIGKILL), `--avoid` regex keeps init/sshd/dockerd safe. Per NVIDIA forum #358951 recommendation. |
| `docs/research/autoresearch/findings_failsafe_design.md` | This document. |

### Modified files (5)

- **`docker/docker-llm-switch`** — sources `spark-mem.sh` (with noop shim fallback); admission gate runs before `run_slot` in the slot-start dispatcher; `docker_run_slot` now stamps every container with `--label spark.exclusive=true --label spark.stack=llm --label spark.slot=<slot>`; new `panic` subcommand.
- **`docker/autoresearch/scripts/autoresearch-switch`** — sources `spark-mem.sh` (uses `readlink -f` so install-via-symlink works); admission gate + `drop_caches` (now BEFORE the check, symmetric with docker-llm-switch) in `cmd_start`; new `cmd_panic` and `panic` subcommand; `projected_cap_gb()` maps each profile to its `${PROFILE}_MEM_LIMIT` env var.
- **`docker/autoresearch/docker-compose.autoresearch.yml`** — adds `labels: spark.exclusive: "true"`, `spark.stack: "autoresearch"` to `x-common` so all 6 profiles inherit.
- **`README.md`** — new "Cross-stack memory failsafe" section with install steps (apt-get earlyoom, cp lib/bin/unit, systemctl enable), required NOPASSWD sudoers line, citation links to forums #264689 / #353752 / #358951.
- **`docs/Plans/AUTORESEARCH-CONTAINERS.md`** — runtime-model section updated to describe cross-stack admission gate, exclusive-label enumeration, earlyoom watchdog, and `panic` subcommand.

### Review fixes applied (after `code-reviewer` pass)

- **CRITICAL-1**: `autoresearch-switch` now uses `readlink -f` for symlink-safe `ROOT_DIR` resolution.
- **CRITICAL-2**: `spark_drop_caches` uses `sudo -n` so it fails fast (logs, continues) instead of hanging on a TTY-less password prompt.
- **HIGH-1**: `spark_acquire_lock` installs an `EXIT` trap that logs lock release.
- **HIGH-2**: `spark_drop_caches` runs BEFORE `spark_admission_check` on both switches — admission sees post-flush memory, prevents spurious cross-stack evictions.
- **HIGH-3**: Removed `$HOME/spark-llm-stack/...` fallback from `tools/spark-panic` (wrong under root when invoked by earlyoom).
- **HIGH-4**: `spark_admission_check` switched to MiB arithmetic — no GiB-truncation rounding errors at the headroom boundary.
- **MEDIUM-1**: Shim `spark_parse_gb` in both switches uses `%%g*` greedy strip so `40gb` correctly parses to `40`, not `40b`.

### Verified locally

- `bash -n` passes on all 4 shell artifacts (`spark-mem.sh`, `spark-panic`, `autoresearch-switch`, `docker-llm-switch`)
- `docker compose -f docker/autoresearch/docker-compose.autoresearch.yml config -q` validates
- Smoke tests pass for `spark_parse_gb` (incl. `40gb` regression), direct-execution guard on the lib, and `EXIT` trap (where flock is available)
- All 4 originally-modified files from the prior UMA-hardening commit (compose ipc/ulimits, drop_caches in cmd_start, ComfyUI patch, karpathy patches) are still intact — they're the foundation this failsafe builds on.

### Install on the DGX host

```bash
sudo apt-get install -y earlyoom
sudo cp docker/lib/spark-mem.sh    /usr/local/lib/spark-mem.sh
sudo cp tools/spark-panic          /usr/local/bin/spark-panic
sudo chmod +x /usr/local/bin/spark-panic
sudo cp systemd/units/spark-earlyoom.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now spark-earlyoom.service
# add to sudoers (visudo): <op> ALL=(root) NOPASSWD: /bin/sh -c sync; echo 3 > /proc/sys/vm/drop_caches
```

### Verification on the DGX host

Run after install:

```bash
# 1. Lock contention
(./docker/autoresearch/scripts/autoresearch-switch start karpathy) &
./docker/autoresearch/scripts/autoresearch-switch start dgx        # blocks on flock

# 2. Cross-stack force-serial fallback
./docker/run.sh coder                                              # 70g cap
./docker/autoresearch/scripts/autoresearch-switch start dgx        # 80g — stops coder

# 3. Admission gate happy path
./docker/run.sh vision                                             # 20g
./docker/autoresearch/scripts/autoresearch-switch start gemini     # 8g — coexists

# 4. earlyoom dry run
journalctl -u spark-earlyoom -f &
stress-ng --vm 1 --vm-bytes 110G --timeout 30s                     # earlyoom fires -N hook

# 5. Panic
spark-panic                                                        # cross-stack stop
docker ps --filter "label=spark.exclusive=true" -q | wc -l         # → 0
```

