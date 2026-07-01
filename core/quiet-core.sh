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
: "${QUIET_PRUNE_INTERVAL_MINUTES:=5}"   # at most one prune scan per this many minutes
: "${QUIET_JSON_MIN_BYTES:=25000}"       # summarize *.json dumps larger than this
: "${QUIET_RESULT_MIN_BYTES:=${QUIET_MCP_MIN_BYTES:-25000}}" # summarize tool results larger than this
: "${QUIET_OUTLINE_MIN_BYTES:=30000}"    # outline source files larger than this
: "${QUIET_OUTLINE_MIN_SYMBOLS:=3}"      # below this many symbols, skip outlining

# Absolute dir of this core (so quiet_rewrite can point at sibling scripts).
QUIET_CORE_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null)" || QUIET_CORE_DIR=.

# Duplicate-read dedup helper (defines _quiet_mtime, quiet_dedup_check).
[ -r "$QUIET_CORE_DIR/quiet-dedup.sh" ] && . "$QUIET_CORE_DIR/quiet-dedup.sh"

# Stage-1 observe-only ledger (config-flag gated, default off; defines
# quiet_observe_record / quiet_observe_report / quiet_observe_fingerprint).
[ -r "$QUIET_CORE_DIR/quiet-observe.sh" ] && . "$QUIET_CORE_DIR/quiet-observe.sh"

# Stage-3 mechanical reuse (config-flag gated, default off; defines
# quiet_reuse_rewrite / quiet_reuse_eligible / quiet_reuse_enabled). Depends on
# helpers from quiet-dedup (_quiet_mtime) and quiet-observe (canon/hash), so it
# is sourced after both.
[ -r "$QUIET_CORE_DIR/quiet-reuse.sh" ] && . "$QUIET_CORE_DIR/quiet-reuse.sh"

# Stage-4 crystallization (manual CLI; defines quiet_crystallize_suggest).
# Reads the observe ledger, so it is sourced after quiet-observe.
[ -r "$QUIET_CORE_DIR/quiet-crystallize.sh" ] && . "$QUIET_CORE_DIR/quiet-crystallize.sh"

# ── Prune stale redirect logs ────────────────────────────────────────────────
quiet_prune() {
  # Throttle: a full dir scan on every hook invocation costs ~40ms. Skip it if we
  # pruned within the last QUIET_PRUNE_INTERVAL_MINUTES (a single-file stat, ~1ms).
  # Behaviour is unchanged — stale logs are still deleted, just checked less often.
  local stamp="${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}prune-stamp"
  if [ -e "$stamp" ] \
     && [ -z "$(find "$stamp" -mmin "+${QUIET_PRUNE_INTERVAL_MINUTES}" 2>/dev/null)" ]; then
    return 0   # pruned recently → skip the full scan
  fi
  : > "$stamp" 2>/dev/null || true   # mark prune time (mtime = now)
  find "$QUIET_LOG_DIR" -maxdepth 1 -type f -name "${QUIET_LOG_PREFIX}*" \
    ! -name "${QUIET_LOG_PREFIX}prune-stamp" \
    -mmin "+${QUIET_LOG_RETENTION_MINUTES}" -delete 2>/dev/null || true
}

