#!/usr/bin/env bash
# SessionStart hook wrapper — runs verify-registry.sh and emits its output as additionalContext so
# master-registry drift (TARGETS.md 'N md' vs the real corpus block count) surfaces when the supervisor
# project opens. Wired from .claude/settings.json (SessionStart). Read-only. Twin of sweep-audits-hook.sh.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/verify-registry.sh" 2>/dev/null)"
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD registry drift (TARGETS.md vs reality):\n"+$c)}}'
else
  # jq missing: fall back to a plain print (still shows in transcript).
  printf 'Research-SDD registry drift (TARGETS.md vs reality):\n%s\n' "$out"
fi
