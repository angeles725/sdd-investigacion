#!/usr/bin/env bash
# java-fidelity-experiment.test.sh — contract for java-fidelity-experiment.sh (kit issue #1488).
#
# The experiment compiles tiny Java fixtures, decompiles them, recompiles the decompiled output and
# compares javap bytecode. These tests use a STUB decompiler (RSDD_FIDELITY_DECOMPILER) so the
# GOOD / DIVERGED / FAILED verdicts are deterministic, plus ONE real run that is counted only when
# javac, javap and the kit decompiler are all usable (a skip is printed, never counted as a pass).
# Needs a real javac/javap for the verdict cases; without them the suite exits 2 (harness error),
# never a silent green.
#
# Usage: java-fidelity-experiment.test.sh [--prove-teeth]
# Exit:  0 = all pass · 1 = regression · 2 = harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../java-fidelity-experiment.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
command -v javac >/dev/null 2>&1 && command -v javap >/dev/null 2>&1 \
  || { echo "FATAL: javac/javap not on PATH; verdict cases cannot run" >&2; exit 2; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-66s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-66s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== java-fidelity-experiment.test.sh =="

# ---- stub decompiler -------------------------------------------------------------------------------
# Behaviour per class name comes from $STUB_DIR/<Class>.mode (copy|diverge|broken|fail|none|missing|hang).
STUB_DIR="$ROOT/stub"; mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/decompiler.sh" <<'STUB'
#!/usr/bin/env bash
in="$1"; out="$2"; name="$(basename "$in" .class)"
mode="$(cat "$STUB_DIR/$name.mode" 2>/dev/null || echo copy)"
mkdir -p "$out"
case "$mode" in
  copy)     cp "$STUB_DIR/$name.good" "$out/$name.java"; echo "OK: $in -> $out (engine=stub)" ;;
  diverge)  cp "$STUB_DIR/$name.alt" "$out/$name.java"; echo "OK: $in -> $out (engine=stub)" ;;
  broken)   printf 'class %s { this is not java }\n' "$name" > "$out/$name.java"; echo "OK: $in -> $out (engine=stub)" ;;
  fail)     echo "boom" >&2; exit 1 ;;
  none)     echo "OK: $in -> $out (engine=stub)" ;;
  missing)  echo "no engine" >&2; exit 3 ;;
  hang)     exec sleep 30 ;;
esac
STUB
chmod +x "$STUB_DIR/decompiler.sh"
export STUB_DIR
export RSDD_FIDELITY_TIMEOUT=2

FIX="$ROOT/fixtures"; mkdir -p "$FIX"
printf 'public class Same { public static int f(int a) { return a + 1; } }\n' > "$FIX/Same.java"
cp "$FIX/Same.java" "$STUB_DIR/Same.good"
printf 'public class Diff { public static int f(int a) { return a + 1; } }\n' > "$FIX/Diff.java"
printf 'public class Diff { public static int f(int a) { return a + 2; } }\n' > "$STUB_DIR/Diff.alt"
echo diverge > "$STUB_DIR/Diff.mode"
printf 'public class Broken { public static int f(int a) { return a; } }\n' > "$FIX/Broken.java"
echo broken > "$STUB_DIR/Broken.mode"
printf 'public class Gone { public static int f(int a) { return a; } }\n' > "$FIX/Gone.java"
echo fail > "$STUB_DIR/Gone.mode"
printf 'public class Empty { public static int f(int a) { return a; } }\n' > "$FIX/Empty.java"
echo none > "$STUB_DIR/Empty.mode"
printf 'public class Multi { static class In {} public static int f(int a) { return a; } }\n' > "$FIX/Multi.java"
printf 'public class Hang { public static int f(int a) { return a; } }\n' > "$FIX/Hang.java"
echo hang > "$STUB_DIR/Hang.mode"
printf 'public class Nocompile { int f( { }\n' > "$FIX/Nocompile.java"
printf 'public class Dbg { public static int f(int a) { int b = a + 1; return b; } }\n' > "$FIX/Dbg.java"
cp "$FIX/Dbg.java" "$STUB_DIR/Dbg.good"

run() { # run SUT ARGV... ; sets OUT, RC
  OUT="$(RSDD_FIDELITY_DECOMPILER="$STUB_DIR/decompiler.sh" "$@" 2>&1)"; RC=$?
}
has()  { grep -qE -- "$1" <<<"$OUT"; }

