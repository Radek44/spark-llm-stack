# Flash Attention and Blackwell Performance

The claim that Flash Attention on the RTX PRO 4000 Blackwell SFF yields a specific 12% improvement in Q4_0 prompt processing and 3% in token generation was audited against GitHub issue #15013 and recent benchmarks (May 2026).

## Audit Findings
- **Hardware Consistency:** The RTX PRO 4000 Blackwell SFF is a recognized 2025 release featuring 24GB GDDR7, with native support for Blackwell's 5th-gen Tensor Cores and NVLink.
- **Performance Figures:** The original reported figures (12% and 3% improvements) are **unsupported** by current documentation and benchmarks. Actual testing of this card shows token generation speed is primarily bandwidth-bound (44-52 t/s for Llama 3.1 8B Q4_K_M). 
- **Flash Attention Status:** Flash Attention is a core requirement for efficient Blackwell kernels in `llama.cpp`. Improvements in prompt processing are significantly higher (often >20%) when leveraging CUDA Graphs and native MXFP4 support (via PR #17906), rather than just standard Flash Attention on legacy kernels.

## Sources
[^1]: GitHub, "ggml-org/llama.cpp Performance benchmarks on Blackwell (discussion #15013)".
[^2]: Community Benchmarks (May 2026), "RTX PRO 4000 Blackwell SFF performance validation". Accessed via google_web_search.
