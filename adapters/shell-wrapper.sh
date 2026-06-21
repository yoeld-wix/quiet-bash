#!/usr/bin/env bash
#
# Universal shell-wrapper adapter for quiet-bash.
#
# Source this from your ~/.bashrc or ~/.zshrc:
#
#     source /path/to/quiet-bash/adapters/shell-wrapper.sh
#
# Unlike the hook adapters, this works under ANY agent — Cursor, Aider,
# Windsurf, Cline, OpenCode, etc. — and in your own terminal, because it
# intercepts verbose commands at the shell level (as functions) rather than
# through an agent's hook API. Full output goes to a temp log; only a summary is
# printed. `--version`/`--help` and other quick invocations pass through.
#
# Works in bash and zsh.

# Locate the repo root so we can source the core (handles bash + zsh).
if [ -n "${BASH_VERSION:-}" ]; then
  _quiet_src="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  _quiet_src="$(eval 'print -r -- ${(%):-%x}')"
else
  _quiet_src="$0"
fi
QUIET_ROOT="${QUIET_ROOT:-$(cd "$(dirname "$_quiet_src")/.." && pwd)}"
unset _quiet_src

# shellcheck source=../core/quiet-core.sh
. "$QUIET_ROOT/core/quiet-core.sh"

# Prune stale logs once when the shell starts.
quiet_prune

# Don't wrap obviously-cheap invocations (version/help probes).
_quiet_is_probe() {
  case " $* " in
    *" --version "* | *" -V "* | *" --help "* | *" -h "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Tools that are almost always verbose — wrap unless it's a version/help probe.
for _t in jest vitest mocha cypress playwright pytest tox nox cargo gradle mvn \
          sbt bazel buildozer turbo webpack vite rollup esbuild tsc eslint \
          prettier rspec rake ninja gulp grunt; do
  eval "${_t}() {
    if _quiet_is_probe \"\$@\"; then command ${_t} \"\$@\"; else quiet_run command ${_t} \"\$@\"; fi
  }"
done
unset _t

# Package managers: wrap only known-verbose subcommands.
_quiet_mgr() {
  local bin=$1; shift
  case "${1:-}" in
    test | build | lint | install | add | ci | run | dev | start | typecheck | watch)
      quiet_run command "$bin" "$@" ;;
    *) command "$bin" "$@" ;;
  esac
}
yarn() { _quiet_mgr yarn "$@"; }
npm()  { _quiet_mgr npm  "$@"; }
pnpm() { _quiet_mgr pnpm "$@"; }
bun()  { _quiet_mgr bun  "$@"; }

# make / cmake / ninja-style builds: wrap whole invocation (unless probe).
make()  { if _quiet_is_probe "$@"; then command make  "$@"; else quiet_run command make  "$@"; fi; }
cmake() { if _quiet_is_probe "$@"; then command cmake "$@"; else quiet_run command cmake "$@"; fi; }

# Note: git diff/show/log are intentionally NOT wrapped here — in an interactive
# shell you usually want that content. The hook adapters handle git separately.
