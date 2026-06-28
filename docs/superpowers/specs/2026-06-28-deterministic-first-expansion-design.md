# Deterministic-first expansion — design spec

**Status:** design spec
**Date:** 2026-06-28
**Source research:** `docs/superpowers/research/2026-06-28-deterministic-first-expansion-candidates.md`

Three new levers that each shift an AI action onto deterministic tooling, all
within quiet-bash's invariant (**mechanical, lossless-or-byte-exact, no extra LLM
call, no regression, zero-dependency**):

- **A. Duplicate-read dedup** — stop re-billing a re-Read of an unchanged file.
- **B. `quiet-check`** — a build/test/lint *verdict + tally* verb.
- **C. `quiet-wait`** — collapse status-polling into one blocking call.

B and C follow the proven verb pattern (siblings of `quiet-verify`/`quiet-agg`);
A extends the existing PostToolUse `Read` hook and is the highest-value / highest-
care piece.

---

## A. Duplicate-read dedup

### Problem
A stateless agent re-sends the whole transcript every turn. When it re-`Read`s a
file it already read this session and the file is unchanged, the bytes are
re-billed even though they're already verbatim earlier in context. Large
non-source reads (logs, data, fixtures) currently **pass through in full** on
every re-read (`adapters/claude-code-result.sh`, the `Read` branch).

### Mechanism (PostToolUse, tail-edit only)
Extend the existing `Read` branch in `adapters/claude-code-result.sh` with a
dedup check, backed by a session-scoped state file.

- **State:** one file per session at
  `${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}dedup-<session_id>` — newline-delimited
  records `key \t mtime \t size`, where `key = sha/quoting of path|offset|limit`.
- **On a Read result** for path `P`, range `(offset,limit)`:
  1. If `session_id` is absent → **do nothing** (can't prove "above" is in *this*
     session; pass through).
  2. If the read was collapsed/outlined this turn (source-file outline path
     already taken, or content not emitted in full) → record nothing extra, pass
     through. The stub must never point at a stub.
  3. Compute current `mtime`,`size` of `P`. Look up `key`.
     - **Hit + mtime&size unchanged** → replace body with the stub (below). Do not
       rewrite the stored record.
     - **Miss, or mtime/size changed** → pass the real content through and
       upsert the record with current `mtime`,`size`.
- **Stub text:**
  `[quiet-bash] <P> is unchanged since you read it earlier this session — its full contents are already above. (To force a fresh read: touch the file, or read a different line range.)`
- **Cache safety:** only the just-emitted result is rewritten (tail edit) — never
  a retroactive edit to an earlier turn, so the prompt-cache prefix is untouched.
- **Pruning:** dedup state files are pruned by the existing `quiet_prune` age
  sweep (same prefix).

### No-regression floor
- Session-scoped only (no `session_id` → disabled).
- mtime **or** size change → always real content.
- Different byte-range → different key → real content.
- Never dedup a read whose prior emission was itself collapsed/outlined.
- The content is verbatim above by construction, so the model loses nothing it
  doesn't already have.

### Interfaces
- Helper extracted into core so it's testable without the hook:
  `quiet_dedup_check <session_id> <path> <offset> <limit>` →
  prints the stub and returns 0 when it should dedup; returns 1 (no output) to
  pass through; updates the state file as a side effect. Lives in a new
  `core/quiet-dedup.sh`, sourced by `quiet-core.sh` (or by the adapter).
- The adapter calls it in the `Read` branch *before* the existing outline logic
  only for non-collapsed reads; on a dedup hit it emits the stub via the existing
  string/`content[]` shape mirror.

### Why this over retroactive masking
Retroactive masking of *old* results is higher headline value (~50%) but busts
the prompt cache and needs `clear_at_least`-style gating — deferred. This tail-
edit slice captures the unchanged-re-read case cache-safely.

---

## B. `quiet-check` — build/test/lint verdict + tally