# ---- verdict cases --------------------------------------------------------------------------------
run bash "$SUT" --fixtures "$FIX" --work "$ROOT/w1"
[ "$RC" = 0 ] && ok "1 full run exits 0 (experiment reports, findings are not failures)" || no "1 exit" "rc=$RC"
has '^FIDELITY Same mode=g verdict=GOOD$'            && ok "2 identical bytecode -> GOOD (-g)"  || no "2 GOOD g" "$OUT"
has '^FIDELITY Same mode=nog verdict=GOOD$'          && ok "3 identical bytecode -> GOOD (no -g)" || no "3 GOOD nog" "$OUT"
has '^FIDELITY Diff mode=g verdict=DIVERGED$'        && ok "4 recompiles but bytecode differs -> DIVERGED" || no "4 DIVERGED" "$OUT"
has '^FIDELITY Broken mode=g verdict=FAILED reason=recompile$' && ok "5 recompile error -> FAILED reason=recompile" || no "5 recompile" "$OUT"
has '^FIDELITY Gone mode=g verdict=FAILED reason=decompile$'   && ok "6 decompiler non-zero -> FAILED reason=decompile" || no "6 decompile" "$OUT"
has '^FIDELITY Empty mode=g verdict=FAILED reason=no-output$'  && ok "7 decompiler rc 0 with no .java -> FAILED reason=no-output (not GOOD)" || no "7 no-output" "$OUT"
has '^FIDELITY Multi mode=g verdict=FAILED reason=multi-class$' && ok "8 multi-class fixture -> FAILED reason=multi-class" || no "8 multi-class" "$OUT"
has '^FIDELITY Hang mode=g verdict=FAILED reason=timeout$' && ok "9b decompiler exceeding the bound -> FAILED reason=timeout" || no "9b timeout" "$OUT"
has '^FIDELITY Nocompile mode=g verdict=FAILED reason=compile$' && ok "9c fixture that does not compile -> FAILED reason=compile" || no "9c compile" "$OUT"
has '^DEBUGINFO Nocompile g_lvt=unmeasured nog_lvt=unmeasured$' && ok "9d unmeasurable DEBUGINFO is 'unmeasured', never 'no'" || no "9d unmeasured" "$OUT"
has '^RESULT: DONE jdk=[0-9][0-9.]* engines=stub engine_degraded_cells=0 ' && ok "9e RESULT records jdk version and the engine the wrapper reported" || no "9e provenance" "$(grep RESULT <<<"$OUT")"
has '^DEBUGINFO Dbg g_lvt=yes nog_lvt=no$'           && ok "9 -g keeps LocalVariableTable, no -g drops it (DEBUGINFO)" || no "9 debuginfo" "$OUT"
has '^RESULT: DONE .*constructs=9 cells=18 good=([0-9]+) diverged=([0-9]+) failed=([0-9]+)'  && ok "10 summary counts the cells it measured" || no "10 summary" "$OUT"
has 'constructs=9 cells=18 good=4 diverged=2 failed=12$' && ok "11 summary tallies GOOD/DIVERGED/FAILED exactly" || no "11 tally" "$(printf '%s\n' "$OUT" | grep RESULT)"

# ---- typed degraded / usage ------------------------------------------------------------------------
run env RSDD_FIDELITY_JAVAC=/nonexistent/javac bash "$SUT" --fixtures "$FIX" --work "$ROOT/w2"
{ [ "$RC" = 4 ] && has '^DEGRADED: .*reason=javac-missing' && ! has 'verdict=GOOD' && ! has '^RESULT: DONE'; } \
  && ok "12 javac absent -> typed DEGRADED rc 4, no verdict, never DONE" || no "12 javac degraded" "rc=$RC $OUT"
run env RSDD_FIDELITY_JAVAP=/nonexistent/javap bash "$SUT" --fixtures "$FIX" --work "$ROOT/w3"
{ [ "$RC" = 4 ] && has 'reason=javap-missing'; } && ok "13 javap absent -> DEGRADED reason=javap-missing" || no "13 javap degraded" "rc=$RC $OUT"
# javac genuinely absent from PATH (not an override): a PATH of symlinks to everything but the JDK.
BIN="$ROOT/bin"; mkdir -p "$BIN"
for t in bash sed mkdir rm cat find sort diff mktemp dirname basename grep wc tr cp mv cut head tail date uname env ls printf; do
  p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && ln -sf "$p" "$BIN/$t"
done
OUT="$(PATH="$BIN" RSDD_FIDELITY_DECOMPILER="$STUB_DIR/decompiler.sh" "$BIN/bash" "$SUT" --fixtures "$FIX" --work "$ROOT/w4" 2>&1)"; RC=$?
{ [ "$RC" = 4 ] && has 'reason=javac-missing'; } && ok "14 javac not on PATH -> DEGRADED rc 4" || no "14 PATH degraded" "rc=$RC $OUT"
echo missing > "$STUB_DIR/Same.mode"
run bash "$SUT" --fixtures "$FIX" --work "$ROOT/w5"
{ [ "$RC" = 4 ] && has 'reason=decompiler-missing' && has 'partial_cells=[1-9]' && ! has '^RESULT: DONE'; } \
  && ok "15 decompiler rc 3 mid-run -> DEGRADED, partial_cells named, never DONE" || no "15 decompiler degraded" "rc=$RC $OUT"
