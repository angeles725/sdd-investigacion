#!/usr/bin/env bash
# Ported to Go: `rsdd sweep audits --hook`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2577).
# SessionStart hook wrapper — runs the audit sweep and emits its output as additionalContext so pending §13 audit
# reports surface when the supervisor project opens. Default: SUMMARY mode (the per-target absent-input lines are
# dropped, the empty-input lines counted in one line); --full passes the complete sweep output through. Wired from
# .claude/settings.json (SessionStart). Read-only. Twin of sweep-retros-hook.sh. The kit swept is this script's
# own checkout, passed explicitly.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/rsdd-exec.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout
rsdd_exec_hook sweep sweep audits --hook --kit "$_RSDD_SELF/.." "$@"
