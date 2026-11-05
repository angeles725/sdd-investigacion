#!/usr/bin/env bash
# Ported to Go: `rsdd maint flake-hunt`. Compatibility shim (kit issue #2209, Go port of the maint batch).
# kit-flake-hunt.sh [--repo DIR] [--runs K] [--load N] [--load-timeout S] [--suite-timeout S] [--suites FILE | --suite PATH ...]
#                   [--tier core|all] [--prove-teeth] [--out DIR] [--evidence-url URL] [--file-issues[=apply]]
# The contract, the typed exit states and the help text live in research-sdd/rsdd/internal/maint/flakehunt/ and are pinned by
# its Go tests (a differential test against the frozen legacy script, one test per .github/workflows/flake-hunt.yml shape)
# and by tests/kit-flake-hunt.test.sh. The hunt defaults to THIS checkout (the Go command cannot see where the shim lives),
# so the checkout goes first and a caller's own --repo, coming later, still wins.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/../lib/rsdd-exec.sh" 2>/dev/null || { echo "degraded: rsdd-unavailable - lib/rsdd-exec.sh missing" >&2; exit 3; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec maint flake-hunt --repo "$(CDPATH='' cd -P -- "$_RSDD_SELF/../../.." && pwd -P)" "$@"
