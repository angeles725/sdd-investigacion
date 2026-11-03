if [ "$mode" = "--next" ]; then
  # kit issue #1837: the state file the --root / --focus picker chose. The STALE-bypass loop below reassigns the
  # global $state (count_investigable / env_get read it), so a scoped --next must read THIS copy, never $state.
  _ns_pick="$state"  # NEXT-PICK-SAVE
  # Refuse to hand out work on an internally inconsistent state (summary claims done while backlog
  # lists pending — verify-state.sh exits 1 on that). An agent trusting --next alone must reconcile first.
  # Use $target (not $corpus) so the STALE gate covers the same scope as the aggregation below: scanning
  # only $corpus=dirname(first) would miss sibling focuses in a split-layout and give a false green light.
  # kit #1543: with --focus <slug> the STALE gate verifies ONLY that focus (a legacy sibling's defects
  # must not brick a clean active focus). Without --focus (the default) or with --all it stays
  # corpus-wide, exactly as before.
  _gate_verify() {
    if [ -n "$focus_slug" ]; then "$here/verify-state.sh" "$target" --focus "$focus_slug" >/dev/null 2>&1
    else "$here/verify-state.sh" "$target" >/dev/null 2>&1; fi
  }
  # _stale_line: the STALE line. In a MULTI-focus corpus (corpus-wide mode) it also names the focus(es)
  # whose own verify-state fails, so the operator sees WHICH legacy focus bricks --next (kit #1543).
  # EVERY STALE line (single-focus, --focus, multi-focus) ends with `[first failure: <file>: <check>]` (kit #1544,
  # below); only the `[failing focus: …]` segment is multi-focus-only. The pre-#1543 prefix is unchanged.
  # kit #1544: the line also carries the FIRST failing verify-state check and the file it belongs to
  # (`[first failure: <file>: <check>]`), so the operator need not re-run the full report to find it.
  # _first_failure <verify-state args...>: first `   FAIL   ` line, prefixed by the `== verify-state: <file> (`
  # header it sits under. A FAIL line ending in ':' (e.g. "...found:") also carries the value line that follows.
  # Truncated to ~160 BYTES on a character boundary (LC_ALL=C awk + continuation-byte back-off, so mawk and
  # gawk agree and a multibyte char is never split). §7: when verify-state printed NO FAIL line (helper missing,
  # degraded, crash — its stderr is dropped) the pointer is the typed `unavailable — … (rc=N)`, never omitted.
  _first_failure() {
    local _ff_out _ff_rc=0 _ff_line
    _ff_out="$("$here/verify-state.sh" "$@" 2>/dev/null)" || _ff_rc=$?
    _ff_line="$(LC_ALL=C awk '
      function emit(  n) {
        n=157
        if (length(c)>160) { while (n>0 && substr(c,n+1,1) ~ /[\200-\277]/) n--; c=substr(c,1,n) "..." }
        print (f==""?"?":f) ": " c; done=1; exit
      }
      /^== verify-state: / { f=$0; sub(/^== verify-state: /,"",f); sub(/ \(target: .*$/,"",f); next }
      pend { v=$0; sub(/^[ \t]+/,"",v); c=c " " v; emit() }
      /^   FAIL   / { c=$0; sub(/^   FAIL   /,"",c); if (c ~ /:$/) { pend=1; next } emit() }
      END { if (!done && pend) emit() }
    ' <<<"$_ff_out")"  # STALE-FIRST-FAILURE
    if [ -n "$_ff_line" ]; then printf '%s' "$_ff_line"
    else printf 'unavailable — verify-state printed no FAIL line (rc=%s)' "$_ff_rc"; fi
  }
  _stale_line() {
    local _sl_line="STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh $target"
    local _sl_files _sl_f _sl_b _sl_names="" _sl_first="" _sl_ff=""
    mapfile -t _sl_files < <(list_state_files "$target")
    if [ "${#_sl_files[@]}" -ge 2 ] && [ -z "$focus_slug" ]; then
      for _sl_f in "${_sl_files[@]}"; do
        _sl_b="$(basename "$_sl_f" .md)"
        case "$_sl_b" in RESEARCH-STATE-?*) _sl_b="${_sl_b#RESEARCH-STATE-}" ;; *) continue ;; esac
        "$here/verify-state.sh" "$target" --focus "$_sl_b" >/dev/null 2>&1 || { _sl_names="${_sl_names:+$_sl_names,}$_sl_b"; [ -n "$_sl_first" ] || _sl_first="$_sl_b"; }
      done
      [ -n "$_sl_names" ] && _sl_line="$_sl_line [failing focus: $_sl_names]"
      # no focus file fails on its own (a stale ROOT RESEARCH-STATE.md, or a corpus-wide-only check): fall back
      # to the corpus-wide run so the pointer is still named instead of silently dropped.
      if [ -n "$_sl_first" ]; then _sl_ff="$(_first_failure "$target" --focus "$_sl_first")"
      else _sl_ff="$(_first_failure "$target")"; fi  # STALE-ROOT-FALLBACK
    elif [ -n "$focus_slug" ]; then
      _sl_ff="$(_first_failure "$target" --focus "$focus_slug")"
    else
      _sl_ff="$(_first_failure "$target")"
    fi
    [ -n "$_sl_ff" ] && _sl_line="$_sl_line [first failure: $_sl_ff]"
    printf '%s\n' "$_sl_line"
  }
  if ! _gate_verify; then
    if [ -z "$focus_slug" ]; then
      # Multi-focus bypass (issue #194): verify-state failed, but the failure may be ONLY from
      # genuinely stopped focuses whose envelopes were not re-seeded after all gaps were covered.
      # A stopped focus's stale envelope must NOT brick the corpus-wide --next result.
      # Classify each focus: unparseable backlog OR active focus (d_inv>0) with a stale critical
      # field → real STALE; stopped focus (parseable + d_inv=0) → skip (forgive stale envelope).
      mapfile -t _stale_chk < <(list_state_files "$target")
      _any_real_stale=0  # N194-STOPPED-BYPASS
      # Bypass scope: multi-focus only. A stopped focus must have an active sibling to fall through
      # to; a single-focus corpus with a failing verify-state has no such sibling and must always
      # surface as STALE. This also prevents BPSKIP-form priorities (strikethrough, em-dash,
      # qualifier) from driving count_investigable to 0 and being mistaken for a legitimate stop:
      # in a single-focus corpus the ONLY way d_inv=0 is trustworthy is with a clean verify-state,
      # which would have passed above and never reached this bypass path.
      if [ "${#_stale_chk[@]}" -lt 2 ]; then
        _stale_line
        exit 0
      fi
      for state in "${_stale_chk[@]}"; do
        # FOCUSES.md check FIRST (issue #641): a stopped/paused focus with malformed priority must be
        # skipped before the INVALID_PRIORITY guard fires, or its unparseable backlog bricks the corpus.
        # Extends N194-STOPPED-BYPASS to also cover stopped focuses whose priority column is unknown.
        # The INVALID_PRIORITY guard below is therefore only reached for ACTIVE focuses.  # N194-FOCUSES-SKIP  # N641-FOCUSES-BEFORE-INVALID-PRIORITY
        _sfoc_file="$(dirname "$state")/FOCUSES.md"
        _read_focuses_tok_into _sfoc_tok "$_sfoc_file" "$(basename "$state")"
        # shellcheck disable=SC2154 # _sfoc_tok is assigned indirectly by _read_focuses_tok_into via printf -v
        if [ "$_sfoc_tok" = "stopped" ] || [ "$_sfoc_tok" = "paused" ]; then
          continue
        fi
        # Unparseable backlog is a real failure for ACTIVE focuses (concealment hazard, BP-INVALID-PRIORITY-FAIL).
        if grep -q '^INVALID_PRIORITY' < <(backlog_rows 2>/dev/null); then
          _any_real_stale=1; break
        fi
        _d_inv="$(count_investigable)"
        if [ "${_d_inv}" != "0" ]; then
          # Active focus — check critical envelope consistency (mirrors verify-state CHECK B + CHECK D).
          if ! grep -q '<!-- research-state.v1 -->' "$state" 2>/dev/null; then
            _any_real_stale=1; break
          fi
          _e_inv="$(env_get investigable_open)"
          if [ "${_e_inv}" != "${_d_inv}" ]; then
            _any_real_stale=1; break
          fi
          # CHECK D mirror: declared full coverage (gc==kg, kg>0) while investigable gaps remain.
          _e_gc="$(env_get gaps_closed)"; _e_kg="$(env_get known_gaps)"
          if [ -n "${_e_gc}" ] && [ -n "${_e_kg}" ] \
             && grep -qE '^[0-9]+$' <<<"${_e_gc}${_e_kg}" \
             && [ "${_e_kg}" -gt 0 ] 2>/dev/null \
             && [ "${_e_gc}" = "${_e_kg}" ]; then
            _any_real_stale=1; break
          fi
        fi
        # d_inv=0 + parseable: genuinely stopped focus — its stale envelope is bypassed (#194).
      done
      if [ "${_any_real_stale}" = 1 ]; then
        _stale_line
        exit 0
      fi
      # All verify-state failures are from stopped focuses — fall through to aggregation.
    else
      _stale_line
      exit 0
    fi
  fi
  # RETRO-DUE (§18 cadence): after STALE passes, check for blocks_since_retro > 10.
  # Check the relevant state file(s): just $state for single-focus, all active files for multi-focus.
  # Emits RETRO-DUE and exits before NEXT/STOP so the cadence advisory reaches the caller.  # RD-BLOCKS-SINCE-RETRO-CHECK
  # kit issue #1837: --root and --focus both PICK one state file ($state, resolved above); --next then reports from
  # that file alone. The no-flag form (and --all, which excludes both flags) keeps the corpus-wide aggregate.
  _ns_scoped=0  # NEXT-SCOPE-DEFAULT
  [ -n "$focus_slug" ] && _ns_scoped=1  # NEXT-FOCUS-SCOPE
  [ "$root_flag" = 1 ] && _ns_scoped=1  # NEXT-ROOT-SCOPE
  _rd_threshold=10
  if [ "$_ns_scoped" = 1 ]; then
    # The RETRO-DUE loop below leaves the global $state on this file, which is what resolve_next reads afterwards.
    _rd_states=("$_ns_pick")  # NEXT-PICK-RD
  else
    mapfile -t _rd_states < <(list_state_files "$target")
  fi
