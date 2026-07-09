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

if [ ! -f "$TARGETS_MD" ]; then
  echo "sweep-retros: cannot find $TARGETS_MD" >&2
  exit 1
fi

# Absolute target paths live in the TARGETS.md table as backtick-wrapped paths.
# Skip truncated ones (contain '...') — they can't be resolved.
paths=$(grep -oE '`/[^`]+`' "$TARGETS_MD" 2>/dev/null | tr -d '`' | grep -v '\.\.\.' | sort -u)

pending=0; total=0
for p in $paths; do
  d="$p/retros"
  [ -d "$d" ] || continue
  for f in "$d"/*.md; do
    [ -e "$f" ] || continue
    total=$((total + 1))
    # Honor the marker only in the retro's LEADING HTML-comment block (see lib/retro-status.sh):
    # a marker-shaped string in the body or in heading/comment prose must not exclude an un-reviewed retro.
    status=$(retro_review_status "$f")
    case "$status" in
      applied|dismissed) continue ;;
    esac
    pending=$((pending + 1))
    deltas=$(grep -cE '^\| *[0-9]+ \|' "$f" 2>/dev/null)
    echo "PENDING  $f"
    echo "         target: $p  ·  ~${deltas:-?} proposed deltas  ·  status: ${status:-none}"
  done
done

echo ""
echo "Summary: ${pending} pending / ${total} retros across targets."
if [ "$pending" -eq 0 ]; then
  echo "Nothing to review."
else
  echo "For each PENDING retro: review it, apply or dismiss its deltas in the kit,"
  echo "then set the top marker to '<!-- review-status: applied <date> · kit <sha> -->'."
fi
