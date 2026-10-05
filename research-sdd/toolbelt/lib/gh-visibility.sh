#!/usr/bin/env bash
# gh-visibility.sh — shared helper: ONE bounded `gh repo view --json visibility` probe (kit issue #1820).
# Sourced by ensure-remote.sh (and, when migrated, research-sdd-init.sh / research-sdd-status.sh) so every
# caller shares one default, one validation and one failure vocabulary. Never a silent empty.
#
#   gh_visibility_probe <gh-bin> <repo-arg> [<cwd>]
#     Runs `<gh-bin> repo view <repo-arg> --json visibility --jq .visibility` bounded by RSDD_GH_TIMEOUT
#     seconds (a positive integer; default 20; unset -> 20 silently; empty/garbage/0/>9 digits -> 20 and
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
# shellcheck disable=SC2034  # GHV_* are the lib's result globals, read by the sourcing callers
if ! declare -F gh_visibility_probe >/dev/null 2>&1; then
  gh_visibility_probe() {
    local ghbin="$1" repo="$2" cwd="${3:-}"
    GHV_STATE="" GHV_RC=0 GHV_WHY="" GHV_RAW="" GHV_BOUND=20 GHV_BOUNDED_BY="" GHV_BAD_TIMEOUT=0
    if ! command -v "$ghbin" >/dev/null 2>&1; then GHV_STATE=GH_MISSING; return 1; fi
    local t="${RSDD_GH_TIMEOUT-20}"
    case "$t" in
      ''|*[!0-9]*) t=0 ;;
      *) t="${t#"${t%%[!0]*}"}"; t="${t:-0}" ;;
    esac
    if [ "${#t}" -gt 9 ] || [ "$((10#$t))" -eq 0 ]; then GHV_BAD_TIMEOUT=1; t=20; else t=$((10#$t)); fi
    GHV_BOUND="$t"
    local cmd=("$ghbin" repo view "$repo" --json visibility --jq .visibility) bounder=""
    if command -v timeout >/dev/null 2>&1; then bounder=timeout
    elif command -v gtimeout >/dev/null 2>&1; then bounder=gtimeout; fi
    if [ -n "$bounder" ]; then cmd=("$bounder" "$t" "${cmd[@]}"); GHV_BOUNDED_BY="$bounder"; else GHV_BOUNDED_BY=watchdog; fi
    local err out="" rc=0 run_dir="${cwd:-.}"
    err="$(mktemp 2>/dev/null)" || { GHV_STATE=PROBE_FAILED; return 1; }
    if [ "$GHV_BOUNDED_BY" = watchdog ]; then
      local outf pid wdpid
      outf="$(mktemp 2>/dev/null)" || { rm -f "$err"; GHV_STATE=PROBE_FAILED; return 1; }
      ( cd "$run_dir" && exec env -u GH_REPO GH_PROMPT_DISABLED=1 "${cmd[@]}" >"$outf" 2>"$err" ) &   # RSDD-GH-WATCHDOG
      pid=$!
      ( sleep "$t"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
      wdpid=$!
      wait "$pid" 2>/dev/null || rc=$?
      kill "$wdpid" 2>/dev/null || :
      wait "$wdpid" 2>/dev/null || :
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
