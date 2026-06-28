#!/usr/bin/env bash
# Task suite + grading for the context-enrichment benchmark. Code-localization
# tasks over THIS repo (stable ground truth). Sourced by bench/enrichment.sh and
# tests/run.sh — no top-level side effects.

FM_TASK_PROMPTS=(
  "Which file would you edit to change how recursive grep/rg output is collapsed? Give its path."
  "Which core/ file implements the duplicate-read dedup helper? Give its path."
  "Which adapter file shrinks large PostToolUse tool results? Give its path."
  "Which file holds the deterministic-first skill cheatsheet you'd add a row to? Give its path."
)

FM_TASK_ASSERTS=(
  'core/quiet-core\.sh'
  'core/quiet-dedup\.sh'
  'adapters/claude-code-result\.sh'
  'skills/deterministic-first/SKILL\.md'
)

# fm_grade <task_index> <answer_text> -> echoes pass|fail, returns 0|1
fm_grade() {
  local rx="${FM_TASK_ASSERTS[$1]:-}"
  [ -z "$rx" ] && { echo fail; return 1; }
  if printf '%s' "$2" | grep -Eiq "$rx"; then echo pass; return 0; fi
  echo fail; return 1
}
