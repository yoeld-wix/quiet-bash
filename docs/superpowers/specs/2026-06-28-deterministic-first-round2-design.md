# Deterministic-first round 2 — design spec

**Status:** design spec
**Date:** 2026-06-28
**Research:** `docs/superpowers/research/2026-06-28-deterministic-first-round2-candidates.md`
**Approved tranche:** N4 `quiet-conf`, #4 search-output collapse, N3 `quiet-hist`/`quiet-blame`, #8 math/date/`tsort` doc rows. Stacks on PR #6.

All within the invariant: **mechanical, lossless-or-byte-exact, no extra LLM call,
no regression, zero-dependency** (bash + jq + coreutils + git).

---

## 1. `quiet-conf` — resolve one config value without reading the file

### Problem
To get the test script, a dependency version, or one env var, the agent `Read`s a
whole `package.json` / lockfile / `.env` (often hundreds–thousands of lines).

### Mechanism
`core/quiet-conf.sh <file> <key>` prints just the resolved scalar (raw, like
`quiet-query` prints raw values — so it's capturable). Dispatch by extension:
- `*.json` → `jq -r "<jqpath>"`. The key is a jq path; if it doesn't start with
  `.`, prepend `.` (so `scripts.test` and `.scripts.test` both work).
- `*.yaml`/`*.yml` → `quiet_to_json` (existing core converter) then `jq -r`.
- everything else (`.env`, `*.properties`, `*.conf`, extensionless) → treat key
  as a var name: first matching `^[[:space:]]*(export[[:space:]]+)?KEY=` line,
  print the value with surrounding single/double quotes stripped.
- **Not found / null** → `quiet-conf: key not found: <key>` to stderr, exit 1.
- Missing args / unreadable file / (YAML with no converter) → stderr + exit 2.

Distinct from `quiet-query` (which interrogates a spilled JSON result); this
targets config files the model would otherwise read in full.

### No-regression floor
Read-only; never writes. A missing key is an explicit exit-1, never a silent
empty success. jq is exact.

---

## 2. Search-output collapse (grep/rg) — #4

### Problem
A recursive `grep -r` / `rg` can dump thousands of match lines into context. Today
`quiet_rewrite` deliberately passes grep/rg through, because a *flag rewrite*
(e.g. forcing `rg`) could change match semantics → a missed match is a regression.

### Mechanism (verbatim-command wrap — not a rewrite)
Extend `quiet_rewrite` in `core/quiet-core.sh` to wrap **recursive** searches with
the existing `_quiet_wrap_search` heredoc (the same spill + first-N + count +
grep-pointer used for `find`/`ls -R`/`tree`). The command runs **exactly as
written** — nothing about the search changes; only a large *result* is collapsed,
and the full output is spilled byte-exact (lossless; small results still show
inline, since `_quiet_wrap_search` prints inline at ≤ `QUIET_INLINE_LINE_LIMIT`).

Match: `grep`/`egrep`/`fgrep` **with** a recursive flag (`-r`/`-R`/`--recursive`),
or `rg`/`ripgrep` (recursive by default). **Guards (pass through, do NOT wrap):**
- piped / redirected / command-substitution / backtick / `-exec` (same guards as
  the listing path — wrapping these would corrupt or mis-window output);
- count/list/quiet flags that already bound output: `-c`/`--count`, `-l`/`-L`/
  `--files-with-matches`/`--files-without-match`, `-q`/`--quiet`;
- already piped to `head`/`tail`/`wc`.

### Deliberate behavior change (pre-flight conflict — resolved)
`tests/run.sh` currently asserts `grep -r x .` and `rg foo` **pass through**. This
spec intentionally flips them to **wrap** (lossless verbatim-wrap). The plan
updates those two assertions and adds a non-recursive `grep x file` to the
pass-through list (non-recursive grep is bounded by its file and stays
pass-through). This is an intentional, documented change, not a regression.

### No-regression floor
Verbatim-wrap = identical search semantics; full output on disk; only recursive
searches (the context-flooding ones) are touched; every output-bounding form
passes through unchanged.

---

## 3. `quiet-hist` / `quiet-blame` — git archaeology — N3

### Problem
"Which commit last touched X / who changed these lines / when was this string
introduced" → the agent scrolls full `git log`/`git blame` dumps and reads files.

### Mechanism (read-only git plumbing)
- `core/quiet-hist.sh <path> [-n N]` → `git log --oneline --date=short -n <N:-15> -- <path>`
  (recent commits touching a path). Plus a pickaxe mode:
  `core/quiet-hist.sh --pick <string> [path]` → `git log --oneline -S "<string>" -- [path]`
  (commits that added/removed the string — the lever models rarely reach for).
- `core/quiet-blame.sh <file> <start> <end>` → `git blame -L <start>,<end> --date=short <file>`
  (who/when for a line range — exact, no file read).
- Not in a git repo / bad range / missing args → stderr + exit 2. No matches →
  print a clear "no commits" line + exit 0 (`hist`) — empty is a valid answer.

### No-regression floor
Read-only; git output is ground truth. `quiet-blame` line range validated numeric
(reuse the `case … *[!0-9]*` guard).

---

## 4. Math / date / `tsort` skill rows — #8

Doc-only: add `deterministic-first` SKILL.md cheatsheet rows so the agent routes
in-head arithmetic and ordering to tools (all confirmed present, zero-dep):
- **Math / aggregation** → `awk`/`bc` (sums, %, p95) instead of mental math.
- **Date arithmetic** → `date -d`/`date -v` / epoch diff instead of in-head.
- **Topological / dependency ordering** → `tsort` instead of reasoning out an order.

No code, no regression risk.

---

## Cross-cutting

- **Surface:** README "what it covers" addition (grep/rg now collapsed; the new
  verbs), and SKILL.md cheatsheet rows: a "config value" lookup (N4), a
  "code archaeology" row (N3), and the #8 math/date/tsort rows. Keep the existing
  required headings + `quiet-verify`/`quiet-agg` references intact (structural
  test).
- **Tests** (`tests/run.sh`): units for `quiet-conf` (json/yaml/env/missing-key),
  `quiet-hist`/`quiet-blame` (run against THIS repo's git history for a stable
  fixture — e.g. history of a long-lived file; guard for git presence), and the
  search-collapse matcher (recursive grep/rg → wrap; bounded forms → pass; the
  two flipped assertions). A composition note for #8 is unnecessary (doc-only).
- **Branch:** stacks on the current expansion branch (PR #6) — shared files
  (`tests/run.sh`, SKILL.md, README) are edited by both, so a separate branch off
  main would conflict.
- **Tasks independent enough** to sequence: quiet-conf; the two git verbs;
  search-collapse (the behavior-change one, isolated to the core matcher + its
  tests); then docs/surface.

## Open questions (resolved)
- `quiet-conf` env value quote-stripping: strip one layer of matching `'`/`"`.
- `quiet-hist` default N: 15.
- search-collapse scope: recursive grep / rg only (non-recursive grep stays
  pass-through) — minimizes behavior change.
