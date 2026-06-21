#!/usr/bin/env bash
#
# quiet-json — summarize a large JSON/YAML file instead of dumping it.
#
#   quiet-json.sh <file.json|file.yaml|file.yml>
#
# Emits a collapsed preview: objects/arrays with many entries show a few samples
# plus a "N more of M, same shape" note (so keys aren't repeated hundreds of
# times), long strings are truncated, and a footer prints the exact query
# commands. The file stays untouched on disk.
#
# JSON needs jq. YAML is converted to JSON with whichever of yq / ruby / python3
# is present (ruby & json+yaml ship in Ruby's stdlib, so this works out of the
# box on macOS and most CI). If none can convert, YAML passes through unchanged.
# YAML comments are lost in conversion — acceptable for a summary.

f="${1:?usage: quiet-json.sh <file>}"

[ -f "$f" ] || exec cat "$f"
command -v jq >/dev/null 2>&1 || exec cat "$f"

: "${QUIET_JSON_MAX_KEYS:=6}"
: "${QUIET_JSON_MAX_ITEMS:=3}"
: "${QUIET_JSON_MAX_STR:=80}"

# Convert YAML→JSON via the first available tool. Multi-doc YAML becomes an
# array; single-doc is unwrapped. Prints JSON and returns 0, or returns 1.
yaml_to_json() {
  local file="$1" out
  # ruby: ships yaml+json in stdlib (present on macOS by default), handles multi-doc
  if command -v ruby >/dev/null 2>&1 \
     && out=$(ruby -ryaml -rjson -e 'd=YAML.load_stream(STDIN.read); puts JSON.generate(d.length==1 ? d[0] : d)' <"$file" 2>/dev/null) \
     && [ -n "$out" ]; then
    printf '%s' "$out"; return 0
  fi
  # python3 + PyYAML
  if command -v python3 >/dev/null 2>&1 \
     && out=$(python3 -c 'import sys,json,yaml; d=list(yaml.safe_load_all(sys.stdin)); json.dump(d[0] if len(d)==1 else d, sys.stdout)' <"$file" 2>/dev/null) \
     && [ -n "$out" ]; then
    printf '%s' "$out"; return 0
  fi
  # yq (purpose-built; resolves anchors). Plain identity — first/merged doc.
  if command -v yq >/dev/null 2>&1 \
     && out=$(yq -o=json '.' "$file" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s' "$out"; return 0
  fi
  return 1
}

# Pick the format and get JSON out of the file.
case "$f" in
  *.yaml | *.yml)
    fmt="YAML"; query="yq"
    if ! json=$(yaml_to_json "$f"); then
      exec cat "$f"   # no converter / unparseable → leave YAML alone
    fi ;;
  *)
    fmt="JSON"; query="jq"
    json=$(cat "$f") ;;
esac

program='
def summ:
  if type=="object" then
    (to_entries) as $e | ($e|length) as $n
    | ([ $e[0:'"$QUIET_JSON_MAX_KEYS"'][] | {key:.key, value:(.value|summ)} ]|from_entries)
      + (if $n>'"$QUIET_JSON_MAX_KEYS"' then {"…": "\($n-'"$QUIET_JSON_MAX_KEYS"') more of \($n) keys, same shape"} else {} end)
  elif type=="array" then
    length as $n
    | ([ .['"0:$QUIET_JSON_MAX_ITEMS"'][] | summ ])
      + (if $n>'"$QUIET_JSON_MAX_ITEMS"' then ["… \($n-'"$QUIET_JSON_MAX_ITEMS"') more of \($n), same shape"] else [] end)
  elif type=="string" then
    (if (length)>'"$QUIET_JSON_MAX_STR"' then (.[0:'"$QUIET_JSON_MAX_STR"'] + "…(len=\(length))") else . end)
  else . end;
summ
'

if ! summary=$(printf '%s' "$json" | jq "$program" 2>/dev/null); then
  echo "[quiet-bash] $f is not valid $fmt — showing raw:"
  exec cat "$f"
fi

bytes=$(wc -c <"$f" | tr -d ' ')
lines=$(wc -l <"$f" | tr -d ' ')
echo "[quiet-bash] $f — ${bytes} bytes, ${lines} lines, ${fmt}. Collapsed preview (full file unchanged on disk):"
printf '%s\n' "$summary"
cat <<EOF
[quiet-bash] Query the full file instead of re-reading it:
    ${query} . "$f"            # whole thing
    ${query} '.<path>' "$f"    # one path
    grep -n '<key>' "$f"       # find a key
EOF
