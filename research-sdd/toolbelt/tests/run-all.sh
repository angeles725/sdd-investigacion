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
#   ./run-all.sh [--prove-teeth|--require-teeth] [--require-clean-tmp] [-j N]
#
#   --require-clean-tmp  Exit 1 when any suite left entries in its per-suite TMPDIR (kit issue
#                    #1277). Every run creates ONE temp root (under the caller's TMPDIR, else /tmp),
#                    exports TMPDIR to a fresh subdir of it for each suite, removes the root on exit,
#                    and reports `TMPDIR leftovers: N — [suite: count]` (N = total entries). Without
#                    the flag the line is report-only; a root that could not be created or scanned is
#                    reported as DEGRADED (and fails under the flag), never as a confident 0.
#
#   -j N             Opt-in parallel run (kit issue #1463), N = 1..6; needs GNU parallel (absent ->
#                    typed DEGRADED line, serial run). Serial is the default and the reference.
#                    Hermeticity guards snapshot once around the batch; a leak found there triggers
#                    a serial re-run of only the candidate suites (those whose run window held the
#                    leaked path's mtime) names the suite; otherwise a typed batch label plus an
#                    `Attribution:` line saying why, never silently.
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
#     violation was detected (caller-cwd top level, or any file under research-sdd/ — #1156), OR the install-tests corpus is ABSENT-INPUT (kit issue
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
  # SENTINEL-SCANNER-STDOUT-ONLY
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

# --- Kit-tree hermeticity guard (kit issue #1156) ---------------------------------------------
# The cwd guard above only sees top-level entries of the CALLER's cwd. It cannot see a suite that
# writes INTO the repo tree — the install suite wrote research-sdd-install.MUTANT*.sh beside its
# SUT, so a concurrent shellcheck of install/ read transient files and a SIGKILL left them behind.
# This guard snapshots research-sdd/ (resolved from THIS script's location, never the cwd) around
# every suite; a new, modified or removed entry is attributed to the suite that was running.
# Files are tracked by path + CONTENT HASH (sha1sum) and symlinks by path + target (kit issue #1299
# item 7; never followed), never mtime: measured on the real tree, ~20
# suites rewrite committed fixtures with identical bytes (new mtime, no change) and python suites
# drop __pycache__/*.pyc — flagging either would fail the gate on every run for noise. A file that
# appears, disappears or changes bytes IS a violation. Directories are not tracked (an empty one is
# invisible to the repo) and `__pycache__` bytecode is excluded as interpreter residue. Limits: only
# research-sdd/ is scanned (a leak elsewhere in the repo is outside this enumerator); a suite that
# rewrites a file and restores the original bytes before exiting is invisible. Like the cwd guard, a scan
# that cannot run is DEGRADED and fails the run — never a confident 0 (§7).
KIT_TREE="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
kit_tree_violations=()   # "<suite basename> leaked: <relpath> (new|modified|removed)"
KIT_TREE_DEGRADED=0
KIT_TREE_DEGRADED_REASON=""
_kit_tree_prev=""
_kit_tree_cur=""
_scan_kit_tree() {
  # Sets _kit_tree_cur to a sorted "relpath<TAB>identity" listing. Returns 1 (listing untouched)
  # when the scan cannot run. STDOUT only: stderr noise from a successful find is never parsed.
  local _out _lnk _rc
  _out="$(find "$KIT_TREE" -type f -not -path '*/__pycache__/*' -exec sha1sum {} +)"
  _rc=$?
  [[ $_rc -eq 0 ]] || return 1
  # Symlinks (kit issue #1299 item 7): `-type f` never lists a link, so one a suite created,
  # retargeted or removed was invisible. Tracked by path + target text (never followed, so a
  # dangling link counts), one tab-separated "path<TAB>link:<target>" line each.
  # SENTINEL-KIT-TREE-SYMLINKS
  _lnk="$(find "$KIT_TREE" -type l -not -path '*/__pycache__/*' -exec sh -c 'for p; do printf "%s\tlink:%s\n" "$p" "$(readlink "$p")"; done' sh {} +)"
  _rc=$?
  [[ $_rc -eq 0 ]] || return 1
  _kit_tree_cur="$({ printf '%s\n' "$_out" | awk -v pre="$KIT_TREE/" 'NF >= 2 { h = $1; sub(/^[^ ]+  /, ""); if (index($0, pre) == 1) $0 = substr($0, length(pre) + 1); print $0 "\t" h }'
    printf '%s\n' "$_lnk" | awk -F'\t' -v pre="$KIT_TREE/" 'NF >= 2 { if (index($1, pre) == 1) $1 = substr($1, length(pre) + 1); print $1 "\t" $2 }'; } | LC_ALL=C sort)"
  return 0
}
_kit_tree_unreadable() {
  # Kit issue #1299 item 7: a chmod-000 file/dir left under research-sdd/ makes `sha1sum`/`find` fail,
  # which used to be reported as "the scanner failed" and blamed on the tooling. Names the first
  # unreadable entry (relative path) when one exists, empty otherwise. Captured, never piped into
  # `head` (SIGPIPE under pipefail). SENTINEL-KIT-TREE-UNREADABLE
  local _u
  _u="$(find "$KIT_TREE" -not -readable 2>/dev/null)"
  _u="${_u%%$'\n'*}"
  [[ -n "$_u" ]] && printf '%s' "${_u#"$KIT_TREE"/}"
  return 0
}
if [[ -z "$KIT_TREE" ]]; then
  KIT_TREE_DEGRADED=1
  KIT_TREE_DEGRADED_REASON="the kit tree (research-sdd/) could not be resolved from $SCRIPT_DIR"
  echo "run-all.sh: WARNING: kit-tree hermeticity guard DEGRADED — $KIT_TREE_DEGRADED_REASON" >&2
elif ! _scan_kit_tree; then
  KIT_TREE_DEGRADED=1
  _kt_unreadable="$(_kit_tree_unreadable)"
  if [[ -n "$_kt_unreadable" ]]; then
    KIT_TREE_DEGRADED_REASON="unreadable entry under research-sdd/ before any suite ran: $_kt_unreadable (a leftover permission change in the tree, not a scanner fault)"
  else
    KIT_TREE_DEGRADED_REASON="the kit-tree scanner ('find' + 'sha1sum') failed or is unavailable on this platform"
  fi
  echo "run-all.sh: WARNING: kit-tree hermeticity guard DEGRADED — $KIT_TREE_DEGRADED_REASON" >&2
