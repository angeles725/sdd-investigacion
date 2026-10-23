#!/usr/bin/env bash
# run-all-default-root.test.sh — regression guard for kit issue #2164.
#
# The VM/Docker tools fall back to the literal host root /tmp/rsdd (docker_common._DEFAULT_RSDD_ROOT) when
# $RSDD_VM_ROOT is unset, and that root is neither under a suite's per-suite TMPDIR nor under research-sdd/,
# so a suite that left run dirs there was invisible to run-all's other checks (capture-analyze left one per run;
# PR #2131's shard failure came from a helper silently depending on what such suites left behind).
#
# This suite proves, against an EMPTY /tmp, that no suite that drives the run-dir allocator leaves ENTRIES in the
# default root. Each suite runs inside `unshare -rm` with a fresh tmpfs on /tmp, so the real /tmp/rsdd is never
# read or written and a developer's own run dirs cannot mask or fake a result. Creating the (empty) mountpoint
# directory is NOT a leak: adapter_core.sandbox() makes it by design as the bwrap --tmpfs mountpoint, and several
# preflight cases need the directory to exist. Root-ownership checks (e.g. the bwrap launcher) fail inside the
# user namespace; that is an artefact, so a suite's own exit code is not asserted here — only that it RAN (it
# printed its summary line, never a silent zero) and what it left in the default root.
#
# Usage: run-all-default-root.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MID='·'
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Measured here: capture-analyze (plain run) and fact-exec + docker-exec (trimmed --prove-teeth runs, below). All have PROOF that
# the allocator runs against the default root: capture-analyze's pre-fix state leaves a run dir, and the fact-exec and docker-exec
# root-hardcoded mutants allocate there by design (see the mutant teeth below). Attribution for #2186 (every run-dir suite, plain
# and --prove-teeth, in an empty-/tmp namespace) found docker-exec --prove-teeth as the only other source. The other run-dir suites (capture-exec, docker-exec plain,
# detonate-exec, trace-exec, qemu-exec) already set RSDD_VM_ROOT and carry their own *-NOLEAK guard, and a preflight
# failure inside the namespace would read as entries=0 for them without proving anything.
SUITES=(capture-analyze)

# RSDD_REQUIRE_UNSHARE=1 (opt-in) turns the missing-unshare SKIP into a typed FAIL, so a CI lane that is meant to
# have user namespaces cannot silently lose this guard. Unset, a host without `unshare -rm` is a typed SKIP.
echo "== run-all-default-root.test.sh =="
if ! command -v unshare >/dev/null 2>&1 || ! unshare -rm true >/dev/null 2>&1; then
  if [ "${RSDD_REQUIRE_UNSHARE:-}" = 1 ]; then
    echo "  FAIL  unshare -rm unavailable but RSDD_REQUIRE_UNSHARE=1: the empty-/tmp measurement cannot run"
    echo "== 0 passed $MID 1 failed =="
    exit 1
  fi
  echo "SKIP: default-root leak tests (unshare -rm unavailable: cannot get an empty /tmp without touching the real one)"
  echo "== 0 passed $MID 0 failed =="
  exit 0
fi

# inner.sh runs INSIDE the namespace: optional bind of a work tree, empty tmpfs on /tmp, run the suite, report.
# argv: <bind-src|-> <bind-dst|-> <cwd> <suite-path> [suite-arg]
cat > "$TMP/inner.sh" <<'INNER'
#!/usr/bin/env bash
src="$1"; dst="$2"; cwd="$3"; suite="$4"; sarg="${5:-}"
if [ "$src" != "-" ]; then mount --bind "$src" "$dst" || { echo "result bind-failed"; exit 0; }; fi
mount -t tmpfs tmpfs /tmp || { echo "result mount-failed"; exit 0; }
unset DE_GLOBAL_ROOT FE_GLOBAL_ROOT   # a caller-set redirect must not hide a pre-fix leak
unset DE_GLOBAL_ROOT FE_GLOBAL_ROOT   # a caller-set redirect must not hide a pre-fix leak
mkdir /tmp/work && export TMPDIR=/tmp/work
cd "$cwd" || { echo "result cd-failed"; exit 0; }
timeout 900 bash "$suite" $sarg > /tmp/out.log 2>&1
rc=$?
ran=0; grep -qE '^== [0-9]+ passed' /tmp/out.log && ran=1
# tooth=1: the fact-exec or docker-exec root-hardcoded mutant (which really allocates a run dir) was caught, i.e. the allocator ran.
tooth=0; grep -qE '^  PASS  teeth-root-hardcoded' /tmp/out.log && tooth=1
if [ -e /tmp/rsdd ]; then
  # find's own rc is the scan verdict; a failed scan must never read as "0 entries".
  if ! listing="$(find /tmp/rsdd -mindepth 1 -maxdepth 1 2>/dev/null)"; then echo "result scan-failed"; exit 0; fi
  if [ -n "$listing" ]; then n=$(printf '%s\n' "$listing" | wc -l); else n=0; fi
