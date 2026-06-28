# Deterministic-first Round 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship the approved round-2 tranche — `quiet-conf` (config value lookup), recursive search-output collapse (grep/rg), `quiet-hist`/`quiet-blame` (git archaeology), and math/date/`tsort` skill rows.

**Architecture:** Three new zero-dependency `core/` verbs mirroring `core/quiet-verify.sh`; one extension to the `quiet_rewrite` matcher in `core/quiet-core.sh` (verbatim-wrap recursive searches via the existing `_quiet_wrap_search`); SKILL.md + README surface. Stacks on the current expansion branch.

**Tech Stack:** bash + jq + coreutils + git. Tests append to `tests/run.sh` (`pass`/`bad`, `== … ==` headers, `$ROOT` predefined).

## Global Constraints

- **Zero new dependencies** — bash + jq + coreutils + git only.
- **No regression / lossless** — verbs read-only, never mutate; search-collapse is a *verbatim-command wrap* (identical search semantics, full output spilled byte-exact, small results still inline). A missing key/blame/hist is an explicit non-success, never a silent wrong answer.
- **Match existing style** — `core/` scripts mirror `core/quiet-verify.sh` (shebang, doc header, arg guards usage→stderr+exit 2). Numeric validation via `case "$x" in ''|*[!0-9]*) … exit 2`.
- **#4 intentionally changes tested behavior** — `grep -r x .` / `rg foo` flip from pass-through to wrap (see Task 3). This is deliberate; update the two assertions, don't work around them.
- Spec: `docs/superpowers/specs/2026-06-28-deterministic-first-round2-design.md`.

---

### Task 1: `quiet-conf` verb

**Files:** Create `core/quiet-conf.sh`; Test: append to `tests/run.sh`.

**Interfaces:** `core/quiet-conf.sh <file> <key>` — JSON/YAML: `<key>` is a jq path (leading `.` optional) → prints the scalar; `.env`/other: `<key>` is a var name → prints the value (one layer of matching quotes stripped). Not found → stderr + exit 1. Missing args / unreadable / unparseable / bad jq path → exit 2.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` before the final summary/exit block:

```bash
echo "== quiet-conf =="
QCF="$ROOT/core/quiet-conf.sh"
JF=$(mktemp).json; printf '{"name":"x","scripts":{"test":"jest"},"dependencies":{"react":"18.2.0"}}' > "$JF"
[ "$("$QCF" "$JF" '.scripts.test')" = "jest" ] && pass "quiet-conf json jq-path" || bad "quiet-conf json jq-path"
[ "$("$QCF" "$JF" 'dependencies.react')" = "18.2.0" ] && pass "quiet-conf json bare-key (dot prepended)" || bad "quiet-conf json bare-key"
"$QCF" "$JF" '.nope' >/dev/null 2>&1; [ $? -eq 1 ] && pass "quiet-conf missing key exit 1" || bad "quiet-conf missing key"
EF=$(mktemp); printf 'FOO=bar\nexport TOKEN="abc123"\n' > "$EF"
[ "$("$QCF" "$EF" 'FOO')" = "bar" ] && pass "quiet-conf env plain" || bad "quiet-conf env plain"
[ "$("$QCF" "$EF" 'TOKEN')" = "abc123" ] && pass "quiet-conf env export+quotes" || bad "quiet-conf env quotes"
"$QCF" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-conf usage exit 2" || bad "quiet-conf usage"
"$QCF" /no/such x >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-conf missing-file exit 2" || bad "quiet-conf missing-file"
rm -f "$JF" "$EF"
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run.sh` → `quiet-conf` lines FAIL.

- [ ] **Step 3: Implement**

Create `core/quiet-conf.sh`:

```bash
#!/usr/bin/env bash
#
# quiet-conf — resolve ONE config value without reading the whole file.
#
#   quiet-conf.sh <file> <key>
#
# JSON/YAML: <key> is a jq path (leading '.' optional), e.g. '.scripts.test' or
# 'dependencies.react'. Other files (.env, *.conf, extensionless): <key> is a
# variable name; the value of the first `KEY=…` line is printed (one layer of
# matching quotes stripped). Prints the raw value; exit 1 if not found, 2 on usage.

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$ROOT/quiet-core.sh"

file="${1:-}"; key="${2:-}"
[ -n "$file" ] && [ -n "$key" ] || { echo "usage: quiet-conf.sh <file> <key>" >&2; exit 2; }
[ -r "$file" ] || { echo "quiet-conf: cannot read $file" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "quiet-conf: jq required" >&2; exit 2; }

