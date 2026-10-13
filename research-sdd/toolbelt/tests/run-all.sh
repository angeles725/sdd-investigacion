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
#   ./run-all.sh [--prove-teeth|--require-teeth] [--require-clean-tmp] [--keep-tmp] [--lane <fast|slow|all>] [-j N]
#                [--tier <core|extras|all>] [--impacted <ref>] [--cache|--no-cache]
#                [--shard I/N [--shard-manifest PATH]] | --list-suites
#
#   --tier <t>       Suite tier (kit issue #2203), default `core`. suite-tiers.txt (next to this script) lists
#                    the EXTRAS suites, one `<repo-relative suite path> extras <reason>` per line ('#' comments,
#                    blank lines ignored): category E VM/dynamic-sandbox suites and unused adapters. `core` runs
#                    everything not listed, `extras` only the listed ones, `all` both. The manifest is parsed
#                    strictly: a line without a reason, a tier word other than `extras`, a duplicate, or a path
#                    that names no discovered suite is `Tier: INVALID` and exits 1 BEFORE any suite runs (a
#                    renamed suite must never silently drop out of the gate). An ABSENT or unreadable manifest
#                    is `Tier: DEGRADED`: every suite runs and the run exits 1 (anti-silent-zero). A tier that
#                    selects 0 suites is `Tier: EMPTY` and exits 1. An invalid value exits 2. The aggregate
#                    prints `Tier: <t> — K of T suites (excluded: N)` (T = every discovered suite). The tier
#                    filter applies BEFORE --list-suites and --shard, so both operate on the selected tier;
#                    discovery, the empty-list check and the install-corpus ABSENT gate judge the full set.
#                    --require-teeth implies `--tier all`; with an explicit core|extras it exits 2 (the
#                    stale-waiver check judges the whole corpus). Also `--tier=<t>`.
#   --shard I/N      Opt-in CI sharding (kit issue #2114): run only shard I of N (1 <= I <= N <= 32). The
#                    selected tier's list (all suites of BOTH corpora under --tier all) is sorted by
#                    repo-relative path (LC_ALL=C) and
#                    suite number k (0-based) belongs to shard (k mod N) + 1, a disjoint cover of the list
#                    for every N. Discovery, the empty-list check and the install-corpus ABSENT-INPUT gate
#                    (#1126/#1144) still judge the FULL discovered set. The aggregate gains one
#                    `Shard: I/N — K of T suites` line; K = 0 (N > T) is reported as EMPTY SHARD and exits 1
#                    (zero coverage is never a pass). Without the flag nothing changes. Also `--shard=I/N`.
#   --shard-manifest PATH
#                    Requires --shard. Writes PATH (also `--shard-manifest=PATH`): a header line
#                    `# shard I/N suites=K exit=RC` then one `<repo-relative suite path> <PASS|FAIL|SKIP>`
#                    line per suite this shard ran. shard-join.sh consumes the N manifests and proves the
#                    union covers every suite exactly once, all green.
#                    Not combinable with --require-teeth (exit 2): the waiver gate needs the whole corpus.
#   --impacted <ref> Fast per-PR gate (kit issue #2201 part 1b), also `--impacted=<ref>`: run only the suites
#                    suite-impact.sh (next to this script) selects for the change between merge-base(<ref>, HEAD)
#                    and the working tree (uncommitted edits count), intersected with the --tier selection. It
#                    parses the suite-impact `--format report` (the only format that carries the escalation
#                    verdict). When suite-impact escalated to FULL the whole tier selection runs unchanged (no
#                    intersection with its list). A selected suite outside the tier is NOT run but is named
#                    (`Impacted outside tier:`). Anything suite-impact cannot answer (script absent, bad ref or no
#                    merge-base, no repo, exit != 0, no header or verdict, a `Selected:` list that is missing,
#                    empty or disagrees with its own count, a suite total that differs from this runner's
#                    discovered count, or a suite this runner did not discover) is `Impacted: DEGRADED`, exit 2
#                    BEFORE any suite runs: never a silent partial set. A selection that is empty inside the tier
#                    is `Impacted: EMPTY`, exit 1. The aggregate prints `Impacted: K of T suites (base <ref>,
#                    merge-base <sha>)` (T = the tier selection; <sha> is the merge-base actually diffed, not the
#                    ref's tip), ONE escalation line (`Impacted escalated: no` or `Impacted escalated: FULL —
#                    <reason>`) and `Impacted skipped: S (selected K + skipped S = T ...)`. Not combinable with
#                    --shard or --require-teeth (exit 2: teeth coverage and the waiver gate judge the whole
#                    corpus). With --list-suites it lists the impacted selection. With --keep-tmp the selection
#                    is kept as <TMPDIR root>/impacted.txt. It NEVER replaces the per-batch full gate (CLAUDE.md
#                    section 5).
#   --cache          Opt-in content-addressed result cache (kit issue #2201 part 2): a suite whose key is unchanged
#                    reuses its previous full PASS (its recorded output is replayed, labelled `(cached)`, and counts
#                    as passed) instead of running. The key is a sha256 over the suite file; every file in its
#                    forward dependency set (suite-impact.sh --deps-all); tests/lib/**, run-all.sh, suite-impact.sh,
#                    the impact-*.txt / suite-tiers.txt / teeth-helper-waivers.txt manifests and the install and
#                    templates trees; files outside research-sdd/ (openspec/, .github/, CLAUDE.md, TARGETS.md,
#                    .shellcheckrc, odd/) when the suite or a dependency NAMES them; the run mode (--prove-teeth,
#                    lane; NOT the tier), `id -u`, and the path plus first `--version` line of bash/python3/node/jq/shellcheck, the VCS tool,
#                    bwrap, unshare, parallel, qemu-system-*, tshark, binwalk and docker;
#                    and the RSDD_* environment (printf %q). ALWAYS-RUN suites (impact-always.txt: whole-tree readers),
#                    blind-spot suites and suites whose dependencies cannot be resolved
#                    are NEVER cached (always run, reason printed). Only a full PASS is stored: never a FAIL, a
#                    SKIP, a suite with per-test skips, or anything from a suite whose own hermeticity/TMPDIR
#                    check found a violation (nor any suite of a -j batch that found one). Entries live in ${XDG_CACHE_HOME:-$HOME/.cache}/research-sdd/run-all/ (a cache dir
#                    inside the repository is refused, exit 2). Degraded states (no sha256 tool, unusable cache
#                    dir, suite-impact cannot answer) run WITHOUT the cache and say so (`Cache: DEGRADED`), never
#                    silently. --cache is refused with --require-teeth and --shard (exit 2): the authoritative gate
#                    never uses it. Known limits: the key cannot see state outside research-sdd/ and the named groups (the
#                    host's commit history, $HOME, the network) or tools other than those listed. `--no-cache` is
#                    the explicit default. RUN_ALL_SHA256_CMD overrides the hash tool (a test hook).
#   --list-suites    Print the selected tier's suite list (repo-relative, LC_ALL=C sorted), one per line,
#                    and exit (1 when the install corpus is absent). The single discovery source for
#                    shard-join.sh.
#
#   --lane <name>    Passthrough (kit issue #1821): exports RSDD_TEST_LANE=<name> to every suite so the
#                    lane-aware ones (lib/test-lane.sh: fast = fixture-cached, slow = real tool, all =
#                    both) pick it up. The value is validated with the lib's own rsdd_lane and an
#                    unknown or missing value exits 2 before any suite runs (fail closed). Without the
#                    flag the caller's ambient RSDD_TEST_LANE is left exactly as it was.
#
#   --require-clean-tmp  Exit 1 when any suite left entries in its per-suite TMPDIR (kit issue
#                    #1277). Every run creates ONE temp root (under the caller's TMPDIR, else /tmp),
#                    exports TMPDIR to a fresh subdir of it for each suite, removes the root on exit,
#                    and reports `TMPDIR leftovers: N — [suite: count]` (N = total entries; entries a
#                    suite newly created in the default host root /tmp/rsdd, which no TMPDIR covers,
#                    are counted too and read `suite: count (in /tmp/rsdd)` — kit issue #2164). Without
#                    the flag the line is report-only; a root that could not be created or scanned is
#                    reported as DEGRADED (and fails under the flag), never as a confident 0.
#
#   --keep-tmp       Do not remove the per-run temp root on exit (kit issue #1645): its kept path is
#                    printed as `TMPDIR kept: <path>` (or `TMPDIR kept: none (...)` when no root could
#                    be created) so a failing run's debugging leftovers can be inspected. Opt-in; the
#                    default still removes the root.
#
#   -j N             Opt-in parallel run (kit issue #1463), N = 1..6; needs GNU parallel (absent ->
#                    typed DEGRADED line, serial run). Serial is the default and the reference.
#                    Hermeticity guards snapshot once around the batch; a leak found there triggers
#                    a serial re-run of only the candidate suites (those whose run window held the
#                    leaked path's mtime) to name the offender; otherwise a typed batch label plus an
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
KIT_TREE="$(cd -P "$SCRIPT_DIR/../.." 2>/dev/null && pwd -P)"
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
KEEP_TMP=""
# Opt-in parallelism (kit issue #1463): `-j N` / `-jN` / `--jobs N`, N a plain integer 1..6 (the
# cap is deliberate: the heavy suites are CPU/IO-bound and a runaway fan-out makes timing-
# sensitive suites flaky). Refused: bare `-j`, `-j 0`, `-j 100%`, non-numeric, N above the cap.
# Serial stays the default and the reference behaviour. May precede or follow the teeth flag;
# any other token, in any position, exits 2 (unknown flag).
MAX_JOBS=6
JOBS=1
USAGE="usage: run-all.sh [--prove-teeth|--require-teeth] [--require-clean-tmp] [--keep-tmp] [--lane <fast|slow|all>] [-j N] [--tier <core|extras|all>] [--impacted <ref>] [--cache|--no-cache] [--shard I/N [--shard-manifest PATH]] | --list-suites"
MAX_SHARDS=32
SHARD_I=""
SHARD_N=""
SHARD_MANIFEST=""
LIST_SUITES=""
CACHE=""
_parse_shard() {  # <value> — sets SHARD_I/SHARD_N or exits 2 (before any suite runs)
  # SENTINEL-SHARD-VALIDATE
  if [[ ! "$1" =~ ^[0-9]{1,3}/[0-9]{1,3}$ ]]; then
    echo "invalid --shard value '$1': need I/N with integers 1 <= I <= N <= $MAX_SHARDS; $USAGE" >&2
    exit 2
  fi
  local _i="${1%/*}" _n="${1#*/}"
  _i=$((10#$_i)); _n=$((10#$_n))
  if [[ "$_n" -lt 1 || "$_n" -gt "$MAX_SHARDS" || "$_i" -lt 1 || "$_i" -gt "$_n" ]]; then
    echo "invalid --shard value '$1': need 1 <= I <= N <= $MAX_SHARDS; $USAGE" >&2
    exit 2
  fi
  SHARD_I="$_i"; SHARD_N="$_n"
}
_parse_shard_manifest() {  # <path> — sets SHARD_MANIFEST or exits 2
  if [[ -z "$1" ]]; then
    echo "--shard-manifest needs a PATH; $USAGE" >&2
    exit 2
  fi
  SHARD_MANIFEST="$1"
}
TIER="core"
TIER_EXPLICIT=""
_parse_tier() {  # <value> — sets TIER or exits 2 (before any suite runs)
  # SENTINEL-TIER-VALIDATE
  case "$1" in
    core|extras|all) TIER="$1"; TIER_EXPLICIT=1 ;;
    *) echo "invalid --tier value '$1' (allowed: core extras all); $USAGE" >&2; exit 2 ;;
  esac
}
IMPACTED_REF=""
_parse_impacted() {  # <value> — sets IMPACTED_REF or exits 2 (before any suite runs)
  # SENTINEL-IMPACTED-REF-VALIDATE
  # A flag-looking value (`--impacted --prove-teeth`) is refused: it would swallow the next flag as a ref.
  if [[ -z "$1" || "$1" == -* ]]; then
    echo "invalid --impacted value '$1': need a git base ref (for example origin/main), not empty and not a flag; $USAGE" >&2
    exit 2
  fi
  IMPACTED_REF="$1"
}
LANE_ARG=""
_parse_lane() {  # <value> — validates through lib/test-lane.sh (rsdd_lane), sets LANE_ARG or exits 2
  local v="$1" lib="$SCRIPT_DIR/../lib/test-lane.sh"
  if [[ -z "$v" ]]; then
    echo "invalid --lane value: missing (allowed: fast slow all); $USAGE" >&2
    exit 2
  fi
  if [[ ! -f "$lib" ]]; then
    echo "--lane needs $lib to validate the lane and it is absent; $USAGE" >&2
    exit 2
  fi
  # shellcheck source=../lib/test-lane.sh
  . "$lib"
  if ! RSDD_TEST_LANE="$v" rsdd_lane >/dev/null; then
    echo "invalid --lane value '$v' (allowed: fast slow all); $USAGE" >&2
    exit 2
  fi
  LANE_ARG="$v"
  export RSDD_TEST_LANE="$v"   # SENTINEL-LANE-EXPORT
}
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
    --keep-tmp)
      KEEP_TMP=1
      ;;
    --lane)
      _ai=$((_ai + 1))
      _parse_lane "${_args[$_ai]-}"
      ;;
    --lane=*)
      _parse_lane "${_a#--lane=}"
      ;;
    --tier)
      _ai=$((_ai + 1))
      _parse_tier "${_args[$_ai]-}"
      ;;
    --tier=*)
      _parse_tier "${_a#--tier=}"
      ;;
    --impacted)
      _ai=$((_ai + 1))
      _parse_impacted "${_args[$_ai]-}"
      ;;
    --impacted=*)
      _parse_impacted "${_a#--impacted=}"
      ;;
    --cache)
      CACHE=1
      ;;
    --no-cache)
      CACHE=""
      ;;
    --shard)
      _ai=$((_ai + 1))
      _parse_shard "${_args[$_ai]-}"
      ;;
    --shard=*)
      _parse_shard "${_a#--shard=}"
      ;;
    --shard-manifest)
      _ai=$((_ai + 1))
      _parse_shard_manifest "${_args[$_ai]-}"
      ;;
    --shard-manifest=*)
      _parse_shard_manifest "${_a#--shard-manifest=}"
      ;;
    --list-suites)
      LIST_SUITES=1
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
if [[ -n "$SHARD_MANIFEST" && -z "$SHARD_N" ]]; then
  echo "--shard-manifest needs --shard I/N (a manifest of an unsharded run would claim a shard it never was); $USAGE" >&2
  exit 2
