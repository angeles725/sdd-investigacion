#!/usr/bin/env bash
# tests/lib/stage-libs.sh — TEST-ONLY scaffolding: stage EVERY toolbelt/lib file into a sandbox toolbelt (T12c), so a
# suite no longer keeps a hand-maintained list of the libs its SUT happens to source today.
# Sourced (never executed); defines: rsdd_stage_libs.
#
#   rsdd_stage_libs DEST_TOOLBELT [--except NAME]...
#     mkdir -p DEST_TOOLBELT/lib, then copy every top-level REGULAR file of toolbelt/lib into it with `cp -p` (modes
#     kept). Directories (e.g. __pycache__) are skipped. --except NAME (repeatable) leaves out the lib file NAME
#     (a file name such as `tool-env.sh`, no path), for a suite that stages a lib of its own in that slot.
#     Silent on success (rc 0). rc 2 with a message on stderr, and nothing written, when: DEST is missing; an argument
#     is unknown or --except has no NAME; the source dir is absent or holds no regular file; an --except NAME is not a
#     file in the source (a typo would otherwise stage the very lib the suite meant to replace); DEST, or DEST/lib
#     through a symlink, resolves at or under the live toolbelt (this helper's own toolbelt, or the toolbelt that owns
#     the source dir) — the same live-tree refusal tests/lib/mutant.sh applies to a mutant. rc 2 also when mkdir or a
#     copy fails (the files copied before the failure stay; the suite owns DEST and its cleanup).
#
# Environment:
#   RSDD_STAGE_LIBS_SRC  the lib dir to stage from. Default: the toolbelt/lib next to this file's tests/ dir.
#
# A suite that calls rsdd_stage_libs no longer names the libs it stages, so suite-impact.sh cannot see the edge from
# the text: detect_blind flags the call (class `stage-libs`) and the suite needs an impact-blindspot.txt row with
# reach=research-sdd/toolbelt/lib/* (`suite-impact.sh --audit` fails without it).
#
# FUNCTIONS ONLY — no `set` options here: a sourced `set` would change the calling suite's shell options.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "stage-libs.sh is a source-only helper; do not execute it directly." >&2
  exit 1
fi

_RSDD_STAGE_LIBS_TB="$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

_rsdd_stage_err() { printf 'rsdd_stage_libs: %s\n' "$1" >&2; }

# _rsdd_stage_phys PATH — the physical form of PATH, which need not exist: its longest existing prefix resolved with
# `cd -P`, the rest appended as written.
_rsdd_stage_phys() {
  local p="$1" rest=""
  while [ ! -d "$p" ]; do
    rest="/${p##*/}$rest"
    case "$p" in */*) p="${p%/*}"; [ -n "$p" ] || p=/ ;; *) p=. ;; esac
  done
  p="$(cd -P -- "$p" 2>/dev/null && pwd -P)" || return 1
  [ "$p" = / ] && p=""
  printf '%s%s' "$p" "$rest"
}
_rsdd_stage_under() { [ "$1" = "$2" ] || [ "${1#"$2"/}" != "$1" ]; }

# _rsdd_stage_placement DEST SRC — rc 0 when DEST is safe to write, else a message and rc 2.
_rsdd_stage_placement() {
  local dest="$1" src="$2" d dl owner live
  d="$(_rsdd_stage_phys "$dest")" || { _rsdd_stage_err "cannot resolve DEST: $dest"; return 2; }
  dl="$(_rsdd_stage_phys "$dest/lib")" || { _rsdd_stage_err "cannot resolve DEST/lib: $dest/lib"; return 2; }
  owner="$(cd -P -- "$src/.." 2>/dev/null && pwd -P)" || { _rsdd_stage_err "cannot resolve the source toolbelt: $src/.."; return 2; }
  for live in "$_RSDD_STAGE_LIBS_TB" "$owner"; do
    if _rsdd_stage_under "$d" "$live" || _rsdd_stage_under "$dl" "$live"; then
      _rsdd_stage_err "REFUSED — DEST '$dest' resolves into the live toolbelt ($live); stage into a temp sandbox"
      return 2
    fi
  done
}

_rsdd_stage_has() { [ -n "$2" ] && [ "${2##*/}" = "$2" ] && [ -f "$1/$2" ] && [ ! -d "$1/$2" ]; }

rsdd_stage_libs() {
  local _rsl_dest="${1:-}" _rsl_src="${RSDD_STAGE_LIBS_SRC:-$_RSDD_STAGE_LIBS_TB/lib}" _rsl_e _rsl_f _rsl_b i
  local -a _rsl_except=() _rsl_files=()
  [ -n "$_rsl_dest" ] || { _rsdd_stage_err "usage: rsdd_stage_libs DEST_TOOLBELT [--except NAME]..."; return 2; }
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --except)
        [ $# -ge 2 ] && [ -n "$2" ] || { _rsdd_stage_err "--except needs a NAME"; return 2; }
        _rsl_except+=("$2"); shift 2 ;;
      *) _rsdd_stage_err "unknown argument: $1"; return 2 ;;
    esac
  done
  [ -d "$_rsl_src" ] || { _rsdd_stage_err "source lib dir not found: $_rsl_src"; return 2; }
  for _rsl_f in "$_rsl_src"/*; do
    [ -f "$_rsl_f" ] || continue
    _rsl_files+=("$_rsl_f")
  done
  [ "${#_rsl_files[@]}" -gt 0 ] || { _rsdd_stage_err "source lib dir has no regular file: $_rsl_src"; return 2; }
  for _rsl_e in "${_rsl_except[@]+"${_rsl_except[@]}"}"; do
    _rsdd_stage_has "$_rsl_src" "$_rsl_e" || { _rsdd_stage_err "--except names no file in $_rsl_src: $_rsl_e"; return 2; }
  done
  _rsdd_stage_placement "$_rsl_dest" "$_rsl_src" || return 2
  mkdir -p -- "$_rsl_dest/lib" || { _rsdd_stage_err "cannot create $_rsl_dest/lib"; return 2; }
  for ((i = 0; i < ${#_rsl_files[@]}; i++)); do
    _rsl_f="${_rsl_files[$i]}"; _rsl_b="${_rsl_f##*/}"
    _rsdd_stage_excepted "$_rsl_b" && continue
    cp -p -- "$_rsl_f" "$_rsl_dest/lib/" || { _rsdd_stage_err "copy failed: $_rsl_f -> $_rsl_dest/lib/"; return 2; }
  done
}

# _rsdd_stage_excepted NAME — rc 0 when NAME was given to --except (reads the caller's _rsl_except).
_rsdd_stage_excepted() {
  local x
  for x in "${_rsl_except[@]+"${_rsl_except[@]}"}"; do [ "$x" = "$1" ] && return 0; done
  return 1
}
