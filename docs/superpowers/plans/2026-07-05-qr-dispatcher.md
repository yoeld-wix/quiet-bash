# `qr.sh` Runtime Dispatcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `quiet_rewrite`'s inline heredoc rewrites (mktemp/redirect/if-else generated as text) with a one-line call to a new `core/qr.sh` dispatcher, so the command an adapter's UI shows as "about to run" is short and readable instead of a multi-line generated script. Bundle in a consistent `quiet-tail.sh`/`quiet-agg.sh` wording fix for the "grep/tail it"-style hints, replacing 5 inconsistent phrasings.

**Architecture:** `core/qr.sh` is a new standalone script (sourcing `quiet-core.sh` for shared config, same pattern as `quiet-json.sh`/`quiet-outline.sh`) with 5 modes (`generic`, `git`, `content`, `search`, `curl`) — one per current `_quiet_wrap_*` function. `quiet_rewrite`'s 7 call sites build a `printf '%q'`-escaped call to `qr.sh` instead of invoking `_quiet_wrap_*`. The 5 `_quiet_wrap_*` function definitions are deleted once nothing calls them.

**Tech Stack:** Bash, `jq` (already a hard dependency), `shellcheck` (CI gate at `-S error`).

## Global Constraints

- No new external dependencies (only `bash`/`jq`, already required repo-wide).
- `core/qr.sh` must pass `shellcheck -S error` (CI: `.github/workflows/ci.yml` runs `shellcheck -S error core/*.sh adapters/*.sh tests/*.sh install.sh`, which globs the new file automatically).
- `quiet_rewrite` must keep returning **byte-identical output for identical input** (the existing cache-safety test at `tests/run.sh` — search `"cache-safety: rendered output is deterministic"` — must keep passing). Never embed a runtime-varying value (timestamp, random path) into the *returned rewrite string* — only inside what the script does when it later runs.
- Do not change any detection regex in `quiet_rewrite` (what decides *whether* to wrap) — only what gets returned once it decides to.
- The new script is named `qr.sh` (not `quiet-run.sh`) — a deliberate, approved exception to the `quiet-*.sh` naming convention used by every other file in `core/`, chosen for a shorter displayed command.
- Every wording change must match the table in `docs/superpowers/specs/2026-07-05-qr-dispatcher-design.md` exactly.

---

### Task 1: Create `core/qr.sh` with `generic` mode; wire the generic call site; fix `quiet_run` wording

**Files:**
- Create: `core/qr.sh`
- Modify: `core/quiet-core.sh` (the `verbose-runner path` block near the end of `quiet_rewrite`; the two `echo` lines inside `quiet_run`)
- Test: `tests/run.sh` (new section appended near the end, before the final summary block)

**Interfaces:**
- Produces: `core/qr.sh <mode> <cmd> [<summary-cmd>]` — a CLI entry point. `generic` mode: `qr.sh generic <cmd>` — runs `<cmd>` via `bash -c`, spills output to a `mktemp` log, prints `[ok: ...]`/`[FAILED: ...]`, exits with `<cmd>`'s exit code. Later tasks add `git`/`content`/`search`/`curl` modes to this same file, and a final `*)` fallback (added in this task) stays last.

- [ ] **Step 1: Write the failing tests**

Open `tests/run.sh` and find this exact block near the end of the file (the very last lines):

```bash
echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
```

Replace it with (this inserts a new test section immediately before the existing final summary, which is unchanged at the bottom):

```bash
echo "== qr.sh: generic mode =="
QR="$ROOT/core/qr.sh"
r=$(quiet_rewrite "npm install")
printf '%s' "$r" | grep -qF 'qr.sh generic' && pass "generic: quiet_rewrite routes to qr.sh generic" || bad "generic: quiet_rewrite routes to qr.sh generic"
printf '%s' "$r" | grep -qF 'mktemp' && bad "generic: rewrite still inlines mktemp" || pass "generic: rewrite has no inline mktemp"

out=$("$QR" generic 'for i in $(seq 1 5); do echo "line $i"; done')
{ printf '%s' "$out" | grep -qF '[ok: exit 0 — 5 lines hidden in ' \
  && printf '%s' "$out" | grep -qF 'more: ' \
  && printf '%s' "$out" | grep -qF 'quiet-tail.sh' \
  && printf '%s' "$out" | grep -qF "tally: quiet-agg.sh"; } \
  && pass "generic: success message uses new wording" || bad "generic: success message uses new wording"

out=$("$QR" generic '(echo "line 1"; echo "ERROR: boom"; exit 3)')
{ printf '%s' "$out" | head -1 | grep -qF '[FAILED: exit 3 —' \
  && printf '%s' "$out" | grep -qF 'more: ' \
  && printf '%s' "$out" | grep -qF 'quiet-tail.sh'; } \
  && pass "generic: FAILED message uses new wording" || bad "generic: FAILED message uses new wording"
printf '%s' "$out" | grep -qF 'ERROR: boom' && pass "generic: failure tail includes the error" || bad "generic: failure tail includes the error"
"$QR" generic '(exit 3)' >/dev/null; [ $? -eq 3 ] && pass "generic: exit code passthrough" || bad "generic: exit code passthrough"

GTD=$(mktemp -d)
( cd "$GTD" \
  && weird='make ; printf "%s\n" "it'"'"'s here"' \
  && rw=$(quiet_rewrite "$weird") \
  && out=$(bash -c "$rw" 2>&1) \
  && logpath=$(printf '%s' "$out" | grep -oE "${QUIET_LOG_DIR%/}/+${QUIET_LOG_PREFIX}[A-Za-z0-9]+" | head -1) \
  && [ -n "$logpath" ] && grep -qF "it's here" "$logpath" ) \
  && pass "generic: %q escaping round-trips quotes through qr.sh" || bad "generic: %q escaping round-trips quotes through qr.sh"
rm -rf "$GTD"

qrun_out=$(quiet_run printf 'a\nb\n')
{ printf '%s' "$qrun_out" | grep -qF 'more: ' && printf '%s' "$qrun_out" | grep -qF 'quiet-tail.sh'; } \
  && pass "quiet_run: success message uses new wording" || bad "quiet_run: success message uses new wording"
qrun_fail=$(quiet_run sh -c 'echo x; exit 2' 2>/dev/null)
{ printf '%s' "$qrun_fail" | grep -qF 'more: ' && printf '%s' "$qrun_fail" | grep -qF 'quiet-tail.sh'; } \
  && pass "quiet_run: FAILED message uses new wording" || bad "quiet_run: FAILED message uses new wording"

echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
```