echo copy > "$STUB_DIR/Same.mode"
run bash "$SUT" --fixtures "$ROOT/absent" --work "$ROOT/w6"
[ "$RC" = 2 ] && ok "16 absent fixtures dir -> rc 2" || no "16 absent" "rc=$RC"
mkdir -p "$ROOT/emptyfix"
run bash "$SUT" --fixtures "$ROOT/emptyfix" --work "$ROOT/w7"
{ [ "$RC" = 1 ] && has 'no fixtures'; } && ok "17 empty fixtures dir -> rc 1 (distinct from absent)" || no "17 empty" "rc=$RC $OUT"
run bash "$SUT" --help
{ [ "$RC" = 0 ] && has 'Limits \(stated' && has '^# +java-fidelity-experiment.sh'; } && ok "18b --help prints the whole header block" || no "18b help" "rc=$RC"
run bash "$SUT" --bogus
[ "$RC" = 2 ] && ok "18 unknown flag -> rc 2" || no "18 usage" "rc=$RC"

# ---- one real run (counted only when the real toolchain is usable) ----------------------------------
REALFIX="$HERE/fixtures/java-fidelity-experiment"
n_fix="$(find "$REALFIX" -maxdepth 1 -name '*.java' | wc -l)"
OUT="$(bash "$SUT" --fixtures "$REALFIX" --work "$ROOT/wreal" 2>&1)"; RC=$?
if [ "$RC" = 0 ]; then
  cells="$(printf '%s\n' "$OUT" | grep -c '^FIDELITY ')"
  [ "$cells" = $((n_fix * 2)) ] && ok "19 real run measured every fixture in both modes" "($cells cells)" || no "19 real cells" "cells=$cells fixtures=$n_fix"
  has '^FIDELITY EnhancedFor mode=g verdict=GOOD$' && has '^RESULT: DONE jdk=[0-9][0-9.]* engines=[a-z]' \
    && ok "19b real run: known-good fixture is GOOD and provenance recorded (an all-FAILED run is not a pass)" \
    || no "19b real run all-failed or no provenance" "$(grep -E '^RESULT' <<<"$OUT")"
elif [ "$RC" = 4 ]; then
  echo "  SKIP  19 real run: toolchain degraded ($(printf '%s\n' "$OUT" | grep '^DEGRADED' | head -1)) — not counted"
else
  no "19 real run" "rc=$RC"
fi

