#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-tools.sh and emits a fleet summary ONLY when
# unrecorded tools exist across the fleet. Silent when every tool is ledgered.
# Full per-target detail lives behind toolbelt/sweep-tools.sh; session start only
# needs the headline so 288 unrecorded-tool lines do not flood the context.
# Wired from .claude/settings.json (SessionStart). Read-only.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/sweep-tools.sh" 2>&1)"; rc=$?

# Operational failure: the sweep could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="Research-SDD tools sweep could not run (exit $rc — check TARGETS.md and lib/ helper):"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg h "$hdr" --arg c "$out" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
  else
    printf '%s\n%s\n' "$hdr" "$out"
  fi
  exit 0
fi

# Extract summary line (always the last "Summary:" line from sweep-tools.sh).
summary="$(printf '%s\n' "$out" | grep '^Summary:')"

# ANTI-SILENT-ZERO: a sweep that ran but produced no Summary line is unexpected —
# surface it rather than treating a broken instrument as "clean".
if [ -z "$summary" ]; then
  hdr="Research-SDD tools sweep: missing Summary line — unexpected output from sweep-tools.sh:"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg h "$hdr" --arg c "$out" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
  else
    printf '%s\n%s\n' "$hdr" "$out"
  fi
  exit 0
fi

# Parse unrecorded count from the summary line.
unrecorded="$(printf '%s\n' "$summary" | grep -oE '[0-9]+ unrecorded' | grep -oE '^[0-9]+')"

# All tools ledgered — stay silent (mirrors verify-kit-clean-hook.sh clean-exit idiom).
[ "${unrecorded:-0}" = "0" ] && exit 0

# Unrecorded tools found — emit summary (+ PARTIAL WARN if present) and prompt for detail.
warn_line="$(printf '%s\n' "$out" | grep '^WARN:' || true)"
detail="${summary}${warn_line:+$'\n'$warn_line}"$'\n'"Run toolbelt/sweep-tools.sh for per-target breakdown."
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$detail" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD tool ledger (unrecorded tools found):\n"+$c)}}'
else
  printf 'Research-SDD tool ledger (unrecorded tools found):\n%s\n' "$detail"
fi
