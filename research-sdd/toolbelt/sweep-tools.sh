#!/usr/bin/env bash
# sweep-tools.sh — fleet tool census + ledger reconciler across all research-sdd targets.
# Reports tools under <target>/tools/ (recursive), how many are RECORDED in a T<N> row in
# any retro, and how many are UNRECORDED. Read-only: never edits anything.
# Usage: research-sdd/toolbelt/sweep-tools.sh

KIT="$(cd "$(dirname "$0")/.." && pwd)"
TARGETS_MD="$KIT/TARGETS.md"

# Shared target-path derivation (handles /abs and $RESEARCH_HOME/... forms).
LIB="$(cd "$(dirname "$0")" && pwd)/lib/target-paths.sh"
if [ ! -f "$LIB" ]; then
  echo "sweep-tools: cannot find helper $LIB" >&2; exit 1
fi
# shellcheck source=lib/target-paths.sh
. "$LIB"
# Fail closed: source must DEFINE the function — a partial source is otherwise swallowed.
declare -F target_paths_all >/dev/null 2>&1 || {
  echo "sweep-tools: helper $LIB failed to define target_paths_all" >&2; exit 1
}

if [ ! -f "$TARGETS_MD" ]; then
  echo "sweep-tools: cannot find $TARGETS_MD" >&2
  exit 1
fi

all_paths=$(target_paths_all "$TARGETS_MD")
paths=$(printf '%s\n' "$all_paths" | grep -v '\.\.\.' | grep -v '^$')
skipped=$(printf '%s\n' "$all_paths" | grep '\.\.\.' | grep -v '^$')

# ANTI-SILENT-ZERO: zero usable paths is a loud error, not a silent empty run.
if [ -z "$paths" ]; then
  echo "sweep-tools: ERROR — no usable target paths in $TARGETS_MD" >&2
  echo "sweep-tools: check TARGETS.md has backtick-wrapped absolute or \$RESEARCH_HOME/... paths" >&2
  exit 1
fi

skipped_names=""; skipped_count=0
for s in $skipped; do
  [ -n "$s" ] || continue
  skipped_count=$((skipped_count + 1))
  skipped_names="${skipped_names:+$skipped_names, }$(basename "$s")"
done

# Tool predicate: a file under tools/ is a TOOL when it has a known script extension
# OR has the executable bit set. Extensions: .py .sh .mjs .js .ts .ps1.
is_tool_file() {
  local f="$1"
  case "$f" in *.py|*.sh|*.mjs|*.js|*.ts|*.ps1) return 0 ;; esac
  [ -x "$f" ]
}

total_tools=0; total_retro_recorded=0; total_ledger_recorded=0; total_unrecorded=0; targets_checked=0

