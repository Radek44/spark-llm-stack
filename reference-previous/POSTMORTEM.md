# DGX Spark LLM Stack — Post-Mortem

**Incident:** OOM brick loop  
**Hardware:** DGX Spark GB10, 121 GB unified memory  
**Severity:** High — host unusable, 15+ unplanned reboots  
**Status:** Resolved, hardened  

---

## Summary

The host entered a self-perpetuating crash-reboot cycle when six heavyweight LLM
services auto-started in parallel at boot. Their combined footprint (~267 GB)
exceeded the 121 GB unified memory pool. The kernel OOM-killer fired, systemd
respawned each killed service via `Restart=on-failure`, and the cycle repeated
on every subsequent boot.

---

## Root cause: seven compounding factors

No single misconfiguration caused this. All seven contributed.

```
factor                                           category         severity
───────────────────────────────────────────────  ───────────────  ────────
1. Six services enabled in default.target         boot autostart   HIGH
2. No MemoryMax on any service                    resource limits  HIGH
3. No Conflicts= between heavyweight services     mutual exclusion HIGH
4. Restart=on-failure without OOMPolicy=stop      restart policy   MEDIUM
5. --no-mmap forcing weights into anonymous RAM   flag config      MEDIUM
6. -c 262144 --cache-ram 49152 on every service   flag config      MEDIUM
7. llm-switch enforced exclusion at runtime only  tooling gap      MEDIUM
```

---

## The brick cycle

```
boot
 │
 └─ all 6 model services start in parallel (no Conflicts=)
       gemma-31b     ~70 GB
       qwen27-mtp    ~70 GB
       qwen35-mtp    ~70 GB
       gptoss-20b    ~30 GB
       gemma-vision  ~12 GB
       flux-klein    ~15 GB
       ─────────────────────
       total          ~267 GB  (host has 121 GB)
 │
 ├─ kernel OOM-killer fires → SIGKILL largest cgroup
 ├─ systemd: "killed = failure → Restart=on-failure → respawn in 5s"
 ├─ respawned service loads again → more pressure
 ├─ kernel vmalloc fails (cannot allocate 6 MB region)
 └─ watchdog reboot → repeat on next boot
```

---

## Why each factor mattered

### `--no-mmap` made it unrecoverable

On unified memory, `--no-mmap` forces model weights into **anonymous pages**.
Anonymous pages cannot be evicted under pressure — the kernel's only options
are swap or OOM kill. With mmap enabled, weights live in **page cache** and
can be evicted gracefully when memory pressure builds.

On a discrete GPU this distinction matters less. On a unified memory system,
`--no-mmap` converts soft memory pressure into hard OOM failure.

### `Restart=on-failure` without `OOMPolicy=stop` creates a respawn loop

systemd interprets SIGKILL from the OOM killer as a "failure" and triggers
`Restart=on-failure`. This is correct for crashes, but catastrophic here:
the service restarts into the same OOM pressure, compounding it.

`OOMPolicy=stop` converts an OOM kill into a deliberate halt that systemd
does not retry. It must be paired with `Restart=on-failure` for any
memory-heavy service.

### Runtime mutual exclusion ≠ boot-time mutual exclusion

`llm-switch` stopped conflicting services when you switched at runtime.
But at boot, systemd started all enabled services in parallel before
`llm-switch` ran. The runtime tool had no effect on boot behaviour.

`Conflicts=` in the systemd unit enforces exclusion at the systemd level,
including at boot. `llm-switch boot-default <slot>` ensures only one service
is enabled at any time.

---

## Remediations

### 1. Zero heavyweight autostart at boot

```bash
systemctl --user disable <all model services>
llm-switch boot-default architect   # only one service autostarts
```

### 2. cgroup memory caps via drop-ins

Applied to every service via `harden-llm-stack.sh`:

```ini
[Service]
MemoryHigh=70G          # soft limit — kernel starts reclaiming
MemoryMax=80G           # hard limit — kernel OOMs this cgroup only
OOMPolicy=stop          # OOM = halt, not respawn
OOMScoreAdjust=200      # prefer killing this over system processes
Restart=on-failure
RestartSec=15
StartLimitBurst=3       # give up after 3 failures in 10 minutes
StartLimitIntervalSec=600
```

Caps by service:

| Service | MemoryHigh | MemoryMax |
|---|---|---|
| qwen27-mtp, qwen35-mtp, gemma-31b | 70G | 80G |
| gptoss-20b, comfyui | 30G | 40G |
| gemma-vision | 15G | 20G |
| flux-klein | 12G | 16G |

### 3. Mutual exclusion via `Conflicts=`

Each heavyweight service's drop-in lists all other heavyweights in `Conflicts=`.
`systemctl start qwen27-mtp` now automatically stops any conflicting service —
at runtime and at boot.

### 4. ExecStart flag cleanup

Removed from every service:

| Flag | Reason removed |
|---|---|
| `--no-mmap` | Weights return to page cache, evictable under pressure |
| `--mlock` | Was pinning 50+ GB permanently, preventing kernel reclaim |

### 5. llm-switch v2 — boot state commands

```bash
llm-switch boot-safe              # disable all model autostart
llm-switch boot-default <slot>    # enable exactly one slot
llm-switch boot-status            # verify before rebooting
```

---

## Lessons learned

**1. `systemctl disable` does not stop a running service.**  
It removes the autostart symlink only. Mental model: `enable`/`disable` controls
future boots; `start`/`stop` controls right now.

**2. `OOMPolicy=stop` must be paired with `Restart=on-failure`.**  
Without `OOMPolicy=stop`, an OOM kill triggers automatic respawn into more
pressure. These two settings must always appear together on memory-heavy services.

**3. `--no-mmap` is wrong on unified-memory hardware.**  
It trades the kernel's best eviction strategy for a marginal load-time speedup.
On discrete GPU it's debatable; on unified memory it's harmful.

**4. Runtime mutual exclusion is not boot-time mutual exclusion.**  
A tool that stops services on switch does nothing about parallel autostart at boot.
Use `Conflicts=` in the unit file for systemd-level enforcement.

**5. `journalctl --list-boots` is a high-signal diagnostic.**  
15 boots in 12 hours is a system asking for help. Check it early.

---

## Useful diagnostic commands

```bash
# What autostarts at boot?
llm-switch boot-status
systemctl --user list-unit-files --state=enabled | grep -iE 'gemma|qwen|gpt|flux|comfy'

# What is running right now?
llm-switch status

# Effective config after all drop-ins merged
systemctl --user show <unit> -p MemoryMax,OOMPolicy,Restart,Conflicts

# cgroup memory view (more accurate than nvidia-smi on unified memory)
systemd-cgtop -n 1 -m --depth=3

# Boot health
journalctl --list-boots | tail -10
# Should grow ~1/day; 15 boots in 12 hours = incident

# Recent OOM events
journalctl --since '24h ago' -k | grep -iE 'oom|killed process|out of memory'

# Revert all hardening drop-ins
bash systemd/harden-llm-stack.sh --revert
```