else
  _kit_tree_prev="$_kit_tree_cur"
fi

# --- Optional flags -------------------------------------------------------
# No arg = fine; a valid flag = enable that mode; anything else is rejected so
# a typo (e.g. --prove-teath) can't silently disable teeth while reporting green.
PROVE_TEETH=""
REQUIRE_TEETH=""
REQUIRE_CLEAN_TMP=""
# Opt-in parallelism (kit issue #1463): `-j N` / `-jN` / `--jobs N`, N a plain integer 1..6 (the
# cap is deliberate: the heavy suites are CPU/IO-bound and a runaway fan-out makes timing-
# sensitive suites flaky). Refused: bare `-j`, `-j 0`, `-j 100%`, non-numeric, N above the cap.
# Serial stays the default and the reference behaviour. May precede or follow the teeth flag;
# any other token, in any position, exits 2 (unknown flag).
MAX_JOBS=6
JOBS=1
USAGE="usage: run-all.sh [--prove-teeth|--require-teeth] [--require-clean-tmp] [-j N]"
_parse_jobs() {  # <value> — sets JOBS or exits 2
  if [[ ! "$1" =~ ^[0-9]+$ ]] || [[ "$((10#$1))" -lt 1 ]]; then
    echo "invalid -j value '$1': need an integer 1..$MAX_JOBS (no bare -j, 0, percentages or non-numerics); $USAGE" >&2
    exit 2
  fi
  if [[ "$((10#$1))" -gt "$MAX_JOBS" ]]; then
    echo "invalid -j value '$1': capped at $MAX_JOBS; $USAGE" >&2
    exit 2
  fi
  JOBS=$((10#$1))
}
_args=("$@")
_ai=0
while [[ $_ai -lt ${#_args[@]} ]]; do
  _a="${_args[$_ai]}"
  case "$_a" in
    --prove-teeth)
      PROVE_TEETH="--prove-teeth"
      ;;
    --require-teeth)
      PROVE_TEETH="--prove-teeth"
      REQUIRE_TEETH=1
      ;;
    --require-clean-tmp)
      REQUIRE_CLEAN_TMP=1
      ;;
    -j|--jobs)
      _ai=$((_ai + 1))
      _parse_jobs "${_args[$_ai]-}"
      ;;
    -j*)
      _parse_jobs "${_a#-j}"
      ;;
    "")
      ;;
    *)
      # Every unknown token, in ANY position, is refused: a typo after a valid flag
      # (`-j 2 --prove-teath`) must not silently run without teeth and report green.
      echo "unknown flag: $_a; $USAGE" >&2
      exit 2
      ;;
  esac
  _ai=$((_ai + 1))
done

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
sh_teeth_nohelper=()   # stripped basenames: HAS teeth (banner or flag) but never sources lib/mutant.sh (#943)

tmp_out="$(mktemp)"
# --- Per-run TMPDIR root (kit issue #1277 slice 3) -----------------------------------------------
# ONE temp root per run, created under the caller's TMPDIR (mktemp honours it, else /tmp). Each suite
# is run with TMPDIR exported to its own fresh subdir of it, so what a suite leaves behind is
# attributable to it by name (also under -j: the subdirs never overlap) and is removed with the root
# on EXIT. The cleanup is ONE function the EXIT trap calls, so every temp resource of the run
# (tmp_out, the -j PAR_DIR, the root) is removed by the same trap — extend _run_all_cleanup, never
# re-set the trap. A root that cannot be created is DEGRADED (the suites then run with the caller's
# TMPDIR unchanged and nothing can be reported about leftovers) — never a confident 0 (§7).
# SENTINEL-TMPDIR-ROOT
# Every variable the EXIT cleanup touches is initialised HERE, before the trap: PAR_DIR is a generic
# name, so one inherited from the caller's environment must never be mistaken for a dir this run
# created (the cleanup removes only what this run made: _par_dir_created).
# SENTINEL-PAR-DIR-INIT
PAR_DIR=""
_par_dir_created=""
RUN_TMP_ROOT=""
TMPDIR_DEGRADED_REASON=""
tmp_leftovers=()        # "<suite basename>: <count>"
tmp_leftover_total=0
tmp_scan_failed=()      # suites whose existing TMPDIR subdir could not be scanned
tmp_create_failed=()    # suites whose per-suite TMPDIR subdir could not be CREATED (they ran on the caller's TMPDIR)
if RUN_TMP_ROOT="$(mktemp -d)" && [[ -n "$RUN_TMP_ROOT" && -d "$RUN_TMP_ROOT" ]]; then
  export RUN_TMP_ROOT
else
  RUN_TMP_ROOT=""
  TMPDIR_DEGRADED_REASON="the per-run TMPDIR root could not be created ('mktemp -d' failed); suites ran with the caller's TMPDIR"
  echo "run-all.sh: WARNING: TMPDIR leftovers DEGRADED — $TMPDIR_DEGRADED_REASON" >&2