### Problem
After running a build/test/lint, the agent reads the log tail to judge pass/fail,
count errors/warnings, and find the first failures — model work over text whose
verdict is deterministic (exit code) and whose counts are a `grep -c`.

### Mechanism
`core/quiet-check.sh <logfile>` (operates on a file — typically a quiet-bash
spill, so it composes with the existing `[ok: … hidden in <log>]` flow):

- Prints a one-line verdict + tallies:
  `[quiet-check] <PASS|FAIL> — <E> error(s), <W> warning(s) in <logfile>`
  where `E` = lines matching the error regex, `W` = the warning regex.
- Then, if `E>0`, the **first K (default 5)** error lines (deterministic head of
  the matches) so the agent sees the actual failures without reading the log.
- Exit code: 0 when `E==0`, 1 when `E>0` (so it doubles as a shell gate).
- Error/warning regexes default to a broad, multi-ecosystem ERE
  (`error|ERROR|FAIL(ED|URE)?|Exception|✗`, `warn(ing)?|WARN`), overridable via
  `QUIET_CHECK_ERROR_RE` / `QUIET_CHECK_WARN_RE`.
- Usage to stderr + exit 2 on missing/unreadable file.

### Overlap note (deliberate scope)
The command-wrap already surfaces the *exit code* verdict. `quiet-check`'s
net-new value is the **deterministic error/warning tally + first-K extraction**
over a spilled log, in one verb — so the agent never reads the tail to count or
quote failures. It does **not** run commands (no overlap with the wrap's
execution); it reads a file. Skill cheatsheet "verify" row gains a "tally/triage
a log" entry.

---

## C. `quiet-wait` — collapse polling into one call

### Problem
The agent waits for a condition (a file to appear, a service to be healthy, a job
to finish) by re-issuing a status check across many turns — each a full
round-trip billed against context. The `deterministic-first` skill already names
the `until`-loop pattern but ships no verb.

### Mechanism
`core/quiet-wait.sh <shell-condition> [--timeout SECS] [--interval SECS]`:

- Loops the condition (evaluated via `sh -c`) until it succeeds or the timeout
  (default 60s) elapses; sleeps `interval` (default 2s) between tries.
- Prints only the **terminal** state, once:
  `[quiet-wait] condition met after <n> tries / <secs>s` (exit 0), or
  `[quiet-wait] TIMEOUT after <secs>s (<n> tries) — condition never met` (exit 1).
- Usage to stderr + exit 2 on missing condition or non-numeric timeout/interval
  (reuses the numeric-validation shape added to `quiet-agg`).
- Hard-caps total tries and timeout to bounded values so it can't hang a hook-
  driven session.

### No-regression floor
The condition is the agent's own shell expression run verbatim — no
interpretation. Timeout-guarded so a never-true condition fails cleanly rather
than blocking forever.

---

## Cross-cutting

- **Surface:** one README "What it covers" sub-bullet/row update (proactive
  lever group), and `deterministic-first` SKILL.md cheatsheet additions: a
  "don't re-Read unchanged files" note (A), a "tally/triage a log" verify entry
  (B), and pointing the existing "wait" row at `quiet-wait` (C).
- **Tests** (`tests/run.sh`, existing `pass`/`bad` style): per-feature units +
  the dedup state-file behavior (hit/miss/changed-mtime/changed-range/no-session/
  collapsed-prior) + a composition test for B over a real spill.
- **Tasks are independent** — B and C are isolated verbs; A is isolated to the
  Read adapter path + a new core helper. They can ship in any order; the plan
  sequences B, C (fast, low-risk) then A (the careful one).

---

## Open questions (resolve in plan)
- A: confirm Claude Code PostToolUse payload exposes `session_id` (assumed yes);
  if not present at runtime, A degrades to disabled (safe).
- A: dedup only non-source large reads in v1 (source files are already outlined
  to small), or all full-content reads? Lean: any read that was about to pass
  through in full — i.e., gate on "not collapsed/outlined this turn".
- B: default K (first-N errors) — lean 5, env-overridable.
