#!/usr/bin/env bash
#
# quiet-agg — frequency table over regex matches in a file, without reading it.
#
#   quiet-agg.sh <file> <regex> [n=20]
#
# Extracts every match of <regex> (ERE, via grep -oE), then counts and ranks
# them descending — the deterministic form of "read it and tally by eye".
#
#   quiet-agg.sh app.log 'E[0-9]+'              # top error codes
#   quiet-agg.sh access.log '[0-9]{3}' 5        # top 5 HTTP statuses

file="${1:-}"; re="${2:-}"; n="${3:-20}"
[ -n "$file" ] && [ -n "$re" ] || { echo "usage: quiet-agg.sh <file> <regex> [n=20]" >&2; exit 2; }
[ -r "$file" ] || { echo "quiet-agg: cannot read $file" >&2; exit 2; }

case "$n" in ''|*[!0-9]*) echo "quiet-agg: n must be a positive integer" >&2; exit 2 ;; esac
[ "$n" -ge 1 ] || { echo "quiet-agg: n must be a positive integer" >&2; exit 2; }

printf '' | grep -E -- "$re" >/dev/null 2>&1; rc=$?
if [ "$rc" -ge 2 ]; then echo "quiet-agg: invalid regex" >&2; exit 2; fi

table=$(grep -oE -- "$re" "$file" 2>/dev/null | sort | uniq -c | sort -rn | head -n "$n")
if [ -z "$table" ]; then
  echo "[quiet-agg] no matches for /$re/ in $file"
  exit 0
fi
echo "[quiet-agg] top $n of /$re/ in $file:"
printf '%s\n' "$table"
