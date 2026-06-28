#!/usr/bin/env bash
#
# 2-arm context-enrichment benchmark for quiet-bash.
# Measures whether prepending a deterministic map (quiet-env + quiet-map) to a
# code-localization task reduces cost & wall-clock with zero answer-quality
# regression. Arms: control (no map) | map (map prepended). See the design spec.
#
#   FM_TARGET=$PWD FM_MODEL=haiku FM_REPEATS=3 bench/enrichment.sh
#
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$ROOT/bench/enrichment-tasks.sh"

TARGET="${FM_TARGET:-$ROOT}"
MODEL="${FM_MODEL:-haiku}"
REPEATS="${FM_REPEATS:-3}"
ARMS="${FM_ARMS:-control map}"
BUDGET="${FM_BUDGET:-4000}"
OUT="${FM_OUT:-$ROOT/bench/enrichment-runs.jsonl}"
: > "$OUT"

MAP="$( { cd "$TARGET" && "$ROOT/core/quiet-env.sh"; echo; "$ROOT/core/quiet-map.sh"; } 2>/dev/null | head -c "$BUDGET" )"

run_one() { # arm task_idx rep
  local arm="$1" ti="$2" rep="$3" task="${FM_TASK_PROMPTS[$2]}" prompt j answer grade
  case "$arm" in
    map)    prompt=$(printf 'Repo & environment map (deterministic):\n\n%s\n\n%s' "$MAP" "$task") ;;
    *)      prompt="$task" ;;
  esac
  j=$(cd "$TARGET" && timeout 300 claude -p "$prompt" --model "$MODEL" --output-format json \
        --allowedTools "Bash" "Read" "Grep" "Glob" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} task${ti} rep${rep}: no output" >&2; return; }
  answer=$(printf '%s' "$j" | jq -r '.result // ""')
  grade=$(fm_grade "$ti" "$answer")
  printf '%s\n' "$j" | FM_ARM="$arm" FM_TI="$ti" FM_REP="$rep" FM_GRADE="$grade" python3 -c "
import sys,json,os
o=json.load(sys.stdin); u=o.get('usage',{}) or {}
inp=(u.get('input_tokens',0) or 0)+(u.get('cache_read_input_tokens',0) or 0)+(u.get('cache_creation_input_tokens',0) or 0)
rec={'arm':os.environ['FM_ARM'],'task':int(os.environ['FM_TI']),'rep':int(os.environ['FM_REP']),
     'input':inp,'output':u.get('output_tokens',0) or 0,'cost':o.get('total_cost_usd',0) or 0,
     'ms':o.get('duration_ms',0) or 0,'turns':o.get('num_turns',0),'pass':(os.environ['FM_GRADE']=='pass')}
print(json.dumps(rec))
" >> "$OUT"
  echo "  ${grade} ${arm} task${ti} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS arms='$ARMS' target=$TARGET" >&2
for ti in "${!FM_TASK_PROMPTS[@]}"; do
  for rep in $(seq 1 "$REPEATS"); do
    for arm in $ARMS; do run_one "$arm" "$ti" "$rep"; done
  done
done
echo >&2
python3 "$ROOT/bench/enrichment-report.py" "$OUT"
