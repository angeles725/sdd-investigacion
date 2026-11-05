# TERMINAL NO-GARBAGE WARN (kit #1277 slice 2; METHODOLOGY §15, contract clean-check.v1.md). When --next resolves to an
# EXHAUSTED STOP (the §8 terminal trigger: `STOP | read-only-investigable exhausted (0)`, with or without the
# issue-coverage marker), run clean-check.sh over the target and echo its findings to STDERR as a loud WARN. Report-only by
# the maintainer decision (slice 1 = report-only): stdout, the verdict line, the --emit-token mapping and the exit code are
# UNCHANGED. Three states (§7): clean (one `INFO: clean-check: clean` line), findings (`WARN: clean-check: ...` per line), and
# unverifiable (a typed `WARN: clean-check: unverifiable (...)` for a missing script, a non-git target, or exit 2/3) — never a silent zero.
# RSDD_STATUS_NO_CLEAN_CHECK=1 skips it (the caller already ran clean-check).
terminal_clean_warn() {
  # No verdict argument: the only two callers sit on the exhausted-STOP print sites inside issues_due_gate, so there is no
  # second copy of the verdict text to drift (RDD round 2).
  [ "${RSDD_STATUS_NO_CLEAN_CHECK:-0}" = "1" ] && return 0
  local _cc_here _cc_script _cc_out _cc_rc _cc_ln
  _cc_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _cc_script="$_cc_here/clean-check.sh"
  if [ ! -f "$_cc_script" ]; then
    printf 'WARN: clean-check: unverifiable (clean-check.sh not found beside research-sdd-status.sh) — terminal no-garbage check NOT run\n' >&2
    return 0
  fi
  # Bounded (RSDD_STATUS_CLEAN_CHECK_TIMEOUT seconds, default 20): --next also runs from the Stop hook. No timeout/gtimeout =
  # typed unverifiable WARN, never an unbounded run.
  local _cc_to _cc_secs="${RSDD_STATUS_CLEAN_CHECK_TIMEOUT:-20}"
  # Exact positive-integer test (#1277 follow-up): digits only, and non-zero once leading zeros are stripped. The old
  # `0|0[0]*` glob rejected 005/007 (any `00`-prefixed value) yet accepted 01. GNU timeout treats 0 as "no limit", so a
  # zero value is never passed through; a valid value is normalised (010 -> 10).
  local _cc_stripped
  case "$_cc_secs" in
    ''|*[!0-9]*) _cc_stripped="" ;;
    *) _cc_stripped="${_cc_secs#"${_cc_secs%%[!0]*}"}" ;;
  esac
  if [ -z "$_cc_stripped" ]; then
    printf 'WARN: clean-check: invalid RSDD_STATUS_CLEAN_CHECK_TIMEOUT=%s (need an integer >= 1) — using 20\n' "$_cc_secs" >&2; _cc_secs=20
  else
    _cc_secs="$_cc_stripped"
  fi
  _cc_to="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  if [ -z "$_cc_to" ]; then
    printf 'WARN: clean-check: unverifiable (timeout/gtimeout not found, unbounded run refused) — terminal no-garbage check NOT run\n' >&2
    return 0
  fi
  _cc_out="$("$_cc_to" -k 5 "$_cc_secs" bash "$_cc_script" --target "$target" 2>&1)"; _cc_rc=$?
  case "$_cc_rc" in
    124|137) printf 'WARN: clean-check: unverifiable (timed out after %ss) — terminal no-garbage check NOT confirmed\n' "$_cc_secs" >&2 ;;
    0) printf 'INFO: clean-check: clean at terminal STOP\n' >&2 ;;
    1) printf 'WARN: clean-check: findings at terminal STOP — resolve or declare in <target>/.research-sdd/keep.txt before closing\n' >&2
       while IFS= read -r _cc_ln; do printf 'WARN: clean-check: %s\n' "$_cc_ln" >&2; done <<<"$_cc_out" ;;
    *) printf 'WARN: clean-check: unverifiable (exit %s: %s) — terminal no-garbage check NOT confirmed\n' "$_cc_rc" "$(printf '%s' "$_cc_out" | tail -n 1)" >&2 ;;
  esac
  return 0
}
