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
