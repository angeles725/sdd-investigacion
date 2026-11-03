resolve_next() {
  local rows; rows="$(backlog_rows)"             # compute ONCE — else the WARN fires per priority tier
  local prio pri gap st lead tok _rn_ib
  for prio in high medium low; do
    while IFS=$'\t' read -r pri gap st; do
      [ -z "$gap" ] && continue
      case "$gap" in *'~~'*) continue ;; esac      # struck-through gap name: resolved row, skip silently
      lead="${st#\*\*}"; lead="${lead/\*\*/}"       # §8b: strip leading ** and its closing pair (handles **pending** (note))
      tok="${lead%% *}"
      [ "$tok" = "pending" ] || continue           # LEADING-TOKEN — bare `pending` or decorated `pending (uncovered by B7)`; NOT "not pending" / "blocked (pending review)"
      is_blocked "$gap"; _rn_ib=$?
      [ "$_rn_ib" -eq 0 ] && continue
      if [ "$_rn_ib" -ne 1 ]; then echo "DEGRADED | blocked-rows read failed while resolving $gap in $(_rel_state "$state") — no gap is handed out; fix the failure named on stderr, then re-run"; return 3; fi  # RESOLVE-DEGRADED-FATAL (#2024 S3)
      printf 'NEXT | %s | %s\n' "$pri" "$gap"; return 0
    done < <(printf '%s\n' "$rows" | awk -F'\t' -v P="$prio" '$1==P')
  done
  # The walk above found NO eligible (pending, non-blocked) gap, so the DERIVED investigable count is 0 BY
  # CONSTRUCTION — the exact number verify-state.sh gates as the envelope's investigable_open, and the --next
  # STALE-gate already ensured the envelope agrees with this derivation before we got here. STOP on that, NOT
  # on the hand-authored `## Stop control` prose (which --sync-state never rewrites and verify-state never
  # gates): reading that prose here would resurrect the stale-mirror class the envelope was built to kill.
  echo "STOP | read-only-investigable exhausted (0)"
}

