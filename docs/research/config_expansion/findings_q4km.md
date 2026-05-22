# Q4_K_M Research Findings

The claim that Q4_K_M (4-bit quantization) in llama.cpp matches AWQ and BitsandBytes in quality (specifically referencing a 51.8% HumanEval score) was audited.

## Audit Findings
- **Quality:** Q4_K_M is the standard "sweet spot" for GGUF-based inference, typically retaining 90–95% of FP16 quality.
- **Comparison:**
  - **vs AWQ:** AWQ often yields slightly higher accuracy retention in 4-bit models for reasoning/coding tasks, but Q4_K_M is highly competitive and significantly more flexible for diverse hardware.
  - **vs BitsandBytes:** NF4 (BitsandBytes) is optimized for QLoRA fine-tuning rather than inference performance.
- **Accuracy of Claim:** The 51.8% HumanEval score is an plausible figure for a base Llama 3 8B model quantized at 4-bit, but the claim that it matches AWQ and BitsandBytes is nuanced: GGUF/Q4_K_M is preferred for flexibility/latency, while AWQ is often superior for high-throughput GPU-bound accuracy. The claim is likely correct in broad strokes but technically contested depending on the specific hardware/model context.

## Sources
[^1]: N1N, "Quantization Guide for Local LLMs". Accessed 2026-05-22.
