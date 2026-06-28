#!/usr/bin/env bash
#
# quiet-blame — who/when for a line range, without reading the whole file.
#
#   quiet-blame.sh <file> <start> <end>

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "quiet-blame: not a git repo" >&2; exit 2; }

file="${1:-}"; start="${2:-}"; end="${3:-}"
{ [ -n "$file" ] && [ -n "$start" ] && [ -n "$end" ]; } \
  || { echo "usage: quiet-blame.sh <file> <start> <end>" >&2; exit 2; }
case "$start" in ''|*[!0-9]*) echo "quiet-blame: start/end must be integers" >&2; exit 2 ;; esac
case "$end" in ''|*[!0-9]*) echo "quiet-blame: start/end must be integers" >&2; exit 2 ;; esac

git blame -L "$start,$end" --date=short -- "$file"
