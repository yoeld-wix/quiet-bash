#!/usr/bin/env bash
#
# quiet-tail — print a cleaned, bounded tail of a log file for surfacing on
# failure. The log on disk is NEVER modified; only the surfaced preview shrinks.
#
#   quiet-tail.sh <logfile> [maxlines]
#
# Three lossless transforms reduce the noise that build/test tools emit:
#   1. strip ANSI/SGR escape sequences (colors, cursor moves)
#   2. collapse carriage-return progress bars to their final state (keep the
#      text after the last \r on a line)
#   3. fold runs of identical consecutive lines into "<line>  (xN)"
#
# Cleaning is applied to a generous tail window, then the result is tailed to
# maxlines — so the budget counts *cleaned* lines, and the work stays bounded
# even for a huge log. Callers fall back to plain `tail` if this script is
# unavailable, so failure display can never break.

log="${1:?usage: quiet-tail.sh <logfile> [maxlines]}"
max="${2:-40}"
[ -f "$log" ] || exit 0
case "$max" in ''|*[!0-9]*) max=40 ;; esac

window=$(( max * 5 ))

tail -n "$window" "$log" 2>/dev/null | awk '
function clean(s,   n, p) {
  n = split(s, p, "\r"); s = p[n]                 # keep text after the last CR
  gsub(/\033\[[0-9;?]*[ -\/]*[@-~]/, "", s)       # strip CSI/SGR escapes
  return s
}
{
  cur = clean($0)
  if (NR > 1 && cur == prev) { cnt++; next }
  if (NR > 1) { if (cnt > 1) printf "%s  (x%d)\n", prev, cnt; else print prev }
  prev = cur; cnt = 1
}
END { if (NR > 0) { if (cnt > 1) printf "%s  (x%d)\n", prev, cnt; else print prev } }
' | tail -n "$max"
