#!/bin/bash
# 08-capture.sh — capture KLD fixtures (logit fingerprints) from packs.
#
# Run this AFTER the serving process is down (~/stop-sushi.sh, or scale Strata to 0):
# a capture wires the pack's weights to the GPU, and the server already holds them.
#
#   scripts/08-capture.sh                 capture standard4 fixtures from both packs
#   CHECK=1 scripts/08-capture.sh        prerequisites + plan only, no GPU work
#   PROMPTS=ours16 scripts/08-capture.sh use our 16-prompt fixture (fixtures/prompts)
#   PROMPTS=standard4,ours16            both, in that order
#   PACKS=ours scripts/08-capture.sh     one pack only
#   FORCE=1 scripts/08-capture.sh        recapture even if a fixture exists
#
# Output: $OUT_ROOT/<pack>/<fixture>/  (baseline.json + token ids + full-vocab rows)
#         $OUT_ROOT/<pack>/<fixture>/capture-manifest.json  (what produced it)
# Exit: 0 ok, 1 prerequisite failed, 2 a capture failed.
#
# v2: every pack is gated through scripts/pack-check.py (index vs on-disk shards) before
# any GPU work. The first run scored a half-downloaded pack and the engine answered
# `MissingMimoShard`; that gate is why it cannot happen again.

set -u
export REPO="${REPO:-$HOME/Projects/Home/swift-1.5-sushi}"

SUSHI="${SUSHI:-$HOME/sushi-macos-arm64/sushi}"
OUR_PACK="${OUR_PACK:-$HOME/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw}"
THEIR_PACK="${THEIR_PACK:-$HOME/.sushi/models/beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw}"
PACKS="${PACKS:-ours,theirs}"
PROMPTS="${PROMPTS:-standard4}"
OUT_ROOT="${OUT_ROOT:-$HOME/kld}"
LOGDIR="$REPO/logs"
PACK_CHECK="$REPO/scripts/pack-check.py"

# measurement protocol (docs/quality-kld.md: teacher raw + no template, 512 tokens, top-k 10)
TOKENS="${TOKENS:-512}"
TOPK="${TOPK:-10}"
CTX="${CTX:-8192}"
KV_CAPTURE="${KV_CAPTURE:-off}"
GDN_TEACHER="${GDN_TEACHER:-32}"
SSD_BUDGET="${SSD_BUDGET:-12}"
WIRED="${WIRED:-60416}"
MARGIN="${MARGIN:-6}"
CHECK="${CHECK:-0}"
FORCE="${FORCE:-0}"
MANIFEST_ONLY="${MANIFEST_ONLY:-0}" # write manifests for fixtures that already exist, no GPU work
RESTORE_WIRED="${RESTORE_WIRED:-1}"
VOCAB_ROWS_B=$((248320 * 4)) # full-vocab f32 row, bytes

log() { printf '[capture %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() {
	log "ABORT: $*"
	exit 1
}

# split a comma list into the global ARR, no newline contamination (bash 3.2 safe)
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

# keep labels to [A-Za-z0-9._-] so paths, log names and JSON keys stay sane
clean() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }

path_of() {
	case "$1" in
	ours) printf '%s' "$OUR_PACK" ;;
	theirs) printf '%s' "$THEIR_PACK" ;;
	*) printf '' ;;
	esac
}
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

