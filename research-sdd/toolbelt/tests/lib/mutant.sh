#!/usr/bin/env bash
# mutant.sh — sourceable helper for mutation controls ("teeth"), kit issue #943.
#
# Root class: a tooth reports ok when the mutated run merely DIFFERS from the good run, so a
# mutant that never applied, was empty, crashed on a syntax error, or was written into the live
# tree all "bite" for the wrong reason. This helper builds a mutant as a COPY of the real SUT in a
# temp dir and REFUSES to hand back one that cannot be a real mutation. A mutant refused for being
# empty, identical, not valid bash, or for a failed sed is removed, so a caller that ignores the
# return code finds nothing to run. A placement/symlink refusal (8, 9) never deletes anything: the
# path is not known to be the helper's own file.
#
#   mutant_sed    ORIG OUT SED_ARGS...   placement checks, then sed SED_ARGS... ORIG > OUT, then
#                                        the content checks of mutant_verify
#   mutant_verify ORIG OUT               the SAME checks (placement, symlink, content) for a
#                                        mutant built some other way (awk, a heredoc, a copy)
#
# Return codes (distinct, so a test can assert the SPECIFIC refusal, not "any failure"):
#   0 ok · 2 original absent/unreadable · 3 original or mutant empty · 4 mutant byte-identical to
#   the original (the mutation never applied) · 5 mutant is not valid bash (bash -n) · 6 sed failed
#   · 7 OUT is the same path as ORIG · 8 OUT is in the live tree (the tree ORIG lives in) or not
#   under the temp root (kit issue #1156: a mutant written beside the SUT lands in the live tree)
#   · 9 OUT is a symlink (a write would go THROUGH it to another file)
#
# "The live tree" is the git work tree containing ORIG (`git rev-parse --show-toplevel`), or ORIG's
# own physical directory when git is absent or ORIG is not in a work tree (git is run with
# GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR removed). A git-ignored OUT is exempt from the live-tree
# test. Placement is TWO independent conditions: OUT must NOT be at or under the live tree, AND must be under the temp
# root. The second alone is not enough — a clone under /tmp, or a TMPDIR that is an ancestor of the
# kit, puts the live tree under the temp root.
#
# Environment:
#   MUTANT_SYNTAX=none   skip the `bash -n` check (mutants of non-bash files). Default: bash.
#   MUTANT_TMPROOT       the directory OUT must live under. Default: ${TMPDIR:-/tmp}.
#
# FUNCTIONS ONLY — source it, never execute it. No `set` options here: a sourced `set` would
# mutate the calling suite's shell options.

_mutant_refuse() { printf 'mutant: REFUSED — %s\n' "$1" >&2; }

# _mutant_realdir <dir> — physical path of an existing directory; fails (no output) otherwise.
_mutant_realdir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# _mutant_under <path> <root> — true when path equals root or lies below it (both physical).
_mutant_under() { [ "$1" = "$2" ] || [ "${1#"$2"/}" != "$1" ]; }

