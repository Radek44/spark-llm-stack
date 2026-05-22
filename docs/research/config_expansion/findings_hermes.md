# Hermes Configuration and Integration Research

## Hermes Agent Desktop / CLI Configuration

### Setup Overview
- Hermes Agent connects to local LLM inference servers (llama.cpp, vLLM, Ollama)
- Configuration via `config.yaml`
- Supports multiple providers with parameter passthrough
- Integrates with Telegram, scheduled cron jobs, and custom tools

### Provider Configuration

#### Supported Provider Aliases
- `ollama` → Maps to custom endpoint
- `vllm` → Maps to custom endpoint  
- `llamacpp` / `llama-cpp` → Maps to custom endpoint
- `custom` → Direct endpoint specification

#### Critical Bug: Non-loopback URL Fallback
- **Issue**: Provider aliases silently fall through to OpenRouter when base_url is non-loopback
  - Affects LAN IPs (192.168.x.x)
  - Affects WireGuard/remote routed hosts
  - Reported: NousResearch/hermes-agent#27132
- **Workaround**: Use `provider: "custom"` instead of alias
- **Root cause**: `_config_base_url_trustworthy_for_bare_custom()` checks only for "custom" type

#### Correct Configuration Pattern
```yaml
# WRONG (may fall through to OpenRouter)
provider: vllm
base_url: http://192.168.0.103:8000

# CORRECT (trusted for non-loopback)
provider: custom
base_url: http://192.168.0.103:8000
```

## Parameter Passthrough

### Temperature and Sampling Parameters
```yaml
provider: custom
base_url: http://localhost:8080
models:
  - name: gemma-4-31B
    temperature: 1.0
    top_p: 0.95
    top_k: 64
```

### Model-Specific Configuration
- Per-model temperature override
- Sampling parameters (top_p, top_k)
- Seed configuration for deterministic outputs
- Flash attention control (`flash-attn: on/off`)
- Context window (`ctxcp` for context copying in MTP variants)

### Example: llama.cpp Integration
```yaml
providers:
  - name: local
    provider: custom
    base_url: http://localhost:8080
models:
  - name: Gemma 4 E4B Q8
    provider: local
    temperature: 1.0
    top_k: 64
    seed: 3407
    slot: 1  # if using multi-slot setup
```

## Known Integration Issues

### vLLM Integration
- Some users report connection failures despite vLLM accepting connections
- Parameter passthrough may not work with all vLLM versions
- Workaround: Use `provider: custom` with explicit base_url

### LAN/Remote Endpoint Handling
- Must use `provider: custom` for non-loopback addresses
- Provider aliases ignore non-loopback URLs and default to OpenRouter
- Authentication error [HTTP 401] indicates fallback to OpenRouter occurred

## Skill Proposal: Local Model Setup

GitHub: NousResearch/hermes-agent#523 proposes a skill for:
- Guiding users through local model setup
- Recommending models for different use cases
- Configuration templates for Ollama, llama.cpp, vLLM
- Parameter optimization per model type

## Integration Best Practices

### Multi-Model Setup
1. Define base providers (llama.cpp, vLLM instances)
2. Map models to providers with per-model parameter overrides
3. Use `provider: custom` for non-loopback endpoints
4. Set slot numbers if using llama.cpp with multiple slots

### Parameter Optimization
- **Code models**: temperature 1.0, top_k 64 (Gemma 4 defaults)
- **Creative tasks**: temperature 0.7-0.9, top_p 0.95
- **Deterministic**: seed value + lower temperature
- **Long context**: ctxcp flag (for MTP variants)

### Monitoring and Debugging
- Hermes silently falls back to OpenRouter on configuration errors
- Check base_url endpoint directly with curl first
- Monitor for "AuthenticationError [HTTP 401]" in Hermes output
- Use `provider: custom` for non-standard endpoints

## Docker/Containerized LLM Integration

### Hermes with Spark LLM Stack
- Connect Hermes to docker-llm-switch slots via localhost:PORT
- Example: coder slot on port 8000, imagine on 8160, comfyui on 8188
- Parameter passthrough for per-slot tuning

### Network Configuration
- Use `--network=host` for container-to-container connectivity
- Hermes on host can reach Docker containers via localhost:PORT
- If Hermes is containerized, adjust network settings accordingly

## Key References
- GitHub: NousResearch/hermes-agent — Main repository
- GitHub: NousResearch/hermes-agent#27132 — Non-loopback URL bug report
- GitHub: NousResearch/hermes-agent#523 — Local model setup skill proposal
- YouTube: "Hermes Agent Desktop + Local LLM" — Full setup tutorial
- Reddit: r/hermesagent — Community configuration discussions

## Recommendations
1. **Use `provider: custom` by default** for all non-OpenRouter endpoints
2. **Document parameter passthrough** in Spark LLM Stack setup guide
3. **Create Hermes config template** for docker-llm-switch integration:
   - Slot-specific parameter overrides
   - Temperature/sampling per model
   - Context length per slot
4. **Test multi-model routing** via Hermes to different slots
5. **Set up example Telegram gateway** if using Hermes Agent Desktop
6. **Monitor OpenRouter fallback** logs for debugging configuration issues

## Future Integration
- vLLM MoE support with model selection routing
- Multi-slot load balancing in Hermes
- Parameter auto-tuning based on model type
- Integration with spark-llm-stack harden script for resource constraints
