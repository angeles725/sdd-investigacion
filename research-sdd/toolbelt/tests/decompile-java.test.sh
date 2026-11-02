#!/usr/bin/env bash
# decompile-java.test.sh — black-box contract for the decompile-java.sh SHIM (kit issues #1190, #1224, #1320; port #2419).
#
# The decompiler wrapper is the Go command `rsdd corroborate decompile` (research-sdd/rsdd/internal/corroborate/
# decompile). Everything this suite used to pin lives in the Go tests now, driven by a fake process runner and a fake
# clock so nothing sleeps: the timeout / kill-after / isolation-budget decisions, the fallback and isolation tree, the
# coverage sweep, the freshness rules, the failure-marker scan, the class-file facts header and the ~70 mutants of the
# old script (table at the head of decompile_test.go: old case or mutant -> Go test). What stays here is what only the
# shim can show: argument and environment pass-through to the real binary, the legacy exit codes, --javap, the typed
# degraded state when rsdd is missing, and a few end-to-end runs of real child processes through the real binary.
# The java stub is a shell script, so the suite needs no JDK and no engine jar.
#
# Removed cases (old suite -> Go): a b c d e -> TestEngineArgv; NJ0 NJ1 A1-A6 B1-B9 C1-C8 E1-E8 F1-F6b G H1-H4 I1-I5 J1-J4
# K1-K3 L1-L3 M1-M3 P1 Q1 R1 S1-S5c -> TestScenarios/<same tag> (and TestIsolationClamp, TestBudgetEdge, TestMarkerRegexp);
# the CLASSFILE header cases H1 H2 H5-H15 -> TestClassfileHeader, TestFactsBudget, TestFactsRunner (H5 H13 H15 H1p and the
# mCF* mutants about the Python fallback and the binary lookup went with those: the facts are read in process now).
#
# TEETH (--prove-teeth, tests/lib/mutant.sh): one mutant of the SHIM, dispatching to another rsdd command, must break
# case 10's legacy usage contract. The engine's mutation controls are Go tests (internal/corroborate/decompile).
#
# Usage: decompile-java.test.sh [--prove-teeth]     Exit: 0 = all pass · 1 = regression · 2 = harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../decompile-java.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-72s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-72s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== decompile-java.test.sh =="

# A kit-shaped copy: the shim resolves rsdd from <toolbelt>/../rsdd (lib/rsdd-exec.sh), so the copy sits in a dir whose
# rsdd/ links to the real module and any rebuild (RSDD_BIN unset, as in CI) lands in $ROOT/kit/bin, never in the kit.
mkdir -p "$ROOT/kit" && ln -s "$(CDPATH='' cd -P -- "$HERE/../../rsdd" && pwd -P)" "$ROOT/kit/rsdd" \
  || { echo "FATAL: could not link the rsdd module" >&2; exit 2; }
TB="$ROOT/kit/toolbelt"; mkdir -p "$TB/lib"
cp "$SUT" "$TB/" && cp "$HERE/../lib/rsdd-exec.sh" "$TB/lib/" || { echo "FATAL: could not stage the shim" >&2; exit 2; }   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh
SHIM="$TB/decompile-java.sh"

# ---- stub JDK: shell scripts that behave like java and javap for tiny inputs -----------------------------------------
JH="$ROOT/jdk"; mkdir -p "$JH/bin"
cat > "$JH/bin/java" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-version" ]; then echo 'openjdk version "21.0.1" 2023-10-17'; exit 0; fi
args=("$@"); n=${#args[@]}; jar=""
for ((i = 0; i < n; i++)); do [ "${args[i]}" = "-jar" ] && jar="${args[i+1]}"; done
case "$jar" in
  *vineflower*) eng=vineflower; IN="${args[n-2]}"; OUT="${args[n-1]}" ;;
  *cfr*) eng=cfr; IN="${args[n-3]}"; OUT="${args[n-1]}" ;;
  *) eng=other; IN="${args[n-1]}"; OUT="$IN" ;;
