# llama.cpp Text-Model Tuning Plan for DGX Spark GB10

**Date:** 2026-05-22  
**Hardware:** NVIDIA DGX Spark GB10 (Grace Blackwell, 128GB unified LPDDR5X, 72 ARM cores, SM 12.1a)  
**Scope:** Benchmark-driven configuration optimization for llama-server text slots: `coder`, `architect`, `gemma`, `gptoss`  
**Methodology:** Fixed test matrix → measure → decide → document per-slot settings

---

## 1. Executive Summary: Why This Matters on GB10

GB10 has fundamentally different performance characteristics from traditional NVIDIA GPUs:

| Property | GB10 LPDDR5X | Traditional GPU HBM |
|----------|--------------|-------------------|
| Bandwidth | 273 GB/s | 3.3 TB/s |
| **Ratio** | **1.0×** | **12×** |

**Key implication:** GB10 is **bandwidth-limited, not compute-limited**. This means:
- **4-bit quantization is 3.5× faster than FP16** (same model)
- Cache efficiency and memory layout matter more than raw compute
- KV cache optimization directly impacts token throughput
- Threading strategy must avoid memory stalls

Current default: `-b 512 -ub 1024 --threads 8` — underutilizes both quantization benefits and available CPU threads (72 cores).

---

## 2. Parameter Matrix: What to Test

### 2.1 Quantization (Q-level)

**Rationale:** GB10 bandwidth bottleneck makes quantization the #1 lever.

| Level | Compression | Expected Speedup | Quality Loss | Recommendation |
|-------|-------------|------------------|--------------|-----------------|
| F16 | 1.0× (baseline) | — | 0% | Quality baseline; not practical for production |
| BF16 | 1.0× | — | <1% | Alternative to F16; similar performance |
| Q6_K | 1.6× | ~1.5× | 0% | Minimal quality loss, moderate speedup |
| Q5_K | 2.0× | ~2.2× | <0.5% | Balanced; strong recommendation |
| Q4_K_M | 4.0× | **3.5×** | <1% | Optimal for bandwidth; our primary target |

**Test set:** `Q4_K_M`, `Q5_K`, `Q6_K` (cover 1.6–4× range; F16 as control)

**Decision criterion:** Choose the highest quantization where latency is within 5% of Q4_K_M. If the model is stability-critical (coder), prefer Q5_K over Q4_K_M if quality metrics show >1% difference.

---

### 2.2 Context Length (-c)

**Rationale:** Longer context increases KV cache size; tests memory limits and cache efficiency.

| Value | Approx KV Cache (GB, f16) | Use Case | Note |
|-------|--------------------------|----------|------|
| 2048 | ~1.6 (7B model) | Short prompts; fast | Minimum for coder slot |
| 4096 | ~3.2 | Standard; balance | Sweet spot for most text tasks |
| 8192 | ~6.4 | Long-context tasks | Tests cache efficiency |
| 16384+ | 12.8+ | Synthetic long-context | Risk of OOM; avoid unless needed |

**Test set:** `2048`, `4096`, `8192` for each slot.

**Per-slot guidance:**
- `coder` → Prefer 8192 (long code files)
- `architect` → 4096–8192 (design documents)
- `gemma` → 4096 (general tasks)
- `gptoss` → 2048 (summarization, low latency)

---

### 2.3 Batch Sizes: -b (prompt batch) and -ub (ubatch/token-splitting)

**Rationale:** Batch size is CPU-GPU sync overhead vs throughput tradeoff. GB10 unified memory is sensitive to memory fragmentation.

**Recommendation:** Follow `4n+1` formula (observed in ComfyUI tuning to reduce fragmentation on unified memory).

| Batch | ubatch | Expected Behavior | Note |
|-------|--------|-------------------|------|
| 1 | 1 | Low throughput, low latency | Testing only |
| 5 | 16 | Good memory alignment | 4×1+1 formula |
| 9 | 32 | Better throughput | 4×2+1 formula |
| 13 | 64 | High throughput, risk of stalls | 4×3+1 formula |

