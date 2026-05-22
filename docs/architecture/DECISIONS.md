# Architecture decisions

This file captures the non-obvious choices in `spark-llm-stack`. Each
entry says *what* and *why*, citing the evidence. Skip the prose at the
file you're reading; come here when a flag or pattern is non-obvious.

The companion research workspace on the `cr1` branch under `docs/research/`
holds the source material for many of these decisions (RESEARCH.md,
CONFIG_GUIDE.md, the `config_expansion/` and `llamacpp_tuning/` workspaces).
Where this file cites those documents, it means "on `cr1`".

---

## 1. Mutual exclusion between heavyweight slots

Running ≥2 heavyweight services simultaneously exhausts 128 GB unified
memory and triggers a systemd OOM respawn loop that bricks the host.
See `reference-previous/POSTMORTEM.md`. The fix is enforced in two
parallel places:

- **systemd**: `Conflicts=` drop-ins written by `systemd/harden-llm-stack.sh`
- **Docker**: `stop_all_except` runs before every `docker run` in `docker/docker-llm-switch`

Both paths also set `OOMPolicy=stop` / `--rm` so an OOM-killed slot exits
rather than respawning into more pressure. `StartLimitBurst=3` (systemd
only) gives up after 3 failures in 10 minutes.

## 2. The four-place slot mirroring rule

Each slot's config lives in four files; changing one without the others
desyncs the stack:

| File | What lives here |
|---|---|
| `systemd/units/<slot>.service` | Authoritative `ExecStart` arg set |
| `systemd/llm-switch` | `SVCS[]`, `PORTS[]`, `ROLES[]` + `wait_ready` |
| `docker/docker-llm-switch` | `CMD_<slot>[]` + `PORTS`/`ROLES`/`MEMCAP`/`MEMSOFT` |
| `systemd/harden-llm-stack.sh` | `SERVICES=()` with `MemoryHigh/Max` + heavyweight flag |

