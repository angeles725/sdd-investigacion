#!/usr/bin/env bash
# sweep-all.sh — aggregator: run all eight canonical Research-SDD session-start sweep scripts
# in sequence, capture each exit status, print a clear per-script PASS/FAIL banner, and exit
# non-zero if ANY script failed.
#
# WHY THIS EXISTS (U-A20): Pi and gentle-shell have no session-start hook, so the sweep scripts must be
# run manually. This shim collapses eight commands into one, raising compliance probability.
# Claude runs the same eight scripts automatically via its session-start hook —
# this aggregator is intended for manual, Pi or gentle-shell use; it is harmless (but redundant) in Claude.
# (OpenCode support was dropped on 2026-09-23 #954.)
#
# Each script runs INDEPENDENTLY: a failure or timeout is captured and reported, but NEVER
# aborts the remaining scripts. All eight always run. Exit is non-zero if ANY failed.
#
# Timeout: each script is run under `timeout $RSDD_SWEEP_TIMEOUT` (default 30 s, mirroring
# the Claude SessionStart hook timeouts of 15–30 s).
# A killed script is reported as FAIL (timed out) and the remaining scripts still run.
#
# Read-only / degrade-to-silence invariants:
#   - All eight underlying scripts are read-only audits; sweep-all.sh never mutates anything.
#   - A missing or non-executable script is reported as FAIL; the others still run.
#   - Stderr from each script is merged into stdout so all output is visible.
#
# Usage: toolbelt/sweep-all.sh
# Exit : 0 all eight scripts passed · non-zero at least one script failed or timed out
# Env  : RSDD_SWEEP_TIMEOUT  per-script timeout in seconds (default 30)

set -uo pipefail

# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
TOOLBELT="$_RSDD_SELF"

SCRIPTS=(
  "$TOOLBELT/sweep-retros.sh"
  "$TOOLBELT/sweep-audits.sh"
  "$TOOLBELT/sweep-breakthroughs.sh"
  "$TOOLBELT/verify-registry.sh"
  "$TOOLBELT/verify-kit-clean.sh"
  "$TOOLBELT/sweep-tools.sh"
  "$TOOLBELT/verify-tool-catalog.sh"
  "$TOOLBELT/verify-skill-drift.sh"
)

TIMEOUT="${RSDD_SWEEP_TIMEOUT:-30}"

overall=0
results=()

for script in "${SCRIPTS[@]}"; do
  name="$(basename "$script")"
  echo ""
  echo "========================================"
  echo "== $name"
  echo "========================================"

  if [ ! -f "$script" ]; then
    echo "FAIL  $name (script not found: $script)" >&2
    overall=1
    results+=("FAIL  $name (not found)")
    continue
  fi

  rc=0
  timeout "$TIMEOUT" bash "$script" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    echo ""
    echo "PASS  $name"
    results+=("PASS  $name")
  elif [ "$rc" -eq 124 ]; then
    echo ""
    echo "FAIL  $name (timed out after ${TIMEOUT}s)"
    results+=("FAIL  $name (timed out)")
    overall=1
  else
    echo ""
    echo "FAIL  $name (exit $rc)"
    results+=("FAIL  $name (exit $rc)")
    overall=1
  fi
done

echo ""
echo "========================================"
echo "== sweep-all summary"
echo "========================================"
for r in "${results[@]}"; do
  echo "  $r"
done

exit "$overall"
