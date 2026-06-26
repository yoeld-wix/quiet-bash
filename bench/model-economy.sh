#!/usr/bin/env bash
#
# 3-arm model-economy benchmark for quiet-bash.
#
# Measures whether downgrading SUBAGENTS to a cheaper tier saves cost with zero
# answer-quality regression. Arms:
#   baseline : subagents inherit the main model (no downgrade)
#   A        : CLAUDE_CODE_SUBAGENT_MODEL=haiku (force subagents to the cheap tier;
#              a robust proxy for the model-economy skill's selective frontmatter
#              tiering — if full downgrade is zero-regression, selective is safer)
#   B        : reserved for the PreToolUse(Task) hook; OFF until its spike passes
#
# Main-loop model is identical across arms (QB_MODEL); only the subagent tier
# changes, so any delta is attributable to subagent downgrade. Tasks are written
# to induce subagent delegation (search/summarize). Each run is graded pass/fail
# by a deterministic regex (see bench/model-economy-tasks.sh).
#
# Usage:
#   QB_TARGET=$PWD QB_MODEL=sonnet QB_REPEATS=2 bench/model-economy.sh
#
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$ROOT/bench/model-economy-tasks.sh"

TARGET="${QB_TARGET:-$ROOT}"
MODEL="${QB_MODEL:-sonnet}"
REPEATS="${QB_REPEATS:-2}"
OUT="${ME_OUT:-$ROOT/bench/model-economy-runs.jsonl}"
ARMS="${ME_ARMS:-baseline A}"
: > "$OUT"

run_one() { # arm task_idx rep
  local arm="$1" ti="$2" rep="$3" task="${ME_TASK_PROMPTS[$2]}"
  local j answer grade envcmd
  case "$arm" in
    baseline) envcmd=(env -u CLAUDE_CODE_SUBAGENT_MODEL) ;;
    A)        envcmd=(env CLAUDE_CODE_SUBAGENT_MODEL=haiku) ;;
    B)        envcmd=(env CLAUDE_CODE_SUBAGENT_MODEL=haiku) ;;  # placeholder; B uses the hook, wired later
    *)        envcmd=(env) ;;
  esac
  j=$(cd "$TARGET" && "${envcmd[@]}" timeout 300 \
        claude -p "$task" --model "$MODEL" --output-format json \
        --allowedTools "Task" "Bash" "Read" "Grep" "Glob" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} task${ti} rep${rep}: no output" >&2; return; }
  answer=$(printf '%s' "$j" | jq -r '.result // ""')
  grade=$(me_grade "$ti" "$answer")
  printf '%s\n' "$j" | ME_ARM="$arm" ME_TI="$ti" ME_REP="$rep" ME_GRADE="$grade" python3 -c "
import sys,json,os
o=json.load(sys.stdin); u=o.get('usage',{}) or {}
inp=(u.get('input_tokens',0) or 0)+(u.get('cache_read_input_tokens',0) or 0)+(u.get('cache_creation_input_tokens',0) or 0)
rec={'arm':os.environ['ME_ARM'],'task':int(os.environ['ME_TI']),'rep':int(os.environ['ME_REP']),
     'input':inp,'output':u.get('output_tokens',0) or 0,'cost':o.get('total_cost_usd',0) or 0,
     'ms':o.get('duration_ms',0) or 0,'turns':o.get('num_turns',0),'pass':(os.environ['ME_GRADE']=='pass')}
print(json.dumps(rec))
" >> "$OUT"
  echo "  ${grade} ${arm} task${ti} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS arms='$ARMS' target=$TARGET" >&2
for ti in "${!ME_TASK_PROMPTS[@]}"; do
  for rep in $(seq 1 "$REPEATS"); do
    for arm in $ARMS; do run_one "$arm" "$ti" "$rep"; done
  done
done

echo >&2
ME_OUT="$OUT" python3 "$ROOT/bench/model-economy-report.py" "$OUT"
