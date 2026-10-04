#!/usr/bin/env bash
# clean-check.sh — read-only instrument: lists leftovers a run should not leave behind (kit issue
# #1277, the NO-GARBAGE rule). Contract: clean-check.v1.md (read it first).
#
# Usage: clean-check.sh [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR]
#   (a) GARBAGE untracked <path>          untracked, non-ignored file in the target repo that no
#                                         <TARGET>/.research-sdd/keep.txt glob keeps
#   (b) GARBAGE stale-tmp <path> age=<h>h tmp.* entry directly under --tmp, older than the stale
#                                         age (default 24 h) and owned by the current user
#   (c) UNPRESERVED-ARTIFACT <file> cited by <block>   (kit #1207) a file in the session scratchpad
#                                         (--scratchpad DIR, else $CLEAN_CHECK_SCRATCHPAD) whose basename or
#                                         full path is mentioned (as a whole path component, never a substring) by
#                                         an .md block of the target (SCRIPTS-MANIFEST.md files excluded; skipped
#                                         when a byte-identical copy already sits under sources/probes/): evidence about
#                                         to be lost - preserve it under sources/probes/b<N>/ first
#   (d) UNMANIFESTED-SCRIPT <file>        (kit #1207) a scratchpad script (sh ps1 py java js rb pl bat cmd
#                                         groovy kts) whose basename is not the FIRST table cell of any row of
#                                         <TARGET>/sources/probes/**/SCRIPTS-MANIFEST.md (exact match)
#   Scratchpad state is never a silent zero: unset -> summary `scratchpad: not set`; configured but missing
#   -> a typed `ABSENT-SCRATCHPAD <path>` line + `scratchpad: absent`; otherwise `scratchpad: N file(s)`.
# Prints nothing else on a clean run except the final `CLEAN-CHECK: ...` summary.
# Exit: 0 clean · 1 findings · 2 usage / not a git work tree / absent dir / scan failure ·
#       3 DEGRADED (a tool named in REQUIRED_TOOLS below is missing — nothing measured).
# propose-never-apply: this script never deletes, moves, or writes anything.

set -uo pipefail
# An inherited repository selector would point git at a DIFFERENT repo than --target.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

_err() { printf 'clean-check: ERROR: %s\n' "$1" >&2; }
_usage() { printf 'Usage: %s [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR]\n' "${0##*/}" >&2; }

TARGET=""; TMPD=""; STALE_H=24; SCRATCH_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target)      [ $# -ge 2 ] || { _usage; _err "--target needs a value"; exit 2; }; TARGET="$2"; shift 2 ;;
    --tmp)         [ $# -ge 2 ] || { _usage; _err "--tmp needs a value"; exit 2; }; TMPD="$2"; shift 2 ;;
    --scratchpad)  [ $# -ge 2 ] || { _usage; _err "--scratchpad needs a value"; exit 2; }; SCRATCH_ARG="$2"; shift 2 ;;
    --stale-hours) [ $# -ge 2 ] || { _usage; _err "--stale-hours needs a value"; exit 2; }; STALE_H="$2"; shift 2 ;;
    -h|--help)     _usage; exit 0 ;;
    *)             _usage; _err "unknown argument: $1"; exit 2 ;;
  esac
