#!/usr/bin/env bash
# gh-visibility.sh — shared helper: ONE bounded `gh repo view --json visibility` probe (kit issue #1820).
# Sourced by ensure-remote.sh, research-sdd-init.sh (vendor-leak step) and research-sdd-status.sh (remote-visibility
# block) so every caller shares one default, one validation and one failure vocabulary. Never a silent empty.
#
#   gh_visibility_probe <gh-bin> <repo-arg> [<cwd>]
#     Runs `<gh-bin> repo view <repo-arg> --json visibility --jq .visibility` bounded by RSDD_GH_TIMEOUT
#     seconds (a positive integer; default $GHV_DEFAULT_BOUND, itself 20 unless the caller sets it — status sets 10 to keep
#     its latency budget; unset -> default silently; empty/garbage/0/>9 digits -> default and
#     GHV_BAD_TIMEOUT=1). GH_PROMPT_DISABLED=1, GH_REPO unset. Bound enforced by `timeout`, else `gtimeout`,
#     else a bash watchdog (gh backgrounded, `sleep N; kill`; GHV_BOUNDED_BY=watchdog).
#     Optional <cwd>: the probe runs inside it.
#     Returns 0 ONLY when the answer is decided; sets these globals (always, every call):
#       GHV_STATE   PUBLIC | PRIVATE | INTERNAL            decided (return 0)
#                   TIMEOUT                                 gh exceeded the bound
#                   GH_MISSING                              <gh-bin> not on PATH
#                   GH_ERROR                                gh (or timeout) exited non-zero (GHV_RC, GHV_WHY)
#                   UNRECOGNISED                            exit 0 but an answer that is not one of the three
#                   PROBE_FAILED                            the probe itself could not run (no temp file)
#       GHV_RC      the gh/timeout exit code (124 = timed out; 143 from the watchdog is normalised to 124)
#       GHV_WHY     first stderr line of gh, or ""
#       GHV_RAW     the raw stdout (upper-cased), for UNRECOGNISED reporting
#       GHV_BOUND   the bound in seconds that was applied
#       GHV_BOUNDED_BY  timeout | gtimeout | watchdog
#       GHV_BAD_TIMEOUT 1 when RSDD_GH_TIMEOUT was present but not a positive integer
#     FAIL CLOSED: callers must treat every non-zero return as "unknown", NEVER as PRIVATE.
#
#   gh_bounded_run <cmd> [args...]   (kit issue #1841)
#     The same bound for any OTHER gh call whose output the caller wants on its own stdout/stderr (ensure-remote.sh:
#     `gh repo create` / `gh repo edit`). Same RSDD_GH_TIMEOUT validation, same timeout -> gtimeout -> watchdog ladder,
#     GH_PROMPT_DISABLED=1, GH_REPO unset. stdout/stderr pass through untouched. Returns the command's exit code
#     (124 when the bound expired). Sets GHV_STATE (OK | TIMEOUT | GH_ERROR | GH_MISSING), GHV_RC, GHV_BOUND,
#     GHV_BOUNDED_BY, GHV_BAD_TIMEOUT. A TIMEOUT means the outcome is UNKNOWN (the remote operation may have landed):
#     callers must re-read the state they care about, never assume either way.
#     The bound knob is overridable per call: `GHV_BOUND_ENV=<VAR> GHV_BOUND_DEFAULT=<n> gh_bounded_run ...` reads the
#     bound from $VAR (same validation, garbage -> <n> + GHV_BAD_TIMEOUT=1) instead of RSDD_GH_TIMEOUT. A command that
#     ignores the TERM sent at the bound is KILLed after a 2 s grace (reported as the same 124 / TIMEOUT).
#
#   Process-group kill on the watchdog path (kit issue #1854): the bounded command runs under `setsid` (own session, so
#   pgid == pid) and the watchdog signals the whole GROUP (`kill -- -PID`), so a helper process spawned by gh cannot
#   outlive the bound. Two more globals, set ONLY when the watchdog is the bounder (empty with timeout/gtimeout):
#       GHV_GROUP   setsid | child-only     how the watchdog signals (child-only = direct child only)
#       GHV_NOTE    "" | DEGRADED: ...      typed note when group kill is unavailable (no `setsid` on PATH, or the caller
#                                           shell has job control on, where a backgrounded setsid would fork and detach)
#   The group (pgid == pid) is VERIFIED with `ps -o pgid=` after launch; a missing ps or a mismatch also degrades to
#   child-only with a typed note naming the pgid. The post-bound sweep signals the group only (never a bare, possibly
#   recycled, pid) and is skipped in child-only mode. From BEFORE the launch until the run ends, the caller's INT/TERM/HUP
#   traps kill the group (setsid detaches it from the terminal) and then re-raise; the caller's previous traps are restored
#   afterwards. Remaining sub-millisecond windows (kit #1911): a signal between a fork and the assignment that records it
#   is covered for the command by the handler's `$!` fallback, but one landing between the watchdog's fork and its
#   recording leaves that watchdog to expire on its own (it signals the already-dead leader/group at the bound).
#   If the caller is signalled while the watchdog waits and its own restored trap does NOT exit, the run reports
#   GHV_STATE=CALLER_SIGNALLED (non-zero return; never TIMEOUT) and skips the verification, the sweep and the bound.
#   child-only is the documented limit: a grandchild of the bounded command may outlive the kill. Callers should print
#   GHV_NOTE when it is non-empty and the state is TIMEOUT.
# shellcheck disable=SC2034  # GHV_* are the lib's result globals, read by the sourcing callers
if ! declare -F _ghv_resolve_bound >/dev/null 2>&1; then
  # _ghv_resolve_bound — sets GHV_BOUND (seconds) and GHV_BAD_TIMEOUT from RSDD_GH_TIMEOUT / GHV_DEFAULT_BOUND.
  _ghv_resolve_bound() {
    local dflt="${GHV_DEFAULT_BOUND:-20}" t benv="${GHV_BOUND_ENV:-RSDD_GH_TIMEOUT}"
    dflt="${GHV_BOUND_DEFAULT:-$dflt}"
    GHV_BAD_TIMEOUT=0
    t="$dflt"; [ -n "${!benv+x}" ] && t="${!benv}"
    case "$t" in
      ''|*[!0-9]*) t=0 ;;
      *) t="${t#"${t%%[!0]*}"}"; t="${t:-0}" ;;
    esac
    if [ "${#t}" -gt 9 ] || [ "$((10#$t))" -eq 0 ]; then GHV_BAD_TIMEOUT=1; t="$dflt"; else t=$((10#$t)); fi
    GHV_BOUND="$t"
  }
  # _ghv_pick_bounder — prints timeout | gtimeout, or nothing when the bash watchdog must be used.
  _ghv_pick_bounder() {
    if command -v timeout >/dev/null 2>&1; then printf 'timeout'
    elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'; fi
  }
  # _ghv_group_mode — sets GHV_GROUP (setsid | child-only) and GHV_NOTE for the watchdog path (kit issue #1854).
  _ghv_group_mode() {
    GHV_GROUP=setsid GHV_NOTE=""
    if ! command -v setsid >/dev/null 2>&1; then
      GHV_GROUP=child-only GHV_NOTE="DEGRADED: no setsid on PATH — the watchdog kills only the direct child; a grandchild of the bounded command may outlive the bound"
    else
      case "$-" in *m*)
        GHV_GROUP=child-only GHV_NOTE="DEGRADED: job control is on (set -m) — a backgrounded setsid would fork and detach; the watchdog kills only the direct child, a grandchild may outlive the bound" ;;
      esac
    fi
  }
  # _ghv_sig <signal> <pid> <group|""> — signal the whole process group when <group> is set, else just the pid. In
  # group mode there is NO bare-pid fallback: the group was verified (pgid == pid) at launch, and a bare kill of a pid
  # whose leader was already reaped could hit a recycled pid.
  _ghv_sig() {
    if [ -n "$3" ]; then kill "-$1" -- "-$2" 2>/dev/null || :; else kill "-$1" "$2" 2>/dev/null || :; fi
  }
  # _ghv_sweep <pid> <group|""> — post-bound KILL sweep of the GROUP, after the leader was reaped. Child-only mode has
  # nothing safe to signal (a reaped pid may be recycled), so it does nothing.
  _ghv_sweep() {
    [ -n "$2" ] || return 0
    kill -KILL -- "-$1" 2>/dev/null || :
  }
  # _ghv_verify_group <pid> — 0 only when the launched leader's pgid is verified == pid (setsid took effect and did not
  # fork); 1 when ps is missing or the pgid never matches; 2 when the leader had already exited (both unverified). Polls ~2s
  # because the backgrounded subshell only becomes a group leader once it has exec'd setsid.
  _ghv_verify_group() {
    local pg i=0
    command -v ps >/dev/null 2>&1 || return 1
    while [ "$i" -lt 20 ]; do
      pg="$(ps -o pgid= -p "$1" 2>/dev/null)"; pg="${pg//[[:space:]]/}"
      [ "$pg" = "$1" ] && return 0
      kill -0 "$1" 2>/dev/null || return 2   # leader already gone: nothing was verified, so no group sweep either
      sleep 0.1; i=$((i+1))
    done
    return 1
  }
  # _ghv_note_unverified <verify rc> — sets GHV_GROUP=child-only and the typed note for an unverified group.
  _ghv_note_unverified() {
    GHV_GROUP=child-only
    if [ "$1" = 2 ]; then GHV_NOTE="DEGRADED: the command had already exited when its pgid was checked — no group was verified, so nothing is swept as a group"
    else GHV_NOTE="DEGRADED: could not verify the command's pgid == pid (ps missing or disagrees) — the watchdog kills only the direct child; a grandchild may outlive the bound"; fi
  }
  # _ghv_set_traps / _ghv_restore_traps — a new session detaches the command from the terminal's
  # Ctrl-C / SIGHUP, so the caller's INT/TERM/HUP must take the group down. The previous traps are saved and restored;
  # the handler restores them first and then re-raises the signal so the caller's own disposition still applies.
  # The handler also disarms the watchdog, else it would later TERM/KILL a recycled pid/pgid.
  _ghv_set_traps() {
    _GHV_PT_INT="$(trap -p INT)"; _GHV_PT_TERM="$(trap -p TERM)"; _GHV_PT_HUP="$(trap -p HUP)"
    # Installed BEFORE the command is launched (kit issue #1911): a signal that lands between the launch and a later
    # install (e.g. during the up-to-2s pgid verification) would otherwise kill the caller with the group and the
    # watchdog still alive. The handler therefore reads the state LATE-BOUND from _GHV_PID / _GHV_GRP / _GHV_WD. The
    # caller sets _GHV_GRP (the intended group mode) BEFORE the launch: a group kill of a group that does not exist yet
    # is a harmless ESRCH. _GHV_PID is recorded in the same command as the caller's `pid=$!`; _GHV_WD inside
    # _ghv_arm_watchdog right after its fork.
    _GHV_PID="" _GHV_GRP="" _GHV_WD="" _GHV_BANG0="${!:-}"
    trap "_ghv_on_signal INT" INT
    trap "_ghv_on_signal TERM" TERM
    trap "_ghv_on_signal HUP" HUP
  }
  _ghv_restore_traps() {
    if [ -n "$_GHV_PT_INT" ]; then eval "$_GHV_PT_INT"; else trap - INT; fi
    if [ -n "$_GHV_PT_TERM" ]; then eval "$_GHV_PT_TERM"; else trap - TERM; fi
    if [ -n "$_GHV_PT_HUP" ]; then eval "$_GHV_PT_HUP"; else trap - HUP; fi
  }
  _ghv_on_signal() { # <SIG> — state from _GHV_PID / _GHV_GRP / _GHV_WD (late-bound, see _ghv_set_traps)
    _GHV_SIGNALLED="$1"          # read after `wait` if the caller's restored trap does not exit
    # Group mode signals the GROUP only (kit #1854): bash reaps background children asynchronously, so a bare pid may be
    # recycled before the caller's `wait`. The one exception is the `$!` fallback below (the pid just forked, so it cannot
    # have been recycled yet; the group may not exist yet either because setsid has not exec'd).
    local pid="${_GHV_PID:-}" fb=""
    if [ -z "$pid" ] && [ "${!:-}" != "$_GHV_BANG0" ]; then pid="$!"; fb=1; fi   # a NEW background pid only, never a stale one
    if [ -n "$pid" ]; then
      _ghv_sig KILL "$pid" "$_GHV_GRP"   # group form when _GHV_GRP is set, else the bare pid (child-only mode)
      [ -z "$fb" ] || kill -KILL "$pid" 2>/dev/null || :
    fi
    [ -z "$_GHV_WD" ] || kill "$_GHV_WD" 2>/dev/null || :   # the watchdog's TERM trap kills its own sleep first
    # shellcheck disable=SC2086  # a space-separated list of the probe's own mktemp paths (no whitespace in mktemp names)
    [ -z "${_GHV_TMPFILES:-}" ] || rm -f $_GHV_TMPFILES   # the caller dies right after: the probe's temp files would leak
    _ghv_restore_traps
    kill -s "$1" "$BASHPID"      # BASHPID, not $$: inside $(...) $$ is the TOP-LEVEL shell
  }
  # _ghv_arm_watchdog <pid> <seconds> [group] — background watchdog: after <seconds> it kills <pid>. Sets GHV_WDPID.
  # Disarming it is `kill "$GHV_WDPID"`: the TERM trap kills every job of the watchdog (`jobs -p`, so no window between
  # `sleep &` and a saved pid can orphan the sleep) first, so a stopped
  # watchdog never leaves a stray sleep running for the rest of the bound (kit issue #1834: a plain `kill` of the
  # subshell orphaned its sleep).
  _ghv_arm_watchdog() {
    ( trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM; sleep "$2" & wait; _ghv_sig TERM "$1" "$3"
      sleep 2 & wait; _ghv_sig KILL "$1" "$3" ) >/dev/null 2>&1 &   # RSDD-GH-WATCHDOG-ARM
    GHV_WDPID=$! _GHV_WD=$!
  }