fi
_run_all_cleanup() {
  rm -f "$tmp_out"
  [[ -n "$_par_dir_created" && -n "$PAR_DIR" ]] && rm -rf "$PAR_DIR"
  if [[ -n "$RUN_TMP_ROOT" ]]; then
    # A leftover the suite chmod'ed shut would defeat rm -rf; reopen it first (best effort).
    chmod -R u+rwX "$RUN_TMP_ROOT" 2>/dev/null
    rm -rf "$RUN_TMP_ROOT"
  fi
}
trap _run_all_cleanup EXIT
_suite_tmpdir() {   # _suite_tmpdir <index> [<suite basename>] — sets _st to the suite's TMPDIR ('' when none)
  # Sets a global (never run in $(...)) so a creation failure can be RECORDED against the suite: a
  # subdir that was never created must not later read as "the suite removed its own TMPDIR" (a
  # confident 0). The -j worker records the same failure in $PAR_DIR/<idx>.tmpfail.
  _st=""
  [[ -n "$RUN_TMP_ROOT" ]] || return 0
  if mkdir -p "$RUN_TMP_ROOT/$1" 2>/dev/null; then
    _st="$RUN_TMP_ROOT/$1"
  elif [[ -n "${2:-}" ]]; then
    # SENTINEL-TMPDIR-CREATE-FAILED
    tmp_create_failed+=("$2")
  fi
}
_check_tmp_leftovers() {   # _check_tmp_leftovers <suite basename> <index>
  # Entries (dotfiles included) directly inside the suite's TMPDIR subdir. Captured, rc-checked.
  # ABSENT != ERROR: a suite that removed its own TMPDIR left nothing (0 for it). Only a find
  # failure on an EXISTING dir (e.g. it was chmod'ed shut) is a scan failure, attributed to THAT
  # suite (tmp_scan_failed) so the other suites' counts survive. A chmod-000 leftover dir inside is
  # itself ONE entry — it is listed by its parent, never opened.
  [[ -n "$RUN_TMP_ROOT" ]] || return 0
  local _o _n
  # A -j worker that could not create the subdir left a marker (serial records at creation time).
  if [[ -n "${PAR_DIR:-}" && -e "$PAR_DIR/$2.tmpfail" ]]; then tmp_create_failed+=("$1"); return 0; fi
  # SENTINEL-TMPDIR-ABSENT
  [[ -e "$RUN_TMP_ROOT/$2" ]] || return 0
  if ! _o="$(find "$RUN_TMP_ROOT/$2" -mindepth 1 -maxdepth 1 2>/dev/null)"; then
    tmp_scan_failed+=("$1")
    return 0
  fi
  [[ -n "$_o" ]] || return 0
  _n="$(printf '%s\n' "$_o" | wc -l)"
  tmp_leftovers+=("$1: $((_n + 0))")
  tmp_leftover_total=$((tmp_leftover_total + _n))
}

# Per-suite hermeticity checks, as functions so the -j batch path can run them ONCE after the
# whole parallel batch (labelled) while the serial path runs them after every suite (by suite name).
_check_cwd_hermeticity() {
  local base="$1"
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
}
_check_kit_tree_hermeticity() {
  local base="$1"
  # --- Kit-tree hermeticity check (kit issue #1156): did THIS suite touch research-sdd/? ---
  # SENTINEL-KIT-TREE-CHECK
  if [[ "$KIT_TREE_DEGRADED" -eq 0 ]]; then
    if ! _scan_kit_tree; then
      KIT_TREE_DEGRADED=1
      _kt_unreadable="$(_kit_tree_unreadable)"
      if [[ -n "$_kt_unreadable" ]]; then
        KIT_TREE_DEGRADED_REASON="unreadable entry under research-sdd/ after $base: $_kt_unreadable (the suite, or a leftover, changed its permissions — not a scanner fault)"
      else
        KIT_TREE_DEGRADED_REASON="the kit-tree scanner failed mid-run (after $base)"
      fi
      echo "run-all.sh: WARNING: kit-tree hermeticity guard DEGRADED mid-run (after $base) — $KIT_TREE_DEGRADED_REASON; cannot verify remaining suites stay hermetic" >&2
    elif [[ "$_kit_tree_cur" != "$_kit_tree_prev" ]]; then
      declare -A _kt_prev_map=() _kt_cur_map=()
      while IFS=$'\t' read -r _kt_path _kt_id; do
        [[ -n "$_kt_path" ]] && _kt_prev_map["$_kt_path"]="$_kt_id"
      done <<< "$_kit_tree_prev"
      while IFS=$'\t' read -r _kt_path _kt_id; do
        [[ -n "$_kt_path" ]] && _kt_cur_map["$_kt_path"]="$_kt_id"
      done <<< "$_kit_tree_cur"
      for _kt_path in "${!_kt_cur_map[@]}"; do
        if [[ "${_kt_prev_map[$_kt_path]+set}" != "set" ]]; then
          kit_tree_violations+=("$base leaked: $_kt_path (new)")
        elif [[ "${_kt_prev_map[$_kt_path]}" != "${_kt_cur_map[$_kt_path]}" ]]; then
          kit_tree_violations+=("$base leaked: $_kt_path (modified)")
        fi
      done
      for _kt_path in "${!_kt_prev_map[@]}"; do
        if [[ "${_kt_cur_map[$_kt_path]+set}" != "set" ]]; then
          kit_tree_violations+=("$base leaked: $_kt_path (removed)")
        fi
      done
      unset _kt_prev_map _kt_cur_map
      _kit_tree_prev="$_kit_tree_cur"   # roll forward, or a later suite is re-blamed
    fi
  fi
}

