#!/usr/bin/env bash
#
# Real multi-arm agentic benchmark for quiet-bash (input side).
#
# Runs a headless Claude Code session on real read-only tasks across three arms,
# isolating quiet-bash's two levers, and measures the real input tokens / cost /
# time each consumes:
#   A baseline  — no hooks
#   B cmd-only  — command-output quieting only (PreToolUse Bash)
#   C full      — command-output + Read/MCP result quieting (Pre + PostToolUse)
# quiet-bash reduces the context that gets re-sent, so B and C should spend fewer
# input tokens (and less $) than A for the same answers.
#
# Tasks are read-only and dependency-free (git log, large file reads) so they
# trigger quiet-bash's quieting without mutating the target repo or needing a build.
#
# Usage:
#   QB_TARGET=/path/to/git/repo QB_MODEL=claude-haiku-4-5 QB_REPEATS=2 bench/agentic.sh
#
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TARGET="${QB_TARGET:?set QB_TARGET to a git repo to run the tasks in}"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-2}"
OUT="${QB_OUT:-$ROOT/bench/agentic-runs.jsonl}"
: > "$OUT"

# Three arms, isolating quiet-bash's two levers:
#   A baseline  = no hooks
#   B cmd-only  = command-output quieting only (PreToolUse Bash)
#   C full      = command-output + Read/MCP result quieting (Pre + PostToolUse)
PRE_HOOK='"PreToolUse":  [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
POST_HOOK='"PostToolUse": [ { "matcher": "Read|mcp__.*|WebFetch|WebSearch", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code-result.sh", "timeout": 15 } ] } ]'

BASE_SET="$(mktemp)";    printf '{}\n' > "$BASE_SET"
CMDONLY_SET="$(mktemp)"; printf '{ "hooks": { %s } }\n'      "$PRE_HOOK"             > "$CMDONLY_SET"
FULL_SET="$(mktemp)";    printf '{ "hooks": { %s, %s } }\n'  "$PRE_HOOK" "$POST_HOOK" > "$FULL_SET"

TASKS=(
  "Run: git log -p -30   then summarise the three most significant changes in two sentences."
  "Read packages/astra-migrations-mcp-server/src/services/pr-review.ts and list its exported function names."
  "Run: cat package-lock.json   then tell me roughly how many dependency entries it has."
  "Run: git log --stat -120   then name the three files that changed most often."
)

run_one() { # arm settings task_idx repeat
  local arm="$1" set="$2" ti="$3" rep="$4" task="${TASKS[$3]}"
  local j
  j=$(cd "$TARGET" && timeout 300 claude -p "$task" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "Bash" "Read" "Grep" "Glob" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} task${ti} rep${rep}: no output" >&2; return; }
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
fresh=u.get('input_tokens',0) or 0
cr=u.get('cache_read_input_tokens',0) or 0
cc=u.get('cache_creation_input_tokens',0) or 0
rec={'arm':'$arm','task':$ti,'rep':$rep,
     'input':fresh+cr+cc,           # legacy total (fresh+cache_read+cache_creation)
     'fresh':fresh,'cache_read':cr,'cache_creation':cc,
     'output':u.get('output_tokens',0) or 0,
     'cost':o.get('total_cost_usd',0) or 0,'ms':o.get('duration_ms',0) or 0,'turns':o.get('num_turns',0)}
print(json.dumps(rec))
" >> "$OUT"
  echo "  ✓ ${arm} task${ti} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS target=$TARGET" >&2
for ti in "${!TASKS[@]}"; do
  for rep in $(seq 1 "$REPEATS"); do
    run_one baseline "$BASE_SET"    "$ti" "$rep"
    run_one cmd-only "$CMDONLY_SET" "$ti" "$rep"
    run_one full     "$FULL_SET"    "$ti" "$rep"
  done
done

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(lambda:collections.defaultdict(list))
# back-compat: older runs lack the split fields; derive what we can.
for r in rows:
    r.setdefault('fresh', r.get('input',0)); r.setdefault('cache_read',0); r.setdefault('cache_creation',0)
    for k in ('input','fresh','cache_read','cache_creation','output','cost','ms','turns'):
        by[r['arm']][k].append(r.get(k,0))
def mean(x): return statistics.mean(x) if x else 0
def stdev(x): return statistics.pstdev(x) if len(x)>1 else 0
def hit(a):  # cache-hit rate = cache_read / all input tokens processed
    tot=mean(by[a]['fresh'])+mean(by[a]['cache_read'])+mean(by[a]['cache_creation'])
    return 100*mean(by[a]['cache_read'])/tot if tot else 0
arms=['baseline','cmd-only','full']
labels={'baseline':'A baseline (no hooks)','cmd-only':'B cmd-only (Bash)','full':'C full (Bash + Read/MCP)'}

# Cost is the metric that matters — cache reads are billed ~0.1x, so lead with it.
print("# quiet-bash agentic benchmark — mean per run (3-arm, cache-aware)")
print(f"| arm | cost $ | fresh in | cache-read | cache-hit % | output | turns | time s | runs |")
print(f"|---|--:|--:|--:|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['cache_read']):,.0f} | {hit(a):.0f}% | {mean(by[a]['output']):,.0f} | {mean(by[a]['turns']):.1f} | {mean(by[a]['ms'])/1000:.1f} | {len(by[a]['cost'])} |")
if by['baseline']['cost']:
    bc=mean(by['baseline']['cost'])
    print("\n_vs baseline (positive = cheaper):_")
    for a in ('cmd-only','full'):
        if not by[a]['cost']: continue
        qc=mean(by[a]['cost'])
        sd=stdev(by[a]['cost'])
        print(f"- **{labels[a]}**: cost {100*(bc-qc)/bc:+.1f}%  (cost σ across runs ${sd:.4f})")
    print("\n_Note: 'cost' is the honest metric — `cache_read` tokens are billed ~0.1x and grow"
          "\nwith turn count, so a raw input-token sum overstates differences driven by agent"
          "\nturn-count variance rather than by quieting. Higher cache-hit % = warmer prefix._")
PY
