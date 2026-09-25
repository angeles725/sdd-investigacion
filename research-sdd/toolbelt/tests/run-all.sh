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
#   ./run-all.sh [--prove-teeth|--require-teeth]
#
#   --prove-teeth    Forwarded to the *.test.sh suites (mutation self-test /
#                    negative control). Node suites are n/a (they have no flag).
#                    Reports "Suites without teeth" in the aggregate block.
#   --require-teeth  Implies --prove-teeth; exits 1 when any *.test.sh suite
#                    lacks teeth (opt-in stricter gate; default behavior unchanged).
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

# --- Hermeticity guard (kit issue #1032; hardened per #1118 review) -------
# Suites are invoked as `bash "$suite" ...` with NO cd, so a suite's own unguarded
# redirection lands in the CALLER's cwd (wherever run-all.sh itself was invoked from) —
# NOT under $SCRIPT_DIR. kit issue #1032: an unquoted bash ${var/pat/repl} replacement in
# stage-retro.test.sh corrupted into a bare `> git` redirection that left a stray file named
# `git` at the caller's cwd.
#
# SCOPE: TOP-LEVEL entries of the caller's cwd only — a suite that leaks nested inside a
# subdirectory it created itself is outside this enumerator (cheap: -maxdepth 1, no recursion).
# Each entry is tracked by name + size + mtime (not name alone), so this ALSO catches: a leak
# onto a name that already existed at baseline (including a second `git` leak while the first
# stray `git` is still present — the exact #1032 state), an overwrite of an existing entry, and
# the deletion of a pre-existing top-level entry. It does NOT catch a rewrite that reproduces
# the exact same size and mtime (astronomically unlikely) or a content-only change with
# unchanged size and mtime.
#
# QUIET-TREE PRECONDITION (CLAUDE.md §3, same as every other gate in this kit): a concurrent
# writer to the caller's cwd (an editor, a second run-all.sh, another session) that touches a
# top-level entry gets attributed to whichever suite happens to be running at that moment.
#
# DEGRADED STATE (§7: absent/unreadable input must never read as a confident 0): if the caller's
# cwd is not a readable, traversable directory, the guard cannot look at all — it reports
# DEGRADED (not "0 violations") and fails the run rather than silently passing.
CALLER_CWD="$(pwd)"
hermeticity_violations=()   # "<suite basename> leaked: <entry> (new|modified|removed)"
HERMETICITY_DEGRADED=0
if [[ ! -d "$CALLER_CWD" ]] || [[ ! -r "$CALLER_CWD" ]] || [[ ! -x "$CALLER_CWD" ]]; then
  HERMETICITY_DEGRADED=1
  echo "run-all.sh: WARNING: hermeticity guard DEGRADED — caller cwd '$CALLER_CWD' is not a readable/traversable directory; cannot verify suites stay hermetic" >&2
fi
_scan_cwd_top_level() {
  # Emits "<name>\t<size>\t<mtime>" per top-level entry of $CALLER_CWD, one per line.
  find "$CALLER_CWD" -mindepth 1 -maxdepth 1 -printf '%f\t%s\t%T@\n' 2>/dev/null
}
declare -A _prev_entries=()
if [[ "$HERMETICITY_DEGRADED" -eq 0 ]]; then
  while IFS=$'\t' read -r _name _size _mtime; do
    [[ -n "$_name" ]] || continue
    _prev_entries["$_name"]="$_size:$_mtime"
  done < <(_scan_cwd_top_level)
fi

