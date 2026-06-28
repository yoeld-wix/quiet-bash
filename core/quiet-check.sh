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
case "$QUIET_CHECK_FIRST_K" in ''|*[!0-9]*) echo "quiet-check: QUIET_CHECK_FIRST_K must be a positive integer" >&2; exit 2 ;; esac

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
