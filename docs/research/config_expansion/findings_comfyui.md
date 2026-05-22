# ComfyUI Advanced Configuration Research

## Memory Management

### Dynamic VRAM Allocation (NEW in ComfyUI)
- Major memory optimization now enabled by default
- Allows workflows to request memory dynamically
- Issue: `--reserve-vram` interacts with dynamic VRAM in unexpected ways
- When dynamic VRAM is enabled, `--reserve-vram` may not work as expected
- Symptom: Workflows consuming all available VRAM even with reserve-vram set

### Reserve VRAM Tuning
- Current setting: `--reserve-vram 2.0`
- Community reports: Reserve VRAM doesn't consistently work with dynamic VRAM enabled
- Alternative: May need `--disable-dynamic-vram` flag when using explicit reserve
- Observation: LTX 2 model uses all 24GB VRAM regardless of reserve-vram setting

### VAE Decode RAM Spike
- Known issue: VAE Decode significantly increases memory bus interface load
- Mitigation: `--disable-pinned-memory` (currently implemented)
- Result: Reduces unified memory pressure during VAE operations
- Alternative: Manual VAE tiling options

## Parameter Tuning

### Low VRAM GPU Strategies
- Memory optimization tricks documented in YouTube guide: "Memory Tricks in Comfyui for Low VRAM GPUs"
- Batch size formula: critical formula is 4n+1 for optimization
- Production optimization tips available but require testing

### Sampler and Model Parameters
- Scheduler selection impacts quality and speed
- Batch size optimization is critical (4n+1 formula)
- SageAttention version selection (v2 vs v3)
- Model-specific tuning per architecture

## SageAttention on GB10 (sm_121a)

### Current Status
- SageAttention v2.x confirmed working on sm_121a
- Native SASS compilation: `-gencode=arch=compute_121a,code=sm_121a`
- v3 release exists but no GB10-specific testing reported yet

### Potential Issues
- SageAttention main branch may have breaking changes
- Version pins recommended (SAGE_REF in Dockerfile)
- v2.2.0 stable, v3 untested on sm_121a

## Integration with Quantization

### Combined Optimization
- FP16 models + SageAttention + optimized memory settings
- E4B (fp8) quantization possible with correct VRAM configuration
- Quality/speed tradeoff: FP16 > E4B > lower quantizations

## Batch Processing Configuration

### Production Tips
- Batch size formula: 4n+1 (critical for optimization)
- Memory efficiency improves with correct batch sizing
- Node memory management: custom nodes can cause unexpected allocation patterns

## References
- GitHub: Comfy-Org/ComfyUI#12699 — Dynamic VRAM discussion
- Reddit: r/comfyui — Dynamic VRAM optimization reports
- YouTube: "Memory Tricks in Comfyui for Low VRAM GPUs"
- Comfy.ICU: Memory optimization strategies and batch_size formula
- ComfyUI-SeedVR2 extension: Advanced memory optimization for different VRAM levels

## Recommendations
1. **Test `--disable-dynamic-vram`** when using explicit `--reserve-vram`
2. **Increase reserve-vram from 2.0 to 4.0-8.0 GB** (test community recommendation)
3. **Batch size optimization**: Document 4n+1 formula in workflow guidelines
4. **Pin SageAttention to v2.2.0** instead of main (avoid potential v3 regressions)
5. **Add batch_size parameter** to documented workflow optimization
6. **Monitor VAE decode** memory spikes with profiling on GB10
7. **Consider comfy-aimdo extension** (>=0.3.0) for dynamic VRAM management
