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
# Matching + body ranges + render are a SINGLE awk pass over the file (no
# grep/cut/tr pipeline — ~4x faster). The per-language regexes are passed via
# ENVIRON (not -v) so awk does not mangle backslash escapes in complex patterns.

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

# Enforce byte threshold: pass through small files (one wc, reused for header).
bytes=$(wc -c <"$f" 2>/dev/null || echo 0)
[ "$bytes" -lt "${QUIET_OUTLINE_MIN_BYTES}" ] && exec cat "$f"

import_re='^[[:space:]]*(import|from|#include|use|require|using|package)([[:space:]]|\()'

# Single awk pass: match signatures + imports (regexes via ENVIRON to preserve
# backslash escapes), compute body ranges, and render the full outline. awk
# exits 3 when below the symbol floor → fall back to cat.
out=$(QUIET_SIG="$sig" QUIET_IMP="$import_re" awk \
  -v lang="$lang" -v base="$base" -v path="$f" -v bytes="$bytes" \
  -v minsym="${QUIET_OUTLINE_MIN_SYMBOLS}" '
BEGIN{ sig=ENVIRON["QUIET_SIG"]; imp=ENVIRON["QUIET_IMP"] }
$0 ~ sig { si[++n]=NR; st[n]=$0 }
$0 ~ imp { if(!ifirst) ifirst=NR; ilast=NR }
END{
  total=NR
  if(n<minsym) exit 3
  printf "[quiet-bash] %s - %d lines / %d bytes of %s - outline (bodies elided; expand: Read %s offset=<start> limit=<n>)\n", base, total, bytes, lang, path
  if(ifirst) printf "%6d  imports ... (lines %d-%d)\n", ifirst, ifirst, ilast
  es=1; ee=1
  for(k=1;k<=n;k++){
    s=si[k]; e=(k<n ? si[k+1]-1 : total)
    t=st[k]; sub(/[[:space:]]+$/,"",t)
    if(length(t)>200) t=substr(t,1,200) "..."
    printf "%6d  %s   body %d-%d\n", s, t, s, e
    if(k==1){ es=s; ee=e }
  }
  en=ee-es+1; if(en<1) en=1
  printf "  [%d symbols - full body: Read %s offset=%d limit=%d - raw: sed -n %d,%dp %s]\n", n, path, es, en, es, ee, path
}' "$f")
ast=$?

{ [ "$ast" -eq 3 ] || [ -z "$out" ]; } && exec cat "$f"
printf '%s\n' "$out"
