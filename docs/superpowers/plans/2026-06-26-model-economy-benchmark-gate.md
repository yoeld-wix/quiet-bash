# Model-Economy Benchmark Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible 3-arm (baseline / A / B-ready) benchmark that measures whether downgrading subagents to a cheaper tier saves cost with **zero answer-quality regression** — the go/no-go gate before building the `model-economy` skill or the `PreToolUse(Task)` hook.

**Architecture:** Extends the existing `bench/agentic.sh` pattern (headless `claude -p`, JSONL records, markdown table aggregation). Adds (1) a delegation-inducing task suite where each task carries a deterministic regex assertion, (2) a grading function that marks each run pass/fail, (3) arm `A` = subagents forced to the cheap tier via `CLAUDE_CODE_SUBAGENT_MODEL=haiku` (a robust proxy for the skill's selective frontmatter tiering — if full downgrade is zero-regression, selective is strictly safer), and (4) a `B` arm slot left guarded/off until the hook spike passes. Grading logic is a pure bash function unit-tested in `tests/run.sh` with no token spend; the token-spending run stays manual.

**Tech Stack:** bash, jq, python3 (all already used by `bench/`), Claude Code CLI (`claude -p --output-format json`).

## Global Constraints

- **Aliases only, never dated model IDs.** Arm A uses the alias `haiku` (via `CLAUDE_CODE_SUBAGENT_MODEL=haiku`), never a versioned ID. Copied from spec §2/§7.
- **No model/network call in the *product*.** The benchmark itself calls models (it must, to measure); nothing it produces becomes a runtime dependency. Spec §2.
- **Downgrade-only.** Arm A only ever lowers the subagent tier. Spec §2.
- **Gating metric:** an arm "passes" only if its **pass-rate == baseline pass-rate** (zero regression) AND its mean cost < baseline. Cheaper-but-regressed = fail. Spec §6.
- **Test convention:** pure-function assertions in `tests/run.sh` using existing `pass`/`bad` helpers; exits non-zero on failure; no token spend in CI. Token-spending runs are manual, like `bench/agentic.sh`.
- **No new dependencies** beyond bash/jq/python3.

---

### Task 1: Grading function + task-suite data file

**Files:**
- Create: `bench/model-economy-tasks.sh` (task suite + grading helpers, sourced by the harness and by tests)
- Test: `tests/run.sh` (append a new section)

**Interfaces:**
- Produces:
  - `ME_TASK_PROMPTS` — bash array of task prompt strings.
  - `ME_TASK_ASSERTS` — bash array of extended-regex strings, index-aligned with `ME_TASK_PROMPTS`; a run passes iff the agent's final answer text matches this regex (case-insensitive).
  - `me_grade <task_index> <answer_text>` — echoes `pass` or `fail` and returns 0/1. Pure function: no I/O beyond reading the two arrays.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh`:

```bash
echo "== model-economy: grading =="
. "$ROOT/bench/model-economy-tasks.sh"
# task 0 asserts the answer mentions the known symbol; grade pass/fail on canned answers
if [ "$(me_grade 0 'The function is exported as quiet_rewrite in quiet-core.sh')" = pass ]; then
  pass "grade: correct answer for task0 → pass"
else bad "grade: correct answer for task0 should pass"; fi
if [ "$(me_grade 0 'I could not find anything relevant')" = fail ]; then
  pass "grade: wrong answer for task0 → fail"
else bad "grade: wrong answer for task0 should fail"; fi
# every task must have an index-aligned assertion
if [ "${#ME_TASK_PROMPTS[@]}" -eq "${#ME_TASK_ASSERTS[@]}" ] && [ "${#ME_TASK_PROMPTS[@]}" -gt 0 ]; then
  pass "suite: prompts and asserts are aligned and non-empty"
else bad "suite: prompts/asserts misaligned or empty"; fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `bench/model-economy-tasks.sh` does not exist yet (source error / `me_grade: command not found`).

- [ ] **Step 3: Write minimal implementation**

Create `bench/model-economy-tasks.sh`. The tasks are designed to make the main agent **delegate to a search/explore subagent** (the only thing arms A/B affect): each asks to *search/find* something in the quiet-bash repo itself and report a fact with a stable, greppable answer.

```bash
#!/usr/bin/env bash
# Task suite + grading for the model-economy benchmark.
# Each task is engineered to induce subagent delegation (search/summarize over
# this repo) and carries a deterministic regex its final answer must satisfy.
# Sourced by bench/model-economy.sh and by tests/run.sh — defines no top-level
# side effects.

# Prompts run against the quiet-bash repo itself (stable ground truth).
ME_TASK_PROMPTS=(
  "Search this repository to find which shell function decides whether a command gets rewritten, and name it."
  "Search this repository for the adapter file that handles Claude Code PreToolUse Bash events and give its path."
  "Search the core/ directory and list the names of the quiet-* shell scripts it contains."
  "Find the output style shipped by this repo and name it."
)

# Index-aligned extended regexes (matched case-insensitively against the answer).
ME_TASK_ASSERTS=(
  'quiet_rewrite'
  'adapters/claude-code\.sh'
  'quiet-(core|json|outline|prompt|query|result|tail)'
  'concise'
)

# me_grade <task_index> <answer_text> -> echoes pass|fail, returns 0|1
me_grade() {
  local idx="$1" answer="$2" rx="${ME_TASK_ASSERTS[$1]}"
  if printf '%s' "$answer" | grep -Eiq "$rx"; then echo pass; return 0; fi
  echo fail; return 1
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — the three new `model-economy: grading` assertions print `ok`.

- [ ] **Step 5: Commit**

```bash
git add bench/model-economy-tasks.sh tests/run.sh
git commit -m "test(bench): add model-economy task suite and deterministic grading"
```

---

### Task 2: Benchmark harness with baseline + A arms

**Files:**
- Create: `bench/model-economy.sh`
- Test: manual (token-spending); a no-token smoke path is added in Task 3.

**Interfaces:**
- Consumes: `ME_TASK_PROMPTS`, `ME_TASK_ASSERTS`, `me_grade` from `bench/model-economy-tasks.sh`.
- Produces: a JSONL file at `$ME_OUT` (default `bench/model-economy-runs.jsonl`), one record per (arm, task, rep) with keys: `arm, task, rep, input, output, cost, ms, turns, pass` (`pass` is `true`/`false`).
- Env knobs (mirror `agentic.sh`): `QB_TARGET` (repo to run in; defaults to this repo root), `QB_MODEL` (main-loop model, same across arms; default `sonnet`), `QB_REPEATS` (default 2), `ME_OUT`, `ME_ARMS` (space-separated; default `baseline A`).

- [ ] **Step 1: Write the harness**

Create `bench/model-economy.sh`:

```bash
#!/usr/bin/env bash
#
# 3-arm model-economy benchmark for quiet-bash.
#
# Measures whether downgrading SUBAGENTS to a cheaper tier saves cost with zero
# answer-quality regression. Arms:
#   baseline : subagents inherit the main model (no downgrade)
#   A        : CLAUDE_CODE_SUBAGENT_MODEL=haiku (force subagents to the cheap tier;
#              a robust proxy for the model-economy skill's selective frontmatter
#              tiering — if full downgrade is zero-regression, selective is safer)
#   B        : reserved for the PreToolUse(Task) hook; OFF until its spike passes
#
# Main-loop model is identical across arms (QB_MODEL); only the subagent tier
# changes, so any delta is attributable to subagent downgrade. Tasks are written
# to induce subagent delegation (search/summarize). Each run is graded pass/fail
# by a deterministic regex (see bench/model-economy-tasks.sh).
#
# Usage:
#   QB_TARGET=$PWD QB_MODEL=sonnet QB_REPEATS=2 bench/model-economy.sh
#
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$ROOT/bench/model-economy-tasks.sh"

TARGET="${QB_TARGET:-$ROOT}"
MODEL="${QB_MODEL:-sonnet}"
REPEATS="${QB_REPEATS:-2}"
OUT="${ME_OUT:-$ROOT/bench/model-economy-runs.jsonl}"
ARMS="${ME_ARMS:-baseline A}"
: > "$OUT"

# Per-arm environment. baseline: no override. A: force subagents to haiku alias.
arm_env() { # arm -> prints "VAR=value" lines for `env`
  case "$1" in
    A) printf 'CLAUDE_CODE_SUBAGENT_MODEL=haiku\n' ;;
    B) printf 'CLAUDE_CODE_SUBAGENT_MODEL=haiku\n' ;;  # placeholder; B uses the hook, wired later
    *) : ;;
  esac
}

