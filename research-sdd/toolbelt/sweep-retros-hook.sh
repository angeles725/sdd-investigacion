#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-retros.sh and emits its output as
# additionalContext so pending §18 retros surface when the supervisor project opens.
# Default: SUMMARY mode — oldest 5 PENDING rows; absent targets collapsed to one line.
# Pass --full to emit the complete sweep output unchanged (byte-identical to old default).
# Wired from .claude/settings.json (SessionStart). Read-only.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
here="$_RSDD_SELF"
# shellcheck source=lib/hook-emit.sh
. "$here/lib/hook-emit.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/hook-emit.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout (#1877)

# Parse --full flag (any position).
_full=0
for _arg in "$@"; do
  case "$_arg" in --full) _full=1 ;; esac
done

out="$("$here/sweep-retros.sh" 2>&1)"; rc=$?

# Operational failure: the sweep could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="Research-SDD retro sweep could not run (exit $rc — check TARGETS.md and lib/ helper):"
  rsdd_hook_emit "$hdr" "$out"
  exit 0
fi

# SUMMARY MODE (default): filter sweep output to oldest 5 PENDING blocks, one collapsed
# absent-target line, and the Summary: line.  All other lines (WARN, MISSING-RETRO, waived,
# per-target INFO lines) are suppressed — the user runs --full to see them.
# --full passes the full sweep output through unchanged.
if [ "$_full" = 0 ]; then
  out="$(printf '%s\n' "$out" | awk '
    BEGIN { pcnt=0; limit=5; in_pb=0 }

    # Suppress verbose lines visible only in --full mode.
    /^WARN:/         { next }
    /^MISSING-RETRO:/ { next }
    /^waived:/       { next }

    # Drop individual per-target absent-input INFO lines — collapsed to aggregate below.
    /^INFO: corpus not found \(absent-input\):/ { next }

    # Aggregate absent-input line: swap the "see INFO lines above" pointer for --full hint.
    /^INFO: [0-9]+ target\(s\) not traversed \(absent-input\)/ {
      sub(/see INFO lines above\.?/, "run --full to list them.")
      print; next  # ABSENT-COLLAPSE-PRINT
    }

    # PENDING header — start a new block; count determines whether to show it.
    /^PENDING  / {
      pcnt++
      in_pb = (pcnt <= limit)
      if (in_pb) print
      next
    }

    # Continuation lines belonging to a PENDING block (9-space indent).
    /^         / {
      if (in_pb) print
      next
    }

    # Summary: line is emitted BYTE-IDENTICAL in both modes; prepend "N more" when needed.
    /^Summary:/ {
      if (pcnt > limit)
        printf "\342\200\246 and %d more \342\200\224 run sweep-retros.sh --full\n", (pcnt - limit)
      print; next  # SUMMARY-LINE-PRINT
    }

    # Everything else: Nothing to review, empty lines.
    { in_pb=0; print }
  ')"
fi

rsdd_hook_emit "Research-SDD retro sweep (supervisor project):" "$out"