# --- Optional flags -------------------------------------------------------
# No arg = fine; a valid flag = enable that mode; anything else is rejected so
# a typo (e.g. --prove-teath) can't silently disable teeth while reporting green.
PROVE_TEETH=""
REQUIRE_TEETH=""
if [[ -n "${1:-}" ]]; then
  case "$1" in
    --prove-teeth)
      PROVE_TEETH="--prove-teeth"
      ;;
    --require-teeth)
      PROVE_TEETH="--prove-teeth"
      REQUIRE_TEETH=1
      ;;
    *)
      echo "unknown flag: $1; usage: run-all.sh [--prove-teeth|--require-teeth]" >&2
      exit 2
      ;;
  esac
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
total_skipped=0     # count of per-test "  SKIP  " lines across all suites
failed_suites=()    # "basename (exit N)" entries for the report
suites_skipped=()   # basenames of suites that emitted a SKIP: line and exited 0
# Teeth-tracking (populated only under --prove-teeth; empty under plain run).
sh_no_teeth=()         # stripped basenames: 0 banners, no flag handling in source
sh_teeth_nobanner=()   # stripped basenames: handles flag in source, 0 banners at runtime

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

  # --- Hermeticity check: did THIS suite leak/modify/delete a top-level cwd entry? ---
  # SENTINEL-HERMETICITY-CHECK
  if [[ "$HERMETICITY_DEGRADED" -eq 0 ]]; then
    declare -A _cur_entries=()
    while IFS=$'\t' read -r _name _size _mtime; do
      [[ -n "$_name" ]] || continue
      _cur_entries["$_name"]="$_size:$_mtime"
    done < <(_scan_cwd_top_level)
    for _name in "${!_cur_entries[@]}"; do
      if [[ "${_prev_entries[$_name]+set}" != "set" ]]; then
        hermeticity_violations+=("$base leaked: $_name (new)")
      elif [[ "${_prev_entries[$_name]}" != "${_cur_entries[$_name]}" ]]; then
        hermeticity_violations+=("$base leaked: $_name (modified)")
      fi
    done
    for _name in "${!_prev_entries[@]}"; do
      if [[ "${_cur_entries[$_name]+set}" != "set" ]]; then
        hermeticity_violations+=("$base leaked: $_name (removed)")
      fi
    done
    # SENTINEL-HERMETICITY-ROLLFORWARD (without it, a later suite is re-blamed for an earlier leak)
    _prev_entries=()
    for _k in "${!_cur_entries[@]}"; do _prev_entries["$_k"]="${_cur_entries[$_k]}"; done
  fi

  # Parse the LAST matching summary line from the captured output.
  # Also accumulate per-test skip lines ("  SKIP  ..." indented format).
  parsed_line=""
  while IFS= read -r line; do
    if [[ "$line" =~ $summary_re ]]; then
      parsed_line="$line"
      s_passed="${BASH_REMATCH[1]}"
      s_failed="${BASH_REMATCH[2]}"
    elif [[ "$line" == "  SKIP  "* ]]; then
      total_skipped=$((total_skipped + 1))
    fi
  done < "$tmp_out"

  if [[ -n "$parsed_line" ]]; then
    total_passed=$((total_passed + s_passed))
    total_failed=$((total_failed + s_failed))
  fi

  # --- Teeth-banner detection (--prove-teeth only; .test.sh suites only) ----
  # Runtime: grep captured output for banner lines emitted under --prove-teeth.
  # Static: grep suite source for flag-handling keyword to classify no-banner suites.
  if [[ -n "$PROVE_TEETH" && "$base" == *.test.sh ]]; then
    base_noext="${base%.test.sh}"
    if grep -qEi '^[[:space:]]*(--|==)[[:space:]]*teeth\b' "$tmp_out" 2>/dev/null; then
      : # has teeth banners — no tracking needed
    elif grep -qE '(--prove-teeth|PROVE_TEETH)' "$suite" 2>/dev/null; then
      sh_teeth_nobanner+=("$base_noext")
    else
      sh_no_teeth+=("$base_noext")
    fi
  fi

  # Suite-level outcome is driven by the EXIT CODE, not the parsed counts.
  # Classification priority (checked in order):
  #   1. SKIP: A suite that exits 0 with a "SKIP:" line is classified as skipped.
  #      Per-test skips use the indented "  SKIP  ..." form counted in total_skipped.
  #   2. HARNESS ERROR: exit 2 (script-under-test missing) reported distinctly.
  #   3. UNPARSED: any non-skip suite that contributed no parsed result must be
  #      named and fail the run. Three distinct states:
  #        no output      — tmp_out is empty (e.g. killed worker)
  #        malformed      — output contains a summary-like line that did not match
  #        no summary     — output is non-empty but has no summary-like line at all
  #   4. ZERO CASES: exit 0 with a parsed 0/0 summary is failed as no coverage.
  #   5. Normal pass/fail by exit code.
  if [[ "$rc" -eq 0 ]] && grep -q '^SKIP:' "$tmp_out"; then
    suites_skipped+=("$base")
  elif [[ "$rc" -eq 2 ]]; then
    failed_suites+=("$base (HARNESS ERROR, exit 2)")
  elif [[ -z "$parsed_line" ]]; then
    if [[ ! -s "$tmp_out" ]]; then
      failed_suites+=("$base (no output, exit $rc)")
    elif grep -qiE 'passed.*failed|failed.*passed' "$tmp_out"; then
      failed_suites+=("$base (malformed summary, exit $rc)")
    else
      failed_suites+=("$base (no summary line, exit $rc)")
    fi
  elif [[ -n "$parsed_line" && "$rc" -eq 0 && "$s_passed" -eq 0 && "$s_failed" -eq 0 ]]; then
    failed_suites+=("$base (zero test cases, exit 0)")
  else
    case "$rc" in
      0)
        suites_ok=$((suites_ok + 1))
        ;;
      *)
        failed_suites+=("$base (exit $rc)")
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
echo "Test cases skipped: $total_skipped"
echo "Test cases failed: $total_failed"
if [[ "$HERMETICITY_DEGRADED" -eq 1 ]]; then
  echo "Hermeticity: DEGRADED — caller cwd was not readable/traversable; could not verify"
