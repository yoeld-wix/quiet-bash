# `qr.sh` Runtime Dispatcher — Design Spec

**Status:** Approved design, pending implementation plan
**Date:** 2026-07-05

## Problem

`quiet_rewrite` (in `core/quiet-core.sh`) is the single function every adapter
(Claude Code, Codex, Copilot, Gemini, the universal shell-wrapper) calls to
decide whether a command is "known-verbose" and, if so, get back a replacement
command to run instead. For 5 command shapes — generic (`npm install`, `make`,
`pytest`, ...), git (`diff`/`show`/`log`), `gh` content (`gh run view --log`,
`gh pr diff`), recursive listings/search (`ls -R`, `find`, `grep -r`), and
`curl` — that replacement is currently a **full inline heredoc**: a
`__log=$(mktemp ...)` line, a `{ <cmd> } >"$__log" 2>&1` redirect block, an
`if`/`elif`/`else` that decides what summary to print, and an `exit $__st`.

On Claude Code (and any adapter using `hookSpecificOutput.updatedInput.command`
/ equivalent), that returned string **is** "the command" as far as the tool-call
UI is concerned — it's what gets shown wherever the actual command-to-run is
displayed. A 10-12 line generated shell blob in place of `npm install` is
noisy and unreadable there, independent of anything the agent sees in its own
context (the eventual printed summary is already compact — this is purely
about the *pre-execution* display of the command itself).

## Goal

Move the wrap logic for all 5 command shapes out of the heredoc-generated
inline text and into a single new script, `core/qr.sh`, that the returned
command merely *calls*. `quiet_rewrite` then returns one line:

```
"$QUIET_CORE_DIR/qr.sh" <mode> <escaped-cmd> [<escaped-arg2>]
```

instead of the multi-line blob. Runtime behavior (log spill, printed summary,
tail-on-failure, exit code passthrough) stays byte-identical — this is a
display/structure change, not a behavior change.

Bundled in (same underlying edit surface, agreed separately): the "grep/tail
it"-style hint text in these summaries is inconsistent across the 5 wrap
paths (`"grep/tail it only if you need details"`, `"grep that file for the
rest"`, `"grep/sed that file for specific files or hunks"`, `"— grep it"`).
Each becomes a consistent pointer to the tool that actually helps: `quiet-
tail.sh <log> <n>` to read more of the tail, `quiet-agg.sh <log> '<re>'` to
tally/rank a pattern, or a literal `grep -n '<pattern>' <log>` to locate a
line (mirroring the existing JSON/curl footer, which already does this
correctly — see `_quiet_wrap_curl`'s JSON branch and
`quiet_result_summarize`, both untouched by this change).

## `core/qr.sh` — modes

```
qr.sh generic <cmd>              # npm install, cargo build, pytest, make, go test, ...
qr.sh git     <cmd> <summary>    # git diff/show/log; summary = same cmd + --stat/--oneline
qr.sh content <cmd>              # gh run view --log[-failed], gh pr diff
qr.sh search  <cmd>              # ls -R, tree, find <path>, grep -r/rg
qr.sh curl    <cmd>              # curl <url>
```

Each mode reproduces exactly the logic currently in `_quiet_wrap_generic`,
`_quiet_wrap_git`, `_quiet_wrap_content`, `_quiet_wrap_search`, and
`_quiet_wrap_curl` respectively (mktemp, redirect, threshold checks, printed
summary, tail/head calls) — but as code that runs immediately inside `qr.sh`,
sourcing `quiet-core.sh` for shared config/helpers, rather than text
templated into a heredoc for later execution. `<cmd>` (and `<summary>` for
git) runs via `bash -c "<cmd>"`, which is behaviorally equivalent to the
current inline `{ <cmd>; } >"$log" 2>&1` — same stdout/stderr/exit code from
the caller's perspective.

### Escaping

`quiet_rewrite` builds the call with `printf '%q'` to turn the original
command string into a single shell-safe argument:

```sh
printf '%s generic %s' "$QUIET_CORE_DIR/qr.sh" "$(printf '%q' "$cmd")"
```

`%q` round-trips any quotes/spaces/special characters in `$cmd` losslessly,
so `qr.sh` receives the exact original command string as `$1` regardless of
its contents.

### Example

```
Before (returned by quiet_rewrite today):
__log=$(mktemp "/tmp/claude-cmd-XXXXXX")
{
npm install
} >"$__log" 2>&1
__st=$?
__ln=$(wc -l <"$__log" | tr -d ' ')
if [ "$__st" -eq 0 ]; then
  echo "[ok: exit 0 — $__ln lines hidden in $__log; grep/tail it only if you need details]"
else
  echo "[FAILED: exit $__st — $__ln lines in $__log | last 40 below; grep that file for the rest]"
  ".../quiet-tail.sh" "$__log" 40 2>/dev/null || tail -n 40 "$__log"
fi
exit $__st

After:
"$QUIET_CORE_DIR/qr.sh" generic npm\ install
```

