#!/usr/bin/env bash
#
# quiet-core — agent-agnostic core for quiet-bash.
#
# Decides whether a shell command is "known-verbose" and, if so, returns a
# rewritten command that redirects full output to a temp log and prints only a
# summary (with the failure tail). No knowledge of any particular AI agent's
# hook format lives here — adapters/ translate each agent's I/O to these calls:
#
#   . core/quiet-core.sh
#   quiet_prune                     # prune stale logs (call once per invocation)
#   if out=$(quiet_rewrite "$cmd"); then echo "$out"; fi   # else pass through
#
# quiet_rewrite prints the rewritten command and returns 0 when it wants to
# wrap; it returns 1 (no output) when the command should run unchanged.

# ── Config (override via environment) ────────────────────────────────────────
: "${QUIET_LOG_DIR:=${TMPDIR:-/tmp}}"
: "${QUIET_LOG_PREFIX:=claude-cmd-}"     # temp-log basename prefix
: "${QUIET_INLINE_LINE_LIMIT:=60}"       # git output up to this many lines shown inline
: "${QUIET_FAIL_TAIL_LINES:=40}"         # lines of a failed command's log to surface
: "${QUIET_LOG_RETENTION_MINUTES:=1440}" # prune redirect logs older than this (24h)
: "${QUIET_JSON_MIN_BYTES:=25000}"       # summarize *.json dumps larger than this

# Absolute dir of this core (so quiet_rewrite can point at sibling scripts).
QUIET_CORE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null)" || QUIET_CORE_DIR=.

# ── Prune stale redirect logs ────────────────────────────────────────────────
quiet_prune() {
  find "$QUIET_LOG_DIR" -maxdepth 1 -type f -name "${QUIET_LOG_PREFIX}*" \
    -mmin "+${QUIET_LOG_RETENTION_MINUTES}" -delete 2>/dev/null || true
}

# ── Runtime executor (for the shell-wrapper adapter) ─────────────────────────
# Runs the given command, sending full output to a temp log and printing only a
# summary; on failure it tails the log. Preserves the command's exit status.
quiet_run() {
  local log st ln
  log=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
  "$@" >"$log" 2>&1
  st=$?
  ln=$(wc -l <"$log" | tr -d ' ')
  if [ "$st" -eq 0 ]; then
    echo "[ok: exit 0 — ${ln} lines hidden in ${log}; grep/tail it only if you need details]"
  else
    echo "[FAILED: exit ${st} — ${ln} lines in ${log} | last ${QUIET_FAIL_TAIL_LINES} below; grep that file for the rest]"
    tail -n "${QUIET_FAIL_TAIL_LINES}" "$log"
  fi
  return "$st"
}

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
  tail -n ${QUIET_FAIL_TAIL_LINES} "\$__log"
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
  tail -n ${QUIET_FAIL_TAIL_LINES} "\$__log"
elif [ "\$__ln" -le ${QUIET_INLINE_LINE_LIMIT} ]; then
  cat "\$__log"
else
  echo "[git output is \$__ln lines -> \$__log | summary below; grep/sed that file for specific files or hunks]"
  { $2 ; } 2>/dev/null | head -n 200
fi
exit \$__st
WRAP
}

