#!/usr/bin/env bash
# java-fidelity-experiment.test.sh — black-box contract for the java-fidelity-experiment.sh SHIM (kit issue #1488; port #2419).
#
# The experiment is the Go command `rsdd corroborate java-fidelity` (research-sdd/rsdd/internal/corroborate/fidelity).
# Its decisions (verdicts, normalisation, cell classification, LocalVariableTable detection, timeout and typed
# reason mapping, report bytes) and the mutation controls that used to be twelve sed mutants of this script live in
# the Go tests (table at the head of fidelity_test.go), driven by a fake javac/javap/decompiler: no JVM, no sleeps.
# What stays here is what only the shim can show: argument pass-through, the --toolbelt wiring (default fixtures and
# decompile-java.sh resolved beside the shim), the typed degraded state when rsdd is missing, and ONE end-to-end stub
# run through the real binary. The stub javac/javap/decompiler are shell scripts, so the fast lane needs no JDK.
#
# Lanes (tests/lib/test-lane.sh): fast (default) = stubs only; slow = adds the real run (real javac, javap and the kit
# decompiler, counted only when the toolchain is usable, else a printed SKIP); all = both.
#
# TEETH: none here. The mutation controls are Go tests (internal/corroborate/fidelity), not mutants of this script.
#
# Usage: java-fidelity-experiment.test.sh [--prove-teeth]     Exit: 0 = all pass · 1 = regression · 2 = harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../java-fidelity-experiment.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
# shellcheck source=lib/test-lane.sh
. "$HERE/lib/test-lane.sh"
LANE="$(rsdd_lane)" || exit 2

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-66s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-66s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== java-fidelity-experiment.test.sh (lane: $LANE) =="

# A kit-shaped copy: the shim resolves rsdd from <toolbelt>/../rsdd (lib/rsdd-exec.sh), so the copy sits in a dir whose
# rsdd/ links to the real module and any rebuild (RSDD_BIN unset, as in CI) lands in $ROOT/kit/bin, never in the kit.
mkdir -p "$ROOT/kit" && ln -s "$(CDPATH='' cd -P -- "$HERE/../../rsdd" && pwd -P)" "$ROOT/kit/rsdd" \
  || { echo "FATAL: could not link the rsdd module" >&2; exit 2; }
TB="$ROOT/kit/toolbelt"; mkdir -p "$TB/lib"
cp "$SUT" "$TB/" && cp "$HERE/../lib/rsdd-exec.sh" "$TB/lib/" || { echo "FATAL: could not stage the shim" >&2; exit 2; }   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh
SHIM="$TB/java-fidelity-experiment.sh"

# ---- stub tools: shell scripts that behave like the JDK for these tiny fixtures ----------------------------------
STUB="$ROOT/stub"; mkdir -p "$STUB"
cat > "$STUB/javac" <<'S'
#!/usr/bin/env bash
if [ "$1" = -version ]; then echo "javac 21.0.1"; exit 0; fi
lvt=no; while [ "$1" != -d ]; do [ "$1" = -g ] && lvt=yes; shift; done
out="$2"; src="$3"; base="$(basename "$src" .java)"; body="$(cat "$src")"
case "$body" in *SYNTAX*) echo "error: illegal start" >&2; exit 1 ;; esac
printf 'src:%s\nlvt:%s\n' "$body" "$lvt" > "$out/$base.class"
S
cat > "$STUB/javap" <<'S'
#!/usr/bin/env bash
flag="$1"; cls="${*: -1}"; name="$(basename "$cls" .class)"; text="$(cat "$cls")" || exit 2
if [ "$flag" = -l ]; then echo "class $name"; case "$text" in *lvt:yes*) echo "      LocalVariableTable:" ;; esac; exit 0; fi
src="${text#src:}"; src="${src%%$'\n'*}"
printf 'Compiled from "%s.java"\nclass %s {\n  0: ldc #%d, 3 // %s\n}\n' "$name" "$name" "$(( ${#cls} % 50 + 1 ))" "$src"
S
cat > "$STUB/decompiler.sh" <<'S'
#!/usr/bin/env bash
in="$1"; out="$2"; name="$(basename "$in" .class)"; mkdir -p "$out"
text="$(cat "$in")"; src="${text#src:}"; src="${src%%$'\n'*}"
case "$name" in
  Gone) echo "boom" >&2; exit 1 ;;
  Diff) printf '%s\n' "${src/+ 1/+ 2}" > "$out/$name.java" ;;
  *)    printf '%s\n' "$src" > "$out/$name.java" ;;
