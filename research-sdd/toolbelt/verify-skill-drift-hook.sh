#!/usr/bin/env bash
# Ported to Go: `rsdd verify skill-drift-hook`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2365).
# SessionStart hook: surfaces diverged deployed SKILL.md(s), install --verify findings (bundle drift) and a stale kit checkout;
# SILENT when there is nothing to flag. Wired from .claude/settings.json and install/pi/research-sdd-hooks.ts.
# The kit is this script's own directory, handed to the binary in RSDD_TOOLBELT_DIR. Seams kept: RESEARCH_SDD_INSTALL_VERIFY_CMD,
# RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT, RESEARCH_SDD_KIT_STALE_CHECK / _MAX_COMMITS / _MAX_DAYS / _VERBOSE, RESEARCH_SDD_KIT_DIR.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/rsdd-exec.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout
export RSDD_TOOLBELT_DIR="$_RSDD_SELF"
rsdd_exec_hook sweep verify skill-drift-hook "$@"