else n=0; fi
echo "result rc=$rc ran=$ran tooth=$tooth entries=$n"
INNER

# run_in_empty_tmp <bind-src|-> <bind-dst|-> <cwd> <suite-path> [suite-arg] — sets RESULT to the inner "result ..." line.
run_in_empty_tmp(){
  RESULT="$(unshare -rm bash "$TMP/inner.sh" "$1" "$2" "$3" "$4" "${5:-}" 2>&1 | grep '^result ' | tail -1)"
}
# judge <label> — OK only when the suite RAN and left no entries in the default root.
judge(){
  case "$RESULT" in
    "") no "$1: no result from the namespace runner (silent zero)"; return 1 ;;
    "result bind-failed"|"result mount-failed"|"result cd-failed"|"result scan-failed") no "$1: harness error: $RESULT"; return 1 ;;
  esac
  case "$RESULT" in *"ran=1"*) ;; *) no "$1: the suite never printed its summary line ($RESULT) — nothing was proven"; return 1 ;; esac
  # judge <label> tooth: additionally require proof that the allocator ran (the suite's allocating mutant was caught).
  if [ "${2:-}" = tooth ]; then case "$RESULT" in *"rc=0 ran=1 tooth=1"*) ;; *) no "$1: the allocating tooth did not pass with rc=0 ($RESULT) — nothing was proven"; return 1 ;; esac; fi
  case "$RESULT" in *"entries=0") ok "$1: left no entries in the default rsdd root ($RESULT)"; return 0 ;; esac
  no "$1: LEFT entries in the default rsdd root ($RESULT)"; return 1
}

for s in "${SUITES[@]}"; do
  [ -f "$HERE/$s.test.sh" ] || { no "$s: suite file missing under $HERE"; continue; }
  run_in_empty_tmp - - "$HERE" "$HERE/$s.test.sh"
  judge "default-root-clean $s"
done

# fact-exec (#2171): its --prove-teeth run leaves rsdd-<uuid> dirs in the default root when the `teeth-root-hardcoded` mutant
# (which deliberately allocates there) is not redirected. The full teeth run takes ~25 min, so this runs a TRIMMED copy that
# keeps only that one tooth. `tooth=1` is the proof the allocator ran: the mutant allocated a run dir and the suite caught it.
# Measured cost of the trimmed run: ~77 s on top of a ~5 s plain suite, so it runs ONLY under --prove-teeth (the gate lane that already
# runs every suite's mutation controls); the default lane stays fast.
# The trimmed tree needs a bind mount point because the real /tmp (where $TMP lives) is hidden by the empty tmpfs.
if [ "${1:-}" = "--prove-teeth" ]; then
MNT=""; for d in /mnt /media /srv /opt; do [ -d "$d" ] && { MNT="$d"; break; }; done
if [ -z "$MNT" ]; then
  printf '  SKIP  %s\n' "fact-exec + docker-exec teeth default-root (no /mnt, /media, /srv or /opt mount point for the work tree)"