- [ ] **Step 2: Run the suite to verify these new assertions fail**

Run: `bash tests/run.sh 2>&1 | tail -20`
Expected: the run reaches `== qr.sh: generic mode ==` and every assertion in it prints `FAIL` (there is no `core/qr.sh` yet, and `quiet_run`'s wording hasn't changed yet), ending in `TESTS FAILED`.

- [ ] **Step 3: Create `core/qr.sh`**

```bash
#!/usr/bin/env bash
#
# qr — quiet-bash's runtime dispatcher for known-verbose command rewrites.
#
#   qr.sh generic <cmd>
#   qr.sh git     <cmd> <summary-cmd>
#   qr.sh content <cmd>
#   qr.sh search  <cmd>
#   qr.sh curl    <cmd>
#
# quiet_rewrite (quiet-core.sh) used to return the mktemp/redirect/summarize
# logic below as inline heredoc text — the full generated script became "the
# command" wherever an adapter's UI shows the command about to run. Now it
# returns a one-line call to this script instead, so what's shown is short
# and readable; the actual spill/summary/tail behavior is unchanged.

QRDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$QRDIR/quiet-core.sh"

mode="${1:?usage: qr.sh <generic|git|content|search|curl> <cmd> [summary-cmd]}"
cmd="${2:?usage: qr.sh <generic|git|content|search|curl> <cmd> [summary-cmd]}"

case "$mode" in
generic)
  log=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
  bash -c "$cmd" >"$log" 2>&1
  st=$?
  ln=$(wc -l <"$log" | tr -d ' ')
  if [ "$st" -eq 0 ]; then
    echo "[ok: exit 0 — ${ln} lines hidden in ${log}; more: ${QUIET_CORE_DIR}/quiet-tail.sh ${log} <n> | tally: quiet-agg.sh ${log} '<re>']"
  else
    echo "[FAILED: exit ${st} — ${ln} lines in ${log} | last ${QUIET_FAIL_TAIL_LINES} below; more: ${QUIET_CORE_DIR}/quiet-tail.sh ${log} <n> | tally: quiet-agg.sh ${log} '<re>']"
    "$QUIET_CORE_DIR/quiet-tail.sh" "$log" "${QUIET_FAIL_TAIL_LINES}" 2>/dev/null || tail -n "${QUIET_FAIL_TAIL_LINES}" "$log"
  fi
  exit "$st"
  ;;

*)
  echo "qr: unknown mode '$mode'" >&2
  exit 2
  ;;
esac
```

Make it executable: `chmod +x core/qr.sh`

- [ ] **Step 4: Wire the generic call site in `core/quiet-core.sh`**

Find this exact block (the last branch in `quiet_rewrite`, the "verbose-runner path"):

```bash
  if [[ $cmd =~ $verbose_re ]]; then
    _quiet_wrap_generic "$cmd"
    return 0
  fi
```

Replace with:

```bash
  if [[ $cmd =~ $verbose_re ]]; then
    printf '%q %q %q' "${QUIET_CORE_DIR}/qr.sh" "generic" "$cmd"
    return 0
  fi
```

- [ ] **Step 5: Fix `quiet_run`'s wording in `core/quiet-core.sh`**

Find (inside the `quiet_run` function):

```bash
  if [ "$st" -eq 0 ]; then
    echo "[ok: exit 0 — ${ln} lines hidden in ${log}; grep/tail it only if you need details]"
  else
    echo "[FAILED: exit ${st} — ${ln} lines in ${log} | last ${QUIET_FAIL_TAIL_LINES} below; grep that file for the rest]"
    "$QUIET_CORE_DIR/quiet-tail.sh" "$log" "${QUIET_FAIL_TAIL_LINES}" 2>/dev/null || tail -n "${QUIET_FAIL_TAIL_LINES}" "$log"
  fi
```

Replace with:

```bash
  if [ "$st" -eq 0 ]; then
    echo "[ok: exit 0 — ${ln} lines hidden in ${log}; more: ${QUIET_CORE_DIR}/quiet-tail.sh ${log} <n> | tally: quiet-agg.sh ${log} '<re>']"
  else
    echo "[FAILED: exit ${st} — ${ln} lines in ${log} | last ${QUIET_FAIL_TAIL_LINES} below; more: ${QUIET_CORE_DIR}/quiet-tail.sh ${log} <n> | tally: quiet-agg.sh ${log} '<re>']"
    "$QUIET_CORE_DIR/quiet-tail.sh" "$log" "${QUIET_FAIL_TAIL_LINES}" 2>/dev/null || tail -n "${QUIET_FAIL_TAIL_LINES}" "$log"
  fi
```

