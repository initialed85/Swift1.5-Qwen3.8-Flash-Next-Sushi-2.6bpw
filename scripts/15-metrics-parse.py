#!/usr/bin/env python3
"""15-metrics-parse.py — read a raw /metrics log, print progress. Nothing is consumed here.

usage: 15-metrics-parse.py [rawfile ...]      (default: newest logs/metrics-raw-*.log)

The raw file is just `=== <utc>` followed by a Prometheus payload. This script only reads; if the
fields we care about turn out to be the wrong ones, re-run it against the same file.
"""
import sys, os, glob, re

KEEP = [
    "sushi:generation_tokens_live",          # tokens decoded right now (liveness)
    "sushi:prefill_tokens_total",            # prompt tokens processed
    "vllm:e2e_request_latency_seconds_count",# completed requests  -> progress /92
    "vllm:generation_tokens_total",          # tokens for completed requests
    "vllm:num_requests_running",
    "vllm:num_requests_waiting",
    "sushi:gpu_utilization_pct",
]

def parse(path):
    snaps, cur, ts = [], {}, None
    for line in open(path, errors="replace"):
        line = line.rstrip()
        if line.startswith("=== "):
            if cur: snaps.append((ts, cur))
            ts, cur = line[4:], {}
            continue
        if not line or line.startswith("#") or line.startswith("---"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0].split("{")[0]
        if name in KEEP:
            try:
                cur[name] = cur.get(name, 0.0) + float(parts[-1])
            except ValueError:
                pass
    if cur: snaps.append((ts, cur))
    return snaps

def main():
    args = sys.argv[1:]
    if not args:
        args = [max(glob.glob(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs", "metrics-raw-*.log")), key=os.path.getmtime)]
    for path in args:
        snaps = parse(path)
        print("== %s  (%d snapshots, %s -> %s)" % (path, len(snaps), snaps[0][0] if snaps else "-", snaps[-1][0] if snaps else "-"))
        hdr = ("time", "done/92", "gen_tok", "live_tok", "running", "waiting", "gpu%", "d_gen", "d_live")
        rows = []
        prev = None
        for ts, m in snaps:
            d = m.get("vllm:e2e_request_latency_seconds_count", 0.0)
            g = m.get("vllm:generation_tokens_total", 0.0)
            l = m.get("sushi:generation_tokens_live", 0.0)
            dg = dl = float("nan")
            if prev is not None:
                dg, dl = g - prev[0], l - prev[1]
            prev = (g, l)
            rows.append((ts[11:], "%.0f" % d, "%d" % g, "%d" % l,
                         "%.0f" % m.get("vllm:num_requests_running", 0),
                         "%.0f" % m.get("vllm:num_requests_waiting", 0),
                         "%.0f" % m.get("sushi:gpu_utilization_pct", 0),
                         "%.0f" % dg, "%.0f" % dl))
        w = [max(len(hdr[i]), max((len(r[i]) for r in rows), default=4)) for i in range(len(hdr))]
        fmt = "  " + "  ".join("%%%ds" % w[i] for i in range(len(hdr)))
        print(fmt % hdr)
        for r in rows: print(fmt % r)
        if rows:
            print("  -> completed %s/92 at %s" % (rows[-1][1], rows[-1][0]))

if __name__ == "__main__":
    main()
