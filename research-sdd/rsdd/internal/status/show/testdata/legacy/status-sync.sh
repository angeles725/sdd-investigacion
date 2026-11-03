if [ "$mode" = "--sync-state" ]; then
  # Seed the research-state.v1 envelope in EVERY RESEARCH-STATE*.md of the corpus. §16 multi-focus corpora
  # keep ONE state file per focus, each with its OWN backlog. Seeding only the head-1 file (as this did before)
  # left sibling foci envelope-less, and verify-state.sh — which lints ALL of them (its line ~19) — then FAILs,
  # BRICKING the whole corpus under the --next STALE-gate. ALL envelope fields are derived PER STATE FILE:
  # investigable_open / blocked_open / coverage from each focus's own backlog, and covered_blocks from that
  # file's OWN directory — recomputed INSIDE the loop with the SAME strict discriminator + dirname scoping that
  # verify-state.sh:101 uses. A once-at-$corpus cb would disagree with verify-state for any focus file living in
  # a subdirectory (verify-state recomputes ondisk per dirname($state)), FAILing the envelope we just wrote.
  render_envelope() {   # reads the per-file globals: cb/gc/kg/io/req/bo/def/uf/_extra_env_lines
    printf '<!-- research-state.v1 -->\n'
    printf 'schema: research-state.v1\n'
    printf 'covered_blocks: %s\n' "$cb"
    printf 'gaps_closed: %s\n' "$gc"
    printf 'known_gaps: %s\n' "$kg"
    printf 'investigable_open: %s\n' "$io"
    printf 'requires_execution_open: %s\n' "$req"
    printf 'blocked_open: %s\n' "$bo"
    printf 'deferred_open: %s\n' "$def"
    [ "$_uf_omit" = 1 ] || printf 'undocumented_findings: %s\n' "$uf"   # UF-NO-INVENT: never seed a manually-maintained 0 into an existing fence
    [ -n "$_extra_env_lines" ] && printf '%s\n' "$_extra_env_lines"  # PREAMBLE-CARRY-FORWARD
    printf '<!-- /research-state.v1 -->'
  }
  # Reassigning the global `state` per iteration is deliberate: section/backlog_rows/blocked_body/env_get all
  # read $state at call time, so each focus derives from its OWN file (single source of truth, same helpers).
  # Scan $target (not $corpus) so split-layout corpora (focuses in sibling subdirectories) are fully seeded;
  # scanning only $corpus=dirname(first) left sibling focuses unseeded — the BLOCKER 2 / WARNING 4 root cause.
  mapfile -t _states < <(list_state_files "$target")
  # When --focus is given, restrict the sync to that single file only (avoids seeding siblings).
  if [ -n "$focus_slug" ] || [ "$root_flag" = 1 ]; then
    if [ "$root_flag" = 1 ]; then _focused="$state"  # ROOT-SYNC-SELECT: the root already resolved (and vetted) at startup
    else
      # rc 0/2 keep the pick (a tie keeps the C-locale-first file); rc 1 prints nothing -> the -f guard below
      # reports the absent message; rc >= 3 is a real resolver error, typed like the startup call sites.
      _focused="$(resolve_state_file "$target" --focus "$focus_slug")"; _sf_rc=$?  # SF-SYNC-FOCUS-PICK
      [ "$_sf_rc" -le 2 ] || { echo "research-sdd-status: state-file resolution failed (rc $_sf_rc)" >&2; exit 1; }
    fi
    if [ ! -f "$_focused" ]; then
      printf 'sync-state: no RESEARCH-STATE%s.md under %s\n' "${focus_slug:+-$focus_slug}" "$target" >&2; exit 1
    fi
    _states=("$_focused")
  fi
  # FIX 2: scope guard — refuse to silently rewrite all siblings when no --focus is given.
  # Multiple RESEARCH-STATE files in a corpus must be targeted one at a time so that per-focus
  # preamble fields are never clobbered by a corpus-wide sweep.
  if [ -z "$focus_slug" ] && [ "$root_flag" != 1 ] && [ "${#_states[@]}" -gt 1 ]; then
    printf 'sync-state: WARN: %d RESEARCH-STATE files found under %s — use --focus <slug> (or --root for the un-suffixed RESEARCH-STATE.md) to target one focus (refusing without explicit scope)\n' \
      "${#_states[@]}" "$target" >&2
    exit 1  # SYNC-SCOPE-GUARD
  fi
  # BO-DEGRADED-SYNC (#2017 W2): derive blocked_open for EVERY state file BEFORE the first write; one degraded
  # derivation refuses the whole sync (no envelope written at all), never a half-rewritten set of foci.
  declare -A _BO_PRE=()
  for state in "${_states[@]}"; do
    state="$(readlink -f "$state" 2>/dev/null || printf '%s' "$state")"
    _bo_v="$(derive_blocked_open)"; _bo_rc=$?
    if [ "$_bo_rc" -ne 0 ]; then
      printf 'research-sdd-status: blocked_open derivation degraded (blocked_open_count rc %s on %s) — NO envelope written\n' "$_bo_rc" "$state" >&2
      exit 1
    fi
    _BO_PRE["$state"]="$_bo_v"
  done
  for state in "${_states[@]}"; do
    # Write THROUGH a symlinked state file to its real path (else the mv below would replace the symlink
    # with a regular file, silently breaking a shared/canonical state). readlink -f also canonicalizes a
    # plain path harmlessly. The temp then lives in the target's OWN directory so mv is a same-filesystem
    # atomic rename (a bare mktemp lands in TMPDIR, and a cross-device mv is a non-atomic copy+unlink).
    state="$(readlink -f "$state" 2>/dev/null || printf '%s' "$state")"
    # BACKLOG PARSE CHECK — refuse to seed an envelope from an unparseable backlog. Unknown priority
    # values (not high/medium/low/deferred) emit an INVALID_PRIORITY sentinel to stdout; seeding from
    # a partial backlog would record a wrong investigable_open, disarming verify-state's gate.
    _brows_invalid="$(backlog_rows | grep '^INVALID_PRIORITY')"
    if [ -n "$_brows_invalid" ]; then  # BP-SYNC-INVALID-REFUSE
      printf 'sync-state: ERROR: %s: backlog NOT FULLY PARSEABLE — unknown priority value(s) found\n' \
        "$(basename "$state")" >&2
      printf '  (diagnostics above name the offending row(s); envelope NOT rewritten — fix the priority value(s) first)\n' >&2
      exit 1
    fi
    # block_scope: carry-forward through --sync-state round-trips so the declaration survives. env_get
    # handles indented+space forms (whitespace-split awk). Fallback probe uses the same whitespace-tolerant
    # /^[[:space:]]*key:/ convention as verify-state.sh (# BS-INDENTED-PROBE) and the UF probe below — catches indented and
    # no-space forms. Only legal values are carried; illegal values stay for verify-state to FAIL on.
    # _e_bs is read into render_envelope via the shared shell scope.
    _e_bs="$(env_get block_scope)"
    if [ -z "$_e_bs" ]; then
      _raw_bs="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^[[:space:]]*block_scope:/{v=$0; sub(/^[[:space:]]*block_scope:[[:space:]]*/,"",v); print v; exit}' "$state")"  # BS-SYNC-PROBE
      case "$_raw_bs" in per-focus|shared-global) _e_bs="$_raw_bs" ;; esac
    fi
    # Generalized preamble carry-forward: collect all non-owned lines from the existing
    # envelope, normalized (leading whitespace stripped, space ensured after colon).
    # The 9 owned keys below are recomputed fresh every run; every other line —
    # block_scope:, method:, or any unknown future field — passes through unchanged.
    # Empty on first-seed (fence absent): nothing to carry forward yet.
    _extra_env_lines=''
    if grep -q '<!-- research-state.v1 -->' "$state"; then
      _extra_env_lines="$(awk '
        /<!-- research-state.v1 -->/{b=1;next}
        /<!-- \/research-state.v1 -->/{b=0}
        b {
          line=$0; sub(/^[[:space:]]+/,"",line)
          colon=index(line,":")
          if (colon==0) next
          key=substr(line,1,colon-1)
          if (key=="schema"||key=="covered_blocks"||key=="gaps_closed"||key=="known_gaps"||
              key=="investigable_open"||key=="requires_execution_open"||key=="blocked_open"||
              key=="deferred_open"||key=="undocumented_findings") next
          val=substr(line,colon+1); sub(/^[[:space:]]+/,"",val); sub(/[[:space:]]+$/,"",val)
          printf "%s: %s\n",key,val
        }' "$state")"  # PREAMBLE-CARRY-FORWARD
    fi
    # covered_blocks from THIS file's own directory — identical discriminator + dirname scoping to
    # verify-state.sh (single definition rule, prevents dual-authority drift on this count).
    # B5 FIX: focus-prefix filter for multi-focus corpora; shared-global path mirrors BS-SHARED-GLOBAL-ONDISK.
    _sfpfx="$(derive_focus_prefix "$state")"
    _sfrange=""   # kit #906: FOCUSES.md block RANGE cell (a prefix wins); malformed/multi/family/missing diagnostics from the shared report
    if [ -z "$_sfpfx" ]; then _sfrange="$(derive_focus_range "$state")"; focus_range_report "$state" 'sync-state: %s: RESEARCH-STATE.md: %s\n' >&2; case "$_sfrange" in '!'*) _sfrange="" ;; esac; fi  # RANGE-REPORT
    if [ "$_e_bs" = "shared-global" ]; then
      # block_scope: shared-global → use attributed B<n> count (mirrors verify-state.sh CHECK A via
      # count_attributed_sg / _derive_attributed_sg respectively, so the two scripts always agree).
      # When no attributed ids are found: seed covered_blocks=0 (anti-silent-zero §7 — the three
      # states are: attributed count known → use it; 0 attributed → warn + seed 0; not shared-global
      # → per-focus or corpus-wide).  The old corpus-wide fallback was WRONG: it silently produced a
      # confident count that was not the attributed count METHODOLOGY §16 requires. verify-state.sh
      # correctly reports INFO unverifiable for the 0 case; seeder and verifier now agree.
      _attr_sg="$(count_attributed_sg)"  # SG-ATTR-SYNC
      if [ "${_attr_sg:-0}" -gt 0 ] 2>/dev/null; then
        cb="$_attr_sg"
      else
        cb=0  # SG-ZERO-UNVERIFIABLE
        printf 'sync-state: WARN: %s: shared-global focus has no attributed block ids (no B<n> in ## Covered blocks or ## Iteration history) — seeding covered_blocks=0; add B<n> ids to make this verifiable.\n' "$(basename "$state")" >&2  # SG-ZERO-WARN
      fi
    elif [ -n "$_sfpfx" ]; then
      cb="$(find "$(dirname "$state")" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
        | block_file_filter "${_sfpfx}" | wc -l | tr -d ' ')"
    elif [ -n "$_sfrange" ]; then
      cb="$(focus_range_block_count "$(dirname "$state")" "$_sfrange" "$state")"  # RANGE-SYNC-COUNT
    else
      cb="$(find "$(dirname "$state")" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
        | block_file_filter | wc -l | tr -d ' ')"
    fi
    # kit #906: the un-suffixed root of a MULTI-focus corpus with no block prefix in FOCUSES.md would get the
    # corpus-wide block count — not its own scope. Flag it; the reconciliation below KEEPS a declared value
    # unless covered_blocks is named in --only, and says so.
    _cw=0
    if [ "$(basename "$state")" = "RESEARCH-STATE.md" ] && [ -z "$_sfpfx" ] && [ -z "$_sfrange" ] && [ "$_e_bs" != "shared-global" ] \
       && [ "$(list_state_files "$target" | wc -l | tr -d ' ')" -gt 1 ]; then _cw=1; fi  # ROOT-CORPUS-WIDE
    io="$(count_investigable)"
    bo="${_BO_PRE[$state]}"   # derived (and rc-checked) in the pre-pass above: same disk-derived helper the status display reuses
    def="$(count_deferred)"
    _ipb="$(backlog_rows 2>/dev/null | inplace_blocked_count "$(blocked_body)")"   # in-place blocked rows (#1915; shared lib/focus-prefix.sh helper, mirrored by verify-state CHECK H): open, in no other bucket — never closed
    # requires_execution_open: compute BEFORE cov/kg so KG-BACKLOG-GC can use dreq.
    # PREFERS the backlog-derived count (rows whose Status carries the `requires-execution` marker →
    # disk-anchored, in lockstep with verify-state.sh's CHECK E) and only falls back to the prose
    # stop-control number / previous envelope when NO row is marked — a marked backlog is
    # authoritative, a prose-only corpus (logosoft) keeps its declared counter.
    dreq="$(count_requires_execution)"
    if [ "$dreq" -gt 0 ]; then
      req="$dreq"
    else
      req="$(pick "$(req_prose)" "$(env_get requires_execution_open)")"
    fi
    # declared-only figures from THIS file's prose (coverage metric X/Y), carrying the previous envelope
    # value when a figure is absent/unparseable (never invent — see pick()).
    cov="$(cov_ratio)"
    # known_gaps: take the larger of the backlog-derived total and the coverage metric Y (issue #568).
    # Backlog-derived: captures newly-added gaps even when the coverage metric prose is stale.
    # Coverage metric Y: preserved when closed gaps are tracked only in the prose and not as backlog rows.
    _dkg="$(count_all_known_gaps)"
    _dkg_total=$(( ${_dkg:-0} + ${def:-0} ))
    _cm_kg="${cov##*/}"
    # KG-LOWER-BOUND (#1307): rows excluded for an undeclared tier make the derived total a LOWER bound. If the
    # envelope already declares a LARGER known_gaps, keep the declared pair instead of clobbering it with the undercount.
    _kg_lb=0; _unc="$(count_uncounted_rows)"; _decl_kg="$(env_get known_gaps)"; _decl_gc="$(env_get gaps_closed)"
    _plain="$(backlog_rows 2>/dev/null | grep -v '^INVALID_PRIORITY' | grep -c . | tr -d ' ')"  # rows the pre-#1307 derivation saw
    [ "${_unc:-0}" -gt 0 ] && printf 'sync-state: WARN: %s: %d backlog row(s) are NOT counted (undeclared tier / malformed row / table without a Priority header) — known_gaps and gaps_closed are LOWER bounds, verify against the prose.\n' \
      "$(basename "$state")" "${_unc}" >&2
    if grep -qE '^[0-9]+$' <<<"${_decl_kg}" && [ "${_decl_kg}" -ge "${_dkg_total}" ] 2>/dev/null; then
      if [ "${_unc:-0}" -gt 0 ]; then
        # KG-LB-UPPER (#1350): the keep is LOUD, never destructive. A declared total above derived + uncounted cannot be explained by the
        # uncounted rows alone, but it is NOT provably stale: it may include closed gaps tracked outside the backlog table (prose, another
        # heading). So it is still kept (propose-never-apply) and the unexplained excess is WARNed for a hand check.
        _kg_lb=1; printf 'sync-state: WARN: %s: keeping the declared known_gaps=%s (derived %d is below it); gaps_closed = max(declared, derived).\n' "$(basename "$state")" "${_decl_kg}" "${_dkg_total}" >&2
        [ "${_decl_kg}" -gt "$(( ${_dkg_total} + ${_unc} ))" ] && printf 'sync-state: WARN: %s: declared known_gaps=%s exceeds what the parser can count (derived %d + %d uncounted) — NOT rewritten; it may include gaps tracked outside the backlog table (prose, other headings) — verify by hand.\n' \
          "$(basename "$state")" "${_decl_kg}" "${_dkg_total}" "${_unc}" >&2
      # B1-NO-UPPER (#1350): this branch keeps WITHOUT an upper bound on purpose: with only closed-class rows and no Coverage metric there is no
      # counted evidence to bound the declared total against, so any declared value is kept (and WARNed below).
      elif [ -z "${_cm_kg}" ] && [ "$(( ${_plain:-0} + ${def:-0} ))" -eq 0 ]; then  # B1: only closed-class rows, no prose metric: nothing proves the declared total shrank
        _kg_lb=1
        printf 'sync-state: WARN: %s: the backlog has only closed-class rows and there is no Coverage metric N/M — derived known_gaps=%d is not evidence the declared total shrank; keeping the declared known_gaps/gaps_closed.\n' \
          "$(basename "$state")" "${_dkg_total}" >&2
      fi
    fi
    if [ "$_kg_lb" = 1 ]; then  # KG-LB-KEEP: assign the DECLARED total explicitly (a stale prose Y must not win); gaps_closed = max(declared, derived) so a real closure is not hidden
      kg="${_decl_kg}"
      warn_inplace_blocked "$(basename "$state")" "${_ipb:-0}"  # INPLACE-BLOCKED-WARN
      _gc_d=$(( ${_dkg_total} - ${io:-0} - ${req:-0} - ${bo:-0} - ${def:-0} - ${_ipb:-0} )); [ "$_gc_d" -lt 0 ] && _gc_d=0
      gc="${_decl_gc}"; grep -qE '^[0-9]+$' <<<"$gc" || gc=0
      [ "$_gc_d" -gt "$gc" ] && gc="$_gc_d"
      [ "$gc" -gt "$kg" ] && gc="$kg"
    fi
    if [ "$_kg_lb" = 0 ] \
       && grep -qE '^[0-9]+$' <<<"${_dkg_total}" \
       && grep -qE '^[0-9]+$' <<<"${_cm_kg:-0}" \
       && [ "${_dkg_total}" -gt "${_cm_kg:-0}" ] 2>/dev/null; then  # KG-BACKLOG-GATE
      kg="${_dkg_total}"  # KG-BACKLOG-EXCEEDS
      # KG-BACKLOG-GC: when kg comes from backlog, gc = closed rows = kg − (io + req + bo + def + in-place blocked).
      # Coverage prose numerator is stale in this path; compute gc from the backlog rows directly.
      _gc_backlog=$(( _dkg_total - ${io:-0} - ${req:-0} - ${bo:-0} - ${def:-0} - ${_ipb:-0} ))  # INPLACE-GC-SUBTRACT
      warn_inplace_blocked "$(basename "$state")" "${_ipb:-0}"  # INPLACE-BLOCKED-WARN
      gc="${_gc_backlog}"  # KG-BACKLOG-GC
      if [ "$gc" -lt 0 ]; then  # GC-CLAMP (kit #983): open buckets can overlap (a requires-execution row also listed blocked)
        # Never write an invented 0 over a DECLARED value: keep the declared gaps_closed (as pick() does); 0 only when none was declared.
        only_has gaps_closed && printf 'sync-state: WARN: %s: derived gaps_closed=%d is negative (known_gaps %d < open buckets io+req+bo+def+in-place-blocked = %d; a row is probably counted in two buckets) — clamp: NOT written, keeping the declared value (0 when none); reconcile the backlog by hand.\n' \
          "$(basename "$state")" "$gc" "${_dkg_total}" "$(( ${io:-0} + ${req:-0} + ${bo:-0} + ${def:-0} + ${_ipb:-0} ))" >&2
        gc="$(pick "" "$(env_get gaps_closed)")"  # GC-CLAMP-KEEP
      fi
      printf 'WARN: Coverage prose denominator is stale (coverage metric %s/%s, backlog has %d known gaps) — update Coverage metric to %d/%d\n' \
        "${cov%%/*}" "${_cm_kg:-?}" "${_dkg_total}" "${gc}" "${kg}" >&2
    elif [ "$_kg_lb" = 1 ]; then
      :  # KG-LB-KEEP above already assigned the declared kg and max(declared, derived) gc
    else
      kg="$(pick "${_cm_kg}" "$(env_get known_gaps)")"
      gc="$(pick "${cov%%/*}" "$(env_get gaps_closed)")"
    fi
    # DECLARED-KEEP (#1637): gaps_closed / known_gaps are DECLARED-only (read from prose, NOT disk-validated —
    # RESEARCH-STATE.template.md). A declared integer ABOVE the derived value is kept and the advisory names both
    # values: the derivation cannot tell a hand-truthful +1 from a stale over-count, so the operator must verify.
    # If the kept pair would leave gaps_closed > known_gaps, neither declared value is kept (DECLARED-PAIR-CHECK).
    # A declared integer at or below the derived value is NOT kept (the derivation is evidence of an undercount;
    # the existing CHANGED line reports the rewrite). Absent or non-integer is not 0: it is seeded from the
    # derivation. --only <name> is the explicit opt-in to write the derived value, so it bypasses the keep.
    if [ "$only_set" = 0 ]; then
      _dk_gc="$gc"; _dk_kg="$kg"; _dk_adv=""
      for _dk_f in gaps_closed known_gaps; do
        _dk_decl="$(env_get "$_dk_f")"
        grep -qE '^[0-9]+$' <<<"${_dk_decl}" || continue
        case "$_dk_f" in gaps_closed) _dk_der="$gc" ;; known_gaps) _dk_der="$kg" ;; esac
        [ "${_dk_decl}" -gt "${_dk_der}" ] || continue  # declared <= derived: the derivation is evidence of an undercount, not a falsification
        case "$_dk_f" in gaps_closed) _dk_gc="${_dk_decl}" ;; known_gaps) _dk_kg="${_dk_decl}" ;; esac
        _dk_adv="${_dk_adv}sync-state: DECLARED ${_dk_f}=${_dk_decl} (derived ${_dk_der}) — kept; verify the declared value or correct it by hand"$'\n'
      done
      # Pair invariant: the per-field decisions are independent, so a kept gaps_closed next to a derived known_gaps can
      # leave gaps_closed > known_gaps. Then NEITHER declared value is kept: the derived pair is written. (The sum
      # identity gc+open buckets = known_gaps stays verify-state CHECK H's WARN; only gc <= kg is enforced here.)
      if [ "$_dk_gc" -gt "$_dk_kg" ] && { [ "$_dk_gc" != "$gc" ] || [ "$_dk_kg" != "$kg" ]; }; then  # DECLARED-PAIR-CHECK
        printf 'sync-state: DECLARED gaps_closed=%s known_gaps=%s inconsistent with derived %s/%s — derived pair written; correct the declaration by hand\n' \
          "$(env_get gaps_closed)" "$(env_get known_gaps)" "$gc" "$kg"
      else
        [ -n "$_dk_adv" ] && printf '%s' "$_dk_adv"  # DECLARED-KEEP-ADVISORY
        gc="$_dk_gc"; kg="$_dk_kg"  # DECLARED-KEEP
      fi
    fi
    # undocumented_findings: distinguish the three cases that pick("","...") collapses into one silent 0.
    # ABSENT       → FIRST seed (no fence): seed 0 (METHODOLOGY §7 seeding contract). Existing fence: the field is
    #                left absent (UF-NO-INVENT, reconciliation block below) — never an invented 0.
    # VALID        → carry the integer forward unchanged.
    # UNPARSEABLE  → warn loudly and carry the raw value forward; NOT replaced with 0 because that
    #                would erase real debt silently (the exact silent-loss channel BLOCKER 1B closes).
    #                verify-state CHECK G FAILs on the carried non-integer, so --next returns STALE.
    #
    # BLIND SPOT: env_get uses $1==key":" (whitespace field split).  A no-space typo like
    # `undocumented_findings:7` makes $1=="undocumented_findings:7" which never matches, so env_get
    # returns "" — identical to the ABSENT case — and the ABSENT branch would silently seed 0.
    # FIX: if env_get returns empty, apply the SAME whitespace-tolerant probe as verify-state.sh's
    # _uf_present (/^[[:space:]]*key:/ convention) to detect absent vs present-but-unreadable-by-env_get,
    # including indented forms and no-space forms (e.g. `  undocumented_findings:7`).
    _raw_uf="$(env_get undocumented_findings)"
    if [ -z "$_raw_uf" ]; then
      # Probe by KEY regex: whitespace-tolerant, matches indented and no-space forms alike.
      _raw_uf="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^[[:space:]]*undocumented_findings:/{val=$0; sub(/^[[:space:]]*undocumented_findings:[[:space:]]*/,"",val); print val; exit}' "$state")"  # UF-SYNC-PROBE
      # If still empty the line is genuinely absent → the case below takes the absent branch (seed 0).
    fi
    case "$_raw_uf" in
      '')           uf=0 ;;
      *[!0-9]*)
        printf 'sync-state: WARN: %s: undocumented_findings=%s is not a non-negative integer; value NOT replaced with 0 — fix manually and re-run --sync-state.\n' \
          "$(basename "$state")" "$_raw_uf" >&2
        uf="$_raw_uf" ;;
      *)            uf="$_raw_uf" ;;
    esac
    # --- declared-vs-derived reconciliation (kit #911) --------------------------------------------
    # Only meaningful when a fence already exists (a first seed declares nothing to compare/preserve).
    # --only keeps every NON-named counter at its DECLARED value (an absent one cannot be preserved, so it
    # is derived); every counter whose final value differs from the declared one is REPORTED, never silent.
    _uf_omit=0; _cw_kept=""
    if grep -q '<!-- research-state.v1 -->' "$state"; then
      _changed_lines=''
      for _cf in $_OWNED_COUNTERS; do
        case "$_cf" in
          covered_blocks) _nv="$cb" ;; gaps_closed) _nv="$gc" ;; known_gaps) _nv="$kg" ;;
          investigable_open) _nv="$io" ;; requires_execution_open) _nv="$req" ;; blocked_open) _nv="$bo" ;;
          deferred_open) _nv="$def" ;; undocumented_findings) _nv="$uf" ;;
        esac
        if _ov="$(env_raw "$_cf")"; then _have=1; else _have=0; fi
        if [ "$_cf" = undocumented_findings ] && [ "$_have" = 0 ]; then _uf_omit=1; continue; fi  # UF-NO-INVENT
        if [ "$only_set" = 1 ] && [ "$_have" = 1 ]; then
          case ",$only_list," in *",$_cf,"*) ;; *) _nv="$_ov" ;; esac   # ONLY-KEEP-DECLARED not named → keep declared value
        fi
        if [ "$_cf" = covered_blocks ] && [ "$_cw" = 1 ] && [ "$_have" = 1 ] && [ "$only_set" = 0 ]; then  # CW-KEEP-DECLARED
          _cw_kept="$_nv"; _nv="$_ov"   # corpus-wide count is not this focus's number: keep what is declared
        fi
        if [ "$_have" = 0 ]; then _ov="(absent)"; fi
        [ "$_ov" = "$_nv" ] || _changed_lines="${_changed_lines}sync-state: CHANGED $(basename "$state") ${_cf}: ${_ov} -> ${_nv}"$'\n'
        case "$_cf" in
          covered_blocks) cb="$_nv" ;; gaps_closed) gc="$_nv" ;; known_gaps) kg="$_nv" ;;
          investigable_open) io="$_nv" ;; requires_execution_open) req="$_nv" ;; blocked_open) bo="$_nv" ;;
          deferred_open) def="$_nv" ;; undocumented_findings) uf="$_nv" ;;
        esac
      done
      [ -n "$_changed_lines" ] && printf '%s' "$_changed_lines"
    fi
    if [ "$_cw" = 1 ] && only_has covered_blocks; then  # ROOT-CORPUS-WIDE-WARN
      if [ -n "$_cw_kept" ]; then
        printf 'sync-state: WARN: %s: covered_blocks would be %s, the CORPUS-WIDE block count (no block prefix or B<a>–B<b> range for the root focus in FOCUSES.md), not this focus'"'"'s number — KEPT the declared %s; name covered_blocks in --only to write it.\n' \
          "$(basename "$state")" "$_cw_kept" "$cb" >&2
      else
        printf 'sync-state: WARN: %s: covered_blocks=%s written is the CORPUS-WIDE block count (no block prefix or B<a>–B<b> range for the root focus in FOCUSES.md) — not scoped to this focus; verify it.\n' \
          "$(basename "$state")" "$cb" >&2
      fi
    fi
    repl="$(render_envelope)"
    tmp="$(mktemp "$(dirname "$state")/.rsdd-sync.XXXXXX")"
    if grep -q '<!-- research-state.v1 -->' "$state"; then
      # fence EXISTS → replace ONLY between the markers (idempotent; surrounding prose untouched).
      awk -v repl="$repl" '
        $0 ~ /<!-- research-state.v1 -->/ { print repl; skip=1; next }
        skip && $0 ~ /<!-- \/research-state.v1 -->/ { skip=0; next }
        skip { next }
        { print }' "$state" > "$tmp" || { rm -f "$tmp"; printf 'sync-state: ERROR: %s: rewriting the envelope failed (awk exit) — file NOT modified.\n' "$state" >&2; exit 1; }  # AWK-CHECK
    else
      # fence ABSENT → insert right after the top intro blockquote (the first contiguous run of `>` lines);
      # if there is no blockquote, append at EOF. Either way a SECOND run finds the fence → byte-identical.
      awk -v repl="$repl" '
        { line=$0
          if (!done) {
            if (line ~ /^>/) inbq=1
            else if (inbq) { print repl; print ""; done=1 }
          }
          print line }
        END { if (!done) { print ""; print repl } }' "$state" > "$tmp" || { rm -f "$tmp"; printf 'sync-state: ERROR: %s: rewriting the envelope failed (awk exit) — file NOT modified.\n' "$state" >&2; exit 1; }  # AWK-CHECK
    fi
    mv "$tmp" "$state"
    echo "sync-state: wrote $state"
    echo "sync-state: $(basename "$state") → covered_blocks=$cb gaps_closed=$gc known_gaps=$kg investigable_open=$io requires_execution_open=$req blocked_open=$bo deferred_open=$def undocumented_findings=$([ "$_uf_omit" = 1 ] && echo - || echo "$uf")"
  done
  exit 0
fi
