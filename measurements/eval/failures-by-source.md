# Failure modes by bench source — per row, per sub-deck

Every row below is one pack × one suite, arms matched across rows (greedy t=0, effort medium on
code / xhigh on hard, `--concurrency 2`, 16 000 output cap, same server flags, only `--model`
changes). `empty content` counts cases where the **content channel** carried nothing the grader
could read — that is a different fault from "answered wrong", and they are actioned differently.

`expected?` answers a specific question: given that Swift 1.5 Qwen3.8-Flash-Next is a chat/RL
model with a thinking channel (not a competition-math model) and we are serving EXL3 2.6 bpw +
kv8 on this box, **should this sub-deck have looked like this?**

## hard suite

| pack | sub-deck | passed | empty content | capped (finish=length) | median thinking tok | median content tok | expected? | verdict | what to do |
|---|---|---|---|---|---|---|---|---|---|
| ours | MMLU-Pro | 28/30 | 1 | 1 | 677 | 104 | **yes** — ~93 % is this model's band | healthy; the one cap is a rambling generator, not a wrong answer | nothing for the score; keep `finish=length` counted separately |
| theirs | MMLU-Pro | 27/30 | 2 | 1 | 1 275 | 80 | **yes** | healthy; ~2.7× more thinking than ours on the same deck | worth comparing thinking budgets as a *cost* finding, not a score |
| ours | NIST Juliet | 5/5 | 0 | 0 | 286 | 7 | **yes** — read-the-code reductions, both packs saturated | no signal at all (identical 5/5) | leave it; it proves the server answers, nothing else |
| theirs | NIST Juliet | 5/5 | 0 | 0 | 336 | 7 | **yes** | as above; note one case ran 9 828 thinking tokens and still got it | — |
| ours | LiveBench (zebra) | 3/5 | 1 | 0 | 1 687 | 10 | **yes, but uninformative** | n=5 ⇒ one case is 20 % of the sub-deck; ±1 between packs is noise | don't conclude; would need more LiveBench cases to mean anything |
| theirs | LiveBench (zebra) | 4/5 | 1 | 0 | 2 675 | 10 | **yes, but uninformative** | as above, opposite direction | as above |
| ours | OlympiadBench | **0/10** | **10** | 1 | 5 845 | **0** | **no — this is an artifact** | both packs think (≈5.8 k tokens) then write a *proof into the content channel* and never emit the `Answer:` line; 9/10 stopped on their own, so not truncation | see "Levers" below — this is the sub-deck killing 10/50 of the hard score |
| theirs | OlympiadBench | **0/10** | **10** | 0 | 5 675 | **0** | **no — same artifact** | same mechanism, all 10 ended `stop` | same |

## code suite

| pack | sub-deck | passed | no code text extracted | code ran, asserts failed | median thinking tok | median content tok | expected? | verdict | what to do |
|---|---|---|---|---|---|---|---|---|---|
| ours | HumanEval | 48/50 | 2 (`HumanEval_43_pairs_sum_to_zero`, `HumanEval_116_sort_array`) | 0 | 368 | 94 | **yes** — near-perfect is this model's band | both misses are extraction misses, not logic | treat as prompt-ambiguity, not a pack finding |
| theirs | HumanEval | 49/50 | 1 (`HumanEval_116_sort_array`) | 0 | 419 | 100 | **yes** | `sort_array` fails on **both** packs ⇒ the prompt, not the pack | — |
| ours | MBPP | 33/50 | 1 (`mbpp_765_is_polite`) | 16 | 332 | 71 | **yes, floor** — llmprobe warns these are one-liners with no examples | 16 real logic failures | the honest substance of our −5 on code |
| theirs | MBPP | 37/50 | 2 (`mbpp_617_min_Jumps`, `mbpp_627_find_First_Missing`) | 11 | 556 | 78 | **yes, floor** | theirs thinks ~1.7× more per MBPP success than we do | compare thinking budgets (below) before assuming it's a weights gap |

### Reading

- **Two sub-decks carry no signal at all**: NIST Juliet (5/5 both) and LiveBench (n=5, ±1).
- **One carries signal but only in the wrong shape**: OlympiadBench, 0/10 both, because the
  `Answer:` contract is never satisfied — the failure is in the **output channel**, not the maths.
- **The only clean capability gap in the whole card is MBPP**: 33 vs 37, and its mechanism is
  visible in cost — our pack thinks ~332 tokens there, theirs ~556.
- Sum of "expected" rows: MMLU-Pro 28/30 vs 27/30, Juliet 5/5 vs 5/5, HumanEval 48/50 vs 49/50 —
  i.e. both packs are behaving like the same base model everywhere the measurement is able to see.

## The Olympiad slice, at `--reasoning-budget 4096` (2026-10-26)

Different arms, so its own table: `--eval-suite hard --eval-cases olympiad` (10 questions), served by
`~/run-sushi-budget.sh` with `EXTRA_FLAGS=--reasoning-budget 4096` — a separate launcher, so
production (`~/run-sushi.sh`) was never budget-capped and came back uncapped afterwards.

| pack | slice score | thinking clamped | cases that then produced graded content | answers seen |
|---|---|---|---|---|
| ours | **1/10** | 5/10 at 4 119 tok | 5 | `11` vs 2 · `3976036` vs 3986729 · **25/2 PASS** · `1002` vs 1003 · one `?` |
| theirs | **2/10** | 4/10 at 4 119 tok | 4 | `4041417` vs 3986729 · **25/2 PASS** · **1003 PASS** · one truncated token run |

Reading: the budget only binds where thinking was long, and it is exactly those cases that then emit
an `Answer:` line. Cases whose thinking finished under 4 096 stay in proof mode with empty content,
so the lever is partial by construction. **The 0/10 at production arms was a format/channel artifact —
but forcing the answer does not reveal hidden competence**: at 2.6 bpw + kv8 this deck is genuinely
~1–2/10, with near-misses like 1002 vs 1003 and 3 976 036 vs 3 986 729 rather than unreachable answers.
At n=10, 1 vs 2 is inside noise, so Olympiad is reported as **non-discriminating**, never as a capability
score. On the 40 live hard-deck questions both packs score 36/40 — identical.
