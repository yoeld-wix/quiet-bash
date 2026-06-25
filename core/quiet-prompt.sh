#!/usr/bin/env bash
#
# quiet-prompt — shrink a long injected prompt WITHOUT dropping the rules the agent
# must always honor.
#
# The naive "spill the whole prompt to a file + inject a stub" approach regresses:
# an agent reliably fetches sections the current TASK needs, but skips governance
# sections (style, output rules, constraints) it has no task-reason to open — so it
# stops following them. (Measured: ~25% rule-compliance for full-spill vs 100% inline.)
#
# So quiet-prompt does a SPLIT, not a spill:
#   • always-apply content (preamble + every untagged section) stays INLINE in the stub
#   • only sections the author tags `[ref]` in their heading are spilled to the file
#     and replaced by a one-line "load on demand" pointer
# This keeps directives in context (100% compliance in tests) while still removing the
# bulky reference material (background, API dumps, long examples) that an agent only
# needs occasionally. Safe by default: nothing tagged (or a small file) => pass through
# whole; quieting only happens where the author opted a section in.
#
# Usage:
#   quiet-prompt.sh <prompt-file>                  → print the split stub (or the whole
#                                                     file if nothing is spillable)
#   quiet-prompt.sh <prompt-file> --section "NAME"  → print just that `## NAME` section
#   quiet-prompt.sh <prompt-file> --all             → print the whole file (escape hatch)
#
# Mark a section as spillable reference by ending its heading with `[ref]`:
#   ## API reference [ref]
#
# Mixed content: prose sections by markdown heading; an embedded JSON/YAML block in a
# spilled section can be queried with quiet-query.sh after loading it.

QPDIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${QUIET_PROMPT_MIN_BYTES:=4000}"   # below this, inject the prompt whole

f="${1:?usage: quiet-prompt.sh <prompt-file> [--section NAME | --all]}"
[ -f "$f" ] || exit 0

# normalize a heading: strip leading "## " and a trailing " [ref]" tag -> bare name
case "${2:-}" in
  --all) cat "$f"; exit 0 ;;
  --section)
    name="${3:?usage: --section NAME}"
    awk -v want="$name" '
      function bare(h){ sub(/^##[[:space:]]+/,"",h); sub(/[[:space:]]*\[ref\][[:space:]]*$/,"",h); return h }
      /^##[[:space:]]+/ {
        if (inblk) exit
        if (bare($0) == want) { inblk = 1; print; next }
      }
      inblk { print }
    ' "$f"
    exit 0 ;;
esac

bytes=$(wc -c <"$f" 2>/dev/null || echo 0)
nref=$(grep -cE '^##[[:space:]]+.*\[ref\][[:space:]]*$' "$f" 2>/dev/null)
nref=${nref:-0}

# Nothing to gain: small prompt, or no section opted into spilling => inject whole (safe).
if [ "$bytes" -lt "${QUIET_PROMPT_MIN_BYTES}" ] || [ "$nref" -eq 0 ]; then
  cat "$f"; exit 0
fi

# Split: print preamble + untagged sections inline; replace [ref] section bodies with a
# pointer; collect the spilled names for a "load on demand" footer.
awk -v sh="$QPDIR/quiet-prompt.sh" -v file="$f" '
  function bare(h){ sub(/^##[[:space:]]+/,"",h); sub(/[[:space:]]*\[ref\][[:space:]]*$/,"",h); return h }
  BEGIN { reflist = "" }
  /^##[[:space:]]+/ {
    if ($0 ~ /\[ref\][[:space:]]*$/) {
      inref = 1
      name = bare($0)
      reflist = reflist (reflist=="" ? "" : "\n") "  • " name
      next
    } else {
      inref = 0
      print; next
    }
  }
  inref { next }      # drop spilled section bodies
  { print }
  END {
    if (reflist != "") {
      print ""
      print "[quiet-bash] Reference material below is on disk — load a section when the task needs it:"
      print reflist
      printf "Read one:  %s %s --section \"<name>\"\n", sh, file
    }
  }
' "$f"
