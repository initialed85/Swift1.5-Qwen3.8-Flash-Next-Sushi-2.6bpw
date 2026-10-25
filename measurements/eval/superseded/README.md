# Superseded: shared-engine pilot (do not quote as the pack's score)

Run 2026-10-25T07:19Z, `initialed85/…Sushi-2.6bpw`, llmprobe 0.6.12, code deck (100 JS functions,
execution-graded, greedy t=0, effort medium, concurrency 4, 16k cap) — **while the same server was
serving this agent's own inference traffic**. The engine was shared, so per-question decode speed
and queueing were not the engine's idle numbers, and 28 min for 100 questions is the congested
figure, not the box's.

Result, for the record: 82/100 (HumanEval 48/50, MBPP 34/50), 0 out-of-token, 0 engine errors,
620 mean reasoning tokens/question, 719 mean output tokens/question.

Scoring is not affected by the sharing — grading is deterministic and independent of latency — so
82 % is a real score for this pack. What the sharing makes non-comparable is the *cost* columns,
and any comparison against a run taken on a quiet engine. The published protocol re-runs both packs
with the server dedicated (`scripts/13-eval-queue.sh`); this file stays as the receipt for the
first run, which is what sized the harness.
