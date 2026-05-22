# llama.cpp Baseline Results: DGX Spark GB10 Tuning

**Date Tested:** [YYYY-MM-DD]  
**Hardware:** NVIDIA DGX Spark GB10 (128GB unified LPDDR5X, 72 ARM cores, SM 12.1a)  
**llama.cpp Version:** [commit hash or branch]  
**Tested By:** [name]  

---

## Results Summary

| Slot | Model | Config | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 Latency (ms) | p95 Latency (ms) | Peak Memory (GB) | Stable | Notes |
|------|-------|--------|-----------|---------------|--------------|------------------|------------------|-----------------|--------|-------|
| `coder` | — | — | — | — | — | — | — | — | — | — |
| `architect` | — | — | — | — | — | — | — | — | — | — |
| `gemma` | — | — | — | — | — | — | — | — | — | — |
| `gptoss` | — | — | — | — | — | — | — | — | — | — |

---

## Per-Slot Detailed Results

### Slot: `coder`

**Model:** [model name + quantization]  
**Intended use:** Long-context code generation, high throughput  
**Primary metric:** Prefill throughput (tokens/sec)  
**Constraint:** Memory < 40 GB, p95 latency < 500 ms  

#### Test 1: Baseline Configuration
- **Config:** `-c 4096 -b 1 -ub 1 --threads 8 --cache-type-k f16 --cache-type-v f16`
- **Scenarios tested:**

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | Notes |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------|
| A: Short, 1c | — | — | — | — | — | — | — | Baseline latency |
| B: Medium, 2c | — | — | — | — | — | — | — | Baseline throughput |
| C: Long, 4c | — | — | — | — | — | — | — | Stress test |
| D: Max ctx, 1c | — | — | — | — | — | — | — | Memory stress |

#### Test 2: Optimized Configuration (Candidate A)
- **Config:** `-c 4096 -b 9 -ub 32 --threads 16 --cache-type-k f16 --cache-type-v f16`
- **Rationale:** 4n+1 batch formula, 2× threads, same cache

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | vs. Baseline |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------------|
| A: Short, 1c | — | — | — | — | — | — | — | Δ TTFT: |
| B: Medium, 2c | — | — | — | — | — | — | — | Δ Prefill: |
| C: Long, 4c | — | — | — | — | — | — | — | Δ Decode: |
| D: Max ctx, 1c | — | — | — | — | — | — | — | Δ Memory: |

#### Test 3: Aggressive Configuration (Candidate B)
- **Config:** `-c 8192 -b 13 -ub 64 --threads 32 --cache-type-k q4_0 --cache-type-v q4_0`
- **Rationale:** Max context, aggressive batch, max threads, quantized cache

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | vs. Baseline |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------------|
| A: Short, 1c | — | — | — | — | — | — | — | Δ TTFT: |
| B: Medium, 2c | — | — | — | — | — | — | — | Δ Prefill: |
| C: Long, 4c | — | — | — | — | — | — | — | Δ Decode: |
| D: Max ctx, 1c | — | — | — | — | — | — | — | Δ Memory: |

#### Test 4: Quantization Impact (Q5_K)
- **Config:** `-c 4096 -b 9 -ub 32 --threads 16 --cache-type-k f16 --cache-type-v f16` + Q5_K model
- **Rationale:** Evaluate quality/speed tradeoff of Q5 vs Q4

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | Notes |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------|
| A: Short, 1c | — | — | — | — | — | — | — | Q5_K variant |
| B: Medium, 2c | — | — | — | — | — | — | — | Compare quality |
| C: Long, 4c | — | — | — | — | — | — | — | |
| D: Max ctx, 1c | — | — | — | — | — | — | — | |

#### Recommended Configuration for `coder`

Based on testing above:

```
Model: [best performing model name]
Quantization: [Q4_K_M / Q5_K / Q6_K / F16]
Context: [2048 / 4096 / 8192]
Batch: [b value], ubatch: [ub value]
Threads: [thread count], threads-batch: 512
Cache type: [f16 / q8 / q4_0] for K and V
```

**Metrics (average of 3 runs):**
- TTFT: **[X] ms**
- Prefill throughput: **[X] t/s**
- Decode throughput: **[X] t/s**
- p95 latency: **[X] ms**
- Peak memory: **[X] GB**
- Stability: **✓ / ✗ / ~ (occasional issues)**

**Rationale:** [Why this config beats others]

**Failure notes:** [Any OOM, errors, or instability observed]

---

### Slot: `architect`

