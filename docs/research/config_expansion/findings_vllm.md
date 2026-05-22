# vLLM Configuration and Optimization Research

## Quantization Strategies

### Primary Quantization Methods
1. **AWQ (Activation-Aware Quantization)**
   - Per-channel scaling to protect salient weights
   - Better quality preservation than naive quantization
   - Marlin-AWQ backend for optimized performance
   - Performance: 51.8% on HumanEval (matches baseline models on quality)

2. **GPTQ (Gradient-based Post-Training Quantization)**
   - Column-wise quantization using inverse Hessian
   - Good for models requiring extreme quantization
   - Marlin-GPTQ available for optimized inference
   - Recommended for latency-critical applications

3. **FP8 (8-bit Float)**
   - Emerging standard for LLM quantization
   - Two KV-cache variants:
     - **Per-tensor**: Simpler, available with any backend
     - **Per-attention-head**: Higher precision (requires Flash Attention backend + llm-compressor)
   - FP8 KV Cache options:
     - No calibration (`calculate_kv_scales=False`)
     - Random token calibration (`calculate_kv_scales=True`)
     - Dataset calibration (recommended with llm-compressor)
   - Attention operations can run in FP8 domain with Flash Attention 3

### Quantization Decision Matrix
| Method | Quality | Speed | Compression | Best For |
|--------|---------|-------|-------------|----------|
| Baseline (FP16) | 100% | 1.0x | 1.0x | Quality critical |
| AWQ (4-bit) | 98%+ | 2-3x | 4x | Balanced |
| GPTQ (4-bit) | 98%+ | 2-3x | 4x | Latency optimization |
| FP8 | 99%+ | 2x | 2x | Memory constrained |
| Q4_K_M (GGUF) | 99% | 2-3x | 4x | Code generation |

## Advanced Optimization Techniques

### KV Cache Optimization
- **Quantized KV Cache** dramatically reduces memory usage (16% overhead typical)
- **FP8 KV Cache** with Flash Attention 3 backend runs attention in FP8 domain
- **Tensor parallel KV quantization** available for distributed inference
- Recommended: Use dataset-calibrated FP8 KV cache for best results

### Scheduling Strategies
- **FCFS (First Come First Served)**: Simple, fair scheduling
- **Priority-Preempt**: Context-aware, allows interrupting low-priority requests
- Impact on latency and throughput varies per workload

### Advanced Features
- **Prefix Caching**: Reuse common prefixes across requests (reduces computation)
- **Speculative Decoding**: 2-3x speedup without output quality loss
  - EAGLE3 speculative decoding: 71% boost on HumanEval, 94% on Math-500
- **Tensor Parallelism**: Distribute model across multiple GPUs
- **Pipelined Parallelism**: Different optimization for memory-bound operations

## GB10 (Grace Blackwell) Specific

### Current Status
- vLLM not extensively tested on DGX Spark GB10 yet
- CUDA 13.x container support available
- Unified memory support in vLLM

### Expected Optimizations
- PagedAttention: Reduces KV cache memory waste to <4%
- GPU memory layout tuning for unified memory
- FP8 quantization viable for large models
- Speculative decoding for throughput improvement

## vLLM Configuration Examples

### For Inference Server
```
vllm serve model-name \
  --dtype float16 \
  --quantization awq \
  --max-model-len 4096 \
  --tensor-parallel-size 1 \
  --gpu-memory-utilization 0.9
```

### For Quantized KV Cache
```
vllm serve model-name \
  --dtype float16 \
  --quantization awq \
  --kv-cache-dtype fp8 \
  --calculate-kv-scales True
```

## Key References
- vLLM Documentation: Quantized KV Cache guide
- Jarvis Labs: Complete Guide to LLM Quantization with vLLM
- Youngju Dev: The Complete Guide to LLM Inference Optimization
- YouTube: vLLM Office Hours - FP8 Quantization Deep Dive (July 9, 2024)
- Model Quantization for Efficient vLLM Inference (July 25, 2024)

## Recommendations for GB10 Integration
1. **Start with AWQ quantization** for balanced quality/performance
2. **Test FP8 KV Cache** with dataset calibration for memory optimization
3. **Benchmark Speculative Decoding** (EAGLE3) for throughput-critical workloads
4. **Monitor unified memory** behavior under quantization strategies
5. **Pin TensorRT-LLM 1.0+** for stable FP8/NVFP4 support on Grace
6. **Test prefix caching** for common prompt prefixes (system prompts, examples)
7. **Configure tensor-parallelism=1** initially (GB10 is single GPU per slot)

## Future Research
- VLLM_FLASHINFER_MOE_BACKEND=latency for MoE models on GB10
- Multi-LoRA serving configuration
- Custom quantization calibration for GB10-specific workloads
