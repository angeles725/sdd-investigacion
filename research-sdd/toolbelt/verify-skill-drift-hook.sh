#!/usr/bin/env bash
# verify-skill-drift-hook.sh — SessionStart hook: surfaces diverged deployed SKILL.md(s).
#
# Calls verify-skill-drift.sh --all (checks every harness registered in adapters.sh).
# SILENT when all installed harnesses are in-sync OR all harnesses are absent (exit 0).
# Emits additionalContext JSON via jq when any harness is diverged or could-not-run.
# Read-only. Wired from .claude/settings.json.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/verify-skill-drift.sh" --all 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && exit 0   # all in-sync / all absent → stay completely silent

case "$rc" in
  1) msg="WARN: research-sdd SKILL.md stale for one or more harnesses — run the fix command(s) shown" ;;
  *) msg="ERROR: verify-skill-drift.sh could not run for one or more harnesses — check kit install/adapters.sh" ;;
esac

if command -v jq >/dev/null 2>&1; then
  jq -n --arg h "$msg" --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
else
  printf '%s\n%s\n' "$msg" "$out"
fi
