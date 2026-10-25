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
#   STUDENTS=ours scripts/09-compare.sh  score one pack only
#
# Pairs produced (when both fixtures exist):
#   ours   vs theirs-fixture   <- the divergence number (Swift scored on base-Qwen's logits)
#   theirs vs ours-fixture     <- the reverse direction
#   ours   vs ours-fixture     <- self-check: must be 0.0000 on the same binary
#   theirs vs theirs-fixture   <- self-check: must be 0.0000
#
# Output: $REPO/measurements/kld/*.json, $REPO/measurements/kld/table.md, logs in $REPO/logs
# Exit: 0 ok, 1 prerequisite failed, 2 a compare failed.
#
# v2: pack-check.py gates every student and every fixture's teacher pack before GPU work,
# fixture dir names are sanitised, and failures are collected instead of overwritten.

set -u
export REPO="${REPO:-$HOME/Projects/Home/swift-1.5-sushi}"

SUSHI="${SUSHI:-$HOME/sushi-macos-arm64/sushi}"
OUR_PACK="${OUR_PACK:-$HOME/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw}"
THEIR_PACK="${THEIR_PACK:-$HOME/.sushi/models/beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw}"
OUT_ROOT="${OUT_ROOT:-$HOME/kld}"
OUT_DIR="$REPO/measurements/kld"
LOGDIR="$REPO/logs"
PACK_CHECK="$REPO/scripts/pack-check.py"

TOKENS="${TOKENS:-512}"
TOPK="${TOPK:-10}"
CTX="${CTX:-8192}"
KV="${KV:-8}"             # students scored at the served kv8 (house protocol)
KV_SELF="${KV_SELF:-off}" # self-checks use the capture's own arms: KLD must be exactly 0
GDN="${GDN:-32}"
SSD_BUDGET="${SSD_BUDGET:-12}"
WIRED="${WIRED:-60416}"
MARGIN="${MARGIN:-6}"
SELF="${SELF:-1}"
CHECK="${CHECK:-0}"
FORCE="${FORCE:-0}"
STUDENTS="${STUDENTS:-ours,theirs}"

log() { printf '[compare %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() {
	log "ABORT: $*"
	exit 1
}
clean() { printf '%s' "$1" | tr -d '[:space:]' | tr -c 'A-Za-z0-9._-' '-'; }
path_of() {
	case "$1" in
	ours) printf '%s' "$OUR_PACK" ;;
	theirs) printf '%s' "$THEIR_PACK" ;;
	*) printf '' ;;
	esac
}
split_csv() {
	OLDIFS="$IFS"
	IFS=','
	set -f
	# shellcheck disable=SC2206
	ARR=($1)
	set +f
	IFS="$OLDIFS"
	i=0
	while [ "$i" -lt ${#ARR[@]} ]; do
		ARR[i]=$(printf '%s' "${ARR[i]}" | tr -d '[:space:]')
		i=$((i + 1))
	done
}

[ -x "$SUSHI" ] || die "sushi binary not found at $SUSHI"
[ -f "$PACK_CHECK" ] || die "missing $PACK_CHECK"
mkdir -p "$OUT_DIR" "$LOGDIR"
VER="$("$SUSHI" --version 2>&1 | grep -m1 -oE 'sushi [0-9]+\.[0-9][^ ]*')"
log "binary ${VER:-?} · sha $(shasum -a 256 "$SUSHI" | cut -c1-12)"

SERVE_PIDS="$(pgrep -f 'sushi serve' 2>/dev/null || true)"
if [ -n "$SERVE_PIDS" ] && [ "$CHECK" != "1" ]; then
	log "serving process STILL RUNNING: $(echo "$SERVE_PIDS" | tr '\n' ' ')"
	die "stop it first: ~/stop-sushi.sh"
fi
[ -n "$SERVE_PIDS" ] && log "serving process running (ok — CHECK=1 does no GPU work)"
DISK_FREE_GB=$(df -k "$OUT_DIR" | awk 'NR==2 {printf "%.0f", $4/1048576}')
WIRED_NOW=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null)

# students must be loadable packs
split_csv "$STUDENTS"
STU=("${ARR[@]}")
for s in "${STU[@]}"; do
	s=$(clean "$s")
	d=$(path_of "$s")
	[ -n "$d" ] || die "STUDENTS must be ours,theirs (got '$s')"
	if ! out=$(python3 "$PACK_CHECK" "$d" 2>&1); then
		log "student '$s' NOT LOADABLE:"
		printf '%s\n' "$out" | sed 's/^/    /'
		die "fix $d before scoring (a half-downloaded pack answers MissingMimoShard)"
	fi
	log "student $s: $(echo "$out" | sed 's/^loadable: //')"
done

# --- discover fixtures ---------------------------------------------------------
NFIX=0
PAIRS=""
for fx in "$OUT_ROOT"/*/*/baseline.json; do
	[ -f "$fx" ] || continue
	fdir=$(dirname "$fx")
	fixkind=$(clean "$(basename "$fdir")")
	pk=$(clean "$(basename "$(dirname "$fdir")")")
	fpack=$(path_of "$pk")
	if [ -z "$fpack" ]; then
		log "fixture dir '$pk' is not ours/theirs — skip"
		continue
	fi
	if ! python3 "$PACK_CHECK" "$fpack" >/dev/null 2>&1; then
		log "fixture $pk/$fixkind: its teacher pack $pk is not loadable right now — skip"
		continue
	fi
	# the fixture must have been captured from the pack it is filed under
	fm=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('model',''))" "$fx" 2>/dev/null)
	case "$fm" in
	*initialed85*) frole=ours ;;
	*beamster*) frole=theirs ;;
	*) frole="?" ;;
	esac
	if [ "$frole" != "$pk" ]; then
		log "fixture $pk/$fixkind: baseline.json says model=$fm, which is not the '$pk' pack — skip"
		continue
	fi
	[ -f "$fdir/capture.done" ] || log "note: $pk/$fixkind has no capture.done marker, using it anyway"
	for student in "${STU[@]}"; do
		student=$(clean "$student")
		[ "$student" = "$pk" ] && [ "$SELF" != "1" ] && continue
		NFIX=$((NFIX + 1))
		PAIRS="$PAIRS$student $pk $fixkind
