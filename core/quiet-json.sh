#!/usr/bin/env bash
#
# quiet-json — summarize a large JSON file instead of dumping it.
#
#   quiet-json.sh <file.json>
#
# Emits a collapsed preview: objects/arrays with many entries show a few samples
# plus a "N more of M, same shape" note (so keys aren't repeated hundreds of
# times), long strings are truncated, and a footer prints the exact jq/grep to
# query the full file — which stays untouched on disk. Chosen over gron-flat and
# schema-only by an A/B/C benchmark (best tokens, zero hallucination, counts
# answerable). If jq is missing or the file isn't valid JSON, falls back to cat.

f="${1:?usage: quiet-json.sh <file.json>}"

if [ ! -f "$f" ] || ! command -v jq >/dev/null 2>&1; then
  exec cat "$f"
fi

# Sample/elision limits (override via env).
: "${QUIET_JSON_MAX_KEYS:=6}"
: "${QUIET_JSON_MAX_ITEMS:=3}"
: "${QUIET_JSON_MAX_STR:=80}"

bytes=$(wc -c <"$f" | tr -d ' ')
lines=$(wc -l <"$f" | tr -d ' ')

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

if ! summary=$(jq "$program" "$f" 2>/dev/null); then
  echo "[quiet-bash] $f is not valid JSON — showing raw:"
  exec cat "$f"
fi

echo "[quiet-bash] $f — ${bytes} bytes, ${lines} lines. Collapsed preview (full file unchanged on disk):"
printf '%s\n' "$summary"
cat <<EOF
[quiet-bash] Query the full file instead of re-reading it:
    jq . "$f"            # whole thing
    jq '.<path>' "$f"    # one path  (e.g. jq '.packages["node_modules/react"]' "$f")
    grep -n '<key>' "$f" # find a key
EOF
