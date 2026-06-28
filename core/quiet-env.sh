#!/usr/bin/env bash
#
# quiet-env — deterministic environment / capability digest in one shot, so the
# agent stops probing (`node -v`, `which docker`, guessing the package manager).
#
#   quiet-env.sh
#
# Reports only what's actually present. Read-only. (MCP servers / skills are
# intentionally omitted — the agent's harness already lists them.)

_present() { command -v "$1" >/dev/null 2>&1; }
_ver() { # label cmd version-args...
  local label="$1" cmd="$2"; shift 2
  _present "$cmd" || return 0
  printf '  %-8s %s\n' "$label" "$("$cmd" "$@" 2>&1 | head -1)"
}

cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?')
echo "[quiet-env] platform: $(uname -s) $(uname -m) | shell ${SHELL##*/} | cpus $cpus"

pm=""
[ -f pnpm-lock.yaml ]     && pm="$pm pnpm"
[ -f yarn.lock ]          && pm="$pm yarn"
[ -f bun.lockb ]          && pm="$pm bun"
[ -f package-lock.json ]  && pm="$pm npm"
[ -f poetry.lock ]        && pm="$pm poetry"
[ -f uv.lock ]            && pm="$pm uv"
[ -f Pipfile.lock ]       && pm="$pm pipenv"
[ -f requirements.txt ]   && pm="$pm pip"
[ -n "$pm" ] && echo "[quiet-env] package manager(s):$pm"

eco=""
for m in package.json pyproject.toml go.mod Cargo.toml Gemfile pom.xml; do [ -f "$m" ] && eco="$eco $m"; done
[ -n "$eco" ] && echo "[quiet-env] project markers:$eco"

echo "[quiet-env] runtimes:"
_ver node   node    --version
_ver python python3 --version
_ver go     go      version
_ver rust   rustc   --version
_ver java   java    -version
_ver ruby   ruby    --version
_ver deno   deno    --version
_ver bun    bun     --version

clis=""
for c in git rg jq fd gh docker kubectl make cargo curl tree; do _present "$c" && clis="$clis $c"; done
echo "[quiet-env] CLIs present:$clis"
