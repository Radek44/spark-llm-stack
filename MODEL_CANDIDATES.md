# Model candidates for DGX Spark local serving

Snapshot source: Hugging Face Hub API queries run on 2026-06-20 for text-generation downloads/likes plus targeted Qwen, Nemotron, and coder searches.

## Recommendation

Keep the local LLM stack lean:

1. Default local agent model: `nvidia/Qwen3.6-35B-A3B-NVFP4`
   - HF search: ~3.6M downloads, NVIDIA FP4, vLLM-oriented, explicitly aligned with DGX Spark/Hermes guidance.
   - Role: `fast_local`, `private_local`.
   - Installed and booted via vLLM 0.23.0 on this host with `max_model_len=65536` and `gpu_memory_utilization=0.50` to avoid unified-memory pressure.
   - Observed warning: vLLM selected Marlin weight-only FP4 and logged that native FP4 compute was not detected. If throughput is disappointing, compare against `Qwen/Qwen3.6-35B-A3B-FP8` before adding more models.
2. NVIDIA-native alternate: `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4`
   - HF search: ~772k downloads for NVFP4, 30B/A3B MoE, NVIDIA-native tool/reasoning family.
   - Role: second service only after the Qwen vLLM baseline is stable.
3. Coding specialist candidate: `Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8` or an AWQ/vLLM quant such as `QuantTrio/Qwen3-Coder-30B-A3B-Instruct-AWQ`
   - HF coder search: Qwen3-Coder-30B-A3B-Instruct ~1.9M downloads; FP8 ~990k; AWQ vLLM quant exists.
   - Role: optional coding slot if local code work needs a specialist. Still route high-stakes coding to frontier models.
4. Small coding subagent experiment: `yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF`
   - HF metadata on 2026-06-20: v2 had ~6.3k downloads / 184 likes after one day; v1 had ~312k downloads / 1,983 likes and was #1 trending.
   - Role: manual-only `small_coder` slot via llama.cpp Q4_K_M, useful for cheap coding subagents and terminal-agent experiments.
   - Caveat: community fine-tune with narrow/self-reported agentic coding benchmarks; do not make it the default Hermes brain.
5. Experimental large reasoning model: `nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4`
   - HF search: ~1.5M downloads, 120B/A12B NVFP4.
   - Role: experiment only, one checkpoint at a time, expect memory pressure. Do not make this the default.
6. Cheap/general fallback: `openai/gpt-oss-20b`
   - HF downloads top list: ~6.8M downloads, vLLM + mxfp4 tags.
   - Role: optional small/fast general route if Qwen is too heavy; otherwise skip to keep the machine clean.

## Why not keep the old GGUF stack

The old llama.cpp GGUF services were useful during tuning, but they add operational surface area:

- multiple service files and drop-ins;
- old HF cache entries consuming ~120G;
- risk of accidentally starting old heavyweight checkpoints;
- duplicate routing config now that LiteLLM exists.

Keep the source/build trees if you still use llama.cpp for benchmarking, but remove old model services and cached GGUF checkpoints from the always-on stack.

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
fast_local -> nvidia/Qwen3.6-35B-A3B-NVFP4 via vLLM on :8170
private_local -> same local-only model, no cloud fallback
litellm -> 127.0.0.1:8180 router
```

Add later only if needed:

```text
nemotron_local -> nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4
coder_local -> Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 or AWQ
small_coder -> yuxinlu1/gemma-4-12B-agentic-fable5-composer2.5-v2-3.5x-tau2-GGUF Q4_K_M via llama.cpp on :8190
large_reasoner_experiment -> nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4
cheap_general -> openai/gpt-oss-20b
```

Never enable more than one heavyweight checkpoint at boot.
