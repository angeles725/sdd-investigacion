#!/usr/bin/env bash
# SessionStart hook wrapper — runs verify-tool-catalog.sh and emits additionalContext.
# When every logged tool is cataloged: emits a declared-clean sentinel (#380 precedent, never silent).
# When drift exists: emits WARN lines + summary. Wired from .claude/settings.json (SessionStart).
# Read-only. Twin of sweep-tools-hook.sh.
here="$(cd "$(dirname "$0")" && pwd)"
out="$("$here/verify-tool-catalog.sh" 2>&1)"; rc=$?

# Operational failure: the guard could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="Research-SDD tool catalog check could not run (exit $rc — check INSTALLED-TOOLS.md and tool-registry.md):"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg h "$hdr" --arg c "$out" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
  else
    printf '%s\n%s\n' "$hdr" "$out"
  fi
  exit 0
fi

# Extract summary line (always the last "Summary:" line from verify-tool-catalog.sh).
summary="$(printf '%s\n' "$out" | grep '^Summary:')"

# ANTI-SILENT-ZERO: a run that exited 0 but produced no Summary line is unexpected — surface it
# rather than treating a broken instrument as "clean" (covers both empty-input and no-Summary cases;
# empty-input already prints its own explicit sentence, so absence of BOTH is the true anomaly).
if [ -z "$summary" ]; then
  if printf '%s\n' "$out" | grep -qi 'empty-input\|no tool log rows'; then
    exit 0  # legitimate empty-input state: nothing to reconcile, stay silent
  fi
  hdr="Research-SDD tool catalog check: missing Summary line — unexpected output from verify-tool-catalog.sh:"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg h "$hdr" --arg c "$out" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:($h+"\n"+$c)}}'
  else
    printf '%s\n%s\n' "$hdr" "$out"
  fi
  exit 0
fi

# Parse "not cataloged" count from the summary line.
missing="$(printf '%s\n' "$summary" | grep -oE '[0-9]+ not cataloged' | grep -oE '^[0-9]+')"

# Every logged tool is cataloged — emit declared-clean sentinel (#380 precedent; never silent on clean).
if [ "${missing:-0}" = "0" ]; then
  logged="$(printf '%s\n' "$summary" | grep -oE 'Summary: [0-9]+' | grep -oE '[0-9]+$')"
  sentinel="Research-SDD tool catalog: clean (${logged:-?} logged tools, 0 uncataloged)."  # CLEAN-SENTINEL
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg c "$sentinel" \
      '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
  else
    printf '%s\n' "$sentinel"
  fi
  exit 0
fi

# Drift found — emit the WARN lines + summary, prompting for the full-detail command.
# No '|| true': grep exit-1 (no WARN lines present) is benign; exit ≥2 must surface — §7.
warn_lines="$(printf '%s\n' "$out" | grep '^WARN')"
_vtch_warn_rc=$?
if [ "$_vtch_warn_rc" -ge 2 ]; then
  warn_lines="(WARN-line extraction failed: grep exit $_vtch_warn_rc)"
fi
detail="${warn_lines}${warn_lines:+$'\n'}${summary}"$'\n'"Run toolbelt/verify-tool-catalog.sh for the full list."
if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$detail" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD tool catalog drift (installed but not cataloged):\n"+$c)}}'
else
  printf 'Research-SDD tool catalog drift (installed but not cataloged):\n%s\n' "$detail"
fi
