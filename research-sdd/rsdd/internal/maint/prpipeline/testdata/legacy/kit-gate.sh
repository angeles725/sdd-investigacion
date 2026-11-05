#!/usr/bin/env bash
# kit-gate.sh [--serial | --cmd CMD] [--state-dir DIR] [--lock-timeout SECONDS] <worktree> <label>
#
# Kit-maintenance tool (kit issue #2212): ONE serial full gate. A flock on <state-dir>/gate.lock makes concurrent
# callers queue, so only one gate runs at a time on this machine (CLAUDE.md section 3: only a quiet-tree gate is
# authoritative). The gate's output goes to <state-dir>/gate-<label>.log; the summary lines are echoed.
# Default CMD (run with bash -c inside <worktree>): bash research-sdd/toolbelt/tests/run-all.sh -j 4 --prove-teeth
# (the maintainer's established gate of record; -j 4 is the attributed parallel run, CLAUDE.md section 5).
# --serial runs `run-all.sh --prove-teeth` with NO -j instead: serial is the CLAUDE.md section 5 REFERENCE for the
# quiet-tree gate. Use it when a -j result is in doubt (a timing-only failure, a leak the -j attribution could not
# pin), or when the machine is loaded. --serial cannot be combined with --cmd.
# --lock-timeout SECONDS (env KIT_GATE_LOCK_TIMEOUT, default 14400): how long to wait for the gate lock.
# Never edit this file in place while a gate that started from it is queued or running: bash reads a script
# incrementally, so an in-place edit corrupts the live run. Copy, edit the copy, start new runs from it.
#
# Typed exit states (the gate's own rc is NOT passed through: it could collide with 2 or 3; it is in the log as
# `gate rc=N` and in the `kit-gate: gate rc=N` line):
#   0   the gate passed
#   2   usage              bad arguments, a missing worktree, or a --state-dir inside the worktree
#   3   degraded           flock or git missing: `degraded: missing runtime dependency: ...`
#   16  gate-failed        the gate command exited non-zero
#   22  gate-lock-timeout  the gate lock was not obtained within --lock-timeout
set -u
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
# shellcheck disable=SC2034 # read by kit-maint-common.sh
KIT_TOOL=kit-gate
# shellcheck source=kit-maint-common.sh
. "$_RSDD_SELF/kit-maint-common.sh" || { echo "kit-gate: degraded: kit-maint-common.sh unavailable" >&2; exit 3; }

cmd='bash research-sdd/toolbelt/tests/run-all.sh -j 4 --prove-teeth'
state='' serial=0 cmd_given=0 lock_timeout="${KIT_GATE_LOCK_TIMEOUT:-14400}"
while [ $# -gt 0 ]; do
  case "$1" in
    --cmd) [ $# -ge 2 ] || kit_fail 2 usage "--cmd needs a value"; cmd="$2"; cmd_given=1; shift 2 ;;
    --serial) serial=1; shift ;;
    --lock-timeout) [ $# -ge 2 ] || kit_fail 2 usage "--lock-timeout needs a value"; lock_timeout="$2"; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || kit_fail 2 usage "--state-dir needs a value"; state="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^[^#]/ { exit } NR > 1 { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    --) shift; break ;;
    -*) kit_fail 2 usage "unknown option $1" ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || kit_fail 2 usage "kit-gate.sh [--cmd CMD] [--state-dir DIR] <worktree> <label>"
wt="$1"; label="$2"
case "$label" in ''|*[!A-Za-z0-9._-]*) kit_fail 2 usage "label must match [A-Za-z0-9._-]+" ;; esac
case "$lock_timeout" in ''|*[!0-9]*) kit_fail 2 usage "--lock-timeout must be a number of seconds" ;; esac
[ "$serial" -eq 0 ] || [ "$cmd_given" -eq 0 ] || kit_fail 2 usage "--serial cannot be combined with --cmd"
[ "$serial" -eq 0 ] || cmd='bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth'
[ -d "$wt" ] || kit_fail 2 usage "worktree is not a directory: $wt"
kit_probe_deps flock git || exit 3
[ -n "$state" ] || state="$(kit_state_dir)"
wt_phys="$(CDPATH='' cd -- "$wt" && pwd -P)" || kit_fail 2 usage "cannot resolve the worktree"
state_phys="$(kit_phys_path "$state")" || kit_fail 2 usage "cannot resolve --state-dir $state"
case "$state_phys/" in "$wt_phys"/*) kit_fail 2 usage "--state-dir $state_phys is inside the worktree; state never lives in the repo" ;; esac
state="$state_phys"
mkdir -p "$state" || kit_fail 2 usage "cannot create state dir $state"
log="$state/gate-$label.log"
exec 9>"$state/gate.lock"
flock -w "$lock_timeout" 9 || kit_fail 22 gate-lock-timeout "could not take $state/gate.lock within ${lock_timeout}s"
cd "$wt" || kit_fail 2 usage "cannot cd to $wt"
echo "head $(git rev-parse --short HEAD)" > "$log"
bash -c "$cmd" >> "$log" 2>&1
rc=$?
echo "gate rc=$rc" >> "$log"
grep -E 'AGGREGATE|passed|failed|Suites|FAIL  |leftovers|hermeticity' "$log" | tail -15
kit_say "gate rc=$rc log=$log"
gate_exit=0
[ "$rc" -eq 0 ] || gate_exit=16
exit "$gate_exit"