# _mutant_git <dir> <git-args...> — git in <dir> with the repository-selecting environment removed:
# an inherited GIT_DIR / GIT_WORK_TREE would otherwise redirect the lookup to a DIFFERENT repo and
# the "live tree" would silently be the wrong one.
_mutant_git() { local d="$1"; shift; env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$d" "$@"; }

# _mutant_live_root <orig> — physical root of the tree ORIG lives in; fails (no output) when ORIG's
# directory cannot be resolved.
_mutant_live_root() {
  local odir top=""
  odir="$(_mutant_realdir "$(dirname -- "$1")")" || return 1
  [ -n "$odir" ] || return 1
  if command -v git >/dev/null 2>&1; then
    top="$(_mutant_git "$odir" rev-parse --show-toplevel 2>/dev/null)" || top=""
    [ -n "$top" ] && top="$(_mutant_realdir "$top")"
  fi
  printf '%s' "${top:-$odir}"
}

# _mutant_check_out <orig> <out> — symlink + placement. Returns 0, 8 or 9.
_mutant_check_out() {
  local orig="$1" out="$2" root real_out real_root live
  # SENTINEL-SYMLINK-CHECK
  if [ -L "$out" ]; then
    _mutant_refuse "OUT '$out' is a symlink — a write would go through it to another file"; return 9
  fi
  real_out="$(_mutant_realdir "$(dirname -- "$out")")"
  live="$(_mutant_live_root "$orig")"
  if [ -z "$real_out" ]; then
    _mutant_refuse "OUT directory '$(dirname -- "$out")' does not exist"; return 8
  fi
  # SENTINEL-LIVE-TREE-CHECK
  # A git-IGNORED OUT is exempt: it is not part of the tracked tree and cannot be committed, which is
  # what makes TMPDIR=<repo>/.tmp (ignored) usable. An un-ignored path in the same repo is refused.
  if [ -z "$live" ] || { _mutant_under "$real_out" "$live" \
       && ! _mutant_git "$live" check-ignore -q -- "$real_out/$(basename -- "$out")" 2>/dev/null; }; then
    _mutant_refuse "OUT '$out' is in the live tree (${live:-unresolved}) — a mutant must be built in a temp copy, never beside the SUT"; return 8
  fi
  root="${MUTANT_TMPROOT:-${TMPDIR:-/tmp}}"
  real_root="$(_mutant_realdir "$root")"
  # SENTINEL-TMPROOT-CHECK
  if [ -z "$real_root" ] || ! _mutant_under "$real_out" "$real_root"; then
    _mutant_refuse "OUT '$out' is not under the temp root '$root'"; return 8
  fi
  return 0
}

mutant_verify() {
  local orig="$1" out="$2" rc
  if [ ! -f "$orig" ] || [ ! -r "$orig" ]; then
    _mutant_refuse "original '$orig' is not a readable file"; return 2
  fi
  if [ ! -s "$orig" ]; then
    _mutant_refuse "original is empty: '$orig'"; return 3
  fi
  # SENTINEL-SELF-CHECK
  if [ "$orig" -ef "$out" ]; then
    _mutant_refuse "OUT and ORIG are the same path ('$out'); never overwrite the SUT"; return 7
  fi
  _mutant_check_out "$orig" "$out"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if [ ! -f "$out" ]; then
    _mutant_refuse "mutant '$out' was not produced"; return 2
  fi
  # SENTINEL-EMPTY-CHECK
  if [ ! -s "$out" ]; then
    _mutant_refuse "mutant is empty: '$out'"; rm -f -- "$out"; return 3
  fi
  # SENTINEL-IDENTICAL-CHECK
  if cmp -s -- "$orig" "$out"; then
    _mutant_refuse "mutant is byte-identical to the original — the mutation never applied"; rm -f -- "$out"; return 4
  fi
  # SENTINEL-SYNTAX-CHECK
  if [ "${MUTANT_SYNTAX:-bash}" != none ]; then
    local synerr
    if ! synerr="$(bash -n "$out" 2>&1)"; then
      _mutant_refuse "mutant is not valid bash (bash -n): $synerr"; rm -f -- "$out"; return 5
    fi
  fi
  return 0
}

mutant_sed() {
  local orig="$1" out="$2" rc
  shift 2
  if [ ! -f "$orig" ] || [ ! -r "$orig" ]; then
    _mutant_refuse "original '$orig' is not a readable file"; return 2
  fi
  if [ ! -s "$orig" ]; then
    _mutant_refuse "original is empty: '$orig'"; return 3
  fi
  # SENTINEL-SELF-CHECK
  if [ "$orig" -ef "$out" ]; then
    _mutant_refuse "OUT and ORIG are the same path ('$out'); never overwrite the SUT"; return 7
  fi
  # Placement BEFORE anything is written (mutant_verify repeats it; this one guards the sed write).
  _mutant_check_out "$orig" "$out"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if ! sed "$@" "$orig" > "$out"; then
    _mutant_refuse "sed failed building '$out'"; rm -f -- "$out"; return 6
  fi
  mutant_verify "$orig" "$out"
}
