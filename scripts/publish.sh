#!/usr/bin/env bash
# publish.sh — push the pack + card to Hugging Face as a model repo.
#
# The 74 GB of weights stay where sushi wants them (~/.sushi/models/…); this uploads them from
# there and uploads the card files from the project dir. No 74 GB staging copy.
#
#   usage: publish.sh <pack_dir> [repo]
#   env:   REPO=initialed85/<packname>  PRIVATE=1  DRY=1  CARD_DIR=<project dir>  COMMIT_MSG
#
# Card files (from CARD_DIR): README.md LICENSE LICENSE-QWEN NOTICE NOTICE-CONVERSION.md
# .gitattributes SHA256SUMS.txt provenance.json measurements.json scripts/ docs/
set -euo pipefail

PACK="${1:?usage: publish.sh <pack_dir> [repo]}"; PACK="${PACK/#\~/$HOME}"
NAME="$(basename "$PACK")"
REPO="${2:-${REPO:-initialed85/$NAME}}"
CARD_DIR="${CARD_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
PRIVATE="${PRIVATE:-1}"
DRY="${DRY:-0}"
COMMIT_MSG="${COMMIT_MSG:-publish $NAME: EXL3 2.625bpw pack + card, scripts, licences}"
HF="${HF:-hf}"

command -v "$HF" >/dev/null || { echo "need huggingface_hub CLI: pip install -U 'huggingface_hub[cli]'"; exit 1; }
"$HF" auth whoami >/dev/null 2>&1 || { echo "run '$HF auth login' first"; exit 1; }
[[ -d "$PACK" && -f "$PACK/model.safetensors.index.json" ]] || { echo "pack incomplete at $PACK"; exit 1; }

# Refuse to publish an unverified pack: this is 74 GB of other people's download time.
if [[ "$DRY" != 1 ]]; then
  python3 "$(dirname "$0")/04-verify-pack.py" "$PACK" >/dev/null || {
    echo "FAIL: pack fails 04-verify-pack.py; not publishing"; exit 1; }
fi

# Refuse to publish without the licence chain, which the licences require.
for f in LICENSE LICENSE-QWEN NOTICE NOTICE-CONVERSION.md README.md .gitattributes; do
  [[ -f "$CARD_DIR/$f" ]] || { echo "FAIL: $CARD_DIR/$f missing (licence/attribution is mandatory)"; exit 1; }
done

CARD_FILES=(README.md LICENSE LICENSE-QWEN NOTICE NOTICE-CONVERSION.md .gitattributes
            SHA256SUMS.txt provenance.json measurements.json)
CARD_DIRS=(scripts docs logs)

# A filename carrying a control character (this bit us: two capture logs whose names embedded newlines,
# because an older 08-capture.sh built the name from an unsanitised label) uploads fine but is
# unquotable on the Hub and invisible to most listing tools. Refuse rather than ship it.
bad_names=$(python3 - "$CARD_DIR" "${CARD_DIRS[@]}" <<'PY'
import os, sys
root, subdirs = sys.argv[1], sys.argv[2:]
bad = []
for d in subdirs:
    for dirpath, _, files in os.walk(os.path.join(root, d)):
        for f in files:
            if any(ord(c) < 32 or ord(c) > 126 for c in f):
                bad.append(os.path.relpath(os.path.join(dirpath, f), root))
print("\n".join(bad))
PY
)
if [[ -n "$bad_names" ]]; then
  echo "FAIL: filenames with control characters under $CARD_DIR (they upload, then are unquotable on the Hub):"
  printf '  %s\n' $bad_names
  echo "rename them first (the sane name is the same string with the control char replaced by '-')"
  exit 1
fi

echo "repo : $REPO  $( [[ "$PRIVATE" == 1 ]] && echo '(private)' ) "
echo "card : $CARD_DIR"
echo "pack : $PACK ($(du -sh "$PACK" | cut -f1), $(find "$PACK" -type f | wc -l | tr -d ' ') files)"

if [[ "$DRY" == 1 ]]; then
  echo "DRY: would create repo, upload card files ${CARD_FILES[*]} ${CARD_DIRS[*]},"
  echo "     then $(find "$PACK" -type f | wc -l | tr -d ' ') pack files to the repo root."
  exit 0
fi

