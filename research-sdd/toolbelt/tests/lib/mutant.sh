#!/usr/bin/env bash
# mutant.sh — sourceable helper for mutation controls ("teeth"), kit issue #943.
#
# Root class: a tooth reports ok when the mutated run merely DIFFERS from the good run, so a
# mutant that never applied, was empty, crashed on a syntax error, or was written into the live
# tree all "bite" for the wrong reason. This helper builds a mutant as a COPY of the real SUT in a
# temp dir and REFUSES to hand back one that cannot be a real mutation. A refused mutant file is
# removed, so a caller that ignores the return code finds nothing to run.
#
#   mutant_sed    ORIG OUT SED_ARGS...   sed SED_ARGS... ORIG > OUT, then mutant_verify
#   mutant_verify ORIG OUT               the same checks for a mutant built some other way
#
# Return codes (distinct, so a test can assert the SPECIFIC refusal, not "any failure"):
#   0 ok · 2 original absent/unreadable · 3 original or mutant empty · 4 mutant byte-identical to
#   the original (the mutation never applied) · 5 mutant is not valid bash (bash -n) · 6 sed failed
#   · 7 OUT is the same path as ORIG · 8 OUT is not under the temp root (kit issue #1156: a mutant
#   written beside the SUT lands in the live tree)
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

mutant_verify() {
  local orig="$1" out="$2"
  if [ ! -f "$orig" ] || [ ! -r "$orig" ]; then
    _mutant_refuse "original '$orig' is not a readable file"; return 2
  fi
  if [ ! -s "$orig" ]; then
    _mutant_refuse "original is empty: '$orig'"; rm -f -- "$out"; return 3
  fi
  # SENTINEL-SELF-CHECK
  if [ "$orig" -ef "$out" ]; then
    _mutant_refuse "OUT and ORIG are the same path ('$out'); never overwrite the SUT"; return 7
  fi
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
  local orig="$1" out="$2" odir root real_out real_root
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
  # SENTINEL-PLACEMENT-CHECK
  odir="$(dirname -- "$out")"
  root="${MUTANT_TMPROOT:-${TMPDIR:-/tmp}}"
  real_out="$(_mutant_realdir "$odir")"
  real_root="$(_mutant_realdir "$root")"
  if [ -z "$real_out" ] || [ -z "$real_root" ] || { [ "$real_out" != "$real_root" ] && [ "${real_out#"$real_root"/}" = "$real_out" ]; }; then
    _mutant_refuse "OUT '$out' is not under the temp root '$root' — a mutant must be built in a temp copy, never in the live tree"; return 8
  fi
  if ! sed "$@" "$orig" > "$out"; then
    _mutant_refuse "sed failed building '$out'"; rm -f -- "$out"; return 6
  fi
  mutant_verify "$orig" "$out"
}