# --- Parallel batch (opt-in, kit issue #1463) --------------------------------------------------
# JOBS_ACTIVE is non-empty only when -j N>1 was asked for AND GNU parallel is usable. If it is
# not, say so with a typed DEGRADED line and run serially — never a silent downgrade. Under -j the
# suites run concurrently into per-suite files; the loop below then REPLAYS them serially in the
# usual order, so parsing, teeth tracking and the aggregate are the same code path as serial.
# Hermeticity attribution cannot be per-suite while suites overlap: both guards snapshot once
# before and once after the batch, and a violation is reported under a typed batch label that
# says the offender could not be named (it still fails the run — never a silent pass); a leak is
# first attributed by a bounded serial re-run of the candidate suites (see _attribute_batch_leaks).
JOBS_ACTIVE=""
PARALLEL_DEGRADED_REASON=""
PARALLEL_UNUSABLE_WHY=""
PARALLEL_LABEL="-j batch (offender unattributed — see the 'Attribution:' line for why)"
_parallel_gnu_ok() {
  # Sets PARALLEL_UNUSABLE_WHY to the concrete cause on failure (kit issue #1491 item 2): three
  # distinct states must not share one message — absent, present-but-broken, present-but-not-GNU.
  # Captured then pattern-matched: a `| head | grep -q` chain would SIGPIPE under pipefail.
  PARALLEL_UNUSABLE_WHY=""
  if ! command -v parallel >/dev/null 2>&1; then
    PARALLEL_UNUSABLE_WHY="'parallel' is not on PATH"
    return 1
  fi
  local _pv
  if ! _pv="$(parallel --version 2>/dev/null)"; then
    PARALLEL_UNUSABLE_WHY="'parallel' is on PATH ($(command -v parallel)) but 'parallel --version' failed"
    return 1
  fi
  if [[ "$_pv" != *"GNU parallel"* ]]; then
    PARALLEL_UNUSABLE_WHY="'parallel' on PATH ($(command -v parallel)) is not GNU parallel"
    return 1
  fi
  return 0
}
# Attribution of a batch leak (kit issue #1491 item 1). The batch snapshot proves a leak happened
# but not WHO. Each -j worker records its suite's [start,end] wall-clock window; the leaked path's
# mtime (the LAST writer) falls inside the window of the suite(s) that were running at that moment,
# so only those candidates (at most -j N of them, never the whole corpus) are re-run serially, each
# under a per-suite timeout (RUN_ALL_ATTRIBUTION_TIMEOUT seconds, default 600, via `timeout` when
# present). A candidate is blamed when the leaked path's signature (full-resolution mtime AND
# content hash) changes across its re-run: mtime alone misses a suite that restores the mtime, the
# hash alone misses an identical-bytes rewrite. It only runs when the batch found a new/modified
# leak, so a clean -j run and the serial path are untouched. Everything that cannot be attributed
# (removed paths, no window containing the mtime, a leak that does not reproduce, a missing stat
# or date capability) keeps the typed batch label AND gets a typed `Attribution:` line saying why
# — never a silent label. Side effects of a re-run are the suite's own (the same as the first run).
ATTRIBUTION_LINES=()
_STAT_MODE=""
_probe_stat() {
  local _v _f="${PAR_DIR:-$SCRIPT_DIR}/run1.sh"
  [[ -e "$_f" ]] || _f="$SCRIPT_DIR/run-all.sh"
  if _v="$(stat -c '%.9Y' -- "$_f" 2>/dev/null)" && [[ "$_v" =~ ^[0-9]+\.[0-9]+$ ]]; then _STAT_MODE=gnu
  elif _v="$(stat -f '%m' -- "$_f" 2>/dev/null)" && [[ "$_v" =~ ^[0-9]+$ ]]; then _STAT_MODE=bsd
  else _STAT_MODE=none; fi
}
_mtime_of() {   # _mtime_of <path>: epoch mtime (full resolution under GNU stat), or "absent"
  case "$_STAT_MODE" in
    gnu) stat -c '%.9Y' -- "$1" 2>/dev/null || printf 'absent' ;;
    bsd) stat -f '%m' -- "$1" 2>/dev/null || printf 'absent' ;;
    *) printf 'absent' ;;
  esac
}
_sig_of() {     # _sig_of <path>: "<mtime>|<sha1 of a regular file>"
  local _h=""
  [[ -f "$1" ]] && _h="$(sha1sum -- "$1" 2>/dev/null)" && _h="${_h%% *}"
  printf '%s|%s' "$(_mtime_of "$1")" "$_h"
}
_pend_add() {   # _pend_add <violations-array-name> <src-tag> <root>: queue its new/modified batch entries
  local -n _pv="$1"; local _from="$4" _i _e _kind _path
  for ((_i = _from; _i < ${#_pv[@]}; _i++)); do
    _e="${_pv[$_i]#"$PARALLEL_LABEL leaked: "}"
    _kind="${_e##* (}"; _kind="${_kind%)}"; _path="${_e% (*}"
    [[ "$_kind" == removed ]] && continue
    _pend_path+=("$3/$_path"); _pend_src+=("$2:$_path"); _pend_kind+=("$_kind"); _pend_done+=("")
  done
}
_attribute_batch_leaks() {
  local _i _j _s _b _m _w _ws _we _tol _t _cmd_to _rt
  local -a _pend_path=() _pend_kind=() _pend_src=() _pend_done=() _pend_before=() _cand=() _attr=()
  # Clean batch: no new violation of either kind -> silent, byte-identical to before.
  [[ ${#hermeticity_violations[@]} -eq $1 && ${#kit_tree_violations[@]} -eq $2 ]] && return 0
  _pend_add hermeticity_violations cwd "$CALLER_CWD" "$1"
  _pend_add kit_tree_violations kit "$KIT_TREE" "$2"
  [[ ${#_pend_path[@]} -gt 0 ]] || { ATTRIBUTION_LINES+=("Attribution: nothing to attribute (only removed paths; a removed path cannot be re-touched)"); return 0; }
  _probe_stat
  if [[ "$_STAT_MODE" == none ]]; then
    ATTRIBUTION_LINES+=("Attribution: DEGRADED (neither 'stat -c %.9Y' nor 'stat -f %m' works on this platform; ${#_pend_path[@]} leaked path(s) left under the batch label)")
    echo "run-all.sh: -j attribution DEGRADED — no usable stat; leaks keep the batch label" >&2
    return 0
  fi
  _tol=0.05; [[ "$_STAT_MODE" == bsd ]] && _tol=1
  # Candidate suites: those whose recorded window contains a leaked path's mtime.
  for _i in "${!_pend_path[@]}"; do
    _m="$(_mtime_of "${_pend_path[$_i]}")"
    [[ "$_m" == absent ]] && continue
    for _j in "${!all_suites[@]}"; do
      [[ -f "$PAR_DIR/$((_j + 1)).win" ]] || continue
      read -r _ws _we < "$PAR_DIR/$((_j + 1)).win"
      if awk -v m="$_m" -v s="$_ws" -v e="$_we" -v t="$_tol" 'BEGIN { exit !(m + 0 >= s - t && m + 0 <= e + t) }'; then
        [[ " ${_cand[*]} " == *" $_j "* ]] || _cand+=("$_j")
      fi
    done
  done
  if [[ ${#_cand[@]} -eq 0 ]]; then
    ATTRIBUTION_LINES+=("Attribution: DEGRADED (no suite run window contains the leaked path's mtime — missing window records or clock skew; ${#_pend_path[@]} path(s) left under the batch label)")
    echo "run-all.sh: -j attribution DEGRADED — no suite window matches the leak's mtime" >&2
    return 0
  fi
  mapfile -t _cand < <(printf '%s\n' "${_cand[@]}" | sort -n)
  _t="${RUN_ALL_ATTRIBUTION_TIMEOUT:-600}"; _cmd_to=()
  command -v timeout >/dev/null 2>&1 && _cmd_to=(timeout "$_t")
  echo "run-all.sh: -j leak detected in the batch; re-running ${#_cand[@]} candidate suite(s) of ${#all_suites[@]} serially to name the offender" >&2
  for _j in "${_cand[@]}"; do
    _s="${all_suites[$_j]}"; _b="$(basename "$_s")"
    for _i in "${!_pend_path[@]}"; do _pend_before[_i]="$(_sig_of "${_pend_path[$_i]}")"; done
    echo "run-all.sh: -j attribution re-run: $_b" >&2
    # Re-runs get their own subdir (never scanned): their leftovers must not double-count.
    _suite_tmpdir "attr-$_j"; _rt="${_st:-${TMPDIR:-/tmp}}"
    if [[ "$_b" == *.test.mjs ]]; then TMPDIR="$_rt" "${_cmd_to[@]}" node "$_s" >/dev/null 2>&1
    elif [[ -n "$PROVE_TEETH" ]]; then TMPDIR="$_rt" "${_cmd_to[@]}" bash "$_s" "$PROVE_TEETH" >/dev/null 2>&1
    else TMPDIR="$_rt" "${_cmd_to[@]}" bash "$_s" >/dev/null 2>&1; fi
    [[ $? -eq 124 && ${#_cmd_to[@]} -gt 0 ]] && ATTRIBUTION_LINES+=("Attribution: re-run of $_b hit the ${_t}s timeout")
    for _i in "${!_pend_path[@]}"; do
      [[ -z "${_pend_done[$_i]}" ]] || continue
      if [[ "$(_sig_of "${_pend_path[$_i]}")" != "${_pend_before[$_i]}" ]]; then
        _pend_done[_i]=1
        _attr+=("${_pend_src[$_i]}"$'\t'"$_b"$'\t'"${_pend_kind[$_i]}")
      fi
    done
  done
  ATTRIBUTION_LINES+=("Attribution: re-ran ${#_cand[@]} candidate suite(s) of ${#all_suites[@]} (bounded to suites whose run window contained the leak's mtime)")
  local _a _src _suite _k _path _un=0
  for _a in "${_attr[@]}"; do
    IFS=$'\t' read -r _src _suite _k <<< "$_a"
    _path="${_src#*:}"
    if [[ "${_src%%:*}" == cwd ]]; then
      for _i in "${!hermeticity_violations[@]}"; do
        [[ "${hermeticity_violations[$_i]}" == "$PARALLEL_LABEL leaked: $_path ($_k)" ]] && hermeticity_violations[_i]="$_suite leaked: $_path ($_k)"
      done
    else
      for _i in "${!kit_tree_violations[@]}"; do
        [[ "${kit_tree_violations[$_i]}" == "$PARALLEL_LABEL leaked: $_path ($_k)" ]] && kit_tree_violations[_i]="$_suite leaked: $_path ($_k)"
      done
    fi
  done
  for _i in "${!_pend_done[@]}"; do [[ -z "${_pend_done[$_i]}" ]] && _un=$((_un + 1)); done
  [[ $_un -gt 0 ]] && ATTRIBUTION_LINES+=("Attribution: $_un leaked path(s) not reproduced by any candidate re-run, left under the batch label")
  return 0
}
if [[ "$JOBS" -gt 1 ]]; then
  if _parallel_gnu_ok; then
    JOBS_ACTIVE=1
  else
    PARALLEL_DEGRADED_REASON="$PARALLEL_UNUSABLE_WHY; -j $JOBS requested but running serially"
    echo "run-all.sh: DEGRADED — $PARALLEL_DEGRADED_REASON" >&2
  fi
fi
if [[ -n "$JOBS_ACTIVE" ]]; then
  PAR_DIR="$(mktemp -d)"; _par_dir_created=1
  cat > "$PAR_DIR/run1.sh" <<'WORKER'
#!/usr/bin/env bash
# run1.sh <index> <suite> — run one suite, capture merged output and the suite's own exit code.
idx="$1"; suite="$2"
# Per-suite TMPDIR (kit issue #1277): a subdir of the run's root, named by the suite's index.
if [[ -n "${RUN_TMP_ROOT:-}" ]]; then
  if mkdir -p "$RUN_TMP_ROOT/$idx" 2>/dev/null; then export TMPDIR="$RUN_TMP_ROOT/$idx"; else : > "$PAR_DIR/$idx.tmpfail"; fi
fi
# Wall-clock window of this suite, used to bound the leak-attribution re-run (kit issue #1491).
_t0="$(date +%s.%N 2>/dev/null)"
# Progress to stderr as jobs run (the replay only happens at the end): a hung suite is the one
# with a "started" line and no "done" line.
echo "run-all.sh: -j started: $(basename "$suite")" >&2
if [[ "$suite" == *.test.mjs ]]; then
  node "$suite" > "$PAR_DIR/$idx.out" 2>&1
elif [[ -n "${PROVE_TEETH:-}" ]]; then
  bash "$suite" "$PROVE_TEETH" > "$PAR_DIR/$idx.out" 2>&1
else
  bash "$suite" > "$PAR_DIR/$idx.out" 2>&1
fi
rc=$?
_t1="$(date +%s.%N 2>/dev/null)"
case "$_t0$_t1" in *[!0-9.]*|"") ;; *) echo "$_t0 $_t1" > "$PAR_DIR/$idx.win" ;; esac
echo "$rc" > "$PAR_DIR/$idx.rc.tmp" && mv "$PAR_DIR/$idx.rc.tmp" "$PAR_DIR/$idx.rc"
echo "run-all.sh: -j done: $(basename "$suite") rc=$rc" >&2
WORKER
  export PAR_DIR PROVE_TEETH
  echo "run-all.sh: -j $JOBS — running ${#all_suites[@]} suite(s) in parallel (output replayed in serial order below)" >&2
  parallel --line-buffer -j "$JOBS" bash "$PAR_DIR/run1.sh" '{#}' '{}' ::: "${all_suites[@]}" >/dev/null
  # No silent zero: every suite must have left a result file.
  _par_results=$(find "$PAR_DIR" -maxdepth 1 -name '*.rc' | wc -l)
  if [[ "$_par_results" -ne "${#all_suites[@]}" ]]; then
    echo "run-all.sh: -j batch recorded $_par_results result(s) for ${#all_suites[@]} suite(s); the missing suites are reported as failed" >&2
  fi
  _hv_before=${#hermeticity_violations[@]}; _kv_before=${#kit_tree_violations[@]}
  _check_cwd_hermeticity "$PARALLEL_LABEL"
  _check_kit_tree_hermeticity "$PARALLEL_LABEL"
  _attribute_batch_leaks "$_hv_before" "$_kv_before"
fi

suite_idx=0
for suite in "${all_suites[@]}"; do
  base="$(basename "$suite")"
  suites_run=$((suites_run + 1))
  suite_idx=$((suite_idx + 1))

  echo "==============================================================="
  echo ">>> running: $base"
  echo "==============================================================="

  # Build the command. Only *.test.sh suites accept --prove-teeth.
  # A direct pipe to `tee` streams output AND captures it; the pipeline waits
  # for `tee` to finish, so the temp file is fully written before we parse it.
  # PIPESTATUS[0] is the SUITE's exit code (not tee's) — reliable under pipefail.
  if [[ -n "$JOBS_ACTIVE" ]]; then
    # -j path: the suite already ran in the batch; replay its captured output and exit code.
    if [[ -f "$PAR_DIR/$suite_idx.rc" ]]; then
      rc="$(cat "$PAR_DIR/$suite_idx.rc")"
    else
      rc=127   # no result recorded — surfaces as a named failure below, never a pass
    fi
    : > "$tmp_out"
    [[ -f "$PAR_DIR/$suite_idx.out" ]] && cat "$PAR_DIR/$suite_idx.out" > "$tmp_out"
    cat "$tmp_out"
  elif [[ "$base" == *.test.mjs ]]; then
    # Node ESM suite: no shebang, no +x — must be invoked via `node`.
    _suite_tmpdir "$suite_idx" "$base"; [[ -n "$_st" ]] || _st="${TMPDIR:-/tmp}"
    TMPDIR="$_st" node "$suite" 2>&1 | tee "$tmp_out"
    rc=${PIPESTATUS[0]}
  else
    # Shell suite: run with bash; forward the flag only when set.
    _suite_tmpdir "$suite_idx" "$base"; [[ -n "$_st" ]] || _st="${TMPDIR:-/tmp}"
    if [[ -n "$PROVE_TEETH" ]]; then
      TMPDIR="$_st" bash "$suite" "$PROVE_TEETH" 2>&1 | tee "$tmp_out"
    else
      TMPDIR="$_st" bash "$suite" 2>&1 | tee "$tmp_out"
    fi
    rc=${PIPESTATUS[0]}
  fi

  if [[ -z "$JOBS_ACTIVE" ]]; then
    _check_cwd_hermeticity "$base"
    _check_kit_tree_hermeticity "$base"
  fi
  # After the suite (serial) or the whole batch (-j: its subdir is its own either way).
  _check_tmp_leftovers "$base" "$suite_idx"


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
    _has_teeth=0
    if grep -qEi '^[[:space:]]*(--|==)[[:space:]]*teeth\b' "$tmp_out" 2>/dev/null; then
      _has_teeth=1 # has teeth banners — no banner tracking needed
    elif grep -qE '(--prove-teeth|PROVE_TEETH)' "$suite" 2>/dev/null; then
      sh_teeth_nobanner+=("$base_noext")
      _has_teeth=1
    else
      sh_no_teeth+=("$base_noext")
    fi
    # SENTINEL-TEETH-HELPER-LINT (kit issue #943): a suite with teeth that never references the
    # shared mutant helper builds its mutants by hand, with none of the helper's refusals (empty,
    # byte-identical, syntax-broken, live-tree, symlink OUT). Reported, never failed: migration is incremental.
    # Kit issue #1299 item 5: a COMMENT mentioning the helper is not use; an actual `.`/`source` is.
    # Recognised: a literal lib/mutant.sh target, or a variable assigned the helper path earlier or
    # later in the same file (ONE level: `LIB=...lib/mutant.sh` then `. "$LIB"`), after a line start
    # or one of ; & | { ( then do else. Comment lines and heredoc bodies are skipped (a delimiter
    # is detected from `<<[-]WORD`; `<<<` herestrings are ignored). Known limits: a second level of
    # indirection and a quoted multi-line string that looks like a source line are not resolved.
    # One awk process, NOT `grep -v | grep -q`: under pipefail the early-exiting `grep -q` SIGPIPEs the
    # producer (rc 141) on any suite larger than the pipe buffer and mislabels it a non-user.
    # SENTINEL-HELPER-USE-TEST
    if [[ "$_has_teeth" -eq 1 ]] && ! awk '
      hd != "" { t = $0; sub(/^[ \t]+/, "", t); if (t == hd) hd = ""; next }
      /^[[:space:]]*#/ { next }
      { code[++n] = $0
        if ($0 !~ /<<</ && match($0, /<<-?[^A-Za-z_]*[A-Za-z_][A-Za-z0-9_]*/)) {
          d = substr($0, RSTART, RLENGTH); sub(/^<<-?[^A-Za-z_]*/, "", d); hd = d } }
      END {
        for (i = 1; i <= n; i++)
          if (code[i] ~ /^[[:space:]]*(local[[:space:]]+|export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=.*lib\/mutant\.sh/) {
            v = code[i]; sub(/^[[:space:]]*(local[[:space:]]+|export[[:space:]]+)?/, "", v); sub(/=.*/, "", v)
            isvar[v] = 1 }
        for (i = 1; i <= n; i++) {
          if (code[i] !~ /(^|[;&|{(]|(^|[[:space:]])(then|do|else))[[:space:]]*(\.|source)[[:space:]]+/) continue
          if (code[i] ~ /(\.|source)[[:space:]]+[^#]*lib\/mutant\.sh/) exit 0
          for (v in isvar) if (index(code[i], "$" v) || index(code[i], "${" v)) exit 0
        }
        exit 1 }' "$suite" 2>/dev/null; then
      sh_teeth_nohelper+=("$base_noext")
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
if [[ -n "$JOBS_ACTIVE" ]]; then
  echo "Parallel: -j $JOBS — a leak found by the batch snapshot is attributed by a serial re-run bounded to the candidate suites whose run window contained the leaked path's mtime (at most -j N, never the whole corpus; per-suite timeout RUN_ALL_ATTRIBUTION_TIMEOUT, default 600s); unattributed leaks keep the batch label plus a typed Attribution line"
  for _al in "${ATTRIBUTION_LINES[@]}"; do echo "$_al"; done
elif [[ -n "$PARALLEL_DEGRADED_REASON" ]]; then
  echo "Parallel: DEGRADED — $PARALLEL_DEGRADED_REASON"
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
if [[ "$KIT_TREE_DEGRADED" -eq 1 ]]; then
  echo "Kit-tree hermeticity: DEGRADED — ${KIT_TREE_DEGRADED_REASON:-cause not recorded}; could not verify"
else
  echo "Kit-tree hermeticity violations (new/modified/removed files under research-sdd/): ${#kit_tree_violations[@]}"
  if [[ ${#kit_tree_violations[@]} -gt 0 ]]; then
    echo "  (a suite must not write into the repo tree — build mutants/fixtures in a temp dir — kit issue #1156)"
    _kt_sorted=()
    mapfile -t _kt_sorted < <(printf '%s\n' "${kit_tree_violations[@]}" | LC_ALL=C sort)
    for kv in "${_kt_sorted[@]}"; do
      echo "  - $kv"
    done
  fi
fi
# SENTINEL-TMPDIR-REPORT
if [[ -n "$TMPDIR_DEGRADED_REASON" ]]; then
  echo "TMPDIR leftovers: DEGRADED — $TMPDIR_DEGRADED_REASON; could not verify"
else
  _tl_names=""; if [[ ${#tmp_leftovers[@]} -gt 0 ]]; then _tl_names="$(printf '%s, ' "${tmp_leftovers[@]}")"; _tl_names="${_tl_names%, }"; fi
  echo "TMPDIR leftovers: $tmp_leftover_total — [$_tl_names]"
  if [[ "$tmp_leftover_total" -gt 0 ]]; then
    echo "  (a suite must remove what it creates under TMPDIR — kit issue #1277; fails the run only under --require-clean-tmp)"
  fi
  if [[ ${#tmp_scan_failed[@]} -gt 0 || ${#tmp_create_failed[@]} -gt 0 ]]; then
    _ts_names=""; _tc_names=""
    if [[ ${#tmp_scan_failed[@]} -gt 0 ]]; then _ts_names="$(printf '%s, ' "${tmp_scan_failed[@]}")"; _ts_names="${_ts_names%, }"; fi
    if [[ ${#tmp_create_failed[@]} -gt 0 ]]; then _tc_names="$(printf '%s, ' "${tmp_create_failed[@]}")"; _tc_names="${_tc_names%, }"; fi
    echo "TMPDIR scan: DEGRADED — could not scan the TMPDIR of [$_ts_names]; per-suite TMPDIR could not be created for [$_tc_names] (they ran on the caller's TMPDIR); their leftovers are unverified"
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
  _join() { local _r="" _x; for _x in "$@"; do _r="${_r:+$_r, }$_x"; done; printf '%s' "$_r"; }
  _nt_names=""; if [[ ${#_nt_sorted[@]} -gt 0 ]]; then _nt_names="$(_join "${_nt_sorted[@]}")"; fi
  _nb_names=""; if [[ ${#_nb_sorted[@]} -gt 0 ]]; then _nb_names="$(_join "${_nb_sorted[@]}")"; fi
  # SENTINEL-NO-TEETH-BANNER
  echo "Suites without teeth: ${#_nt_sorted[@]} — [$_nt_names]"
  echo "(vocabulary check: a \"teeth\" case with no real mutant is a review item)"
  echo "Suites n/a for teeth (node): ${#mjs_suites[@]}"
  if [[ ${#_nb_sorted[@]} -gt 0 ]]; then
    echo "Suites with teeth but no banner: ${#_nb_sorted[@]} — [$_nb_names]"
  fi
  _nh_sorted=(); if [[ ${#sh_teeth_nohelper[@]} -gt 0 ]]; then
    mapfile -t _nh_sorted < <(printf '%s\n' "${sh_teeth_nohelper[@]}" | sort)
  fi
  _nh_names=""; if [[ ${#_nh_sorted[@]} -gt 0 ]]; then _nh_names="$(_join "${_nh_sorted[@]}")"; fi
  # SENTINEL-TEETH-HELPER-REPORT
  echo "Suites with teeth not using lib/mutant.sh: ${#_nh_sorted[@]} — [$_nh_names]"
  # --- Teeth-helper gate (kit issue #1299 item 4; --require-teeth only) -----------------------
  # Under --require-teeth every hand-rolled teeth suite must either use the helper or carry an
  # explicit waiver in teeth-helper-waivers.txt ("<suite> <reason>" per line; '#' comments).
  # Unwaived suites, STALE waivers (the suite now uses the helper, lost its teeth, or no longer
  # exists), and malformed waiver lines each fail the run — none is silently ignored (§7).
  # A missing waiver file is reported as absent-input and means "no waivers", which fails only
  # when something actually needs one.
  if [[ -n "$REQUIRE_TEETH" ]]; then
    WAIVER_FILE="$SCRIPT_DIR/teeth-helper-waivers.txt"
    declare -A _wv_reason=()
    _wv_invalid=()
    _wv_state="ok"
    if [[ ! -e "$WAIVER_FILE" ]]; then
      _wv_state="absent"
    elif [[ ! -f "$WAIVER_FILE" || ! -r "$WAIVER_FILE" ]]; then
      _wv_state="unreadable"
    else
      _wv_ln=0
      while IFS= read -r _wv_line || [[ -n "$_wv_line" ]]; do
        _wv_ln=$((_wv_ln + 1))
        _wv_line="${_wv_line#"${_wv_line%%[![:space:]]*}"}"
        [[ -z "$_wv_line" || "$_wv_line" == "#"* ]] && continue
        _wv_name="${_wv_line%%[[:space:]]*}"
        _wv_why="${_wv_line#"$_wv_name"}"
        _wv_why="${_wv_why#"${_wv_why%%[![:space:]]*}"}"
        if [[ ! "$_wv_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
          _wv_invalid+=("line $_wv_ln: bad suite name")
        elif [[ -z "$_wv_why" ]]; then
          _wv_invalid+=("line $_wv_ln: '$_wv_name' has no reason")
        elif [[ "${_wv_reason[$_wv_name]+set}" == "set" ]]; then
          _wv_invalid+=("line $_wv_ln: '$_wv_name' waived twice")
        else
          _wv_reason["$_wv_name"]="$_wv_why"
        fi
      done < "$WAIVER_FILE"
    fi
    # A basename shared by both corpora is ambiguous: one waiver line would silently cover both files.
    # Every such name is REPORTED on its own line below. Only a waiver line that NAMES one is Invalid
    # (exit 1). An unwaived collision does not double-fail: the same name already lands in the
    # "not waived" count, which fails the run.
    _ambig=()
    if [[ ${#_nh_sorted[@]} -gt 0 ]]; then mapfile -t _ambig < <(printf '%s\n' "${_nh_sorted[@]}" | uniq -d); fi
    for _n in "${_ambig[@]+"${_ambig[@]}"}"; do
      if [[ "${_wv_reason[$_n]+set}" == "set" ]]; then  # SENTINEL-TEETH-AMBIGUOUS
        _wv_invalid+=("'$_n' is ambiguous: a suite with that name exists in both corpora, so a waiver cannot be scoped to one")
      fi
    done
    declare -A _nh_set=()
    for _n in "${_nh_sorted[@]}"; do _nh_set["$_n"]=1; done
    _unwaived=(); _waived=(); _stale=()
    for _n in "${_nh_sorted[@]}"; do
      if [[ "${_wv_reason[$_n]+set}" == "set" ]]; then _waived+=("$_n"); else _unwaived+=("$_n"); fi
    done
    for _n in "${!_wv_reason[@]}"; do
      [[ "${_nh_set[$_n]+set}" == "set" ]] || _stale+=("$_n")
    done
    _un_names=""; _wa_names=""; _st_names=""; _iv_names=""
    if [[ ${#_unwaived[@]} -gt 0 ]]; then _un_names="$(_join "${_unwaived[@]}")"; fi
    if [[ ${#_waived[@]} -gt 0 ]]; then _wa_names="$(_join "${_waived[@]}")"; fi
    if [[ ${#_stale[@]} -gt 0 ]]; then
      mapfile -t _stale < <(printf '%s\n' "${_stale[@]}" | LC_ALL=C sort)
      _st_names="$(_join "${_stale[@]}")"
    fi
    if [[ ${#_wv_invalid[@]} -gt 0 ]]; then _iv_names="$(_join "${_wv_invalid[@]}")"; fi
    case "$_wv_state" in
      absent) echo "Teeth-helper waivers: ABSENT-INPUT ($WAIVER_FILE not found; treated as no waivers)" ;;
      unreadable) echo "Teeth-helper waivers: UNREADABLE ($WAIVER_FILE is not a readable file; run fails)" ;;
    esac
    # SENTINEL-TEETH-HELPER-GATE
    echo "Suites with teeth not using lib/mutant.sh and not waived: ${#_unwaived[@]} — [$_un_names]"
    echo "Waived teeth-helper suites (teeth-helper-waivers.txt): ${#_waived[@]} — [$_wa_names]"
    # SENTINEL-TEETH-HELPER-STALE
    echo "Stale teeth-helper waivers (suite uses the helper, has no teeth, or does not exist): ${#_stale[@]} — [$_st_names]"
    echo "Invalid teeth-helper waiver lines: ${#_wv_invalid[@]} — [$_iv_names]"
    _am_names=""; if [[ ${#_ambig[@]} -gt 0 ]]; then _am_names="$(_join "${_ambig[@]}")"; fi
    echo "Ambiguous teeth-helper suite names (both corpora): ${#_ambig[@]} — [$_am_names]"
  fi
fi
echo "==============================================================="

# Exit 0 only if no suite failed AND at least one suite actually passed.
# A fully-skipped run (suites_ok == 0) exits 1 — zero test coverage is not "all green".
if [[ $suites_failed -eq 0 ]] && [[ $suites_ok -gt 0 ]] \
   && [[ ${#hermeticity_violations[@]} -eq 0 ]] && [[ "$HERMETICITY_DEGRADED" -eq 0 ]] \
   && [[ ${#kit_tree_violations[@]} -eq 0 ]] && [[ "$KIT_TREE_DEGRADED" -eq 0 ]] \
   && [[ "$INSTALL_TESTS_DEGRADED" -eq 0 ]]; then
  # SENTINEL-REQUIRE-CLEAN-TMP-EXIT
  if [[ -n "$REQUIRE_CLEAN_TMP" ]] && { [[ "$tmp_leftover_total" -gt 0 ]] || [[ -n "$TMPDIR_DEGRADED_REASON" ]] || [[ ${#tmp_scan_failed[@]} -gt 0 ]] || [[ ${#tmp_create_failed[@]} -gt 0 ]]; }; then
    exit 1
  fi
  # SENTINEL-REQUIRE-TEETH-EXIT
  if [[ -n "$REQUIRE_TEETH" ]] && [[ ${#sh_no_teeth[@]} -gt 0 ]]; then
    exit 1
  fi
  # SENTINEL-TEETH-HELPER-EXIT
  if [[ -n "$REQUIRE_TEETH" ]] && { [[ ${#_unwaived[@]} -gt 0 ]] || [[ ${#_stale[@]} -gt 0 ]] \
     || [[ ${#_wv_invalid[@]} -gt 0 ]] || [[ "$_wv_state" == "unreadable" ]]; }; then
    exit 1
  fi
  exit 0
else
  exit 1
fi
