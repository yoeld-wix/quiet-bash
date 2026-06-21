#!/usr/bin/env bash
#
# quiet-bash installer.
#
#   ./install.sh <target>
#
# Targets:
#   shims        Generate PATH shims and print the PATH line (works under ANY
#                agent — recommended for Cursor/Aider/Windsurf/Cline).
#   shell        Append `source adapters/shell-wrapper.sh` to your shell rc
#                (quiets your interactive terminal).
#   claude       Print the Claude Code marketplace install commands.
#   codex        Print the Codex CLI hook config to add.
#   gemini       Print the Gemini CLI hook config to add.
#   copilot      Print the GitHub Copilot CLI hook config to add.
#
# Hook-based agents (claude/codex/gemini/copilot) need a one-time config edit in
# THEIR settings, which this script prints for you to paste — it never edits an
# agent's config behind your back.

set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-}"

rc_file() {
  case "${SHELL:-}" in
    *zsh) printf '%s' "$HOME/.zshrc" ;;
    *)    printf '%s' "$HOME/.bashrc" ;;
  esac
}

case "$target" in
  shims)
    "$ROOT/adapters/install-shims.sh"
    ;;
  shell)
    rc="$(rc_file)"
    line="source \"$ROOT/adapters/shell-wrapper.sh\""
    if grep -qsF "$line" "$rc"; then
      echo "Already present in $rc"
    else
      printf '\n# quiet-bash\n%s\n' "$line" >> "$rc"
      echo "✓ Added to $rc — open a new shell or: source \"$rc\""
    fi
    ;;
  claude)
    cat <<EOF
Claude Code — run these in the Claude Code prompt:

    /plugin marketplace add yoeld-wix/quiet-bash
    /plugin install quiet-bash@quiet-bash

Then restart Claude Code.
EOF
    ;;
  codex)
    cat <<EOF
Codex CLI — add to ~/.codex/hooks.json (see docs/ for the link):

    {
      "hooks": { "PreToolUse": [
        { "matcher": "*", "hooks": [
          { "type": "command", "command": "$ROOT/adapters/codex.sh" }
        ] }
      ] }
    }

Then approve it via /hooks.
EOF
    ;;
  gemini)
    cat <<EOF
Gemini CLI — add to settings.json:

    {
      "hooks": { "BeforeTool": [
        { "matcher": "run_shell_command", "hooks": [
          { "command": "$ROOT/adapters/gemini.sh" }
        ] }
      ] }
    }
EOF
    ;;
  copilot)
    cat <<EOF
GitHub Copilot CLI — add to .github/hooks/quiet-bash.json:

    {
      "version": 1,
      "hooks": { "preToolUse": [
        { "type": "command", "matcher": "*", "bash": "$ROOT/adapters/copilot.sh" }
      ] }
    }
EOF
    ;;
  *)
    sed -n '2,30p' "$ROOT/install.sh" | sed 's/^# \{0,1\}//'
    echo
    echo "Usage: ./install.sh <shims|shell|claude|codex|gemini|copilot>"
    exit 1
    ;;
esac