fi
if ! declare -F gh_visibility_probe >/dev/null 2>&1; then
  gh_visibility_probe() {
    local ghbin="$1" repo="$2" cwd="${3:-}"
    GHV_STATE="" GHV_RC=0 GHV_WHY="" GHV_RAW="" GHV_BOUND=${GHV_DEFAULT_BOUND:-20} GHV_BOUNDED_BY="" GHV_BAD_TIMEOUT=0 GHV_GROUP="" GHV_NOTE=""
    if ! command -v "$ghbin" >/dev/null 2>&1; then GHV_STATE=GH_MISSING; return 1; fi
    _ghv_resolve_bound
    local t="$GHV_BOUND"
    local cmd=("$ghbin" repo view "$repo" --json visibility --jq .visibility) bounder=""
    bounder="$(_ghv_pick_bounder)"
    if [ -n "$bounder" ]; then cmd=("$bounder" "$t" "${cmd[@]}"); GHV_BOUNDED_BY="$bounder"; else GHV_BOUNDED_BY=watchdog; fi
    local err out="" rc=0 run_dir="${cwd:-.}"
    err="$(mktemp 2>/dev/null)" || { GHV_STATE=PROBE_FAILED; return 1; }
    if [ "$GHV_BOUNDED_BY" = watchdog ]; then
      local outf pid wdpid vrc grp=() grpflag=""
      outf="$(mktemp 2>/dev/null)" || { rm -f "$err"; GHV_STATE=PROBE_FAILED; return 1; }
      _GHV_TMPFILES="$outf $err"
      _ghv_group_mode
      if [ "$GHV_GROUP" = setsid ]; then grp=(setsid); grpflag=group; fi
      _GHV_SIGNALLED=""
      _ghv_set_traps; _GHV_GRP="$grpflag"   # BEFORE the launch (kit issue #1911): no launch without a handler
      ( cd "$run_dir" && exec ${grp[@]+"${grp[@]}"} env -u GH_REPO GH_PROMPT_DISABLED=1 "${cmd[@]}" >"$outf" 2>"$err" ) &   # RSDD-GH-WATCHDOG
      pid=$! _GHV_PID=$!
      if [ -n "$grpflag" ] && [ -z "$_GHV_SIGNALLED" ]; then
        _ghv_verify_group "$pid" || { vrc=$?; grpflag=""; _GHV_GRP=""; [ -n "$_GHV_SIGNALLED" ] || _ghv_note_unverified "$vrc"; }
      fi
      wdpid=""
      if [ -z "$_GHV_SIGNALLED" ]; then _ghv_arm_watchdog "$pid" "$t" "$grpflag"; wdpid="$GHV_WDPID"; fi
      wait "$pid" 2>/dev/null || rc=$?
      _ghv_restore_traps
      if [ -n "$_GHV_SIGNALLED" ]; then
        # the caller's own trap did not exit: group and watchdog were already handled in the handler; the group and the
        # leader are reaped, so no sweep, no watchdog kill and NO TIMEOUT mapping — a typed caller-signal state instead
        [ -z "$wdpid" ] || { kill "$wdpid" 2>/dev/null || :; wait "$wdpid" 2>/dev/null || :; }   # armed just before the signal
        rm -f "$outf" "$err"; _GHV_TMPFILES=""; GHV_RC="$rc"; GHV_STATE=CALLER_SIGNALLED; return 1
      fi
      kill "$wdpid" 2>/dev/null || :
      wait "$wdpid" 2>/dev/null || :
      # the bound fired (TERM/KILL of the leader): sweep the GROUP once more so a TERM-ignoring grandchild cannot linger
      if [ "$rc" = 143 ] || [ "$rc" = 137 ]; then _ghv_sweep "$pid" "$grpflag"; fi
      [ "$rc" = 143 ] && rc=124
      out="$(cat "$outf" 2>/dev/null)"; rm -f "$outf"; _GHV_TMPFILES="$err"
    else
      out="$(cd "$run_dir" && env -u GH_REPO GH_PROMPT_DISABLED=1 "${cmd[@]}" 2>"$err")" || rc=$?
    fi
    GHV_RC="$rc"
    GHV_WHY="$(sed -n '1p' "$err" 2>/dev/null)"; rm -f "$err"; _GHV_TMPFILES=""
    GHV_RAW="$(printf '%s' "$out" | tr '[:lower:]' '[:upper:]')"
    if [ "$rc" = 124 ]; then GHV_STATE=TIMEOUT; return 1; fi
    if [ "$rc" != 0 ]; then GHV_STATE=GH_ERROR; return 1; fi
    case "$GHV_RAW" in
      PUBLIC|PRIVATE|INTERNAL) GHV_STATE="$GHV_RAW"; return 0 ;;
      *) GHV_STATE=UNRECOGNISED; return 1 ;;
    esac
  }
