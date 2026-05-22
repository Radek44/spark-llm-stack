# Research Findings: Grace Blackwell and ARM-Based GPU Tuning

## GB10 Hardware Specifications

### Memory Architecture (Critical for llama.cpp)
- **Unified Memory**: 128 GB LPDDR5X, coherent
- **Memory Bandwidth**: **273 GB/s** (vs 3.3 TB/s on traditional HBM3)
- **Memory Interface**: 256-bit
- **L2 Cache**: 65 MB unified L2 for GPU (vs 24 MiB for SoC variant)

**Key Implication**: GB10 is **~12× more bandwidth-constrained** than traditional NVIDIA GPUs. This explains why quantization (4-bit = 3.5× faster than F16) is so critical.

### CPU Architecture
- **20-core ARM-based Grace CPU**:
  - 10× Cortex-X925 (performance cores)
  - 10× Cortex-A725 (efficiency cores)
- **Available for llama.cpp**: Full 20 cores (72 cores mentioned in project notes is from DGX Spark variant; GB10 has 20)
- **Arm architecture characteristics**:
  - Lower clock speed (2-3 GHz typical) vs x86
  - Higher memory efficiency per core
  - Better for sustained throughput on memory-bound workloads

### L2 Cache Behavior
- **Light load latency**: 358 cycles
- **Saturation latency**: 508 cycles (+42% under load)
- **Implication**: L2 becomes bottleneck under contention; reduces available threads for parallelism

---

## ARM Threading Model Implications

### Physical Core Binding (Critical for GB10)
- **ARM provides 20 physical cores** (10 performance + 10 efficiency)
- **Recommendation**: Test 16-20 threads initially (match performance cores)
- **Avoid**: Pushing beyond 20 threads unless profiling shows benefit (efficiency cores slower)

### Memory Coherency (Unified Memory Advantage)
- Grace Blackwell provides **hardware coherency** between CPU and GPU memory
- This means:
  - No explicit cache flush needed
  - Sequential batching may be more efficient (avoid memory barrier overhead)
  - Similar behavior to unified memory systems like NVIDIA GH200

---

## Project DIGITS / DGX Spark Context

**NVIDIA's Marketing on GB10**:
- "Petaflop AI performance at FP4 precision"
- "128GB of coherent unified system memory"
- "Run AI models up to 200B parameters at your desktop"

**Practical tuning guidance**:
- GB10 targets latency-tolerant workloads (fine-tuning, inference, not real-time)
- The unified memory is a feature (enables large models) but a challenge (bandwidth limits throughput)

---

## Expected Performance Characteristics

### Threading Scaling on GB10
**Hypothesis** (based on ARM architecture + unified memory):
- Optimal: 16-20 threads
- Degradation point: 24+ threads (L2 cache contention)
- Diminishing returns: 32+ threads (efficiency cores kick in, higher latency)

### Memory Fragmentation on Unified Memory
- LPDDR5X is more susceptible to fragmentation than HBM3
- **Recommendation**: Use `4n+1` batch formula to align allocations (from ComfyUI research)
- **Avoid**: Large batch sizes (>16) without careful memory monitoring

### Expected Bandwidth-Limited Speedups
- Quantization benefit: **3-3.5×** for Q4_K_M (matches prior vLLM research on bandwidth-limited systems)
- Thread scaling: **1.5-2×** from 8 → 20 threads (half of x86 due to lower clock)

---

## Recommended GB10 Tuning Checklist

- [ ] Test threading: 8, 12, 16, 20, 24 (stop if degradation >20%)
- [ ] Confirm 4n+1 batch formula reduces memory fragmentation
- [ ] Quantize to Q4_K_M or Q5_K_M (follow bandwidth-limited strategy)
- [ ] Use `PYTORCH_NO_CUDA_MEMORY_CACHING=1` (let OS reclaim pages on unified memory)
- [ ] Monitor L2 cache hit rate under load (nvidia-smi L2 util)
- [ ] Avoid CPU core affinity pinning (let kernel scheduler handle it initially)

---

**Sources**:
- NVIDIA DGX Spark product page
- NVIDIA Project DIGITS announcement
- ASUS Ascent GX10 specs
- Medium: "NVIDIA Project DIGITS and Blackwell Architecture" (Jan 2025)
- EmergenMind: GB10 architecture overview