# ── Decide + rewrite ─────────────────────────────────────────────────────────
# Prints rewritten command and returns 0 to wrap; returns 1 to pass through.
quiet_rewrite() {
  local cmd=$1
  [ -z "$cmd" ] && return 1

  # Never double-wrap, and never wrap a follow-up read of a redirect log.
  case "$cmd" in
    *__log=* | *"${QUIET_LOG_PREFIX}"* | *quiet-json.sh*) return 1 ;;
  esac

  # ── JSON read optimization: summarize a large *.json dump ─────────────
  # Only plain reads (cat/bat/less/more/head/tail or `jq .`) of a single large
  # .json file — never a piped/redirected command or a jq projection (those
  # already narrow the output, so leave them alone).
  case "$cmd" in
    *'|'* | *'>'*) : ;;  # piped/redirected → skip JSON path
    *)
      local jfile
      jfile=$(printf '%s' "$cmd" | grep -oE '[^[:space:]]+\.json' | head -1)
      if [ -n "$jfile" ] && [ -f "$jfile" ] \
         && [ "$(wc -c <"$jfile" 2>/dev/null || echo 0)" -gt "${QUIET_JSON_MIN_BYTES}" ]; then
        if printf '%s' "$cmd" | grep -qE '(^|[[:space:];&|(])(cat|bat|less|more|head|tail)[[:space:]]' \
           || printf '%s' "$cmd" | grep -qE "(^|[[:space:];&|(])jq[[:space:]]+(-[A-Za-z]+[[:space:]]+)*('\\.'|\\.)([[:space:]]|\$)"; then
          printf '%q %q' "${QUIET_CORE_DIR}/quiet-json.sh" "$jfile"
          return 0
        fi
      fi
      ;;
  esac

  # ── git path: diff/show/log have unbounded output but CONTENT matters ──
  local git_re='(^|[[:space:];&|(])git[[:space:]]+(diff|show|log)([[:space:]]|$)'
  # Skip if the command already bounds its own output (flag, pipe, or redirect).
  local limited_re='[-][-](stat|shortstat|numstat|name-only|name-status|oneline)|\|[[:space:]]*(head|tail|wc|grep|sed|awk)|>'
  if printf '%s' "$cmd" | grep -qE "$git_re" && ! printf '%s' "$cmd" | grep -qE "$limited_re"; then
    local summary
    summary=$(printf '%s' "$cmd" | sed -E \
      -e 's/(^|[[:space:];&|(])git([[:space:]]+)diff/\1git\2diff --stat/' \
      -e 's/(^|[[:space:];&|(])git([[:space:]]+)show/\1git\2show --stat/' \
      -e 's/(^|[[:space:];&|(])git([[:space:]]+)log/\1git\2log --oneline/')
    _quiet_wrap_git "$cmd" "$summary"
    return 0
  fi

  # ── verbose-runner path: build/test/install/CI tooling across ecosystems ──
  # Boundary before a tool token: start, whitespace, shell operator, or a path
  # separator (so `./gradlew`, `./mvnw`, `/usr/bin/make` are recognised).
  local pre='(^|[[:space:];&|(/])'
  # Tools that are almost always verbose, whatever the subcommand.
  local always='(jest|vitest|mocha|cypress|playwright|pytest|tox|nox|cargo|gradle|gradlew|mvn|mvnw|maven|sbt|bloop|bazel|buildozer|buildkite|turbo|webpack|vite|rollup|esbuild|tsc|eslint|prettier|rspec|rake|ninja|gulp|grunt)([[:space:]]|$)'
  # Managers/tools verbose only for specific subcommands.
  local managed='(yarn|npm|pnpm|bun)([[:space:]]+(workspace|--filter|-w)[[:space:]]+[^[:space:]]+)*[[:space:]]+(test|build|lint|install|add|ci|run|dev|start|typecheck|watch)'
  managed="${managed}|npx[[:space:]]+[^[:space:]]+"
  managed="${managed}|pip[0-9.]*[[:space:]]+install|pipenv[[:space:]]+(install|run|sync)|poetry[[:space:]]+(install|build|run|update|lock)|uv[[:space:]]+(pip|sync|run|build|lock)|conda[[:space:]]+(install|env)|python[0-9.]*[[:space:]]+(-m|setup\.py)|tox([[:space:]]|$)"
  managed="${managed}|go[[:space:]]+(test|build|install|vet|mod|get|run)"
  managed="${managed}|make([[:space:]]|$)|cmake([[:space:]]|$)"
  managed="${managed}|docker[[:space:]]+(build|compose)|docker-compose[[:space:]]+(build|up)"
  managed="${managed}|bundle[[:space:]]+(install|exec|update)|gem[[:space:]]+install"
  managed="${managed}|bk([[:space:]]|$)|buildkite"
  local verbose_re="${pre}(${always}|${managed})"

  if printf '%s' "$cmd" | grep -qE "$verbose_re"; then
    _quiet_wrap_generic "$cmd"
    return 0
  fi

  return 1
}