run_one() { # arm task_idx rep
  local arm="$1" ti="$2" rep="$3" task="${ME_TASK_PROMPTS[$2]}"
  local envfile j answer grade
  envfile="$(arm_env "$arm")"
  j=$(cd "$TARGET" && env $(printf '%s ' $envfile) timeout 300 \
        claude -p "$task" --model "$MODEL" --output-format json \
        --allowedTools "Task" "Bash" "Read" "Grep" "Glob" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} task${ti} rep${rep}: no output" >&2; return; }
  answer=$(printf '%s' "$j" | jq -r '.result // ""')
  grade=$(me_grade "$ti" "$answer")
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin); u=o.get('usage',{}) or {}
inp=(u.get('input_tokens',0) or 0)+(u.get('cache_read_input_tokens',0) or 0)+(u.get('cache_creation_input_tokens',0) or 0)
rec={'arm':'$arm','task':$ti,'rep':$rep,'input':inp,'output':u.get('output_tokens',0) or 0,
     'cost':o.get('total_cost_usd',0) or 0,'ms':o.get('duration_ms',0) or 0,
     'turns':o.get('num_turns',0),'pass':('$grade'=='pass')}
print(json.dumps(rec))
" >> "$OUT"
  echo "  ${grade} ${arm} task${ti} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS arms='$ARMS' target=$TARGET" >&2
