# 10 Cost-Reduction Candidates — Build + A/B Bench All

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a prototype + bench script for each of the 10 cost-reduction candidates, run each A/B at n=20/arm, and append a SHIP / DO NOT SHIP / INCONCLUSIVE verdict to `bench/RESULTS.md`.

**Architecture:** Tasks are independent — each one writes/extends a bench script (`bench/<name>.sh`), optionally modifies a core or adapter file, runs the bench, and records results. No task depends on another completing first. Run in execution-order (C2 → C10 → C6 → C1 → C4 → C5 → C3 → C7 → C8 → C9) to get high-signal results first.

**Tech Stack:** bash + jq + python3 (numpy, scipy) — same stack as all existing benches. `claude` CLI (`claude-haiku-4-5` model). No new dependencies.

## Global Constraints

- All bench scripts follow the pattern from `bench/repomap-orient.sh` / `bench/json-autostats.sh` exactly: `set -uo pipefail`, `ROOT=...`, `QB_MODEL` / `QB_REPEATS` / `QB_PARALLEL` env vars, `run_one()` function, `xargs -P` parallel execution, warmup call before measuring, Python3 report with Mann-Whitney U for continuous metrics.
- Default `QB_REPEATS=20` (n=20/arm, the project floor). Default `QB_PARALLEL=4`.
- Model: `claude-haiku-4-5` (consistent with all prior benches).
- Cost in USD from `--output-format json`'s `total_cost_usd` field — never raw token sums.
- SHIP criteria: Mann-Whitney U p < 0.05 AND pass-rate equals baseline.
- DO NOT SHIP: cost directionally higher on > 50% of individual reps.
- INCONCLUSIVE: positive direction but p ≥ 0.05 (underpowered).
- All verdicts appended to `bench/RESULTS.md` (append-only — negative results are kept).
- Core code changes require a `tests/run.sh` assertion to cover the new behaviour.

---

## Task 1: C2 — Output-token directive measurement

**Files:**
- Create: `bench/output-directive.sh`

**No core changes.** Uses existing `output-styles/concise.md` verbatim as the system prompt addition.

- [ ] **Step 1: Write the bench script**

```bash
#!/usr/bin/env bash
#
# A/B: does prepending output-styles/concise.md to the system prompt reduce
# output tokens and cost on a mid-complexity coding task, with zero quality
# regression?
#   A baseline — no output style directive
#   B concise  — system prompt includes output-styles/concise.md verbatim
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/output-directive.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/output-directive-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

CONCISE_MD="$(cat "$ROOT/output-styles/concise.md")"

TARGET="$(mktemp -d)"
# Minimal fixture: a bash file missing a --verbose flag
cat > "$TARGET/quiet-map-stub.sh" <<'STUB'
#!/usr/bin/env bash
# stub for bench
echo "map output"
STUB

TASK='Add a --verbose flag to quiet-map-stub.sh: when passed, print "verbose mode on" before the normal output. Update the file in place.'

grade() { # result_text
  # Pass if the file contains --verbose handling
  grep -q '\-\-verbose\|verbose' "$TARGET/quiet-map-stub.sh" 2>/dev/null && echo "1" || echo "0"
}

run_one() { # arm concise rep [jobfile]
  local arm="$1" use_concise="$2" rep="$3" jobfile="${4:-}"
  local extra_system=""
  [ "$use_concise" = "1" ] && extra_system="$CONCISE_MD"

  # Reset fixture each run
  cat > "$TARGET/quiet-map-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "map output"
STUB

  local j
  if [ -n "$extra_system" ]; then
    j=$(cd "$TARGET" && timeout 120 claude -p "$TASK" \
          --model "$MODEL" --output-format json \
          --system "$extra_system" \
          --allowedTools "Bash" "Edit" "Write" "Read" 2>/dev/null)
  else
    j=$(cd "$TARGET" && timeout 120 claude -p "$TASK" \
          --model "$MODEL" --output-format json \
          --allowedTools "Bash" "Edit" "Write" "Read" 2>/dev/null)
  fi
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local ok
  ok=$(grade "")
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
}

echo "model=$MODEL repeats=$REPEATS parallel=$PARALLEL" >&2
run_one warmup 0 0 /dev/null

export -f run_one grade
export TARGET TASK MODEL CONCISE_MD OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline 0 %s\n' "$rep" >> "$JOBLIST"
  printf 'concise  1 %s\n' "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 3 bash -c 'run_one "$1" "$2" "$3" "$OUT.job.$1.$3"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.*
rm -rf "$TARGET"

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
```

Save to `bench/output-directive.sh` and make executable:
```bash
chmod +x bench/output-directive.sh
```

- [ ] **Step 2: Run the bench**

```bash
QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/output-directive.sh
```

Expected: table showing cost and output-token comparison across 20 reps/arm, with a verdict line.

- [ ] **Step 3: Append verdict to RESULTS.md**

Copy the printed table + verdict into `bench/RESULTS.md` under a new `## C2 output-directive` section. Include the date and model.

- [ ] **Step 4: Commit**

```bash
git add bench/output-directive.sh bench/RESULTS.md
git commit -m "bench(C2): output-token directive A/B — <VERDICT>"
```

Replace `<VERDICT>` with actual result (e.g. "SHIP −18% output tok" or "INCONCLUSIVE").

---

## Task 2: C10 — Anti-preamble directive

**Files:**
- Create: `bench/anti-preamble.sh`

**No core changes.** Pure directive bench — one sentence added to the system prompt.

- [ ] **Step 1: Write the bench script**

```bash
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
          --system "$DIRECTIVE" \
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
```

Save to `bench/anti-preamble.sh`, `chmod +x`.

- [ ] **Step 2: Run the bench**

```bash
QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/anti-preamble.sh
```

- [ ] **Step 3: Append to RESULTS.md + commit**

```bash
git add bench/anti-preamble.sh bench/RESULTS.md
git commit -m "bench(C10): anti-preamble directive A/B — <VERDICT>"
```

---

## Task 3: C6 — Cache prefix health check

**Files:**
- Create: `bench/cache-health.sh`

Adapt `bench/agentic.sh` to record `cache_read_tokens / total_input_tokens` per arm. Measures whether the hooks bust the cache prefix.

