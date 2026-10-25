# Build log — how this pack was made, in the order it happened

Long-form companion to [`README.md`](README.md). Everything here is from the actual logs of
2026-10-24 on a 64 GB Apple M2 Max MacBook Pro: `~/swift15-dl.log`, `~/swift15-pipeline.log`,
`~/sushi-convert.log`, `~/sushi-supervisor.log`, `~/sushi-smoke.log`, `~/sushi-codetest.log`.
Machine-readable versions: [`measurements.json`](measurements.json), [`provenance.json`](provenance.json).


## Why this pack exists

You like `Swift1.5-Qwen3.8-Flash-Next` running on Strata (llama.cpp + GGUF). You also have a
64 GB M2 Max MacBook Pro that runs [sushi](https://github.com/beamivalice/sushi) — an MLX-based native
inference engine with its own quantization format (EXL3) and its own converter.
beamster publishes packs for the *base* Qwen model, not for Swift. This is the Swift pack,
built locally, at the same rate and encoder as beamster's recommended 64 GB tier.

Decisions worth keeping:

| decision | why |
|---|---|
| Build from the **BF16 HF repo**, not the GGUF | `sushi convert exl3` accepts **BF16 HF checkpoints only**; it refuses GGUF/quantized input. The llama.cpp GGUF route (`ukisai/Swift1.5-…-GGUF`) stays on the other cluster as a fallback. |
| Match beamster's recipe exactly (`k=2.625`, `mcg`, `w=15`) | so the pack is structurally comparable to the released 2.6bpw tier and lands in sushi's "recommended for 64 GB" tier |
| Do **not** use `--factor-precision 32` | GPU float32 factors are faster but change pack bytes → breaks the comparison, and it wants GPU RAM the search already owns |
| Do **not** run while sushi is serving | a server wires ~50 GB and owns the GPU the trellis search needs; converting under it OOMs |
| Keep `--calibration` unset | sushi's built-in 64k prose+code mix is what the released packs' KLD numbers were framed against; a custom corpus makes the pack incomparable to everything else |
| Leave serving + model swap as a human decision | server start needs `sudo sysctl iogpu.wired_limit_mb=…`, binds `0.0.0.0:8088`, wires ~46 GB |

## Hardware and budget

```
MacBook Pro (Mac14,6) — Apple M2 Max, 12 CPU cores (8P+4E), 38 GPU cores, 64 GB (hw.memsize 68719476736)
macOS 26.2 (25D2142), arm64, 1 TB APFS volume (994.7 GB container)
sushi 1.3.0 — MLX 0.32.3, mlx-c 56b2d39        (sushi update --check: up to date)
iogpu.wired_limit_mb = 60416                    (persistent sysctl, set once, survives reboot)
disk: 994.7 GB total, 524 GB free at start
source model: ukisai/Swift1.5-Qwen3.8-Flash-Next, arch qwen4_exp
  48 layers · 512 routed experts · 10 experts/token · hidden 2560 · vocab 248320
  MTP head present (31 MTP tensors in the index) · vision tower present (Qwen3-VL ViT)
```

Disk budget arithmetic that matters:

```
free at start                        524 GB
- 360 GB source                       164 GB left
- ~41 GB of pack mid-build (trunk + ngram + 40 layers)
  minimum observed during convert     111 GB free
+ delete source after smoke test      451 GB free
net cost of the whole exercise          +74 GB
peak requirement                        401 GB   ← the binding constraint, not the final size
```

Rule for a 64 GB Mac: **start with ≥ 400 GB free, keep ≥ 60 GB free at all times.** The tightest
moment is the last phase (MTP head + lm_head + embed), which peaked at 51.7/64 GB RAM used and
111 GB disk free. RAM headroom matters more than disk here: the M2 Max's 38 GPU cores are plenty
for the search, and 64 GB is the ceiling the whole build lives under.

## Phase 1 — get the source (1 h 50 m)

```bash
scripts/01-download-source.sh ~/swift15-src          # 131 shards, 360.04 GB
```

Excluded by intent: `benchmarks/gpqa-diamond-20260921.json` (1.5 MB, the converter never reads
it), the demo `.mp4`, the banner `.png` — no: those two *were* kept, because they travel with the
pack as attribution. Everything else came down. 4 workers, resumable, `.incomplete` → published
per shard, so a dropped connection costs a shard, not the download.

Network: ~12 MB/s on WiFi, ~33 MB/s on the hardline ethernet (`en7`), 59 MB/s average as
`hf download` streams. The move that mattered was switching to ethernet *before* starting; a
WiFi download of 360 GB is 8+ hours and the whole job is 9 h 45 m.

Then prove it (`scripts/02-verify-source.py`): 148/148 files present, sizes exact against the HF
tree API, content hashes on the trusted small files (git blob SHA-1) — `config.json`,
`model.safetensors.index.json`, `generation_config.json`, `chat_template.jinja`,
`tokenizer_config.json`, `vocab.json`, `merges.txt`. Zero mismatches.

The tree API gives the hashes for free: `lfs.oid` is SHA-256 for LFS files; `oid` is the git blob
SHA-1 (`SHA1("blob <len>\0" + bytes)`) for ordinary files. `--deep` hashes all 131 shards
(~30 min of disk read) if you want the full 360 GB provenven.

## Phase 2 — convert (7 h 55 m)

```bash
scripts/03-convert.sh ~/swift15-src ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw
```

The converter's own stages, from the log:

| time | stage | artifact |
|---|---|---|
| 15:45:41 | tokenizer load, vocab 248 320, chat template | — |
| 15:45–15:47 | built-in calibration mix, 65 536 tokens (14 chunks auto) | `calib_sha256 7f2a5b14…` |
| 15:47–15:54 | dense/trunk → 8-bit affine, group 64 | `model-trunk-00000..2.safetensors`, 6.32 GB on disk (2 628 tensors: embed, lm_head, trunk linears, vision tower, MTP fc/norm) |
| 15:54–16:04 | n-gram embedding table → 4-bit affine, group 32 | `ngram_table.bin`, 32.0 GB (29.8 GiB) |
| 16:04–23:35 | 48 routed-expert layers → EXL3 2.625 bpw, `mcg`, `w=15` | `layer-0..47.safetensors`, 836 MB each |
| 23:35–23:44 | MTP head, index | `mtp-0.safetensors` (836 MB — the MTP layer's routed experts, same 9-tensor shape as a decoder layer), `model.safetensors.index.json` |
| 23:46:51 | `ALL DONE` | 74 GB pack, 451 GB free (after source delete) |

Per layer, 48 samples, medians: `search 354.4 s`, `scale 88.2 s`, `hessian 81.7 s`,
`prep 79.3 s`, `feedback 38.2 s`, `read 1.5 s`, `wait 2.2 s`, `pack 0.4 s`, `factor 0.0 s`
→ **646 s/layer**, **9.4 min/layer wall**, max 9.5 min (layer 0, cold), total 8.62 h of stage
time inside a 7.55 h wall clock (stages overlap: capture/convert of layer N+1 runs under
the search of layer N).

`search` is 55 % of the work. It is the trellis / codebook-window search that chooses the
per-group codebook for `mcg` at window 15 — memory-bound (whole 512-expert layer resident,
29–33 GB RSS) and the reason the flags' default CPU float64 path is the honest one.

Non-fatal noise seen in the log, worth knowing so it doesn't panic you:

```
[mlx] Thread group size (1024) is larger than the maximum allowed by the GPU device (1024)
[mem] MLX buffer-pool cap 4096 MB (was 62259 MB)
[ngram] 5169087680B for the draft table exceeds the 6442450944B draft cap; draft table dropped
[ngram] speculative decoding engaged: mode=trellis table=0B vocab=4096
[convert] imatrix skipped (ngram table present)
[convert] calibration text: built-in standard mix (64k prose+code)
[convert] calib chunks: auto (14 chunks)
[convert] factor precision: auto (affine: CPU float64; EXL3: CPU float64)
[convert] factor precision: auto (CPU float64: calib in RAM)
[convert] expert windows: auto (window 32)
[convert] expert windows: capped (window 32 -> 15)
```

`expert windows: capped (32 -> 15)` is the `--window 15` flag being applied to the auto
default. `ngram … draft table dropped` is about the *draft* table during conversion, not the
pack's 32 GB n-gram table: the pack ships it and sushi engages it at serve time.

## Phase 3 — the unattended part

`scripts/supervise.sh` is what finished the job while nobody was awake to press enter. Design:

```
loop:
  convert running?  log layers/48, size, free  → sleep 300 → continue
  index.json + config.json + 48/48 layers?     → COMPLETE, break
  a sushi server is running?                   → NEEDS HUMAN, exit (never convert under a server)
  free < 60 GB?                                → NEEDS HUMAN, exit
  resumes > 3?                                 → NEEDS HUMAN, exit  (no thrash, no disk eaten)
  else re-launch 03-convert.sh --resume, sleep 120
integrity: 04-verify-pack.py                   → fail = leave source for forensics, exit
smoke:     05-smoke-test.sh                    → fail = leave source for forensics, exit
rm -rf source                                  → only after BOTH gates green
```

Single-instance via lockdir (`mkdir` as a lock), status mirrored to `~/sushi-pack-STATUS.txt`
so a glance from a shell tells you where it is, log lines appended not overwritten.

The order is deliberate: **the source is deleted last**, after integrity *and* generation pass.
A pack that fails smoke keeps its 360 GB source so the run is reproducible; a pack that passes
costs you nothing more.

## Failures we hit (each one became a guard in the scripts)

**1. `--experts-k 2.6` → `error: BadFlagValue: --experts-k expects <float>; use 'help' to list valid choices`**

The first launch died in seconds. "2.6bpw" is sushi's marketing name for **21⁄8 = 2.625**; the
flag accepts a 1/8 grid (2.5, 2.625, 2.75, …). `sushi convert exl3 --experts-k help` prints it.
`03-convert.sh` now reads the grid **from the binary** and refuses a value that isn't on it
before burning an hour of setup.

**2. The integrity check reported 52 defective shards on a healthy pack**

```
BAD ('model-00005-of-00048.safetensors', "readfail", "'data_offsets'")
```

A safetensors header contains `__header__` **and `__metadata__`**, neither of which is a tensor
and neither of which has `data_offsets`. The first version skipped `__header__` only. The pack
was fine; the checker was wrong. `04-verify-pack.py` skips both keys and also checks payload
bytes vs on-disk bytes and index closure (every index entry → an existing shard).

**3. `MissingMimoShard` from a half-downloaded pack**

The first fixture capture crashed with `error: MissingMimoShard` a few seconds in — after the
tokenizer loaded and the expert streamer came up, before any prompt was scored. The pack it was
pointed at was `beamster/Qwen3.8-Flash-Next-Sushi-2.6bpw` mid-download: 26 GB of 79 GB on disk.
The index named 203 shards; most were not there yet.

The actual bug was mine and it is worth writing down because it is invisible in bash: splitting a
list with `IFS=',' read -r -d '' -a ARR <<<"$LIST"` makes `read` consume the here-string *including
its trailing newline*, so the last element was `"theirs\n"`. Every `[[ $p == theirs ]]` test then
silently failed, the incomplete-pack skip was bypassed, and directories and log files were created
with newlines in their names. Fixed with an explicit `split_csv()` and a `clean()` that restricts
labels to `[A-Za-z0-9._-]`, and `scripts/pack-check.py` now gates every pack — index closure,
shard bytes vs `total_size`, no `.incomplete` parts, n-gram table and tokenizer present — before
any GPU work. A pack that cannot load is a two-second CPU finding, not a failure ten seconds into a
capture with the GPU wired up to its limit.

**4. The file map on the card described the wrong pack**

`README.md` and `NOTICE-CONVERSION.md` listed `model-lm-head.safetensors`, `model-embed.safetensors`,
`model-vision.safetensors`, `tokenizer.sushi.json` and `vocab.filemap.json`, and gave the trunk as
5.94 GB and the MTP head as 96 MB. None of those files exist in this pack and both sizes are wrong:
they are beamster's shard layout and figures, picked up while reading their card, and the sizes were
guesses rather than `ls`. Corrected against the pack directory: 69 files, 52 shards, trunk 6.32 GB
(2 628 tensors — embed, lm_head, vision tower and MTP fc/norm all live in the trunk shards),
`mtp-0.safetensors` 836 MB, layer shards 836 MB each. The converter log has no timestamps, so the
stage table's times come from shard mtimes (trunk 15:51:43, n-gram 15:54:49, layer-0 16:04:25,
layer-47 23:35:13, mtp-0 + index + config 23:44:34).

Both are the same lesson in different clothes: **verify the checker before trusting the verdict**
— and never let a checker's word be the thing that deletes 360 GB.

## Phase 4 — verification

```
04-verify-pack.py : shards 52 · tensors 3069 · payload 47.26 GB == on-disk 47.26 GB
                    index entries 3069, unresolved 0, defects 0 → integrity OK
05-smoke-test.sh  : "Reply with exactly: PACK OK" → "PACK OK" via path=mtp
                    exl3 n42 funnel codebook=mcg window=15 ✓ gdn engaged ✓ mtp engaged ✓
                    preflight: weights ~43.44 GB, needs ~45.69, available 58.00 → fits
real prompt       : from-scratch fnmatch-free glob matcher, 306 tokens, 29.4 s
                    prefill 72.7 tok/s · decode 45.1 tok/s · MTP accept 81.5 %
sushi list        : qwen3.8-flash-next:2.6bpw — published 73.7 GB, this Mac "fits",
                    marked "recommended" for 64 GB; our dir measures 73.85 GiB
```

## Reproducing a build, start to finish

```bash
export SUSHI=$HOME/sushi-macos-arm64/sushi
scripts/01-download-source.sh   ~/swift15-src
scripts/02-verify-source.py     ~/swift15-src
DRY=1 scripts/03-convert.sh     ~/swift15-src ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw
DRY=0 scripts/03-convert.sh     ~/swift15-src ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw
scripts/supervise.sh            ~/swift15-src ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw &
scripts/04-verify-pack.py       ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw
scripts/05-smoke-test.sh        ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw
scripts/07-checksums.sh         ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw
scripts/06-kld.sh               ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw ~/swift15-src
scripts/08-capture.sh             # KLD fixtures: capture fingerprints from both packs (server down)
CHECK=1 scripts/08-capture.sh     #   plan-only dry run, no GPU work
scripts/09-compare.sh             #   score every pack against every fixture, print measurements/kld/table.md
scripts/10-kld-table.py           #   render compare JSONs as a markdown table
scripts/11-eval.sh <model-id>      #  task-level eval (llmprobe) against the pack the server is serving
CHECK=1 scripts/11-eval.sh ...     #   plan only; SUITE=code|hard|core, arms pinned per suite
scripts/12-eval-table.py measurements/eval   # render eval reports as an arms-matched table
scripts/13-eval-queue.sh           #   both packs x hard+code, swapping --model between jobs (~2.5 h)
scripts/pack-check.py             #   is a pack dir loadable? (index vs shards) - run this first
PRIVATE=1 scripts/publish.sh    ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw
```

Expected, on this machine: 2 h download · 8 h convert · 20 min verify+smoke · 40 min publish
upload · 2–5 h if you run KLD. Hands-off: 9 h 45 m of download+convert.

### KLD fixtures and pack-vs-pack divergence

`08-capture.sh` writes a logit fingerprint (fixture) for each pack it is pointed at;
`09-compare.sh` scores every pack against every fixture. Both refuse to start while a
`sushi serve` process is alive, and both gate every pack through `pack-check.py` first:
a half-downloaded pack answers `MissingMimoShard`, and the gate catches it before ten
minutes of GPU time are spent. `CHECK=1` on either script prints the plan and does
nothing else; `MANIFEST_ONLY=1` on `08` rewrites fixture manifests without touching the
GPU.

Protocol (from sushi's `docs/quality-kld.md`): capture raw text, no chat template,
`--tokens 512 --top-k 10 --ctx-size 8192 --kv-quant off --qwen-gdn 32 --no-mtp`,
`MLX_ENABLE_TF32=0`, students scored at the served `--kv-quant 8`. Fixtures land in
`~/kld/<pack>/<fixture>/` with a `capture-manifest.json` recording binary, protocol and
machine; results land in `measurements/kld/*.json` plus `table.md`.

Read the table honestly: a self row (pack against its own fixture) must be 0.0000 KLD /
100% top-1 on the same binary, and a nonzero self row is engine nondeterminism, not
quality. Cross rows here compare two quantisations of two DIFFERENT models - Swift 1.5
against base Qwen - so they are a divergence fingerprint, not a KLD-to-teacher, and they
are not comparable with the published 16x512 wikitext rows in sushi's docs. Our 16 prompts
in `fixtures/prompts/` are original text, not the wikitext 16; `standard4` is the bundled
two-code/two-prose screen.

### Task-level eval (llmprobe) — the leg that wants the server UP

`08`/`09` refuse a live server; the eval leg requires one, because it is a black-box test of the
pack as served. Tool: `llmprobe` (`ddalcu/llmprobe`, Apache-2.0, npm) via `npx -y llmprobe@<ver>`;
`scripts/11-eval.sh` pins 0.6.12 (the version beamster's card names), checks `/v1/models` and refuses
if the server is serving something other than the model id it is given — measuring the wrong pack is
how a bogus number reaches a card.

```bash
SUITE=code scripts/11-eval.sh <served-model-id>   # 100 JS functions, graded by executing them
SUITE=hard scripts/11-eval.sh <served-model-id>   # 50 questions: MMLU-Pro / OlympiadBench / LiveBench / Juliet
scripts/12-eval-table.py measurements/eval        # arms-matched table + per-source breakdown
scripts/13-eval-queue.sh                          # ours:hard, theirs:hard, theirs:code, ours:code
CHECK=1 scripts/13-eval-queue.sh                  # plan only
```

`13-eval-queue.sh` is the comparison run: per job it stops the server, restarts it on one pack with
identical flags (`~/run-sushi.sh` with `MODEL=`), waits for `loaded=true state=ready` after a warm
request, runs the deck, and at the end leaves the server serving our pack. It takes
`measurements/eval/.queue.lock`, refuses while a `kld capture|compare` is running, gates both packs
through `pack-check.py`, skips jobs whose report already exists, and logs to
`logs/eval-queue-<stamp>.log` + `logs/server-<stamp>.log`. Run it under `nohup caffeinate -is`.

```bash
# the whole comparison, in a terminal you keep open (≈4–7 h, box dedicated):
nohup caffeinate -is scripts/13-eval-queue.sh > logs/handrun-$(date -u +%FT%TZ).log 2>&1 &
tail -f logs/eval-queue-*.log                        # watch it
LEAVE_DOWN=1 JOBS="ours:code,theirs:code" scripts/13-eval-queue.sh   # code deck only, leave the server down at the end
LEAVE_DOWN=1 JOBS="ours:hard" scripts/13-eval-queue.sh               # one job, stop any time with ctrl-C
scripts/12-eval-table.py measurements/eval --csv measurements/eval/table.csv   # render when jobs land
```

By default the script's EXIT trap **restores the server on our pack**, even if you stop it partway,
so the box is never left without inference; `LEAVE_DOWN=1` opts out of that (trap then only drops
the lock). `JOBS="ours|theirs:[hard|code|core],..."` picks any subset in any order; a job whose
report JSON exists is skipped, so a killed queue resumes where it stopped. A `kld capture|compare`
running, a missing pack, or a pack that fails `pack-check.py` all make it refuse before touching the
server.

Arms are pinned and identical for both packs — only `--model` moves: greedy t=0 (llmprobe default,
never overridden), effort `medium` for code / `xhigh` for hard, `--concurrency 2` (half the server's
`--max-concurrent` 4 — deliberately under saturation so the client can never hold the whole engine
while it reads nothing; llmprobe deliberately applies no per-request timeout), 16k output cap,
server `--kv-quant 8 --mtp --qwen-gdn 16 --expert-pick-tolerance 0.3 --ctx-size 131072`. So a row
measures the pack *as served here*, kv8 penalty included; it is not a weights-only number and not
a teacher KLD.

Cost measured on this box (dedicated, concurrency 2): code deck ≈ 50–70 min wall (the shared-engine
pilot at concurrency 4 was 28 min / 71 934 output tokens, 719 mean output and 620 mean reasoning
tokens per question — a *lower* wall time, so the concurrency-2 clean runs read slower but are
pack-comparable). Budget 1.5–3 h per pack for the hard deck (xhigh, 16k cap: MMLU-Pro ~30-60 s,
Olympiad up to tens of minutes each). Four jobs ≈ 4–7 h of dedicated box.

Things that bite:

- **An announced-but-unloaded server answers chat with nothing.** `/v1/models` replies as soon as the
  process is up; the pack is resident later. Requests in that window return empty completions, llmprobe
  scores 100 empty answers as 100 failures and exits 0 — a 0 % report in three seconds, indistinguishable
  from a bad pack unless you check. `11-eval.sh` now gates on `loaded=true state=ready` and quarantines a
  report whose cases produced no text (`measurements/eval/invalid/`, receipt kept).
- `pgrep -f 'sushi serve'` matches any shell whose command line contains that string — mine did,
  twice, and once it killed my own shell. Match the executable with `pgrep -x sushi` when the check
  is about the server.
- Check `reasoningEffortRejected` is `false` in the report, or the deck ran at an effort the server
  ignored and the score is not the card's arms.
- `--sampling` presets (t>0) are a different measurement and must never share a table with greedy
  rows; `11-eval.sh` never passes `--sampling` and records `sampling: greedy t=0`.
- Suites are not comparable to each other, and rows are only comparable when effort, cap, kv and MTP
  match. The table prints the arms per row so the mismatch is visible.
- Scores are aggregates. The decks are third-party corpora (licences recorded per run in
  `*-manifest.json`: GPQA CC BY 4.0, SuperGPQA ODC-BY, AIME mirror MIT, MMLU-Pro/OlympiadBench/
  LiveBench Apache-2.0 as redistributed by llmprobe, Juliet reductions CC0, MultiPL-E MIT) and are
  not redistributed by this repo.

## Serving it (deliberately not automated)

```bash
sudo sysctl iogpu.wired_limit_mb=60416          # 64 GB Mac; 7/8 of RAM, one notch under the pack's need
~/run-sushi.sh                                   # swap --model to the new pack
#   --model ~/.sushi/models/initialed85/Swift1.5-Qwen3.8-Flash-Next-Sushi-2.6bpw/
#   --mtp --qwen-gdn 16 --ctx-size 131072 --kv-quant 8 --prefix-cache-disk 8G …
```

Why this is a human call: it needs `sudo` on a sysctl, it wires ~46 GB (leaving ~1.6 GB free
with 26.4 GB of caches), it binds `0.0.0.0:8088`, and it is the thing your agents are talking
to right now. Once the pack is verified you can swap it in one line and restart; keep the old
model on disk so the swap is reversible.

The tiers sushi publishes for `qwen3.8-flash-next` (`docs/usage.md`), which is where "fits on 64,
streaming below that" comes from. The n-gram table is the wall — 29.8 GiB, never wired:

| RAM | 2.6bpw (73.7 GB) | 3bpw (81.4 GB) | 4bpw (95.6 GB) |
|---|---|---|---|
| 128 / 96 / 80 / **64** | fits, **recommended at 64** | fits; recommended at 96, 128 | fits at 128; 96 wants `--wired-limit-gb 60`; 80, 64 want `--ssd-budget-gb <target>` |
| 48 | wants `--wired-limit-gb 44` | streams experts (`--ssd-budget-gb`) | 64 wants `--ssd-budget-gb 36` |
| 32 | streams experts | streams experts | 48, 32 want `--ssd-budget-gb 24` |
| 24 | streams experts | streams experts | **not runnable** |

Our own preflight agrees with the 64 GB row: 43.44 GB of weights, needs 45.69 GB, 58.00 GB
available — at the wired limit this box sets explicitly (`iogpu.wired_limit_mb=60416` = 59 GB;
sushi's default is 7/8 of RAM = 56 GB) with the 29.8 GiB table read from SSD, never wired.
The pack's 73.85 GiB total is never all resident; only the 44.01 GiB of weights are.
