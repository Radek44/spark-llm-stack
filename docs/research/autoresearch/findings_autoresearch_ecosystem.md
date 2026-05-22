# Autoresearch Ecosystem — Profile Findings

Research date: 2026-05-22  
Sources: GitHub READMEs, NVIDIA forums, SkyPilot blog, OSS Insight, MarkTechPost, HuggingFace Papers

---

## 1. karpathy/autoresearch (profile: `karpathy`)

### What it is
Released March 7, 2026. Three-file repo: `prepare.py` (data prep, immutable), `train.py` (model + loop, agent edits this), `program.md` (plain-English agent instructions, human edits this). The agent runs an indefinite modify→train→evaluate→keep/revert loop on `train.py` only. Scope is deliberately minimal so diffs are reviewable.

### Loop mechanics
- Training budget: exactly **5 minutes wall-clock per experiment**
- Metric: `val_bpb` (validation bits per byte) — lower is better, vocab-size-independent
- Throughput: ~12 experiments/hour → ~100 overnight (~8–9 h)
- Karpathy's own 2-day run: 700 experiments, 20 improvements kept, Time-to-GPT2 dropped 2.02h → 1.80h
- Shopify CEO overnight run: 37 experiments, 19% improvement

### DGX Spark (GB10) adaptation — confirmed changes
Two modifications required (source: NVIDIA forums, rundatarun.io):

1. **Flash Attention**: Replace FA3 with PyTorch SDPA  
   `scaled_dot_product_attention` is the drop-in. FA3 precompiled wheels do not exist for `linux_aarch64 + sm_121`; building from source fails with kernel-arch mismatch ("built for sm80–sm100, running on sm121"). The Dao-AILab/flash-attention issue #1969 tracks this; workaround is eager/SDPA.

2. **FLOPS constant**: Change from H100's `990` TFLOPS to GB10's measured `213` TFLOPS  
   This controls time-budget scaling inside the agent's reasoning. Using the wrong value causes the agent to propose changes calibrated for a much faster GPU.

### Optimal GB10 configuration (community-discovered)
From 151-experiment overnight run on a single Spark (22.5% val_bpb improvement):
```
depth=3, dim=384 (~17.9M parameters)
batch_size=2^16
lr_schedule: 2% warmup, 70% warmdown
GPU memory used: 6.1 GB (out of 128 GB available — agent self-selected)
throughput: ~281K tok/sec, ~1,290 steps/5 min
```

Key insight: **The agent chose 6.1 GB, not because it couldn't use more, but because larger models are slower per step at 213 TFLOPS**. H100 heuristics (bigger = better) do not transfer. The GB10 operates in a different regime where smaller, shallower, more-steps is optimal within a 5-minute window.

### Dependencies
- Python 3.10+, PyTorch, `uv`, a few small packages
- **Not** flash-attention (remove from pyproject.toml before `uv sync` on GB10)
- FP8 via `torchao` — enables tensor core utilization, significant speedup on Blackwell

### Repo URL
`https://github.com/karpathy/autoresearch`

---

## 2. David-Barnes/autoresearch-DGX-Spark (profile: `dgx`)

### What it is
Direct fork of karpathy/autoresearch with the two GB10-specific patches applied (SDPA swap, FLOPS correction) plus alignment toward multi-node Spark configurations and RL training of the research model itself (planned). The flow is identical to `karpathy` — clone/fetch, `uv sync`, `uv run prepare.py`, bounded `uv run train.py`.

### Notable difference from `karpathy`
The fork is explicitly targeting DGX Spark hardware workflows and is expected to diverge further as the author adds reinforcement-learning training of the research policy itself.

### Memory characteristics
Same as karpathy profile. The agent self-regulates to ~6 GB GPU usage on a single Spark. `dgx` profile is given 80 GB `mem_limit` / 60 GB `mem_reservation` in the compose file to allow headroom for larger experiments if the agent explores them.

### Repo URL
`https://github.com/David-Barnes-Data-Imaginations/autoresearch-DGX-Spark`

---

## 3. iii-experimental/n-autoresearch (profiles: `nauto-orch`, `nauto-worker`)

