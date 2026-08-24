#!/usr/bin/env python3
"""Measure decode throughput of the local qwen38 server, and prove losslessness.

Run once against DSpark, once against DFlash2. Greedy (temperature 0) so the
two runs are directly comparable: DFlash2 claims lossless decoding, which means
the OUTPUT TEXT must be byte-identical to DSpark's, not merely similar. A
speedup with different text is not a speedup, it is a different model, so the
sha256 of each completion is recorded and compared across runs.

Concurrency 1 on purpose -- that is how the lane actually runs, and it is the
regime where speculative decoding pays most.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import time
import urllib.request

# Coding-shaped work, matching how the lane uses the model. Long enough outputs
# that per-request overhead does not dominate the tok/s figure.
PROMPTS = [
    "Write a JavaScript function `medianOfStream` maintaining two heaps, with a"
    " short comment on why two heaps rather than a sorted array. Code only.",
    "In JavaScript, write `parseDuration(s)` accepting '1h30m', '45s', '2d4h',"
    " returning milliseconds, rejecting malformed input with a thrown Error."
    " Include five example calls as comments. Code only.",
    "Write a GLSL fragment shader function that returns a Gerstner wave"
    " displacement for a given position, time, and four wave parameters."
    " Explain each parameter in one comment line. Code only.",
]


def run_one(url: str, model: str, prompt: str, max_tokens: int, effort: str) -> dict:
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "top_p": 1,
        # Keep the thinking phase from eating the budget; see the T38/T39
        # finding. Held constant across both runs so it cannot flatter either.
        "chat_template_kwargs": {"reasoning_effort": effort},
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer sk-anything"},
    )
    t0 = time.monotonic()
    resp = json.load(urllib.request.urlopen(req, timeout=900))
    elapsed = time.monotonic() - t0

    msg = resp["choices"][0]["message"]
    text = (msg.get("content") or "")
    reasoning = (msg.get("reasoning_content") or "")
    usage = resp.get("usage", {})
    completion = usage.get("completion_tokens") or 0
    return {
        "elapsed_s": round(elapsed, 2),
        "completion_tokens": completion,
        "tok_per_s": round(completion / elapsed, 1) if elapsed else 0.0,
        "prompt_tokens": usage.get("prompt_tokens"),
        # Hash content and reasoning separately: a lossless drafter must
        # reproduce both, but only content is what the lane consumes.
        "content_sha": hashlib.sha256(text.encode()).hexdigest()[:16],
        "reasoning_sha": hashlib.sha256(reasoning.encode()).hexdigest()[:16],
        "content_chars": len(text),
        "reasoning_chars": len(reasoning),
        "finish_reason": resp["choices"][0].get("finish_reason"),
    }


def server_identity(url: str) -> dict:
    """Ask the server what it is running instead of trusting local config.

    A drop-in can say DFLASH while the process on the port was started from an
    older command line; that exact mismatch happened this session. Recording
    what the live endpoint reports keeps the artifact honest.
    """
    base = url.split("/v1/")[0]
    out: dict = {}
    for name, path in (("model_info", "/get_model_info"),
                       ("server_info", "/get_server_info")):
        try:
            with urllib.request.urlopen(base + path, timeout=10) as fh:
                data = json.load(fh)
        except Exception as exc:
            out[name] = f"unavailable: {type(exc).__name__}"
            continue
        if name == "server_info":
            # The full server_args dump is thousands of keys; keep the ones
            # that identify the speculative configuration under test.
            keys = ("speculative_algorithm", "speculative_draft_model_path",
                    "speculative_num_draft_tokens", "mem_fraction_static",
                    "max_total_num_tokens", "context_length", "chat_template")
            src = data.get("server_args", data)
            out[name] = {k: src.get(k) for k in keys if k in src}
        else:
            out[name] = data
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8171/v1/chat/completions")
    ap.add_argument("--model", default="qwen38")
    ap.add_argument("--label", required=True, help="e.g. dspark or dflash2")
    ap.add_argument("--max-tokens", type=int, default=1200)
    ap.add_argument("--effort", default="medium")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    # One throwaway call first. The first request after a restart pays CUDA
    # graph warmup and an empty radix cache; counting it would understate the
    # configuration under test.
    try:
        run_one(args.url, args.model, "Reply with the word: ready", 16, "low")
    except Exception as exc:  # noqa: BLE001 - diagnostic only
        print(f"warmup failed: {exc}")

    results = []
    for i, prompt in enumerate(PROMPTS, 1):
        r = run_one(args.url, args.model, prompt, args.max_tokens, args.effort)
        r["prompt_index"] = i
        results.append(r)
        print(
            f"[{args.label}] p{i}: {r['tok_per_s']:>6} tok/s  "
            f"{r['completion_tokens']:>5} tok in {r['elapsed_s']:>6}s  "
            f"finish={r['finish_reason']}  sha={r['content_sha']}"
        )

    total_tok = sum(r["completion_tokens"] for r in results)
    total_s = sum(r["elapsed_s"] for r in results)
    agg = round(total_tok / total_s, 1) if total_s else 0.0
    print(f"[{args.label}] AGGREGATE {agg} tok/s over {total_tok} tokens / {total_s:.1f}s")

    payload = {
        "label": args.label,
        "aggregate_tok_per_s": agg,
        # Run parameters, so a future hash comparison can be attributed. A
        # differing sha means nothing unless both sides agree on effort, cap
        # and endpoint -- and the drafter is what is under test here.
        "params": {
            "url": args.url,
            "model": args.model,
            "effort": args.effort,
            "max_tokens": args.max_tokens,
            "temperature": 0,
        },
        "server": server_identity(args.url),
        "results": results,
    }
    out = args.out or f"/home/radek/spec-bench-{args.label}.json"
    with open(out, "w") as fh:
        json.dump(payload, fh, indent=2)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
