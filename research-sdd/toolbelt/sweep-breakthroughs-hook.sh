#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-breakthroughs.sh and emits its output as
# additionalContext so unindexed/drifted breakthroughs surface when the supervisor project opens.
# Default: SUMMARY mode — per-target absent-input INFO lines collapsed to one counted line.
# Pass --full to emit the complete sweep output unchanged (byte-identical to sweep script output).
# Wired from .claude/settings.json (SessionStart). Read-only. Twin of sweep-retros-hook.sh.
here="$(cd "$(dirname "$0")" && pwd)"

# Parse --full flag (any position).
_full=0
for _arg in "$@"; do
  case "$_arg" in --full) _full=1 ;; esac
done

out="$("$here/sweep-breakthroughs.sh" 2>&1)"; rc=$?

# Operational failure: the sweep could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="Research-SDD breakthroughs sweep could not run (exit $rc — check TARGETS.md and lib/ helper):"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg h "$hdr" --arg c "$out" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
  else
    printf '%s\n%s\n' "$hdr" "$out"
  fi
  exit 0
fi

# SUMMARY MODE (default): collapse per-target absent-input, empty-input, and no-match INFO
# lines to counted summaries.  (#974: keeps aggregate under the 8,000-char budget.)
# Anti-silent-zero §7: the three states are reported distinctly, never merged into one.
# --full passes the full sweep output through unchanged (byte-identical to sweep script output).
if [ "$_full" = 0 ]; then  # FULL-PASSTHROUGH-GUARD
  out="$(printf '%s\n' "$out" | awk '
    BEGIN { ei=0; nm=0 }

    # Drop individual per-target absent-input INFO lines — collapsed to aggregate below.
    /^INFO: corpus not found \(absent-input\):/ { next }

    # Count and drop per-target empty-input INFO lines — collapsed to summary at END.
    # Anti-silent-zero §7: distinct state from absent-input and no-match.
    /^INFO: corpus exists, no block files \(empty-input\):/ {
      ei++; next  # EMPTY-COLLAPSE-COUNT
    }

    # Count and drop per-target no-match INFO lines — collapsed to summary at END.
    # Anti-silent-zero §7: distinct state from absent-input and empty-input.
    /^INFO: no tagged breakthroughs in corpus \(no-match[^)]*\):/ {
      nm++; next  # NOMATCH-COLLAPSE-COUNT
    }

    # Aggregate absent-input line: swap the "see INFO lines above" pointer for --full hint.
    /^INFO: [0-9]+ target\(s\) not traversed \(absent-input\)/ {
      sub(/see INFO lines above\.?/, "run --full to list them.")
      print; next  # ABSENT-COLLAPSE-PRINT
    }

    # Everything else passes through unchanged.
    { print }

    # Emit the empty-input/no-match summary with the full counts of all per-target lines seen,
    # regardless of where they appeared relative to the absent aggregate line.
    # Combined when both > 0; separate lines otherwise (anti-silent-zero §7: each state distinct).
    END {
      if (ei > 0 && nm > 0) printf "INFO: %d corpus(es) empty-input, %d no-match — run --full to list them\n", ei, nm  # COMBINED-COLLAPSE-EMIT
      else if (ei > 0) printf "INFO: %d corpus(es) empty-input — run --full to list them\n", ei  # EMPTY-COLLAPSE-EMIT
      else if (nm > 0) printf "INFO: %d corpus(es) no-match — run --full to list them\n", nm  # NOMATCH-COLLAPSE-EMIT
    }
  ')"
fi

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD breakthrough ledger sweep (§22):\n"+$c)}}'
else
  # jq missing: fall back to a plain print (still shows in transcript).
  printf 'Research-SDD breakthrough ledger sweep (§22):\n%s\n' "$out"
fi
