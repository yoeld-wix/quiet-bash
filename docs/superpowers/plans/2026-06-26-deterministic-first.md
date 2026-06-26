# Deterministic-first Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a quiet-bash lever that pushes find/count/extract/verify work onto deterministic shell pipelines instead of the model reading content into context — via a `deterministic-first` skill plus two thin `core/` verbs.

**Architecture:** A new skill (`skills/deterministic-first/SKILL.md`, sibling to `minimal-change`) carries the decision rule and pattern cheatsheet — the model stays in control, so it's lossless by construction. Two small zero-dependency `core/` scripts (`quiet-verify.sh`, `quiet-agg.sh`) back the two pipelines whose ergonomics actually deter agents. A composition test proves the bridge to quiet-bash's existing spill files. No interception/rewrite of agent actions (that would breach the no-regression invariant).

**Tech Stack:** `bash` + `jq` (already required), POSIX `grep`/`sort`/`uniq`. Tests are assertion blocks appended to `tests/run.sh`. Skills are auto-discovered from `skills/` — no manifest change.

## Global Constraints

- **Zero new dependencies** — `bash` + `jq` only (`jq` already required); no daemon, no network, no model call.
- **No regression / lossless** — verbs operate on a path and never swallow or mutate data; the skill must instruct reading-not-piping whenever a pipeline could miss what's needed.
- **No action rewriting** — this lever never rewrites or blocks an agent tool call (see spec §2 regression boundary). Skill + opt-in verbs only.
- **Match existing style** — `core/` scripts mirror `core/quiet-query.sh` (shebang, doc-comment header, `ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"`, source `quiet-core.sh` only if needed). Tests mirror `tests/run.sh` (`pass`/`bad` helpers, `echo "== … =="` section headers). Skill mirrors `skills/minimal-change/SKILL.md` (frontmatter `name`+`description`, short scannable body).
- **Provenance** — every verb prints a one-line `[quiet-verify]`/`[quiet-agg]` header so its output is self-describing in the transcript.
- Spec of record: `docs/superpowers/specs/2026-06-26-deterministic-first-design.md`.

---

### Task 1: `quiet-verify` verb

A presence check: count matching lines in a file, print `OK`/`FAIL` + count, exit code reflects it. Replaces "read the log to confirm X happened."

**Files:**
- Create: `core/quiet-verify.sh`
- Test: append a section to `tests/run.sh`

**Interfaces:**
- Produces: `core/quiet-verify.sh <file> <pattern>` — prints `[quiet-verify] OK — <n> line(s) match /<pattern>/ in <file>` and exits 0 when `n>0`; prints `[quiet-verify] FAIL — no lines match /<pattern>/ in <file>` and exits 1 when `n==0`; prints usage to stderr and exits 2 on missing args or unreadable file. `<pattern>` is an ERE (`grep -E`).

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` (before the final `exit` line):

```bash
echo "== quiet-verify =="
QV="$ROOT/core/quiet-verify.sh"
VF=$(mktemp); printf 'build ok\nPASS test_a\nPASS test_b\n' > "$VF"
out=$("$QV" "$VF" 'PASS'); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q 'OK' && printf '%s' "$out" | grep -q '2 line'; } \
  && pass "quiet-verify hit: OK + count + exit 0" || bad "quiet-verify hit"
