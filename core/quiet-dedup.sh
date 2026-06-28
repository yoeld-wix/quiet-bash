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

# Sub-second mtime where available (BSD %Fm = fractional epoch, else GNU whole-second, else 0).
_quiet_mtime() {
  stat -f %Fm "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0
}

# quiet_dedup_check <session_id> <path> <offset> <limit>
#   prints stub + returns 0  -> dedup (unchanged repeat read)
#   no output  + returns 1   -> pass through (and upsert the record)
quiet_dedup_check() {
  local sid="$1" path="$2" off="${3:-}" lim="${4:-}"
  [ -n "$sid" ] && [ -n "$path" ] && [ -f "$path" ] || return 1
  local safe key state cmt csz prev
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
