#!/usr/bin/env bash
#
# quiet-reuse-run — executor invoked by the rewritten command (see quiet-reuse.sh).
#
#   quiet-reuse-run.sh run   <key> <command-string>   # run, cache result+meta, emit output
#   quiet-reuse-run.sh serve <key>                     # emit the cached result (cache hit)
#
# Lossless: the full result lives byte-exact at <cache>/<key>.out — a cache hit
# just `cat`s it and replays the original exit status. Both paths print the
# result to stdout exactly as the original command would.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
. "$ROOT/core/quiet-core.sh"

mode="${1:-}"; key="${2:-}"
[ -n "$mode" ] && [ -n "$key" ] || { echo "quiet-reuse-run: usage: {run|serve} <key> [cmd]" >&2; exit 2; }

dir=$(_quiet_reuse_dir)
mkdir -p "$dir" 2>/dev/null
out="$dir/$key.out"

case "$mode" in
  serve)
    touch "$out" 2>/dev/null || true   # mark recently-used so LRU eviction is accurate
    quiet_reuse_log_event "$key" "$(_quiet_reuse_canon_of "$key")" hit "$(_quiet_size "$out")" 2>/dev/null || true
    printf '[quiet-bash] reuse: served cached result (inputs unchanged; full output follows)\n' >&2
    cat -- "$out"
    exit "$(quiet_reuse_status_of "$key")"
    ;;
  run)
    cmd="${3:-}"
    sh -c "$cmd" >"$out.tmp" 2>&1; st=$?
    cap="${QUIET_REUSE_MAX_OUTPUT_BYTES:-1048576}"
    sz=$(_quiet_size "$out.tmp")
    if [ "${sz:-0}" -gt "${cap}" ] 2>/dev/null; then
      # Too large to be worth caching — emit it but don't store (bounds per-entry disk).
      cat -- "$out.tmp"; rm -f "$out.tmp" 2>/dev/null
      exit "$st"
    fi
    mv -f "$out.tmp" "$out" 2>/dev/null
    quiet_reuse_store "$key" "$cmd" "$st"
    quiet_reuse_log_event "$key" "$(_quiet_reuse_canon_of "$key")" miss "$(_quiet_size "$out")" 2>/dev/null || true
    cat -- "$out"
    exit "$st"
    ;;
  *)
    echo "quiet-reuse-run: unknown mode '$mode'" >&2; exit 2 ;;
esac