# ── Get a file as JSON (json as-is; yaml via ruby / python3 / yq) ────────────
# Prints JSON and returns 0, or returns 1 if it can't convert. Multi-doc YAML
# becomes an array; single-doc is unwrapped.
quiet_to_json() {
  local file="$1" out
  case "$file" in
    *.yaml | *.yml)
      if command -v ruby >/dev/null 2>&1 \
         && out=$(ruby -ryaml -rjson -e 'd=YAML.load_stream(STDIN.read); puts JSON.generate(d.length==1 ? d[0] : d)' <"$file" 2>/dev/null) \
         && [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
      if command -v python3 >/dev/null 2>&1 \
         && out=$(python3 -c 'import sys,json,yaml; d=list(yaml.safe_load_all(sys.stdin)); json.dump(d[0] if len(d)==1 else d, sys.stdout)' <"$file" 2>/dev/null) \
         && [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
      if command -v yq >/dev/null 2>&1 \
         && out=$(yq -o=json '.' "$file" 2>/dev/null) && [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
      return 1 ;;
    *) cat "$file" ;;
  esac
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
    "$QUIET_CORE_DIR/quiet-tail.sh" "$log" "${QUIET_FAIL_TAIL_LINES}" 2>/dev/null || tail -n "${QUIET_FAIL_TAIL_LINES}" "$log"
  fi
  # Stage-1 observe: shell-wrapper/shim path runs the command here, so we have
  # the REAL output byte count. No-op unless observe is enabled.
  if command -v quiet_observe_record >/dev/null 2>&1; then
    quiet_observe_record "$*" 1 "$(wc -c <"$log" 2>/dev/null | tr -d ' ')"
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

# ── Summarize a large tool RESULT (for PostToolUse-style adapters) ───────────
# Given the textual payload of a tool result (and the tool name), prints a
# compact replacement summary and returns 0; returns 1 to pass through (small,
# empty, or already-wrapped). JSON → collapsed preview + quiet-query footer;
# text → head/tail + spill pointer. The byte-exact payload is spilled to a file.
quiet_result_summarize() {
  local text="$1" tool="${2:-tool}" bytes spill lines
  [ -z "$text" ] && return 1
  case "$text" in *'[quiet-bash]'* | *'[quiet-mcp]'*) return 1 ;; esac
  bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
  [ "$bytes" -le "${QUIET_RESULT_MIN_BYTES}" ] && return 1
  spill=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}result-XXXXXX")
  printf '%s' "$text" > "$spill"
  if printf '%s' "$text" | jq -e . >/dev/null 2>&1; then
    mv "$spill" "$spill.json"; spill="$spill.json"
    printf '[quiet-bash] %s returned %s bytes of JSON — collapsed below.\n%s' \
      "$tool" "$bytes" "$("$QUIET_CORE_DIR/quiet-json.sh" "$spill")"
  else
    lines=$(wc -l <"$spill" | tr -d ' ')
    printf '[quiet-bash] %s returned %s bytes / %s lines — spilled to %s\n' "$tool" "$bytes" "$lines" "$spill"
    echo "--- first 20 lines ---"; head -n 20 "$spill"
    echo "--- last 10 lines ---";  tail -n 10 "$spill"
    printf "[query the full result:  sed -n '1,60p' %q   |   grep -n '<pattern>' %q]\n" "$spill" "$spill"
  fi
  return 0
}