"
	done
done
[ "$NFIX" -gt 0 ] || die "no usable fixtures under $OUT_ROOT — run scripts/08-capture.sh first"

log "$NFIX comparisons planned:"
printf '%s' "$PAIRS" | while IFS=' ' read -r s f k; do
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

FAILED_LIST="$OUT_DIR/.failures"
: >"$FAILED_LIST"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
printf '%s' "$PAIRS" | while IFS=' ' read -r student fixturepack fixkind; do
	[ -n "${student:-}" ] || continue
	fdir="$OUT_ROOT/$fixturepack/$fixkind"
	[ -d "$fdir" ] || fdir="$OUT_ROOT/$fixturepack/$(basename "$fdir")"
	spack=$(path_of "$student")
	if [ "$student" = "$fixturepack" ]; then
		kv="$KV_SELF"
		name="${fixkind}__self-${student}"
	else
		kv="$KV"
		name="${fixkind}__${fixturepack}-fixture-vs-${student}"
	fi
	json="$OUT_DIR/$name.json"
	logfile="$LOGDIR/compare-${name}-${stamp}.log"
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
		--label "$name" 2>&1 | tee "$logfile"
	rc=${PIPESTATUS[0]}
	if [ "$rc" != "0" ] || [ ! -s "$json" ]; then
		log "$name: compare FAILED rc=$rc (see $logfile)"
		log "if the log blames --kv-quant, re-run: KV=16 scripts/09-compare.sh  (self rows: KV_SELF=16)"
		printf '%s\n' "$name" >>"$FAILED_LIST"
		continue
	fi
	head=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
def g(*names):
    for n in names:
        for k,v in d.items():
            if n in k.lower().replace('_','') and isinstance(v,(int,float)): return v
    return None
print('KLD(all)=%s KLD(first-EOS)=%s top1=%s' % (g('kld'), g('kldtofirsteos','kldfirsteos','kdleos'), g('top1','agreement')))" "$json" 2>/dev/null)
	log "$name: scored -> $json  [$head]"
	printf '%s\n' "$name" >>"$OUT_DIR/.successes"
done

if [ "$RAISED" = "1" ] && [ "${RESTORE_WIRED:-1}" = "1" ]; then
	sudo -n sysctl iogpu.wired_limit_mb=0 >/dev/null 2>&1 && log "iogpu.wired_limit_mb -> 0 (default)"
fi

FAIL=0
if [ -s "$FAILED_LIST" ]; then
	log "FAILED rows:"
	sed 's/^/  /' "$FAILED_LIST"
	FAIL=2
fi
rm -f "$FAILED_LIST"

log "table:"
python3 "$REPO/scripts/10-kld-table.py" "$OUT_DIR" | tee "$OUT_DIR/table.md"
log "written: $OUT_DIR/table.md  (rc $FAIL)"
exit $FAIL
