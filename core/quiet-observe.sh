#!/usr/bin/env bash
#
# quiet-observe — Stage 1 "observe-only" of the learning loop (sourced helper).
#
# Records, per Bash command, a normalized *fingerprint* + a cheap cost proxy to a
# local append-only JSONL ledger, so recurring expensive work can be ranked
# (recurrence x cost) later. It NEVER rewrites a command or touches the
# transcript — pure measurement, off the hot path. See docs/research/learning-loop.md.
#
# Gated behind a config-file toggle (default OFF): the key `observe = on` in the
# config file (see _quiet_obs_config_file). Local-first, zero new dependencies
# (bash + jq, same as the rest of quiet-bash).
#
#   . core/quiet-observe.sh
#   quiet_observe_record "<cmd>" "<wrapped 0|1>" "<bytes>"   # no-op unless enabled
#   quiet_observe_report [ledger]                            # local ranking
#
# Recovery: the ledger is plain JSONL — inspect with `jq` / `quiet_observe_report`.

# ── Config-file flag resolution ──────────────────────────────────────────────
# Precedence: $QUIET_CONFIG_FILE → repo-local ./.quiet-bash.conf → XDG config.
_quiet_obs_config_file() {
  if [ -n "${QUIET_CONFIG_FILE:-}" ]; then printf '%s' "$QUIET_CONFIG_FILE"; return; fi
  if [ -f "./.quiet-bash.conf" ]; then printf '%s' "./.quiet-bash.conf"; return; fi
  printf '%s/quiet-bash/config' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# quiet_observe_enabled — return 0 iff the config file sets `observe` to a truthy value.
quiet_observe_enabled() {
  local f val
  f=$(_quiet_obs_config_file)
  [ -n "$f" ] && [ -r "$f" ] || return 1
  val=$(sed -nE 's/^[[:space:]]*observe[[:space:]]*=[[:space:]]*([^[:space:]#]+).*/\1/p' "$f" 2>/dev/null | tail -1)
  case "$(printf '%s' "$val" | tr 'A-Z' 'a-z')" in
    on | true | 1 | yes | enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Ledger size bound (keeps append-only JSONL — and the jq -s that reads it —
# from growing without limit). When a ledger exceeds QUIET_LEDGER_MAX_BYTES it is
# truncated to its last QUIET_LEDGER_KEEP_LINES rows. Shared by observe + reuse.
_quiet_trim_ledger() {
  local f="$1" max="${QUIET_LEDGER_MAX_BYTES:-5242880}" keep="${QUIET_LEDGER_KEEP_LINES:-2000}" sz tmp
  [ -f "$f" ] || return 0
  sz=$(wc -c <"$f" 2>/dev/null | tr -d ' '); sz=${sz:-0}
  [ "$sz" -gt "$max" ] 2>/dev/null || return 0
  tmp="$f.trim.$$"
  tail -n "$keep" "$f" >"$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
}

# ── Ledger location (persistent, local, per-repo by default) ──────────────────
quiet_observe_ledger() {
  if [ -n "${QUIET_OBSERVE_LEDGER:-}" ]; then printf '%s' "$QUIET_OBSERVE_LEDGER"; return; fi
  local root
  if root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ]; then
    printf '%s/.quiet-cache/observe.jsonl' "$root"; return
  fi
  printf '%s/quiet-bash/observe.jsonl' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

# ── Fingerprinting ───────────────────────────────────────────────────────────
# Normalize a shell command to a stable "shape": basename argv0, keep flag names
# (drop their values), collapse literals (strings/URLs/numbers/hashes/paths) to
# typed placeholders. Same shape -> same fingerprint -> recurrence is visible.
# (The fingerprint is for ranking only; it is never used to serve a result.)
quiet_observe_canon() {
  local s="$1"
  # Quoted strings → <STR> (do this first so embedded spaces don't split tokens).
  s=$(printf '%s' "$s" | sed -E "s/'[^']*'/<STR>/g; s/\"[^\"]*\"/<STR>/g")
  # URLs → <URL>.
  s=$(printf '%s' "$s" | sed -E 's#https?://[^ ]+#<URL>#g')
  printf '%s' "$s" | awk '
  {
    # Skip leading wrapper tokens + VAR=val assignments so e.g. "command npm test"
    # and "env FOO=1 npm test" cluster with a bare "npm test".
    start=1
    while (start<=NF){
      w=$start
      if (w=="command"||w=="exec"||w=="builtin"||w=="sudo"||w=="env"||w=="time"||w=="nice"||w=="nohup"){ start++; continue }
      if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/){ start++; continue }
      break
    }
    out=""
    for (i=start;i<=NF;i++){
      t=$i
      if (i==start){ n=split(t,a,"/"); out=a[n]; continue }    # basename argv0
      if (t ~ /^-/){ sub(/=.*/,"=<V>",t) }                    # flag: keep name, mask value
      else if (t=="<STR>" || t=="<URL>" || t=="<PATH>" || t=="<NUM>" || t=="<HASH>"){ }
      else if (t ~ /^[0-9]+([.][0-9]+)?$/){ t="<NUM>" }
      else if (t ~ /^[0-9a-f]{7,}$/){ t="<HASH>" }
      else if (t ~ /\// || t ~ /\.[A-Za-z0-9]+$/){ t="<PATH>" }
      out=out" "t
    }
    print out
  }'
}

_quiet_obs_hash() {
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum | cut -c1-12
  elif command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | cut -c1-12
  else printf '%s' "$1" | cksum | tr -d ' ' | cut -c1-12; fi
}

quiet_observe_fingerprint() {
  _quiet_obs_hash "$(quiet_observe_canon "$1")"
}

# ── Recording ────────────────────────────────────────────────────────────────
# quiet_observe_record <cmd> [wrapped 0|1] [bytes]
#   Appends one JSONL row when enabled; a fast no-op otherwise. Never fails the
#   caller (always returns 0) and never writes to stdout — it must be safe to
#   call from inside a hook whose stdout is reserved for the hook protocol.
quiet_observe_record() {
  quiet_observe_enabled || return 0
  local cmd="${1:-}" wrapped="${2:-0}" bytes="${3:-0}" canon fp ledger dir ts repo wb
  [ -n "$cmd" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  canon=$(quiet_observe_canon "$cmd") || return 0
  fp=$(_quiet_obs_hash "$canon")
  ledger=$(quiet_observe_ledger)
  dir=$(dirname "$ledger")
  mkdir -p "$dir" 2>/dev/null || return 0
  ts=$(date +%s 2>/dev/null || echo 0)
  repo=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null)
  case "$wrapped" in 1 | true) wb=true ;; *) wb=false ;; esac
  case "$bytes" in '' | *[!0-9]*) bytes=0 ;; esac
  jq -nc \
    --arg fp "$fp" --arg canon "$canon" --arg cmd "$cmd" \
    --argjson bytes "$bytes" --argjson wrapped "$wb" \
    --argjson ts "$ts" --arg repo "$repo" \
    '{fp:$fp,canon:$canon,cmd:$cmd,bytes:$bytes,wrapped:$wrapped,ts:$ts,repo:$repo}' \
    >>"$ledger" 2>/dev/null || return 0
  _quiet_trim_ledger "$ledger"
  return 0
}

