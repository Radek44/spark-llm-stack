# spark-llm-stack

Local LLM inference stack for **NVIDIA DGX Spark (GB10 Grace Blackwell)**.
Two deployment paths over the same model roster — systemd user-services
(primary) and Docker containers (mirror) — bound by a shared hardening
contract that prevents the 128 GB unified-memory OOM brick-loop documented
in [POSTMORTEM.md](reference-previous/POSTMORTEM.md).

## Repo structure

```
spark-llm-stack/
├── README.md                    ← you are here
├── CLAUDE.md                    contributor / agent guide
│
│
├── systemd/                     PRIMARY path: user-services on the host
│   ├── units/                     one .service per model slot (authoritative ExecStart)
│   │   ├── qwen27-mtp.service     coder       :8152
│   │   ├── qwen35-mtp.service     architect   :8154
│   │   ├── gemma-vision.service   vision      :8155
│   │   ├── gemma-31b.service      gemma       :8156
│   │   ├── gptoss-20b.service     gptoss      :8157
│   │   └── flux-klein.service     imagine     :8160 (sd-server / FLUX.2-klein)
│   ├── llm-switch                runtime slot manager (stop others, start one, wait_ready)
│   └── harden-llm-stack.sh       generates drop-ins: MemoryMax, OOMPolicy=stop,
│                                 Conflicts=, StartLimitBurst=3 — this is the
│                                 contract POSTMORTEM mandates
│
├── docker/                      MIRROR path: same slots, in containers
│   ├── Dockerfile                llama.cpp image (coder/architect/gemma/vision/gptoss)
│   ├── sd-server/Dockerfile      stable-diffusion.cpp image for imagine (FLUX.2-klein)
│   ├── comfyui/
│   │   ├── Dockerfile            ComfyUI image (PyTorch cu130 + SageAttention sm_121a)
│   │   └── entrypoint.sh         seeds ComfyUI-Manager into the bind-mounted custom_nodes
│   ├── docker-compose.yml        declarative build for all three images
│   ├── docker-llm-switch         Docker analogue of systemd llm-switch
│   │                             (stop_all_except → Conflicts=,
│   │                              --rm → OOMPolicy=stop,
│   │                              --oom-score-adj=200 → OOMScoreAdjust=200,
│   │                              --restart unless-stopped → boot-default,
│   │                              IMAGE[<slot>] picks llama / sd-server / comfyui)
│   └── run.sh                    thin wrapper: delegates to docker-llm-switch
│   └── autoresearch/             launcher path: upstream autoresearch repos in isolated containers
│      ├── README.md                quickstart + profile graph + source attribution
│      ├── docker-compose.autoresearch.yml
│      ├── Dockerfile.base
│      ├── scripts/autoresearch-switch
│      └── SMOKE-TESTS.md
│
├── tools/
│   └── flux-gen                 CLI for the FLUX.2-klein async image API
│                                (bundled inside the Docker image too)
│
├── config/
│   └── hermes-config-snippet.yaml   provider stanzas for the Hermes harness
│
└── reference-previous/          archival material — read for context, not for execution
    ├── POSTMORTEM.md            the OOM brick-loop incident; why the hardening exists
    └── drop-ins/                snapshot of what harden-llm-stack.sh writes
                                 to ~/.config/systemd/user/<unit>.d/override.conf
                                 (live files — this is just a reference copy)
```

## Autoresearch launcher

For upstream autoresearch-style projects (without code folding), use:

- [docker/autoresearch/README.md](docker/autoresearch/README.md)
- [docker/autoresearch/SMOKE-TESTS.md](docker/autoresearch/SMOKE-TESTS.md)

Core command:

```bash
./docker/autoresearch/scripts/autoresearch-switch start karpathy
```

## Cross-stack memory failsafe (REQUIRED on the DGX host)

