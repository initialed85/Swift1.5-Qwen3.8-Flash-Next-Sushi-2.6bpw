# Invalid reports (receipts, excluded from tables and from the queue's skip list)

`initialed85_…__code-20261025T080032Z.json` — **0/100 in 3.1 s**, every case
`SyntaxError: Unexpected end of input` with `text: ""` and `finishReason: null`.

Cause: I ran `11-eval.sh` by hand at the exact moment the queue was swapping the server onto
`beamster/…`; the request stream hit a server that answered `/v1/models` while the pack was being
reloaded. Every chat request returned an empty completion, llmprobe scored 100 empty answers as 100
failures, and **exited 0**. Nothing in the harness noticed. That is the failure mode that puts a
plausible-looking 0 % into a card.

Guards added to `11-eval.sh` after this (validity logic now lives in `scripts/14-manifest.py`):

- Preflight refuses unless `/v1/models` reports the named model with `loaded=true state=ready`.
  Note `/v1/models` lists **every** pack the server knows, loaded or not — grepping the payload for
  an id proves nothing (measured: our pack was listed there at `loaded=false` while beamster was the
  one serving). `13-eval-queue.sh` now uses `served_id`, which returns only the entry that is
  actually `loaded` and `ready`.
- After the run, the report is invalid only if it generated **nothing at all**: aggregate
  `usage.outputTokens == 0`, or more than half the cases have `outputTokens == 0` with `finishReason`
  null. That is the measured signature above: 100/100 cases at 0 tokens in 3.1 s.

**A first attempt at that guard was wrong and got caught by its own data.** I first keyed it on *empty
final text* (more than 25 % ⇒ invalid). Our own hard deck legitimately has 12/50 cases with empty
final text, and beamster's 13/50 — so the guard buried a real measurement at
`2026-10-25T14:49:46Z`. It was recovered to `measurements/eval/` intact and its manifest regenerated
by `14-manifest.py`; the report bytes were never touched. The reason the wrong test looked plausible
is also the reason the right one is right: on the hard deck a pack can reason for **1 503 – 16 000
tokens** and never emit an answer line — that is a real failure mode of the pack (and a real
measurement of it), whereas the swap bug produced zero generated tokens per case. Empty text is a
finding; no generation is a broken instrument.

Kept, not deleted: the point of the receipt is the mechanism, and a guard you cannot point at an
example of is just a paragraph.
