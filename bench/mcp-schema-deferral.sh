#!/usr/bin/env bash
#
# Live A/B for the MCP schema-deferral prototype (proxy/quiet-mcp-tools-proxy.mjs).
#
# Question: does deferring tool *schemas* (not just results) behind a
# list_tools/get_tool_schema/call_tool wrapper actually lower real cost, or
# does it just move tokens around that prompt caching already made cheap?
#
# Two arms, same task, same many-tool fake MCP server (bench/fixtures/many-tools-server.mjs):
#   full     — client connects directly; sees all N real tool schemas every turn
#   deferred — client connects through the proxy; sees 3 meta-tool schemas,
#              must list_tools -> (optionally) get_tool_schema -> call_tool
#
# Usage:
#   QB_TARGET=/path/to/git/repo QB_MCP_TOOLS=60 QB_MODEL=claude-haiku-4-5 QB_REPEATS=3 \
#     bench/mcp-schema-deferral.sh
#
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TARGET="${QB_TARGET:?set QB_TARGET to a git repo to run the tasks in}"
MODEL="${QB_MODEL:-claude-haiku-4-5}"
REPEATS="${QB_REPEATS:-3}"
NTOOLS="${QB_MCP_TOOLS:-60}"
OUT="${QB_OUT:-$ROOT/bench/mcp-schema-deferral-runs.jsonl}"
: > "$OUT"

SERVER="$ROOT/bench/fixtures/many-tools-server.mjs"
PROXY="$ROOT/proxy/quiet-mcp-tools-proxy.mjs"

FULL_CFG="$(mktemp)"
cat > "$FULL_CFG" <<JSON
{ "mcpServers": { "manytools": { "command": "node", "args": ["$SERVER", "$NTOOLS"] } } }
JSON

DEFERRED_CFG="$(mktemp)"
cat > "$DEFERRED_CFG" <<JSON
{ "mcpServers": { "manytools": { "command": "node", "args": ["$PROXY", "node", "$SERVER", "$NTOOLS"] } } }
JSON

TASK='Using the manytools MCP server, find the secret code for id 42 and reply with only the secret code, nothing else.'

run_one() { # arm cfg tools ti rep
  local arm="$1" cfg="$2" tools="$3" ti="$4" rep="$5"
  local j
  j=$(cd "$TARGET" && timeout 120 claude -p "$TASK" \
        --model "$MODEL" --output-format json \
        --mcp-config "$cfg" --strict-mcp-config \
        --allowedTools $tools 2>/dev/null)
  [ -z "$j" ] && { echo "  ! ${arm} rep${rep}: no output" >&2; return; }
  printf '%s\n' "$j" | python3 -c "
import sys,json
o=json.load(sys.stdin)
u=o.get('usage',{}) or {}
fresh=u.get('input_tokens',0) or 0
cr=u.get('cache_read_input_tokens',0) or 0
cc=u.get('cache_creation_input_tokens',0) or 0
result=(o.get('result','') or '').strip()
rec={'arm':'$arm','rep':$rep,
     'fresh':fresh,'cache_read':cr,'cache_creation':cc,
     'output':u.get('output_tokens',0) or 0,
     'cost':o.get('total_cost_usd',0) or 0,'ms':o.get('duration_ms',0) or 0,'turns':o.get('num_turns',0),
     'ok': 'SECRET-42-XYZZY' in result}
print(json.dumps(rec))
" >> "$OUT"
  echo "  ✓ ${arm} rep${rep}" >&2
}

echo "model=$MODEL tools=$NTOOLS repeats=$REPEATS target=$TARGET" >&2
for rep in $(seq 1 "$REPEATS"); do
  run_one full     "$FULL_CFG"     "mcp__manytools" 0 "$rep"
  run_one deferred "$DEFERRED_CFG" "mcp__manytools" 0 "$rep"
done
rm -f "$FULL_CFG" "$DEFERRED_CFG"

echo >&2
python3 - "$OUT" <<'PY'
import sys,json,collections,statistics
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by=collections.defaultdict(lambda:collections.defaultdict(list))
oks=collections.defaultdict(list)
for r in rows:
    for k in ('fresh','cache_read','cache_creation','output','cost','ms','turns'):
        by[r['arm']][k].append(r.get(k,0))
    oks[r['arm']].append(r.get('ok', False))
def mean(x): return statistics.mean(x) if x else 0
def hit(a):
    tot=mean(by[a]['fresh'])+mean(by[a]['cache_read'])+mean(by[a]['cache_creation'])
    return 100*mean(by[a]['cache_read'])/tot if tot else 0
arms=['full','deferred']
labels={'full':'A full (real schemas)','deferred':'B deferred (proxy, 3 meta-tools)'}
print("# MCP schema-deferral benchmark — mean per run")
print("| arm | cost $ | fresh in | cache-read | cache-create | cache-hit % | output | turns | correct | runs |")
print("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
for a in arms:
    if not by[a]['cost']: continue
    n=len(by[a]['cost']); ok=sum(1 for x in oks[a] if x)
    print(f"| {labels[a]} | {mean(by[a]['cost']):.4f} | {mean(by[a]['fresh']):,.0f} | {mean(by[a]['cache_read']):,.0f} | {mean(by[a]['cache_creation']):,.0f} | {hit(a):.0f}% | {mean(by[a]['output']):,.0f} | {mean(by[a]['turns']):.1f} | {ok}/{n} | {n} |")
if by['full']['cost'] and by['deferred']['cost']:
    fc=mean(by['full']['cost']); dc=mean(by['deferred']['cost'])
    print(f"\n_deferred vs full: cost {100*(fc-dc)/fc:+.1f}% (positive = cheaper)._")
    print("_Note: cache_creation happens once per session (first call pays full price for the schema"
          "\nbytes); cache_read is what later calls in the same session pay (~0.1x). A short,"
          "\nfew-turn task is the worst case for deferral (extra list_tools/get_tool_schema round"
          "\ntrips may not be amortized); a long tool-heavy session is the best case.")
PY
