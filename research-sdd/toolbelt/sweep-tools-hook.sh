#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-tools.sh and surfaces the fleet summary when
# unrecorded tools are found or when registered targets could not be traversed (absent-input).
# Silent only when every tool is ledgered AND all targets were reached.
# Full per-target detail lives behind toolbelt/sweep-tools.sh; session start only
# needs the headline so per-target lines do not flood the context.
# Wired from .claude/settings.json (SessionStart). Read-only.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
here="$_RSDD_SELF"
# shellcheck source=lib/hook-emit.sh
. "$here/lib/hook-emit.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/hook-emit.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout (#1877)
out="$("$here/sweep-tools.sh" 2>&1)"; rc=$?

# Operational failure: the sweep could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="Research-SDD tools sweep could not run (exit $rc — check TARGETS.md and lib/ helper):"
  rsdd_hook_emit "$hdr" "$out"
  exit 0
fi

# Extract summary line (always the last "Summary:" line from sweep-tools.sh).
summary="$(printf '%s\n' "$out" | grep '^Summary:')"

# ANTI-SILENT-ZERO: a sweep that ran but produced no Summary line is unexpected —
# surface it rather than treating a broken instrument as "clean".
if [ -z "$summary" ]; then
  hdr="Research-SDD tools sweep: missing Summary line — unexpected output from sweep-tools.sh:"
  rsdd_hook_emit "$hdr" "$out"
  exit 0
fi

# Parse unrecorded count from the summary line.
unrecorded="$(printf '%s\n' "$summary" | grep -oE '[0-9]+ unrecorded' | grep -oE '^[0-9]+')"

# Extract not-traversed INFO line (absent targets) if present — suppress silence when targets
# were not traversed so a 0-of-N traversed state is never swallowed. STH-ABSENT-INFO
info_absent="$(printf '%s\n' "$out" | grep '^INFO:.*not traversed')"
_sth_absent_rc=$?
if [ "$_sth_absent_rc" -ge 2 ]; then
  info_absent="(INFO-line extraction failed: grep exit $_sth_absent_rc)"
fi

# All tools ledgered AND all targets traversed — stay silent. STH-ABSENT-CHECK
[ "${unrecorded:-0}" = "0" ] && [ -z "$info_absent" ] && exit 0  # STH-SILENT-EXIT

# Surface findings: unrecorded tools, unreachable targets, or both.
# No '|| true': grep exit-1 (no WARN lines present) is benign; exit ≥2 must surface — §7.
warn_line="$(printf '%s\n' "$out" | grep '^WARN:')"
_sth_warn_rc=$?
if [ "$_sth_warn_rc" -ge 2 ]; then
  warn_line="(WARN-line extraction failed: grep exit $_sth_warn_rc)"
fi

if [ "${unrecorded:-0}" = "0" ]; then
  # Targets not traversed but no unrecorded tools: surface the not-traversed INFO.
  detail="${summary}"$'\n'"${info_absent}${warn_line:+$'\n'$warn_line}"$'\n'"Run toolbelt/sweep-tools.sh for per-target breakdown."
  rsdd_hook_emit "Research-SDD tool ledger (targets not traversed):" "$detail"
else
  # Unrecorded tools found — emit summary + WARN (if any) + not-traversed INFO (if any) + prompt.
  _sth_info_absent_out="${info_absent}"  # STH-UNRECORDED-ABSENT-FIELD — isolated for mutation testing
  detail="${summary}${warn_line:+$'\n'$warn_line}${_sth_info_absent_out:+$'\n'$_sth_info_absent_out}"$'\n'"Run toolbelt/sweep-tools.sh for per-target breakdown."
  rsdd_hook_emit "Research-SDD tool ledger (unrecorded tools found):" "$detail"
fi
