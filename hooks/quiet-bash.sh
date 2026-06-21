#!/usr/bin/env bash
#
# quiet-bash — a PreToolUse(Bash) hook for Claude Code.
#
# Known-verbose commands (test runners, builds, buildkite, docker, bazel, and
# unbounded `git diff/show/log`) have their full output redirected to a temp
# log file; only a short summary — plus the failure tail — enters the model's
# context. Short commands pass through untouched: wrapping them would cost more
# in extra round-trips than it saves.
#
# Contract: reads the PreToolUse event JSON on stdin and either
#   • prints an `updatedInput` JSON object that rewrites the command, or
#   • exits 0 with no output to let the command run unchanged.

set -u

# ── Config ──────────────────────────────────────────────────────────────────
LOG_DIR="${TMPDIR:-/tmp}"
LOG_PREFIX="claude-cmd-"   # temp-log basename prefix
INLINE_LINE_LIMIT=60       # git output up to this many lines is shown inline
FAIL_TAIL_LINES=40         # lines of a failed command's log to surface
LOG_RETENTION_MINUTES=1440 # prune redirect logs older than this (24h)

# ── Housekeeping: prune stale redirect logs ──────────────────────────────────
find "$LOG_DIR" -maxdepth 1 -type f -name "${LOG_PREFIX}*" \
  -mmin "+${LOG_RETENTION_MINUTES}" -delete 2>/dev/null || true

# ── Emit a rewritten command and exit ────────────────────────────────────────
emit() {
  jq -n --arg c "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: {command: $c}}}'
  exit 0
}

# Generic verbose runner: hide all output on success, tail the log on failure.
wrap_generic() {
  cat <<WRAP
__log=\$(mktemp "${LOG_DIR}/${LOG_PREFIX}XXXXXX")
{
$1
} >"\$__log" 2>&1
__st=\$?
__ln=\$(wc -l <"\$__log" | tr -d ' ')
if [ "\$__st" -eq 0 ]; then
  echo "[ok: exit 0 — \$__ln lines hidden in \$__log; grep/tail it only if you need details]"
else
  echo "[FAILED: exit \$__st — \$__ln lines in \$__log | last ${FAIL_TAIL_LINES} below; grep that file for the rest]"
  tail -n ${FAIL_TAIL_LINES} "\$__log"
fi
exit \$__st
WRAP
}

# git diff/show/log: content matters, so show it inline when small, else a
# --stat/--oneline summary plus a pointer to grep the full log.
wrap_git() {
  cat <<WRAP
__log=\$(mktemp "${LOG_DIR}/${LOG_PREFIX}XXXXXX")
{
$1
} >"\$__log" 2>&1
__st=\$?
__ln=\$(wc -l <"\$__log" | tr -d ' ')
if [ "\$__st" -ne 0 ]; then
  echo "[git FAILED: exit \$__st — \$__ln lines in \$__log | last ${FAIL_TAIL_LINES} below]"
  tail -n ${FAIL_TAIL_LINES} "\$__log"
elif [ "\$__ln" -le ${INLINE_LINE_LIMIT} ]; then
  cat "\$__log"
else
  echo "[git output is \$__ln lines -> \$__log | summary below; grep/sed that file for specific files or hunks]"
  { $2 ; } 2>/dev/null | head -n 200
fi
exit \$__st
WRAP
}

# ── Read the event ───────────────────────────────────────────────────────────
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0

# Never double-wrap, and never wrap a follow-up read of a redirect log.
case "$cmd" in
  *__log=* | *"${LOG_PREFIX}"*) exit 0 ;;
esac

# ── git path: diff/show/log have unbounded output but the CONTENT matters ─────
GIT_RE='(^|[[:space:];&|(])git[[:space:]]+(diff|show|log)([[:space:]]|$)'
# Skip if the command already bounds its own output (flags, a pipe, or a redirect).
LIMITED_RE='[-][-](stat|shortstat|numstat|name-only|name-status|oneline)|\|[[:space:]]*(head|tail|wc|grep|sed|awk)|>'
if printf '%s' "$cmd" | grep -qE "$GIT_RE" && ! printf '%s' "$cmd" | grep -qE "$LIMITED_RE"; then
  summary=$(printf '%s' "$cmd" | sed -E \
    -e 's/(^|[[:space:];&|(])git([[:space:]]+)diff/\1git\2diff --stat/' \
    -e 's/(^|[[:space:];&|(])git([[:space:]]+)show/\1git\2show --stat/' \
    -e 's/(^|[[:space:];&|(])git([[:space:]]+)log/\1git\2log --oneline/')
  emit "$(wrap_git "$cmd" "$summary")"
fi

# ── verbose-runner path: test/build/install/CI tooling ───────────────────────
VERBOSE_RE='(^|[[:space:];&|(])(yarn([[:space:]]+workspace[[:space:]]+[^[:space:]]+)?[[:space:]]+(test|build|lint|install)|npm[[:space:]]+(test|ci|install|run[[:space:]]+(test|build|lint))|npx[[:space:]]+(jest|turbo|tsc)|turbo[[:space:]]+run|jest([[:space:]]|$)|bk[[:space:]]|docker[[:space:]]+build|bazel[[:space:]]+(build|test))|buildkite'
printf '%s' "$cmd" | grep -qE "$VERBOSE_RE" || exit 0
emit "$(wrap_generic "$cmd")"
