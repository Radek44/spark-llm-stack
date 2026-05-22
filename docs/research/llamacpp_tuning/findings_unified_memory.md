---
title: "Verification Report: Unified Memory Performance and KV Cache Optimization"
date: "2026-03-22"
authors: ["Gemini"]
purpose: "Verify claims in findings_unified_memory.md against authoritative sources."
status: "Completed"
---

# Verification Report

## Summary of Findings
The document contains accurate information regarding the nature and source of KV cache fragmentation, heavily drawing on established research (vLLM/PagedAttention). The specific strategy recommended for llama.cpp on a hypothetical "GB10" unified memory system is a mix of standard LLM best practices and specific tuning suggestions.

## Claim Verification

| Claim | Status | Notes |
| :--- | :--- | :--- |
| KV cache waste (60-80%) in traditional systems | **Confirmed** | Source: SOSP 2023 "Efficient Memory Management for Large Language Model Serving with PagedAttention". |
| PagedAttention reduces waste to <4% | **Confirmed** | Source: PagedAttention paper / vLLM documentation. |
| `--cache-type-k q8` available in llama.cpp | **Confirmed** | Llama.cpp supports KV cache quantization (k-quants). |
| Unified memory has coherency overhead (~1-2%) | **Likely** | Consistent with general knowledge of unified memory (e.g., NVIDIA Grace Hopper, Apple Silicon). |
| 4n+1 batch size formula | **Contested** | No authoritative source links 4n+1 to KV cache fragmentation reduction in llama.cpp. This is likely a hallucination or misapplied heuristic from other domains. |

## Updated Findings (`docs/research/llamacpp_tuning/findings_unified_memory.md`)

```markdown
# Research Findings: Unified Memory Performance and KV Cache Optimization

## KV Cache Fragmentation Problem

### Scale of the Problem
**Finding**: Inference systems waste **60-80% of allocated KV cache memory** through fragmentation and over-allocation [1].

**Example** (70B model, 8K context):
- ~20 GB KV cache per request
- Traditional approach: Over-provision for max context length, waste majority of space
- PagedAttention approach: Only allocate what's needed, waste <4% [1].

---

## Memory Fragmentation Sources

### Internal & External Fragmentation
- **Internal**: Pre-allocating full sequence length (8192 tokens) for every request.
- **External**: Requests in batch require different pre-allocated sizes; gaps between large contiguous allocations cannot be reused [1].

---

## Solutions and Techniques

### 1. PagedAttention (vLLM approach)
**Mechanism**: Divide KV cache into fixed-size "pages" [1].
**Status**: Not integrated into llama.cpp; available in vLLM [1].

### 3. KV Cache Quantization
**Technique**: Store KV cache in lower precision (q8, q4).
**Status**: Available in llama.cpp via `--cache-type-k q8` [2].

---

## Unified Memory Specific Strategies

### Custom Pooling for Unified Memory
**Finding**: Unified memory benefits from pre-allocation.

**Recommended approach for GB10**:
1. Pre-allocate large KV cache pool at startup.
2. Set `PYTORCH_NO_CUDA_MEMORY_CACHING=1` to enable page reclaim (relevant if using PyTorch-based runners).

### Batch Size Formula (4n+1)
**Finding**: **Unsupported/Likely False**. There is no established research confirming the "4n+1" batch size formula as an effective memory fragmentation reduction technique for `llama.cpp` or general LLM serving. 

---

**Sources**:
[1] Kwon et al., "Efficient Memory Management for Large Language Model Serving with PagedAttention" (SOSP 2023).
[2] Llama.cpp official documentation.
```

## Conclusion
The technical foundation is sound, but the "4n+1" batch size heuristic should be removed or labeled as unverified speculation.
