#!/usr/bin/env bash
#
# GitHub Copilot CLI adapter for quiet-bash.  (preToolUse hook)
# Docs: https://docs.github.com/en/copilot/reference/hooks-configuration
#
# Copilot's preToolUse hook can substitute tool arguments via `modifiedArgs`
# alongside `permissionDecision`. For a verbose command we allow it and swap in
# the rewritten command; otherwise we emit nothing and let Copilot's normal
# flow proceed.
#
# IMPORTANT: Copilot hooks are FAIL-CLOSED — a crash or timeout DENIES the call.
# This adapter therefore never errors out (always exits 0) and only emits a
# decision when it actually rewrites.
#
# Verified against the documented Copilot hook schema (input + output): toolName
# "bash", toolArgs is a JSON-encoded string, output uses modifiedArgs +
# permissionDecision. Not yet exercised against a live authenticated CLI.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/core/quiet-core.sh"

quiet_prune

input=$(cat)
# Copilot sends `toolArgs` as a JSON-encoded STRING (e.g. "{\"command\":\"ls\"}"),
# so it must be double-decoded. Also accept the VS Code-style snake_case alias.
cmd=$(printf '%s' "$input" | jq -r '
  (.tool_input.command)
  // ( .toolArgs | if type=="string" then (try fromjson catch null) else . end | .command? )
  // empty')

if rewritten=$(quiet_rewrite "$cmd"); then
  jq -n --arg c "$rewritten" \
    '{permissionDecision: "allow", modifiedArgs: {command: $c}}'
fi
exit 0
