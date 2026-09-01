#!/usr/bin/env bash
# sweep-retros.sh — surface un-reviewed §18 self-retrospective proposals across ALL
# research-sdd targets, so no proposed kit delta sits unreviewed (METHODOLOGY §18).
#
# A retro under <target>/retros/*.md is PENDING unless its top carries a marker:
#   <!-- review-status: applied ... -->   or   <!-- review-status: dismissed ... -->
# The maintainer runs this (manually or on a schedule) from anywhere; it reads the
# target list from the kit's TARGETS.md. Read-only: it never edits anything.
#
# Usage: research-sdd/toolbelt/sweep-retros.sh

KIT="$(cd "$(dirname "$0")/.." && pwd)"
TARGETS_MD="$KIT/TARGETS.md"

# Shared review-status reader — single source of truth for the marker logic (sweep-retros.sh and
# stage-retro.sh both source it, so the leading-comment-block scan can never drift between them).
LIB="$(cd "$(dirname "$0")" && pwd)/lib/retro-status.sh"
if [ ! -f "$LIB" ]; then
  echo "sweep-retros: cannot find helper $LIB" >&2
  exit 1
fi
# shellcheck source=lib/retro-status.sh
. "$LIB"
# Fail closed: existence of $LIB is not enough — the source must have DEFINED the reader.
# Neither script uses `set -e`, so a failed/partial/syntax-broken source would otherwise be
# swallowed and every retro would silently read as 'none' (fail-open). Abort before any work.
declare -F retro_review_status >/dev/null 2>&1 || { echo "sweep-retros: helper $LIB failed to define retro_review_status" >&2; exit 1; }
# retro_is_waived is needed for the MISSING-RETRO waiver check in the fleet pass.
declare -F retro_is_waived >/dev/null 2>&1 || { echo "sweep-retros: helper $LIB failed to define retro_is_waived" >&2; exit 1; }

# Shared target-path derivation (handles /abs and $RESEARCH_HOME/... forms).
_sr_tp_lib="$(cd "$(dirname "$0")" && pwd)/lib/target-paths.sh"
if [ ! -f "$_sr_tp_lib" ]; then
  echo "sweep-retros: cannot find helper $_sr_tp_lib" >&2; exit 1
fi
# shellcheck source=lib/target-paths.sh
. "$_sr_tp_lib"
# Fail closed: source must DEFINE the function — a partial source is otherwise swallowed.
declare -F target_paths_all >/dev/null 2>&1 || { echo "sweep-retros: helper $_sr_tp_lib failed to define target_paths_all" >&2; exit 1; }
unset _sr_tp_lib

if [ ! -f "$TARGETS_MD" ]; then
  echo "sweep-retros: cannot find $TARGETS_MD" >&2
  exit 1
fi

# Absolute target paths live in the TARGETS.md table as backtick-wrapped paths.
# target_paths_all handles /abs and $RESEARCH_HOME/... forms; truncated '...' entries
# pass through so the summary can WARN the sweep is PARTIAL.
all_paths=$(target_paths_all "$TARGETS_MD")
paths=$(printf '%s\n' "$all_paths" | grep -v '\.\.\.')
skipped=$(printf '%s\n' "$all_paths" | grep '\.\.\.')
# ANTI-SILENT-ZERO: zero usable paths is a loud error, not a silent empty run.
if [ -z "$paths" ]; then
  echo "sweep-retros: ERROR — no usable target paths in $TARGETS_MD" >&2
  echo "sweep-retros: check TARGETS.md has backtick-wrapped absolute or \$RESEARCH_HOME/... paths" >&2
  exit 1
fi

skipped_names=""; skipped_count=0
for s in $skipped; do
  skipped_count=$((skipped_count + 1))
  skipped_names="${skipped_names:+$skipped_names, }$(basename "$s")"
done