esac
[ -z "${STUB_LOG:-}" ] || printf '%s %s\n' "$eng" "${args[*]}" >> "$STUB_LOG"
[ "$eng" = vineflower ] && [ -n "${STUB_VF_RC:-}" ] && exit "$STUB_VF_RC"
[ "$eng" = vineflower ] && [ -n "${STUB_FAIL_WHOLE:-}" ] && [[ "$IN" == *.jar ]] && exit 1
[ -z "${STUB_SILENT:-}" ] || exit 0
if [ -d "$IN" ]; then classes="$(cd "$IN" && find . -name '*.class' | sed 's|^\./||' | sort)"
elif [[ "$IN" == *.jar ]]; then classes="$(unzip -Z1 "$IN" | grep '\.class$' | sort)"
else classes="$(basename "$IN")"; fi
for c in $classes; do
  b="${c##*/}"; b="${b%.class}"; [[ "$b" == *'$'* ]] && continue
  d="${c%/*}"; [ "$d" = "$c" ] && d=.
  mkdir -p "$OUT/$d"; { echo "// engine=$eng"; echo "class $b {}"; } > "$OUT/${c%.class}.java"
done
exit 0
STUB
cat > "$JH/bin/javap" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-version" ]; then echo 'openjdk version "21.0.1" 2023-10-17'; exit 0; fi
echo "javap-stub $*"; echo "javap warning" >&2; exit 5
STUB
chmod +x "$JH/bin/java" "$JH/bin/javap"
: > "$ROOT/vineflower.jar"; : > "$ROOT/cfr.jar"; : > "$ROOT/procyon.jar"
printf 'not a class file' > "$ROOT/Test.class"
mkdir -p "$ROOT/jarsrc/a" "$ROOT/jarsrc/b" && printf x > "$ROOT/jarsrc/a/A.class" && printf x > "$ROOT/jarsrc/b/B.class"
(cd "$ROOT/jarsrc" && zip -qr "$ROOT/two.jar" .) || { echo "FATAL: zip is required" >&2; exit 2; }

run() { # run ENV... -- ARGS... ; sets OUT, ERR, RC (the stub JDK and jars are on every run)
  local -a ev=(); while [ "$1" != "--" ]; do ev+=("$1"); shift; done; shift
  OUT="$(env JAVA_HOME="$JH" VINEFLOWER_JAR="$ROOT/vineflower.jar" CFR_JAR="$ROOT/cfr.jar" PROCYON_JAR="$ROOT/procyon.jar" \
    STUB_LOG="$ROOT/stub.log" "${ev[@]}" bash "$SHIM" "$@" 2>"$ROOT/err")"; RC=$?
  ERR="$(cat "$ROOT/err")"
}
has()  { grep -qE -- "$1" <<<"$OUT"; }
hasE() { grep -qE -- "$1" <<<"$ERR"; }

# ---- shim shape ---------------------------------------------------------------------------------------------------
grep -q '^rsdd_exec corroborate decompile "\$@"' "$SUT" && ! grep -q 'run_engine\|timeout' "$SUT" \
  && ok "1 the script is a shim for rsdd corroborate decompile (no engine logic left)" || no "1 shim shape"

# ---- end-to-end runs through the real binary --------------------------------------------------------------------------
rm -f "$ROOT/stub.log"
run -- "$ROOT/Test.class" "$ROOT/o1" --engine vineflower
{ [ "$RC" = 0 ] && [ "$OUT" = "OK: $ROOT/Test.class -> $ROOT/o1  (engine=vineflower)" ] && [ -f "$ROOT/o1/Test.java" ]; } \
  && ok "2 .class run: typed OK line only on stdout, rc 0, source written" || no "2 .class run" "rc=$RC out=$OUT err=$ERR"
{ hasE '^CLASSFILE major=unknown lvt=unknown classes=1 resugar_risk=unknown unreadable=1 partial=0 truncated=none$' \
  && hasE '^WARN: decompiled source is a reconstruction; syntax-level claims .* need bytecode evidence \(javap -c -p'; } \
  && ok "3 stderr carries the CLASSFILE header (read in process) and the bytecode-evidence warning" || no "3 stderr header" "$ERR"
