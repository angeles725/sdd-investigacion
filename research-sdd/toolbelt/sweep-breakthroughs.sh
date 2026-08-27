#!/usr/bin/env bash
# sweep-breakthroughs.sh — WARN-only checker for the Breakthrough Ledger (METHODOLOGY §22).
#
# Reads every target corpus from TARGETS.md via lib/target-paths.sh, finds blocks carrying
# the **Breakthrough:** marker, cross-checks against BREAKTHROUGHS.md, and WARNs on:
#   · a block tagged but absent from BREAKTHROUGHS.md (unindexed breakthrough)
#   · a BREAKTHROUGHS.md row whose block no longer carries the marker (drift)
# At INFO: a corpus with ZERO tagged breakthroughs (expected while back-fill is pending).
#
# Anti-silent-zero §7: three states are ALWAYS distinct:
#   absent-input  — corpus directory not found
#   empty-input   — corpus found, 0 block files
#   no-match      — block files exist, 0 carry the marker
#
# RECOGNIZED marker form (METHODOLOGY §22.1 / block.template.md):
#   A header-blockquote line matching: ^>[[:space:]]*\*\*Breakthrough:\*\*
# EXPLICITLY EXCLUDED (not the marker):
#   · prose signals: "HITO", "the pivot", "the decisive negative"
#   · informal bare "BREAKTHROUGH" (caps in body text — not the structured field)
#   · any "Breakthrough" occurrence NOT in the blockquote field position (not matching above)
#
# Exit 1 ONLY on OPERATIONAL failure (TARGETS.md or BREAKTHROUGHS.md missing; a lib helper
# that failed to define its function). A finding (WARN or INFO) NEVER fails the run.
# Read-only: it never edits any corpus or the ledger (propose-never-apply §8).
#
# Usage: research-sdd/toolbelt/sweep-breakthroughs.sh

KIT="$(cd "$(dirname "$0")/.." && pwd)"
TARGETS_MD="$KIT/TARGETS.md"
BREAKTHROUGHS_MD="$KIT/BREAKTHROUGHS.md"

# Shared target-path derivation (handles /abs and $RESEARCH_HOME/... forms).
_sb_tp_lib="$(cd "$(dirname "$0")" && pwd)/lib/target-paths.sh"
if [ ! -f "$_sb_tp_lib" ]; then
  echo "sweep-breakthroughs: cannot find helper $_sb_tp_lib" >&2; exit 1
fi
# shellcheck source=lib/target-paths.sh
. "$_sb_tp_lib"
# Fail closed: source must DEFINE the function — a partial source is otherwise swallowed.
declare -F target_paths_all >/dev/null 2>&1 || {
  echo "sweep-breakthroughs: helper $_sb_tp_lib failed to define target_paths_all" >&2; exit 1
}
unset _sb_tp_lib

if [ ! -f "$TARGETS_MD" ]; then
  echo "sweep-breakthroughs: cannot find $TARGETS_MD" >&2
  exit 1
fi

if [ ! -f "$BREAKTHROUGHS_MD" ]; then
  echo "sweep-breakthroughs: cannot find $BREAKTHROUGHS_MD" >&2
  exit 1
fi

# Absolute target paths from TARGETS.md; truncated '...' entries pass through for PARTIAL WARN.
all_paths=$(target_paths_all "$TARGETS_MD")
paths=$(printf '%s\n' "$all_paths" | grep -v '\.\.\.')
skipped=$(printf '%s\n' "$all_paths" | grep '\.\.\.')
# ANTI-SILENT-ZERO: zero usable paths is a loud error, not a silent empty run.
if [ -z "$paths" ]; then
  echo "sweep-breakthroughs: ERROR — no usable target paths in $TARGETS_MD" >&2
  echo "sweep-breakthroughs: check TARGETS.md has backtick-wrapped absolute or \$RESEARCH_HOME/... paths" >&2
  exit 1
fi

skipped_names=""; skipped_count=0
for s in $skipped; do
  skipped_count=$((skipped_count + 1))
  skipped_names="${skipped_names:+$skipped_names, }$(basename "$s")"
done