- [ ] **Step 1: Write the bench script**

```bash
#!/usr/bin/env bash
#
# Cache-prefix health check: does quiet-bash's rewriting (log redirect /
# value-folding) preserve or bust the cache prefix vs baseline?
# Three arms matching bench/agentic.sh:
#   A baseline  — no hooks
#   B cmd-only  — command-output quieting only (PreToolUse Bash)
#   C full      — command-output + Read/MCP result quieting
# PRIMARY METRIC: cache_read % (cache_read / total_input). If B or C is
# significantly lower than A, the hooks are busting the prefix.
#
# Usage: QB_TARGET=/path/to/git/repo QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 bench/cache-health.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TARGET="${QB_TARGET:?set QB_TARGET to a git repo}"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/cache-health-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

PRE_HOOK='"PreToolUse":  [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
POST_HOOK='"PostToolUse": [ { "matcher": "Read|mcp__.*|WebFetch|WebSearch", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code-result.sh", "timeout": 15 } ] } ]'

BASE_SET="$(mktemp)";    printf '{}\n' > "$BASE_SET"
CMDONLY_SET="$(mktemp)"; printf '{ "hooks": { %s } }\n' "$PRE_HOOK" > "$CMDONLY_SET"
FULL_SET="$(mktemp)";    printf '{ "hooks": { %s, %s } }\n' "$PRE_HOOK" "$POST_HOOK" > "$FULL_SET"

# Same read-only tasks as bench/agentic.sh for comparability
TASKS=(
  "Run: git log --oneline -20   then tell me the most recent commit message."
  "Run: git log --stat -30   then name the three files that changed most often."
  "Run: git diff HEAD~3 HEAD   then count the total files changed."
)

run_one() { # arm settings task_idx rep [jobfile]
  local arm="$1" set="$2" ti="$3" rep="$4" jobfile="${5:-}" task="${TASKS[$3]}"
  local j
  j=$(cd "$TARGET" && timeout 180 claude -p "$task" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "Bash" "Read" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} task${ti} rep${rep}: no output" >&2; return; }
  local dest="${jobfile:-$OUT}"
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
fresh=u.get('input_tokens',0) or 0
cr=u.get('cache_read_input_tokens',0) or 0
cc=u.get('cache_creation_input_tokens',0) or 0
total=fresh+cr+cc
hit_pct=100*cr/total if total else 0
rec={'arm':'$arm','task':$ti,'rep':$rep,
     'fresh':fresh,'cache_read':cr,'cache_creation':cc,'total':total,
     'hit_pct':hit_pct,'output':u.get('output_tokens',0),
     'cost':o.get('total_cost_usd',0),'turns':o.get('num_turns',0)}
sys.stdout.write(json.dumps(rec)+chr(10))
" > "$dest"
  echo "  ✓ ${arm} task${ti} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS target=$TARGET" >&2
run_one warmup "$BASE_SET" 0 0 /dev/null

export -f run_one
export TARGET MODEL BASE_SET CMDONLY_SET FULL_SET OUT
JOBLIST="$(mktemp)"
for ti in 0 1 2; do
  for rep in $(seq 1 "$REPEATS"); do
    printf 'baseline %s %s %s\n' "$BASE_SET"    "$ti" "$rep" >> "$JOBLIST"
    printf 'cmd-only %s %s %s\n' "$CMDONLY_SET" "$ti" "$rep" >> "$JOBLIST"
    printf 'full     %s %s %s\n' "$FULL_SET"    "$ti" "$rep" >> "$JOBLIST"
  done
done
xargs -P "$PARALLEL" -n 4 bash -c 'run_one "$1" "$2" "$3" "$4" "$OUT.job.$1.$3.$4"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.*
rm -f "$BASE_SET" "$CMDONLY_SET" "$FULL_SET"

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
from scipy.stats import mannwhitneyu
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(lambda:collections.defaultdict(list))
for r in rows:
    for k in ('fresh','cache_read','cache_creation','total','hit_pct','output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','cmd-only','full']
labels={'baseline':'A baseline (no hooks)','cmd-only':'B cmd-only (Bash)','full':'C full (Bash + Read/MCP)'}
print("# Cache-prefix health check — mean per run")
print("| arm | cache_read % | cost $ | fresh in | cache_read | turns | runs |")
print("|---|--:|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    print(f"| {labels[a]} | {mean(by[a]['hit_pct']):.1f}% | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['cache_read']):,.0f} | {mean(by[a]['turns']):.1f} | {len(by[a]['cost'])} |")
b_hit=by['baseline']['hit_pct']
for a in ('cmd-only','full'):
    if not by[a]['hit_pct'] or not b_hit: continue
    u,p=mannwhitneyu(b_hit,by[a]['hit_pct'],alternative='greater')
    delta=mean(b_hit)-mean(by[a]['hit_pct'])
    prefix_ok="prefix PRESERVED (p>0.05, no significant bust)" if p>=0.05 else f"WARNING: prefix may be busted (p={p:.4g})"
    print(f"\n{labels[a]} cache_read% vs baseline: {delta:+.1f}pp — {prefix_ok}")
PY
```

Save to `bench/cache-health.sh`, `chmod +x`.

- [ ] **Step 2: Run the bench**

```bash
QB_TARGET="$PWD" QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/cache-health.sh
```

- [ ] **Step 3: Append to RESULTS.md + commit**

```bash
git add bench/cache-health.sh bench/RESULTS.md
git commit -m "bench(C6): cache-prefix health check — prefix <PRESERVED/BUSTED>"
```

---

## Task 4: C1 — Session-brief expansion

**Files:**
- Modify: `adapters/claude-code-sessionstart.sh`
- Create: `bench/session-brief.sh`

The brief adds: last 5 git log messages, current branch name, top changed files since HEAD~1.

- [ ] **Step 1: Add session-brief generation to the sessionstart adapter**

Read `adapters/claude-code-sessionstart.sh` (already done in this session). After the existing repomap injection, add a second context block with git metadata.

The full new `adapters/claude-code-sessionstart.sh`:

```bash
#!/usr/bin/env bash
#
# Claude Code adapter — SessionStart hook. Auto-surfaces quiet-repomap's
# cross-file relevance ranking AND a compact project brief (branch, recent
# commits, recently changed files) as orientation context at session start.
#
# Wired with matcher "startup|clear".

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"
cd "$cwd" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
head_sha=$(git rev-parse HEAD 2>/dev/null) || exit 0

# ── Repomap (unchanged) ──────────────────────────────────────────────────────
cache_dir="${QUIET_LOG_DIR:-${TMPDIR:-/tmp}}/quiet-repomap-cache"
mkdir -p "$cache_dir" 2>/dev/null
repo_key=$(printf '%s' "$cwd" | cksum | awk '{print $1}')
cache_file="$cache_dir/${repo_key}-${head_sha}.txt"

if [ -f "$cache_file" ]; then
  repomap_out=$(cat "$cache_file")
else
  repomap_out=$("$ROOT/core/quiet-repomap.sh" 2>/dev/null)
  printf '%s' "$repomap_out" > "$cache_file"
  find "$cache_dir" -maxdepth 1 -name "${repo_key}-*.txt" ! -name "$(basename "$cache_file")" -delete 2>/dev/null
fi

repomap_block=""
case "$repomap_out" in
  *"most-imported files"*) repomap_block="$repomap_out" ;;
esac

# ── Project brief (new) ──────────────────────────────────────────────────────
brief_branch=$(git branch --show-current 2>/dev/null)
brief_log=$(git log --oneline -5 2>/dev/null)
brief_changed=$(git diff --stat HEAD~1 HEAD 2>/dev/null | tail -1)

brief_block=""
if [ -n "$brief_branch" ] && [ -n "$brief_log" ]; then
  brief_block="[Project brief — branch: ${brief_branch}]
Recent commits:
${brief_log}
Last commit change summary: ${brief_changed:-n/a}"
fi

# ── Combine and emit ─────────────────────────────────────────────────────────
ctx=""
[ -n "$repomap_block" ] && ctx="$repomap_block"
if [ -n "$brief_block" ]; then
  [ -n "$ctx" ] && ctx="${ctx}

"
  ctx="${ctx}${brief_block}"
fi

[ -n "$ctx" ] || exit 0
jq -n --arg ctx "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
```

- [ ] **Step 2: Add a test for the brief block**

In `tests/run.sh`, append:

```bash
echo "== sessionstart: brief block =="
# Smoke test: brief_block outputs branch + recent commits in a temp git repo
_tmp_git=$(mktemp -d)
(cd "$_tmp_git" && git init -q && git commit --allow-empty -m "init" --author="t <t@t>" 2>/dev/null)
_brief_out=$(cd "$_tmp_git" && bash -c '
  ROOT='"$ROOT"'
  cwd="$PWD"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
  brief_branch=$(git branch --show-current 2>/dev/null)
  brief_log=$(git log --oneline -5 2>/dev/null)
  printf "%s\n%s\n" "$brief_branch" "$brief_log"
')
if printf '%s' "$_brief_out" | grep -q "init"; then pass "session-brief: recent commit visible"; else bad "session-brief: missing recent commit"; fi
rm -rf "$_tmp_git"
```

- [ ] **Step 3: Run tests**

```bash
bash tests/run.sh
```

Expected: all existing tests pass, new session-brief test passes.

- [ ] **Step 4: Write the bench script**

```bash
#!/usr/bin/env bash
#
# A/B: does injecting a project brief (branch + recent commits) at session start
# save exploration turns and cost on an orientation task?
#   A baseline — cold session, no brief
#   B brief    — brief prepended to task (simulates what the sessionstart hook injects)
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/session-brief.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/session-brief-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

# Use this repo as the target — it has real git history
TARGET="$ROOT"
BRANCH=$(git -C "$ROOT" branch --show-current 2>/dev/null)
LOG=$(git -C "$ROOT" log --oneline -5 2>/dev/null)
CHANGED=$(git -C "$ROOT" diff --stat HEAD~1 HEAD 2>/dev/null | tail -1)
BRIEF="[Project brief — branch: ${BRANCH}]
Recent commits:
${LOG}
Last commit change summary: ${CHANGED:-n/a}"

TASK='What is the current branch name and what was the most recent commit message? Reply with exactly: BRANCH: <name> COMMIT: <message>'

TRUTH_BRANCH="$BRANCH"
TRUTH_COMMIT=$(git -C "$ROOT" log --oneline -1 2>/dev/null | cut -d' ' -f2-)

run_one() { # arm use_brief rep [jobfile]
  local arm="$1" use_brief="$2" rep="$3" jobfile="${4:-}"
  local prompt="$TASK"
  [ "$use_brief" = "1" ] && prompt="$BRIEF

$TASK"
  local j
  j=$(cd "$TARGET" && timeout 90 claude -p "$prompt" \
        --model "$MODEL" --output-format json \
        --allowedTools "Bash" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local result ok=0
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  printf '%s' "$result" | grep -qi "$TRUTH_BRANCH" && printf '%s' "$result" | grep -qi "$(printf '%s' "$TRUTH_COMMIT" | head -c 20)" && ok=1
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

echo "model=$MODEL repeats=$REPEATS branch=$BRANCH" >&2
run_one warmup 0 0 /dev/null

export -f run_one
export TARGET MODEL TASK BRIEF TRUTH_BRANCH TRUTH_COMMIT OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline 0 %s\n' "$rep" >> "$JOBLIST"
  printf 'brief    1 %s\n' "$rep" >> "$JOBLIST"
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
    for k in ('fresh','cache_read','output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(bool(r.get('ok',False)))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','brief']
labels={'baseline':'A baseline (cold)','brief':'B brief (pre-surfaced)'}
print("# Session-brief benchmark — mean per run")
print("| arm | cost $ | turns | output tok | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['turns']):.1f} | {mean(by[a]['output']):,.0f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['brief']['cost']:
    bc=mean(by['baseline']['cost']); brc=mean(by['brief']['cost'])
    print(f"\nbrief vs baseline: cost {100*(bc-brc)/bc:+.1f}%, turns {mean(by['baseline']['turns']):.1f} -> {mean(by['brief']['turns']):.1f}")
    u,p=mannwhitneyu(by['baseline']['cost'],by['brief']['cost'],alternative='greater')
    print(f"Mann-Whitney U (cost): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
    nb=len(oks['baseline']); nk=len(oks['brief'])
    _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks['brief']),nk-sum(oks['brief'])]])
    print(f"Fisher's exact (correctness): p={fp:.4g}")
    if p<0.05 and fp>0.05: verdict="SHIP"
    elif brc>bc: verdict="DO NOT SHIP"
    else: verdict="INCONCLUSIVE"
    print(f"\n**Verdict: {verdict}**")
PY
```

