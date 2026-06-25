#!/usr/bin/env bash
#
# Claude Code adapter for quiet-bash.
#
# Wired as a PreToolUse(Bash) hook. Reads the event JSON on stdin, asks the core
# whether to rewrite the command, and — if so — emits Claude Code's
# `hookSpecificOutput.updatedInput` so the rewritten command runs instead.
# Otherwise prints nothing and the command runs unchanged.
#
# NOTE: Claude Code only applies `updatedInput` when the hook also returns
# `permissionDecision: "allow"` (a sibling field) — without it the rewrite is
# silently ignored. So a rewritten (known-verbose) command is auto-allowed; this
# only affects commands quiet-bash chooses to wrap, not arbitrary commands
# (non-matching commands print nothing and follow the normal permission flow).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/core/quiet-core.sh"

quiet_prune

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

if rewritten=$(quiet_rewrite "$cmd"); then
  jq -n --arg c "$rewritten" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: {command: $c}}}'
fi
exit 0
