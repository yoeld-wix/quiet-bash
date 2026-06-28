# Deterministic-first Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three deterministic-first levers — `quiet-check` (log verdict+tally), `quiet-wait` (collapse polling), and duplicate-read dedup (PostToolUse) — each shifting an AI action onto deterministic tooling.

**Architecture:** `quiet-check`/`quiet-wait` are zero-dependency `core/` verbs mirroring `core/quiet-verify.sh`. Dedup is a sourced core helper (`core/quiet-dedup.sh`) wired into the existing PostToolUse `Read` branch of `adapters/claude-code-result.sh`, backed by a session-scoped state file under `QUIET_LOG_DIR`. Everything is mechanical, lossless, no extra LLM call.

**Tech Stack:** `bash` + `jq` (already required) + coreutils (`grep`/`cksum`/`stat`/`wc`/`awk`). Tests append to `tests/run.sh` (`pass`/`bad` helpers, `== … ==` headers, `$ROOT` predefined).

## Global Constraints

- **Zero new dependencies** — bash + jq + coreutils only; no daemon, network, or model call.
- **No regression / lossless** — verbs operate on a path/condition and never mutate data; dedup only ever replaces a *re-emitted* read whose content is already verbatim above, gated on unchanged mtime+size+range, session-scoped, tail-edit only (prompt-cache safe).
- **Match existing style** — `core/` scripts mirror `core/quiet-verify.sh` (shebang, doc-comment header, arg guards: usage→stderr+exit 2). Provenance: every verb/stub prints a `[quiet-…]` header. Invalid-regex/`grep` error (exit ≥2) must exit 2, never a silent false result (the pattern added in commit 024c17e).
- **Numeric-arg validation** — reuse the `case "$n" in ''|*[!0-9]*) … exit 2` shape from `core/quiet-agg.sh`.
- Spec of record: `docs/superpowers/specs/2026-06-28-deterministic-first-expansion-design.md`.

---

### Task 1: `quiet-check` verb

**Files:**
- Create: `core/quiet-check.sh`
- Test: append a section to `tests/run.sh`

