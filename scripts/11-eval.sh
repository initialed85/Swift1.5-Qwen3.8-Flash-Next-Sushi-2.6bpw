#!/usr/bin/env bash
# 11-eval.sh — task-level capability eval of the pack the server is serving, with llmprobe.
#
# This is the quality leg that needs NO teacher, NO 360 GB BF16 download and NO GPU downtime:
# it drives the live OpenAI-compatible server, grades at temperature 0, and scores answers
# deterministically (execution for the code deck, normalised `Answer:` line matching for the
# reasoning decks).
#
#   SUITE=code  ./11-eval.sh <served-model-id>     # 100 JS functions (50 HumanEval + 50 MBPP,
#                                                  # MultiPL-E ports), graded by RUNNING the tests
#   SUITE=hard  ./11-eval.sh <served-model-id>     # 50 questions: 30 MMLU-Pro, 10 OlympiadBench,
#                                                  # 5 LiveBench, 5 NIST Juliet — the deck beamster's
#                                                  # card reports "Hard 50" on
#
# Arms are fixed per suite so two packs are compared with nothing moving except the weights:
# greedy sampling (llmprobe default, t=0), pinned llmprobe version, pinned reasoning effort,
# pinned concurrency and output cap. The server must be serving the model you name; the script
# checks /v1/models and refuses if it is not, because measuring the wrong pack is how a bogus
# number gets into a card.
#
# CHECK=1       print the plan, run nothing
# SUITE=code|hard   (default: code)
# REASONING=..  effort (default: medium for code, xhigh for hard — xhigh is what beamster's card uses)
# CONCURRENCY=n server streams in flight (default 4 = the server's --max-concurrent)
# MAX_TOKENS=n  per-question output cap (default 16000, matching beamster's card)
# QUESTIONS=n   first n questions only (default: all) — for pilots
# CASES=alias   sub-deck selector, llmprobe's --eval-cases (default: all). Aliases llmprobe accepts:
#               olympiad|olympiadbench (OlympiadBench), mmlupro, livebench, juliet, humaneval, mbpp,
#               code. A CASES row is a SMALLER DECK at possibly different server flags — it gets its
#               own table and must never be blended with the full-deck rows.
# LLP=ver       llmprobe version to pin (default 0.6.12, the version beamster's card reports)
# OUT=dir       report dir (default <repo>/measurements/eval)
# FORCE=1       skip the "is the server idle-ish" advisory
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$REPO/measurements/eval}"
SUITE="${SUITE:-code}"
LLP="${LLP:-0.6.12}"
MAX_TOKENS="${MAX_TOKENS:-16000}"
CONCURRENCY="${CONCURRENCY:-2}"
# The report/manifest label carries the sub-deck so a 10-case slice cannot collide with, or be
# mistaken for, a 50-case row.
LABEL="$SUITE"; [ -n "$CASES" ] && LABEL="${SUITE}-${CASES}"
QUESTIONS="${QUESTIONS:-}"
CASES="${CASES:-}"
BASE="${BASE:-http://127.0.0.1:8088}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

case "$SUITE" in
  code) REASONING="${REASONING:-medium}" ;;
  hard) REASONING="${REASONING:-xhigh}" ;;
  core) REASONING="${REASONING:-xhigh}" ;;
  *) echo "SUITE must be code, hard or core"; exit 2 ;;
esac

MODEL="${1:-}"
if [ -z "$MODEL" ]; then
  sed -n '1,24p' "$0"; exit 2
fi

# ---- preflight: the server must be up and serving the model we are about to score -------
MODELS_JSON="$(curl -s -m 5 "$BASE/v1/models" || true)"
if [ -z "$MODELS_JSON" ]; then
  echo "REFUSE: no server answering $BASE/v1/models. This eval drives the live server; start it first."
  echo "  (unlike capture/compare, this one wants the server UP)"
  exit 1
fi
python3 - "$MODEL" <<'PY'
import json, sys, urllib.request
want = sys.argv[1]
base = "http://127.0.0.1:8088"
try:
    d = json.load(urllib.request.urlopen(base + "/v1/models", timeout=5))
except Exception as e:
    print(f"REFUSE: /v1/models did not answer ({e}). Start the server first: this eval drives it.")
    sys.exit(1)