# AGING (Feature #26): each PENDING retro is AGED from its git FIRST-COMMIT (added) date so a stale proposal
# can't sit unreviewed; the queue is REORDERED oldest-first and items past a threshold are TAGGED ESCALATED.
# This only SORTS + LABELS to help the human — it never auto-applies/auto-dismisses anything (propose-never-apply).
now="$(date +%s)"
age_days="${RSDD_RETRO_AGE_DAYS:-7}"   # ESCALATE pending items older than this many days (override via env)
# Grace window — MISSING-RETRO is suppressed while the newest block is within this many hours
# of NOW, tolerating a run whose retro has not yet been committed (still in-flight). Once the
# block has been sitting idle longer than the window, the gap is genuine and surfaces.
# Default: 24h. Override via env: RSDD_MISSING_RETRO_GRACE_HOURS=4
grace_hours="${RSDD_MISSING_RETRO_GRACE_HOURS:-24}"
case "$grace_hours" in
  ''|*[!0-9]*) echo "WARN: RSDD_MISSING_RETRO_GRACE_HOURS='$grace_hours' is not a non-negative integer — using default 24h" >&2
               grace_hours=24;;
esac
grace_secs=$(( grace_hours * 3600 ))
pending=0; missing=0; total=0
absent_targets=0   # count of target dirs not found on disk (§7 absent-input disclosure)
pending_rows=()   # collected as "<epoch>\t<f>\t<p>\t<deltas>\t<status>\t<age_d>\t<tag>" for oldest-first sort
# Resolve retros RECURSIVELY with the SAME predicate the MISSING-RETRO fleet pass below uses
# (find "$p" -path '*/retros/*.md'), so a nested-corpus target that keeps its retros deeper (e.g.
# <target>/research/retros/*.md) is walked here too — a flat "$p/retros/*.md" glob would miss them and
# the two passes in this file would contradict each other. DEDUP by canonical path so a retro reachable
# under more than one listed target (overlapping $paths) or via more than one location is counted once.
# Index/manifest files (RETROS-INDEX.md / *-INDEX.md) are EXCLUDED (-not -iname '*index*.md'): they are
# generated tables of contents, not proposals — counting one as a retro surfaced it as '~0 proposed deltas
# · status none' (three.js). Both this pass and the MISSING-RETRO pass below carry the same exclusion.
declare -A rsdd_seen_retro=()
for p in $paths; do
  # Anti-silent-zero §7: distinguish absent-input from empty-input from no-match.
  if [ ! -d "$p" ]; then
    echo "INFO: corpus not found (absent-input): $p"
    absent_targets=$((absent_targets + 1))
    continue
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    key="$(realpath -- "$f" 2>/dev/null || printf '%s' "$f")"
    [ -n "${rsdd_seen_retro[$key]:-}" ] && continue
    rsdd_seen_retro[$key]=1
    # Skip files that explicitly opt out of §18 supervision (see lib/retro-status.sh:
    # retro_is_excluded). These are not §18 kit retros — e.g. client-feedback retros placed under
    # corpus/retros/. Opt-out marker fails noisily (missing → file surfaces), not silently.
    retro_is_excluded "$f" && continue
    total=$((total + 1))
    # Honor the marker only in the retro's LEADING HTML-comment block (see lib/retro-status.sh):
    # a marker-shaped string in the body or in heading/comment prose must not exclude an un-reviewed retro.
    status=$(retro_review_status "$f")
    case "$status" in
      applied|dismissed) continue ;;
    esac
    # Warn on any status word that is neither a known open state nor a closing word.
    # 'pending' and an absent marker are normal open states; do not warn on those.
    # Only 'applied' and 'dismissed' close a retro — no synonyms, no widening the vocabulary.
    case "$status" in
      ""|pending) ;;
      *) echo "WARN: unrecognized review-status '${status}' in $(basename "$f") — only 'applied' or 'dismissed' close a retro" ;;
    esac
    pending=$((pending + 1))
    # Count proposed deltas — SECTION-SCOPED, doctrine-first (see retro.template.md).
    # THE LOAD-BEARING INVARIANT: a retro with any delta indicator never reports confident 0.
    #
    # THREE COUNTING FORMS (precedence: form 1 > form 2 > form 3):
    #   FORM 1 — canonical section + TABLE: count non-separator data rows (ID-agnostic).
    #   FORM 2 — canonical section + no table: count delta-ENTRY ###-headings.
    #            Delta-entry heading = separator-shaped: has em-dash/en-dash after short
    #            token (e.g. "### D1 — ...", "### DELTA-1 — ...", "### PN-A — ...").
    #            Structural headings (### Rationale, ### Evidence, ### Dedup) have no
    #            em-dash and are not counted. Bug guard: section exit uses /^##[^#]/ (not
    #            /^##/), so ### headings do NOT exit the section prematurely.
    #   FORM 3 — no canonical section: count "## Delta "-prefixed separator-shaped ##-headings
    #            (e.g. "## Delta W1 — ...", "## Delta SO1 — ...", "## Delta 1 — ...").
    #
    # WARN CASES (counted as "?"):
    #   WARN-A: canonical section found, no table (form 1), no delta-entry sub-headings (form 2)
    #           → "delta section present but not in countable form — count by hand"
    #   WARN-B: no canonical section, no "## Delta"-headed deltas (form 3), but non-canonical
    #           indicators present (per-delta headings without "## Delta" prefix, letter+digit,
    #           bare-number headings) → "non-conforming delta declaration — count by hand"
    #
    # CANONICAL HEADING SET (tolerant, case-insensitive):
    #   "## [N. ] Proposed kit delta[s][ (...)| EOL]"  (tightened: excludes "verdict" etc.)
    #   "## Proposed delta[s][...]"
    #   "## Delta proposals[...]"
    #   "## Deltas NUEVOS[...]"
    _sec_r=$(awk '
      BEGIN { in_sec=0; found=0; rows=0; h3d=0; d3=0 }
      { low=tolower($0) }
      low ~ /^## ([0-9]+\. )?proposed kit delta[s]?([[:space:]]*\(|[[:space:]]*$)/ ||
      low ~ /^## proposed delta/                                                     ||
      low ~ /^## delta proposals/                                                    ||
      low ~ /^## deltas nuevos/                                                      { in_sec=1; found=1; next }
      /^##[^#]/ && in_sec { in_sec=0 }
      in_sec && /^\|/ && $0 !~ /^\|[-: |]+\|?[[:space:]]*$/ { rows++ }
      in_sec && /^###[^#]/ && /—/ { h3d++ }
      !in_sec && low ~ /^## delta / && /—/ { d3++ }
      END {
        data = (rows > 0) ? rows - 1 : 0
        if (found) {
          if      (data  > 0) print found+0 ":1:" data+0
          else if (h3d   > 0) print found+0 ":2:" h3d+0
          else                print found+0 ":w:0"
        } else {
          if (d3 > 0) print "0:3:" d3+0
          else        print "0:n:0"
        }
      }
    ' "$f")
    _sec_found="${_sec_r%%:*}"
    _sec_rest="${_sec_r#*:}"; _sec_form="${_sec_rest%%:*}"; _sec_cnt="${_sec_rest##*:}"
    delta_warn=""
    if [ "$_sec_found" = 1 ]; then
      case "$_sec_form" in
        1|2) deltas="$_sec_cnt" ;;                          # form 1 (table) or form 2 (### entries)
        *)   delta_warn="delta section present but not in countable form — count by hand"
             deltas="?" ;;                                  # WARN-A: canonical section, pure prose
      esac
    else
      case "$_sec_form" in
        3)   deltas="$_sec_cnt" ;;                          # form 3 (## Delta-prefixed headings)
        *)   # WARN-B or confident zero — check for non-canonical indicators
             if grep -qiE '^#{2,3}[[:space:]]+(Proposed|Delta|Deltas)' "$f" 2>/dev/null \
                || grep -qiE '^#{1,3}[[:space:]]+([A-Za-z][0-9]+|[0-9]+)([[:space:].—–-]|$)' "$f" 2>/dev/null; then
               delta_warn="non-conforming delta declaration — count by hand"
               deltas="?"                                   # WARN-B
             else
               deltas=0                                     # confident zero — no indicators at all
             fi
             ;;
      esac
    fi
    unset _sec_r _sec_found _sec_rest _sec_form _sec_cnt
    # Age from the git FIRST-COMMIT date of THIS file under its CURRENT path (when it entered review
    # under that name), falling back to file mtime when the file is untracked or the dir is not a git
    # repo — so a non-git target never crashes the sweep.
    # NO --follow: rename-following is 15x slower per call (measured: 0.405s/call with --follow vs
    # 0.027s/call without, on a 526-commit / 473-file target) and this sweep makes hundreds of these
    # calls per run — with --follow the sweep took ~200s and was killed by the session-start hook's
    # 30s timeout, surfacing nothing. Accepted tradeoff: a file RENAMED after creation is now dated
    # from its rename commit, not its original creation — rare for retro/block files (they are not
    # routinely renamed post-creation), and a sweep that never completes is worse than an occasionally
    # later "added" date.
    epoch=""
    added="$(git -C "$p" log --diff-filter=A --format=%aI -1 -- "$f" 2>/dev/null)"
    [ -n "$added" ] && epoch="$(date -d "$added" +%s 2>/dev/null || echo '')"
    [ -n "$epoch" ] || epoch="$(stat -c %Y "$f" 2>/dev/null || echo "$now")"
    age_s=$(( now - epoch )); [ "$age_s" -lt 0 ] && age_s=0
    age_d=$(( age_s / 86400 ))
    tag=""; [ "$age_d" -gt "$age_days" ] && tag="  ·  ESCALATED (aged ${age_d}d)"
    # Use \x1f (ASCII Unit Separator) as field delimiter — it is not a whitespace IFS character,
    # so consecutive delimiters (e.g. when $tag and/or $delta_warn are empty) are NOT collapsed
    # by IFS splitting in `read`.  A plain tab as IFS is whitespace: two consecutive tabs become
    # one separator and the empty $tag field disappears, shifting $delta_warn into the tag slot.
    pending_rows+=("$(printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
      "$epoch" "$f" "$p" "${deltas:-?}" "${status:-none}" "$age_d" "$tag" "$delta_warn")")
  done < <(find "$p" -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*' -not -iname '*index*.md' 2>/dev/null)
done

# Print the pending queue oldest-first (smallest first-commit epoch on top) so the most-stale proposals lead.
if [ "${#pending_rows[@]}" -gt 0 ]; then
  while IFS=$'\x1f' read -r _ep f p deltas status age_d tag delta_warn; do
    echo "PENDING  $f"
    echo "         target: $p  ·  ~${deltas} proposed deltas  ·  status: ${status}  ·  age: ${age_d}d${tag}"
    [ -n "$delta_warn" ] && echo "         WARN: ${delta_warn}"
  done < <(printf '%s\n' "${pending_rows[@]}" | sort -n -t$'\x1f' -k1,1)
fi

echo ""
echo "Summary: ${pending} pending / ${total} retros across targets."
if [ "$absent_targets" -gt 0 ]; then
  echo "INFO: ${absent_targets} target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above."
fi
if [ "$skipped_count" -gt 0 ]; then
  echo "WARN: ${skipped_count} target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: ${skipped_names}"
fi
if [ "$pending" -gt 0 ]; then
  echo "For each PENDING retro: review it, apply or dismiss its deltas in the kit,"
  echo "then set the top marker to '<!-- review-status: applied <date> · kit <sha> -->'."
  echo "Note: the count above tracks the review-status MARKER, not whether each delta is open work."
  echo "A kit commit may have applied a delta without flipping the marker — an ESCALATED retro is worth"
  echo "verifying against the kit before treating its full delta count as unresolved."
fi

# --- MISSING-RETRO fleet pass (Feature #25b): a run that ADVANCED the corpus but produced NO fresh retro
# lost that run's feedback. For each resolvable target, compare the newest BLOCK's date against the newest
# RETRO's date using the SAME date source for both (git FIRST-COMMIT/added epoch, fallback to file mtime when
# untracked) — a like-for-like comparison, so a block ADDED after the newest retro means the corpus advanced
# past it. (A mixed git-commit-vs-mtime comparison would fire on almost every git target — any unrelated commit
# is newer than a checkout mtime — so the added-date of the block itself is the signal.) PURE DETECTION — it
# only FLAGS the gap for the human; it never auto-generates a retro (propose-never-apply). Reuses the same
# $paths derivation (truncated '...' paths already skipped + WARNed above).
rsdd_added_epoch() {  # <repo-dir> <file> → git first-commit(added, under CURRENT path — no --follow,
  # see the rename tradeoff note above rsdd's sibling lookup) epoch if tracked, else file mtime, else 0
  local d="$1" f="$2" e
  e="$(git -C "$d" log --diff-filter=A --format=%ct -1 -- "$f" 2>/dev/null)"
  [ -n "$e" ] || e="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  printf '%s' "$e"
}
waived_count=0; waived_names=""   # targets with a retro-waived marker; suppressed from MISSING-RETRO
for p in $paths; do
  if [ ! -d "$p" ]; then continue; fi   # already disclosed as absent-input in the pending pass above
  # Scan this target's retros/ for a retro-waived marker before doing the advancement check.
  # A waived target acknowledges a deliberate decision not to reconstruct a retro for a dormant
  # run — typically placed as <target>/retros/retro-waived.md carrying both '<!-- kit-retro:
  # exclude -->' (so the pending pass skips it) and '<!-- retro-waived: <date> · <reason> -->'.
  _p_is_waived=0
  while IFS= read -r _wf; do
    [ -n "$_wf" ] || continue
    if retro_is_waived "$_wf"; then _p_is_waived=1; break; fi
  done < <(find "$p" -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*' 2>/dev/null)
  if [ "$_p_is_waived" = 1 ]; then
    waived_count=$((waived_count + 1))
    waived_names="${waived_names:+$waived_names, }$p"
    continue   # suppress MISSING-RETRO for this target
  fi
  nr=0   # newest retro added-date under this target
  while IFS= read -r rf; do
    [ -n "$rf" ] || continue
    # Skip excluded files so a client-artifact retro does not set nr and suppress MISSING-RETRO.
    retro_is_excluded "$rf" && continue
    m="$(rsdd_added_epoch "$p" "$rf")"; [ "${m:-0}" -gt "$nr" ] && nr="$m"
  done < <(find "$p" -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*' -not -iname '*index*.md' 2>/dev/null)
  nb=0   # newest block added-date under this target (gen-catalog's block/bloque discriminator)
  while IFS= read -r bf; do
    [ -n "$bf" ] || continue
    m="$(rsdd_added_epoch "$p" "$bf")"; [ "${m:-0}" -gt "$nb" ] && nb="$m"
  done < <(find "$p" -type f -name '*.md' 2>/dev/null | grep -E '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$')
  # Only meaningful when the corpus has blocks (nb>0) and the block is newer than the retro
  # (nb>nr — the corpus genuinely advanced past it). Fire when the newest block is itself older
  # than the grace window measured from NOW: the run has been idle long enough that any in-flight
  # retro would already have been committed. This is a time-from-now tolerance, not a
  # time-between-block-and-retro threshold — the old nb > nr + grace_secs form granted permanent
  # amnesty to any block that landed within the window of the retro's epoch, silencing the alert
  # forever even years later.
  if [ "$nb" -gt 0 ] && [ "$nb" -gt "$nr" ] && [ "$now" -gt "$(( nb + grace_secs ))" ]; then
    echo "MISSING-RETRO: $p advanced with no retro for the latest run"
    missing=$((missing+1))
  fi
done
# Report waived targets in summary so the suppression is never invisible.
if [ "$waived_count" -gt 0 ]; then
  echo "waived: ${waived_count} target(s) — MISSING-RETRO suppressed: ${waived_names}"
fi
# Clean-verdict sentinel — relocated AFTER the MISSING-RETRO pass so the whole run is
# visible before the claim. Gated on missing==0 (no MISSING-RETRO findings) AND
# skipped_count==0 (not a PARTIAL sweep) in addition to pending==0. Any of the three
# signals being non-zero means the fleet has not been fully and cleanly inspected.
if [ "$pending" -eq 0 ] && [ "$missing" -eq 0 ] && [ "$skipped_count" -eq 0 ]; then
  echo "Nothing to review."
fi
