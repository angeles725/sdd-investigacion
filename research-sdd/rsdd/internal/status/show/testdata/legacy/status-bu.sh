
# _stop_exhausted — single source of truth for the exhausted-investigable STOP message.
# Both issues_due_gate and the --focus arm use this to prevent literal drift.
_stop_exhausted() { printf 'STOP | read-only-investigable exhausted (0)%s\n' "$_BU_SUFFIX"; }  # BU-STOP-EXHAUSTED

# _BU_SUFFIX (kit #1959): the inline ` [backlog-unreadable: N rows]` qualifier every `--next` exhausted STOP appends
# when the backlog parser left N rows UNCOUNTED (near-miss heading, no-Priority-header table, non-tier priority token,
# malformed row — count_uncounted_rows, the number --sync-state treats as a lower bound). Empty when N=0, so a clean
# backlog prints the bare STOP unchanged. _bu_compute STATE... sums the uncounted rows of exactly the state files the
# verdict covers (the picked file when --root/--focus scopes, else every state file, stopped and paused included) and sets
# _BU_SUFFIX. It swaps the global $state that backlog_rows reads and restores it.
_BU_SUFFIX=""
# A count that cannot be taken (unreadable state file, backlog parser failure, grep error) is NOT zero: it yields the
# typed ` [backlog-unreadable: unverified]` qualifier instead (kit #1959 W2), non-terminal exactly like a numeric one.
_bu_compute() {
  local _bu_saved="$state" _bu_total=0 _bu_unv=0 _bu_n _bu_f _bu_rows _bu_rc
  for _bu_f in "$@"; do
    state="$_bu_f"
    if [ ! -r "$_bu_f" ]; then _bu_unv=1; continue; fi  # BU-UNREADABLE-FILE
    _bu_rows="$(backlog_rows 1 2>/dev/null)"; _bu_rc=$?
    if [ "$_bu_rc" -ne 0 ]; then _bu_unv=1; continue; fi  # BU-PARSER-RC
    _bu_n="$(grep -c '^UNCOUNTED' <<<"$_bu_rows")"; _bu_rc=$?
    if [ "$_bu_rc" -gt 1 ]; then _bu_unv=1; continue; fi
    case "$_bu_n" in ''|*[!0-9]*) _bu_unv=1; continue ;; esac
    _bu_total=$(( _bu_total + _bu_n ))  # BU-SUM
  done
  state="$_bu_saved"
  _BU_SUFFIX=""
  if [ "$_bu_unv" -gt 0 ]; then _BU_SUFFIX=" [backlog-unreadable: unverified]"  # BU-UNVERIFIED
  elif [ "$_bu_total" -gt 0 ]; then _BU_SUFFIX=" [backlog-unreadable: ${_bu_total} rows]"; fi
  return 0
}