esac
echo "OK: $in -> $out (engine=stub)"
S
chmod +x "$STUB"/*
FIX="$ROOT/fixtures"; mkdir -p "$FIX"
printf 'public class Same { public static int f(int a) { return a + 1; } }\n' > "$FIX/Same.java"
printf 'public class Diff { public static int f(int a) { return a + 1; } }\n' > "$FIX/Diff.java"
printf 'public class Gone { public static int f(int a) { return a; } }\n' > "$FIX/Gone.java"

run() { # run ARGV... ; sets OUT, ERR, RC (the stub toolchain is on every run unless the case overrides it)
  local e="$ROOT/err"
  OUT="$(RSDD_FIDELITY_JAVAC="$STUB/javac" RSDD_FIDELITY_JAVAP="$STUB/javap" RSDD_FIDELITY_DECOMPILER="$STUB/decompiler.sh" "$@" 2>"$e")"; RC=$?
  ERR="$(cat "$e")"
}
has()  { grep -qE -- "$1" <<<"$OUT"; }
hasE() { grep -qE -- "$1" <<<"$ERR"; }

# ---- shim shape ---------------------------------------------------------------------------------------------------
grep -q '^rsdd_exec corroborate java-fidelity ' "$SUT" && ! grep -q 'javac' "$SUT" \
  && ok "1 the script is a shim for rsdd corroborate java-fidelity (no javac logic left)" || no "1 shim shape"

# ---- one end-to-end stub run through the shim ---------------------------------------------------------------------
run bash "$SHIM" --fixtures "$FIX" --work "$ROOT/w1"
want="FIDELITY Diff mode=g verdict=DIVERGED
FIDELITY Diff mode=nog verdict=DIVERGED
DEBUGINFO Diff g_lvt=yes nog_lvt=no
FIDELITY Gone mode=g verdict=FAILED reason=decompile
FIDELITY Gone mode=nog verdict=FAILED reason=decompile
DEBUGINFO Gone g_lvt=yes nog_lvt=no
FIDELITY Same mode=g verdict=GOOD
FIDELITY Same mode=nog verdict=GOOD
DEBUGINFO Same g_lvt=yes nog_lvt=no
RESULT: DONE jdk=21.0.1 engines=stub engine_degraded_cells=0 constructs=3 cells=6 good=2 diverged=2 failed=2"
[ "$RC" = 0 ] && [ -z "$ERR" ] && [ "$OUT" = "$want" ] \
  && ok "2 stub run through the shim: exact report, rc 0, empty stderr" || no "2 stub run" "rc=$RC err=$ERR out=$OUT"
[ -f "$ROOT/w1/Same/g/dec.log" ] && [ -f "$ROOT/w1/Same/nog/orig.javap" ] \
  && ok "3 --work is honoured: per-cell logs are written under it" || no "3 work dir" "$(find "$ROOT/w1" -type f | head -5)"

# ---- the shim hands the Go command its own directory (--toolbelt): default fixtures and decompile-java.sh --------
mkdir -p "$TB/tests/fixtures/java-fidelity-experiment"
cp "$FIX/Same.java" "$TB/tests/fixtures/java-fidelity-experiment/"
cp "$STUB/decompiler.sh" "$TB/decompile-java.sh"
OUT="$(env -u RSDD_FIDELITY_DECOMPILER RSDD_FIDELITY_JAVAC="$STUB/javac" RSDD_FIDELITY_JAVAP="$STUB/javap" bash "$SHIM" --work "$ROOT/w2" 2>"$ROOT/err")"; RC=$?; ERR="$(cat "$ROOT/err")"
{ [ "$RC" = 0 ] && has '^FIDELITY Same mode=g verdict=GOOD$' && has 'constructs=1 cells=2 good=2 '; } \
  && ok "4 no --fixtures and no decompiler env: both default to the shim's own toolbelt" || no "4 toolbelt defaults" "rc=$RC err=$ERR out=$OUT"

# ---- typed degraded / usage pass through with the legacy exit codes --------------------------------------------------
run env RSDD_FIDELITY_JAVAC=/nonexistent/javac bash "$SHIM" --fixtures "$FIX" --work "$ROOT/w3"
{ [ "$RC" = 4 ] && has '^DEGRADED: reason=javac-missing' && ! has 'verdict=' && ! has '^RESULT: DONE'; } \
  && ok "5 javac absent -> typed DEGRADED, rc 4, no verdict, never DONE" || no "5 degraded" "rc=$RC $OUT"
run bash "$SHIM" --fixtures "$ROOT/absent" --work "$ROOT/w4"
{ [ "$RC" = 2 ] && hasE 'fixtures directory not found'; } && ok "6 absent fixtures dir -> rc 2" || no "6 absent" "rc=$RC $ERR"
mkdir -p "$ROOT/emptyfix"
run bash "$SHIM" --fixtures "$ROOT/emptyfix" --work "$ROOT/w5"
{ [ "$RC" = 1 ] && hasE 'no fixtures'; } && ok "7 empty fixtures dir -> rc 1 (distinct from absent)" || no "7 empty" "rc=$RC $ERR"
run env RSDD_FIDELITY_TIMEOUT=abc bash "$SHIM" --fixtures "$FIX" --work "$ROOT/w6"
{ [ "$RC" = 2 ] && hasE 'RSDD_FIDELITY_TIMEOUT'; } && ok "8 invalid RSDD_FIDELITY_TIMEOUT -> rc 2" || no "8 timeout" "rc=$RC $ERR"
run bash "$SHIM" --bogus
{ [ "$RC" = 2 ] && hasE '^usage: java-fidelity-experiment.sh'; } && ok "9 unknown flag -> rc 2 with the legacy usage line" || no "9 usage" "rc=$RC $ERR"
run bash "$SHIM" --help
{ [ "$RC" = 0 ] && has 'Limits \(stated' && has '^# +java-fidelity-experiment.sh'; } && ok "10 --help prints the whole header block" || no "10 help" "rc=$RC"
run env RSDD_BIN=/nonexistent/rsdd bash "$SHIM" --fixtures "$FIX"
{ [ "$RC" = 2 ] && hasE '^degraded: rsdd-unavailable'; } && ok "11 no rsdd binary -> typed degraded: rsdd-unavailable, never a silent pass" || no "11 rsdd missing" "rc=$RC $ERR"

# ---- one real run (slow lane only; counted only when the real toolchain is usable) ----------------------------------
if [ "$LANE" = fast ]; then
  echo "  SKIP  real run: fast lane (RSDD_TEST_LANE=slow runs it) — not counted"
elif ! command -v javac >/dev/null 2>&1 || ! command -v javap >/dev/null 2>&1; then
  echo "  SKIP  real run: javac/javap not on PATH — not counted"
else
  REALFIX="$HERE/fixtures/java-fidelity-experiment"
  n_fix="$(find "$REALFIX" -maxdepth 1 -name '*.java' | wc -l)"
  OUT="$(env -u RSDD_FIDELITY_TIMEOUT RSDD_FIDELITY_DECOMPILER="$HERE/../decompile-java.sh" bash "$SHIM" --fixtures "$REALFIX" --work "$ROOT/wreal" 2>&1)"; RC=$?
  if [ "$RC" = 0 ]; then
    cells="$(printf '%s\n' "$OUT" | grep -c '^FIDELITY ')"
    [ "$cells" = $((n_fix * 2)) ] && ok "12 real run measured every fixture in both modes" "($cells cells)" || no "12 real cells" "cells=$cells fixtures=$n_fix"
    has '^RESULT: DONE jdk=[0-9][^ ]* engines=[a-z]' && has ' good=[1-9][0-9]* ' \
      && ok "13 real run: at least one GOOD cell and provenance recorded" \
      || no "13 real run all-failed or no provenance" "$(grep -E '^RESULT' <<<"$OUT")"
  elif [ "$RC" = 4 ]; then
    echo "  SKIP  real run: toolchain degraded ($(printf '%s\n' "$OUT" | grep '^DEGRADED' | head -1)) — not counted"
  else
    no "12 real run" "rc=$RC"
  fi
fi

# --prove-teeth: the experiment is the Go command `rsdd corroborate java-fidelity` (kit issue #2419); its mutation
# controls live in research-sdd/rsdd/internal/corroborate/fidelity (table at the head of fidelity_test.go), so this
# suite runs the shim black-box only.

echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