# queue_next — kit #1614. Serve the first pending, non-blocked gap of THIS state file's declared `next_session_queue`
# (header zone = lines before the first `## ` heading). rc 0 + one NEXT line on stdout when served; rc 1 otherwise, with
# a typed note on stderr saying WHY (the caller then falls back to resolve_next, so a queue never blocks the loop).
# Reads the global $state like backlog_rows. An id matches a backlog Gap cell that equals it or starts with it followed
# by a character that cannot continue an id (so G1 never matches G10 or G1-b).
queue_next() {
  local slug raw val id ids=() items=() rows pri gap st lead tok served="" cls c n=0 nunk=0 ndone=0 ndef=0 nblk=0 nprog=0 found nmatch j dup
  slug="$(basename "$state" .md)"; slug="${slug#RESEARCH-STATE}"; slug="${slug#-}"; slug="${slug:-root}"
  raw="$(awk '/^## /{exit} /<!--/{c=1} c{if (/-->/) c=0; next} /^(-[[:space:]]+)?next_session_queue:/{print}' "$state" 2>/dev/null)"
  if [ -z "$raw" ]; then
    if awk '/^## /{exit} /<!--/{c=1} c{if (/-->/) c=0; next} tolower($0) ~ /next[ _-]session[ _-]queue/{f=1} END{exit !f}' "$state" 2>/dev/null; then
      printf 'INFO: queue-prose-only [%s]: header names a next-session queue in prose but declares no `next_session_queue:` field — priority order used\n' "$slug" >&2
    else
      printf 'INFO: queue-absent [%s]: no next_session_queue field in the header — priority order used\n' "$slug" >&2
    fi
    return 1
  fi
  if [ "$(printf '%s\n' "$raw" | wc -l)" -gt 1 ]; then
    printf 'WARN: queue-malformed [%s]: next_session_queue declared more than once — field ignored, priority order used\n' "$slug" >&2; return 1
  fi
  val="${raw#*next_session_queue:}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
  case "${val,,}" in ''|none|'[]') printf 'INFO: queue-empty [%s]: next_session_queue is declared with no gap ids — priority order used\n' "$slug" >&2; return 1 ;; esac
  case "$val" in *,) printf 'WARN: queue-malformed [%s]: trailing comma in next_session_queue — field ignored, priority order used\n' "$slug" >&2; return 1 ;; esac
  IFS=',' read -r -a items <<<"$val"   # array split: no pathname expansion of the items
  for id in "${items[@]}"; do
    id="${id#"${id%%[![:space:]]*}"}"; id="${id%"${id##*[![:space:]]}"}"
    if ! grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$' <<<"$id"; then
      printf 'WARN: queue-malformed [%s]: item [%s] is not a gap id (want G1, G2, ... comma-separated) — field ignored, priority order used\n' "$slug" "$id" >&2; return 1
    fi
    dup=0; for j in ${ids[@]+"${ids[@]}"}; do [ "$j" = "$id" ] && dup=1; done
    if [ "$dup" = 1 ]; then printf 'WARN: queue-duplicate-id [%s]: id [%s] is queued more than once — later occurrence ignored\n' "$slug" "$id" >&2; continue; fi
    ids+=("$id")
  done
  # ONE parse with the closed-class rows included (deferred / ~~p~~ / em-dash, as emitted for count_all_known_gaps), plus the OPEN
  # deferred rows that parse leaves to count_deferred: a queued gap that is closed or parked is KNOWN, never "unknown". resolve_next
  # keeps its own backlog_rows call and output.
  # Open deferred rows: only inside a `## Gap-backlog` section, 4- or 5-column rows (a bolded `**deferred**` priority is a STALE backlog, so never reaches here).
  rows="$(backlog_rows 1)"$'\n'"$(deferred_scan 1)"
  for id in "${ids[@]}"; do
    n=$((n+1)); found=0; cls=""; nmatch=0
    while IFS=$'\t' read -r pri gap st; do
      [ -z "$gap" ] && continue
      case "$pri" in UNCOUNTED|INVALID_PRIORITY) continue ;; esac
      lead="$gap"
      for _ in 1 2; do lead="${lead#\*\*}"; lead="${lead#\~\~}"; lead="${lead#\`}"; done
      case "$lead" in "$id") ;; "$id"[!A-Za-z0-9._-]*) ;; *) continue ;; esac
      found=1; nmatch=$((nmatch+1))
      lead="${st#\*\*}"; lead="${lead/\*\*/}"; tok="${lead%% *}"
      case "$pri" in
        deferred-open) c=deferred ;;
        deferred|'~~'|—) c=terminal ;;
        *) if [[ "$gap" == *'~~'* ]]; then c=terminal
           else case "$tok" in
             pending) is_blocked "$gap"; _qn_ib=$?
                      case "$_qn_ib" in 0) c=blocked ;; 1) c=serve ;;
                        *) echo "DEGRADED | blocked-rows read failed while resolving $gap in $(_rel_state "$state") — no gap is handed out; fix the failure named on stderr, then re-run"; return 3 ;; esac ;;  # QUEUE-DEGRADED-FATAL (#2024)
             blocked*|requires-execution*) c=blocked ;;
             closed|'[closed]'|covered|'[covered]'|done|'[done]'|cubierto|'[cubierto]'|'✅'*|'~~'*) c=terminal ;;
             *) c=inprogress ;;
           esac; fi ;;
      esac
      if [ "$c" = serve ]; then
        [ -n "$served" ] || served="$(printf 'NEXT | %s | %s' "$pri" "$gap")"
        cls=serve; continue
      fi
      [ -n "$cls" ] || cls="$c"
    done < <(printf '%s\n' "$rows")
    case "$cls" in
      terminal) ndone=$((ndone+1)) ;; deferred) ndef=$((ndef+1)) ;; blocked) nblk=$((nblk+1)) ;; inprogress) nprog=$((nprog+1)) ;;
    esac
    if [ "$nmatch" -gt 1 ]; then printf 'WARN: queue-ambiguous-id [%s]: queued id [%s] (%s rows) matches several backlog rows — a servable one wins\n' "$slug" "$id" "$nmatch" >&2; fi
    if [ "$found" = 0 ]; then
      nunk=$((nunk+1)); printf 'WARN: queue-unknown-gap [%s]: queued id [%s] (position %s) matches no backlog row — skipped\n' "$slug" "$id" "$n" >&2
    fi
  done
  if [ -n "$served" ]; then printf '%s\n' "$served"; return 0; fi
  printf 'INFO: queue-exhausted [%s]: next_session_queue (%s ids: %s done, %s deferred, %s blocked, %s in-progress, %s unknown) has no pending gap — priority order used\n' "$slug" "${#ids[@]}" "$ndone" "$ndef" "$nblk" "$nprog" "$nunk" >&2
  return 1
}

# resolve_next_q — resolve_next, preferring the declared queue when --queue was given (kit #1614).
resolve_next_q() {
  local _rq_rc
  if [ "$queue_flag" = 1 ]; then
    queue_next; _rq_rc=$?
    [ "$_rq_rc" -eq 0 ] && return 0
    [ "$_rq_rc" -eq 3 ] && return 3   # RESOLVE-Q-PASSTHROUGH: a degraded queue read never falls back to the priority walk
  fi
  resolve_next
}
