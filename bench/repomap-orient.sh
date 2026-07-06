#!/usr/bin/env bash
#
# Live A/B for quiet-repomap (docs/research/cost-levers-2026-07-update.md
# candidate #3): does surfacing a cross-file relevance ranking up front save
# exploration turns (and cost) on an orientation task, vs. today's baseline of
# figuring it out via ls/grep/reads?
#
# Two arms, same synthetic fixture (bench/fixtures/make-repomap-fixture.sh —
# one file imported by 9 others, unambiguous ground truth), same task:
#   baseline — agent explores cold with Bash only
#   repomap  — the quiet-repomap.sh output is prepended to the task, as if a
#              session-start hook had already surfaced it (mirrors how
#              quiet-env/quiet-map are actually used)
#
# Usage:
#   QB_MODEL=claude-haiku-4-5 QB_REPEATS=8 QB_PARALLEL=4 bench/repomap-orient.sh
#
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-8}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/repomap-orient-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

TARGET="$(mktemp -d)"
bash "$ROOT/bench/fixtures/make-repomap-fixture.sh" "$TARGET" >&2
REPOMAP_OUT="$(cd "$TARGET" && bash "$ROOT/core/quiet-repomap.sh")"
TRUTH="core/logger.js"

TASK_BASE='This is an unfamiliar codebase. Identify the single file that the rest of the codebase depends on most — the most central/foundational module, the one most other files import. Reply with only its relative file path, nothing else.'

run_one() { # arm withmap rep [jobfile]
  local arm="$1" withmap="$2" rep="$3" jobfile="${4:-}"
  local prompt="$TASK_BASE"
  if [ "$withmap" = "1" ]; then
    prompt="[Orientation info, already gathered at session start]
$REPOMAP_OUT

$TASK_BASE"
  fi
  local j
  j=$(cd "$TARGET" && timeout 90 claude -p "$prompt" \
        --model "$MODEL" --output-format json \
        --allowedTools "Bash" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local dest="${jobfile:-$OUT}"
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
fresh=u.get('input_tokens',0) or 0
cr=u.get('cache_read_input_tokens',0) or 0
cc=u.get('cache_creation_input_tokens',0) or 0
result=(o.get('result','') or '').strip()
lines=[l.strip() for l in result.split(chr(10)) if l.strip()]
last=lines[-1] if lines else ''
ok = ('$TRUTH' in result) or ('logger.js' in last)
rec={'arm':'$arm','rep':$rep,
     'fresh':fresh,'cache_read':cr,'cache_creation':cc,
     'output':u.get('output_tokens',0) or 0,
     'cost':o.get('total_cost_usd',0) or 0,'ms':o.get('duration_ms',0) or 0,'turns':o.get('num_turns',0),
     'ok': ok, 'result': result}
sys.stdout.write(json.dumps(rec) + chr(10))
" > "$dest"
  echo "  ✓ ${arm} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS parallel=$PARALLEL target=$TARGET truth=$TRUTH" >&2
run_one warmup 0 0 /dev/null

export -f run_one
export TARGET MODEL TRUTH TASK_BASE REPOMAP_OUT OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline 0 %s\n' "$rep" >> "$JOBLIST"
  printf 'repomap 1 %s\n' "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 3 bash -c 'run_one "$1" "$2" "$3" "$OUT.job.$1.$3"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.*
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
arms=['baseline','repomap']
labels={'baseline':'A baseline (cold explore)','repomap':'B repomap (pre-surfaced)'}
print("# quiet-repomap orientation benchmark — mean per run")
print("| arm | cost $ | turns | output tok | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(1 for x in oks[a] if x)
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['turns']):.1f} | {mean(by[a]['output']):,.0f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['repomap']['cost']:
    bc=mean(by['baseline']['cost']); rc=mean(by['repomap']['cost'])
    bt=mean(by['baseline']['turns']); rt=mean(by['repomap']['turns'])
    print(f"\nrepomap vs baseline: cost {100*(bc-rc)/bc:+.1f}% (positive=cheaper), turns {bt:.1f} -> {rt:.1f}")

    from scipy.stats import mannwhitneyu
    u, p = mannwhitneyu(by['baseline']['cost'], by['repomap']['cost'], alternative='greater')
    print(f"\nMann-Whitney U (cost: baseline > repomap): U={u:.1f}, p={p:.4g}", "SIGNIFICANT (p<0.05)" if p<0.05 else "not significant")
    ut, pt = mannwhitneyu(by['baseline']['turns'], by['repomap']['turns'], alternative='greater')
    print(f"Mann-Whitney U (turns: baseline > repomap): U={ut:.1f}, p={pt:.4g}", "SIGNIFICANT (p<0.05)" if pt<0.05 else "not significant")
PY
