#!/usr/bin/env bash
# harness.sh — sourced by the kit-pr-pipeline / kit-rdd-* suites (kit issue #2212). FUNCTIONS ONLY.
# One hermetic case = one temp dir holding a PATH made ONLY of symlinks: the shims (git gh gentle-ai flock) and
# the few real tools the SUTs need. A case therefore never reaches the real gh / git / gentle-ai.
#   kh_init TMPROOT      new case dir; sets KH_CASE KH_BIN KH_WT; exports SHIM_STATE SHIM_FIX
#   kh_rule NAME GLOB RC [OUT [TIMES [OPTION]]]   append a shim rule (see shim.sh)
#   kh_drop TOOL         remove TOOL from the case PATH (a missing dependency)
#   kh_calls             the recorded calls
KH_FIXDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
kh_init() {
  KH_CASE="$(mktemp -d "${1:?kh_init needs a temp root}/case.XXXXXX")" || return 2
  KH_BIN="$KH_CASE/bin"; KH_WT="$KH_CASE/wt"; SHIM_STATE="$KH_CASE/state"; SHIM_FIX="$KH_FIXDIR"
  mkdir -p "$KH_BIN" "$KH_WT" "$SHIM_STATE" || return 2
  local t p
  for t in git gh gentle-ai flock; do ln -s "$KH_FIXDIR/shim.sh" "$KH_BIN/$t"; done
  for t in bash env cat grep sed awk sleep date mkdir rm cut tail head dirname readlink basename mktemp tr \
           sort wc seq touch ls uniq tee ln find python3 cp mv chmod true false sh; do
    p="$(command -v "$t")" && [ -n "$p" ] && ln -sf "$p" "$KH_BIN/$t"
  done
  : > "$SHIM_STATE/calls.log"; : > "$SHIM_STATE/rules.tsv"
  export SHIM_STATE SHIM_FIX
}
kh_rule() {
  local n="$1" g="$2" rc="$3" o="${4:--}" t="${5:--}" op="${6:--}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$g" "$rc" "$o" "$t" "$op" >> "$SHIM_STATE/rules.tsv"
}
kh_drop() { rm -f -- "$KH_BIN/$1"; }
kh_calls() { cat "$SHIM_STATE/calls.log"; }
