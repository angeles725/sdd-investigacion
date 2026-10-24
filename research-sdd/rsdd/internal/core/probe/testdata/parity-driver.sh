#!/usr/bin/env bash
# parity-driver.sh <toolbelt-dir> <mode> [arg]
#
# Runs the REAL toolbelt/lib/tool-env.sh so the Go differential test can require the same stdout and return
# code from core/probe:
#   cmdv NAME   command -v NAME          brew     rsdd_brew_prefix
#   java        rsdd_resolve_java_home   jar NAME rsdd_resolve_java_jar NAME
#   ghidra      rsdd_resolve_ghidra_home r2       rsdd_resolve_r2
#   ilspy       rsdd_resolve_ilspy       pkgcfg   rsdd_system_pkgconfig_path
# The value is captured as every caller does, "$(fn)" (trailing newlines cut), and printed with one
# newline when non-empty; the function's return code is the driver's exit code. Harness failures (lib
# missing, a function not defined, unknown mode) exit 97 and are never confusable with a function rc.
# RSDD_DRIVER_UNSET_PATH=1 unsets PATH after sourcing (bash would otherwise invent a default PATH).
die() { echo "parity-driver: $*" >&2; exit 97; }
tb="${1:-}"; mode="${2:-}"
[ -n "$tb" ] && [ -n "$mode" ] || die "usage: parity-driver.sh <toolbelt-dir> <mode> [arg]"
shift 2
[ -f "$tb/lib/tool-env.sh" ] || die "lib missing: $tb/lib/tool-env.sh"
# shellcheck source=/dev/null
. "$tb/lib/tool-env.sh" || die "sourcing tool-env.sh failed"
fn() { declare -F "$1" >/dev/null 2>&1 || die "tool-env.sh failed to define $1"; "$@"; }
[ "${RSDD_DRIVER_UNSET_PATH:-0}" = 1 ] && unset PATH
resolve() {
  case "$mode" in
    cmdv)   command -v "$1" ;;
    brew)   fn rsdd_brew_prefix ;;
    java)   fn rsdd_resolve_java_home ;;
    jar)    fn rsdd_resolve_java_jar "$1" ;;
    ghidra) fn rsdd_resolve_ghidra_home ;;
    r2)     fn rsdd_resolve_r2 ;;
    ilspy)  fn rsdd_resolve_ilspy ;;
    pkgcfg) fn rsdd_system_pkgconfig_path ;;
    *) echo "unknown mode: $mode" >&2; return 97 ;;
  esac
}
value="$(resolve "$@")"; rc=$?
[ "$rc" -ne 97 ] || die "harness failure in mode $mode"
[ -z "$value" ] || printf '%s\n' "$value"
exit "$rc"
