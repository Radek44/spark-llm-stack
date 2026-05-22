# Autoresearch + DGX Spark Memory — Research Summary

Research date: 2026-05-22  
Scope: autoresearch ecosystem (all 6 profiles), unified-memory container juggling, ComfyUI on GB10, llama.cpp on GB10

---

## Key Findings at a Glance

### 1. karpathy/autoresearch on GB10 requires exactly two code changes
- Remove Flash Attention 3 → use PyTorch SDPA (`scaled_dot_product_attention`)
- Change FLOPS constant from 990 (H100) to 213 (GB10 measured)

Without these: FA3 will fail to load on sm_121, and the agent's time-budget reasoning will be calibrated for a 5× faster GPU.

### 2. The GB10 optimal training profile is radically smaller than H100
Community runs converge independently: `depth=3, dim=384, batch=2^16, ~6 GB VRAM`. The agent discovers this itself. Do NOT pre-configure for H100 heuristics (bigger models, larger batches). The 5-minute window at 213 TFLOPS rewards shallow-wide over deep-narrow.

### 3. Docker `mem_limit` does NOT reliably cap GPU memory on DGX Spark
Standard cgroup enforcement fails for CUDA allocations on unified memory (ATS addressing, NVLink-C2C). `systemd-run --scope -p MemoryMax=...G` also confirmed ineffective (forum #353752). The container sees `memory.max = max` for CUDA paths regardless of the cgroup limit applied.

**Consequence for this repo**: `mem_limit` in compose is a planning budget, not a hard cap. Mutual exclusion via `autoresearch-switch stop_all_except` is the actual safety mechanism.

### 4. Pre-launch buffer cache flush is mandatory
```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```
Without this, 8–20 GB may already be consumed by Linux page cache, shrinking your effective working headroom below what `free -h` suggests is available.

### 5. `--highvram` destroys ComfyUI on DGX Spark
Do not use `--highvram`, `--gpu-only`, `--cache-none`, or `--disable-mmap` in ComfyUI. They pin models GPU-side permanently or cause copy-doubling on the unified pool. Use `--bf16-unet --bf16-vae --bf16-text-enc --use-sage-attention --disable-dynamic-vram` instead.

### 6. ComfyUI's `model_management.py` needs a UMA patch
`cudaMemGetInfo()` under-reports free memory when another CUDA process is resident (e.g., llama-server). Replace with `psutil.virtual_memory().available` in `comfy/model_management.py`.

### 7. KV cache q8_0 is the best llama-server trade-off on GB10
- q4_0 saves memory but falls off a cliff at 64K context (92.5% prompt throughput drop)
- q8_0 saves ~47% KV memory with < 5% speed penalty at all context lengths
- Counterintuitively: q4_0 uses 6–7% MORE memory than f16 at typical GB10 buffer sizes (metadata overhead exceeds savings)

### 8. n-autoresearch is overkill for single-Spark but worth it for crash recovery
On a single GB10 the orchestrator + worker overhead adds complexity with minimal parallelism benefit. The payoff is persistent experiment state across agent context-fill events and session boundaries. On multi-node Spark clusters (or with an H100 worker fleet) the N×12 experiments/hour scaling is the main draw.

---

## Action Items for This Repo

| Priority | Item | File to update |
|---|---|---|
| HIGH | Add buffer cache flush to `autoresearch-switch start` (or document prominently) | `docker/autoresearch/scripts/autoresearch-switch` |
| HIGH | Add UMA ulimits to compose (memlock=-1, stack=67108864) | `docker/autoresearch/docker-compose.autoresearch.yml` |
| HIGH | Add CUDA env vars to compose (PYTORCH_NO_CUDA_MEMORY_CACHING, OMP_NUM_THREADS) | `docker/autoresearch/docker-compose.autoresearch.yml` |
| MEDIUM | Patch ComfyUI `model_management.py` in comfyui Dockerfile | `docker/comfyui/Dockerfile` or entrypoint |
| MEDIUM | Document FA3→SDPA swap in `entrypoint.sh` for karpathy/dgx profiles | `docker/autoresearch/scripts/entrypoint.sh` |
| LOW | Consider adding FLOPS constant detection/override to entrypoint | `docker/autoresearch/scripts/entrypoint.sh` |
| LOW | Add q8_0 KV cache flags to coder/architect slot service files for long-context use | `systemd/units/*.service` |

---

## Profile Memory Budget Summary

| Profile | Practical GPU footprint | mem_limit | Enforcement |
|---|---|---|---|
| `karpathy` | 6–20 GB (agent-selected) | 60 GB | Mutual exclusion only |
| `dgx` | 6–40 GB | 80 GB | Mutual exclusion only |
| `nauto-orch` | 2–4 GB | 40 GB | Mutual exclusion only |
| `nauto-worker` | 6–40 GB | 80 GB | Mutual exclusion only |
| `gemini` | 2–4 GB | 8 GB | Mutual exclusion only |
| `autokernel` | 20–70 GB | 70 GB | Mutual exclusion only |

Total available (after OS + drop_caches): ~105–115 GB  
Largest single-profile ceiling: ~70 GB (autokernel profiling a large model)

---

## File Map

| File | Contents |
|---|---|
| `findings_autoresearch_ecosystem.md` | Per-profile deep dive: all 5 upstreams, API endpoints, architecture, DGX Spark-specific notes |
| `findings_dgx_spark_memory.md` | UMA cgroup failure analysis, mitigations, drop_caches, ulimits, env vars, monitoring |
| `findings_comfyui_memory.md` | Flags to use/avoid, model_management.py patch, memory footprint benchmarks, coexistence |
| `findings_llama_gb10.md` | Build flags for sm_121, FA3 status, KV cache quant benchmarks and cliff analysis, threading |
| `RESEARCH_SUMMARY.md` | This file — synthesis and action items |
