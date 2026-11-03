# _blocked_degraded_files FILE... (kit #2024): the shared "could the blocked set be read?" probe for EVERY state file a verdict walks.
# Prints the comma-joined basenames whose blocked-section extraction DEGRADED (blocked_open_count rc 3) and returns 1; prints nothing
# and returns 0 when none did. rc 2 (state file absent or unreadable) is NOT counted here: it is its own typed state, surfaced by the
# [backlog-unreadable: ...] qualifier (kit #1959), and an unreadable file yields no backlog rows either, so is_blocked is never asked. Silent on stderr (callers print their own typed line); it takes files, never the global $state, so a loop that reassigns
# $state cannot point it at the wrong focus. is_blocked/blocked_names/count_investigable all read the same extractors, so a failure
# here means every blocked/investigable figure derived from that file is untrustworthy.
_rel_state() { local _rs_p="$1" _rs_t="${target%/}"; case "$_rs_p" in "$_rs_t"/*) printf '%s' "${_rs_p#"$_rs_t"/}" ;; *) printf '%s' "$_rs_p" ;; esac; }  # #2024 S2: path relative to the target (split layouts repeat basenames)
_blocked_degraded_files() {
  local _bd_f _bd_rc _bd_names=""
  for _bd_f in "$@"; do  # BD-ALL-FOCUSES
    blocked_open_count "$_bd_f" >/dev/null 2>&1; _bd_rc=$?
    { [ "$_bd_rc" -eq 0 ] || [ "$_bd_rc" -eq 2 ]; } || _bd_names="${_bd_names:+$_bd_names,}$(_rel_state "$_bd_f")"
  done
  [ -z "$_bd_names" ] || { printf '%s' "$_bd_names"; return 1; }
  return 0
}