**Interfaces:**
- Produces: `core/quiet-check.sh <logfile>` → prints `[quiet-check] <PASS|FAIL> — <E> error(s), <W> warning(s) in <logfile>`; if `E>0`, also prints `--- first <K> error line(s) ---` then up to K matching lines (with line numbers). Exit 0 when `E==0`, 1 when `E>0`, 2 on missing/unreadable file or invalid override regex. Env overrides: `QUIET_CHECK_ERROR_RE`, `QUIET_CHECK_WARN_RE`, `QUIET_CHECK_FIRST_K` (default 5).

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` before the final summary/exit block:

```bash
echo "== quiet-check =="
QC="$ROOT/core/quiet-check.sh"
CF=$(mktemp); printf 'building...\nWARNING deprecated\nERROR boom\nFAILED step 2\nok done\n' > "$CF"
out=$("$QC" "$CF"); st=$?
{ [ "$st" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL' && printf '%s' "$out" | grep -qE '2 error' && printf '%s' "$out" | grep -qE '1 warning'; } \
  && pass "quiet-check FAIL + tally + exit 1" || bad "quiet-check fail-case"
printf '%s' "$out" | grep -q 'first 5 error' && pass "quiet-check shows first errors" || bad "quiet-check first errors"
GF=$(mktemp); printf 'building...\nall good\nok done\n' > "$GF"
out=$("$QC" "$GF"); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q 'PASS' && printf '%s' "$out" | grep -qE '0 error'; } \
  && pass "quiet-check PASS + exit 0" || bad "quiet-check pass-case"
"$QC" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-check usage exit 2" || bad "quiet-check usage"
"$QC" /no/such/file >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-check missing-file exit 2" || bad "quiet-check missing-file"
QUIET_CHECK_ERROR_RE='[' "$QC" "$CF" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-check invalid regex exit 2" || bad "quiet-check invalid regex"
rm -f "$CF" "$GF"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: the `quiet-check` lines FAIL (`core/quiet-check.sh` missing).

- [ ] **Step 3: Write minimal implementation**

Create `core/quiet-check.sh`:

```bash
#!/usr/bin/env bash
#
# quiet-check — deterministic verdict + error/warning tally over a log file,
# without reading the log into context.
#
#   quiet-check.sh <logfile>
#
# Prints PASS/FAIL + error/warning counts; on failure, the first K error lines.
# Exit 0 = no errors, 1 = errors found (so it doubles as a shell gate), 2 = usage.
# Tune via QUIET_CHECK_ERROR_RE / QUIET_CHECK_WARN_RE / QUIET_CHECK_FIRST_K.
#
#   quiet-check.sh build.log            # after a quiet-bash spill: [ok: … in <log>]
#   QUIET_CHECK_ERROR_RE='FAILED' quiet-check.sh test.out

file="${1:-}"
[ -n "$file" ] || { echo "usage: quiet-check.sh <logfile>" >&2; exit 2; }
[ -r "$file" ] || { echo "quiet-check: cannot read $file" >&2; exit 2; }
: "${QUIET_CHECK_ERROR_RE:=error|ERROR|FAIL(ED|URE)?|Exception|✗}"
: "${QUIET_CHECK_WARN_RE:=warn(ing)?|WARN}"
: "${QUIET_CHECK_FIRST_K:=5}"

e=$(grep -Ec -- "$QUIET_CHECK_ERROR_RE" "$file" 2>/dev/null); rc=$?
[ "$rc" -ge 2 ] && { echo "quiet-check: invalid QUIET_CHECK_ERROR_RE" >&2; exit 2; }
e=${e:-0}
w=$(grep -Ec -- "$QUIET_CHECK_WARN_RE" "$file" 2>/dev/null); rc=$?
[ "$rc" -ge 2 ] && { echo "quiet-check: invalid QUIET_CHECK_WARN_RE" >&2; exit 2; }
w=${w:-0}

if [ "$e" -gt 0 ]; then verdict=FAIL; else verdict=PASS; fi
echo "[quiet-check] $verdict — $e error(s), $w warning(s) in $file"
if [ "$e" -gt 0 ]; then
  echo "--- first $QUIET_CHECK_FIRST_K error line(s) ---"
  grep -En -- "$QUIET_CHECK_ERROR_RE" "$file" 2>/dev/null | head -n "$QUIET_CHECK_FIRST_K"
fi
[ "$e" -eq 0 ]
```

Then: `chmod +x core/quiet-check.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: all `quiet-check` lines `ok`; suite exits 0.

- [ ] **Step 5: Commit**

```bash
git add core/quiet-check.sh tests/run.sh
git commit -m "feat: quiet-check — deterministic verdict + error/warning tally over a log"
```

---

### Task 2: `quiet-wait` verb

**Files:**
- Create: `core/quiet-wait.sh`
- Test: append a section to `tests/run.sh`

**Interfaces:**
- Produces: `core/quiet-wait.sh <condition> [--timeout SECS] [--interval SECS]` — evaluates `<condition>` via `sh -c` in a loop; on success prints `[quiet-wait] condition met after <n> tries / <s>s` (exit 0); on timeout prints `[quiet-wait] TIMEOUT after <s>s (<n> tries) — condition never met` (exit 1). Defaults: timeout 60, interval 2 (interval floored to 1, timeout capped at 3600). Usage→stderr+exit 2 on missing condition, unknown flag, or non-numeric timeout/interval.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` before the final summary/exit block:

```bash
echo "== quiet-wait =="
QW="$ROOT/core/quiet-wait.sh"
out=$("$QW" 'true' --timeout 2 --interval 1); st=$?
{ [ "$st" -eq 0 ] && printf '%s' "$out" | grep -q 'condition met'; } && pass "quiet-wait success exit 0" || bad "quiet-wait success"
out=$("$QW" 'false' --timeout 1 --interval 1); st=$?
{ [ "$st" -eq 1 ] && printf '%s' "$out" | grep -q 'TIMEOUT'; } && pass "quiet-wait timeout exit 1" || bad "quiet-wait timeout"
"$QW" >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-wait usage exit 2" || bad "quiet-wait usage"
"$QW" 'true' --timeout abc >/dev/null 2>&1; [ $? -eq 2 ] && pass "quiet-wait bad timeout exit 2" || bad "quiet-wait bad timeout"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: `quiet-wait` lines FAIL (script missing).

- [ ] **Step 3: Write minimal implementation**

Create `core/quiet-wait.sh`:

```bash
#!/usr/bin/env bash
#
# quiet-wait — block until a shell condition holds, printing only the terminal
# state once (instead of polling across many agent turns).
#
#   quiet-wait.sh <condition> [--timeout SECS] [--interval SECS]
#
# <condition> is any shell expression (run via sh -c); success = exit 0.
# Defaults: --timeout 60, --interval 2. Exit 0 = met, 1 = timed out, 2 = usage.
#
#   quiet-wait.sh 'test -f /tmp/done' --timeout 120
#   quiet-wait.sh 'curl -sf localhost:8080/health' --interval 3

cond="${1:-}"
[ -n "$cond" ] || { echo "usage: quiet-wait.sh <condition> [--timeout SECS] [--interval SECS]" >&2; exit 2; }
shift
timeout=60; interval=2
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) timeout="${2:-}"; shift 2 || { echo "quiet-wait: --timeout needs a value" >&2; exit 2; } ;;
    --interval) interval="${2:-}"; shift 2 || { echo "quiet-wait: --interval needs a value" >&2; exit 2; } ;;
    *) echo "quiet-wait: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
