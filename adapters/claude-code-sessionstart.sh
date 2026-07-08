#!/usr/bin/env bash
#
# Claude Code adapter — SessionStart hook. Auto-surfaces quiet-repomap's
# cross-file relevance ranking AND a compact project brief (branch, recent
# commits, recently changed files) as orientation context at session start.
#
# Wired with matcher "startup|clear".

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"
cd "$cwd" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
head_sha=$(git rev-parse HEAD 2>/dev/null) || exit 0

# ── Repomap (unchanged) ──────────────────────────────────────────────────────
cache_dir="${QUIET_LOG_DIR:-${TMPDIR:-/tmp}}/quiet-repomap-cache"
mkdir -p "$cache_dir" 2>/dev/null
repo_key=$(printf '%s' "$cwd" | cksum | awk '{print $1}')
cache_file="$cache_dir/${repo_key}-${head_sha}.txt"

if [ -f "$cache_file" ]; then
  repomap_out=$(cat "$cache_file")
else
  repomap_out=$("$ROOT/core/quiet-repomap.sh" 2>/dev/null)
  printf '%s' "$repomap_out" > "$cache_file"
  find "$cache_dir" -maxdepth 1 -name "${repo_key}-*.txt" ! -name "$(basename "$cache_file")" -delete 2>/dev/null
fi

repomap_block=""
case "$repomap_out" in
  *"most-imported files"*) repomap_block="$repomap_out" ;;
esac

# ── Project brief (new) ──────────────────────────────────────────────────────
brief_branch=$(git branch --show-current 2>/dev/null)
brief_log=$(git log --oneline -5 2>/dev/null)
brief_changed=$(git diff --stat HEAD~1 HEAD 2>/dev/null | tail -1)

brief_block=""
if [ -n "$brief_branch" ] && [ -n "$brief_log" ]; then
  brief_block="[Project brief — branch: ${brief_branch}]
Recent commits:
${brief_log}
Last commit change summary: ${brief_changed:-n/a}"
fi

# ── Combine and emit ─────────────────────────────────────────────────────────
ctx=""
[ -n "$repomap_block" ] && ctx="$repomap_block"
if [ -n "$brief_block" ]; then
  [ -n "$ctx" ] && ctx="${ctx}

"
  ctx="${ctx}${brief_block}"
fi

[ -n "$ctx" ] || exit 0
jq -n --arg ctx "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
