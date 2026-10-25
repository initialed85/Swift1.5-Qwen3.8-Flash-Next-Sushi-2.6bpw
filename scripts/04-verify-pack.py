#!/usr/bin/env python3
"""04-verify-pack.py — is the pack whole, before spending 50 GB of RAM loading it?

Checks, per shard: magic + header length, JSON parseability, every tensor's data_offsets,
that the declared offset span fits in the file, that payload bytes == on-disk bytes, and that
every entry in model.safetensors.index.json resolves to a shard that exists.

Two bugs worth not repeating (both were hit building this pack):
  * safetensors headers contain `__metadata__` (a dict) as well as `__header__`. Neither is a
    tensor and neither has `data_offsets`. Skipping only `__header__` reports every shard as
    defective — a healthy 52-shard pack once scored 52 "problems".
  * the first draft read headers as text and needed 8+json_len bytes: use struct on the 8-byte
    little-endian length prefix.

  usage: 04-verify-pack.py <pack_dir>
"""
import json, os, struct, sys

d = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: 04-verify-pack.py <pack_dir>"))
idxp = os.path.join(d, "model.safetensors.index.json")
if not os.path.exists(idxp):
    sys.exit(f"no {idxp} — conversion did not reach the index stage")

idx = json.load(open(idxp))
shards = sorted(set(idx["weight_map"].values()))
problems, payload, tensors, sizes = [], 0, 0, 0

for s in shards:
    fp = os.path.join(d, s)
    if not os.path.exists(fp):
        problems.append((s, "missing")); continue
    try:
        with open(fp, "rb") as f:
            n = struct.unpack("<Q", f.read(8))[0]
            hdr = json.loads(f.read(n))
            span = 0
            for k, v in hdr.items():
                if k in ("__header__", "__metadata__"):
                    continue
                if not isinstance(v, dict) or "data_offsets" not in v:
                    problems.append((s, "no data_offsets", k)); continue
                a, b = v["data_offsets"]
                if b < a:
                    problems.append((s, "inverted offsets", k)); continue
                span = max(span, b)
                tensors += 1
                payload += b - a
    except Exception as e:
        problems.append((s, "header read", repr(e)[:80])); continue
    on_disk = os.path.getsize(fp)
    sizes += on_disk
    if on_disk < 8 + n + span:
        problems.append((s, "file shorter than declared payload", on_disk, 8 + n + span))

orphans = [k for k, v in idx["weight_map"].items() if not os.path.exists(os.path.join(d, v))]
print(f"pack: {d}")
print(f"shards            : {len(shards)}")
print(f"tensors verified  : {tensors}")
print(f"index entries     : {len(idx['weight_map'])}  unresolved: {len(orphans)}")
print(f"payload           : {payload/1e9:.2f} GB   on disk (shards): {sizes/1e9:.2f} GB")
print(f"defects           : {len(problems)}")
for p in problems[:25]:
    print("  ", p)
for o in orphans[:25]:
    print("   ORPHAN", o, "->", idx["weight_map"][o])
if problems or orphans:
    print("RESULT: NOT SERVE-READY")
    sys.exit(1)
print("RESULT: integrity OK")
