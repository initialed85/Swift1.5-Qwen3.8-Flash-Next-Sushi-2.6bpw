#!/usr/bin/env bash
# 03-convert.sh — the conversion: BF16 HF source -> sushi EXL3 pack. One machine, ~8 h.
#
#   usage: 03-convert.sh <src_dir> <pack_dir> [--resume]
#   env:   SUSHI, EXPERTS_K, CODEBOOK, WINDOW, BATCH, FORCE=1, MIN_FREE_GB, DRY=1
#
# The guards are the point of this script; the convert itself is six flags:
#   sushi convert exl3 --model SRC --out PACK --experts-k 2.625 --codebook mcg --window 15 --batch 16
#
#  * --experts-k is a strict 1/8 grid. "2.6" is REJECTED (BadFlagValue); 2.6bpw is 21/8 = 2.625.
#    The grid is read from the binary (`--experts-k help`), not hardcoded.
#  * A running sushi server wires ~50 GB and owns the GPU the trellis search needs -> refuse.
#  * Peak disk is source + pack-in-progress; refuse below MIN_FREE_GB (default 60).
#  * Expert search is memory-bound: warn under 48 GB RAM, hard-refuse under 32 GB.
#  * --resume continues from convert-progress.json at the layer boundary.
set -euo pipefail

SRC="${1:?usage: 03-convert.sh <src_dir> <pack_dir> [--resume]}"; SRC="${SRC/#\~/$HOME}"
OUT="${2:?usage: 03-convert.sh <src_dir> <pack_dir> [--resume]}"; OUT="${OUT/#\~/$HOME}"
shift 2 2>/dev/null || true
RESUME=""
[[ "${1:-}" == "--resume" ]] && RESUME="--resume"

SUSHI="${SUSHI:-$HOME/sushi-macos-arm64/sushi}"
EXPERTS_K="${EXPERTS_K:-2.625}"     # 2.6bpw = 21/8. 2.6 is not on the grid.
CODEBOOK="${CODEBOOK:-mcg}"         # beamster's 2.6bpw recipe
WINDOW="${WINDOW:-15}"              # --help: "use mcg with --window 15"; default is 32
BATCH="${BATCH:-16}"                # 1..64 experts quantised together per bank; the pack bytes do NOT depend on it (docs/flags.md) — RAM/throughput knob only
MIN_FREE_GB="${MIN_FREE_GB:-60}"
LOG="${LOG:-$HOME/sushi-convert.log}"
DRY="${DRY:-0}"

[[ -x "$SUSHI" ]] || { echo "sushi binary not found at $SUSHI"; echo "  brew install beamivalice/tap/sushi"; echo "  or: curl -L https://github.com/beamivalice/sushi/releases/latest/download/sushi-bin-macos-arm64.tar.gz | tar xz"; exit 1; }
[[ -d "$SRC" ]] || { echo "no source dir $SRC; run 01-download-source.sh"; exit 1; }
[[ "$(find "$SRC" -name '*.safetensors' | wc -l | tr -d ' ')" -gt 0 ]] || { echo "no safetensors in $SRC"; exit 1; }

echo "== sushi: $("$SUSHI" --version | head -1)"
echo "== source: $SRC ($(du -sh "$SRC" | cut -f1))"
echo "== pack:   $OUT"

