#!/usr/bin/env bash
#
# quiet-outline — signature skeleton for a large source file (zero-dep).
#
#   quiet-outline.sh <file>
#
# Prints imports + class/function/method signatures with bodies elided, each
# with the exact line range to expand it (Read <file> offset=S limit=N). The
# file is never modified and IS the byte-exact backup. If fewer than
# QUIET_OUTLINE_MIN_SYMBOLS symbols are found, or the extension is not a known
# source type, it `exec cat`s the file so the caller's normal handling applies.
#
# Symbol start-lines come from `grep -nE` (reliable ERE); body ranges + render
# are an awk pass over the file (no dynamic awk regex; bash-3.2 safe).

QODIR="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$QODIR/quiet-core.sh"

f="${1:?usage: quiet-outline.sh <file>}"
[ -f "$f" ] || exec cat "$f"

base="${f##*/}"; ext="${base##*.}"
lang=""; sig=""
case "$ext" in
  py) lang="Python"
      sig='^[[:space:]]*(async[[:space:]]+def|def|class)[[:space:]]' ;;
  js|mjs|cjs|jsx|ts|tsx) lang="JS/TS"
      sig='^[[:space:]]*((export([[:space:]]+default)?[[:space:]]+)?(async[[:space:]]+)?(function\*?|class|interface|type|enum)[[:space:]]|(export[[:space:]]+)?(const|let|var)[[:space:]]+[A-Za-z0-9_$]+[[:space:]]*=[[:space:]]*(async[[:space:]]+)?(\(|function|[A-Za-z0-9_$]+[[:space:]]*=>))' ;;
  go) lang="Go"
      sig='^(func|type)[[:space:]]' ;;
  rs) lang="Rust"
      sig='^[[:space:]]*(pub[[:space:]]+)?(async[[:space:]]+)?(fn|struct|enum|trait|impl|mod)[[:space:]]' ;;
  java) lang="Java"
      sig='^[[:space:]]*(public|private|protected|static|final|abstract|class|interface|enum)[[:space:]]' ;;
  kt|kts) lang="Kotlin"
      sig='^[[:space:]]*(fun|class|interface|object|enum|val|var)[[:space:]]' ;;
  scala) lang="Scala"
      sig='^[[:space:]]*(def|class|object|trait|case[[:space:]]+class)[[:space:]]' ;;
  rb) lang="Ruby"
      sig='^[[:space:]]*(def|class|module)[[:space:]]' ;;
  c|h|cc|cpp|cxx|hpp) lang="C/C++"
      sig='^[[:space:]]*(struct|class|enum|typedef)[[:space:]]|^[A-Za-z_][A-Za-z0-9_<>:,*& ]*[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' ;;
  php) lang="PHP"
      sig='^[[:space:]]*((public|private|protected|static|abstract|final)[[:space:]]+)*(function|class|interface|trait)[[:space:]]' ;;
  swift) lang="Swift"
      sig='^[[:space:]]*((public|private|internal|fileprivate|open|final|static|override)[[:space:]]+)*(func|class|struct|enum|protocol|extension)[[:space:]]' ;;
  *) exec cat "$f" ;;   # not a known source extension → leave it
esac

# Enforce byte threshold: pass through small files
[ "$(wc -c <"$f" 2>/dev/null || echo 0)" -lt "${QUIET_OUTLINE_MIN_BYTES}" ] && exec cat "$f"

import_re='^[[:space:]]*(import|from|#include|use|require|using|package)([[:space:]]|\()'

sym_lines=$(grep -nE "$sig" "$f" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
imp_lines=$(grep -nE "$import_re" "$f" 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
n=$(printf '%s' "$sym_lines" | wc -w | tr -d ' ')
[ "$n" -lt "${QUIET_OUTLINE_MIN_SYMBOLS}" ] && exec cat "$f"

out=$(awk -v syms="$sym_lines" -v imps="$imp_lines" -v minsym="${QUIET_OUTLINE_MIN_SYMBOLS}" '
BEGIN{
  ns=split(syms, SA, " "); cnt=0
  for(i=1;i<=ns;i++) if(SA[i]!=""){ cnt++; order[cnt]=SA[i]+0 }
  ni=split(imps, IA, " ")
  for(i=1;i<=ni;i++) if(IA[i]!=""){ if(!ifirst) ifirst=IA[i]+0; ilast=IA[i]+0 }
}
{ L[NR]=$0 }
END{
  total=NR
  if(cnt<minsym){ print "@@FALLBACK@@"; exit }
  if(ifirst) printf "%6d  imports ... (lines %d-%d)\n", ifirst, ifirst, ilast
  for(k=1;k<=cnt;k++){
    s=order[k]; e=(k<cnt ? order[k+1]-1 : total)
    t=L[s]; sub(/[[:space:]]+$/,"",t)
    if(length(t)>200) t=substr(t,1,200) "..."
    printf "%6d  %s   body %d-%d\n", s, t, s, e
  }
  printf "@@META@@ %d %d\n", cnt, total
}' "$f")

case "$out" in *"@@FALLBACK@@"*) exec cat "$f" ;; esac

meta=$(printf '%s\n' "$out" | sed -n 's/^@@META@@ //p')
n=${meta%% *}; total=${meta##* }
body=$(printf '%s\n' "$out" | grep -v '^@@META@@')
bytes=$(wc -c <"$f" | tr -d ' ')

first=$(printf '%s\n' "$body" | sed -n 's/.*body \([0-9]*\)-\([0-9]*\)$/\1 \2/p' | head -1)
# shellcheck disable=SC2086
set -- $first
es="${1:-1}"; ee="${2:-1}"; en=$((ee-es+1))

printf '[quiet-bash] %s - %d lines / %d bytes of %s - outline (bodies elided; expand: Read %s offset=<start> limit=<n>)\n' \
  "$base" "$total" "$bytes" "$lang" "$f"
printf '%s\n' "$body"
printf '  [%d symbols - full body: Read %s offset=%d limit=%d - raw: sed -n %d,%dp %s]\n' \
  "$n" "$f" "$es" "$en" "$es" "$ee" "$f"