else
  echo "Hermeticity violations (new/modified/removed top-level entries in caller cwd): ${#hermeticity_violations[@]}"
  if [[ ${#hermeticity_violations[@]} -gt 0 ]]; then
    echo "  (a suite must not leak, overwrite, or delete top-level entries in the caller's cwd — kit issue #1032)"
    _hv_sorted=()
    mapfile -t _hv_sorted < <(printf '%s\n' "${hermeticity_violations[@]}" | LC_ALL=C sort)
    for hv in "${_hv_sorted[@]}"; do
      echo "  - $hv"
    done
  fi
fi
# --- Teeth report (--prove-teeth / --require-teeth only) ------------------
if [[ -n "$PROVE_TEETH" ]]; then
  # Sort the tracked lists.
  _nt_sorted=(); if [[ ${#sh_no_teeth[@]} -gt 0 ]]; then
    mapfile -t _nt_sorted < <(printf '%s\n' "${sh_no_teeth[@]}" | sort)
  fi
  _nb_sorted=(); if [[ ${#sh_teeth_nobanner[@]} -gt 0 ]]; then
    mapfile -t _nb_sorted < <(printf '%s\n' "${sh_teeth_nobanner[@]}" | sort)
  fi
  # Build comma-separated name strings.
  _nt_names=""; for _n in "${_nt_sorted[@]}"; do _nt_names="${_nt_names:+$_nt_names, }$_n"; done
  _nb_names=""; for _n in "${_nb_sorted[@]}"; do _nb_names="${_nb_names:+$_nb_names, }$_n"; done
  # SENTINEL-NO-TEETH-BANNER
  echo "Suites without teeth: ${#_nt_sorted[@]} — [$_nt_names]"
  echo "(vocabulary check: a \"teeth\" case with no real mutant is a review item)"
  echo "Suites n/a for teeth (node): ${#mjs_suites[@]}"
  if [[ ${#_nb_sorted[@]} -gt 0 ]]; then
    echo "Suites with teeth but no banner: ${#_nb_sorted[@]} — [$_nb_names]"
  fi
fi
echo "==============================================================="

# Exit 0 only if no suite failed AND at least one suite actually passed.
# A fully-skipped run (suites_ok == 0) exits 1 — zero test coverage is not "all green".
if [[ $suites_failed -eq 0 ]] && [[ $suites_ok -gt 0 ]] \
   && [[ ${#hermeticity_violations[@]} -eq 0 ]] && [[ "$HERMETICITY_DEGRADED" -eq 0 ]]; then
  # SENTINEL-REQUIRE-TEETH-EXIT
  if [[ -n "$REQUIRE_TEETH" ]] && [[ ${#sh_no_teeth[@]} -gt 0 ]]; then
    exit 1
  fi
  exit 0
else
  exit 1
fi
