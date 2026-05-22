# Autoresearch Profile Behaviors

## karpathy
Repository: `karpathy/autoresearch`
Flow:
1. clone/fetch repo
2. `uv sync`
3. `uv run prepare.py`
4. `timeout $KARPATHY_TRAIN_TIMEOUT uv run train.py`

## dgx
Repository: `David-Barnes-Data-Imaginations/autoresearch-DGX-Spark`
Flow:
1. clone/fetch repo
2. `uv sync`
3. `uv run prepare.py`
4. bounded `uv run train.py`

## nauto-orch
Repository: `iii-experimental/n-autoresearch`
Flow:
1. clone/fetch repo
2. `uv sync`
3. run `workers/orchestrator/orchestrator.py`

## nauto-worker
Repository: `iii-experimental/n-autoresearch`
Flow:
1. clone/fetch repo
2. `uv sync`
3. run `workers/worker/worker.py`

## gemini
Repository: `supratikpm/gemini-autoresearch`
Flow:
1. clone/fetch repo
2. keep container alive for host-driven Gemini CLI/skill workflows

## autokernel
Repository: `RightNow-AI/autokernel`
Flow:
1. clone/fetch repo
2. `uv sync`
3. execute stage selected by `AUTOKERNEL_STAGE`:
   - `profile` -> `profile.py`
   - `extract` -> `extract.py`
   - `bench` -> `bench.py`
   - `verify` -> `verify.py`

## Notes
- Profiles are launched through `autoresearch-switch` only.
- One profile runs at a time in mutual exclusion mode.
- Modify resource caps and repo URLs in `.env.autoresearch`.
