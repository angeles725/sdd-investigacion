#!/usr/bin/env bash
# SessionStart hook wrapper — runs verify-kit-clean.sh and, ONLY when the kit is NOT clean, emits its report
# as additionalContext so a DIRTY / unpushed kit surfaces when the supervisor project opens (alongside the
# retro sweep). A clean kit emits nothing — no session-start noise. Read-only. Wired from .claude/settings.json.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/verify-kit-clean.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && exit 0                         # clean → stay silent
# Distinguish a real dirty/unpushed state (rc=1) from a gate that could not run (rc=2: not a git repo /
# misdeployed) so the surfaced banner is not misleading.
if [ "$rc" = 1 ]; then
  hdr="Research-SDD KIT is NOT clean — commit/stash + push before staging §18 retros (else the retro branch/PR mixes unrelated history):"
else
  hdr="Research-SDD kit-clean check could not run (exit $rc — misconfigured path or not a git repo):"
fi
if command -v jq >/dev/null 2>&1; then
  jq -n --arg h "$hdr" --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
else
  printf '%s\n%s\n' "$hdr" "$out"
fi
