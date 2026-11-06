
# --- §8c campaign queue helpers ----------------------------------------------------------------

# _CQ_COMMENT_SKIP_AWK: shared HTML-comment-skip state machine body, textually shared by
# campaign_section() and campaign_queue_present() (R2 round 3: this used to be hand-duplicated in
# each function — a fix to one could silently drift from the other, and a mutation anchor only ever
# covered whichever copy it happened to sit in). Defined ONCE as a bash string and interpolated into
# both awk programs below, so there is exactly one physical copy of this logic in the source file,
# and a single sed-targeted mutation against it exercises both callers.
#
# The template wraps its own "## Campaign queue" section in <!-- ... --> as a "do-not-pre-create"
# note; real RESEARCH-STATE files do NOT have HTML comments, so we must skip them when they appear
# (e.g. if someone copies from the template literally).
#
# R3-comment-skip-overreach (round 1): comment markers only count at the START of a line (optionally
# after whitespace) — matching how the template actually writes them. A table row's Seed/Convergence
# cell may legitimately contain a literal "-->" or an unclosed "<!--"; since a table row always starts
# with "|", it never matches these start-anchored patterns, so such a cell can no longer falsely
# open/close comment mode and drop or hide rows.
#
# R3/B2-comment-trailing-text (round 2): round 1's closing check required "-->" to be the LAST thing
# on the line (`/-->[[:space:]]*$/`), so a real closing line with trailing prose — the retro/audit
# templates' own `<!-- review-status: pending --> see note` shape, or `line --> (end)` — never closed
# the comment, silently swallowing every row after it (pending=1 became "campaign: none"). The state
# machine below closes on "-->" ANYWHERE once inside a comment, and only ENTERS multi-line comment
# mode when the opening line does NOT also contain a closing "-->" (so a genuine one-line comment like
# `<!-- a -> b -->` — broken before this PR too, since `[^>]*` could not cross the embedded ">" in
# "->" — is consumed whole without ever setting in_c).
_CQ_COMMENT_SKIP_AWK='
      if (in_c) {
        if ($0 ~ /-->/) { in_c = 0 }  # CQ-COMMENT-CLOSE-ANCHOR — closes on --> ANYWHERE, not just at EOL
        next
      }
      if ($0 ~ /^[[:space:]]*<!--/) {  # CQ-COMMENT-OPEN-STARTANCHOR — only a LINE-START <!-- opens a comment
        if ($0 !~ /-->/) { in_c = 1 }  # CQ-COMMENT-OPEN-ANCHOR — only multi-line when not also closed here
        next
      }
'

# campaign_section: body of "## Campaign queue", skipping HTML comment blocks (shared state machine
# above). A file that ends while still inside a comment WARNs loudly instead of silently discarding
# the rest of the section (anti-silent-zero, kit §7).
campaign_section() {
  awk '
    {
'"$_CQ_COMMENT_SKIP_AWK"'
      if (index($0, "## Campaign queue") == 1) { f = 1; next }
      if ($0 ~ /^## /) { f = 0 }
      if (f) print
    }
    END {
      if (in_c) print "WARN: campaign queue: file ends while still inside an HTML comment (unclosed <!--)" > "/dev/stderr"  # CQ-COMMENT-EOF-WARN-ANCHOR
    }
  ' "$state"
}

# campaign_queue_present: exits 0 when ## Campaign queue exists outside HTML comments. Same
# comment-detection state machine as campaign_section() — literally the same shared string, not a
# hand-copied twin (R2 round 3).
campaign_queue_present() {
  awk '
    {
'"$_CQ_COMMENT_SKIP_AWK"'
      if (index($0, "## Campaign queue") == 1) { found = 1; exit }
    }
    END { exit !found }
  ' "$state"
}

# _campaign_age_min <ISO8601-ts>: prints age in minutes as integer, or "unknown" on parse fail.
# Respects _RSDD_NOW_EPOCH test-hook (injected by tests for deterministic stall computation).
#
# R3/R4 bsd-date-tz + bsd-date-utc-skew: on hosts without GNU `date -d`, the BSD/macOS fallback
# `date -j -f "%Y-%m-%dT%H:%M:%SZ" ...` treats the trailing Z as a literal character, not a UTC
# marker, so without an explicit TZ it parses the timestamp as LOCAL wall-clock time — the computed
# age is then off by the host's UTC offset (negative west of UTC, inflated east of UTC). Forcing
# TZ=UTC on that call makes it interpret the (already-UTC) fields correctly regardless of the host's
# local timezone, matching what GNU `date -d` already does for a Z-suffixed timestamp.
#
# A resulting negative or otherwise unparseable age is never printed as a raw number — every
# downstream numeric guard is `^[0-9]+$`, so a silent negative would just look like "no stall" with
# no indication anything was wrong. Report it loudly instead: WARN to stderr and return "unknown".
_campaign_age_min() {
  local ts="$1" ts_epoch now_epoch age
  ts_epoch=$(date -d "$ts" +%s 2>/dev/null) \
    || ts_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null) || true
  if [ -z "$ts_epoch" ] || ! grep -qE '^-?[0-9]+$' <<<"$ts_epoch"; then
    printf 'unknown'
    return
  fi
  now_epoch="${_RSDD_NOW_EPOCH:-$(date +%s)}"
  age=$(( (now_epoch - ts_epoch) / 60 ))
  if [ "$age" -lt 0 ]; then  # CQ-NEG-AGE-ANCHOR
    printf 'WARN: campaign: last_iteration_ts %s is in the future relative to now (age %d min) — reporting unknown\n' \
      "$ts" "$age" >&2
    printf 'unknown'
    return
  fi
  printf '%s' "$age"
}