# write_manifest <out> <role> <pack> <fixture> <prompts> <stamp> <config-sha16>
write_manifest() {
	local out="$1" p="$2" d="$3" k="$4" prom="$5" stamp="$6" sha_cfg="$7"
	python3 - "$out/capture-manifest.json" "$p" "$d" "$k" "$prom" "$stamp" \
		"$(basename "$SUSHI")" "$VER" "$(shasum -a 256 "$SUSHI" | cut -c1-16)" "$sha_cfg" \
		"$TOKENS" "$TOPK" "$CTX" "$KV_CAPTURE" "$GDN_TEACHER" "$SSD_BUDGET" "$MARGIN" "$RAM_GB" \
		"$(sysctl -n machdep.cpu.brand_string)" <<'PYMAN'
import json,os,subprocess,sys
manpath,p,d,k,prom,stamp,binn,ver,bsha,cfgsha,tokens,topk,ctx,kv,gdn,ssd,margin,ram,cpu=sys.argv[1:20]
out=os.path.dirname(manpath)   # the fixture dir; manpath is the manifest file inside it
repo=os.environ.get("REPO",os.path.expanduser("~/Projects/Home/swift-1.5-sushi"))
git=subprocess.run("git -C %s rev-parse --short HEAD"%repo,shell=True,capture_output=True,text=True).stdout.strip()
base=json.load(open(os.path.join(out,"baseline.json")))
nll=[q.get("strict_nll_mean") for q in base.get("prompts",[]) if q.get("strict_nll_mean") is not None]
man={"schema":"swift15-kld-capture-v2","role":"self-reference fixture (a pack captured along its own greedy path)",
"teacher_pack":d,"teacher_pack_role":p,"prompts_source":prom,"captured_utc":stamp,
"binary":binn,"binary_version":ver,"binary_sha256_prefix":bsha,"repo_git":git,
"protocol":{"tokens":int(tokens),"top_k":int(topk),"ctx_size":int(ctx),"kv_quant":kv,
  "ssd_budget_gb":int(ssd),"wired_margin_gib":int(margin),"no_template":True,"no_mtp":True,
  "qwen_gdn":int(gdn),"MLX_ENABLE_TF32":"0"},
"fixture_as_recorded":{"schema":base.get("schema"),"kv_cache_format":base.get("kv_cache_format"),
  "inference_profile":base.get("inference_profile"),"prompt_set":base.get("prompt_set"),
  "tokens_per_prompt":base.get("tokens_per_prompt"),"top_k":base.get("top_k"),
  "elapsed_secs":base.get("elapsed_secs"),"prompts":len(base.get("prompts",[])),
  "per_prompt":[{"id":q.get("id"),"prompt_tokens":q.get("prompt_tokens"),
    "generated_tokens":q.get("generated_tokens"),"strict_nll_mean":q.get("strict_nll_mean"),
    "strict_perplexity":q.get("strict_perplexity")} for q in base.get("prompts",[])],
  "mean_strict_nll":round(sum(nll)/len(nll),9) if nll else None},
"machine":{"ram_gb":int(ram),"cpu":cpu,"os":subprocess.run("sw_vers -productVersion",shell=True,capture_output=True,text=True).stdout.strip()},
"model_config_sha256_prefix":cfgsha,
"caveat":"A fixture is model- and arms-specific. Numbers drawn from it are scoped to it; they are not sushi's published 16x512 wikitext readings."}
pm=os.path.join(repo,"fixtures","PROMPTS-MANIFEST.json")
if os.path.exists(pm):
	man["prompts_manifest_sha256_prefix"]=subprocess.run("shasum -a 256 %s"%pm,shell=True,capture_output=True,text=True).stdout.split()[0][:16]
json.dump(man,open(manpath,"w"),indent=2,sort_keys=True)
print("manifest ->",manpath)
PYMAN
}

# --- prerequisites -------------------------------------------------------------
[ -x "$SUSHI" ] || die "sushi binary not found at $SUSHI (set SUSHI=)"
[ -f "$PACK_CHECK" ] || die "missing $PACK_CHECK"
mkdir -p "$OUT_ROOT" "$LOGDIR"
VER="$("$SUSHI" --version 2>&1 | grep -m1 -oE 'sushi [0-9]+\.[0-9][^ ]*')"
[ -n "$VER" ] || VER="unknown"

NEED_GB=0
PLAN=""
SKIP=""
SERVE_PIDS="$(pgrep -f 'sushi serve' 2>/dev/null || true)"
DISK_FREE_GB=$(df -k "$OUT_ROOT" | awk 'NR==2 {printf "%.0f", $4/1048576}')
RAM_GB=$(sysctl -n hw.memsize | awk '{printf "%.0f", $1/1073741824}')
WIRED_NOW=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null)