### What it is
Multi-GPU autoresearch infrastructure. Same three files (`prepare.py`, `train.py`, `program.md`), same 5-minute training budget and val_bpb metric. Replaces the bash loop and flat TSV with:
- Queryable experiment tracking state (KV store)
- Adaptive search strategy (explore / exploit / combine / ablation modes)
- Crash recovery (resume from last completed experiment)
- Multi-GPU parallelism via `N` independent worker processes

### Architecture
Two components communicate via REST + WebSocket:
- **Orchestrator** (Python) — HTTP on port `3111`, WebSocket on port `49134`
- **Worker** (Rust) — one per GPU, registers at startup, heartbeats every 30 s, goes offline if no heartbeat for 60 s

### Key REST API endpoints
```
POST /api/experiment/setup      — init run tag
POST /api/experiment/register   — record hypothesis before training
POST /api/experiment/complete   — record metrics, auto keep/discard
POST /api/search/suggest        — get next direction from orchestrator
POST /api/report/summary        — full stats for a run tag
```

### KV state schema
```
experiments:{id}    → { id, tag, hypothesis, val_bpb, peak_vram_mb, status, gpu_id, diff_summary }
best:{tag}          → { experiment_id, val_bpb, commit_sha }
near_misses:{id}    → { experiment_id, val_bpb, delta, hypothesis }
gpu_pool:{gpu_id}   → { id, gpu_index, vram_mb, status, current_experiment_id }
strategy:{tag}      → { mode, explore_ratio, temperature, reason }
crashes:{tag}       → consecutive crash count (int)
```

### Multi-GPU parallelism
With N GPU workers, N agents run experiments simultaneously on the same `tag`. Each: acquire GPU → run train.py → record metrics → release GPU. Search strategy adapts globally across all parallel experiments.

Throughput comparison (SkyPilot blog):
| Setup | Experiments/hour | Strategy |
|---|---|---|
| 1 GPU (sequential) | ~10–12 | greedy hill-climbing |
| 16 GPUs (parallel) | ~90 | factorial grids per wave |

16-GPU run reached same best val_bpb 9× faster (8 h vs ~72 h).

### On DGX Spark (single GPU, no worker fleet)
`nauto-orch` is given 40 GB mem_limit; `nauto-worker` gets 80 GB. With a single Spark the setup is: one orchestrator + one worker targeting GPU 0. This is overkill for one GPU but gains crash recovery and persistent experiment state across sessions.

### Requirements
NVIDIA GPU(s), Python 3.10+, `uv`, Rust 1.82+ (for the worker binary)

### Repo URL
`https://github.com/iii-hq/n-autoresearch`

---

## 4. supratikpm/gemini-autoresearch (profile: `gemini`)

### What it is
Gemini CLI skill that generalises the autoresearch keep/revert loop to **any domain with a measurable outcome** — not just ML training. Works in Antigravity IDE via `.agents/skills/`. 

### Unique capabilities vs karpathy loop
- **Google Search grounding inside the loop**: Gemini can query live Google results per iteration to verify if an API is deprecated, whether an approach matches current best practices, what's actually ranking — no other autoresearch skill can do this natively
- **1M token context**: allows much longer experiment history to inform decisions
- **Headless overnight mode**: `--yolo --prompt` flag runs fully unattended
- **Goal-directed**: you describe the goal in plain English; Gemini scans the project, detects the tech stack, proposes the full config, runs a dry run, and hands back the ready-to-run command
- **Dual-gate quality assurance**: any change that breaks types gets reverted even if it improved the target metric

### DGX Spark usage pattern
The `gemini` profile container is a **keep-alive environment** — the container stays up and serves as the execution context for host-driven Gemini CLI sessions. The actual loop is initiated from the host or from Antigravity IDE pointing at the container. Memory footprint is minimal (8 GB mem_limit / 4 GB reservation) since the container itself just runs the skill environment.

### Repo URL
`https://github.com/supratikpm/gemini-autoresearch`

---

## 5. RightNow-AI/autokernel (profile: `autokernel`)

