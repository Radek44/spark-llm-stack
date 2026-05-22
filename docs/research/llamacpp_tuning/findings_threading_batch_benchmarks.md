# Research Findings: llama.cpp Threading & Batch Benchmarks

## Key Insights on Threading

### Thread Count Optimization
**Finding**: Performance peaks when the thread count matches the number of **physical performance cores**, as LLM inference is primarily **memory-bandwidth limited** rather than compute-bound.

- **Saturation Point**: Once threads saturate available memory channels, performance plateaus or degrades due to cache thrashing and synchronization overhead.
- **Physical vs. Logical**: Hyperthreading/SMT typically offers no benefit for `llama.cpp`'s compute-heavy, memory-bound workloads and should generally be ignored in thread configuration.
- **Hybrid Architectures**: For CPUs with Performance (P) and Efficiency (E) cores, pinning threads to P-cores prevents tail latency caused by slower E-core execution.

**Key Technical Context**: Inference requires reading the entire model weight set from memory for every single generated token. On consumer CPUs, this memory bandwidth is often saturated by 4 to 8 threads. Adding threads beyond the saturation point consumes additional power without increasing tokens per second.

---

## Batch Size and Inference Optimization

### Batch Scaling Performance
**llama.cpp Inference Considerations**:
- **Prompt Processing (PP)**: Compute-bound. Higher batch sizes (`-b`, `-ub`) significantly improve performance by leveraging GPU/CPU SIMD/Tensor units.
- **Token Generation (TG)**: Memory-bandwidth bound. Processing is effectively batch size 1 per stream, so throughput scaling relies on request concurrency (parallel inference) rather than single-request batch size.
- **Memory Overhead**: Increasing batch sizes consumes additional VRAM for the compute buffer; large batches on memory-constrained systems (like unified memory architectures with lower bandwidth than HBM) require careful tuning to prevent OOM errors.

---

## Unified Memory Considerations

**Note**: GB10's LPDDR5X (273 GB/s) offers significantly lower bandwidth than high-end GPU HBM3 (3.3 TB/s).
- **Amplified Overhead**: The impact of thread switching and memory I/O overhead is amplified on lower-bandwidth memory architectures.
- **Recommendation**: Prioritize thread affinity and memory locality over high-concurrency batching until baseline performance is established.

---

## Recommendations for GB10 Testing

1. **Start conservative**: `--threads` equal to the number of physical P-cores.
2. **Benchmark incrementally**: Vary `-t` (e.g., -t 4, -t 8, -t 12) and monitor `eval time` to find the saturation threshold.
3. **Use pinning**: Pin threads to high-performance cores where supported.
4. **Flash Attention**: Enable `-fa` to reduce memory overhead for large batches.

---

**Sources**:
- [ggml-org/llama.cpp (GitHub)](https://github.com/ggml-org/llama.cpp) - Inference optimization guidelines.
- [Memory bandwidth limitations in LLM inference](https://www.reddit.com/r/LocalLLaMA/) - Community benchmarks on memory-bound workloads.
- [Hybrid Architecture Performance](https://www.intel.com/content/www/us/en/developer/articles/technical/performance-tuning-hybrid-architectures.html) - Tuning for P/E core systems.