fi
# SENTINEL-SHARD-REQUIRE-TEETH-REFUSE
if [[ -n "$REQUIRE_TEETH" && -n "$SHARD_N" ]]; then
  echo "--require-teeth cannot be combined with --shard: the teeth-helper waiver gate judges the whole corpus, so a shard would report waivers for suites in other shards as stale and fail; run --require-teeth unsharded; $USAGE" >&2
  exit 2
fi
# SENTINEL-TIER-REQUIRE-TEETH-REFUSE
if [[ -n "$REQUIRE_TEETH" ]]; then
  if [[ -n "$TIER_EXPLICIT" && "$TIER" != "all" ]]; then
    echo "--require-teeth cannot be combined with --tier $TIER: the teeth-helper waiver gate judges the whole corpus, so the excluded suites' waivers would be reported as stale; --require-teeth implies --tier all; $USAGE" >&2
    exit 2
  fi
  TIER="all"
fi
# SENTINEL-IMPACTED-REFUSE
if [[ -n "$IMPACTED_REF" && -n "$SHARD_N" ]]; then
  echo "--impacted cannot be combined with --shard: shards must cover the whole tier list so shard-join.sh can prove every suite ran once; $USAGE" >&2
  exit 2
fi
if [[ -n "$IMPACTED_REF" && -n "$REQUIRE_TEETH" ]]; then
  echo "--impacted cannot be combined with --require-teeth: teeth coverage and the teeth-helper waiver gate judge the whole corpus, so a partial run would report the skipped suites' waivers as stale; $USAGE" >&2
  exit 2
fi
# SENTINEL-CACHE-REFUSE
if [[ -n "$CACHE" && -n "$REQUIRE_TEETH" ]]; then
  echo "--cache cannot be combined with --require-teeth: the authoritative gate (teeth coverage, the waiver gate) judges the whole corpus and never reuses a result; $USAGE" >&2
  exit 2
fi
if [[ -n "$CACHE" && -n "$SHARD_N" ]]; then
  echo "--cache cannot be combined with --shard: shards are the CI gate, which must run every suite it covers; $USAGE" >&2
  exit 2
