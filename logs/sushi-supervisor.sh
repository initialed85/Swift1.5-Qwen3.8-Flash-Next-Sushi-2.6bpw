#!/bin/bash
# Overnight supervisor for the Swift 1.5 sushi pack conversion.
# Polls the convert, auto-resumes on crash, verifies the pack, smoke-tests it,
# and only then reclaims the 360 GB source. Serving stays a human decision.
set -uo pipefail

SRC="$HOME/swift15-src"
OUT="$HOME/.sushi/models/beamster/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw"
SUSHI="$HOME/sushi-macos-arm64/sushi"
LOG="$HOME/sushi-supervisor.log"
CLOG="$HOME/sushi-convert.log"
STATUS="$HOME/sushi-pack-STATUS.txt"

stamp(){ date '+%a %H:%M:%S'; }
say(){ echo "$(stamp) $*" | tee -a "$LOG" >> "$STATUS"; }
packsize(){ du -sh "$OUT" 2>/dev/null | cut -f1; }
layers(){ ls "$OUT"/layer-*.safetensors 2>/dev/null | wc -l | tr -d ' '; }
freegb(){ df -k /System/Volumes/Data | tail -1 | awk '{printf "%.0f", $4/1048576}'; }

RESUMES=0
say "=== supervisor start: layers=$(layers)/48 size=$(packsize) free=$(freegb)G ==="

# ---------- 1. watch the convert ----------
while true; do
  if pgrep -f 'convert exl3' >/dev/null; then
    say "running: layers=$(layers)/48 size=$(packsize) free=$(freegb)G"
    sleep 300
    continue
  fi
  if [ -f "$OUT/model.safetensors.index.json" ] && [ -f "$OUT/config.json" ] && [ "$(layers)" -eq 48 ]; then
    say "convert COMPLETE: layers=$(layers)/48 size=$(packsize) free=$(freegb)G"
    break
  fi
  say "convert not running, pack incomplete (layers=$(layers)/48)"
  if pgrep -f 'sushi (serve|run)' >/dev/null; then
    say "NEEDS HUMAN: a sushi server is up; refusing to convert over it."
    exit 1
  fi
  RESUMES=$((RESUMES+1))
  fg=$(freegb)
  if [ "$fg" -lt 60 ]; then
    say "NEEDS HUMAN: only ${fg}G free, not enough headroom to resume."
    exit 1
  fi
  if [ "$RESUMES" -gt 3 ]; then
    say "NEEDS HUMAN: $RESUMES resumes without completion."
    exit 1
  fi
  say "resume #$RESUMES with --resume; last convert log lines:"
  tail -6 "$CLOG" >> "$LOG"
  nohup "$SUSHI" convert exl3 --model "$SRC" --out "$OUT" \
    --experts-k 2.625 --codebook mcg --window 15 --batch 16 --resume >> "$CLOG" 2>&1 &
  sleep 120
done

# ---------- 2. integrity: every shard in the index, header-complete ----------
python3 - "$OUT" <<'PY' 2>&1 | tee -a "$LOG" >> "$STATUS"
import json,os,struct,sys
d=sys.argv[1]
idx=json.load(open(os.path.join(d,'model.safetensors.index.json')))
shards=sorted(set(idx['weight_map'].values()))
bad=[]
for s in shards:
    fp=os.path.join(d,s)
    if not os.path.exists(fp):
        bad.append((s,'missing')); continue
    try:
        with open(fp,'rb') as f:
            n=struct.unpack('<Q',f.read(8))[0]
            hdr=json.loads(f.read(n))
            tot=0
            for k,v in hdr.items():
                if k=='__header__': continue
                a,b=v['data_offsets']; tot+=b-a
            need=8+n+tot
            fs=os.path.getsize(fp)
            if fs<need: bad.append((s,'short',fs,need))
    except Exception as e:
        bad.append((s,'readfail',str(e)[:60]))
print("integrity: %d shards in index, %d problems" % (len(shards), len(bad)))
for b in bad[:10]: print("  BAD", b)
PY

# ---------- 3. smoke test ----------
timeout 1500 "$SUSHI" --model "$OUT" --prompt "Reply with exactly: PACK OK" \
  --max-tokens 160 --no-prevent-sleep --no-vision > "$HOME/sushi-smoke.log" 2>&1
rc=$?
say "smoke test exit=$rc output: $(head -c 200 "$HOME/sushi-smoke.log" | tr '\n' ' ')"
if [ "$rc" -ne 0 ] || ! grep -qi 'PACK OK' "$HOME/sushi-smoke.log"; then
  say "SMOKE FAILED - source left intact for forensics. NEEDS HUMAN."
  exit 1
fi

# ---------- 4. reclaim the source ----------
rm -rf "$SRC"
say "source removed: free=$(freegb)G pack=$(packsize)"
say "=== ALL DONE: pack at $OUT ==="
exit 0