# ---------------------------------------------------------------------------
# Parse BREAKTHROUGHS.md ledger: extract block path:line pointers from the "how" column.
# Table: | # | target | what (cracked) | how — block `path:line` | memory — engram topic-key |
# Column positions (awk -F'|'): $1=empty $2=# $3=target $4=what $5=how $6=memory
# Skip: header rows (first cell is '#'), separator rows (|---|...|), skeleton rows (first cell is '—').
# ---------------------------------------------------------------------------
ledger_pointers=$(
  grep -E '^\|' "$BREAKTHROUGHS_MD" 2>/dev/null \
    | grep -vE '^\|[[:space:]]*[-:]+[[:space:]]*\|' \
    | awk -F'|' '
      {
        c1 = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c1)
        # Skip header (#), placeholder/skeleton (—), separator, or empty first cell
        if (c1 == "#" || c1 == "\342\200\224" || c1 == "-" || c1 == "" || c1 == "—") next
        how = $5
        # Extract backtick-wrapped path:line pointer: `anything:digits`
        if (match(how, /`[^`]+:[0-9]+`/)) {
          ptr = substr(how, RSTART + 1, RLENGTH - 2)
          print ptr
        }
      }
    '
)

# ---------------------------------------------------------------------------
# Fleet pass: scan each corpus for tagged blocks
# ---------------------------------------------------------------------------
total_tagged=0
warn_unindexed=0
warn_drift=0

for p in $paths; do
  # Anti-silent-zero §7: distinguish absent-input from empty-input from no-match.
  if [ ! -d "$p" ]; then
    echo "INFO: corpus not found (absent-input): $p"
    continue
  fi

  # Find block files using the gen-catalog discriminator (block|bloque).
  # Build array from find output using process substitution to avoid trailing-newline issues.
  block_files=()
  while IFS= read -r bf; do
    [ -n "$bf" ] && block_files+=("$bf")
  done < <(find "$p" -type f -name '*.md' 2>/dev/null \
             | grep -E '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' \
             | sort)

  if [ "${#block_files[@]}" -eq 0 ]; then
    echo "INFO: corpus exists, no block files (empty-input): $p"
    continue
  fi

  # Walk block files; detect the recognized marker.
  corpus_tagged=0
  for bf in "${block_files[@]}"; do
    # Recognized marker: header-blockquote line ^>[[:space:]]*\*\*Breakthrough:\*\*
    # grep -q: exit 0 if found, 1 if not — do NOT add || true (converts grep error to silent zero).
    if grep -qE '^>[[:space:]]*\*\*Breakthrough:\*\*' "$bf" 2>/dev/null; then
      lineno=$(grep -nE '^>[[:space:]]*\*\*Breakthrough:\*\*' "$bf" 2>/dev/null \
                 | head -1 | cut -d: -f1)
      corpus_tagged=$((corpus_tagged + 1))
      total_tagged=$((total_tagged + 1))
      # Check if this block is indexed in BREAKTHROUGHS.md.
      # Match by checking if the ledger contains the block's absolute path and line number.
      if ! printf '%s\n' "$ledger_pointers" | grep -qF "${bf}:${lineno}" 2>/dev/null; then
        echo "WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: ${bf}:${lineno}"
        warn_unindexed=$((warn_unindexed + 1))
      fi
    fi
  done

  if [ "$corpus_tagged" -eq 0 ]; then
    # no-match: block files exist but none carry the marker (expected during back-fill)
    echo "INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): $p"
  fi
done

# ---------------------------------------------------------------------------
# Drift pass: check every ledger row's block still carries the marker.
# ---------------------------------------------------------------------------
if [ -n "$ledger_pointers" ]; then
  while IFS= read -r ptr; do
    [ -n "$ptr" ] || continue
    # ptr format: "path:lineno" — split on the last colon to recover the path.
    bfile="${ptr%:*}"
    if [ ! -f "$bfile" ]; then
      echo "WARN: drift — indexed block file no longer exists: $bfile (from BREAKTHROUGHS.md)"
      warn_drift=$((warn_drift + 1))
    elif ! grep -qE '^>[[:space:]]*\*\*Breakthrough:\*\*' "$bfile" 2>/dev/null; then
      echo "WARN: drift — indexed block no longer carries the **Breakthrough:** marker: $ptr (from BREAKTHROUGHS.md)"
      warn_drift=$((warn_drift + 1))
    fi
  done <<< "$ledger_pointers"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Summary: ${total_tagged} tagged breakthrough(s) across corpora · ${warn_unindexed} unindexed · ${warn_drift} drifted."
if [ "$skipped_count" -gt 0 ]; then
  echo "WARN: ${skipped_count} target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: ${skipped_names}"
fi
if [ "$warn_unindexed" -eq 0 ] && [ "$warn_drift" -eq 0 ] && [ "$skipped_count" -eq 0 ]; then
  echo "Ledger consistent — all tagged breakthroughs indexed, no drift."
fi
if [ "$warn_unindexed" -gt 0 ]; then
  echo "For each unindexed breakthrough: add a row to BREAKTHROUGHS.md with the block path:line pointer."
fi
if [ "$warn_drift" -gt 0 ]; then
  echo "For each drifted row: verify the block still exists and carries the **Breakthrough:** field; update or remove the ledger row."
fi
