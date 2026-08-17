# Model candidates for DGX Spark local serving

Current selection verified from Poolside and Hugging Face primary sources on 2026-08-01. The older discovery evidence below remains dated 2026-06-20.

## Recommendation

Keep the local LLM stack lean:

1. Accepted default local agent: `poolside/Laguna-S-2.1-NVFP4`
   - Pin the last DGX-sized target revision `07614121b31898586430f189d27a25a0be310843` and its spinquant-removal DFlash revision `4cdcc6e9b29105e8ff5790885cadccbeb4f33f54`.
   - Role: `fast_local`, `private_local`, native interleaved thinking, and Poolside tool parsing.
   - Use vLLM 0.26.0, 32,768 tokens, one sequence, eager execution, an explicit 4 GiB BF16 KV cache, `expandable_segments:False`, and DFlash rather than MTP. The accepted run held at least 36.6 GiB `MemAvailable`; direct and LiteLLM-routed output, thinking, tools, and speculative acceptance passed.
   - Requalify FP8 KV separately: it produced severe repetition and NVIDIA allocation errors locally despite Poolside's advertised FP8-KV scheme. The experimental expandable allocator also produced errors when attaching DFlash.
   - Poolside replaced the target on 2026-08-01: the original official target is 66.98 GiB, while revision `f8fdfcdc4e7b0c474a0102430a8cae0a3a358669` is 92.85 GiB despite upstream prose still saying roughly 71-72 GB. The newer target crossed the 20 GiB host-memory floor during weight load and was removed from the local cache after the safe pin passed.
2. Alternate local agent: `RadixArk/Qwen3.8-27B-NVFP4` + `RadixArk/Qwen3.8-27B-DSpark`
   - Pin target revision `52d1adc5f38aa5ebf099c29ed7025ba34cfbb854` and draft revision
     `923ed3a8572615643f0137e424e4ce4edd7f1cda`.
   - Role: `qwen38`. Dense 27B hybrid (Gated DeltaNet + Gated Attention), multimodal,
     Apache 2.0, 262,144 native context, released 2026-08-14.
   - Served by SGLang image `qwen38-27b` on `:8171`, DSpark speculative decoding with
     block size 7, `flashinfer` attention, `mem-fraction-static 0.50`, context 65,536.
   - **Not** a standing service: `Conflicts=` with Laguna, started on demand via
     `llm-switch qwen38`. This does not violate the one-heavyweight-checkpoint rule.
   - Engine choice follows the model card, which names SGLang and documents the DSpark
     flags; it is not a benchmark result. Measured here: SGLang+NVFP4+DSpark runs
     27.9-40.6 tok/s at parallel 1 on this GB10. llama.cpp+MTP and vLLM+DSpark were never
     run on this machine and carry no local numbers. Note that vLLM 0.26.0 does implement
     `dspark` and `dflash`, so it is a viable alternative runtime, not an excluded one.
     The archived llama.cpp trees stay available if
     that ever needs rechecking locally.
   - Requalify separately: context above 65,536, and `mem-fraction-static` above 0.50. The
     latter is dangerous precisely because it fails quietly into eager mode.

3. Do not add another resident coding or reasoning checkpoint by default.
   - Hosted `architect`, `implementer`, `mechanical`, and `adversary` profiles remain authoritative for Agent OS roles.
   - Re-evaluate a small local specialist only from measured quality/latency demand, not as another standing service.

## Why not keep the old GGUF stack

The old llama.cpp GGUF services were useful during tuning, but they add operational surface area:

- multiple service files and drop-ins;
- old HF cache entries consuming ~120G;
- risk of accidentally starting old heavyweight checkpoints;
- duplicate routing config now that LiteLLM exists.

The old model services and cached GGUF checkpoints were removed after Laguna acceptance. Archived llama.cpp source/build trees remain available for future benchmarking.

## HF evidence captured

Top/download-heavy text-generation models included:

- `deepseek-ai/DeepSeek-R1-0528` — ~7.15M downloads, strong likes, but too large as a default local model unless using distill/quant variants.
- `deepseek-ai/DeepSeek-R1` — ~6.8M downloads, highest likes in the query, not the default for this DGX Spark stack.
- `openai/gpt-oss-20b` — ~6.8M downloads, `vllm`, `mxfp4` tags.
- `openai/gpt-oss-120b` — ~4.0M downloads, `vllm`, `mxfp4` tags.

Targeted Qwen3.6 search:

- `Qwen/Qwen3.6-27B` — ~6.0M downloads.
- `Qwen/Qwen3.6-35B-A3B-FP8` — ~5.5M downloads.
- `Qwen/Qwen3.6-35B-A3B` — ~5.1M downloads.
- `nvidia/Qwen3.6-35B-A3B-NVFP4` — ~3.6M downloads, NVIDIA FP4, text-generation.
- `RedHatAI/Qwen3.6-35B-A3B-NVFP4` — ~2.8M downloads, vLLM tag.
- `cyankiwi/Qwen3.6-35B-A3B-AWQ-4bit` — ~1.6M downloads.

Targeted Nemotron search:

- `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16` — ~1.7M downloads.
- `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4` — ~1.5M downloads.
- `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16` — ~1.4M downloads.
- `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4` — ~772k downloads.
- `nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-NVFP4` — available but not appropriate for a single 128G DGX Spark.

Targeted coder search:

- `Qwen/Qwen3-Coder-30B-A3B-Instruct` — ~1.9M downloads.
- `Qwen/Qwen3-Coder-Next` — ~1.1M downloads.
- `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` — ~990k downloads.
- `QuantTrio/Qwen3-Coder-30B-A3B-Instruct-AWQ` — vLLM/AWQ quant candidate.

## Service roadmap

Current clean target:

```text
fast_local -> poolside/Laguna-S-2.1-NVFP4 + matched DFlash via vLLM on :8170
private_local -> same local-only model, no cloud fallback
qwen38 -> RadixArk/Qwen3.8-27B-NVFP4 + DSpark via SGLang on :8171 (conflicts with fast_local)
litellm -> 127.0.0.1:8180 router
```

Never enable more than one heavyweight checkpoint at boot.
