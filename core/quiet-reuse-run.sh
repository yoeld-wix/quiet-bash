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
    canon=$(_quiet_reuse_canon_of "$key")
    touch "$out" 2>/dev/null || true   # mark recently-used so LRU eviction is accurate
    # Shadow-verify every Nth hit: re-run the command and compare to the cached
    # result. Catches drift that input-freshness can't (untracked deps). On a
    # mismatch, RETIRE the entry and serve the FRESH output — fail safe.
    every="${QUIET_REUSE_VERIFY_EVERY:-50}"
    hitsf="$dir/$key.hits"
    n=$(cat "$hitsf" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$hitsf" 2>/dev/null
    if [ "${every:-0}" -gt 0 ] 2>/dev/null && [ $((n % every)) -eq 0 ]; then
      vcmd=$(_quiet_reuse_cmd_of "$key")
      sh -c "$vcmd" >"$out.verify" 2>&1; vst=$?
      if cmp -s "$out.verify" "$out"; then
        rm -f "$out.verify" 2>/dev/null
        quiet_reuse_log_event "$key" "$canon" verify "$(_quiet_size "$out")" 2>/dev/null || true
        printf '[quiet-bash] reuse: cached result re-verified (still matches)\n' >&2
        cat -- "$out"; exit "$(quiet_reuse_status_of "$key")"
      else
        quiet_reuse_log_event "$key" "$canon" drift "$(_quiet_size "$out.verify")" 2>/dev/null || true
        printf '[quiet-bash] reuse: DRIFT — cached result no longer matches; retiring entry, serving fresh output\n' >&2
        cat -- "$out.verify"
        rm -f "$out" "$dir/$key.meta" "$hitsf" "$out.verify" 2>/dev/null   # retire (fail safe)
        exit "$vst"
      fi
    fi
    quiet_reuse_log_event "$key" "$canon" hit "$(_quiet_size "$out")" 2>/dev/null || true
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
