#!/usr/bin/env bash
# Ported to Go: `rsdd sweep tools --hook`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2361).
# SessionStart hook wrapper — runs the tool census and surfaces the fleet summary when unrecorded tools are found
# or when registered targets could not be traversed (absent-input). Silent only when every tool is ledgered AND all
# targets were reached. Full per-target detail lives behind toolbelt/sweep-tools.sh. Wired from
# .claude/settings.json (SessionStart). Read-only. The kit swept is this script's own checkout, passed explicitly.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/rsdd-exec.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout
rsdd_exec_hook sweep sweep tools --hook --kit "$_RSDD_SELF/.." "$@"