for p in $paths; do
  [ -n "$p" ] || continue
  [ -d "$p" ] || continue   # non-dir tokens (e.g. /mrdoob/three.js) skip — verify-registry.sh:76
  targets_checked=$((targets_checked + 1))
  name="$(basename "$p")"

  if [ ! -d "$p/tools" ]; then
    printf 'TARGET  %s\n' "$name"
    printf '        tools/: no tools directory\n'
    continue
  fi

  tool_files=(); predicate_rejects=0; all_files=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    all_files=$((all_files + 1))
    if is_tool_file "$f"; then
      tool_files+=("$f")
    else
      predicate_rejects=$((predicate_rejects + 1))
    fi
  done < <(find "$p/tools" -type f 2>/dev/null | sort)

  printf 'TARGET  %s\n' "$name"
  if [ "$all_files" -eq 0 ]; then
    printf '        tools/: directory exists but is empty\n'
    continue
  fi

  ntools=${#tool_files[@]}

  # Collect T-rows from every retro (same recursive find as sweep-retros.sh).
  t_rows=""; retros_found=0; retros_with_table=0
  while IFS= read -r rf; do
    [ -n "$rf" ] || continue
    retros_found=$((retros_found + 1))
    chunk=$(grep -E '^\| T[0-9]+' "$rf" 2>/dev/null || true)
    if [ -n "$chunk" ]; then
      retros_with_table=$((retros_with_table + 1))
      t_rows="${t_rows}${chunk}"$'\n'
    fi
  done < <(find "$p" -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*' \
            -not -iname '*index*.md' 2>/dev/null)

  # Parse tools/README.md ledger — the primary write-at-acquisition record (METHODOLOGY §10).
  # Three distinguishable states: none | no-table (unparseable) | parsed.
  ledger_file="$p/tools/README.md"
  ledger_status="none"; ledger_rows=""
  if [ -f "$ledger_file" ]; then
    # Collect all | lines that are NOT separator rows (|---|---|).
    ledger_rows=$(grep -E '^\|' "$ledger_file" 2>/dev/null \
      | grep -vE '^\|[[:space:]]*[-:]+[[:space:]]*\|' || true)
    if [ -z "$ledger_rows" ]; then
      ledger_status="no-table"
    else
      ledger_status="parsed"
    fi
  fi

  retro_recorded=0; ledger_recorded=0; unrecorded=0
  # BT: literal backtick for use in grep character classes (can't inline in double-quoted strings).
  BT=$'\x60'
  for tool in "${tool_files[@]}"; do
    base="$(basename "$tool")"
    in_retro=0; in_ledger=0
    [ -n "$t_rows" ] && printf '%s\n' "$t_rows" | grep -qF "$base" && in_retro=1
    # Boundary-aware ledger match: require a cell-start or path separator before the basename
    # so that `envelope.py` does not false-match inside `gf-envelope.py`.
    # Preceding boundary: backtick, pipe, slash, or space.  Trailing: same set plus colon.
    # SENTINEL: ledger match — change in_ledger=1 to in_ledger=0 to test tooth C
    base_re="${base//./\\.}"
    [ "$ledger_status" = "parsed" ] && \
      printf '%s\n' "$ledger_rows" | \
      grep -qE "(^|[${BT}|/ ])${base_re}([${BT}|/ :])" && in_ledger=1
    if [ "$in_retro" -eq 1 ]; then
      retro_recorded=$((retro_recorded + 1))
    elif [ "$in_ledger" -eq 1 ]; then
      ledger_recorded=$((ledger_recorded + 1))
    else
      unrecorded=$((unrecorded + 1))
    fi
  done

  total_tools=$((total_tools + ntools))
  total_retro_recorded=$((total_retro_recorded + retro_recorded))
  total_ledger_recorded=$((total_ledger_recorded + ledger_recorded))
  total_unrecorded=$((total_unrecorded + unrecorded))

  printf '        tools: %d found' "$ntools"
  [ "$predicate_rejects" -gt 0 ] && \
    printf ' (%d non-tool file(s) in tools/ not counted)' "$predicate_rejects"
  printf '\n'
  # Ledger unreadable: WARN separately and omit the ledger count (anti-silent-zero:
  # "recorded (ledger): 0" would be indistinguishable from "nobody wrote anything").
  if [ "$ledger_status" = "no-table" ]; then
    printf '        WARN: tools/README.md has no table — ledger unreadable\n'
    printf '        recorded (retro): %d  ·  unrecorded: %d' "$retro_recorded" "$unrecorded"
  else
    # ledger_status = none (0 is correct: no ledger = no ledger entries) or parsed.
    printf '        recorded (retro): %d  ·  recorded (ledger): %d  ·  unrecorded: %d' \
      "$retro_recorded" "$ledger_recorded" "$unrecorded"
  fi
  # Distinguish "no retros" from "retros exist but have no tools table".
  if [ "$retros_found" -eq 0 ]; then
    printf '  ·  no retros found'
  elif [ "$retros_with_table" -eq 0 ]; then
    printf '  ·  no retro has a tools table'
  fi
  printf '\n'
done

echo ""
echo "Summary: ${total_tools} tool(s) across ${targets_checked} target(s) · ${total_retro_recorded} recorded (retro) · ${total_ledger_recorded} recorded (ledger) · ${total_unrecorded} unrecorded."
if [ "$skipped_count" -gt 0 ]; then
  echo "WARN: ${skipped_count} target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: ${skipped_names}"
fi
