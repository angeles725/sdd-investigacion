#!/usr/bin/env bash
# SessionStart hook wrapper — runs verify-tool-catalog.sh and emits additionalContext.
# When every logged tool is cataloged: emits a declared-clean sentinel (#380 precedent, never silent).
# When drift exists: emits WARN lines + summary. Wired from .claude/settings.json (SessionStart).
# Read-only. Twin of sweep-tools-hook.sh.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
_RSDD_SELF="$(cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
here="$_RSDD_SELF"
# shellcheck source=lib/hook-emit.sh
. "$here/lib/hook-emit.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/hook-emit.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout (#1877)
out="$("$here/verify-tool-catalog.sh" 2>&1)"; rc=$?

# Operational failure: the guard could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="Research-SDD tool catalog check could not run (exit $rc — check INSTALLED-TOOLS.md and tool-registry.md):"
  rsdd_hook_emit "$hdr" "$out"
  exit 0
fi

# Extract summary line (always the last "Summary:" line from verify-tool-catalog.sh).
summary="$(printf '%s\n' "$out" | grep '^Summary:')"

# ANTI-SILENT-ZERO: a run that exited 0 but produced no Summary line is unexpected — surface it
# rather than treating a broken instrument as "clean" (covers both empty-input and no-Summary cases;
# empty-input already prints its own explicit sentence, so absence of BOTH is the true anomaly).
if [ -z "$summary" ]; then
  if grep -qi 'empty-input\|no tool log rows' <<<"$out"; then
    exit 0  # legitimate empty-input state: nothing to reconcile, stay silent
  fi
  hdr="Research-SDD tool catalog check: missing Summary line — unexpected output from verify-tool-catalog.sh:"
  rsdd_hook_emit "$hdr" "$out"
  exit 0
fi

# Parse "not cataloged" count from the summary line.
missing="$(printf '%s\n' "$summary" | grep -oE '[0-9]+ not cataloged' | grep -oE '^[0-9]+')"

# Every logged tool is cataloged — emit declared-clean sentinel (#380 precedent; never silent on clean).
if [ "${missing:-0}" = "0" ]; then
  logged="$(printf '%s\n' "$summary" | grep -oE 'Summary: [0-9]+' | grep -oE '[0-9]+$')"
  sentinel="Research-SDD tool catalog: clean (${logged:-?} logged tools, 0 uncataloged)."  # CLEAN-SENTINEL
  rsdd_hook_emit "$sentinel"
  exit 0
fi

# Drift found — emit the WARN lines + summary, prompting for the full-detail command.
# No '|| true': grep exit-1 (no WARN lines present) is benign; exit ≥2 must surface — §7.
warn_lines="$(printf '%s\n' "$out" | grep '^WARN')"
_vtch_warn_rc=$?
if [ "$_vtch_warn_rc" -ge 2 ]; then
  warn_lines="(WARN-line extraction failed: grep exit $_vtch_warn_rc)"
fi
#
# COMPACT (#1816, SessionStart output budget): the per-tool "installed-but-not-cataloged" WARN lines share
# one long remediation sentence; collapse them into ONE line naming every tool (count == names listed ==
# the summary's "not cataloged" count). Any other WARN line passes through (truncated), never dropped.
# cut -c counts BYTES, so it can split a multibyte character; drop an incomplete UTF-8 sequence at end of line.
_utf8_trim() { LC_ALL=C sed -E 's/([\xC0-\xDF]|[\xE0-\xEF][\x80-\xBF]?|[\xF0-\xF7][\x80-\xBF]{0,2})$//'; }
if [ "${1:-}" != "--full" ]; then  # COMPACT-GUARD
  names="$(printf '%s\n' "$warn_lines" | sed -n "s/^WARN  installed-but-not-cataloged: '\([^']*\)'.*/\1/p" | paste -sd, - | sed 's/,/, /g')"
  n_names="$(printf '%s\n' "$warn_lines" | grep -c "^WARN  installed-but-not-cataloged: '")"
  other="$(printf '%s\n' "$warn_lines" | grep -v "^WARN  installed-but-not-cataloged: '" | cut -c1-160 | _utf8_trim)"
  warn_lines="${other}"
  if [ "${n_names:-0}" -gt 0 ]; then
    warn_lines="${warn_lines}${warn_lines:+$'\n'}WARN  installed-but-not-cataloged (${n_names}): ${names} — add a tool-registry.md row each (propose-never-apply)."
  fi
fi
detail="${warn_lines}${warn_lines:+$'\n'}${summary}"$'\n'"Run toolbelt/verify-tool-catalog.sh for the full list."
rsdd_hook_emit "Research-SDD tool catalog drift (installed but not cataloged):" "$detail"