out=$("$QV" "$VF" 'FAILURE'); st=$?
{ [ "$st" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL'; } \
  && pass "quiet-verify miss: FAIL + exit 1" || bad "quiet-verify miss"
"$QV" "$VF" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-verify usage exit 2" || bad "quiet-verify usage"
"$QV" /no/such/file 'x' >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-verify missing-file exit 2" || bad "quiet-verify missing-file"
rm -f "$VF"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: the four `quiet-verify` lines print `FAIL` (script `core/quiet-verify.sh` does not exist yet), suite exits non-zero.

- [ ] **Step 3: Write minimal implementation**

Create `core/quiet-verify.sh`:

```bash
#!/usr/bin/env bash
#
# quiet-verify — verify a fact against a file without reading it into context.
#
#   quiet-verify.sh <file> <pattern>
#
# Counts lines matching <pattern> (an ERE). Prints OK + count and exits 0 when
# there is at least one match; prints FAIL and exits 1 when there are none.
# Use instead of reading a log/output to confirm something happened.
#
#   quiet-verify.sh build.log 'BUILD SUCCESS'
#   quiet-verify.sh test.out  'FAIL|Error'

file="${1:-}"; pat="${2:-}"
[ -n "$file" ] && [ -n "$pat" ] || { echo "usage: quiet-verify.sh <file> <pattern>" >&2; exit 2; }
[ -r "$file" ] || { echo "quiet-verify: cannot read $file" >&2; exit 2; }

n=$(grep -Ec -- "$pat" "$file" 2>/dev/null || true); n=${n:-0}
if [ "$n" -gt 0 ]; then
  echo "[quiet-verify] OK — $n line(s) match /$pat/ in $file"
  exit 0
else
  echo "[quiet-verify] FAIL — no lines match /$pat/ in $file"
  exit 1
fi
```

Then make it executable: `chmod +x core/quiet-verify.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: the four `quiet-verify` lines print `ok`; suite exits 0 (assuming no pre-existing failures).

- [ ] **Step 5: Commit**

```bash
git add core/quiet-verify.sh tests/run.sh
git commit -m "feat: quiet-verify — verify a fact against a file without reading it"
```

---

### Task 2: `quiet-agg` verb

Frequency table over regex matches: the "I'll just read it and tally" case, done deterministically.

**Files:**
- Create: `core/quiet-agg.sh`
- Test: append a section to `tests/run.sh`

**Interfaces:**
- Produces: `core/quiet-agg.sh <file> <regex> [n=20]` — prints `[quiet-agg] top <n> of /<regex>/ in <file>:` then a `count token` table (descending, `grep -oE` matches → `sort | uniq -c | sort -rn | head -n <n>`). Prints `[quiet-agg] no matches for /<regex>/ in <file>` and exits 0 when there are none. Usage to stderr + exit 2 on missing args/unreadable file.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` (before the final `exit` line):

```bash
echo "== quiet-agg =="
QA="$ROOT/core/quiet-agg.sh"
AF=$(mktemp); printf 'E101 boom\nE200 nope\nE101 again\nE101 third\nE200 second\n' > "$AF"
out=$("$QA" "$AF" 'E[0-9]+')
# E101 appears 3×, E200 2× — E101 must be the first data row
top=$(printf '%s' "$out" | grep -E 'E[0-9]+' | grep -v '\[quiet-agg\]' | head -1)
{ printf '%s' "$top" | grep -q 'E101' && printf '%s' "$top" | grep -q '3'; } \
  && pass "quiet-agg ranks E101(3) first" || bad "quiet-agg ranking"
out=$("$QA" "$AF" 'ZZZ'); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q 'no matches'; } \
  && pass "quiet-agg no-match exit 0" || bad "quiet-agg no-match"
"$QA" "$AF" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-agg usage exit 2" || bad "quiet-agg usage"
rm -f "$AF"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: the three `quiet-agg` lines print `FAIL` (`core/quiet-agg.sh` does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `core/quiet-agg.sh`:

```bash
#!/usr/bin/env bash
#
# quiet-agg — frequency table over regex matches in a file, without reading it.
#
#   quiet-agg.sh <file> <regex> [n=20]
#
# Extracts every match of <regex> (ERE, via grep -oE), then counts and ranks
# them descending — the deterministic form of "read it and tally by eye".
#
#   quiet-agg.sh app.log 'E[0-9]+'              # top error codes
#   quiet-agg.sh access.log '[0-9]{3}' 5        # top 5 HTTP statuses

file="${1:-}"; re="${2:-}"; n="${3:-20}"
[ -n "$file" ] && [ -n "$re" ] || { echo "usage: quiet-agg.sh <file> <regex> [n=20]" >&2; exit 2; }
[ -r "$file" ] || { echo "quiet-agg: cannot read $file" >&2; exit 2; }

table=$(grep -oE -- "$re" "$file" 2>/dev/null | sort | uniq -c | sort -rn | head -n "$n")
if [ -z "$table" ]; then
  echo "[quiet-agg] no matches for /$re/ in $file"
  exit 0
fi
echo "[quiet-agg] top $n of /$re/ in $file:"
printf '%s\n' "$table"
```

Then: `chmod +x core/quiet-agg.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: the three `quiet-agg` lines print `ok`; suite exits 0.

- [ ] **Step 5: Commit**

```bash
git add core/quiet-agg.sh tests/run.sh
git commit -m "feat: quiet-agg — frequency table over regex matches without reading the file"
```

---

### Task 3: `deterministic-first` skill

The spine: the decision rule + pattern cheatsheet that changes the model's default reach. Lossless by construction (model stays in control).

**Files:**
- Create: `skills/deterministic-first/SKILL.md`
- Test: append a section to `tests/run.sh` (structural assertions only — content is prose)

**Interfaces:**
- Consumes: `core/quiet-verify.sh` (Task 1) and `core/quiet-agg.sh` (Task 2) — referenced by name in the cheatsheet.
- Produces: a skill file with YAML frontmatter (`name: deterministic-first`, a `description:` beginning with `Use before`) and body sections including the literal headings `## The decision rule`, a pattern table, `## Compose with quiet-bash`, and `## The no-regression floor`.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` (before the final `exit` line):

```bash
echo "== deterministic-first skill =="
SK="$ROOT/skills/deterministic-first/SKILL.md"
[ -f "$SK" ] && pass "skill file exists" || bad "skill file exists"
grep -q '^name: deterministic-first' "$SK" 2>/dev/null && pass "skill name frontmatter" || bad "skill name"
grep -q '^description: Use before' "$SK" 2>/dev/null && pass "skill description trigger" || bad "skill description"
for h in 'The decision rule' 'Compose with quiet-bash' 'The no-regression floor'; do
  grep -qF "$h" "$SK" 2>/dev/null && pass "skill section: $h" || bad "skill section: $h"
done
grep -q 'quiet-agg' "$SK" 2>/dev/null && grep -q 'quiet-verify' "$SK" 2>/dev/null \
  && pass "skill references the verbs" || bad "skill references verbs"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: the `deterministic-first skill` lines print `FAIL` (file does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Create `skills/deterministic-first/SKILL.md`:

```markdown
---
name: deterministic-first
description: Use before reading files or large output to find, count, extract, parse, verify, loop, or wait. Routes that work to a deterministic shell pipeline so the answer enters context, not the haystack — cheaper and more correct than reading content into the model.
---

# Pipe for the Answer, Don't Read the Haystack

quiet-bash's hooks shrink output you already chose to read. This is the other
move: change the *choice*. A human debugging a 10k-line log doesn't read it into
their head — they pipe `grep | sort | uniq -c`. The shell is cheaper (no tokens
for the haystack, none to re-send it every later turn) and more correct (a
`uniq -c` count doesn't hallucinate; a regex doesn't skim past line 4,000).

## The decision rule
Before issuing a Read / `cat` / large fetch **whose purpose is to locate or
compute something**, ask: *can a pipeline return just the answer?* If yes, run
the pipeline and let only the answer enter context.

| Task | Read-to-answer (avoid) | Deterministic form |
|---|---|---|
| **Find** where / which files | open files until you spot it | `rg -l PAT` · `rg -n PAT` · `grep -rln PAT` |
| **Count** / frequency | read log, tally by eye | `grep -c PAT` · `quiet-agg FILE 'PAT'` |
| **Extract** fields | copy values out of JSON/text | `jq '.path'` · `awk '{print $2}'` · `grep -oE` |
| **Parse** structured slices | scan a config visually | `jq` / `yq` / `quiet-query FILE keys` |
| **Verify** a fact | read output to confirm | `quiet-verify FILE 'PAT'` · `test -f` · exit code |
| **Repeat** over a set | N near-identical tool calls | `xargs` · `for f in …; do …; done` |
| **Wait** for a condition | poll by re-reading status | `until COND; do sleep N; done` |

## Compose with quiet-bash
When the haystack is a quiet-bash spill (`[ok: … hidden in <path>]` or a
`spilled to <path>` line), run the pipeline **against that file** —
`grep`/`jq`/`quiet-query <path>`/`quiet-verify <path> …`/`quiet-agg <path> …`.
You recover the exact answer without ever re-reading the haystack.

## The no-regression floor
Never trade correctness for a pipeline. If you genuinely need the full content —
reviewing prose, understanding unfamiliar code, any case where *you* are the
right judge — **read it**. A pipeline that misses the thing you needed costs far
more than it saves. This reflex is for *find / compute*, not for *understand*.
When a pattern might miss matches (case, word boundaries, multiline), widen it
or fall back to reading.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: all `deterministic-first skill` lines print `ok`; suite exits 0.

- [ ] **Step 5: Commit**

```bash
git add skills/deterministic-first/SKILL.md tests/run.sh
git commit -m "feat: deterministic-first skill — pipe for the answer, don't read the haystack"
```

---

### Task 4: Composition test + README row

Prove the spill→recover bridge end-to-end, and surface the lever in the README so it's discoverable.

**Files:**
- Modify: `tests/run.sh` (add composition section)
- Modify: `README.md` (add a row to the "What it covers" table)

**Interfaces:**
- Consumes: `core/quiet-verify.sh`, `core/quiet-agg.sh` (Tasks 1–2), and the existing `quiet_run` executor in `core/quiet-core.sh:71` which spills full output and prints `[ok: … hidden in <log>]`.

- [ ] **Step 1: Write the failing composition test**

Append to `tests/run.sh` (before the final `exit` line):

```bash
echo "== composition: spill -> recover with a verb =="
. "$ROOT/core/quiet-core.sh"
# Run a command whose output quiet_run spills to a temp log, then recover the
# answer from that spill with a verb — without re-reading the haystack.
SPILL_MSG=$(quiet_run printf 'WARN a\nERROR boom\nWARN b\n')
LOG=$(printf '%s' "$SPILL_MSG" | grep -oE "${QUIET_LOG_DIR%/}/${QUIET_LOG_PREFIX}[A-Za-z0-9]+" | head -1)
{ [ -n "$LOG" ] && [ -f "$LOG" ]; } && pass "spill log created" || bad "spill log created"
"$ROOT/core/quiet-verify.sh" "$LOG" 'ERROR' >/dev/null && pass "recover: verify hit on spill" || bad "recover: verify"
"$ROOT/core/quiet-agg.sh" "$LOG" 'WARN|ERROR' | grep -q 'WARN' && pass "recover: agg on spill" || bad "recover: agg"
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: the three `composition` lines print `ok`. (Verbs already exist from Tasks 1–2, so this passes immediately — it guards the documented bridge against future regressions.)

- [ ] **Step 3: Add the README row**

In `README.md`, find the "What it covers" table (the four-row table whose header row is `| What | Without quiet-bash | With quiet-bash |`). Add this row directly beneath the last existing row:

```markdown
| **Read-to-find work** — locating, counting, extracting, verifying over files/logs | model reads the haystack into context | `deterministic-first` skill + `quiet-verify`/`quiet-agg` return just the answer |
```

- [ ] **Step 4: Verify the table still renders**

Run: `grep -n 'Read-to-find work' README.md`
Expected: one line printed, inside the table block.

- [ ] **Step 5: Commit**

```bash
git add tests/run.sh README.md
git commit -m "test+docs: spill->recover composition test; surface deterministic-first in README"
```

---

## Notes for the implementer

- **Deferred by design (do NOT build):** the advisory PostToolUse hook (spec §4.3, "Component B"). It stays documented-but-unshipped because its intent-detection precision is low. Building it now would be scope creep — and it must *never* rewrite an action.
- **Verb set:** the spec (§8) leaves room to cut to one verb if either fails the "agents actually avoid this pipeline" bar. Ship both; revisit after real-transcript adoption data.
- **Bench scenario** (spec §6): a read-to-answer vs. pipe-to-answer token comparison in `bench/` is valuable but optional for this plan — it measures rather than implements the feature. Add it as a follow-up if a headline number is wanted, and keep it reproducible per `docs/maximizing-savings.md` norms (don't headline a session number the skill can't guarantee).
```