(Note: this is textually different from the heredoc version inside `_quiet_wrap_generic` — that one uses `\$__ln`/`\$__log`. Leave `_quiet_wrap_generic` untouched; it's deleted wholesale in Task 6.)

- [ ] **Step 6: Run the suite to verify the new assertions pass**

Run: `bash tests/run.sh 2>&1 | tail -20`
Expected: every line under `== qr.sh: generic mode ==` prints `ok`, ending in `ALL TESTS PASSED`.

- [ ] **Step 7: Shellcheck**

Run: `shellcheck -S error core/qr.sh core/quiet-core.sh`
Expected: no output, exit 0.

- [ ] **Step 8: Commit**

```bash
git add core/qr.sh core/quiet-core.sh tests/run.sh
git commit -m "$(cat <<'EOF'
feat: qr.sh dispatcher for generic verbose-command rewrites

quiet_rewrite now returns a one-line "qr.sh generic <cmd>" call instead of
an inline mktemp/redirect/if-else heredoc, so what an adapter's UI shows as
the command about to run is short and readable. Also fixes quiet_run's
"grep/tail it" hint to name the actual tools (quiet-tail.sh/quiet-agg.sh).
EOF
)"
```

---

### Task 2: Add `git` mode to `qr.sh`; wire the git call site

**Files:**
- Modify: `core/qr.sh` (insert a new case branch before the `*)` fallback)
- Modify: `core/quiet-core.sh` (the git-diff/show/log branch in `quiet_rewrite`)
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: the `*)` fallback block created in Task 1, used as the insertion anchor.
- Produces: `qr.sh git <cmd> <summary-cmd>` — runs `<cmd>`; on failure, tails the log; on success, shows inline if ≤ `QUIET_INLINE_LINE_LIMIT` lines, else prints a `locate:`/`tally:` hint and runs `<summary-cmd>` (piped through `head -n 200`).

- [ ] **Step 1: Write the failing tests**

In `tests/run.sh`, find the final summary block again:

```bash
echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
```

Replace with:

```bash
echo "== qr.sh: git mode =="
r=$(quiet_rewrite "git diff")
printf '%s' "$r" | grep -qF 'qr.sh git' && pass "git: quiet_rewrite routes to qr.sh git" || bad "git: quiet_rewrite routes to qr.sh git"
printf '%s' "$r" | grep -qF 'mktemp' && bad "git: rewrite still inlines mktemp" || pass "git: rewrite has no inline mktemp"

GD=$(mktemp -d)
( cd "$GD" && git init -q && git config user.email t@t.com && git config user.name t \
  && printf 'a\nb\nc\n' > f.txt && git add f.txt && git commit -qm init \
  && for i in $(seq 1 100); do echo "line $i" >> f.txt; done \
  && git add f.txt && git commit -qm bulk )
out=$( cd "$GD" && "$ROOT/core/qr.sh" git 'git log --oneline' 'git log --oneline' )
printf '%s' "$out" | grep -qF 'bulk' && pass "git: small output shown inline" || bad "git: small output shown inline"

out=$( cd "$GD" && "$ROOT/core/qr.sh" git 'git show nonexistent-ref' 'git show --stat nonexistent-ref' )
printf '%s' "$out" | grep -qF '[git FAILED: exit' && pass "git: failure message format" || bad "git: failure message format"
( cd "$GD" && "$ROOT/core/qr.sh" git 'git show nonexistent-ref' 'git show --stat nonexistent-ref' >/dev/null 2>&1 ); [ $? -ne 0 ] && pass "git: exit code passthrough on failure" || bad "git: exit code passthrough on failure"
rm -rf "$GD"

GD2=$(mktemp -d)
( cd "$GD2" && git init -q && git config user.email t@t.com && git config user.name t \
  && printf 'orig\n' > f.txt && git add f.txt && git commit -qm init \
  && for i in $(seq 1 100); do echo "line $i"; done > f.txt )
out=$( cd "$GD2" && "$ROOT/core/qr.sh" git 'git diff' 'git diff --stat' )
{ printf '%s' "$out" | grep -qF 'git output is' \
  && printf '%s' "$out" | grep -qF 'locate: ' \
  && printf '%s' "$out" | grep -qF 'tally: quiet-agg.sh'; } \
  && pass "git: large output uses new locate/tally wording" || bad "git: large output uses new locate/tally wording"
printf '%s' "$out" | grep -qF 'f.txt' && pass "git: large-output summary shows file stat" || bad "git: large-output summary shows file stat"
rm -rf "$GD2"

echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
```

- [ ] **Step 2: Run the suite to verify these new assertions fail**

Run: `bash tests/run.sh 2>&1 | tail -25`
Expected: `git: quiet_rewrite routes to qr.sh git` fails (git still routes to `_quiet_wrap_git`); the direct `"$ROOT/core/qr.sh" git ...` calls fail with "qr: unknown mode 'git'" since mode `git` doesn't exist yet.

- [ ] **Step 3: Add the `git` branch to `core/qr.sh`**

In `core/qr.sh`, find:

```bash
*)
  echo "qr: unknown mode '$mode'" >&2
  exit 2
  ;;
esac
```

Replace with:

```bash
git)
  summary="${3:?usage: qr.sh git <cmd> <summary-cmd>}"
  log=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
  bash -c "$cmd" >"$log" 2>&1
  st=$?
  ln=$(wc -l <"$log" | tr -d ' ')
  if [ "$st" -ne 0 ]; then
    echo "[git FAILED: exit ${st} — ${ln} lines in ${log} | last ${QUIET_FAIL_TAIL_LINES} below]"
    "$QUIET_CORE_DIR/quiet-tail.sh" "$log" "${QUIET_FAIL_TAIL_LINES}" 2>/dev/null || tail -n "${QUIET_FAIL_TAIL_LINES}" "$log"
  elif [ "$ln" -le "${QUIET_INLINE_LINE_LIMIT}" ]; then
    cat "$log"
  else
    echo "[git output is ${ln} lines -> ${log} | summary below; locate: grep -n '<pattern>' ${log} | tally: quiet-agg.sh ${log} '<pattern>']"
    bash -c "$summary" 2>/dev/null | head -n 200
  fi
  exit "$st"
  ;;

*)
  echo "qr: unknown mode '$mode'" >&2
  exit 2
  ;;
esac
```

- [ ] **Step 4: Wire the git call site in `core/quiet-core.sh`**

Find:

```bash
    _quiet_wrap_git "$cmd" "$summary"
    return 0
  fi
```

Replace with:

```bash
    printf '%q %q %q %q' "${QUIET_CORE_DIR}/qr.sh" "git" "$cmd" "$summary"
    return 0
  fi
```

- [ ] **Step 5: Run the suite to verify the new assertions pass**

Run: `bash tests/run.sh 2>&1 | tail -25`
Expected: every line under `== qr.sh: git mode ==` prints `ok`, and the full suite still ends `ALL TESTS PASSED`.

- [ ] **Step 6: Shellcheck**

Run: `shellcheck -S error core/qr.sh core/quiet-core.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add core/qr.sh core/quiet-core.sh tests/run.sh
git commit -m "feat: qr.sh git mode for diff/show/log rewrites"
```

---

### Task 3: Add `content` mode to `qr.sh`; wire both content call sites

**Files:**
- Modify: `core/qr.sh`
- Modify: `core/quiet-core.sh` (the `gh` content-path branch, and the `logdump_re` line in the infra/list-content branch)
- Test: `tests/run.sh`

**Interfaces:**
- Produces: `qr.sh content <cmd>` — runs `<cmd>`; shows inline if ≤ `QUIET_INLINE_LINE_LIMIT` lines, else prints head 15 + an ellipsis count + a cleaned tail (25 lines), with a `more:`/`locate:` hint. No failure-specific branch (matches current `_quiet_wrap_content` behavior — the caller wants the content regardless of exit status).

- [ ] **Step 1: Write the failing tests**

Replace the final summary block in `tests/run.sh` with:

```bash
echo "== qr.sh: content mode =="
r=$(quiet_rewrite "gh pr diff 45")
printf '%s' "$r" | grep -qF 'qr.sh content' && pass "content: gh pr diff routes to qr.sh content" || bad "content: gh pr diff routes to qr.sh content"
r2=$(quiet_rewrite "kubectl logs mypod")
printf '%s' "$r2" | grep -qF 'qr.sh content' && pass "content: kubectl logs routes to qr.sh content" || bad "content: kubectl logs routes to qr.sh content"

out=$("$ROOT/core/qr.sh" content 'echo hello')
[ "$out" = "hello" ] && pass "content: small output shown inline" || bad "content: small output shown inline"

out=$("$ROOT/core/qr.sh" content 'for i in $(seq 1 100); do echo "line $i"; done')
{ printf '%s' "$out" | grep -qF 'head+tail below' \
  && printf '%s' "$out" | grep -qF 'more: ' \
  && printf '%s' "$out" | grep -qF 'quiet-tail.sh' \
  && printf '%s' "$out" | grep -qF 'locate: grep -n'; } \
  && pass "content: large output uses new wording" || bad "content: large output uses new wording"
{ printf '%s' "$out" | grep -qF 'line 1' && printf '%s' "$out" | grep -qF 'line 100'; } \
  && pass "content: head+tail both present" || bad "content: head+tail both present"
printf '%s' "$out" | grep -qF '— grep it' && bad "content: ellipsis still has old trailing hint" || pass "content: ellipsis has no old trailing hint"

echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
```

- [ ] **Step 2: Run the suite to verify these new assertions fail**

Run: `bash tests/run.sh 2>&1 | tail -15`
Expected: routing assertions fail (still routes to `_quiet_wrap_content`); direct `qr.sh content ...` calls fail with "unknown mode 'content'".

- [ ] **Step 3: Add the `content` branch to `core/qr.sh`**

Find the `*)` fallback block and insert before it:

```bash
content)
  log=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
  bash -c "$cmd" >"$log" 2>&1
  st=$?
  ln=$(wc -l <"$log" | tr -d ' ')
  if [ "$ln" -le "${QUIET_INLINE_LINE_LIMIT}" ]; then
    cat "$log"
  else
    echo "[output is ${ln} lines -> ${log} | head+tail below; more: ${QUIET_CORE_DIR}/quiet-tail.sh ${log} <n> | locate: grep -n '<pattern>' ${log}]"
    head -n 15 "$log"
    echo "   ⋮ ($((ln - 40)) more lines in ${log})"
    "$QUIET_CORE_DIR/quiet-tail.sh" "$log" 25 2>/dev/null || tail -n 25 "$log"
  fi
  exit "$st"
  ;;

*)
  echo "qr: unknown mode '$mode'" >&2
  exit 2
  ;;
esac
```

- [ ] **Step 4: Wire the two content call sites in `core/quiet-core.sh`**

Find (the `gh` content path):

```bash
    _quiet_wrap_content "$cmd"
    return 0
  fi
```

Replace with:

```bash
    printf '%q %q %q' "${QUIET_CORE_DIR}/qr.sh" "content" "$cmd"
    return 0
  fi
```

Find (the infra/list-content path — note this line has the log-dump branch; leave the adjacent `listing_re` line for Task 4):

```bash
    if [[ $cmd =~ $logdump_re ]]; then _quiet_wrap_content "$cmd"; return 0; fi
```

Replace with:

```bash
    if [[ $cmd =~ $logdump_re ]]; then printf '%q %q %q' "${QUIET_CORE_DIR}/qr.sh" "content" "$cmd"; return 0; fi
```

- [ ] **Step 5: Run the suite to verify the new assertions pass**

Run: `bash tests/run.sh 2>&1 | tail -15`
Expected: every line under `== qr.sh: content mode ==` prints `ok`, full suite ends `ALL TESTS PASSED`.

- [ ] **Step 6: Shellcheck**

Run: `shellcheck -S error core/qr.sh core/quiet-core.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add core/qr.sh core/quiet-core.sh tests/run.sh
git commit -m "feat: qr.sh content mode for gh/log-dump rewrites"
```

---

### Task 4: Add `search` mode to `qr.sh`; wire all three search call sites

**Files:**
- Modify: `core/qr.sh`
- Modify: `core/quiet-core.sh` (recursive-listing branch, recursive-search/grep branch, and the `listing_re` line in the infra/list-content branch)
- Test: `tests/run.sh`

**Interfaces:**
- Produces: `qr.sh search <cmd>` — runs `<cmd>`; shows inline if ≤ `QUIET_INLINE_LINE_LIMIT` lines, else prints the first `QUIET_FAIL_TAIL_LINES` lines with a `locate:`/`tally:` hint.

- [ ] **Step 1: Write the failing tests**

Replace the final summary block in `tests/run.sh` with:

```bash
echo "== qr.sh: search mode =="
r=$(quiet_rewrite "ls -R /tmp")
printf '%s' "$r" | grep -qF 'qr.sh search' && pass "search: ls -R routes to qr.sh search" || bad "search: ls -R routes to qr.sh search"
r2=$(quiet_rewrite "grep -r foo .")
printf '%s' "$r2" | grep -qF 'qr.sh search' && pass "search: grep -r routes to qr.sh search" || bad "search: grep -r routes to qr.sh search"
r3=$(quiet_rewrite "npm ls")
printf '%s' "$r3" | grep -qF 'qr.sh search' && pass "search: npm ls routes to qr.sh search" || bad "search: npm ls routes to qr.sh search"

out=$("$ROOT/core/qr.sh" search 'echo one; echo two')
{ printf '%s' "$out" | grep -qF 'one' && printf '%s' "$out" | grep -qF 'two'; } && pass "search: small output shown inline" || bad "search: small output shown inline"

out=$("$ROOT/core/qr.sh" search 'for i in $(seq 1 100); do echo "file_$i.txt"; done')
{ printf '%s' "$out" | grep -qF 'lines ->' \
  && printf '%s' "$out" | grep -qF 'locate: grep -n' \
  && printf '%s' "$out" | grep -qF 'tally: quiet-agg.sh'; } \
  && pass "search: large output uses new wording" || bad "search: large output uses new wording"

echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
```

- [ ] **Step 2: Run the suite to verify these new assertions fail**

Run: `bash tests/run.sh 2>&1 | tail -15`
Expected: routing assertions fail; direct `qr.sh search ...` calls fail with "unknown mode 'search'".

- [ ] **Step 3: Add the `search` branch to `core/qr.sh`**

Find the `*)` fallback block and insert before it:

```bash
search)
  log=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
  bash -c "$cmd" >"$log" 2>&1
  st=$?
  ln=$(wc -l <"$log" | tr -d ' ')
  if [ "$ln" -le "${QUIET_INLINE_LINE_LIMIT}" ]; then
    cat "$log"
  else
    echo "[${ln} lines -> ${log} | first ${QUIET_FAIL_TAIL_LINES} below; locate: grep -n '<pattern>' ${log} | tally: quiet-agg.sh ${log} '<pattern>']"
    head -n "${QUIET_FAIL_TAIL_LINES}" "$log"
  fi
  exit "$st"
  ;;

*)
  echo "qr: unknown mode '$mode'" >&2
  exit 2
  ;;
esac
```

- [ ] **Step 4: Wire all three search call sites in `core/quiet-core.sh`**

Find (recursive-listing path):

```bash
  if [[ $cmd != *'|'* && $cmd != *'>'* && $cmd != *'$('* && $cmd != *'`'* && $cmd != *-exec* ]] \
     && { [[ $cmd =~ $lsr_re ]] || [[ $cmd =~ $tree_re ]] || [[ $cmd =~ $find_re ]]; }; then
    _quiet_wrap_search "$cmd"
    return 0
  fi
```

Replace with:

```bash
  if [[ $cmd != *'|'* && $cmd != *'>'* && $cmd != *'$('* && $cmd != *'`'* && $cmd != *-exec* ]] \
     && { [[ $cmd =~ $lsr_re ]] || [[ $cmd =~ $tree_re ]] || [[ $cmd =~ $find_re ]]; }; then
    printf '%q %q %q' "${QUIET_CORE_DIR}/qr.sh" "search" "$cmd"
    return 0
  fi
```

Find (recursive-search / grep-rg path):

```bash
  if [[ $cmd != *'|'* && $cmd != *'>'* && $cmd != *'$('* && $cmd != *'`'* && $cmd != *-exec* ]] \
     && { { [[ $cmd =~ $grep_re ]] && [[ $cmd =~ $recflag_re ]]; } || [[ $cmd =~ $rg_re ]]; } \
     && ! [[ $cmd =~ $sbound_re ]]; then
    _quiet_wrap_search "$cmd"
    return 0
  fi
```

Replace with:

```bash
  if [[ $cmd != *'|'* && $cmd != *'>'* && $cmd != *'$('* && $cmd != *'`'* && $cmd != *-exec* ]] \
     && { { [[ $cmd =~ $grep_re ]] && [[ $cmd =~ $recflag_re ]]; } || [[ $cmd =~ $rg_re ]]; } \
     && ! [[ $cmd =~ $sbound_re ]]; then
    printf '%q %q %q' "${QUIET_CORE_DIR}/qr.sh" "search" "$cmd"
    return 0
  fi
```

Find (the `listing_re` line in the infra/list-content path — note the two spaces before `"$cmd"` in the original):

```bash
    if [[ $cmd =~ $listing_re ]]; then _quiet_wrap_search  "$cmd"; return 0; fi
```

Replace with:

```bash
    if [[ $cmd =~ $listing_re ]]; then printf '%q %q %q' "${QUIET_CORE_DIR}/qr.sh" "search" "$cmd"; return 0; fi
```

- [ ] **Step 5: Run the suite to verify the new assertions pass**

Run: `bash tests/run.sh 2>&1 | tail -15`
Expected: every line under `== qr.sh: search mode ==` prints `ok`, full suite ends `ALL TESTS PASSED`.

- [ ] **Step 6: Shellcheck**

Run: `shellcheck -S error core/qr.sh core/quiet-core.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add core/qr.sh core/quiet-core.sh tests/run.sh
git commit -m "feat: qr.sh search mode for listing/recursive-search rewrites"
```

---

### Task 5: Add `curl` mode to `qr.sh`; wire the curl call site

**Files:**
- Modify: `core/qr.sh`
- Modify: `core/quiet-core.sh` (the curl branch in `quiet_rewrite`)
- Test: `tests/run.sh`

**Interfaces:**
- Produces: `qr.sh curl <cmd>` — runs `<cmd>`; shows inline if ≤ `QUIET_JSON_MIN_BYTES` bytes; if larger and valid JSON, collapses via `quiet-json.sh` (wording unchanged — already correct); else head 15 + cleaned tail 25 with a `more:`/`locate:` hint.

- [ ] **Step 1: Write the failing tests**

Replace the final summary block in `tests/run.sh` with:

```bash
echo "== qr.sh: curl mode =="
r=$(quiet_rewrite "curl https://example.com")
printf '%s' "$r" | grep -qF 'qr.sh curl' && pass "curl: routes to qr.sh curl" || bad "curl: routes to qr.sh curl"

out=$(QUIET_JSON_MIN_BYTES=50 "$ROOT/core/qr.sh" curl 'for i in $(seq 1 20); do echo "resp line $i padding padding padding padding padding"; done')
{ printf '%s' "$out" | grep -qF 'curl returned' \
  && printf '%s' "$out" | grep -qF 'more: ' \
  && printf '%s' "$out" | grep -qF 'quiet-tail.sh' \
  && printf '%s' "$out" | grep -qF 'locate: grep -n'; } \
  && pass "curl: large non-JSON uses new wording" || bad "curl: large non-JSON uses new wording"

out=$(QUIET_JSON_MIN_BYTES=10 "$ROOT/core/qr.sh" curl 'printf "%s" "{\"items\": [1,2,3,4,5]}"')
{ printf '%s' "$out" | grep -qF 'curl returned' \
  && printf '%s' "$out" | grep -qF 'bytes of JSON' \
  && printf '%s' "$out" | grep -qF 'query: ' \
  && printf '%s' "$out" | grep -qF 'quiet-query.sh'; } \
  && pass "curl: large JSON unchanged wording (query: quiet-query.sh)" || bad "curl: large JSON unchanged wording"

out=$("$ROOT/core/qr.sh" curl 'echo small-body')
[ "$out" = "small-body" ] && pass "curl: small body shown inline" || bad "curl: small body shown inline"

echo
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
```

- [ ] **Step 2: Run the suite to verify these new assertions fail**

Run: `bash tests/run.sh 2>&1 | tail -15`
Expected: routing assertion fails; direct `qr.sh curl ...` calls fail with "unknown mode 'curl'".

- [ ] **Step 3: Add the `curl` branch to `core/qr.sh`**

Find the `*)` fallback block and insert before it:

```bash
curl)
  log=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
  bash -c "$cmd" >"$log" 2>&1
  st=$?
  by=$(wc -c <"$log" | tr -d ' ')
  if [ "$by" -le "${QUIET_JSON_MIN_BYTES}" ]; then
    cat "$log"
  elif command -v jq >/dev/null 2>&1 && jq -e . "$log" >/dev/null 2>&1 && mv "$log" "$log.json" 2>/dev/null; then
    log="$log.json"
    echo "[curl returned ${by} bytes of JSON -> ${log} | collapsed below; query: ${QUIET_CORE_DIR}/quiet-query.sh ${log} keys]"
    "$QUIET_CORE_DIR/quiet-json.sh" "$log"
  else
    ln=$(wc -l <"$log" | tr -d ' ')
    echo "[curl returned ${by} bytes / ${ln} lines -> ${log} | head+tail below; more: ${QUIET_CORE_DIR}/quiet-tail.sh ${log} <n> | locate: grep -n '<pattern>' ${log}]"
    head -n 15 "$log"
    "$QUIET_CORE_DIR/quiet-tail.sh" "$log" 25 2>/dev/null || tail -n 25 "$log"
  fi
  exit "$st"
  ;;

