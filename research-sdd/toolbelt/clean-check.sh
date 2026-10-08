#!/usr/bin/env bash
# clean-check.sh — read-only instrument: lists leftovers a run should not leave behind (kit issue
# #1277, the NO-GARBAGE rule). Contract: clean-check.v1.md (read it first).
#
# Usage: clean-check.sh [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR]
#                       [--base REF] [--evidence DIR] [--backup-days N]
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
#                                         groovy kts) whose basename is not the FIRST table cell of any VALID row (2nd cell = 64-hex sha256) of
#                                         <TARGET>/sources/probes/**/SCRIPTS-MANIFEST.md (exact match)
#   Scratchpad state is never a silent zero: unset -> summary `scratchpad: not set`; configured but missing
#   -> a typed `ABSENT-SCRATCHPAD <path>` line + `scratchpad: absent`; otherwise `scratchpad: N file(s)`.
#   Retention scans (kit #1277 slice 3) are REPORT-ONLY: typed `WARN <class> ...` lines that are counted in the
#   summary (`warnings: N`) but are NEVER findings - they cannot change the exit code (maintainer decision 2026-10-07):
#   (e) WARN stale-worktree <path> missing|prunable   a registered git worktree (not the main one) whose path is gone or
#                                         that git itself marks prunable
#   (f) WARN merged-branch <name> merged into <base>          a local branch already merged into the base
#       WARN merged-remote-branch <remote/name> merged into <base>   a remote-tracking ref already merged into the base
#       base = --base REF, else origin/HEAD, else local main, else master; none found -> typed ABSENT-BASE (scan skipped).
#       The base's own branch (and its local/remote twins) and any branch checked out in a worktree (the main one
#       included, so the branch HEAD is on) are never reported.
#   (g) WARN stale-backup <path> age=<d>d retention=<D>d      a rollback/backup entry (name contains `rollback` or
#                                         `backup`, case-insensitive) up to 2 levels under an `_evidence` directory
#                                         (--evidence DIR, else every `_evidence` dir found under the target, depth <= 4)
#                                         older than --backup-days (default 14)
#   A retention scan that cannot run (git worktree/for-each-ref failing, an unreadable evidence dir) is a typed
#   `DEGRADED-<SCAN> ...` line + a `degraded` summary (exit 3 when otherwise clean), never a quiet zero.
# Prints nothing else on a clean run except the final `CLEAN-CHECK: ...` summary.
# Exit: 0 clean (retention WARNs never change it) · 1 findings · 2 usage (an unresolvable --base included; checked before any scan prints) / not a git work tree / absent dir / scan failure (the
#       untracked, tmp, block, manifest and probes scans; a failing RETENTION scan is exit 3 DEGRADED, never 2) ·
#       3 DEGRADED (a tool named in REQUIRED_TOOLS below is missing — nothing measured; or no sha256sum/shasum, the
#         preserved-copy check was skipped, or a retention scan could not run: typed DEGRADED-* line + a `degraded` summary, exit 3 when otherwise clean, findings still win with 1).
# propose-never-apply: this script never deletes, moves, or writes anything.

set -uo pipefail
# An inherited repository selector would point git at a DIFFERENT repo than --target.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

_err() { printf 'clean-check: ERROR: %s\n' "$1" >&2; }
_usage() { printf 'Usage: %s [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR] [--base REF] [--evidence DIR] [--backup-days N]\n' "${0##*/}" >&2; }

