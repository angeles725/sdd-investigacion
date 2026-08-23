#!/usr/bin/env bash
# test-lane.sh — shared lane-selection helper for research-sdd test suites.
# Sourced (never executed); exports: rsdd_lane, rsdd_lane_fixture.
#
# Lane contract:
#   fast (default) — fixture-cached assertions; real tool NOT spawned.
#   slow           — real tool run; bwrap / containment guards still asserted.
#   all            — both fast and slow paths exercised.
#
# Env var: RSDD_TEST_LANE  (unset or empty → "fast")
# Anti-silent-zero (§7): any value outside the enum fails CLOSED — garbage must
# not silently degrade to a lane.

# Sourced only — refuse direct execution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "test-lane.sh is a source-only helper; do not execute it directly." >&2
  exit 1
fi

# Idempotent: safe to source more than once.
if ! declare -F rsdd_lane >/dev/null 2>&1; then

  # Capture lib dir at source time so the fixture resolver is cwd-independent.
  _RSDD_LANE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  _RSDD_LANE_TOOLBELT_DIR="$(dirname "$_RSDD_LANE_LIB_DIR")"

  # rsdd_lane
  #   Echo the active lane name: fast | slow | all.
  #   Reads $RSDD_TEST_LANE; defaults to "fast" when unset or empty.
  #   Returns non-zero (and emits an error to stderr) for any unrecognised value.
  rsdd_lane() {
    local v="${RSDD_TEST_LANE:-fast}"
    case "$v" in
      fast|slow|all)
        printf '%s\n' "$v"
        ;;
      *)
        printf 'test-lane: invalid RSDD_TEST_LANE=%s (allowed: fast slow all)\n' \
          "$v" >&2
        return 1
        ;;
    esac
  }

  # rsdd_lane_fixture <suite> <name>
  #   Echo the fixture path for a given suite and fixture name:
  #     <toolbelt>/tests/fixtures/lane/<suite>/<name>.json
  #   The file need not exist — path resolution only (the caller checks existence).
  rsdd_lane_fixture() {
    local suite="${1:-}" name="${2:-}"
    if [[ -z "$suite" || -z "$name" ]]; then
      printf 'test-lane: rsdd_lane_fixture requires <suite> and <name> arguments\n' >&2
      return 1
    fi
    printf '%s\n' \
      "${_RSDD_LANE_TOOLBELT_DIR}/tests/fixtures/lane/${suite}/${name}.json"
  }

fi