fi
if [[ -n "$LIST_SUITES" && -n "$SHARD_N" ]]; then
  echo "--list-suites lists the selected tier and cannot be combined with --shard; $USAGE" >&2
  exit 2
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
INSTALL_TESTS_DIR="$(cd -P "$SCRIPT_DIR/../../install/tests" 2>/dev/null && pwd -P)"
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
declare -A suite_rel=()   # absolute suite path -> repo-relative path (shard key, manifest identity; kit issue #2114)
# SENTINEL-CORPUS-MERGE
for f in "${sh_suites[@]}" "${mjs_suites[@]}" "${install_sh_suites[@]}" "${install_mjs_suites[@]}"; do
  all_suites+=("$f")
  if [[ "$f" == "$SCRIPT_DIR"/* ]]; then suite_rel["$f"]="research-sdd/toolbelt/tests/${f##*/}"
  else suite_rel["$f"]="research-sdd/install/tests/${f##*/}"; fi
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

# --- Suite tiers (kit issue #2203) ------------------------------------------------------------
# suite-tiers.txt lists the EXTRAS suites ("<repo-relative suite path> extras <reason>"; '#' comments and blank
# lines ignored). The manifest is judged against the FULL discovered set, then the list is filtered by --tier
# BEFORE --list-suites / --shard / total_suites below, so those operate on the selected tier. Strict like
# teeth-helper-waivers.txt: every defect is a typed `Tier: INVALID` line and exit 1 before any suite runs (a
# renamed suite must not silently drop out of the gate); an absent/unreadable manifest is DEGRADED (run ALL, exit 1).
# SENTINEL-SUITE-TIER
TIER_MANIFEST="$SCRIPT_DIR/suite-tiers.txt"
TIER_DEGRADED=""
discovered_suites=${#all_suites[@]}
declare -A _rel_known=()
for f in "${all_suites[@]}"; do _rel_known["${suite_rel[$f]}"]=1; done
declare -A _extras_reason=()
_tier_invalid=()
if [[ ! -e "$TIER_MANIFEST" ]]; then
  TIER_DEGRADED="suite-tiers.txt absent"
elif [[ ! -f "$TIER_MANIFEST" || ! -r "$TIER_MANIFEST" ]]; then
  TIER_DEGRADED="suite-tiers.txt unreadable"
else
  _tl_n=0
  while IFS= read -r _tl || [[ -n "$_tl" ]]; do
    _tl_n=$((_tl_n + 1))
    _tl="${_tl#"${_tl%%[![:space:]]*}"}"
    [[ -z "$_tl" || "$_tl" == "#"* ]] && continue
    read -r _tl_path _tl_word _tl_why <<<"$_tl"
    if [[ -z "$_tl_word" ]]; then
      _tier_invalid+=("line $_tl_n: '$_tl_path' has no tier word and no reason")
    elif [[ "$_tl_word" != "extras" ]]; then
      _tier_invalid+=("line $_tl_n: unknown tier '$_tl_word' for '$_tl_path' (only 'extras' is listed; core is the default)")
    elif [[ -z "$_tl_why" ]]; then
      _tier_invalid+=("line $_tl_n: '$_tl_path' has no reason")
    elif [[ "${_extras_reason[$_tl_path]+set}" == "set" ]]; then
      _tier_invalid+=("line $_tl_n: '$_tl_path' is listed twice")
    elif [[ "${_rel_known[$_tl_path]+set}" != "set" ]]; then
      _tier_invalid+=("line $_tl_n: '$_tl_path' names no discovered suite (renamed or removed?)")
    else
      _extras_reason["$_tl_path"]="$_tl_why"
    fi
  done < "$TIER_MANIFEST"
fi
if [[ ${#_tier_invalid[@]} -gt 0 ]]; then
  for _ti in "${_tier_invalid[@]}"; do echo "Tier: INVALID — $TIER_MANIFEST $_ti" >&2; done
  echo "run-all.sh: suite-tiers.txt has ${#_tier_invalid[@]} invalid line(s); nothing ran" >&2
  exit 1
fi
if [[ -n "$TIER_DEGRADED" ]]; then
  echo "Tier: DEGRADED — $TIER_DEGRADED; running ALL $discovered_suites suite(s) because the extras cannot be told apart; the run exits non-zero" >&2
elif [[ "$TIER" != "all" ]]; then
  _tier_sel=()
  for f in "${all_suites[@]}"; do
    if [[ "${_extras_reason[${suite_rel[$f]}]+set}" == "set" ]]; then
      [[ "$TIER" == "extras" ]] && _tier_sel+=("$f")
    else
      [[ "$TIER" == "core" ]] && _tier_sel+=("$f")
    fi
  done
  all_suites=("${_tier_sel[@]+"${_tier_sel[@]}"}")
fi
if [[ ${#all_suites[@]} -eq 0 ]]; then
  echo "Tier: EMPTY — --tier $TIER selected 0 of $discovered_suites suites (check suite-tiers.txt); nothing ran, so this is not a pass" >&2
  exit 1
fi

# --- --list-suites / --shard (kit issue #2114) -------------------------------------------------
# Both operate on the tier-selected list above (kit issue #2203); the empty-list gate has already run on the
# FULL discovered list and INSTALL_TESTS_DEGRADED (checked at exit) is untouched by the selection.
tier_selected=${#all_suites[@]}   # the SELECTED tier's count (discovered_suites is the full set)

# --- --impacted (kit issue #2201 part 1b) ----------------------------------------------------------
# Intersect the tier selection with what suite-impact.sh says the change (base ref -> working tree) can affect. Every
# state it cannot answer is a typed DEGRADED + exit 2 BEFORE any suite runs (CLAUDE.md section 7): a guess or a
# partial set must never stand in for the answer. The report format is parsed because only it carries the
# escalation verdict; its own `Impacted: N of M` header is cross-checked against the `Selected:` list so a
# truncated or contradictory answer cannot read as a selection.
IMPACTED_ESC="no"
IMPACTED_SHA=""
IMPACTED_OUTSIDE=""
impacted_sel_rels=()
_imp_degraded() { echo "Impacted: DEGRADED — $1; nothing ran (an unknown or partial selection is never replaced by a guess)" >&2; exit 2; }
if [[ -n "$IMPACTED_REF" ]]; then
  # SENTINEL-IMPACTED-SELECT
  _imp_script="$SCRIPT_DIR/suite-impact.sh"
  command -v git >/dev/null 2>&1 || _imp_degraded "git not found on PATH"
  [[ -f "$_imp_script" ]] || _imp_degraded "suite-impact.sh not found next to run-all.sh ($SCRIPT_DIR)"
  # suite-impact --worktree diffs merge-base(<ref>, HEAD) against the working tree, so that commit (not the ref's tip) is the real base.
  IMPACTED_SHA="$(git -C "$SCRIPT_DIR" rev-parse --short "$(git -C "$SCRIPT_DIR" merge-base "$IMPACTED_REF" HEAD 2>/dev/null)" 2>/dev/null)" || IMPACTED_SHA=""
  [[ -n "$IMPACTED_SHA" ]] || _imp_degraded "base ref '$IMPACTED_REF' has no merge-base with HEAD (or does not resolve to a commit) in the repository around $SCRIPT_DIR"
  _imp_errf="$(mktemp)" || _imp_degraded "cannot create a temp file for suite-impact's stderr"
  _imp_report="$(bash "$_imp_script" --base "$IMPACTED_REF" --worktree --format report --repo "$SCRIPT_DIR" 2>"$_imp_errf")"; _imp_rc=$?
  _imp_err1="$(head -n 1 "$_imp_errf" 2>/dev/null)"; rm -f "$_imp_errf"
  [[ "$_imp_rc" -eq 0 ]] || _imp_degraded "suite-impact.sh exited $_imp_rc${_imp_err1:+ ($_imp_err1)}"
  _imp_n=""; _imp_m=""; _imp_verdict=""; _imp_in_sel=0; _imp_seen_sel=0; _imp_sel=()
  while IFS= read -r _imp_l; do
    if (( _imp_in_sel )); then [[ -z "$_imp_l" ]] || _imp_sel+=("$_imp_l"); continue; fi
    if [[ "$_imp_l" =~ ^Impacted:\ ([0-9]+)\ of\ ([0-9]+)\ suites$ ]]; then _imp_n="${BASH_REMATCH[1]}"; _imp_m="${BASH_REMATCH[2]}"
    elif [[ "$_imp_l" == "Escalated: no" ]]; then _imp_verdict="no"
    elif [[ "$_imp_l" == "Escalated to FULL: "* ]]; then _imp_verdict="${_imp_l#Escalated to FULL: }"
    elif [[ "$_imp_l" == "Selected:" ]]; then _imp_in_sel=1; _imp_seen_sel=1
    fi
  done <<<"$_imp_report"
  [[ -n "$_imp_n" ]] || _imp_degraded "suite-impact.sh printed no 'Impacted: N of M suites' header"
  [[ -n "$_imp_verdict" ]] || _imp_degraded "suite-impact.sh printed no escalation verdict (neither 'Escalated: no' nor 'Escalated to FULL:')"
  (( _imp_seen_sel )) || _imp_degraded "suite-impact.sh printed no 'Selected:' list"
  [[ "$_imp_n" -eq "${#_imp_sel[@]}" && "$_imp_n" -gt 0 ]] || _imp_degraded "suite-impact.sh header says $_imp_n suite(s) but its Selected list has ${#_imp_sel[@]}"
  # suite-impact's own suite count must equal what this runner discovered: a suite one side cannot see (for example a
  # .gitignored one) would otherwise be dropped from the selection without a word.
  [[ "$_imp_m" -eq "$discovered_suites" ]] || _imp_degraded "suite-impact.sh knows $_imp_m suite(s) but this runner discovered $discovered_suites (a git-ignored or unreadable suite?)"
  declare -A _imp_known=() _imp_tier=() _imp_pick=()
  for _imp_f in "${suite_rel[@]}"; do _imp_known["$_imp_f"]=1; done
  for _imp_f in "${all_suites[@]}"; do _imp_tier["${suite_rel[$_imp_f]}"]=1; done
  _imp_unknown=(); _imp_outside=()
  for _imp_l in "${_imp_sel[@]}"; do
    if [[ "${_imp_known[$_imp_l]+set}" != set ]]; then _imp_unknown+=("$_imp_l")
    elif [[ "${_imp_tier[$_imp_l]+set}" == set ]]; then _imp_pick["$_imp_l"]=1
    else _imp_outside+=("$_imp_l")
    fi
  done
  [[ ${#_imp_unknown[@]} -eq 0 ]] || _imp_degraded "suite-impact.sh selected ${#_imp_unknown[@]} suite(s) this runner did not discover: ${_imp_unknown[*]}"
  IMPACTED_ESC="$_imp_verdict"
  if [[ "$IMPACTED_ESC" != "no" ]]; then
    # Escalated to FULL: the whole tier selection runs unchanged (no intersection, nothing "outside").
    for _imp_f in "${all_suites[@]}"; do impacted_sel_rels+=("${suite_rel[$_imp_f]}"); done
  else
    _imp_new=()
    for _imp_f in "${all_suites[@]}"; do
      [[ "${_imp_pick[${suite_rel[$_imp_f]}]+set}" == set ]] && { _imp_new+=("$_imp_f"); impacted_sel_rels+=("${suite_rel[$_imp_f]}"); }
    done
    if [[ ${#_imp_outside[@]} -gt 0 ]]; then
      IMPACTED_OUTSIDE="$(printf '%s\n' "${_imp_outside[@]}" | LC_ALL=C sort | paste -sd, - | sed 's/,/, /g')"
      [[ -z "$LIST_SUITES" ]] || echo "Impacted outside tier: $IMPACTED_OUTSIDE" >&2
    fi
    if [[ ${#_imp_new[@]} -eq 0 ]]; then
      echo "Impacted: EMPTY — suite-impact selected ${#_imp_sel[@]} suite(s) but none is inside --tier $TIER (outside tier: ${IMPACTED_OUTSIDE:-none}); nothing ran, so this is not a pass" >&2
      exit 1
    fi
    all_suites=("${_imp_new[@]}")
  fi
fi
total_suites=${#all_suites[@]}   # what will run: the tier selection, narrowed by --impacted
if [[ -n "$LIST_SUITES" || -n "$SHARD_N" ]]; then
  declare -A _rel_abs=()
  for f in "${all_suites[@]}"; do _rel_abs["${suite_rel[$f]}"]="$f"; done
  if [[ ${#_rel_abs[@]} -ne ${#all_suites[@]} ]]; then
    echo "run-all.sh: ${#all_suites[@]} suite(s) discovered but only ${#_rel_abs[@]} distinct repo-relative path(s); refusing to shard/list an ambiguous set" >&2
    exit 1
  fi
  mapfile -t _sorted_rels < <(printf '%s\n' "${!_rel_abs[@]}" | LC_ALL=C sort)
fi
if [[ -n "$LIST_SUITES" ]]; then
  printf '%s\n' "${_sorted_rels[@]}"
  [[ "$INSTALL_TESTS_DEGRADED" -eq 0 && -z "$TIER_DEGRADED" ]] || exit 1
  exit 0
fi
if [[ -n "$SHARD_N" ]]; then
  declare -A _shard_pick=()
  for ((_si = 0; _si < ${#_sorted_rels[@]}; _si++)); do
    # SENTINEL-SHARD-ASSIGN
    if (( _si % SHARD_N == SHARD_I - 1 )); then _shard_pick["${_rel_abs[${_sorted_rels[$_si]}]}"]=1; fi
  done
  _shard_suites=()
  for f in "${all_suites[@]}"; do
    [[ "${_shard_pick[$f]+set}" == set ]] && _shard_suites+=("$f")
  done
  all_suites=("${_shard_suites[@]+"${_shard_suites[@]}"}")
fi
# --- --cache (kit issue #2201 part 2) ----------------------------------------------------------------------
# Content-addressed per-suite result cache; the flag, its key and its refusals are described in the header. Every key is
# decided HERE, before any suite runs, from file CONTENT only (never mtimes): sha256 over the run mode, tool versions,
# the RSDD_* environment, the global inputs (tests/lib, run-all.sh, suite-impact.sh, manifests, install and templates
# trees), the suite file and its forward dependency set from `suite-impact.sh --deps-all`, plus the outside-repo groups
# the suite or a dependency NAMES. Any state it cannot establish is a typed `Cache: DEGRADED` and the run proceeds
# WITHOUT the cache; a suite it cannot key is `uncacheable` with the reason printed (CLAUDE.md section 7).
CACHE_ACTIVE=""
CACHE_DEGRADED_REASON=""
CACHE_DIR=""
cache_hit_names=()     # basenames reused
cache_unc_names=()     # "<basename>: <reason>"
cache_miss_count=0
cache_stored=0
cache_store_failed=0
declare -A cache_state=() cache_file=()
_cache_degrade() { CACHE_DEGRADED_REASON="$1"; echo "run-all.sh: Cache: DEGRADED — $1; running WITHOUT the cache" >&2; }
_cache_prepare() {  # sets CACHE_DIR, cache_state[], cache_file[], the report arrays; rc 1 = degraded (nothing keyed)
  local sha="${RUN_ALL_SHA256_CMD:-sha256sum}" rel_tests="research-sdd/toolbelt/tests" imp="$SCRIPT_DIR/suite-impact.sh"
  local root base abs dfile="" errf="" hfile="" rc hl tag a b f t v s rel bn key km reason gi mine hdr h
  declare -A cdeps=() cblind=() cunres=() calways=() chash=() gmention=() ghash=()
  root="$(cd -P -- "$SCRIPT_DIR/../../.." 2>/dev/null && pwd -P)" || { _cache_degrade "cannot resolve the repository root from $SCRIPT_DIR"; return 1; }
  base="${XDG_CACHE_HOME:-}"
  if [[ -z "$base" ]]; then
    [[ -n "${HOME:-}" ]] || { _cache_degrade "neither XDG_CACHE_HOME nor HOME is set, so there is no cache dir"; return 1; }
    base="$HOME/.cache"
  fi
  CACHE_DIR="$base/research-sdd/run-all"
  abs="$(realpath -m -- "$CACHE_DIR" 2>/dev/null)" || abs="$CACHE_DIR"
  [[ "$abs" == /* ]] || abs="$PWD/$abs"
  # SENTINEL-CACHE-INREPO
  case "$abs/" in
    "$root"/*) echo "--cache: the cache dir '$abs' is inside the repository '$root'; set XDG_CACHE_HOME outside it (a cached result must never become part of the tree under test); $USAGE" >&2; exit 2 ;;
  esac
  command -v "$sha" >/dev/null 2>&1 || { _cache_degrade "no sha256 tool ($sha not on PATH)"; return 1; }
  { mkdir -p -- "$CACHE_DIR" && : > "$CACHE_DIR/.probe.$$" && rm -f "$CACHE_DIR/.probe.$$"; } 2>/dev/null \
    || { _cache_degrade "cache dir '$CACHE_DIR' cannot be created or written"; return 1; }
  [[ -f "$imp" ]] || { _cache_degrade "suite-impact.sh not found next to run-all.sh ($SCRIPT_DIR)"; return 1; }
  dfile="$(mktemp)" && errf="$(mktemp)" && hfile="$(mktemp)" || { rm -f "$dfile" "$errf" "$hfile"; _cache_degrade "cannot create temp files"; return 1; }
  bash "$imp" --deps-all --repo "$SCRIPT_DIR" >"$dfile" 2>"$errf"; rc=$?
  if [[ "$rc" -ne 0 ]]; then
    _cache_degrade "suite-impact.sh --deps-all exited $rc ($(head -n 1 "$errf"))"; rm -f "$dfile" "$errf" "$hfile"; return 1
  fi
  hl="$(tail -n 1 "$dfile")"
  if [[ ! "$hl" =~ ^DEPS-SUMMARY$'\t'([0-9]+)$'\t'[0-9]+$ ]]; then
    _cache_degrade "suite-impact.sh --deps-all printed no DEPS-SUMMARY line"; rm -f "$dfile" "$errf" "$hfile"; return 1
  fi
  if [[ "${BASH_REMATCH[1]}" -ne "$discovered_suites" ]]; then
    _cache_degrade "suite-impact.sh knows ${BASH_REMATCH[1]} suite(s) but this runner discovered $discovered_suites"; rm -f "$dfile" "$errf" "$hfile"; return 1
  fi
  while IFS=$'\t' read -r tag a b; do
    case "$tag" in
      DEP) cdeps["$a"]+="$b"$'\n' ;;
      BLIND) cblind["$a"]="$b" ;;
      UNRESOLVED) cunres["$a"]="$b" ;;
      ALWAYS) calways["$a"]="$b" ;;
    esac
  done < "$dfile"
  # one batch hash of every file under research-sdd/ (content only)
  ( cd "$root" && find research-sdd -type f -print0 | xargs -0 "$sha" ) > "$hfile" 2>"$errf"
  while IFS= read -r hl; do
    [[ "$hl" =~ ^([0-9a-f]{64})\ \ (.+)$ ]] && chash["${BASH_REMATCH[2]}"]="${BASH_REMATCH[1]}"
  done < "$hfile"
  if [[ ${#chash[@]} -eq 0 ]]; then
    _cache_degrade "could not hash the files under research-sdd/ ($(head -n 1 "$errf"))"; rm -f "$dfile" "$errf" "$hfile"; return 1
  fi
  # run mode, tool versions (first --version line), RSDD_* environment
  local mode_sig tool_sig="" env_sig="" glob_sig=""
  # The tier is NOT part of the key: it only picks which suites run, never what one suite does.
  mode_sig="mode prove=${PROVE_TEETH:-none} lane=${LANE_ARG:-none}"$'\n'
  local -a q_tools=(bash python3 node git jq shellcheck bwrap unshare parallel tshark binwalk docker)
  local q_name
  while IFS= read -r q_name; do [[ -n "$q_name" ]] && q_tools+=("$q_name"); done < <(compgen -c qemu-system- | LC_ALL=C sort -u)
  local -a q_to=(); command -v timeout >/dev/null 2>&1 && q_to=(timeout 5)
  tool_sig+="uid $(id -u 2>/dev/null || echo unknown)"$'\n'
  for t in "${q_tools[@]}"; do   # presence (path) AND the first --version line: a suite may skip or run by what is installed
    if v="$(command -v "$t" 2>/dev/null)" && [[ -n "$v" ]]; then
      h="$("${q_to[@]}" "$t" --version 2>&1 </dev/null)"; h="${h%%$'\n'*}"
      tool_sig+="tool $t $v $h"$'\n'
    else
      tool_sig+="tool $t absent"$'\n'
    fi
  done
  for v in $(compgen -e | LC_ALL=C sort); do
    [[ "$v" == RSDD_* ]] && env_sig+="env $v=$(printf '%q' "${!v}")"$'\n'
  done
  # SENTINEL-CACHE-GLOBAL: inputs every suite may lean on
  while IFS= read -r f; do
    case "$f" in
      "$rel_tests"/lib/*|"$rel_tests"/run-all.sh|"$rel_tests"/suite-impact.sh|"$rel_tests"/impact-*.txt|"$rel_tests"/suite-tiers.txt|"$rel_tests"/teeth-helper-waivers.txt|"$rel_tests"/shard-join.sh|research-sdd/templates/*)
        glob_sig+="global $f ${chash[$f]}"$'\n' ;;
      research-sdd/install/tests/*.test.sh|research-sdd/install/tests/*.test.mjs) ;;
      research-sdd/install/*) glob_sig+="global $f ${chash[$f]}"$'\n' ;;
    esac
  done < <(printf '%s\n' "${!chash[@]}" | LC_ALL=C sort)
  # files outside research-sdd/ a suite may read, keyed only when the suite or one of its dependencies names them
  local -a g_pat=('openspec' '\.github' 'CLAUDE\.md' 'TARGETS\.md' '\.shellcheckrc' '(^|[^A-Za-z0-9_])odd/')
  local -a g_path=(openspec .github CLAUDE.md TARGETS.md .shellcheckrc odd)
  for gi in "${!g_pat[@]}"; do
    ( cd "$root" && grep -rlIE --include='*.sh' --include='*.py' --include='*.mjs' --include='*.js' -e "${g_pat[$gi]}" research-sdd ) > "$hfile" 2>"$errf"; rc=$?
    if [[ "$rc" -gt 1 ]]; then _cache_degrade "scanning for '${g_pat[$gi]}' failed ($(head -n 1 "$errf"))"; rm -f "$dfile" "$errf" "$hfile"; return 1; fi
    while IFS= read -r f; do gmention["$gi|$f"]=1; done < "$hfile"
  done
  rm -f "$dfile" "$errf" "$hfile"
  for s in "${all_suites[@]}"; do
    rel="${suite_rel[$s]}"; bn="${s##*/}"; reason=""; mine=""
    # SENTINEL-CACHE-ALWAYS: an always-run suite reads the whole tree; a key made of its declared deps would not see it
    if [[ -n "${calways[$rel]+set}" ]]; then reason="always-run"
    elif [[ -n "${cblind[$rel]+set}" ]]; then reason="blind-spot (${cblind[$rel]})"   # SENTINEL-CACHE-BLIND
    elif [[ -n "${cunres[$rel]+set}" ]]; then reason="no dependency resolved"
    elif [[ -z "${cdeps[$rel]+set}" ]]; then reason="not known to suite-impact.sh"
    elif [[ -z "${chash[$rel]+set}" ]]; then reason="suite file unreadable"
    fi
    if [[ -z "$reason" ]]; then
      km="$mode_sig$tool_sig$env_sig$glob_sig""suite $rel ${chash[$rel]}"$'\n'
      for gi in "${!g_pat[@]}"; do [[ -n "${gmention["$gi|$rel"]+set}" ]] && mine+=" $gi"; done
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        if [[ -z "${chash[$f]+set}" ]]; then reason="dependency unreadable: $f"; break; fi
        km+="dep $f ${chash[$f]}"$'\n'
        for gi in "${!g_pat[@]}"; do [[ -n "${gmention["$gi|$f"]+set}" ]] && mine+=" $gi"; done
      done <<<"${cdeps[$rel]}"
    fi
    if [[ -z "$reason" ]]; then
      for gi in $(printf '%s\n' $mine | LC_ALL=C sort -un); do
        if [[ -z "${ghash[$gi]+set}" ]]; then
          h="$( cd "$root" && if [[ -d "${g_path[$gi]}" ]]; then find "${g_path[$gi]}" -type f -print0 | LC_ALL=C sort -z | xargs -0 "$sha" 2>/dev/null
                              elif [[ -f "${g_path[$gi]}" ]]; then "$sha" "${g_path[$gi]}" 2>/dev/null
                              else echo absent; fi | "$sha" )"
          ghash[$gi]="${h%% *}"
        fi
        km+="outside ${g_path[$gi]} ${ghash[$gi]}"$'\n'
      done
    fi
    if [[ -n "$reason" ]]; then
      cache_state["$s"]=unc; cache_unc_names+=("$bn: $reason"); continue
    fi
    key="$(printf '%s' "$km" | "$sha")"; key="${key%% *}"
    if [[ ! "$key" =~ ^[0-9a-f]{64}$ ]]; then cache_state["$s"]=unc; cache_unc_names+=("$bn: could not compute the key"); continue; fi
    cache_file["$s"]="$CACHE_DIR/$key"
    hdr=""; [[ -f "${cache_file[$s]}" ]] && hdr="$(head -n 1 "${cache_file[$s]}" 2>/dev/null)"
    # a hit needs a well-formed header AND a recorded all-pass summary line; anything else is a miss (never trusted)
    if [[ "$hdr" =~ ^PASS\ [0-9]+\ 0\  ]] && grep -qE '^== [0-9]+ passed · 0 failed ==$' "${cache_file[$s]}" 2>/dev/null; then   # SENTINEL-CACHE-HIT
      cache_state["$s"]=hit; cache_hit_names+=("$bn")
    else
      cache_state["$s"]=miss; cache_miss_count=$((cache_miss_count + 1))
    fi
  done
  return 0
}
if [[ -n "$CACHE" ]]; then
  if _cache_prepare; then CACHE_ACTIVE=1; fi
fi
suite_results=()   # "<repo-relative path> <PASS|FAIL|SKIP>" per suite actually run (shard manifest)

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
  # SENTINEL-KEEP-TMP-EARLY
  [[ -n "$KEEP_TMP" ]] && echo "run-all.sh: --keep-tmp: per-run TMPDIR root kept at $RUN_TMP_ROOT" >&2
  # SENTINEL-IMPACTED-KEEP
  if [[ -n "$IMPACTED_REF" && -n "$KEEP_TMP" ]]; then
    printf '%s\n' "${impacted_sel_rels[@]}" | LC_ALL=C sort > "$RUN_TMP_ROOT/impacted.txt" \
      || echo "run-all.sh: WARNING: could not write $RUN_TMP_ROOT/impacted.txt" >&2
  fi
else
  RUN_TMP_ROOT=""
  TMPDIR_DEGRADED_REASON="the per-run TMPDIR root could not be created ('mktemp -d' failed); suites ran with the caller's TMPDIR"
  echo "run-all.sh: WARNING: TMPDIR leftovers DEGRADED — $TMPDIR_DEGRADED_REASON" >&2
fi
_run_all_cleanup() {
  rm -f "$tmp_out"
  [[ -n "$_par_dir_created" && -n "$PAR_DIR" ]] && rm -rf "$PAR_DIR"
  if [[ -n "$RUN_TMP_ROOT" && -z "$KEEP_TMP" ]]; then
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
  # One "." per entry (-exec printf), counted by length: a name containing a newline is ONE entry
  # (kit issue #1645), and find's own rc is still the scan verdict.
  if ! _o="$(find "$RUN_TMP_ROOT/$2" -mindepth 1 -maxdepth 1 -exec printf '.%.0s' {} + 2>/dev/null)"; then
    tmp_scan_failed+=("$1")
    return 0
  fi
  [[ -n "$_o" ]] || return 0
  _n=${#_o}
  tmp_leftovers+=("$1: $((_n + 0))")
  tmp_leftover_total=$((tmp_leftover_total + _n))
}

# --- Default rsdd root (kit issue #2164) ---------------------------------------------------------
# The VM/Docker tools fall back to the literal host root /tmp/rsdd when $RSDD_VM_ROOT is unset
# (docker_common._DEFAULT_RSDD_ROOT; deliberately not derived from TMPDIR). That path is neither
# under a suite's per-suite TMPDIR nor under research-sdd/, so a suite writing there was invisible
# to every other check. Snapshot its entry names around each suite and report NEW entries in the
# same `TMPDIR leftovers` line. Absent root = empty (production hosts may not have it); a root that
# exists but cannot be scanned is a scan failure, never a confident 0 (§7). A pre-existing entry
# (e.g. a developer's own /tmp/rsdd) is never blamed: only names new since the previous snapshot.
# RUN_ALL_DEFAULT_RSDD_ROOT exists for run-all.test.sh only (fixtures must not touch the real /tmp/rsdd).
# SENTINEL-RSDD-DEFAULT-ROOT
RSDD_DEFAULT_ROOT="${RUN_ALL_DEFAULT_RSDD_ROOT:-/tmp/rsdd}"
declare -A _rsdd_prev=() _rsdd_cur=()
_rsdd_scan() {   # _rsdd_scan — fills _rsdd_cur with the root's entry names; rc 1 = scan failed
  _rsdd_cur=()
  [[ -e "$RSDD_DEFAULT_ROOT" || -L "$RSDD_DEFAULT_ROOT" ]] || return 0
  local _rs_list _rs_name
  _rs_list="$(mktemp)" || return 1
  if ! find -H "$RSDD_DEFAULT_ROOT" -mindepth 1 -maxdepth 1 -print0 > "$_rs_list" 2>/dev/null; then rm -f "$_rs_list"; return 1; fi
  while IFS= read -r -d '' _rs_name; do _rsdd_cur["$_rs_name"]=1; done < "$_rs_list"
  rm -f "$_rs_list"
  return 0
}
_rsdd_base_failed=""
_rsdd_snapshot() {   # baseline before the first suite / the -j batch
  if _rsdd_scan; then _rsdd_prev=(); local _k; for _k in "${!_rsdd_cur[@]}"; do _rsdd_prev["$_k"]=1; done
  else _rsdd_prev=(); _rsdd_base_failed=1; tmp_scan_failed+=("baseline (default rsdd root $RSDD_DEFAULT_ROOT)"); fi
}
_check_rsdd_default_root() {   # _check_rsdd_default_root <suite basename | batch label>
  # Names-only diff: CREATED and REMOVED entries are reported; an entry whose content changes under the
  # same name is not seen.
  local _k _n=0 _r=0
  [[ -z "$_rsdd_base_failed" ]] || return 0   # no trustworthy baseline: already reported as a scan failure
  if ! _rsdd_scan; then tmp_scan_failed+=("$1 (default rsdd root $RSDD_DEFAULT_ROOT)"); return 0; fi
  for _k in "${!_rsdd_cur[@]}"; do [[ "${_rsdd_prev[$_k]+set}" == "set" ]] || _n=$((_n + 1)); done
  for _k in "${!_rsdd_prev[@]}"; do [[ "${_rsdd_cur[$_k]+set}" == "set" ]] || _r=$((_r + 1)); done
  # Roll forward so a later suite is not re-blamed for this one's entries.
  _rsdd_prev=(); for _k in "${!_rsdd_cur[@]}"; do _rsdd_prev["$_k"]=1; done
  if [[ "$_n" -gt 0 ]]; then
    tmp_leftovers+=("$1: $_n (in $RSDD_DEFAULT_ROOT)")
    tmp_leftover_total=$((tmp_leftover_total + _n))
  fi
  if [[ "$_r" -gt 0 ]]; then
    tmp_leftovers+=("$1: removed $_r (in $RSDD_DEFAULT_ROOT)")
    tmp_leftover_total=$((tmp_leftover_total + _r))
  fi
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
# so only those candidates (typically at most -j N of them: the union over leaked paths and windows, never the whole corpus) are re-run serially, each
# under a per-suite timeout (RUN_ALL_ATTRIBUTION_TIMEOUT seconds, default 600, via `timeout` when
# present). A candidate is blamed when the leaked path's signature (full-resolution mtime AND
# content hash) changes across its re-run: mtime alone misses a suite that restores the mtime, the
# hash alone misses an identical-bytes rewrite. It only runs when the batch found a new/modified
# leak, so a clean -j run and the serial path are untouched. Everything that cannot be attributed
# (removed paths, no window containing the mtime, a leak that does not reproduce, a missing stat
# or date capability) keeps the typed batch label AND gets a typed `Attribution:` line saying why
# — never a silent label. Side effects of a re-run are the suite's own (the same as the first run).
ATTRIBUTION_LINES=()
ATTR_TOL_FINE=0.05     # seconds: sub-second (GNU stat %.9Y) mtime vs a fractional run window
ATTR_TOL_COARSE=1      # seconds: whole-second mtime (BSD stat -f %m) or whole-second run window
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
_pend_add() {   # _pend_add <violations-array-name> <src-tag> <root> <first-new-index>: queue the new/modified batch entries from <first-new-index> on
  local -n _pv="$1"; local _from="$4" _i _e _kind _path
  for ((_i = _from; _i < ${#_pv[@]}; _i++)); do
    _e="${_pv[$_i]#"$PARALLEL_LABEL leaked: "}"
    _kind="${_e##* (}"; _kind="${_kind%)}"; _path="${_e% (*}"
    [[ "$_kind" == removed ]] && continue
    _pend_path+=("$3/$_path"); _pend_src+=("$2:$_path"); _pend_kind+=("$_kind"); _pend_done+=("")
  done
}
_attribute_batch_leaks() {
  local _i _j _s _b _m _w _ws _we _wt _tol _t _cmd_to _rt
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
  _tol="$ATTR_TOL_FINE"; [[ "$_STAT_MODE" == bsd ]] && _tol="$ATTR_TOL_COARSE"
  # Candidate suites: those whose recorded window contains a leaked path's mtime.
  for _i in "${!_pend_path[@]}"; do
    _m="$(_mtime_of "${_pend_path[$_i]}")"
    [[ "$_m" == absent ]] && continue
    for _j in "${!all_suites[@]}"; do
      [[ -f "$PAR_DIR/$((_j + 1)).win" ]] || continue
      read -r _ws _we < "$PAR_DIR/$((_j + 1)).win"
      # Whole-second window records (a `date` without %N) widen the tolerance: the stat mtime keeps
      # its fraction, so [floor(start), floor(end)] alone would miss a write in the last second.
      _wt="$_tol"; [[ "$_ws$_we" == *.* ]] || _wt="$ATTR_TOL_COARSE"
      if awk -v m="$_m" -v s="$_ws" -v e="$_we" -v t="$_wt" 'BEGIN { exit !(m + 0 >= s - t && m + 0 <= e + t) }'; then
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
  # `timeout abc` exits 125 without running the suite: every re-run would then "reproduce nothing"
  # silently. Validate once, say so, and fall back to the default.
  if ! [[ "$_t" =~ ^[1-9][0-9]*$ ]]; then
    ATTRIBUTION_LINES+=("Attribution: RUN_ALL_ATTRIBUTION_TIMEOUT='$_t' is not a positive integer; using 600")
    _t=600
  fi
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
# An empty shard (kit issue #2114) has nothing to batch; `parallel ::: <nothing>` would read stdin.
[[ ${#all_suites[@]} -gt 0 ]] || JOBS_ACTIVE=""
_rsdd_snapshot
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
_now() { local _v; _v="$(date +%s.%N 2>/dev/null)"; case "$_v" in ""|*[!0-9.]*) _v="$(date +%s 2>/dev/null)" ;; esac; printf '%s' "$_v"; }
_t0="$(_now)"
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
_t1="$(_now)"
case "$_t0$_t1" in *[!0-9.]*|"") ;; *) echo "$_t0 $_t1" > "$PAR_DIR/$idx.win" ;; esac
echo "$rc" > "$PAR_DIR/$idx.rc.tmp" && mv "$PAR_DIR/$idx.rc.tmp" "$PAR_DIR/$idx.rc"
echo "run-all.sh: -j done: $(basename "$suite") rc=$rc" >&2
WORKER
  export PAR_DIR PROVE_TEETH
  # A suite the cache reuses (--cache) is not handed to the batch; the others keep their position in the serial order as
  # their index, so the replay below finds <index>.rc/.out whether or not hits are interleaved.
  _par_idx=(); _par_run=()
  for ((_pi = 0; _pi < ${#all_suites[@]}; _pi++)); do
    [[ "${cache_state[${all_suites[$_pi]}]-}" == hit ]] && continue   # SENTINEL-CACHE-J-SKIP
    _par_idx+=("$((_pi + 1))"); _par_run+=("${all_suites[$_pi]}")
  done
  echo "run-all.sh: -j $JOBS — running ${#_par_run[@]} suite(s) in parallel (output replayed in serial order below)" >&2
  if [[ ${#_par_run[@]} -gt 0 ]]; then
    parallel --line-buffer -j "$JOBS" bash "$PAR_DIR/run1.sh" '{1}' '{2}' ::: "${_par_idx[@]}" :::+ "${_par_run[@]}" >/dev/null
  fi
  # No silent zero: every suite that was handed to the batch must have left a result file.
  _par_results=$(find "$PAR_DIR" -maxdepth 1 -name '*.rc' | wc -l)
  if [[ "$_par_results" -ne "${#_par_run[@]}" ]]; then
    echo "run-all.sh: -j batch recorded $_par_results result(s) for ${#_par_run[@]} suite(s); the missing suites are reported as failed" >&2
  fi
  _hv_before=${#hermeticity_violations[@]}; _kv_before=${#kit_tree_violations[@]}
  _check_cwd_hermeticity "$PARALLEL_LABEL"
  _check_kit_tree_hermeticity "$PARALLEL_LABEL"
  # Own label: PARALLEL_LABEL points at an 'Attribution:' line that is never printed for this check.
  _check_rsdd_default_root "-j batch (default rsdd root: per-suite attribution not attempted)"
  _attribute_batch_leaks "$_hv_before" "$_kv_before"
fi

# --- Per-suite wall time (kit issue #2230) --------------------------------------------------------------------
# timing_rows holds "<seconds>|<repo-relative suite>|<rc>" for every suite that was MEASURED; a reused (--cache)
# suite ran nothing and is counted apart (timing_cached), a suite with no usable measurement is counted in
# timing_unmeasured: none of the three may read as 0 s (CLAUDE.md section 7).
timing_rows=(); timing_cached=0; timing_unmeasured=0
_ts_now() { local _v; _v="$(date +%s.%N 2>/dev/null)"; case "$_v" in ""|*[!0-9.]*) _v="$(date +%s 2>/dev/null)" ;; esac; printf '%s' "$_v"; }
# _ts_secs <t0> <t1> — elapsed seconds with one decimal; prints nothing when either end is not a number or t1 < t0.
_ts_secs() {
  case "$1$2" in ""|*[!0-9.]*) return 0 ;; esac
  awk -v a="$1" -v b="$2" 'BEGIN { if (a ~ /^[0-9]+(\.[0-9]+)?$/ && b ~ /^[0-9]+(\.[0-9]+)?$/ && b >= a) printf "%.1f", b - a }'
}

suite_idx=0
_viol_at_start=$((${#hermeticity_violations[@]} + ${#kit_tree_violations[@]}))   # under -j: what the batch snapshot already found
for suite in "${all_suites[@]}"; do
  base="$(basename "$suite")"
  suites_run=$((suites_run + 1))
  suite_idx=$((suite_idx + 1))

  _cache_hit=""
  [[ "${cache_state[$suite]-}" == hit ]] && _cache_hit=1
  echo "==============================================================="
  echo ">>> running: $base${_cache_hit:+ (cached)}"
  echo "==============================================================="
  _ts_t0=""; [[ -n "$_cache_hit" || -n "$JOBS_ACTIVE" ]] || _ts_t0="$(_ts_now)"   # -j suites carry their own window (<idx>.win)

  # Build the command. Only *.test.sh suites accept --prove-teeth.
  # A direct pipe to `tee` streams output AND captures it; the pipeline waits
  # for `tee` to finish, so the temp file is fully written before we parse it.
  # PIPESTATUS[0] is the SUITE's exit code (not tee's) — reliable under pipefail.
  if [[ -n "$_cache_hit" ]]; then
    # --cache: replay the recorded output of the previous full PASS (line 1 is the entry header); nothing executes, so the
    # hermeticity and TMPDIR checks below have nothing to judge for this suite.
    tail -n +2 "${cache_file[$suite]}" > "$tmp_out"
    cat "$tmp_out"
    rc=0
  elif [[ -n "$JOBS_ACTIVE" ]]; then
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

  _ts_val=""
  if [[ -n "$_cache_hit" ]]; then
    timing_cached=$((timing_cached + 1))
  else
    if [[ -n "$JOBS_ACTIVE" ]]; then
      _ts_w0=""; _ts_w1=""; [[ -f "$PAR_DIR/$suite_idx.win" ]] && read -r _ts_w0 _ts_w1 < "$PAR_DIR/$suite_idx.win"
      _ts_val="$(_ts_secs "$_ts_w0" "$_ts_w1")"
    else
      _ts_val="$(_ts_secs "$_ts_t0" "$(_ts_now)")"
    fi
    if [[ -n "$_ts_val" ]]; then timing_rows+=("$_ts_val|${suite_rel[$suite]}|$rc"); else timing_unmeasured=$((timing_unmeasured + 1)); fi
  fi

  _viol_before=$((${#hermeticity_violations[@]} + ${#kit_tree_violations[@]})); _left_before=$tmp_leftover_total
  if [[ -z "$JOBS_ACTIVE" && -z "$_cache_hit" ]]; then
    _check_cwd_hermeticity "$base"
    _check_kit_tree_hermeticity "$base"
    _check_rsdd_default_root "$base"
  fi
  # After the suite (serial) or the whole batch (-j: its subdir is its own either way). A reused result ran nothing.
  [[ -n "$_cache_hit" ]] || _check_tmp_leftovers "$base" "$suite_idx"
  _suite_clean=""   # no hermeticity / TMPDIR finding from THIS suite's check (and none from a -j batch, which cannot be attributed)
  [[ $((${#hermeticity_violations[@]} + ${#kit_tree_violations[@]})) -eq "$_viol_before" && "$tmp_leftover_total" -eq "$_left_before" && "$_viol_at_start" -eq 0 ]] && _suite_clean=1


  # Parse the LAST matching summary line from the captured output.
  # Also accumulate per-test skip lines ("  SKIP  ..." indented format).
  parsed_line=""
  _suite_test_skips=0
  while IFS= read -r line; do
    if [[ "$line" =~ $summary_re ]]; then
      parsed_line="$line"
      s_passed="${BASH_REMATCH[1]}"
      s_failed="${BASH_REMATCH[2]}"
    elif [[ "$line" == "  SKIP  "* ]]; then
      total_skipped=$((total_skipped + 1))
      _suite_test_skips=$((_suite_test_skips + 1))
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
    # is detected from `<<[-]WORD` in a command context only; `<<<` herestrings, a `<<` inside quotes and
    # one inside an awk regex literal are ignored — kit issue #1647). A `bash -c '. .../lib/mutant.sh && ...'`
    # string (Python-bodied suites) counts as use. Known limits: a second level of
    # indirection and a quoted multi-line string that looks like a source line are not resolved.
    # One awk process, NOT `grep -v | grep -q`: under pipefail the early-exiting `grep -q` SIGPIPEs the
    # producer (rc 141) on any suite larger than the pipe buffer and mislabels it a non-user.
    # SENTINEL-HELPER-USE-TEST
    if [[ "$_has_teeth" -eq 1 ]] && ! awk '
      # Python-bodied suites (kit issue #1647): a bash -c string whose body sources the helper. Checked on
      # EVERY non-comment line, heredoc bodies included (gate.test.sh embeds its Python in a heredoc).
      !/^[[:space:]]*#/ && /bash["\047,[:space:]]+-c["\047,[:space:]]+(\.|source)[[:space:]]+[^#]*lib\/mutant\.sh/ { py = 1 }
      hd != "" { t = $0; sub(/^[ \t]+/, "", t); if (t == hd) hd = ""; next }
      /^[[:space:]]*#/ { next }
      { code[++n] = $0
        # Heredoc opener: `<<` [-] optional blanks, optional quote or backslash, then a WORD (kit
        # issue #1647). `<<` inside an awk regex literal (`/<<-?[[:space:]]*...`), preceded by `/`,
        # or inside a quoted string (open quote state at it) is not an opener.
        if ($0 !~ /<<</ && match($0, /<<-?[ \t]*[\\"\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
          # Quote state is scanned left to right (escapes honoured; an apostrophe inside "..." is
          # literal), not inferred from raw parity: `echo "it'"'"'s"; cat <<EOF` is a real opener.
          qs = ""
          for (k = 1; k < RSTART; k++) {
            ch = substr($0, k, 1)
            if (qs == "\047") { if (ch == "\047") qs = "" }
            else if (ch == "\\") k++
            else if (qs == "\"") { if (ch == "\"") qs = "" }
            else if (ch == "\047" || ch == "\"") qs = ch
          }
          if (qs == "" && substr($0, RSTART - 1, 1) != "/") {
            d = substr($0, RSTART, RLENGTH); sub(/^<<-?[ \t]*[\\"\047]?/, "", d); hd = d } } }
      END {
        if (py) exit 0
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
  _res=FAIL
  if [[ "$rc" -eq 0 ]] && grep -q '^SKIP:' "$tmp_out"; then
    suites_skipped+=("$base")
    _res=SKIP
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
        _res=PASS   # SENTINEL-SHARD-RESULT-PASS
        ;;
      *)
        failed_suites+=("$base (exit $rc)")
        ;;
    esac
  fi

  # --cache: record a FULL pass only (SENTINEL-CACHE-STORE). Never a FAIL/SKIP, a suite with per-test skips (an
  # environment-dependent result), or anything once this run has a hermeticity / TMPDIR violation: replaying a
  # leaking suite's PASS would hide the leak.
  # SENTINEL-CACHE-SKIPLINE: any line that starts with SKIP (indented or not, `SKIP:` or `SKIP  case`) marks an
  # environment-dependent result
  _suite_skip_seen=0
  if [[ "${cache_state[$suite]-}" == miss ]] && grep -qE '^[[:space:]]*SKIP([^[:alnum:]_]|$)' "$tmp_out"; then _suite_skip_seen=1; fi
  if [[ "${cache_state[$suite]-}" == miss && "$_res" == PASS && "$_suite_skip_seen" -eq 0 && "${s_failed:-1}" -eq 0 \
        && -n "$_suite_clean" ]]; then
    [[ -n "${_cache_head-}" ]] || { _cache_head="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null)" || _cache_head=""; : "${_cache_head:=nohead}"; }
    if { printf 'PASS %s 0 %s %s\n' "$s_passed" "$(date +%Y-%m-%d)" "$_cache_head"; cat "$tmp_out"; } > "$CACHE_DIR/.tmp.$$.$suite_idx" 2>/dev/null \
       && mv -f "$CACHE_DIR/.tmp.$$.$suite_idx" "${cache_file[$suite]}" 2>/dev/null; then
      cache_stored=$((cache_stored + 1))
    else
      rm -f "$CACHE_DIR/.tmp.$$.$suite_idx" 2>/dev/null
      cache_store_failed=$((cache_store_failed + 1))
      echo "run-all.sh: WARNING: could not store the cache entry for $base in $CACHE_DIR" >&2
    fi
  fi

  suite_results+=("${suite_rel[$suite]} $_res")
  echo
done

# --- Final aggregate block ------------------------------------------------
suites_failed=$((suites_run - suites_ok - ${#suites_skipped[@]}))
_cache_note=""; [[ ${#cache_hit_names[@]} -eq 0 ]] || _cache_note=" (${#cache_hit_names[@]} cached suites not checked)"   # a reused result ran nothing, so these checks never saw it

echo "==============================================================="
echo "AGGREGATE RESULT"
echo "==============================================================="
echo "Corpus: toolbelt tests ($SCRIPT_DIR) = $((${#sh_suites[@]} + ${#mjs_suites[@]})) suite(s)"
if [[ "$INSTALL_TESTS_DEGRADED" -eq 1 ]]; then
  echo "Corpus: install tests — ABSENT-INPUT (research-sdd/install/tests not found; NOT traversed; run exits non-zero)"
else
  echo "Corpus: install tests ($INSTALL_TESTS_DIR) = $((${#install_sh_suites[@]} + ${#install_mjs_suites[@]})) suite(s)"
fi
if [[ -n "$TIER_DEGRADED" ]]; then
  echo "Tier: DEGRADED — $TIER_DEGRADED; ran all $discovered_suites suites; run exits non-zero"
else
  echo "Tier: $TIER — $tier_selected of $discovered_suites suites (excluded: $((discovered_suites - tier_selected)))"
fi
if [[ -n "$IMPACTED_REF" ]]; then
  echo "Impacted: $total_suites of $tier_selected suites (base $IMPACTED_REF, merge-base $IMPACTED_SHA)"
  if [[ "$IMPACTED_ESC" == "no" ]]; then
    echo "Impacted escalated: no"
  else
    echo "Impacted escalated: FULL — $IMPACTED_ESC"
  fi
  echo "Impacted skipped: $((tier_selected - total_suites)) (selected $total_suites + skipped $((tier_selected - total_suites)) = $tier_selected suites in the tier)"
  [[ -z "$IMPACTED_OUTSIDE" ]] || echo "Impacted outside tier: $IMPACTED_OUTSIDE"
fi
if [[ -n "$LANE_ARG" ]]; then
  echo "Lane: $LANE_ARG — exported to every suite as RSDD_TEST_LANE"
fi
if [[ -n "$CACHE_DEGRADED_REASON" ]]; then
  echo "Cache: DEGRADED — $CACHE_DEGRADED_REASON; ran every suite without the cache"
elif [[ -n "$CACHE_ACTIVE" ]]; then
  _cu=""; if [[ ${#cache_unc_names[@]} -gt 0 ]]; then _cu="$(printf '%s, ' "${cache_unc_names[@]}")"; _cu="${_cu%, }"; fi
  _ch="none"; if [[ ${#cache_hit_names[@]} -gt 0 ]]; then _ch="$(printf '%s, ' "${cache_hit_names[@]}")"; _ch="${_ch%, }"; fi
  echo "Cache: hit ${#cache_hit_names[@]}, miss $cache_miss_count, uncacheable ${#cache_unc_names[@]} — [$_cu]"
  echo "Cache hits: $_ch"
  echo "Cache stored: $cache_stored"
  [[ "$cache_store_failed" -eq 0 ]] || echo "Cache store FAILED: $cache_store_failed entr(y/ies) could not be written to $CACHE_DIR (those suites will run again)"
  echo "Cache dir: $CACHE_DIR"
fi
if [[ -n "$SHARD_N" ]]; then
  echo "Shard: $SHARD_I/$SHARD_N — ${#all_suites[@]} of $total_suites suites"
  if [[ ${#all_suites[@]} -eq 0 ]]; then
    # SENTINEL-SHARD-EMPTY
    echo "Shard: EMPTY SHARD — $SHARD_I/$SHARD_N selected 0 of $total_suites suites (N exceeds the suite count); nothing ran, so this shard is not a pass"
  fi
  [[ -z "$SHARD_MANIFEST" ]] || echo "Shard manifest: $SHARD_MANIFEST"
fi
if [[ -n "$JOBS_ACTIVE" ]]; then
  echo "Parallel: -j $JOBS — a leak found by the batch snapshot is attributed by a serial re-run bounded to the candidate suites whose run window contained the leaked path's mtime (the suites whose recorded window matched — typically at most -j N, never the whole corpus; per-suite timeout RUN_ALL_ATTRIBUTION_TIMEOUT, default 600s); unattributed leaks keep the batch label plus a typed Attribution line"
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
  echo "Hermeticity violations (new/modified/removed top-level entries in caller cwd): ${#hermeticity_violations[@]}${_cache_note}"
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
  echo "Kit-tree hermeticity violations (new/modified/removed files under research-sdd/): ${#kit_tree_violations[@]}${_cache_note}"
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
  echo "TMPDIR leftovers: $tmp_leftover_total — [$_tl_names]${_cache_note}"
  if [[ "$tmp_leftover_total" -gt 0 ]]; then
    echo "  (a suite must remove what it creates under TMPDIR — kit issue #1277; fails the run only under --require-clean-tmp)"
  fi
  if [[ ${#tmp_scan_failed[@]} -gt 0 || ${#tmp_create_failed[@]} -gt 0 ]]; then
    _ts_names=""; _tc_names=""; _td_parts=()
    if [[ ${#tmp_scan_failed[@]} -gt 0 ]]; then _ts_names="$(printf '%s, ' "${tmp_scan_failed[@]}")"; _ts_names="${_ts_names%, }"; _td_parts+=("could not scan the TMPDIR of [$_ts_names]"); fi
    if [[ ${#tmp_create_failed[@]} -gt 0 ]]; then _tc_names="$(printf '%s, ' "${tmp_create_failed[@]}")"; _tc_names="${_tc_names%, }"; _td_parts+=("per-suite TMPDIR could not be created for [$_tc_names] (they ran on the caller's TMPDIR)"); fi
    # Only the clauses that apply (kit issue #1645): an empty [] clause is noise that reads as a finding.
    echo "TMPDIR scan: DEGRADED — $(printf '%s; ' "${_td_parts[@]}")their leftovers are unverified"
  fi
fi
# SENTINEL-TMPDIR-KEPT
if [[ -n "$KEEP_TMP" ]]; then
  if [[ -n "$RUN_TMP_ROOT" ]]; then echo "TMPDIR kept: $RUN_TMP_ROOT"
  else echo "TMPDIR kept: none (no per-run TMPDIR root was created, so there is nothing to keep)"; fi
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
# --- Slowest suites + timing history (kit issue #2230) --------------------------------------------------------
# SENTINEL-SLOWEST-SUITES
_ts_mode="serial"; [[ -z "$JOBS_ACTIVE" ]] || _ts_mode="-j $JOBS"
_ts_sorted=()
if [[ ${#timing_rows[@]} -gt 0 ]]; then mapfile -t _ts_sorted < <(printf '%s\n' "${timing_rows[@]}" | LC_ALL=C sort -t'|' -k1,1nr -k2,2); fi
_ts_top=${#_ts_sorted[@]}; [[ $_ts_top -le 15 ]] || _ts_top=15
echo "Slowest suites (top $_ts_top of ${#_ts_sorted[@]} timed, wall seconds, $_ts_mode): measured ${#_ts_sorted[@]}, cached $timing_cached (not timed), unmeasured $timing_unmeasured"
for ((_ti = 0; _ti < _ts_top; _ti++)); do
  IFS='|' read -r _ts_s _ts_n _ts_r <<< "${_ts_sorted[$_ti]}"
  printf '  %8s  %s%s\n' "$_ts_s" "$_ts_n" "$([[ "$_ts_r" == 0 ]] || echo " (rc=$_ts_r)")"
done
# SENTINEL-TIMING-HISTORY: append-only, outside the repo (the kit-tree hermeticity check fails a suite that writes into
# research-sdd/). A state dir that cannot be created or written is a typed degraded note; the gate result is unchanged.
if [[ ${#timing_rows[@]} -gt 0 ]]; then
  _th_dir="${XDG_STATE_HOME:-${HOME:-}/.local/state}/research-sdd"; _th_file="$_th_dir/suite-timings.log"
  _th_head="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null)" || _th_head=""; : "${_th_head:=nohead}"
  _th_date="$(date +%Y-%m-%d)"
  if [[ -z "${HOME:-}${XDG_STATE_HOME:-}" ]]; then
    echo "Suite timing history: DEGRADED — neither XDG_STATE_HOME nor HOME is set; ${#timing_rows[@]} timings not recorded"
  elif mkdir -p "$_th_dir" 2>/dev/null && {
         for _tr in "${timing_rows[@]}"; do IFS='|' read -r _ts_s _ts_n _ts_r <<< "$_tr"; printf '%s %s %s %s %s\n' "$_th_date" "$_th_head" "$_ts_n" "$_ts_s" "$_ts_r"; done
       } >> "$_th_file" 2>/dev/null; then
    echo "Suite timing history: appended ${#timing_rows[@]} row(s) to $_th_file"
  else
    echo "Suite timing history: DEGRADED — cannot write $_th_file; ${#timing_rows[@]} timings not recorded"
  fi
else
  echo "Suite timing history: nothing to record (no suite was measured)"
fi
echo "==============================================================="

# Exit 0 only if no suite failed AND at least one suite actually passed.
# A fully-skipped run (suites_ok == 0) exits 1 — zero test coverage is not "all green".
# The verdict is computed into final_rc (not exited inline) so a shard manifest can record it: a
# shard that failed on hermeticity/teeth with every suite PASS must not read as green at the join.
final_rc=1
if [[ $suites_failed -eq 0 ]] && [[ $suites_ok -gt 0 ]] \
   && [[ ${#hermeticity_violations[@]} -eq 0 ]] && [[ "$HERMETICITY_DEGRADED" -eq 0 ]] \
   && [[ ${#kit_tree_violations[@]} -eq 0 ]] && [[ "$KIT_TREE_DEGRADED" -eq 0 ]] \
   && [[ "$INSTALL_TESTS_DEGRADED" -eq 0 ]] && [[ -z "$TIER_DEGRADED" ]]; then
  final_rc=0
  # SENTINEL-REQUIRE-CLEAN-TMP-EXIT
  if [[ -n "$REQUIRE_CLEAN_TMP" ]] && { [[ "$tmp_leftover_total" -gt 0 ]] || [[ -n "$TMPDIR_DEGRADED_REASON" ]] || [[ ${#tmp_scan_failed[@]} -gt 0 ]] || [[ ${#tmp_create_failed[@]} -gt 0 ]]; }; then
    final_rc=1
  fi
  # SENTINEL-REQUIRE-TEETH-EXIT
  if [[ -n "$REQUIRE_TEETH" ]] && [[ ${#sh_no_teeth[@]} -gt 0 ]]; then
    final_rc=1
  fi
  # SENTINEL-TEETH-HELPER-EXIT
  if [[ -n "$REQUIRE_TEETH" ]] && { [[ ${#_unwaived[@]} -gt 0 ]] || [[ ${#_stale[@]} -gt 0 ]] \
     || [[ ${#_wv_invalid[@]} -gt 0 ]] || [[ "$_wv_state" == "unreadable" ]]; }; then
    final_rc=1
  fi
fi
# SENTINEL-SHARD-MANIFEST-WRITE
if [[ -n "$SHARD_MANIFEST" ]]; then
  {
    printf '# shard %s/%s suites=%s exit=%s\n' "$SHARD_I" "$SHARD_N" "${#all_suites[@]}" "$final_rc"
    [[ ${#suite_results[@]} -eq 0 ]] || printf '%s\n' "${suite_results[@]}"
  } > "$SHARD_MANIFEST.tmp.$$" && mv "$SHARD_MANIFEST.tmp.$$" "$SHARD_MANIFEST" \
    || { rm -f "$SHARD_MANIFEST.tmp.$$"; echo "run-all.sh: could not write the shard manifest '$SHARD_MANIFEST'" >&2; exit 1; }
fi
exit "$final_rc"
