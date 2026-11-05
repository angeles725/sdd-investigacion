#!/usr/bin/env bash
# Ported to Go: `rsdd maint gate`. Compatibility shim (kit issue #2212, Go port of the maint batch).
# kit-gate.sh [--state-dir DIR] [--cmd CMD | --serial] [--lock-timeout SECONDS] <worktree> <label>
# The contract, the typed exit states and the help text live in research-sdd/rsdd/internal/maint/gate/ and are pinned by its
# Go tests (a differential test against the frozen legacy script) and by tests/kit-pr-pipeline.test.sh.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/../lib/rsdd-exec.sh" 2>/dev/null || { echo "degraded: rsdd-unavailable - lib/rsdd-exec.sh missing" >&2; exit 3; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec maint gate "$@"
