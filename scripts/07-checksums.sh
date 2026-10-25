#!/usr/bin/env bash
# 07-checksums.sh — SHA256SUMS.txt for every file in the pack (74 GB read, ~4-6 min).
#
#   usage: 07-checksums.sh <pack_dir> [out_file]
#   verify: (cd <pack_dir> && shasum -a 256 -c SHA256SUMS.txt)
set -euo pipefail
PACK="${1:?usage: 07-checksums.sh <pack_dir> [out_file]}"; PACK="${PACK/#\~/$HOME}"
OUT="${2:-$PWD/SHA256SUMS.txt}"
[[ -d "$PACK" ]] || { echo "no pack at $PACK"; exit 1; }
echo "hashing $(find "$PACK" -type f | wc -l | tr -d ' ') files, $(du -sh "$PACK" | cut -f1) -> $OUT"
( cd "$PACK" && find . -type f ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 shasum -a 256 ) > "$OUT"
echo "$(wc -l < "$OUT" | tr -d ' ') lines written to $OUT"
echo "verify with: (cd $PACK && shasum -a 256 -c $OUT)"