log "binary ${VER} · sha $(shasum -a 256 "$SUSHI" | cut -c1-12) · ${RAM_GB} GB RAM · wired ${WIRED_NOW} MB · ${DISK_FREE_GB} GB free at $OUT_ROOT"

if [ -n "$SERVE_PIDS" ]; then
	if [ "$CHECK" = "1" ] || [ "$MANIFEST_ONLY" = "1" ]; then
		log "serving process running: $(echo "$SERVE_PIDS" | tr '\n' ' ') — fine, this mode does no GPU work"
	else
		log "serving process STILL RUNNING: $(echo "$SERVE_PIDS" | tr '\n' ' ')"
		die "stop it first: ~/stop-sushi.sh  (a capture needs the GPU memory the server is holding)"
	fi
fi

split_csv "$PACKS"
PK=("${ARR[@]}")
split_csv "$PROMPTS"
PP=("${ARR[@]}")

if [ "$MANIFEST_ONLY" = "1" ]; then
	log "MANIFEST_ONLY=1 — writing manifests for existing fixtures, no GPU work"
	for p in "${PK[@]}"; do
		p=$(clean "$p")
		d=$(path_of "$p")
		[ -n "$d" ] && [ -d "$d" ] || continue
		for k in "${PP[@]}"; do
			k=$(clean "$k")
			out="$OUT_ROOT/$p/$k"
			[ -f "$out/baseline.json" ] || continue
			sha_cfg=$(shasum -a 256 "$d/config.json" | cut -c1-16)
			stamp=$(python3 -c "import os,sys,datetime;print(datetime.datetime.fromtimestamp(os.path.getmtime(sys.argv[1]),datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))" "$out/baseline.json")
			write_manifest "$out" "$p" "$d" "$k" "$(prompts_kind "$k")" "$stamp" "$sha_cfg"
			[ -f "$out/capture.done" ] || touch "$out/capture.done"
			log "$p/$k: manifest refreshed from existing fixture"
		done
	done
	exit 0
fi

for p in "${PK[@]}"; do
	p=$(clean "$p")
	d=$(path_of "$p")
	[ -n "$d" ] || {
		SKIP="$SKIP  '$p': not ours or theirs
"
		continue
	}
	[ -d "$d" ] || {
		SKIP="$SKIP  $p: dir absent ($d)
"
		continue
	}
	if ! "$SUSHI" --version >/dev/null 2>&1; then
		die "sushi binary does not run"
	fi
	if ! out=$(python3 "$PACK_CHECK" "$d" 2>&1); then
		SKIP="$SKIP  $p: NOT LOADABLE
$(echo "$out" | sed 's/^/      /')
"
		continue
	fi
	log "$p: $(echo "$out" | sed 's/^loadable: //')"
	for k in "${PP[@]}"; do
		k=$(clean "$k")
		prom=$(prompts_kind "$k")
		[ "$prom" = "standard4" ] || [ -d "$prom" ] || die "prompt source '$prom' not a directory"
		np=$(count_prompts "$prom")
		[ "$np" -gt 0 ] || die "no *.txt in $prom"
		fgb=$((np * TOKENS * VOCAB_ROWS_B / 1000000000))
		NEED_GB=$((NEED_GB + fgb + 1))
		PLAN="$PLAN  $p  x  $k   ->  $OUT_ROOT/$p/$k   (${np} prompts x ${TOKENS} tokens, ~${fgb} GB)
"
	done
done

if [ -n "$SKIP" ]; then
	log "packs SKIPPED:"
	printf '%s' "$SKIP" | while IFS= read -r l; do [ -n "$l" ] && log "$l"; done
fi
log "fixtures planned:"
printf '%s' "$PLAN" | while IFS= read -r l; do [ -n "$l" ] && log "  $l"; done
log "fixture disk need: ${NEED_GB} GB (free ${DISK_FREE_GB} GB)"
[ "$DISK_FREE_GB" -gt $((NEED_GB + 30)) ] || die "need ${NEED_GB} GB + 30 GB headroom, only ${DISK_FREE_GB} GB free"

