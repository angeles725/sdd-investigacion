#!/usr/bin/env bash
# gh-driver.sh <toolbelt-dir> <out-dir> probe <gh-bin> <repo> [cwd]
# gh-driver.sh <toolbelt-dir> <out-dir> run <cmd> [args...]
#
# Runs the REAL toolbelt/lib/gh-visibility.sh so the Go differential test can require the same typed result from
# core/gh. Prints the function's return code and its GHV_* globals, one `key=value` per line; gh_bounded_run's
# pass-through stdout and stderr land in <out-dir>/stdout and <out-dir>/stderr. Harness failures (lib missing,
# function not defined, unknown mode) exit 97 and are never confusable with a function rc.
die() { echo "gh-driver: $*" >&2; exit 97; }
tb="${1:-}"; out="${2:-}"; mode="${3:-}"
[ -n "$tb" ] && [ -d "$out" ] && [ -n "$mode" ] || die "usage: gh-driver.sh <toolbelt-dir> <out-dir> probe|run ..."
shift 3
[ -f "$tb/lib/gh-visibility.sh" ] || die "lib missing: $tb/lib/gh-visibility.sh"
# shellcheck source=/dev/null
. "$tb/lib/gh-visibility.sh" || die "sourcing gh-visibility.sh failed"
rc=0
case "$mode" in
  probe) declare -F gh_visibility_probe >/dev/null || die "gh_visibility_probe not defined"
         gh_visibility_probe "$@" || rc=$? ;;
  run)   declare -F gh_bounded_run >/dev/null || die "gh_bounded_run not defined"
         gh_bounded_run "$@" >"$out/stdout" 2>"$out/stderr" || rc=$? ;;
  *)     die "unknown mode $mode" ;;
esac
printf 'rc=%s\nstate=%s\nRC=%s\nwhy=%s\nraw=%s\nbound=%s\nbad=%s\n' \
  "$rc" "$GHV_STATE" "$GHV_RC" "${GHV_WHY:-}" "${GHV_RAW:-}" "$GHV_BOUND" "$GHV_BAD_TIMEOUT"