case "$timeout" in ''|*[!0-9]*) echo "quiet-wait: --timeout must be a positive integer" >&2; exit 2 ;; esac
case "$interval" in ''|*[!0-9]*) echo "quiet-wait: --interval must be a positive integer" >&2; exit 2 ;; esac
[ "$interval" -ge 1 ] || interval=1
[ "$timeout" -le 3600 ] || timeout=3600

start=$(date +%s); tries=0
while :; do
  tries=$((tries + 1))
  if sh -c "$cond" >/dev/null 2>&1; then
    echo "[quiet-wait] condition met after $tries tries / $(( $(date +%s) - start ))s"
    exit 0
  fi
  if [ "$(( $(date +%s) - start ))" -ge "$timeout" ]; then
    echo "[quiet-wait] TIMEOUT after $(( $(date +%s) - start ))s ($tries tries) — condition never met"
    exit 1
  fi
  sleep "$interval"
done
```

Then: `chmod +x core/quiet-wait.sh`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: all `quiet-wait` lines `ok` (adds ~2–3s for the timeout case); suite exits 0.

- [ ] **Step 5: Commit**

```bash
git add core/quiet-wait.sh tests/run.sh
git commit -m "feat: quiet-wait — collapse status polling into one blocking call"
```

---

### Task 3: `quiet-dedup` core helper

**Files:**
- Create: `core/quiet-dedup.sh`
- Modify: `core/quiet-core.sh` (source the new helper)
- Test: append a section to `tests/run.sh`

**Interfaces:**
- Produces: two shell functions (sourced):
  - `_quiet_mtime <path>` → epoch-seconds mtime (portable: BSD `stat -f %m` then GNU `stat -c %Y`, else `0`).
  - `quiet_dedup_check <session_id> <path> <offset> <limit>` → returns 0 and **prints a stub** when the file is unchanged (mtime+size) since a prior recorded read of the same `path|offset|limit` in this session; otherwise returns 1 (no output) and **upserts** the record. Disabled (returns 1) if `session_id` or `path` is empty or `path` is not a regular file. State file: `${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}dedup-<sanitized-session_id>`.
- Consumes: `QUIET_LOG_DIR`, `QUIET_LOG_PREFIX` (already defined in `quiet-core.sh`).

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` before the final summary/exit block:

