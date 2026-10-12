#!/usr/bin/env bash
# kit-flake-hunt.sh — run test suites repeatedly under bounded synthetic CPU load and report every
# suite that failed at least once (a load flake), so timing flakes are found before they fail a
# gate (kit issue #2209; incident #2197: a teeth case failed at exactly its 5000 ms ceiling under
# load and cost four full gates before it was isolated; CLAUDE.md section 3 files "failed under
# load, passes standalone" as a defect).
#
# Usage:
#   kit-flake-hunt.sh [--repo DIR] [--runs K] [--load N] [--load-timeout S] [--suite-timeout S]
#                     [--suites FILE | --suite PATH ...] [--tier core|all] [--prove-teeth]
#                     [--out DIR] [--file-issues[=apply]]
#
#   --repo DIR          kit checkout to hunt in (default: the checkout this script lives in). Suites
#                       run with DIR as cwd, so the pre-fix tree of an incident can be replayed with
#                       the current script: `kit-flake-hunt.sh --repo <old-worktree> --suite ...`.
#   --runs K            passes over the selected suites (default 3, integer >= 1).
#   --load N            busy-loop workers (default nproc/2, min 1; 0 = no load).
#   --load-timeout S    every worker is wrapped in `timeout S` (default 14400) and also killed by PID
#                       when this script exits or is interrupted. Never pkill/killall by name.
#   --suite-timeout S   per-suite bound (default 900); a suite past it is recorded TIMEOUT and counts
#                       as a failure.
#   --suites FILE       one suite path per line (blank lines and #-comments skipped); --suite PATH is
#                       repeatable. Paths are relative to the repo or absolute. Without either, the
#                       suites run-all.sh would run (`run-all.sh --list-suites`).
#   --tier core|all     default all. `core` is tried as `run-all.sh --list-suites --tier core`; a
#                       runner that rejects --tier gets the full list and a `note:` line says so.
#   --prove-teeth       pass --prove-teeth to every suite.
#   --out DIR           results directory (default under ${XDG_STATE_HOME:-$HOME/.local/state}/
#                       research-sdd/flake-hunt/<timestamp>); inside the repo is refused.
#   --file-issues       print the exact `gh issue create|comment` it WOULD run per flaky suite (dry).
#   --file-issues=apply actually run it. An open issue with the suite name in its title is commented
#                       on, never duplicated; a failed search files nothing. Label: type:bug.
#
# Output: <out>/results.tsv = `<run>\t<suite>\t<PASS|FAIL|SKIP|TIMEOUT>\t<first FAIL line>` per
# run per suite, <out>/logs/<run>-<n>.log, then per suite `flaky: <suite> failed X/K — <line>`
# (failed in some runs), `broken: <suite> failed K/K — <line>` (failed in EVERY run: a defect, not
# a flake; with --runs 1 a failure cannot be told from a flake and reads as broken) and the totals
# line `Flake hunt: runs=K suites=M load=N flaky=F broken=B stable=S skipped=P`.
# Each suite sees FLAKE_HUNT_RUN (1-based), FLAKE_HUNT_SUITE and FLAKE_HUNT_OUT in its environment.
#
# Exit: 0 no flaky suite · 1 at least one flaky suite · 2 degraded or bad usage (a missing
# timeout/nproc/bash, no run-all.sh, no suites selected, an unreadable suite list, a failed issue
# search): a degraded run is not a clean hunt. A broken-only result exits 0 and is listed loudly.
#
# Local scheduling (nightly, no workflow needed):
#   17 3 * * *  cd ~/investigacion/sdd-investigacion && bash research-sdd/toolbelt/maint/kit-flake-hunt.sh --runs 5 --prove-teeth --file-issues >> ~/.local/state/research-sdd/flake-hunt.cron.log 2>&1
set -uo pipefail

usage() {
  echo "usage: kit-flake-hunt.sh [--repo DIR] [--runs K] [--load N] [--load-timeout S] [--suite-timeout S] [--suites FILE | --suite PATH ...] [--tier core|all] [--prove-teeth] [--out DIR] [--file-issues[=apply]]" >&2
}
die() { printf 'degraded: kit-flake-hunt: %s\n' "$1" >&2; exit 2; }
isint() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t

