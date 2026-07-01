#!/usr/bin/env bash
#
# quiet-reuse — Stage 3 "mechanical reuse" of the learning loop (sourced helper).
#
# When the SAME deterministic, read-only command recurs and its input files are
# unchanged, the result was already computed — re-running just re-spends time
# (and re-feeds the output to the agent). This helper serves a byte-exact cached
# result instead of re-running. See docs/research/learning-loop.md (§5.1).
#
# Soundness over coverage (zero wrong hits is the bar). A command is eligible
# only if ALL hold:
#   - it is a single simple command — no pipes/redirects/;/&&/||/`…`/$(…),
#   - its program is NOT denylisted (no mutation / network / clock / build /
#     test / package-manager / infra), and
#   - it references at least one EXISTING REGULAR FILE argument (so dir-, stdin-,
#     and env-dependent commands are never cached).
# Freshness is tiered: mtime+size fast path, content-hash confirm when mtime
# moved. Any changed/missing/added input → miss (re-run).
#
# Gated behind the config flag `reuse = on` (default OFF; independent of observe).
# Local, zero new dependencies (bash + jq + the hashing already used by dedup).

# Programs whose output is NOT a pure function of their file args (mutating,
# networked, clock-driven, build/test/package/infra). Override via env.
: "${QUIET_REUSE_DENY:=rm mv cp ln mkdir rmdir touch chmod chown chgrp dd tee truncate install shred \
kill pkill killall git npm yarn pnpm bun npx pip pip3 poetry uv cargo go rustc make cmake ninja gradle mvn sbt bazel \
docker podman kubectl helm terraform pulumi ansible ansible-playbook \
curl wget ssh scp rsync nc ncat telnet ping dig nslookup host \
date sleep uuidgen openssl gpg ssh-keygen \
apt apt-get yum dnf brew pacman apk \
psql mysql mongosh redis-cli systemctl journalctl reboot shutdown}"

# ── Flag (config key `reuse`) ────────────────────────────────────────────────
quiet_reuse_enabled() {
  local f val
  f=$(_quiet_obs_config_file)
  [ -n "$f" ] && [ -r "$f" ] || return 1
  val=$(sed -nE 's/^[[:space:]]*reuse[[:space:]]*=[[:space:]]*([^[:space:]#]+).*/\1/p' "$f" 2>/dev/null | tail -1)
  case "$(printf '%s' "$val" | tr 'A-Z' 'a-z')" in
    on | true | 1 | yes | enabled) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Small fs helpers (mtime comes from quiet-dedup's _quiet_mtime) ────────────
_quiet_size() { wc -c <"$1" 2>/dev/null | tr -d ' '; }
_quiet_reuse_hash_file() {
  if command -v shasum >/dev/null 2>&1; then shasum "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" 2>/dev/null | cut -d' ' -f1
  else cksum "$1" 2>/dev/null | cut -d' ' -f1; fi
}

# ── Command analysis ─────────────────────────────────────────────────────────
# First "real" program name (basename), skipping wrapper words + VAR=val.
_quiet_reuse_argv0() {
  ( set -f; set -- $1
    while [ $# -gt 0 ]; do
      case "$1" in
        command | exec | builtin | sudo | env | time | nice | nohup) shift; continue ;;
        -*) break ;;
        *=*) shift; continue ;;
        *) break ;;
      esac
    done
    [ $# -gt 0 ] || exit 0
    printf '%s' "${1##*/}" )
}

# Existing regular-file arguments (glob disabled so unexpanded globs don't count).
_quiet_reuse_inputs() {
  ( set -f
    for tok in $1; do
      case "$tok" in -*) continue ;; esac
      tok=${tok#\"}; tok=${tok%\"}; tok=${tok#\'}; tok=${tok%\'}
      [ -f "$tok" ] && printf '%s\n' "$tok"
    done )
}

quiet_reuse_eligible() {
  local cmd="$1" a0
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *'|'* | *'>'* | *'<'* | *';'* | *'&'* | *'`'* | *'$('*) return 1 ;;
  esac
  a0=$(_quiet_reuse_argv0 "$cmd")
  [ -n "$a0" ] || return 1
  case " $QUIET_REUSE_DENY " in *" $a0 "*) return 1 ;; esac
  [ "$a0" = sed ] && case " $cmd " in *' -i'*) return 1 ;; esac
  [ -n "$(_quiet_reuse_inputs "$cmd")" ] || return 1
  return 0
}

# ── Cache location & key ─────────────────────────────────────────────────────
_quiet_reuse_dir() {
  if [ -n "${QUIET_REUSE_DIR:-}" ]; then printf '%s' "$QUIET_REUSE_DIR"
  else printf '%s/reuse' "$(dirname "$(quiet_observe_ledger)")"; fi
}
# Key folds the EXACT command + cwd. It must be precise, never the normalized
# fingerprint (canon collapses literals, so `cat a.txt` and `cat b.txt` would
# share a key → a wrong hit). The coarse canon is only for observe/reporting.
_quiet_reuse_key() { _quiet_obs_hash "$1|$PWD"; }

