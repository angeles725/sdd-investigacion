#!/usr/bin/env bash
# Ported to Go: `rsdd verify block`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2456).
# Usage: verify-block.sh [--strict-ephemeral | --ephemeral=warn|fail] [--extern-check] [--backptr=high|all|off] <block.md> [target-dir]
#        verify-block.sh --possibility-sweep <corpus-dir>   (list existing bare feasibility verdicts; read-only)
# Exit: 0 = no verifiable contradiction · 1 = a cited line out of range / an unpreserved block-evidence artifact / a cited
#       empty-input digest / an ephemeral path (EPHEMERAL!, a WARN under --ephemeral=warn or RSDD_STRICT_EPHEMERAL=0) /
#       a SCRIPTS-MANIFEST mismatch or a degraded scan · 2 = bad args.
# The report (marker tally, [INFER]/[CERT] ratio, [CERT] file:line citation resolution, possibility-first lint, OCR
# provenance, empty-input digests, ephemeral-path cites, SCRIPTS-MANIFEST rows and the section-14 back-pointer check) is
# produced by the binary, byte for byte as this script printed it; METHODOLOGY section 11 describes what it checks. The
# frozen script and the libraries it sourced are the parity oracle of the Go differential tests (internal/verify/block,
# testdata/block-legacy). Environment read: RSDD_STRICT_EPHEMERAL (only the exact value 0 opts out) and SOURCE_ROOT.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec verify block "$@"