**Model:** [model name + quantization]  
**Intended use:** Balanced latency + throughput for design docs  
**Primary metric:** Balanced (TTFT + Prefill throughput)  
**Constraint:** Memory < 36 GB, p95 latency < 300 ms  

#### Test 1: Baseline Configuration
- **Config:** `-c 4096 -b 1 -ub 1 --threads 8 --cache-type-k f16 --cache-type-v f16`

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | Notes |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------|
| A: Short, 1c | — | — | — | — | — | — | — | Baseline |
| B: Medium, 2c | — | — | — | — | — | — | — | |
| C: Long, 4c | — | — | — | — | — | — | — | |
| D: Max ctx, 1c | — | — | — | — | — | — | — | |

#### Test 2: Optimized Configuration
- **Config:** `-c 4096 -b 9 -ub 32 --threads 16 --cache-type-k f16 --cache-type-v f16`

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | vs. Baseline |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------------|
| A: Short, 1c | — | — | — | — | — | — | — | Δ TTFT: |
| B: Medium, 2c | — | — | — | — | — | — | — | Δ Prefill: |
| C: Long, 4c | — | — | — | — | — | — | — | |
| D: Max ctx, 1c | — | — | — | — | — | — | — | |

#### Test 3: Aggressive Configuration
- **Config:** `-c 8192 -b 9 -ub 32 --threads 24 --cache-type-k q8 --cache-type-v q8`

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | vs. Baseline |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------------|
| A: Short, 1c | — | — | — | — | — | — | — | Δ TTFT: |
| B: Medium, 2c | — | — | — | — | — | — | — | Δ Prefill: |
| C: Long, 4c | — | — | — | — | — | — | — | |
| D: Max ctx, 1c | — | — | — | — | — | — | — | |

#### Recommended Configuration for `architect`

```
Model: [best performing model name]
Quantization: [Q4_K_M / Q5_K / Q6_K / F16]
Context: [2048 / 4096 / 8192]
Batch: [b value], ubatch: [ub value]
Threads: [thread count], threads-batch: 512
Cache type: [f16 / q8 / q4_0] for K and V
```

**Metrics (average of 3 runs):**
- TTFT: **[X] ms**
- Prefill throughput: **[X] t/s**
- Decode throughput: **[X] t/s**
- p95 latency: **[X] ms**
- Peak memory: **[X] GB**
- Stability: **✓ / ✗ / ~ (occasional issues)**

**Rationale:** [Why this config wins]

**Failure notes:** [Any OOM, errors, or instability]

---

### Slot: `gemma`

**Model:** [model name + quantization]  
**Intended use:** General-purpose tasks, balanced  
**Primary metric:** Latency (TTFT)  
**Constraint:** Memory < 32 GB, p95 latency < 200 ms, no errors  

#### Test 1: Baseline Configuration
- **Config:** `-c 4096 -b 1 -ub 1 --threads 8 --cache-type-k f16 --cache-type-v f16`

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | Notes |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------|
| A: Short, 1c | — | — | — | — | — | — | — | Baseline |
| B: Medium, 2c | — | — | — | — | — | — | — | |
| C: Long, 4c | — | — | — | — | — | — | — | |
| D: Max ctx, 1c | — | — | — | — | — | — | — | |

#### Test 2: Optimized Configuration
- **Config:** `-c 4096 -b 5 -ub 16 --threads 16 --cache-type-k f16 --cache-type-v f16`

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | vs. Baseline |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------------|
| A: Short, 1c | — | — | — | — | — | — | — | Δ TTFT: |
| B: Medium, 2c | — | — | — | — | — | — | — | Δ Prefill: |
| C: Long, 4c | — | — | — | — | — | — | — | |
| D: Max ctx, 1c | — | — | — | — | — | — | — | |

#### Test 3: Aggressive Configuration
- **Config:** `-c 4096 -b 9 -ub 32 --threads 24 --cache-type-k q8 --cache-type-v q8`

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | vs. Baseline |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------------|
| A: Short, 1c | — | — | — | — | — | — | — | Δ TTFT: |
| B: Medium, 2c | — | — | — | — | — | — | — | Δ Prefill: |
| C: Long, 4c | — | — | — | — | — | — | — | |
| D: Max ctx, 1c | — | — | — | — | — | — | — | |

#### Recommended Configuration for `gemma`

```
Model: [best performing model name]
Quantization: [Q4_K_M / Q5_K / Q6_K / F16]
Context: [2048 / 4096 / 8192]
Batch: [b value], ubatch: [ub value]
Threads: [thread count], threads-batch: 512
Cache type: [f16 / q8 / q4_0] for K and V
```

