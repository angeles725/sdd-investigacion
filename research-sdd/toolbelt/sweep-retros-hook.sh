#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-retros.sh and emits its output as
# additionalContext so pending §18 retros surface when the supervisor project opens.
# Wired from .claude/settings.json (SessionStart). Read-only.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/sweep-retros.sh" 2>&1)"; rc=$?

# Operational failure: the sweep could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="Research-SDD retros sweep could not run (exit $rc — check TARGETS.md and lib/ helper):"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg h "$hdr" --arg c "$out" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
  else
    printf '%s\n%s\n' "$hdr" "$out"
  fi
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD retro sweep (supervisor project):\n"+$c)}}'
else
  # jq missing: fall back to a plain systemMessage-free print (still shows in transcript).
  printf 'Research-SDD retro sweep (supervisor project):\n%s\n' "$out"
fi
