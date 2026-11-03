#!/usr/bin/env bash
# Ported to Go: `rsdd sweep audits`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2577).
# sweep-audits.sh — surfaces un-reviewed §13 audit reports across ALL research-sdd targets, so no audit-delta
# (certainty or coverage) sits unacted-upon (METHODOLOGY §13). Mirror of sweep-retros.sh.
# An audit under <target>/audits/*.md is PENDING unless its leading comment block carries a closing marker,
# '<!-- review-status: applied ... -->' or '<!-- review-status: dismissed ... -->'. The PENDING queue is oldest first.
# Read-only: it never edits a target (audits act on the TARGET, so there is no stage/branch/PR path here).
# Usage: sweep-audits.sh   (run from anywhere; the target list is the kit's TARGETS.md)
# Exit: 0 always for findings; 1 when the sweep could not run (no TARGETS.md, no usable target path).
# The kit swept is this script's own checkout, passed explicitly because the binary cannot see this file's directory.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec sweep audits --kit "$_RSDD_SELF/.." "$@"
