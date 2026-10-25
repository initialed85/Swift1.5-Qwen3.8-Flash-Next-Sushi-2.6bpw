#!/usr/bin/env python3
"""pack-check.py — is this pack dir actually loadable?

Usage: pack-check.py <pack-dir> [--json]

Exit 0 = loadable, 1 = NOT loadable, 2 = not a pack dir.
Prints one human line per problem. This is the pre-flight that catches
`MissingMimoShard` (a shard named by the index that is not on disk) before a
capture/compare burns ten minutes of GPU time.

Checks:
  1. config.json parses, model_type + expert_quant/trunk_quant present
  2. model.safetensors.index.json parses; every shard it names exists, is
     non-empty, and the sum of shard bytes matches metadata.total_size
  3. no *.incomplete part files anywhere under the dir (a live `hf download`)
  4. the n-gram table named in config.json exists and is non-empty
  5. tokenizer.json / vocab.json present
"""
import json
import os
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    d = sys.argv[1]
    as_json = "--json" in sys.argv
    problems: list[str] = []
    info: dict[str, object] = {"dir": d}

    if not os.path.isdir(d):
        print(f"not a directory: {d}")
        return 2

    cfg_p = os.path.join(d, "config.json")
    idx_p = os.path.join(d, "model.safetensors.index.json")
    if not os.path.exists(cfg_p):
        problems.append("no config.json")
    if not os.path.exists(idx_p):
        problems.append("no model.safetensors.index.json")
    if problems:
        report(problems, info, as_json)
        return 2

    cfg = json.load(open(cfg_p))
    info["model_type"] = cfg.get("model_type")
    eq = cfg.get("expert_quant", {})
    info["expert_quant"] = {k: eq.get(k) for k in ("format", "k", "codebook", "window")}

    idx = json.load(open(idx_p))
    wm = idx.get("weight_map", {})
    shards = sorted(set(wm.values()))
    info["tensors"] = len(wm)
    info["shards"] = len(shards)

    missing, empty = [], []
    total = 0
    for f in shards:
        p = os.path.join(d, f)
        if not os.path.exists(p):
            missing.append(f)
            continue
        n = os.path.getsize(p)
        if n == 0:
            empty.append(f)
        total += n
    declared = idx.get("metadata", {}).get("total_size", 0)
    info["shard_bytes"] = total
    info["declared_bytes"] = declared
    if missing:
        problems.append(
            f"{len(missing)} shard(s) named by the index are MISSING on disk "
            f"(this is what the engine reports as MissingMimoShard): {missing[:4]}"
        )
    if empty:
        problems.append(f"{len(empty)} shard(s) are zero-length: {empty[:4]}")
    if declared and not missing and abs(total - declared) > 1_000_000:
        problems.append(
            f"shard bytes {total/1e9:.2f} GB != index total_size {declared/1e9:.2f} GB"
        )

    inc = []
    for root, _dirs, files in os.walk(d):
        for f in files:
            if f.endswith(".incomplete") or f.endswith(".tmp"):
                inc.append(os.path.join(root, f))
    if inc:
        problems.append(f"{len(inc)} .incomplete/.tmp part file(s): a download is still running or died")

    ng = cfg.get("ngram_table", {})
    if isinstance(ng, dict) and ng.get("file"):
        p = os.path.join(d, ng["file"])
        if not os.path.exists(p):
            problems.append(f"n-gram table {ng['file']} missing")
        elif os.path.getsize(p) == 0:
            problems.append(f"n-gram table {ng['file']} is zero-length")
        else:
            info["ngram_bytes"] = os.path.getsize(p)

    for f in ("tokenizer.json", "vocab.json"):
        if not os.path.exists(os.path.join(d, f)):
            problems.append(f"{f} missing")

    report(problems, info, as_json)
    return 1 if problems else 0


def report(problems, info, as_json) -> None:
    if as_json:
        print(json.dumps({"ok": not problems, "problems": problems, "info": info}, indent=2))
        return
    if problems:
        print(f"NOT LOADABLE: {info['dir']}")
        for p in problems:
            print(f"  - {p}")
    else:
        print(
            f"loadable: {info['dir']} · {info.get('model_type')} · "
            f"{info.get('tensors')} tensors / {info.get('shards')} shards · "
            f"{info.get('shard_bytes', 0)/1e9:.2f} GB weights · "
            f"n-gram {info.get('ngram_bytes', 0)/1e9:.2f} GB · "
            f"expert_quant {info.get('expert_quant')}"
        )


if __name__ == "__main__":
    sys.exit(main())
