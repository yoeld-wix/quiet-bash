#!/usr/bin/env bash
#
# Claude Code MCP adapter for quiet-bash.  (PostToolUse hook, matcher mcp__.*)
#
# Large MCP tool *results* are the third big context sink (after verbose shell
# output and large file reads): web-search dumps, DB rows, API payloads — the
# whole thing lands in context and is re-sent every later turn. This hook fires
# after an MCP tool returns, and when its result is large it spills the full
# payload to a file and replaces what the model sees with a compact summary plus
# the exact command to query the rest. The spill file is byte-exact (lossless).
#
# Branches by payload type:
#   JSON  → reuse the JSON collapser (collapsed preview + jq drill-in footer)
#   text  → head + tail + "spilled to <file>" with a sed/grep drill-in
#
# Replaces the result via hookSpecificOutput.updatedToolOutput (mirrors the
# tool_response shape: {content:[{type:"text",text:…}]}). Small results and
# non-text content pass through untouched (no output).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/core/quiet-core.sh"
command -v jq >/dev/null 2>&1 || exit 0

quiet_prune

input=$(cat)

# Concatenate the text blocks of the MCP result.
text=$(printf '%s' "$input" | jq -r '(.tool_response.content // []) | map(select(.type=="text") | .text) | join("\n")' 2>/dev/null)
[ -z "$text" ] && exit 0   # nothing textual (image/audio/empty) → leave it

# Never re-wrap our own output.
case "$text" in
  *'[quiet-mcp]'* | *'[quiet-bash]'*) exit 0 ;;
esac

bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
[ "$bytes" -le "${QUIET_MCP_MIN_BYTES}" ] && exit 0   # small → pass through

tool=$(printf '%s' "$input" | jq -r '.tool_name // "mcp"')

# Spill the full payload to disk (byte-exact).
spill=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}mcp-XXXXXX")
printf '%s' "$text" > "$spill"

if printf '%s' "$text" | jq -e . >/dev/null 2>&1; then
  # JSON result → reuse the collapser (handles fold + jq drill-in footer).
  mv "$spill" "$spill.json"; spill="$spill.json"
  summary="[quiet-mcp] ${tool} returned ${bytes} bytes of JSON — collapsed below.
$("$ROOT/core/quiet-json.sh" "$spill")"
else
  # Plain text → head/tail + spill pointer.
  lines=$(wc -l <"$spill" | tr -d ' ')
  summary=$(
    echo "[quiet-mcp] ${tool} returned ${bytes} bytes / ${lines} lines — spilled to ${spill}"
    echo "--- first 20 lines ---"
    head -n 20 "$spill"
    echo "--- last 10 lines ---"
    tail -n 10 "$spill"
    echo "[query the full result:  sed -n '1,60p' \"${spill}\"   |   grep -n '<pattern>' \"${spill}\"]"
  )
fi

# Replace the result (updatedToolOutput must mirror tool_response's shape).
jq -n --arg t "$summary" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: {content: [{type: "text", text: $t}]}}}'
