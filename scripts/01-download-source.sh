#!/usr/bin/env bash
# 01-download-source.sh — pull the BF16 HF source that `sushi convert exl3` requires.
#
# Resumable: rerun after a dropped connection and it continues from the published shards.
# `sushi convert exl3` needs weights, tokenizer and config; the source repo's benchmark JSONs,
# images, video and README are not read by the converter, so they are excluded by default
# (kept out of the 360 GB; they are redistributed in this repo from the pack).
#
#   usage: 01-download-source.sh [src_dir]        (default ~/swift15-src)
#   env:   SRC_REPO, WORKERS, LOG, EXCLUDES, HF_HUB_ENABLE_HF_TRANSFER
set -euo pipefail

SRC_REPO="${SRC_REPO:-ukisai/Swift1.5-Qwen3.8-Flash-Next}"
DEST="${1:-$HOME/swift15-src}"
LOG="${LOG:-$HOME/swift15-dl.log}"
WORKERS="${WORKERS:-4}"
read -r -a EXCLUDE_ARR <<< "${EXCLUDES:-benchmarks/*.json *.mp4 *.png}"

command -v hf >/dev/null || { echo "need the huggingface_hub CLI: pip install -U 'huggingface_hub[cli]'"; exit 1; }
hf auth whoami >/dev/null 2>&1 || { echo "no HF token: run 'hf auth login' (read scope is enough)"; exit 1; }

# A gated source needs the terms accepted on the website first. Check before burning an hour.
if ! python3 - "$SRC_REPO" <<'PY'
import json, sys, urllib.request
d = json.load(urllib.request.urlopen(
    f"https://huggingface.co/api/models/{sys.argv[1]}"))
g = d.get("gated")
print(f"source {sys.argv[1]}: gated={g} filesPermissions={d.get('filesPermissions')}")
sys.exit(1 if g else 0)
PY
then
  echo "gated source: accept the terms on the model page with this account, then re-run"; exit 1
fi

mkdir -p "$DEST"
echo "downloading $SRC_REPO -> $DEST  (workers=$WORKERS, log=$LOG)"
hf download "$SRC_REPO" --local-dir "$DEST" --max-workers "$WORKERS" --exclude "${EXCLUDE_ARR[@]}" 2>&1 | tee -a "$LOG"

n=$(find "$DEST" -name '*.safetensors' -type f | wc -l | tr -d ' ')
sz=$(du -sh "$DEST" | cut -f1)
echo "source ready: $n safetensors shards, $sz in $DEST"
echo "next: $(dirname "$0")/02-verify-source.py $DEST $SRC_REPO"
