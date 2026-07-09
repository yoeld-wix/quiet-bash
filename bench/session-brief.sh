#!/usr/bin/env bash
#
# A/B: does injecting a project brief (branch + recent commits) at session start
# save exploration turns and cost on an orientation task?
#   A baseline — cold session, no brief
#   B brief    — brief prepended to task (simulates what the sessionstart hook injects)
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/session-brief.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/session-brief-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

# Use this repo as the target — it has real git history
TARGET="$ROOT"
BRANCH=$(git -C "$ROOT" branch --show-current 2>/dev/null)
LOG=$(git -C "$ROOT" log --oneline -5 2>/dev/null)
CHANGED=$(git -C "$ROOT" diff --stat HEAD~1 HEAD 2>/dev/null | tail -1)
BRIEF="[Project brief — branch: ${BRANCH}]
Recent commits:
${LOG}
Last commit change summary: ${CHANGED:-n/a}"

TASK='What is the most recently added feature in this repo? Name the file that implements it and explain in one sentence what it does. Check the code to confirm.'

TRUTH_BRANCH="$BRANCH"
TRUTH_COMMIT=$(git -C "$ROOT" log --oneline -1 2>/dev/null | cut -d' ' -f2-)

run_one() { # arm use_brief rep [jobfile]
  local arm="$1" use_brief="$2" rep="$3" jobfile="${4:-}"
  local prompt="$TASK"
  [ "$use_brief" = "1" ] && prompt="$BRIEF

$TASK"
  local j
  j=$(cd "$TARGET" && timeout 90 claude -p "$prompt" \
        --model "$MODEL" --output-format json \
        --allowedTools "Bash" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local result ok=0
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  printf '%s' "$result" | grep -qE '\b[a-zA-Z0-9_/-]+\.sh\b' && ok=1
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

echo "model=$MODEL repeats=$REPEATS branch=$BRANCH" >&2
run_one warmup 0 0 /dev/null

export -f run_one
export TARGET MODEL TASK BRIEF TRUTH_BRANCH TRUTH_COMMIT OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline 0 %s\n' "$rep" >> "$JOBLIST"
  printf 'brief    1 %s\n' "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 3 bash -c 'run_one "$1" "$2" "$3" "$OUT.job.$1.$3"' _ < "$JOBLIST"
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
    for k in ('fresh','cache_read','output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(bool(r.get('ok',False)))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','brief']
labels={'baseline':'A baseline (cold)','brief':'B brief (pre-surfaced)'}
print("# Session-brief benchmark — mean per run")
print("| arm | cost $ | turns | output tok | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['turns']):.1f} | {mean(by[a]['output']):,.0f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['brief']['cost']:
    bc=mean(by['baseline']['cost']); brc=mean(by['brief']['cost'])
    print(f"\nbrief vs baseline: cost {100*(bc-brc)/bc:+.1f}%, turns {mean(by['baseline']['turns']):.1f} -> {mean(by['brief']['turns']):.1f}")
    u,p=mannwhitneyu(by['baseline']['cost'],by['brief']['cost'],alternative='greater')
    print(f"Mann-Whitney U (cost): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
    nb=len(oks['baseline']); nk=len(oks['brief'])
    _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks['brief']),nk-sum(oks['brief'])]])
    print(f"Fisher's exact (correctness): p={fp:.4g}")
    if p<0.05 and fp>0.05: verdict="SHIP"
    elif brc>bc: verdict="DO NOT SHIP"
    else: verdict="INCONCLUSIVE"
    print(f"\n**Verdict: {verdict}**")
PY
