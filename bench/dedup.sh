#!/usr/bin/env bash
#
# A/B: does quiet_cmd_dedup (already shipped) save cost when the agent re-reads
# the same file twice in one session via cat?
#   A baseline — no hooks (both cat calls execute and return full content)
#   B dedup    — PreToolUse Bash hook (second unchanged cat → stub)
#
# Per-job fixture isolation: each run_one() creates its own tmp dir to avoid
# race conditions when running in parallel (lesson from Task 1).
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/dedup.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/dedup-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

PRE_HOOK='"PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
BASE_SET="$(mktemp)";  printf '{}\n' > "$BASE_SET"
DEDUP_SET="$(mktemp)"; printf '{ "hooks": { %s } }\n' "$PRE_HOOK" > "$DEDUP_SET"

TASK='First, run: cat package.json   to find the version field. Then modify startup.sh so it prints "version: X.Y.Z" (using the actual version from package.json) before "starting...". Run: cat package.json again to confirm the version before finalizing.'

run_one() { # arm settings rep jobfile
  local arm="$1" set="$2" rep="$3" jobfile="${4:-}"
  # Each job gets its own isolated fixture directory to avoid parallel race conditions
  local target
  target="$(mktemp -d)"
  cat > "$target/package.json" <<'JSON'
{"name":"dedup-fixture","version":"2.7.1","description":"bench fixture"}
JSON
  cat > "$target/startup.sh" <<'SH'
#!/usr/bin/env bash
echo "starting..."
SH
  local j
  j=$(cd "$target" && timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "Bash" "Edit" "Write" 2>/dev/null)
  local ok=0
  if grep -qE 'version.*2\.7\.1|2\.7\.1.*version' "$target/startup.sh" 2>/dev/null; then
    ok=1
  fi
  rm -rf "$target"
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
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

echo "model=$MODEL repeats=$REPEATS parallel=$PARALLEL" >&2

# Warmup run (baseline, no output captured)
run_one warmup "$BASE_SET" 0 /dev/null

export -f run_one
export MODEL TASK BASE_SET DEDUP_SET OUT

JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline %s %s\n' "$BASE_SET"  "$rep" >> "$JOBLIST"
  printf 'dedup    %s %s\n' "$DEDUP_SET" "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 3 bash -c 'run_one "$1" "$2" "$3" "$OUT.job.$1.$3"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.* "$BASE_SET" "$DEDUP_SET"

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
arms=['baseline','dedup']
labels={'baseline':'A baseline (no dedup)','dedup':'B dedup (quiet_cmd_dedup active)'}
print("# Same-session cat dedup benchmark — mean per run")
print("| arm | cost $ | fresh in | turns | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['turns']):.1f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['dedup']['cost']:
    bc=mean(by['baseline']['cost']); dc=mean(by['dedup']['cost'])
    print(f"\ndedup vs baseline: cost {100*(bc-dc)/bc:+.1f}% (positive=cheaper)")
    u,p=mannwhitneyu(by['baseline']['cost'],by['dedup']['cost'],alternative='greater')
    print(f"Mann-Whitney U (cost): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
    nb=len(oks['baseline']); nd=len(oks['dedup'])
    _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks['dedup']),nd-sum(oks['dedup'])]])
    print(f"Fisher's exact (correctness): p={fp:.4g}")
    if p<0.05 and fp>0.05: verdict="SHIP (existing feature confirmed)"
    elif dc>bc: verdict="DO NOT SHIP (regression)"
    else: verdict="INCONCLUSIVE"
    print(f"\n**Verdict: {verdict}**")
PY
