#!/usr/bin/env bash
#
# quiet-repomap — cross-file relevance ranking so the agent orients toward the
# most-referenced code without grepping/reading its way there.
#
#   quiet-repomap.sh            # top files by import in-degree (most-depended-on first)
#
# A lightweight, zero-dependency approximation of Aider's tree-sitter+PageRank
# repo map (docs/research/cost-levers-2026-07-update.md candidate #3): instead
# of AST-parsing + graph-ranking, this greps import/require (JS/TS) and
# import/from (Python) statements, resolves each target to a repo file by
# BASENAME match (not full module resolution), and ranks files by how many
# *other* files import them — a proxy for "this is load-bearing, look here
# first." PROTOTYPE — basename matching is approximate: it will over/under-count
# in a repo with duplicate basenames across directories (e.g. two `utils.py`
# files look like one node). Complements quiet-map (file-size/churn/tree) and
# quiet-outline (per-file signatures) rather than replacing them.
#
# Env: QUIET_REPOMAP_TOP (25), QUIET_REPOMAP_MAX_FILES (3000, caps the scan on
# huge repos — deterministic prefix of `git ls-files`, not a random sample).

TOP="${QUIET_REPOMAP_TOP:-25}"
MAX_FILES="${QUIET_REPOMAP_MAX_FILES:-3000}"

_filelist0() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files -z
  else
    find . -type f -not -path './.git/*' -print0
  fi
}

srcfiles=$(_filelist0 | tr '\0' '\n' | grep -E '\.(js|jsx|ts|tsx|mjs|cjs|py)$' | head -n "$MAX_FILES")
[ -n "$srcfiles" ] || { echo "[quiet-repomap] no JS/TS/Python source files found"; exit 0; }
truncated=0
[ "$(printf '%s\n' "$srcfiles" | wc -l | tr -d ' ')" -ge "$MAX_FILES" ] && truncated=1

filelist=$(_filelist0 | tr '\0' '\n')

# One "source<TAB>target" line per import found, target normalized so dotted
# Python modules (foo.bar) and slashed JS paths (../foo/bar) both resolve the
# same way in the awk pass below (basename of the last segment).
py_re='^[[:space:]]*(from[[:space:]]+[A-Za-z_.][A-Za-z0-9_.]*[[:space:]]+import|import[[:space:]]+[A-Za-z_.][A-Za-z0-9_.]*)'
js_re="(from|require\\()[[:space:]]*['\"][^'\"]+['\"]"
imports=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    *.py)
      tgts=$(grep -nE "$py_re" "$f" 2>/dev/null | sed -E 's/^[0-9]+://' \
        | sed -E "s/^[[:space:]]*from[[:space:]]+([A-Za-z_.][A-Za-z0-9_.]*).*/\\1/; s/^[[:space:]]*import[[:space:]]+([A-Za-z_.][A-Za-z0-9_.]*).*/\\1/" \
        | tr '.' '/') ;;
    *)
      tgts=$(grep -noE "$js_re" "$f" 2>/dev/null | sed -E 's/^[0-9]+://' \
        | sed -E "s/^(from|require\\()[[:space:]]*[\"']//; s/[\"']\$//") ;;
  esac
  [ -n "$tgts" ] || continue
  while IFS= read -r tgt; do
    [ -n "$tgt" ] && imports="$imports$f	$tgt
"
  done <<EOF
$tgts
EOF
done <<EOF
$srcfiles
EOF

[ -n "$imports" ] || { echo "[quiet-repomap] no import statements found"; exit 0; }

filelist_f=$(mktemp); imports_f=$(mktemp)
trap 'rm -f "$filelist_f" "$imports_f"' EXIT
printf '%s\n' "$filelist" > "$filelist_f"
printf '%s' "$imports" > "$imports_f"

ranked=$(awk -F'\t' '
  FNR == NR {
    path = $0
    nseg = split(path, parts, "/")
    base = parts[nseg]
    sub(/\.[A-Za-z0-9]+$/, "", base)
    if (!(base in bymap)) bymap[base] = path
    next
  }
  {
    src = $1; tgt = $2
    gsub(/^\.\.?\//, "", tgt)
    m = split(tgt, tp, "/")
    tbase = tp[m]
    sub(/\.[A-Za-z0-9]+$/, "", tbase)
    if (tbase in bymap) {
      target = bymap[tbase]
      if (target != src) indeg[target]++
    }
  }
  END {
    for (f in indeg) printf "%d\t%s\n", indeg[f], f
  }
' "$filelist_f" "$imports_f" | sort -t "$(printf '\t')" -k1,1rn -k2,2 | head -n "$TOP")

[ -n "$ranked" ] || { echo "[quiet-repomap] no cross-file references resolved (all imports point outside the repo, or basenames didn't match)"; exit 0; }

echo "[quiet-repomap] most-imported files (top $TOP by in-degree — how many other files import them):"
printf '%s\n' "$ranked" | awk -F'\t' '{ printf "%6d  %s\n", $1, $2 }'
echo "[quiet-repomap] Approximate (basename-matched imports, not full module resolution) — a proxy for \"start here,\" not ground truth."
[ "$truncated" = 1 ] && echo "[quiet-repomap] scan capped at QUIET_REPOMAP_MAX_FILES=$MAX_FILES source files — ranking may be incomplete on this repo."
