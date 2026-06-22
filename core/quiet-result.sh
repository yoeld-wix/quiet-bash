#!/usr/bin/env bash
#
# quiet-result — CLI wrapper around quiet_result_summarize.
#
#   <result-text-on-stdin> | quiet-result.sh [tool-name]
#
# Prints a compact summary if the result is large (JSON → collapsed preview +
# quiet-query footer; text → head/tail + spill pointer), or NOTHING if it should
# pass through (small / empty / already-wrapped). Lets non-bash callers (e.g. the
# MCP proxy) reuse the exact same summarizer the agent hook adapters use.

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$ROOT/quiet-core.sh"
command -v jq >/dev/null 2>&1 || exit 0

text=$(cat)
quiet_result_summarize "$text" "${1:-tool}" || exit 0
