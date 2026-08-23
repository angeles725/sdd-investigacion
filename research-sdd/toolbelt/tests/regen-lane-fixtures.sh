#!/usr/bin/env bash
# regen-lane-fixtures.sh — regenerate lane fixture files for test suites.
#
# Each test suite that uses the fast/slow lane pattern captures real-tool output
# under tests/fixtures/lane/<suite>/<name>.json when run in RSDD_TEST_LANE=slow.
# This script is the ONLY place where the real tool must be present.  In fast
# lane, suites load these fixtures instead of spawning the tool.
#
# Usage:
#   bash regen-lane-fixtures.sh [--suite <suite-name>] [--lane <slow|all>] [--dry-run]
#
#   --suite <name>    Regenerate fixtures only for the named suite.
#                     If omitted, regenerates for ALL registered suites.
#   --lane <slow|all> Lane to run during regeneration (default: slow).
#                     Use "all" to also run fast-path assertions as a sanity check.
#   --dry-run         Print the commands that WOULD be executed; do not write files.
#
# Layout:
#   tests/fixtures/lane/<suite>/<name>.json
#
# Adding a new suite:
#   1. Add a regen_<suite>() function below that invokes the real tool and writes
#      its output via write_fixture().
#   2. Add the suite name to the KNOWN_SUITES list.
#   3. Run this script to generate the initial fixtures.
#
# Containment guards (bwrap / qemu / docker flags) are ALWAYS asserted even during
# slow-lane runs — only the tool spawn itself moves from fixture to real execution.
#
# Anti-#128 rule: fast-lane suites must NEVER emit SKIP: lines; they must always
# produce a normal "== N passed · N failed ==" summary.  Fixtures provide the data;
# containment contract is still verified in fast lane.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_BASE="$SCRIPT_DIR/fixtures/lane"

# --- Parse arguments ----------------------------------------------------------
SUITE_FILTER=""
REGEN_LANE="slow"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite)
      SUITE_FILTER="${2:-}"
      shift 2
      ;;
    --lane)
      REGEN_LANE="${2:-slow}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "unknown flag: $1" >&2
      echo "Usage: regen-lane-fixtures.sh [--suite <name>] [--lane <slow|all>] [--dry-run]" >&2
      exit 2
      ;;
  esac
done

case "$REGEN_LANE" in
  slow|all) ;;
  *)
    echo "regen-lane-fixtures: --lane must be slow or all (got: $REGEN_LANE)" >&2
    exit 2
    ;;
esac

# --- Registered suites --------------------------------------------------------
# Add new suite names here when adding a regen_<suite>() function below.
KNOWN_SUITES=(
  # Example placeholder — replace with real suite names as each PR converts a suite.
  # corroborate-ghidra
  # corroborate-native-r2
)

# --- Helpers ------------------------------------------------------------------

write_fixture() {
  local suite="$1" name="$2" content="$3"
  local dest="${FIXTURE_BASE}/${suite}/${name}.json"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would write: $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" > "$dest"
  echo "wrote: $dest"
}

# --- Per-suite regen functions ------------------------------------------------
# Each function receives no arguments.  It must invoke the real tool in slow lane
# and call write_fixture() for every fixture it produces.
#
# Template:
#
# regen_corroborate_ghidra() {
#   local output rc=0
#   output="$(RSDD_TEST_LANE=slow bash "$SCRIPT_DIR/corroborate-ghidra.test.sh" 2>&1)" || rc=$?
#   # Parse or capture the relevant output into JSON fixture format.
#   write_fixture "corroborate-ghidra" "baseline" \
#     "$(printf '{"exit":%d,"output":%s}' "$rc" "$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")"
# }

# --- Main ---------------------------------------------------------------------

if [[ ${#KNOWN_SUITES[@]} -eq 0 ]]; then
  echo "regen-lane-fixtures: no suites registered yet." >&2
  echo "  Add a regen_<suite>() function and a KNOWN_SUITES entry to register one." >&2
  exit 0
fi

ran=0
skipped=0

for suite in "${KNOWN_SUITES[@]}"; do
  if [[ -n "$SUITE_FILTER" && "$suite" != "$SUITE_FILTER" ]]; then
    skipped=$((skipped + 1))
    continue
  fi

  # Derive function name: replace hyphens with underscores.
  fn="regen_${suite//-/_}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    echo "WARNING: no regen function $fn for suite $suite — skipping" >&2
    skipped=$((skipped + 1))
    continue
  fi

  echo "--- regenerating fixtures for: $suite (lane=$REGEN_LANE) ---"
  "$fn"
  ran=$((ran + 1))
done

echo ""
echo "regen-lane-fixtures: ran=$ran skipped=$skipped lane=$REGEN_LANE dry_run=$DRY_RUN"
