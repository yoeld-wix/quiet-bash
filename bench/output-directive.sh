#!/usr/bin/env bash
#
# A/B: does prepending output-styles/concise.md to the system prompt reduce
# output tokens and cost on a mid-complexity coding task, with zero quality
# regression?
#   A baseline — no output style directive
#   B concise  — system prompt includes output-styles/concise.md verbatim
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/output-directive.sh
set -euo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/output-directive-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

CONCISE_MD="$(cat "$ROOT/output-styles/concise.md")"

TASK='Add a --verbose flag to quiet-map-stub.sh: when passed, print "verbose mode on" before the normal output. Update the file in place.'

run_one() { # arm concise rep [jobfile]
  local arm="$1" use_concise="$2" rep="$3" jobfile="${4:-}"
  local extra_system=""
  [ "$use_concise" = "1" ] && extra_system="$CONCISE_MD"

  # Each parallel job gets its own isolated directory
  local tgt; tgt=$(mktemp -d)

  # Write the initial fixture into $tgt/
  cat > "$tgt/quiet-map-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "map output"
STUB

  local j
  if [ -n "$extra_system" ]; then
    j=$(cd "$tgt" && timeout 120 claude -p "$TASK" \
          --model "$MODEL" --output-format json \
          --append-system-prompt "$extra_system" \
          --allowedTools "Bash" "Edit" "Write" "Read" 2>/dev/null)
  else
    j=$(cd "$tgt" && timeout 120 claude -p "$TASK" \
          --model "$MODEL" --output-format json \
          --allowedTools "Bash" "Edit" "Write" "Read" 2>/dev/null)
  fi
  if [ -z "$j" ]; then
    echo "  ! ${arm} rep${rep}: no output" >&2
    rm -rf "$tgt"
    return
  fi
  local ok
  # Grade by checking $tgt/quiet-map-stub.sh
  grep -q '\-\-verbose\|verbose' "$tgt/quiet-map-stub.sh" 2>/dev/null && ok=1 || ok=0
  local dest="${jobfile:-$OUT}"
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
rec={'arm':'$arm','rep':$rep,
     'fresh':u.get('input_tokens',0),'cache_read':u.get('cache_read_input_tokens',0),
     'cache_creation':u.get('cache_creation_input_tokens',0),
     'output':u.get('output_tokens',0),
     'cost':o.get('total_cost_usd',0),'turns':o.get('num_turns',0),
     'ok': $ok}
sys.stdout.write(json.dumps(rec)+chr(10))
" > "$dest"
  echo "  ✓ ${arm} rep${rep}" >&2
  rm -rf "$tgt"
}

echo "model=$MODEL repeats=$REPEATS parallel=$PARALLEL" >&2
run_one warmup 0 0 /dev/null

export -f run_one
export TASK MODEL CONCISE_MD OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline 0 %s\n' "$rep" >> "$JOBLIST"
  printf 'concise  1 %s\n' "$rep" >> "$JOBLIST"
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
    for k in ('fresh','cache_read','cache_creation','output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(bool(r.get('ok',False)))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','concise']
labels={'baseline':'A baseline (no directive)','concise':'B concise (output-styles/concise.md)'}
print("# Output-directive benchmark — mean per run")
print("| arm | cost $ | output tok | turns | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['output']):,.0f} | {mean(by[a]['turns']):.1f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['concise']['cost']:
    bc=mean(by['baseline']['cost']); cc=mean(by['concise']['cost'])
    bo=mean(by['baseline']['output']); co_=mean(by['concise']['output'])
    print(f"\nconcise vs baseline: cost {100*(bc-cc)/bc:+.1f}%, output tok {100*(bo-co_)/bo:+.1f}% (positive=cheaper/fewer)")
    u,p=mannwhitneyu(by['baseline']['cost'],by['concise']['cost'],alternative='greater')
    print(f"Mann-Whitney U (cost): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
    nb=len(oks['baseline']); nc=len(oks['concise'])
    kb=sum(oks['baseline']); kc=sum(oks['concise'])
    _,fp=fisher_exact([[kb,nb-kb],[kc,nc-kc]])
    print(f"Fisher's exact (correctness): p={fp:.4g}")
    if p<0.05 and fp>0.05: verdict="SHIP"
    elif mean(by['concise']['cost'])>mean(by['baseline']['cost']): verdict="DO NOT SHIP"
    else: verdict="INCONCLUSIVE"
    print(f"\n**Verdict: {verdict}**")
PY
