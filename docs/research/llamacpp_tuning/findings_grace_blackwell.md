# Research Findings: Grace Blackwell and ARM-Based GPU Tuning

## GB10 Hardware Specifications

### Memory Architecture (Critical for llama.cpp)
- **Unified Memory**: 128 GB LPDDR5X-9400, coherent [1]
- **Memory Bandwidth**: **301 GB/s** (raw), 600 GB/s aggregate accessible via low-power C2C NVLINK [1, 5]
- **Memory Interface**: 256-bit [1, 3]

**Key Implication**: GB10 is bandwidth-constrained compared to traditional HBM3-based GPUs. This makes quantization (e.g., FP4/Q4) highly effective for increasing effective throughput. [1, 4]

### CPU Architecture
- **20-core ARM-based Grace CPU**:
  - Organized into two clusters of 10 cores [4]
- **Available for llama.cpp**: Full 20 cores (the 72-core figure refers to different DGX/Superchip variants) [4]
- **Arm architecture characteristics**:
  - Higher memory efficiency per core [4]
  - Optimized for sustained throughput [4]

### L2 Cache Behavior
- **Characteristics**: L2 cache becomes a bottleneck under high contention, impacting parallel thread scaling. [4]

---

## ARM Threading Model Implications

### Physical Core Binding (Critical for GB10)
- **ARM provides 20 physical cores** [4]
- **Recommendation**: Test 16-20 threads initially to match physical performance cores. [4]

### Memory Coherency (Unified Memory Advantage)
- Grace Blackwell provides **hardware coherency** between CPU and GPU memory [1, 4]
- This eliminates the need for explicit cache flushes and allows for efficient sequential batching. [1, 4]

---

## Project DIGITS / DGX Spark Context

**NVIDIA's Positioning of GB10**:
- "Personal AI Supercomputing" offering a massive 128GB coherent memory buffer for 200B+ parameter models. [1, 4]

**Practical tuning guidance**:
- GB10 is ideal for large-scale local LLM inference and development. [4]

---

## Expected Performance Characteristics

### Threading Scaling on GB10
**Hypothesis** (based on ARM architecture + unified memory):
- Optimal: 16-20 threads [4]
- Degradation point: 24+ threads (due to L2 cache contention) [4]

### Expected Bandwidth-Limited Speedups
- Quantization benefit: Significant, enabling models up to 200B+ parameters to run locally. [1, 4]

---

## Recommended GB10 Tuning Checklist

- [ ] Test threading: 8, 12, 16, 20, 24 (stop if degradation >20%)
- [ ] Quantize to Q4_K_M or Q5_K_M (bandwidth-limited strategy)
- [ ] Monitor L2 cache hit rate under load [4]
- [ ] Avoid CPU core affinity pinning (allow kernel scheduler flexibility)

---

**References**:
[1] VideoCardz, "NVIDIA GB10 Grace Blackwell Superchip Specs," https://videocardz.com
[2] PCMag, "NVIDIA DGX Spark Workstation Analysis," https://pcmag.com
[3] TechPowerUp, "GB10 Architecture Deep Dive," https://techpowerup.com
[4] NVIDIA / Newegg / Wccftech technical specifications, https://newegg.com / https://wccftech.com
[5] Wccftech, "Grace Blackwell Superchip Bandwidth Details," https://wccftech.com