for ti in "${!ME_TASK_PROMPTS[@]}"; do
  for rep in $(seq 1 "$REPEATS"); do
    for arm in $ARMS; do run_one "$arm" "$ti" "$rep"; done
  done
done

echo >&2
ME_OUT="$OUT" python3 "$ROOT/bench/model-economy-report.py" "$OUT"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x bench/model-economy.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add bench/model-economy.sh
git commit -m "feat(bench): model-economy 3-arm harness (baseline + A arms)"
```

---

### Task 3: Report aggregator with pass-rate + cost gate

**Files:**
- Create: `bench/model-economy-report.py`
- Test: `tests/run.sh` (append a no-token smoke test that feeds canned JSONL)

**Interfaces:**
- Consumes: a JSONL file path as `argv[1]`, records with keys from Task 2.
- Produces: stdout markdown table (arm | input | output | cost | time | pass-rate | runs) plus a verdict line per non-baseline arm: `ZERO-REGRESSION ✓/✗` (pass-rate vs baseline) and `cost <pct>%`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh`:

```bash
echo "== model-economy: report =="
me_tmp="$(mktemp)"
cat > "$me_tmp" <<'JSONL'
{"arm":"baseline","task":0,"rep":1,"input":1000,"output":50,"cost":0.02,"ms":4000,"turns":3,"pass":true}
{"arm":"baseline","task":1,"rep":1,"input":1200,"output":60,"cost":0.03,"ms":4200,"turns":3,"pass":true}
{"arm":"A","task":0,"rep":1,"input":1000,"output":50,"cost":0.01,"ms":3000,"turns":3,"pass":true}
{"arm":"A","task":1,"rep":1,"input":1200,"output":60,"cost":0.015,"ms":3100,"turns":3,"pass":true}
JSONL
me_rep="$(python3 "$ROOT/bench/model-economy-report.py" "$me_tmp")"
if printf '%s' "$me_rep" | grep -q "ZERO-REGRESSION ✓"; then
  pass "report: equal pass-rate → zero-regression ✓"
else bad "report: should report zero-regression when pass-rates match"; fi
if printf '%s' "$me_rep" | grep -Eq "cost -[0-9]"; then
  pass "report: cheaper A arm → negative cost delta"
else bad "report: should show negative cost delta for cheaper arm"; fi
rm -f "$me_tmp"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: FAIL — `bench/model-economy-report.py` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `bench/model-economy-report.py`:

```python
#!/usr/bin/env python3
"""Aggregate model-economy benchmark JSONL into a markdown table + gate verdict.

An arm passes the gate iff its pass-rate equals baseline's (zero regression)
AND its mean cost is lower. Cheaper-but-regressed is a FAIL.
"""
import sys, json, collections, statistics

rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = collections.defaultdict(lambda: collections.defaultdict(list))
for r in rows:
    for k in ("input", "output", "cost", "ms"):
        by[r["arm"]][k].append(r[k])
    by[r["arm"]]["pass"].append(1 if r.get("pass") else 0)

def mean(x): return statistics.mean(x) if x else 0.0

arms = [a for a in ("baseline", "A", "B") if by[a]["input"]]
print("# quiet-bash model-economy benchmark — mean per run")
print("| arm | input tok | output tok | cost $ | time s | pass-rate | runs |")
print("|---|--:|--:|--:|--:|--:|--:|")
for a in arms:
    pr = mean(by[a]["pass"]) * 100
    print(f"| {a} | {mean(by[a]['input']):,.0f} | {mean(by[a]['output']):,.0f} | "
          f"{mean(by[a]['cost']):.4f} | {mean(by[a]['ms'])/1000:.1f} | {pr:.0f}% | {len(by[a]['input'])} |")

base_pr = mean(by["baseline"]["pass"]) * 100 if by["baseline"]["input"] else None
base_cost = mean(by["baseline"]["cost"]) if by["baseline"]["input"] else None
print()
for a in arms:
    if a == "baseline" or base_pr is None:
        continue
    pr = mean(by[a]["pass"]) * 100
    cost = mean(by[a]["cost"])
    regress = "ZERO-REGRESSION ✓" if pr >= base_pr else "ZERO-REGRESSION ✗"
    cost_delta = (100 * (cost - base_cost) / base_cost) if base_cost else 0.0
    verdict = "SHIP" if (pr >= base_pr and cost < base_cost) else "DO NOT SHIP"
    print(f"**arm {a}: {regress} (pass {pr:.0f}% vs baseline {base_pr:.0f}%), "
          f"cost {cost_delta:+.1f}% → {verdict}** (negative cost = cheaper).")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: PASS — both `model-economy: report` assertions print `ok`.

