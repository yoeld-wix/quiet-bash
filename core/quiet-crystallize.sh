#!/usr/bin/env bash
#
# quiet-crystallize — Stage 4 of the learning loop (sourced helper + CLI).
#
# Turns a top recurring pattern from the observe ledger into a CANDIDATE Agent
# Skill: a SKILL.md (LLM-synthesized) plus a bundled deterministic script that
# runs the recurring command. Candidates are written to a suggestions area for
# HUMAN REVIEW — nothing is auto-installed. See docs/research/learning-loop.md.
#
#   quiet-crystallize suggest [N]     # crystallize the top N recurring patterns
#
# The SKILL.md is written by a synthesizer command ($QUIET_SYNTH_CMD, default
# `claude -p`) fed the prompt on stdin. If no synthesizer is available it falls
# back to a mechanical stub, so the feature degrades gracefully with zero hard
# LLM dependency. The bundled script is always deterministic (mechanical).

_quiet_cryst_suggest_dir() {
  if [ -n "${QUIET_SUGGEST_DIR:-}" ]; then printf '%s' "$QUIET_SUGGEST_DIR"
  else printf '%s/suggestions' "$(dirname "$(quiet_observe_ledger)")"; fi
}

# Top-N recurring patterns as JSON: [{fp,canon,cmd,n,bytes}], most frequent first.
_quiet_cryst_top() {
  local ledger="${1:-$(quiet_observe_ledger)}" n="${2:-1}"
  [ -r "$ledger" ] || return 1
  jq -s --argjson n "$n" '
    group_by(.fp)
    | map({fp:.[0].fp, canon:.[0].canon, cmd:(map(.cmd)|last), n:length, bytes:(map(.bytes)|add // 0)})
    | sort_by(-.n, -.bytes) | .[:$n]' "$ledger" 2>/dev/null
}

_quiet_cryst_slug() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//' | cut -c1-40
}

_quiet_cryst_prompt() { # <canon> <count> <example-cmd>
  cat <<EOF
You are writing an Anthropic Agent Skill (SKILL.md) that captures a recurring shell workflow so a future agent reuses it instead of re-deriving it.

Recurring pattern (normalized): $1
Times seen: $2
Example command: $3

A deterministic helper already exists at scripts/run.sh that runs this command. Output ONLY the SKILL.md content, starting with '---':
- YAML frontmatter:
    name: short lowercase-hyphen gerund, <=64 chars
    description: THIRD PERSON, one sentence stating what it does AND when to use it, packed with concrete trigger words, <=1024 chars
- A thin body (<40 lines): tell the agent to run scripts/run.sh for the deterministic part; add only judgment tips that matter.
Raw markdown only. No prose before '---'.
EOF
}

# Crystallize the top N patterns into candidate skills under the suggestions dir.
quiet_crystallize_suggest() {
  local n="${1:-1}" ledger top count_i i canon count cmd slug dir synth
  ledger=$(quiet_observe_ledger)
  [ -r "$ledger" ] || { printf 'quiet-crystallize: no observe ledger (%s) — enable `observe = on` first\n' "$ledger"; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'quiet-crystallize: jq required\n'; return 0; }
  synth="${QUIET_SYNTH_CMD:-claude -p}"
  top=$(_quiet_cryst_top "$ledger" "$n")
  count_i=$(printf '%s' "$top" | jq 'length' 2>/dev/null)
  [ "${count_i:-0}" -gt 0 ] 2>/dev/null || { printf 'quiet-crystallize: ledger empty — nothing to crystallize\n'; return 0; }
  i=0
  while [ "$i" -lt "$count_i" ]; do
    canon=$(printf '%s' "$top" | jq -r ".[$i].canon")
    count=$(printf '%s' "$top" | jq -r ".[$i].n")
    cmd=$(printf '%s' "$top" | jq -r ".[$i].cmd")
    slug=$(_quiet_cryst_slug "$canon"); [ -n "$slug" ] || slug="pattern-$i"
    dir="$(_quiet_cryst_suggest_dir)/$slug"
    mkdir -p "$dir/scripts" 2>/dev/null || { i=$((i + 1)); continue; }
    # Bundled deterministic helper (mechanical).
    { printf '#!/usr/bin/env bash\n'
      printf '# Auto-suggested by quiet-bash from a recurring pattern.\n'
      printf '# Pattern: %s  (seen %s times)\n' "$canon" "$count"
      printf 'set -euo pipefail\n'
      printf '%s\n' "$cmd"
    } >"$dir/scripts/run.sh"
    chmod +x "$dir/scripts/run.sh" 2>/dev/null
    # LLM-synthesized SKILL.md, with a mechanical fallback.
    if ! printf '%s' "$(_quiet_cryst_prompt "$canon" "$count" "$cmd")" | eval "$synth" >"$dir/SKILL.md" 2>/dev/null \
      || [ ! -s "$dir/SKILL.md" ]; then
      { printf -- '---\n'
        printf 'name: %s\n' "$slug"
        printf 'description: Runs the recurring workflow `%s` (seen %s times). Use when you would otherwise run that command.\n' "$canon" "$count"
        printf -- '---\n\n'
        printf 'Run the bundled deterministic helper for this pattern:\n\n    scripts/run.sh\n\n'
        printf '_(Generated mechanically — no synthesizer was available. Set QUIET_SYNTH_CMD to enrich.)_\n'
      } >"$dir/SKILL.md"
    fi
    printf 'quiet-crystallize: candidate skill → %s\n' "$dir"
    i=$((i + 1))
  done
}

# ── Skill verification: does the crystallized artifact actually work, and what
# does it cost? Runs the bundled script and reports RESULT (correct? — diffed
# against re-running the underlying command), COST (output bytes), and TIME (ms).
# This is the trust-ladder's mechanical shadow check for a candidate skill; the
# deeper "does it save the AGENT tokens/turns" A/B lives in bench/ (agentic.sh,
# session-savings.py). Returns 0 only when PASS and the result matches baseline.
_quiet_now_ms() {
  if command -v python3 >/dev/null 2>&1; then python3 -c 'import time;print(int(time.time()*1000))'
  else printf '%s000' "$(date +%s 2>/dev/null || echo 0)"; fi
}

quiet_crystallize_verify() {
  local dir="$1" scr cmd out st bytes t0 t1 ms base corr verdict
  scr="$dir/scripts/run.sh"
  [ -f "$scr" ] || { printf 'skill verify: no script at %s\n' "$scr"; return 1; }
  cmd=$(grep -vE '^[[:space:]]*(#|set )' "$scr" 2>/dev/null | grep -vE '^[[:space:]]*$' | tail -1)
  t0=$(_quiet_now_ms)
  out=$(bash "$scr" 2>&1); st=$?
  t1=$(_quiet_now_ms)
  ms=$((t1 - t0)); [ "$ms" -lt 0 ] 2>/dev/null && ms=0
  bytes=$(printf '%s' "$out" | wc -c | tr -d ' ')
  base=$(sh -c "$cmd" 2>&1)
  if [ "$out" = "$base" ]; then corr="matches baseline"; else corr="DIFFERS from baseline"; fi
  if [ "$st" -eq 0 ] && [ -n "$out" ]; then verdict="PASS"; else verdict="FAIL"; fi
  printf 'skill verify: %s\n' "$dir"
  printf '  script:  %s\n' "$scr"
  printf '  exit:    %s\n' "$st"
  printf '  result:  %s bytes, %s\n' "$bytes" "$corr"
  printf '  time:    %s ms\n' "$ms"
  printf '  verdict: %s\n' "$verdict"
  [ "$verdict" = "PASS" ] && [ "$corr" = "matches baseline" ]
}

# ── CLI (only when executed directly; sentinel guards the re-source) ─────────
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ] && [ -z "${_QUIET_CRYST_CLI:-}" ]; then
  _QUIET_CRYST_CLI=1
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/core/quiet-core.sh"
  case "${1:-help}" in
    suggest) shift; quiet_crystallize_suggest "${1:-1}" ;;
    verify) shift; quiet_crystallize_verify "$1" ;;
    *) printf 'quiet-crystallize — stage-4/5: recurring pattern → candidate skill\n\n'
       printf 'usage:\n'
       printf '  quiet-crystallize suggest [N]   crystallize the top N recurring patterns into\n'
       printf '                                  candidate skills (SKILL.md + scripts/run.sh)\n'
       printf '  quiet-crystallize verify <dir>  run a candidate skill and report\n'
       printf '                                  result (correct?) + cost (bytes) + time (ms)\n'
       printf '\nSynthesizer: $QUIET_SYNTH_CMD (default `claude -p`); mechanical fallback if absent.\n' ;;
  esac
fi
