#!/usr/bin/env bash
# supervise.sh — the unattended wrapper that actually finished this build.
#
# Watches the conversion, auto-resumes a crash, verifies the pack, smoke-tests it, and only
# then reclaims the 360 GB source. Serving stays a human decision (it wires ~50 GB and binds
# 0.0.0.0), so this never starts a server.
#
#   usage: supervise.sh <src_dir> <pack_dir>
#   env:   SUSHI, LOG, STATUS, MIN_FREE_GB, MAX_RESUMES, POLL, LAYERS
#
# It is single-instance (lockdir) and caps resumes, so a systematic failure stops and asks
# for a human instead of eating the disk in a loop.
set -uo pipefail

SRC="${1:?usage: supervise.sh <src_dir> <pack_dir>}"; SRC="${SRC/#\~/$HOME}"
OUT="${2:?usage: supervise.sh <src_dir> <pack_dir>}"; OUT="${OUT/#\~/$HOME}"
SUSHI="${SUSHI:-$HOME/sushi-macos-arm64/sushi}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${LOG:-$HOME/sushi-supervisor.log}"
CLOG="${CLOG:-$HOME/sushi-convert.log}"
STATUS="${STATUS:-$HOME/sushi-pack-STATUS.txt}"
MIN_FREE_GB="${MIN_FREE_GB:-60}"
MAX_RESUMES="${MAX_RESUMES:-3}"
POLL="${POLL:-300}"
LAYERS="${LAYERS:-48}"

LOCK="${LOCK:-$HOME/.sushi-supervisor-$(basename "$OUT").lock}"
if ! mkdir "$LOCK" 2>/dev/null; then echo "supervisor already running ($LOCK)"; exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

stamp(){ date '+%a %H:%M:%S'; }
say(){ echo "$(stamp) $*" | tee -a "$LOG" >> "$STATUS"; }
packsize(){ du -sh "$OUT" 2>/dev/null | cut -f1; }
layers(){ ls "$OUT"/layer-*.safetensors 2>/dev/null | wc -l | tr -d ' '; }
freegb(){ df -k /System/Volumes/Data | tail -1 | awk '{printf "%.0f", $4/1048576}'; }

RESUMES=0
say "=== supervisor start: layers=$(layers)/$LAYERS size=$(packsize) free=$(freegb)G ==="

# ---------- 1. watch / resume the convert ----------
while true; do
  if pgrep -f 'convert exl3' >/dev/null; then
    say "running: layers=$(layers)/$LAYERS size=$(packsize) free=$(freegb)G"
    sleep "$POLL"; continue
  fi
  if [[ -f "$OUT/model.safetensors.index.json" && -f "$OUT/config.json" && "$(layers)" -eq "$LAYERS" ]]; then
    say "convert COMPLETE: layers=$(layers)/$LAYERS size=$(packsize) free=$(freegb)G"; break
  fi
  say "convert not running, pack incomplete (layers=$(layers)/$LAYERS)"
  if pgrep -f 'sushi (serve|run)' >/dev/null; then
    say "NEEDS HUMAN: a sushi server is up; refusing to convert over it."; exit 1
  fi
  RESUMES=$((RESUMES+1))
  fg=$(freegb)
  (( fg < MIN_FREE_GB )) && { say "NEEDS HUMAN: only ${fg}G free, no headroom to resume."; exit 1; }
  (( RESUMES > MAX_RESUMES )) && { say "NEEDS HUMAN: $RESUMES resumes without completion."; exit 1; }
  say "resume #$RESUMES (03-convert.sh --resume); last convert log lines:"
  tail -6 "$CLOG" >> "$LOG" 2>/dev/null
  SRC="$SRC" OUT="$OUT" LOG="$CLOG" nohup "$HERE/03-convert.sh" "$SRC" "$OUT" --resume >>"$CLOG" 2>&1 &
  sleep 120
done

# ---------- 2. integrity ----------
python3 "$HERE/04-verify-pack.py" "$OUT" 2>&1 | tee -a "$LOG" >> "$STATUS"
if ! python3 "$HERE/04-verify-pack.py" "$OUT" >/dev/null; then
  say "INTEGRITY FAILED — source left intact for forensics. NEEDS HUMAN."; exit 1
fi

# ---------- 3. smoke test ----------
SUSHI="$SUSHI" LOG="$HOME/sushi-smoke.log" "$HERE/05-smoke-test.sh" "$OUT" >>"$LOG" 2>&1
rc=$?
say "smoke test exit=$rc : $(tail -1 "$HOME/sushi-smoke.log")"
if (( rc != 0 )); then
  say "SMOKE FAILED — source left intact for forensics. NEEDS HUMAN."; exit 1
fi

# ---------- 4. reclaim the source (only after a green smoke test) ----------
rm -rf "$SRC"
say "source removed: free=$(freegb)G pack=$(packsize)"
say "=== ALL DONE: pack at $OUT ==="
say "next: 07-checksums.sh $OUT && publish.sh $OUT   (serving stays a human decision)"
exit 0
