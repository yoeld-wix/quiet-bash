#!/usr/bin/env bash
#
# Live A/B for the JSON auto-stats prototype (QUIET_JSON_AUTOSTATS=1 in core/quiet-json.sh).
#
# Question: when a task needs an aggregate answer over a large JSON record
# array (a count-by-status, an average price), does auto-computing field stats
# into the collapsed preview actually save a round trip (and cost), or does the
# bigger preview + occasional wrong-without-querying answers wash it out? A
# small (n=4) pilot found cost ~flat but a correctness gap (2/4 vs 4/4) — this
# run scales up and fits a logistic regression (GLM, binomial/logit) on
# correctness ~ arm to check whether that gap is statistically real.
#
# Two arms, same task, same large record-array fixture (5,000 uniform records):
#   baseline  — today's shipped preview (3-item sample + shape fold only)
#   autostats — QUIET_JSON_AUTOSTATS=1 — preview also carries per-field stats
#
# Runs REPEATS x 2 arms concurrently (QB_PARALLEL workers) since sequential
# would take too long at this scale.
#
# Usage:
#   QB_MODEL=claude-haiku-4-5 QB_REPEATS=40 QB_PARALLEL=8 bench/json-autostats.sh
#
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-3}"
PARALLEL="${QB_PARALLEL:-8}"
OUT="${QB_OUT:-$ROOT/bench/json-autostats-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

TARGET="$(mktemp -d)"
python3 - "$TARGET/orders.json" <<'PY'
import json, random, sys
random.seed(42)
owners = ['alice', 'bob', 'carol', 'dave', 'erin']
statuses = ['open', 'closed', 'shipped']
rows = [{'id': i, 'status': statuses[i % 3], 'price': round(random.uniform(10, 500), 2), 'owner': owners[i % 5]}
        for i in range(5000)]
open(sys.argv[1], 'w').write(json.dumps(rows))
PY
python3 - "$TARGET/orders.json" > "$TARGET/truth.txt" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
open_count = sum(1 for r in rows if r['status'] == 'open')
avg_price = sum(r['price'] for r in rows) / len(rows)
print(f"{open_count} {avg_price:.2f}")
PY
read -r TRUE_OPEN TRUE_AVG < "$TARGET/truth.txt"
echo "ground truth: open=$TRUE_OPEN avg_price=$TRUE_AVG" >&2

PRE_HOOK='"PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
SET="$(mktemp)"; printf '{ "hooks": { %s } }\n' "$PRE_HOOK" > "$SET"

TASK='Run: cat orders.json   Then reply with exactly two numbers separated by a space: (1) how many orders have status "open", (2) the average price across ALL orders rounded to 2 decimals. No other text.'

