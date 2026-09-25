#!/usr/bin/env bash
#
# run-all.sh — central test runner for the research-sdd toolbelt test suites.
#
# What it does:
#   Auto-discovers every test suite living NEXT TO this script AND every suite under
#   research-sdd/install/tests/ (kit issue #1126: that tree is a separate corpus CI already
#   runs but this gate did not — a PR could be green on every local gate and still fail CI),
#   and runs them all, streaming each suite's output while aggregating a final pass/fail
#   report. The two corpora are declared separately in the output (§7: a merged total alone
#   would hide which tree was actually traversed) but run as ONE gate command.
#     * *.test.sh  suites are run with `bash <file>`
#     * *.test.mjs suites are run with `node <file>`
#   Suites are discovered dynamically (glob), so a new suite dropped into either directory
#   is picked up automatically — nothing is hardcoded.
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
#   0 if no suite failed AND at least one suite passed (skipped ≠ passed) AND the
#     research-sdd/install/tests corpus was actually found (see below).
#   1 if any suite failed, all suites were skipped (no real coverage), a hermeticity
#     violation was detected, OR the install-tests corpus is ABSENT-INPUT (kit issue
#     #1144: a moved/renamed research-sdd/install/tests must fail the gate loudly, not
#     silently pass on the toolbelt corpus alone — an EMPTY install/tests dir, by
#     contrast, is not a failure by itself; it is reported as "= 0 suite(s)").

set -uo pipefail

# --- Locate our own directory (CWD-independent) ---------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Hermeticity guard (kit issue #1032; hardened per #1118 review rounds 2-3) --------------
# Suites are invoked as `bash "$suite" ...` with NO cd, so a suite's own unguarded
# redirection lands in the CALLER's cwd (wherever run-all.sh itself was invoked from) —
# NOT under $SCRIPT_DIR. kit issue #1032: an unquoted bash ${var/pat/repl} replacement in
# stage-retro.test.sh corrupted into a bare `> git` redirection that left a stray file named
# `git` at the caller's cwd.
#
# SCOPE: TOP-LEVEL entries of the caller's cwd only — a suite that leaks nested inside a
# subdirectory it created itself is outside this enumerator (cheap: -maxdepth 1, no recursion).
# REGULAR FILES (and symlinks/other non-directory types) are tracked by name + size + mtime,
# so this catches a leak onto a name that already existed at baseline (including a second `git`
# leak while the first stray `git` is still present — the exact #1032 state), an overwrite of an
# existing file, and the deletion of a pre-existing top-level file. It does NOT catch a rewrite
# that reproduces the exact same size and mtime within the same mtime tick — nanosecond
# resolution on this filesystem (ext4/WSL) makes that rare, but 1-2s-granularity filesystems
# (FAT, some NFS/SMB mounts) make a same-second, same-size rewrite plausible.
#
# DIRECTORIES are tracked by NAME ONLY (existence — added/removed), never by mtime: a
# directory's own mtime changes on ANY entry created or removed directly inside it, including by
# legitimate, read-adjacent operations a suite is expected to run — `git status` opportunistically
# refreshes the index via a lock+rename, which bumps `.git/`'s mtime, and the CodeGraph watcher's
# `-wal`/`-shm` files bump `.codegraph/`'s. Tracking directory mtime would flag both on every run
# (round-2 review, reproduced from a non-worktree checkout root). A top-level directory being
# REPLACED by a different directory of the same name is therefore invisible to this guard.
#
# QUIET-TREE PRECONDITION (CLAUDE.md §3, same as every other gate in this kit): a concurrent
# writer to the caller's cwd (an editor, a second run-all.sh, another session) that touches a
# top-level entry gets attributed to whichever suite happens to be running at that moment.
#
# DEGRADED STATE (§7: absent/unreadable/unscannable input must never read as a confident 0):
# DEGRADED (not "0 violations", failing the run) is reported when either: the caller's cwd is
# not a readable, traversable directory; or the scanner itself cannot run — `find -printf` is a
# GNU extension absent on BSD/macOS find, and a scan whose exit status is never checked is
# exactly the "could it run at all" silent-zero this doctrine exists to prevent (round-2 review:
# a stubbed `find` rejecting -printf left a real leak unreported, `rc=0`).
CALLER_CWD="$(pwd)"
hermeticity_violations=()   # "<suite basename> leaked: <entry> (new|modified|removed)"
HERMETICITY_DEGRADED=0
# HERMETICITY_DEGRADED_REASON: the human-readable cause of a DEGRADED state, captured at the
# point of detection and echoed verbatim in the final aggregate block (kit issue #1121, Opus
# round-3 review of #1118 finding #1: the aggregate used to print the SAME "caller cwd was not
# readable/traversable" text regardless of WHICH of the two distinct guards degraded — an
# unreadable cwd and a failed/unsupported scanner are different failures and need different text.
HERMETICITY_DEGRADED_REASON=""
if [[ ! -d "$CALLER_CWD" ]] || [[ ! -r "$CALLER_CWD" ]] || [[ ! -x "$CALLER_CWD" ]]; then
  HERMETICITY_DEGRADED=1
  HERMETICITY_DEGRADED_REASON="caller cwd '$CALLER_CWD' is not a readable/traversable directory"
  echo "run-all.sh: WARNING: hermeticity guard DEGRADED — caller cwd '$CALLER_CWD' is not a readable/traversable directory; cannot verify suites stay hermetic" >&2
