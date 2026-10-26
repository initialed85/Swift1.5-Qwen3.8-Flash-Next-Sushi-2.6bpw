# Task-level eval evidence — what is published and what is not

Published here (aggregate, no third-party text):

- `*-manifest.json` — one per run: score, arms, cost, validity counters, `report_sha256`.
- `table.csv` — every row, arms side by side (rendered by `scripts/12-eval-table.py`).
- `failures-by-source.md` — per sub-deck failure modes, with the counts that came out of the runs.
- `invalid/README.md`, `superseded/README.md` — receipts for the runs that are not measurements.

**Not published here**: the case-level `*.json` reports and the run logs (`logs/eval-queue-*.log`).
They embed the benchmark corpora's questions and published answers — MMLU-Pro, OlympiadBench,
SuperGPQA, Juliet, HumanEval/MBPP via MultiPL-E — and llmprobe's own README says LiveBench's five
questions are sourced from a private benchmark and are **not** to be published. So neither the HF
model repo nor the GitHub repo carries them; the `*.json` report blobs and `logs/` are
`.gitignore`d here and were never added to the HF tree.

What travels instead is the anchor: each manifest carries the report's `report_sha256`. If you
re-run the deck at the same arms, `shasum -a 256 <report.json>` should match. That makes the
aggregate rows checkable without shipping the corpora.

## Arms (so a re-run is a like-for-like re-run)

All rows: llmprobe **0.6.12**, greedy `t=0`, `--eval-max-tokens 16000`, `--concurrency 2`,
effort `medium` on code / `xhigh` on hard and core, server flags
`--kv-quant 8 --mtp --mtp-min-depth 1 --mtp-max-depth 2 --mtp-typical 0.1 --prefix-cache-entries 4
--prefix-cache-mem 8GB --prefix-cache-disk 0 --max-concurrent 4 --ctx-size 131072
--prefill-chunk 8192 --qwen-gdn 16 --expert-pick-tolerance 0.3 --metrics`.
Between the two packs **only `--model` changes**.

```bash
scripts/13-eval-queue.sh                                   # both packs x hard + code, unattended
SUITE=code scripts/11-eval.sh <served-model-id>            # one deck, one pack
SUITE=hard CASES=olympiad scripts/11-eval.sh <served-model-id>   # the 10-question slice
RUNNER="$HOME/run-sushi-budget.sh" EXTRA_FLAGS="--reasoning-budget 4096" \
  JOBS="ours:hard:olympiad,theirs:hard:olympiad" scripts/13-eval-queue.sh   # the slice, budgeted arms
scripts/12-eval-table.py measurements/eval --csv measurements/eval/table.csv
```

## The rows

| pack | suite | score | effort | report sha256 | note |
|---|---|---|---|---|---|
| ours | code | 81/100 | medium | `d94cfad16d8a362e…` | dedicated box; 3/100 produced no code text |
| theirs | code | 86/100 | medium | `d3a5d8b4eef78e54…` | dedicated box; 3/100 produced no code text |
| ours | hard | 36/50 | xhigh | `fc508d22e1336161…` | 12/50 cases reasoned with no `Answer:` line |
| theirs | hard | 36/50 | xhigh | `a61badf3c71a82f8…` | 13/50 cases reasoned with no `Answer:` line |
| ours | hard-olympiad (10 q slice) | 1/10 | xhigh | `bb9b6633529c15c5…` | arms add `--reasoning-budget 4096`; 5/10 no final text |
| theirs | hard-olympiad (10 q slice) | 2/10 | xhigh | `bbc39a3bd0caa8a6…` | same budgeted arms; 6/10 no final text |
| ours | core | 69/92 | xhigh | `eb8fe08474f66c0c…` | dedicated box; 16/92 cases reasoned with no `Answer:` line, 3 hit the 16 k output cap. A floor, not a point estimate. |
| theirs | core | **no report** | xhigh | — | ran 6 h 57 m; the 6 h watchdog failed to stop it (it TERM'd the `npm exec` wrapper, not the `node` child, and its log line went to `/dev/null`). Force-killed 19:58Z, rc=1. No score, no partial count. Not a measurement. |
| ours | code (invalid) | 0/100 | — | `29d51cd8773abd5c…` | 100/100 cases generated **0 tokens** in 3.1 s: the server answered while no pack was resident. Not a measurement. |
| ours | code (superseded) | 82/100 | medium | `46d3edb7eba29f26…` | concurrency 4 while the engine was shared with this agent's inference; cost columns congested, score credible |

Suites are not comparable to each other (llmprobe's rule). Slices are not comparable to their deck.
A row at `--reasoning-budget` is not comparable to a row without it.

The two older manifests (`invalid/`, `superseded/`) were written before the validity gate was
rewritten, so they carry no `cases_without_final_text` / `cases_without_generation` fields —
`invalid/README.md` states that run's counts directly (100/100 cases at zero generated tokens).

## Monitoring a run (collect raw, parse later)

Never parse the live server in a pipeline — a broken `grep` mid-run is unrecoverable, and every
field we want is cheap to re-derive from a saved payload. So collection and parsing are separate
scripts, and collection writes a file:

```bash
nohup scripts/14-metrics-log.sh >/dev/null 2>&1 &      # raw /metrics snapshots -> logs/metrics-raw-<stamp>.log
python3 scripts/15-metrics-parse.py logs/metrics-raw-<stamp>.log   # offline: progress table, deltas
pkill -f 14-metrics-log.sh                             # stop collecting
```

`14-metrics-log.sh` does no parsing at all (timestamped copy of the payload, one `curl`, every 30 s).
`15-metrics-parse.py` only reads. If the fields turn out to be the wrong ones, re-run the parser on
the same file. Same rule as the deck runs: llmprobe's report `*.json` and its tee'd `*.log` land on
disk raw, and `scripts/12-eval-table.py` builds the table afterwards — nothing in the collection
path depends on a filter being right.

Which counter means "alive": `sushi:generation_tokens_live` (tokens decoding right now) is the
liveness signal. `vllm:e2e_request_latency_seconds_count` (completed requests) is the progress
signal, and it moves slowly by design — at xhigh with a 16 k cap one question takes 10-20 minutes,
so a flat completion count for a few minutes is not a stall. A real stall is `live` frozen while
requests are running (that is how `theirs:core` died on 2026-10-26: ~20 min with no decode).

## Core (run 2026-10-26/27) — ours landed, theirs did not

`--eval-suite core` (92: GPQA Diamond + SuperGPQA + AIME 2025 + COMPSEC) was run at the arms above
(xhigh, no budget) on 2026-10-26/27. **Ours landed** 69/92 (75.0 %, valid): 16 cases reasoned to
completion but emitted no `Answer:` line and 3 more hit the 16 k output cap, so it is a floor, not a
point estimate. **Theirs never produced a report**: the run started 13:00Z, went 6 h 57 m, and was
force-killed at 19:58Z (rc=1) because it had gone engine-silent (a healthy run streams every decode
step). The queue's 6 h watchdog did not stop it — it TERM'd the `npm exec` wrapper rather than the
`node` child, and its log line went to `/dev/null` under nohup. There is no `theirs:core` number and
no partial count to publish. The watchdog is now fixed (it logs to the queue log and does
TERM-then-KILL on the `node`), so the missing leg is bounded:

```bash
JOBS="theirs:core" scripts/13-eval-queue.sh      # ~3–5 h; queue budgets 360 min per job, now enforced
```

A `core` row is a different deck and must never be read against the `hard` or `code` rows (llmprobe's
rule). When `theirs:core` lands it will fold into the table above with `serving = no budget` and
effort `xhigh`.