# _campaign_row_counts <warn-label> <section-text>: reads <section-text> (campaign_section()'s
# output, passed in rather than re-fetched — R2-002: avoid re-running campaign_section() once per
# field, which would also re-emit its unclosed-comment WARN once per field) table rows and prints
# "pending active done bound-stopped rejected row_count" (six space-separated integers) on stdout.
# WARNs to stderr for a malformed Kind/State or an empty table; warn-label (e.g. " [beta]") is
# appended to each WARN so a multi-focus WARN is attributable to the right focus.
_campaign_row_counts() {
  local _wlabel="${1:-}" _section="${2:-}"
  local n_cq_pending=0 n_cq_active=0 n_cq_done=0 n_cq_bstopped=0 n_cq_rejected=0
  local _cq_row_count=0
  local _row_name _row_kind _row_state
  while IFS='|' read -r _ _row_name _ _row_kind _ _ _row_state _; do
    _row_name="${_row_name#"${_row_name%%[! ]*}"}" ; _row_name="${_row_name%"${_row_name##*[! ]}"}"
    _row_kind="${_row_kind#"${_row_kind%%[! ]*}"}" ; _row_kind="${_row_kind%"${_row_kind##*[! ]}"}"
    _row_state="${_row_state#"${_row_state%%[! ]*}"}" ; _row_state="${_row_state%"${_row_state##*[! ]}"}"
    [ "$_row_kind" = "Kind" ] && continue                              # header row
    grep -qE '^-+$' <<<"$_row_kind" && continue            # separator row
    [ -z "$_row_name" ] && continue                                    # truly empty line
    _cq_row_count=$(( _cq_row_count + 1 ))
    # Validate Kind vocabulary: focus | tier | sub-topic
    case "$_row_kind" in
      focus|tier|sub-topic) ;;
      *) printf 'WARN: campaign queue%s: unrecognised Kind '\''%s'\'' in row %s\n' \
           "$_wlabel" "$_row_kind" "$_row_name" >&2 ;;
    esac
    # Count and validate State vocabulary  # CQ-COUNT-PENDING-ANCHOR
    case "$_row_state" in
      pending)       n_cq_pending=$(( n_cq_pending + 1 )) ;;  # CQ-COUNT-PENDING-ANCHOR
      active)        n_cq_active=$(( n_cq_active + 1 )) ;;
      done)          n_cq_done=$(( n_cq_done + 1 )) ;;
      bound-stopped) n_cq_bstopped=$(( n_cq_bstopped + 1 )) ;;
      rejected)      n_cq_rejected=$(( n_cq_rejected + 1 )) ;;
      *) printf 'WARN: campaign queue%s: unrecognised State '\''%s'\'' in row %s\n' \
           "$_wlabel" "$_row_state" "$_row_name" >&2 ;;
    esac
  done < <(printf '%s\n' "$_section" | grep '^|')

  if [ "$_cq_row_count" -eq 0 ]; then
    printf 'WARN: campaign queue table present but empty%s\n' "$_wlabel" >&2
  fi

  printf '%d %d %d %d %d %d\n' \
    "$n_cq_pending" "$n_cq_active" "$n_cq_done" "$n_cq_bstopped" "$n_cq_rejected" "$_cq_row_count"
}

