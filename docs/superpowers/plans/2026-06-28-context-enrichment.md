# Context Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship `quiet-env` (environment/capability digest), `quiet-map` (folder map: size/context-risk, churn, tree), and `bench/enrichment.*` (measure the cost/time savings).

**Architecture:** Two zero-dependency `core/` verbs mirroring `core/quiet-verify.sh`; a benchmark trio mirroring `bench/model-economy.*` (tasks+grader, runner, python report) with canned-data unit tests. Stacks on branch `deterministic-first-folder-maps` (off merged main).

**Tech Stack:** bash + coreutils + git + jq; bench report uses python3 (report only). Tests append to `tests/run.sh` (`pass`/`bad`, `== … ==` headers, `$ROOT` predefined).

## Global Constraints

- **Zero new dependencies** — bash + coreutils + git + jq; bench report python3 (like the existing one).
- **No regression / lossless** — verbs are read-only, never mutate; they orient (point at files / report capabilities), never replace reading. Honest output (a *map*, not content; only report tools actually present).
- **Portability (verified)** — NO `find -printf` (absent on BSD); CPU via `getconf _NPROCESSORS_ONLN` → `sysctl -n hw.ncpu` → `?`; `go version` (not `--version`); `java -version` → stderr (`2>&1`); `python3` (not `python`); line-count maps must text-filter (`grep -Il .`) so binaries aren't counted; folder spine = `git ls-files -z` in a repo else `find … -print0`.
- **Match existing style** — `core/` scripts mirror `core/quiet-verify.sh` (shebang, doc header, arg guards usage→stderr+exit 2, `[quiet-…]` provenance). Bench mirrors `bench/model-economy.*`.
- **Dropped (do NOT build):** MCP/skills enrichment (harness already provides), symbol/repo-map (deferred).
- Spec: `docs/superpowers/specs/2026-06-28-context-enrichment-design.md`.

---

### Task 1: `quiet-env` verb

**Files:** Create `core/quiet-env.sh`; Test: append to `tests/run.sh`.

**Interface:** `core/quiet-env.sh` (no args) → a compact digest: `[quiet-env] platform: …`, package manager(s) (from lockfiles), project markers, runtimes (present-only), CLIs present. Exit 0.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` before the final summary/exit block:

```bash
echo "== quiet-env =="
QE="$ROOT/core/quiet-env.sh"
out=$("$QE"); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q '\[quiet-env\] platform'; } && pass "quiet-env runs + platform" || bad "quiet-env platform"
printf '%s' "$out" | grep -q 'git' && pass "quiet-env lists git CLI" || bad "quiet-env git"
ED=$(mktemp -d); ( cd "$ED" && : > pnpm-lock.yaml && "$QE" ) | grep -q 'pnpm' && pass "quiet-env detects pnpm" || bad "quiet-env pnpm"
rm -rf "$ED"
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run.sh` → `quiet-env` lines FAIL.

- [ ] **Step 3: Implement**

Create `core/quiet-env.sh`:

```bash
#!/usr/bin/env bash
#
# quiet-env — deterministic environment / capability digest in one shot, so the
# agent stops probing (`node -v`, `which docker`, guessing the package manager).
#
#   quiet-env.sh
#
# Reports only what's actually present. Read-only. (MCP servers / skills are
# intentionally omitted — the agent's harness already lists them.)

_present() { command -v "$1" >/dev/null 2>&1; }
_ver() { # label cmd version-args...
  local label="$1" cmd="$2"; shift 2
  _present "$cmd" || return 0
  printf '  %-8s %s\n' "$label" "$("$cmd" "$@" 2>&1 | head -1)"
}

cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')
echo "[quiet-env] platform: $(uname -s) $(uname -m) | shell ${SHELL##*/} | cpus $cpus"