run_one() { # arm autostats rep [jobfile]
  local arm="$1" autostats="$2" rep="$3" jobfile="${4:-}"
  local j
  j=$(cd "$TARGET" && QUIET_JSON_AUTOSTATS="$autostats" timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json --settings "$SET" \
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
# Grade the LAST non-empty line, not the first token: a model given auto-stats
# often cites its source before the final answer ('Based on the stats... \n\n1667 255.18'),
# which is correct but not first-token-parseable. (Found via a mis-graded n=40 run.)
lines=[ln.strip() for ln in result.split(chr(10)) if ln.strip()]
words=lines[-1].split() if lines else []
ok=False
try:
    ok = len(words)>=2 and words[0].strip('*:')=='$TRUE_OPEN' and abs(float(words[1].strip('*'))-$TRUE_AVG)<0.01
except Exception:
    ok=False
rec={'arm':'$arm','rep':$rep,
     'fresh':fresh,'cache_read':cr,'cache_creation':cc,
     'output':u.get('output_tokens',0) or 0,
     'cost':o.get('total_cost_usd',0) or 0,'ms':o.get('duration_ms',0) or 0,'turns':o.get('num_turns',0),
     'ok': ok, 'result': result}
sys.stdout.write(json.dumps(rec) + chr(10))
" > "$dest"
  echo "  ✓ ${arm} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS parallel=$PARALLEL target=$TARGET" >&2
# Warm the shared prompt-cache prefix (system + tools + task) before measuring,
# so job1 doesn't eat a one-off cold-cache tax that has nothing to do with the
# feature under test — both arms share this prefix.
run_one warmup 0 0 /dev/null

# macOS ships bash 3.2 (no `wait -n`), so use xargs -P for portable concurrency
# instead of manual job-slot tracking.
export -f run_one
export TARGET SET TASK MODEL TRUE_OPEN TRUE_AVG OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline 0 %s\n' "$rep" >> "$JOBLIST"
  printf 'autostats 1 %s\n' "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 3 bash -c 'run_one "$1" "$2" "$3" "$OUT.job.$1.$3"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.* "$SET"
rm -rf "$TARGET"

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
import numpy as np
from scipy.stats import norm, fisher_exact

rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(lambda:collections.defaultdict(list))
oks=collections.defaultdict(list)
for r in rows:
    for k in ('fresh','cache_read','cache_creation','output','cost','ms','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(r.get('ok', False))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','autostats']
labels={'baseline':'A baseline (no autostats)','autostats':'B autostats (QUIET_JSON_AUTOSTATS=1)'}
print("# JSON auto-stats benchmark — mean per run")
print("| arm | cost $ | fresh in | cache-read | output | turns | time s | correct | runs |")
print("|---|--:|--:|--:|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(1 for x in oks[a] if x)
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['cache_read']):,.0f} | {mean(by[a]['output']):,.0f} | {mean(by[a]['turns']):.1f} | {mean(by[a]['ms'])/1000:.1f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['autostats']['cost']:
    bc=mean(by['baseline']['cost']); ac=mean(by['autostats']['cost'])
    print(f"\n_autostats vs baseline: cost {100*(bc-ac)/bc:+.1f}% (positive = cheaper)._")

# --- GLM (binomial/logit) on correctness ~ arm, fit by hand via IRLS (no statsmodels dep) ---
if by['baseline']['cost'] and by['autostats']['cost']:
    y = np.array([1 if v else 0 for v in oks['baseline']] + [1 if v else 0 for v in oks['autostats']], dtype=float)
    x = np.array([0]*len(oks['baseline']) + [1]*len(oks['autostats']), dtype=float)
    X = np.column_stack([np.ones_like(x), x])

    n_base, n_auto = len(oks['baseline']), len(oks['autostats'])
    k_base, k_auto = sum(oks['baseline']), sum(oks['autostats'])
    print(f"\n## Significance test: correctness ~ arm (n={n_base+n_auto})")
    print(f"contingency: baseline {k_base}/{n_base} correct, autostats {k_auto}/{n_auto} correct")

    if k_base in (0, n_base) or k_auto in (0, n_auto):
        print("**Perfect/quasi-complete separation** (an arm is 100% or 0% correct) — logistic")
        print("regression coefficients diverge; falling back to Fisher's exact test only.")
        _, p = fisher_exact([[k_base, n_base-k_base],[k_auto, n_auto-k_auto]])
        print(f"Fisher's exact test p-value: {p:.4g}")
    else:
        beta = np.zeros(2)
        for _ in range(100):
            eta = X @ beta
            mu = 1/(1+np.exp(-eta))
            w = np.clip(mu*(1-mu), 1e-9, None)
            XtWX = X.T @ (X * w[:, None])
            grad = X.T @ (y - mu)
            try:
                delta = np.linalg.solve(XtWX, grad)
            except np.linalg.LinAlgError:
                delta = np.linalg.lstsq(XtWX, grad, rcond=None)[0]
            beta_new = beta + delta
            if np.max(np.abs(beta_new - beta)) < 1e-10:
                beta = beta_new
                break
            beta = beta_new
        eta = X @ beta
        mu = 1/(1+np.exp(-eta))
        w = np.clip(mu*(1-mu), 1e-9, None)
        XtWX = X.T @ (X * w[:, None])
        cov = np.linalg.inv(XtWX)
        se = np.sqrt(np.diag(cov))
        z = beta/se
        pval = 2*(1-norm.cdf(np.abs(z)))
        print(f"GLM (binomial, logit link) fit via IRLS: correctness ~ 1 + is_autostats")
        print(f"  intercept: {beta[0]:+.3f} (se {se[0]:.3f})  — baseline log-odds of correct")
        print(f"  is_autostats coef: {beta[1]:+.3f} (se {se[1]:.3f}, z={z[1]:.2f}, p={pval[1]:.4g})")
        odds_ratio = np.exp(beta[1])
        print(f"  odds ratio (autostats vs baseline): {odds_ratio:.2f}x")
        _, fp = fisher_exact([[k_base, n_base-k_base],[k_auto, n_auto-k_auto]])
        print(f"  cross-check, Fisher's exact test p-value: {fp:.4g}")
        sig = "SIGNIFICANT (p<0.05)" if pval[1] < 0.05 else "not significant at p<0.05"
        print(f"  verdict: {sig}")
PY