fi

if ! declare -F gh_bounded_run >/dev/null 2>&1; then
  gh_bounded_run() {
    GHV_STATE="" GHV_RC=0 GHV_BOUND=${GHV_DEFAULT_BOUND:-20} GHV_BOUNDED_BY="" GHV_BAD_TIMEOUT=0
    if [ "$#" -eq 0 ] || ! command -v "$1" >/dev/null 2>&1; then GHV_STATE=GH_MISSING; GHV_RC=127; return 127; fi
    _ghv_resolve_bound
    local t="$GHV_BOUND" bounder rc=0 pid wdpid vrc grp=() grpflag=""
    GHV_GROUP="" GHV_NOTE=""
    bounder="$(_ghv_pick_bounder)"
    if [ -n "$bounder" ]; then
      GHV_BOUNDED_BY="$bounder"
      env -u GH_REPO GH_PROMPT_DISABLED=1 "$bounder" -k 2 "$t" "$@" || rc=$?
    else
      GHV_BOUNDED_BY=watchdog
      _ghv_group_mode
      if [ "$GHV_GROUP" = setsid ]; then grp=(setsid); grpflag=group; fi
      _GHV_SIGNALLED=""
      _ghv_set_traps; _GHV_GRP="$grpflag"   # BEFORE the launch (kit issue #1911)
      ( exec ${grp[@]+"${grp[@]}"} env -u GH_REPO GH_PROMPT_DISABLED=1 "$@" ) &   # RSDD-GH-WATCHDOG-RUN
      pid=$! _GHV_PID=$!
      if [ -n "$grpflag" ] && [ -z "$_GHV_SIGNALLED" ]; then
        _ghv_verify_group "$pid" || { vrc=$?; grpflag=""; _GHV_GRP=""; [ -n "$_GHV_SIGNALLED" ] || _ghv_note_unverified "$vrc"; }
      fi
      wdpid=""
      if [ -z "$_GHV_SIGNALLED" ]; then _ghv_arm_watchdog "$pid" "$t" "$grpflag"; wdpid="$GHV_WDPID"; fi
      wait "$pid" 2>/dev/null || rc=$?
      _ghv_restore_traps
      if [ -n "$_GHV_SIGNALLED" ]; then
        [ -z "$wdpid" ] || { kill "$wdpid" 2>/dev/null || :; wait "$wdpid" 2>/dev/null || :; }
        GHV_RC="$rc"; GHV_STATE=CALLER_SIGNALLED; return "$rc"; fi
      kill "$wdpid" 2>/dev/null || :
      wait "$wdpid" 2>/dev/null || :
      if [ "$rc" = 143 ] || [ "$rc" = 137 ]; then _ghv_sweep "$pid" "$grpflag"; fi
      [ "$rc" = 143 ] && rc=124
    fi
    [ "$rc" = 137 ] && rc=124   # the bound's KILL escalation (command ignored TERM)
    GHV_RC="$rc"
    if [ "$rc" = 124 ]; then GHV_STATE=TIMEOUT
    elif [ "$rc" != 0 ]; then GHV_STATE=GH_ERROR
    else GHV_STATE=OK; fi
    return "$rc"
  }
fi