pm=""
[ -f pnpm-lock.yaml ]     && pm="$pm pnpm"
[ -f yarn.lock ]          && pm="$pm yarn"
[ -f bun.lockb ]          && pm="$pm bun"
[ -f package-lock.json ]  && pm="$pm npm"
[ -f poetry.lock ]        && pm="$pm poetry"
[ -f uv.lock ]            && pm="$pm uv"
[ -f Pipfile.lock ]       && pm="$pm pipenv"
[ -f requirements.txt ]   && pm="$pm pip"
[ -n "$pm" ] && echo "[quiet-env] package manager(s):$pm"

eco=""
for m in package.json pyproject.toml go.mod Cargo.toml Gemfile pom.xml; do [ -f "$m" ] && eco="$eco $m"; done
[ -n "$eco" ] && echo "[quiet-env] project markers:$eco"

echo "[quiet-env] runtimes:"
_ver node   node    --version
_ver python python3 --version
_ver go     go      version
_ver rust   rustc   --version
_ver java   java    -version
_ver ruby   ruby    --version
_ver deno   deno    --version
_ver bun    bun     --version

clis=""
for c in git rg jq fd gh docker kubectl make cargo curl tree; do _present "$c" && clis="$clis $c"; done
echo "[quiet-env] CLIs present:$clis"
```

Then `chmod +x core/quiet-env.sh`.

- [ ] **Step 4: Run to verify pass** — `bash tests/run.sh` → all `quiet-env` lines `ok`, suite exit 0.

- [ ] **Step 5: Commit**

```bash
git add core/quiet-env.sh tests/run.sh
git commit -m "feat: quiet-env — one-shot environment/capability digest (no probing)"
```

---

### Task 2: `quiet-map` verb

**Files:** Create `core/quiet-map.sh`; Test: append to `tests/run.sh`.

**Interface:** `core/quiet-map.sh [--churn|--tree]`. Default: largest files by line count (top `QUIET_MAP_TOP`=25), flagging files over `QUIET_MAP_BIG_LINES`=800 with `⚠`. `--churn` (git only): most-changed files. `--tree`: files-per-top-dir. Unknown flag → exit 2; `--churn` outside git → exit 2.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` before the final summary/exit block:

```bash
echo "== quiet-map =="
QM="$ROOT/core/quiet-map.sh"
out=$("$QM"); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q '\[quiet-map\] largest'; } && pass "quiet-map size map runs" || bad "quiet-map size"
QUIET_MAP_BIG_LINES=10 "$QM" | grep -q '⚠' && pass "quiet-map flags big files" || bad "quiet-map flag"
"$QM" --churn >/dev/null 2>&1; [ $? -eq 0 ] && pass "quiet-map --churn runs in repo" || bad "quiet-map churn"
"$QM" --tree | grep -q 'core' && pass "quiet-map --tree lists dirs" || bad "quiet-map tree"
"$QM" --bogus >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-map unknown flag exit 2" || bad "quiet-map unknown flag"
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run.sh` → `quiet-map` lines FAIL.

- [ ] **Step 3: Implement**

Create `core/quiet-map.sh`:

```bash
#!/usr/bin/env bash
#
# quiet-map — deterministic folder map so the agent orients without exploring +
# reading files. Read-only; it points at files, never replaces reading them.
#
#   quiet-map.sh            # largest files by line count + ⚠ "too big to Read whole"
#   quiet-map.sh --churn    # most-changed files (git) — where the live code is
#   quiet-map.sh --tree     # files per top-level directory
#
# Env: QUIET_MAP_TOP (25), QUIET_MAP_BIG_LINES (800), QUIET_MAP_CHURN_COMMITS (500).

TOP="${QUIET_MAP_TOP:-25}"
BIG="${QUIET_MAP_BIG_LINES:-800}"
CHURN_N="${QUIET_MAP_CHURN_COMMITS:-500}"

_filelist0() { # NUL-delimited, gitignore-aware in a repo
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -z
  else
    find . -type f -not -path './.git/*' -print0
  fi
}

mode="${1:-}"
case "$mode" in
  "" )
    out=$(_filelist0 | xargs -0 grep -Il . 2>/dev/null | tr '\n' '\0' | xargs -0 wc -l 2>/dev/null \
      | awk '{c=$1; $1=""; sub(/^[ \t]+/,""); if ($0!="total" && $0!="") print c"\t"$0}' \
      | sort -rn | head -n "$TOP")
    [ -n "$out" ] || { echo "[quiet-map] no text files found"; exit 0; }
    echo "[quiet-map] largest files by line count (top $TOP; ⚠ = >$BIG lines → prefer quiet-outline / Read with offset):"
    printf '%s\n' "$out" | awk -F'\t' -v big="$BIG" '{ f=($1>big)?" ⚠":""; printf "%8d  %s%s\n",$1,$2,f }'
    ;;
  --churn )
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "quiet-map: --churn needs a git repo" >&2; exit 2; }
    echo "[quiet-map] most-changed files (last $CHURN_N commits):"
    git log --format= --name-only -n "$CHURN_N" 2>/dev/null | sed '/^$/d' | sort | uniq -c | sort -rn | head -n "$TOP"
    ;;
  --tree )
    echo "[quiet-map] files per top-level dir:"
    _filelist0 | tr '\0' '\n' | awk -F/ '{ d=(NF>1)?$1"/":"(root)"; c[d]++ } END { for (k in c) printf "%6d  %s\n", c[k], k }' | sort -rn
    ;;
  * )
    echo "usage: quiet-map.sh [--churn|--tree]" >&2; exit 2 ;;
esac
```

Then `chmod +x core/quiet-map.sh`.

- [ ] **Step 4: Run to verify pass** — `bash tests/run.sh` → all `quiet-map` lines `ok`, suite exit 0.

- [ ] **Step 5: Commit**

```bash
git add core/quiet-map.sh tests/run.sh
git commit -m "feat: quiet-map — deterministic folder map (size/context-risk, churn, tree)"
```

---

### Task 3: `bench/enrichment.*` — measurement harness

**Files:** Create `bench/enrichment-tasks.sh`, `bench/enrichment-report.py`, `bench/enrichment.sh`; Test: append canned-data unit tests to `tests/run.sh`.

**Interface:** mirrors `bench/model-economy.*`. `enrichment-tasks.sh` defines `FM_TASK_PROMPTS`/`FM_TASK_ASSERTS` + `fm_grade <i> <answer>` (pass|fail; out-of-range → fail). `enrichment-report.py <jsonl>` → per-arm table + ZERO-REGRESSION/SHIP verdict vs control. `enrichment.sh` runs arms (control vs map). **Read `bench/model-economy.sh`, `-tasks.sh`, `-report.py` first and mirror their structure.**

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` before the final summary/exit block (canned data — no live model):

```bash
echo "== bench: enrichment grading =="
. "$ROOT/bench/enrichment-tasks.sh"
[ "$(fm_grade 0 'You would edit core/quiet-core.sh for that')" = pass ] && pass "fm_grade correct→pass" || bad "fm_grade correct"
[ "$(fm_grade 0 'totally unrelated')" = fail ] && pass "fm_grade wrong→fail" || bad "fm_grade wrong"
[ "$(fm_grade 99 'anything')" = fail ] && pass "fm_grade out-of-range→fail" || bad "fm_grade oor"
{ [ "${#FM_TASK_PROMPTS[@]}" -eq "${#FM_TASK_ASSERTS[@]}" ] && [ "${#FM_TASK_PROMPTS[@]}" -gt 0 ]; } && pass "fm tasks aligned" || bad "fm aligned"

