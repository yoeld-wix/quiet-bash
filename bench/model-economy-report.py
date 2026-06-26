#!/usr/bin/env python3
"""Aggregate model-economy benchmark JSONL into a markdown table + gate verdict.

An arm passes the gate iff its pass-rate equals baseline's (zero regression)
AND its mean cost is lower. Cheaper-but-regressed is a FAIL.
"""
import sys, json, collections, statistics

rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = collections.defaultdict(lambda: collections.defaultdict(list))
for r in rows:
    for k in ("input", "output", "cost", "ms"):
        by[r["arm"]][k].append(r[k])
    by[r["arm"]]["pass"].append(1 if r.get("pass") else 0)

def mean(x): return statistics.mean(x) if x else 0.0

arms = [a for a in ("baseline", "A", "B") if by[a]["input"]]  # arms outside this tuple are ignored in the table/verdict
print("# quiet-bash model-economy benchmark — mean per run")
print("| arm | input tok | output tok | cost $ | time s | pass-rate | runs |")
print("|---|--:|--:|--:|--:|--:|--:|")
for a in arms:
    pr = mean(by[a]["pass"]) * 100
    print(f"| {a} | {mean(by[a]['input']):,.0f} | {mean(by[a]['output']):,.0f} | "
          f"{mean(by[a]['cost']):.4f} | {mean(by[a]['ms'])/1000:.1f} | {pr:.0f}% | {len(by[a]['input'])} |")

base_pr = mean(by["baseline"]["pass"]) * 100 if by["baseline"]["input"] else None
base_cost = mean(by["baseline"]["cost"]) if by["baseline"]["input"] else None
print()
for a in arms:
    if a == "baseline" or base_pr is None:
        continue
    pr = mean(by[a]["pass"]) * 100
    cost = mean(by[a]["cost"])
    regress = "ZERO-REGRESSION ✓" if pr >= base_pr else "ZERO-REGRESSION ✗"
    if base_cost:
        cost_str = f"cost {100*(cost-base_cost)/base_cost:+.1f}%"
    else:
        cost_str = "cost n/a"
    verdict = "SHIP" if (pr >= base_pr and cost < base_cost) else "DO NOT SHIP"
    print(f"**arm {a}: {regress} (pass {pr:.0f}% vs baseline {base_pr:.0f}%), "
          f"{cost_str} → {verdict}** (negative cost = cheaper).")
