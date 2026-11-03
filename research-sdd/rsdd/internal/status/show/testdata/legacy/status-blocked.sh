blocked_names() {
  local _bn_body   # BODY-RC (#2017 W1): capture the body WITH its rc; a failed extractor is rc 3, never an empty list
  _bn_body="$(blocked_body)" || return 3
  printf '%s\n' "$_bn_body" | sed -n 's/^[[:space:]]*-[[:space:]]*//p' \
    | sed -E 's/[[:space:]]*[-–—]+[[:space:]]*needs:.*$//I; s/[[:space:]]*needs:.*$//I' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | { grep -v '^$' || [ "$?" -eq 1 ]; }   # grep rc 1 = no names (empty-input), only rc >= 2 is an error
}
is_blocked() {
  local g="$1" b _ib_names _ib_rc
  _ib_names="$(blocked_names)"; _ib_rc=$?
  if [ "$_ib_rc" -ne 0 ]; then   # IS-BLOCKED-DEGRADED: an unreadable blocked section must not read as "nothing is blocked" silently
    printf 'research-sdd-status: blocked sections could not be extracted (rc %s on %s) — blocked status UNKNOWN (degraded derivation; callers fail closed)\n' "$_ib_rc" "$state" >&2
    return 2   # IS-BLOCKED-RC2 (#2024 S3): 0 blocked, 1 not blocked, 2 UNKNOWN (degraded) — resolve_next treats 2 as fatal
  fi
  while IFS= read -r b; do [ "$b" = "$g" ] && return 0; done <<<"$_ib_names"; return 1
}