elif [ ! -f "$HERE/fact-exec.test.sh" ]; then no "fact-exec: suite file missing under $HERE"
else
  # fe_trim <src> <dst-tree> - build the trimmed tree (symlinked lib/fact_plan) around a copy of <src> keeping only the root-hardcoded tooth.
  fe_trim(){
    mkdir -p "$2/tests"; ln -s "$HERE/../lib" "$2/lib"; ln -s "$HERE/../fact_plan.py" "$2/fact_plan.py"; ln -s "$HERE/lib" "$2/tests/lib"
    sed -e '/^\(FE_GLOBAL_ROOT=[^ ]* \)\{0,1\}tt teeth-/{/ tt teeth-root-hardcoded /!{/^tt teeth-root-hardcoded /!d;};}' "$1" > "$2/tests/fact-exec.test.sh"
    grep -q 'tt teeth-root-hardcoded ' "$2/tests/fact-exec.test.sh"
  }
  FE="$TMP/fe"
  if ! fe_trim "$HERE/fact-exec.test.sh" "$FE"; then no "fact-exec: the root-hardcoded tooth is gone from fact-exec.test.sh (trim found nothing)"
  else
    run_in_empty_tmp "$FE" "$MNT" "$MNT/tests" "$MNT/tests/fact-exec.test.sh" --prove-teeth
    judge "default-root-clean fact-exec --prove-teeth" tooth
  fi
fi