# 1) create the repo (private by default — flip with hf repos settings when you're happy with it)
# The existence probe MUST be authenticated: this repo is private, so an unauthenticated probe gets
# 401, the guard concludes "doesn't exist", and `repos create` then answers 409 Conflict. Same reason
# the verify block below sends Authorization.
TOK="$("$HF" auth token)"
repo_exists() { curl -sf -H "Authorization: Bearer $TOK" "https://huggingface.co/api/models/$REPO" >/dev/null; }
if ! repo_exists; then
  echo "probing says $REPO is not there (or the token cannot see it) — trying create, a 409 means it already exists"
  if [[ "$PRIVATE" == 1 ]]; then
    "$HF" repos create "$REPO" --type model --private || echo "create failed; if it said 409 Conflict the repo is already yours, continuing"
  else
    "$HF" repos create "$REPO" --type model || echo "create failed; if it said 409 Conflict the repo is already yours, continuing"
  fi
fi

# 2) card + licences + provenance + scripts
for f in "${CARD_FILES[@]}"; do
  [[ -f "$CARD_DIR/$f" ]] && { echo "card  $f"; "$HF" upload "$REPO" "$CARD_DIR/$f" "$f" --repo-type model; }
done
for d in "${CARD_DIRS[@]}"; do
  [[ -d "$CARD_DIR/$d" ]] && { echo "card  $d/"; "$HF" upload "$REPO" "$CARD_DIR/$d" "$d" --repo-type model; }
done

# 3) weights, one file at a time (Xet/LFS; ~40 min at 30 MB/s up on the hardline)
#
# The pack root carries the SOURCE repo's own README.md, LICENSE, LICENSE-QWEN and NOTICE.
# The licence trio is byte-identical to the copies we publish from CARD_DIR, so skip it here.
# The source README must NOT land at the repo root — it would overwrite our card — so it ships
# as README-SOURCE.md, verbatim, for attribution.
cd "$PACK"
total=$(find . -type f ! -name '.DS_Store' | wc -l | tr -d ' ')
i=0
for f in $(find . -type f ! -name '.DS_Store' | sort); do
  i=$((i+1))
  rel="${f#./}"
  case "$rel" in
    LICENSE|LICENSE-QWEN|NOTICE) echo "pack  [$i/$total] $rel (skipped: card copy published at root)"; continue ;;
    README.md) rel="README-SOURCE.md"; echo "pack  [$i/$total] $rel (was README.md at pack root: keeps our card)" ;;
  esac
  echo "pack  [$i/$total] $rel ($(du -sh "$f" | cut -f1))"
  "$HF" upload "$REPO" "$f" "$rel" --repo-type model --commit-message "$COMMIT_MSG"
done

# 4) prove it landed
echo "== verifying the repo tree"
HF_TOKEN="$TOK" python3 - "$REPO" "$PACK" <<'PY'
import json, sys, os, urllib.request
repo, pack = sys.argv[1], sys.argv[2]
tok = os.environ["HF_TOKEN"]
# Authorization is mandatory: the pack repo is PRIVATE, so an unauthenticated tree call is a 401
# and the whole push looks like it failed when every byte is already up.
def api(u):
    return json.load(urllib.request.urlopen(urllib.request.Request(
        u, headers={"Authorization": f"Bearer {tok}", "User-Agent": "publish/1.0"})))
tree = api(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true&full=true")
remote = {e["path"]: e.get("size", 0) for e in tree if e["type"] == "file"}
import os
local = {}
for root, _, files in os.walk(pack):
    for f in files:
        if f == ".DS_Store": continue
        p = os.path.relpath(os.path.join(root, f), pack)
        local[p] = os.path.getsize(os.path.join(root, f))
missing = [p for p in local if ("README-SOURCE.md" if p == "README.md" else p) not in remote]
mismatch = [p for p in local if p != "README.md" and ("README-SOURCE.md" if p == "README.md" else p) in remote and local[p] != remote["README-SOURCE.md" if p == "README.md" else p]]
print(f"pack files: {len(local)}   repo files: {len(remote)}   missing: {len(missing)}   size mismatch: {len(mismatch)}")
for m in missing[:15]: print("   MISSING", m)
for m in mismatch[:15]: print("   SIZE", m, local[m], remote[m])
print(f"https://huggingface.co/{repo}")
print("weights OK" if not missing and not mismatch else "INCOMPLETE — re-run publish.sh (it resumes per-file)")
PY
echo
echo "flip public when ready:  hf repos settings $REPO --no-private"
echo "note: sushi 'pull' only works for the beamster org; advertise 'run' and 'hf download'."
