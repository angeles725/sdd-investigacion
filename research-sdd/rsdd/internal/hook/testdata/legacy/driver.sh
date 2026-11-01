#!/usr/bin/env bash
# Differential-test driver: asks the frozen bash half of lib/hook-wiring.sh the same questions the Go port answers.
# Usage: driver.sh <wiring|script|root|abs|launch|exec> <arg>...   Every answer is NUL-terminated (a path may hold a newline).
#   wiring <dir>...  hook_stop_wiring_state_var       -> state
#   script <dir>...  hook_stop_script_state_var       -> state
#   root   <dir>...  _hw_find_git_root                -> HW_TARGET_IS_ROOT, HW_GIT_ROOT
#   abs    <path>... _hw_abspath                      -> HW_ABS_PATH
#   launch <dir>...  hook_stop_launch_state_var       -> state (kit issue #2357; needs hook-wiring-half2.sh)
#   exec   <dir>...  hook_wired_exec_report           -> its stdout, one NUL after each target's report
#   cli-wiring-state <dir> / cli-script-state <dir>   the same predicates, newline-terminated and single-target:
#                    the exact shape of `rsdd hook wiring-state` / `rsdd hook script-state` (testkit/parity cases).
set -u
here="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=hook-wiring-half1.sh
. "$here/hook-wiring-half1.sh"
# shellcheck source=hook-wiring-half2.sh
. "$here/hook-wiring-half2.sh"
mode="${1:?mode}"; shift
for a in "$@"; do
  case "$mode" in
    wiring) hook_stop_wiring_state_var "$a"; printf '%s\0' "$HOOK_WIRING_STATE" ;;
    script) hook_stop_script_state_var "$a"; printf '%s\0' "$HOOK_SCRIPT_STATE" ;;
    root) _hw_find_git_root "$a"; printf '%s\0%s\0' "$HW_TARGET_IS_ROOT" "$HW_GIT_ROOT" ;;
    abs) _hw_abspath "$a"; printf '%s\0' "$HW_ABS_PATH" ;;
    launch) hook_stop_launch_state_var "$a"; printf '%s\0' "$HOOK_LAUNCH_STATE" ;;
    exec) hook_wired_exec_report "$a"; printf '\0' ;;
    cli-wiring-state) hook_stop_wiring_state_var "$a"; printf '%s\n' "$HOOK_WIRING_STATE" ;;
    cli-script-state) hook_stop_script_state_var "$a"; printf '%s\n' "$HOOK_SCRIPT_STATE" ;;
    *) echo "driver: unknown mode $mode" >&2; exit 2 ;;
  esac
done
