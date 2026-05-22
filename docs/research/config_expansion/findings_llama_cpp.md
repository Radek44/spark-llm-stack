# llama.cpp / llama-server Configuration Research

## Quantization Levels and Performance

### GGUF Quantization Formats
- **Q4_K_M** (4-bit): Strong code generation performance (51.8% on HumanEval), matches AWQ and BitsandBytes
  - Uses GGML's simpler quantization (standard scale/zero-point, not activation-aware)
  - Good for code tasks despite simpler approach
- **Q5_K, Q6_K**: Higher quality at cost of increased VRAM
- **F16**: Full precision, best quality but 2x VRAM vs Q4
- **GGUF vs AWQ/GPTQ**: GGUF Q4_K_M matches AWQ and BitsandBytes on quality metrics despite simpler method

## Grace Blackwell Specific

### TurboQuant KV Cache Optimization
- Extreme KV cache quantization available via `--cache-type-k turbo3 --cache-type-v turbo3`
- Block size optimization: 4.57x → 5.12x compression with turbo3
- Note: q8_0/q8_0 can fail on large models (Qwen3.6-27B reported)
- MTP branch (multi-token prefill) shows degenerate-loop stability patterns

### Threading
- Grace has 72 ARM cores available
- Current implementation uses `--threads 8` which is conservative
- Opportunity: test `--threads 32-72` scaling
- MTP branch may have better threading scheduling

### Flash Attention
- Confirmed working on Blackwell (RTX PRO 4000 Blackwell SFF has sm_120, similar architecture to sm_121)
- Benchmark: Q4_0 with FA: 4078 t/s vs without: 3628 t/s (12% improvement)
- Token generation (tg128): 92.54 t/s with FA vs 89.73 without FA (3% improvement)

## Key References
- GitHub: ggml-org/llama.cpp#15013 — Performance benchmarks on Blackwell
- GitHub: ggml-org/llama.cpp#20969 — TurboQuant KV cache optimization discussion
- Jarvis Labs: Complete guide to LLM Quantization with vLLM (2026) — quantization comparisons
- Reddit: /r/LocalLLaMA — GB10 performance estimation discussions

## Recommendations
1. Test `--cache-type-k turbo3 --cache-type-v turbo3` for memory optimization
2. Benchmark `--threads 16-32` vs current `--threads 8` on GB10
3. Consider pinning to MTP branch for multi-token prefill (if performance critical)
4. Q5_K or Q6_K recommended for quality-critical applications
