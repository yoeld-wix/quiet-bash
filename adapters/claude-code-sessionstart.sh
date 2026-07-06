#!/usr/bin/env bash
#
# Claude Code adapter — SessionStart hook. Auto-surfaces quiet-repomap's
# cross-file relevance ranking as orientation context at session start,
# mirroring how the live A/B (bench/repomap-orient.sh) actually tested it:
# pre-surfaced, not something the agent has to discover and choose to run.
#
# Wired with matcher "startup|clear" — a resumed/compacted session already has
# this in its transcript, so re-injecting there would just be dead weight.
#
# Cost/speed: the scan itself is O(source files) grep+awk, capped by
# QUIET_REPOMAP_MAX_FILES; a disk cache keyed by repo path + git HEAD means
# repeat session starts on the same commit are a cache read, not a rescan —
# only a new commit (or a fresh checkout/HEAD move) triggers recomputation.
# Silent no-op (exit 0, no output) outside a git repo, or when nothing useful
# resolves (non-JS/Python repos, no cross-file imports) — never blocks or
# slows down session start with a "nothing found" message.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"
cd "$cwd" 2>/dev/null || exit 0

command -v jq >/dev/null 2>&1 || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
head_sha=$(git rev-parse HEAD 2>/dev/null) || exit 0

cache_dir="${QUIET_LOG_DIR:-${TMPDIR:-/tmp}}/quiet-repomap-cache"
mkdir -p "$cache_dir" 2>/dev/null
repo_key=$(printf '%s' "$cwd" | cksum | awk '{print $1}')
cache_file="$cache_dir/${repo_key}-${head_sha}.txt"

if [ -f "$cache_file" ]; then
  out=$(cat "$cache_file")
else
  out=$("$ROOT/core/quiet-repomap.sh" 2>/dev/null)
  printf '%s' "$out" > "$cache_file"
  # Prune this repo's stale entries (old HEADs) so the cache dir doesn't grow forever.
  find "$cache_dir" -maxdepth 1 -name "${repo_key}-*.txt" ! -name "$(basename "$cache_file")" -delete 2>/dev/null
fi

# Only inject when there's an actual ranking — not a "nothing found" filler.
case "$out" in
  *"most-imported files"*) ;;
  *) exit 0 ;;
esac

jq -n --arg ctx "$out" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
