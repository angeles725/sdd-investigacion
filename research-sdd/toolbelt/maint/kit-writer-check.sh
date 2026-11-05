#!/usr/bin/env bash
# Ported to Go: `rsdd maint writer-check`. Compatibility shim (kit issue #2212, Go port of the maint batch).
# kit-writer-check.sh --base <ref> [--head <ref>|--worktree] [--teeth-log DIR] [--format report|json] [--repo DIR] ...
# kit-writer-check.sh --write-teeth-log DIR --base <ref> [--repo DIR] <suite>...
# kit-writer-check.sh --classify <path>...
# Mechanical writer discipline (kit issue #2208), run BEFORE the full gate: required suites, bound --prove-teeth logs,
# waivers, and the name-based process-kill scan over added lines. The contract, the typed exit states and the usage text live in
# research-sdd/rsdd/internal/maint/writercheck/ and are pinned by its Go tests (a differential test against the frozen legacy
# script, and the shared name-kill corpus and production-path list) and by tests/kit-writer-check.test.sh.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
# The impact map is the one of THIS kit unless the caller names another (the Go command cannot see the shim's directory).
export KIT_WRITER_CHECK_IMPACT="${KIT_WRITER_CHECK_IMPACT:-$_RSDD_SELF/../tests/suite-impact.sh}"
. "$_RSDD_SELF/../lib/rsdd-exec.sh" 2>/dev/null || { echo "degraded: rsdd-unavailable - lib/rsdd-exec.sh missing" >&2; exit 3; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec maint writer-check "$@"
