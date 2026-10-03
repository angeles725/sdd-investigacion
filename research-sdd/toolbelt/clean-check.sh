#!/usr/bin/env bash
# clean-check.sh — read-only instrument: lists leftovers a run should not leave behind (kit issue
# #1277, the NO-GARBAGE rule). Contract: clean-check.v1.md (read it first).
#
# Usage: clean-check.sh [--target DIR] [--tmp DIR] [--stale-hours N]
#   (a) GARBAGE untracked <path>          untracked, non-ignored file in the target repo that no
#                                         <TARGET>/.research-sdd/keep.txt glob keeps
#   (b) GARBAGE stale-tmp <path> age=<h>h tmp.* entry directly under --tmp, older than the stale
#                                         age (default 24 h) and owned by the current user
# Prints nothing else on a clean run except the final `CLEAN-CHECK: ...` summary.
# Exit: 0 clean · 1 findings · 2 usage / not a git work tree / absent dir / scan failure ·
#       3 DEGRADED (a tool named in REQUIRED_TOOLS below is missing — nothing measured).
# propose-never-apply: this script never deletes, moves, or writes anything.

set -uo pipefail
# An inherited repository selector would point git at a DIFFERENT repo than --target.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

_err() { printf 'clean-check: ERROR: %s\n' "$1" >&2; }
_usage() { printf 'Usage: %s [--target DIR] [--tmp DIR] [--stale-hours N]\n' "$(basename "$0")" >&2; }

TARGET=""; TMPD=""; STALE_H=24
while [ $# -gt 0 ]; do
  case "$1" in
    --target)      [ $# -ge 2 ] || { _usage; _err "--target needs a value"; exit 2; }; TARGET="$2"; shift 2 ;;
    --tmp)         [ $# -ge 2 ] || { _usage; _err "--tmp needs a value"; exit 2; }; TMPD="$2"; shift 2 ;;
    --stale-hours) [ $# -ge 2 ] || { _usage; _err "--stale-hours needs a value"; exit 2; }; STALE_H="$2"; shift 2 ;;
    -h|--help)     _usage; exit 0 ;;
    *)             _usage; _err "unknown argument: $1"; exit 2 ;;
  esac
done
# Decimal digits only, at most 9 (no arithmetic overflow); a leading zero (08, 010) is still decimal.
case "$STALE_H" in ''|*[!0-9]*|??????????*) _usage; _err "--stale-hours must be a decimal integer of at most 9 digits: '$STALE_H'"; exit 2 ;; esac
STALE_H=$((10#$STALE_H))
OWNER_UID="${CLEAN_CHECK_UID:-}"
if [ -z "$OWNER_UID" ]; then OWNER_UID="$(id -u 2>/dev/null)" || OWNER_UID=""; fi
case "$OWNER_UID" in ''|*[!0-9]*) _err "cannot determine the owner uid ('$OWNER_UID')"; exit 2 ;; esac

# SENTINEL-DEGRADED-PROBE: a missing dependency is a typed DEGRADED, never a quiet clean (§7).
REQUIRED_TOOLS="git find date sort"   # the single list: the probe below and the header/doc refer to it
for _tool in $REQUIRED_TOOLS; do
  command -v "$_tool" >/dev/null 2>&1 || { printf 'clean-check: DEGRADED: %s not found on PATH; nothing was measured\n' "$_tool" >&2; exit 3; }
done

[ -n "$TARGET" ] || TARGET="$PWD"
[ -d "$TARGET" ] || { _err "target not found: $TARGET"; exit 2; }
TARGET_P="$(cd -P -- "$TARGET" && pwd -P)" || { _err "cannot enter target: $TARGET"; exit 2; }
_inside="$(git -C "$TARGET_P" rev-parse --is-inside-work-tree 2>/dev/null)" || _inside=""
[ "$_inside" = "true" ] || { _err "target is not inside a git work tree: $TARGET"; exit 2; }
[ -n "$TMPD" ] || TMPD="${TMPDIR:-/tmp}"
TMPD="${TMPD%/}"; [ -n "$TMPD" ] || TMPD="/"
[ -d "$TMPD" ] || { _err "tmp dir not found: $TMPD"; exit 2; }
TMPD_P="$(cd -P -- "$TMPD" && pwd -P)" || { _err "cannot enter tmp dir: $TMPD"; exit 2; }

SCRATCH_P=""
if [ -n "${CLEAN_CHECK_SCRATCHPAD:-}" ]; then
  SCRATCH_P="${CLEAN_CHECK_SCRATCHPAD%/}"
  if [ -d "$SCRATCH_P" ]; then SCRATCH_P="$(cd -P -- "$SCRATCH_P" && pwd -P)"; fi
fi
# _in_scratch <absolute path>: true when the path is the scratchpad or lies below it.
_in_scratch() {
  [ -n "$SCRATCH_P" ] || return 1
  [ "$1" = "$SCRATCH_P" ] && return 0
  case "$1" in "$SCRATCH_P"/*) return 0 ;; esac
  return 1
}

# ---- keep-list -------------------------------------------------------------------------------
KEEP_REL=".research-sdd/keep.txt"
KEEP_FILE="$TARGET_P/$KEEP_REL"
KEEP=(); KEEP_N=0
if [ -e "$KEEP_FILE" ]; then
  { [ -f "$KEEP_FILE" ] && [ -r "$KEEP_FILE" ]; } || { _err "keep-list is not a readable file: $KEEP_FILE"; exit 2; }
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%$'\r'}"
    _line="${_line#"${_line%%[![:space:]]*}"}"
    case "$_line" in ''|'#'*) continue ;; esac
    case "$_line" in *' #'*) _line="${_line%% #*}" ;; esac
    _line="${_line%"${_line##*[![:space:]]}"}"
    [ -n "$_line" ] || continue
    KEEP+=("$_line"); KEEP_N=$((KEEP_N + 1))
  done < "$KEEP_FILE"
  KEEP_PRESENT=1
else
  KEEP_PRESENT=0
fi
# _kept <relative path>: true when keep.txt keeps it (a trailing-slash glob keeps a whole tree).
_kept() {
  local p="$1" g
  [ "$p" = "$KEEP_REL" ] && return 0
  for g in ${KEEP[@]+"${KEEP[@]}"}; do
    case "$g" in
      */) # shellcheck disable=SC2053
          [[ "$p" == $g* ]] && return 0 ;;
      *)  # shellcheck disable=SC2053
          [[ "$p" == $g ]] && return 0 ;;
    esac
  done
  return 1
}