echo "== bench: enrichment report =="
ft=$(mktemp)
cat > "$ft" <<'JSONL'
{"arm":"control","task":0,"rep":1,"input":2000,"output":80,"cost":0.05,"ms":9000,"turns":6,"pass":true}
{"arm":"control","task":1,"rep":1,"input":2200,"output":90,"cost":0.06,"ms":9500,"turns":6,"pass":true}
{"arm":"map","task":0,"rep":1,"input":1200,"output":70,"cost":0.03,"ms":6000,"turns":4,"pass":true}
{"arm":"map","task":1,"rep":1,"input":1300,"output":75,"cost":0.035,"ms":6200,"turns":4,"pass":true}
JSONL
frep=$(python3 "$ROOT/bench/enrichment-report.py" "$ft")
printf '%s' "$frep" | grep -q 'ZERO-REGRESSION ✓' && pass "report: equal pass-rate → zero-regression" || bad "report zero-regression"
printf '%s' "$frep" | grep -Eq 'cost -[0-9]' && pass "report: cheaper arm shows negative cost delta" || bad "report cost delta"
rm -f "$ft"
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run.sh` → bench lines FAIL (files missing).

- [ ] **Step 3: Implement `bench/enrichment-tasks.sh`**

```bash
#!/usr/bin/env bash
# Task suite + grading for the context-enrichment benchmark. Code-localization
# tasks over THIS repo (stable ground truth). Sourced by bench/enrichment.sh and
# tests/run.sh — no top-level side effects.

FM_TASK_PROMPTS=(
  "Which file would you edit to change how recursive grep/rg output is collapsed? Give its path."
  "Which core/ file implements the duplicate-read dedup helper? Give its path."
  "Which adapter file shrinks large PostToolUse tool results? Give its path."
  "Which file holds the deterministic-first skill cheatsheet you'd add a row to? Give its path."
)

FM_TASK_ASSERTS=(
  'core/quiet-core\.sh'
  'core/quiet-dedup\.sh'
  'adapters/claude-code-result\.sh'
  'skills/deterministic-first/SKILL\.md'
)

# fm_grade <task_index> <answer_text> -> echoes pass|fail, returns 0|1
fm_grade() {
  local rx="${FM_TASK_ASSERTS[$1]:-}"
  [ -z "$rx" ] && { echo fail; return 1; }
  if printf '%s' "$2" | grep -Eiq "$rx"; then echo pass; return 0; fi
  echo fail; return 1
}
```

- [ ] **Step 4: Implement `bench/enrichment-report.py`** (mirror `bench/model-economy-report.py`, arms control/map/symbol)

```python
#!/usr/bin/env python3
"""Aggregate context-enrichment benchmark JSONL into a table + gate verdict.

An arm passes the gate iff its pass-rate >= control's (zero regression) AND its
mean cost is lower. Cheaper-but-regressed is DO NOT SHIP.
"""
import sys, json, collections, statistics

rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by = collections.defaultdict(lambda: collections.defaultdict(list))
for r in rows:
    for k in ("input", "output", "cost", "ms"):
        by[r["arm"]][k].append(r[k])
    by[r["arm"]]["pass"].append(1 if r.get("pass") else 0)

def mean(x): return statistics.mean(x) if x else 0.0

arms = [a for a in ("control", "map", "symbol") if by[a]["input"]]
print("# quiet-bash context-enrichment benchmark — mean per run")
print("| arm | input tok | output tok | cost $ | time s | turns | pass-rate | runs |")
print("|---|--:|--:|--:|--:|--:|--:|--:|")
for a in arms:
    pr = mean(by[a]["pass"]) * 100
    print(f"| {a} | {mean(by[a]['input']):,.0f} | {mean(by[a]['output']):,.0f} | "
          f"{mean(by[a]['cost']):.4f} | {mean(by[a]['ms'])/1000:.1f} | {mean(by[a].get('turns',[0])) if by[a].get('turns') else 0:.1f} | {pr:.0f}% | {len(by[a]['input'])} |")

