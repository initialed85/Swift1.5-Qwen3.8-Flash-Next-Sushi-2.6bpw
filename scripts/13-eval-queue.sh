#!/usr/bin/env bash
# 13-eval-queue.sh — run the task-level eval on BOTH packs with matched arms, unattended.
#
# Sequence (default): ours:hard, theirs:hard, theirs:code, ours:code. The server is restarted
# between jobs with the same flags and only --model swapped, so the only thing that moves between
# two compared rows is the pack. The last job leaves the server serving OUR pack (production).
#
#   CHECK=1 scripts/13-eval-queue.sh          print the plan, touch nothing
#   scripts/13-eval-queue.sh                  run the whole queue (hours; run it under nohup)
#   JOBS="ours:hard,theirs:code" ...          any subset, in order  (pack = ours|theirs)
#   SUITE defaults per job pair; CONCURRENCY / LLP / MAX_TOKENS / REASONING pass through to 11-eval.sh
#
# Resumable: a job is skipped if its report JSON already exists (`.done` marker per job label).
# Takes the box: it stops the server, which means 45 tok/s of production inference is down for the
# duration. Refuses to start while a capture/compare is running. Logs to logs/eval-queue-<stamp>.log.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/measurements/eval"
LOGDIR="$REPO/logs"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$LOGDIR/eval-queue-$STAMP.log"
LOCK="$OUT/.queue.lock"
PORT="${PORT:-8088}"
BASE="http://127.0.0.1:$PORT"
SUSHI_DIR="${SUSHI_DIR:-$HOME/sushi-macos-arm64}"
CONCURRENCY="${CONCURRENCY:-4}"
MAX_TOKENS="${MAX_TOKENS:-16000}"
LLP="${LLP:-0.6.12}"
mkdir -p "$OUT" "$LOGDIR"
# 11-eval.sh tees llmprobe stdout to "<report>.json.log"; when the queue redirects stdout to its
# own log, those files are empty noise. Drop the empty ones.
find "$OUT" -maxdepth 1 -name '*.json.log' -size 0 -delete 2>/dev/null || true

OURS_DIR="$HOME/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw"
THEIRS_DIR="$HOME/.sushi/models/beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw"
OURS_ID="initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw"
THEIRS_ID="beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw"

JOBS="${JOBS:-ours:hard,theirs:hard,theirs:code,ours:code}"
IFS=',' read -r -a JOBS_ARR <<< "$JOBS"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }

plan() {
  local i=0
  for j in "${JOBS_ARR[@]}"; do
    i=$((i+1))
    local pack="${j%%:*}" suite="${j##*:}"
    local dir id; case "$pack" in
      ours) dir="$OURS_DIR"; id="$OURS_ID";;
      theirs) dir="$THEIRS_DIR"; id="$THEIRS_ID";;
      *) echo "bad job '$j' (pack must be ours|theirs)"; return 2;;
    esac
    local eff; case "$suite" in code) eff="medium";; *) eff="xhigh";; esac
    [ -n "${REASONING:-}" ] && eff="$REASONING"
    printf '%2d. stop server -> serve %s -> warm -> SUITE=%s effort=%s conc=%s cap=%s\n' \
      "$i" "$pack" "$suite" "$eff" "$CONCURRENCY" "$MAX_TOKENS"
    printf '    eval target: %s (dir %s)\n' "$id" "$dir"
  done
  printf 'last job leaves the server serving: %s\n' "${JOBS_ARR[${#JOBS_ARR[@]}-1]%%:*}"
}

if [ "${CHECK:-0}" = "1" ]; then plan; exit 0; fi

# ---- guards -----------------------------------------------------------------------------
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  echo "REFUSE: an eval queue is already running (pid $(cat "$LOCK"))."; exit 1
fi
echo $$ > "$LOCK"
restore_production() {  # never leave the box with no server serving our pack
  if [ "${LEAVE_DOWN:-0}" = "1" ]; then
    log "EXIT TRAP: LEAVE_DOWN=1, leaving the server as-is (start it with ~/run-sushi.sh)"
    rm -f "$LOCK"; return 0
  fi
  if ! curl -s -m 3 "$BASE/v1/models" 2>/dev/null | grep -q "$OURS_ID"; then
    log "EXIT TRAP: server is not serving $OURS_ID; restarting it"
    ( cd "$SUSHI_DIR" && MODEL="$OURS_DIR/" nohup bash "$HOME/run-sushi.sh" >>"$LOGDIR/server-$STAMP.log" 2>&1 & )
    sleep 20
  fi
  rm -f "$LOCK"
}
trap restore_production EXIT
if pgrep -f 'kld (capture|compare)' >/dev/null 2>&1; then
  echo "REFUSE: a kld capture/compare is running; it needs the GPU."; trap - EXIT; exit 1
