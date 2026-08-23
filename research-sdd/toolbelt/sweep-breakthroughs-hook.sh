#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-breakthroughs.sh and emits its output as
# additionalContext so unindexed/drifted breakthroughs surface when the supervisor project opens.
# Wired from .claude/settings.json (SessionStart). Read-only. Twin of sweep-retros-hook.sh.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/sweep-breakthroughs.sh" 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD breakthrough ledger sweep (§22):\n"+$c)}}'
else
  # jq missing: fall back to a plain print (still shows in transcript).
  printf 'Research-SDD breakthrough ledger sweep (§22):\n%s\n' "$out"
fi