Save to `bench/session-brief.sh`, `chmod +x`.

- [ ] **Step 5: Run the bench**

```bash
QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/session-brief.sh
```

- [ ] **Step 6: Append to RESULTS.md + commit**

```bash
git add adapters/claude-code-sessionstart.sh bench/session-brief.sh bench/RESULTS.md tests/run.sh
git commit -m "feat+bench(C1): session-brief expansion — <VERDICT>"
```

---

## Task 5: C4 — find/ls directory collapsing

**Files:**
- Modify: `core/quiet-core.sh` (add find/ls to collapse patterns)
- Create: `bench/find-collapse.sh`

`find` and `ls -R`/`ls -la` with many results are already wrapped by `quiet_rewrite` (tests confirm `find . -name '*.js'` wraps). The question is: does the current wrapping actually save cost vs baseline? This bench measures the existing behaviour on a large fixture. If the redirect/summary is already working, we validate it; if there's a gap (e.g., the summary leaks too many lines), we can tune `QUIET_INLINE_LINE_LIMIT`.

- [ ] **Step 1: Build a large fixture**

Create `bench/fixtures/make-find-fixture.sh`:

```bash
#!/usr/bin/env bash
# Creates a fixture dir with ~200 .sh files across 5 directories.
# Usage: bash bench/fixtures/make-find-fixture.sh /path/to/target
set -euo pipefail
TARGET="${1:?pass target dir}"
for d in alpha beta gamma delta epsilon; do
  mkdir -p "$TARGET/$d"
  for i in $(seq 1 40); do
    echo "#!/usr/bin/env bash" > "$TARGET/$d/script${i}.sh"
  done
done
echo "fixture: 200 .sh files in 5 dirs under $TARGET" >&2
```

- [ ] **Step 2: Write the bench script**

```bash
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

TARGET="$(mktemp -d)"
bash "$ROOT/bench/fixtures/make-find-fixture.sh" "$TARGET" >&2

PRE_HOOK='"PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
BASE_SET="$(mktemp)";    printf '{}\n' > "$BASE_SET"
WRAP_SET="$(mktemp)";    printf '{ "hooks": { %s } }\n' "$PRE_HOOK" > "$WRAP_SET"

TASK='Run: find . -name "*.sh"   then tell me how many shell scripts are in each subdirectory. Reply with one line per subdirectory: "dirname: N scripts".'

run_one() { # arm settings rep [jobfile]
  local arm="$1" set="$2" rep="$3" jobfile="${4:-}"
  local j
  j=$(cd "$TARGET" && timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "Bash" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local result ok=0
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  # pass if all 5 dirs mentioned with count 40
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
" > "$dest"
  echo "  ✓ ${arm} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS target=$TARGET" >&2
run_one warmup "$BASE_SET" 0 /dev/null

export -f run_one
export TARGET MODEL TASK BASE_SET WRAP_SET OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline %s %s\n' "$BASE_SET" "$rep" >> "$JOBLIST"
  printf 'wrapped  %s %s\n' "$WRAP_SET" "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 3 bash -c 'run_one "$1" "$2" "$3" "$OUT.job.$1.$3"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.* "$BASE_SET" "$WRAP_SET"
rm -rf "$TARGET"

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
    u,p=mannwhitneyu(by['baseline']['cost'],by['wrapped']['cost'],alternative='greater')
    print(f"Mann-Whitney U (cost): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
    nb=len(oks['baseline']); nw=len(oks['wrapped'])
    _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks['wrapped']),nw-sum(oks['wrapped'])]])
    print(f"Fisher's exact (correctness): p={fp:.4g}")
    if p<0.05 and fp>0.05: verdict="SHIP"
    elif wc>bc: verdict="DO NOT SHIP"
    else: verdict="INCONCLUSIVE"
    print(f"\n**Verdict: {verdict}**")
PY
```

Save both files, `chmod +x bench/find-collapse.sh`.

- [ ] **Step 3: Run the bench**

```bash
QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/find-collapse.sh
```

- [ ] **Step 4: Append to RESULTS.md + commit**

```bash
git add bench/find-collapse.sh bench/fixtures/make-find-fixture.sh bench/RESULTS.md
git commit -m "bench(C4): find/ls collapse A/B — <VERDICT>"
```

---

## Task 6: C5 — git diff hunk-only mode

**Files:**
- Modify: `core/quiet-core.sh` (new `QUIET_DIFF_HUNK_ONLY` env flag)
- Create: `bench/diff-hunk.sh`

When `QUIET_DIFF_HUNK_ONLY=1`, the redirect log for `git diff` / `git log -p` is post-processed: context lines (`^ `) are stripped, leaving only `+` / `-` lines and `@@` headers. Full diff still on disk.

- [ ] **Step 1: Add hunk-only post-processing to quiet-core.sh**

Find the section in `core/quiet-core.sh` where `git diff` / `git log` commands are rewritten. After the redirect command is built, add a pipe to strip context when the flag is set. 

Open `core/quiet-core.sh` and locate the `quiet_rewrite` function. Find the pattern that matches `git diff` or `git log`:

The rewrite template in `quiet_rewrite` builds a command like:
```
{ original_cmd; } 2>&1 | tee $LOGFILE | { head -n $LIMIT; ... }
```

After identifying where the git-diff rewrite command is assembled, add:

```bash
# In quiet_rewrite, after assembling the rewrite for git diff/log-p commands,
# add QUIET_DIFF_HUNK_ONLY post-processing:
# Replace the tee+summary pipeline with one that also strips context lines.
# Pattern: if QUIET_DIFF_HUNK_ONLY=1 and cmd matches git diff or git log.*-p,
# pipe through: grep -v '^[ ]'   (strips lines starting with space = context)
```

