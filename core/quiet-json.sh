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
#
# PROTOTYPE, opt-in (QUIET_JSON_AUTOSTATS=1): when the root value is a large
# array of uniform-shaped records (the common "API list" / DB-query-result /
# CSV-as-JSON shape), also compute per-field stats over ALL records — not just
# the folded sample — so a count/min/max/avg/top-values question can often be
# answered straight from the preview, without a follow-up quiet-query call.
# See docs/research/cost-levers-2026-07-update.md (candidate #2) and
# bench/RESULTS.md for the live A/B this was built to answer.

QJDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$QJDIR/quiet-core.sh"

f="${1:?usage: quiet-json.sh <file>}"

[ -f "$f" ] || exec cat "$f"
command -v jq >/dev/null 2>&1 || exec cat "$f"

: "${QUIET_JSON_MAX_KEYS:=6}"
: "${QUIET_JSON_MAX_ITEMS:=3}"
: "${QUIET_JSON_MAX_STR:=80}"
: "${QUIET_JSON_AUTOSTATS:=0}"
: "${QUIET_JSON_STATS_MIN_ITEMS:=10}"
: "${QUIET_JSON_STATS_MAX_ITEMS:=100000}"
: "${QUIET_JSON_STATS_MAX_FIELDS:=20}"
: "${QUIET_JSON_STATS_DECIMALS:=4}"

# Get JSON out of the file (yaml via the shared core converter).
case "$f" in
  *.yaml | *.yml)
    fmt="YAML"; query="yq"
    if ! json=$(quiet_to_json "$f"); then
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

if [ "$QUIET_JSON_AUTOSTATS" = "1" ]; then
  stats_mult=$((10 ** QUIET_JSON_STATS_DECIMALS))
  stats_program='
def rnd: (. * '"$stats_mult"' | round) / '"$stats_mult"';
def numstats($vals): {min:($vals|min|rnd), max:($vals|max|rnd), avg:(($vals|add)/($vals|length)|rnd)};
def fieldstats($arr; $k):
  ($arr | map(.[$k]) | map(select(. != null))) as $vals
  | ($vals|length) as $n
  | if $n==0 then {present:0}
    elif (($vals|map(type)|unique)==["number"]) then {type:"number", present:$n} + numstats($vals)
    elif (($vals|map(type)|unique)==["string"]) then
      ($vals|group_by(.)|map({value:.[0],count:length})|sort_by(-.count)) as $g
      | {type:"string", present:$n, distinct:($g|length)}
        + (if ($g|length) <= 10 then {top:$g} else {} end)
    elif (($vals|map(type)|unique)==["boolean"]) then
      {type:"boolean", present:$n, true:([$vals[]|select(.==true)]|length), false:([$vals[]|select(.==false)]|length)}
    else {type:"mixed", present:$n} end;
. as $root
| if ($root|type)=="array"
     and ($root|length) >= '"$QUIET_JSON_STATS_MIN_ITEMS"'
     and ($root|length) <= '"$QUIET_JSON_STATS_MAX_ITEMS"'
     and ($root|all(.[]; type=="object"))
  then
    ( [ $root[] | keys_unsorted[] ] | unique ) as $allkeys
    | ($allkeys[0:'"$QUIET_JSON_STATS_MAX_FIELDS"']) as $keys
    | { record_count: ($root|length),
        fields: ( reduce $keys[] as $k ({}; . + {($k): fieldstats($root; $k)}) ) }
      + (if ($allkeys|length) > ($keys|length)
         then {omitted_fields: (($allkeys|length) - ($keys|length))} else {} end)
  else null end
'
  if stats=$(printf '%s' "$json" | jq "$stats_program" 2>/dev/null) && [ "$stats" != "null" ]; then
    echo "[quiet-bash] EXACT stats below, computed over ALL records (not the sample above)."
    echo "[quiet-bash] These are final, pre-rounded values — use them as-is, no further jq/computation needed:"
    printf '%s\n' "$stats"
  fi
fi

qq="$QJDIR/quiet-query.sh"
cat <<EOF
[quiet-bash] Query/aggregate the full file instead of re-reading it:
    $qq "$f" keys                 # keys + types
    $qq "$f" count '.<path>'      # how many items
    $qq "$f" sample '.<path>' 5   # first 5 items
    $qq "$f" select '.<path>' '.score > 0.8'   # filter
    $qq "$f" group '.<path>' '.status'         # count by field (aggregate)
    $qq "$f" stats '.<path>' '.price'          # min/max/sum/avg
    $qq "$f" search '<regex>'     # find matching paths
  (or raw: ${query} '.<path>' "$f")
EOF
