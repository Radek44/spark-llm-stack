# Research Findings: llama.cpp Threading & Batch Benchmarks

## Key Insights on Threading

### Thread Count Optimization
**Finding**: Performance peaks at the number of physical CPU cores, then degrades beyond that due to memory bandwidth saturation.

- **AMD Ryzen 3700X (8 cores)**: Performance peaks at 8 threads, drops significantly at 9+ threads
- **AMD Ryzen Threadripper (16 cores)**: Best performance at 16 threads  
- **Intel Xeon (quad-channel memory)**: Can sustain 29 threads due to higher memory bandwidth
- **GB10 Grace CPU (20 cores, Arm-based)**: Expected optimal range: 16-32 threads (needs testing)

**Key Quote**: "Memory bandwidth is the silent governor of Llama.cpp's performance. CPUs like the AMD RX 3700X, with its eight physical cores and dual-channel memory, illustrate this perfectly. Benchmarks show that performance peaks at eight threads—the exact number of physical cores. Push beyond that, and you're not just wasting resources; you're actively slowing things down." — Notes on Llama.cpp optimization.

**Implication for GB10**: With 20 ARM cores and Arm's higher memory efficiency per core, testing 16, 20, and 24 threads recommended before pushing to 32.

---

## Batch Size and Unbatch Optimization

### Batch Scaling Performance
**llama.cpp Batched Inference Results (A100 GPU, 7B OpenLLaMA F16)**:

| Batch Size | Tokens/sec |
|-----------|------------|
| 1 | 108.29 |
| 8 | 247.30 |
| 10 | 296.58 |
| 16 | 368.59 |
| 32 | 422.33 |
| 60 | 489.99 |
| 64 | 481.83 |

**Findings**:
- Linear scaling up to batch 60, then diminishing returns
- Batch size 32 gives ~3.9× throughput vs batch 1
- Beyond batch 64, performance drops (cache thrashing, attention kernel inefficiency)

### Server Production Tuning
**RedHat Production Study** (H200 GPU):
- `--threads 64` and `--threads-batch 64` determined as "stable limit"
- This suggests dedicated batch threads improve concurrent request handling
- Suggests batch threads should be ≤ total threads (prevent oversubscription)

**ClearML Guidance**:
- Higher thread values improve performance on multi-core systems
- **Separate threads-batch** from main threads for handling multiple requests
- `--parallel N` controls number of request slots

---

## Unified Memory Considerations

**Note**: Traditional discrete GPU memory (HBM3) has 3.3 TB/s bandwidth. GB10's LPDDR5X has 273 GB/s — a **12× difference**. This means:
- Batch overhead (thread switching, memory I/O) is amplified on GB10
- Fragmentation costs more on unified memory
- Sequential batching may outperform concurrent approaches

---

## Recommendations for GB10 Testing

1. **Start conservative**: `--threads 16 --threads-batch 16`
2. **Test incrementally**: 16 → 20 → 24 → 32
3. **Watch for degradation**: If p95 latency increases >20%, you've hit the wall
4. **Ubatch strategy**: Keep ubatch = batch or batch + slack (e.g., `-b 9 -ub 32`)

---

**Sources**:
- GitHub ggml-org/llama.cpp#3479 (batched decoding performance)
- Notes on Llama.cpp (notes.suhaib.in)
- GitHub ggml-org/llama.cpp#18308 (parallel inference optimization)
- RedHat: vLLM or llama.cpp comparison (2024)
- Debian manpages llama-server
