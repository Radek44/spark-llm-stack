# Research Plan: Comprehensive LLM Stack Configuration Deep-Dive

## Main Research Question
What are the optimal configurations, quantization strategies, parameter tunings, and gotchas for running llama.cpp, stable-diffusion.cpp, ComfyUI, vLLM, and Hermes on NVIDIA DGX Spark GB10 (Grace Blackwell, aarch64)?

## Subtopics (5 research agents, run in parallel)

### Subtopic 1: llama.cpp / llama-server Configuration
**Scope**: Quantization levels, threading strategies, context optimization, attention mechanisms, optimization flags
- Which quantization levels (q4_K, q5_K, q6_K, f16) impact quality vs speed vs VRAM?
- Optimal `--threads` count for Grace (72 ARM cores, unified memory)?
- Flash attention vs other attention mechanisms on Grace Blackwell?
- Context size tuning, rope scaling parameters, batch processing
- GPU memory optimization flags specific to unified memory
- Performance reports from Grace/Blackwell users

### Subtopic 2: stable-diffusion.cpp (FLUX) Configuration
**Scope**: Weight quantization, schedulers, attention, memory optimization for image generation
- Weight types available (`f32`, `f16`, `q8_0`, `q4_x` etc) and tradeoffs
- `--diffusion-fa` (flash attention) reliability and performance on sm_121a
- Scheduler selection (DDIM, Euler, LMS) and image quality impact
- Guidance scale, VAE tiling, batch inference on unified memory
- Memory optimization flags for Grace unified memory
- Performance comparisons (FLUX vs other diffusion models)

### Subtopic 3: ComfyUI Advanced Configuration
**Scope**: Memory tuning, sampler selection, VAE optimization, node management
- `--reserve-vram` tuning (2.0 vs 4.0 vs 8.0 GB) and impact
- Memory modes (`--lowvram`, `--normalvram`, `--highvram`) effectiveness on unified memory
- Sampler selection and quality/speed tradeoffs
- VAE decode optimization, pinned memory management
- SageAttention v2 vs v3 on sm_121a, any regressions?
- Custom node memory management, ComfyUI-Manager best practices
- Long workflow chain optimization, node execution order impact

### Subtopic 4: vLLM Configuration and Optimization
**Scope**: Quantization, scheduling, memory management, advanced optimization strategies
- Quantization options (AWQ, GPTQ, fp8) and compatibility with GB10
- Scheduling strategies (FCFS, priority-preempt) and latency impact
- Prefix caching, speculative decoding on unified memory
- GPU memory layout, GPU blocks per model size
- Batching strategies and throughput vs latency tradeoffs
- Multi-LoRA serving on Grace
- Early reports of vLLM on Grace Blackwell/DGX Spark

### Subtopic 5: Hermes Setup and Integration
**Scope**: Configuration, routing, parameter passthrough, best practices
- Hermes configuration file structure and options
- Model selection routing logic
- Parameter passthrough for quantization, temperature, top_k per model
- Integration with llama.cpp, vLLM, other backends
- Health checks, load balancing strategies
- Error handling and fallback routing
- Performance optimization for multi-model inference

## Expected Outputs

Each subagent will save findings to:
- `research_config_expansion/findings_[subtopic].md`

Containing:
- Key findings and parameters
- Quantization/quality comparisons where applicable
- Performance characteristics
- Community recommendations
- Source URLs with full citations

## Synthesis Plan

After gathering findings:
1. Update `RESEARCH.md` with detailed config analysis per engine
2. Create `CONFIG_GUIDE.md` with reference tables:
   - Quantization decision matrix (model type × quality target → recommendation)
   - Parameter impact tables (parameter → effect on performance/quality/memory)
   - Optimization checklists per engine
   - Decision trees for common scenarios
3. Flag high-priority config changes for CLAUDE.md or Dockerfiles

## Search Depth
- 4-5 web searches per subtopic (Tavily)
- Focus on recent reports (2024-2026), GitHub discussions, official docs
- Include community blogs, benchmark reports, architecture-specific findings
