# How to Test Cost-Reduction Candidates

A field guide to the A/B benchmarking methodology used in this project.
Every candidate goes through the same process — this doc is the single reference for how to design, run, and interpret a test.

---

## Why this matters

Token cost in an agentic session is noisy. Run-to-run variance is typically 60% of the mean (σ ≈ mean on a $0.05 session). A naive "I ran it twice and it was cheaper" observation is meaningless. This project has been burned by small-n results pointing the wrong direction (the JSON auto-stats n=4 overclaim, the agentic.sh n=8 input-token overclaim) — the methodology below exists to avoid repeating those mistakes.

**The rule:** trust direction only when you have n ≥ 20 reps per arm AND a significance test confirms the direction isn't noise.

---

## The cost equation

```
total_cost = (fresh_input × rate)
           + (output × ~3× rate)
           + (cache_creation × 1.25× rate)
           + (cache_read × 0.1× rate)
           + turns × transcript_regrowth
```

Each candidate attacks one or more of these terms. Know which term you're targeting before designing the test — it determines what to measure.

| Lever | What changes | Primary metric |
|-------|-------------|----------------|
| Fresh input tokens | Content sent that isn't cached | `input_tokens` in usage |
| Output tokens | Generated response length | `output_tokens` |
| Turns | Each turn re-sends the growing transcript | `num_turns` |
| Cache prefix | Fraction of input served from cache (0.1× price) | `cache_read / total_input` |
| Cache creation | New content written to cache (1.25× price) | `cache_creation_input_tokens` |

**Always measure cost $, not raw token counts.** `cache_read` tokens are billed ~10× cheaper than fresh tokens — a raw input sum that doesn't distinguish them will overstate or understate the real saving. Use `total_cost_usd` from `claude --output-format json`.

---

## Cache considerations

Cache is the most counterintuitive lever. These are the things that will mislead you if you ignore them:

### 1. A raw input-token sum includes cheap cache_read tokens

If your feature increases turn count (each turn re-reads the transcript), `cache_read` grows — and the raw input sum balloons even though cost barely moves. **Always split: report `fresh`, `cache_read`, `cache_creation`, and `cost $` separately.**

### 2. Rewrites can bust the cache prefix

Claude's prompt cache works on a stable prefix: if the first N tokens of a request are identical to a prior request, they're served from cache. If your hook rewrites tool output, the rewritten bytes become part of the transcript — and if they differ from what would have been there otherwise, they can break the cache prefix for all subsequent turns.

**Test for this:** run a 3-arm bench (baseline / hook-on / hook-off) and compare `cache_read %` across arms. If the hook arm has lower cache_read %, the rewrite is busting the prefix. See `bench/cache-health.sh`.

### 3. Cold-cache runs are confounded

If both arms share the same prompt prefix (same system prompt, same task), the first run of each session writes a new cache entry (`cache_creation`, billed 1.25×). If your A/B runs the two arms sequentially (A then B then A then B...), B arm benefits from A arm's warm cache while A arm always runs cold. **Fix:** alternate arms randomly, OR run a throwaway warmup call before measuring, OR use xargs -P parallel execution (both arms run concurrently, same cache state).

All bench scripts in this project use `run_one warmup 0 0 /dev/null` before the parallel dispatch for exactly this reason.

### 4. A "smaller payload = cheaper" intuition can be wrong

The MCP schema-deferral experiment shrank the tool schema payload by 99% — but cost went UP 74% because the extra round-trip (to discover the tool, then call it) added turns, and each extra turn re-processes the growing transcript as `cache_creation`. **Extra turns compound.** A feature that saves N tokens per turn but adds 1 extra turn can be net negative if N < (average transcript size / turn).

Rule of thumb: a feature that adds a turn is only worth it if it saves > 5,000 tokens per turn (rough break-even at a 50k-token session).

---

## Bench script template

Every bench script follows this exact structure (see `bench/repomap-orient.sh` or `bench/json-autostats.sh` for the canonical version):

```bash
#!/usr/bin/env bash
# [1-para description of what this tests and the arms]
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/NAME.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/NAME-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

# [Set up fixture / hook configs here]

run_one() { # arm <arm-specific-args> rep [jobfile]
  local arm="$1" ... rep="$N" jobfile="${last:-}"
  local j
  j=$(cd "$TARGET" && timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json \
        --allowedTools "Bash" ... 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  # Grade the result (deterministic regex, not LLM judgment)
  local ok=0
  printf '%s' "$result" | grep -qE 'pattern' && ok=1
  # Emit JSONL record
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
rec={'arm':'$arm','rep':$rep,
     'fresh':u.get('input_tokens',0),
     'cache_read':u.get('cache_read_input_tokens',0),
     'cache_creation':u.get('cache_creation_input_tokens',0),
     'output':u.get('output_tokens',0),
     'cost':o.get('total_cost_usd',0),
     'turns':o.get('num_turns',0),
     'ok': $ok}
sys.stdout.write(json.dumps(rec)+chr(10))
" > "${jobfile:-$OUT}"
  echo "  ✓ ${arm} rep${rep}" >&2
}

# Warmup: share a warm cache prefix before measuring
run_one warmup ... 0 /dev/null

# Parallel dispatch (macOS bash 3.2 safe — no `wait -n`)
export -f run_one
export TARGET MODEL TASK OUT ...
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline ... %s\n' "$rep" >> "$JOBLIST"
  printf 'feature  ... %s\n' "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n N bash -c 'run_one "$1" ... "$OUT.job.$1.$N"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.*

# Report with Mann-Whitney U
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
from scipy.stats import mannwhitneyu, fisher_exact
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
# ... (see any existing bench script for the full report block)
PY
```

