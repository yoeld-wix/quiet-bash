#!/usr/bin/env bash
# Task suite + grading for the model-economy benchmark.
# Each task is engineered to induce subagent delegation (search/summarize over
# this repo) and carries a deterministic regex its final answer must satisfy.
# Sourced by bench/model-economy.sh and by tests/run.sh — defines no top-level
# side effects.

# Prompts run against the quiet-bash repo itself (stable ground truth).
ME_TASK_PROMPTS=(
  "Search this repository to find which shell function decides whether a command gets rewritten, and name it."
  "Search this repository for the adapter file that handles Claude Code PreToolUse Bash events and give its path."
  "Search the core/ directory and list the names of the quiet-* shell scripts it contains."
  "Find the output style shipped by this repo and name it."
)

# Index-aligned extended regexes (matched case-insensitively against the answer).
ME_TASK_ASSERTS=(
  'quiet_rewrite'
  'adapters/claude-code\.sh'
  'quiet-(core|json|outline|prompt|query|result|tail)'
  'concise'
)

# me_grade <task_index> <answer_text> -> echoes pass|fail, returns 0|1
me_grade() {
  local idx="$1" answer="$2" rx="${ME_TASK_ASSERTS[$1]}"
  if printf '%s' "$answer" | grep -Eiq "$rx"; then echo pass; return 0; fi
  echo fail; return 1
}
