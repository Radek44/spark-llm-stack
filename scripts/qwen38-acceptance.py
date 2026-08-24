#!/usr/bin/env python3
"""Acceptance suite for the qwen38 stack after the DFlash 2 / template switch.

Every check is falsifiable and prints PASS/FAIL with the evidence that decided
it. Nothing here trusts a 200 response as proof of anything.

The reasoning_effort checks deserve a note, because "the default is applied" is
not directly observable -- SGLang does not echo the rendered prompt. So it is
established behaviourally at temperature 0, where the same prompt through the
same effort must produce byte-identical text:

    A  :8171 direct, explicit medium          <- ground truth for "medium"
    B  :8180 LiteLLM, nothing specified       <- must equal A  => default lands
    C  :8171 direct, explicit xhigh           <- must differ from A, else the
                                                 knob does nothing and A==B
                                                 proves nothing
    D  :8180 LiteLLM, explicit xhigh          <- must equal C  => per-request
                                                 override still beats the
                                                 configured default

C is the control that keeps B honest. Without it, a stack that silently ignored
reasoning_effort entirely would pass A==B and look correct.
"""
from __future__ import annotations

import base64
import hashlib
import json
import struct
import sys
import urllib.error
import urllib.request
import zlib

DIRECT = "http://127.0.0.1:8171/v1/chat/completions"
ROUTER = "http://127.0.0.1:8180/v1/chat/completions"

results: list[tuple[str, bool, str]] = []


