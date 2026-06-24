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

# Extract shape, tool, path, and text in ONE jq pass (one subprocess instead of
# 3-4). shape/tool/path are single-line and come first; text may be multiline so
# it is last — read the first three lines, then slurp the rest as text.
meta=$(printf '%s' "$input" | jq -r '
  (.tool_response | if type=="string" then "string"
     elif (type=="object" and ((.content|type)=="array")) then "content"
     else "other" end),
  (.tool_name // "tool"),
  (.tool_input.path // .tool_input.file_path // ""),
  (.tool_response | if type=="string" then .
     else ((.content // []) | map(select(.type=="text") | .text) | join("\n")) end)
' 2>/dev/null)
{ IFS= read -r shape; IFS= read -r tool; IFS= read -r path; text=$(cat); } <<EOF
$meta
EOF

[ "$shape" = "other" ] && exit 0   # unknown shape → leave it alone
[ -z "$text" ] && exit 0           # nothing textual (image/audio/empty)

summary=""
obytes=$(printf '%s' "$text" | wc -c | tr -d ' ')

if [ "$tool" = "Read" ]; then
  # Native Read: outline a large SOURCE file; pass anything else through untouched
  # (don't head/tail arbitrary large reads — the agent asked for that content).
  if [ "$obytes" -gt "${QUIET_OUTLINE_MIN_BYTES}" ]; then
    if [ -n "$path" ] && [ -f "$path" ]; then
      case "${path##*.}" in
        py|js|mjs|cjs|jsx|ts|tsx|go|rs|java|kt|kts|scala|rb|c|h|cc|cpp|cxx|hpp|php|swift)
          osum=$("$ROOT/core/quiet-outline.sh" "$path")
          case "$osum" in '[quiet-bash]'*) summary="$osum" ;; esac ;;
      esac
    fi
  fi
  [ -z "$summary" ] && exit 0   # non-source / small Read → pass through untouched
else
  # MCP / WebFetch / WebSearch: collapse large JSON, head/tail large text (as before).
  summary=$(quiet_result_summarize "$text" "$tool") || exit 0
fi

# Emit a replacement that mirrors the original shape.
if [ "$shape" = "string" ]; then
  jq -n --arg t "$summary" '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $t}}'
else
  jq -n --arg t "$summary" '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: {content: [{type: "text", text: $t}]}}}'
fi
