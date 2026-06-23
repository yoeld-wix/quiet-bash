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

tool=$(printf '%s' "$input" | jq -r '.tool_name // "tool"')

# Source-file outline: if this was a read of a large source file, outline the real file.
summary=""
path=$(printf '%s' "$input" | jq -r '.tool_input.path // .tool_input.file_path // empty' 2>/dev/null)
if [ -n "$path" ] && [ -f "$path" ]; then
  case "${path##*.}" in
    py|js|mjs|cjs|jsx|ts|tsx|go|rs|java|kt|kts|scala|rb|c|h|cc|cpp|cxx|hpp|php|swift)
      if [ "$(wc -c <"$path" 2>/dev/null || echo 0)" -gt "${QUIET_OUTLINE_MIN_BYTES}" ]; then
        osum=$("$ROOT/core/quiet-outline.sh" "$path")
        case "$osum" in '[quiet-bash]'*) summary="$osum" ;; esac
      fi ;;
  esac
fi

[ -z "$summary" ] && { summary=$(quiet_result_summarize "$text" "$tool") || exit 0; }   # small/empty → pass through

# Emit a replacement that mirrors the original shape.
if [ "$shape" = "string" ]; then
  jq -n --arg t "$summary" '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: $t}}'
else
  jq -n --arg t "$summary" '{hookSpecificOutput: {hookEventName: "PostToolUse", updatedToolOutput: {content: [{type: "text", text: $t}]}}}'
fi