# ── Decide + rewrite ─────────────────────────────────────────────────────────
# Prints rewritten command and returns 0 to wrap; returns 1 to pass through.
quiet_rewrite() {
  local cmd=$1
  [ -z "$cmd" ] && return 1

  # Never double-wrap, and never wrap a follow-up read of a redirect log.
  case "$cmd" in
    *__log=* | *"${QUIET_LOG_PREFIX}"* | *quiet-json.sh* | *quiet-outline.sh*) return 1 ;;
  esac

  # All matching below uses the builtin `[[ =~ ]]` (ERE, identical to grep -E)
  # so the common non-matching command forks ZERO subprocesses. The two file
  # extractions still use one grep each, but only after a builtin pre-check
  # confirms a candidate is plausible — so they never run on a typical command.
  local read_re='(^|[[:space:];&|(])(cat|bat|less|more|head|tail)[[:space:]]'
  local jqyq_re="(^|[[:space:];&|(])(jq|yq)[[:space:]]+(-[A-Za-z=]+[[:space:]]+)*('\\.'|\\.)([[:space:]]|$)"

  # ── JSON/YAML read optimization: summarize a large structured-data dump ──
  # Only plain reads (cat/bat/less/more/head/tail or `jq .`/`yq .`) of a single
  # large .json/.yaml/.yml file — never a piped/redirected command or a
  # projection. YAML handled when a converter (ruby / python3 / yq) is present.
  if [[ $cmd != *'|'* && $cmd != *'>'* ]] \
     && [[ $cmd =~ [^[:space:]]+\.(json|ya?ml) ]] \
     && { [[ $cmd =~ $read_re ]] || [[ $cmd =~ $jqyq_re ]]; }; then
    local jfile
    jfile=$(printf '%s' "$cmd" | grep -oE '[^[:space:]]+\.(json|ya?ml)' | head -1)
    if [ -n "$jfile" ] && [ -f "$jfile" ] \
       && [ "$(wc -c <"$jfile" 2>/dev/null || echo 0)" -gt "${QUIET_JSON_MIN_BYTES}" ]; then
      local ok=0
      case "$jfile" in
        *.json) ok=1 ;;
        # YAML needs a converter — ruby (macOS default) / python3 / yq
        *) { command -v ruby >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || command -v yq >/dev/null 2>&1; } && ok=1 ;;
      esac
      if [ "$ok" = 1 ]; then
        printf '%q %q' "${QUIET_CORE_DIR}/quiet-json.sh" "$jfile"
        return 0
      fi
    fi
  fi

  # ── Source-file outline: large code file read → signature skeleton ──
  local src_token_re='[^[:space:]]+\.(py|js|mjs|cjs|jsx|ts|tsx|go|rs|java|kt|kts|scala|rb|c|h|cc|cpp|cxx|hpp|php|swift)'
  if [[ $cmd != *'|'* && $cmd != *'>'* ]] \
     && [[ $cmd =~ $src_token_re ]] && [[ $cmd =~ $read_re ]]; then
    local sfile
    sfile=$(printf '%s' "$cmd" | grep -oE "$src_token_re" | head -1)
    if [ -n "$sfile" ] && [ -f "$sfile" ] \
       && [ "$(wc -c <"$sfile" 2>/dev/null || echo 0)" -gt "${QUIET_OUTLINE_MIN_BYTES}" ]; then
      printf '%q %q' "${QUIET_CORE_DIR}/quiet-outline.sh" "$sfile"
      return 0
    fi
  fi

  # ── git path: diff/show/log have unbounded output but CONTENT matters ──
  local git_re='(^|[[:space:];&|(])git[[:space:]]+(diff|show|log)([[:space:]]|$)'
  # Skip if the command already bounds its own output (flag, pipe, or redirect).
  # `[|]` is an unambiguous literal pipe in both grep -E and bash ERE.
  local limited_re='[-][-](stat|shortstat|numstat|name-only|name-status|oneline)|[|][[:space:]]*(head|tail|wc|grep|sed|awk)|>'
  if [[ $cmd =~ $git_re ]] && ! [[ $cmd =~ $limited_re ]]; then
    local summary
    summary=$(printf '%s' "$cmd" | sed -E \
      -e 's/(^|[[:space:];&|(])git([[:space:]]+)diff/\1git\2diff --stat/' \
      -e 's/(^|[[:space:];&|(])git([[:space:]]+)show/\1git\2show --stat/' \
      -e 's/(^|[[:space:];&|(])git([[:space:]]+)log/\1git\2log --oneline/')
    _quiet_wrap_git "$cmd" "$summary"
    return 0
  fi

  # ── gh content path: CI logs / PR diffs are huge but the content matters ──
  # `gh run view … --log[-failed]` (CI logs) and `gh pr diff` dump large output
  # the agent reads to debug. Spill + cleaned tail + grep pointer (lossless).
  # Guard: skip command-substitution / backtick forms (e.g. `X=$(gh pr diff)`) —
  # rewriting them would corrupt the assignment, not just the output.
  local ghrun_re='(^|[[:space:];&|(])gh[[:space:]]+run[[:space:]]+view'
  local ghdiff_re='(^|[[:space:];&|(])gh[[:space:]]+pr[[:space:]]+diff([[:space:]]|$)'
  local ghlogflag_re='(^|[[:space:]])--log(-failed)?([[:space:]]|$)'   # bounded: not --log-url/--logout
  if [[ $cmd != *'|'* && $cmd != *'>'* && $cmd != *'$('* && $cmd != *'`'* ]] \
     && { { [[ $cmd =~ $ghrun_re ]] && [[ $cmd =~ $ghlogflag_re ]]; } || [[ $cmd =~ $ghdiff_re ]]; }; then
    _quiet_wrap_content "$cmd"
    return 0
  fi

  # ── recursive-listing path: ls -R / tree / find <path> can flood context ──
  # Listings only (NOT grep/rg — a targeted search missing a match is a
  # regression). Skip: piped/redirected, command-substitution ($(…)/backticks,
  # which would corrupt an assignment), and find -exec (that runs a tool whose
  # output is build/test results, not a listing — wrong summary window).
  local lsr_re='(^|[[:space:];&|(])ls[[:space:]]+-[A-Za-z]*R'
  local tree_re='(^|[;&|(])[[:space:]]*tree([[:space:]]|$)'   # tree as a command, not `… tree` subcommand
  local find_re='(^|[[:space:];&|(])find[[:space:]]+[^-]'
  if [[ $cmd != *'|'* && $cmd != *'>'* && $cmd != *'$('* && $cmd != *'`'* && $cmd != *-exec* ]] \
     && { [[ $cmd =~ $lsr_re ]] || [[ $cmd =~ $tree_re ]] || [[ $cmd =~ $find_re ]]; }; then
    _quiet_wrap_search "$cmd"
    return 0
  fi

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

  # ── network-fetch path: curl returning a large body floods context ──
  # Skip piped/redirected/$(…); skip -o/-O (writes a file, no stdout) and -I/
  # --head (headers only, small). Small responses still pass through inline.
  # Require a trailing space (so `echo curl`/`which curl`/bare `curl` don't match)
  # and allow a leading `/` (so `/usr/bin/curl` matches), mirroring verbose_re.
  local curl_re='(^|[[:space:];&|(/])curl[[:space:]]'
  local curlfile_re='(^|[[:space:]])(-o|--output|-O|--remote-name|-I|--head)([[:space:]]|$)'
  if [[ $cmd != *'|'* && $cmd != *'>'* && $cmd != *'$('* && $cmd != *'`'* ]] \
     && [[ $cmd =~ $curl_re ]] && ! [[ $cmd =~ $curlfile_re ]]; then
    _quiet_wrap_curl "$cmd"
    return 0
  fi

  # ── infra/list content path: large output the agent wants a SAMPLE of ──
  # Listings (read top-down) → head + count; log dumps (recent matters) → head+tail.
  # Both spill the full output (lossless) and only kick in past the inline limit, so
  # small results still pass inline. Skip piped/redirected/$()/backticks (would
  # corrupt an assignment or fight an explicit limit the agent already set).
  local listing_re='(^|[[:space:];&|(])(kubectl[[:space:]]+(get|describe)|docker[[:space:]]+(images|ps)|(npm|pnpm|yarn)[[:space:]]+(ls|list)|pip[0-9.]*[[:space:]]+(list|freeze|show)|brew[[:space:]]+(list|info))'
  local logdump_re='(^|[[:space:];&|(])(kubectl[[:space:]]+logs|docker[[:space:]]+logs|journalctl|dmesg)([[:space:]]|$)'
  local help_re='(^|[[:space:]])(-h|--help|--version|version)([[:space:]]|$)'
  if [[ $cmd != *'|'* && $cmd != *'>'* && $cmd != *'$('* && $cmd != *'`'* ]] && ! [[ $cmd =~ $help_re ]]; then
    if [[ $cmd =~ $listing_re ]]; then _quiet_wrap_search  "$cmd"; return 0; fi
    if [[ $cmd =~ $logdump_re ]]; then _quiet_wrap_content "$cmd"; return 0; fi
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
  managed="${managed}|terraform[[:space:]]+(plan|apply|destroy|init)|tofu[[:space:]]+(plan|apply|destroy|init)|pulumi[[:space:]]+(up|preview|destroy)|helm[[:space:]]+(install|upgrade|template|lint)|ansible-playbook([[:space:]]|$)"
  managed="${managed}|bundle[[:space:]]+(install|exec|update)|gem[[:space:]]+install"
  managed="${managed}|bk([[:space:]]|$)|buildkite"
  local verbose_re="${pre}(${always}|${managed})"

  if [[ $cmd =~ $verbose_re ]]; then
    _quiet_wrap_generic "$cmd"
    return 0
  fi

  return 1
}