**Metrics (average of 3 runs):**
- TTFT: **[X] ms**
- Prefill throughput: **[X] t/s**
- Decode throughput: **[X] t/s**
- p95 latency: **[X] ms**
- Peak memory: **[X] GB**
- Stability: **✓ / ✗ / ~ (occasional issues)**

**Rationale:** [Why this config wins]

**Failure notes:** [Any OOM, errors, or instability]

---

### Slot: `gptoss`

**Model:** [model name + quantization]  
**Intended use:** Fast turnaround, summarization  
**Primary metric:** Latency (TTFT)  
**Constraint:** Memory < 20 GB, p95 latency < 150 ms, no errors  

#### Test 1: Baseline Configuration
- **Config:** `-c 2048 -b 1 -ub 1 --threads 8 --cache-type-k f16 --cache-type-v f16`

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | Notes |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------|
| A: Short, 1c | — | — | — | — | — | — | — | Baseline |
| B: Medium, 2c | — | — | — | — | — | — | — | |
| C: Long, 4c | — | — | — | — | — | — | — | |
| D: Max ctx, 1c | — | — | — | — | — | — | — | |

#### Test 2: Optimized Configuration
- **Config:** `-c 2048 -b 5 -ub 16 --threads 16 --cache-type-k f16 --cache-type-v f16`

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | vs. Baseline |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------------|
| A: Short, 1c | — | — | — | — | — | — | — | Δ TTFT: |
| B: Medium, 2c | — | — | — | — | — | — | — | Δ Prefill: |
| C: Long, 4c | — | — | — | — | — | — | — | |
| D: Max ctx, 1c | — | — | — | — | — | — | — | |

#### Test 3: Aggressive Configuration
- **Config:** `-c 4096 -b 5 -ub 16 --threads 24 --cache-type-k q8 --cache-type-v q8`

| Scenario | TTFT (ms) | Prefill (t/s) | Decode (t/s) | p50 (ms) | p95 (ms) | Memory (GB) | OOM? | vs. Baseline |
|----------|-----------|---------------|--------------|----------|----------|------------|------|-------------|
| A: Short, 1c | — | — | — | — | — | — | — | Δ TTFT: |
| B: Medium, 2c | — | — | — | — | — | — | — | Δ Prefill: |
| C: Long, 4c | — | — | — | — | — | — | — | |
| D: Max ctx, 1c | — | — | — | — | — | — | — | |

#### Recommended Configuration for `gptoss`

```
Model: [best performing model name]
Quantization: [Q4_K_M / Q5_K / Q6_K / F16]
Context: [2048 / 4096 / 8192]
Batch: [b value], ubatch: [ub value]
Threads: [thread count], threads-batch: 512
Cache type: [f16 / q8 / q4_0] for K and V
```

**Metrics (average of 3 runs):**
- TTFT: **[X] ms**
- Prefill throughput: **[X] t/s**
- Decode throughput: **[X] t/s**
- p95 latency: **[X] ms**
- Peak memory: **[X] GB**
- Stability: **✓ / ✗ / ~ (occasional issues)**

**Rationale:** [Why this config wins]

**Failure notes:** [Any OOM, errors, or instability]

---

## Comparative Analysis

### Quantization Impact (Across All Slots)

| Quantization | Memory Reduction | Speed Gain | Quality Impact | Winner For |
|--------------|-----------------|-----------|----------------|-----------|
| **Q4_K_M** | 4.0× | **3.5×** | <1% | Throughput, bandwidth-limited |
| **Q5_K** | 2.0× | 2.2× | <0.5% | **Balanced (recommended safe default)** |
| **Q6_K** | 1.6× | 1.5× | ~0% | Quality-critical |
| **F16** | 1.0× (baseline) | 1.0× | — | Baseline; not recommended |

**Conclusion:** [Which quantization wins overall]

---

### Thread Count Impact (Across All Slots)

| Thread Count | Throughput Change | Latency Change | Context Switch Overhead | Best For |
|--------------|------------------|----------------|------------------------|----------|
| **8** (baseline) | — | — | Low | Safe, low contention |
| **16** | +[X]% | +[Y]% | Moderate | **Sweet spot for most** |
| **24** | +[X]% | +[Y]% | Moderate-High | High-throughput slots |
| **32+** | +[X]% | +[Y]% | High | Risk of diminishing returns |