Printed summary on success (new wording):
```
[ok: exit 0 — 612 lines hidden in /tmp/claude-cmd-x; more: quiet-tail.sh /tmp/claude-cmd-x <n> | tally: quiet-agg.sh /tmp/claude-cmd-x '<re>']
```

### Exact wording per mode

| Mode | Case | Before | After |
|---|---|---|---|
| generic | success | `grep/tail it only if you need details` | `more: quiet-tail.sh <log> <n> \| tally: quiet-agg.sh <log> '<re>'` |
| generic | failure | `grep that file for the rest` | `more: quiet-tail.sh <log> <n> \| tally: quiet-agg.sh <log> '<re>'` |
| git | large output | `grep/sed that file for specific files or hunks` | `locate: grep -n '<pattern>' <log> \| tally: quiet-agg.sh <log> '<pattern>'` |
| git | failure | *(no hint today — tail already printed below)* | unchanged |
| content | large output | `grep that file for the rest` (+ ellipsis line `— grep it`) | `more: quiet-tail.sh <log> <n> \| locate: grep -n '<pattern>' <log>` (ellipsis line drops its own trailing hint) |
| search | large output | `grep/sed that file for the rest` | `locate: grep -n '<pattern>' <log> \| tally: quiet-agg.sh <log> '<pattern>'` |
| curl | non-JSON large | `grep that file for the rest` | `more: quiet-tail.sh <log> <n> \| locate: grep -n '<pattern>' <log>` |
| curl | JSON large | *(already good — `query: quiet-query.sh <log>.json keys`)* | unchanged |

## Cache-safety

`tests/run.sh` already has a dedicated test (`"cache-safety: rendered output
is deterministic"`) asserting `quiet_rewrite "$c"` returns byte-identical
text across repeated calls for the same input — required so the rewrite never
busts Claude's prompt-cache prefix. The new form preserves this: `qr.sh
<mode> <escaped-cmd>` is a pure function of `$cmd` (and `$QUIET_CORE_DIR`,
fixed per install) — no mktemp path, timestamp, or other runtime value is
embedded in the *returned* string (mktemp still only happens later, inside
`qr.sh`, exactly as today). The new form is also shorter than the heredoc it
replaces, so slightly fewer tokens land in the cached prefix per wrapped call.

## Non-goals

- No change to any of the detection regexes in `quiet_rewrite` that decide
  *whether* a command gets wrapped — only what gets returned once it does.
- No change to `quiet_run` (the shell-wrapper's runtime executor for the
  universal/non-Claude-Code path) or to `_quiet_wrap_curl`'s JSON branch /
  `quiet_result_summarize` — both already point to named tools correctly.
- No shell-function/`BASH_ENV` based shorthand — rejected: each Bash tool
  call is a fresh subprocess with no persisted state, the PreToolUse hook and
  the command-execution process are separate processes, and adapters other
  than Claude Code don't guarantee a shell that would source it consistently.
  A plain, portable script call is the only option that works uniformly
  across all adapters.

## Testing strategy

`tests/run.sh` has ~15 assertions against `quiet_rewrite`'s *returned string*
(e.g. `quiet_rewrite "cat $big" | grep -q 'quiet-json.sh'`). These need
updating for the new one-line shape:

1. **Shape** — for each of the 5 modes, `quiet_rewrite "<sample cmd>"`
   contains `qr.sh <mode>` and does **not** contain `mktemp`/`__log` (proves
   the heredoc is gone).
2. **Round-trip correctness** — for commands containing quotes/spaces/special
   characters, decode the `%q`-escaped argument and confirm it equals the
   original `$cmd` byte-for-byte.
3. **Execution parity, per mode** — actually run the returned command (as the
   adapter would) against a synthetic success case and a synthetic failure
   case, and assert the printed summary matches the new wording and the exit
   code is passed through. (Existing tests already do this style of
   end-to-end run for some paths — e.g. the JSON/spill recovery tests —
   extend the same pattern to all 5 modes.)
4. **Cache-safety test** (`tests/run.sh:590-604`) — must still pass unchanged;
   extend its command list to cover all 5 modes if it doesn't already.
5. **Existing wrap/pass-through regex tests** — unaffected (they test
   *whether* `quiet_rewrite` returns non-empty, not its shape) but must still
   pass.

## Files touched

- `core/qr.sh` (new) — the 5-mode runtime dispatcher.
- `core/quiet-core.sh` (modified) — `quiet_rewrite`'s 5 call sites change from
  `_quiet_wrap_generic "$cmd"` (etc.) to building the `qr.sh` call string;
  the `_quiet_wrap_*` functions are removed (logic moved to `qr.sh`).
- `tests/run.sh` (modified) — update the ~15 shape assertions, add the new
  tests above.
- `README.md` — update the "How it works" section's description and any
  example output to reflect the one-line dispatcher call.
- `CHANGELOG.md` — document the change.

## Out of scope (follow-ons)

- Applying the same dispatcher pattern to `adapters/*-result.sh` (PostToolUse
  result-summarization paths) — those don't emit a *replacement command* at
  all (they replace a tool *result*), so the "messy displayed command"
  problem doesn't apply there.
