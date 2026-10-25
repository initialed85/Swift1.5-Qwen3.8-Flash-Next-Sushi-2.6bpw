#!/bin/bash
# 08-capture.sh — capture KLD fixtures (logit fingerprints) from packs.
#
# Run this AFTER the serving process is down (~/stop-sushi.sh, or scale Strata to 0):
# a capture wires the pack's weights to the GPU, and the server already holds them.
#
#   scripts/08-capture.sh                 capture standard4 fixtures from both packs
#   CHECK=1 scripts/08-capture.sh        prerequisites + plan only, no GPU work
#   PROMPTS=ours16 scripts/08-capture.sh use our 16-prompt fixture (fixtures/prompts)
#   PROMPTS=standard4,ours16 scripts/08-capture.sh   both, in that order
#   PACKS=ours scripts/08-capture.sh     one pack only
#   FORCE=1 scripts/08-capture.sh        recapture even if a fixture exists
#
# Output: $OUT_ROOT/<pack>/<fixture>/  (baseline.json + token ids + full-vocab rows)
#         $OUT_ROOT/<pack>/<fixture>/capture-manifest.json  (what produced it)
# Exit: 0 ok, 1 prerequisite failed, 2 a capture failed.

set -u
export REPO="${REPO:-$HOME/Projects/Home/swift-1.5-sushi}"

SUSHI="${SUSHI:-$HOME/sushi-macos-arm64/sushi}"
OUR_PACK="${OUR_PACK:-$HOME/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw}"
THEIR_PACK="${THEIR_PACK:-$HOME/.sushi/models/beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw}"
PACKS="${PACKS:-ours,theirs}"
PROMPTS="${PROMPTS:-standard4}"
OUT_ROOT="${OUT_ROOT:-$HOME/kld}"
REPO="${REPO:-$HOME/Projects/Home/swift-1.5-sushi}"
LOGDIR="$REPO/logs"

# measurement protocol (docs/quality-kld.md: teacher raw+no template, 512 tokens, top-k 10)
TOKENS="${TOKENS:-512}"
TOPK="${TOPK:-10}"
CTX="${CTX:-8192}"
KV_CAPTURE="${KV_CAPTURE:-off}"
SSD_BUDGET="${SSD_BUDGET:-12}"
WIRED="${WIRED:-60416}"
MARGIN="${MARGIN:-6}"
CHECK="${CHECK:-0}"
FORCE="${FORCE:-0}"
RESTORE_WIRED="${RESTORE_WIRED:-1}"
VOCAB_ROWS_B=$((248320 * 4)) # full-vocab f32 row, bytes