REPO="" RUNS=3 LOAD="" LOAD_TIMEOUT=14400 SUITE_TIMEOUT=900 TIER=all PROVE=0 OUT="" FILE_MODE="" SUITES_FILE=""
SUITE_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || { usage; exit 2; }; REPO="$2"; shift 2 ;;
    --runs) [ "$#" -ge 2 ] || { usage; exit 2; }; RUNS="$2"; shift 2 ;;
    --load) [ "$#" -ge 2 ] || { usage; exit 2; }; LOAD="$2"; shift 2 ;;
    --load-timeout) [ "$#" -ge 2 ] || { usage; exit 2; }; LOAD_TIMEOUT="$2"; shift 2 ;;
    --suite-timeout) [ "$#" -ge 2 ] || { usage; exit 2; }; SUITE_TIMEOUT="$2"; shift 2 ;;
    --suites) [ "$#" -ge 2 ] || { usage; exit 2; }; SUITES_FILE="$2"; shift 2 ;;
    --suite) [ "$#" -ge 2 ] || { usage; exit 2; }; SUITE_ARGS+=("$2"); shift 2 ;;
    --tier) [ "$#" -ge 2 ] || { usage; exit 2; }; TIER="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || { usage; exit 2; }; OUT="$2"; shift 2 ;;
    --prove-teeth) PROVE=1; shift ;;
    --file-issues) FILE_MODE=dry; shift ;;
    --file-issues=apply) FILE_MODE=apply; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "kit-flake-hunt: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# --- dependency probe (CLAUDE.md section 7: a missing tool is a typed degraded state, never a pass) ---
for _dep in bash timeout nproc; do
  command -v "$_dep" >/dev/null 2>&1 || die "required tool '$_dep' not found on PATH; the hunt cannot run"
done
isint "$RUNS" && [ "$RUNS" -ge 1 ] || { echo "kit-flake-hunt: --runs must be an integer >= 1 (got '$RUNS')" >&2; exit 2; }
if [ -z "$LOAD" ]; then
  _np="$(nproc 2>/dev/null)" || _np=""
  isint "$_np" && [ "$_np" -ge 1 ] || die "nproc gave no usable CPU count; pass --load N explicitly"
  LOAD=$((_np / 2)); [ "$LOAD" -ge 1 ] || LOAD=1
fi
isint "$LOAD" || { echo "kit-flake-hunt: --load must be an integer >= 0 (got '$LOAD')" >&2; exit 2; }
isint "$LOAD_TIMEOUT" && [ "$LOAD_TIMEOUT" -ge 1 ] || { echo "kit-flake-hunt: --load-timeout must be an integer >= 1" >&2; exit 2; }
isint "$SUITE_TIMEOUT" && [ "$SUITE_TIMEOUT" -ge 1 ] || { echo "kit-flake-hunt: --suite-timeout must be an integer >= 1" >&2; exit 2; }
case "$TIER" in core | all) ;; *) echo "kit-flake-hunt: --tier must be core or all (got '$TIER')" >&2; exit 2 ;; esac
if [ -n "$SUITES_FILE" ] && [ "${#SUITE_ARGS[@]}" -gt 0 ]; then echo "kit-flake-hunt: --suites and --suite are mutually exclusive" >&2; exit 2; fi

[ -n "$REPO" ] || REPO="$(cd -P -- "$_RSDD_SELF/../../.." && pwd -P)"
[ -d "$REPO" ] || die "repo directory not found: $REPO"
REPO="$(cd -P -- "$REPO" && pwd -P)"