# _campaign_stop_text <pending> <active> <last_audit> <section-text>: prints the campaign_stop text
# (an explicit campaign_stop: field in <section-text>, or the computed STOP condition), or nothing
# when neither applies. Factored out so campaign_status_block can decide per-focus AND aggregate STOP
# correctly (R4-campaign-block-first-focus-only) instead of only ever looking at one focus.
# <section-text> is passed in rather than re-fetched — see _campaign_row_counts above (R2-002).
_campaign_stop_text() {
  local _p="$1" _a="$2" _la="$3" _section="${4:-}" _field
  _field="$(grep -m1 '^campaign_stop:' <<<"$_section" | sed 's/^campaign_stop:[[:space:]]*//')"
  if [ -n "$_field" ]; then
    printf '%s' "$_field"
    return
  fi
  if [ "$_p" -eq 0 ] && [ "$_a" -eq 0 ] && [ -n "$_la" ]; then
    # STOP condition: all entries terminal AND last_audit enqueued=0 (absent last_audit never satisfies)
    local _enq
    _enq="$(printf '%s' "$_la" | grep -oE 'enqueued=[0-9]+' | grep -oE '[0-9]+')"
    [ "${_enq:-}" = "0" ] && printf 'STOP reached — all entries terminal, last_audit enqueued=0'
  fi
}

