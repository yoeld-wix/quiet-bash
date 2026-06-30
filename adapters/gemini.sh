#!/usr/bin/env bash
#
# Gemini CLI adapter for quiet-bash.  (BeforeTool hook, matcher: run_shell_command)
# Docs: https://geminicli.com/docs/hooks/reference/
#
# Gemini's BeforeTool hook can rewrite a tool call by emitting
# `hookSpecificOutput.tool_input` — an object that merges with and overrides the
# model's arguments. For the shell tool that argument is `command`.
#
# Verified against the documented schema: input .tool_input.command (tool_name
# "run_shell_command"), output hookSpecificOutput.tool_input.command. Not yet
# exercised against a live authenticated CLI.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/core/quiet-core.sh"

quiet_prune

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // .toolInput.command // .args.command // empty')

if rewritten=$(quiet_reuse_rewrite "$cmd") || rewritten=$(quiet_rewrite "$cmd"); then
  quiet_observe_record "$cmd" 1
  jq -n --arg c "$rewritten" \
    '{hookSpecificOutput: {tool_input: {command: $c}}}'
else
  quiet_observe_record "$cmd" 0
fi
exit 0
