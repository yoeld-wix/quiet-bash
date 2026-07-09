#!/usr/bin/env bash
#
# A/B: does a minimal "no preamble, no postamble" directive reduce output tokens
# on a simple code-generation task, without affecting pass-rate?
#   A baseline       — no directive
#   B anti-preamble  — one-sentence rule: no acknowledgment, no closing summary
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/anti-preamble.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/anti-preamble-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

DIRECTIVE='Do not start your response with an acknowledgment ("Sure", "Of course", "I will", "Here is", etc.) and do not end with a closing remark ("Let me know", "Hope this helps", etc.). Output the result directly.'

TASK='Write a bash function called count_lines that takes one filename argument and prints the number of lines in that file. Output only the function definition, nothing else.'

grade() { # result_text
  # Pass if result contains a valid bash function definition
  printf '%s' "$1" | grep -qE 'count_lines\s*\(\s*\)|function\s+count_lines' && echo "1" || echo "0"
}

run_one() { # arm use_directive rep [jobfile]
  local arm="$1" use_dir="$2" rep="$3" jobfile="${4:-}"
  local j
  if [ "$use_dir" = "1" ]; then
    j=$(timeout 60 claude -p "$TASK" \
          --model "$MODEL" --output-format json \
          --append-system-prompt "$DIRECTIVE" \
          --allowedTools "" 2>/dev/null)
  else
    j=$(timeout 60 claude -p "$TASK" \
          --model "$MODEL" --output-format json \
          --allowedTools "" 2>/dev/null)
  fi
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local result ok
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  ok=$(grade "$result")
  local dest="${jobfile:-$OUT}"
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
rec={'arm':'$arm','rep':$rep,
     'output':u.get('output_tokens',0),
     'cost':o.get('total_cost_usd',0),'turns':o.get('num_turns',0),
     'ok': $ok}
sys.stdout.write(json.dumps(rec)+chr(10))
" > "$dest"
  echo "  ✓ ${arm} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS parallel=$PARALLEL" >&2
run_one warmup 0 0 /dev/null

export -f run_one grade
export TASK MODEL DIRECTIVE OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline       0 %s\n' "$rep" >> "$JOBLIST"
  printf 'anti-preamble  1 %s\n' "$rep" >> "$JOBLIST"
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
    for k in ('output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(bool(r.get('ok',False)))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','anti-preamble']
labels={'baseline':'A baseline (no directive)','anti-preamble':'B anti-preamble (directive)'}
print("# Anti-preamble directive benchmark — mean per run")
print("| arm | cost $ | output tok | turns | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['output']):,.0f} | {mean(by[a]['turns']):.1f} | {ok}/{n} | {n} |")
if by['baseline']['output'] and by['anti-preamble']['output']:
    bc=mean(by['baseline']['cost']); ac=mean(by['anti-preamble']['cost'])
    bo=mean(by['baseline']['output']); ao=mean(by['anti-preamble']['output'])
    print(f"\nanti-preamble vs baseline: output tok {100*(bo-ao)/bo:+.1f}%, cost {100*(bc-ac)/bc:+.1f}% (positive=fewer/cheaper)")
    u,p=mannwhitneyu(by['baseline']['output'],by['anti-preamble']['output'],alternative='greater')
    print(f"Mann-Whitney U (output tok): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
    nb=len(oks['baseline']); na=len(oks['anti-preamble'])
    _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks['anti-preamble']),na-sum(oks['anti-preamble'])]])
    print(f"Fisher's exact (correctness): p={fp:.4g}")
    if p<0.05 and fp>0.05: verdict="SHIP"
    elif ao>bo: verdict="DO NOT SHIP"
    else: verdict="INCONCLUSIVE"
    print(f"\n**Verdict: {verdict}**")
PY