---

## Grading

**Always grade deterministically.** Never use an LLM judge — it adds noise, cost, and latency. Use grep/regex/arithmetic on the model's output.

Good grader patterns:
```bash
# Check a specific string is present
printf '%s' "$result" | grep -qF "expected string" && ok=1

# Check a number is close enough
python3 -c "import sys; ok=abs(float('$result') - $truth) < 0.01; print(int(ok))"

# Check a file was modified correctly
grep -qE 'pattern' "$TARGET/some-file.sh" && ok=1
```

Bad grader patterns:
- "does the response look reasonable?" — LLM judge, don't do it
- Checking only the first token (the json-autostats grading bug) — check the last non-empty line
- Checking presence of a keyword that could appear in preamble — strip preamble first

---

## Statistical tests

### For continuous metrics (cost, turns, output tokens)

Use **Mann-Whitney U** (non-parametric, handles the non-normal distribution of LLM costs):

```python
from scipy.stats import mannwhitneyu
u, p = mannwhitneyu(by['baseline']['cost'], by['feature']['cost'], alternative='greater')
# alternative='greater': tests "baseline cost > feature cost" (feature is cheaper)
# p < 0.05 → the cost difference is statistically significant
```

### For binary metrics (pass/fail correctness)

Use **Fisher's exact test**:

```python
from scipy.stats import fisher_exact
_, p = fisher_exact([[k_baseline, n_baseline - k_baseline],
                     [k_feature,  n_feature  - k_feature]])
# p > 0.05 → no significant correctness difference (required for SHIP)
```

---

## Verdict rules

| Condition | Verdict |
|-----------|---------|
| Mann-Whitney p < 0.05 (cost) **AND** Fisher's p > 0.05 (correctness) | **SHIP** |
| Feature cost directionally higher on > 50% of individual reps | **DO NOT SHIP** |
| Positive direction but p ≥ 0.05 | **INCONCLUSIVE** — re-run at n=40 |
| Positive direction, p < 0.05, but correctness regressed | **DO NOT SHIP** — quality loss overrides cost saving |

**INCONCLUSIVE is not failure** — it means you need more data. Re-run at n=40 and re-test. If still inconclusive at n=40, file as "no proven effect" and move on.

---

## Minimum sample size

| Situation | n |
|-----------|---|
| Initial pilot (to check direction) | 8 |
| Standard bench | 20/arm |
| Pilot showed noisy / close result | 40/arm + significance test |
| Never publish a verdict at | < 20/arm |

The project has been burned twice by n < 20 (auto-stats n=4 overclaim, agentic n=8 input regression). These aren't mistakes to avoid — they're the documented reason the floor exists. If you run a pilot at n=8 and see a promising direction, **still run n=20 before declaring a verdict.**

---

## Recording results

Every verdict goes into `bench/RESULTS.md`, appended at the bottom. Include:

```markdown
## [Feature name] — [DATE]

[One-paragraph description of what was tested]

[The printed table from the bench script, verbatim]

**Verdict: SHIP / DO NOT SHIP / INCONCLUSIVE.** [1-2 sentence explanation of why.]

Reproduce: `bench/NAME.sh`. Run: YYYY-MM-DD.
```

Negative results stay in the file permanently. A DO NOT SHIP result is as valuable as a SHIP — it tells the next person not to re-test the same dead end.

---

## Execution checklist

Before running any bench:

- [ ] The bench script has `run_one warmup ... /dev/null` before the parallel dispatch
- [ ] Both arms are dispatched in the SAME xargs batch (not sequentially) — so they share a warm cache prefix
- [ ] Grading is deterministic (grep/regex/arithmetic, no LLM judge)
- [ ] `QB_REPEATS` is at least 20
- [ ] The report block includes both Mann-Whitney U (cost) and Fisher's exact (correctness)
- [ ] The report block prints a `**Verdict:**` line

After running:

- [ ] Appended the printed output to `bench/RESULTS.md`
- [ ] Committed with `bench(C#): <feature> A/B — <VERDICT>`
- [ ] If INCONCLUSIVE: noted in RESULTS.md that n=40 re-run is needed