fi
[ -x "$SUSHI_DIR/sushi" ] || { echo "REFUSE: no sushi binary in $SUSHI_DIR (run-sushi.sh runs ./sushi from its cwd)"; trap - EXIT; exit 1; }
[ -f "$HOME/run-sushi.sh" ] || { echo "REFUSE: $HOME/run-sushi.sh not found"; trap - EXIT; exit 1; }
[ -d "$OURS_DIR" ] && [ -d "$THEIRS_DIR" ] || { echo "REFUSE: a pack dir is missing"; trap - EXIT; exit 1; }
python3 "$REPO/scripts/pack-check.py" "$OURS_DIR" >/dev/null 2>&1 || { echo "REFUSE: ours fails pack-check"; trap - EXIT; exit 1; }
python3 "$REPO/scripts/pack-check.py" "$THEIRS_DIR" >/dev/null 2>&1 || { echo "REFUSE: theirs fails pack-check"; trap - EXIT; exit 1; }

log "eval queue starting: $JOBS"
log "boxes: server downtime for the whole queue; production inference will be down"

serve() {  # serve <dir> ; restart the server on a pack, wait for ready + loaded
  local dir="$1" id="$2"
  log "stopping server (if any)"
  "$HOME/stop-sushi.sh" >>"$LOG" 2>&1 || true
  sleep 3
  log "starting server on $id (cwd $SUSHI_DIR, script $HOME/run-sushi.sh)"
  # run-sushi.sh invokes ./sushi, so it must run with cwd = the dir holding the sushi binary
  ( cd "$SUSHI_DIR" && MODEL="$dir/" nohup bash "$HOME/run-sushi.sh" >>"$LOGDIR/server-$STAMP.log" 2>&1 & )
  local t=0
  until curl -s -m 5 "$BASE/v1/models" 2>/dev/null | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(x['id']=='$id' for x in d.get('data',[])) else 1)" ; do
    sleep 5; t=$((t+5)); [ $t -ge 420 ] && { log "FATAL: server did not announce $id in 420 s"; tail -20 "$LOGDIR/server-$STAMP.log" >>"$LOG"; exit 1; }
  done
  log "announced; forcing load"
  curl -s -m 180 "$BASE/v1/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$id\",\"prompt\":\"hello\",\"max_tokens\":1,\"temperature\":0}" >>"$LOG" 2>&1 || true
  t=0
  until curl -s -m 5 "$BASE/v1/models" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin); m=[x for x in d['data'] if x['id']=='$id']
sys.exit(0 if m and m[0].get('loaded') and m[0].get('state')=='ready' else 1)"; do
    sleep 5; t=$((t+5)); [ $t -ge 420 ] && { log "FATAL: pack did not reach ready in 420 s"; tail -20 "$LOGDIR/server-$STAMP.log" >>"$LOG"; exit 1; }
  done
  log "ready: $id (loaded, warm)"
}

i=0
for job in "${JOBS_ARR[@]}"; do
  i=$((i+1))
  pack="${job%%:*}"; suite="${job##*:}"
  case "$pack" in ours) dir="$OURS_DIR"; id="$OURS_ID";; *) dir="$THEIRS_DIR"; id="$THEIRS_ID";; esac
  tag="$(echo "$id" | tr '/:' '__')__${suite}"
  if ls "$OUT/${tag}-"*.json >/dev/null 2>&1; then
    log "job $i ($tag): report already exists, skipping"
    continue
  fi
  log "job $i of ${#JOBS_ARR[@]}: $tag"
  serve "$dir" "$id"
  log "job $i: running suite=$suite model=$id"
  SUITE="$suite" CONCURRENCY="$CONCURRENCY" MAX_TOKENS="$MAX_TOKENS" LLP="$LLP" FORCE=1 \
    "$REPO/scripts/11-eval.sh" "$id" >>"$LOG" 2>&1
  rc=$?
  if ls "$OUT/${tag}-"*.json >/dev/null 2>&1; then
    log "job $i: finished (rc=$rc) -> $(ls "$OUT/${tag}-"*.json | head -1)"
  else
    log "job $i: NO REPORT (rc=$rc); see $LOG"
  fi
done

# leave production as it was: serving our pack
final_id="$OURS_ID"; final_dir="$OURS_DIR"
last="${JOBS_ARR[${#JOBS_ARR[@]}-1]}"; [ "${last%%:*}" = "theirs" ] && { final_id="$THEIRS_ID"; final_dir="$THEIRS_DIR"; }
if ! curl -s -m 5 "$BASE/v1/models" 2>/dev/null | grep -q "$OURS_ID"; then
  log "restoring server to $OURS_ID"
  serve "$OURS_DIR" "$OURS_ID"
fi
log "queue complete; server serving $(curl -s -m 5 "$BASE/v1/models" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)"
log "render with: scripts/12-eval-table.py measurements/eval"
