#!/usr/bin/env bash
# sweep-audits.sh — surface un-reviewed §13 audit reports across ALL research-sdd targets, so no
# audit-delta (certainty or coverage) sits unacted-upon (METHODOLOGY §13). Mirror of sweep-retros.sh.
#
# An audit under <target>/audits/*.md is PENDING unless its top carries a marker:
#   <!-- review-status: applied ... -->   or   <!-- review-status: dismissed ... -->
# The maintainer runs this (manually or on a schedule) from anywhere; it reads the target list from
# the kit's TARGETS.md. Read-only: it never edits anything. Audits act on the TARGET (§14 corrections
# into the corpus + §8 backlog seeds), so — unlike retros — there is NO stage/branch/PR path here.
#
# Usage: research-sdd/toolbelt/sweep-audits.sh

KIT="$(cd "$(dirname "$0")/.." && pwd)"
TARGETS_MD="$KIT/TARGETS.md"

# Reuse the retro marker reader — its leading-comment-block scan is generic (retro-status.sh:23-36),
# so it reads an audit's '<!-- review-status: ... -->' marker identically. Single source of truth.
LIB="$(cd "$(dirname "$0")" && pwd)/lib/retro-status.sh"
if [ ! -f "$LIB" ]; then
  echo "sweep-audits: cannot find helper $LIB" >&2
  exit 1
fi
# shellcheck source=lib/retro-status.sh
. "$LIB"
# Fail closed: existence of $LIB is not enough — the source must have DEFINED the reader. No `set -e`
# here, so a failed/partial source would otherwise be swallowed and every audit read as 'none'.
declare -F retro_review_status >/dev/null 2>&1 || { echo "sweep-audits: helper $LIB failed to define retro_review_status" >&2; exit 1; }

if [ ! -f "$TARGETS_MD" ]; then
  echo "sweep-audits: cannot find $TARGETS_MD" >&2
  exit 1
fi

# Absolute target paths live in the TARGETS.md table as backtick-wrapped paths.
# Truncated ones (contain '...') can't be resolved to a real dir, so they're dropped from the
# sweep — but COLLECT them so the summary can WARN that it is PARTIAL instead of reading complete.
all_paths=$(grep -oE '`/[^`]+`' "$TARGETS_MD" 2>/dev/null | tr -d '`' | sort -u)
paths=$(printf '%s\n' "$all_paths" | grep -v '\.\.\.')
skipped=$(printf '%s\n' "$all_paths" | grep '\.\.\.')

skipped_names=""; skipped_count=0
for s in $skipped; do
  skipped_count=$((skipped_count + 1))
  skipped_names="${skipped_names:+$skipped_names, }$(basename "$s")"
done

# AGING (Feature #26): each PENDING audit is AGED from its git FIRST-COMMIT (added) date so a stale audit
# can't sit unacted-upon; the queue is REORDERED oldest-first and items past a threshold are TAGGED ESCALATED.
# This only SORTS + LABELS to help the human — it never auto-applies/auto-dismisses anything (propose-never-apply).
now="$(date +%s)"
age_days="${RSDD_RETRO_AGE_DAYS:-7}"   # ESCALATE pending items older than this many days (override via env)
pending=0; total=0
pending_rows=()   # collected as "<epoch>\t<f>\t<p>\t<claims>\t<status>\t<age_d>\t<tag>" for oldest-first sort
# Resolve audits RECURSIVELY (find "$p" -path '*/audits/*.md'), mirroring sweep-retros.sh's retro pass, so a
# nested-corpus target that keeps its audits deeper (e.g. <target>/research/audits/*.md) is walked here too —
# a flat "$p/audits/*.md" glob would miss them. DEDUP by canonical path so an audit reachable under more than
# one listed target (overlapping $paths) or via more than one location is counted once. Index/manifest files
# (AUDITS-INDEX.md / *-INDEX.md) are EXCLUDED (-not -iname '*index*.md'): they are generated tables of
# contents, not audit reports — counting one as an audit would surface it as a bogus '~0 audited claims' item.
declare -A rsdd_seen_audit=()
for p in $paths; do
  [ -d "$p" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    key="$(realpath -- "$f" 2>/dev/null || printf '%s' "$f")"
    [ -n "${rsdd_seen_audit[$key]:-}" ] && continue
    rsdd_seen_audit[$key]=1
    total=$((total + 1))
    # Honor the marker only in the audit's LEADING HTML-comment block (see lib/retro-status.sh);
    # a missing marker reads as pending, same as retros.
    status=$(retro_review_status "$f")
    case "$status" in
      applied|dismissed) continue ;;
    esac
    pending=$((pending + 1))
    claims=$(grep -cE '^\| *[0-9]+ \|' "$f" 2>/dev/null)
    # Age from the git FIRST-COMMIT date of THIS file, falling back to file mtime when untracked or the dir
    # is not a git repo — so a non-git target never crashes the sweep.
    epoch=""
    added="$(git -C "$p" log --follow --diff-filter=A --format=%aI -1 -- "$f" 2>/dev/null)"
    [ -n "$added" ] && epoch="$(date -d "$added" +%s 2>/dev/null || echo '')"
    [ -n "$epoch" ] || epoch="$(stat -c %Y "$f" 2>/dev/null || echo "$now")"
    age_s=$(( now - epoch )); [ "$age_s" -lt 0 ] && age_s=0
    age_d=$(( age_s / 86400 ))
    tag=""; [ "$age_d" -gt "$age_days" ] && tag="  ·  ESCALATED (aged ${age_d}d)"
    pending_rows+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$epoch" "$f" "$p" "${claims:-?}" "${status:-none}" "$age_d" "$tag")")
  done < <(find "$p" -maxdepth 4 -path '*/audits/*.md' -not -path '*/.git/*' -not -iname '*index*.md' 2>/dev/null)
done

# Print the pending queue oldest-first (smallest first-commit epoch on top) so the most-stale audits lead.
if [ "${#pending_rows[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r _ep f p claims status age_d tag; do
    echo "PENDING  $f"
    echo "         target: $p  ·  ~${claims} audited claims  ·  status: ${status}  ·  age: ${age_d}d${tag}"
  done < <(printf '%s\n' "${pending_rows[@]}" | sort -n -t$'\t' -k1,1)
fi

echo ""
echo "Summary: ${pending} pending / ${total} audits across targets."
if [ "$skipped_count" -gt 0 ]; then
  echo "WARN: ${skipped_count} target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: ${skipped_names}"
fi
if [ "$pending" -eq 0 ]; then
  echo "Nothing to review."
else
  echo "For each PENDING audit: apply §14 corrections (REFUTED/DOWNGRADED) into the corpus + seed"
  echo "coverage gaps into the §8 backlog, then flip the marker to"
  echo "'<!-- review-status: applied <date> · kit <sha> -->' (or 'dismissed')."
fi
