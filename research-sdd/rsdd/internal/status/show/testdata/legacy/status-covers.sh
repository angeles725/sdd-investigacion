  # _rd_covers_derive <state> <declared-counter> <target> — kit issue #1640 (design accepted on the issue).
  # The retro template carries a machine-readable column-0 `covers_through: B<n>` line, optionally scoped with
  # ` focus=<slug>` (the RESEARCH-STATE-<slug>.md suffix; the un-suffixed root RESEARCH-STATE.md is `focus=root`).
  # blocks_since_retro is derived as max(0, newest block id on disk − highest IN-RANGE covers_through over the
  # target's retros) and replaces the declared counter ONLY when LOWER. FAIL-CLOSED PRINCIPLE: coverage may only ever
  # LOWER the counter when the evidence unambiguously belongs to THIS focus; anything ambiguous keeps the declared
  # counter (RETRO-DUE keeps firing). Hence: an UNSCOPED line counts only when the corpus's single state file is the
  # root RESEARCH-STATE.md (several state files, or a lone slugged one, ignore it with a typed note), a state-file slug that is not unique is refused, and a value above the newest block on disk is
  # excluded from the maximum (typed WARN per retro) — it is never clamped to 0. Sets _rd_eff (effective counter)
  # and _rd_note (RETRO-DUE suffix). Every state in which the derivation cannot run is NAMED on stderr (§7): no
  # retros / no field / malformed value / no block files / range-scoped focus / missing helper / incomplete retro
  # enumeration — each keeps the declared counter. Prose such as "coverage through B140" is deliberately NOT parsed
  # (doctrine first). Called only for a counter that would fire, so legacy corpora stay quiet.
  # The grammar below is byte-identical to the one in stage-retro-issues.sh (parity test in its suite).
  # CV-GRAMMAR-BEGIN
  _CV_AWK='
