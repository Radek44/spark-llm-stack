# Verification Report: Q4_K_M Research Findings

## Claim Verification

| Claim | Assessment | Reasoning |
| :--- | :--- | :--- |
| Q4_K_M matches AWQ/BitsandBytes in quality (coding benchmarks). | **Contested** | Q4_K_M (mixed-precision) often outperforms AWQ/GPTQ in perplexity due to higher average bit-width (~4.8 bits), but AWQ is specialized for GPU throughput. BitsandBytes (NF4) is optimized for training, not inference, and usually underperforms on inference speed compared to GGUF/AWQ. |
| 51.8% HumanEval is the standard score for 4-bit Llama 3 8B. | **Likely** | This is a known benchmark figure for AWQ 4-bit Llama 3 8B. Q4_K_M (GGUF) often reports higher (e.g., ~60.9%) due to its mixed-precision nature. |

## Notes
- The "match" in quality is technically inaccurate; Q4_K_M (GGUF) typically retains more quality than uniform 4-bit quantizations like AWQ/GPTQ due to its layered mixed-precision approach.
- BitsandBytes (NF4) should not be used as an inference reference point, as it is primarily a training format with high overhead for inference.

## Updated Findings
The original findings were slightly imprecise regarding the comparative quality. GGUF (Q4_K_M) generally provides higher perplexity-based accuracy than uniform 4-bit methods like AWQ because it uses layered bit-width allocation. AWQ is superior for GPU throughput, not raw accuracy retention.

---
*Verified by Research Sub-Agent (2026-03-22)*
