#!/usr/bin/env bash
#
# quiet-map — deterministic folder map so the agent orients without exploring +
# reading files. Read-only; it points at files, never replaces reading them.
#
#   quiet-map.sh            # largest files by line count + ⚠ "too big to Read whole"
#   quiet-map.sh --churn    # most-changed files (git) — where the live code is
#   quiet-map.sh --tree     # files per top-level directory
#
# Env: QUIET_MAP_TOP (25), QUIET_MAP_BIG_LINES (800), QUIET_MAP_CHURN_COMMITS (500).

TOP="${QUIET_MAP_TOP:-25}"
BIG="${QUIET_MAP_BIG_LINES:-800}"
CHURN_N="${QUIET_MAP_CHURN_COMMITS:-500}"

_filelist0() { # NUL-delimited, gitignore-aware in a repo
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -z
  else
    find . -type f -not -path './.git/*' -print0
  fi
}

mode="${1:-}"
case "$mode" in
  "" )
    out=$(_filelist0 | xargs -0 grep -Il . 2>/dev/null | tr '\n' '\0' | xargs -0 wc -l 2>/dev/null \
      | awk '{c=$1; $1=""; sub(/^[ \t]+/,""); if ($0!="total" && $0!="") print c"\t"$0}' \
      | sort -rn | head -n "$TOP")
    [ -n "$out" ] || { echo "[quiet-map] no text files found"; exit 0; }
    echo "[quiet-map] largest files by line count (top $TOP; ⚠ = >$BIG lines → prefer quiet-outline / Read with offset):"
    printf '%s\n' "$out" | awk -F'\t' -v big="$BIG" '{ f=($1>big)?" ⚠":""; printf "%8d  %s%s\n",$1,$2,f }'
    ;;
  --churn )
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "quiet-map: --churn needs a git repo" >&2; exit 2; }
    echo "[quiet-map] most-changed files (last $CHURN_N commits):"
    git log --format= --name-only -n "$CHURN_N" 2>/dev/null | sed '/^$/d' | sort | uniq -c | sort -rn | head -n "$TOP"
    ;;
  --tree )
    echo "[quiet-map] files per top-level dir:"
    _filelist0 | tr '\0' '\n' | awk -F/ '{ d=(NF>1)?$1"/":"(root)"; c[d]++ } END { for (k in c) printf "%6d  %s\n", c[k], k }' | sort -rn
    ;;
  * )
    echo "usage: quiet-map.sh [--churn|--tree]" >&2; exit 2 ;;
esac
