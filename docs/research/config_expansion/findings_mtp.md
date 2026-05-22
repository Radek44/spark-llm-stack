# MTP Branch Research Findings

The Multi-Token Prediction (MTP) capability, previously identified as an experimental branch, was audited as of May 2026.

## Audit Findings
- **Status:** Officially merged into llama.cpp mainline as of May 16, 2026 (PR #22673).
- **Stability:** Stable, with a critical VRAM leak fix merged on May 21, 2026. Users are advised to use the latest master branch.
- **Usage:** Requires MTP-specific GGUF files and appropriate flags (--spec-type draft-mtp).
- **Known Issues:** Vision multimodal models and SWA (Sliding Window Attention) models can experience instability or lower acceptance rates.

## Sources
[^1]: GitHub, "ggml-org/llama.cpp PR #22673 (MTP Merge)". Accessed 2026-05-22.
