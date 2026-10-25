#!/bin/bash
# Build a Sushi pack from the Swift 1.5 Qwen3.8-Flash-Next BF16 checkpoint.
# Run on icarus (sushi is MLX/Apple-Silicon only). Keep sushi's server OFF while this runs.
set -euo pipefail

SRC="${SRC:-$HOME/swift15-src}"
OUT="${OUT:-$HOME/.sushi/models/beamster/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw}"
BPW="${BPW:-2.6}"

# refuse to run if a sushi server is serving (it wires ~50 GB of the 64 GB unified memory)
if pgrep -f 'sushi (serve|run)' >/dev/null; then
  echo "sushi server is running — stop it first (it owns the GPU/RAM this needs)" >&2
  exit 1
fi

exec "$HOME/sushi-macos-arm64/sushi" convert exl3 \
  --model "$SRC" \
  --out "$OUT" \
  --experts-k "$BPW" \
  --codebook mcg \
  --window 15 \
  --batch 16 \
  "$@"
