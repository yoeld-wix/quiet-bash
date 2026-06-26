#!/usr/bin/env bash
#
# quiet-verify — verify a fact against a file without reading it into context.
#
#   quiet-verify.sh <file> <pattern>
#
# Counts lines matching <pattern> (an ERE). Prints OK + count and exits 0 when
# there is at least one match; prints FAIL and exits 1 when there are none.
# Use instead of reading a log/output to confirm something happened.
#
#   quiet-verify.sh build.log 'BUILD SUCCESS'
#   quiet-verify.sh test.out  'FAIL|Error'

file="${1:-}"; pat="${2:-}"
[ -n "$file" ] && [ -n "$pat" ] || { echo "usage: quiet-verify.sh <file> <pattern>" >&2; exit 2; }
[ -r "$file" ] || { echo "quiet-verify: cannot read $file" >&2; exit 2; }

n=$(grep -Ec -- "$pat" "$file" 2>/dev/null || true); n=${n:-0}
if [ "$n" -gt 0 ]; then
  echo "[quiet-verify] OK — $n line(s) match /$pat/ in $file"
  exit 0
else
  echo "[quiet-verify] FAIL — no lines match /$pat/ in $file"
  exit 1
fi