```bash
echo "== quiet-dedup =="
( # subshell so QUIET_LOG_DIR override is local
  export QUIET_LOG_DIR; QUIET_LOG_DIR=$(mktemp -d)
  . "$ROOT/core/quiet-dedup.sh"
  DF="$QUIET_LOG_DIR/data.txt"; printf 'hello\nworld\n' > "$DF"
  # first read: pass through (no output), returns 1
  o1=$(quiet_dedup_check "sessA" "$DF" "" ""); r1=$?
  { [ "$r1" -eq 1 ] && [ -z "$o1" ]; } && pass "dedup first read passes through" || bad "dedup first read"
  # second identical read: dedup (output + returns 0)
  o2=$(quiet_dedup_check "sessA" "$DF" "" ""); r2=$?
  { [ "$r2" -eq 0 ] && printf '%s' "$o2" | grep -q 'unchanged since you read it'; } && pass "dedup repeat read deduped" || bad "dedup repeat read"
  # changed mtime+content: pass through
  sleep 1; printf 'hello\nworld\nmore\n' > "$DF"
  o3=$(quiet_dedup_check "sessA" "$DF" "" ""); r3=$?
  [ "$r3" -eq 1 ] && pass "dedup changed file passes through" || bad "dedup changed file"
  # different range: different key → pass through
  o4=$(quiet_dedup_check "sessA" "$DF" "10" "20"); r4=$?
  [ "$r4" -eq 1 ] && pass "dedup different range passes through" || bad "dedup different range"
  # no session id: disabled
  o5=$(quiet_dedup_check "" "$DF" "" ""); r5=$?
  [ "$r5" -eq 1 ] && pass "dedup no-session disabled" || bad "dedup no-session"
  rm -rf "$QUIET_LOG_DIR"
)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: `quiet-dedup` lines FAIL (`core/quiet-dedup.sh` missing — sourcing errors, functions undefined).

- [ ] **Step 3: Write minimal implementation**

Create `core/quiet-dedup.sh`:

```bash
#!/usr/bin/env bash
#
# quiet-dedup — session-scoped duplicate-read detector (sourced helper).
#
# When an agent re-Reads a file it already read THIS SESSION and the file is
# unchanged (same mtime+size, same byte-range), the bytes are already verbatim
# earlier in context — re-sending them just re-bills the transcript. This helper
# detects that case so the hook can replace the re-emitted body with a stub.
# Lossless (content is above), session-scoped, and only ever applied to the
# just-emitted result (tail edit → prompt-cache safe).

# Portable mtime in epoch seconds (BSD stat, then GNU stat, else 0).
_quiet_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# quiet_dedup_check <session_id> <path> <offset> <limit>
#   prints stub + returns 0  -> dedup (unchanged repeat read)
#   no output  + returns 1   -> pass through (and upsert the record)
quiet_dedup_check() {
  local sid="$1" path="$2" off="${3:-}" lim="${4:-}"
  [ -n "$sid" ] && [ -n "$path" ] && [ -f "$path" ] || return 1
  local safe key state cmt csz prev
  safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')
  state="${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}dedup-${safe}"
  key=$(printf '%s|%s|%s' "$path" "$off" "$lim" | cksum | cut -d' ' -f1)
  cmt=$(_quiet_mtime "$path")
  csz=$(wc -c <"$path" 2>/dev/null | tr -d ' '); csz=${csz:-0}
  if [ -f "$state" ]; then
    prev=$(awk -v k="$key" '$1==k{m=$2; s=$3} END{ if (m!="") print m" "s }' "$state" 2>/dev/null)
  fi
  if [ -n "$prev" ] && [ "$prev" = "$cmt $csz" ]; then
    printf '[quiet-bash] %s is unchanged since you read it earlier this session — its full contents are already above. (To force a fresh read: touch the file, or read a different line range.)' "$path"
    return 0
  fi
  # upsert: drop any existing record for this key, append the fresh one
  { [ -f "$state" ] && grep -v -E "^${key} " "$state" 2>/dev/null
    printf '%s %s %s\n' "$key" "$cmt" "$csz"
  } > "${state}.tmp" 2>/dev/null && mv "${state}.tmp" "$state" 2>/dev/null
  return 1
}
```

- [ ] **Step 4: Source the helper from core**

In `core/quiet-core.sh`, immediately after the line that sets `QUIET_CORE_DIR` (the `QUIET_CORE_DIR="$(cd -P …)"` line near the top), add:

```bash
# Duplicate-read dedup helper (defines _quiet_mtime, quiet_dedup_check).
[ -r "$QUIET_CORE_DIR/quiet-dedup.sh" ] && . "$QUIET_CORE_DIR/quiet-dedup.sh"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: all `quiet-dedup` lines `ok`; suite exits 0.

- [ ] **Step 6: Commit**

```bash
git add core/quiet-dedup.sh core/quiet-core.sh tests/run.sh
git commit -m "feat: quiet-dedup core helper — session-scoped duplicate-read detector"
```

---

### Task 4: Wire dedup into the PostToolUse Read adapter

**Files:**
- Modify: `adapters/claude-code-result.sh`
- Test: append a section to `tests/run.sh`

**Interfaces:**
- Consumes: `quiet_dedup_check` (Task 3, available via `quiet-core.sh`). The adapter already sources `core/quiet-core.sh`.
- Behavior: in the `Read` branch, after the existing outline attempt, if the read was NOT outlined (would pass full content through), call `quiet_dedup_check "$sid" "$path" "$off" "$lim"`; on a hit, emit the stub as the replacement (mirroring the existing string/`content[]` shape); on a miss, pass through (exit 0). Adds `session_id`, `offset`, `limit` to the single jq extraction pass.