# campaign_status_block: emit §8c campaign queue lines in the default status report.
#
# R4-campaign-block-first-focus-only (round 1): the original implementation read only the single
# alphabetically-first $state, so in a multi-focus target the queue counts, campaign_stop and the
# stall warning described only that one focus. This mirrors the fix already applied to the "next
# step" block below: iterate every focus, skip only the ones FOCUSES.md declares stopped/paused, and
# never let one focus's terminal state stand in for the whole campaign.
#
# B1 (round 2): when --focus <slug> narrows the report to one focus, the campaign block must report
# exactly that focus — never siblings, and never skip it even when FOCUSES.md declares it stopped or
# paused (that skip exists to keep a MULTI-focus scan from being misled by a terminal sibling; it does
# not apply when the caller explicitly asked for this one focus).
#
# W1 (round 2): a target where NO active focus has started a campaign yet used to print one "none"
# line PER focus (62 lines on a 30-focus corpus). Collapsed to a single summary line, and per-focus
# lines are now printed only for focuses that actually have a queue.
campaign_status_block() {
  local -a _cqb_states=()
  # B1/RDD: shadow the caller's global $state so the loops below never leak their reassignments out
  # to it — but COPY the caller's current value in first ("local state=$state"), not a bare "local
  # state": under `set -u`, a bare local declaration starts unset, and $focus_slug's already-resolved
  # $state (needed immediately below) would then read as an unbound-variable error.
  local state="$state"
  if [ -n "$focus_slug" ]; then  # B1-FOCUS-STATES-ANCHOR
    _cqb_states=("$state")
  else
    mapfile -t _cqb_states < <(list_state_files "$target")
  fi

  local -a _cqb_active=()
  local _cqb_skip=0 _cqb_st _cqb_foc_file _cqb_foc_tok
  if [ -n "$focus_slug" ]; then  # B1-FOCUS-ACTIVE-ANCHOR
    _cqb_active=("${_cqb_states[0]}")
  else
    for _cqb_st in "${_cqb_states[@]}"; do
      _cqb_foc_file="$(dirname "$_cqb_st")/FOCUSES.md"
      _read_focuses_tok_into _cqb_foc_tok "$_cqb_foc_file" "$(basename "$_cqb_st")"
      if [ "$_cqb_foc_tok" = "stopped" ] || [ "$_cqb_foc_tok" = "paused" ]; then
        _cqb_skip=$(( _cqb_skip + 1 ))
        continue
      fi
      _cqb_active+=("$_cqb_st")
    done
  fi
  # CQB-MULTIFOCUS-ANCHOR (R4-campaign-block-first-focus-only: every active focus is evaluated below,
  # not just the alphabetically-first one)

  if [ "${#_cqb_active[@]}" -eq 0 ]; then
    printf '  %-16s: no active focus (%d declared stopped/paused in FOCUSES.md)\n' "campaign" "$_cqb_skip"
    return
  fi

  # --- pass 1: which active focuses actually have a queue? (W1 collapse decision.) ---
  local -a _cqb_queue_states=()
  for state in "${_cqb_active[@]}"; do
    campaign_queue_present && _cqb_queue_states+=("$state")
  done
  local _cqb_n_active="${#_cqb_active[@]}" _cqb_n_queue="${#_cqb_queue_states[@]}"

  if [ "$_cqb_n_queue" -eq 0 ]; then  # W1-COLLAPSE-ANCHOR
    # R2-misleading-preserve-contract-comment (round 3): "focus" is singular when there is exactly
    # one active focus — nave-panccadia (a genuine single-focus corpus) was printing the grammatically
    # wrong "1 active focuses, 0 with a queue" before this.
    local _cqb_focus_word="focuses"
    [ "$_cqb_n_active" -eq 1 ] && _cqb_focus_word="focus"
    printf '  %-16s: none (%d active %s, 0 with a queue)\n' "campaign" "$_cqb_n_active" "$_cqb_focus_word"  # CQ-NONE-ANCHOR
    if [ "$_cqb_n_active" -eq 1 ]; then
      # Single-focus corpus, no campaign started: still prints the original two-line SHAPE (a
      # campaign-status line followed by a last_iteration_ts line) rather than dropping the ts line
      # entirely — it does NOT preserve the original line's exact TEXT, which is the point of this
      # branch (round 3: the previous wording here claimed to "preserve the original two-line
      # contract", which overclaimed byte-for-byte sameness the collapsed line never had).
      local _cqb_ts
      state="${_cqb_active[0]}"
      _cqb_ts="$(env_get last_iteration_ts)"
      if [ -z "$_cqb_ts" ]; then
        printf '  %-16s: absent\n' "last_iteration_ts"
      else
        printf '  %-16s: %s  (age: %s min)\n' "last_iteration_ts" "$_cqb_ts" "$(_campaign_age_min "$_cqb_ts")"
      fi
    fi
    return
  fi

  # Labelling and STOP-aggregation are both keyed on the QUEUE-BEARING count, not the total active
  # count: a focus with no queue at all was never "terminal" in any meaningful sense, so it must not
  # inflate the denominator in "all N ... terminal" (W3) or force labels when only one focus is ever
  # actually reported (a no-queue sibling produces no output at all — W1).
  local _cqb_multi=0
  [ "$_cqb_n_queue" -gt 1 ] && _cqb_multi=1

  local _cqb_slug _cqb_flabel _cqb_wlabel _ts _ts_age_min _cqb_section
  local _cqb_all_stopped=1
  local _p _a _d _b _r _rows _stop_txt _la
  local _cq_bounds_field _bd_token _bd_key _bd_val

  for state in "${_cqb_queue_states[@]}"; do
    _cqb_slug="$(basename "$state" .md)"; _cqb_slug="${_cqb_slug#RESEARCH-STATE-}"
    _cqb_flabel=""; _cqb_wlabel=""
    if [ "$_cqb_multi" -eq 1 ]; then
      _cqb_flabel="[$_cqb_slug]"
      _cqb_wlabel=" [$_cqb_slug]"
    fi

    _ts="$(env_get last_iteration_ts)"
    _cqb_section="$(campaign_section)"

    read -r _p _a _d _b _r _rows < <(_campaign_row_counts "$_cqb_wlabel" "$_cqb_section")
    printf '  %-16s: pending=%d active=%d done=%d bound-stopped=%d rejected=%d\n' \
      "campaign${_cqb_flabel}" "$_p" "$_a" "$_d" "$_b" "$_r"

    # --- last_audit ---
    _la="$(grep -m1 '^last_audit:' <<<"$_cqb_section" | sed 's/^last_audit:[[:space:]]*//')"
    if [ -n "$_la" ]; then
      printf '  %-16s: %s\n' "last_audit${_cqb_flabel}" "$_la"
    else
      printf '  %-16s: not yet audited\n' "last_audit${_cqb_flabel}"
    fi

    # --- campaign_stop field or computed STOP condition, per focus ---
    _stop_txt="$(_campaign_stop_text "$_p" "$_a" "$_la" "$_cqb_section")"
    if [ -n "$_stop_txt" ]; then
      printf '  %-16s: %s\n' "campaign_stop${_cqb_flabel}" "$_stop_txt"
    else
      _cqb_all_stopped=0
    fi

    # --- campaign_bounds ---
    _cq_bounds_field="$(grep -m1 '^campaign_bounds:' <<<"$_cqb_section" | sed 's/^campaign_bounds:[[:space:]]*//')"
    if [ -n "$_cq_bounds_field" ]; then
      printf '  %-16s: %s\n' "campaign_bounds${_cqb_flabel}" "$_cq_bounds_field"
      # Validate each key=value token
      while IFS= read -r _bd_token; do
        [ -z "$_bd_token" ] && continue
        _bd_key="$(printf '%s' "$_bd_token" | cut -d= -f1)"
        _bd_val="$(printf '%s' "$_bd_token" | cut -d= -f2-)"
        case "$_bd_key" in
          max-depth|iterations)
            grep -qE '^[0-9]+$' <<<"$_bd_val" \
              || printf 'WARN: campaign_bounds%s: bad %s value '\''%s'\''\n' "$_cqb_wlabel" "$_bd_key" "$_bd_val" >&2 ;;
          wall-clock)
            grep -qE '^[0-9]+(\.[0-9]+)?h$' <<<"$_bd_val" \
              || printf 'WARN: campaign_bounds%s: bad wall-clock value '\''%s'\''\n' "$_cqb_wlabel" "$_bd_val" >&2 ;;
          *)
            printf 'WARN: campaign_bounds%s: unknown key '\''%s'\''\n' "$_cqb_wlabel" "$_bd_key" >&2 ;;
        esac
      done < <(printf '%s\n' "$_cq_bounds_field" | tr ' ' '\n')
    fi

    # --- last_iteration_ts with age; stall WARN when THIS focus's campaign is active/pending ---
    if [ -z "$_ts" ]; then
      printf '  %-16s: absent\n' "last_iteration_ts${_cqb_flabel}"
    else
      _ts_age_min="$(_campaign_age_min "$_ts")"
      printf '  %-16s: %s  (age: %s min)\n' "last_iteration_ts${_cqb_flabel}" "$_ts" "$_ts_age_min"
      if [ "$_p" -gt 0 ] || [ "$_a" -gt 0 ]; then
        if grep -qE '^[0-9]+$' <<<"$_ts_age_min" && [ "$_ts_age_min" -gt "$stall_minutes" ]; then
          printf 'WARN: campaign stall%s — last_iteration_ts age %s min exceeds threshold %s min\n' "$_cqb_wlabel" "$_ts_age_min" "$stall_minutes" >&2  # CQ-STALL-WARN-ANCHOR
          :  # noop — keeps then-block non-empty after stall-anchor mutation
        fi
      fi
    fi
  done

  # Aggregate STOP: only when EVERY queue-bearing focus independently reached its own STOP condition
  # — never just the first one (R4-campaign-block-first-focus-only). W3: the count in the message is
  # the QUEUE-BEARING count (_cqb_n_queue), never the total active count — a no-queue sibling was
  # never "terminal" and must not be folded into "all N ... terminal".
  if [ "$_cqb_multi" -eq 1 ] && [ "$_cqb_all_stopped" -eq 1 ]; then
    printf '  %-16s: STOP reached — all %d queue-bearing focuses terminal\n' "campaign_stop" "$_cqb_n_queue"  # W3-WORDING-ANCHOR
  fi
}

