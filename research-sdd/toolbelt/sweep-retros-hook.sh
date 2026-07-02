#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-retros.sh and emits its output as
# additionalContext so pending §18 retros surface when the supervisor project opens.
# Wired from .claude/settings.json (SessionStart). Read-only.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/sweep-retros.sh" 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD retro sweep (supervisor project):\n"+$c)}}'
else
  # jq missing: fall back to a plain systemMessage-free print (still shows in transcript).
  printf 'Research-SDD retro sweep (supervisor project):\n%s\n' "$out"
fi
