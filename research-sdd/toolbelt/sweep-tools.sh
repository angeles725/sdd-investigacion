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

# Library-module predicate: a file under tools/ is a LIBRARY MODULE (not a standalone
# tool) when it lives under a *_lib/ directory or inside a Python package sub-directory
# (i.e., a sub-directory of tools/ that contains __init__.py).
# §7 Part A: library modules are DISCLOSED separately — never silently dropped from the
# headline count. The discriminator is directory structure, not extension.
# SENTINEL: is_lib_module *_lib check — change return 0 to return 1 to test tooth E
is_lib_module() {
  local f="$1" tools_dir="$2"
  local rel="${f#$tools_dir/}"
  local dir_part
  dir_part="$(dirname "$rel")"
  # Walk directory components from tools/ root: if any component ends with _lib, it is a
  # library directory whose contents are import-only package internals, not standalone tools.
  while [ "$dir_part" != "." ] && [ -n "$dir_part" ]; do
    case "$(basename "$dir_part")" in *_lib) return 0 ;; esac
    dir_part="$(dirname "$dir_part")"
  done
  # Also: if the file's immediate parent directory (other than tools/ itself) contains an
  # __init__.py, it is a Python package internal — not a standalone tool.
  local parent
  parent="$(dirname "$f")"
  if [ "$parent" != "$tools_dir" ] && [ -f "$parent/__init__.py" ]; then
    return 0
  fi
  return 1
}

total_tools=0; total_retro_recorded=0; total_ledger_recorded=0; total_unrecorded=0
targets_checked=0; absent_targets=0

for p in $paths; do
  [ -n "$p" ] || continue
  # Anti-silent-zero §7 Part B: distinguish absent-input from empty-input from no-match.
  # Mirror sweep-audits.sh three-state exactly — no token filtering (slugs disclosed as absent).
  # SENTINEL: absent-input — remove the next 4 lines to test tooth F
  if [ ! -d "$p" ]; then
    echo "INFO: corpus not found (absent-input): $p"
    absent_targets=$((absent_targets + 1))
    continue
  fi
  targets_checked=$((targets_checked + 1))
  name="$(basename "$p")"

  if [ ! -d "$p/tools" ]; then
    printf 'TARGET  %s\n' "$name"
    printf '        INFO: no tools/ directory (empty-input)\n'
    continue
  fi

  tool_files=(); lib_module_files=(); predicate_rejects=0; all_files=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    all_files=$((all_files + 1))
    if is_tool_file "$f"; then
      # §7 Part A: split tool files into top-level tools vs library modules so the headline
      # count reflects only standalone tools. Library modules are disclosed separately.
      if is_lib_module "$f" "$p/tools"; then
        lib_module_files+=("$f")
      else
        tool_files+=("$f")
      fi
    else
      predicate_rejects=$((predicate_rejects + 1))
    fi
  done < <(find "$p/tools" -type f -not -path '*/node_modules/*' -not -path '*/__pycache__/*' -not -path '*/.venv/*' -not -path '*/.git/*' 2>/dev/null | sort)

  printf 'TARGET  %s\n' "$name"
  if [ "$all_files" -eq 0 ]; then
    printf '        INFO: tools/ directory exists but is empty (empty-input)\n'
    continue
  fi

  ntools=${#tool_files[@]}
  nlib=${#lib_module_files[@]}

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
  # Recording loop iterates TOP-LEVEL tools only: library modules are package internals and
  # are not expected to have individual T-rows. (§7 Part A: their count is disclosed above.)
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
  [ "$nlib" -gt 0 ] && \
    printf ' (%d library module(s) not counted as tools)' "$nlib"
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
if [ "$absent_targets" -gt 0 ]; then
  echo "INFO: ${absent_targets} target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above."
fi
if [ "$skipped_count" -gt 0 ]; then
  echo "WARN: ${skipped_count} target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: ${skipped_names}"
fi
