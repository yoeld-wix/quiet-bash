#!/usr/bin/env bash
#
# OpenAI Codex CLI adapter for quiet-bash.  (PreToolUse hook)
# Docs: https://developers.openai.com/codex/hooks
#
# Codex's PreToolUse hook reads the event JSON on stdin and may rewrite the
# command by emitting `permissionDecision: "allow"` together with
# `hookSpecificOutput.updatedInput.command` — the same shape as Claude Code.
#
# Verified against the documented schema: input .tool_input.command (tool_name
# "Bash"), output hookSpecificOutput.updatedInput.command + permissionDecision
# "allow". Caveats: the `updatedInput` rewrite requires a recent Codex (older
# versions reject it); PreToolUse may not intercept every shell path yet. Not
# yet exercised against a live authenticated CLI.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/core/quiet-core.sh"

quiet_prune

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.cmd // empty')

if rewritten=$(quiet_rewrite "$cmd"); then
  jq -n --arg c "$rewritten" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: {command: $c}}}'
fi
exit 0
