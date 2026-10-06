#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-audits.sh and emits its output as additionalContext so
# pending §13 audit reports surface when the supervisor project opens. Wired from
# .claude/settings.json (SessionStart). Read-only. Twin of sweep-retros-hook.sh.
# Default: SUMMARY mode — per-target absent-input INFO lines collapsed to one counted line.
# Pass --full to emit the complete sweep output unchanged (byte-identical to sweep script output).
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/hook-emit.sh
. "$here/lib/hook-emit.sh"

# Parse --full flag (any position).
_full=0
for _arg in "$@"; do
  case "$_arg" in --full) _full=1 ;; esac
done

out="$("$here/sweep-audits.sh" 2>&1)"; rc=$?

# Operational failure: the sweep could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="Research-SDD audits sweep could not run (exit $rc — check TARGETS.md and lib/ helper):"
  rsdd_hook_emit "$hdr" "$out"
  exit 0
fi

# SUMMARY MODE (default): collapse per-target absent-input and empty-input INFO lines to
# counted summaries.  (#974: keeps aggregate under the 8,000-char session budget.)
# --full passes the full sweep output through unchanged (byte-identical to sweep script output).
if [ "$_full" = 0 ]; then  # FULL-PASSTHROUGH-GUARD
  out="$(printf '%s\n' "$out" | awk '
    BEGIN { ei=0 }

    # Drop individual per-target absent-input INFO lines — collapsed to aggregate below.
    /^INFO: corpus not found \(absent-input\):/ { next }

    # Count and drop per-target empty-input INFO lines — collapsed to summary at END.
    # Anti-silent-zero §7: empty-input is a distinct state from absent-input and no-match.
    /^INFO: corpus exists, no audits found \(empty-input\):/ {
      ei++; next  # EMPTY-COLLAPSE-COUNT
    }

    # Aggregate absent-input line: swap the "see INFO lines above" pointer for --full hint.
    /^INFO: [0-9]+ target\(s\) not traversed \(absent-input\)/ {
      sub(/see INFO lines above\.?/, "run --full to list them.")
      print; next  # ABSENT-COLLAPSE-PRINT
    }

    # Everything else passes through unchanged.
    { print }

    # Emit the empty-input summary with the full count of all per-target lines seen,
    # regardless of where they appeared relative to the absent aggregate line.
    END {
      if (ei > 0) printf "INFO: %d corpus(es) empty-input — run --full to list them\n", ei  # EMPTY-COLLAPSE-EMIT
    }
  ')"
fi

rsdd_hook_emit "Research-SDD pending audits (per-target §13):" "$out"
