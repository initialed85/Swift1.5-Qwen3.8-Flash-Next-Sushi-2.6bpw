#!/usr/bin/env python3
"""12-eval-table.py — render llmprobe eval reports (+ their manifests) as a markdown table.

Usage: 12-eval-table.py <dir-of-report.json> [--csv out.csv]

Pairs each llmprobe report with the `*-manifest.json` that scripts/11-eval.sh wrote beside it
(arms, deck licences, cost). Reads the `reasoning` block: passed/total/stopped/error, per-source
breakdown, per-case token counts.

Comparability rules this table enforces in words: suites are not comparable to each other, a
greedy run is not comparable to a `--sampling` preset run, and two runs are only comparable when
effort, output cap, KV quantisation and MTP match. The table prints those arms per row so a
reader can see whether the rows they are comparing share them.
"""
import csv
import glob
import json
import os
import sys


def load(d):
    rows = []
    for f in sorted(glob.glob(os.path.join(d, "*.json"))):
        if f.endswith("-manifest.json"):
            continue
        try:
            j = json.load(open(f))
        except Exception as e:  # noqa: BLE001
            rows.append({"file": f, "err": str(e)})
            continue
        if "reasoning" not in j:
            rows.append({"file": f, "err": "no reasoning block (run with --eval-only?)"})
            continue
        m = {}
        mf = f[:-5] + "-manifest.json"
        if os.path.exists(mf):
            m = json.load(open(mf))
        rows.append({"file": f, "j": j, "m": m, "err": None})
    return rows


def arms(row):
    j, m = row.get("j", {}), row.get("m", {})
    r = j.get("reasoning", {})
    a = m.get("arms", {})
    return (a.get("reasoning_effort") or r.get("reasoningEffort") or "?",
            a.get("max_output_tokens_per_question") or r.get("maxTokens"),
            a.get("concurrency"), a.get("sampling") or ("greedy t=0" if r.get("temperature") == 0 else f"t={r.get('temperature')}"),
            (a.get("server_flags") or "").replace("\\n", " "))


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    rows = load(sys.argv[1])
    good = [r for r in rows if not r["err"]]
    if not good:
        print(f"no eval reports in {sys.argv[1]}")
        return 1

    good.sort(key=lambda r: (r["j"]["target"]["model"], r["j"]["reasoning"].get("suite", "?")))

    print("# Task-level eval")
    print()
    print(f"Tool: llmprobe (Apache-2.0, `ddalcu/llmprobe`), version "
          f"{', '.join(sorted({r['m'].get('tool_version','?') for r in good if r.get('m')}))}. "
          "Graded at temperature 0; the code deck is graded by executing the model's function "
          "against the ported asserts (3 s cap, `node:vm`), the reasoning decks by normalised "
          "`Answer:` line matching against the published answer and its listed equivalent forms. "
          "A question that hits the output cap with no answer line is counted as *out of tokens* "
          "and reported apart from wrong.")
    print()
    print("| model | suite | passed | score | out of tokens | errors | effort | cap | conc | sampling | output tok | reasoning tok/q | wall |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in good:
        j, m = r["j"], r.get("m", {})
        rr = j["reasoning"]
        tot = rr.get("total") or 0
        acc = 100.0 * (rr.get("passed") or 0) / tot if tot else 0
        a = arms(r)
        cost = m.get("cost", {})
        print(f"| {j['target']['model']} | {rr.get('suite')} | {rr.get('passed')}/{tot} | "
              f"**{acc:.1f} %** | {rr.get('stopped')} | {rr.get('error')} | {a[0]} | {a[1]} | {a[2]} | "
              f"{a[3]} | {cost.get('output_tokens', (j.get('usage') or {}).get('outputTokens'))} | "
              f"{cost.get('mean_reasoning_tokens_per_question')} | {cost.get('duration_s', round(j.get('durationMs', 0)/1000, 1))} s |")
    print()
    print("## Per source")
    print()
    srcs = sorted({s["source"] for r in good for s in r["j"]["reasoning"].get("bySource", [])})
    print("| model | suite | " + " | ".join(srcs) + " |")
    print("|---|---|" + "---|" * len(srcs))
    for r in good:
        rr = r["j"]["reasoning"]
        by = {s["source"]: s for s in rr.get("bySource", [])}
        cells = []
        for s in srcs:
            b = by.get(s)
            cells.append(f"{b['passed']}/{b['total']}" if b else "-")
        print(f"| {r['j']['target']['model']} | {rr.get('suite')} | " + " | ".join(cells) + " |")
    print()
    print("Suites are not comparable to each other (llmprobe says so explicitly: *Hard runs are "
          "reported as such and are not comparable to core runs*). A `--sampling` preset run is not "
          "comparable to a greedy run. Two rows are only comparable when effort, output cap, KV "
          "quantisation and MTP match — read the arms columns before comparing any two rows.")

    bad = [r for r in rows if r["err"]]
    if bad:
        print()
        print("## Unreadable")
        for r in bad:
            print(f"- `{os.path.basename(r['file'])}`: {r['err']}")

    if "--csv" in sys.argv:
        out = sys.argv[sys.argv.index("--csv") + 1]
        with open(out, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["model", "suite", "passed", "total", "acc_pct", "stopped_cap", "errors",
                        "effort", "cap", "concurrency", "sampling", "output_tokens",
                        "reasoning_tokens_per_q", "duration_s", "tool_version", "report"])
            for r in good:
                j, m = r["j"], r.get("m", {})
                rr = j["reasoning"]
                a = arms(r)
                cost = m.get("cost", {})
                tot = rr.get("total") or 0
                w.writerow([j["target"]["model"], rr.get("suite"), rr.get("passed"), tot,
                            round(100.0 * (rr.get("passed") or 0) / tot, 2) if tot else None,
                            rr.get("stopped"), rr.get("error"), a[0], a[1], a[2], a[3],
                            cost.get("output_tokens", (j.get("usage") or {}).get("outputTokens")),
                            cost.get("mean_reasoning_tokens_per_question"),
                            cost.get("duration_s", round(j.get("durationMs", 0) / 1000, 1)),
                            m.get("tool_version"), os.path.basename(r["file"])])
        print(f"\ncsv -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