# 1) --experts-k must be on the binary's grid. 2.6 -> BadFlagValue, 7 h lost if you guess.
#    The grid is derived from the binary's own help text ("1.5 to 8 in steps of 0.125"),
#    not hardcoded: 2.6bpw is 21/8 = 2.625 and 2.6 is not on that ladder.
HT="$(mktemp)"; "$SUSHI" convert exl3 --help >"$HT" 2>&1 || true
if ! python3 - "$HT" "$EXPERTS_K" "$WINDOW" "$CODEBOOK" <<'PY'
import re, sys
txt = open(sys.argv[1]).read()
k, w, cb = float(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
bad = 0
m = re.search(r"bits per weight,\s*([\d.]+)\s+to\s+([\d.]+)\s+in\s+steps\s+of\s+([\d.]+)", txt)
if m:
    lo, hi, st = (float(m.group(i)) for i in (1, 2, 3))
    n = round((k - lo) / st)
    valid = lo <= k <= hi and abs((lo + n * st) - k) < 1e-9
    print(f"experts-k: grid {lo}..{hi} step {st} -> {k} " + ("OK" if valid else
          f"REJECTED; nearest valid {lo + round((k-lo)/st)*st:.3f}"))
    bad |= not valid
m = re.search(r"--window <n>\s*\n?\s*trellis search window,\s*(\d+)\s+to\s+(\d+)", txt)
if m:
    lo, hi = int(m.group(1)), int(m.group(2))
    ok = lo <= w <= hi
    print(f"window: {lo}..{hi} -> {w} " + ("OK" if ok else "REJECTED"))
    bad |= not ok
m = re.search(r"--codebook <name>\s*\n?\s*(\S+)\s+or\s+(\S+)", txt)
if m:
    names = m.group(1, 2)
    ok = cb in names
    print(f"codebook: {'/'.join(names)} -> {cb} " + ("OK" if ok else "REJECTED"))
    bad |= not ok
sys.exit(1 if bad else 0)
PY
then
  echo "FAIL: flags are outside sushi's declared ranges (see the grid lines above). Aborting."
  rm -f "$HT"; exit 1
fi
rm -f "$HT"

# 2) Never convert while a server is serving. There is no `sushi server list`; the honest
#    detections are the process table and the port. A server wires ~50 GB and owns the GPU
#    the trellis search needs — converting under it OOMs and loses hours of work.
if [[ "${FORCE:-0}" != 1 ]]; then
  if pgrep -f 'sushi (serve|run)' >/dev/null 2>&1; then
    echo "FAIL: a sushi server/serve process is running: $(pgrep -fl 'sushi (serve|run)' | tr '\n' '; ')"
    echo "      It owns ~50 GB of wired memory the search needs. Stop it, or FORCE=1."
    exit 1
  fi
  probe_port="${PROBE_PORT:-${SUSHI_PORT:-8088}}"
  if curl -sf -m 2 "http://127.0.0.1:${probe_port}/v1/models" >/dev/null 2>&1; then
    echo "FAIL: something is answering OpenAI-compatible API on 127.0.0.1:${probe_port}."
    echo "      That is a serving sushi; it is what convert is about to fight over RAM."
    echo "      Stop it, point PROBE_PORT elsewhere, or FORCE=1."
    exit 1
  fi
fi

# 3) Disk: peak is source + pack mid-build, not the final size.
free_gb=$(df -g "$HOME" | awk 'NR==2{print $4}')
need_gb=$(( $(du -sk "$OUT" 2>/dev/null | cut -f1) / 1048576 + 80 ))
echo "== disk: ${free_gb} GB free (pack so far ${need_gb} GB)"
if (( free_gb < MIN_FREE_GB )); then
  echo "FAIL: ${free_gb} GB free < MIN_FREE_GB=$MIN_FREE_GB. Free space first; the MTP/lm_head"
  echo "      phase is the peak and it will not wait for you to notice."
  exit 1
fi

# 4) RAM: the search keeps a 512-expert layer resident.
ram_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
echo "== ram: ${ram_gb} GB, cores: $(sysctl -n hw.ncpu)"
if (( ram_gb < 32 )); then echo "FAIL: ${ram_gb} GB RAM is below the 32 GB floor for this arch"; exit 1; fi
(( ram_gb < 48 )) && echo "note: ${ram_gb} GB < 48 GB; expect the MTP/lm_head phase to be tight"
command -v powermetrics >/dev/null && echo "note: thermal state: $(pmset -g therm 2>/dev/null | grep -oE 'CPU Speed.*|Level.*' | tr '\n' ' ')"

if [[ "$DRY" == 1 ]]; then echo "DRY: all guards passed, would run:"; echo "  $SUSHI convert exl3 --model $SRC --out $OUT --experts-k $EXPERTS_K --codebook $CODEBOOK --window $WINDOW --batch $BATCH $RESUME"; exit 0; fi

mkdir -p "$OUT"
echo "== converting (log: $LOG) — 48 expert layers at ~9.5 min each on M2/64 GB"
"$SUSHI" convert exl3 --model "$SRC" --out "$OUT" \
  --experts-k "$EXPERTS_K" --codebook "$CODEBOOK" --window "$WINDOW" --batch "$BATCH" $RESUME \
  2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}
echo "convert exit=$rc"
echo "next: $(dirname "$0")/04-verify-pack.py $OUT"
