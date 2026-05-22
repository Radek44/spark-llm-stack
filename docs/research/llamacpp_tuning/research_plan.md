# Research Plan: llama.cpp Tuning for Unified Memory Systems

## Main Research Question

What are the optimal llama.cpp configuration parameters for maximizing throughput and latency on DGX Spark GB10 (unified memory, ARM-based Grace Blackwell GPU)?

## Subtopics to Investigate

### 1. llama.cpp Tuning Parameters: Real Benchmarks
**Focus:** Threading, batch size, context length impact on TTFT and token throughput
- How do thread counts (8, 16, 32, 48) affect performance on GB10?
- What is the ideal batch size and ubatch relationship?
- Context length scaling: performance penalty at 4K, 8K, 16K contexts
- Source: GitHub llama.cpp issues, benchmark reports, community discussions

### 2. Unified Memory Performance Best Practices
**Focus:** Memory layout, cache efficiency, fragmentation reduction specific to unified memory
- How does unified memory affect KV cache efficiency?
- Memory fragmentation on repeated allocation patterns
- Best practices from NVIDIA documentation or community
- Source: NVIDIA Learning Paths, GitHub discussions, developer blogs

### 3. Quantization Impact (Q4/Q5/Q6): Real-World Tradeoffs
**Focus:** Community testing of quality vs speed for Q4_K_M, Q5_K, Q6_K
- Actual benchmark speedups reported in the wild
- Quality degradation metrics (perplexity, task performance)
- Which quantization level is production-safe?
- Source: llama.cpp wiki, community benchmarks, research papers

### 4. Grace Blackwell / ARM Systems: Specific Guidance
**Focus:** Any tuning guidance for Arm-based GPUs or unified memory architectures
- Grace Blackwell-specific performance tuning
- Arm CPU threading models (72 cores)
- Unified memory vs discrete memory tradeoffs
- Source: NVIDIA Grace Performance Tuning Guide, Arm Learning Paths

### 5. llama-server Production Tuning: Real Configs
**Focus:** How are production deployments configured for throughput/latency?
- Real-world thread counts and batch sizes in use
- Context window choices in production
- Load balancing and concurrent request handling
- Source: GitHub discussions, production incident reports, deployment guides

## Expected Information per Subtopic

| Subtopic | Expected Information | Confidence Level |
|----------|----------------------|-----------------|
| Threading benchmarks | Speedup curves for 8→16→32→48 threads | High |
| Unified memory | Fragmentation patterns, best practices | Medium |
| Quantization | Real speedup numbers (Q4=3-4×, Q5=2-2.5×?) | High |
| Grace Blackwell | ARM threading model, unified memory tuning | Medium-Low |
| Production configs | Common thread/batch/context combos in use | High |

## How Results Will Be Synthesized

1. **Validate assumptions** in LLAMACPP_TUNING_PLAN.md against real-world data
2. **Update parameter ranges** if community benchmarks suggest different optimal values
3. **Add production-proven configs** from real deployments
4. **Document tradeoffs** with concrete numbers from community
5. **Prioritize recommendations** based on evidence from multiple sources
6. Create **LLAMACPP_TUNING_RESEARCH.md** with findings + sources

## Research Timeline

- Research phase: 3 subagents in parallel (2 hours)
- Synthesis: 1 hour
- Final update to tuning plan: 1 hour

