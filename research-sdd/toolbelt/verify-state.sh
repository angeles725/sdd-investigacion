#!/usr/bin/env bash
# Ported to Go: `rsdd verify state`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2457).
# Usage: verify-state.sh <target-dir> [--focus <slug>]
# Exit: 0 = consistent · 1 = inconsistency (stale mirror) · 2 = bad args / no state file / absent-focus.
# The report (living-mirror consistency of every RESEARCH-STATE*.md, the research-state.v1 envelope checks and the
# P8 hook-placeholder scan) is produced by the binary, byte for byte as this script printed it. The gap-drift check
# runs in process (`rsdd verify gap-drift`, kit issue #2645), so no checker has to sit beside this file.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec verify state "$@"
