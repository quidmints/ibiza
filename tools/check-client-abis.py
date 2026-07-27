#!/usr/bin/env python3
"""
Cross-check every ethers ABI signature declared in the wallet's TypeScript against the real
compiled Solidity ABIs in forge's `out/`.

This catches the class of bug `tsc --strict` structurally cannot: ethers ABIs are plain STRINGS, so
a TS file can name a Solidity function that was renamed or deleted and still typecheck perfectly,
then revert at runtime. Every contract change we made to the PP fork is a candidate for this.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TS_DIRS = [ROOT / "frontend/identity-wallet/src"]
OUT = ROOT / "backend/contracts/out"

# ---- 1. collect every function/event/error signature the compiled contracts actually expose ----
onchain_funcs = {}   # name -> set of (inputs tuple)
onchain_events = {}
for artifact in OUT.rglob("*.json"):
    try:
        data = json.loads(artifact.read_text())
    except Exception:
        continue
    abi = data.get("abi")
    if not isinstance(abi, list):
        continue
    for entry in abi:
        t = entry.get("type")
        name = entry.get("name")
        if not name:
            continue
        types = tuple(i.get("type", "") for i in entry.get("inputs", []))
        if t == "function":
            onchain_funcs.setdefault(name, set()).add(types)
        elif t == "event":
            onchain_events.setdefault(name, set()).add(types)

# ---- 2. collect every signature the TypeScript declares in an ABI string ----
# Capture balanced-ish arg lists: tuples like "(address a,bytes b) x" appear inline in ethers
# human-readable ABIs, so a naive [^)]* stops at the first inner ")".
SIG_RE = re.compile(r'"\s*(function|event)\s+([A-Za-z_]\w*)\s*\((.*?)\)\s*(?:external|view|returns|"|,)')

def split_top_level(raw: str):
    """Split on commas that are NOT inside parentheses, so tuple components stay together."""
    parts, depth, cur = [], 0, ""
    for ch in raw:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return [p.strip() for p in parts if p.strip()]


def norm_types(raw: str):
    out = []
    for part in split_top_level(raw):
        part = re.sub(r"\b(calldata|memory|storage|indexed)\b", " ", part).strip()
        if part.startswith("("):
            # solc reports struct params as "tuple" in the compiled ABI
            out.append("tuple")
            continue
        tok = part.split()
        if not tok:
            continue
        out.append(tok[0])
    return tuple(out)

problems = []
checked = 0
for d in TS_DIRS:
    for ts in d.rglob("*.ts"):
        text = ts.read_text(encoding="utf-8", errors="replace")
        for m in SIG_RE.finditer(text):
            kind, name, raw_args = m.group(1), m.group(2), m.group(3)
            checked += 1
            types = norm_types(raw_args)
            table = onchain_funcs if kind == "function" else onchain_events
            rel = ts.relative_to(ROOT)
            line = text[: m.start()].count("\n") + 1
            if name not in table:
                problems.append((f"{rel}:{line}", kind, name, types, "NO SUCH NAME on any contract"))
            elif types not in table[name]:
                problems.append(
                    (f"{rel}:{line}", kind, name, types,
                     f"arg mismatch; on-chain variants: {sorted(table[name])}")
                )

print(f"checked {checked} ABI signatures declared in TypeScript\n")
if not problems:
    print("OK - every declared signature matches a real compiled contract signature")
    sys.exit(0)
print(f"{len(problems)} MISMATCH(ES):\n")
for loc, kind, name, types, why in problems:
    print(f"  {loc}\n    {kind} {name}{types}\n    -> {why}\n")
sys.exit(1)