- [ ] **Step 1: Write the failing test**

Append to `tests/run.sh` before the final summary/exit block:

```bash
echo "== adapter: duplicate-read dedup =="
(
  export QUIET_LOG_DIR; QUIET_LOG_DIR=$(mktemp -d)
  BIG="$QUIET_LOG_DIR/big.log"
  awk 'BEGIN{for(i=0;i<4000;i++)print "line "i" some filler text to exceed the outline threshold"}' > "$BIG"
  CONTENT=$(cat "$BIG")
  EV=$(jq -n --arg p "$BIG" --arg t "$CONTENT" --arg s "sessDED" \
        '{session_id:$s, tool_name:"Read", tool_input:{file_path:$p}, tool_response:$t}')
  # first event: pass through (adapter prints nothing)
  o1=$(printf '%s' "$EV" | "$ROOT/adapters/claude-code-result.sh")
  [ -z "$o1" ] && pass "adapter first read passes through" || bad "adapter first read"
  # second identical event: deduped (adapter prints replacement with the stub)
  o2=$(printf '%s' "$EV" | "$ROOT/adapters/claude-code-result.sh")
  printf '%s' "$o2" | jq -e '.hookSpecificOutput.updatedToolOutput' >/dev/null 2>&1 \
    && printf '%s' "$o2" | grep -q 'unchanged since you read it' \
    && pass "adapter repeat read deduped" || bad "adapter repeat read"
  rm -rf "$QUIET_LOG_DIR"
)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/run.sh`
Expected: "adapter repeat read deduped" FAILS (second read still passes through — no dedup wired yet). The first-read assertion may already pass.

- [ ] **Step 3: Extend the jq extraction**

In `adapters/claude-code-result.sh`, replace the existing `meta=$(…)` jq block and the line that reads it back. Find this exact block:

```bash
meta=$(printf '%s' "$input" | jq -r '
  (.tool_response | if type=="string" then "string"
     elif (type=="object" and ((.content|type)=="array")) then "content"
     else "other" end),
  (.tool_name // "tool"),
  (.tool_input.path // .tool_input.file_path // ""),
  (.tool_response | if type=="string" then .
     else ((.content // []) | map(select(.type=="text") | .text) | join("\n")) end)
' 2>/dev/null)
{ IFS= read -r shape; IFS= read -r tool; IFS= read -r path; text=$(cat); } <<EOF
$meta
EOF
```

Replace it with (adds `session_id`, `offset`, `limit` as single-line fields before the multiline text):

```bash
meta=$(printf '%s' "$input" | jq -r '
  (.tool_response | if type=="string" then "string"
     elif (type=="object" and ((.content|type)=="array")) then "content"
     else "other" end),
  (.tool_name // "tool"),
  (.tool_input.path // .tool_input.file_path // ""),
  (.session_id // ""),
  (.tool_input.offset // ""),
  (.tool_input.limit // ""),
  (.tool_response | if type=="string" then .
     else ((.content // []) | map(select(.type=="text") | .text) | join("\n")) end)
' 2>/dev/null)
{ IFS= read -r shape; IFS= read -r tool; IFS= read -r path; IFS= read -r sid; IFS= read -r off; IFS= read -r lim; text=$(cat); } <<EOF
$meta
EOF
```

- [ ] **Step 4: Add the dedup branch**

In the same file, find the Read branch's pass-through tail:

```bash
  [ -z "$summary" ] && exit 0   # non-source / small Read → pass through untouched
```

Replace that single line with:

```bash
  if [ -z "$summary" ]; then
    # Not outlined → would re-send full content. If this is an unchanged repeat
    # read in the same session, replace it with a stub (content is already above).
    if dstub=$(quiet_dedup_check "$sid" "$path" "$off" "$lim"); then
      summary="$dstub"
    else
      exit 0   # non-source / small / first-seen Read → pass through untouched
    fi
  fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: both `adapter: duplicate-read dedup` lines `ok`; whole suite exits 0 (including the existing adapter shape tests, which are unaffected — the new jq fields are additive and the `yarn test`/`ls -la` events have no `session_id`/Read path).

- [ ] **Step 6: Commit**

```bash
git add adapters/claude-code-result.sh tests/run.sh
git commit -m "feat: dedup unchanged repeat Reads in the PostToolUse adapter (cache-safe)"
```

---

### Task 5: Surface in skill + README

**Files:**
- Modify: `skills/deterministic-first/SKILL.md`
- Modify: `README.md`
- Test: append a `quiet-check` composition test to `tests/run.sh`

**Interfaces:**
- Consumes: `core/quiet-check.sh` (Task 1), `core/quiet-wait.sh` (Task 2), the `quiet_run` spill function in `core/quiet-core.sh`.

- [ ] **Step 1: Write the failing composition test**

Append to `tests/run.sh` before the final summary/exit block:

```bash
echo "== composition: quiet-check over a spill =="
. "$ROOT/core/quiet-core.sh"
MSG=$(quiet_run sh -c 'echo building; echo "ERROR nope"; echo "WARNING meh"; exit 1' 2>/dev/null)
LOG=$(printf '%s' "$MSG" | grep -oE "${QUIET_LOG_DIR%/}/+${QUIET_LOG_PREFIX}[A-Za-z0-9]+" | head -1)
{ [ -n "$LOG" ] && [ -f "$LOG" ]; } && pass "spill log created (check)" || bad "spill log created (check)"
out=$("$ROOT/core/quiet-check.sh" "$LOG"); st=$?
{ [ "$st" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL' && printf '%s' "$out" | grep -qE '1 error'; } \
  && pass "quiet-check recovers verdict+tally from spill" || bad "quiet-check over spill"
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bash tests/run.sh`
Expected: both `composition: quiet-check over a spill` lines `ok` (regression guard — `quiet-check` already exists from Task 1, so it passes on first run).

- [ ] **Step 3: Update the skill cheatsheet**

In `skills/deterministic-first/SKILL.md`, in the pattern table (the rows under `## The decision rule`), update the **Verify** and **Wait** rows and add a **Re-read** row. Replace these two existing rows:

```markdown
| **Verify** a fact | read output to confirm | `quiet-verify FILE 'PAT'` · `test -f` · exit code |
```
```markdown
| **Wait** for a condition | poll by re-reading status | `until COND; do sleep N; done` |
```

with (Verify gains a tally entry; Wait points at the verb; a new Re-read row):

```markdown
| **Verify** a fact / triage a log | read output to confirm or count failures | `quiet-verify FILE 'PAT'` · `quiet-check FILE` (PASS/FAIL + error tally) · `test -f` |
| **Wait** for a condition | poll by re-reading status | `quiet-wait 'COND' --timeout N` · `until COND; do sleep N; done` |
| **Re-read** a file you already read | re-open it (re-bills the bytes) | don't — its contents are already above this turn; scroll up |
```

- [ ] **Step 4: Add the README row**

In `README.md`, find the row added previously (it begins `| **Read-to-find work**`). Directly beneath it, add:

```markdown
| **Repeated & blocking work** — re-reading unchanged files, judging logs, polling | model re-reads / re-judges / re-polls every turn | dedup of unchanged re-reads · `quiet-check` verdict+tally · `quiet-wait` one-shot poll |
```

- [ ] **Step 5: Verify the docs render**

Run: `grep -n 'Repeated & blocking work' README.md && grep -nc 'quiet-check\|quiet-wait\|Re-read' skills/deterministic-first/SKILL.md`
Expected: the README line prints once; the skill grep count is ≥ 3.

- [ ] **Step 6: Commit**

```bash
git add skills/deterministic-first/SKILL.md README.md tests/run.sh
git commit -m "docs: surface dedup/quiet-check/quiet-wait in skill + README; check-over-spill test"
```

---

## Notes for the implementer

- **Order:** Tasks 1→5 as written. 1 and 2 are independent isolated verbs; 3 must precede 4 (4 uses the helper); 5 is docs+composition and comes last.
- **Dedup scope (resolved from spec open question):** dedup fires only on reads that would otherwise pass *full content* through (large non-source). Source files are already outlined to a small deterministic form, so they are intentionally left to the existing outline path — do not add dedup there.
- **Portability:** `_quiet_mtime` handles BSD (macOS) and GNU `stat`; the composition tests reuse the `/+` slash tolerance from the existing spill-path regex (commit d9f8abc) for macOS `TMPDIR`.
- **Do not** weaken any arg/regex guard to make a test pass — exit 2 on bad input is a hard requirement (per global constraints).
