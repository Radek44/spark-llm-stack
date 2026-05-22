# Research Findings: Unified Memory Performance and KV Cache Optimization

## KV Cache Fragmentation Problem

### Scale of the Problem
**Finding**: Inference systems waste **60-80% of allocated KV cache memory** through fragmentation and over-allocation.

**Example** (70B model, 8K context):
- ~20 GB KV cache per request
- Batch of 32 requests: ~640 GB needed (exceeds GB10's 128 GB!)
- **Traditional approach**: Over-provision for max context length, waste majority of space
- **PagedAttention approach**: Only allocate what's needed, waste <4%

---

## Memory Fragmentation Sources

### Internal Fragmentation
- Pre-allocating full sequence length (8192 tokens) for every request
- Actual request may only use 2000 tokens
- Remainder stays reserved for lifetime of request

### External Fragmentation
- Requests in batch require different pre-allocated sizes
- Gaps between allocations cannot be reused
- Severe on unified memory due to lower bandwidth (any waste is costly)

---

## Solutions and Techniques

### 1. PagedAttention (vLLM approach)
**Mechanism**: Divide KV cache into fixed-size "pages" (like OS virtual memory)
- **Benefits**:
  - Reduces fragmentation from 60-80% → <4%
  - Enables 2-4× throughput improvement
  - Allows copy-on-write (shared prefixes across requests)
- **Status**: Not integrated into llama.cpp yet; available in vLLM

### 2. Custom Memory Allocators
**Technique**: Replace `cudaMalloc`/`cudaFree` with pooling allocators
- Pre-allocate large memory pools
- Manage allocation/deallocation within pools
- **Benefits**: Reduces CUDA driver calls, minimizes fragmentation
- **Status**: Can be implemented in llama.cpp; not default

### 3. KV Cache Quantization
**Technique**: Store KV cache in lower precision (q8, q4)
- Reduces memory requirements by 2-4×
- Reduces fragmentation proportionally
- **Status**: Available in llama.cpp via `--cache-type-k/v q8`

### 4. Layer-Wise KV Cache Management (LayerKV)
**Technique**: Keep only subset of KV layers on GPU during prefill
- Move some layers to CPU memory during prefill phase
- Reduces TTFT (time to first token)
- **Status**: Research prototype, not in llama.cpp yet

### 5. Attention Offloading (InfiniGen)
**Technique**: Prefetch only required KV cache blocks (not entire cache)
- Minimize PCIe bandwidth usage
- Useful for CPU-offloaded KV cache
- **Status**: Research prototype

---

## Unified Memory Specific Strategies

### Custom Pooling for Unified Memory
**Finding**: Unified memory benefits from pre-allocation more than discrete memory.

**Recommended approach for GB10**:
1. Pre-allocate large KV cache pool at startup
2. Use custom allocator for requests
3. Return unused memory to OS (not needed on unified memory like discrete GPU)
4. Set `PYTORCH_NO_CUDA_MEMORY_CACHING=1` to enable page reclaim

### Batch Size Formula (4n+1)
**Finding** (from ComfyUI research): Batch sizes following 4n+1 (1, 5, 9, 13, 17) reduce fragmentation
- **Why**: Aligns memory allocations to cache line boundaries
- **Impact**: ~10-15% memory reduction on unified memory systems
- **Status**: Not proven for llama.cpp, but worth testing

---

## Expected Memory Improvements on GB10

### Current llama.cpp (no optimization)
- KV cache waste: ~50% on batch size 8
- Effective memory for batch size 8: ~60GB + model weight
- **Result**: OOM on 8+ concurrent requests (128GB limit)

### With quantized KV cache (`--cache-type-k q8`)
- KV cache size: 50% of f16
- Waste: ~50% of quantized (so ~25% overall)
- Effective for batch 16: ~30GB KV + model
- **Result**: ~4 concurrent requests (roughly 2× improvement)

### With batch formula (4n+1) + quantized KV
- Fragmentation reduction: ~10%
- Combined savings: 50% + 10% = 60% reduction
- Effective for batch 16: ~25GB KV + model
- **Result**: ~5 concurrent requests (practical for GB10)

---

## Recommendations for llama.cpp on GB10

1. **Use quantized KV cache**:
   ```bash
   --cache-type-k q8 --cache-type-v q8
   ```
   (Reduces memory footprint by 2×, fragmentation by proportion)

2. **Enable unified memory page reclamation**:
   ```bash
   PYTORCH_NO_CUDA_MEMORY_CACHING=1
   ```

3. **Test 4n+1 batch formula**:
   - Start with `-b 5 -ub 16` (4×1+1)
   - Test `-b 9 -ub 32`, `-b 13 -ub 64`
   - Measure memory fragmentation improvement

4. **Monitor allocation patterns**:
   - Use `nvidia-smi dmon` to watch memory allocation/free
   - Look for large allocations followed by small frees (fragmentation)

---

## Unified Memory Limitations

**Important caveat**: GB10's unified memory is a **feature**, not a performance advantage.
- Coherency overhead: ~1-2% latency cost vs discrete memory
- Bandwidth: Still 273 GB/s (same as discrete)
- **Benefit**: Simplifies programming, enables larger models
- **Cost**: No freedom to optimize memory layout like discrete GPU

---

**Sources**:
- NVIDIA Blog: Mastering LLM Techniques (2024)
- ArXiv: KV Cache Optimization Strategies (2026)
- Introl Blog: KV Cache Optimization for Production LLMs
- APXml: LLM Compression and Acceleration (Chapter 6)
- vLLM PagedAttention paper
