#!/usr/bin/env bash
# verify-skill-drift-hook.sh — SessionStart hook: surfaces a diverged deployed SKILL.md.
#
# Calls verify-skill-drift.sh (harness: claude, default home).
# SILENT when in-sync (exit 0) — contributes ZERO characters to the SessionStart aggregate.
# Emits additionalContext JSON via jq when diverged, absent, or could-not-run.
# Read-only. Wired from .claude/settings.json.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/verify-skill-drift.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && exit 0   # in-sync → stay completely silent

case "$rc" in
  1) msg="WARN: research-sdd SKILL.md (claude) is stale — run: research-sdd-install.sh --harness claude --force-skill" ;;
  3) msg="INFO: research-sdd SKILL.md (claude) not deployed — run: research-sdd-install.sh --harness claude" ;;
  *) msg="ERROR: verify-skill-drift.sh could not run (exit $rc) — check kit install/adapters.sh" ;;
esac

if command -v jq >/dev/null 2>&1; then
  jq -n --arg h "$msg" --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
else
  printf '%s\n%s\n' "$msg" "$out"
fi