### What it is
Autoresearch transplanted to GPU **kernel optimization**. Given any PyTorch model, it profiles it, identifies computational bottlenecks via Amdahl's law, and iteratively refines Triton or CUDA C++ implementations through hundreds of experiments without human intervention.

### Pipeline stages (map to `AUTOKERNEL_STAGE` env var)
| Stage | Script | What happens |
|---|---|---|
| `profile` | `profile.py` | Profiles the PyTorch model, identifies top N kernels by wall-clock time, ranks by Amdahl's law impact |
| `extract` | `extract.py` | Extracts kernel signatures, generates starter implementations in Triton and/or CUDA C++ |
| `bench` | `bench.py` | Runs the keep/revert optimization loop; each iteration ≈ 90s (30s correctness + 30s benchmark + 30s agent) → ~40 experiments/hour, 300–400 per 10h overnight run |
| `verify` | `verify.py` | Final correctness sweep against 5-stage harness on production inputs |

### 5-stage correctness harness (gate before any speedup is recorded)
1. **Smoke test** — small input, catches compilation errors / shape mismatches in < 1 s
2. **Shape sweep** — 8–10 input configs × 3 dtypes (FP16, BF16, FP32) — catches boundary handling bugs
3. **Numerical stability** — adversarial inputs (large identical values, extreme dynamic range, near-zero variance)
4. **Determinism** — same input 3×, requires bitwise-identical output (catches race conditions)
5. **Edge cases** — empty tensors, single-element batches, non-power-of-2 shapes

### Backends
- **Triton**: Python-like DSL, JIT compiles in 1–5 s. Best for rapid iteration. Agent can modify block sizes, warp counts, pipeline stages, accumulator precision, loop structure. Reaches 80–95% of cuBLAS throughput for matmul.
- **CUDA C++**: Direct access to warp-level primitives, WMMA tensor core instructions (16×16×16 fragments), vectorized loads (`float4`, `half2`), bank-conflict-free shared memory, double buffering.

Both backends expose the same `kernel_fn()` interface so benchmark infrastructure runs identically.

### 6-tier optimization playbook (program.md, 909 lines)
Tier 1: block size tuning → Tier 2: memory access → Tier 3: compute → Tier 4: advanced → Tier 5: architecture-specific → Tier 6: kernel-specific

### Results (H100 baseline from paper arxiv:2603.21331)
| Kernel | vs PyTorch eager | vs torch.compile max-autotune |
|---|---|---|
| RMSNorm | 5.29× | 2.83× |
| Softmax | 2.82× | 3.44× |
| Cross-entropy | 2.21× | 2.94× |
| Triton FP4 matmul | 1.63–2.15× over CUTLASS | — |
| vectorsum_v2 B200 | 🥇 leaderboard #1 | — |

### DGX Spark notes
- Forum thread (NVIDIA #363215) notes it "may need a bit of expansion to include more modern model types" for GB10 workloads
- `autokernel` mem_limit is 70 GB / reservation 50 GB in compose — the profiling stage maps the whole model and staging data into GPU address space
- Triton JIT compiles for `sm_121` automatically when `CUDA_VISIBLE_DEVICES` points to the GB10 and CUDA 13 is available

### Repo URL
`https://github.com/RightNow-AI/autokernel`

---

## Sources
- https://github.com/karpathy/autoresearch
- https://rundatarun.io/p/the-overnight-loop
- https://forums.developer.nvidia.com/t/karpathys-autoresearch-customised-for-spark/362949
- https://github.com/iii-hq/n-autoresearch
- https://blog.skypilot.co/scaling-autoresearch
- https://github.com/karpathy/autoresearch/issues/169
- https://github.com/supratikpm/gemini-autoresearch
- https://skillsllm.com/skill/alvinreal-awesome-autoresearch
- https://github.com/RightNow-AI/autokernel
- https://www.marktechpost.com/2026/04/06/rightnow-ai-releases-autokernel-an-open-source-framework-that-applies-an-autonomous-agent-loop-to-gpu-kernel-optimization-for-arbitrary-pytorch-models
- https://huggingface.co/papers/2603.21331
- https://forums.developer.nvidia.com/t/autokernel-autoresearch-for-kernel-optimization/363215