def record(name: str, ok: bool, detail: str) -> None:
    results.append((name, ok, detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {detail}", flush=True)


def call(url: str, body: dict, timeout: int = 300) -> dict:
    body.setdefault("model", "qwen38")
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer sk-anything"},
    )
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def text_of(resp: dict) -> str:
    """Content, but refuse to return a truncated completion as if it were whole.

    finish_reason=='length' means the cap was hit. Comparing hashes across a
    truncation boundary compares where the budget ran out, not what the model
    would say -- which is exactly how the D!=C false failure was produced.
    """
    choice = resp["choices"][0]
    if choice.get("finish_reason") == "length":
        u = resp.get("usage", {}).get("completion_tokens_details", {})
        raise RuntimeError(
            f"truncated: finish_reason=length, "
            f"reasoning_tokens={u.get('reasoning_tokens')}, "
            f"text_tokens={u.get('text_tokens')} -- raise max_tokens")
    return choice["message"].get("content") or ""


def flush_cache() -> None:
    """Empty the radix cache so the next request sees a known state.

    Best-effort: if the endpoint is missing the comparison is still worth
    running, it just loses the control, so this warns rather than aborts.
    """
    try:
        urllib.request.urlopen(urllib.request.Request(
            "http://127.0.0.1:8171/flush_cache", method="POST"), timeout=30).read()
    except Exception as exc:  # noqa: BLE001 - control is advisory
        print(f"       WARNING: flush_cache failed ({type(exc).__name__}); "
              f"effort hashes are not cache-controlled", flush=True)


def effort_call(url: str, effort: str | None) -> str:
    """One effort leg, from a flushed cache, identical in all else."""
    flush_cache()
    body: dict = {"messages": [{"role": "user", "content": EFFORT_PROMPT}],
                  "max_tokens": 4000, "temperature": 0, "top_p": 1}
    if effort is not None:
        body["chat_template_kwargs"] = {"reasoning_effort": effort}
    return sha(text_of(call(url, body)))


def sha(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()[:16]


def solid_png(rgb: tuple[int, int, int], size: int = 64) -> bytes:
    """Minimal solid-colour PNG, built here so the test needs no fixture file."""
    raw = b"".join(b"\x00" + bytes(rgb) * size for _ in range(size))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


# ---------------------------------------------------------------- 1. basics --
for label, url in (("direct :8171", DIRECT), ("router :8180", ROUTER)):
    try:
        t = text_of(call(url, {"messages": [{"role": "user", "content": "Reply with exactly: READY"}],
                               "max_tokens": 600, "temperature": 0}))
        record(f"chat via {label}", "READY" in t, repr(t.strip())[:60])
    except Exception as exc:
        record(f"chat via {label}", False, f"{type(exc).__name__}: {str(exc)[:120]}")

# ------------------------------------------------- 2. chat-template repairs --
# Two leading system messages plus a developer role. The stock template drops
# the second system message and has no developer branch, so it falls through to
# its "System message must be at the beginning" raise.
try:
    t = text_of(call(DIRECT, {"messages": [
        {"role": "system", "content": "S1"}, {"role": "system", "content": "S2"},
        {"role": "developer", "content": "D1"},
        {"role": "user", "content": "Reply with exactly: ROLES_OK"}],
        "max_tokens": 600, "temperature": 0}))
    record("template: system+system+developer", "ROLES_OK" in t, repr(t.strip())[:60])
except Exception as exc:
    record("template: system+system+developer", False, f"{type(exc).__name__}: {str(exc)[:120]}")

# reasoning_effort='high' is the standard OpenAI value; stock raises on it.
try:
    t = text_of(call(DIRECT, {"messages": [{"role": "user", "content": "Reply with exactly: HIGH_OK"}],
                              "max_tokens": 400, "temperature": 0,
                              "chat_template_kwargs": {"reasoning_effort": "high"}}))
    record("template: reasoning_effort=high accepted", "HIGH_OK" in t, repr(t.strip())[:60])
except Exception as exc:
    record("template: reasoning_effort=high accepted", False, f"{type(exc).__name__}: {str(exc)[:120]}")

# ------------------------------------------- 3. reasoning_effort plumbing ----
EFFORT_PROMPT = ("Write a JavaScript function `clamp(v, lo, hi)`. "
                 "Include one comment line. Code only.")
try:
    a = effort_call(DIRECT, "medium")
    b = effort_call(ROUTER, None)
    c = effort_call(DIRECT, "xhigh")
    d = effort_call(ROUTER, "xhigh")
    print(f"       A(direct medium)={a}  B(router default)={b}")
    print(f"       C(direct xhigh) ={c}  D(router xhigh)  ={d}")
    record("effort knob actually changes output (A != C)", a != c, f"{a} vs {c}")
    record("LiteLLM default is medium (B == A)", b == a, f"{b} vs {a}")
    record("per-request override still wins (D == C)", d == c, f"{d} vs {c}")
except Exception as exc:
    record("reasoning_effort plumbing", False, f"{type(exc).__name__}: {str(exc)[:160]}")

# ------------------------------------------------------------- 4. vision -----
img = base64.b64encode(solid_png((220, 20, 20))).decode()
for label, url in (("direct :8171", DIRECT), ("router :8180", ROUTER)):
    try:
        t = text_of(call(url, {"messages": [{"role": "user", "content": [
            {"type": "text", "text": "What colour fills this image? Answer with one word."},
            {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{img}"}}]}],
            "max_tokens": 300, "temperature": 0}))
        record(f"vision via {label}", "red" in t.lower(), repr(t.strip())[:70])
    except Exception as exc:
        record(f"vision via {label}", False, f"{type(exc).__name__}: {str(exc)[:120]}")

# -------------------------------------------------------- 5. tool calling ----
# The qwen3_coder parser with a nested-object argument -- the shape the
# template's `arguments is mapping` fix exists to handle.
TOOLS = [{"type": "function", "function": {
    "name": "set_wave", "description": "Configure an ocean wave.",
    "parameters": {"type": "object", "properties": {
        "name": {"type": "string"},
        "params": {"type": "object", "properties": {
            "amplitude": {"type": "number"}, "steepness": {"type": "number"}},
            "required": ["amplitude", "steepness"]}},
        "required": ["name", "params"]}}}]
try:
    resp = call(DIRECT, {"messages": [{"role": "user",
                "content": "Call set_wave for a wave named 'swell' with amplitude 1.5 and steepness 0.4."}],
                "tools": TOOLS, "tool_choice": "auto", "max_tokens": 700, "temperature": 0})
    msg = resp["choices"][0]["message"]
    calls = msg.get("tool_calls") or []
    if not calls:
        record("tool call: nested object args", False, f"no tool_calls; content={repr(msg.get('content'))[:80]}")
    else:
        args = json.loads(calls[0]["function"]["arguments"])
        ok = args.get("name") == "swell" and isinstance(args.get("params"), dict) \
            and abs(float(args["params"]["amplitude"]) - 1.5) < 1e-6
        record("tool call: nested object args", ok, json.dumps(args)[:100])
except Exception as exc:
    record("tool call: nested object args", False, f"{type(exc).__name__}: {str(exc)[:140]}")

# ------------------------------------------------------------- summary -------
passed = sum(1 for _, ok, _ in results if ok)
print(f"\n==== {passed}/{len(results)} passed ====")
for name, ok, detail in results:
    if not ok:
        print(f"  FAILED: {name} -- {detail}")
sys.exit(0 if passed == len(results) else 1)
