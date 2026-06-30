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
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')

# Resolution order: (1) a plain repeat read of an unchanged file is already in
# context → stub it; (2) a deterministic read-only command with unchanged inputs
# → serve its cached result (or run+cache on first sight); (3) a known-verbose
# command → summarize. First match wins.
if rewritten=$(quiet_cmd_dedup "$sid" "$cmd") \
  || rewritten=$(quiet_reuse_rewrite "$cmd") \
  || rewritten=$(quiet_rewrite "$cmd"); then
  # Stage-1 observe: a command quiet-bash chose to quiet is the verbose/cost-class (wrapped=1).
  quiet_observe_record "$cmd" 1
  jq -n --arg c "$rewritten" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", updatedInput: {command: $c}}}'
else
  # Pass-through command — still recorded (recurrence signal), tagged plain (wrapped=0).
  quiet_observe_record "$cmd" 0
fi
exit 0