# --- suite selection ---
SUITES=()
add_suite() { [ -n "$1" ] && SUITES+=("$1"); return 0; }
if [ -n "$SUITES_FILE" ]; then
  [ -r "$SUITES_FILE" ] || die "suite list not readable: $SUITES_FILE"
  # SENTINEL-FLAKE-LAST-LINE: a final line without a trailing newline still has to be read.
  while IFS= read -r _l || [ -n "$_l" ]; do
    _l="${_l%%#*}"; _l="${_l#"${_l%%[![:space:]]*}"}"; _l="${_l%"${_l##*[![:space:]]}"}"
    add_suite "$_l"
  done <"$SUITES_FILE"
elif [ "${#SUITE_ARGS[@]}" -gt 0 ]; then
  for _l in "${SUITE_ARGS[@]}"; do add_suite "$_l"; done
else
  RUNALL="$REPO/research-sdd/toolbelt/tests/run-all.sh"
  [ -f "$RUNALL" ] || die "run-all.sh not found at $RUNALL; pass --suite/--suites or a valid --repo"
  _listed=""
  if [ "$TIER" = core ] && _listed="$(cd -- "$REPO" && bash "$RUNALL" --list-suites --tier core 2>/dev/null)"; then :; else
    [ "$TIER" != core ] || echo "note: run-all.sh rejected --tier core; hunting the full suite list"
    _listed="$(cd -- "$REPO" && bash "$RUNALL" --list-suites 2>/dev/null)" || die "run-all.sh --list-suites failed"
  fi
  while IFS= read -r _l || [ -n "$_l" ]; do add_suite "$_l"; done <<<"$_listed"
fi
[ "${#SUITES[@]}" -gt 0 ] || die "no suites selected (an empty list is not a clean hunt)"
for _s in "${SUITES[@]}"; do
  case "$_s" in /*) _p="$_s" ;; *) _p="$REPO/$_s" ;; esac
  [ -f "$_p" ] || die "suite not found: $_s"
done

# --- output directory (never inside the repo) ---
[ -n "$OUT" ] || OUT="${XDG_STATE_HOME:-$HOME/.local/state}/research-sdd/flake-hunt/$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p -- "$OUT/logs" || die "cannot create output directory $OUT"
OUT="$(cd -P -- "$OUT" && pwd -P)"
case "$OUT/" in "$REPO"/*) rm -rf -- "$OUT"; die "output directory is inside the repo ($REPO); choose another --out" ;; esac
RESULTS="$OUT/results.tsv"; : >"$RESULTS"
export FLAKE_HUNT_OUT="$OUT"

# --- load generator: timeout-bounded busy loops, killed by PID on exit ---
LOAD_PIDS=(); SUITE_PID=""
kill_group() { kill -TERM -- "-$1" 2>/dev/null || kill -TERM "$1" 2>/dev/null; return 0; }
# SENTINEL-FLAKE-CLEANUP: every worker is stopped by PID (its own process group), never by name.
cleanup() {
  local p
  [ -z "$SUITE_PID" ] || kill_group "$SUITE_PID"
  for p in "${LOAD_PIDS[@]+"${LOAD_PIDS[@]}"}"; do kill_group "$p"; done
  for p in "${LOAD_PIDS[@]+"${LOAD_PIDS[@]}"}"; do wait "$p" 2>/dev/null; done
  LOAD_PIDS=(); SUITE_PID=""
}
trap cleanup EXIT
# SENTINEL-FLAKE-TERM-TRAP
trap 'exit 143' TERM
trap 'exit 130' INT
_i=0
while [ "$_i" -lt "$LOAD" ]; do
  timeout "$LOAD_TIMEOUT" bash -c 'while :; do :; done' "kit-flake-hunt-load:$OUT" >/dev/null 2>&1 &
  LOAD_PIDS+=("$!"); _i=$((_i + 1))
done

# --- hunt ---
declare -A FAILS=() SKIPS=() FIRST=() SEEN=()
for ((run = 1; run <= RUNS; run++)); do
  idx=0
  for s in "${SUITES[@]}"; do
    idx=$((idx + 1))
    case "$s" in /*) p="$s" ;; *) p="$REPO/$s" ;; esac
    log="$OUT/logs/$run-$idx.log"
    args=(); [ "$PROVE" -eq 1 ] && args=(--prove-teeth)
    ( cd -- "$REPO" && export FLAKE_HUNT_RUN="$run" FLAKE_HUNT_SUITE="$s" && exec timeout "$SUITE_TIMEOUT" bash "$p" "${args[@]+"${args[@]}"}" ) >"$log" 2>&1 &
    SUITE_PID=$!
    wait "$SUITE_PID"; rc=$?
    SUITE_PID=""
    first=""
    if [ "$rc" -eq 124 ]; then st=TIMEOUT
    elif [ "$rc" -eq 0 ]; then
      # SENTINEL-FLAKE-SKIP: a clean exit with a `SKIP:` line is a skip, not a pass.
      if grep -q '^SKIP:' "$log"; then st=SKIP; else st=PASS; fi
    else st=FAIL; fi
    if [ "$st" = FAIL ] || [ "$st" = TIMEOUT ]; then
      first="$(grep -m1 '^  FAIL  ' "$log" 2>/dev/null)" || first=""
      first="${first#"${first%%[![:space:]]*}"}"
      [ -n "$first" ] || first="exit=$rc, no '  FAIL  ' line in $log"
      first="${first//$'\t'/ }"
      FAILS[$s]=$(( ${FAILS[$s]:-0} + 1 ))
      [ -n "${FIRST[$s]:-}" ] || FIRST[$s]="$first"
    fi
    [ "$st" != SKIP ] || SKIPS[$s]=$(( ${SKIPS[$s]:-0} + 1 ))
    SEEN[$s]=$(( ${SEEN[$s]:-0} + 1 ))
    printf '%s\t%s\t%s\t%s\n' "$run" "$s" "$st" "$first" >>"$RESULTS"
  done
done

# --- report ---
flaky=0 broken=0 stable=0 skipped=0
FLAKY_LIST=()
for s in "${SUITES[@]}"; do
  [ "${SEEN[$s]:-0}" -gt 0 ] || continue
  f="${FAILS[$s]:-0}"
  if [ "$f" -eq 0 ]; then
    if [ "${SKIPS[$s]:-0}" -eq "$RUNS" ]; then skipped=$((skipped + 1)); else stable=$((stable + 1)); fi
  elif [ "$f" -eq "$RUNS" ]; then
    # SENTINEL-FLAKE-BROKEN: failed in every run is a defect, not a flake.
    broken=$((broken + 1)); printf 'broken: %s failed %s/%s — %s\n' "$s" "$f" "$RUNS" "${FIRST[$s]}"
  else
    flaky=$((flaky + 1)); FLAKY_LIST+=("$s"); printf 'flaky: %s failed %s/%s — %s\n' "$s" "$f" "$RUNS" "${FIRST[$s]}"
  fi
done
printf 'Flake hunt: runs=%s suites=%s load=%s flaky=%s broken=%s stable=%s skipped=%s\n' "$RUNS" "${#SUITES[@]}" "$LOAD" "$flaky" "$broken" "$stable" "$skipped"
printf 'Results: %s\n' "$RESULTS"

# --- issue filing (dry unless =apply) ---
rc_out=0; [ "$flaky" -eq 0 ] || rc_out=1
if [ -n "$FILE_MODE" ] && [ "$flaky" -gt 0 ]; then
  have_gh=1; command -v gh >/dev/null 2>&1 || have_gh=0
  if [ "$have_gh" -eq 0 ] && [ "$FILE_MODE" = apply ]; then
    echo "degraded: kit-flake-hunt: gh not found; --file-issues=apply cannot file anything" >&2; exit 2
  fi
  for s in "${FLAKY_LIST[@]}"; do
    base="${s##*/}"
    case "$base" in *[!A-Za-z0-9._-]*) echo "degraded: kit-flake-hunt: suite name '$base' is not filename-safe; not filing" >&2; rc_out=2; continue ;; esac
    existing=""; checked=1
    if [ "$have_gh" -eq 1 ]; then
      if existing="$(gh issue list --state open --search "$base in:title" --json number,title -q ".[] | select(.title | contains(\"$base\")) | .number" 2>/dev/null)"; then
        existing="${existing%%$'\n'*}"
      else
        if [ "$FILE_MODE" = apply ]; then echo "degraded: kit-flake-hunt: gh issue search failed for $base; nothing filed for it" >&2; rc_out=2; continue; fi
        existing=""; checked=0
      fi
    else checked=0; fi
    body="$OUT/issue-$base.md"
    printf 'Load flake found by kit-flake-hunt (kit issue #2209).\n\nsuite: %s\nfailed: %s/%s runs under load=%s (prove-teeth=%s)\nfirst failing line: %s\nresults: %s\n' \
      "$s" "${FAILS[$s]}" "$RUNS" "$LOAD" "$PROVE" "${FIRST[$s]}" "$RESULTS" >"$body"
    if [ -n "$existing" ]; then
      cmd=(gh issue comment "$existing" --body-file "$body")
    else
      cmd=(gh issue create --title "flake: $base failed ${FAILS[$s]}/$RUNS under CPU load" --label type:bug --body-file "$body")
    fi
    # SENTINEL-FLAKE-APPLY-GATE: dry mode must never reach the mutating call.
    if [ "$FILE_MODE" = apply ]; then
      printf 'running: '; printf '%q ' "${cmd[@]}"; printf '\n'
      "${cmd[@]}" || { echo "degraded: kit-flake-hunt: gh failed for $base" >&2; rc_out=2; }
    else
      printf 'would run: '; printf '%q ' "${cmd[@]}"
      [ "$checked" -eq 1 ] || printf '# dedupe not checked: gh unavailable or search failed'
      printf '\n'
    fi
  done
fi
exit "$rc_out"
