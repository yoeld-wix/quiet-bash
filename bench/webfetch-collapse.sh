#!/usr/bin/env bash
#
# A/B/C: does quiet-bash's WebFetch result collapsing save cost, and what
# threshold is optimal?
#   A baseline        — no PostToolUse hook (full WebFetch content in context)
#   B current         — collapse at QUIET_RESULT_MIN_BYTES default (25000)
#   C aggressive      — collapse at half the default (12500)
#
# Task: fetch the jq README from raw.githubusercontent.com and answer a question
# about it — this is a controlled, reproducible WebFetch target.
#
# NOTE: This bench requires network access. Results are env-dependent (latency,
# caching). Run from a consistent network environment.
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/webfetch-collapse.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/webfetch-collapse-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

PRE_HOOK='"PreToolUse":  [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
POST_HOOK_DEFAULT='"PostToolUse": [ { "matcher": "WebFetch|WebSearch|mcp__.*", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code-result.sh", "timeout": 15 } ] } ]'

BASE_SET="$(mktemp)";       printf '{}\n' > "$BASE_SET"
DEFAULT_SET="$(mktemp)";    printf '{ "hooks": { %s } }\n' "$POST_HOOK_DEFAULT" > "$DEFAULT_SET"
AGGR_SET="$(mktemp)";       printf '{ "hooks": { %s } }\n' "$POST_HOOK_DEFAULT" > "$AGGR_SET"

# Task that requires WebFetch: the README of a small known repo
TASK='Fetch https://raw.githubusercontent.com/stedolan/jq/master/README then tell me: what does jq do? One sentence.'

run_one() { # arm settings min_bytes rep [jobfile]
  local arm="$1" set="$2" min_bytes="$3" rep="$4" jobfile="${5:-}"
  local j
  j=$(QUIET_RESULT_MIN_BYTES="$min_bytes" timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "WebFetch" "Bash" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local result ok=0
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  # pass if result mentions jq's core function (JSON processing)
  printf '%s' "$result" | grep -qiE 'json|command.line|process|filter' && ok=1
  local dest="${jobfile:-$OUT}"
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
rec={'arm':'$arm','rep':$rep,
     'fresh':u.get('input_tokens',0),'cache_read':u.get('cache_read_input_tokens',0),
     'output':u.get('output_tokens',0),
     'cost':o.get('total_cost_usd',0),'turns':o.get('num_turns',0),
     'ok': $ok}
sys.stdout.write(json.dumps(rec)+chr(10))
" > "$dest"
  echo "  ✓ ${arm} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS" >&2
run_one warmup "$BASE_SET" 25000 0 /dev/null

export -f run_one
export MODEL TASK BASE_SET DEFAULT_SET AGGR_SET OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline   %s 999999 %s\n' "$BASE_SET"    "$rep" >> "$JOBLIST"
  printf 'default    %s 25000  %s\n' "$DEFAULT_SET" "$rep" >> "$JOBLIST"
  printf 'aggressive %s 12500  %s\n' "$AGGR_SET"    "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 4 bash -c 'run_one "$1" "$2" "$3" "$4" "$OUT.job.$1.$4"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.* "$BASE_SET" "$DEFAULT_SET" "$AGGR_SET"

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
from scipy.stats import mannwhitneyu, fisher_exact
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(lambda:collections.defaultdict(list))
oks=collections.defaultdict(list)
for r in rows:
    for k in ('fresh','output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(bool(r.get('ok',False)))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','default','aggressive']
labels={'baseline':'A baseline (no collapse)','default':'B default (25000 B threshold)','aggressive':'C aggressive (12500 B)'}
print("# WebFetch collapse benchmark — mean per run")
print("| arm | cost $ | fresh in | turns | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['turns']):.1f} | {ok}/{n} | {n} |")
if by['baseline']['cost']:
    bc=mean(by['baseline']['cost'])
    for a in ('default','aggressive'):
        if not by[a]['cost']: continue
        ac=mean(by[a]['cost'])
        u,p=mannwhitneyu(by['baseline']['cost'],by[a]['cost'],alternative='greater')
        nb=len(oks['baseline']); na=len(oks[a])
        _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks[a]),na-sum(oks[a])]])
        if p<0.05 and fp>0.05: verdict="SHIP"
        elif ac>bc: verdict="DO NOT SHIP"
        else: verdict="INCONCLUSIVE"
        print(f"\n{labels[a]}: cost {100*(bc-ac)/bc:+.1f}%, p={p:.4g} — **{verdict}**")
PY
