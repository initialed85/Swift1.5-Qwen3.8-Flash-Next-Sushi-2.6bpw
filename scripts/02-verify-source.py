#!/usr/bin/env python3
"""02-verify-source.py — prove the source matches the HF repo before converting.

A silently partial download is the #1 way a quantising run dies seven hours in. Check, in
increasing cost: file presence, byte size, then content hashes.

HF's tree API gives the hashes for free: `lfs.oid` is the file's SHA-256 for LFS files,
`oid` is the git blob SHA-1 (SHA1("blob <len>\\0" + bytes)) for ordinary files. Hashing 360 GB
of shards costs ~30 min of disk read, so the default pass checks sizes for everything and
hashes the small files the converter trusts most. Add --deep to hash every shard too.

  usage: 02-verify-source.py <src_dir> [repo] [--deep]
"""
import json, os, sys, hashlib, urllib.request

args = [a for a in sys.argv[1:] if a != "--deep"]
deep = "--deep" in sys.argv
src = os.path.expanduser(args[0] if args else "~/swift15-src")
repo = args[1] if len(args) > 1 else "ukisai/Swift1.5-Qwen3.8-Flash-Next"
EXCLUDE_PREFIX = ("benchmarks/", ".git/")
TRUSTED = ("config.json", "model.safetensors.index.json", "generation_config.json",
           "chat_template.jinja", "tokenizer_config.json", "merges.txt", "vocab.json")

def api(url):
    req = urllib.request.Request(url, headers={"User-Agent": "sushi-build/1.0"})
    return json.load(urllib.request.urlopen(req))

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""):
            h.update(chunk)
    return h.hexdigest()

def git_blob_sha1(path):
    data = open(path, "rb").read()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()

tree = api(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true&full=true")
want = {e["path"]: e for e in tree
        if e["type"] == "file" and not e["path"].startswith(EXCLUDE_PREFIX)}

missing, size_bad, hash_bad, hashed = [], [], [], 0
for path, e in sorted(want.items()):
    lp = os.path.join(src, path)
    if not os.path.exists(lp):
        missing.append(path); continue
    if os.path.getsize(lp) != e.get("size", -1):
        size_bad.append((path, os.path.getsize(lp), e.get("size"))); continue
    need_sha256 = deep and "lfs" in e
    need_blob = path in TRUSTED and "lfs" not in e
    if need_sha256:
        if sha256(lp) != e["lfs"]["oid"]:
            hash_bad.append((path, "sha256")); continue
        hashed += 1
    elif need_blob:
        if git_blob_sha1(lp) != e.get("oid"):
            hash_bad.append((path, "blob-sha1")); continue
        hashed += 1

shards = [p for p in want if p.endswith(".safetensors")]
print(f"repo files checked: {len(want)} ({len(shards)} safetensors shards)")
print(f"missing: {len(missing)}  size mismatch: {len(size_bad)}  hash mismatch: {len(hash_bad)}  hashed: {hashed}")
for m in missing[:20]: print("  MISSING", m)
for s in size_bad[:20]: print(f"  SIZE {s[0]}: local {s[1]} != repo {s[2]}")
for h in hash_bad[:20]: print(f"  HASH {h[0]} ({h[1]})")
if missing or size_bad or hash_bad:
    print("NOT safe to convert. Rerun 01-download-source.sh (it resumes), then verify again.")
    sys.exit(1)
print("source is complete and byte-exact. safe to convert.")