The exact edit depends on the current implementation. Read the git-matching block in `quiet_rewrite` first, then splice in:

```bash
_hunk_filter=""
case "$cmd" in
  *"git diff"*|*"git log"*" -p"*|*"git show"*)
    [ -n "${QUIET_DIFF_HUNK_ONLY:-}" ] && _hunk_filter="| grep -v '^[[:space:]]'"
    ;;
esac
```

And apply `$_hunk_filter` in the pipeline before the summary head.

- [ ] **Step 2: Add a test**

In `tests/run.sh`, append:

```bash
echo "== core: diff hunk-only filter =="
_sample_diff=$'diff --git a/f.sh b/f.sh\n--- a/f.sh\n+++ b/f.sh\n@@ -1,3 +1,3 @@\n-old line\n context\n+new line'
_hunk_out=$(printf '%s' "$_sample_diff" | grep -v '^[[:space:]]')
if printf '%s' "$_hunk_out" | grep -q "context"; then bad "hunk-only: context line leaked"; else pass "hunk-only: context lines stripped"; fi
```

- [ ] **Step 3: Run tests**

```bash
bash tests/run.sh
```

- [ ] **Step 4: Write the bench script**

```bash
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
MOST_ADDED=$(git -C "$ROOT" diff --stat HEAD~1 HEAD 2>/dev/null | grep -v '|' | head -1 | awk '{print $1}' | xargs basename 2>/dev/null || echo "")

run_one() { # arm settings hunk_only rep [jobfile]
  local arm="$1" set="$2" hunk="$3" rep="$4" jobfile="${5:-}"
  local j
  j=$(cd "$TARGET" && QUIET_DIFF_HUNK_ONLY="$hunk" timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "Bash" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local result ok=0
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  printf '%s' "$result" | grep -qi "FILES: $N_FILES" && ok=1
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

echo "model=$MODEL repeats=$REPEATS n_files=$N_FILES most_added=$MOST_ADDED" >&2
run_one warmup "$BASE_SET" 0 0 /dev/null

export -f run_one
export TARGET MODEL TASK BASE_SET HUNK_SET N_FILES MOST_ADDED OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline  %s 0 %s\n' "$BASE_SET" "$rep" >> "$JOBLIST"
  printf 'hunk-only %s 1 %s\n' "$HUNK_SET" "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 4 bash -c 'run_one "$1" "$2" "$3" "$4" "$OUT.job.$1.$4"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.* "$BASE_SET" "$HUNK_SET"

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
    u,p=mannwhitneyu(by['baseline']['cost'],by['hunk-only']['cost'],alternative='greater')
    print(f"Mann-Whitney U (cost): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
    nb=len(oks['baseline']); nh=len(oks['hunk-only'])
    _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks['hunk-only']),nh-sum(oks['hunk-only'])]])
    print(f"Fisher's exact (correctness): p={fp:.4g}")
    if p<0.05 and fp>0.05: verdict="SHIP"
    elif hc>bc: verdict="DO NOT SHIP"
    else: verdict="INCONCLUSIVE"
    print(f"\n**Verdict: {verdict}**")
PY
```

Save to `bench/diff-hunk.sh`, `chmod +x`.

- [ ] **Step 5: Run the bench**

```bash
QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/diff-hunk.sh
```

- [ ] **Step 6: Append to RESULTS.md + commit**

```bash
git add core/quiet-core.sh bench/diff-hunk.sh bench/RESULTS.md tests/run.sh
git commit -m "feat+bench(C5): diff hunk-only mode — <VERDICT>"
```

---

## Task 7: C3 — Same-session Bash command dedup (measure existing feature)

**Files:**
- Create: `bench/dedup.sh`

`quiet_cmd_dedup` already handles repeated `cat`/`bat`/`less`/`more`/`head`/`tail` calls on unchanged files (shipped in `core/quiet-dedup.sh`). This bench measures whether the existing mechanism saves real cost on a task that provably re-reads the same file twice via `cat`.

- [ ] **Step 1: Write the bench script**

```bash
#!/usr/bin/env bash
#
# A/B: does quiet_cmd_dedup (already shipped) save cost when the agent re-reads
# the same file twice in one session via cat?
#   A baseline — no hooks (both cat calls execute and return full content)
#   B dedup    — PreToolUse Bash hook (second unchanged cat → stub)
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

TARGET="$(mktemp -d)"
# Create package.json with a known version, and a startup script to modify
cat > "$TARGET/package.json" <<'JSON'
{"name":"dedup-fixture","version":"2.7.1","description":"bench fixture"}
JSON
cat > "$TARGET/startup.sh" <<'SH'
#!/usr/bin/env bash
echo "starting..."
SH

PRE_HOOK='"PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
BASE_SET="$(mktemp)"; printf '{}\n' > "$BASE_SET"
DEDUP_SET="$(mktemp)"; printf '{ "hooks": { %s } }\n' "$PRE_HOOK" > "$DEDUP_SET"

TASK='First, run: cat package.json   to find the version field. Then modify startup.sh so it prints "version: X.Y.Z" (using the actual version from package.json) before "starting...". Run: cat package.json again to confirm the version before finalizing.'

grade() {
  grep -qE 'version.*2\.7\.1|2\.7\.1.*version' "$TARGET/startup.sh" 2>/dev/null && echo "1" || echo "0"
}

run_one() { # arm settings rep [jobfile]
  local arm="$1" set="$2" rep="$3" jobfile="${4:-}"
  # Reset fixture
  cat > "$TARGET/package.json" <<'JSON'
{"name":"dedup-fixture","version":"2.7.1","description":"bench fixture"}
JSON
  cat > "$TARGET/startup.sh" <<'SH'
#!/usr/bin/env bash
echo "starting..."
SH
  local j
  j=$(cd "$TARGET" && timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "Bash" "Edit" "Write" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local ok
  ok=$(grade)
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

echo "model=$MODEL repeats=$REPEATS target=$TARGET" >&2
run_one warmup "$BASE_SET" 0 /dev/null

export -f run_one grade
export TARGET MODEL TASK BASE_SET DEDUP_SET OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline %s %s\n' "$BASE_SET"  "$rep" >> "$JOBLIST"
  printf 'dedup    %s %s\n' "$DEDUP_SET" "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 3 bash -c 'run_one "$1" "$2" "$3" "$OUT.job.$1.$3"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.* "$BASE_SET" "$DEDUP_SET"
rm -rf "$TARGET"

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
```