base_pr = mean(by["control"]["pass"]) * 100 if by["control"]["input"] else None
base_cost = mean(by["control"]["cost"]) if by["control"]["input"] else None
base_ms = mean(by["control"]["ms"]) if by["control"]["input"] else None
print()
for a in arms:
    if a == "control" or base_pr is None:
        continue
    pr = mean(by[a]["pass"]) * 100
    cost = mean(by[a]["cost"]); ms = mean(by[a]["ms"])
    regress = "ZERO-REGRESSION ✓" if pr >= base_pr else "ZERO-REGRESSION ✗"
    cost_str = f"cost {100*(cost-base_cost)/base_cost:+.1f}%" if base_cost else "cost n/a"
    time_str = f"time {100*(ms-base_ms)/base_ms:+.1f}%" if base_ms else "time n/a"
    verdict = "SHIP" if (pr >= base_pr and cost < base_cost) else "DO NOT SHIP"
    print(f"**arm {a}: {regress} (pass {pr:.0f}% vs control {base_pr:.0f}%), "
          f"{cost_str}, {time_str} → {verdict}** (negative = cheaper/faster).")
```

- [ ] **Step 5: Implement `bench/enrichment.sh`** (mirror `bench/model-economy.sh`; per-arm map prepend instead of subagent-model swap)

```bash
#!/usr/bin/env bash
#
# 2-arm context-enrichment benchmark for quiet-bash.
# Measures whether prepending a deterministic map (quiet-env + quiet-map) to a
# code-localization task reduces cost & wall-clock with zero answer-quality
# regression. Arms: control (no map) | map (map prepended). See the design spec.
#
#   FM_TARGET=$PWD FM_MODEL=haiku FM_REPEATS=3 bench/enrichment.sh
#
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$ROOT/bench/enrichment-tasks.sh"

TARGET="${FM_TARGET:-$ROOT}"
MODEL="${FM_MODEL:-haiku}"
REPEATS="${FM_REPEATS:-3}"
ARMS="${FM_ARMS:-control map}"
BUDGET="${FM_BUDGET:-4000}"
OUT="${FM_OUT:-$ROOT/bench/enrichment-runs.jsonl}"
: > "$OUT"

MAP="$( { cd "$TARGET" && "$ROOT/core/quiet-env.sh"; echo; "$ROOT/core/quiet-map.sh"; } 2>/dev/null | head -c "$BUDGET" )"

run_one() { # arm task_idx rep
  local arm="$1" ti="$2" rep="$3" task="${FM_TASK_PROMPTS[$2]}" prompt j answer grade
  case "$arm" in
    map)    prompt=$(printf 'Repo & environment map (deterministic):\n\n%s\n\n%s' "$MAP" "$task") ;;
    *)      prompt="$task" ;;
  esac
  j=$(cd "$TARGET" && timeout 300 claude -p "$prompt" --model "$MODEL" --output-format json \
        --allowedTools "Bash" "Read" "Grep" "Glob" 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} task${ti} rep${rep}: no output" >&2; return; }
  answer=$(printf '%s' "$j" | jq -r '.result // ""')
  grade=$(fm_grade "$ti" "$answer")
  printf '%s\n' "$j" | FM_ARM="$arm" FM_TI="$ti" FM_REP="$rep" FM_GRADE="$grade" python3 -c "
import sys,json,os
o=json.load(sys.stdin); u=o.get('usage',{}) or {}
inp=(u.get('input_tokens',0) or 0)+(u.get('cache_read_input_tokens',0) or 0)+(u.get('cache_creation_input_tokens',0) or 0)
rec={'arm':os.environ['FM_ARM'],'task':int(os.environ['FM_TI']),'rep':int(os.environ['FM_REP']),
     'input':inp,'output':u.get('output_tokens',0) or 0,'cost':o.get('total_cost_usd',0) or 0,
     'ms':o.get('duration_ms',0) or 0,'turns':o.get('num_turns',0),'pass':(os.environ['FM_GRADE']=='pass')}
