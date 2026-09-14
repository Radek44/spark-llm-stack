# Base Qwen serving on DGX Spark

The selected profile serves the unchanged Qwen3.8-27B NVFP4 target with
DFlash2 speculative decoding, full 262,144-token context and CUDA graphs.
Torch compile is disabled: the older permanent launcher failed during compiled
CUDA graph capture. The image is the official SGLang v0.5.19-cu130 ARM64 manifest
`sha256:4cba07b0c68725991890c64843403396effb7faa39ac47261166b2299095c513`.
Target and draft revisions remain pinned in the launcher and unit.

## Measured comparison, 2026-09-14

Each configuration completed the same 18 synthetic requests on the same GB10,
with memory fraction 0.50, DFlash block size 8, maximum four requests, CUDA graph
batch cap 8, autotuning disabled and sleep-on-idle enabled. These are one-pass
measurements, not confidence intervals or a universal fastest-engine claim.

| Configuration | Coding tokens/s | Two-request aggregate tokens/s | Startup seconds | 21,912-token cold/warm TTFT seconds | Minimum MemAvailable GiB |
| --- | ---: | ---: | ---: | --- | ---: |
| Aug22 DFlash2 image, FP32 state / extra_buffer / chunk 8192 | 43.62 | 82.12 | 305.84 | 12.154 / 0.584 | 44.19 |
| Stable v0.5.19, same controls | 43.58 | 81.34 | 310.89 | 12.645 / 0.513 | 43.70 |
| Stable v0.5.19, BF16 state / extra_buffer_lazy / chunk 2048 | 47.33 | 90.39 | 226.03 | 10.361 / 0.499 | 46.57 |

Relative to stable with the old controls, tuning improved observed coding
throughput 8.6%, two-request throughput 11.1%, and startup time 27.3%. The
stable engine upgrade alone was effectively tied. Changes were tested as a
bundle; these numbers do not attribute the gain to one individual option.

All three profiles passed eight of ten strict checks: warmup, six functional
JSON answers and a structured tool call. Both context queries retrieved the
correct value but returned an object or fenced JSON when a JSON string was
requested. Those two format failures remain failures. Each trial completed all
18 responses without pending transport, released its container/CUDA processes
and canonical lock, and restored ComfyUI with an independently verified owner.

The coding samples use a 1,200-token cap and include reasoning that can reach
the cap before delivering code. They measure serving throughput, not playable
games or program correctness. BF16 recurrent state can affect output quality;
this bounded sample does not establish general quality parity. Completion hashes
are diagnostic only. Raw synthetic responses and receipts are retained privately
under `~/.local/state/agentos/qwen-base-optimization-20260914` on Spark.

## Controls

| Environment variable | Default | Accepted values |
| --- | --- | --- |
| `ENABLE_TORCH_COMPILE` | `false` | `true`, `false`; when true, `TORCH_COMPILE_MAX_BS` must be a positive integer |
| `CHUNKED_PREFILL_SIZE` | `2048` | positive integer |
| `MAMBA_SSM_DTYPE` | `bfloat16` | `float32`, `bfloat16` |
| `MAMBA_STRATEGY` | `extra_buffer_lazy` | `extra_buffer`, `extra_buffer_lazy`, `no_buffer` |
| `MAX_RUNNING_REQUESTS` | `4` | positive integer |
| `CUDA_GRAPH_MAX_BS` | `8` | positive integer |
| `DISABLE_FLASHINFER_AUTOTUNE` | `true` | `true`, `false` |
| `SLEEP_ON_IDLE` | `true` | `true`, `false` |

Both compile flags are omitted unless explicitly enabled. CUDA graphs remain
on. Context stays 262,144 and memory fraction stays 0.50. The canonical exclusive
GPU lock and memory floor remain enforced. Broker residency and global rollout
remain off; automatic broker arbitration is not claimed by this change. Its
current one-compute-process registration needs separate review for DFlash2.

The official [Qwen cookbook](https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B)
describes the GB10 DFlash2 options. Local measurements determine the selection.
Long-context and permanent-service release/resume acceptance is recorded below
when completed; the comparison alone does not establish that acceptance.
