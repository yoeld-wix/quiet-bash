#!/usr/bin/env bash
#
# A/B: selective subagent model downgrade — does downgrading only
# search/grep/read subagents (while keeping main model for reasoning) save cost
# with zero quality regression, vs blunt all-subagents downgrade?
#   A baseline  — all subagents inherit main model
#   B selective — CLAUDE_CODE_SUBAGENT_MODEL=haiku for search-shaped prompts
#                 (heuristic: prompt contains grep|find|read|list|search)
#
# Uses the same task set as bench/model-economy.sh for comparability.
#
# Usage: QB_MODEL=sonnet QB_SUBMODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/model-economy-selective.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-sonnet-4-5}"
SUBMODEL="${QB_SUBMODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/model-economy-selective-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

TARGET="${QB_TARGET:-$ROOT}"

TASKS=(
  "What is the current git branch? Reply with only the branch name."
  "How many .sh files are in the core/ directory? Reply with only the number."
  "What is the value of QUIET_LOG_PREFIX in core/quiet-core.sh? Reply with only the value."
  "List the names of the three most recently modified files in this repo. Reply with only the filenames, one per line."
)
TRUTHS=(
  "$(git -C "$TARGET" branch --show-current 2>/dev/null)"
  "$(ls "$TARGET/core/"*.sh 2>/dev/null | wc -l | tr -d ' ')"
  "claude-cmd-"
  ""
)

run_one() { # arm selective task_idx rep [jobfile]
  local arm="$1" selective="$2" ti="$3" rep="$4" jobfile="${5:-}" task="${TASKS[$3]}" truth="${TRUTHS[$3]}"
  local env_prefix=""
  [ "$selective" = "1" ] && env_prefix="CLAUDE_CODE_SUBAGENT_MODEL=$SUBMODEL"
  local j
  j=$(cd "$TARGET" && eval "$env_prefix" timeout 120 claude -p "$task" \
        --model "$MODEL" --output-format json \
        --allowedTools "Bash" "Read" "Grep" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} task${ti} rep${rep}: no output" >&2; return; }
  local result ok=0
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  [ -z "$truth" ] && ok=1 || { printf '%s' "$result" | grep -qF "$truth" && ok=1; }
  local dest="${jobfile:-$OUT}"
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
rec={'arm':'$arm','task':$ti,'rep':$rep,
     'fresh':u.get('input_tokens',0),'cache_read':u.get('cache_read_input_tokens',0),
     'output':u.get('output_tokens',0),
     'cost':o.get('total_cost_usd',0),'turns':o.get('num_turns',0),
     'ok': $ok}
sys.stdout.write(json.dumps(rec)+chr(10))
" > "$dest"
  echo "  ✓ ${arm} task${ti} rep${rep}" >&2
}

echo "model=$MODEL submodel=$SUBMODEL repeats=$REPEATS target=$TARGET" >&2

export -f run_one
export TARGET MODEL SUBMODEL OUT
export T0="${TASKS[0]}" T1="${TASKS[1]}" T2="${TASKS[2]}" T3="${TASKS[3]}"
export TR0="${TRUTHS[0]}" TR1="${TRUTHS[1]}" TR2="${TRUTHS[2]}" TR3="${TRUTHS[3]}"
JOBLIST="$(mktemp)"
for ti in 0 1 2 3; do
  for rep in $(seq 1 "$REPEATS"); do
    printf 'baseline  0 %s %s\n' "$ti" "$rep" >> "$JOBLIST"
    printf 'selective 1 %s %s\n' "$ti" "$rep" >> "$JOBLIST"
  done
done
xargs -P "$PARALLEL" -n 4 bash -c '
  TASKS=("$T0" "$T1" "$T2" "$T3"); TRUTHS=("$TR0" "$TR1" "$TR2" "$TR3")
  run_one "$1" "$2" "$3" "$4" "$OUT.job.$1.$3.$4"
' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.*

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
arms=['baseline','selective']
labels={'baseline':'A baseline (inherit model)','selective':'B selective (search agents → haiku)'}
print("# Selective model downgrade benchmark — mean per run")
print("| arm | cost $ | output tok | turns | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['output']):,.0f} | {mean(by[a]['turns']):.1f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['selective']['cost']:
    bc=mean(by['baseline']['cost']); sc_=mean(by['selective']['cost'])
    print(f"\nselective vs baseline: cost {100*(bc-sc_)/bc:+.1f}% (positive=cheaper)")
    u,p=mannwhitneyu(by['baseline']['cost'],by['selective']['cost'],alternative='greater')
    print(f"Mann-Whitney U (cost): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
    nb=len(oks['baseline']); ns=len(oks['selective'])
    _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks['selective']),ns-sum(oks['selective'])]])
    print(f"Fisher's exact (correctness): p={fp:.4g}")
    if p<0.05 and fp>0.05: verdict="SHIP"
    elif sc_>bc: verdict="DO NOT SHIP"
    else: verdict="INCONCLUSIVE"
    print(f"\n**Verdict: {verdict}**")
PY
