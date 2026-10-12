#!/usr/bin/env bash
# kit-gate.sh [--cmd CMD] [--state-dir DIR] <worktree> <label>
#
# Kit-maintenance tool (kit issue #2212): ONE serial full gate. A flock on <state-dir>/gate.lock makes concurrent
# callers queue, so only one gate runs at a time on this machine (CLAUDE.md section 3: only a quiet-tree gate is
# authoritative). The gate's output goes to <state-dir>/gate-<label>.log; the summary lines are echoed.
# Default CMD (run with bash -c inside <worktree>): bash research-sdd/toolbelt/tests/run-all.sh -j 4 --prove-teeth
# Never edit this file in place while a gate that started from it is queued or running: bash reads a script
# incrementally, so an in-place edit corrupts the live run. Copy, edit the copy, start new runs from it.
#
# Exit = the gate's own rc, except the typed tool states:
#   2  usage      bad arguments or a missing worktree
#   3  degraded   flock or git missing: `degraded: missing runtime dependency: ...`
# (the pipeline maps any non-zero gate rc to its own `gate-failed` state, exit 16)
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
state=''
while [ $# -gt 0 ]; do
  case "$1" in
    --cmd) [ $# -ge 2 ] || kit_fail 2 usage "--cmd needs a value"; cmd="$2"; shift 2 ;;
    --state-dir) [ $# -ge 2 ] || kit_fail 2 usage "--state-dir needs a value"; state="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    --) shift; break ;;
    -*) kit_fail 2 usage "unknown option $1" ;;
    *) break ;;
  esac
done
[ $# -eq 2 ] || kit_fail 2 usage "kit-gate.sh [--cmd CMD] [--state-dir DIR] <worktree> <label>"
wt="$1"; label="$2"
case "$label" in ''|*[!A-Za-z0-9._-]*) kit_fail 2 usage "label must match [A-Za-z0-9._-]+" ;; esac
[ -d "$wt" ] || kit_fail 2 usage "worktree is not a directory: $wt"
kit_probe_deps flock git || exit 3
[ -n "$state" ] || state="$(kit_state_dir)"
mkdir -p "$state" || kit_fail 2 usage "cannot create state dir $state"
log="$state/gate-$label.log"
exec 9>"$state/gate.lock"
flock 9 || kit_fail 3 degraded "flock failed on $state/gate.lock"
cd "$wt" || kit_fail 2 usage "cannot cd to $wt"
echo "head $(git rev-parse --short HEAD)" > "$log"
bash -c "$cmd" >> "$log" 2>&1
rc=$?
echo "gate rc=$rc" >> "$log"
grep -E 'AGGREGATE|passed|failed|Suites|FAIL  |leftovers|hermeticity' "$log" | tail -15
kit_say "gate rc=$rc log=$log"
exit "$rc"