/^(```|~~~)/ { m = substr($0, 1, 1); if (fence == "") fence = m; else if (fence == m) fence = ""; next }
fence != "" { next }
/^covers_through:/ {
  line = $0; sub(/\r$/, "", line)
  if (line ~ /^covers_through:[ \t]+B[0-9]+([ \t]+focus=[A-Za-z0-9._-]+)?[ \t]*$/) {
    v = line; sub(/^covers_through:[ \t]+B/, "", v); n = v; sub(/[^0-9].*$/, "", n)
    sl = "-"; if (v ~ /focus=/) { sl = v; sub(/^.*focus=/, "", sl); sub(/[ \t]*$/, "", sl) }
    if (length(n) > 9) print "M"; else print "V " n " " sl
  } else print "M"
}'
  # CV-GRAMMAR-END
  _rd_covers_derive() {  # RD-COVERS-DERIVE
    local _st="$1" _decl="$2" _tg="$3" _base _slug _myslug _pfx _rng _dir _f _b _id _newest=-1 _rs _line _v _sl
    local _maxcov=-1 _nret=0 _nbad=0 _badlist="" _nover=0 _nunsc=0 _rlist _rf _der=0 _fo _frc _multi=0 _unsc_ok=0 _sfiles _sf _sfb _dups=0
    _rd_eff="$_decl"; _rd_note=""
    _base="$(basename "$_st")"; _slug=""
    case "$_base" in RESEARCH-STATE-*.md) _slug="${_base#RESEARCH-STATE-}"; _slug="${_slug%.md}";; esac
    _myslug="${_slug:-root}"
    _dir="$(dirname "$_st")"
    # more than one state file in the target = a multi-focus corpus: only a `focus=<own slug>` line is this focus's evidence
    _sfiles="$(list_state_files "$_tg")"
    if [ "$(grep -c . <<<"$_sfiles")" -gt 1 ]; then  # RD-MULTI-FOCUS
      _multi=1
      while IFS= read -r _sf; do
        _sfb="$(basename "$_sf")"; _sfb="${_sfb#RESEARCH-STATE}"; _sfb="${_sfb#-}"; _sfb="${_sfb%.md}"
        [ "${_sfb:-root}" = "$_myslug" ] && _dups=$((_dups+1))
      done <<<"$_sfiles"
      if [ "$_dups" -gt 1 ]; then
        printf 'status: WARN: covers_through not applied: focus slug [%s] is not unique among the corpus state files (split layout) — using declared blocks_since_retro: %s\n' "$_myslug" "$_decl" >&2
        return 0
      fi
    fi
    # an UNSCOPED line is this focus's evidence only when the corpus has exactly one state file AND it is the root
    # RESEARCH-STATE.md (a lone slugged file left after a corpus shrank still needs its explicit focus=<slug>)
    [ "$_multi" = 0 ] && [ -z "$_slug" ] && _unsc_ok=1
    _pfx="$(derive_focus_prefix "$_st")"
    if [ -z "$_pfx" ]; then
      _rng="$(derive_focus_range "$_st" 2>/dev/null)"
      case "$_rng" in ''|'!'*) ;; *)
        printf 'status: WARN: covers_through not applied: range-scoped focus %s — using declared blocks_since_retro: %s\n' "$_base" "$_decl" >&2
        return 0;; esac
    fi
    _rs="$here/lib/retro-status.sh"
    if [ -f "$_rs" ]; then
      # shellcheck source=lib/retro-status.sh
      . "$_rs"
    fi
    if ! declare -F retro_is_excluded >/dev/null 2>&1; then
      printf 'status: WARN: covers_through not applied: helper lib/retro-status.sh unavailable — using declared blocks_since_retro: %s\n' "$_decl" >&2
      return 0
    fi
    # newest block id in this focus's scope (same file predicate as the on-disk block count)
    while IFS= read -r _f; do
      _b="$(basename "$_f")"
      if [ -n "$_pfx" ]; then  # RD-NEWEST-PREFIX
        [[ "$_b" =~ ^${_pfx}(block|bloque)([0-9]+)(-[[:alnum:]_-]+)?\.md$ ]] || continue
      else
        [[ "$_b" =~ ^.+-(block|bloque)([0-9]+)(-[[:alnum:]_-]+)?\.md$ ]] || continue
      fi
      _id="${BASH_REMATCH[2]}"
      [ "${#_id}" -le 9 ] || continue
      [ "$((10#$_id))" -gt "$_newest" ] && _newest=$((10#$_id))
    done < <(find "$_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | block_file_filter "${_pfx}")
    if [ "$_newest" -lt 0 ]; then
      printf 'status: WARN: covers_through not applied: no block files found for %s — using declared blocks_since_retro: %s\n' "$_base" "$_decl" >&2
      return 0
    fi
    # retros: the same enumeration predicate as the ISSUES-DUE gate / sweep-retros.sh. find's own exit status is
    # captured (IDG-FIND-EXIT-UNVERIFIED pattern): a partial listing is never read as the complete retro set.
    _fo="$(find "$_tg" -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*' -not -iname '*index*.md' -type f 2>/dev/null)"; _frc=$?  # RD-FIND-EXIT
    if [ "$_frc" -ne 0 ]; then
      printf 'status: WARN: covers_through not applied: retro enumeration incomplete (find exit %s) — using declared blocks_since_retro: %s\n' "$_frc" "$_decl" >&2
      return 0
    fi
    _rlist="$(LC_ALL=C sort <<<"$_fo")" || {
      printf 'status: WARN: covers_through not applied: retro enumeration sort failed — using declared blocks_since_retro: %s\n' "$_decl" >&2
      return 0; }
    while IFS= read -r _rf; do
      [ -n "$_rf" ] || continue
      retro_is_excluded "$_rf" && continue  # RD-EXCLUDED-RETRO
      _nret=$((_nret+1))
      while IFS= read -r _line; do
        case "$_line" in
          'V '*) _v="${_line#V }"; _sl="${_v#* }"; _v="${_v%% *}"
                 if [ "$_sl" = "-" ]; then
                   # unscoped: only the corpus's single root state file owns it
                   if [ "$_unsc_ok" != 1 ]; then _nunsc=$((_nunsc+1)); continue; fi  # RD-UNSCOPED-IGNORED
                 elif [ "$_sl" != "$_myslug" ]; then continue; fi
                 if [ "$((10#$_v))" -gt "$_newest" ]; then  # RD-OVER-RANGE
                   _nover=$((_nover+1))
                   printf 'status: WARN: covers_through B%s in %s exceeds newest block B%s on disk — value excluded (never clamped to 0)\n' "$((10#$_v))" "$(basename "$_rf")" "$_newest" >&2
                 elif [ "$((10#$_v))" -gt "$_maxcov" ]; then
                   _maxcov=$((10#$_v))
                 fi ;;
          'M') _nbad=$((_nbad+1)); _badlist="$_badlist $(basename "$_rf")" ;;
        esac
      done < <(awk "$_CV_AWK" "$_rf")
    done <<< "$_rlist"
    [ "$_nbad" -gt 0 ] && printf 'status: WARN: covers_through: malformed in%s (want `covers_through: B<n>` with a number) — malformed lines ignored\n' "$_badlist" >&2
    [ "$_nunsc" -gt 0 ] && printf 'status: WARN: covers_through: %s unscoped line(s) ignored — only a lone root RESEARCH-STATE.md owns unscoped evidence; write `covers_through: B<n> focus=%s` (root focus: focus=root)\n' "$_nunsc" "$_myslug" >&2
    if [ "$_nret" -eq 0 ]; then
      printf 'status: WARN: covers_through: absent (no retros found) — using declared blocks_since_retro: %s\n' "$_decl" >&2
      return 0
    fi
    if [ "$_maxcov" -lt 0 ]; then
      [ "$((_nbad + _nover + _nunsc))" -gt 0 ] || printf 'status: WARN: covers_through: absent in %s retro(s) — using declared blocks_since_retro: %s\n' "$_nret" "$_decl" >&2
      return 0
    fi
    _der=$((_newest - _maxcov))
    if [ "$_der" -lt "$_decl" ]; then
      _rd_eff="$_der"
      _rd_note=" [derived: newest block B${_newest} − covers_through B${_maxcov}; declared counter was ${_decl}]"
      printf 'status: INFO: blocks_since_retro: %s overridden by retro coverage (covers_through B%s, newest block B%s → %s)\n' "$_decl" "$_maxcov" "$_newest" "$_der" >&2
    fi
    return 0
  }
