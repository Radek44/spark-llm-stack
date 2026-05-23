# PR #3 Review Remediation Handoff

Date: 2026-05-22
Target: `gardinermichael/spark-llm-stack#3`
Purpose: Apply fixes for the full-repo review findings (correctness/reliability/security)

## 1) Fix `ensure_absent` false-success race in `docker/docker-llm-switch`

Problem
- `ensure_absent()` returns success even if the container name is still present after polling.
- Downstream `docker run --name ...` can fail nondeterministically with name conflicts.

Proposed change
- Make `ensure_absent()` fail hard on timeout.
- Include an explicit error message with container name and elapsed wait.
- Preserve current best-effort behavior for `docker rm -f` itself, but do not silently continue when state remains non-absent.

Suggested patch shape
- In `ensure_absent()`:
  - Keep `docker rm -f "$name" >/dev/null 2>&1 || true`.
  - After loop timeout, print to stderr and `return 1`.
- In callers (`run_slot`, `boot_default` recreate path):
  - Check `ensure_absent "$name" || { echo "..." >&2; exit 1; }`.

Acceptance checks
- Force a repro by creating a rapidly flapping container with same name, then run `docker-llm-switch <slot>` repeatedly.
- Expected: deterministic failure with clear error, not random `Conflict. The container name ... is already in use`.

## 2) Expand Docker lint CI coverage to all Dockerfiles

Problem
- `.github/workflows/docker.yml` lint job checks only `docker/Dockerfile`.
- `docker/comfyui/Dockerfile` and `docker/sd-server/Dockerfile` can regress undetected.

Proposed change
- Convert lint job to a matrix over all Dockerfiles under `docker/` currently shipped.

Suggested patch shape
- Replace single lint step with matrix values:
  - `docker/Dockerfile`
  - `docker/sd-server/Dockerfile`
  - `docker/comfyui/Dockerfile`
- Use `with.file: ${{ matrix.dockerfile }}`.

Acceptance checks
- PR touching each Dockerfile should run lint for that file.
- Introduce a deliberate syntax error in each Dockerfile (one at a time) and confirm lint fails for corresponding matrix entry.

## 3) Expand Scout CVE scan scope to all runtime images

Problem
- Scout resolves/scans only the base from `docker/Dockerfile`.
- CVEs in runtime lineage for `sd-server` and `comfyui` may be missed.

Proposed change
- Add separate Scout scan steps (or matrix) for each runtime image base reference source.
- Keep `exit-code: false` behavior if non-blocking reporting is still desired.

Suggested patch shape
- Option A (simplest/explicit): 3 resolve+scan pairs:
  - resolve `docker/Dockerfile` -> scan result
  - resolve `docker/sd-server/Dockerfile` -> scan result
  - resolve `docker/comfyui/Dockerfile` -> scan result
- Option B (cleaner): matrix on Dockerfile path + `awk` extractor, one shared Scout step.
- Ensure secret env pass-through remains on each Scout step.

Acceptance checks
- Workflow summary contains three Scout results.
- Any known high/critical CVE in a base image appears in report for the corresponding Dockerfile lineage.

## 4) Remove unsafe interpolation in `tools/flux-gen`

Problem
- Embedded Python heredoc directly interpolates shell variables (including prompt text).
- Prompts with quotes/newlines can break execution; shell input is treated as code text.

Proposed change
- Pass values as arguments or environment variables to Python.
- Parse and validate inside Python before payload construction.

Suggested patch shape
- Preferred:
  - `python3 - "$BASE" "$PROMPT" "$WIDTH" "$HEIGHT" "$STEPS" "$SEED" "$OUTDIR" <<'PYEOF'`
  - In Python, read `sys.argv[1:]`.
- Validation in Python:
  - `width`, `height`, `steps`, `seed` parse as integers.
  - Reasonable bounds check for width/height/steps (to fail fast on typos).
- Keep existing endpoint flow unchanged.

Acceptance checks
- Prompt containing both quotes and newlines succeeds:
  - Example: `flux-gen $'he said "hi"\nsecond line' 512 512 4 42`
- Invalid numeric inputs return clear error and non-zero exit.

## 5) Fix stale header comment in `docker/docker-llm-switch`

Problem
- Header says `imagine` and `comfyui` are not covered, but script fully supports both.

Proposed change
- Update header comments to match current behavior.

Acceptance checks
- Help text and top-level comments consistently describe all 7 slots.

## Recommended implementation order

1. `ensure_absent` failure semantics (highest runtime risk)
2. `flux-gen` safe argument passing
3. Lint matrix expansion
4. Scout scope expansion
5. Comment cleanup

## Regression checklist after fixes

- `docker/docker-llm-switch help` shows expected slot/boot behavior.
- `shellcheck docker/docker-llm-switch docker/run.sh tools/flux-gen` passes (or document intentional exceptions).
- GitHub Actions `docker` workflow runs green on PR with no syntax faults.
- Manual sanity:
  - `docker-llm-switch coder`
  - `docker-llm-switch boot-default coder`
  - `docker-llm-switch status`
  - `docker-llm-switch off`
