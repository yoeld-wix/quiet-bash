#!/usr/bin/env bash
#
# Claude Code adapter — shrink any large TOOL RESULT.  (PostToolUse hook)
#
# Works for MCP tools AND non-MCP tools (WebFetch, WebSearch, …): large tool
# results are the third context sink (after verbose shell output and large file
# reads). When a result is large, spill the byte-exact payload to a file and
# replace what the model sees with a compact summary (JSON → collapsed preview +
# quiet-query footer; text → head/tail + drill-in). Lossless: only the preview
# shrinks.
#
# `updatedToolOutput` must MIRROR the original tool_response shape, so we handle:
#   - string result            → replace with a string
#   - MCP content[] result     → replace with {content:[{type:"text",text:…}]}
#   - any other shape          → pass through untouched (safe no-op)
# Small results and non-text content also pass through.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/core/quiet-core.sh"
command -v jq >/dev/null 2>&1 || exit 0

quiet_prune

input=$(cat)

# Classify the result shape so the replacement can mirror it.
shape=$(printf '%s' "$input" | jq -r '
  .tool_response
  | if type=="string" then "string"
    elif (type=="object" and (.content|type)=="array") then "content"
    else "other" end' 2>/dev/null)
[ "$shape" = "other" ] && exit 0   # unknown shape → leave it alone

# Pull the textual payload.
text=$(printf '%s' "$input" | jq -r '
  .tool_response
  | if type=="string" then .
    else (.content | map(select(.type=="text") | .text) | join("\n")) end' 2>/dev/null)
[ -z "$text" ] && exit 0            # nothing textual (image/audio/empty)

case "$text" in *'[quiet-bash]'* | *'[quiet-mcp]'*) exit 0 ;; esac   # never re-wrap

bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
[ "$bytes" -le "${QUIET_RESULT_MIN_BYTES}" ] && exit 0   # small → pass through

tool=$(printf '%s' "$input" | jq -r '.tool_name // "tool"')

spill=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}result-XXXXXX")
printf '%s' "$text" > "$spill"

if printf '%s' "$text" | jq -e . >/dev/null 2>&1; then
  mv "$spill" "$spill.json"; spill="$spill.json"
  summary="[quiet-bash] ${tool} returned ${bytes} bytes of JSON — collapsed below.
$("$ROOT/core/quiet-json.sh" "$spill")"
else
  lines=$(wc -l <"$spill" | tr -d ' ')
  summary=$(
    echo "[quiet-bash] ${tool} returned ${bytes} bytes / ${lines} lines — spilled to ${spill}"
    echo "--- first 20 lines ---"; head -n 20 "$spill"
    echo "--- last 10 lines ---";  tail -n 10 "$spill"
    printf "[query the full result:  sed -n '1,60p' %q   |   grep -n '<pattern>' %q]\n" "$spill" "$spill"
  )
fi

# Emit a replacement that mirrors the original shape.
if [ "$shape" = "string" ]; then
  jq -n --arg t "$summary" '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $t}}'
else
  jq -n --arg t "$summary" '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: {content: [{type: "text", text: $t}]}}}'
fi
