#!/usr/bin/env bash
#
# quiet-dedup — session-scoped duplicate-read detector (sourced helper).
#
# When an agent re-Reads a file it already read THIS SESSION and the file is
# unchanged (same mtime+size, same byte-range), the bytes are already verbatim
# earlier in context — re-sending them just re-bills the transcript. This helper
# detects that case so the hook can replace the re-emitted body with a stub.
# Lossless (content is above), session-scoped, and only ever applied to the
# just-emitted result (tail edit → prompt-cache safe).

# Whole-second mtime, cross-platform. GNU FIRST (stat -c %Y): on GNU, BSD's
# `stat -f` is --file-system and leaks filesystem output to stdout even when the
# format is invalid, which would corrupt the captured value; trying the GNU flag
# first avoids ever invoking `stat -f` on GNU. `head -1` is belt-and-suspenders
# against any platform that prints extra lines. Dedup only needs a stable value,
# not sub-second precision.
_quiet_mtime() {
  { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; } | head -1
}

# quiet_dedup_check <session_id> <path> <offset> <limit>
#   prints stub + returns 0  -> dedup (unchanged repeat read)
#   no output  + returns 1   -> pass through (and upsert the record)
quiet_dedup_check() {
  local sid="$1" path="$2" off="${3:-}" lim="${4:-}"
  [ -n "$sid" ] && [ -n "$path" ] && [ -f "$path" ] || return 1
  local safe key state cmt csz prev=""   # init: bash 5 errors on unset under `set -u`
  safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')
  state="${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}dedup-${safe}"
  key=$(printf '%s|%s|%s' "$path" "$off" "$lim" | cksum | cut -d' ' -f1)
  cmt=$(_quiet_mtime "$path")
  csz=$(wc -c <"$path" 2>/dev/null | tr -d ' '); csz=${csz:-0}
  if [ -f "$state" ]; then
    prev=$(awk -v k="$key" '$1==k{m=$2; s=$3} END{ if (m!="") print m" "s }' "$state" 2>/dev/null)
  fi
  if [ -n "$prev" ] && [ "$prev" = "$cmt $csz" ]; then
    printf '[quiet-bash] %s is unchanged since you read it earlier this session — its full contents are already above. (To force a fresh read: touch the file, or read a different line range.)' "$path"
    return 0
  fi
  # upsert: drop any existing record for this key, append the fresh one
  { [ -f "$state" ] && grep -v -E "^${key} " "$state" 2>/dev/null
    printf '%s %s %s\n' "$key" "$cmt" "$csz"
  } > "${state}.tmp" 2>/dev/null && mv "${state}.tmp" "$state" 2>/dev/null
  return 1
}

# quiet_cmd_dedup <session_id> <cmd>
#   The Bash-path twin of quiet_dedup_check: a plain repeat read of ONE unchanged
#   file via cat/bat/less/more/head/tail (no pipe/redirect/glob/chaining) is bytes
#   already in context — re-running just re-bills them. On an unchanged repeat,
#   prints a rewritten command (`echo <stub>`) and returns 0; else returns 1.
#   Shares dedup state with quiet_dedup_check, so a `cat X` after a `Read X`
#   (or vice-versa) is recognised. Lossless (content above; file on disk).
quiet_cmd_dedup() {
  local sid="$1" cmd="$2" tok f="" files=0
  [ -n "$sid" ] || return 1
  case "$cmd" in *'|'*|*'>'*|*'<'*|*'$('*|*'`'*|*';'*|*'&'*|*'*'*|*'?'*|*'['*) return 1 ;; esac
  printf '%s' "$cmd" | grep -qE '^[[:space:]]*(cat|bat|less|more|head|tail)([[:space:]]|$)' || return 1
  for tok in $cmd; do
    case "$tok" in -*) ;; *) if [ -f "$tok" ]; then f="$tok"; files=$((files+1)); fi ;; esac
  done
  [ "$files" = 1 ] || return 1           # exactly one file → safe to dedup
  local stub
  if stub=$(quiet_dedup_check "$sid" "$f" "" ""); then
    printf 'echo %q' "$stub"
    return 0
  fi
  return 1
}

# quiet_diff_reread <session_id> <path> <content>   (OPT-IN: QUIET_DIFF_REREAD=1)
#   When a file is re-read after CHANGING this session, the agent usually only
#   needs what changed. If a unified diff vs the last-read snapshot is much
#   smaller than the full content, print it (lossless — full file is on disk at
#   <path>) and return 0; else return 1 (show full). Off by default → no
#   behaviour change unless explicitly enabled. Snapshots live under the log dir
#   and are pruned with everything else.
quiet_diff_reread() {
  [ -n "${QUIET_DIFF_REREAD:-}" ] || return 1
  local sid="$1" path="$2" content="$3"
  [ -n "$sid" ] && [ -n "$path" ] || return 1
  local safe ph snap
  safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')
  ph=$(printf '%s' "$path" | cksum | cut -d' ' -f1)
  snap="${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}snap-${safe}-${ph}"
  if [ -f "$snap" ] && ! printf '%s' "$content" | cmp -s - "$snap"; then
    local cur diff csz dsz
    cur=$(mktemp "${QUIET_LOG_DIR}/${QUIET_LOG_PREFIX}cur-XXXXXX")
    printf '%s' "$content" > "$cur"
    diff=$(diff -u "$snap" "$cur" 2>/dev/null)
    csz=$(printf '%s' "$content" | wc -c | tr -d ' ')
    dsz=$(printf '%s' "$diff" | wc -c | tr -d ' ')
    mv "$cur" "$snap" 2>/dev/null || { cp "$cur" "$snap" 2>/dev/null; rm -f "$cur" 2>/dev/null; }
    if [ -n "$diff" ] && [ "$dsz" -lt "$((csz/2))" ]; then
      printf '[quiet-bash] %s changed since you last read it this session — unified diff below (full current file is on disk, unchanged, at %s):\n%s' "$path" "$path" "$diff"
      return 0
    fi
    return 1   # diff not smaller than full → let the full content through
  fi
  printf '%s' "$content" > "$snap" 2>/dev/null   # first read / identical → (re)snapshot
  return 1
}