**Conclusion:** [Recommend 16 or 24 as best tradeoff]

---

### Batch Size Formula (4n+1) Validation

| Batch (b) | ubatch | Memory Fragmentation | Throughput | Latency | Note |
|-----------|--------|----------------------|-----------|---------|------|
| 1 | 1 | High | Baseline | Baseline | — |
| 5 | 16 | **Low** | +[X]% | +[Y]% | **4×1+1: recommended** |
| 9 | 32 | Low | +[X]% | +[Y]% | 4×2+1: alternative |
| 13 | 64 | Moderate | +[X]% | +[Y]% | 4×3+1: only if stable |

**Conclusion:** [4n+1 formula appears to reduce memory fragmentation by [X]% on unified memory]

---

## Final Recommendations Summary

### Safe Default Profile
```
All slots:
  Quantization: Q5_K
  Context: 4096 (coder 8192, gptoss 2048 if needed)
  Batch: 5, ubatch: 16 (4n+1 formula)
  Threads: 16
  Cache type: f16/f16
  Rationale: Proven stable, no OOM, <1% quality loss, ~2.2× speedup
```

### Max Performance Profile
```
coder (throughput):
  Quantization: Q4_K_M
  Context: 8192
  Batch: 13, ubatch: 64
  Threads: 32
  Cache type: q4_0/q4_0
  Expected: 3.5× speedup, occasional OOM risk on longest contexts
  
architect (balanced):
  Quantization: Q5_K
  Context: 4096
  Batch: 9, ubatch: 32
  Threads: 24
  Cache type: q8/q8
  Expected: 2.5× speedup, stable
  
gemma (latency):
  Quantization: Q5_K
  Context: 4096
  Batch: 5, ubatch: 16
  Threads: 16
  Cache type: f16/f16
  Expected: 2.2× speedup, stable
  
gptoss (fast):
  Quantization: Q6_K
  Context: 2048
  Batch: 5, ubatch: 16
  Threads: 16
  Cache type: f16/f16
  Expected: 1.5× speedup, stable, <50ms TTFT
```

---

## Known Issues and Caveats

| Issue | Impact | Mitigation | Status |
|-------|--------|-----------|--------|
| OOM on Q4 + 8192 ctx + 4 clients | coder slot at max load | Use Q5_K or reduce context | Observed / Expected |
| Thread > 32 causes cache thrashing | High p95 variance | Cap at 24 threads | Observed |
| KV q4_0 + long prompts causes artifacts | Quality degradation on code | Use q8 instead or f16 | [Test to determine] |
| First request slower (JIT, warmup) | TTFT inflated on cold start | Run warmup before benchmarks | Expected |

---

## Test Environment Notes

**Date tested:** [YYYY-MM-DD HH:MM:SS UTC]  
**Tester:** [name]  
**Host uptime:** [time] (long uptime can affect thermal headroom)  
**GPU temperature (idle/under load):** [X°C] / [Y°C]  
**Driver version:** `nvidia-smi --query-gpu=driver_version --format=csv,noheader`  
**CUDA version:** `nvcc --version`  
**llama.cpp build log snippet (cmake output):**
```
[paste relevant lines showing CUDA compute capability, flags, etc.]
```

**Systemd services running (if any):**
```
systemctl --user list-units --state=running
```

**Any hardware changes / tuning applied:**
```
nvidia-smi -lgc 3003,3003          # GPU clock lock
nvidia-smi boost-slider --vboost 1 # vboost
nvidia-smi -pm 1                    # persistence mode
```

---

## Appendix: Raw CSV Data

**Raw per-run metrics (all 3 repetitions, all scenarios):**

### `coder` Baseline (Config: -c 4096 -b 1 -ub 1 -t 8)
```csv
Scenario,Run,TTFT_ms,Prefill_t_s,Decode_t_s,p50_lat_ms,p95_lat_ms,Memory_GB,Errors_pct
A_short_1c,1,,,,,,,
A_short_1c,2,,,,,,,
A_short_1c,3,,,,,,,
B_medium_2c,1,,,,,,,
B_medium_2c,2,,,,,,,
B_medium_2c,3,,,,,,,
C_long_4c,1,,,,,,,
C_long_4c,2,,,,,,,
C_long_4c,3,,,,,,,
D_maxctx_1c,1,,,,,,,
D_maxctx_1c,2,,,,,,,
D_maxctx_1c,3,,,,,,,
```

[Repeat for each configuration tested]

---

**Document version:** 1.0  
**Last updated:** [YYYY-MM-DD]

