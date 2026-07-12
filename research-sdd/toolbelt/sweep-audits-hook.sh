#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-audits.sh and emits its output as additionalContext so
# pending §13 audit reports surface when the supervisor project opens. Wired from
# .claude/settings.json (SessionStart). Read-only. Twin of sweep-retros-hook.sh.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/sweep-audits.sh" 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD pending audits (per-target §13):\n"+$c)}}'
else
  # jq missing: fall back to a plain print (still shows in transcript).
  printf 'Research-SDD pending audits (per-target §13):\n%s\n' "$out"
fi
