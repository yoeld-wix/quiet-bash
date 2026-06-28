#!/usr/bin/env bash
#
# quiet-conf — resolve ONE config value without reading the whole file.
#
#   quiet-conf.sh <file> <key>
#
# JSON/YAML: <key> is a jq path (leading '.' optional), e.g. '.scripts.test' or
# 'dependencies.react'. Other files (.env, *.conf, extensionless): <key> is a
# variable name; the value of the first `KEY=…` line is printed (one layer of
# matching quotes stripped). Prints the raw value; exit 1 if not found, 2 on usage.

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$ROOT/quiet-core.sh"

file="${1:-}"; key="${2:-}"
[ -n "$file" ] && [ -n "$key" ] || { echo "usage: quiet-conf.sh <file> <key>" >&2; exit 2; }
[ -r "$file" ] || { echo "quiet-conf: cannot read $file" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "quiet-conf: jq required" >&2; exit 2; }

case "$file" in
  *.json | *.yaml | *.yml)
    json=$(quiet_to_json "$file") || { echo "quiet-conf: cannot parse $file" >&2; exit 2; }
    case "$key" in .*) path="$key" ;; *) path=".$key" ;; esac
    t=$(printf '%s' "$json" | jq -r "($path) | type" 2>/dev/null) \
      || { echo "quiet-conf: bad key path: $key" >&2; exit 2; }
    { [ -n "$t" ] && [ "$t" != "null" ]; } || { echo "quiet-conf: key not found: $key" >&2; exit 1; }
    if [ "$t" = "object" ] || [ "$t" = "array" ]; then
      val=$(printf '%s' "$json" | jq -c "$path" 2>/dev/null)
    else
      val=$(printf '%s' "$json" | jq -r "$path | tostring" 2>/dev/null)
    fi
    printf '%s\n' "$val" ;;
  *)
    esc=$(printf '%s' "$key" | sed 's/[][(){}.^$*+?|\\]/\\&/g')
    line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${esc}=" "$file" 2>/dev/null | head -1)
    [ -n "$line" ] || { echo "quiet-conf: key not found: $key" >&2; exit 1; }
    val=${line#*=}
    val=${val%$'\r'}   # tolerate CRLF-authored .env files
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    printf '%s\n' "$val" ;;
esac
