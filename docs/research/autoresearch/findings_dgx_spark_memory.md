# DGX Spark Memory Management — Research Findings

Research date: 2026-05-22  
Sources: NVIDIA developer forums, deepwiki, community post-mortems

---

## The Core Problem: Unified Memory + Docker = Unreliable Capping

DGX Spark (GB10) has 128 GB of LPDDR5X unified memory — one physical pool shared coherently between the ARM CPU and the Blackwell GPU. This is fundamentally different from discrete GPU systems where VRAM and system RAM are separate [1, 2, 3]. Almost all standard Docker/cgroup memory-containment advice either partially or completely fails on this platform.

### What does NOT work (confirmed)

**`--memory=Ng` Docker flag**  
Sets `memory.max` in the container's cgroup, but CUDA allocations on unified memory go through the Unified Memory driver path (ATS addressing, NVLink-C2C). When the CUDA driver allocates, it bypasses or races the cgroup reclaim path in ways that are specific to the UMA fabric. Observed behavior: container exceeds its `--memory` cap and continues allocating until the system panics. (Status: Confirmed)

**`systemd-run --scope -p MemoryMax=...G docker run --gpus all ...`**  
Community confirmed (NVIDIA forum thread #353752): inspecting cgroups from inside the container shows `memory.max` is correctly applied at scope level, but CUDA allocations still see `0::/` with `memory.max = max`. The cgroup tree is doubly broken for this use case. The CUDA driver context lives at the root hierarchy where no limit is imposed. (Status: Confirmed)

**`--oom-score-adj` tuning**  
The OOM killer still fires at the system level (not per-container) when unified memory is exhausted. Adjusting scores doesn't prevent the system zombie/hang. (Status: Confirmed)

### What DOES happen when memory is exhausted

Instead of a clean CUDA OOM exception, the DGX Spark often becomes **unresponsive ("zombie mode")**:
- No error in any log
- No CUDA OOM thrown
- Hard reboot (physical unplug) required to recover
- Reproducible at ~95–100% unified memory utilization
(Status: Confirmed - referenced in reference-previous/POSTMORTEM.md)

---

## Available Mitigations

These are **defense-in-depth** measures — none is a hard guarantee, but layering them reduces zombie frequency significantly.

### 1. Drop buffer cache before heavy launches (most impactful)
```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```
The Linux kernel's page/dentry/inode cache aggressively occupies unified memory even after processes terminate. On a freshly booted Spark with no workloads: 8–20 GB may already be consumed by buffer cache. Flushing before launching any heavy container reclaims this headroom. (Status: Confirmed)

### 2. Configure UMA-correct container ulimits
```yaml
# docker-compose snippet
ulimits:
  memlock: -1        # unlimited memory locking — required for CUDA pinned-memory DMA
  stack: 67108864    # 64 MB stack — prevents stack overflow in deep LLM frameworks
```
(Status: Confirmed - Best practice for CUDA/Deep Learning environments)

### 3. IPC namespace sharing
```bash
--ipc=host
```
Required for PyTorch multi-process data loading. Without it, shared memory defaults to 64 MB, causing training failures in DataLoader workers. (Status: Confirmed)

### 4. Compose `mem_limit` / `mem_reservation` as soft budgets
Even though hard enforcement is unreliable, the `mem_limit` in the compose file serves two purposes:
1. Documentation: records the expected footprint of each profile
2. Soft pressure: under memory pressure Docker's cgroup soft limit may trigger reclaim earlier for that container

(Status: Likely/Useful - Best practice)

### 5. Profile-specific budget guidance (based on observed behavior)

| Profile | Expected GPU usage | `mem_limit` set | Notes |
|---|---|---|---|
| karpathy | ~6–20 GB | 60 GB | Agent self-selects small models on GB10 |
| dgx | ~6–40 GB | 80 GB | More headroom for agent exploration |
| nauto-orch | ~2–4 GB | 40 GB | Orchestrator only, minimal GPU |
| nauto-worker | ~6–40 GB | 80 GB | Same as dgx, worker runs train.py |
| gemini | ~2–4 GB | 8 GB | Keep-alive container, minimal compute |
| autokernel | ~20–70 GB | 70 GB | Profile stage maps full model |

### 6. Monitor with free -h
Standard `nvidia-smi` **cannot report GPU memory usage** on DGX Spark because there is no separate VRAM. Use `free -h` to monitor total unified memory usage. (Status: Confirmed)

---

## OS-Level Headroom Budget

A freshly booted DGX Spark with no workloads:
- Total unified memory: 128 GB physical
- DGX OS + kernel: ~8–12 GB
- Buffer cache (aggressive): 8–20 GB
- CUDA driver context: ~1–2 GB
- **Practical usable ceiling (after drop_caches):** ~105–115 GB

(Status: Confirmed)

---

## Mutual Exclusion as the Primary Safety Mechanism

Since cgroup hard limits are unreliable, the **real** OOM-prevention strategy is `autoresearch-switch`'s `stop_all_except` call.
(Status: Confirmed - Standard operational pattern for this repo)

---

## Sources
[1] https://forums.developer.nvidia.com/t/dgx-spark-becomes-unresponsive-zombie-instead-of-throwing-cuda-oom/353752
[2] https://deepwiki.com/NVIDIA/dgx-spark-playbooks/8.3-memory-management
[3] https://deepwiki.com/NVIDIA/dgx-spark-playbooks/9.2-docker-and-container-configuration
[4] https://forums.developer.nvidia.com/t/running-dgx-spark-as-a-unified-memory-inference-fabric/369086
[5] https://www.linkedin.com/posts/d0znpp_dont-buy-nvidia-dgx-spark-read-this-first
