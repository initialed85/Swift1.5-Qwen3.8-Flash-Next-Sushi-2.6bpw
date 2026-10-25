# Invalid reports (receipts, excluded from tables and from the queue's skip list)

`initialed85_…__code-20261025T080032Z.json` — **0/100 in 3.1 s**, every case
`SyntaxError: Unexpected end of input` with `text: ""` and `finishReason: null`.

Cause: I ran `11-eval.sh` by hand at the exact moment the queue was swapping the server onto
`beamster/…`; the request stream hit a server that answered `/v1/models` while the pack was being
reloaded. Every chat request returned an empty completion, llmprobe scored 100 empty answers as 100
failures, and **exited 0**. Nothing in the harness noticed. That is the failure mode that puts a
plausible-looking 0 % into a card.

Guards added to `11-eval.sh` after this:

- Preflight refuses unless `/v1/models` reports the named model with `loaded=true state=ready`.
- After the run, if more than 25 % of cases produced no text (or zero output tokens), the report is
  moved to this directory, marked, and the script exits 1 — so the queue's "report exists, skip"
  logic cannot mistake it for a completed job.

Kept, not deleted: the point of the receipt is the mechanism, and a guard you cannot point at an
example of is just a paragraph.