**Test set:** `-b 1` (baseline), `-b 5 -ub 16`, `-b 9 -ub 32`, `-b 13 -ub 64`

**Decision criterion:** Choose the highest batch where p95 latency ≤ baseline + 20%. Avoid unbatch > 128 to prevent OOM on long contexts.

---

### 2.4 KV Cache Strategy: --cache-type-k, --cache-type-v, --cache-ram

**Rationale:** KV cache is the largest memory component for long sequences. Quantization reduces size; --cache-ram lets us control spill-to-host behavior.

**Cache type options:**
- `f16` — Full precision KV cache (baseline, high memory)
- `q8` — 8-bit quantized KV cache (2× compression, minimal quality loss)
- `q4_0`, `q4_1` — 4-bit KV cache (4× compression, more quality loss)

**Cache RAM strategy:**
- `--cache-ram 0` → All KV cache in GPU memory
- `--cache-ram N` → Allow N GB to spill to host RAM (slower but avoids OOM)

**Test set:**
- `--cache-type-k f16 --cache-type-v f16 --cache-ram 0` (baseline)
- `--cache-type-k q8 --cache-type-v q8 --cache-ram 0` (quantized, no spill)
- `--cache-type-k q4_0 --cache-type-v q4_0 --cache-ram 8` (extreme compression + host spill)

**Note:** TurboQuant KV compression (4.57x → 5.12x) is a research prototype; not tested here. Standard quantization is the conservative choice.

---

### 2.5 Threading: --threads, --threads-batch, --threads-http

**Rationale:** GB10 has 72 ARM cores; default of 8 underutilizes. However, too many threads can overload the cache and scheduler.

| Threads | Typical Use Case | Note |
|---------|-----------------|------|
| 8 | Current default | Safe, but underutilizes |
| 16 | Moderate throughput | Test first |
| 32 | High throughput | Risk of cache contention |
| 48+ | Max utilization | Only if measured benefit |

**Test set:** `--threads 8`, `--threads 16`, `--threads 32` (with `--threads-batch 512` in all cases)

**--threads-http:** Separate thread pool for HTTP server. Default is `--threads-http 8`. Only tune if request queuing is observed.

**Decision criterion:** Choose the lowest thread count where TTFT and token/s are within 5% of the best observed. Avoid 48+ unless benchmarks prove benefit—context switching overhead can hurt latency.

---

### 2.6 KV Cache Reuse and Checkpointing: --cache-reuse, --ctx-checkpoints

**Rationale:** These flags help manage memory and enable efficient prompt reuse.

**--cache-reuse:** Allow reusing KV cache from previous prompts (useful if same prompts repeated).
- `0` (disabled) — Default; safest
- `1` (enabled) — Useful for repeated system prompts

**--ctx-checkpoints:** Periodically checkpoint context to manage fragmentation.
- `0` (disabled) — Default
- `N > 0` — Checkpoint every N tokens (reduces fragmentation at cost of slight overhead)

**Test set:** Keep both at default (`0`) for baseline. Only test non-zero values if memory fragmentation is observed in results.

---

### 2.7 Multi-Token Prefill (MTP): --spec-* flags

**Rationale:** MTP (available in llama.cpp-mtp branch) can 2–3× prefill throughput via speculative decoding.

**Relevant flags:**
- `--spec-token-count N` — How many draft tokens to speculate (typically 4–16)
- `--spec-token-draft N` — Draft model tokens (set to same as --spec-token-count for "draft cache")

**Note:** Only applicable if using MTP branch llama.cpp. Enable only for `coder` and `architect` slots (high token throughput).

**Test set:** If using MTP branch:
- `--spec-token-count 0` (disabled)
- `--spec-token-count 8` (moderate speculation)

