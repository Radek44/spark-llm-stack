# TurboQuant Research Findings

TurboQuant, a KV cache quantization technique, was audited via Discussion #20969 and related PRs.

## Audit Findings
- **Status:** TurboQuant (using turbo3 / turbo4) is an active development in llama.cpp forks and experimental branches as of May 2026.
- **Compression:** Provides ~4.9x (turbo3) to 3.8x (turbo4) compression, enabling massive context windows (up to 536K) on consumer VRAM.
- **Implementation:** Usage confirmed via --cache-type-k turbo3 --cache-type-v turbo3. Asymmetric configurations are recommended.
- **Stability:** Generally stable and near-lossless at temp 0, with active performance optimizations in the MTP branches.

## Sources
[^1]: GitHub, "ggml-org/llama.cpp TurboQuant KV cache optimization (Discussion #20969)". Accessed 2026-05-22.
[^2]: GitHub, "ggml-org/llama.cpp PR #21089".
