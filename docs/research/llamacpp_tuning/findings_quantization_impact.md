# Research Findings: Quantization Impact on Quality and Speed

## Quantization Level Comparison

### Perplexity Impact (Llama 3 8B benchmark)

| Quantization | Size (GB) | Perplexity (PPL) | PPL Change vs. F16 |
|--------------|-----------|------------------|--------------------|
| F16          | 14.97     | 6.2331           | Baseline           |
| Q8_0         | 7.96      | 6.2342           | +0.018%            |
| Q6_K         | 6.14      | 6.2533           | +0.324%            |
| **Q5_K_M**   | 5.33      | 6.2886           | +0.890%            |
| **Q4_K_M**   | 4.58      | 6.3830           | +2.405%            |
| Q4_0         | 4.34      | 6.7001           | +7.492%            |

---

## Unified Evaluation Study Results

**Which Quantization Should I Use? ArXiv Study (Jan 2026)**:
*Paper title: "Which Quantization Should I Use? A Unified Evaluation of llama.cpp Quantization on Llama-3.1-8B-Instruct" (arXiv:2601.14277)*

### Recommendation
The study identifies specific formats that offer the best trade-off (Pareto frontier) for Llama-3.1-8B-Instruct:

| Goal | Recommended Format | Size Reduction | Performance |
| :--- | :--- | :--- | :--- |
| **Maximum Quality** | **`Q5_0`** | ~65% | Better than FP16 |
| **Best All-Rounder** | **`Q4_K_S`** | ~71% | ~99.5% of FP16 |
| **Maximum Savings** | **`Q3_K_L`** | ~73% | ~98.5% of FP16 |

**Key takeaway**: `Q5_0` is recommended as the new "gold standard" for local deployment, and users should avoid formats below `Q3_K_L` to maintain reasoning capabilities.

---

## Speedup Expectations on GB10

### Memory Bandwidth Impact
- **GB10 is bandwidth-limited** (273 GB/s LPDDR5X)
- Reducing model size directly reduces memory transfer bottlenecks.
- **Projected GB10 Speedup**: Q4_K_M likely **3-3.5× faster** than F16.

---

**Sources**:
- ArXiv: "Which Quantization Should I Use? A Unified Evaluation" (2601.14277, Jan 2026)
- Llama 3 8B GGUF benchmarks (based on llama.cpp perplexity tests)