FINDINGS=0
[ "$KEEP_PRESENT" = 1 ] || printf 'ABSENT-KEEPLIST %s\n' "$KEEP_FILE"

# ---- (a) untracked, non-ignored files --------------------------------------------------------
# The list is read with an explicit RC marker as its last NUL-terminated element, so a git run that
# failed or was cut short cannot read as an empty (clean) list.
_items=()
while IFS= read -r -d '' _p; do _items+=("$_p"); done < <(
  git -C "$TARGET_P" ls-files --others --exclude-standard -z 2>/dev/null
  printf 'RC=%s\0' "$?"
)
_last=$(( ${#_items[@]} - 1 ))
{ [ "$_last" -ge 0 ] && [ "${_items[$_last]}" = "RC=0" ]; } || { _err "git ls-files failed or was truncated in $TARGET"; exit 2; }
for ((_i = 0; _i < _last; _i++)); do
  _p="${_items[$_i]}"
  _kept "$_p" && continue
  _in_scratch "$TARGET_P/$_p" && continue
  printf 'GARBAGE untracked %s\n' "$_p"
  FINDINGS=$((FINDINGS + 1))
done

# ---- (b) stale tmp.* entries -----------------------------------------------------------------
# _mtime <path>: the entry's own mtime in epoch seconds (GNU stat, then BSD stat); empty on failure.
_mtime() {
  local m
  m="$(stat -c %Y -- "$1" 2>/dev/null)" || m=""
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m -- "$1" 2>/dev/null)" || m="" ;; esac
  case "$m" in ''|*[!0-9]*) m="" ;; esac
  printf '%s' "$m"
}
# An entry vanishing between readdir and stat (a concurrent run cleaning its tmp.*) makes GNU find exit
# non-zero. -ignore_readdir_race (GNU) turns that benign race off; where find lacks the flag (BSD) the
# probe leaves it out and a race still surfaces as the loud exit 2 below — rerun, never a quiet clean.
FIND_RACE=()
if find "$TMPD_P" -ignore_readdir_race -maxdepth 0 >/dev/null 2>&1; then FIND_RACE=(-ignore_readdir_race); fi
_items=()
while IFS= read -r -d '' _p; do _items+=("$_p"); done < <(
  find "$TMPD_P" ${FIND_RACE[@]+"${FIND_RACE[@]}"} -mindepth 1 -maxdepth 1 -name 'tmp.*' -uid "$OWNER_UID" -mmin "+$((STALE_H * 60))" -print0 2>/dev/null
  printf 'RC=%s\0' "$?"
)
_last=$(( ${#_items[@]} - 1 ))
{ [ "$_last" -ge 0 ] && [ "${_items[$_last]}" = "RC=0" ]; } || { _err "find failed or was truncated in $TMPD"; exit 2; }
_now="$(date +%s)"
_sorted=()
if [ "$_last" -gt 0 ]; then
  while IFS= read -r -d '' _p; do _sorted+=("$_p"); done < <(printf '%s\0' "${_items[@]:0:$_last}" | sort -z)
fi
for _p in ${_sorted[@]+"${_sorted[@]}"}; do
  _in_scratch "$_p" && continue
  _m="$(_mtime "$_p")"
  if [ -n "$_m" ]; then _age="$(( (_now - _m) / 3600 ))h"; else _age="unknown"; fi
  printf 'GARBAGE stale-tmp %s/%s age=%s\n' "$TMPD" "${_p##*/}" "$_age"
  FINDINGS=$((FINDINGS + 1))
done

# ---- summary ---------------------------------------------------------------------------------
_scanned="untracked in $TARGET, tmp.* in $TMPD older than ${STALE_H}h, keep-list entries: $KEEP_N"
if [ "$FINDINGS" -eq 0 ]; then
  printf 'CLEAN-CHECK: clean (%s)\n' "$_scanned"
  exit 0
fi
printf 'CLEAN-CHECK: %s finding(s) (%s)\n' "$FINDINGS" "$_scanned"
exit 1
