#!/usr/bin/env bash
#
# quiet-hist — recent commits touching a path, or pickaxe for a string,
# without scrolling a full `git log` dump.
#
#   quiet-hist.sh <path> [-n N]          # last N (default 15) commits for a path
#   quiet-hist.sh --pick <string> [path] # commits that added/removed <string>

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "quiet-hist: not a git repo" >&2; exit 2; }

if [ "${1:-}" = "--pick" ]; then
  str="${2:-}"; [ -n "$str" ] || { echo "usage: quiet-hist.sh --pick <string> [path]" >&2; exit 2; }
  if [ -n "${3:-}" ]; then git log --oneline -S "$str" -- "$3"; else git log --oneline -S "$str"; fi
  exit $?
fi

path="${1:-}"; [ -n "$path" ] || { echo "usage: quiet-hist.sh <path> [-n N]" >&2; exit 2; }
n=15
if [ "${2:-}" = "-n" ]; then
  n="${3:-15}"
  case "$n" in ''|*[!0-9]*) echo "quiet-hist: -n must be a positive integer" >&2; exit 2 ;; esac
fi
out=$(git log -n "$n" --date=short --format='%h %ad %s' -- "$path" 2>/dev/null)
[ -n "$out" ] || { echo "[quiet-hist] no commits touch $path"; exit 0; }
printf '%s\n' "$out"
