#!/usr/bin/env python3
"""10-kld-table.py — render `sushi kld compare` JSONs as a markdown table.

Usage: 10-kld-table.py <dir-of-compare.json> [--csv out.csv]

Schema read here is `mlx-serve-kld-compare-v1` (sushi 1.3.0):

  mean_kld / mean_kld_to_eos           KLD, all positions and the to-first-EOS subset
  mean_top1 / mean_top1_to_eos         top-1 agreement, as a fraction
  mean_nll / mean_nll_to_eos           student NLL on the fixture's token path
  mean_cosine_loss / worst_cosine_loss cosine distance of the logit vectors
  positions / positions_to_eos         how many rows those means cover
  prompts[]                            per-prompt copy of all of the above, plus eos_pos

Reading the output:
  * A self row (pack vs its own fixture, same binary and arms) must be 0 KLD / 100 % top-1.
    Anything else is engine nondeterminism, not quality.
  * A cross row between two packs of two DIFFERENT models is a divergence fingerprint, not a
    KLD-to-teacher, and it is not comparable with sushi's published 16x512 wikitext rows.
  * Students here are scored at the served --kv-quant 8 against a bf16-KV fixture, so a cross
    row contains the kv8 penalty as well as the pack difference. Self rows use the capture's
    own arms (bf16), so they do not.
"""
import csv
import glob
import json
import os
import sys

SELF_KEYS = ("self-ours", "self-theirs")


def pct(x):
    return "-" if x is None else f"{100 * x:.2f} %"


def num(x, nd=4):
    return "-" if x is None else f"{x:.{nd}f}"


def role_of(d):
    """Which pack was scored, from the compare JSON itself."""
    m = (d.get("model") or "").replace("\\", "/")
    if "initialed85" in m:
        return "ours"
    if "beamster" in m:
        return "theirs"
    return os.path.basename(m.rstrip("/")) or "?"


_fx = {}


def fixture_of(d):
    """Which pack a fixture was captured from - read its baseline.json, not the label."""
    f = (d.get("fixture") or "").replace("\\", "/").rstrip("/")
    if f in _fx:
        return _fx[f]
    role = None
    try:
        base = json.load(open(os.path.join(f, "baseline.json")))
        m = (base.get("model") or "").replace("\\", "/")
        role = "ours" if "initialed85" in m else "theirs" if "beamster" in m else None
    except Exception:  # noqa: BLE001
        pass
    if role is None:
        n = os.path.basename(f)
        role = {"ours": "ours", "theirs": "theirs"}.get(n, n or "?")
    _fx[f] = role
    return role


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    d = sys.argv[1]
    files = sorted(glob.glob(os.path.join(d, "*.json")))
    if not files:
        print(f"no compare JSONs in {d}")
        return 1

    rows = []
    for f in files:
        try:
            j = json.load(open(f))
        except Exception as e:  # noqa: BLE001
            rows.append({"name": os.path.basename(f), "err": str(e), "j": {}})
            continue
        if not isinstance(j, dict) or "mean_kld" not in j:
            rows.append({"name": os.path.basename(f), "err": "not a compare JSON", "j": j})
            continue
        s, t = role_of(j), fixture_of(j)
        rows.append({
            "name": os.path.basename(f)[:-5],
            "err": None,
            "j": j,
            "fixture_kind": (j.get("label") or "").split("__")[0].split("-")[0],
            "pair": f"{t} fixture \u2192 {s}" if s != t else f"{s} \u2192 itself",
            "self": s == t,
            "kld": j.get("mean_kld"),
            "kld_eos": j.get("mean_kld_to_eos"),
            "top1": j.get("mean_top1"),
            "top1_eos": j.get("mean_top1_to_eos"),
            "nll": j.get("mean_nll"),
            "nll_eos": j.get("mean_nll_to_eos"),
            "cos": j.get("mean_cosine_loss"),
            "worst": j.get("worst_cosine_loss"),
            "pos": j.get("positions"),
            "pos_eos": j.get("positions_to_eos"),
            "kv": j.get("kv_cache_format"),
        })

    rows.sort(key=lambda r: (r.get("fixture_kind", "?"), not r.get("self", False), r["name"]))

    print("# KLD measurements")
    print()
    print(f"Source: `sushi kld compare`, schema `{rows[0]['j'].get('schema', '?')}`, "
          f"{len(rows)} rows. Fixture protocol: standard4 (2 code + 2 prose, raw text, no chat "
          "template), 512 greedy tokens per prompt, top-k 10, ctx 8192, teacher arms bf16 KV.")
    print()
    print("| fixture | row (fixture \u2192 student) | KLD all | KLD to first EOS | top-1 | top-1 to EOS | NLL | NLL to EOS | cos loss | positions | student KV |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        if r["err"]:
            print(f"| ? | {r['name']} | read failed: {r['err']} | | | | | | | | |")
            continue
        print(f"| {r.get('fixture_kind')} | {r['pair']} | {num(r['kld'])} | {num(r['kld_eos'])} | "
              f"{pct(r['top1'])} | {pct(r['top1_eos'])} | {num(r['nll'])} | {num(r['nll_eos'])} | "
              f"{num(r['cos'])} | {r['pos']} / {r['pos_eos']} | {r['kv']} |")
    print()
    print("Self rows (a pack against its own fixture, same binary and arms) are the harness "
          "check: they must read 0 KLD and 100 % top-1. Cross rows between two packs of two "
          "**different models** are a divergence fingerprint, not a KLD-to-teacher, and are not "
          "comparable with sushi's published 16x512 wikitext readings. Students in cross rows "
          "carry the served kv8 penalty; self rows do not.")

    # per-prompt detail
    print()
    print("## Per-prompt detail (to first EOS)")
    print()
    ids = None
    for r in rows:
        if r["err"] or not r["j"].get("prompts"):
            continue
        if ids is None:
            ids = [p.get("id", "?") for p in r["j"]["prompts"]]
            print("| row | " + " | ".join(i.replace("_", " ") for i in ids) + " |")
            print("|---|" + "---|" * len(ids))
        ps = r["j"]["prompts"]
        cells = []
        for p in ps[: len(ids)]:
            pe = p.get("positions_to_eos") or 0
            cells.append(f"{num(p.get('kld_to_eos'))} / {pct((p.get('top1_to_eos') or 0) / pe) if pe else '-'}")
        print(f"| {r['name']} | " + " | ".join(cells) + " |")
    print()
    print("Cells are `KLD / top-1 agreement`.")

    if "--csv" in sys.argv:
        out = sys.argv[sys.argv.index("--csv") + 1]
        with open(out, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["row", "fixture_kind", "pair", "is_self", "kld", "kld_to_eos", "top1",
                        "top1_to_eos", "nll", "nll_to_eos", "cosine_loss", "worst_cosine_loss",
                        "positions", "positions_to_eos", "kv_cache_format"])
            for r in rows:
                w.writerow([r["name"], r.get("fixture_kind"), r.get("pair"), r.get("self"),
                            r.get("kld"), r.get("kld_eos"), r.get("top1"), r.get("top1_eos"),
                            r.get("nll"), r.get("nll_eos"), r.get("cos"), r.get("worst"),
                            r.get("pos"), r.get("pos_eos"), r.get("kv")])
        print(f"\ncsv -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
