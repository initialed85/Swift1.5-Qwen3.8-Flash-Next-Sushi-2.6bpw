#!/usr/bin/env python3
"""10-kld-table.py — render sushi kld compare JSONs as a markdown table.

Usage: 10-kld-table.py <dir-of-compare.json> [--json-out FILE]

compare's JSON schema is not documented, so this flattens every file and picks the
headline numbers by name, then prints a full appendix of every scalar it found. If a
key is missing the cell prints as '-' and the appendix shows what was there.

Reading the table:
  self rows (pack vs its own fixture, same binary/arms) MUST be 0 KLD and 100% top-1.
  Anything else is engine nondeterminism, not quality.
  cross rows are divergence between two quantisations of two DIFFERENT models.
"""
import glob
import json
import os
import sys

def flatten(obj, prefix=""):
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            out += flatten(v, f"{prefix}{k}.")
    elif isinstance(obj, list):
        out.append((prefix.rstrip("."), f"list[{len(obj)}]"))
        for i, v in enumerate(obj[:2]):
            out += flatten(v, f"{prefix}{i}.")
    elif isinstance(obj, (int, float, str, bool)) or obj is None:
        out.append((prefix.rstrip("."), obj))
    return out

def norm(key):
    return key.lower().replace("-", "").replace("_", "").replace(".", "")

def pick(cells, wanted, exclude=()):
    hits = []
    for depth, key, raw, val in cells:
        n = norm(key)
        if not wanted(n):
            continue
        if any(x in n for x in exclude):
            continue
        if isinstance(val, (int, float)):
            hits.append((depth, key, val))
    hits.sort(key=lambda t: (t[0], len(t[1])))  # shallowest, then shortest name
    return hits

COLUMNS = [
    ("KLD all positions", lambda n: "kld" in n and "eos" not in n and "bin" not in n),
    ("KLD to first EOS", lambda n: "kld" in n and "eos" in n),
    ("top-1", lambda n: ("top1" in n or "topagreement" in n or "agreement" in n)),
    ("NLL", lambda n: "nll" in n),
    ("positions", lambda n: "position" in n and any(x in n for x in ("count", "total", "n", "num"))),
]

def fmt(v):
    if isinstance(v, float):
        return f"{v:.4f}" if abs(v) < 1000 else f"{v:.1f}"
    return str(v)

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    d = sys.argv[1]
    files = sorted(glob.glob(os.path.join(d, "*.json")))
    if not files:
        print(f"no compare JSONs in {d}")
        return 1

    rows = []
    for f in files:
        try:
            data = json.load(open(f))
        except Exception as e:  # noqa: BLE001
            rows.append({"name": os.path.basename(f), "err": str(e), "cells": []})
            continue
        flat = flatten(data)
        cells = []
        def walk(o, pre="", depth=0):
            if isinstance(o, dict):
                for k, v in o.items():
                    walk(v, f"{pre}{k}.", depth + 1)
            elif isinstance(o, list):
                for i, v in enumerate(o[:2]):
                    walk(v, f"{pre}{i}.", depth + 1)
            else:
                cells.append((depth, pre.rstrip("."), pre.rstrip("."), o))
        walk(data)
        name = os.path.basename(f)[:-5]
        row = {"name": name, "cells": cells, "err": None}
        for col, want in COLUMNS:
            hits = pick(cells, want)
            row[col] = fmt(hits[0][2]) if hits else "-"
            if len(hits) > 1:
                row[col] += f"  ({hits[0][1]})"
        label = data.get("label") if isinstance(data, dict) else None
        row["label"] = label or name
        rows.append(row)

    order = {"standard4": 0, "ours16": 1}
    def key(r):
        kind = r["name"].split("__")[0]
        return (order.get(kind, 9), "self" in r["name"], r["name"])

    rows.sort(key=key)
    cols = [c for c, _ in COLUMNS]
    print("| fixture | row | " + " | ".join(cols) + " |")
    print("|---|---|" + "---|" * len(cols))
    for r in rows:
        kind, pair = (r["name"].split("__") + [""])[:2]
        print(f"| {kind} | {pair} | " + " | ".join(r.get(c, "-") for c in cols) + " |")
    print()
    print("Self rows (pack vs its own fixture) must read 0 KLD / 100% top-1 on the same binary;")
    print("a nonzero self row is engine nondeterminism, not quality. Cross rows compare two")
    print("quantisations of two DIFFERENT models (Swift 1.5 vs base Qwen) — a fingerprint, not")
    print("a KLD-to-teacher, and not comparable with sushi's published 16x512 wikitext rows.")
    print()
    print("## Appendix — every scalar in each compare JSON")
    for r in rows:
        print(f"\n### {r['name']}")
        if r["err"]:
            print(f"read failed: {r['err']}")
            continue
        seen = set()
        for depth, key, raw, val in r["cells"]:
            if key in seen:
                continue
            seen.add(key)
            if isinstance(val, (int, float)) and not isinstance(val, bool):
                print(f"- `{key}` = {val}")
            elif isinstance(val, str) and len(val) < 120:
                print(f"- `{key}` = {val!r}")
            elif isinstance(val, str):
                print(f"- `{key}` = <{len(val)} chars>")
            else:
                print(f"- `{key}` = {val}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
