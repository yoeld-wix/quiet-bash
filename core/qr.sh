#!/usr/bin/env bash
#
# qr — quiet-bash's runtime dispatcher for known-verbose command rewrites.
#
#   qr.sh generic    <cmd>
#   qr.sh git        <cmd> <summary-cmd>
#   qr.sh content    <cmd>
#   qr.sh search     <cmd>
#   qr.sh grepsearch <cmd>
#   qr.sh curl       <cmd>
#
# quiet_rewrite (quiet-core.sh) used to return the mktemp/redirect/summarize
# logic below as inline heredoc text — the full generated script became "the
# command" wherever an adapter's UI shows the command about to run. Now it
# returns a one-line call to this script instead, so what's shown is short
# and readable; the actual spill/summary/tail behavior is unchanged.

QRDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$QRDIR/quiet-core.sh"

mode="${1:?usage: qr.sh <generic|git|content|search|grepsearch|curl> <cmd> [summary-cmd]}"
cmd="${2:?usage: qr.sh <generic|git|content|search|grepsearch|curl> <cmd> [summary-cmd]}"

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

git)
  summary="${3:?usage: qr.sh git <cmd> <summary-cmd>}"
  hunk_only="${4:-}"   # "--hunk-only" when QUIET_DIFF_HUNK_ONLY=1 (set by quiet_rewrite)
  log=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
  bash -c "$cmd" >"$log" 2>&1
  st=$?
  ln=$(wc -l <"$log" | tr -d ' ')
  if [ "$st" -ne 0 ]; then
    echo "[git FAILED: exit ${st} — ${ln} lines in ${log} | last ${QUIET_FAIL_TAIL_LINES} below]"
    "$QUIET_CORE_DIR/quiet-tail.sh" "$log" "${QUIET_FAIL_TAIL_LINES}" 2>/dev/null || tail -n "${QUIET_FAIL_TAIL_LINES}" "$log"
  elif [ "$ln" -le "${QUIET_INLINE_LINE_LIMIT}" ]; then
    # hunk-only: strip context lines (^space) so LLM sees only +/- lines and @@ headers;
    # full diff stays on disk at $log for follow-up reads.
    if [ -n "$hunk_only" ]; then grep -v '^[[:space:]]' "$log"; else cat "$log"; fi
  else
    echo "[git output is ${ln} lines -> ${log} | summary below; locate: grep -n '<pattern>' ${log} | tally: quiet-agg.sh ${log} '<pattern>']"
    bash -c "$summary" 2>/dev/null | head -n 200
  fi
  exit "$st"
  ;;

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

grepsearch)
  # grep -r / rg output is "path:content" or "path:line:content" — the text
  # before the FIRST colon is always the file path, so per-file match counts
  # are one awk pass, no flag-parsing needed. Long lines (a matched minified
  # single-line file) are capped so one match can't dominate the token budget.
  log=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}XXXXXX")
  bash -c "$cmd" >"$log" 2>&1
  st=$?
  ln=$(wc -l <"$log" | tr -d ' ')
  if [ "$ln" -le "${QUIET_INLINE_LINE_LIMIT}" ]; then
    cat "$log"
  else
    counts=$(awk -F: '{print $1}' "$log" | sort | uniq -c | sort -rn)
    nfiles=$(printf '%s\n' "$counts" | wc -l | tr -d ' ')
    echo "[${ln} matches across ${nfiles} files -> ${log}]"
    echo "[top files by match count:]"
    printf '%s\n' "$counts" | head -n "${QUIET_SEARCH_TOP_FILES}" | awk '{printf "  %6s  %s\n", $1, $2}'
    if [ "$nfiles" -gt "${QUIET_SEARCH_TOP_FILES}" ]; then
      echo "  … $((nfiles - QUIET_SEARCH_TOP_FILES)) more files"
    fi
    echo "[sample matches (first ${QUIET_SEARCH_SAMPLE_LINES}, lines >${QUIET_SEARCH_MAX_COLS} cols truncated):]"
    head -n "${QUIET_SEARCH_SAMPLE_LINES}" "$log" | awk -v m="${QUIET_SEARCH_MAX_COLS}" \
      '{ if (length($0)>m) print substr($0,1,m) "…(truncated, " length($0) " chars)"; else print }'
    echo "[full matches: grep -n '<pattern>' ${log} | tally by file: quiet-agg.sh ${log} '<pattern>' | narrow: re-run with -c or a specific path]"
  fi
  exit "$st"
  ;;

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
