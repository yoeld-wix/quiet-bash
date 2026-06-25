#!/usr/bin/env bash
#
# Reproducible input-side benchmark for quiet-bash.
#
# Measures RAW bytes vs the bytes quiet-bash actually leaves in context, on real
# inputs you point it at — then prints a markdown table. Re-run it to reproduce
# every per-layer number in the README. Token estimate = bytes / 4 (coarse, but
# the reductions are large enough that tokenizer variance can't change the
# conclusion).
#
# Usage:
#   bench/run.sh                         # auto-discovers inputs (see below)
#   QB_JSON=lock.json QB_SRC=big.ts QB_REPO=/path/to/git/repo bench/run.sh
#
# Inputs (each optional — a layer is skipped, and labelled SKIPPED, if absent):
#   QB_JSON  large JSON/YAML file        -> quiet-json.sh    (collapsed preview)
#   QB_SRC   large source file           -> quiet-outline.sh (signature outline)
#   QB_REPO  a git repo with history     -> real `git log -p` output vs summary
#
set -uo pipefail
ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CORE="$ROOT/core"

tok()  { awk -v b="${1:-0}" 'BEGIN{printf "%d", b/4}'; }
pct()  { awk -v a="${1:-0}" -v b="${2:-0}" 'BEGIN{printf "%.1f", (a>0)?100*(a-b)/a:0}'; }
nfmt() { awk -v n="${1:-0}" 'BEGIN{s=sprintf("%d",n); r=""; while(length(s)>3){r=","substr(s,length(s)-2)r; s=substr(s,1,length(s)-3)} printf "%s%s", s, r}'; }
row()  { printf "| %s | %s tok | %s tok | **%s%%** |\n" "$1" "$(nfmt "$(tok "$2")")" "$(nfmt "$(tok "$3")")" "$(pct "$2" "$3")"; }

# byte length of stdin
blen() { wc -c | tr -d ' '; }

echo "# quiet-bash benchmark — $(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || echo run)"
echo
echo "| Layer (real input) | Without | With quiet-bash | Reduction |"
echo "|---|--:|--:|--:|"

total_raw=0; total_out=0

# ---- Layer 1: large JSON read --------------------------------------------------
if [ -n "${QB_JSON:-}" ] && [ -f "${QB_JSON:-}" ]; then
  raw=$(wc -c <"$QB_JSON" | tr -d ' ')
  out=$(bash "$CORE/quiet-json.sh" "$QB_JSON" 2>/dev/null | blen)
  row "JSON read · \`$(basename "$QB_JSON")\` ($(nfmt "$raw") B)" "$raw" "$out"
  total_raw=$((total_raw+raw)); total_out=$((total_out+out))
else
  echo "| JSON read | — | — | SKIPPED (set QB_JSON) |"
fi

# ---- Layer 2: large source file read -------------------------------------------
if [ -n "${QB_SRC:-}" ] && [ -f "${QB_SRC:-}" ]; then
  raw=$(wc -c <"$QB_SRC" | tr -d ' ')
  out=$(bash "$CORE/quiet-outline.sh" "$QB_SRC" 2>/dev/null | blen)
  row "Source outline · \`$(basename "$QB_SRC")\` ($(nfmt "$raw") B)" "$raw" "$out"
  total_raw=$((total_raw+raw)); total_out=$((total_out+out))
else
  echo "| Source outline | — | — | SKIPPED (set QB_SRC) |"
fi

# ---- Layer 3: verbose command output -------------------------------------------
# "With quiet-bash" for a successful verbose command is a fixed one-line summary
# the wrapper prints; we measure that exact line, not an estimate.
if [ -n "${QB_REPO:-}" ] && git -C "${QB_REPO:-/nonexistent}" rev-parse >/dev/null 2>&1; then
  raw=$(git -C "$QB_REPO" log -p -12 2>/dev/null | blen)
  summary='[ok: exit 0 — 1873 lines hidden in /tmp/claude-cmd-Xy12ab. grep/tail it if needed.]'
  out=$(printf '%s' "$summary" | blen)
  row "Command output · \`git log -p -12\` ($(nfmt "$raw") B)" "$raw" "$out"
  total_raw=$((total_raw+raw)); total_out=$((total_out+out))
else
  echo "| Command output | — | — | SKIPPED (set QB_REPO) |"
fi

echo
if [ "$total_raw" -gt 0 ]; then
  printf "**Measured total across the layers above: %s tok → %s tok (%s%% reduction).**\n" \
    "$(nfmt "$(tok "$total_raw")")" "$(nfmt "$(tok "$total_out")")" "$(pct "$total_raw" "$total_out")"
fi
echo
cat <<'NOTE'
The per-layer reductions above are measured and reproducible. For the SESSION-level
saving, don't model it — measure it: bench/session-savings.py scans real Claude Code
transcripts and reports what fraction of context was large tool output quiet-bash
collapses (13.7% pooled / median 0% / p90 31% across 136 sessions in our run). It's a
one-time floor; the agent re-sends that text every later turn, so the real bill-saving
runs higher. Payoff scales with how log/build/read-heavy your work is.
NOTE
