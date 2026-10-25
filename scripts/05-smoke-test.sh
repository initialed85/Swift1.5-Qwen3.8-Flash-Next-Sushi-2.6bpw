#!/usr/bin/env bash
# 05-smoke-test.sh — serve the pack once offline and prove it generated through the pack.
#
# Asserts: exit 0, the sentinel text came back, the EXL3/MTP/GDN kernels engaged, and the
# preflight said it fits. This is the gate the supervisor uses before reclaiming 360 GB of source.
#
#   usage: 05-smoke-test.sh <pack_dir>
#   env:   SUSHI, SENTINEL, MAX_TOKENS, TIMEOUT
set -euo pipefail

PACK="${1:?usage: 05-smoke-test.sh <pack_dir>}"
PACK="${PACK/#\~/$HOME}"
SUSHI="${SUSHI:-$HOME/sushi-macos-arm64/sushi}"
SENTINEL="${SENTINEL:-PACK OK}"
MAX_TOKENS="${MAX_TOKENS:-160}"
TIMEOUT="${TIMEOUT:-1500}"
LOG="${LOG:-$HOME/sushi-smoke.log}"
[[ -d "$PACK" ]] || { echo "no pack at $PACK"; exit 1; }

echo "smoke: $PACK -> '$SENTINEL' (log: $LOG)"
set +e
timeout "$TIMEOUT" "$SUSHI" --model "$PACK" \
  --prompt "Reply with exactly: $SENTINEL" \
  --max-tokens "$MAX_TOKENS" --no-prevent-sleep --no-vision > "$LOG" 2>&1
rc=$?
set -e

fail=0
[[ $rc -eq 0 ]] || { echo "FAIL: exit=$rc"; fail=1; }
grep -qi "$SENTINEL" "$LOG" || { echo "FAIL: sentinel '$SENTINEL' not in output"; fail=1; }

echo "-- kernels the log must show (the pack is only really exercised if these engage)"
for pat in 'exl3.*n42 funnel' 'codebook=mcg' 'window=15' 'gdn.*engaged' 'mtp.*engaged' 'Loading layer-'; do
  if grep -qE "$pat" "$LOG"; then echo "  ok    $pat"; else echo "  MISS  $pat"; fail=1; fi
done

echo "-- preflight + rates"
grep -oE 'weights ~[0-9.]+ GB, needs ~[0-9.]+ GB, available [0-9.]+ GB' "$LOG" | tail -1
grep -E 'prefill: .*tok/s' "$LOG" | tail -1
grep -E '\[spec-stats\]' "$LOG" | tail -1 | grep -oE 'accepts=[0-9]+|attempts=[0-9]+|per_draft_pct=[0-9.]+' | tr '\n' ' '; echo

if (( fail )); then
  echo "SMOKE FAILED — keep the source for forensics, look at $LOG"
  exit 1
fi
echo "SMOKE OK: pack loads, generates, and the EXL3/MTP/GDN paths are live."
