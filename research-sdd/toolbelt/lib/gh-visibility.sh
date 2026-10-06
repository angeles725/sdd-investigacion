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
  # _ghv_sig <signal> <pid> <group|""> — signal the whole process group when <group> is set (falls back to the pid).
  _ghv_sig() {
    if [ -n "$3" ]; then kill "-$1" -- "-$2" 2>/dev/null || kill "-$1" "$2" 2>/dev/null; else kill "-$1" "$2" 2>/dev/null; fi
  }
  # _ghv_arm_watchdog <pid> <seconds> [group] — background watchdog: after <seconds> it kills <pid>. Sets GHV_WDPID.
  # Disarming it is `kill "$GHV_WDPID"`: the TERM trap kills the watchdog's own `sleep` child first, so a stopped
  # watchdog never leaves a stray sleep running for the rest of the bound (kit issue #1834: a plain `kill` of the
  # subshell orphaned its sleep).
  _ghv_arm_watchdog() {
    ( sp=""; trap '[ -z "$sp" ] || kill "$sp" 2>/dev/null; exit 0' TERM; sleep "$2" & sp=$!; wait "$sp"; _ghv_sig TERM "$1" "$3"
      sleep 2 & sp=$!; wait "$sp"; _ghv_sig KILL "$1" "$3" ) >/dev/null 2>&1 &   # RSDD-GH-WATCHDOG-ARM
    GHV_WDPID=$!
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
      local outf pid wdpid grp=() grpflag=""
      outf="$(mktemp 2>/dev/null)" || { rm -f "$err"; GHV_STATE=PROBE_FAILED; return 1; }
      _ghv_group_mode
      if [ "$GHV_GROUP" = setsid ]; then grp=(setsid); grpflag=group; fi
      ( cd "$run_dir" && exec ${grp[@]+"${grp[@]}"} env -u GH_REPO GH_PROMPT_DISABLED=1 "${cmd[@]}" >"$outf" 2>"$err" ) &   # RSDD-GH-WATCHDOG
      pid=$!
      _ghv_arm_watchdog "$pid" "$t" "$grpflag"
      wdpid="$GHV_WDPID"
      wait "$pid" 2>/dev/null || rc=$?
      kill "$wdpid" 2>/dev/null || :
      wait "$wdpid" 2>/dev/null || :
      # the bound fired (TERM/KILL of the leader): sweep the group once more so a TERM-ignoring grandchild cannot linger
      if [ "$rc" = 143 ] || [ "$rc" = 137 ]; then _ghv_sig KILL "$pid" "$grpflag"; fi
      [ "$rc" = 143 ] && rc=124
      out="$(cat "$outf" 2>/dev/null)"; rm -f "$outf"
    else
      out="$(cd "$run_dir" && env -u GH_REPO GH_PROMPT_DISABLED=1 "${cmd[@]}" 2>"$err")" || rc=$?
    fi
    GHV_RC="$rc"
    GHV_WHY="$(sed -n '1p' "$err" 2>/dev/null)"; rm -f "$err"
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
    local t="$GHV_BOUND" bounder rc=0 pid wdpid grp=() grpflag=""
    GHV_GROUP="" GHV_NOTE=""
    bounder="$(_ghv_pick_bounder)"
    if [ -n "$bounder" ]; then
      GHV_BOUNDED_BY="$bounder"
      env -u GH_REPO GH_PROMPT_DISABLED=1 "$bounder" -k 2 "$t" "$@" || rc=$?
    else
      GHV_BOUNDED_BY=watchdog
      _ghv_group_mode
      if [ "$GHV_GROUP" = setsid ]; then grp=(setsid); grpflag=group; fi
      ( exec ${grp[@]+"${grp[@]}"} env -u GH_REPO GH_PROMPT_DISABLED=1 "$@" ) &   # RSDD-GH-WATCHDOG-RUN
      pid=$!
      _ghv_arm_watchdog "$pid" "$t" "$grpflag"
      wdpid="$GHV_WDPID"
      wait "$pid" 2>/dev/null || rc=$?
      kill "$wdpid" 2>/dev/null || :
      wait "$wdpid" 2>/dev/null || :
      if [ "$rc" = 143 ] || [ "$rc" = 137 ]; then _ghv_sig KILL "$pid" "$grpflag"; fi
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
