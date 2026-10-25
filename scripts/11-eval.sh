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
QUESTIONS="${QUESTIONS:-}"
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

REPORT_NAME="$(echo "$MODEL" | tr '/:' '__')__${SUITE}-${STAMP}.json"
CMD=(npx -y "llmprobe@${LLP}" "$BASE" -m "$MODEL" --eval-only --eval-suite "$SUITE"
     --reasoning "$REASONING" --concurrency "$CONCURRENCY" --eval-max-tokens "$MAX_TOKENS"
     --label "${SUITE}/${REASONING} kv8 cap${MAX_TOKENS} llmprobe-${LLP}"
     --json --save "$OUT/$REPORT_NAME")
[ -n "$QUESTIONS" ] && CMD+=(--eval-questions "$QUESTIONS")

REPORT="$OUT/$REPORT_NAME"
echo "== llmprobe ${LLP} :: suite=$SUITE effort=$REASONING concurrency=$CONCURRENCY cap=$MAX_TOKENS sampling=greedy(t=0) =="
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
python3 - "$REPORT" "$MODEL" "$SUITE" "$REASONING" "$CONCURRENCY" "$MAX_TOKENS" "$LLP" "$SRV_FLAGS" "$STAMP" <<'PY'
import json, os, sys, hashlib
report, model, suite, effort, conc, cap, llp, flags, stamp = sys.argv[1:10]
if not os.path.exists(report):
    print("no report written; skipping manifest"); sys.exit(0)
j = json.load(open(report))
r = j.get("reasoning", {})
cases = r.get("cases", [])
no_generation = [c for c in cases if not c.get("text")]
valid = bool(cases) and len(no_generation) <= len(cases) // 4 and (j.get("usage") or {}).get("outputTokens", 0) > 0
sha = hashlib.sha256(open(report, "rb").read()).hexdigest()
if not valid:
    inv = os.path.join(os.path.dirname(report), "invalid")
    os.makedirs(inv, exist_ok=True)
    dest = os.path.join(inv, os.path.basename(report))
    os.replace(report, dest)
    logf = report + ".log"
    if os.path.exists(logf):
        os.replace(logf, os.path.join(inv, os.path.basename(logf)))
    print(f"INVALID REPORT ({len(no_generation)}/{len(cases)} cases produced no text): moved to {dest}")
    print("  Usual cause: server answered while the pack was not resident, so every request returned empty.")
    print("  This report is not a measurement and is excluded from the queue's skip list.")
    sys.exit(1)
dur = j.get("durationMs", 0) / 1000.0
out_tok = (j.get("usage") or {}).get("outputTokens", 0)
man = {
    "schema": "swift15-eval-v1",
    "tool": "llmprobe", "tool_version": llp, "tool_license": "Apache-2.0 (ddalcu/llmprobe)",
    "report_sha256": sha,
    "model": model, "suite": suite,
    "arms": {"sampling": "greedy t=0 (llmprobe default)", "reasoning_effort": effort,
             "concurrency": int(conc), "max_output_tokens_per_question": int(cap),
             "server_flags": flags.strip()},
    "score": {"passed": r.get("passed"), "total": r.get("total"),
              "stopped_token_cap": r.get("stopped"), "errors": r.get("error"),
              "by_source": r.get("bySource")},
    "cost": {"duration_s": round(dur, 1), "output_tokens": out_tok,
             "input_tokens": (j.get("usage") or {}).get("inputTokens", 0),
             "mean_output_tokens_per_question": round(out_tok / r.get("total", 1), 1) if r.get("total") else None,
             "mean_reasoning_tokens_per_question": (round(sum(c.get("reasoningTokens") or 0 for c in r.get("cases", [])) / len(r.get("cases", [])), 1) if r.get("cases") else None)},
    "measured_utc": stamp,
    "valid": True,
    "cases_without_text": len(no_generation),
    "machine": j.get("machine"),
    "deck_licenses": {"GPQA": "CC BY 4.0", "SuperGPQA": "ODC-BY", "AIME 2025 mirror": "MIT",
                      "MMLU-Pro": "Apache-2.0 (as redistributed by llmprobe)",
                      "OlympiadBench": "Apache-2.0 (as redistributed by llmprobe)",
                      "LiveBench": "Apache-2.0 (as redistributed by llmprobe)",
                      "NIST Juliet reductions": "CC0", "MultiPL-E (code deck)": "MIT"},
    "comparability": ("Suites are not comparable to each other. Greedy (t=0) runs are not comparable to "
                      "--sampling preset runs. Effort, output cap, KV quantisation and MTP must match "
                      "between two runs that are being compared. llmprobe's own wording: 'Suites are not "
                      "comparable to each other'; 'Hard runs are reported as such and are not comparable "
                      "to core runs'."),
    "notes": ("aggregate scores only; the prompt sets are third-party corpora under the licenses listed "
              "and are not redistributed by this repo"),
}
open(report.replace(".json", "-manifest.json"), "w").write(json.dumps(man, indent=2) + "\n")
acc = 100.0 * (r.get("passed") or 0) / r.get("total", 1) if r.get("total") else 0
print(f"\n== {suite}: {r.get('passed')}/{r.get('total')} ({acc:.1f} %), "
      f"{dur:.0f} s, {out_tok} output tokens -> {report} ==")
PY

# A report that the validity step rejected exits 1; do not let it look like a completed job.
if [ "$RC" != "0" ]; then
  echo "11-eval.sh: reporting step failed (rc=$RC) — treat this run as not done"
  exit 1
fi