fi
_refresh_cwd_entries() {
  # Populates the associative array NAMED BY $1 (bash nameref) with "<name>" -> identity, where
  # identity is "d" for a directory (name-only tracking) or "<size>:<mtime>" otherwise. Returns 1
  # (array left UNTOUCHED) if the scan itself fails for any reason — an unsupported `find -printf`
  # flag, a transient error, etc. — so a scan that could not run is never mistaken for "found
  # nothing" by the caller.
  # STDOUT ONLY (kit issue #1121, #1118 review NIT): a successful find (rc=0) that ALSO prints a
  # warning to stderr must never have that warning merged into the parsed TSV stream — it would
  # be read as a phantom top-level entry name. stderr is left to flow to the real terminal.
  local -n _target="$1"
  local _out _rc _name _type _size _mtime
  _out="$(find "$CALLER_CWD" -mindepth 1 -maxdepth 1 -printf '%f\t%y\t%s\t%T@\n')"
  # SENTINEL-SCANNER-RC-CHECK
  _rc=$?
  [[ $_rc -eq 0 ]] || return 1
  _target=()
  while IFS=$'\t' read -r _name _type _size _mtime; do
    [[ -n "$_name" ]] || continue
    if [[ "$_type" == d ]]; then
      # SENTINEL-DIR-NAME-ONLY-TRACKING
      _target["$_name"]="d"
    else
      _target["$_name"]="$_size:$_mtime"
    fi
  done <<< "$_out"
  return 0
}
declare -A _prev_entries=()
if [[ "$HERMETICITY_DEGRADED" -eq 0 ]] && ! _refresh_cwd_entries _prev_entries; then
  HERMETICITY_DEGRADED=1
  HERMETICITY_DEGRADED_REASON="the cwd scanner ('find -printf', a GNU extension) failed or is unsupported on this platform"
  echo "run-all.sh: WARNING: hermeticity guard DEGRADED — the cwd scanner ('find -printf', a GNU extension) failed or is unsupported on this platform; cannot verify suites stay hermetic" >&2
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

# --- Second corpus: research-sdd/install/tests/ (kit issue #1126) ---------
# Resolved relative to this script (research-sdd/toolbelt/tests -> research-sdd/install/tests),
# never assumed from the caller's cwd. Declared distinctly from the toolbelt corpus below (§7:
# absent-input for this tree is reported loudly, not silently folded into "0 more suites").
INSTALL_TESTS_DIR="$(cd "$SCRIPT_DIR/../../install/tests" 2>/dev/null && pwd)"
install_sh_suites=()
install_mjs_suites=()
INSTALL_TESTS_DEGRADED=0
if [[ -z "$INSTALL_TESTS_DIR" ]]; then
  INSTALL_TESTS_DEGRADED=1
  echo "run-all.sh: WARNING: install-tests corpus ABSENT-INPUT — research-sdd/install/tests not found relative to $SCRIPT_DIR; that corpus was NOT traversed; the run will exit non-zero even if every discovered suite passes (kit issue #1144: a missing/renamed corpus must not read as a silent pass)" >&2
else
  shopt -s nullglob
  install_sh_suites=("$INSTALL_TESTS_DIR"/*.test.sh)
  install_mjs_suites=("$INSTALL_TESTS_DIR"/*.test.mjs)
  shopt -u nullglob
fi

# Merge and sort for deterministic order.
all_suites=()
# SENTINEL-CORPUS-MERGE
for f in "${sh_suites[@]}" "${mjs_suites[@]}" "${install_sh_suites[@]}" "${install_mjs_suites[@]}"; do
  all_suites+=("$f")
done

if [[ ${#all_suites[@]} -eq 0 ]]; then
  echo "run-all.sh: no test suites (*.test.sh / *.test.mjs) found in $SCRIPT_DIR or ${INSTALL_TESTS_DIR:-<install/tests absent>}" >&2
  exit 1
fi

# Sort by FULL PATH for a stable, deterministic order (kit issue #1144 review: this comment
# previously said "by basename", which was only true when every suite lived in one directory;
# with two corpora it sorts by full path, so "research-sdd/install/..." suites sort before
# "research-sdd/toolbelt/..." suites lexically. Harmless — still fully deterministic — but the
# install corpus now runs FIRST, not interleaved by suite name).
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
    if ! _refresh_cwd_entries _cur_entries; then
      HERMETICITY_DEGRADED=1
      HERMETICITY_DEGRADED_REASON="the cwd scanner failed mid-run (after $base)"
      echo "run-all.sh: WARNING: hermeticity guard DEGRADED mid-run (after $base) — the cwd scanner failed; cannot verify remaining suites stay hermetic" >&2
    else
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
echo "Corpus: toolbelt tests ($SCRIPT_DIR) = $((${#sh_suites[@]} + ${#mjs_suites[@]})) suite(s)"
if [[ "$INSTALL_TESTS_DEGRADED" -eq 1 ]]; then
  echo "Corpus: install tests — ABSENT-INPUT (research-sdd/install/tests not found; NOT traversed; run exits non-zero)"
else
  echo "Corpus: install tests ($INSTALL_TESTS_DIR) = $((${#install_sh_suites[@]} + ${#install_mjs_suites[@]})) suite(s)"
fi
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
  echo "Hermeticity: DEGRADED — ${HERMETICITY_DEGRADED_REASON:-cause not recorded}; could not verify"
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
   && [[ ${#hermeticity_violations[@]} -eq 0 ]] && [[ "$HERMETICITY_DEGRADED" -eq 0 ]] \
   && [[ "$INSTALL_TESTS_DEGRADED" -eq 0 ]]; then
  # SENTINEL-REQUIRE-TEETH-EXIT
  if [[ -n "$REQUIRE_TEETH" ]] && [[ ${#sh_no_teeth[@]} -gt 0 ]]; then
    exit 1
  fi
  exit 0
else
  exit 1
fi
