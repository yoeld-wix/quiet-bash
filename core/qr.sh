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

*)
  echo "qr: unknown mode '$mode'" >&2
  exit 2
  ;;
esac