case "$file" in
  *.json | *.yaml | *.yml)
    json=$(quiet_to_json "$file") || { echo "quiet-conf: cannot parse $file" >&2; exit 2; }
    case "$key" in .*) path="$key" ;; *) path=".$key" ;; esac
    val=$(printf '%s' "$json" | jq -r "($path) // empty" 2>/dev/null) \
      || { echo "quiet-conf: bad key path: $key" >&2; exit 2; }
    [ -n "$val" ] || { echo "quiet-conf: key not found: $key" >&2; exit 1; }
    printf '%s\n' "$val" ;;
  *)
    line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | head -1)
    [ -n "$line" ] || { echo "quiet-conf: key not found: $key" >&2; exit 1; }
    val=${line#*=}
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    printf '%s\n' "$val" ;;
esac
```

Then `chmod +x core/quiet-conf.sh`.

- [ ] **Step 4: Run to verify pass** — `bash tests/run.sh` → all `quiet-conf` lines `ok`, suite exit 0.

- [ ] **Step 5: Commit**

```bash
git add core/quiet-conf.sh tests/run.sh
git commit -m "feat: quiet-conf — resolve one config value without reading the file"
```

---

### Task 2: `quiet-hist` + `quiet-blame` verbs

**Files:** Create `core/quiet-hist.sh`, `core/quiet-blame.sh`; Test: append to `tests/run.sh`.

**Interfaces:**
- `core/quiet-hist.sh <path> [-n N]` → `%h %ad %s` of the last N (default 15) commits touching `<path>`; `--pick <string> [path]` → `git log --oneline -S`. No commits → `[quiet-hist] no commits …` + exit 0. Not a git repo / bad N / missing args → exit 2.
- `core/quiet-blame.sh <file> <start> <end>` → `git blame -L start,end --date=short`. Non-integer range / missing args / not a git repo → exit 2.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` before the final summary/exit block (tests run against THIS repo's git history — `README.md` is a long-lived tracked file):

```bash
echo "== quiet-hist / quiet-blame =="
QH="$ROOT/core/quiet-hist.sh"; QB="$ROOT/core/quiet-blame.sh"
out=$("$QH" README.md -n 3); st=$?
{ [ "$st" -eq 0 ] && [ -n "$out" ]; } && pass "quiet-hist lists commits" || bad "quiet-hist lists"
"$QH" --pick quiet_rewrite core/quiet-core.sh >/dev/null 2>&1; [ $? -eq 0 ] && pass "quiet-hist pickaxe runs" || bad "quiet-hist pickaxe"
"$QH" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-hist usage exit 2" || bad "quiet-hist usage"
"$QH" README.md -n abc >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-hist bad -n exit 2" || bad "quiet-hist bad -n"
out=$("$QB" README.md 1 3); st=$?
{ [ "$st" -eq 0 ] && [ -n "$out" ]; } && pass "quiet-blame shows range" || bad "quiet-blame range"
"$QB" README.md 1 >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-blame usage exit 2" || bad "quiet-blame usage"
"$QB" README.md a b >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-blame non-numeric exit 2" || bad "quiet-blame non-numeric"
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run.sh` → these lines FAIL.

- [ ] **Step 3: Implement `core/quiet-hist.sh`**

```bash
#!/usr/bin/env bash
#
# quiet-hist — recent commits touching a path, or pickaxe for a string,
# without scrolling a full `git log` dump.
#
#   quiet-hist.sh <path> [-n N]          # last N (default 15) commits for a path
#   quiet-hist.sh --pick <string> [path] # commits that added/removed <string>

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "quiet-hist: not a git repo" >&2; exit 2; }

if [ "${1:-}" = "--pick" ]; then
  str="${2:-}"; [ -n "$str" ] || { echo "usage: quiet-hist.sh --pick <string> [path]" >&2; exit 2; }
  if [ -n "${3:-}" ]; then git log --oneline -S "$str" -- "$3"; else git log --oneline -S "$str"; fi
  exit $?
fi

path="${1:-}"; [ -n "$path" ] || { echo "usage: quiet-hist.sh <path> [-n N]" >&2; exit 2; }
n=15
if [ "${2:-}" = "-n" ]; then
  n="${3:-15}"
  case "$n" in ''|*[!0-9]*) echo "quiet-hist: -n must be a positive integer" >&2; exit 2 ;; esac
fi
out=$(git log -n "$n" --date=short --format='%h %ad %s' -- "$path" 2>/dev/null)
[ -n "$out" ] || { echo "[quiet-hist] no commits touch $path"; exit 0; }
printf '%s\n' "$out"
```

Then `chmod +x core/quiet-hist.sh`.

- [ ] **Step 4: Implement `core/quiet-blame.sh`**

```bash
#!/usr/bin/env bash
#
# quiet-blame — who/when for a line range, without reading the whole file.
#
#   quiet-blame.sh <file> <start> <end>

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "quiet-blame: not a git repo" >&2; exit 2; }

file="${1:-}"; start="${2:-}"; end="${3:-}"
{ [ -n "$file" ] && [ -n "$start" ] && [ -n "$end" ]; } \
  || { echo "usage: quiet-blame.sh <file> <start> <end>" >&2; exit 2; }
case "$start" in ''|*[!0-9]*) echo "quiet-blame: start/end must be integers" >&2; exit 2 ;; esac
case "$end" in ''|*[!0-9]*) echo "quiet-blame: start/end must be integers" >&2; exit 2 ;; esac

git blame -L "$start,$end" --date=short -- "$file"
```

Then `chmod +x core/quiet-blame.sh`.

- [ ] **Step 5: Run to verify pass** — `bash tests/run.sh` → all `quiet-hist / quiet-blame` lines `ok`, suite exit 0.

- [ ] **Step 6: Commit**

```bash
git add core/quiet-hist.sh core/quiet-blame.sh tests/run.sh
git commit -m "feat: quiet-hist/quiet-blame — git archaeology without full-dump reads"
```

---

### Task 3: Recursive search-output collapse (#4)

**Files:** Modify `core/quiet-core.sh` (add a matcher to `quiet_rewrite`); Modify `tests/run.sh` (flip two assertions + add a section).

**Interfaces:** Consumes the existing `_quiet_wrap_search` heredoc in `core/quiet-core.sh`. After this task, `quiet_rewrite` returns 0 (wrap) for recursive `grep -r/-R`/`rg`, and still 1 (pass) for bounded/piped/non-recursive forms.

- [ ] **Step 1: Flip the two existing assertions + add the new test section**

In `tests/run.sh`:

(a) On the "should PASS THROUGH" line (currently `for c in "ls -la" "cat f.txt" "grep -r x ." "git status" …`), replace the token `"grep -r x ."` with `"grep x f.txt"` (non-recursive grep stays pass-through).

(b) On the gh-layer should-pass line (currently `… "find --help" "grep -r x ." "rg foo" \`), remove the tokens `"grep -r x ."` and `"rg foo"` (they move to wrap below).

(c) Add this new section before the final summary/exit block:

```bash
echo "== core: recursive-search collapse (grep -r / rg) =="
for c in "grep -r x ." "grep -R foo src" "grep -rn TODO ." "rg foo" "rg bar src" "rg -n foo"; do
  if quiet_rewrite "$c" >/dev/null; then pass "wrap: $c"; else bad "should wrap: $c"; fi
done
for c in "grep x f.txt" "grep -rl x ." "grep -c x ." "rg -l foo" "rg -c foo" "rg foo | head" \
         "grep -r x . > out" "grep -r x . | wc -l" 'd=$(rg foo)'; do
  if quiet_rewrite "$c" >/dev/null; then bad "should pass: $c"; else pass "pass: $c"; fi
done
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run.sh` → the new wrap assertions FAIL (recursive grep/rg not wrapped yet); the flipped pass-through lines should already be green.

- [ ] **Step 3: Add the matcher to `quiet_rewrite`**

In `core/quiet-core.sh`, find the recursive-listing path block (the one with `lsr_re`/`tree_re`/`find_re` that calls `_quiet_wrap_search`). Immediately AFTER that entire `if … fi` block, add:

```bash
  # ── recursive-search path: grep -r / rg can flood context; VERBATIM-wrap ──
  # The command runs exactly as written (no flag rewrite → no changed match
  # semantics); only a large RESULT is collapsed (spill + first-N + count +
  # grep pointer), small results still show inline. Lossless. Only recursive
  # searches (the flooding ones); bounded/piped/listing forms pass through.
  local grep_re='(^|[[:space:];&|(/])(grep|egrep|fgrep)[[:space:]]'
  local recflag_re='[[:space:]](-[A-Za-z]*[rR][A-Za-z]*|--recursive)([[:space:]]|$)'
  local rg_re='(^|[[:space:];&|(/])(rg|ripgrep)[[:space:]]'
  # Output-bounding flags (count/list/quiet) → already small, leave alone.
  local sbound_re='[[:space:]](-[A-Za-z]*[clLq][A-Za-z]*|--count|--files-with-matches|--files-without-match|--quiet)([[:space:]]|$)'
  if [[ $cmd != *'|'* && $cmd != *'>'* && $cmd != *'$('* && $cmd != *'`'* && $cmd != *-exec* ]] \
     && { { [[ $cmd =~ $grep_re ]] && [[ $cmd =~ $recflag_re ]]; } || [[ $cmd =~ $rg_re ]]; } \
     && ! [[ $cmd =~ $sbound_re ]]; then
    _quiet_wrap_search "$cmd"
    return 0
  fi
```

- [ ] **Step 4: Run to verify pass** — `bash tests/run.sh` → all `recursive-search collapse` lines `ok`, and the existing "should PASS THROUGH" / gh-layer sections still green; suite exit 0.

- [ ] **Step 5: Commit**

```bash
git add core/quiet-core.sh tests/run.sh
git commit -m "feat: collapse recursive grep/rg output (verbatim-wrap, lossless)"
```

---

### Task 4: Skill + README surface

**Files:** Modify `skills/deterministic-first/SKILL.md`, `README.md`; Test: a structural assertion in `tests/run.sh`.

**Interfaces:** Consumes the verbs from Tasks 1–2.

- [ ] **Step 1: Write the failing structural test**

Append to `tests/run.sh` before the final summary/exit block:

```bash
echo "== round-2 skill rows =="
SKR="$ROOT/skills/deterministic-first/SKILL.md"
for tok in 'quiet-conf' 'quiet-hist' 'tsort'; do
  grep -qF "$tok" "$SKR" 2>/dev/null && pass "skill mentions $tok" || bad "skill missing $tok"
done
grep -q 'Repeated & blocking work' "$ROOT/README.md" 2>/dev/null && pass "README round-1 row intact" || bad "README row"
```

- [ ] **Step 2: Run to verify it fails** — the `quiet-conf`/`quiet-hist`/`tsort` skill lines FAIL.

- [ ] **Step 3: Add skill cheatsheet rows**

In `skills/deterministic-first/SKILL.md`, in the pattern table under `## The decision rule`, add these rows after the existing **Parse** row:

```markdown
| **Config value** — one field from a config/lockfile | read the whole file to find it | `quiet-conf FILE KEY` (jq path for json/yaml, var name for .env) |
| **Code archaeology** — who/when/which-commit | scroll full `git log`/`blame`, read files | `quiet-hist PATH` · `quiet-hist --pick STR` · `quiet-blame FILE S E` |
| **Math / dates / ordering** — compute in-head | sum/percent/date-diff/order by reasoning | `awk`/`bc` · `date -d` · `tsort` (topological order) |
```

- [ ] **Step 4: Add the README row**

In `README.md`, find the row beginning `| **Repeated & blocking work**` (added in round 1). Directly beneath it, add:

```markdown
| **Lookups & archaeology** — config values, git history, recursive search | model reads whole files / scrolls full logs / floods on `grep -r` | `quiet-conf` · `quiet-hist`/`quiet-blame` · recursive `grep`/`rg` auto-collapsed |
```

- [ ] **Step 5: Run to verify pass** — `bash tests/run.sh` → all `round-2 skill rows` lines `ok`; the existing structural test (headings, `quiet-verify`/`quiet-agg`) still green; suite exit 0.

- [ ] **Step 6: Commit**

```bash
git add skills/deterministic-first/SKILL.md README.md tests/run.sh
git commit -m "docs: surface quiet-conf/hist/blame + search-collapse + math rows"
```

---

## Notes for the implementer

- **Order:** 1 → 2 → 3 → 4. Each appends its own test section; don't disturb earlier sections or the final `[ "$fail" -eq 0 ]` accounting.
- **Task 3 is a deliberate behavior change** — flip exactly the two assertions named; do not weaken the new wrap assertions to pass.
- **Git verbs (Task 2)** are tested against this repo's real history (`README.md`, `core/quiet-core.sh`) — stable fixtures; they run inside the worktree where git history is available.
- **Do not** weaken any arg/regex guard to make a test pass (exit 2 on bad input is required).
