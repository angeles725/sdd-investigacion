#!/usr/bin/env bash
# SessionStart hook wrapper — runs verify-registry.sh and emits its output as additionalContext so
# master-registry drift (TARGETS.md 'N md' vs the real corpus block count) surfaces when the supervisor
# project opens. Wired from .claude/settings.json (SessionStart). Read-only. Twin of sweep-audits-hook.sh.
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/hook-emit.sh
. "$here/lib/hook-emit.sh"
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
  rsdd_hook_emit "$hdr" "$out"
  exit 0
fi

# COMPACT MODE: every WARN-class signal stays visible, only its verbosity shrinks. Anti-silent-zero §7:
# nothing is dropped without a count — WARN lines past the cap are counted, per-row INFO lines are counted,
# the Summary line (which carries every drift/absent/unresolvable count) always passes through whole, and any
# line this filter does not recognise passes through unchanged rather than vanishing.
# awk length/substr count BYTES on mawk or in a non-UTF-8 locale, so a cut can split a multibyte character
# (em dash, ≠) and hand invalid UTF-8 to jq. Every cut ends in "..." (or end of line), so drop an INCOMPLETE
# UTF-8 sequence sitting right before it, byte-wise and independent of the awk implementation / locale.
_utf8_trim() { LC_ALL=C sed -E 's/([\xC0-\xDF]|[\xE0-\xEF][\x80-\xBF]?|[\xF0-\xF7][\x80-\xBF]{0,2})(\.\.\.|$)/\2/g'; }

if [ "$_full" = 0 ]; then  # COMPACT-GUARD
  out="$(printf '%s\n' "$out" | awk -v maxwarn=6 -v wmax=100 -v imax=230 -v hmax=110 '
    function trunc(s, n) { return (length(s) > n) ? substr(s, 1, n - 3) "..." : s }
    # Long INFO line: keep a bounded head (it carries the count) and the WHOLE last sentence (the
    # remediation hint), dropping only the middle (the example-path list).
    function keeptail(s,   p, rest, i, tail) {
      if (length(s) <= imax) return s
      tail = s; rest = s; p = 0
      while ((i = index(rest, ". ")) > 0) { p += i + 1; rest = substr(rest, i + 2) }
      if (p == 0) return trunc(s, imax)
      tail = substr(s, p + 1)
      return trunc(s, hmax) " " tail
    }
    # Rank before capping: fleet/kit-level WARN kinds (kit-not-registered, oversized-row, unresolvable corpus,
    # unreadable retros, partial reconcile, any "WARN:" aggregate) come first; per-target drift WARNs after.
    /^WARN/ {
      tw++
      if ($0 ~ /^WARN: |kit repo is NOT in its own|master cell is [0-9]+ chars|corpus layout not resolvable|is not accessible|PARTIAL/) pri[++np] = $0; else oth[++no] = $0
      next                                                            # WARN-CAP
    }
    /^INFO  / { ri++; next }                                          # ROW-INFO-COUNT
    /^INFO:/ { print keeptail($0); next }
    /^For each / { next }
    /^[[:space:]]*$/ { next }
    { print }
    END {
      shown = 0
      for (k = 1; k <= np && shown < maxwarn; k++) { print trunc(pri[k], wmax); shown++ }  # WARN-RANK
      for (k = 1; k <= no && shown < maxwarn; k++) { print trunc(oth[k], wmax); shown++ }
      if (tw > maxwarn) printf "WARN: +%d more WARN line(s) omitted (%d total)\n", tw - maxwarn, tw  # WARN-OVERFLOW
      if (ri > 0) printf "INFO: %d per-row INFO line(s) omitted\n", ri
      print "Full detail: toolbelt/verify-registry.sh (or this hook with --full)."
    }
  ' | _utf8_trim)"  # UTF8-TRIM
fi

rsdd_hook_emit "Research-SDD registry check (TARGETS.md vs reality):" "$out"