ids = [m["id"] for m in d.get("data", [])]
if want not in ids:
    print(f"REFUSE: server serves {ids}, not {want!r}.")
    print("  Point the server at the pack you want to score (sushi serve --model <dir>), then rerun.")
    sys.exit(1)
m = [x for x in d["data"] if x["id"] == want][0]
print(f"  serving {m['id']}: loaded={m.get('loaded')} state={m.get('state')} "
      f"context={m.get('context_length')} on_disk={m.get('bytes_on_disk')}")
# A server that answers /v1/models before the pack is resident answers chat requests with *nothing*.
# llmprobe scores that as 100 wrong answers in three seconds and exits 0. Gate it.
if not (m.get("loaded") and m.get("state") == "ready"):
    print("REFUSE: the pack is announced but not loaded/ready. Send it one completion (curl /v1/completions")
    print("  max_tokens=1) or wait for state=ready, then rerun. An unloaded server produces a 0 % report,")
    print("  not a measurement.")
    sys.exit(1)
PY

SRV_PID="$(pgrep -f 'sushi serve' | head -1 || true)"
SRV_FLAGS="$( [ -n "$SRV_PID" ] && ps -o args= -p "$SRV_PID" | tr -s ' ' )"
N_INFLIGHT="$(curl -s -m 5 "${BASE}/metrics" 2>/dev/null | grep -cE '^sushi_(requests_active|inflight)' || true)"

BIN="$(command -v npx || true)"
[ -n "$BIN" ] || { echo "REFUSE: npx not found (llmprobe is an npm package, Apache-2.0)."; exit 1; }

REPORT_NAME="$(echo "$MODEL" | tr '/:' '__')__${LABEL}-${STAMP}.json"
CMD=(npx -y "llmprobe@${LLP}" "$BASE" -m "$MODEL" --eval-only --eval-suite "$SUITE"
     --reasoning "$REASONING" --concurrency "$CONCURRENCY" --eval-max-tokens "$MAX_TOKENS"
     --label "${LABEL}/${REASONING} kv8 cap${MAX_TOKENS} llmprobe-${LLP}"
     --json --save "$OUT/$REPORT_NAME")
[ -n "$QUESTIONS" ] && CMD+=(--eval-questions "$QUESTIONS")
[ -n "$CASES" ] && CMD+=(--eval-cases "$CASES")

REPORT="$OUT/$REPORT_NAME"
echo "== llmprobe ${LLP} :: suite=$LABEL effort=$REASONING concurrency=$CONCURRENCY cap=$MAX_TOKENS sampling=greedy(t=0) =="
[ -n "$CASES" ] && echo "   sub-deck: --eval-cases $CASES (this is a SLICE, its own table)"
echo "   model: $MODEL"
echo "   server: ${SRV_FLAGS:-<not running under this user>}"
echo "   report: $REPORT"
if [ "${CHECK:-0}" = "1" ]; then
  printf '   plan:   '; printf '%q ' "${CMD[@]}"; echo
  exit 0
fi
if [ -z "${FORCE:-}" ] && [ "${N_INFLIGHT:-0}" -gt 0 ]; then
  echo "ADVISORY: the server reports active requests; a capability eval at concurrency $CONCURRENCY will"
  echo "          share the engine with them and slow everyone. Set FORCE=1 to proceed anyway."
  exit 1
fi

mkdir -p "$OUT"
echo "== running (eval requests are never timed out by llmprobe; this is a ${SUITE} deck, expect minutes to hours) =="
set +e
"${CMD[@]}" 2>&1 | tee "$OUT/$(basename "$REPORT").log"
RC=${PIPESTATUS[0]}
set -e

# ---- record the arms alongside the report -------------------------------------------------
# ---- validity of what came back ----------------------------------------------------------
# 14-manifest.py exits 1 (and set -e stops us) when the report is not a measurement.
python3 "$REPO/scripts/14-manifest.py" "$REPORT" "$MODEL" "$LABEL" "$REASONING" "$CONCURRENCY" "$MAX_TOKENS" "$LLP" "$SRV_FLAGS" "$STAMP"

# A report that the validity step rejected exits 1; do not let it look like a completed job.
if [ "$RC" != "0" ]; then
  echo "11-eval.sh: reporting step failed (rc=$RC) — treat this run as not done"
  exit 1
fi
