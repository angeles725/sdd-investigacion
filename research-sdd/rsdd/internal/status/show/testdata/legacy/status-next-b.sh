  for state in "${_rd_states[@]}"; do
    _rd_foc_file="$(dirname "$state")/FOCUSES.md"
    _read_focuses_tok_into _rd_foc_tok "$_rd_foc_file" "$(basename "$state")"
    # shellcheck disable=SC2154 # _rd_foc_tok is assigned indirectly by _read_focuses_tok_into via printf -v
    if [ "$_rd_foc_tok" = "stopped" ] || [ "$_rd_foc_tok" = "paused" ]; then continue; fi
    _rd_bsr="$(env_get blocks_since_retro)"
    _rd_note=""
    # kit issue #1640: only a counter that would FIRE is cross-checked against the retro's covers_through, and
    # the derived value replaces it only when LOWER: coverage can only suppress or shorten a RETRO-DUE, never create
    # one, and a counter at or below the threshold is never touched.
    if grep -qE '^[0-9]+$' <<<"$_rd_bsr" && [ "$_rd_bsr" -gt "$_rd_threshold" ]; then
      _rd_covers_derive "$state" "$_rd_bsr" "$target"  # RD-COVERS-THROUGH
      _rd_bsr="$_rd_eff"
    fi
    if grep -qE '^[0-9]+$' <<<"$_rd_bsr" && [ "$_rd_bsr" -gt "$_rd_threshold" ]; then  # RD-THRESHOLD-CHECK
      echo "RETRO-DUE | ${_rd_bsr} blocks since last retro (§18 threshold: ${_rd_threshold})${_rd_note}"
      exit 0
    fi
  done
  # DEGRADED gate (kit #2024): after STALE and RETRO-DUE, before any NEXT/STOP verdict. is_blocked() only logs a failed
  # blocked-section read and then answers "not blocked", so a verdict derived from an unreadable file could hand out a
  # blocked gap (NEXT) or an inflated paused-focus count (STOP). Refuse instead, for every file the verdict reads.
  if [ "$_ns_scoped" = 1 ]; then _nxt_dg_files=("$_ns_pick"); else mapfile -t _nxt_dg_files < <(list_state_files "$target"); fi
  _nxt_dg_names="$(_blocked_degraded_files ${_nxt_dg_files[@]+"${_nxt_dg_files[@]}"})"; _nxt_dg_rc=$?
  if [ "$_nxt_dg_rc" -ne 0 ]; then  # NEXT-DEGRADED-GATE
    printf 'research-sdd-status: --next refused: blocked-rows derivation degraded for %s — exit 3 (see the blocked-rows: stderr line from lib/blocked-rows.sh)\n' "$_nxt_dg_names" >&2
    echo "DEGRADED | blocked-rows derivation unreadable for ${_nxt_dg_names} — --next would answer from an empty blocked set; fix the failure named on stderr, then re-run"
    exit 3
  fi
  if [ "$_ns_scoped" = 0 ]; then
    # Multi-focus guard (chihuahua/px-chart-classic regression + BLOCKER 2 split-layout): iterate every
    # state file under $target (not just $corpus=dirname(first)), so focuses in sibling subdirectories are
    # not missed. Return NEXT from the first active focus; only emit STOP when ALL focuses are stopped.
    # Scanning $corpus alone was the C3 false-STOP root cause one directory level up: alpha (stopped)
    # sorted first → corpus=alpha → aggregation never reached beta (active) → false STOP.
    mapfile -t _next_states < <(list_state_files "$target")
    _nxt_skip_gaps=0
    : # IDG-PREC-SENTINEL (teeth-IDG-precedence: replace with 'issues_due_gate; exit 0' to verify gate fires AFTER resolve_next)
    for state in "${_next_states[@]}"; do
      _nxt_foc_slug="$(basename "$state" .md)"; _nxt_foc_slug="${_nxt_foc_slug#RESEARCH-STATE-}"
      _nxt_foc_file="$(dirname "$state")/FOCUSES.md"
      _read_focuses_tok_into _nxt_foc_tok "$_nxt_foc_file" "$(basename "$state")"  # N194-FOCUSES-SKIP
      # shellcheck disable=SC2154 # _nxt_foc_tok is assigned indirectly by _read_focuses_tok_into via printf -v
      if [ "$_nxt_foc_tok" = "stopped" ] || [ "$_nxt_foc_tok" = "paused" ]; then
        printf 'INFO: skipped %s (focus-status: %s in FOCUSES.md)\n' "$_nxt_foc_slug" "$_nxt_foc_tok" >&2
        [ -r "$state" ] || printf 'WARN: cannot read state file %s\n' "$state" >&2
        _nxt_skip_d_inv="$(count_investigable 2>/dev/null)" || { echo "DEGRADED | blocked-rows read failed while counting the paused/stopped focus $(_rel_state "$state") — the no-active-focus count would be inflated; fix the failure named on stderr, then re-run"; exit 3; }  # COUNT-DEGRADED-EXIT
        [ "${_nxt_skip_d_inv:-0}" != "0" ] && _nxt_skip_gaps=$(( _nxt_skip_gaps + 1 ))
        continue
      fi
      _r="$(resolve_next_q)"
      case "$_r" in NEXT\ *) echo "$_r"; exit 0;; DEGRADED\ *) echo "$_r"; exit 3;; esac  # RESOLVE-DEGRADED-EXIT
    done
    # kit #1959 W1: the qualifier counts EVERY state file, skipped (stopped/paused) ones included — a paused focus whose
    # only open rows are unread must not leave a bare terminal STOP.
    _bu_compute ${_next_states[@]+"${_next_states[@]}"}  # BU-WALKED
    if [ "$_nxt_skip_gaps" -gt 0 ]; then
      echo "STOP | no active focus (${_nxt_skip_gaps} declared stopped/paused in FOCUSES.md with open gaps)${_BU_SUFFIX}"
    else
      issues_due_gate
    fi
  else
    _rn_out="$(resolve_next_q)"
    case "$_rn_out" in
      "STOP | read-only-investigable exhausted (0)")
        _bu_compute "$_ns_pick"  # BU-SCOPE
        issues_due_gate ;;  # IDG-FOCUS-GATE
      DEGRADED\ *) printf '%s\n' "$_rn_out"; exit 3 ;;
      *) printf '%s\n' "$_rn_out" ;;
    esac
  fi
  exit 0
fi