**Decision criterion:** Accept if tokens/s improves by >10% and p95 latency doesn't degrade by >15%.

---

### 2.8 Sampling Parameters: --temp, --top-k, --top-p, --min-p

**Rationale:** These affect generation quality and diversity, but should NOT significantly impact TTFT or raw token throughput (they're post-sampling logic).

**Decision:** Only test if you suspect they affect performance (unlikely). Tune for generation quality separately from latency benchmarks.

**Test set:** Use reasonable production defaults:
- `coder` → `--temp 0.7 --top-k 40 --min-p 0.05`
- `architect` → `--temp 0.8 --top-k 64 --min-p 0.05`
- `gemma` → `--temp 1.0 --top-k 64 --top-p 0.95`
- `gptoss` → `--temp 0.6 --top-k 32 --top-p 0.90`

---

### 2.9 Build/Runtime Environment Flags: GGML_CUDA_*, Launch Queue Config

**Rationale:** GB10 has special CUDA characteristics (unified memory, SM 12.1a). Some flags may affect performance.

**Candidates:**
- `GGML_CUDA_GRAPHS` — Use CUDA graphs for kernel launch overhead reduction. Default may be off; try enabling.
- `GGML_CUDA_PEER_MAX_BATCH_SIZE` — Peer GPU access batch size (not relevant on single GPU).
- `CUDA_DEVICE_MAX_CONNECTIONS` — Connection limit per thread (try `32` for high concurrency).
- `CUDA_GRAPH_POOL_SIZE` — If using CUDA graphs, may help with memory fragmentation.

**Conservative approach:** Test with defaults first. Only adjust if profiling shows kernel launch overhead or memory fragmentation.

---

## 3. Benchmark Methodology: How to Test

### 3.1 Test Harness

**Tool:** Use both `llama-bench` (synthetic) and `llama-server` with concurrent curl requests (production-realistic).

**llama-bench command template:**
```bash
./llama-bench \
  -m /path/to/model.gguf \
  -c <context> \
  -b <batch> \
  -ub <ubatch> \
  --threads <threads> \
  --threads-batch <threads-batch> \
  --cache-type-k <kv_type> \
  --cache-type-v <kv_type> \
  -t 2 \
  -ngl 99 \
  --repetitions 3
```

**llama-server real-request test:**
```bash
# In one terminal:
./llama-server \
  -m /path/to/model.gguf \
  -c <context> \
  -b <batch> \
  -ub <ubatch> \
  --threads <threads> \
  -ngl 99 \
  --port 8000

# In another terminal, measure with Apache Bench or custom script:
ab -n 100 -c 4 -p prompt.json http://localhost:8000/v1/completions
```

### 3.2 Test Scenarios

Each scenario tests a specific performance profile:

#### Scenario A: Low-Latency Single Request (Short Context)
- **Workload:** Short prompt (10–50 tokens), expect fast TTFT
- **Concurrency:** 1 client
- **Context:** 2048
- **Expected metric:** TTFT ≤ 100 ms, token rate ≥ 40 t/s
- **Relevant to:** `gptoss`, fast-response scenarios

#### Scenario B: Balanced Throughput (Medium Context)
- **Workload:** Medium prompt (100–500 tokens), generate 200 tokens
- **Concurrency:** 2 clients, staggered
- **Context:** 4096
- **Expected metric:** TTFT 50–200 ms, sustained >30 t/s
- **Relevant to:** `architect`, general tasks

#### Scenario C: High-Throughput Batch (Long Context)
- **Workload:** Large prompt (500–2000 tokens), generate 500 tokens
- **Concurrency:** 4 clients, aggressive pipelining
- **Context:** 8192
- **Expected metric:** TTFT 200–500 ms, sustained >20 t/s
- **Relevant to:** `coder`, document processing

#### Scenario D: Memory Stress (Max Context)
- **Workload:** Maximum context (8192), single large request
- **Concurrency:** 1 client
- **Context:** 8192
- **Expected metric:** Observe OOM behavior, memory footprint
- **Relevant to:** Stability testing, cache efficiency

### 3.3 Fixed Prompts and Workloads

**Prompt 1 (Short):** 20 tokens
```
What is the capital of France?
```

**Prompt 2 (Medium):** 150 tokens
```
Explain the difference between supervised and unsupervised learning in machine learning.
Include at least 3 key differences and provide examples.
```

**Prompt 3 (Long):** 500 tokens
```
Write a comprehensive guide on setting up a Kubernetes cluster in production,
covering networking, storage, security, and monitoring. Include configuration
examples for a 5-node cluster with 3 control planes.
[Add filler text to reach 500 tokens for consistent memory pressure]
```

**Continuation length:** Generate 200 tokens (fixed across all tests).

---

### 3.4 Warmup and Repetition Protocol

1. **Warmup phase (per config):**
   - Run Scenario A once (discarded)
   - Purpose: warm up GPU cache, JIT compilation, stabilize clocks

2. **Measured phase (per config):**
   - Run each scenario 3 times
   - Record metrics from each run
   - Discard slowest/fastest if > 20% variance; otherwise average 3 runs

3. **Repetition count:**
   - 3 runs per config × 4 scenarios × 4 quantizations × 3 contexts × 4 batch settings × 3 thread settings = **1,728 individual tests**
   - **Estimate:** ~20–30 hours of testing on GB10 (heavily parallelizable by model)
   - **Practical approach:** Test one context at a time, one quantization at a time; total ~8–10 hours

---

## 4. Metrics and Output Format

### 4.1 Primary Metrics

| Metric | Unit | How to Measure | Notes |
|--------|------|----------------|-------|
| TTFT | ms | Time from request submission to first token output | Latency-critical; lower is better |
| Prefill Rate | t/s | (prompt_tokens) / (prefill_time) | Throughput on new tokens |
| Decode Rate | t/s | (completion_tokens) / (decode_time) | Throughput on generation |
| p50 Latency | ms | Median latency across 3 runs | Typical experience |
| p95 Latency | ms | 95th percentile (worst of 3 runs) | Tail latency; SLA indicator |
| Memory Peak | GB | Peak GPU + host memory during run | Tells us safety margin to OOM |
| OOM Observed | yes/no | Did the test trigger OOM killer? | Hard failure; log kernel message |
| Error Rate | % | (failed_requests) / (total_requests) × 100 | Network/timeout errors only |

### 4.2 Output Format: CSV per Test

```csv
Config,Scenario,TTFT_ms,Prefill_t_s,Decode_t_s,p50_lat_ms,p95_lat_ms,Memory_GB,OOM,Errors_pct,Notes
Q4_K_M,Scenario_A_Short_1c,35,45,42,38,42,8.2,no,0,baseline_quantization
Q4_K_M,Scenario_A_Short_1c,36,44,41,39,43,8.2,no,0,repeat_2
Q4_K_M,Scenario_A_Short_1c,35,45,42,38,41,8.2,no,0,repeat_3
```

### 4.3 Aggregation: Summary Results Table

Per-slot summary (see LLAMACPP_BASELINE_RESULTS.md for template):

```
Slot: coder | Model: gemma-2-27b-q4_k_m | Context: 8192
Config | TTFT | Prefill | Decode | p50 Lat | Memory | Stable | Notes
------|------|---------|--------|---------|--------|--------|-------
baseline (-b 1 -t 8) | 80 | 38 | 35 | 85 | 28 | ✓ | slow throughput
optimized (-b 9 -t 16) | 95 | 52 | 41 | 100 | 32 | ✓ | 30% faster prefill
max_perf (-b 13 -t 32) | 120 | 65 | 44 | 140 | 38 | ~ | occasional timeouts
```

---

## 5. Analysis and Decision Criteria

### 5.1 Performance Trade-off Matrix

Define acceptable trade-offs for each slot:

| Slot | Priority 1 | Priority 2 | Priority 3 | Constraint |
|------|-----------|-----------|-----------|-----------|
| `coder` | Throughput (prefill) | Stability (no OOM) | TTFT | p95 < 500ms, mem < 40GB |
| `architect` | Balance (TTFT + throughput) | Stability | Memory | p95 < 300ms, mem < 36GB |
| `gemma` | Latency (TTFT) | Quality | Throughput | p95 < 200ms, no errors |
| `gptoss` | Latency (TTFT) | Accuracy | Throughput | p95 < 150ms, mem < 20GB |

### 5.2 Decision Algorithm

For each slot:

1. **Eliminate unstable configs:** Remove any with OOM, error rate >1%, or p95 > constraint.
2. **Rank by primary metric:** Sort remaining by priority #1.
3. **Apply secondary filters:** Among top 3, prefer those with best priority #2.
4. **Check constraint:** Verify memory and latency are within limits.
5. **Choose the simplest:** If tied, prefer lower `--threads` (less contention) or lower `--batch` (simpler resource management).

**Example for `coder`:**
```
Candidate A: Q4_K_M, -b 9, -t 16 → 52 t/s prefill, 95 TTFT, 32 GB ✓
Candidate B: Q4_K_M, -b 13, -t 32 → 65 t/s prefill, 120 TTFT, 38 GB ✓
Candidate C: Q5_K, -b 9, -t 16 → 35 t/s prefill, 85 TTFT, 20 GB ✓

Decision: Choose A. Reason: 52 t/s is 79% of B's throughput, but 20% lower TTFT
and simpler threading. B's extra 12 t/s (22%) is marginal vs. OOM risk (38 GB vs 32 GB).
```

---

## 6. Rollback and Tradeoff Guidance

### 6.1 "Safe Default" Profile

Criteria:
- No OOM observed in any test
- Error rate = 0
- p95 latency within 110% of best
- Minimal configuration drift from baseline

**Expected safe defaults (from prior research):**
- Quantization: Q5_K (proven stable, 2.2× speedup)
- Context: 4096 (balance for most models)
- Batch: 9 (4n+1 formula, stable memory)
- Threads: 16 (50% of default, proven stable on unified memory)
- Cache: f16 (no quantization risk)

---

### 6.2 "Max Performance" Profile

Criteria:
- Accepts minor OOM risk (observed in 1 of 3 runs, recoverable)
- Error rate <0.5%
- p95 latency within 150% of best
- Aggressive on quantization and threading

**Expected max performance:**
- Quantization: Q4_K_M (3.5× speedup, acceptable quality)
- Context: 8192 (match slot's designed max)
- Batch: 13 (high throughput)
- Threads: 32 (high parallelism)
- Cache: q4_0 (aggressive compression)

---

### 6.3 Known Tradeoffs

| Setting | Benefit | Risk | Mitigation |
|---------|---------|------|-----------|
| Q4_K_M | 3.5× faster | <1% quality loss | Test on actual workload |
| -b 13 | +30% throughput | OOM risk on long context | Use -c 4096 max |
| -t 32 | 50% more cores | Cache contention, scheduling overhead | Monitor p95 variance |
| --cache-type-k q4_0 | -75% cache memory | Quantization artifacts on edge cases | Fallback to q8 if issues |
| --ctx-checkpoints N | Reduce fragmentation | Small overhead | Only enable if needed |

---

### 6.4 Rollback Procedure

If a configuration causes issues in production:

1. **Switch to safe default** immediately (documented in Section 6.1).
2. **Document failure** in LLAMACPP_BASELINE_RESULTS.md under "Failure Notes".
3. **Investigate** one variable at a time (quantization → threads → batch).
4. **Retest** the isolated variable to identify the culprit.
5. **Update guidelines** based on findings.

**Example rollback:**
```bash
# Current failing config:
llama-server -m model.gguf -c 8192 -b 13 -ub 64 -t 32 --cache-type-k q4_0

# Rollback to safe default:
llama-server -m model.gguf -c 4096 -b 9 -ub 32 -t 16 --cache-type-k f16

# Then incrementally re-apply optimizations:
# 1. Try quantization: -b 9 -t 16 --cache-type-k q8
# 2. If stable, try threads: -b 9 -t 24 --cache-type-k q8
# 3. If stable, try batch: -b 11 -t 24 --cache-type-k q8
```

---

## 7. Implementation: Running the Benchmarks

### 7.1 Prerequisite Checklist

- [ ] GB10 host with NVIDIA driver 580+
- [ ] llama.cpp built with CUDA compute capability 12.1a (`-DCMAKE_CUDA_ARCHITECTURES=121a-real`)
- [ ] All test models downloaded to `~/models/`:
  - `Gemma-2-27b-q4_k_m.gguf` (7B/27B variant per slot)
  - Alternative: Any text model you're actually using
- [ ] `llama-bench` binary available in `build/bin/`
- [ ] `llama-server` binary available in `build/bin/`
- [ ] Test prompts saved to files (see Section 3.4)
- [ ] Systemd `llm-switch` stopped (exclusive GPU access for testing)

### 7.2 Quick-Start: Single Config Test

```bash
cd ~/src/llama.cpp-mtp

# Build (if needed)
mkdir -p build && cd build
cmake .. -DCMAKE_CUDA_ARCHITECTURES=121a-real
make -j 16

cd ~/Dev/spark-llm-stack

# Run single benchmark
./build/bin/llama-bench \
  -m ~/models/gemma-2-27b-q4_k_m.gguf \
  -c 4096 \
  -b 9 \
  -ub 32 \
  --threads 16 \
  --threads-batch 512 \
  --cache-type-k f16 \
  --cache-type-v f16 \
  -ngl 99 \
  -t 2 \
  --repetitions 3
```

### 7.3 Full Matrix: Batch Testing Script (Pseudocode)

```bash
#!/bin/bash
# benchmark_matrix.sh

MODELS=( "gemma-2-27b-q4_k_m.gguf" "gemma-2-27b-q5_k.gguf" "gemma-2-27b-q6_k.gguf" "gemma-2-27b-f16.gguf" )
CONTEXTS=( 2048 4096 8192 )
BATCHES=( "1,1" "5,16" "9,32" "13,64" )  # format: b,ub
THREADS=( 8 16 32 )
CACHE_TYPES=( "f16,f16" "q8,q8" "q4_0,q4_0" )

for model in "${MODELS[@]}"; do
  for context in "${CONTEXTS[@]}"; do
    for batch_spec in "${BATCHES[@]}"; do
      IFS=',' read -r b ub <<< "$batch_spec"
      for threads in "${THREADS[@]}"; do
        for cache_spec in "${CACHE_TYPES[@]}"; do
          IFS=',' read -r cache_k cache_v <<< "$cache_spec"
          
          echo "Testing: $model context=$context b=$b ub=$ub threads=$threads cache=$cache_k/$cache_v"
          ./build/bin/llama-bench \
            -m ~/models/$model \
            -c $context -b $b -ub $ub \
            --threads $threads --threads-batch 512 \
            --cache-type-k $cache_k --cache-type-v $cache_v \
            -ngl 99 -t 2 --repetitions 3 \
            | tee -a results_${model%.*}_${context}.csv
        done
      done
    done
  done
done
```

---

## 8. Expected Outcomes: Per-Slot Recommendations (Template)

**To be filled after benchmarking:**

### coder slot (primary throughput, long context)
```
Recommended config:
  Model: gemma-2-27b (or equivalent)
  Quantization: Q4_K_M
  Context: 8192
  Batch: 9, ubatch: 32
  Threads: 16, threads-batch: 512
  Cache: f16/f16
  Expected TTFT: 90–110 ms
  Expected throughput: 48–55 t/s (prefill), 38–42 t/s (decode)
  Memory: 30–34 GB
  Stability: ✓ no OOM observed
```

### architect slot (balanced)
```
Recommended config:
  Model: gemma-2-27b-q5_k (or equivalent)
  Quantization: Q5_K
  Context: 4096
  Batch: 9, ubatch: 32
  Threads: 16, threads-batch: 512
  Cache: f16/f16
  Expected TTFT: 60–80 ms
  Expected throughput: 35–40 t/s (prefill), 32–36 t/s (decode)
  Memory: 22–26 GB
  Stability: ✓ no OOM observed
```

### gemma slot (general)
```
Recommended config:
  Model: gemma-2-7b-q5_k (or equivalent)
  Quantization: Q5_K
  Context: 4096
  Batch: 5, ubatch: 16
  Threads: 16, threads-batch: 512
  Cache: f16/f16
  Expected TTFT: 40–60 ms
  Expected throughput: 50–60 t/s (prefill), 40–50 t/s (decode)
  Memory: 12–16 GB
  Stability: ✓ no OOM observed
```

### gptoss slot (fast, small)
```
Recommended config:
  Model: gemma-2-7b-q6_k (or equivalent)
  Quantization: Q6_K
  Context: 2048
  Batch: 5, ubatch: 16
  Threads: 8, threads-batch: 512
  Cache: f16/f16
  Expected TTFT: 25–40 ms
  Expected throughput: 65–75 t/s (prefill), 55–65 t/s (decode)
  Memory: 10–12 GB
  Stability: ✓ no OOM observed
```

---

## 9. Assumptions and Caveats

1. **Hardware assumptions:**
   - GB10 running at stable clocks (nvidia-smi -lgc 3003,3003)
   - NVIDIA driver 580+ installed
   - No other services consuming GPU memory

2. **Model assumptions:**
   - Testing with Gemma 2 variants (can substitute with your actual models)
   - Quantization is via llama.cpp's built-in Q4/Q5/Q6 levels, not external tooling

3. **Workload assumptions:**
   - Fixed prompts (not representative of all real-world queries)
   - Single slot isolated testing (not measuring contention between slots)
   - No KV cache reuse across requests (worst case for cache efficiency)

4. **Build assumptions:**
   - llama.cpp built with `-DCMAKE_CUDA_ARCHITECTURES=121a-real`
   - MTP branch (if testing --spec-* flags)
   - CUDA 12.x, PTX optimizations available

5. **Methodology assumptions:**
   - 3 repetitions sufficient to catch most variance
   - Discarding outliers acceptable (20% threshold)
   - Latency outliers don't indicate instability (only check OOM/errors)

---

## 10. Success Criteria and Sign-Off

Benchmarking is **complete** when:

- [ ] At least **one quantization level** (Q4, Q5, Q6) tested across **all contexts** (2048, 4096, 8192)
- [ ] At least **two thread counts** (8 and 16 or 16 and 32) tested for significant speedup variance
- [ ] At least **one batch size formula** (4n+1) shown to be better than random batches
- [ ] **No OOM crashes** observed in "safe default" profile; OOM behavior documented if aggressive profile crashes
- [ ] **per-slot recommendation** written with actual measured metrics
- [ ] **LLAMACPP_BASELINE_RESULTS.md** filled with results table

---

**Next steps:**
1. Review this plan with team
2. Allocate 8–10 hours of GB10 testing time
3. Run benchmark script (Section 7.3)
4. Aggregate results into LLAMACPP_BASELINE_RESULTS.md
5. Generate per-slot recommendations (Section 8)
6. Test recommended configs in production (systemd or docker-llm-switch)
7. Document final settings in README or systemd/.env

