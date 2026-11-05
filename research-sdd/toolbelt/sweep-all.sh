#!/usr/bin/env bash
# Ported to Go: `rsdd sweep all`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2664).
# sweep-all.sh — aggregator: run all eight canonical Research-SDD session-start sweep scripts
# in sequence, capture each exit status, print a clear per-script PASS/FAIL banner, and exit
# non-zero if ANY script failed.
#
# WHY THIS EXISTS (U-A20): Pi and gentle-shell have no session-start hook, so the sweep scripts must be
# run manually. This shim collapses eight commands into one, raising compliance probability.
# Claude runs the same eight scripts automatically via its session-start hook —
# this aggregator is intended for manual, Pi or gentle-shell use; it is harmless (but redundant) in Claude.
#
# Each script runs INDEPENDENTLY: a failure or timeout is captured and reported, but NEVER
# aborts the remaining scripts. All eight always run. Exit is non-zero if ANY failed.
# The eight scripts are listed in rsdd/internal/sweep/allscripts.go (tests/sweep-all.test.sh checks them against the
# kit's registered SessionStart hooks). Stderr of each script is merged into stdout; a missing script is a FAIL.
#
# Usage: toolbelt/sweep-all.sh
# Exit : 0 all eight scripts passed · non-zero at least one script failed or timed out
# Env  : RSDD_SWEEP_TIMEOUT  per-script timeout in seconds (default 30; a value that is not a positive number
#                            of seconds falls back to 30 with a warning line on stderr)
# The toolbelt run is this script's own checkout, passed explicitly because the binary cannot see this file's directory.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec sweep all --kit "$_RSDD_SELF/.." "$@"
