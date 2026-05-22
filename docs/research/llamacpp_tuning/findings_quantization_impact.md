# Research Findings: Quantization Impact on Quality and Speed

## Quantization Level Comparison

### K-Quants Effectiveness (Community Consensus)
**Reddit r/LocalLLaMA consensus**:
- **Q4_K_M**: "sweet spot" — indistinguishable from unquantized, huge memory savings
- **Q5_K_M**: Slightly better quality than Q4_K_M, suitable if VRAM available
- **Q6_K**: Even higher quality, requires more memory

### Perplexity Impact (Llama 3 8B benchmark)

| Quantization | File Size (GB) | Perplexity | Quality vs F16 |
|--------------|----------------|-----------| -------------- |
| F16 | 14.97 | 6.2331 | Baseline |
| Q8_0 | 7.96 | 6.2342 | **-0.02% (lossless)** |
| Q6_K | 6.14 | 6.2533 | -0.03% |
| **Q5_K_M** | **5.33** | **6.2886** | **-0.09% (excellent)** |
| Q5_0 | 5.21 | 6.3632 | -0.21% |
| **Q4_K_M** | **4.58** | **6.3830** | **-0.24% (acceptable)** |
| Q4_0 | 4.34 | 6.7001 | -0.7% |

**Key Insight**: Q5_K_M offers nearly lossless quality with 64% size reduction. Q4_K_M sacrifices <0.25% quality for additional 32% size reduction.

---

## Unified Evaluation Study Results

**Which Quantization Should I Use? ArXiv Study (Jan 2025)**:

### Quality Metrics (MMLU, HellaSwag, etc. benchmarks)
- **Q4_K_M**: 69-79% accuracy (acceptable for most tasks)
- **Q5_K_M**: 64-78.5% accuracy (better for code/reasoning)
- **Q6_K**: 58-78% accuracy (edge cases preserved)

### Size Reduction
- Q4_K_M: **69.4% reduction** (4-bit equivalent 4.5 bpw)
- Q5_K_M: **64.3% reduction** (5-bit equivalent 5.5 bpw)
- Q6_K: **59% reduction** (6-bit equivalent 6.5 bpw)

### Recommendation
"Q4_K_M, Q5_K_S and Q5_K_M are considered recommended." — llama.cpp GitHub discussion

---

## Speedup Expectations on GB10

### Memory Bandwidth Impact
- **GB10 is bandwidth-limited** (273 GB/s LPDDR5X)
- Reducing model size directly → fewer memory transfers
- **Expected speedup**:
  - Q5_K vs F16: **2-2.5×** (64% model size reduction)
  - Q4_K_M vs F16: **3-3.5×** (69% model size reduction)

### Real-World Speedups (Reported)
- CPU inference (AMD 7995WX): Q8 ~2× faster than F16
- GPU inference (M2 Ultra): Q8 30-35% faster than F16 (compute-limited GPU, less benefit)
- **GB10 projection**: Q4_K_M likely **3-3.5× faster** than F16 (confirms prior research)

---

## Quality Loss by Use Case

| Use Case | Safe Quantization | Max Performance |
|----------|-------------------|------------------|
| Code generation | Q5_K_M (>0% quality) | Q4_K_M if acceptable |
| Summarization | Q5_K_M | Q4_K_M |
| Reasoning/MMLU | Q5_K_M | Q4_K_M (test first) |
| Translation | Q5_K_M | Q4_K_M (marginal risk) |
| Creative tasks | Q6_K (safety margin) | Q5_K_M |

---

## Recommended Quantizations for GB10 Slots

- **coder** (code, critical): Q4_K_M (with testing for edge cases)
- **architect** (design, reasoning): Q5_K_M (balanced)
- **gemma** (general): Q5_K_M (good quality/speed)
- **gptoss** (fast/summary): Q6_K or Q5_K_M (latency priority)

---

**Sources**:
- ArXiv: "Which Quantization Should I Use? A Unified Evaluation" (2025)
- GitHub ggml-org/llama.cpp#2094 (quantization comparison)
- JamesFlare blog: Quantization types for llama.cpp
- Reddit r/LocalLLaMA: GGUF quantization methods
- LessWrong: Comparing quantized performance in Llama models