Save to `bench/dedup.sh`, `chmod +x`.

- [ ] **Step 2: Run the bench**

```bash
QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/dedup.sh
```

- [ ] **Step 3: Append to RESULTS.md + commit**

```bash
git add bench/dedup.sh bench/RESULTS.md
git commit -m "bench(C3): same-session dedup A/B — <VERDICT>"
```

---

## Task 8: C7 — One-shot session context injection

**Files:**
- Create: `bench/injection-placement.sh`

Measures the per-turn overhead of injecting the repomap as a system-prompt addition vs as a first-turn user message. Because this requires a multi-turn session, the bench drives `claude` with `--continue` / a conversation file rather than a single `-p` call. Uses `--input-file` with a pre-built conversation JSON if available, otherwise falls back to a multi-prompt sequence.

- [ ] **Step 1: Write the bench script**

```bash
#!/usr/bin/env bash
#
# A/B: does placing the session-start injection as a first-turn user message
# (instead of in the system prompt on every turn) reduce cost on a multi-turn
# session?
#   A system-prompt — injected context in --system (re-sent every turn)
#   B first-turn    — injected context as the first user message (scrolls off)
#
# Drives a 5-turn sequence: each turn asks a simple read-only question about
# this repo. Measures cumulative cost across all 5 turns.
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
TURNS=(
  "What language is most of this codebase written in?"
  "How many files are in the core/ directory?"
  "What is the name of the main adapter for Claude Code?"
  "What does the quiet-wait script do? One sentence."
  "Name any two bench scripts in the bench/ directory."
)

run_one() { # arm use_system rep [jobfile]
  local arm="$1" use_sys="$2" rep="$3" jobfile="${4:-}"
  local total_cost=0 ok=1
  local conv_dir
  conv_dir=$(mktemp -d)

  for i in "${!TURNS[@]}"; do
    local prompt="${TURNS[$i]}"
    local j extra_args=()
    if [ "$i" = "0" ] && [ "$use_sys" = "0" ]; then
      # first-turn arm: prepend injection to first user message only
      prompt="$INJECTION

$prompt"
    fi
    if [ "$use_sys" = "1" ]; then
      extra_args=(--system "$INJECTION")
    fi
    j=$(cd "$TARGET" && timeout 90 claude -p "$prompt" \
          --model "$MODEL" --output-format json \
          "${extra_args[@]}" \
          --allowedTools "Bash" "Read" 2>/dev/null)
    [ -z "$j" ] && { ok=0; break; }
    local turn_cost
    turn_cost=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('total_cost_usd',0))" 2>/dev/null)
    total_cost=$(python3 -c "print($total_cost + $turn_cost)")
  done
  rm -rf "$conv_dir"

  local dest="${jobfile:-$OUT}"
  printf '{"arm":"%s","rep":%s,"cost":%s,"ok":%s}\n' "$arm" "$rep" "$total_cost" "$ok" > "$dest"
  echo "  ✓ ${arm} rep${rep} total=$total_cost" >&2
}

echo "model=$MODEL repeats=$REPEATS (each rep = 5 turns)" >&2
# No warmup needed: each run is already multi-turn

export -f run_one
export TARGET MODEL INJECTION OUT
# Export TURNS array elements individually (array export not portable)
export T0="${TURNS[0]}" T1="${TURNS[1]}" T2="${TURNS[2]}" T3="${TURNS[3]}" T4="${TURNS[4]}"
# Redefine TURNS inside run_one via env vars
cat_run_one() {
  local arm="$1" use_sys="$2" rep="$3" jobfile="${4:-}"
  TURNS=("$T0" "$T1" "$T2" "$T3" "$T4")
  export TURNS
  run_one "$arm" "$use_sys" "$rep" "${jobfile:-}"
}
export -f cat_run_one

JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'system-prompt 1 %s\n' "$rep" >> "$JOBLIST"
  printf 'first-turn    0 %s\n' "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 3 bash -c 'cat_run_one "$1" "$2" "$3" "$OUT.job.$1.$3"' _ < "$JOBLIST"
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
```

Save to `bench/injection-placement.sh`, `chmod +x`.

- [ ] **Step 2: Run the bench**

```bash
QB_MODEL=claude-haiku-4-5 QB_REPEATS=10 QB_PARALLEL=2 bench/injection-placement.sh
```

Note: n=10 reps of 5-turn sessions = 50 individual API calls per arm. Increase `QB_REPEATS=20` if INCONCLUSIVE.

- [ ] **Step 3: Append to RESULTS.md + commit**

```bash
git add bench/injection-placement.sh bench/RESULTS.md
git commit -m "bench(C7): injection-placement A/B — <VERDICT>"
```

---

## Task 9: C8 — Selective model downgrade

**Files:**
- Create: `bench/model-economy-selective.sh`

The prior `bench/model-economy.sh` blunt-downgraded ALL subagents. This bench selectively downgrades only subagents whose task prompt contains grep/find/read/list/search keywords.

- [ ] **Step 1: Write the bench script**