TARGET=""; TMPD=""; STALE_H=24; SCRATCH_ARG=""; BASE_ARG=""; EVID_ARG=""; BACKUP_D=14
while [ $# -gt 0 ]; do
  case "$1" in
    --target)      [ $# -ge 2 ] || { _usage; _err "--target needs a value"; exit 2; }; TARGET="$2"; shift 2 ;;
    --tmp)         [ $# -ge 2 ] || { _usage; _err "--tmp needs a value"; exit 2; }; TMPD="$2"; shift 2 ;;
    --scratchpad)  [ $# -ge 2 ] || { _usage; _err "--scratchpad needs a value"; exit 2; }; SCRATCH_ARG="$2"; shift 2 ;;
    --base)        [ $# -ge 2 ] || { _usage; _err "--base needs a value"; exit 2; }; BASE_ARG="$2"; shift 2 ;;
    --evidence)    [ $# -ge 2 ] || { _usage; _err "--evidence needs a value"; exit 2; }; EVID_ARG="$2"; shift 2 ;;
    --backup-days) [ $# -ge 2 ] || { _usage; _err "--backup-days needs a value"; exit 2; }; BACKUP_D="$2"; shift 2 ;;
    --stale-hours) [ $# -ge 2 ] || { _usage; _err "--stale-hours needs a value"; exit 2; }; STALE_H="$2"; shift 2 ;;
    -h|--help)     _usage; exit 0 ;;
    *)             _usage; _err "unknown argument: $1"; exit 2 ;;
  esac
