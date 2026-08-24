#!/usr/bin/env python3
"""Does radix-cache state change greedy output?

Last night's probe repeated one identical request N times and found the output
byte-stable, and concluded temperature 0 is reproducible here. This morning the
same effort level produced two different hashes inside one suite run. The
difference between the two situations is not the request -- it is what was in
the prefix cache when the request arrived.

Chunked prefill plus a partial radix hit changes how many chunks the prefill is
split into, which changes floating-point reduction order, which can flip a
token at a near-tie. If that is what is happening, then "same bytes" is only a
valid instrument when cache state is controlled, and every cross-configuration
hash comparison in this session needs that control.

Three conditions, same request throughout:
  COLD   flush_cache before every call      -> cache state constant (empty)
  WARM   no flush, repeated back to back    -> cache state constant (full)
  MIXED  interleaved with a sibling request -> cache state varies
If COLD and WARM are each internally stable but disagree with each other, or
MIXED varies, cache state is the variable.
"""
from __future__ import annotations

import hashlib, json, urllib.request

DIRECT = "http://127.0.0.1:8171"
PROMPT = ("Write a JavaScript function `clamp(v, lo, hi)`. "
          "Include one comment line. Code only.")
SIBLING = ("Write a JavaScript function `lerp(a, b, t)`. "
           "Include one comment line. Code only.")


def call(prompt: str, effort: str) -> str:
    body = {"model": "qwen38", "messages": [{"role": "user", "content": prompt}],
            "max_tokens": 4000, "temperature": 0, "top_p": 1,
            "chat_template_kwargs": {"reasoning_effort": effort}}
    req = urllib.request.Request(DIRECT + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer x"})
    r = json.load(urllib.request.urlopen(req, timeout=600))
    c = r["choices"][0]
    if c.get("finish_reason") == "length":
        return "TRUNCATED"
    return hashlib.sha256((c["message"].get("content") or "").encode()).hexdigest()[:16]


def flush() -> None:
    try:
        urllib.request.urlopen(urllib.request.Request(
            DIRECT + "/flush_cache", method="POST"), timeout=30).read()
    except Exception as exc:
        print(f"  (flush_cache unavailable: {type(exc).__name__})")


for effort in ("medium", "xhigh"):
    print(f"\n=== effort={effort} ===")

    cold = []
    for _ in range(3):
        flush()
        cold.append(call(PROMPT, effort))
    print(f"  COLD  (flush before each) {cold}  {'stable' if len(set(cold))==1 else 'VARIES'}")

    warm = [call(PROMPT, effort) for _ in range(3)]
    print(f"  WARM  (no flush, repeat)  {warm}  {'stable' if len(set(warm))==1 else 'VARIES'}")

    mixed = []
    for _ in range(3):
        call(SIBLING, effort)          # perturb the cache between measurements
        mixed.append(call(PROMPT, effort))
    print(f"  MIXED (sibling between)   {mixed}  {'stable' if len(set(mixed))==1 else 'VARIES'}")

    allh = set(cold) | set(warm) | set(mixed)
    print(f"  -> {len(allh)} distinct output(s) across all cache states: {sorted(allh)}")