done
# Decimal digits only, at most 9 (no arithmetic overflow); a leading zero (08, 010) is still decimal.
case "$STALE_H" in ''|*[!0-9]*|??????????*) _usage; _err "--stale-hours must be a decimal integer of at most 9 digits: '$STALE_H'"; exit 2 ;; esac
STALE_H=$((10#$STALE_H))

# SENTINEL-DEGRADED-PROBE: a missing dependency is a typed DEGRADED, never a quiet clean (§7).
REQUIRED_TOOLS="git find date sort id stat"   # the single list: the probe below and the header/doc refer to it
for _tool in $REQUIRED_TOOLS; do
  command -v "$_tool" >/dev/null 2>&1 || { printf 'clean-check: DEGRADED: %s not found on PATH; nothing was measured\n' "$_tool" >&2; exit 3; }
done

OWNER_UID="${CLEAN_CHECK_UID:-}"
if [ -z "$OWNER_UID" ]; then OWNER_UID="$(id -u 2>/dev/null)" || OWNER_UID=""; fi
case "$OWNER_UID" in ''|*[!0-9]*) _err "cannot determine the owner uid ('$OWNER_UID')"; exit 2 ;; esac

[ -n "$TARGET" ] || TARGET="$PWD"
[ -d "$TARGET" ] || { _err "target not found: $TARGET"; exit 2; }
TARGET_P="$(cd -P -- "$TARGET" && pwd -P)" || { _err "cannot enter target: $TARGET"; exit 2; }
# stdout alone decides: a successful git may still print warnings on stderr (unreadable config, deprecation)
# and those must not turn a work tree into a failure. Only when the check fails is git rerun, stderr only,
# to report git's own reason (dubious ownership, a broken git) - never a guess like "not a work tree".
if _inside="$(git -C "$TARGET_P" rev-parse --is-inside-work-tree 2>/dev/null)"; then
  [ "$_inside" = "true" ] || { _err "target is not inside a git work tree: $TARGET"; exit 2; }
else
  _gmsg="$(git -C "$TARGET_P" rev-parse --is-inside-work-tree 2>&1 >/dev/null)"; _gmsg="${_gmsg//$'\n'/ }"
  _err "git rev-parse failed for target $TARGET: ${_gmsg:-git exited non-zero without output}"; exit 2
fi
[ -n "$TMPD" ] || TMPD="${TMPDIR:-/tmp}"
TMPD="${TMPD%/}"; [ -n "$TMPD" ] || TMPD="/"
[ -d "$TMPD" ] || { _err "tmp dir not found: $TMPD"; exit 2; }
TMPD_P="$(cd -P -- "$TMPD" && pwd -P)" || { _err "cannot enter tmp dir: $TMPD"; exit 2; }

SCRATCH_P=""
[ -n "$SCRATCH_ARG" ] && CLEAN_CHECK_SCRATCHPAD="$SCRATCH_ARG"
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
# git's and find's stderr is deliberately NOT discarded: on failure it is the diagnostic.
# The list is read with an explicit RC marker as its last NUL-terminated element, so a git run that
# failed or was cut short cannot read as an empty (clean) list.
_items=()
while IFS= read -r -d '' _p; do _items+=("$_p"); done < <(
  git -C "$TARGET_P" ls-files --others --exclude-standard -z
  printf 'RC=%s\0' "$?"
)
_last=$(( ${#_items[@]} - 1 ))
{ [ "$_last" -ge 0 ] && [ "${_items[$_last]}" = "RC=0" ]; } || { _err "git ls-files failed or was truncated in $TARGET"; exit 2; }
for ((_i = 0; _i < _last; _i++)); do
  _rel="${_items[$_i]}"
  _kept "$_rel" && continue
  _in_scratch "$TARGET_P/$_rel" && continue
  printf 'GARBAGE untracked %s\n' "$_rel"
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
  find "$TMPD_P" ${FIND_RACE[@]+"${FIND_RACE[@]}"} -mindepth 1 -maxdepth 1 -name 'tmp.*' -uid "$OWNER_UID" -mmin "+$((STALE_H * 60))" -print0
  printf 'RC=%s\0' "$?"
)
_last=$(( ${#_items[@]} - 1 ))
{ [ "$_last" -ge 0 ] && [ "${_items[$_last]}" = "RC=0" ]; } || { _err "find failed or was truncated in $TMPD"; exit 2; }
_now="$(date +%s)"
# The sort step carries its own RC marker (producer and sort both), so a failing sort cannot shrink the
# list to nothing and read as a quiet clean.
_sorted=(); _slast=-1
if [ "$_last" -gt 0 ]; then
  while IFS= read -r -d '' _p; do _sorted+=("$_p"); done < <(
    printf '%s\0' "${_items[@]:0:$_last}" | sort -z
    _pst=("${PIPESTATUS[@]}")
    printf 'RC=%s\0' "$(( _pst[0] || _pst[1] ))"
  )
  _slast=$(( ${#_sorted[@]} - 1 ))
  { [ "$_slast" -ge 0 ] && [ "${_sorted[$_slast]}" = "RC=0" ]; } || { _err "sort failed or was truncated while ordering tmp.* entries in $TMPD"; exit 2; }
fi
for ((_i = 0; _i < _slast; _i++)); do
  _p="${_sorted[$_i]}"
  _in_scratch "$_p" && continue
  _m="$(_mtime "$_p")"
  if [ -n "$_m" ]; then _age="$(( (_now - _m) / 3600 ))h"; else _age="unknown"; fi
  printf 'GARBAGE stale-tmp %s/%s age=%s\n' "$TMPD" "${_p##*/}" "$_age"
  FINDINGS=$((FINDINGS + 1))
done

# _mentions <basename> <file>: whole-path-component mention (never a bare substring: run.sh is not prerun.sh,
# out is not layout). Before: start, '/', blank, backtick, quotes, brackets, '|', '<', '>' or '('. After: end, blank,
# backtick, quotes, brackets, '|', '<', '>', ')' , ',:;!?' or a '.' that ends the sentence. Returns grep's status (0 found, 1 none, 2 error).
_mentions() {
  local re; re="$(printf '%s' "$1" | sed 's#[][\.*^$+?(){}|/]#\\&#g')" || return 2
  grep -qE -- "(^|[][/[:space:]\`(\"'|<>])${re}(\$|[][[:space:]\`)\"',:;!?|<>]|\.(\$|[[:space:]]))" "$2"
}
# ---- (c)/(d) scratchpad artifacts a block mentions, scripts with no manifest row (kit #1207) --------
SCRATCH_STATE="not set"
if [ -n "$SCRATCH_P" ]; then
  if [ ! -d "$SCRATCH_P" ]; then   # CC-ABSENT
    printf 'ABSENT-SCRATCHPAD %s\n' "$SCRATCH_P"
    SCRATCH_STATE="absent"
  else
    _sf=()
    while IFS= read -r -d '' _p; do _sf+=("$_p"); done < <(
      find "$SCRATCH_P" -type f -print0 | sort -z
      _pst=("${PIPESTATUS[@]}")
      printf 'RC=%s\0' "$(( _pst[0] || _pst[1] ))"
    )
    _slast=$(( ${#_sf[@]} - 1 ))
    { [ "$_slast" -ge 0 ] && [ "${_sf[$_slast]}" = "RC=0" ]; } || { _err "find failed or was truncated in scratchpad $SCRATCH_P"; exit 2; }
    SCRATCH_STATE="$_slast file(s)"
    # blocks: every .md of the target (tracked or untracked) except the manifests themselves (a manifest row names
    # a script on purpose - it is the preservation record, not a citation). Tracked files deleted from disk are
    # listed by `git ls-files -co`: skipped and COUNTED, never a crash.
    _blk=(); _bmiss=0
    _braw=()
    while IFS= read -r -d '' _p; do _braw+=("$_p"); done < <(
      git -C "$TARGET_P" ls-files -co --exclude-standard -z -- '*.md'
      printf 'RC=%s\0' "$?"
    )
    _blast=$(( ${#_braw[@]} - 1 ))
    { [ "$_blast" -ge 0 ] && [ "${_braw[$_blast]}" = "RC=0" ]; } || { _err "git ls-files failed or was truncated listing blocks in $TARGET"; exit 2; }
    for ((_j = 0; _j < _blast; _j++)); do
      _bp="${_braw[$_j]}"
      [ "${_bp##*/}" = "SCRIPTS-MANIFEST.md" ] && continue
      _in_scratch "$TARGET_P/$_bp" && continue
      [ -f "$TARGET_P/$_bp" ] || { _bmiss=$((_bmiss + 1)); continue; }   # CC-MISSING
      _blk+=("$_bp")
    done
    # manifests: the find carries its REAL exit status; a failed scan is DEGRADED, never "no manifests".
    _mf_names=""
    if [ -d "$TARGET_P/sources/probes" ]; then
      _mf=()
      while IFS= read -r -d '' _p; do _mf+=("$_p"); done < <(
        find "$TARGET_P/sources/probes" -type f -name SCRIPTS-MANIFEST.md -print0
        printf 'RC=%s\0' "$?"
      )
      _mlast=$(( ${#_mf[@]} - 1 ))
      { [ "$_mlast" -ge 0 ] && [ "${_mf[$_mlast]}" = "RC=0" ]; } || { printf 'clean-check: DEGRADED: manifest scan failed under %s/sources/probes; UNMANIFESTED-SCRIPT not evaluated\n' "$TARGET_P" >&2; exit 3; }   # CC-MF-RC
      for ((_j = 0; _j < _mlast; _j++)); do
        # first cell of each table row, backticks/blanks stripped, directory part dropped: matched EXACTLY below
        _o="$(awk -F'|' '/^[[:space:]]*\|/ { a = $2; gsub(/[`[:space:]]/, "", a); n = split(a, q, "/"); if (q[n] != "") print q[n] }' "${_mf[$_j]}")" \
          || { _err "cannot read manifest ${_mf[$_j]}"; exit 2; }
        _mf_names="$_mf_names"$'\n'"$_o"
      done
    fi
    # preserved copies: sha256 of every file already under sources/probes (byte-identical copy => preserved)
    _sha_cmd=""
    if command -v sha256sum >/dev/null 2>&1; then _sha_cmd="sha256sum"; elif command -v shasum >/dev/null 2>&1; then _sha_cmd="shasum -a 256"; fi
    _probe_shas=""; _pres=0
    if [ -n "$_sha_cmd" ] && [ -d "$TARGET_P/sources/probes" ]; then
      _pl=()
      while IFS= read -r -d '' _p; do _pl+=("$_p"); done < <(
        find "$TARGET_P/sources/probes" -type f -print0
        printf 'RC=%s\0' "$?"
      )
      _plast=$(( ${#_pl[@]} - 1 ))
      { [ "$_plast" -ge 0 ] && [ "${_pl[$_plast]}" = "RC=0" ]; } || { printf 'clean-check: DEGRADED: probes scan failed under %s/sources/probes; preserved copies not evaluated\n' "$TARGET_P" >&2; exit 3; }
      for ((_j = 0; _j < _plast; _j++)); do
        _probe_shas="$_probe_shas"$'\n'"$($_sha_cmd -- "${_pl[$_j]}" 2>/dev/null | cut -d' ' -f1)"
      done
    fi
    [ -n "$_sha_cmd" ] || printf 'DEGRADED-NO-SHA256 %s\n' "preserved-copy check skipped (no sha256sum/shasum on PATH)"
    for ((_i = 0; _i < _slast; _i++)); do
      _f="${_sf[$_i]}"; _b="${_f##*/}"
      _citer=""
      for _bp in ${_blk[@]+"${_blk[@]}"}; do
        _mentions "$_b" "$TARGET_P/$_bp"; _g=$?   # CC-CITE-GREP
        case "$_g" in
          0) _citer="$_bp"; break ;;
          1) ;;
          *) _err "grep failed reading block $_bp"; exit 2 ;;
        esac
      done
      if [ -n "$_citer" ]; then
        _same=0
        if [ -n "$_sha_cmd" ] && [ -n "$_probe_shas" ]; then
          _h="$($_sha_cmd -- "$_f" 2>/dev/null | cut -d' ' -f1)"
          if [ -n "$_h" ] && grep -qxF -- "$_h" <<<"$_probe_shas"; then _same=1; fi   # CC-PRESERVED
        fi
        if [ "$_same" = 1 ]; then _pres=$((_pres + 1))
        else
          printf 'UNPRESERVED-ARTIFACT %s cited by %s\n' "$_f" "$_citer"
          FINDINGS=$((FINDINGS + 1))
        fi
      fi
      case "$_b" in
        *.sh|*.ps1|*.py|*.java|*.js|*.rb|*.pl|*.bat|*.cmd|*.groovy|*.kts)   # CC-SCRIPT-EXT
          if ! grep -qxF -- "$_b" <<<"$_mf_names"; then   # CC-MANIFEST-LOOKUP
            printf 'UNMANIFESTED-SCRIPT %s\n' "$_f"
            FINDINGS=$((FINDINGS + 1))
          fi ;;
      esac
    done
    SCRATCH_STATE="$_slast file(s), blocks-missing-on-disk: $_bmiss, preserved-copies: $_pres"
  fi
fi

# ---- summary ---------------------------------------------------------------------------------
_scanned="untracked in $TARGET, tmp.* in $TMPD older than ${STALE_H}h, keep-list entries: $KEEP_N, scratchpad: $SCRATCH_STATE"
if [ "$FINDINGS" -eq 0 ]; then
  printf 'CLEAN-CHECK: clean (%s)\n' "$_scanned"
  exit 0
fi
printf 'CLEAN-CHECK: %s finding(s) (%s)\n' "$FINDINGS" "$_scanned"
exit 1
