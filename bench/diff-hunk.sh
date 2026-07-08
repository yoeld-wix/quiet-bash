#!/usr/bin/env bash
#
# A/B: does hunk-only mode (stripping context lines from git diff output)
# reduce cost on a diff-inspection task, with no correctness loss?
#   A baseline   — full diff output (context lines included)
#   B hunk-only  — QUIET_DIFF_HUNK_ONLY=1 (context lines stripped)
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/diff-hunk.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/diff-hunk-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

TARGET="$ROOT"   # use this repo — it has real diffs

PRE_HOOK='"PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
BASE_SET="$(mktemp)";    printf '{}\n' > "$BASE_SET"
HUNK_SET="$(mktemp)";    printf '{ "hooks": { %s } }\n' "$PRE_HOOK" > "$HUNK_SET"

# Task: inspect last commit diff to count changed files
TASK='Run: git diff HEAD~1 HEAD   then tell me: (1) how many files changed, (2) the name of the file with the most lines added. Reply as: FILES: N MOST_ADDED: filename'

# Ground truth from the real repo
N_FILES=$(git -C "$ROOT" diff --stat HEAD~1 HEAD 2>/dev/null | tail -1 | grep -oE '[0-9]+ file' | grep -oE '[0-9]+')
MOST_ADDED=$(git -C "$ROOT" diff --stat HEAD~1 HEAD 2>/dev/null | grep '|' | sort -t'|' -k2 -rn | head -1 | awk '{print $1}' | xargs basename 2>/dev/null || echo "")

run_one() { # arm settings hunk_only rep
  local arm="$1" set="$2" hunk="$3" rep="$4"
  local j
  j=$(cd "$TARGET" && QUIET_DIFF_HUNK_ONLY="$hunk" timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "Bash" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local result ok=0
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  printf '%s' "$result" | grep -qi "FILES: $N_FILES" && ok=1
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
" >> "$OUT"
  echo "  ✓ ${arm} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS n_files=$N_FILES most_added=$MOST_ADDED" >&2
run_one warmup "$BASE_SET" 0 0

export -f run_one
export TARGET MODEL TASK BASE_SET HUNK_SET N_FILES MOST_ADDED OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline  %s 0 %s\n' "$BASE_SET" "$rep" >> "$JOBLIST"
  printf 'hunk-only %s 1 %s\n' "$HUNK_SET" "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 4 bash -c 'run_one "$1" "$2" "$3" "$4"' _ < "$JOBLIST"
rm -f "$JOBLIST" "$BASE_SET" "$HUNK_SET"

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
try:
    from scipy.stats import mannwhitneyu, fisher_exact
    has_scipy=True
except ImportError:
    has_scipy=False
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(lambda:collections.defaultdict(list))
oks=collections.defaultdict(list)
for r in rows:
    for k in ('fresh','cache_read','output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(bool(r.get('ok',False)))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','hunk-only']
labels={'baseline':'A baseline (full diff)','hunk-only':'B hunk-only (context stripped)'}
print("# Diff hunk-only benchmark — mean per run")
print("| arm | cost $ | fresh in | turns | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['turns']):.1f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['hunk-only']['cost']:
    bc=mean(by['baseline']['cost']); hc=mean(by['hunk-only']['cost'])
    print(f"\nhunk-only vs baseline: cost {100*(bc-hc)/bc:+.1f}% (positive=cheaper)")
    if has_scipy:
        u,p=mannwhitneyu(by['baseline']['cost'],by['hunk-only']['cost'],alternative='greater')
        print(f"Mann-Whitney U (cost): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
        nb=len(oks['baseline']); nh=len(oks['hunk-only'])
        _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks['hunk-only']),nh-sum(oks['hunk-only'])]])
        print(f"Fisher's exact (correctness): p={fp:.4g}")
        if p<0.05 and fp>0.05: verdict="SHIP"
        elif hc>bc: verdict="DO NOT SHIP"
        else: verdict="INCONCLUSIVE"
        print(f"\n**Verdict: {verdict}**")
    else:
        print("(scipy not available — skipping significance tests)")
        if hc < bc: verdict="SHIP (cost reduced, no scipy for significance)"
        elif hc > bc: verdict="DO NOT SHIP"
        else: verdict="INCONCLUSIVE"
        print(f"\n**Verdict: {verdict}**")
PY
