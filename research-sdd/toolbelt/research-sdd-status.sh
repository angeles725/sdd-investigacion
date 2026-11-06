#!/usr/bin/env bash
# Ported to Go: `rsdd status show`. Compatibility shim (removed in phase 8, kit issue #2270; ported from the 2,642-line bash, kit issue #2549).
# research-sdd-status.sh <target-dir> [--next [--all] [--queue] [--emit-token] | --sync-state [--only F[,F...]]] [--focus <slug> | --root] [--stall-minutes N]
# The command line, the modes and the typed states are documented in tool-registry.d/research-sdd-status.md; the engine is
# research-sdd/rsdd/internal/status/show, pinned by its Go tests (a differential against the frozen legacy script and its libs).
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
# The Go command runs verify-state.sh and reconcile-issues.sh from this directory (the script ran them as "$here/<script>").
RSDD_TOOLBELT_DIR="$_RSDD_SELF" rsdd_exec status show "$@"