print(json.dumps(rec))
" >> "$OUT"
  echo "  ${grade} ${arm} task${ti} rep${rep}" >&2
}

echo "model=$MODEL repeats=$REPEATS arms='$ARMS' target=$TARGET" >&2
for ti in "${!FM_TASK_PROMPTS[@]}"; do
  for rep in $(seq 1 "$REPEATS"); do
    for arm in $ARMS; do run_one "$arm" "$ti" "$rep"; done
  done
done
echo >&2
python3 "$ROOT/bench/enrichment-report.py" "$OUT"
```

Then `chmod +x bench/enrichment-tasks.sh bench/enrichment.sh` (the `.py` need not be executable; it's run via `python3`).

- [ ] **Step 6: Run to verify pass** — `bash tests/run.sh` → all bench lines `ok`, suite exit 0. (`bench/enrichment-runs.jsonl` is already gitignored by `bench/*-runs.jsonl`.)

- [ ] **Step 7: Commit**

```bash
git add bench/enrichment-tasks.sh bench/enrichment-report.py bench/enrichment.sh tests/run.sh
git commit -m "feat(bench): context-enrichment benchmark (control vs map; cost+time gate)"
```

---

### Task 4: Skill + README surface

**Files:** Modify `skills/deterministic-first/SKILL.md`, `README.md`; Test: structural assertion in `tests/run.sh`.

- [ ] **Step 1: Write the failing structural test**

Append to `tests/run.sh` before the final summary/exit block:

```bash
echo "== enrichment skill rows =="
SKE="$ROOT/skills/deterministic-first/SKILL.md"
for tok in 'quiet-env' 'quiet-map'; do
  grep -qF "$tok" "$SKE" 2>/dev/null && pass "skill mentions $tok" || bad "skill missing $tok"
done
grep -q 'Orient' "$SKE" 2>/dev/null && pass "skill has orient row" || bad "skill orient row"
```

- [ ] **Step 2: Run to verify it fails** — those lines FAIL.

- [ ] **Step 3: Add skill cheatsheet row**

In `skills/deterministic-first/SKILL.md`, in the pattern table under `## The decision rule`, add after the **Code archaeology** row:

```markdown
| **Orient** in an unfamiliar repo / env | `ls`/`find`/read files; probe `node -v`/`which X` | `quiet-map` (sizes/churn/tree) · `quiet-env` (pkg-mgr, CLIs, versions) |
```

- [ ] **Step 4: Add the README row**

In `README.md`, find the row beginning `| **Lookups & archaeology**` (round 2). Directly beneath it, add:

```markdown
| **Orientation** — repo shape & toolchain | model explores with `ls`/`find`/reads, probes `node -v`/`which` | `quiet-map` (file-size/churn/tree map) · `quiet-env` (one-shot env digest) |
```

- [ ] **Step 5: Run to verify pass** — `bash tests/run.sh` → `enrichment skill rows` `ok`; existing structural test still green; suite exit 0.

- [ ] **Step 6: Commit**

```bash
git add skills/deterministic-first/SKILL.md README.md tests/run.sh
git commit -m "docs: surface quiet-env/quiet-map orientation in skill + README"
```

---

## Notes for the implementer
- **Order 1→4.** Append each test section after existing ones; never disturb the final `[ "$fail" -eq 0 ]` accounting.
- **Task 3** is integration: READ `bench/model-economy.{sh,sh,py}` first and mirror them (the report/runner here are close variants — arms control/map, per-arm map prepend, `total_cost_usd`/`duration_ms` capture). The bench is unit-tested with CANNED JSONL only (no live `claude` in CI).
- **Portability:** do not use `find -printf`, `stat -c`, `nproc`, or `python` (use python3); the provided code already avoids these.
- **Do not** weaken arg guards (unknown flag / non-git `--churn` → exit 2 are required).
