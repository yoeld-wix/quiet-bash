#!/usr/bin/env python3
"""Aggregate context-enrichment benchmark JSONL into a table + gate verdict.

An arm passes the gate iff its pass-rate >= control's (zero regression) AND its
mean cost is lower. Cheaper-but-regressed is DO NOT SHIP.
"""
import sys, json, collections, statistics

rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = collections.defaultdict(lambda: collections.defaultdict(list))
for r in rows:
    for k in ("input", "output", "cost", "ms"):
        by[r["arm"]][k].append(r[k])
    by[r["arm"]]["pass"].append(1 if r.get("pass") else 0)

def mean(x): return statistics.mean(x) if x else 0.0

arms = [a for a in ("control", "map", "symbol") if by[a]["input"]]
print("# quiet-bash context-enrichment benchmark — mean per run")
print("| arm | input tok | output tok | cost $ | time s | turns | pass-rate | runs |")
print("|---|--:|--:|--:|--:|--:|--:|--:|")
for a in arms:
    pr = mean(by[a]["pass"]) * 100
    print(f"| {a} | {mean(by[a]['input']):,.0f} | {mean(by[a]['output']):,.0f} | "
          f"{mean(by[a]['cost']):.4f} | {mean(by[a]['ms'])/1000:.1f} | {mean(by[a].get('turns',[0])) if by[a].get('turns') else 0:.1f} | {pr:.0f}% | {len(by[a]['input'])} |")

base_pr = mean(by["control"]["pass"]) * 100 if by["control"]["input"] else None
base_cost = mean(by["control"]["cost"]) if by["control"]["input"] else None
base_ms = mean(by["control"]["ms"]) if by["control"]["input"] else None
print()
for a in arms:
    if a == "control" or base_pr is None:
        continue
    pr = mean(by[a]["pass"]) * 100
    cost = mean(by[a]["cost"]); ms = mean(by[a]["ms"])
    regress = "ZERO-REGRESSION ✓" if pr >= base_pr else "ZERO-REGRESSION ✗"
    cost_str = f"cost {100*(cost-base_cost)/base_cost:+.1f}%" if base_cost else "cost n/a"
    time_str = f"time {100*(ms-base_ms)/base_ms:+.1f}%" if base_ms else "time n/a"
    verdict = "SHIP" if (pr >= base_pr and cost < base_cost) else "DO NOT SHIP"
    print(f"**arm {a}: {regress} (pass {pr:.0f}% vs control {base_pr:.0f}%), "
          f"{cost_str}, {time_str} → {verdict}** (negative = cheaper/faster).")
