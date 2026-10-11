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

# Only capture-analyze: it is the suite with PROOF that the allocator runs against the default root (its pre-fix
# state leaves a run dir; see the mutant tooth below). The other run-dir suites (capture-exec, docker-exec, fact-exec,
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
# argv: <bind-src|-> <bind-dst|-> <cwd> <suite-path>
cat > "$TMP/inner.sh" <<'INNER'
#!/usr/bin/env bash
src="$1"; dst="$2"; cwd="$3"; suite="$4"
if [ "$src" != "-" ]; then mount --bind "$src" "$dst" || { echo "result bind-failed"; exit 0; }; fi
mount -t tmpfs tmpfs /tmp || { echo "result mount-failed"; exit 0; }
mkdir /tmp/work && export TMPDIR=/tmp/work
cd "$cwd" || { echo "result cd-failed"; exit 0; }
timeout 900 bash "$suite" > /tmp/out.log 2>&1
rc=$?
ran=0; grep -qE '^== [0-9]+ passed' /tmp/out.log && ran=1
if [ -e /tmp/rsdd ]; then
  # find's own rc is the scan verdict; a failed scan must never read as "0 entries".
  if ! listing="$(find /tmp/rsdd -mindepth 1 -maxdepth 1 2>/dev/null)"; then echo "result scan-failed"; exit 0; fi
  if [ -n "$listing" ]; then n=$(printf '%s\n' "$listing" | wc -l); else n=0; fi
else n=0; fi
echo "result rc=$rc ran=$ran entries=$n"
INNER

# run_in_empty_tmp <bind-src|-> <bind-dst|-> <cwd> <suite-path> — sets RESULT to the inner "result ..." line.
run_in_empty_tmp(){
  RESULT="$(unshare -rm bash "$TMP/inner.sh" "$1" "$2" "$3" "$4" 2>&1 | grep '^result ' | tail -1)"
}
# judge <label> — OK only when the suite RAN and left no entries in the default root.
judge(){
  case "$RESULT" in
    "") no "$1: no result from the namespace runner (silent zero)"; return 1 ;;
    "result bind-failed"|"result mount-failed"|"result cd-failed"|"result scan-failed") no "$1: harness error: $RESULT"; return 1 ;;
  esac
  case "$RESULT" in *"ran=1"*) ;; *) no "$1: the suite never printed its summary line ($RESULT) — nothing was proven"; return 1 ;; esac
  case "$RESULT" in *"entries=0") ok "$1: left no entries in the default rsdd root ($RESULT)"; return 0 ;; esac
  no "$1: LEFT entries in the default rsdd root ($RESULT)"; return 1
}

for s in "${SUITES[@]}"; do
  [ -f "$HERE/$s.test.sh" ] || { no "$s: suite file missing under $HERE"; continue; }
  run_in_empty_tmp - - "$HERE" "$HERE/$s.test.sh"
  judge "default-root-clean $s"
done

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
  MNT=""; for d in /mnt /media /srv /opt; do [ -d "$d" ] && { MNT="$d"; break; }; done

  # The "-- teeth:" banners are printed ONLY where a mutant really runs: run-all --require-teeth counts banners
  # as teeth. Skips use the indented per-test form so a suite whose real cases passed is not classed as SKIPPED.
  if [ -z "$MNT" ]; then
    printf '  SKIP  %s\n' "fixture + capture-analyze teeth (no /mnt, /media, /srv or /opt mount point for the work tree)"
  else
    echo "-- teeth: a fixture suite that leaves a run dir in the default root must be flagged --"
    mkdir -p "$TMP/fix"
    { printf '#!/usr/bin/env bash\n'
      printf 'mkdir -p /tmp/rsdd && mkdir /tmp/rsdd/rsdd-leaked-run\n'
      printf 'echo "== 1 passed %s 0 failed =="\n' "$MID"
    } > "$TMP/fix/leaky.test.sh"
    run_in_empty_tmp "$TMP/fix" "$MNT" "$MNT" "$MNT/leaky.test.sh"
    case "$RESULT" in *"ran=1 entries=1") ok "teeth-leak-detect: a leaking fixture reads entries=1 → the empty-/tmp measurement sees a default-root leak" ;;
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
        *"ran=1 entries="*) ok "teeth-capture-analyze-global: the pre-fix suite leaves entries in /tmp/rsdd → the regression test has real teeth ($RESULT)" ;;
        *) no "teeth-capture-analyze-global: the mutant did not run to a summary ($RESULT)" ;; esac
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
