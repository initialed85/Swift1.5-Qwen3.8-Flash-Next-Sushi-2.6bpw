#!/bin/bash
# Watch the download, verify it, then run the sushi pack conversion. One shot.
SRC="$HOME/swift15-src"; OUT="$HOME/.sushi/models/beamster/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw"
log(){ echo "$(date '+%H:%M:%S') $*" >> "$HOME/swift15-pipeline.log"; }

log "pipeline: waiting for download"
while pgrep -f 'hf download' >/dev/null; do sleep 60; done
log "download process exited; size=$(du -sh $SRC | cut -f1) free=$(df -k /System/Volumes/Data | tail -1 | awk '{printf "%.0fG", $4/1048576}')"

n=$(ls "$SRC"/model-*-of-00131.safetensors 2>/dev/null | wc -l | tr -d ' ')
log "shards=$n/131"
if [ "$n" -ne 131 ]; then log "ABORT: incomplete download"; exit 1; fi

# sushi server would steal the GPU/RAM the trellis search needs
if pgrep -f 'sushi (serve|run)' >/dev/null; then log "ABORT: sushi server running"; exit 1; fi

log "convert: start"
"$HOME/sushi-macos-arm64/sushi" convert exl3 \
  --model "$SRC" --out "$OUT" --experts-k 2.625 --codebook mcg --window 15 --batch 16 \
  >> "$HOME/sushi-convert.log" 2>&1
rc=$?
log "convert: exit=$rc ; out size=$(du -sh "$OUT" 2>/dev/null | cut -f1) free=$(df -k /System/Volumes/Data | tail -1 | awk '{printf "%.0fG", $4/1048576}')"
tail -25 "$HOME/sushi-convert.log" >> "$HOME/swift15-pipeline.log"
exit $rc
