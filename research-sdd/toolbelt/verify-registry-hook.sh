#!/usr/bin/env bash
# SessionStart hook wrapper — runs verify-registry.sh and emits its output as additionalContext so
# master-registry drift (TARGETS.md 'N md' vs the real corpus block count) surfaces when the supervisor
# project opens. Wired from .claude/settings.json (SessionStart). Read-only. Twin of sweep-audits-hook.sh.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/verify-registry.sh" 2>&1)"; rc=$?

# Operational failure: the check could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="Research-SDD registry check could not run (exit $rc — check TARGETS.md and lib/ helper):"
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
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD registry drift (TARGETS.md vs reality):\n"+$c)}}'
else
  # jq missing: fall back to a plain print (still shows in transcript).
  printf 'Research-SDD registry drift (TARGETS.md vs reality):\n%s\n' "$out"
fi
