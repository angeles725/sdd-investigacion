# --- envelope seeder (--sync-state) --------------------------------------------------------------
# derived investigable_open, reusing THIS script's backlog_rows/is_blocked — IDENTICAL to resolve_next's
# NEXT-eligibility set (single source of truth), and to what verify-state.sh recomputes.
count_investigable() {
  local gap st lead tok n=0 _ci_ib _ci_deg=0
  while IFS=$'\t' read -r _ gap st; do          # field 1 (priority) unused here → discard into _
    [ -z "$gap" ] && continue
    case "$gap" in *'~~'*) continue ;; esac      # struck-through gap name: resolved row, skip silently  # STRICKEN-GAP-SKIP
    lead="${st#\*\*}"; lead="${lead/\*\*/}"       # §8b: strip leading ** and its closing pair (handles **pending** (note))  # BOLD-STRIP
    tok="${lead%% *}"
    [ "$tok" = "pending" ] || {
      case "$tok" in
        requires-execution*|blocked-on-*|blocked|blocked:|blocked,|'~~'*|'✅'*|closed|\[closed\]|covered|\[covered\]|done|\[done\]|cubierto|\[cubierto\]) ;;  # DONE-TOKENS
        re-typed*|retyped*) printf 'WARN: re-typed row still carries "re-typed" — write its Status as the re-typed form "blocked (requires-<what>)" per METHODOLOGY §8b (or move it to the Blocked-gaps section) [gap: %s]\n' "$gap" >&2 ;;  # RETYPED-WARN (#1638): uncounted by design, never silent; mirrored in verify-state.sh
        *) printf 'WARN: unrecognised Status token [%s] in gap: %s\n' "$tok" "$gap" >&2 ;;  # UNRECOG-STATUS-WARN
      esac
      continue
    }
    is_blocked "$gap"; _ci_ib=$?
    [ "$_ci_ib" -eq 0 ] && continue
    [ "$_ci_ib" -eq 1 ] || _ci_deg=1   # CI-DEGRADED-RC (#2024): an unknown blocked status is neither counted nor silently "not blocked"
    n=$((n+1))
  done < <(backlog_rows 2>/dev/null)
  echo "$n"
  return "$_ci_deg"   # 0, or 3 when any blocked read failed: the count is then inflated and callers that gate a verdict must refuse
}
# count_retyped_in_table — OPEN backlog rows whose leading Status token is `re-typed`/`retyped` (#1638). Such a
# row is deliberately NOT investigable and NOT a blocked bucket (METHODOLOGY §8b: it leaves the main table in
# the same edit) — this makes it VISIBLE so it is never counted nowhere. MIRRORS verify-state.sh's
# derive_retyped_in_table EXACTLY (same token set, same struck-gap skip).
count_retyped_in_table() {
  local gap st lead tok n=0
  while IFS=$'\t' read -r _ gap st; do
    [ -z "$gap" ] && continue
    case "$gap" in *'~~'*) continue ;; esac
    lead="${st#\*\*}"; lead="${lead/\*\*/}"
    tok="${lead%% *}"
    case "$tok" in re-typed*|retyped*) n=$((n+1)) ;; esac  # RETYPED-COUNT RETYPED-TOKENS
  done < <(backlog_rows 2>/dev/null)
  echo "$n"
}
# warn_inplace_blocked FILE N — the typed actionable WARN for the in-place bucket (prints nothing when N is 0).
# Called on every path that derives gaps_closed (backlog-derived AND declared-keep).
warn_inplace_blocked() {
  [ "${2:-0}" -gt 0 ] || return 0
  printf 'sync-state: WARN: %s: %d in-place blocked row(s) (Status blocked / blocked-on-*) are open but not in blocked_open (section-derived) — NOT counted as closed in gaps_closed; move them to ## Blocked gaps (METHODOLOGY §21.1) so blocked_open and the known_gaps identity (verify-state CHECK H) agree.\n' "$1" "$2" >&2
}
# derived requires_execution_open — MIRRORS verify-state.sh's derive_requires_execution EXACTLY (same
# deliberate lockstep as count_investigable): OPEN backlog rows whose STATUS column (tolower'd by
# backlog_rows) is ANCHORED to the LEADING token `requires-execution` (mirrors count_investigable's
# `pending` leading-token discipline) — a free-text mention that merely NAMES the phrase
# (`pending (requires-execution)`) is NOT counted (was a CHECK E false-POSITIVE). CLOSED is decided only
# by UNAMBIGUOUS markers: a struck-through gap (~~), or a status carrying ~~/✅. The bare words
# covered/closed/done/cubierto were REMOVED from the closed-test: they appear NEGATED in genuinely OPEN
# asides (`not yet covered`, `not yet done`), and a bare substring match there false-excluded an open row
# (was a CHECK E false-NEGATIVE). Only a LOWER BOUND: a prose-tracked build gap (logosoft) has no backlog
# marker, so --sync-state prefers this count ONLY when it is > 0.
count_requires_execution() {
  local gap st lead n=0
  while IFS=$'\t' read -r _ gap st; do          # field 1 (priority) unused here → discard into _
    [ -z "$gap" ] && continue
    # OPEN marker ANCHORED to the leading token (strip one ** bold first) — mirrors derive_investigable's
    # `pending` leading-token discipline so a free-text mention (`pending (requires-execution)`) that merely
    # names the phrase is NOT counted as a build gap (was a CHECK E false-FAIL).
    lead="${st#\*\*}"
    case "$lead" in requires-execution|requires-execution[!a-z0-9]*) ;; *) continue ;; esac
    # CLOSED only via UNAMBIGUOUS markers: a struck gap/status (~~) or a ✅ verdict. The bare words
    # covered/closed/done/cubierto were REMOVED: they appear negated in OPEN asides (`(not yet covered)`,
    # `not yet done`), and a substring match there false-excluded a genuinely open gap → CHECK E missed the
    # premature-build-STOP hazard. Canonical closure always pairs the word WITH ✅ (`✅ cubierto`), so ✅ suffices.
    case "$gap" in *'~~'*) continue ;; esac
    case "$st" in *'~~'*|*'✅'*) continue ;; esac
    n=$((n+1))
  done < <(backlog_rows 2>/dev/null)
  echo "$n"
}
# count_all_known_gaps — total backlog row count: all valid-priority rows (all statuses) PLUS the closed-class
# rows (kit #1307): em-dash and struck-tier rows, and CLOSED deferred rows (✅ / ~~). Those are gaps that were
# closed, so they belong in known_gaps (and, by the kg − open-buckets derivation, in gaps_closed) but are
# never routable. OPEN deferred rows are NOT in this count: they are counted by count_deferred and added by
# the caller, so no row is counted twice. An em-dash row whose Status is open is excluded with a WARN (§8b).
# Used to derive known_gaps when the backlog total exceeds the coverage metric Y (issue #568): a new gap
# added to the backlog bumps this count even when the coverage metric prose is stale.
# INVALID_PRIORITY rows are excluded — they are not countable and are reported separately.
count_all_known_gaps() {
  # Stderr is captured, not discarded: the closed-class WARNs (open em-dash row, malformed closed-class row) exist ONLY
  # on this call's path and must reach the operator; the structural WARNs were already printed by the parse check.
  local _kg_err _kg_rows; _kg_err="$(mktemp)" || { echo "sync-state: ERROR: mktemp failed" >&2; echo 0; return; }
  _kg_rows="$(backlog_rows 1 2>"$_kg_err")"  # KG-ALL-BACKLOG (arg 1 = ALSO closed-class rows, #1307)
  grep -E 'em-dash priority on an OPEN row|malformed closed-class backlog row|em-dash row whose Gap cell is not a gap id|near-miss backlog heading has no Priority header' "$_kg_err" >&2
  rm -f "$_kg_err"
  printf '%s\n' "$_kg_rows" | grep -v -e '^INVALID_PRIORITY' -e '^UNCOUNTED' | grep -c . | tr -d ' '  # KG-COUNT-NONEMPTY
}
# count_uncounted_rows — rows under a near-miss backlog heading whose tier token is not a §8b tier (numeric,
# bold, ...). They are excluded from count_all_known_gaps (and WARNed), so a derived known_gaps is then only a
# LOWER BOUND: --sync-state must not lower a declared known_gaps below it (kit #1307).
count_uncounted_rows() { backlog_rows 1 2>/dev/null | grep -c '^UNCOUNTED' | tr -d ' '; }
# count_attributed_sg — attributed covered-blocks count for block_scope: shared-global, mirroring
# _derive_attributed_sg() in verify-state.sh so --sync-state and CHECK A always agree.
# Source 1 (preferred): distinct B<n> ids in '## Covered blocks' body.
# Source 2 (fallback): distinct B<n> ids in the Block column of '## Iteration history'.
# Returns 0 when neither source yields any id (unverifiable — caller seeds 0 + WARN, not corpus-wide).
count_attributed_sg() {
  local ids n
  ids="$(section '## Covered blocks' | grep -oE '\bB[0-9]+\b' | sort -u)"
  if [ -z "$ids" ]; then
    ids="$(section '## Iteration history' | awk '
      BEGIN { blockcol=0 }
      /\|/ {
        gsub(/\r$/, "")
        gsub(/\\\|/, "\001")  # GFM-EP-BLOCKCOL (#2148): any `\|` is an escaped pipe, never a separator
        n = split($0, a, "|")
        if (!blockcol) {
          for (i=1; i<=n; i++) { v=a[i]; gsub(/^[ \t]+|[ \t]+$/,"",v); if (tolower(v)=="block") blockcol=i }
          next
        }
        if (blockcol && n >= blockcol) { v=a[blockcol]; gsub(/^[ \t]+|[ \t]+$/,"",v); print v }
      }' | grep -oE '\bB[0-9]+\b' | sort -u)"
  fi
  [ -z "$ids" ] && { echo 0; return; }
  n="$(printf '%s\n' "$ids" | wc -l | tr -d ' ')"
  echo "${n:-0}"
}
# requires-execution count from the `## Stop control` prose. Parenthesized asides are stripped FIRST and
# the number is anchored to the token itself, not to the whole line: the real logosoft line reads
# `— requires-execution (NO read-only; …, METHODOLOGY §8)**: **0 — AGOTADO.**`, and the old bare
# first-integer grep grabbed the 8 out of `§8` instead of the declared 0 (that stale 8 was live in its
# envelope). Emits the first integer AFTER the token, or nothing when the line/number is absent.
req_prose() { stopctl | sed -E 's/\([^)]*\)//g' | grep -ioE 'requires-execution[^0-9]*[0-9]+' | head -1 | grep -oE '[0-9]+$'; }
# read a field from the CURRENT envelope (for carry-forward of declared-only fields we cannot parse fresh).
env_get() { awk -v k="$1" '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && $1==k":"{v=$2; sub(/\r$/,"",v); print v; exit}' "$state"; }  # strip trailing CR (CRLF-safe)
# env_raw <key> — full declared value (everything after "key:", trimmed, CR-stripped) from the CURRENT
# envelope; exit 1 when the key is ABSENT (absent != empty). Whitespace/indent tolerant like the UF probe.
env_raw() { awk -v k="$1" '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0}
  b { l=$0; sub(/^[[:space:]]+/,"",l); if (index(l,k":")==1) { v=substr(l,length(k)+2); sub(/^[[:space:]]+/,"",v); sub(/[[:space:]\r]+$/,"",v); print v; f=1; exit } }
  END { exit f?0:1 }' "$state"; }  # ENV-RAW
# cov_ratio — the "N/M" of the Coverage metric FIELD in "## Coverage" (kit issue #1154), or empty when there is none.
# The label is the field's identity: a line only counts when it STARTS with `Coverage metric` (an optional list
# marker, bold marks, and a parenthetical qualifier such as `(this focus)` allowed) followed by `:` or `=`.
# Matching the bare phrase anywhere in the section read any note that merely mentioned it (e.g. an Outline line
# pointing at the field) as the gap ratio. Label forms measured on the fleet: `**Coverage metric**:` and the
# qualified `**Coverage metric (this focus)**:`; no prefixed label (`Gap coverage metric:`) occurs.
# Anti-silent-zero (§7): when NO line in the section matches the label at all, but a line still mentions the
# phrase AND carries a ratio, the figure is NOT silently dropped (that would print <none> / let --sync-state
# carry a stale envelope value forward): a typed WARN names the unrecognised line on stderr. A label line that
# EXISTS but carries no ratio (intentionally blank, e.g. document mode) means "metric not set": no WARN, even if
# another line mentions the phrase with a ratio.
COVMETRIC_LABEL_RE='^[[:space:]]*([-*+][[:space:]]+)?\*{0,2}coverage metric\*{0,2}[[:space:]]*(\([^)]*\))?\*{0,2}[[:space:]]*[:=]'  # CM-LABEL-ANCHOR
cov_ratio() {
  local _cr_r _cr_loose _cr_nlab
  _cr_r="$(section '## Coverage' | grep -iE "$COVMETRIC_LABEL_RE" | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | tr -d ' ')"
  _cr_nlab="$(section '## Coverage' | grep -ciE "$COVMETRIC_LABEL_RE")"  # CM-LABEL-PRESENT
  if [ -z "$_cr_r" ] && [ "${_cr_nlab:-0}" -eq 0 ]; then
    _cr_loose="$(section '## Coverage' | grep -iE 'coverage metric' | grep -E '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | cut -c1-100)"  # CM-UNRECOGNISED-LABEL
    [ -z "$_cr_loose" ] || printf 'WARN: %s: unrecognised coverage label — a line mentions the coverage metric with a ratio but does not start with the "Coverage metric:" label, so it is NOT read as the metric: %s\n' "$(basename "$state")" "$_cr_loose" >&2
  fi
  printf '%s\n' "$_cr_r"
}

# pick <parsed> <previous> — prefer a freshly-parsed integer, else carry the previous envelope value, else
# 0. NEVER invent: an unparseable declared field falls back to what was already recorded, not a guess.
pick() { case "$1" in ''|*[!0-9]*) case "$2" in ''|*[!0-9]*) echo 0;; *) echo "$2";; esac;; *) echo "$1";; esac; }
