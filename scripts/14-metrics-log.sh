#!/usr/bin/env bash
# 14-metrics-log.sh — dumb raw collector. No parsing, no pipes.
#
# Appends a timestamped copy of the server's /metrics payload to a raw file, every N seconds.
# Parse it later with scripts/15-metrics-parse.py. If the parsing is wrong, re-parse the same file;
# nothing here has to be re-run, and nothing here can lose data.
#
#   scripts/14-metrics-log.sh                     # logs/metrics-raw-<stamp>.log, every 30 s
#   INTERVAL=10 scripts/14-metrics-log.sh
#   OUT=logs/metrics-raw-runX.log scripts/14-metrics-log.sh
#
# Stop it with: pkill -f 14-metrics-log.sh
set -u
PORT="${PORT:-8088}"
INTERVAL="${INTERVAL:-30}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-$(cd "$(dirname "$0")/.." && pwd)/logs/metrics-raw-$STAMP.log}"
mkdir -p "$(dirname "$OUT")"
echo "[metrics-log] writing raw /metrics snapshots to $OUT every ${INTERVAL}s"
while :; do
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT"
  # --write-out appends the request time after the body; that is the only derived field, and it is
  # cheap to recompute from the body if it ever turns out to be useless.
  curl -s -m 10 "http://127.0.0.1:$PORT/metrics" >> "$OUT" 2>/dev/null
  echo "--- curl_exit=$?" >> "$OUT"
  sleep "$INTERVAL"
done
