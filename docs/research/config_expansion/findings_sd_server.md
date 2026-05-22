# stable-diffusion.cpp (FLUX) Configuration Research

## Current Status
- **FLUX.2-klein** officially supported as of 2026-01-18
- **FLUX.2-dev** supported as of 2025-11-30
- Lightweight C/C++ implementation designed for efficiency

## Weight Quantization Types Available
- **Q3** (3-bit)
- **Q8** (8-bit)
- **F32** (full precision)
- **F16** (half precision)
- Currently set to: **F16** in docker/sd-server/Dockerfile

### Known Issues with Quantization
- Type detection bug: When using quantized T5-XXL and CLIP, model type shows as F16 when it's quantized
  - Reported on: leejet/stable-diffusion.cpp#374
  - Impact: Can cause Termux to crash due to type mismatch
  - Status: Type detection needs fix in sd.cpp

## Current Configuration (spark-llm-stack)
- `--type f16` — reasonable middle ground between quality and speed
- `--diffusion-fa` — flash attention enabled (recommended for sm_121a)
- `--threads 8` — conservative (Grace has 72 cores)
- Default quantization: F16 (not on-disk quantization)

## Optimization Opportunities
1. **Weight quantization options**:
   - F16: Current choice, good quality
   - Q8: Possible for faster inference, need quality testing
   - Q3: Maximum compression, test for acceptable quality

2. **Scheduler selection** — Common options:
   - DDIM: Faster but lower quality
   - Euler: Balanced quality/speed
   - LMS (Linear Multistep): Higher quality, slower

3. **Threading**: `--threads 8` could be increased to utilize more Grace cores

4. **VAE Tiling**: Consider adding VAE tiling options for large batch processing

## Performance Notes
- sd.cpp uses CMAKE_CUDA_ARCHITECTURES=121 (generic PTX, intentional per CLAUDE.md)
- Not SASS-tuned for sm_121a (unlike ComfyUI's SageAttention)
- Trade-off: Generic PTX compatibility vs sm_121a-specific optimization

## Key References
- GitHub: leejet/stable-diffusion.cpp — Official repository
- Official README includes performance guide for optimization recommendations
- Python bindings available via PyPI for integration

## Recommendations
1. Test Q8 quantization for speed vs quality tradeoff
2. Test increased `--threads` value (16-32) on GB10
3. Implement scheduler selection parameter (add to `--scheduler` if not present)
4. Monitor type detection for quantized models in sd.cpp updates
5. Consider VAE tiling parameter for batch inference
