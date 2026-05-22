# Verification Report: findings_threading_batch_benchmarks.md

**Date**: 2026-03-22
**Document**: `docs/research/llamacpp_tuning/findings_threading_batch_benchmarks.md`
**Verifier**: Gemini CLI (Verification Agent)

## Assessment
The original document contained speculative benchmarks (the batch size table) and potentially harmful configuration advice based on outdated or misinterpreted data (over-subscription of threads).

- **Confirmed**:
  - `llama.cpp` inference is memory-bandwidth limited.
  - Thread count should match physical P-cores.
  - Hyperthreading does not typically benefit compute-heavy, memory-bound workloads in this context.
- **Likely**:
  - Batching strategies (`-b` vs `-ub`) should differentiate between prompt processing and token generation stages.
  - Unified memory architectures like GB10 require lower threading overhead to maintain efficiency due to lower total memory bandwidth.
- **False/Unsupported (Corrected/Removed)**:
  - The provided batch size scaling table (e.g., batch 60-64 performance drop) was deemed speculative/unreferenced and removed to prevent misleading users.
  - RedHat "stable limit" advice (threads 64) was removed for potentially misleading over-subscription recommendations without specific hardware/workload context.

## Actions Taken
1. Updated findings to reflect current best practices for `llama.cpp` (physical core alignment, memory bandwidth bottleneck).
2. Added authoritative citations.
3. Removed unverified batch performance benchmarks.
4. Refined recommendations for the GB10 test plan to focus on incremental benchmarking rather than arbitrary high-thread counts.

The document is now considered authoritative and aligned with current `ggml-org` standards.
