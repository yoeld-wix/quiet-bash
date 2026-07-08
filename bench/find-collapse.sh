#!/usr/bin/env bash
#
# A/B: does quiet-bash's find/ls wrapping save cost on a task that searches
# for files, vs cold baseline with no hooks?
#   A baseline — no hooks (full find output reaches context)
#   B wrapped  — PreToolUse Bash hook (find gets redirected+summarised)
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/find-collapse.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/find-collapse-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

PRE_HOOK='"PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
BASE_SET="$(mktemp)";    printf '{}\n' > "$BASE_SET"
WRAP_SET="$(mktemp)";    printf '{ "hooks": { %s } }\n' "$PRE_HOOK" > "$WRAP_SET"

TASK='Run: find . -name "*.sh"   then tell me how many shell scripts are in each subdirectory. Reply with one line per subdirectory: "dirname: N scripts".'

run_one() { # arm settings rep [jobfile]
  local arm="$1" set="$2" rep="$3" jobfile="${4:-}"
  # Per-job fixture isolation: each run gets its own tmp dir
  local tmpdir
  tmpdir=$(mktemp -d)
  bash "$ROOT/bench/fixtures/make-find-fixture.sh" "$tmpdir" 2>/dev/null
  local j
  j=$(cd "$tmpdir" && timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "Bash" 2>/dev/null)
  rm -rf "$tmpdir"
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local result ok=0
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  # pass if model mentions "40" at least 4 times (one per dir)
  cnt=$(printf '%s' "$result" | grep -cE '40|forty' 2>/dev/null || true)
  [ "$cnt" -ge 4 ] && ok=1
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
" >> "$dest"
  echo "  ✓ ${arm} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS" >&2

# Warmup with its own isolated fixture
WARMUP_DIR=$(mktemp -d)
bash "$ROOT/bench/fixtures/make-find-fixture.sh" "$WARMUP_DIR" 2>/dev/null
(cd "$WARMUP_DIR" && timeout 120 claude -p "$TASK" \
  --model "$MODEL" --output-format json --settings "$BASE_SET" \
  --allowedTools "Bash" 2>/dev/null) > /dev/null || true
rm -rf "$WARMUP_DIR"
echo "  warmup done" >&2

export -f run_one
export MODEL TASK BASE_SET WRAP_SET OUT ROOT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline %s %s\n' "$BASE_SET" "$rep" >> "$JOBLIST"
  printf 'wrapped  %s %s\n' "$WRAP_SET" "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 3 bash -c 'run_one "$1" "$2" "$3" "$OUT.job.$1.$3"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* >> "$OUT" 2>/dev/null
rm -f "$OUT".job.* "$BASE_SET" "$WRAP_SET"

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(lambda:collections.defaultdict(list))
oks=collections.defaultdict(list)
for r in rows:
    for k in ('fresh','cache_read','output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(bool(r.get('ok',False)))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','wrapped']
labels={'baseline':'A baseline (no hooks)','wrapped':'B wrapped (find collapse)'}
print("# find/ls collapse benchmark — mean per run")
print("| arm | cost $ | fresh in | turns | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['turns']):.1f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['wrapped']['cost']:
    bc=mean(by['baseline']['cost']); wc=mean(by['wrapped']['cost'])
    print(f"\nwrapped vs baseline: cost {100*(bc-wc)/bc:+.1f}% (positive=cheaper)")
    try:
        from scipy.stats import mannwhitneyu, fisher_exact
        u,p=mannwhitneyu(by['baseline']['cost'],by['wrapped']['cost'],alternative='greater')
        print(f"Mann-Whitney U (cost): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
        nb=len(oks['baseline']); nw=len(oks['wrapped'])
        _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks['wrapped']),nw-sum(oks['wrapped'])]])
        print(f"Fisher's exact (correctness): p={fp:.4g}")
        if p<0.05 and fp>0.05: verdict="SHIP"
        elif wc>bc: verdict="DO NOT SHIP"
        else: verdict="INCONCLUSIVE"
        print(f"\n**Verdict: {verdict}**")
    except ImportError:
        print("(scipy not available — skipping significance tests)")
        if wc < bc: verdict="INCONCLUSIVE (no stats)"
        else: verdict="DO NOT SHIP"
        print(f"\n**Verdict: {verdict}**")
PY