# ── Local report (recurrence x cost ranking) ─────────────────────────────────
quiet_observe_report() {
  local ledger="${1:-$(quiet_observe_ledger)}"
  [ -r "$ledger" ] || { printf 'quiet-observe: no ledger at %s\n' "$ledger"; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'quiet-observe: jq required for report\n'; return 0; }
  jq -s '
    group_by(.fp)
    | map({fp:.[0].fp, canon:.[0].canon, n:length,
           bytes:(map(.bytes)//[]|add), wrapped:(map(select(.wrapped))|length)})
    | sort_by(-.n, -.bytes)' "$ledger" 2>/dev/null \
    | jq -r '.[] | "\(.n)\t\(.wrapped)\t\(.bytes)\t\(.canon)"' 2>/dev/null \
    | awk -F'\t' '
        BEGIN{ printf "%5s %5s %10s  %s\n","uses","wrap","bytes","pattern" }
        { printf "%5d %5d %10d  %s\n",$1,$2,$3,$4 }'
}

# quiet_observe_status — human-readable: on/off, which config, ledger, row count.
quiet_observe_status() {
  local ledger rows
  ledger=$(quiet_observe_ledger)
  if quiet_observe_enabled; then printf 'observe: ENABLED\n'; else printf 'observe: disabled\n'; fi
  printf 'config:  %s\n' "$(_quiet_obs_config_file)"
  printf 'ledger:  %s\n' "$ledger"
  if [ -r "$ledger" ]; then
    rows=$(wc -l <"$ledger" 2>/dev/null | tr -d ' ')
    printf 'rows:    %s\n' "${rows:-0}"
  else
    printf 'rows:    0 (no ledger yet)\n'
  fi
}

# ── CLI (only when executed directly, not when sourced) ──────────────────────
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  case "${1:-help}" in
    report) shift; quiet_observe_report "$@" ;;
    status) quiet_observe_status ;;
    fp | fingerprint) shift; quiet_observe_fingerprint "$*" ;;
    canon) shift; quiet_observe_canon "$*" ;;
    *) printf 'quiet-observe — stage-1 observe-only ledger\n\n'
       printf 'usage: quiet-observe <command>\n'
       printf '  report          rank recurring commands by uses x cost\n'
       printf '  status          show enabled/config/ledger/row-count\n'
       printf '  fp   <cmd>      print the fingerprint of a command\n'
       printf '  canon <cmd>     print the normalized shape of a command\n' ;;
  esac
fi
