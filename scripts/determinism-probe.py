#!/usr/bin/env python3
"""Is this server reproducible at temperature 0?

Every downstream claim -- "DFlash2 is lossless", "the reasoning_effort default
lands" -- is asserted by hashing completions and comparing them. That method is
only valid if the SAME request repeated gives the SAME bytes. It has never been
checked here. So check it, before trusting any hash comparison.

Confounder controlled: xhigh produces long reasoning, so a 500-token cap can
truncate mid-thought and turn a tiny divergence into a large one. Each effort
level is probed at a cap generous enough to finish, and finish_reason is
printed so truncation is visible rather than silent.
"""
from __future__ import annotations

import hashlib, json, urllib.request

DIRECT = "http://127.0.0.1:8171/v1/chat/completions"
ROUTER = "http://127.0.0.1:8180/v1/chat/completions"
PROMPT = ("Write a JavaScript function `clamp(v, lo, hi)`. "
          "Include one comment line. Code only.")


def call(url: str, body: dict) -> dict:
    body.setdefault("model", "qwen38")
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer sk-anything"})
    return json.load(urllib.request.urlopen(req, timeout=600))


def probe(label: str, url: str, effort: str | None, n: int, max_tokens: int) -> None:
    hashes, reasons, rlens = [], [], []
    for _ in range(n):
        body = {"messages": [{"role": "user", "content": PROMPT}],
                "max_tokens": max_tokens, "temperature": 0, "top_p": 1}
        if effort:
            body["chat_template_kwargs"] = {"reasoning_effort": effort}
        r = call(url, body)
        ch = r["choices"][0]
        msg = ch["message"]
        content = msg.get("content") or ""
        hashes.append(hashlib.sha256(content.encode()).hexdigest()[:16])
        reasons.append(ch.get("finish_reason"))
        rlens.append(len(msg.get("reasoning_content") or ""))
    stable = len(set(hashes)) == 1
    print(f"{'STABLE  ' if stable else 'VARIES  '} {label}")
    print(f"    hashes={hashes}")
    print(f"    finish={reasons}  reasoning_chars={rlens}")


print("=== repeatability of one identical request ===")
probe("direct medium x4  (cap 800)", DIRECT, "medium", 4, 800)
probe("direct xhigh  x4  (cap 4000)", DIRECT, "xhigh", 4, 4000)
probe("router xhigh  x4  (cap 4000)", ROUTER, "xhigh", 4, 4000)

print("\n=== does the router forward chat_template_kwargs at all? ===")
# If LiteLLM drops the client's kwargs, router-xhigh collapses onto the
# configured medium. If it forwards them, it tracks direct-xhigh.
for label, url, effort, cap in (("direct medium", DIRECT, "medium", 800),
                                ("router medium", ROUTER, "medium", 800),
                                ("router default", ROUTER, None, 800),
                                ("direct xhigh", DIRECT, "xhigh", 4000),
                                ("router xhigh", ROUTER, "xhigh", 4000)):
    body = {"messages": [{"role": "user", "content": PROMPT}],
            "max_tokens": cap, "temperature": 0, "top_p": 1}
    if effort:
        body["chat_template_kwargs"] = {"reasoning_effort": effort}
    r = call(url, body)
    m = r["choices"][0]["message"]
    c = m.get("content") or ""
    print(f"  {label:16s} sha={hashlib.sha256(c.encode()).hexdigest()[:16]} "
          f"reasoning_chars={len(m.get('reasoning_content') or ''):5d} "
          f"finish={r['choices'][0].get('finish_reason')}")

print("\n=== the empty-content router reply, in full ===")
r = call(ROUTER, {"messages": [{"role": "user", "content": "Reply with exactly: READY"}],
                  "max_tokens": 30, "temperature": 0})
print("  " + json.dumps(r["choices"][0], indent=2)[:900].replace("\n", "\n  "))
print("  usage:", json.dumps(r.get("usage")))
