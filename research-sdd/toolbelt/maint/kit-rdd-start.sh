#!/usr/bin/env bash
# Ported to Go: `rsdd maint rdd-start`. Compatibility shim (removed in phase 8, kit issue #2394).
# kit-rdd-start.sh [--consent granted] [--base-ref REF] [--agent NAME] <cwd> <outfile>
# The contract, the typed exit states and the allowlist are documented in research-sdd/rsdd/internal/maint/rddstart.go
# and pinned by tests/kit-rdd-start.test.sh. It keeps a stable toolbelt path for maint/kit-pr-pipeline.sh, which runs it with bash,
# and for manual runs. It replaced the former kit-rdd-start.py wrapper.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/../lib/rsdd-exec.sh" 2>/dev/null || { echo "degraded: rsdd-unavailable - lib/rsdd-exec.sh missing" >&2; exit 3; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec maint rdd-start "$@"
