#!/usr/bin/env bash
#
# quiet-patch — apply a unified diff atomically (check first; never partial).
# For an existing diff blob or an atomic multi-file patch. For a single small
# edit, prefer the agent's native Edit tool — this does not replace it.
#
#   quiet-patch.sh [-R] [-f patch.diff] < diff
#
# Safety: dry-run (git apply --check) first; only apply if the WHOLE patch fits;
# never --reject / --whitespace=fix. A bad diff fails loud, tree untouched.

rev=""; file=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R) rev="-R"; shift ;;
    -f) file="${2:-}"; shift 2 || { echo "quiet-patch: -f needs a file" >&2; exit 2; } ;;
    *)  echo "usage: quiet-patch.sh [-R] [-f patch.diff] < diff" >&2; exit 2 ;;
  esac
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "quiet-patch: not a git repo" >&2; exit 2; }

tmp=$(mktemp)
if [ -n "$file" ]; then
  [ -r "$file" ] || { echo "quiet-patch: cannot read $file" >&2; rm -f "$tmp"; exit 2; }
  cat "$file" > "$tmp"
else
  cat > "$tmp"
fi
[ -s "$tmp" ] || { echo "usage: quiet-patch.sh [-R] [-f patch.diff] < diff (empty input)" >&2; rm -f "$tmp"; exit 2; }

if ! err=$(git apply --check $rev "$tmp" 2>&1); then
  echo "[quiet-patch] FAIL — does not apply cleanly; no changes written: $(printf '%s' "$err" | head -1)"
  rm -f "$tmp"; exit 1
fi
stat=$(git apply --numstat $rev "$tmp" 2>/dev/null | awk '{a+=$1; d+=$2; n++} END{printf "%d file(s), +%d -%d", n, a, d}')
git apply $rev "$tmp"
echo "[quiet-patch] OK — applied $stat"
rm -f "$tmp"; exit 0
