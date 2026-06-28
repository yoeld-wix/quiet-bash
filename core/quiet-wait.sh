#!/usr/bin/env bash
#
# quiet-wait — block until a shell condition holds, printing only the terminal
# state once (instead of polling across many agent turns).
#
#   quiet-wait.sh <condition> [--timeout SECS] [--interval SECS]
#
# <condition> is any shell expression (run via sh -c); success = exit 0.
# Defaults: --timeout 60, --interval 2. Exit 0 = met, 1 = timed out, 2 = usage.
#
#   quiet-wait.sh 'test -f /tmp/done' --timeout 120
#   quiet-wait.sh 'curl -sf localhost:8080/health' --interval 3

cond="${1:-}"
[ -n "$cond" ] || { echo "usage: quiet-wait.sh <condition> [--timeout SECS] [--interval SECS]" >&2; exit 2; }
shift
timeout=60; interval=2
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) timeout="${2:-}"; shift 2 || { echo "quiet-wait: --timeout needs a value" >&2; exit 2; } ;;
    --interval) interval="${2:-}"; shift 2 || { echo "quiet-wait: --interval needs a value" >&2; exit 2; } ;;
    *) echo "quiet-wait: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
case "$timeout" in ''|*[!0-9]*) echo "quiet-wait: --timeout must be a positive integer" >&2; exit 2 ;; esac
case "$interval" in ''|*[!0-9]*) echo "quiet-wait: --interval must be a positive integer" >&2; exit 2 ;; esac
[ "$interval" -ge 1 ] || interval=1
[ "$timeout" -le 3600 ] || timeout=3600

start=$(date +%s); tries=0
while :; do
  tries=$((tries + 1))
  if sh -c "$cond" >/dev/null 2>&1; then
    echo "[quiet-wait] condition met after $tries tries / $(( $(date +%s) - start ))s"
    exit 0
  fi
  if [ "$(( $(date +%s) - start ))" -ge "$timeout" ]; then
    echo "[quiet-wait] TIMEOUT after $(( $(date +%s) - start ))s ($tries tries) — condition never met"
    exit 1
  fi
  sleep "$interval"
done