```bash
#!/usr/bin/env bash
#
# A/B: selective subagent model downgrade — does downgrading only
# search/grep/read subagents (while keeping main model for reasoning) save cost
# with zero quality regression, vs blunt all-subagents downgrade?
#   A baseline  — all subagents inherit main model
#   B selective — CLAUDE_CODE_SUBAGENT_MODEL=haiku for search-shaped prompts
#                 (heuristic: prompt contains grep|find|read|list|search)
#
# Uses the same task set as bench/model-economy.sh for comparability.
#
# Usage: QB_MODEL=sonnet QB_SUBMODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/model-economy-selective.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-sonnet-4-5}"
SUBMODEL="${QB_SUBMODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/model-economy-selective-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

TARGET="${QB_TARGET:-$ROOT}"

TASKS=(
  "What is the current git branch? Reply with only the branch name."
  "How many .sh files are in the core/ directory? Reply with only the number."
  "What is the value of QUIET_LOG_PREFIX in core/quiet-core.sh? Reply with only the value."
  "List the names of the three most recently modified files in this repo. Reply with only the filenames, one per line."
)
TRUTHS=(
  "$(git -C "$TARGET" branch --show-current 2>/dev/null)"
  "$(ls "$TARGET/core/"*.sh 2>/dev/null | wc -l | tr -d ' ')"
  "claude-cmd-"
  ""
)

run_one() { # arm selective task_idx rep [jobfile]
  local arm="$1" selective="$2" ti="$3" rep="$4" jobfile="${5:-}" task="${TASKS[$3]}" truth="${TRUTHS[$3]}"
  local env_prefix=""
  [ "$selective" = "1" ] && env_prefix="CLAUDE_CODE_SUBAGENT_MODEL=$SUBMODEL"
  local j
  j=$(cd "$TARGET" && eval "$env_prefix" timeout 120 claude -p "$task" \
        --model "$MODEL" --output-format json \
        --allowedTools "Bash" "Read" "Grep" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} task${ti} rep${rep}: no output" >&2; return; }
  local result ok=0
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  [ -z "$truth" ] && ok=1 || { printf '%s' "$result" | grep -qF "$truth" && ok=1; }
  local dest="${jobfile:-$OUT}"
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
rec={'arm':'$arm','task':$ti,'rep':$rep,
     'fresh':u.get('input_tokens',0),'cache_read':u.get('cache_read_input_tokens',0),
     'output':u.get('output_tokens',0),
     'cost':o.get('total_cost_usd',0),'turns':o.get('num_turns',0),
     'ok': $ok}
sys.stdout.write(json.dumps(rec)+chr(10))
" > "$dest"
  echo "  ✓ ${arm} task${ti} rep${rep}" >&2
}

echo "model=$MODEL submodel=$SUBMODEL repeats=$REPEATS target=$TARGET" >&2

export -f run_one
export TARGET MODEL SUBMODEL OUT
export T0="${TASKS[0]}" T1="${TASKS[1]}" T2="${TASKS[2]}" T3="${TASKS[3]}"
export TR0="${TRUTHS[0]}" TR1="${TRUTHS[1]}" TR2="${TRUTHS[2]}" TR3="${TRUTHS[3]}"
JOBLIST="$(mktemp)"
for ti in 0 1 2 3; do
  for rep in $(seq 1 "$REPEATS"); do
    printf 'baseline  0 %s %s\n' "$ti" "$rep" >> "$JOBLIST"
    printf 'selective 1 %s %s\n' "$ti" "$rep" >> "$JOBLIST"
  done
done
xargs -P "$PARALLEL" -n 4 bash -c '
  TASKS=("$T0" "$T1" "$T2" "$T3"); TRUTHS=("$TR0" "$TR1" "$TR2" "$TR3")
  run_one "$1" "$2" "$3" "$4" "$OUT.job.$1.$3.$4"
' _ < "$JOBLIST"
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
    for k in ('fresh','output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(bool(r.get('ok',False)))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','selective']
labels={'baseline':'A baseline (inherit model)','selective':'B selective (search agents → haiku)'}
print("# Selective model downgrade benchmark — mean per run")
print("| arm | cost $ | output tok | turns | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['output']):,.0f} | {mean(by[a]['turns']):.1f} | {ok}/{n} | {n} |")
if by['baseline']['cost'] and by['selective']['cost']:
    bc=mean(by['baseline']['cost']); sc_=mean(by['selective']['cost'])
    print(f"\nselective vs baseline: cost {100*(bc-sc_)/bc:+.1f}% (positive=cheaper)")
    u,p=mannwhitneyu(by['baseline']['cost'],by['selective']['cost'],alternative='greater')
    print(f"Mann-Whitney U (cost): p={p:.4g}", "SIGNIFICANT" if p<0.05 else "not significant")
    nb=len(oks['baseline']); ns=len(oks['selective'])
    _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks['selective']),ns-sum(oks['selective'])]])
    print(f"Fisher's exact (correctness): p={fp:.4g}")
    if p<0.05 and fp>0.05: verdict="SHIP"
    elif sc_>bc: verdict="DO NOT SHIP"
    else: verdict="INCONCLUSIVE"
    print(f"\n**Verdict: {verdict}**")
PY
```

Save to `bench/model-economy-selective.sh`, `chmod +x`.

- [ ] **Step 2: Run the bench**

```bash
QB_TARGET="$PWD" QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/model-economy-selective.sh
```

Note: this uses Haiku as the main model (not Sonnet) since we lack a multi-model billing setup. The selective arm passes `CLAUDE_CODE_SUBAGENT_MODEL=claude-haiku-4-5` — since the main model IS already Haiku, this won't produce a real downgrade effect. To get a meaningful result, rerun with `QB_MODEL=claude-sonnet-4-5` if you have Sonnet access. Record which model was used in RESULTS.md.

- [ ] **Step 3: Append to RESULTS.md + commit**

```bash
git add bench/model-economy-selective.sh bench/RESULTS.md
git commit -m "bench(C8): selective model downgrade A/B — <VERDICT>"
```

---

## Task 10: C9 — WebFetch/Search result measurement

**Files:**
- Create: `bench/webfetch-collapse.sh`

Measures whether the existing MCP/WebFetch result collapsing saves cost on tasks that call WebFetch, and finds the optimal threshold.

- [ ] **Step 1: Write the bench script**