rm -f "$ROOT/stub.log"; run -- "$ROOT/Test.class" "$ROOT/o2" --engine cfr
{ [ "$RC" = 0 ] && grep -qF -- "cfr -jar $ROOT/cfr.jar $ROOT/Test.class --outputdir $ROOT/o2" "$ROOT/stub.log"; } \
  && ok "4 --engine and the jar variables reach the engine command line" || no "4 engine argv" "rc=$RC log=$(cat "$ROOT/stub.log" 2>/dev/null)"
rm -f "$ROOT/stub.log"; run RSDD_DECOMPILE_MAX_HEAP=256m -- "$ROOT/Test.class" "$ROOT/o3" --thread-count 3
{ [ "$RC" = 0 ] && grep -qF -- "-Xmx256m -jar $ROOT/vineflower.jar --thread-count=3 $ROOT/Test.class $ROOT/o3" "$ROOT/stub.log"; } \
  && ok "5 --thread-count and RSDD_DECOMPILE_MAX_HEAP reach the engine command line" || no "5 heap/threads" "rc=$RC log=$(cat "$ROOT/stub.log" 2>/dev/null)"
run STUB_VF_RC=7 -- "$ROOT/Test.class" "$ROOT/o4"
{ [ "$RC" = 4 ] && has '^DEGRADED: .* \(engine=vineflower units=1 primary=error\)$' && has '^UNIT: Test reason=error fallback=cfr result=ok$' \
  && [ "$(sed -n 1p "$ROOT/o4/Test.java")" = "// engine=cfr" ]; } \
  && ok "6 primary engine fails -> cfr fallback, typed DEGRADED, UNIT line, rc 4" || no "6 fallback" "rc=$RC out=$OUT"
run STUB_FAIL_WHOLE=1 -- "$ROOT/two.jar" "$ROOT/o5"
{ [ "$RC" = 4 ] && has '\(engine=vineflower units=0 primary=error isolation=package\)$' \
  && [ "$(sed -n 1p "$ROOT/o5/a/A.java")" = "// engine=vineflower" ] && [ "$(sed -n 1p "$ROOT/o5/b/B.java")" = "// engine=vineflower" ]; } \
  && ok "7 whole-jar failure: per-package isolation through real unzip recovers every class" || no "7 jar isolation" "rc=$RC out=$OUT err=$ERR"
run -- "$ROOT/two.jar" "$ROOT/o6"
{ [ "$RC" = 0 ] && has '^OK: ' && [ -f "$ROOT/o6/a/A.java" ]; } && ok "8 whole-jar success: coverage sweep passes, bare OK" || no "8 jar ok" "rc=$RC out=$OUT"

# ---- legacy exit codes and messages pass through ---------------------------------------------------------------------
run STUB_SILENT=1 -- "$ROOT/Test.class" "$ROOT/o7"
{ [ "$RC" = 1 ] && [ -z "$OUT" ] && hasE 'exited 0 but produced no .java files'; } && ok "9 exit 0 with no source -> rc 1, no OK line" || no "9 empty output" "rc=$RC out=$OUT err=$ERR"
run -- "$ROOT/Test.class" "$ROOT/o8" --bogus
{ [ "$RC" = 2 ] && hasE '^unknown option: --bogus$'; } && ok "10 unknown option -> rc 2" || no "10 usage" "rc=$RC $ERR"
run -- "$ROOT/Test.class" "$ROOT/o9" --timeout abc
{ [ "$RC" = 2 ] && hasE '^invalid timeout'; } && ok "11 invalid --timeout -> rc 2" || no "11 timeout" "rc=$RC $ERR"
run CFR_JAR="$ROOT/no-such.jar" -- "$ROOT/Test.class" "$ROOT/o10" --engine cfr
{ [ "$RC" = 3 ] && hasE '^cfr jar not found \(set CFR_JAR\)$'; } && ok "12 missing engine jar -> rc 3 naming the variable" || no "12 jar missing" "rc=$RC $ERR"
run -- --javap "$ROOT/Test.class"
{ [ "$RC" = 5 ] && [ "$OUT" = "javap-stub -p -c $ROOT/Test.class" ] && hasE '^javap warning$'; } \
  && ok "13 --javap runs javap -p -c and passes its status and streams through" || no "13 javap" "rc=$RC out=$OUT err=$ERR"