# ---- teeth ---------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
    || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth" >&2; exit 2; }
  MUT="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$MUT"' EXIT
  mk() { mkdir -p "$(dirname "$2")"; mutant_chain "$1" "$SUT" "$2" "${@:3}" || { fail=$((fail+1)); return 1; }; }
  tt() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  export RSDD_FIDELITY_DECOMPILER="$STUB_DIR/decompiler.sh"

  echo "-- teeth A: bytecode comparison always equal -> DIVERGED cell reported GOOD --"
  mk "teeth A" "$MUT/A.sh" 's/\[ "\$orig_norm" = "\$new_norm" \]  # SENTINEL-COMPARE/true  # SENTINEL-COMPARE/' \
    && tt "teeth A: neutered compare turns the DIVERGED fixture GOOD" 0 0 "$MUT/A.sh" \
         --good-has 'Diff mode=g verdict=DIVERGED' --bad-lacks 'Diff mode=g verdict=DIVERGED' \
         --bad-has 'Diff mode=g verdict=GOOD' -- bash @SUT@ --fixtures "$FIX" --work "$MUT/wA"

  echo "-- teeth B: recompile status ignored -> uncompilable output reported GOOD/DIVERGED --"
  mk "teeth B" "$MUT/B.sh" 's/if ! "\$JAVAC" \$flags -d "\$re" "\$jf" >"\$log" 2>&1; then  # SENTINEL-RECOMPILE-RC/if false; then  # SENTINEL-RECOMPILE-RC/' \
    && tt "teeth B: ignored recompile failure no longer yields FAILED" 0 0 "$MUT/B.sh" \
         --good-has 'Broken mode=g verdict=FAILED reason=recompile$' \
         --bad-lacks 'Broken mode=g verdict=FAILED reason=recompile$' -- bash @SUT@ --fixtures "$FIX" --work "$MUT/wB"

  echo "-- teeth C: empty decompiler output no longer detected -> silent zero --"
  mk "teeth C" "$MUT/C.sh" 's/\[ "\$n_java" -eq 0 \]  # SENTINEL-NO-OUTPUT/false  # SENTINEL-NO-OUTPUT/' \
    && tt "teeth C: no-output guard removed, Empty fixture loses reason=no-output" 0 0 "$MUT/C.sh" \
         --good-has 'Empty mode=g verdict=FAILED reason=no-output' \
         --bad-lacks 'Empty mode=g verdict=FAILED reason=no-output' -- bash @SUT@ --fixtures "$FIX" --work "$MUT/wC"

  echo "-- teeth D: javac probe disabled -> missing javac no longer DEGRADED --"
  mk "teeth D" "$MUT/D.sh" 's/\[ -x "\$JAVAC_BIN" \]  # SENTINEL-JAVAC-PROBE/true  # SENTINEL-JAVAC-PROBE/' \
    && tt "teeth D: javac absent still degrades only with the probe" 4 0 "$MUT/D.sh" \
         --good-has 'reason=javac-missing' --bad-has '^RESULT: DONE' \
         -- env RSDD_FIDELITY_JAVAC=/nonexistent/javac bash @SUT@ --fixtures "$FIX" --work "$MUT/wD"

  echo "-- teeth E: decompiler rc 3 treated as an ordinary failure -> no DEGRADED --"
  echo missing > "$STUB_DIR/Same.mode"
  mk "teeth E" "$MUT/E.sh" 's/\[ "\$drc" -eq 3 \]  # SENTINEL-DECOMPILER-RC3/false  # SENTINEL-DECOMPILER-RC3/' \
    && tt "teeth E: decompiler-missing is distinguished from a failed unit" 4 0 "$MUT/E.sh" \
         --good-has 'reason=decompiler-missing' --bad-has '^RESULT: DONE' \
         -- bash @SUT@ --fixtures "$FIX" --work "$MUT/wE"
  echo copy > "$STUB_DIR/Same.mode"

  echo "-- teeth F: empty fixtures dir exits 0 (silent zero) --"
  mk "teeth F" "$MUT/F.sh" 's/exit 1  # SENTINEL-EMPTY-FIXTURES/exit 0  # SENTINEL-EMPTY-FIXTURES/' \
    && tt "teeth F: empty fixtures must stay exit 1" 1 0 "$MUT/F.sh" \
         --good-has 'no fixtures' -- bash @SUT@ --fixtures "$ROOT/emptyfix" --work "$MUT/wF"

  echo "-- teeth G: -g flag dropped from the debug-info probe -> DEBUGINFO claims no LVT --"
  mk "teeth G" "$MUT/G.sh" 's/g_flag="-g"  # SENTINEL-G-FLAG/g_flag="-g:none"  # SENTINEL-G-FLAG/' \
    && tt "teeth G: DEBUGINFO g_lvt depends on the real -g compile" 0 0 "$MUT/G.sh" \
         --good-has 'DEBUGINFO Dbg g_lvt=yes nog_lvt=no' --bad-lacks 'DEBUGINFO Dbg g_lvt=yes' \
         --bad-has 'DEBUGINFO Dbg g_lvt=no' -- bash @SUT@ --fixtures "$FIX" --work "$MUT/wG"

  echo "-- teeth H: unmeasured guard removed -> uncompiled fixture claims lvt=no --"
  mk "teeth H" "$MUT/H.sh" 's/\[ "\$n" -gt 0 \] || { echo unmeasured; return; }  # SENTINEL-LVT-UNMEASURED/true  # SENTINEL-LVT-UNMEASURED/' \
    && tt "teeth H: DEBUGINFO of an uncompiled fixture must stay unmeasured" 0 0 "$MUT/H.sh" \
         --good-has 'DEBUGINFO Nocompile g_lvt=unmeasured' --bad-lacks 'g_lvt=unmeasured' \
         --bad-has 'DEBUGINFO Nocompile g_lvt=no' -- bash @SUT@ --fixtures "$FIX" --work "$MUT/wH"

  echo "-- teeth I: timeout status 124 no longer typed -> reported as a generic decompile failure --"
  mk "teeth I" "$MUT/I.sh" 's/if \[ "\$drc" -eq 124 \]; then/if false; then/' \
    && tt "teeth I: Hang fixture keeps reason=timeout only with the 124 branch" 0 0 "$MUT/I.sh" \
         --good-has 'Hang mode=g verdict=FAILED reason=timeout$' --bad-lacks 'Hang mode=g verdict=FAILED reason=timeout$' \
         --bad-has 'Hang mode=g verdict=FAILED reason=decompile$' -- bash @SUT@ --fixtures "$FIX" --work "$MUT/wI"
fi

echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