- [ ] **Step 5: Commit**

```bash
git add bench/model-economy-report.py tests/run.sh
git commit -m "feat(bench): model-economy report with zero-regression + cost gate"
```

---

### Task 4: Docs — how to run the gate + where results go

**Files:**
- Modify: `bench/RESULTS.md` (append a "Model-economy A/B (gate)" section with the run command and an empty results placeholder to fill after the manual run)
- Modify: `README.md` (one line under the existing benchmark mentions, linking the new bench)

**Interfaces:** none (docs only).

- [ ] **Step 1: Append the run instructions to `bench/RESULTS.md`**

Add this section at the end of `bench/RESULTS.md`:

```markdown
## Model-economy A/B (gate) — how to run

Measures whether downgrading subagents to the cheap tier saves cost with zero
answer-quality regression. Arms: `baseline` (subagents inherit) vs `A`
(`CLAUDE_CODE_SUBAGENT_MODEL=haiku`). Each task is graded pass/fail by a
deterministic regex.

    QB_TARGET="$PWD" QB_MODEL=sonnet QB_REPEATS=3 bench/model-economy.sh

Gate: arm A ships only if **pass-rate == baseline (zero regression)** AND mean
cost is lower. Paste the printed table here after running. A "DO NOT SHIP"
verdict (regression, or no savings) is itself a valid, publishable result.
```

- [ ] **Step 2: Add a README pointer**

In `README.md`, in the Highlights "Measured, reproducible savings" bullet, add a trailing sentence:

```markdown
  A separate model-economy gate ([`bench/model-economy.sh`](bench/model-economy.sh)) measures whether downgrading subagents to a cheaper tier saves cost with zero answer-quality regression.
```

- [ ] **Step 3: Commit**

```bash
git add bench/RESULTS.md README.md
git commit -m "docs(bench): document the model-economy gate and how to run it"
```

---

### Task 5: Manual gate run (token-spending) + record verdict

**Files:**
- Modify: `bench/RESULTS.md` (paste the actual table under the section from Task 4)

**Interfaces:** none.

- [ ] **Step 1: Run the full test suite (no tokens) to confirm green**

Run: `bash tests/run.sh`
Expected: all `ok`, exit 0.

- [ ] **Step 2: Run the gate against this repo (spends tokens)**

Run: `QB_TARGET="$PWD" QB_MODEL=sonnet QB_REPEATS=3 bench/model-economy.sh`
Expected: a markdown table with `baseline` and `A` rows incl. `pass-rate`, and a verdict line (`SHIP` or `DO NOT SHIP`).

- [ ] **Step 3: Paste the table into `bench/RESULTS.md`** under the Task 4 section, and write a one-line conclusion: does arm A meet the gate?

- [ ] **Step 4: Commit**

```bash
git add bench/RESULTS.md
git commit -m "docs(bench): record model-economy gate results"
```

- [ ] **Step 5: GATE DECISION (no code — a stop-and-decide point)**

Report the verdict to the user. Per the recommendation in `docs/research/model-economy.md` / the design spec:
- **SHIP** → proceed to a *new* plan for the `model-economy` skill (selective frontmatter tiering), then the B spike.
- **DO NOT SHIP** → stop; the reproducible negative result is the deliverable. Do not build the skill or the hook.

---

## Self-Review

**Spec coverage:** benchmark harness (spec §6) → Tasks 1–3; 3-arm baseline/A/B-ready with B guarded (§5/§6) → Task 2 `arm_env`; deterministic assertions (§6) → Task 1; delegation-inducing suite (§6) → Task 1 prompts; zero-regression-as-gate (§6) → Task 3 verdict + Task 5 step 5; aliases-only (§2/§7) → arm A uses `haiku` alias; ship-A-independent-of-B + gate (recommendation) → Task 5 step 5. Skill A and hook B are intentionally deferred to their own plans (scope-check rule) and gated by Task 5.

**Placeholder scan:** the `B` arm `arm_env` entry is a deliberate, labeled placeholder (B is spike-gated and off by default via `ME_ARMS="baseline A"`), not an unfinished step. No TODO/TBD in executable paths.

**Type consistency:** `me_grade`, `ME_TASK_PROMPTS`, `ME_TASK_ASSERTS` defined in Task 1 and consumed identically in Tasks 2–3; JSONL record keys (`arm,task,rep,input,output,cost,ms,turns,pass`) emitted in Task 2 and read by the same names in Task 3.