*)
  echo "qr: unknown mode '$mode'" >&2
  exit 2
  ;;
esac
```

- [ ] **Step 4: Wire the curl call site in `core/quiet-core.sh`**

Find:

```bash
    _quiet_wrap_curl "$cmd"
    return 0
  fi
```

Replace with:

```bash
    printf '%q %q %q' "${QUIET_CORE_DIR}/qr.sh" "curl" "$cmd"
    return 0
  fi
```

- [ ] **Step 5: Run the suite to verify the new assertions pass**

Run: `bash tests/run.sh 2>&1 | tail -15`
Expected: every line under `== qr.sh: curl mode ==` prints `ok`, full suite ends `ALL TESTS PASSED`.

- [ ] **Step 6: Shellcheck**

Run: `shellcheck -S error core/qr.sh core/quiet-core.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add core/qr.sh core/quiet-core.sh tests/run.sh
git commit -m "feat: qr.sh curl mode for network-fetch rewrites"
```

---

### Task 6: Remove the dead `_quiet_wrap_*` functions; extend cache-safety coverage; full regression pass

**Files:**
- Modify: `core/quiet-core.sh` (delete the 5 now-unused function definitions)
- Modify: `tests/run.sh` (extend the cache-safety command list to include a `content`-mode command)

**Interfaces:** none new — this task only removes dead code and strengthens an existing test.

- [ ] **Step 1: Confirm the functions are actually unused**

Run: `grep -n '_quiet_wrap_' core/quiet-core.sh`
Expected output: exactly 5 lines, each a function *definition* (`_quiet_wrap_generic() {`, `_quiet_wrap_git() {`, `_quiet_wrap_content() {`, `_quiet_wrap_search() {`, `_quiet_wrap_curl() {`) — no call sites remain. If any call site remains, stop and check Tasks 1-5 were applied correctly first.

- [ ] **Step 2: Delete the 5 function definitions**

In `core/quiet-core.sh`, find the contiguous block starting at the `_quiet_wrap_generic` comment and ending right before the `quiet_result_summarize` section comment:

```bash
# Generic verbose runner: hide all output on success, tail the log on failure.
_quiet_wrap_generic() {
  cat <<WRAP
__log=\$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
{
$1
} >"\$__log" 2>&1
__st=\$?
__ln=\$(wc -l <"\$__log" | tr -d ' ')
if [ "\$__st" -eq 0 ]; then
  echo "[ok: exit 0 — \$__ln lines hidden in \$__log; grep/tail it only if you need details]"
else
  echo "[FAILED: exit \$__st — \$__ln lines in \$__log | last ${QUIET_FAIL_TAIL_LINES} below; grep that file for the rest]"
  "${QUIET_CORE_DIR}/quiet-tail.sh" "\$__log" ${QUIET_FAIL_TAIL_LINES} 2>/dev/null || tail -n ${QUIET_FAIL_TAIL_LINES} "\$__log"
fi
exit \$__st
WRAP
}

# git diff/show/log: show inline when small, else a --stat/--oneline summary.
_quiet_wrap_git() {
  cat <<WRAP
__log=\$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
{
$1
} >"\$__log" 2>&1
__st=\$?
__ln=\$(wc -l <"\$__log" | tr -d ' ')
if [ "\$__st" -ne 0 ]; then
  echo "[git FAILED: exit \$__st — \$__ln lines in \$__log | last ${QUIET_FAIL_TAIL_LINES} below]"
  "${QUIET_CORE_DIR}/quiet-tail.sh" "\$__log" ${QUIET_FAIL_TAIL_LINES} 2>/dev/null || tail -n ${QUIET_FAIL_TAIL_LINES} "\$__log"
elif [ "\$__ln" -le ${QUIET_INLINE_LINE_LIMIT} ]; then
  cat "\$__log"
else
  echo "[git output is \$__ln lines -> \$__log | summary below; grep/sed that file for specific files or hunks]"
  { $2 ; } 2>/dev/null | head -n 200
fi
exit \$__st
WRAP
}

# Content command (e.g. `gh run view --log`, `gh pr diff`): the agent wants the
# output, so show it inline when small; when large, spill the full content and
# surface a cleaned tail + a grep pointer (lossless — full output on disk).
_quiet_wrap_content() {
  cat <<WRAP
__log=\$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
{
$1
} >"\$__log" 2>&1
__st=\$?
__ln=\$(wc -l <"\$__log" | tr -d ' ')
if [ "\$__ln" -le ${QUIET_INLINE_LINE_LIMIT} ]; then
  cat "\$__log"
else
  echo "[output is \$__ln lines -> \$__log | head+tail below; grep that file for the rest]"
  head -n 15 "\$__log"
  echo "   ⋮ (\$((__ln - 40)) more lines in \$__log — grep it)"
  "${QUIET_CORE_DIR}/quiet-tail.sh" "\$__log" 25 2>/dev/null || tail -n 25 "\$__log"
fi
exit \$__st
WRAP
}

# Recursive listing (ls -R / tree / find <path>): can dump thousands of entries.
# Spill the full listing and show the first lines + count + a grep pointer
# (lossless). Head sample (not tail) because listings are read top-down.
_quiet_wrap_search() {
  cat <<WRAP
__log=\$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
{
$1
} >"\$__log" 2>&1
__st=\$?
__ln=\$(wc -l <"\$__log" | tr -d ' ')
if [ "\$__ln" -le ${QUIET_INLINE_LINE_LIMIT} ]; then
  cat "\$__log"
else
  echo "[\$__ln lines -> \$__log | first ${QUIET_FAIL_TAIL_LINES} below; grep/sed that file for the rest]"
  head -n ${QUIET_FAIL_TAIL_LINES} "\$__log"
fi
exit \$__st
WRAP
}

# Network fetch (curl): large API responses are a context sink, and JSON ones
# are often minified to a single line (head/tail useless). Spill full; collapse
# JSON via quiet-json; else head+tail. Small responses pass inline. Lossless.
_quiet_wrap_curl() {
  cat <<WRAP
__log=\$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
{
$1
} >"\$__log" 2>&1
__st=\$?
__by=\$(wc -c <"\$__log" | tr -d ' ')
if [ "\$__by" -le ${QUIET_JSON_MIN_BYTES} ]; then
  cat "\$__log"
elif command -v jq >/dev/null 2>&1 && jq -e . "\$__log" >/dev/null 2>&1 && mv "\$__log" "\$__log.json" 2>/dev/null; then
  echo "[curl returned \$__by bytes of JSON -> \$__log.json | collapsed below; query: ${QUIET_CORE_DIR}/quiet-query.sh \$__log.json keys]"
  "${QUIET_CORE_DIR}/quiet-json.sh" "\$__log.json"
else
  __ln=\$(wc -l <"\$__log" | tr -d ' ')
  echo "[curl returned \$__by bytes / \$__ln lines -> \$__log | head+tail below; grep that file for the rest]"
  head -n 15 "\$__log"
  "${QUIET_CORE_DIR}/quiet-tail.sh" "\$__log" 25 2>/dev/null || tail -n 25 "\$__log"
fi
exit \$__st
WRAP
}

```

Delete the entire block above (all 5 functions), leaving the comment/section that follows (`# ── Summarize a large tool RESULT ...`) directly after the previous section's blank line.

- [ ] **Step 3: Verify the deletion left no dangling references**

Run: `grep -n '_quiet_wrap_' core/quiet-core.sh`
Expected: no output (nothing found).

- [ ] **Step 4: Extend the cache-safety test's command coverage**

In `tests/run.sh`, find (inside the `"== cache-safety: ..."` section):

```bash
  for c in "yarn test" "cargo build --release" "git diff" "grep -r foo ." "curl https://x"; do
    [ "$(quiet_rewrite "$c")" = "$(quiet_rewrite "$c")" ] || cs_ok=0
  done
```

Replace with:

```bash
  for c in "yarn test" "cargo build --release" "git diff" "grep -r foo ." "curl https://x" "gh pr diff 1"; do
    [ "$(quiet_rewrite "$c")" = "$(quiet_rewrite "$c")" ] || cs_ok=0
  done
```

(This adds `content`-mode coverage — `"gh pr diff 1"` — to the determinism check; `generic`/`git`/`search`/`curl` were already covered by the existing list.)

- [ ] **Step 5: Run the full suite**

Run: `bash tests/run.sh 2>&1 | tail -20`
Expected: `ALL TESTS PASSED`.

- [ ] **Step 6: Shellcheck the whole modified surface**

Run: `shellcheck -S error core/*.sh adapters/*.sh tests/*.sh install.sh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add core/quiet-core.sh tests/run.sh
git commit -m "$(cat <<'EOF'
refactor: remove dead _quiet_wrap_* functions (now qr.sh)

All 5 wrap types are dispatched through core/qr.sh as of the previous
commits; the inline heredoc generators they replaced are now unreachable.
Also extends the cache-safety determinism test to cover content-mode.
EOF
)"
```

---

### Task 7: Update README and CHANGELOG

**Files:**
- Modify: `README.md` (the "How it works" section)
- Modify: `CHANGELOG.md` (the `[Unreleased]` section)

**Interfaces:** none — documentation only.

- [ ] **Step 1: Update README's "How it works" section**

Find:

```markdown
## How it works

Each adapter reads its agent's pre-tool event JSON, extracts the shell command, and calls
`quiet_rewrite` from the core. For a known-verbose command the core returns a rewritten
command that redirects output to `mktemp` and prints only a summary; the adapter wraps
that in whatever rewrite field its agent expects. Non-matching commands return nothing, so
they run unchanged. Each invocation also prunes redirect logs older than
`QUIET_LOG_RETENTION_MINUTES`.
```

Replace with:

```markdown
## How it works

Each adapter reads its agent's pre-tool event JSON, extracts the shell command, and calls
`quiet_rewrite` from the core. For a known-verbose command the core returns a short call to
`core/qr.sh <mode> <cmd>` (e.g. `qr.sh generic npm\ install`) instead of inlining the
mktemp/redirect/summarize logic as text — so whatever an adapter's UI shows as "the command
about to run" stays compact and readable. `qr.sh` does the actual work: it runs the
original command, redirects full output to `mktemp`, and prints only a summary; the
adapter wraps the one-line call in whatever rewrite field its agent expects. Non-matching
commands return nothing, so they run unchanged. Each invocation also prunes redirect logs
older than `QUIET_LOG_RETENTION_MINUTES`.
```

- [ ] **Step 2: Add a CHANGELOG entry**

Find:

```markdown
## [Unreleased]

### Added
- **Cache-hit observability** in `bench/session-savings.py` — it now also reports the real
  **cache-hit rate** (`cache_read` / all input tokens) measured across your own Claude Code
  transcripts, with the fresh / cache-read / cache-creation token split. This is the
  real-transcript counterpart to the Coinbase post's headline caching number. (Measured on
  the author's 188 sessions: ~96.8% pooled — Claude Code's own prompt caching is already very
  warm, so quiet-bash's payoff is avoiding the *fresh* re-bills and not busting that prefix.)
```

Replace with:

```markdown
## [Unreleased]

### Changed
- **`quiet_rewrite` now returns a one-line call to `core/qr.sh <mode> <cmd>` instead of an
  inline multi-line heredoc.** The mktemp/redirect/summarize logic that used to live in
  `_quiet_wrap_generic`/`_quiet_wrap_git`/`_quiet_wrap_content`/`_quiet_wrap_search`/
  `_quiet_wrap_curl` (generated as text, substituted into the returned command) now lives
  in `qr.sh` as real code, run via a short dispatcher call. Whatever an adapter's UI shows
  as "the command about to run" for a wrapped command is now compact and readable instead
  of a generated multi-line script. Runtime behavior (spill, summary, tail-on-failure, exit
  code) is unchanged; `quiet_rewrite`'s cache-safety determinism guarantee is preserved.
  Also standardizes the "read more of this log" hint text across all 5 wrap types —
  previously inconsistent phrasing ("grep/tail it", "grep that file for the rest",
  "grep/sed that file...") now consistently names `quiet-tail.sh`/`quiet-agg.sh` or a
  literal `grep -n`, matching the pattern the JSON/curl path already used correctly.

### Added
- **Cache-hit observability** in `bench/session-savings.py` — it now also reports the real
  **cache-hit rate** (`cache_read` / all input tokens) measured across your own Claude Code
  transcripts, with the fresh / cache-read / cache-creation token split. This is the
  real-transcript counterpart to the Coinbase post's headline caching number. (Measured on
  the author's 188 sessions: ~96.8% pooled — Claude Code's own prompt caching is already very
  warm, so quiet-bash's payoff is avoiding the *fresh* re-bills and not busting that prefix.)
```

- [ ] **Step 3: Run the full suite one more time**

Run: `bash tests/run.sh 2>&1 | tail -10`
Expected: `ALL TESTS PASSED` (README/CHANGELOG changes don't affect test behavior, but this confirms nothing else drifted).

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document the qr.sh dispatcher"
```

---

## Post-plan verification

After Task 7, do a final end-to-end sanity check that isn't covered by `tests/run.sh` unit assertions: manually run `quiet_rewrite "npm install"` and confirm the printed rewrite is short and contains no `mktemp`/`__log` text — this is the actual user-facing thing this whole plan exists to fix.

```bash
. core/quiet-core.sh
quiet_rewrite "npm install"
```

Expected output (path prefix will differ): `/absolute/path/to/core/qr.sh generic npm\ install`
