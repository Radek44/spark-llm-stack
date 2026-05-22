# Research Findings: Production llama-server Deployment Tuning

## Real-World Production Configurations

### H200 Production Study (RedHat)
**Stable production configuration**:
```bash
--threads 64 --threads-batch 64
--ngl 99  # all layers to GPU
```

**Key findings**:
- 64 threads for BOTH threads and threads-batch
- Suggests modern high-core-count systems can sustain higher thread counts
- Implies: threads-batch should equal (or be close to) main threads

**Scaling**: High-end production favors aggressive threading over conservative defaults.

---

### Parallel Request Handling

**ClearML Deployment Guidance**:
- **--threads**: CPU threads for main inference
- **--threads-batch**: SEPARATE thread pool for batch processing
- **--parallel N**: Number of request slots (concurrent requests)
- **Max Concurrent Requests**: Hard limit to prevent queue buildup

**Design pattern**:
```
Total threads ≈ --threads + --threads-batch (rough estimate)
--parallel = number of concurrent requests
```

---

## Production Deployment Strategies

### Docker + Compose for Production
- **Reason**: Simplified multi-service management
- **Advantage**: Declarative configuration, easy scaling
- **Pattern**: One container per slot, use compose for orchestration
- **Network**: Use `--network=host` for bare-metal performance (similar to GB10 systemd setup)

### OpenAI-Compatible API Requirement
- **Finding**: Production deployments expect OpenAI-compatible API
- **llama-server**: Provides `/v1/completions`, `/v1/chat/completions` endpoints
- **Implication**: Hermes and other clients can route via standard OpenAI protocol

---

## Concurrency and Request Handling

### Sequential vs Concurrent Batching
**Finding** (from CPU-only studies): **Sequential batching can outperform concurrent batching** on bandwidth-limited systems.

- **Sequential**: Handle requests one-by-one (traditional)
- **Concurrent**: Handle multiple requests in parallel batch
- **Result**: On memory-bandwidth-limited systems, sequential avoids memory contention

**Implication for GB10**:
- With only 273 GB/s bandwidth vs 3.3 TB/s on traditional GPU
- Consider testing lower `--parallel` values (1-2 instead of 4+)
- Measure throughput vs latency for your workload

### Request Queuing and SLA Tuning
**Production pattern**:
- Set `--parallel` to max expected concurrent requests
- Use `--timeout N` to reject long-queued requests
- Monitor SLA: p50, p95, p99 latency per endpoint

---

## Deployment Pitfalls and Solutions

### Problem 1: Thread Oversubscription
**Symptom**: Many threads configured, but latency increases
**Solution**: Reduce threads to physical core count, test incrementally
**GB10 guidance**: Start at 16, test up to 20

### Problem 2: OOM on Concurrent Requests
**Symptom**: Single request works, batch fails
**Solution**: Lower `--parallel`, use KV cache quantization
**GB10 specific**: Use `--cache-type-k q8 --cache-type-v q8`

### Problem 3: Poor Throughput on llama-server
**Symptom**: Token rate is 50% of llama-bench
**Solution**: 
- Increase batch size (`--batch`)
- Increase threads-batch
- Check GPU utilization (should be >80%)
- Verify no other services contending for GPU

### Problem 4: TTFT (Time to First Token) Too High
**Symptom**: First token takes 200+ ms
**Solution**:
- Reduce `--parallel` (less queuing)
- Reduce context length (less prefill compute)
- Increase threads-batch (faster batch processing)

---

## llama-server Command Reference (Production)

```bash
llama-server \
  -m /path/to/model.gguf \
  -c 8192 \
  -b 9 \
  -ub 32 \
  --threads 16 \
  --threads-batch 32 \
  --threads-http 8 \
  --parallel 2 \
  -ngl 99 \
  --cache-type-k q8 \
  --cache-type-v q8 \
  --port 8000 \
  --host 0.0.0.0
```

**Explanation**:
- `-m`: Model path
- `-c 8192`: Max context
- `-b 9 -ub 32`: Batch/unbatch (4n+1 formula)
- `--threads 16`: Main thread pool
- `--threads-batch 32`: Batch processing threads (test tuning)
- `--threads-http 8`: HTTP server threads (separate, keep low)
- `--parallel 2`: Max concurrent requests (conservative for GB10)
- `-ngl 99`: Offload all layers
- `--cache-type-*`: Quantized KV (memory optimization)
- `--port 8000 --host 0.0.0.0`: Listen on all interfaces

---

## Performance Monitoring in Production

### Key Metrics to Track
```bash
# Monitor request latency
curl -X POST http://localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"llama","prompt":"test","max_tokens":100}' \
  | jq '.usage'

# llama-server logs provide:
# - prompt eval time (prefill latency)
# - eval time (decode latency)
# - sample time (token sampling)
```

### System-Level Monitoring
```bash
# GPU utilization
nvidia-smi dmon -s puctem

# Memory fragmentation (watch allocated/freed)
nvidia-smi -l 1 -q -d MEMORY

# Thread utilization
ps -p $(pgrep llama-server) -O %cpu,%mem,cmd
```

---

## Recommendations for GB10 Production

1. **Start conservative**:
   ```bash
   --threads 16 --threads-batch 16 --parallel 2
   ```

2. **Monitor under load**:
   - Send 10 concurrent requests
   - Measure TTFT, token/s, memory usage
   - Watch for OOM or latency spikes

3. **Tune incrementally**:
   - Increase `--parallel` to 4, re-test
   - Increase `--threads-batch` to 24, re-test
   - Measure point where p95 latency exceeds SLA

4. **Use quantized KV cache**:
   ```bash
   --cache-type-k q8 --cache-type-v q8
   ```
   (Non-negotiable on GB10 for memory efficiency)

5. **Document final config**:
   - Record system specs, load profile, latency/throughput results
   - Use as baseline for future model upgrades

---

**Sources**:
- RedHat: "vLLM or llama.cpp: Choosing the right LLM inference engine" (2025)
- ClearML: Llama.cpp Model Deployment guide
- ServiceStack: llama-server deployment guide
- Debian manpages: llama-server(1)
- Meta Llama: Self-hosted deployment for regulated industries