# ── Freshness ────────────────────────────────────────────────────────────────
# 0 = every recorded input still matches; 1 = stale/missing/added.
#
# Tiered for speed, but mtime is NEVER trusted to declare an input *fresh* — a
# same-second, same-size content edit leaves mtime unchanged, so trusting it
# would serve a stale result (a wrong hit, the cardinal sin for a result cache).
# So: size is the cheap stale-filter (mismatch → stale without hashing), and a
# size match is always confirmed by content hash. Inputs here are small
# read-only files, so the hash is cheap; correctness wins over skipping it.
quiet_reuse_fresh() {
  local key="$1" meta f m s h cs
  meta="$(_quiet_reuse_dir)/$key.meta"
  [ -f "$meta" ] || return 1
  while IFS="$(printf '\t')" read -r f m s h; do
    case "$f" in '#'* | '') continue ;; esac
    [ -f "$f" ] || return 1
    cs=$(_quiet_size "$f")
    [ "$cs" = "$s" ] || return 1                               # size changed → stale (no hash)
    [ "$(_quiet_reuse_hash_file "$f")" = "$h" ] || return 1    # confirm content
  done <"$meta"
  return 0
}

# Write the meta sidecar: status + canon lines, then one tab-separated sig row
# per input. The canon is stored so a cache-hit (which only knows the key) can
# still attribute the event to a human-readable pattern.
quiet_reuse_store() {
  local key="$1" cmd="$2" status="$3" meta f
  meta="$(_quiet_reuse_dir)/$key.meta"
  { printf '#status %s\n' "$status"
    printf '#canon %s\n' "$(quiet_observe_canon "$cmd")"
    printf '#cmd %s\n' "$cmd"
    _quiet_reuse_inputs "$cmd" | while IFS= read -r f; do
      printf '%s\t%s\t%s\t%s\n' "$f" "$(_quiet_mtime "$f")" "$(_quiet_size "$f")" "$(_quiet_reuse_hash_file "$f")"
    done
  } >"$meta" 2>/dev/null || return 0
}

quiet_reuse_status_of() {
  local s; s=$(sed -n 's/^#status //p' "$(_quiet_reuse_dir)/$1.meta" 2>/dev/null | head -1)
  printf '%s' "${s:-0}"
}
_quiet_reuse_canon_of() { sed -n 's/^#canon //p' "$(_quiet_reuse_dir)/$1.meta" 2>/dev/null | head -1; }
_quiet_reuse_cmd_of() { sed -n 's/^#cmd //p' "$(_quiet_reuse_dir)/$1.meta" 2>/dev/null | head -1; }

# ── Feedback / reputation: every reuse decision is a logged event ────────────
# hit  = a cached result was served (bytes = result size that was NOT re-spent)
# miss = the command ran and populated the cache (bytes = result size produced)
# Accumulated per pattern, this is the reputation that later drives ranking,
# trust-promotion, and eviction (docs/research/learning-loop.md §13).
_quiet_reuse_events() {
  if [ -n "${QUIET_REUSE_EVENTS:-}" ]; then printf '%s' "$QUIET_REUSE_EVENTS"
  else printf '%s/reuse-events.jsonl' "$(dirname "$(quiet_observe_ledger)")"; fi
}

quiet_reuse_log_event() {
  local key="$1" canon="$2" event="$3" bytes="$4" f dir ts
  command -v jq >/dev/null 2>&1 || return 0
  f=$(_quiet_reuse_events); dir=$(dirname "$f")
  mkdir -p "$dir" 2>/dev/null || return 0
  ts=$(date +%s 2>/dev/null || echo 0)
  case "$bytes" in '' | *[!0-9]*) bytes=0 ;; esac
  jq -nc --arg key "$key" --arg canon "$canon" --arg event "$event" \
    --argjson bytes "$bytes" --argjson ts "$ts" \
    '{key:$key,canon:$canon,event:$event,bytes:$bytes,ts:$ts}' >>"$f" 2>/dev/null || return 0
  _quiet_trim_ledger "$f"
}

