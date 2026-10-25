#!/usr/bin/env bash
# 06-kld.sh — the quality number: KLD of the pack against the BF16 checkpoint.
#
# sushi ships this measurement; beamster publishes it for their tiers. Two runs:
#   capture  — score the BF16 teacher (needs the 360 GB source on disk, streams experts)
#   compare  — score the pack against that fixture and write JSON
#
#   usage: 06-kld.sh <pack_dir> <src_dir>
#   env:   SUSHI, PROMPTS (standard4|dir|fixture|jsonl), TOKENS, TOP_K, KV_QUANT,
#          SSD_BUDGET_GB, TEACHER_DIR, OUT_JSON, LIMIT
#
# Cost, honestly: the teacher is 360 GB of BF16 streaming from SSD at ~1.3 GB/s with a small
# cache; capture is hours, not minutes, and it is the reason the source must exist again.
# The fixture is reusable across packs; the compare is minutes.
#
# House protocol (docs/quality-kld.md), so the number means something next to beamster's:
#   * teacher captured with a DENSE KV cache (--kv-quant 16 = bf16); students scored at kv8
#   * 16 prompts x 512 tokens, scored to the teacher's first end-of-turn token
#   * quote the "to-first-EOS" line, give the all-positions line beside it
#   * `standard4` is the bundled 2 prose + 2 code subset: comparable, not the published fixture
#   * bar to beat (published Sushi-2.6bpw, same rate/encoder/window): KLD 0.1355, top-1 89.08 %
set -euo pipefail

PACK="${1:?usage: 06-kld.sh <pack_dir> <src_dir>}"; PACK="${PACK/#\~/$HOME}"
SRC="${2:?usage: 06-kld.sh <pack_dir> <src_dir>}"; SRC="${SRC/#\~/$HOME}"
SUSHI="${SUSHI:-$HOME/sushi-macos-arm64/sushi}"
PROMPTS="${PROMPTS:-standard4}"
TOKENS="${TOKENS:-512}"
TOP_K="${TOP_K:-10}"
KV_QUANT="${KV_QUANT:-8}"
TEACHER_KV="${TEACHER_KV:-16}"     # dense (bf16) KV for the teacher, per docs/quality-kld.md
SSD_BUDGET_GB="${SSD_BUDGET_GB:-8}"
TEACHER_DIR="${TEACHER_DIR:-$HOME/kld-teacher-$(basename "$SRC")}"
OUT_JSON="${OUT_JSON:-$PWD/kld.json}"
LIMIT="${LIMIT:-0}"

[[ -d "$SRC" ]] || { echo "BF16 teacher missing at $SRC — run 01-download-source.sh first."; exit 1; }
[[ -f "$SRC/config.json" ]] || { echo "$SRC is not an HF checkpoint (no config.json)"; exit 1; }
free_gb=$(df -g "$HOME" | awk 'NR==2{print $4}')
echo "== free ${free_gb} GB; capture writes a fixture to $TEACHER_DIR"

echo "== 1/2 capture teacher (BF16, greedy ${TOKENS} tokens per prompt, experts streamed)"
"$SUSHI" kld capture \
  --model "$SRC" \
  --prompts "$PROMPTS" \
  --out "$TEACHER_DIR" \
  --tokens "$TOKENS" \
  --top-k "$TOP_K" \
  --no-mtp \
  --kv-quant "$TEACHER_KV" \
  --ssd-budget-gb "$SSD_BUDGET_GB" \
  ${LIMIT:+--limit "$LIMIT"}

echo "== 2/2 compare pack against the fixture (kv$KV_QUANT)"
"$SUSHI" kld compare \
  --model "$PACK" \
  --fixture "$TEACHER_DIR" \
  --kv-quant "$KV_QUANT" \
  --json "$OUT_JSON"

echo "== numbers -> $OUT_JSON"
[[ -f "$OUT_JSON" ]] && python3 - "$OUT_JSON" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
def walk(x,p=""):
    if isinstance(x,dict):
        for k,v in x.items(): walk(v,f"{p}.{k}")
    elif isinstance(x,(int,float)) and any(t in p.lower() for t in ("kld","nll","ppl","perplex","top1","kl")):
        print(f"  {p} = {x}")
walk(d)
print("  (full numbers in", sys.argv[1]+")")
PY
echo "Publish these numbers in README.md 'Quality' and measurements.json if you use them."
echo "Quote the to-first-EOS line; published Sushi-2.6bpw = KLD 0.1355, top-1 89.08 % (docs/qwen4-kld.md)."