log() { printf '[capture %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() {
	log "ABORT: $*"
	exit 1
}
path_of() { [ "$1" = "ours" ] && printf '%s' "$OUR_PACK" || printf '%s' "$THEIR_PACK"; }
prompts_kind() {
	case "$1" in
	standard4) printf 'standard4' ;;
	ours16) printf '%s/fixtures/prompts' "$REPO" ;;
	*) printf '%s' "$1" ;;
	esac
}
count_prompts() {
	[ "$1" = "standard4" ] && { printf 4; return; }
	ls "$1"/*.txt 2>/dev/null | wc -l | tr -d ' '
}

# --- prerequisites -------------------------------------------------------------
[ -x "$SUSHI" ] || die "sushi binary not found at $SUSHI (set SUSHI=)"
mkdir -p "$OUT_ROOT" "$LOGDIR"
NEED_GB=0
PLAN=""
IFS=',' read -r -d '' -a PK <<<"$PACKS" || true
IFS=',' read -r -d '' -a PP <<<"$PROMPTS" || true

SERVE_PIDS="$(pgrep -f 'sushi serve' 2>/dev/null || true)"
DISK_FREE_GB=$(df -k "$OUT_ROOT" | awk 'NR==2 {printf "%.0f", $4/1048576}')
RAM_GB=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')
WIRED_NOW=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null)

VER="$("$SUSHI" --version 2>&1 | grep -m1 -oE 'sushi [0-9]+\.[0-9][^ ]*')"
[ -n "$VER" ] || VER="unknown"
log "binary ${VER:-?} · sha $(shasum -a 256 "$SUSHI" | cut -c1-12) · ${RAM_GB} GB RAM · wired ${WIRED_NOW} MB · ${DISK_FREE_GB} GB free at $OUT_ROOT"

if [ -n "$SERVE_PIDS" ]; then
	log "serving process STILL RUNNING: $(echo "$SERVE_PIDS" | tr '\n' ' ')"
	die "stop it first: ~/stop-sushi.sh  (a capture needs the GPU memory the server is holding)"
fi

for p in "${PK[@]}"; do
	d=$(path_of "$p")
	[ -n "$d" ] || die "PACKS must be ours,theirs (got '$PACKS')"
	[ -d "$d" ] || {
		log "$p: pack dir absent ($d) — will skip"
		continue
	}
	nf=$(find "$d" -type f | wc -l | tr -d ' ')
	sz_gb=$(du -sk "$d" | awk '{printf "%.0f", $1/1048576}')
	inc=$(find "$d/.cache" -name '*.incomplete' 2>/dev/null | wc -l | tr -d ' ')
	if [ "$inc" != "0" ]; then
		log "$p: download not finished — $inc .incomplete part files, ${sz_gb} GB so far — will skip"
		continue
	fi
	[ "$p" = "ours" ] && [ "$nf" -lt 60 ] && die "$p: only $nf files in $d — pack looks incomplete"
	[ "$p" = "theirs" ] && [ "$nf" -lt 200 ] && {
		log "$p: only $nf files — beamster's repo has 218; download incomplete? — will skip"
		continue
	}
	[ "$sz_gb" -lt 60 ] && die "$p: ${sz_gb} GB looks too small for a 2.6bpw pack (~74-79 GB)"
	log "$p: $nf files, ${sz_gb} GB — $d"
	for k in "${PP[@]}"; do
		prom=$(prompts_kind "$k")
		[ "$prom" = "standard4" ] || [ -d "$prom" ] || die "prompt source '$prom' not a directory"
		np=$(count_prompts "$prom")
		[ "$np" -gt 0 ] || die "no *.txt in $prom"
		fgb=$((np * TOKENS * VOCAB_ROWS_B / 1000000000))
		NEED_GB=$((NEED_GB + fgb + 1))
		PLAN="$PLAN
  $p  x  $k   ->  $OUT_ROOT/$p/$k   (${np} prompts x ${TOKENS} tokens, ~${fgb} GB)"
	done
done

log "fixtures planned:${PLAN}"
log "fixture disk need: ${NEED_GB} GB (free ${DISK_FREE_GB} GB)"
[ "$DISK_FREE_GB" -gt $((NEED_GB + 30)) ] || die "need ${NEED_GB} GB + 30 GB headroom, only ${DISK_FREE_GB} GB free"

if [ "$CHECK" = "1" ]; then
	log "CHECK=1 — plan validated, nothing captured. Run:  scripts/08-capture.sh"
	exit 0
fi

[ "$NEED_GB" != "0" ] || die "nothing to capture (both packs skipped?)"

RAISED=0
if [ "$WIRED_NOW" != "$WIRED" ]; then
	if sudo -n sysctl "iogpu.wired_limit_mb=$WIRED" >/dev/null 2>&1; then
		RAISED=1
		log "iogpu.wired_limit_mb -> $WIRED"
	else
		die "cannot set iogpu.wired_limit_mb=$WIRED (sudo -n failed); run: sudo sysctl iogpu.wired_limit_mb=$WIRED"
	fi
fi

FAIL=0
for p in "${PK[@]}"; do
	d=$(path_of "$p")
	[ -d "$d" ] || continue
	nf=$(find "$d" -type f | wc -l | tr -d ' ')
	inc=$(find "$d/.cache" -name '*.incomplete' 2>/dev/null | wc -l | tr -d ' ')
	{ [ "$p" = "theirs" ] && { [ "$nf" -lt 200 ] || [ "$inc" != "0" ]; }; } && continue
	for k in "${PP[@]}"; do
		prom=$(prompts_kind "$k")
		[ "$prom" = "standard4" ] || [ -d "$prom" ] || continue
		out="$OUT_ROOT/$p/$k"
		if [ -f "$out/capture.done" ] && [ "$FORCE" != "1" ]; then
			log "$p/$k already captured ($out) — FORCE=1 to recapture"
			continue
		fi
		mkdir -p "$out"
		stamp=$(date -u +%Y%m%dT%H%M%SZ)
		sha_cfg=$(shasum -a 256 "$d/config.json" | cut -c1-16)
		log "$p/$k: purging memory, capturing ${TOKENS}x tokens with label $p-$k"
		sudo -n purge >/dev/null 2>&1 || log "purge skipped (sudo -n failed)"
		MLX_ENABLE_TF32=0 "$SUSHI" kld capture \
			--model "$d" \
			--prompts "$prom" \
			--out "$out" \
			--tokens "$TOKENS" \
			--top-k "$TOPK" \
			--ctx-size "$CTX" \
			--kv-quant "$KV_CAPTURE" \
			--qwen-gdn 32 \
			--ssd-budget-gb "$SSD_BUDGET" \
			--wired-margin-gib "$MARGIN" \
			--no-template \
			--no-mtp \
			--label "${p}-${k}" 2>&1 | tee "$LOGDIR/capture-${p}-${k}-${stamp}.log"
		rc=${PIPESTATUS[0]}
		if [ "$rc" != "0" ] || [ ! -f "$out/baseline.json" ]; then
			log "$p/$k: capture FAILED rc=$rc (see $LOGDIR/capture-${p}-${k}-${stamp}.log)"
			log "if the log blames --kv-quant '$KV_CAPTURE', re-run: KV_CAPTURE=16 scripts/08-capture.sh"
			FAIL=2
			continue
		fi
		touch "$out/capture.done"
		prom_sha=$(cd "$REPO" && find fixtures/prompts -name '*.txt' -exec shasum -a 256 {} \; 2>/dev/null | sort | shasum -a 256 | cut -c1-16)
		python3 - "$out/capture-manifest.json" "$p" "$d" "$k" "$prom" "$stamp" "$(basename "$SUSHI")" \
			"$VER" "$(shasum -a 256 "$SUSHI" | cut -c1-16)" "$sha_cfg" \
			"$TOKENS" "$TOPK" "$CTX" "$KV_CAPTURE" "$SSD_BUDGET" "$MARGIN" "$RAM_GB" "$(sysctl -n machdep.cpu.brand_string)" <<'PY'
import json,sys,os,subprocess
out,p,d,k,prom,stamp,binn,ver,bsha,cfgsha,tokens,topk,ctx,kv,ssd,margin,ram,cpu=sys.argv[1:19]
git=subprocess.run("git -C %s rev-parse --short HEAD"%os.environ.get("REPO",os.path.expanduser("~/Projects/Home/swift-1.5-sushi")),
	shell=True,capture_output=True,text=True).stdout.strip()
man={"schema":"swift15-kld-capture-v1","role":"self-reference fixture (a pack captured along its own greedy path)",
"teacher_pack":d,"teacher_pack_role":p,"prompts_source":prom,"captured_utc":stamp,
"binary":binn,"binary_version":ver,"binary_sha256_prefix":bsha,"repo_git":git,
"protocol":{"tokens":int(tokens),"top_k":int(topk),"ctx_size":int(ctx),"kv_quant":kv,
  "ssd_budget_gb":int(ssd),"wired_margin_gib":int(margin),"no_template":True,"no_mtp":True,
  "qwen_gdn":32,"MLX_ENABLE_TF32":"0"},
"machine":{"ram_gb":int(ram),"cpu":cpu,"os":subprocess.run("sw_vers -productVersion",shell=True,capture_output=True,text=True).stdout.strip()},
"model_config_sha256_prefix":cfgsha,
"caveat":"A fixture is model- and arms-specific. Numbers from this fixture are scoped to it; they are not the published 16x512 wikitext readings."}
if os.path.exists(os.path.join(os.environ.get("REPO",os.path.expanduser("~/Projects/Home/swift-1.5-sushi")),"fixtures/PROMPTS-MANIFEST.json")):
	man["prompts_manifest_sha256_prefix"]=subprocess.run(
		"shasum -a 256 %s/fixtures/PROMPTS-MANIFEST.json"%os.environ.get("REPO",os.path.expanduser("~/Projects/Home/swift-1.5-sushi")),
		shell=True,capture_output=True,text=True).stdout.split()[0][:16]
json.dump(man,open(out,"w"),indent=2,sort_keys=True)
print("manifest ->",out)
PY
		log "$p/$k: captured, $(du -sh "$out" | cut -f1) in $out"
	done
done

if [ "$RESTORE_WIRED" = "1" ] && [ "$RAISED" = "1" ]; then
	sudo -n sysctl iogpu.wired_limit_mb=0 >/dev/null 2>&1 && log "iogpu.wired_limit_mb -> 0 (default)"
fi
log "done (rc $FAIL). Next: scripts/09-compare.sh"
exit $FAIL
