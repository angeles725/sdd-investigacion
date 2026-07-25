#!/usr/bin/env bash
#
# run-all.sh — central test runner for the research-sdd toolbelt test suites.
#
# What it does:
#   Auto-discovers every test suite living NEXT TO this script and runs them all,
#   streaming each suite's output while aggregating a final pass/fail report.
#     * *.test.sh  suites are run with `bash <file>`
#     * *.test.mjs suites are run with `node <file>`
#   Suites are discovered dynamically (glob), so a new suite dropped into this
#   directory is picked up automatically — nothing is hardcoded.
#
# Usage:
#   ./run-all.sh [--prove-teeth]
#
#   --prove-teeth   Forwarded ONLY to the *.test.sh suites (mutation self-test /
#                   negative control). It is NEVER passed to the .mjs suite,
#                   which has no such flag and whose teeth check always runs.
#
# Per-suite exit codes (honored for suite-level outcome):
#   0 = all tests passed
#   1 = some test failed
#   2 = harness error (script-under-test missing)
# The exit-2 harness-error convention is honored WHEN a suite emits it — the
# shell suites do (they exit 2 when their SUT is missing). A node suite that
# fails to resolve its module cannot practically reach exit 2 (a missing static
# import crashes node with exit 1), so that case surfaces as an ordinary failure.
#
# Runner exit code:
#   0 if no suite failed AND at least one suite passed (skipped ≠ passed).
#   1 if any suite failed, or if all suites were skipped (no real coverage).

set -uo pipefail

# --- Locate our own directory (CWD-independent) ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Optional flag --------------------------------------------------------
# No arg = fine; --prove-teeth = enable teeth mode; anything else is rejected so
# a typo (e.g. --prove-teath) can't silently disable teeth while reporting green.
PROVE_TEETH=""
if [[ -n "${1:-}" ]]; then
  if [[ "$1" == "--prove-teeth" ]]; then
    PROVE_TEETH="--prove-teeth"
  else
    echo "unknown flag: $1; usage: run-all.sh [--prove-teeth]" >&2
    exit 2
  fi
fi

# --- Discover suites deterministically ------------------------------------
shopt -s nullglob
sh_suites=("$SCRIPT_DIR"/*.test.sh)
mjs_suites=("$SCRIPT_DIR"/*.test.mjs)
shopt -u nullglob

# Merge and sort for deterministic order.
all_suites=()
for f in "${sh_suites[@]}" "${mjs_suites[@]}"; do
  all_suites+=("$f")
done

if [[ ${#all_suites[@]} -eq 0 ]]; then
  echo "run-all.sh: no test suites (*.test.sh / *.test.mjs) found in $SCRIPT_DIR" >&2
  exit 1
fi

# Sort by basename for stable, readable ordering.
mapfile -t all_suites < <(printf '%s\n' "${all_suites[@]}" | sort)

# --- Summary line matcher -------------------------------------------------
# Exact format printed by every suite (separator is U+00B7 MIDDLE DOT):
#   == <N> passed · <N> failed ==
summary_re='^== ([0-9]+) passed · ([0-9]+) failed ==$'

# --- Aggregators ----------------------------------------------------------
suites_run=0
suites_ok=0
total_passed=0
total_failed=0
failed_suites=()    # "basename (exit N)" entries for the report
suites_skipped=()   # basenames of suites that emitted a SKIP: line and exited 0

tmp_out="$(mktemp)"
trap 'rm -f "$tmp_out"' EXIT

for suite in "${all_suites[@]}"; do
  base="$(basename "$suite")"
  suites_run=$((suites_run + 1))

  echo "==============================================================="
  echo ">>> running: $base"
  echo "==============================================================="

  # Build the command. Only *.test.sh suites accept --prove-teeth.
  # A direct pipe to `tee` streams output AND captures it; the pipeline waits
  # for `tee` to finish, so the temp file is fully written before we parse it.
  # PIPESTATUS[0] is the SUITE's exit code (not tee's) — reliable under pipefail.
  if [[ "$base" == *.test.mjs ]]; then
    # Node ESM suite: no shebang, no +x — must be invoked via `node`.
    node "$suite" 2>&1 | tee "$tmp_out"
    rc=${PIPESTATUS[0]}
  else
    # Shell suite: run with bash; forward the flag only when set.
    if [[ -n "$PROVE_TEETH" ]]; then
      bash "$suite" "$PROVE_TEETH" 2>&1 | tee "$tmp_out"
    else
      bash "$suite" 2>&1 | tee "$tmp_out"
    fi
    rc=${PIPESTATUS[0]}
  fi

  # Parse the LAST matching summary line from the captured output.
  parsed_line=""
  while IFS= read -r line; do
    if [[ "$line" =~ $summary_re ]]; then
      parsed_line="$line"
      s_passed="${BASH_REMATCH[1]}"
      s_failed="${BASH_REMATCH[2]}"
    fi
  done < "$tmp_out"

  if [[ -n "$parsed_line" ]]; then
    total_passed=$((total_passed + s_passed))
    total_failed=$((total_failed + s_failed))
  fi

  # Suite-level outcome is driven by the EXIT CODE, not the parsed counts.
  # A suite that exits 0 with a "SKIP:" line on stdout is classified as skipped,
  # not passed — the signal is already established across the test suite set.
  if [[ "$rc" -eq 0 ]] && grep -q '^SKIP:' "$tmp_out"; then
    suites_skipped+=("$base")
  else
    case "$rc" in
      0)
        suites_ok=$((suites_ok + 1))
        ;;
      2)
        failed_suites+=("$base (HARNESS ERROR, exit 2)")
        ;;
      *)
        if [[ -n "$parsed_line" ]]; then
          failed_suites+=("$base (exit $rc)")
        else
          failed_suites+=("$base (exit $rc, no summary parsed)")
        fi
        ;;
    esac
  fi

  echo
done

# --- Final aggregate block ------------------------------------------------
suites_failed=$((suites_run - suites_ok - ${#suites_skipped[@]}))

echo "==============================================================="
echo "AGGREGATE RESULT"
echo "==============================================================="
echo "Suites run:    $suites_run"
echo "Suites passed: $suites_ok"
echo "Suites failed: $suites_failed"
echo "Suites skipped: ${#suites_skipped[@]}"
if [[ ${#failed_suites[@]} -gt 0 ]]; then
  echo "Failed suites:"
  for fs in "${failed_suites[@]}"; do
    echo "  - $fs"
  done
fi
if [[ ${#suites_skipped[@]} -gt 0 ]]; then
  echo "Skipped suites:"
  for ss in "${suites_skipped[@]}"; do
    echo "  - $ss"
  done
fi
echo "Test cases passed: $total_passed"
echo "Test cases failed: $total_failed"
echo "==============================================================="

# Exit 0 only if no suite failed AND at least one suite actually passed.
# A fully-skipped run (suites_ok == 0) exits 1 — zero test coverage is not "all green".
if [[ $suites_failed -eq 0 ]] && [[ $suites_ok -gt 0 ]]; then
  exit 0
else
  exit 1
fi