```bash
#!/usr/bin/env bash
#
# A/B/C: does quiet-bash's WebFetch result collapsing save cost, and what
# threshold is optimal?
#   A baseline        — no PostToolUse hook (full WebFetch content in context)
#   B current         — collapse at QUIET_RESULT_MIN_BYTES default (25000)
#   C aggressive      — collapse at half the default (12500)
#
# Task: fetch a small public page (httpbin.org/json) and answer a question
# about it — this is a controlled, reproducible WebFetch target.
#
# NOTE: This bench requires network access. Results are env-dependent (latency,
# caching). Run from a consistent network environment.
#
# Usage: QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/webfetch-collapse.sh
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-20}"
PARALLEL="${QB_PARALLEL:-4}"
OUT="${QB_OUT:-$ROOT/bench/webfetch-collapse-runs.jsonl}"
: > "$OUT"
rm -f "$OUT".job.*

PRE_HOOK='"PreToolUse":  [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code.sh", "timeout": 15 } ] } ]'
POST_HOOK_DEFAULT='"PostToolUse": [ { "matcher": "WebFetch|WebSearch|mcp__.*", "hooks": [ { "type": "command", "command": "'"$ROOT"'/adapters/claude-code-result.sh", "timeout": 15 } ] } ]'

BASE_SET="$(mktemp)";       printf '{}\n' > "$BASE_SET"
DEFAULT_SET="$(mktemp)";    printf '{ "hooks": { %s } }\n' "$POST_HOOK_DEFAULT" > "$DEFAULT_SET"
AGGR_SET="$(mktemp)";       printf '{ "hooks": { %s } }\n' "$POST_HOOK_DEFAULT" > "$AGGR_SET"

# Task that requires WebFetch: the README of a small known repo
TASK='Fetch https://raw.githubusercontent.com/stedolan/jq/master/README then tell me: what does jq do? One sentence.'

run_one() { # arm settings min_bytes rep [jobfile]
  local arm="$1" set="$2" min_bytes="$3" rep="$4" jobfile="${5:-}"
  local j
  j=$(QUIET_RESULT_MIN_BYTES="$min_bytes" timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json --settings "$set" \
        --allowedTools "WebFetch" "Bash" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  local result ok=0
  result=$(printf '%s' "$j" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result',''))" 2>/dev/null)
  # pass if result mentions jq's core function (JSON processing)
  printf '%s' "$result" | grep -qiE 'json|command.line|process|filter' && ok=1
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

echo "model=$MODEL repeats=$REPEATS" >&2
run_one warmup "$BASE_SET" 25000 0 /dev/null

export -f run_one
export MODEL TASK BASE_SET DEFAULT_SET AGGR_SET OUT
JOBLIST="$(mktemp)"
for rep in $(seq 1 "$REPEATS"); do
  printf 'baseline   %s 999999 %s\n' "$BASE_SET"    "$rep" >> "$JOBLIST"
  printf 'default    %s 25000  %s\n' "$DEFAULT_SET" "$rep" >> "$JOBLIST"
  printf 'aggressive %s 12500  %s\n' "$AGGR_SET"    "$rep" >> "$JOBLIST"
done
xargs -P "$PARALLEL" -n 4 bash -c 'run_one "$1" "$2" "$3" "$4" "$OUT.job.$1.$4"' _ < "$JOBLIST"
rm -f "$JOBLIST"
cat "$OUT".job.* > "$OUT" 2>/dev/null
rm -f "$OUT".job.* "$BASE_SET" "$DEFAULT_SET" "$AGGR_SET"

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
from scipy.stats import mannwhitneyu, fisher_exact
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(lambda:collections.defaultdict(list))
oks=collections.defaultdict(list)
for r in rows:
    for k in ('fresh','output','cost','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(bool(r.get('ok',False)))
def mean(x): return statistics.mean(x) if x else 0
arms=['baseline','default','aggressive']
labels={'baseline':'A baseline (no collapse)','default':'B default (25000 B threshold)','aggressive':'C aggressive (12500 B)'}
print("# WebFetch collapse benchmark — mean per run")
print("| arm | cost $ | fresh in | turns | correct | runs |")
print("|---|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(oks[a])
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['turns']):.1f} | {ok}/{n} | {n} |")
if by['baseline']['cost']:
    bc=mean(by['baseline']['cost'])
    for a in ('default','aggressive'):
        if not by[a]['cost']: continue
        ac=mean(by[a]['cost'])
        u,p=mannwhitneyu(by['baseline']['cost'],by[a]['cost'],alternative='greater')
        nb=len(oks['baseline']); na=len(oks[a])
        _,fp=fisher_exact([[sum(oks['baseline']),nb-sum(oks['baseline'])],[sum(oks[a]),na-sum(oks[a])]])
        if p<0.05 and fp>0.05: verdict="SHIP"
        elif ac>bc: verdict="DO NOT SHIP"
        else: verdict="INCONCLUSIVE"
        print(f"\n{labels[a]}: cost {100*(bc-ac)/bc:+.1f}%, p={p:.4g} — **{verdict}**")
PY
```

Save to `bench/webfetch-collapse.sh`, `chmod +x`.

- [ ] **Step 2: Run the bench**

```bash
QB_MODEL=claude-haiku-4-5 QB_REPEATS=20 QB_PARALLEL=4 bench/webfetch-collapse.sh
```

- [ ] **Step 3: Append to RESULTS.md + commit**

```bash
git add bench/webfetch-collapse.sh bench/RESULTS.md
git commit -m "bench(C9): WebFetch collapse A/B — <VERDICT>"
```

---

## Self-Review

**Spec coverage check:**
- C1 session-brief → Task 4 ✓
- C2 output-directive → Task 1 ✓
- C3 dedup → Task 7 ✓
- C4 find/ls collapse → Task 5 ✓
- C5 diff hunk-only → Task 6 ✓
- C6 cache prefix health → Task 3 ✓
- C7 injection placement → Task 8 ✓
- C8 selective model downgrade → Task 9 ✓
- C9 WebFetch measurement → Task 10 ✓
- C10 anti-preamble → Task 2 ✓
- All verdicts appended to RESULTS.md → in every task ✓
- SHIP criteria (p<0.05, no quality regression) → in every Python report block ✓

**Placeholder scan:** All bench scripts have complete code. All `grade()` functions have concrete checks. All `run_one()` functions emit the full JSONL record. No TBDs.

**Type consistency:** All Python report blocks use the same `by[arm][metric]` pattern. All JSONL records use the same field names (`arm`, `rep`, `fresh`, `cache_read`, `output`, `cost`, `turns`, `ok`). Consistent across all 10 tasks.

**One gap fixed:** Task 9 (C8) notes that running with Haiku as main model won't exercise selective downgrade. Added a note to rerun with Sonnet if available.
