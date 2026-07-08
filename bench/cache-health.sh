#!/usr/bin/env bash
#
# Cache-prefix health check: does quiet-bash's rewriting (log redirect /
# value-folding) preserve or bust the cache prefix vs baseline?
# Three arms matching bench/agentic.sh:
#   A baseline  — no hooks
#   B cmd-only  — command-output quieting only (PreToolUse Bash)
#   C full      — command-output + Read/MCP result quieting
# PRIMARY METRIC: cache_read % (cache_read / total_input). If B or C is
# significantly lower than A, the hooks are busting the prefix.
#
# Usage: QB_TARGET=/path/to/git/repo QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 bench/cache-health.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TARGET="${QB_TARGET:?set QB_TARGET to a git repo}"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/cache-health-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

PRE_HOOK='"PreToolUse":  [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
POST_HOOK='"PostToolUse": [ { "matcher": "Read|mcp__.*|WebFetch|WebSearch", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code-result.sh", "timeout": 15 } ] } ]'

BASE_SET="$(mktemp)";    printf '{}\n' > "$BASE_SET"
CMDONLY_SET="$(mktemp)"; printf '{ "hooks": { %s } }\n' "$PRE_HOOK" > "$CMDONLY_SET"
FULL_SET="$(mktemp)";    printf '{ "hooks": { %s, %s } }\n' "$PRE_HOOK" "$POST_HOOK" > "$FULL_SET"

# Same read-only tasks as bench/agentic.sh for comparability
# Note: bash arrays can't be exported to subshells, so store as indexed env vars
export TASK_0="Run: git log --oneline -20   then tell me the most recent commit message."
export TASK_1="Run: git log --stat -30   then name the three files that changed most often."
export TASK_2="Run: git diff HEAD~3 HEAD   then count the total files changed."

run_one() { # arm settings task_idx rep [jobfile]
  local arm="$1" set="$2" ti="$3" rep="$4" jobfile="${5:-}"
  local task
  eval "task=\$TASK_${ti}"
  local j
  j=$(cd "$TARGET" && timeout 180 claude -p "$task" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "Bash" "Read" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} task${ti} rep${rep}: no output" >&2; return; }
  local dest="${jobfile:-$OUT}"
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
fresh=u.get('input_tokens',0) or 0
cr=u.get('cache_read_input_tokens',0) or 0
cc=u.get('cache_creation_input_tokens',0) or 0
total=fresh+cr+cc
hit_pct=100*cr/total if total else 0
rec={'arm':'$arm','task':$ti,'rep':$rep,
     'fresh':fresh,'cache_read':cr,'cache_creation':cc,'total':total,
     'hit_pct':hit_pct,'output':u.get('output_tokens',0),
     'cost':o.get('total_cost_usd',0),'turns':o.get('num_turns',0)}
sys.stdout.write(json.dumps(rec)+chr(10))
" > "$dest"
  echo "  ✓ ${arm} task${ti} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS target=$TARGET" >&2
run_one warmup "$BASE_SET" 0 0 /dev/null

export -f run_one
export TARGET MODEL BASE_SET CMDONLY_SET FULL_SET OUT TASK_0 TASK_1 TASK_2
JOBLIST="$(mktemp)"
for ti in 0 1 2; do
  for rep in $(seq 1 "$REPEATS"); do
    printf 'baseline %s %s %s\n' "$BASE_SET"    "$ti" "$rep" >> "$JOBLIST"
    printf 'cmd-only %s %s %s\n' "$CMDONLY_SET" "$ti" "$rep" >> "$JOBLIST"
    printf 'full     %s %s %s\n' "$FULL_SET"    "$ti" "$rep" >> "$JOBLIST"
  done
done
xargs -P "$PARALLEL" -n 4 bash -c 'run_one "$1" "$2" "$3" "$4" "$OUT.job.$1.$3.$4"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.*
rm -f "$BASE_SET" "$CMDONLY_SET" "$FULL_SET"

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
from scipy.stats import mannwhitneyu
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(lambda:collections.defaultdict(list))
for r in rows:
    for k in ('fresh','cache_read','cache_creation','total','hit_pct','output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','cmd-only','full']
labels={'baseline':'A baseline (no hooks)','cmd-only':'B cmd-only (Bash)','full':'C full (Bash + Read/MCP)'}
print("# Cache-prefix health check — mean per run")
print("| arm | cache_read % | cost $ | fresh in | cache_read | turns | runs |")
print("|---|--:|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    print(f"| {labels[a]} | {mean(by[a]['hit_pct']):.1f}% | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['cache_read']):,.0f} | {mean(by[a]['turns']):.1f} | {len(by[a]['cost'])} |")
b_hit=by['baseline']['hit_pct']
for a in ('cmd-only','full'):
    if not by[a]['hit_pct'] or not b_hit: continue
    u,p=mannwhitneyu(b_hit,by[a]['hit_pct'],alternative='greater')
    delta=mean(b_hit)-mean(by[a]['hit_pct'])
    prefix_ok="prefix PRESERVED (p>0.05, no significant bust)" if p>=0.05 else f"WARNING: prefix may be busted (p={p:.4g})"
    print(f"\n{labels[a]} cache_read% vs baseline: {delta:+.1f}pp — {prefix_ok}")
PY
