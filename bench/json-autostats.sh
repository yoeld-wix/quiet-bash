#!/usr/bin/env bash
#
# Live A/B for the JSON auto-stats prototype (QUIET_JSON_AUTOSTATS=1 in core/quiet-json.sh).
#
# Question: when a task needs an aggregate answer over a large JSON record
# array (a count-by-status, an average price), does auto-computing field stats
# into the collapsed preview actually save a round trip (and cost), or does the
# bigger preview + occasional wrong-without-querying answers wash it out?
#
# Two arms, same task, same large record-array fixture (5,000 uniform records):
#   baseline  — today's shipped preview (3-item sample + shape fold only)
#   autostats — QUIET_JSON_AUTOSTATS=1 — preview also carries per-field stats
#
# Usage:
#   QB_MODEL=claude-haiku-4-5 QB_REPEATS=3 bench/json-autostats.sh
#
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-3}"
OUT="${QB_OUT:-$ROOT/bench/json-autostats-runs.jsonl}"
: > "$OUT"

TARGET="$(mktemp -d)"
python3 - "$TARGET/orders.json" <<'PY'
import json, random, sys
random.seed(42)
owners = ['alice', 'bob', 'carol', 'dave', 'erin']
statuses = ['open', 'closed', 'shipped']
rows = [{'id': i, 'status': statuses[i % 3], 'price': round(random.uniform(10, 500), 2), 'owner': owners[i % 5]}
        for i in range(5000)]
open(sys.argv[1], 'w').write(json.dumps(rows))
PY
python3 - "$TARGET/orders.json" > "$TARGET/truth.txt" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
open_count = sum(1 for r in rows if r['status'] == 'open')
avg_price = sum(r['price'] for r in rows) / len(rows)
print(f"{open_count} {avg_price:.2f}")
PY
read -r TRUE_OPEN TRUE_AVG < "$TARGET/truth.txt"
echo "ground truth: open=$TRUE_OPEN avg_price=$TRUE_AVG" >&2

PRE_HOOK='"PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
SET="$(mktemp)"; printf '{ "hooks": { %s } }\n' "$PRE_HOOK" > "$SET"

TASK='Run: cat orders.json   Then reply with exactly two numbers separated by a space: (1) how many orders have status "open", (2) the average price across ALL orders rounded to 2 decimals. No other text.'

run_one() { # arm autostats ti rep
  local arm="$1" autostats="$2" rep="$3"
  local j
  j=$(cd "$TARGET" && QUIET_JSON_AUTOSTATS="$autostats" timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json --settings "$SET" \
        --allowedTools "Bash" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
fresh=u.get('input_tokens',0) or 0
cr=u.get('cache_read_input_tokens',0) or 0
cc=u.get('cache_creation_input_tokens',0) or 0
result=(o.get('result','') or '').strip()
words=result.split()
ok=False
try:
    ok = len(words)>=2 and words[0]=='$TRUE_OPEN' and abs(float(words[1])-$TRUE_AVG)<0.01
except Exception:
    ok=False
rec={'arm':'$arm','rep':$rep,
     'fresh':fresh,'cache_read':cr,'cache_creation':cc,
     'output':u.get('output_tokens',0) or 0,
     'cost':o.get('total_cost_usd',0) or 0,'ms':o.get('duration_ms',0) or 0,'turns':o.get('num_turns',0),
     'ok': ok, 'result': result}
print(json.dumps(rec))
" >> "$OUT"
  echo "  ✓ ${arm} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS target=$TARGET" >&2
# Warm the shared prompt-cache prefix (system + tools + task) before measuring,
# so rep1 of the loop below doesn't eat a one-off cold-cache tax that has
# nothing to do with the feature under test — both arms share this prefix.
WARM_OUT="$OUT.warm"; QB_OUT_SAVE="$OUT"; OUT="$WARM_OUT"
run_one warmup 0 0
OUT="$QB_OUT_SAVE"; rm -f "$WARM_OUT"
for rep in $(seq 1 "$REPEATS"); do
  run_one baseline  0 "$rep"
  run_one autostats 1 "$rep"
done
rm -f "$SET"
rm -rf "$TARGET"

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(lambda:collections.defaultdict(list))
oks=collections.defaultdict(list)
for r in rows:
    for k in ('fresh','cache_read','cache_creation','output','cost','ms','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(r.get('ok', False))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','autostats']
labels={'baseline':'A baseline (no autostats)','autostats':'B autostats (QUIET_JSON_AUTOSTATS=1)'}
print("# JSON auto-stats benchmark — mean per run")
print("| arm | cost $ | fresh in | cache-read | output | turns | time s | correct | runs |")
print("|---|--:|--:|--:|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(1 for x in oks[a] if x)
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['cache_read']):,.0f} | {mean(by[a]['output']):,.0f} | {mean(by[a]['turns']):.1f} | {mean(by[a]['ms'])/1000:.1f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['autostats']['cost']:
    bc=mean(by['baseline']['cost']); ac=mean(by['autostats']['cost'])
    print(f"\n_autostats vs baseline: cost {100*(bc-ac)/bc:+.1f}% (positive = cheaper)._")
PY
