#!/usr/bin/env python3
"""14-manifest.py — record the arms, cost and validity of one llmprobe eval report beside it.

Used by scripts/11-eval.sh after a deck finishes, and usable on its own to re-record a report
without re-running the hours-long deck (e.g. one a guard mis-quarantined).

Usage: 14-manifest.py <report.json> <model> <suite> <effort> <concurrency> <cap> <llmprobe-ver> <server-flags> <utc-stamp>
"""
import json, os, sys, hashlib
report, model, suite, effort, conc, cap, llp, flags, stamp = sys.argv[1:10]
if not os.path.exists(report):
    print("no report written; skipping manifest"); sys.exit(0)
j = json.load(open(report))
r = j.get("reasoning", {})
cases = r.get("cases", [])
# Invalidity is about *generation*, not about final text. A pack can reason for thousands of tokens
# and never emit an answer line (measured: Olympiad cases at 1 503-16 000 output tokens with empty
# final text) - that is a real measurement of a real failure mode, so it must stay valid. The
# signature of the server-answering-without-the-pack bug is requests that generated nothing at all:
# 0 output tokens per case, finishReason null, and 0 in the aggregate usage. Measured: the 0/100
# run had 100/100 cases at 0 tokens in 3.1 s; every genuine case has >= 119 output tokens.
zero_gen = [c for c in cases if (c.get("outputTokens") or 0) == 0]
no_text = [c for c in cases if not c.get("text")]
valid = bool(cases) and (j.get("usage") or {}).get("outputTokens", 0) > 0 and 2 * len(zero_gen) <= len(cases)
sha = hashlib.sha256(open(report, "rb").read()).hexdigest()
if not valid:
    inv = os.path.join(os.path.dirname(report), "invalid")
    os.makedirs(inv, exist_ok=True)
    dest = os.path.join(inv, os.path.basename(report))
    os.replace(report, dest)
    logf = report + ".log"
    if os.path.exists(logf):
        os.replace(logf, os.path.join(inv, os.path.basename(logf)))
    print(f"INVALID REPORT ({len(zero_gen)}/{len(cases)} cases generated nothing at all"
          f" / {len(no_text)}/{len(cases)} with no final text): moved to {dest}")
    print("  Usual cause: server answered while the pack was not resident, so every request returned empty.")
    print("  This report is not a measurement and is excluded from the queue's skip list.")
    sys.exit(1)
dur = j.get("durationMs", 0) / 1000.0
out_tok = (j.get("usage") or {}).get("outputTokens", 0)
man = {
    "schema": "swift15-eval-v1",
    "tool": "llmprobe", "tool_version": llp, "tool_license": "Apache-2.0 (ddalcu/llmprobe)",
    "report_sha256": sha,
    "model": model, "suite": suite,
    "arms": {"sampling": "greedy t=0 (llmprobe default)", "reasoning_effort": effort,
             "concurrency": int(conc), "max_output_tokens_per_question": int(cap),
             "server_flags": flags.strip()},
    "score": {"passed": r.get("passed"), "total": r.get("total"),
              "stopped_token_cap": r.get("stopped"), "errors": r.get("error"),
              "by_source": r.get("bySource")},
    "cost": {"duration_s": round(dur, 1), "output_tokens": out_tok,
             "input_tokens": (j.get("usage") or {}).get("inputTokens", 0),
             "mean_output_tokens_per_question": round(out_tok / r.get("total", 1), 1) if r.get("total") else None,
             "mean_reasoning_tokens_per_question": (round(sum(c.get("reasoningTokens") or 0 for c in r.get("cases", [])) / len(r.get("cases", [])), 1) if r.get("cases") else None)},
    "measured_utc": stamp,
    "valid": True,
    "cases_without_final_text": len(no_text),   # reasoned but no answer line: a real result, kept
    "cases_without_generation": len(zero_gen),  # 0 output tokens: the server-answering-without-pack bug
    "machine": j.get("machine"),
    "deck_licenses": {"GPQA": "CC BY 4.0", "SuperGPQA": "ODC-BY", "AIME 2025 mirror": "MIT",
                      "MMLU-Pro": "Apache-2.0 (as redistributed by llmprobe)",
                      "OlympiadBench": "Apache-2.0 (as redistributed by llmprobe)",
                      "LiveBench": "Apache-2.0 (as redistributed by llmprobe)",
                      "NIST Juliet reductions": "CC0", "MultiPL-E (code deck)": "MIT"},
    "comparability": ("Suites are not comparable to each other. Greedy (t=0) runs are not comparable to "
                      "--sampling preset runs. Effort, output cap, KV quantisation and MTP must match "
                      "between two runs that are being compared. llmprobe's own wording: 'Suites are not "
                      "comparable to each other'; 'Hard runs are reported as such and are not comparable "
                      "to core runs'."),
    "notes": ("aggregate scores only; the prompt sets are third-party corpora under the licenses listed "
              "and are not redistributed by this repo"),
}
open(report.replace(".json", "-manifest.json"), "w").write(json.dumps(man, indent=2) + "\n")
acc = 100.0 * (r.get("passed") or 0) / r.get("total", 1) if r.get("total") else 0
print(f"\n== {suite}: {r.get('passed')}/{r.get('total')} ({acc:.1f} %), "
      f"{dur:.0f} s, {out_tok} output tokens -> {report} ==")
