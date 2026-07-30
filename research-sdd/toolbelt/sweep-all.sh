#!/usr/bin/env bash
# sweep-all.sh — aggregator: run all five canonical Research-SDD session-start sweep scripts
# in sequence, capture each exit status, print a clear per-script PASS/FAIL banner, and exit
# non-zero if ANY script failed.
#
# WHY THIS EXISTS (U-A20): Codex has no session-start hook, so the four sweep scripts must be
# run manually. This shim collapses four commands into one, raising compliance probability.
# Claude and OpenCode run the same four scripts automatically via their own hooks/plugins — this
# aggregator is intended for manual or Codex use; it is harmless (but redundant) elsewhere.
#
# Each script runs INDEPENDENTLY: a failure or timeout is captured and reported, but NEVER
# aborts the remaining scripts. All five always run. Exit is non-zero if ANY failed.
#
# Timeout: each script is run under `timeout $RSDD_SWEEP_TIMEOUT` (default 30 s, mirroring
# the Claude SessionStart hook timeouts of 15–30 s and the OpenCode plugin 20 s timeout).
# A killed script is reported as FAIL (timed out) and the remaining scripts still run.
#
# Read-only / degrade-to-silence invariants:
#   - All four underlying scripts are read-only audits; sweep-all.sh never mutates anything.
#   - A missing or non-executable script is reported as FAIL; the others still run.
#   - Stderr from each script is merged into stdout so all output is visible.
#
# Usage: toolbelt/sweep-all.sh
# Exit : 0 all five scripts passed · non-zero at least one script failed or timed out
# Env  : RSDD_SWEEP_TIMEOUT  per-script timeout in seconds (default 30)

set -uo pipefail

TOOLBELT="$(cd "$(dirname "$0")" && pwd)"

SCRIPTS=(
  "$TOOLBELT/sweep-retros.sh"
  "$TOOLBELT/sweep-audits.sh"
  "$TOOLBELT/verify-registry.sh"
  "$TOOLBELT/verify-kit-clean.sh"
  "$TOOLBELT/sweep-tools.sh"
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
