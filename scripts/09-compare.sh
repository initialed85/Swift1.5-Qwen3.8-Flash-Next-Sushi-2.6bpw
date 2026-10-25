#!/bin/bash
# 09-compare.sh — score packs against the fixtures captured by 08-capture.sh.
#
# Run AFTER the serving process is down: compare loads the student pack onto the GPU.
#
#   scripts/09-compare.sh                 every fixture found in $OUT_ROOT, every pair
#   CHECK=1 scripts/09-compare.sh        plan only, no GPU work
#   SELF=0 scripts/09-compare.sh         skip the self-checks (each pack vs its own fixture)
#   KV=16 scripts/09-compare.sh          score students with bf16 KV instead of the served kv8
#   GDN=16 scripts/09-compare.sh         score the student's served bf16 GDN state (default 32 = f32)
#
# Pairs produced (when both fixtures exist):
#   ours   vs theirs-fixture   <- the divergence number (Swift scored on base-Qwen's logits)
#   theirs vs ours-fixture     <- the reverse direction
#   ours   vs ours-fixture     <- self-check: must be 0.0000 on the same binary
#   theirs vs theirs-fixture   <- self-check: must be 0.0000
#
# Output: $REPO/measurements/kld/*.json, $REPO/measurements/kld/table.md, logs in $REPO/logs
# Exit: 0 ok, 1 prerequisite failed, 2 a compare failed.

set -u
export REPO="${REPO:-$HOME/Projects/Home/swift-1.5-sushi}"

SUSHI="${SUSHI:-$HOME/sushi-macos-arm64/sushi}"
OUR_PACK="${OUR_PACK:-$HOME/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw}"
THEIR_PACK="${THEIR_PACK:-$HOME/.sushi/models/beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw}"
OUT_ROOT="${OUT_ROOT:-$HOME/kld}"
OUT_DIR="$REPO/measurements/kld"
LOGDIR="$REPO/logs"

TOKENS="${TOKENS:-512}"
TOPK="${TOPK:-10}"
CTX="${CTX:-8192}"
KV="${KV:-8}"           # students scored at the served kv8 (house protocol)
KV_SELF="${KV_SELF:-off}" # self-checks use the capture's own arms: KLD must be exactly 0
GDN="${GDN:-32}"
SSD_BUDGET="${SSD_BUDGET:-12}"
WIRED="${WIRED:-60416}"
MARGIN="${MARGIN:-6}"
SELF="${SELF:-1}"
CHECK="${CHECK:-0}"
FORCE="${FORCE:-0}"

log() { printf '[compare %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() {
	log "ABORT: $*"
	exit 1
}
path_of() { [ "$1" = "ours" ] && printf '%s' "$OUR_PACK" || printf '%s' "$THEIR_PACK"; }

[ -x "$SUSHI" ] || die "sushi binary not found at $SUSHI"
VER="$("$SUSHI" --version 2>&1 | grep -m1 -oE 'sushi [0-9]+\.[0-9][^ ]*')"
log "binary ${VER:-?} · sha $(shasum -a 256 "$SUSHI" | cut -c1-12)"
mkdir -p "$OUT_DIR" "$LOGDIR"

SERVE_PIDS="$(pgrep -f 'sushi serve' 2>/dev/null || true)"
if [ -n "$SERVE_PIDS" ]; then
	log "serving process STILL RUNNING: $(echo "$SERVE_PIDS" | tr '\n' ' ')"
	die "stop it first: ~/stop-sushi.sh"
fi

DISK_FREE_GB=$(df -k "$OUT_DIR" | awk 'NR==2 {printf "%.0f", $4/1048576}')
WIRED_NOW=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null)

# --- discover fixtures ---------------------------------------------------------
PAIRS=""
NFIX=0
for fx in "$OUT_ROOT"/*/*/baseline.json; do
	[ -f "$fx" ] || continue
	fdir=$(dirname "$fx")
	fixkind=$(basename "$fdir")
	pk=$(basename "$(dirname "$fdir")")
	pack=$(path_of "$pk")
	[ -d "$pack" ] || {
		log "fixture $pk/$fixkind points at a pack dir that is gone: $pack — skip"
		continue
	}
	[ -f "$fdir/capture.done" ] || log "note: $pk/$fixkind has no capture.done marker, using it anyway"
	for student in ours theirs; do
		[ "$student" = "$pk" ] && [ "$SELF" != "1" ] && continue
		[ -d "$(path_of "$student")" ] || continue
		NFIX=$((NFIX + 1))
		PAIRS="$PAIRS$student $pk $fixkind