if [ "$CHECK" = "1" ]; then
	log "CHECK=1 — plan validated, nothing captured. Run:  scripts/08-capture.sh"
	exit 0
fi

[ "$NEED_GB" != "0" ] || die "nothing to capture (every pack skipped — fix the reasons above)"

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
	p=$(clean "$p")
	d=$(path_of "$p")
	[ -n "$d" ] && [ -d "$d" ] || continue
	python3 "$PACK_CHECK" "$d" >/dev/null 2>&1 || continue
	for k in "${PP[@]}"; do
		k=$(clean "$k")
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
		logfile="$LOGDIR/capture-${p}-${k}-${stamp}.log"
		log "$p/$k: purging memory, capturing ${TOKENS} tokens/prompt, label ${p}-${k}"
		sudo -n purge >/dev/null 2>&1 || log "purge skipped (sudo -n failed)"
		MLX_ENABLE_TF32=0 "$SUSHI" kld capture \
			--model "$d" \
			--prompts "$prom" \
			--out "$out" \
			--tokens "$TOKENS" \
			--top-k "$TOPK" \
			--ctx-size "$CTX" \
			--kv-quant "$KV_CAPTURE" \
			--qwen-gdn "$GDN_TEACHER" \
			--ssd-budget-gb "$SSD_BUDGET" \
			--wired-margin-gib "$MARGIN" \
			--no-template \
			--no-mtp \
			--label "${p}-${k}" 2>&1 | tee "$logfile"
		rc=${PIPESTATUS[0]}
		# verify the fixture is what we asked for before trusting it
		ok=$(python3 - "$out" "$TOKENS" "${p}-${k}" <<'PY'
import json,os,sys
out,tokens,label=sys.argv[1:4]
try:
    b=json.load(open(os.path.join(out,"baseline.json")))
except Exception as e:
    print("BAD no baseline.json: %s" % e); sys.exit()
ps=b.get("prompts",[])
rows=b.get("tokens_per_prompt")
bad=[]
sizes=[]
for pr in ps:
    lg=os.path.join(out,pr.get("dir",""),"logits.f32")
    if not os.path.exists(lg):
        bad.append(pr.get("id") + ":no logits"); continue
    sz=os.path.getsize(lg); sizes.append(sz)
    want=int(tokens)*248320*4
    if abs(sz-want) > 2*248320:   # allow a little slack for top-k/extra rows
        bad.append("%s:%d bytes != %d expected" % (pr.get("id"), sz, want))
prob=[]
if (b.get("label") or "").strip() != label.strip(): prob.append("label %r != %r" % (b.get("label"), label))
if not ps: prob.append("prompts empty")
if rows != int(tokens): prob.append("tokens_per_prompt %s != %s" % (rows, tokens))
if bad: prob.append("logits: " + "; ".join(bad[:3]))
print("OK" if not prob else "BAD " + "; ".join(prob))
PY
)
		if [ "$rc" != "0" ] || [ "$ok" != "OK" ]; then
			log "$p/$k: capture FAILED rc=$rc fixture=$ok (see $logfile)"
			log "if the log blames --kv-quant '$KV_CAPTURE', re-run: KV_CAPTURE=16 scripts/08-capture.sh"
			log "if it blames wired memory, re-run: MARGIN=8 SSD_BUDGET=8 scripts/08-capture.sh"
			FAIL=2
			continue
		fi
		touch "$out/capture.done"
		write_manifest "$out" "$p" "$d" "$k" "$prom" "$stamp" "$sha_cfg"
		log "$p/$k: captured, $(du -sh "$out" | cut -f1) in $out"
	done
done

if [ "$RESTORE_WIRED" = "1" ] && [ "$RAISED" = "1" ]; then
	sudo -n sysctl iogpu.wired_limit_mb=0 >/dev/null 2>&1 && log "iogpu.wired_limit_mb -> 0 (default)"
fi
log "done (rc $FAIL). Next: scripts/09-compare.sh"
exit $FAIL
