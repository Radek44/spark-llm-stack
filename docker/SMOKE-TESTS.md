# Docker smoke tests

CI (`.github/workflows/docker.yml`) only does Dockerfile lint + a Scout
base-image scan — GitHub runners have no NVIDIA GPU, so the actual
binary cannot be exercised in CI. The checklist below is the manual
smoke-test pass that has to happen on a real GB10 host before changes
to anything under `docker/` are considered shippable.

Run from the repo root unless stated otherwise.

## 1. Static checks (mandatory; no hardware needed)

```bash
bash -n docker/run.sh docker/docker-llm-switch docker/comfyui/entrypoint.sh
docker compose -f docker/docker-compose.yml config >/dev/null
grep -nE '\-c "?[0-9]+' docker/Dockerfile docker/docker-llm-switch
grep -nE '\-c [0-9]+' systemd/units/*.service
```

Expected: scripts parse cleanly; compose YAML validates; the `-c`
context-size values match between Docker CMD tables and the
authoritative `.service` ExecStart blocks.

## 2. Build all three images

```bash
docker compose -f docker/docker-compose.yml build
```

Expected: three images present —

```bash
docker image ls | grep ^spark-llm-
# spark-llm-stack    (~5-6 GB,  llama.cpp)
# spark-llm-imagine  (~3-4 GB,  sd-server)
# spark-llm-comfyui  (~10-12 GB, ComfyUI + PyTorch + SageAttention)
```

If the ComfyUI build fails on SageAttention, pin a known-good ref:

```bash
docker compose -f docker/docker-compose.yml build \
  --build-arg SAGE_REF=v3.0.0 comfyui
```

## 3. Bad-ref regression tests (must FAIL)

The Dockerfiles must hard-fail on a typo, not silently fall through to
`master`. Verify the f32c2f9 / sd-server / comfyui guard:

```bash
# Each of these MUST exit non-zero. If any succeeds, the guard regressed.
docker build -f docker/Dockerfile        --build-arg LLAMA_REF=no-such-ref   .
docker build -f docker/sd-server/Dockerfile --build-arg SD_REF=no-such-ref     .
docker build -f docker/comfyui/Dockerfile   --build-arg COMFYUI_REF=no-such-ref .
```

## 4. Mutual exclusion + slot startup

```bash
docker-llm-switch coder    # llama coder up; nothing else running
docker-llm-switch architect
docker ps --format '{{.Names}}'   # exactly one spark-llm-* container
docker-llm-switch imagine
docker ps --format '{{.Names}}'   # spark-llm-imagine, nothing else
docker-llm-switch comfyui
docker ps --format '{{.Names}}'   # spark-llm-comfyui only

docker-llm-switch off
```

Expected: `docker ps` ever shows one spark-llm-* container.

## 5. Readiness + host-network reachability

```bash
docker-llm-switch coder
curl -sf http://127.0.0.1:8152/health >/dev/null && echo OK

docker-llm-switch imagine
curl -sf http://127.0.0.1:8160/sdcpp/v1/capabilities >/dev/null && echo OK

docker-llm-switch comfyui
# ComfyUI cold-start can run 60-120s; wait_ready handles this but verify:
curl -sf http://127.0.0.1:8188/system_stats >/dev/null && echo OK
```

From a Tailscale peer:

```bash
TS_IP=$(tailscale ip -4)
curl -sf "http://${TS_IP}:8152/health"
curl -sf "http://${TS_IP}:8160/sdcpp/v1/capabilities"
curl -sf "http://${TS_IP}:8188/system_stats"
```

Expected: all three return 200 from the LAN/Tailscale peer. Confirms
`--network=host` exposes each slot on the host's `tailscale0` interface.

## 6. Hardening parity with systemd

For each running slot:

```bash
docker inspect spark-llm-<slot> --format \
  '{{.HostConfig.OomScoreAdj}} {{.HostConfig.NetworkMode}} {{.HostConfig.Memory}}'
```

Expected:
- `OomScoreAdj` = `200` (matches `OOMScoreAdjust=200`)
- `NetworkMode` = `host`
- `Memory` = the slot's MEMCAP byte count (80g llama, 16g imagine, 40g comfyui)

## 7. End-to-end: FLUX image gen

```bash
docker-llm-switch imagine
flux-gen "test prompt, white background" 512 512 4 42
# expected: a PNG written under ~/flux-output/ within ~3 seconds
```

## 8. End-to-end: ComfyUI custom nodes persistence

```bash
docker-llm-switch comfyui
ls ~/comfyui/custom_nodes/   # ComfyUI-Manager should be present after first start
# Open http://<host>:8188 → Manager → install any test node
docker-llm-switch off
docker rmi spark-llm-comfyui
docker compose -f docker/docker-compose.yml build comfyui
docker-llm-switch comfyui
ls ~/comfyui/custom_nodes/   # the test node must still be there
```

Expected: user-installed nodes survive container restart AND image
rebuild (the `cp -n` seed in `entrypoint.sh` never clobbers them).

## 9. Boot-default policy + daemon-restart survival

```bash
docker-llm-switch boot-default architect
docker inspect spark-llm-architect --format '{{.HostConfig.RestartPolicy.Name}}'
# expected: unless-stopped

# Restart Docker (this WILL bounce all containers).
sudo systemctl restart docker

# Wait ~30s, then:
docker ps --format '{{.Names}}'    # spark-llm-architect should be back
```

Expected: `architect` auto-starts after daemon restart. (This is the
codex P1 fix from commit 4830f2c.)

## When to re-run

- Every PR that touches `docker/**`, `tools/flux-gen`, or any `.service`
  file under `systemd/units/`.
- Whenever a base-image bump (`CUDA_VERSION`, `UBUNTU_VERSION`) lands.
- Whenever PyTorch / SageAttention / ComfyUI pinned refs change.

If a smoke step fails, file the breakage with the failing command's
output before retrying.
