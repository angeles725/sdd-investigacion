#!/usr/bin/env bash
# SessionStart hook wrapper — runs verify-registry.sh and emits its output as additionalContext so
# master-registry drift (TARGETS.md 'N md' vs the real corpus block count) surfaces when the supervisor
# project opens. Wired from .claude/settings.json (SessionStart). Read-only. Twin of sweep-audits-hook.sh.
here="$(cd "$(dirname "$0")" && pwd)"
# Default: COMPACT mode (#1816 — SessionStart output budget, openspec/specs/kit-session-cost). Pass --full
# to emit verify-registry.sh output unchanged.
_full=0
for _arg in "$@"; do
  case "$_arg" in --full) _full=1 ;; esac
done

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

# COMPACT MODE: every WARN-class signal stays visible, only its verbosity shrinks. Anti-silent-zero §7:
# nothing is dropped without a count — WARN lines past the cap are counted, per-row INFO lines are counted,
# the Summary line (which carries every drift/absent/unresolvable count) always passes through whole, and any
# line this filter does not recognise passes through unchanged rather than vanishing.
if [ "$_full" = 0 ]; then  # COMPACT-GUARD
  out="$(printf '%s\n' "$out" | awk -v maxwarn=6 -v wmax=100 -v imax=170 '
    function trunc(s, n) { return (length(s) > n) ? substr(s, 1, n - 3) "..." : s }
    /^WARN/ { tw++; if (tw <= maxwarn) print trunc($0, wmax); next }  # WARN-CAP
    /^INFO  / { ri++; next }                                          # ROW-INFO-COUNT
    /^INFO:/ { print trunc($0, imax); next }
    /^For each / { next }
    /^[[:space:]]*$/ { next }
    { print }
    END {
      if (tw > maxwarn) printf "WARN: +%d more WARN line(s) omitted (%d total)\n", tw - maxwarn, tw  # WARN-OVERFLOW
      if (ri > 0) printf "INFO: %d per-row INFO line(s) omitted\n", ri
      print "Full detail: toolbelt/verify-registry.sh (or this hook with --full)."
    }
  ')"
fi

if command -v jq >/dev/null 2>&1; then
  jq -n --arg c "$out" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("Research-SDD registry check (TARGETS.md vs reality):\n"+$c)}}'
else
  # jq missing: fall back to a plain print (still shows in transcript).
  printf 'Research-SDD registry check (TARGETS.md vs reality):\n%s\n' "$out"
fi