done
# Decimal digits only, at most 9 (no arithmetic overflow); a leading zero (08, 010) is still decimal.
case "$STALE_H" in ''|*[!0-9]*|??????????*) _usage; _err "--stale-hours must be a decimal integer of at most 9 digits: '$STALE_H'"; exit 2 ;; esac
STALE_H=$((10#$STALE_H))
case "$BACKUP_D" in ''|*[!0-9]*|??????????*) _usage; _err "--backup-days must be a decimal integer of at most 9 digits: '$BACKUP_D'"; exit 2 ;; esac
BACKUP_D=$((10#$BACKUP_D))

# SENTINEL-DEGRADED-PROBE: a missing dependency is a typed DEGRADED, never a quiet clean (§7).
REQUIRED_TOOLS="git find date sort id stat"   # the single list: the probe below and the header/doc refer to it
for _tool in $REQUIRED_TOOLS; do
  command -v "$_tool" >/dev/null 2>&1 || { printf 'clean-check: DEGRADED: %s not found on PATH; nothing was measured\n' "$_tool" >&2; exit 3; }
done

# kit #1659: the one shared SCRIPTS-MANIFEST row parser; fail closed when it cannot be loaded.
# kit #1676: loaded LAZILY by _cc_load_smlib, only when the target holds a SCRIPTS-MANIFEST (the scratchpad
# UNMANIFESTED-SCRIPT check is its only consumer); a run that needs no manifest never touches lib/.
# Resolved from THIS script's own directory with symlinks followed (BASH_SOURCE), never the caller's cwd or a lib/
# beside a symlink. A helper that cannot be loaded is exit 2 (it runs in the main shell, so `exit` ends the run).
_cc_load_smlib() {
  local _src="${BASH_SOURCE[0]}" _n=0 _lt _d _here _smlib
  while [ -L "$_src" ] && [ "$_n" -lt 40 ]; do   # CC-LIB-RESOLVE
    _n=$((_n + 1)); _lt="$(readlink -- "$_src")" || { _err "cannot read symlink $_src"; exit 2; }
    case "$_lt" in /*) _src="$_lt" ;; *) _d="${_src%/*}"; [ "$_d" = "$_src" ] && _d=.; _src="$_d/$_lt" ;; esac
  done
  _d="${_src%/*}"; [ "$_d" = "$_src" ] && _d=.
  _here="$(cd -P -- "$_d" 2>/dev/null && pwd -P)" || { _err "cannot resolve the script directory of $_src"; exit 2; }
  _smlib="$_here/lib/scripts-manifest.sh"
  [ -f "$_smlib" ] || { _err "cannot find helper $_smlib"; exit 2; }
  # shellcheck source=lib/scripts-manifest.sh
  . "$_smlib"
  declare -F scripts_manifest_rows >/dev/null 2>&1 || { _err "helper lib/scripts-manifest.sh failed to define scripts_manifest_rows"; exit 2; }
}

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

# ---- base resolution (kit #1277): done HERE so a bad --base is exit 2 before any scan has printed a line ----
_base_commit=""; _base_label=""; _base_full=""
if [ -n "$BASE_ARG" ]; then
  _base_commit="$(git -C "$TARGET_P" rev-parse --verify -q "${BASE_ARG}^{commit}" 2>/dev/null)" || { _err "--base ref not found or not a commit: $BASE_ARG"; exit 2; }
  _base_label="$BASE_ARG"; _base_full="$(git -C "$TARGET_P" rev-parse --symbolic-full-name "$BASE_ARG" 2>/dev/null)"
else
  _sym="$(git -C "$TARGET_P" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)"; _src=$?   # 1 = not a symbolic ref (absent)
  if [ "$_src" -eq 0 ] && [ -n "$_sym" ] && git -C "$TARGET_P" rev-parse --verify -q "$_sym^{commit}" >/dev/null 2>&1; then
    _base_full="$_sym"
  elif git -C "$TARGET_P" rev-parse --verify -q "refs/heads/main^{commit}" >/dev/null 2>&1; then _base_full="refs/heads/main"
  elif git -C "$TARGET_P" rev-parse --verify -q "refs/heads/master^{commit}" >/dev/null 2>&1; then _base_full="refs/heads/master"
  fi
  if [ -n "$_base_full" ]; then
    _base_commit="$(git -C "$TARGET_P" rev-parse --verify -q "$_base_full^{commit}" 2>/dev/null)"
    _base_label="${_base_full#refs/remotes/}"; _base_label="${_base_label#refs/heads/}"
  fi
fi

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

FINDINGS=0; DEGRADED=0; WARNINGS=0; DEGRADED_WHY=""
# _degrade <typed line> <short reason>: a scan that could not run; never a finding, never a quiet zero.
_degrade() { printf '%s\n' "$1"; DEGRADED=1; DEGRADED_WHY="${DEGRADED_WHY:+$DEGRADED_WHY; }$2"; }
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
    # The scratchpad is LIVE (the session keeps writing and deleting there): a file vanishing mid-walk must not
    # abort the run. GNU find: -ignore_readdir_race (FIND_RACE, probed above). Without it (BSD), find's stderr is
    # captured and ONLY "No such file or directory" lines are benign; any other error is still a failed scan.
    _sraw=()
    while IFS= read -r -d '' _p; do _sraw+=("$_p"); done < <(
      { _ferr="$(find "$SCRATCH_P" ${FIND_RACE[@]+"${FIND_RACE[@]}"} -type f -print0 2>&1 >&3)"; _frc=$?; } 3>&1   # CC-SCRATCH-FIND
      _other=0   # any stderr line that is not an ENOENT (a vanished entry) makes the scan a real failure
      while IFS= read -r _l; do case "$_l" in '') ;; *"No such file or directory"*) ;; *) _other=1 ;; esac; done <<<"$_ferr"
      if [ "$_frc" -ne 0 ] && [ -n "$_ferr" ] && [ "$_other" -eq 0 ]; then _frc=0; fi   # CC-ENOENT-BENIGN
      [ "$_frc" -eq 0 ] || printf '%s\n' "$_ferr" >&2
      printf 'RC=%s\0' "$_frc"
    )
    _rlast=$(( ${#_sraw[@]} - 1 ))
    { [ "$_rlast" -ge 0 ] && [ "${_sraw[$_rlast]}" = "RC=0" ]; } || { _err "find failed or was truncated in scratchpad $SCRATCH_P"; exit 2; }
    _sf=()
    if [ "$_rlast" -gt 0 ]; then
      while IFS= read -r -d '' _p; do _sf+=("$_p"); done < <(
        printf '%s\0' "${_sraw[@]:0:$_rlast}" | sort -z
        _pst=("${PIPESTATUS[@]}")
        printf 'RC=%s\0' "$(( _pst[0] || _pst[1] ))"
      )
    else
      _sf=("RC=0")
    fi
    _slast=$(( ${#_sf[@]} - 1 ))
    { [ "$_slast" -ge 0 ] && [ "${_sf[$_slast]}" = "RC=0" ]; } || { _err "sort failed or was truncated while ordering scratchpad files in $SCRATCH_P"; exit 2; }
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
      { [ "$_mlast" -ge 0 ] && [ "${_mf[$_mlast]}" = "RC=0" ]; } || { _err "manifest scan failed under $TARGET_P/sources/probes; UNMANIFESTED-SCRIPT not evaluated"; exit 2; }   # CC-MF-RC
      if [ "$_mlast" -gt 0 ]; then _cc_load_smlib; fi   # CC-LIB-LAZY: only a target that holds a manifest needs the parser
      for ((_j = 0; _j < _mlast; _j++)); do
        # kit #1659: the shared parser (lib/scripts-manifest.sh) yields the VALID rows (64-hex sha cell); the
        # basename of each resolved path is matched EXACTLY below. A parse failure is a failed scan (exit 2).
        _rows="$(scripts_manifest_rows "$TARGET_P" "${_mf[$_j]}")" || { _err "cannot parse manifest ${_mf[$_j]}"; exit 2; }   # CC-MF-PARSE
        _o="$(awk -F'\t' 'NF { n = split($1, q, "/"); if (q[n] != "") print q[n] }' <<<"$_rows")" || { _err "cannot read parsed manifest rows of ${_mf[$_j]}"; exit 2; }
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
      { [ "$_plast" -ge 0 ] && [ "${_pl[$_plast]}" = "RC=0" ]; } || { _err "probes scan failed under $TARGET_P/sources/probes; preserved copies not evaluated"; exit 2; }   # CC-PB-RC
      for ((_j = 0; _j < _plast; _j++)); do
        _probe_shas="$_probe_shas"$'\n'"$($_sha_cmd -- "${_pl[$_j]}" 2>/dev/null | cut -d' ' -f1)"
      done
    fi
    if [ -z "$_sha_cmd" ]; then   # CC-NO-SHA
      printf 'DEGRADED-NO-SHA256 %s\n' "preserved-copy check skipped (no sha256sum/shasum on PATH)"
      DEGRADED=1; DEGRADED_WHY="${DEGRADED_WHY:+$DEGRADED_WHY; }preserved-copy check skipped"
    fi
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

# ---- (e)(f)(g) retention scans: REPORT-ONLY (kit #1277 slice 3) --------------------------------
# These emit `WARN ...` lines and bump WARNINGS only; FINDINGS (and so the exit code) is never touched.
# A scan that cannot run is _degrade'd (typed DEGRADED-* line, exit 3 when otherwise clean), never silent.
_warn() { printf 'WARN %s\n' "$1"; WARNINGS=$((WARNINGS + 1)); }

# (e) stale worktrees. `git worktree list --porcelain` blocks (blank-line separated); the first block is the main one.
WT_STATE="not evaluated"
WT_CHECKED=()   # branches checked out in some worktree, the main one included (never reported as merged)
_wt_ok=0   # 1 only when the worktree list was read: WT_CHECKED is then complete
_wl=()
# _wt_try [-z]: read `git worktree list --porcelain [-z]` into _wl (one element per record), true only when git exited 0.
# -z (git >= 2.36) keeps a newline inside a path whole; older git rejects it and the caller falls back to line mode.
_wt_try() {
  local _l _mk _last
  _wl=()
  if [ "${1:-}" = "-z" ]; then
    while IFS= read -r -d '' _l; do _wl+=("$_l"); done < <(git -C "$TARGET_P" worktree list --porcelain -z 2>/dev/null; printf 'RC=%s\0' "$?")
  else
    while IFS= read -r _l || [ -n "$_l" ]; do _wl+=("$_l"); done < <(git -C "$TARGET_P" worktree list --porcelain 2>/dev/null; printf 'RC=%s\n' "$?")
  fi
  _last=$(( ${#_wl[@]} - 1 ))
  [ "$_last" -ge 0 ] && [ "${_wl[$_last]}" = "RC=0" ] || return 1
  unset "_wl[$_last]"
}
if _wt_try -z || _wt_try; then   # CC-WT-LIST
  _wt_ok=1
  _wn=0; _wstale=0; _wp=""; _wprun=""; _wlock=""; _wbare=0; _wbr=""
  _wt_flush() {
    [ -n "$_wp" ] || return 0
    [ -z "$_wbr" ] || WT_CHECKED+=("$_wbr")
    if [ "$_wn" -gt 0 ] && [ "$_wbare" = 0 ]; then
      if [ ! -e "$_wp" ]; then _warn "stale-worktree $_wp missing${_wlock:+ (locked)}"; _wstale=$((_wstale + 1))   # CC-WT-MISSING
      elif [ -n "$_wprun" ]; then _warn "stale-worktree $_wp prunable ($_wprun)${_wlock:+ (locked)}"; _wstale=$((_wstale + 1))
      fi
    fi
    _wn=$((_wn + 1)); _wp=""; _wprun=""; _wlock=""; _wbare=0; _wbr=""
  }
  for _l in ${_wl[@]+"${_wl[@]}"}; do
    case "$_l" in
      "worktree "*) _wt_flush; _wp="${_l#worktree }" ;;
      "prunable"*)  _wprun="${_l#prunable}"; _wprun="${_wprun# }"; [ -n "$_wprun" ] || _wprun="prunable" ;;
      "locked"*)    _wlock=1 ;;
      "bare")       _wbare=1 ;;
      "branch "*)   _wbr="${_l#branch }" ;;
    esac
  done
  _wt_flush
  WT_STATE="$_wn registered, $_wstale stale"
else
  _wmsg="$(git -C "$TARGET_P" worktree list --porcelain 2>&1 >/dev/null)"; _wmsg="${_wmsg//$'\n'/ }"
  _degrade "DEGRADED-WORKTREE-SCAN git worktree list failed: ${_wmsg:-git exited non-zero without output}" "worktree scan failed"
  WT_STATE="degraded"
fi

# (f) merged branches (local + remote-tracking) against the base.
BR_STATE="not evaluated"
# (the base itself was resolved, and --base validated, right after argument parsing: see "base resolution" above)
if [ -z "$_base_commit" ]; then
  printf 'ABSENT-BASE %s\n' "no --base, origin/HEAD, main or master found; merged-branch scan skipped"
  BR_STATE="no base"
else
  # the base's own branch name (without refs/heads/ or refs/remotes/<remote>/), to hide its local/remote twins
  case "$_base_full" in
    refs/remotes/*) _bb="${_base_full#refs/remotes/}"; _bb="${_bb#*/}" ;;
    refs/heads/*)   _bb="${_base_full#refs/heads/}" ;;
    *)              _bb="" ;;
  esac
  if _bm="$(git -C "$TARGET_P" for-each-ref "--merged=$_base_commit" '--format=%(refname)' refs/heads refs/remotes 2>/dev/null)"; then   # CC-BR-LIST
    _bl=0; _br=0
    # without the worktree list the checked-out exclusion is unknown, so a local WARN could be false: suppress them
    [ "$_wt_ok" = 1 ] || printf 'INFO merged-branch scan of local branches skipped: %s\n' "worktree scan degraded, checked-out branches unknown"
    while IFS= read -r _r; do
      [ -n "$_r" ] || continue
      case "$_r" in
        refs/heads/*)   _nm="${_r#refs/heads/}"; _bn="$_nm"; _kind="merged-branch" ;;
        refs/remotes/*) _nm="${_r#refs/remotes/}"; _bn="${_nm#*/}"; _kind="merged-remote-branch"
                        [ "$_bn" = "HEAD" ] && continue ;;
        *) continue ;;
      esac
      [ "$_r" = "$_base_full" ] && continue
      [ -n "$_bb" ] && [ "$_bn" = "$_bb" ] && continue
      _chk=0; for _c in ${WT_CHECKED[@]+"${WT_CHECKED[@]}"}; do [ "$_c" = "$_r" ] && { _chk=1; break; }; done
      [ "$_chk" = 1 ] && continue
      if [ "$_kind" = "merged-branch" ]; then
        [ "$_wt_ok" = 1 ] || { continue; }
      fi
      _warn "$_kind $_nm merged into $_base_label"
      if [ "$_kind" = "merged-branch" ]; then _bl=$((_bl + 1)); else _br=$((_br + 1)); fi
    done <<<"$_bm"
    BR_STATE="base $_base_label, $_bl local, $_br remote"
  else
    _bmsg="$(git -C "$TARGET_P" for-each-ref "--merged=$_base_commit" '--format=%(refname)' refs/heads refs/remotes 2>&1 >/dev/null)"; _bmsg="${_bmsg//$'\n'/ }"
    _degrade "DEGRADED-BRANCH-SCAN git for-each-ref failed: ${_bmsg:-git exited non-zero without output}" "branch scan failed"
    BR_STATE="degraded"
  fi
fi

# (g) _evidence rollback-backup retention. States (§7): explicit dir absent -> ABSENT-EVIDENCE; none found -> `none found`;
# scanned -> counts. An unreadable dir / failing find is DEGRADED-EVIDENCE-SCAN (find's own stderr is left visible).
EV_STATE="not evaluated"
_evdirs=()
_ev_ok=1
if [ -n "$EVID_ARG" ]; then
  EVID_ARG="${EVID_ARG%/}"; [ -n "$EVID_ARG" ] || EVID_ARG="/"
  if [ -d "$EVID_ARG" ]; then _evdirs=("$EVID_ARG")
  else printf 'ABSENT-EVIDENCE %s\n' "$EVID_ARG"; EV_STATE="absent"; _ev_ok=0
  fi
else
  # find's stderr is captured (English, LC_ALL=C) so a failure can be attributed: an unreadable directory that is
  # NOT under an _evidence dir only hides evidence dirs below it -> typed INFO naming it; anything else degrades.
  _evraw=()
  while IFS= read -r -d '' _p; do _evraw+=("$_p"); done < <(
    { _ferr="$(LC_ALL=C find "$TARGET_P" ${FIND_RACE[@]+"${FIND_RACE[@]}"} -maxdepth 4 -name .git -prune -o -type d -name _evidence -print0 2>&1 1>&3 3>&-)"; _frc=$?; } 3>&1
    printf 'ERR=%s\0' "$_ferr"
    printf 'RC=%s\0' "$_frc"
  )
  _el=$(( ${#_evraw[@]} - 1 ))
  _ev_fatal=0; _ev_unread=0
  if [ "$_el" -ge 1 ] && [[ "${_evraw[$_el]}" == RC=* ]] && [[ "${_evraw[$((_el - 1))]}" == ERR=* ]]; then
    _frc="${_evraw[$_el]#RC=}"; _ferr="${_evraw[$((_el - 1))]#ERR=}"
    for ((_i = 0; _i < _el - 1; _i++)); do _evdirs+=("${_evraw[$_i]}"); done
    if [ "$_frc" != 0 ]; then
      _ev_fatal=1   # an error with no readable attribution stays fatal
      _pre="find: '"; _suf="': Permission denied"   # C-locale find shape, anchored at both ends
      while IFS= read -r _fl; do
        [ -n "$_fl" ] || continue
        if [[ "$_fl" == "$_pre"*"$_suf" ]]; then
          _fp="${_fl#"$_pre"}"; _fp="${_fp%"$_suf"}"; _fp="${_fp#"$TARGET_P"/}"   # classify below the target only
          case "/$_fp/" in
            */_evidence/*) _ev_fatal=1; break ;;   # CC-EV-ARM: under an _evidence dir (whole path component): fatal
            *) _ev_fatal=0; _ev_unread=$((_ev_unread + 1))
               printf 'INFO evidence-discovery skipped unreadable directory (evidence dirs below it, if any, are not scanned): %s\n' "$_fl" ;;
          esac
        else _ev_fatal=1; break
        fi
      done <<<"$_ferr"
    fi
  else _ev_fatal=1; _ferr="no exit status recovered from find"
  fi
  if [ "$_ev_fatal" = 1 ]; then
    _degrade "DEGRADED-EVIDENCE-SCAN find for _evidence directories failed under $TARGET_P: ${_ferr//$'\n'/ }" "evidence scan failed"
    EV_STATE="degraded"; _ev_ok=0
  elif [ "${#_evdirs[@]}" -eq 0 ]; then EV_STATE="none found"; _ev_ok=0
  fi
  _ev_sfx=""; [ "$_ev_unread" -eq 0 ] || _ev_sfx=", $_ev_unread unreadable dir(s) skipped"   # §7: a skip is never a quiet "none found"
  [ "$_ev_ok" = 1 ] || { [ "$EV_STATE" != "none found" ] || EV_STATE="none found$_ev_sfx"; }
fi
if [ "$_ev_ok" = 1 ]; then
  _evn=0; _evold=0; _evbad=0
  for _d in "${_evdirs[@]}"; do
    _bk=()
    while IFS= read -r -d '' _p; do _bk+=("$_p"); done < <(
      find "$_d" ${FIND_RACE[@]+"${FIND_RACE[@]}"} -mindepth 1 -maxdepth 2 \( -iname '*rollback*' -o -iname '*backup*' \) -mmin "+$((BACKUP_D * 1440))" -print0 -prune   # CC-EV-FIND: a matched dir is reported once, its matching children are pruned
      printf 'RC=%s\0' "$?"
    )
    _bl=$(( ${#_bk[@]} - 1 ))
    if [ "$_bl" -ge 0 ] && [ "${_bk[$_bl]}" = "RC=0" ]; then
      _evn=$((_evn + 1))
      if [ "$_bl" -gt 0 ]; then
        _bs=()
        while IFS= read -r -d '' _p; do _bs+=("$_p"); done < <(
          printf '%s\0' "${_bk[@]:0:$_bl}" | sort -z
          _pst=("${PIPESTATUS[@]}")
          printf 'RC=%s\0' "$(( _pst[0] || _pst[1] ))"
        )
        _sl=$(( ${#_bs[@]} - 1 ))
        if [ "$_sl" -ge 0 ] && [ "${_bs[$_sl]}" = "RC=0" ]; then
          for ((_i = 0; _i < _sl; _i++)); do
            _p="${_bs[$_i]}"; _m="$(_mtime "$_p")"
            if [ -n "$_m" ]; then _age="$(( (_now - _m) / 86400 ))d"; else _age="unknown"; fi
            _warn "stale-backup $_p age=$_age retention=${BACKUP_D}d"; _evold=$((_evold + 1))
          done
        else
          _degrade "DEGRADED-EVIDENCE-SCAN sort failed ordering backups under $_d" "evidence scan failed"; _evbad=$((_evbad + 1))
        fi
      fi
    else
      _degrade "DEGRADED-EVIDENCE-SCAN find failed or was truncated under $_d" "evidence scan failed"; _evbad=$((_evbad + 1))
    fi
  done
  EV_STATE="$_evn dir(s) scanned, $_evold older than ${BACKUP_D}d"
  [ "$_evbad" -eq 0 ] || EV_STATE="$EV_STATE, $_evbad unreadable"
  EV_STATE="$EV_STATE${_ev_sfx:-}"
fi

# ---- summary ---------------------------------------------------------------------------------
_scanned="untracked in $TARGET, tmp.* in $TMPD older than ${STALE_H}h, keep-list entries: $KEEP_N, scratchpad: $SCRATCH_STATE"
_scanned="$_scanned, worktrees: $WT_STATE, branches: $BR_STATE, evidence: $EV_STATE, warnings: $WARNINGS"
if [ "$DEGRADED" -eq 1 ]; then _scanned="$_scanned, degraded: $DEGRADED_WHY"; fi
if [ "$FINDINGS" -eq 0 ]; then
  if [ "$DEGRADED" -eq 1 ]; then   # CC-DEGRADED-EXIT: a run that could not check everything never reads as clean
    printf 'CLEAN-CHECK: degraded (%s)\n' "$_scanned"
    exit 3
  fi
  printf 'CLEAN-CHECK: clean (%s)\n' "$_scanned"
  exit 0
fi
printf 'CLEAN-CHECK: %s finding(s) (%s)\n' "$FINDINGS" "$_scanned"
exit 1
