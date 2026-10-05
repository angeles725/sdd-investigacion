#!/usr/bin/env bash
# verify-skill-drift-hook.sh — SessionStart hook: surfaces diverged deployed SKILL.md(s) and
# install --verify findings (bundle drift, stale kit checkout).
#
# Calls verify-skill-drift.sh --all (checks every harness registered in adapters.sh), then
# research-sdd-install.sh --verify (kit issue #1702 bundle digest + kit-checkout staleness).
# SILENT when all installed harnesses are in-sync / absent AND --verify has nothing to flag (exit 0).
# Emits additionalContext JSON via jq otherwise. Read-only. Wired from .claude/settings.json.
#
# Budget (openspec/specs/kit-session-cost/spec.md: SessionStart output < 8,000 chars total): the
# install --verify part contributes at most 4 typed lines of at most 170 chars each (SENTINEL-VERIFY-CAP).
# $RESEARCH_SDD_INSTALL_VERIFY_CMD overrides the install --verify command (test seam).
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/verify-skill-drift.sh" --all 2>&1)"; rc=$?

vcmd="${RESEARCH_SDD_INSTALL_VERIFY_CMD:-$here/../install/research-sdd-install.sh}"
extra=""
if [ -x "$vcmd" ]; then
  if command -v timeout >/dev/null 2>&1; then
    vout="$(timeout "${RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT:-10}" "$vcmd" --verify 2>&1)"; vrc=$?   # SENTINEL-VERIFY-TIMEOUT
  else
    vout="$("$vcmd" --verify 2>&1)"; vrc=$?
  fi
  # Only findings: harness drift / degraded and kit behind. match, absent, current stay silent; a kit
  # `degraded` (tarball install, no upstream) is un-clearable at session start, so it stays visible only
  # in `research-sdd-install.sh --verify` itself (SENTINEL-KIT-BEHIND-ONLY).
  extra="$(printf '%s\n' "$vout" | grep -E '^verify (harness=[^ ]+ status=(drift|degraded)|kit status=behind)' | cut -c1-170 | head -4)" # SENTINEL-VERIFY-CAP
  # Anti-silent-zero: a failing --verify that printed no typed finding must still be surfaced.
  if [ "$vrc" -eq 124 ]; then
    extra="verify: install --verify timed out (RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT, default 10s)${extra:+
$extra}"
  elif [ -z "$extra" ] && [ "$vrc" -ne 0 ]; then
    extra="verify: install --verify exited $vrc with no typed line"
  fi
else
  extra="verify: install --verify could not run (not executable: ${vcmd##*/})"
fi

[ "$rc" -eq 0 ] && [ -z "$extra" ] && exit 0   # all in-sync / all absent, nothing to flag → stay completely silent

case "$rc" in
  0) msg="WARN: research-sdd install --verify reports issues — see lines below" ;;
  1) msg="WARN: research-sdd SKILL.md stale for one or more harnesses — run the fix command(s) shown" ;;
  *) msg="ERROR: verify-skill-drift.sh could not run for one or more harnesses — check kit install/adapters.sh" ;;
esac
[ -n "$extra" ] && out="${out:+$out
}$extra"

if command -v jq >/dev/null 2>&1; then
  jq -n --arg h "$msg" --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
else
  printf '%s\n%s\n' "$msg" "$out"
fi
