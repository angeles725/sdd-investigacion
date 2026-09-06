#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-audits.sh and emits its output as additionalContext so
# pending §13 audit reports surface when the supervisor project opens. Wired from
# .claude/settings.json (SessionStart). Read-only. Twin of sweep-retros-hook.sh.
# Default: SUMMARY mode — per-target absent-input INFO lines collapsed to one counted line.
# Pass --full to emit the complete sweep output unchanged (byte-identical to sweep script output).
here="$(cd "$(dirname "$0")" && pwd)"

# Parse --full flag (any position).
_full=0
for _arg in "$@"; do
  case "$_arg" in --full) _full=1 ;; esac
done

out="$("$here/sweep-audits.sh" 2>&1)"; rc=$?

# Operational failure: the sweep could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="Research-SDD audits sweep could not run (exit $rc — check TARGETS.md and lib/ helper):"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg h "$hdr" --arg c "$out" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
  else
    printf '%s\n%s\n' "$hdr" "$out"
  fi
  exit 0
fi

# SUMMARY MODE (default): collapse per-target absent-input INFO lines to one counted line.
# --full passes the full sweep output through unchanged (byte-identical to sweep script output).
if [ "$_full" = 0 ]; then  # FULL-PASSTHROUGH-GUARD
  out="$(printf '%s\n' "$out" | awk '
    # Drop individual per-target absent-input INFO lines — collapsed to aggregate below.
    /^INFO: corpus not found \(absent-input\):/ { next }

    # Aggregate absent-input line: swap the "see INFO lines above" pointer for --full hint.
    /^INFO: [0-9]+ target\(s\) not traversed \(absent-input\)/ {
      sub(/see INFO lines above\.?/, "run --full to list them.")
      print; next  # ABSENT-COLLAPSE-PRINT
    }

    # Everything else passes through unchanged.
    { print }
  ')"
fi

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD pending audits (per-target §13):\n"+$c)}}'
else
  # jq missing: fall back to a plain print (still shows in transcript).
  printf 'Research-SDD pending audits (per-target §13):\n%s\n' "$out"
fi