# docker-exec (#2186): same shape. Its `teeth-root-hardcoded` mutant (make_run_subdir without the root argument) allocates in the
# default root, and the 4 empty rsdd-<uuid> dirs it left were the "second source" behind the post-#2180 leftovers. A TRIMMED copy keeps
# only that tooth (and the DE_GLOBAL_ROOT redirect it needs); `tooth=1` is again the proof the allocator ran.
if [ -n "$MNT" ]; then
  if [ ! -f "$HERE/docker-exec.test.sh" ]; then no "docker-exec: suite file missing under $HERE"
  else
    # de_trim <src> <dst-tree> - build the trimmed tree (symlinked lib/ and top-level modules) around a copy of <src> keeping only the
    # root-hardcoded tooth: drop the control run and every other `tt teeth-*` line (teeth-image-local spans several lines).
    de_trim(){
      mkdir -p "$2/tests"; ln -s "$HERE/../lib" "$2/lib"; ln -s "$HERE/lib" "$2/tests/lib"
      for m in "$HERE"/../*.py; do ln -s "$m" "$2/$(basename "$m")"; done
      sed -e '/^if mutant_py_stage_control /d' -e '/^# CLI-SNAPSHOT-TOOTH-BEGIN/,/^# CLI-SNAPSHOT-TOOTH-END/d' \
          -e '/^tt teeth-image-local /,/FAIL  G-image-not-local/d' \
          -e '/^\(DE_GLOBAL_ROOT=[^ ]* \)\{0,1\}tt teeth-/{/ tt teeth-root-hardcoded /!{/^tt teeth-root-hardcoded /!d;};}' "$1" > "$2/tests/docker-exec.test.sh"
      grep -q 'tt teeth-root-hardcoded ' "$2/tests/docker-exec.test.sh"
    }
    DE="$TMP/de"
    if ! de_trim "$HERE/docker-exec.test.sh" "$DE"; then no "docker-exec: the root-hardcoded tooth is gone from docker-exec.test.sh (trim found nothing)"
    else
      run_in_empty_tmp "$DE" "$MNT" "$MNT/tests" "$MNT/tests/docker-exec.test.sh" --prove-teeth
      judge "default-root-clean docker-exec --prove-teeth" tooth
    fi
  fi
fi
fi

# RSDD_REQUIRE_UNSHARE paths, exercised with a PATH shim whose `unshare` always fails (no recursion into real runs).
mkdir -p "$TMP/noshare"
printf '#!/bin/sh\nexit 1\n' > "$TMP/noshare/unshare"; chmod +x "$TMP/noshare/unshare"
rs_out="$(PATH="$TMP/noshare:$PATH" RSDD_REQUIRE_UNSHARE='' bash "$0" 2>&1)"; rs_rc=$?
if [ "$rs_rc" -eq 0 ] && grep -qx 'SKIP: default-root leak tests.*' <<<"$rs_out"; then ok "require-unshare-off: without the opt-in a host lacking unshare -rm is a typed SKIP (exit 0)"
else no "require-unshare-off: rc=$rs_rc :: $rs_out"; fi
rs_out="$(PATH="$TMP/noshare:$PATH" RSDD_REQUIRE_UNSHARE=1 bash "$0" 2>&1)"; rs_rc=$?
if [ "$rs_rc" -eq 1 ] && grep -qF 'RSDD_REQUIRE_UNSHARE=1' <<<"$rs_out" && ! grep -q '^SKIP:' <<<"$rs_out"; then ok "require-unshare-on: RSDD_REQUIRE_UNSHARE=1 turns the missing-unshare SKIP into a typed FAIL (exit 1)"
else no "require-unshare-on: rc=$rs_rc :: $rs_out"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # Mount point for the fixture/mutant trees: they live under the real /tmp, which the empty tmpfs hides.

  # The "-- teeth:" banners are printed ONLY where a mutant really runs: run-all --require-teeth counts banners
  # as teeth. Skips use the indented per-test form so a suite whose real cases passed is not classed as SKIPPED.
  if [ -z "$MNT" ]; then
    printf '  SKIP  %s\n' "fixture + capture-analyze + docker-exec teeth (no /mnt, /media, /srv or /opt mount point for the work tree)"
  else
    echo "-- teeth: a fixture suite that leaves a run dir in the default root must be flagged --"
    mkdir -p "$TMP/fix"
    { printf '#!/usr/bin/env bash\n'
      printf 'mkdir -p /tmp/rsdd && mkdir /tmp/rsdd/rsdd-leaked-run\n'
      printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
    } > "$TMP/fix/leaky.test.sh"
    run_in_empty_tmp "$TMP/fix" "$MNT" "$MNT" "$MNT/leaky.test.sh"
    case "$RESULT" in *"ran=1 tooth=0 entries=1") ok "teeth-leak-detect: a leaking fixture reads entries=1 → the empty-/tmp measurement sees a default-root leak" ;;
      *) no "teeth-leak-detect: the leaking fixture was NOT flagged ($RESULT) — the harness cannot see a leak (THEATER)" ;; esac

    echo "-- teeth: a suite that never prints its summary must not read as clean --"
    { printf '#!/usr/bin/env bash\nexit 0\n'; } > "$TMP/fix/silent.test.sh"
    run_in_empty_tmp "$TMP/fix" "$MNT" "$MNT" "$MNT/silent.test.sh"
    RESULT_BEFORE="$fail"; judge "silent-fixture" >/dev/null
    if [ "$fail" -gt "$RESULT_BEFORE" ]; then fail=$((fail-1)); ok "teeth-silent-zero: a suite with no summary line is rejected, not counted as clean"
    else no "teeth-silent-zero: a silent suite was accepted as clean (THEATER)"; fi

    echo "-- teeth: capture-analyze pointed back at the global /tmp/rsdd (its pre-#2164 state) must be flagged --"
    T="$TMP/mut"; mkdir -p "$T/tests"
    ln -s "$HERE/../lib" "$T/lib"; ln -s "$HERE/../capture_plan.py" "$T/capture_plan.py"
    if ! mutant_sed "$HERE/capture-analyze.test.sh" "$T/tests/capture-analyze.test.sh" \
         's|^os.environ\["RSDD_VM_ROOT"\] = os.path.join(_SBX, "rsdd")$|os.environ["RSDD_VM_ROOT"] = "/tmp/rsdd"|' 2>"$TMP/mutant.err"; then
      no "teeth-capture-analyze-global: could not build a valid mutant: $(cat "$TMP/mutant.err")"
    else
      run_in_empty_tmp "$T" "$MNT" "$MNT/tests" "$MNT/tests/capture-analyze.test.sh"
      case "$RESULT" in *"ran=1"*"entries=0") no "teeth-capture-analyze-global: the mutant left nothing — mutation not exercised ($RESULT) (THEATER)" ;;
        *"ran=1 "*"entries="*) ok "teeth-capture-analyze-global: the pre-fix suite leaves entries in /tmp/rsdd → the regression test has real teeth ($RESULT)" ;;
        *) no "teeth-capture-analyze-global: the mutant did not run to a summary ($RESULT)" ;; esac
    fi
  fi

  if [ -n "$MNT" ] && [ -f "$HERE/fact-exec.test.sh" ]; then
    echo "-- teeth: fact-exec with the FE_GLOBAL_ROOT redirect removed (its pre-#2171 state) must be flagged --"
    if ! mutant_sed "$HERE/fact-exec.test.sh" "$TMP/fe-mutant.sh" 's|^FE_GLOBAL_ROOT="\$MUT/global-root" tt teeth-root-hardcoded|tt teeth-root-hardcoded|' 2>"$TMP/mutant.err" \
       || ! fe_trim "$TMP/fe-mutant.sh" "$TMP/fe2"; then
      no "teeth-fact-exec-global: could not build a valid mutant: $(cat "$TMP/mutant.err")"
    else
      run_in_empty_tmp "$TMP/fe2" "$MNT" "$MNT/tests" "$MNT/tests/fact-exec.test.sh" --prove-teeth
      case "$RESULT" in *"tooth=1 entries=0") no "teeth-fact-exec-global: the mutant left nothing - mutation not exercised ($RESULT) (THEATER)" ;;
        *"ran=1 tooth=1 entries="*) ok "teeth-fact-exec-global: without the redirect the teeth run leaves entries in /tmp/rsdd -> the regression test has real teeth ($RESULT)" ;;
        *) no "teeth-fact-exec-global: the mutant did not run to a proven summary ($RESULT)" ;; esac
    fi
  fi

  if [ -n "$MNT" ] && [ -f "$HERE/docker-exec.test.sh" ]; then
    echo "-- teeth: docker-exec with the DE_GLOBAL_ROOT redirect AND the NOLEAK cleanup removed (its pre-#2186 state, where the guard never saw the CLI child's dirs) must be flagged --"
    if ! mutant_sed "$HERE/docker-exec.test.sh" "$TMP/de-mutant.sh" 's|^DE_GLOBAL_ROOT="\$MUT/global-root" tt teeth-root-hardcoded|tt teeth-root-hardcoded|;s|^        shutil.rmtree(_p, ignore_errors=True)$|        pass|' 2>"$TMP/mutant.err" \
       || ! de_trim "$TMP/de-mutant.sh" "$TMP/de2"; then
      no "teeth-docker-exec-global: could not build a valid mutant: $(cat "$TMP/mutant.err")"
    else
      run_in_empty_tmp "$TMP/de2" "$MNT" "$MNT/tests" "$MNT/tests/docker-exec.test.sh" --prove-teeth
      case "$RESULT" in *"tooth=1 entries=0") no "teeth-docker-exec-global: the mutant left nothing - mutation not exercised ($RESULT) (THEATER)" ;;
        *"ran=1 tooth=1 entries="*) ok "teeth-docker-exec-global: without the redirect the teeth run leaves entries in /tmp/rsdd -> the regression test has real teeth ($RESULT)" ;;
        *) no "teeth-docker-exec-global: the mutant did not run to a proven summary ($RESULT)" ;; esac
    fi
  fi

  echo "-- teeth: drop the RSDD_REQUIRE_UNSHARE branch; the opt-in must then NOT fail (case require-unshare-on) --"
  if ! mutant_sed "$HERE/run-all-default-root.test.sh" "$TMP/ru-mutant.sh" 's/\[ "\${RSDD_REQUIRE_UNSHARE:-}" = 1 \]/false/' 2>"$TMP/mutant.err"; then
    no "teeth-require-unshare: could not build a valid mutant: $(cat "$TMP/mutant.err")"
  else
    PATH="$TMP/noshare:$PATH" RSDD_REQUIRE_UNSHARE=1 bash "$TMP/ru-mutant.sh" >/dev/null 2>&1; ru_rc=$?
    if [ "$ru_rc" -eq 0 ]; then ok "teeth-require-unshare: opt-in-less mutant still SKIPs (exit 0) → the typed FAIL has real teeth"
    else no "teeth-require-unshare: mutant still fails (rc=$ru_rc) — mutation not exercised (THEATER)"; fi
  fi
fi

echo "== $pass passed $MID $fail failed =="
[ "$fail" -eq 0 ] || exit 1