Docker `--memory` and cgroup `memory.max` do **not** enforce caps on CUDA
allocations on GB10 — confirmed in NVIDIA forums [#264689][f264689],
[#353752][f353752], and [#358951][f358951] (NVIDIA staff explicitly recommend
earlyoom as the mitigation). The repo therefore ships a three-layer userspace
failsafe that works regardless of cgroup behaviour:

1. **Admission gate** — `docker/lib/spark-mem.sh`, sourced by both switches.
   Acquires a shared `flock`, checks `MemAvailable`, and (if a new workload's
   cap would exceed the headroom) force-stops cross-stack containers before
   launch. Switches now stamp every exclusive container with
   `label spark.exclusive=true` so the enumeration works across both stacks.
2. **Runtime watchdog** — `systemd/units/spark-earlyoom.service`. earlyoom
   polls `/proc/meminfo`, fires SIGTERM at MemAvailable < 8 % and SIGKILL at
   < 4 %, and runs `/usr/local/bin/spark-panic` *before* SIGKILL via the
   `-N` hook — so containers stop gracefully instead of leaving zombie CUDA
   contexts.
3. **Panic / recovery** — `tools/spark-panic`, also reachable as
   `docker-llm-switch panic` and `autoresearch-switch panic`. Stops every
   container with the exclusive label across both stacks, clears restart
   policies, and drops the page cache.

Install:

```bash
sudo apt-get install -y earlyoom
sudo cp docker/lib/spark-mem.sh    /usr/local/lib/spark-mem.sh
sudo cp tools/spark-panic          /usr/local/bin/spark-panic
sudo chmod +x /usr/local/bin/spark-panic
sudo cp systemd/units/spark-earlyoom.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now spark-earlyoom.service
```

`spark_drop_caches` uses `sudo -n` (non-interactive) so the admission gate
never blocks on a password prompt under SSH-without-TTY or cron. Grant
NOPASSWD for the single command by adding this line via `sudo visudo`:

```
<your-operator-user> ALL=(root) NOPASSWD: /bin/sh -c sync; echo 3 > /proc/sys/vm/drop_caches
```

Without it, the failsafe still works — `drop_caches` just becomes a no-op
and the admission gate runs against unflushed memory (visible in
`journalctl` as `drop_caches failed (sudo -n required; configure NOPASSWD)`).

Verify:

```bash
systemctl status spark-earlyoom        # active (running)
docker-llm-switch panic                # idempotent
spark-panic                            # same, manual route
```

Full design and citations: [`docs/research/autoresearch/findings_failsafe_design.md`](docs/research/autoresearch/findings_failsafe_design.md).

[f264689]: https://forums.developer.nvidia.com/t/cuda-unified-memory-usage-is-not-accounted-by-linux-cgroup/264689
[f353752]: https://forums.developer.nvidia.com/t/dgx-spark-becomes-unresponsive-zombie-instead-of-throwing-cuda-oom/353752
[f358951]: https://forums.developer.nvidia.com/t/spark-hangs-requires-a-hard-reset-physically-unplugging/358951

## How everything wires together

```
                      ┌───────────────────────────────────────────┐
                      │  Authoritative arg set lives in:          │
                      │    systemd/units/<slot>.service ExecStart │
                      └───────────────────────────────────────────┘
                            │                            │
                  mirror    │                            │  mirror
                  (live)    ▼                            ▼  (in image)
       ┌────────────────────────────┐      ┌────────────────────────────────┐
       │ systemd/llm-switch         │      │ docker/docker-llm-switch       │
       │  SVCS[], PORTS[], ROLES[]  │      │  CMD_<slot>[] arrays mirror    │
       │  wait_ready /health        │      │  ExecStart + --host 0.0.0.0    │
       └─────────────┬──────────────┘      └────────────────┬───────────────┘
                     │                                      │
            starts/stops                            starts/stops
            ~/.config/systemd/                      spark-llm-<slot>
            user/<slot>.service                     containers
                     │                                      │
                     ▼                                      ▼
       ┌────────────────────────────┐      ┌────────────────────────────────┐
       │ llama-server (MTP build)   │      │ llama-server (in container)    │
       │ listens on :<slot port>    │      │ --network=host, same :port     │
       └────────────────────────────┘      └────────────────────────────────┘
                     ▲                                      ▲
                     └───────── shared hardening ───────────┘
                                       │
                  ┌────────────────────┴────────────────────┐
                  │ systemd/harden-llm-stack.sh writes:     │
                  │   MemoryMax, OOMPolicy=stop,            │
                  │   OOMScoreAdjust=200, Conflicts=,       │
                  │   StartLimitBurst=3                     │
                  │                                         │
                  │ Docker path replays the same intent:    │
                  │   --memory, --rm, --oom-score-adj=200,  │
                  │   stop_all_except, (no daemon analogue  │
                  │   to StartLimitBurst — single-slot OOM  │
                  │   loop is recoverable, multi-slot is    │
                  │   prevented by stop_all_except)         │
                  └─────────────────────────────────────────┘

  Clients (Hermes, Claude Code, curl, flux-gen)
       │
       │  HTTP over tailscale0 / loopback to :8152/:8154/:8155/:8156/:8157/:8160
       ▼
  whichever slot is currently up
```

### Adding or changing a slot (the four-place rule)
A slot lives in four files that must stay in sync. Change one, change all:

| File | What to update |
|---|---|
| `systemd/units/<slot>.service` | `ExecStart` — authoritative arg set |
| `systemd/llm-switch` | `SVCS[]`, `PORTS[]`, `ROLES[]` + wait_ready entry |
| `docker/docker-llm-switch` | `CMD_<slot>[]` + `PORTS`/`ROLES`/`MEMCAP`/`MEMSOFT` |
| `systemd/harden-llm-stack.sh` | `SERVICES=()` entry with `MemoryHigh/Max` and heavyweight flag |

### What lives where, at runtime

| Concern | Systemd path | Docker path |
|---|---|---|
| Mutual exclusion | `Conflicts=` (drop-in) | `stop_all_except` (function) |
| Memory cap | `MemoryMax=80G` (drop-in) | `--memory=80g --memory-swap=80g` |
| OOM = halt, not respawn | `OOMPolicy=stop` (drop-in) | `--rm` (runtime mode) |
| OOM victim selection | `OOMScoreAdjust=200` | `--oom-score-adj=200` |
| Boot-time auto-start | `systemctl --user enable <slot>` | `--restart unless-stopped` |
| Respawn burst limit | `StartLimitBurst=3` | (none; relies on mutual exclusion) |
| `imagine` slot | `flux-klein.service` (sd-server) | `spark-llm-imagine` (from `docker/sd-server/Dockerfile`) |
| `comfyui` slot | `comfyui.service` (host install) | `spark-llm-comfyui` (from `docker/comfyui/Dockerfile`) |

---

## Docker quickstart

### Before you begin (read this — it'll save you a brick)

- **Hardware**: NVIDIA DGX Spark GB10 (Grace Blackwell, aarch64, SM 12.1).
  The cmake flag `121a-real` and the env vars `CUDA_SCALE_LAUNCH_QUEUES=4x`
  / `GGML_CUDA_GRAPH_OPT=1` only apply on this chip. Other CUDA cards will
  build but won't get the tuned SASS path.
- **Driver**: NVIDIA driver 580 or newer, CUDA 13.0+.
- **Docker**: with the NVIDIA Container Toolkit installed and tested
  (`docker run --rm --gpus=all nvidia/cuda:13.2.0-base-ubuntu24.04
  nvidia-smi`).
- **Disk**: ~20 GB for the image, plus model weights (≈80 GB across the
  full roster — Qwen3.6-27B alone is ~17 GB).
- **Models directory**: create `~/models/` and put your GGUFs there. The
  container bind-mounts it at `/models`. To download weights inside the
  container, export `HUGGING_FACE_HUB_TOKEN` first.
- **Network**: containers run `--network=host`. Slots bind to `0.0.0.0`
  on `:8152` / `:8154` / `:8155` / `:8156` / `:8157` / `:8160` — accessible
  over Tailscale on the host's `tailscale0` IP. Make sure nothing else
  on the host is squatting those ports.
- **Single-slot rule** (the one that bricks the box if ignored):
  Running more than one heavyweight slot at a time exhausts 128 GB
  unified memory and triggers an OOM respawn loop documented in
  [POSTMORTEM.md](reference-previous/POSTMORTEM.md). `docker-llm-switch` enforces this by
  stopping every other `spark-llm-*` container before starting a new one
  — so use `./docker/run.sh <slot>` or `docker-llm-switch <slot>`, never
  raw `docker run`.
- **Build time**: ~25–40 min on GB10 with `BUILD_JOBS=16`. The default
  `LLAMA_REF=master` ships mainline llama.cpp (~23 t/s on Qwen3.6-27B).
  For full perf (~28 t/s), build with `--build-arg LLAMA_REF=<mtp-sha>`
  pointing at the pre-merge MTP branch the systemd `*.service` files use.
- **FLUX (imagine) and ComfyUI** are in the Docker path as separate
  images, built from `docker/sd-server/` and `docker/comfyui/`. Both share
  the same `--network=host` + bind-mounted-models pattern as the llama
  slots. ComfyUI additionally bind-mounts `~/comfyui/{custom_nodes,output,user}`
  so anything you install via the Manager web UI persists across rebuilds.
- **ComfyUI OOM warning**: ComfyUI on Blackwell unified memory has a
  known issue (Comfy-Org/ComfyUI#11106) where chaining VAE Decode with
  Depth nodes can spike past 128 GB in seconds. The image already passes
  `--disable-pinned-memory` and `--reserve-vram 2.0` to mitigate; if you
  still hit it, batch in smaller tiles and avoid forcing `--gpu-only`.

### Commands

Run these from the repo root.

```bash
# 1. Build all three images (llama / sd-server / comfyui). Build context
#    is the repo root so tools/flux-gen is reachable for the llama image.
#    Override LLAMA_REF / COMFYUI_REF / SD_REF via --build-arg to pin.
docker compose -f docker/docker-compose.yml build
# (or build a single image: `docker compose -f docker/docker-compose.yml build comfyui`)

# 2. Install the container manager on PATH (one-time).
cp docker/docker-llm-switch ~/.local/bin/
chmod +x ~/.local/bin/docker-llm-switch

# 3. Start a slot (stops every other spark-llm-* container first).
./docker/run.sh                  # coder slot (Qwen3.6-27B, :8152)
./docker/run.sh architect        # architect slot (Qwen3.6-35B, :8154)
./docker/run.sh gemma            # gemma 31B, :8156
./docker/run.sh vision           # gemma vision, :8155
./docker/run.sh gptoss           # gpt-oss-20B, :8157
./docker/run.sh imagine          # FLUX.2-klein via sd-server, :8160
./docker/run.sh comfyui          # ComfyUI on :8188

# 4. Manage state
docker-llm-switch status         # what's running, ports, restart policy
docker-llm-switch off            # stop everything

# 5. Auto-start a slot on Docker daemon reboot
docker-llm-switch boot-default architect   # only one slot ever has a policy
docker-llm-switch boot-status              # show what'll start at daemon boot
docker-llm-switch boot-safe                # clear all restart policies
```

### Custom nodes for ComfyUI

The container's `/opt/ComfyUI/custom_nodes/` is a bind mount of
`~/comfyui/custom_nodes/` on the host. The image seeds ComfyUI-Manager
into that directory on first run (no-clobber, so anything you've added
is preserved across restarts and image rebuilds). Install new nodes
through the Manager web UI or by `git clone`-ing into
`~/comfyui/custom_nodes/` directly — restart the container to pick them
up. Workflows / settings live in `~/comfyui/user/`, generated images in
`~/comfyui/output/`.

### Verifying a build before you trust it

CI runs Dockerfile lint + a Scout base-image CVE scan, but it has no
GPU and cannot exercise the actual binaries. See
[`docker/SMOKE-TESTS.md`](docker/SMOKE-TESTS.md) for the manual checklist
that has to pass on a real GB10 host before changes under `docker/` are
considered shippable (build, bad-ref regression, mutual exclusion,
Tailscale reachability, hardening parity, end-to-end FLUX gen, custom-
node persistence, daemon-restart survival).

First-time HF download example (one-off, fills `~/models/`):

```bash
docker run --rm --gpus=all --network=host \
  --memory=80g --memory-swap=80g \
  --oom-score-adj=200 --ulimit memlock=-1:-1 --shm-size=1g \
  -v ~/models:/models \
  -e HUGGING_FACE_HUB_TOKEN="$HUGGING_FACE_HUB_TOKEN" \
  spark-llm-stack \
  -hf unsloth/Qwen3.6-27B-MTP-GGUF:UD-Q4_K_XL \
  --alias qwen3.6-27b-coder --host 0.0.0.0 --port 8152
```

---

## Docker container — what came from where

The `docker/Dockerfile`, `docker/run.sh`, and `docker/docker-llm-switch` were built by synthesising three sources:

### From [eugr/spark-vllm-docker](https://github.com/eugr/spark-vllm-docker)
A vLLM container for the same GB10 hardware that confirmed the right approach before a line was written:
- **Base image**: `nvidia/cuda:13.2.0-devel-ubuntu24.04` — verified by that repo to work on GB10 aarch64; used verbatim.
- **Multi-stage build** (builder → runtime) — keeps the final image free of cmake, git, and CUDA headers.
- **`ARG BUILD_JOBS=16`** with `ENV MAX_JOBS=${BUILD_JOBS}` — parallelism override pattern adopted as-is.
- **Ninja generator** (`-G Ninja`) — that repo builds all its C++ with Ninja; used here for the llama.cpp build.

That repo does not use Tailscale — it relies on InfiniBand/RoCE for multi-node links. This confirmed that host networking (`--network=host`) is the right and sufficient approach for single-node Tailscale access.

### From this repo's own `.service` files and [`POSTMORTEM.md`](reference-previous/POSTMORTEM.md)
Every llama.cpp flag, env var, and memory limit came from what was already here:
- **GB10 cmake flags** (`121a-real`, `GGML_CPU_KLEIDIAI`, `GGML_CUDA_FA_ALL_QUANTS`, `GGML_CUDA_FORCE_MMQ`) — copied verbatim from the README build section.
- **`CMD` args** in the Dockerfile and `docker-llm-switch` slot tables — translated line-for-line from the `ExecStart` blocks in each `.service` file (`qwen27-mtp.service`, `qwen35-mtp.service`, `gemma-31b.service`, `gemma-vision.service`, `gptoss-20b.service`).
- **CUDA env vars** (`CUDA_SCALE_LAUNCH_QUEUES=4x`, `GGML_CUDA_GRAPH_OPT=1`, `GGML_CUDA_FORCE_CUBLAS_COMPUTE_16F=1`) — lifted from the `Environment=` lines in every service unit.
- **Memory caps** — `docker-llm-switch`'s `MEMCAP` and `MEMSOFT` tables map directly to the `MemoryMax` and `MemoryHigh` drop-in values from the POSTMORTEM hardening table. `--rm` (runtime) gives `OOMPolicy=stop` semantics; `--oom-score-adj=200` mirrors `OOMScoreAdjust=200`; `--restart unless-stopped` (boot-default) is the Docker analogue of `WantedBy=default.target`; `stop_all_except` replaces `Conflicts=`.
- **`--host 0.0.0.0`** (not `127.0.0.1`) — the one deliberate delta from the service files, needed so traffic arriving on the host's `tailscale0` interface reaches the server.

## ComfyUI + FLUX containers — what came from where

`docker/comfyui/` and `docker/sd-server/` were synthesised from this repo's own systemd units (the `ExecStart` for `flux-klein.service` is the authoritative source for the sd-server CMD), plus the following community work on Blackwell aarch64 — none of their images are pulled directly, but their configuration choices are the reason the build works on first try.

### From [AEON-7/comfyui-aeon-spark](https://github.com/AEON-7/comfyui-aeon-spark)
The most concrete reference for Blackwell-specific tuning:
- **`TORCH_CUDA_ARCH_LIST=12.1a`** — emit sm_121a SASS specifically, not generic Blackwell PTX. Adopted in `docker/comfyui/Dockerfile`.
- **SageAttention compile flags** (`-gencode=arch=compute_121a,code=sm_121a` via `NVCC_APPEND_FLAGS`) — the only working fast-attention path on GB10; FlashAttention 2/3 has no aarch64 sm_121 wheels. Used verbatim in the SageAttention build step.
- **`TORCH_COMPILE_DISABLE=1`** — torch.compile emits broken SASS for sm_121a on PyTorch 2.9.x. Set as ENV in both build and runtime stages.
- **`CUDA_MANAGED_FORCE_DEVICE_ALLOC=1` + `PYTORCH_ALLOC_CONF=expandable_segments:True`** — Grace unified-memory tuning; lifted from their docker-compose env block.
- **`--disable-pinned-memory --reserve-vram 2.0`** ComfyUI CLI flags — community-confirmed workaround for the Grace coherence issues. Applied as the default CMD.

### From [luix93/DGX-Spark-ComfyUI](https://github.com/luix93/DGX-Spark-ComfyUI)
- **`/opt/venv` virtualenv pattern** — copy a fully-resolved venv from the builder stage rather than running pip in the runtime stage. Cleaner final image; adopted.
- **PyTorch source**: official cu130 wheels from `https://download.pytorch.org/whl/cu130`, NOT NGC wheels (NGC lags in sm_121a PTX). Locked to `torch==2.9.1+cu130` in `docker/comfyui/Dockerfile`.

### From [mmartial/ComfyUI-Nvidia-Docker](https://github.com/mmartial/ComfyUI-Nvidia-Docker)
- **ComfyUI-Manager auto-bootstrap pattern** — bake a default copy of ComfyUI-Manager into the image at a path *outside* the bind-mount target (`/opt/comfy-defaults/`), seeded into `/opt/ComfyUI/custom_nodes/` on first run via a small entrypoint script. Without this, a bind-mounted empty host directory shadows the in-image ComfyUI-Manager and the user has to install it by hand. See `docker/comfyui/entrypoint.sh`.
- **`HF_HUB_ENABLE_HF_TRANSFER=1`** — faster model downloads when grabbing weights from inside the container.

### From the NVIDIA Developer forums + [comfyanonymous/ComfyUI#11106](https://github.com/comfyanonymous/ComfyUI/issues/11106)
- **Documented mitigations** for the Grace unified-memory VAE-Decode spike (chained VAE Decode + Depth can spike past 128 GB in seconds). Our defaults match the community workaround; the README "Before you begin" section flags the issue so the user has a pointer when they hit it.
- **CUDA 13.x is mandatory** for sm_121 support; CUDA 12.x maxes out at sm_120 and won't work. Already baked in via the existing `nvidia/cuda:13.2.0` base image.

### What we deliberately did NOT take

- **Pre-bundled custom-node packs** (AEON-7 ships 14 node repos; luix93 ships several) — we ship only ComfyUI-Manager and let the user install what they actually need via the web UI. Image stays smaller, no version-lock surprises.
- **Pre-staged model weights** (AEON-7 ships ~285 GB of FLUX/SDXL/LoRA bundles) — models live on the host at `~/models/`, bind-mounted in. Image stays small, weights are not duplicated.
- **NGC `nvcr.io/nvidia/cuda`** base images — Docker Hub `nvidia/cuda:13.2.0` works the same and matches the existing llama Dockerfile, so layer cache is shared.
- **`docker-compose` as runtime orchestrator** — we use compose for builds only; runtime (mutual exclusion, boot-default, status, wait_ready) stays in `docker-llm-switch` so the systemd and Docker paths have the same UX.

---

Local LLM inference stack for **NVIDIA DGX Spark (GB10 Grace Blackwell)**.  
Two-service design: fast coder + deep reasoning architect, on-demand switching.  
Benchmarked and tuned May 2026. All performance numbers are real.

> **Before enabling any service, read the [hardening section](#hardening).**  
> Running more than one heavyweight service simultaneously will OOM the host.

---

## Hardware requirements

- NVIDIA GB10 Grace Blackwell Superchip
- 128 GB unified CPU+GPU memory (no PCIe bottleneck)
- Grace CPU: 10× Cortex-X925 (4 GHz) + 10× Cortex-A725 (2.8 GHz), Armv9/SVE2
- CUDA 13.0+, driver 580+
- SM 12.1 — **not** the same as discrete Blackwell RTX (SM 100); build flags matter

---

## Model roster

| Slot | Model | HF repo | Port | Role |
|---|---|---|---|---|
| `coder` | Qwen3.6-27B dense | `unsloth/Qwen3.6-27B-MTP-GGUF:UD-Q4_K_XL` | 8152 | Fast coding, MTP |
| `architect` | Qwen3.6-35B-A3B MoE | `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Q4_K_XL` | 8154 | Deep reasoning |
| `vision` | Gemma-4-E4B | `unsloth/gemma-4-E4B-it-GGUF:UD-Q4_K_XL` | 8155 | Fast vision + audio |
| `gemma` | Gemma-4-31B | `unsloth/gemma-4-31B-it-GGUF:UD-Q4_K_XL` | 8156 | Alt reasoning + image |
| `gptoss` | GPT-OSS-20B | built-in (`--gpt-oss-20b-default`) | 8157 | Fast general |
| `imagine` | FLUX.2-klein-4B | `black-forest-labs/FLUX.2-klein-4B` (Apache 2.0) | 8160 | Image generation |
| `comfyui` | ComfyUI | your existing install | 8188 | Diffusion workflows |

---

## Performance (measured, greedy decode, 8 runs, GB10)

| Model | tg t/s avg | tg stdev | MTP accept | pp t/s |
|---|---|---|---|---|
| Qwen3.6-27B coder | 23.9 | 0.8 | 66–70% | 110–120 |
| Qwen3.6-35B architect | 58.5 | 0.5 | n/a (MTP removed) | 435 |

Memory at rest: ~8.5 GB. Peak per service: 27B ~61 GB, 35B ~48 GB.  
Both services fit simultaneously (~77 GB combined) but exclusive operation is recommended.

---

## Build: llama.cpp (GB10-specific flags)

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp

cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON \
  -DGGML_CUDA=ON \
  -DGGML_CURL=ON \
  -DCMAKE_CUDA_ARCHITECTURES="121a-real" \
  -DGGML_CUDA_FA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DGGML_CUDA_FORCE_MMQ=ON \
  -DGGML_CPU_KLEIDIAI=ON

cmake --build build --config Release -j20 --target llama-server llama-bench
```

| Flag | Why it matters |
|---|---|
| `121a-real` | Native GB10 SASS — no JIT at load time. `121` alone generates generic PTX. |
| `GGML_CPU_KLEIDIAI=ON` | ARM KleidiAI SVE2 GEMM kernels on Grace CPU. Biggest single flag on aarch64. |
| `GGML_CUDA_FA_ALL_QUANTS=ON` | Flash Attention for q8_0 KV cache. Without this, FA is silently disabled. |
| `GGML_CUDA_FORCE_MMQ=ON` | Quantized matmul path — faster on Blackwell for quantized models. |

> **Binary note (May 2026):** MTP merged into llama.cpp mainline (PR #22673 by @am17an).  
> However, mainline currently underperforms the pre-merge branch on GB10 (~23 t/s vs ~28 t/s).  
> The service files point to the MTP branch binary. Watch `src/llama-mtp.cpp` commits for fixes.

### CUDA environment variables (add to every service unit)

```ini
Environment="CUDA_SCALE_LAUNCH_QUEUES=4x"
Environment="GGML_CUDA_GRAPH_OPT=1"
Environment="GGML_CUDA_FORCE_CUBLAS_COMPUTE_16F=1"
```

---

## Build: stable-diffusion.cpp (for FLUX.2-klein)

```bash
git clone --recursive https://github.com/leejet/stable-diffusion.cpp
cd stable-diffusion.cpp
git submodule update --init --recursive

cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DSD_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="121" \
  -DSD_FLASH_ATTN=ON

cmake --build build --config Release -j20
```

### FLUX.2-klein model files (~17 GB total)

```bash
mkdir -p ~/models/flux2-klein/text_encoder

# Main model (~8 GB, Apache 2.0)
hf download black-forest-labs/FLUX.2-klein-4B \
  flux-2-klein-4b.safetensors --local-dir ~/models/flux2-klein

# VAE (~335 MB)
hf download Comfy-Org/flux2-dev \
  split_files/vae/flux2-vae.safetensors --local-dir ~/models/flux2-klein

# Text encoder shards (~8 GB total)
hf download black-forest-labs/FLUX.2-klein-4B \
  text_encoder/ --local-dir ~/models/flux2-klein/text_encoder

# Merge shards into single file (required once)
python3 -c "
from safetensors.torch import save_file, load_file
base = 'text_encoder'
s1 = load_file(f'{base}/model-00001-of-00002.safetensors')
s2 = load_file(f'{base}/model-00002-of-00002.safetensors')
save_file({**s1, **s2}, f'{base}/qwen_3_4b.safetensors')
print('Done')
" 
```

---

## Installation

Service files use the `%h` systemd specifier (expands to your home directory).  
You only need to adjust two things:

1. **`ExecStart` binary path** — edit each `.service` to point at your llama.cpp build.  
   Default: `%h/src/llama.cpp-mtp/build/bin/llama-server`

2. **`flux-klein.service` model paths** — edit to match your download location.  
   Default: `%h/models/flux2-klein/...`

```bash
# Install service files
mkdir -p ~/.config/systemd/user
cp systemd/units/*.service ~/.config/systemd/user/

# Install drop-ins (memory caps + mutual exclusion) — recommended
bash systemd/harden-llm-stack.sh

# Or manually, copying the reference overlay:
for d in reference-previous/drop-ins/*/; do
  svc=$(basename "$d")
  mkdir -p ~/.config/systemd/user/$svc
  cp "$d/override.conf" ~/.config/systemd/user/$svc/
done

systemctl --user daemon-reload

# Install CLI tools
cp systemd/llm-switch ~/.local/bin/ && chmod +x ~/.local/bin/llm-switch
cp tools/flux-gen ~/.local/bin/ && chmod +x ~/.local/bin/flux-gen

# (Optional) Docker path — install the container manager
cp docker/docker-llm-switch ~/.local/bin/ && chmod +x ~/.local/bin/docker-llm-switch
```

---

## llm-switch

On-demand model switching. Stops the current service before starting the next,
giving each model the full 128 GB pool. Blocks until the model is serving.

```bash
llm-switch coder        # Qwen3.6-27B  — fast coding, MTP
llm-switch architect    # Qwen3.6-35B  — deep reasoning, MoE
llm-switch gemma        # Gemma-4-31B  — alt reasoning + image input
llm-switch vision       # Gemma-4-E4B  — fast vision + audio input
llm-switch imagine      # FLUX.2-klein — image generation
llm-switch gptoss       # GPT-OSS-20B  — fast general
llm-switch comfyui      # ComfyUI      — diffusion UI + workflows
llm-switch both         # coder + architect (accepts some contention)
llm-switch off          # stop everything
llm-switch status       # show running state + memory

# Boot state management
llm-switch boot-default architect   # set one slot to autostart at boot
llm-switch boot-safe                # disable all model autostart
llm-switch boot-status              # check what starts at boot
```

---

## Harness

[Hermes](https://github.com/nousresearch/hermes-agent) (NousResearch) as agentic harness.  
Provider config: `config/hermes-config-snippet.yaml`.

Key Hermes settings for local providers:
- `extra_body.max_tokens: 4096` — prevents response cutoff on long codegen
- `extra_body.temperature` — set per-model (0.6 coder, 1.0 architect/gemma)
- `extra_body.top_k` — 20 for Qwen models, 64 for Gemma models

---

## FLUX.2-klein API

sd-server uses an async job API, not OpenAI-compatible:

```bash
# Submit job
curl -s http://127.0.0.1:8160/sdcpp/v1/img_gen \
  -H "Content-Type: application/json" \
  -d '{"prompt":"...", "width":512, "height":512,
       "sample_params":{"sample_steps":4, "sample_method":"euler",
                        "guidance":{"txt_cfg":1.0,"distilled_guidance":3.5}}}'

# Poll until completed
curl -s http://127.0.0.1:8160/sdcpp/v1/jobs/{id}
# result.images[0].b64_json contains the PNG

# Or use the CLI wrapper
flux-gen "pixel art sword icon, white background" 512 512 4 42
```

> Use 4 steps with `cfg_scale=1.0` for the distilled 4B model.  
> The built-in web UI is available at `http://127.0.0.1:8160/` when the service is running.

---

## Hardening

> **Critical on GB10.** Running multiple heavyweight services simultaneously  
> exceeds 128 GB and causes a systemd OOM respawn loop that bricks the host.  
> See [POSTMORTEM.md](reference-previous/POSTMORTEM.md) for the full incident report.

### Drop-ins applied by `harden-llm-stack.sh`

Each service gets:
- `MemoryMax` — kernel OOMs the cgroup only, host stays up
- `OOMPolicy=stop` — OOM = deliberate halt, not respawn into more pressure
- `Conflicts=` — systemd stops conflicting services automatically
- `StartLimitBurst=3` — gives up after 3 failures in 10 minutes

| Service | MemoryHigh | MemoryMax |
|---|---|---|
| qwen27-mtp, qwen35-mtp, gemma-31b | 70G | 80G |
| gptoss-20b, comfyui | 30G | 40G |
| gemma-vision | 15G | 20G |
| flux-klein | 12G | 16G |

```bash
bash systemd/harden-llm-stack.sh          # apply
bash systemd/harden-llm-stack.sh --revert # remove all drop-ins
```

### Flag notes

| Flag | Status | Reason |
|---|---|---|
| `--no-mmap` | **removed** | Anonymous pages can't be evicted on unified memory. Page cache is safer. |
| `--mlock` | **removed** | Pins entire model permanently, starves other services. |
| `-c 262144` | optional | Lower to `131072` for typical tasks; 256K context is rarely needed. |

### Pre-reboot checklist

```bash
llm-switch boot-status              # confirm only one service autostarts
journalctl --list-boots | tail -5   # should grow ~1/day
```

---

## Open questions — improvements welcome

- Better MTP tuning for the 35B MoE (currently disabled, was 1.15–1.25× gain)
- Whether `--swa-full` improves long-context quality on hybrid attention layers
- Mainline llama.cpp MTP regression — watching `src/llama-mtp.cpp` for fixes
- Alternative harnesses to Hermes with better tool-call streaming

---

## Credits

- MTP support: [PR #22673](https://github.com/ggml-org/llama.cpp/pull/22673) by [@am17an](https://github.com/am17an) — merged mainline May 2026
- Model GGUFs: [Unsloth](https://huggingface.co/unsloth) — Dynamic 2.0 quantization
- FLUX.2-klein: [Black Forest Labs](https://github.com/black-forest-labs/flux2) — Apache 2.0
- stable-diffusion.cpp: [leejet](https://github.com/leejet/stable-diffusion.cpp)
- Harness: [NousResearch Hermes](https://github.com/nousresearch)
- GB10 build insights: [NVIDIA DGX Spark developer forums](https://forums.developer.nvidia.com/c/accelerated-computing/dgx-spark-gb10/719)