# ---- the shim itself --------------------------------------------------------------------------------------------------
run RSDD_BIN=/nonexistent/rsdd -- "$ROOT/Test.class" "$ROOT/o12"
{ [ "$RC" = 2 ] && hasE '^degraded: rsdd-unavailable'; } && ok "14 no rsdd binary -> typed degraded: rsdd-unavailable, never a silent pass" || no "14 rsdd missing" "rc=$RC $ERR"
mkdir -p "$ROOT/lonely" && cp "$SUT" "$ROOT/lonely/"
OUT="$(bash "$ROOT/lonely/decompile-java.sh" x y 2>"$ROOT/err")"; RC=$?; ERR="$(cat "$ROOT/err")"
{ [ "$RC" = 2 ] && hasE '^degraded: rsdd-unavailable — rsdd-exec.sh missing beside'; } && ok "15 rsdd-exec.sh missing beside the shim -> rc 2, typed" || no "15 lib missing" "rc=$RC $ERR"
mkdir -p "$ROOT/elsewhere" && ln -s "$SHIM" "$ROOT/elsewhere/dj"
OUT="$(cd "$ROOT/elsewhere" && env JAVA_HOME="$JH" VINEFLOWER_JAR="$ROOT/vineflower.jar" CFR_JAR="$ROOT/cfr.jar" bash ./dj "$ROOT/Test.class" "$ROOT/o13" 2>"$ROOT/err")"; RC=$?
{ [ "$RC" = 0 ] && [ -f "$ROOT/o13/Test.java" ]; } && ok "16 run through a symlink from another directory: the shim finds its own directory" || no "16 symlink" "rc=$RC $(cat "$ROOT/err")"

# --prove-teeth: the wrapper is the Go command `rsdd corroborate decompile` (kit issue #2419); its mutation controls
# live in research-sdd/rsdd/internal/corroborate/decompile (table at the head of decompile_test.go), so this suite runs
# the shim black-box only.

# ---- TEETH ----------------------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # shellcheck source=lib/stage-libs.sh
  . "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into the mutant toolbelt
  mutant_bootstrap mutant_chain || exit 2
  echo "-- teeth 1: the shim dispatches to another command, expect case 10's usage contract to break --"
  MTB="$ROOT/kitm/toolbelt"; mkdir -p "$MTB" && ln -s "$(readlink "$ROOT/kit/rsdd")" "$ROOT/kitm/rsdd" \
    && rsdd_stage_libs "$MTB" || { echo "FATAL: could not stage the mutant kit" >&2; exit 2; }
  if mutant_chain teeth1-wrong-command "$SHIM" "$MTB/decompile-java.sh" 's|rsdd_exec corroborate decompile|rsdd_exec corroborate nonesuch|'; then
    real_shim="$SHIM"; SHIM="$MTB/decompile-java.sh"
    run -- "$ROOT/Test.class" "$ROOT/o8m" --bogus
    SHIM="$real_shim"
    if [ "$RC" = 2 ] && hasE '^unknown option: --bogus$'; then no "teeth1: case 10 still passes under a wrong dispatch — case 10 is THEATER" "rc=$RC"
    else ok "teeth1: a wrong dispatch loses the legacy unknown-option line — case 10 has teeth" "rc=$RC"; fi
  else no "teeth1: mutant refused by lib/mutant.sh" "tooth not run"; fi
fi

echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