"
	done
done
[ "$NFIX" -gt 0 ] || die "no fixtures under $OUT_ROOT — run scripts/08-capture.sh first"

log "$NFIX comparisons planned:"
printf '%s' "$PAIRS" | while read -r s f k; do
	[ -n "${s:-}" ] || continue
	log "  fixture $f/$k  ->  student $s   (kv $( [ "$s" = "$f" ] && echo "$KV_SELF" || echo "$KV" ), gdn $GDN)"
done
log "disk free ${DISK_FREE_GB} GB · wired ${WIRED_NOW} MB"

if [ "$CHECK" = "1" ]; then
	log "CHECK=1 — plan validated, nothing scored. Run:  scripts/09-compare.sh"
	exit 0
fi

RAISED=0
if [ "$WIRED_NOW" != "$WIRED" ]; then
	if sudo -n sysctl "iogpu.wired_limit_mb=$WIRED" >/dev/null 2>&1; then
		RAISED=1
		log "iogpu.wired_limit_mb -> $WIRED"
	else
		die "cannot set iogpu.wired_limit_mb=$WIRED; run: sudo sysctl iogpu.wired_limit_mb=$WIRED"
	fi
fi

FAIL=0
stamp=$(date -u +%Y%m%dT%H%M%SZ)
printf '%s' "$PAIRS" | while read -r student fixturepack fixkind; do
	[ -n "${student:-}" ] || continue
	fdir="$OUT_ROOT/$fixturepack/$fixkind"
	spack=$(path_of "$student")
	if [ "$student" = "$fixturepack" ]; then
		kv="$KV_SELF"
		name="${fixkind}__self-${student}"
	else
		kv="$KV"
		name="${fixkind}__${fixturepack}-fixture-vs-${student}"
	fi
	json="$OUT_DIR/$name.json"
	if [ -f "$json" ] && [ "$FORCE" != "1" ]; then
		log "$name already scored ($json) — FORCE=1 to redo"
		continue
	fi
	log "$name: scoring $student against $fixturepack/$fixkind"
	sudo -n purge >/dev/null 2>&1 || true
	MLX_ENABLE_TF32=0 "$SUSHI" kld compare \
		--model "$spack" \
		--fixture "$fdir" \
		--json "$json" \
		--tokens "$TOKENS" \
		--top-k "$TOPK" \
		--ctx-size "$CTX" \
		--kv-quant "$kv" \
		--qwen-gdn "$GDN" \
		--ssd-budget-gb "$SSD_BUDGET" \
		--wired-margin-gib "$MARGIN" \
		--no-template \
		--no-mtp \
		--label "$name" 2>&1 | tee "$LOGDIR/compare-${name}-${stamp}.log"
	rc=${PIPESTATUS[0]}
	if [ "$rc" != "0" ] || [ ! -f "$json" ]; then
		log "$name: compare FAILED rc=$rc (see $LOGDIR/compare-${name}-${stamp}.log)"
		log "if the log blames --kv-quant, re-run with: KV=16 scripts/09-compare.sh  (and KV_SELF=16 for the self rows)"
		printf '2' >"$OUT_DIR/.lastfail"
		continue
	fi
	rm -f "$OUT_DIR/.lastfail"
	log "$name: scored -> $json"
done
if [ -f "$OUT_DIR/.lastfail" ]; then
	FAIL=2
	rm -f "$OUT_DIR/.lastfail"
fi

if [ "$RAISED" = "1" ] && [ "${RESTORE_WIRED:-1}" = "1" ]; then
	sudo -n sysctl iogpu.wired_limit_mb=0 >/dev/null 2>&1 && log "iogpu.wired_limit_mb -> 0 (default)"
fi

log "table:"
python3 "$REPO/scripts/10-kld-table.py" "$OUT_DIR" | tee "$OUT_DIR/table.md"
log "written: $OUT_DIR/table.md  (rc $FAIL)"
exit $FAIL
