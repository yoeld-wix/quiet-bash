#!/usr/bin/env bash
#
# quiet-applies — does this unified diff apply cleanly? (read-only git apply --check)
# Use instead of reasoning over two file versions to decide if a patch fits.
#
#   quiet-applies.sh [-R] [-f patch.diff] < diff

rev=""; file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R) rev="-R"; shift ;;
    -f) file="${2:-}"; shift 2 || { echo "quiet-applies: -f needs a file" >&2; exit 2; } ;;
    *)  echo "usage: quiet-applies.sh [-R] [-f patch.diff] < diff" >&2; exit 2 ;;
  esac
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "quiet-applies: not a git repo" >&2; exit 2; }

tmp=$(mktemp)
if [ -n "$file" ]; then
  [ -r "$file" ] || { echo "quiet-applies: cannot read $file" >&2; rm -f "$tmp"; exit 2; }
  cat "$file" > "$tmp"
else
  cat > "$tmp"
fi
[ -s "$tmp" ] || { echo "usage: quiet-applies.sh [-R] [-f patch.diff] < diff (empty input)" >&2; rm -f "$tmp"; exit 2; }

if err=$(git apply --check $rev "$tmp" 2>&1); then
  stat=$(git apply --numstat $rev "$tmp" 2>/dev/null | awk '{a+=$1; d+=$2; n++} END{printf "%d file(s), +%d -%d", n, a, d}')
  echo "[quiet-applies] APPLIES — $stat"
  rm -f "$tmp"; exit 0
else
  echo "[quiet-applies] CONFLICT — $(printf '%s' "$err" | head -1)"
  rm -f "$tmp"; exit 1
fi