# Reputation per pattern: hits, misses, bytes saved (served), sorted by savings.
quiet_reuse_report() {
  local f="${1:-$(_quiet_reuse_events)}"
  [ -r "$f" ] || { printf 'quiet-reuse: no events at %s\n' "$f"; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'quiet-reuse: jq required\n'; return 0; }
  jq -s '
    group_by(.canon)
    | map({canon:.[0].canon,
           hits:(map(select(.event=="hit"))|length),
           miss:(map(select(.event=="miss"))|length),
           drift:(map(select(.event=="drift"))|length),
           saved:([.[]|select(.event=="hit")|.bytes]|add // 0)})
    | sort_by(-.saved, -.hits)' "$f" 2>/dev/null \
    | jq -r '.[] | "\(.hits)\t\(.miss)\t\(.drift)\t\(.saved)\t\(.canon)"' 2>/dev/null \
    | awk -F'\t' '
        BEGIN{ printf "%5s %5s %6s %11s  %s\n","hits","miss","drift","saved-B","pattern" }
        { printf "%5d %5d %6d %11d  %s\n",$1,$2,$3,$4,$5 }'
}

quiet_reuse_status() {
  local dir n bytes
  dir=$(_quiet_reuse_dir)
  if quiet_reuse_enabled; then printf 'reuse:  ENABLED\n'; else printf 'reuse:  disabled\n'; fi
  printf 'config: %s\n' "$(_quiet_obs_config_file)"
  printf 'cache:  %s\n' "$dir"
  printf 'events: %s\n' "$(_quiet_reuse_events)"
  if [ -d "$dir" ]; then
    n=$(find "$dir" -maxdepth 1 -type f -name '*.out' 2>/dev/null | wc -l | tr -d ' ')
    bytes=$(find "$dir" -maxdepth 1 -type f -name '*.out' -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
    printf 'entries: %s / cap %s\n' "${n:-0}" "${QUIET_REUSE_MAX_ENTRIES:-500}"
    printf 'bytes:   %s\n' "${bytes:-0}"
  fi
}

# ── Disk control: TTL + LRU eviction ─────────────────────────────────────────
# TTL drops entries whose cached output is older than QUIET_REUSE_TTL_MINUTES;
# LRU drops the least-recently-used (by .out mtime; a hit `touch`es it) until at
# most QUIET_REUSE_MAX_ENTRIES remain. Prints a one-line summary.
quiet_reuse_gc() {
  local dir ttl max n removed=0 over i=0 f
  dir=$(_quiet_reuse_dir)
  [ -d "$dir" ] || { printf 'quiet-reuse gc: no cache (%s)\n' "$dir"; return 0; }
  ttl="${QUIET_REUSE_TTL_MINUTES:-20160}"
  max="${QUIET_REUSE_MAX_ENTRIES:-500}"
  if [ "${ttl:-0}" -gt 0 ] 2>/dev/null; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rm -f "$f" "${f%.out}.meta" 2>/dev/null && removed=$((removed + 1))
    done <<EOF
$(find "$dir" -maxdepth 1 -type f -name '*.out' -mmin "+$ttl" 2>/dev/null)
EOF
  fi
  n=$(find "$dir" -maxdepth 1 -type f -name '*.out' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n:-0}" -gt "${max:-500}" ] 2>/dev/null; then
    over=$((n - max))
    while IFS= read -r f; do
      [ "$i" -lt "$over" ] || break
      [ -n "$f" ] || continue
      rm -f "$f" "${f%.out}.meta" 2>/dev/null && { removed=$((removed + 1)); i=$((i + 1)); }
    done <<EOF
$(ls -tr "$dir"/*.out 2>/dev/null)
EOF
  fi
  printf 'quiet-reuse gc: evicted %s (cap=%s, ttl=%smin)\n' "$removed" "$max" "$ttl"
}

# Opportunistic, throttled GC so the cache stays bounded without a cron job.
_quiet_reuse_gc_throttled() {
  local dir stamp iv="${QUIET_REUSE_GC_INTERVAL_MINUTES:-60}"
  dir=$(_quiet_reuse_dir); [ -d "$dir" ] || return 0
  stamp="$dir/.gc-stamp"
  [ -e "$stamp" ] && [ -z "$(find "$stamp" -mmin "+$iv" 2>/dev/null)" ] && return 0
  : >"$stamp" 2>/dev/null || true
  quiet_reuse_gc >/dev/null 2>&1 || true
}

# ── Single-quote a string for safe embedding in a rewritten command ──────────
_quiet_reuse_shquote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ── Decision: print a rewritten command (serve | run+cache), or return 1 ─────
quiet_reuse_rewrite() {
  quiet_reuse_enabled || return 1
  local cmd="$1" key dir runner
  _quiet_reuse_gc_throttled
  quiet_reuse_eligible "$cmd" || return 1
  key=$(_quiet_reuse_key "$cmd")
  dir=$(_quiet_reuse_dir)
  runner="$QUIET_CORE_DIR/quiet-reuse-run.sh"
  if [ -f "$dir/$key.out" ] && quiet_reuse_fresh "$key"; then
    printf '%s serve %s' "$(_quiet_reuse_shquote "$runner")" "$key"
  else
    printf '%s run %s %s' "$(_quiet_reuse_shquote "$runner")" "$key" "$(_quiet_reuse_shquote "$cmd")"
  fi
  return 0
}

# ── CLI (only when executed directly). This file depends on helpers from
# quiet-core, so the CLI sources it; a sentinel prevents the re-source from
# re-triggering this block (which would recurse). ────────────────────────────
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ] && [ -z "${_QUIET_REUSE_CLI:-}" ]; then
  _QUIET_REUSE_CLI=1
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/core/quiet-core.sh"
  case "${1:-help}" in
    report) shift; quiet_reuse_report "$@" ;;
    status) quiet_reuse_status ;;
    gc) quiet_reuse_gc ;;
    *) printf 'quiet-reuse — stage-3 mechanical reuse\n\n'
       printf 'usage: quiet-reuse <command>\n'
       printf '  report   reuse hits / misses / bytes-saved per pattern\n'
       printf '  status   enabled/config/cache/events + entry & byte counts\n'
       printf '  gc       evict by TTL + LRU to keep the cache bounded\n' ;;
  esac
fi