Not every change touches all four (e.g. threading-only edits touch only
the unit file + `docker-llm-switch`'s CMD array). The README "How
everything wires together" diagram is the source of truth for the
mirroring contract.

## 3. MTP fork of llama.cpp, not mainline

Mainline llama.cpp underperforms the pre-merge MTP branch on GB10
(~23 t/s vs ~28 t/s on Qwen3.6-27B). Service files point at
`%h/src/llama.cpp-mtp/build/bin/llama-server`. The Docker llama image
defaults `LLAMA_REF=master` for reproducibility, with the README and
`CLAUDE.md` instructing users to override via
`--build-arg LLAMA_REF=<mtp-sha>` for full performance.

**Open question**: pin `LLAMA_REF` default to a specific known-good MTP
commit SHA. Research recommends pinning but doesn't name a SHA; needs
hardware validation to pick one.

## 4. Build flag `121a-real` (llama) vs `121` (FLUX)

`-DCMAKE_CUDA_ARCHITECTURES="121a-real"` emits native sm_121a SASS — no
JIT at load time. `121` alone emits generic PTX that the driver
JIT-compiles on first launch (slow first inference, no SASS-level
optimization). `stable-diffusion.cpp` is built with `121` deliberately
because the project isn't GB10-specific and the JIT cost is one-time on
a long-running server.

## 5. Flags that are forbidden by design: `--no-mmap`, `--mlock`

Both pin model weights into anonymous, non-evictable pages. On 128 GB
unified memory this starves co-resident services and removes the kernel's
ability to free pages under pressure. CLAUDE.md flags these as never to
appear in service files. The research surveyed on `cr1` did not propose
adding them; this decision is unchanged.

## 6. ComfyUI: `SAGE_REF=v2.2.0` pin

SageAttention v3 has confirmed mosaic visual artifacts on GB10
(thu-ml/SageAttention#321, referenced by `Triplany/comfyui-dgx-spark`
README). v2.2.0 is the last community-validated stable tag. The default
`ARG SAGE_REF=v2.2.0` in `docker/comfyui/Dockerfile` guards against
upstream moving `main` to v3.

## 7. ComfyUI: `PYTORCH_NO_CUDA_MEMORY_CACHING=1`

PyTorch's caching allocator hoards "freed" GPU pages. On unified memory
those pages are still accessible to Grace CPU and the OS; the caching
allocator fights the UMA fabric. Setting the env var lets the OS reclaim
freed pages cleanly. Compatible with the existing
`PYTORCH_ALLOC_CONF=expandable_segments:True` — they address different
allocator behaviors and run together. Source: SparkyUI and Triplany
projects both set this; CONFIG_GUIDE.md §4 on `cr1`.

## 8. ComfyUI: `--reserve-vram 8.0` (was 2.0)

The original `2.0` was carried over from an older fix for the
ComfyUI#11106 VAE-Decode RAM spike. Subsequent community work
(`Triplany/comfyui-dgx-spark`, tested on DGX Spark 128 GB driver 580.95
across Flux1/2/Qwen2512/Wan2.2/LTX2.3) shows `8.0` runs reliably and
prevents late-iteration allocation failures on heavy workflows.
Important: the VAE-spike fix itself is `--disable-pinned-memory`, which
we keep. `--reserve-vram` is independent headroom for activations, not
the spike mitigation; raising it does not undo the spike fix.

## 9. ComfyUI: `comfy-aimdo` installed

NVIDIA-backed DynamicVRAM allocator. As of v0.3.0 (April 2026) it ships
aarch64 wheels on PyPI — no source build. When importable, ComfyUI
auto-detects it, enables async weight offload (default on Nvidia since
ComfyUI PR #10953), and prevents memory creep across workflow switches.
Logs `aimdo: comfy-aimdo inited for GPU: NVIDIA GB10` on start.

## 10. Llama threading: `--threads 16 --threads-batch 24` (was 8 / 16)

Grace has 10× Cortex-X925 P-cores + 10× Cortex-A725 E-cores = 20 total.
Community DGX Spark work (RedHat H200 ARM study, `Triplany`, NVIDIA
forum threads) lands on 16-20 threads as optimal; `--threads-batch` can
run wider because it's prefill, not decode. The decode/prefill phases
don't overlap in `llama-server`, so 16+24=40 nominal threads share the
20-core pool across phases without contention.

**Why we dropped `--cpu-range` / `--cpu-range-batch`**: the original
config pinned decode to cores 0-9 (X925) and batch to 10-19 (A725) — a
clever split that gave decode the fast cores. At 16/24 threads that
pinning no longer fits (16 threads on 10 cores is over-subscribed; 24 on
10 cores is double-subscribed). Rather than constructing an awkward
overlapping range, we let the kernel scheduler handle it — Linux's
EAS / heterogeneous scheduling on Armv9 already prefers latency-sensitive
work on X925.

This change is unvalidated on hardware. `LLAMACPP_TUNING_PLAN.md` and
`LLAMACPP_BASELINE_RESULTS.md` on `cr1` describe the benchmark
methodology to validate it. Rollback is `git revert`.

## 11. Context window `-c 131072` (was `262144`) — and the now-available `--parallel 2`

Default context window on the heavy slots (coder, architect, gemma)
was lowered from 256K to 128K tokens. gptoss and vision were already
128K. Rationale: real-world usage rarely exceeds 128K, and at 256K
with `q8_0/q8_0` KV one slot consumed ~48 GB just for cache, leaving
no headroom under the 80 G `MemoryMax` cap.

To go back to 256K on a specific slot, edit `-c 131072` in both
`systemd/units/<slot>.service` and the matching `CMD_<slot>` array in
`docker/docker-llm-switch`, then `systemctl --user daemon-reload` (or
rebuild the Docker image). The README "Hardening" section documents
this trade.

**`--parallel 2` is now safe but not enabled.** At 128K the KV footprint
halves to ~24 GB, so `--parallel 2` fits in the 80 G cap. We didn't flip
it because doubling parallel changes user-facing behavior under load
(two concurrent requests share the slot's compute, halving per-request
throughput). Enable it when the use case actually wants concurrent
requests (e.g. multi-client coder slot), not preemptively.

## 12. Why we did NOT adopt the 4n+1 batch-size formula for llama.cpp

The 4n+1 formula (1, 5, 9, 13, 17…) is a legitimate ComfyUI / diffusion
optimization for **image batch sizes** in workflows — it reduces memory
fragmentation on unified memory. The research extrapolated it to
llama.cpp's `-b` (prompt-processing batch size in **tokens**), which is a
misapplication: `-b 9` would mean processing 9 tokens at a time, which
would gut prefill throughput. We keep `-b 32768 -ub 8192` (coder) and
`-b 16384 -ub 4096` (architect/gemma/gptoss). The 4n+1 rule remains
correctly applied in any ComfyUI workflow batch settings.

## 13. Why we did NOT add vLLM as an 8th slot

`CONFIG_GUIDE.md` §5 on `cr1` describes a vLLM container recipe for
GB10. PagedAttention reduces KV fragmentation and AWQ quantization adds
~3.5× throughput on bandwidth-limited GB10. We deferred adoption because
the current llama.cpp slots haven't hit a throughput ceiling that
justifies a parallel inference stack — adding vLLM means another image,
another slot, another set of mirrored configs, and a separate model
roster (AWQ-quantized weights). Revisit if measured per-slot throughput
on the new threading is still the bottleneck. The cr1 recipe is the
starting point.

## 14. Why we did NOT enable TurboQuant `turbo3` KV cache

4.9× KV cache compression unlocks ~536K context on this hardware. But
the research itself flags MTP-branch stability of `turbo3` as unclear
(see `findings_turboquant.md` and `findings_llama_cpp.md` on `cr1`).
At our current `-c 262144` with `q8_0/q8_0` we're not memory-pressured
on the KV cache. Revisit if a use case actually needs >256K context, or
the MTP+turbo3 combo gets community validation.

## 15. GPU clock-lock as an ops step, not a container concern

`nvidia-smi -lgc 3003,3003`, `boost-slider --vboost 1`, and `-pm 1` lock
SM clocks to max and enable persistence mode. These prevent host hard-
crashes from power spikes during heavy work (LTX video gen reported in
the NVIDIA forum thread "Unlocking the Power of the Spark in ComfyUI").
They cannot live in a Docker image or a systemd user unit because they
require root and don't survive reboot — they're a host-level pre-flight
step. Documented in `docker/SMOKE-TESTS.md` §0 and linked from the README
"Before you begin" section.

## 16. Hermes provider alias trap

In `~/.hermes/config.yaml`, the `provider: vllm` alias silently falls
back to OpenRouter when `api:` / `base_url` is non-loopback. The same
config with `provider: custom` does not. For loopback URLs (the default
in `config/hermes-config-snippet.yaml`) it doesn't matter. As soon as a
Tailscale IP or LAN host is involved, use `provider: custom` explicitly
— otherwise Hermes will look like it's working while routing every
request off-box. Source: CONFIG_GUIDE.md §5/§6 on `cr1`.

---

## Deferred / open items

Tracked here because there's no external reminder system — these are the
follow-ups that need user input or hardware access before they can move.

- **`LLAMA_REF` pin to a specific MTP SHA** (decision 3) — needs a
  known-good commit. To produce one, on the Spark host run:
  `cd ~/src/llama.cpp-mtp && git rev-parse HEAD && git log -1 --format='%ci %s'`
  Once nominated, change `docker/Dockerfile`'s `ARG LLAMA_REF=master`
  default to that SHA.
- **Run `LLAMACPP_TUNING_PLAN.md` benchmark on hardware** (decision 10) —
  validates the 16/24 threading change. Plan + result template live on
  `cr1` under `docs/research/`. Needs `llama-bench` + concurrent `curl`
  against `llama-server` on the Spark; no shortcut.
- **Enable `--parallel 2` on a chosen slot** (decision 11) — now
  memory-safe at 128K context; un-gated by a product decision (do you
  want concurrent requests sharing a slot?).
- **Adopt vLLM as an 8th slot** (decision 13) — only if measured
  throughput ceiling actually justifies it.
- **Adopt `docker/autoresearch/` runtime** — lives on `cr1` and is being
  actively edited there. Do not cherry-pick onto this branch until cr1
  is settled.
