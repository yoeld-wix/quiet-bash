#!/usr/bin/env bash
#
# A/B: does placing the session-start injection as a first-turn user message
# (instead of in the system prompt on every turn) reduce cost on a multi-turn
# session?
#   A system-prompt — injected context in --append-system-prompt (re-sent every turn)
#   B first-turn    — injected context as the first user message (scrolls off)
#
# Drives a 5-turn sequence: each turn asks a simple read-only question about
# this repo. Measures cumulative cost across all 5 turns.
# NOTE: calls are independent -p calls (not --continue); we are testing
# the overhead of the system-prompt injection vs a one-time first-turn injection.
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=10 QB_PARALLEL=2 bench/injection-placement.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-10}"
PARALLEL="${QB_PARALLEL:-2}"
OUT="${QB_OUT:-$ROOT/bench/injection-placement-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

TARGET="$ROOT"
REPOMAP_OUT=$(bash "$ROOT/core/quiet-repomap.sh" 2>/dev/null || echo "[repomap unavailable]")
INJECTION="[Orientation context]
$REPOMAP_OUT"

# 5 read-only questions about this repo
T0="What language is most of this codebase written in?"
T1="How many files are in the core/ directory?"
T2="What is the name of the main adapter for Claude Code?"
T3="What does the quiet-wait script do? One sentence."
T4="Name any two bench scripts in the bench/ directory."

run_one() { # arm use_system rep [jobfile]
  local arm="$1" use_sys="$2" rep="$3" jobfile="${4:-}"
  local total_cost=0 ok=1
  local turns=("$T0" "$T1" "$T2" "$T3" "$T4")

  for i in 0 1 2 3 4; do
    local prompt="${turns[$i]}"
    local j
    if [ "$i" = "0" ] && [ "$use_sys" = "0" ]; then
      # first-turn arm: prepend injection to first user message only
      prompt="$INJECTION

$prompt"
    fi
    if [ "$use_sys" = "1" ]; then
      j=$(cd "$TARGET" && timeout 90 claude -p "$prompt" \
            --model "$MODEL" --output-format json \
            --append-system-prompt "$INJECTION" \
            --allowedTools "Bash" "Read" 2>/dev/null)
    else
      j=$(cd "$TARGET" && timeout 90 claude -p "$prompt" \
            --model "$MODEL" --output-format json \
            --allowedTools "Bash" "Read" 2>/dev/null)
    fi
    [ -z "$j" ] && { ok=0; break; }
    local turn_cost
    turn_cost=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_cost_usd',0))" 2>/dev/null)
    total_cost=$(python3 -c "print($total_cost + $turn_cost)")
  done

  local dest="${jobfile:-$OUT}"
  printf '{"arm":"%s","rep":%s,"cost":%s,"ok":%s}\n' "$arm" "$rep" "$total_cost" "$ok" >> "$dest"
  echo "  ✓ ${arm} rep${rep} total=$total_cost" >&2
}

echo "model=$MODEL repeats=$REPEATS (each rep = 5 turns)" >&2

export -f run_one
export TARGET MODEL INJECTION OUT T0 T1 T2 T3 T4

JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'system-prompt 1 %s\n' "$rep" >> "$JOBLIST"
  printf 'first-turn 0 %s\n' "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 3 bash -c 'run_one "$1" "$2" "$3" "$OUT.job.$1.$3"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.*

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
from scipy.stats import mannwhitneyu
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(list)
for r in rows:
    by[r['arm']].append(r.get('cost',0))
def mean(x): return statistics.mean(x) if x else 0
arms=['system-prompt','first-turn']
labels={'system-prompt':'A system-prompt (re-sent every turn)','first-turn':'B first-turn (injected once)'}
print("# Injection placement benchmark — cumulative 5-turn cost per rep")
print("| arm | cost $ (5-turn total) | runs |")
print("|---|--:|--:|")
for a in arms:
    if not by[a]: continue
    print(f"| {labels[a]} | {mean(by[a]):.4f} | {len(by[a])} |")
if by['system-prompt'] and by['first-turn']:
    sc=mean(by['system-prompt']); fc=mean(by['first-turn'])
    print(f"\nfirst-turn vs system-prompt: cost {100*(sc-fc)/sc:+.1f}% (positive=cheaper)")
    u,p=mannwhitneyu(by['system-prompt'],by['first-turn'],alternative='greater')
    print(f"Mann-Whitney U: p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
    if p<0.05: verdict="SHIP"
    elif fc>sc: verdict="DO NOT SHIP"
    else: verdict="INCONCLUSIVE"
    print(f"\n**Verdict: {verdict}**")
PY
