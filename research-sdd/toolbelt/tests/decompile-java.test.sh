#!/usr/bin/env bash
# decompile-java.test.sh — contract for procyon engine class/jar input handling.
#
# Tests: (a) procyon + .class → class file NOT after -jar; bare positional; -o present
#        (b) procyon + .jar  → -jar <jar> present; -o present
#        (c) vineflower + .class (regression) → <in> <out> positionals, no -jar misuse
#        (d) cfr + .class (regression) → <in> --outputdir <out> in argv
#
# Stubbing: JAVA_HOME → fake dir with stub java that records argv to JAVA_ARGV_LOG.
#           PROCYON_JAR / VINEFLOWER_JAR / CFR_JAR → empty placeholder files.
#           No real JVM or engine jar is required.
#
# Note on mutant placement: decompile-java.sh resolves lib/tool-env.sh relative to
# ${BASH_SOURCE[0]}.  Mutants live in a sub-directory of the test's temp ROOT so
# that they are never orphaned in the live toolbelt tree (CLAUDE.md §3).  The lib/
# directory is copied alongside them so that the relative source resolves correctly.
#
# Usage: decompile-java.test.sh [--prove-teeth]
# Exit:  0 = all pass · 1 = regression · 2 = harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../decompile-java.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }

TOOLBELT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ROOT="$(mktemp -d)"
MUTANT_DIR="$ROOT/mutants"
mkdir -p "$MUTANT_DIR/lib"
cp "$TOOLBELT_DIR/lib/tool-env.sh" "$MUTANT_DIR/lib/tool-env.sh"
MUT1="$MUTANT_DIR/decompile-java.mut1.sh"
MUT2="$MUTANT_DIR/decompile-java.mut2.sh"
cleanup() { rm -rf "$ROOT"; }
trap 'cleanup' EXIT

pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== decompile-java.test.sh =="

# ── Stub setup ───────────────────────────────────────────────────────────────
# Fake JAVA_HOME with a stub java executable.
# When called with -version (by rsdd_java_21_usable): prints Java 21 version string.
# Otherwise (the actual decompile call): records all argv to JAVA_ARGV_LOG and exits 0.
FAKE_JAVA_HOME="$ROOT/java21"
mkdir -p "$FAKE_JAVA_HOME/bin"
cat > "$FAKE_JAVA_HOME/bin/java" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-version" ]; then
  echo 'openjdk version "21.0.1" 2023-10-17'
  exit 0
fi
if [ -n "${JAVA_ARGV_LOG:-}" ]; then
  printf 'ARGV: %s\n' "$*" >> "$JAVA_ARGV_LOG"
fi
exit 0
STUB
chmod +x "$FAKE_JAVA_HOME/bin/java"
# javap stub required: rsdd_java_21_usable checks [ -x "$home/bin/javap" ]
cp "$FAKE_JAVA_HOME/bin/java" "$FAKE_JAVA_HOME/bin/javap"

# Fake engine jar placeholders (must be real files for the [ -f "$JAR" ] guard)
FAKE_PROCYON="$ROOT/procyon.jar"
FAKE_VINEFLOWER="$ROOT/vineflower.jar"
FAKE_CFR="$ROOT/cfr.jar"
touch "$FAKE_PROCYON" "$FAKE_VINEFLOWER" "$FAKE_CFR"

# Fake input files (created in case decompile-java.sh adds an input guard later)
FAKE_CLASS="$ROOT/Test.class"
FAKE_JAR="$ROOT/test.jar"
touch "$FAKE_CLASS" "$FAKE_JAR"

FAKE_OUT="$ROOT/out"

# Helper: run a SUT (or mutant) and return the last ARGV line logged by the java stub.
# The -version probe inside rsdd_java_21_usable exits before the logging path,
# so the last ARGV line is always the actual decompile invocation.
# Args: sut_path log_path [decompile-java.sh args...]
run_engine() {
  local sut_path="$1" log_path="$2"; shift 2
  rm -f "$log_path"
  JAVA_HOME="$FAKE_JAVA_HOME" \
  PROCYON_JAR="$FAKE_PROCYON" \
  VINEFLOWER_JAR="$FAKE_VINEFLOWER" \
  CFR_JAR="$FAKE_CFR" \
  JAVA_ARGV_LOG="$log_path" \
    bash "$sut_path" "$@" >/dev/null 2>&1 || true
  grep '^ARGV: ' "$log_path" | tail -1 || true
}

# ── Test (a): procyon + .class — class file must NOT follow -jar ──────────────
# Regression: the original code always passed -jar "$IN", breaking .class inputs.
# After the fix the class file is a bare positional; -o $OUT comes before it.
argv_a="$(run_engine "$SUT" "$ROOT/log-a.txt" "$FAKE_CLASS" "$FAKE_OUT" --engine procyon)"
if printf '%s\n' "$argv_a" | grep -qF -- "-jar $FAKE_CLASS"; then
  no "a procyon+class: class file must NOT follow -jar" "argv=[$argv_a]"
elif printf '%s\n' "$argv_a" | grep -qF "$FAKE_CLASS" \
  && printf '%s\n' "$argv_a" | grep -qF -- "-o $FAKE_OUT"; then
  ok "a procyon+class: bare positional, no -jar misuse, -o present" ""
else
  no "a procyon+class: class file or -o missing from argv" "argv=[$argv_a]"
fi

# ── Test (b): procyon + .jar — -jar <jar> must be present ────────────────────
argv_b="$(run_engine "$SUT" "$ROOT/log-b.txt" "$FAKE_JAR" "$FAKE_OUT" --engine procyon)"
if printf '%s\n' "$argv_b" | grep -qF -- "-jar $FAKE_JAR" \
  && printf '%s\n' "$argv_b" | grep -qF -- "-o $FAKE_OUT"; then
  ok "b procyon+jar: -jar <jar> and -o present" ""
else
  no "b procyon+jar: -jar <jar> or -o missing" "argv=[$argv_b]"
fi

# ── Test (c): vineflower + .class — regression: no -jar misuse ───────────────
argv_c="$(run_engine "$SUT" "$ROOT/log-c.txt" "$FAKE_CLASS" "$FAKE_OUT" --engine vineflower)"
if printf '%s\n' "$argv_c" | grep -qF -- "-jar $FAKE_CLASS"; then
  no "c vineflower+class: must not pass -jar <class>" "argv=[$argv_c]"
elif printf '%s\n' "$argv_c" | grep -qF "$FAKE_CLASS" \
  && printf '%s\n' "$argv_c" | grep -qF "$FAKE_OUT"; then
  ok "c vineflower+class: no -jar misuse, in/out positionals present" ""
else
  no "c vineflower+class: in/out missing from argv" "argv=[$argv_c]"
fi

# ── Test (d): cfr + .class — regression: --outputdir present ─────────────────
argv_d="$(run_engine "$SUT" "$ROOT/log-d.txt" "$FAKE_CLASS" "$FAKE_OUT" --engine cfr)"
if printf '%s\n' "$argv_d" | grep -qF "$FAKE_CLASS" \
  && printf '%s\n' "$argv_d" | grep -qF -- "--outputdir $FAKE_OUT"; then
  ok "d cfr+class: <in> --outputdir <out> in argv" ""
else
  no "d cfr+class: expected pattern missing" "argv=[$argv_d]"
fi

# ── Test (e): procyon + uppercase .JAR — must route to -jar branch ────────────
# Pins D1: the extension match must be case-insensitive.  With the old "$IN"
# comparison a foo.JAR input misrouted to the positional (.class) branch.
FAKE_JAR_UPPER="$ROOT/test.JAR"
touch "$FAKE_JAR_UPPER"
argv_e="$(run_engine "$SUT" "$ROOT/log-e.txt" "$FAKE_JAR_UPPER" "$FAKE_OUT" --engine procyon)"
if printf '%s\n' "$argv_e" | grep -qF -- "-jar $FAKE_JAR_UPPER" \
  && printf '%s\n' "$argv_e" | grep -qF -- "-o $FAKE_OUT"; then
  ok "e procyon+.JAR(upper): -jar <jar> and -o present (case-insensitive route)" ""
else
  no "e procyon+.JAR(upper): -jar <jar> or -o missing -- case-sensitive bug" "argv=[$argv_e]"
fi

# ── NJ1 / NJ0 — non-empty output guard ───────────────────────────────────────
# NJ1: engine exits 0 but produces no .java files → wrapper must exit non-zero, no OK.
# Reuses FAKE_JAVA_HOME: stub java exits 0, writes ARGV, but never creates .java files.
_nj1_out="$ROOT/nj1-out"
JAVA_HOME="$FAKE_JAVA_HOME" \
  VINEFLOWER_JAR="$FAKE_VINEFLOWER" \
  JAVA_ARGV_LOG="$ROOT/nj1.log" \
  bash "$SUT" "$FAKE_CLASS" "$_nj1_out" --engine vineflower \
  >"$ROOT/nj1.stdout" 2>"$ROOT/nj1.stderr"; _nj1rc=$?
if [ "$_nj1rc" -ne 0 ] && ! grep -q '^OK' "$ROOT/nj1.stdout"; then
  ok "NJ1: engine exits 0 but no .java files → wrapper exits non-zero, no OK"
else
  no "NJ1: engine exits 0 but no .java files → must exit non-zero (got rc=$_nj1rc)"
fi

# NJ0: success baseline: engine exits 0 and creates .java files → wrapper exits 0, prints OK.
# Uses a separate java stub that writes a sentinel .java to the last positional (out-dir).
NJ0_JAVA_HOME="$ROOT/java21-with-output"
mkdir -p "$NJ0_JAVA_HOME/bin"
cat > "$NJ0_JAVA_HOME/bin/java" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-version" ]; then
  echo 'openjdk version "21.0.1" 2023-10-17'
  exit 0
fi
# Last positional arg is the output directory for vineflower/cfr.
_out="${@: -1}"
mkdir -p "$_out"
touch "$_out/Decompiled.java"
exit 0
STUB
chmod +x "$NJ0_JAVA_HOME/bin/java"
cp "$NJ0_JAVA_HOME/bin/java" "$NJ0_JAVA_HOME/bin/javap"
_nj0_out="$ROOT/nj0-out"
JAVA_HOME="$NJ0_JAVA_HOME" \
  VINEFLOWER_JAR="$FAKE_VINEFLOWER" \
  bash "$SUT" "$FAKE_CLASS" "$_nj0_out" --engine vineflower \
  >"$ROOT/nj0.stdout" 2>"$ROOT/nj0.stderr"; _nj0rc=$?
if [ "$_nj0rc" -eq 0 ] && grep -q '^OK' "$ROOT/nj0.stdout"; then
  ok "NJ0: engine creates .java file → wrapper exits 0, prints OK"
else
  no "NJ0: engine creates .java file → must exit 0 and print OK (got rc=$_nj0rc)"
fi

# ── Scenario stub (timeout / fallback / isolation / marker contract) ─────────
# A programmable fake `java`: identifies the engine from the jar after -jar, derives
# <in>/<out> per engine CLI shape, and writes one .java per top-level .class it is
# given.  Behaviour is driven by env:
#   STUB_SLEEP_CLASSES   space list of class basenames; vineflower given any of them sleeps
#   STUB_SLEEP           seconds to sleep (default 3; the SUT runs with timeout 1)
#   STUB_VF_RC           non-zero: vineflower exits with this code, writing nothing
#   STUB_MARKER_CLASSES  space list of class basenames whose vineflower output carries the
#                        marker given by STUB_MARKER_TEXT (default: indented $VF: line)
#   STUB_CFR_MARKER      non-empty: cfr output carries the markers too (final fallback output must not be re-scanned)
#   STUB_LOG             append "<engine> <in> <out>" per decompile call
T_JAVA_HOME="$ROOT/java-scn"
mkdir -p "$T_JAVA_HOME/bin"
cat > "$T_JAVA_HOME/bin/java" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-version" ]; then echo 'openjdk version "21.0.1" 2023-10-17'; exit 0; fi
args=("$@"); n=${#args[@]}; jar=""
for ((i = 0; i < n; i++)); do [ "${args[i]}" = "-jar" ] && jar="${args[i+1]}"; done
case "$jar" in *vineflower*) eng=vineflower ;; *cfr*) eng=cfr ;; *procyon*) eng=procyon ;; *) eng=unknown ;; esac
case "$eng" in
  vineflower) IN="${args[n-2]}"; OUT="${args[n-1]}" ;;
  cfr) IN="${args[n-3]}"; OUT="${args[n-1]}" ;;
  *) IN="${args[n-1]}"; OUT="${args[n-1]}" ;;
esac
[ -n "${STUB_LOG:-}" ] && printf '%s %s %s\n' "$eng" "$IN" "$OUT" >> "$STUB_LOG"
if [ -d "$IN" ]; then classes="$(cd "$IN" && find . -name '*.class' | sed 's|^\./||' | sort)"
elif [[ "$IN" == *.jar ]]; then classes="$(unzip -Z1 "$IN" | grep '\.class$' | sort)"
else r="${IN#*/ext/}"; [ "$r" = "$IN" ] && r="$(basename "$IN")"; classes="$r"; fi
[ "$eng" = vineflower ] && [ -n "${STUB_VF_RC:-}" ] && exit "$STUB_VF_RC"
if [ "$eng" = vineflower ]; then
  for c in $classes; do b="$(basename "$c" .class)"
    for s in ${STUB_SLEEP_CLASSES:-}; do [ "$b" = "$s" ] && exec sleep "${STUB_SLEEP:-3}"; done
  done
fi
for c in $classes; do
  b="$(basename "$c" .class)"
  case "$b" in *\$*) continue ;; esac
  mkdir -p "$OUT/$(dirname "$c")"
  { echo "// engine=$eng"; echo "class $b {"
    if [ "$eng" = vineflower ] || [ -n "${STUB_CFR_MARKER:-}" ]; then
      def="$(printf '    // $VF: Couldn%st be decompiled' "'")"
      for m in ${STUB_MARKER_CLASSES:-}; do
        [ "$b" = "$m" ] && printf '%s\n' "${STUB_MARKER_TEXT:-$def}"
      done
    fi
    echo "}"; } > "$OUT/${c%.class}.java"
done
exit 0
STUB
chmod +x "$T_JAVA_HOME/bin/java"
cp "$T_JAVA_HOME/bin/java" "$T_JAVA_HOME/bin/javap"

# rt <tag> <input> [ENV=val ...] -- [sut options]   (output dir: $ROOT/o-<tag>)
# Sets RC, SO (stdout), SE (stderr).  RT_SUT overrides the script under test.
rt() {
  local tag="$1" in="$2"; shift 2
  local -a ev=()
  while [ "${1:-}" != "--" ]; do ev+=("$1"); shift; done
  shift
  rm -rf "$ROOT/o-$tag"
  env JAVA_HOME="$T_JAVA_HOME" VINEFLOWER_JAR="$FAKE_VINEFLOWER" CFR_JAR="$FAKE_CFR" \
    PROCYON_JAR="$FAKE_PROCYON" RSDD_DECOMPILE_TIMEOUT=1 STUB_LOG="$ROOT/log-$tag" \
    "${ev[@]}" bash "${RT_SUT:-$SUT}" "$in" "$ROOT/o-$tag" "$@" \
    >"$ROOT/so-$tag" 2>"$ROOT/se-$tag"
  RC=$?; SO="$(cat "$ROOT/so-$tag")"; SE="$(cat "$ROOT/se-$tag")"
}
engine_of() { sed -n '1s|^// engine=||p' "$ROOT/o-$1/$2" 2>/dev/null; }
mkjar() { # mkjar <jar> <class-path>...  (fake .class entries; stubs never parse them)
  local jar="$1"; shift; local d="$ROOT/mk.$$"; rm -rf "$d"; mkdir -p "$d"
  local c; for c in "$@"; do mkdir -p "$d/$(dirname "$c")"; echo "x" > "$d/$c"; done
  [ -z "${MKJAR_SYMLINK:-}" ] || ln -s /nonexistent-target "$d/$MKJAR_SYMLINK"
  rm -f "$jar"; (cd "$d" && zip -qry "$jar" .)
}

# ── Slice A: bounded timeout + automatic fallback (kit issue #1190) ──────────
# A1: primary (vineflower) times out on a .class input → CFR fallback for that unit,
#     typed DEGRADED (never a bare OK), the unit named with reason=timeout.
rt A1 "$FAKE_CLASS" STUB_SLEEP_CLASSES="Test" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED' <<<"$SO" && ! grep -q '^OK' <<<"$SO" \
  && grep -q '^UNIT: Test.*reason=timeout.*fallback=cfr.*result=ok' <<<"$SO" \
  && [ "$(engine_of A1 Test.java)" = cfr ]; then
  ok "A1 timeout → cfr fallback, DEGRADED rc=4, unit named reason=timeout"
else
  no "A1 timeout → cfr fallback, DEGRADED rc=4, unit named reason=timeout" "rc=$RC so=[$SO] se=[$SE]"
fi

# A2: non-zero exit (not a timeout) also falls back; reason distinguishes the two.
rt A2 "$FAKE_CLASS" STUB_VF_RC=7 -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: Test.*reason=error' <<<"$SO" && [ "$(engine_of A2 Test.java)" = cfr ]; then
  ok "A2 non-zero exit → cfr fallback, reason=error (distinct from timeout)"
else
  no "A2 non-zero exit → cfr fallback, reason=error" "rc=$RC so=[$SO]"
fi

# A3: fallback engine unavailable → no output at all: typed PARTIAL naming the unit,
#     wrapper exits non-zero, never OK.
rt A3 "$FAKE_CLASS" STUB_SLEEP_CLASSES="Test" CFR_JAR="$ROOT/absent-cfr.jar" -- --engine vineflower
if [ "$RC" -ne 0 ] && ! grep -q '^OK' <<<"$SO" && grep -q '^PARTIAL' <<<"$SO" \
  && grep -q '^UNIT: Test.*reason=timeout.*fallback=unavailable' <<<"$SO"; then
  ok "A3 fallback engine absent → PARTIAL, fallback=unavailable, non-zero, no OK"
else
  no "A3 fallback engine absent → PARTIAL, fallback=unavailable" "rc=$RC so=[$SO]"
fi

# A4: `timeout` binary absent → typed degraded probe result, engine still runs unbounded.
rt A4 "$FAKE_CLASS" RSDD_TIMEOUT_BIN="$ROOT/no-such-timeout" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED.*reason=timeout-unavailable' <<<"$SO" && ! grep -q '^OK' <<<"$SO"; then
  ok "A4 timeout binary absent → DEGRADED reason=timeout-unavailable, not OK"
else
  no "A4 timeout binary absent → DEGRADED reason=timeout-unavailable" "rc=$RC so=[$SO]"
fi

# A5: invalid timeout value is a usage error (exit 2); 0 disables the bound.
rt A5 "$FAKE_CLASS" -- --engine vineflower --timeout abc
[ "$RC" -eq 2 ] && ok "A5 --timeout abc → exit 2" || no "A5 --timeout abc → exit 2" "rc=$RC"
rt A5b "$FAKE_CLASS" -- --engine vineflower --timeout 0
if [ "$RC" -eq 0 ] && grep -q '^OK' <<<"$SO"; then ok "A5b --timeout 0 → unbounded, OK"; else no "A5b --timeout 0 → unbounded, OK" "rc=$RC so=[$SO]"; fi

# A6: healthy primary never touches the fallback engine.
rt A6 "$FAKE_CLASS" -- --engine vineflower
if [ "$RC" -eq 0 ] && grep -q '^OK' <<<"$SO" && ! grep -q '^cfr ' "$ROOT/log-A6"; then
  ok "A6 healthy primary → OK, fallback engine never invoked"
else
  no "A6 healthy primary → OK, fallback never invoked" "rc=$RC so=[$SO]"
fi

# ── Slice B: unit isolation for jars (kit issue #1224 semantics governing #1190) ──
# A timeout on a jar must degrade ONLY the offending unit (package bisect, then class bisect);
# every other class keeps primary-engine output and the summary is never a bare OK.
units_of() { grep '^UNIT: ' <<<"$SO" | sed -E 's/^UNIT: ([^ ]+) .*/\1/' | sort | tr '\n' ' ' | sed 's/ $//'; }
JAR3="$ROOT/three.jar"
mkjar "$JAR3" a/A.class 'a/A$1.class' b/B.class c/C.class
# iso <tag> <slow-classes> <expected-units> <expected-primary-java...>
iso() {
  local tag="$1" slow="$2" want="$3"; shift 3
  rt "$tag" "$JAR3" STUB_SLEEP_CLASSES="$slow" -- --engine vineflower
  local good=1 f
  [ "$RC" -eq 4 ] || good=0
  grep -q '^OK' <<<"$SO" && good=0
  grep -q '^DEGRADED' <<<"$SO" || good=0
  [ "$(units_of)" = "$want" ] || good=0
  for f in a/A b/B c/C; do
    if [[ " $want " == *" $f "* ]]; then [ "$(engine_of "$tag" "$f.java")" = cfr ] || good=0
    else [ "$(engine_of "$tag" "$f.java")" = vineflower ] || good=0; fi
  done
  if [ "$good" -eq 1 ]; then ok "$tag slow=[$slow] → only [$want] degraded, rest vineflower, DEGRADED rc=4"
  else no "$tag slow=[$slow] → only [$want] degraded" "rc=$RC units=[$(units_of)] so=[$SO]"; fi
}
iso B1 "A" "a/A"
iso B2 "B" "b/B"
iso B3 "C" "c/C"
iso B4 "A C" "a/A c/C"
iso B5 "A B C" "a/A b/B c/C"

# B6: single-unit jar — the only class times out → one unit, cfr output, DEGRADED.
JAR1="$ROOT/one.jar"; mkjar "$JAR1" a/A.class
rt B6 "$JAR1" STUB_SLEEP_CLASSES="A" -- --engine vineflower
if [ "$RC" -eq 4 ] && [ "$(units_of)" = "a/A" ] && [ "$(engine_of B6 a/A.java)" = cfr ] && ! grep -q '^OK' <<<"$SO"; then
  ok "B6 single-unit jar timing out → unit a/A degraded, DEGRADED rc=4"
else no "B6 single-unit jar timing out" "rc=$RC so=[$SO]"; fi

# B7: several classes in ONE package, the middle one hangs → class-level bisect inside the package.
JARP="$ROOT/pkg.jar"; mkjar "$JARP" a/A1.class a/A2.class a/A3.class
rt B7 "$JARP" STUB_SLEEP_CLASSES="A2" -- --engine vineflower
if [ "$RC" -eq 4 ] && [ "$(units_of)" = "a/A2" ] && [ "$(engine_of B7 a/A2.java)" = cfr ] \
  && [ "$(engine_of B7 a/A1.java)" = vineflower ] && [ "$(engine_of B7 a/A3.java)" = vineflower ]; then
  ok "B7 hang inside a multi-class package → class-level isolation, siblings stay vineflower"
else no "B7 class-level isolation inside a package" "rc=$RC units=[$(units_of)] so=[$SO]"; fi

# B9: a jar carrying a symlink entry is refused for isolation (typed), never extracted into use.
JARL="$ROOT/link.jar"; MKJAR_SYMLINK=b/L.class mkjar "$JARL" a/A.class b/B.class
rt B9 "$JARL" STUB_SLEEP_CLASSES="B" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: <whole-artifact> reason=timeout.*isolation=unavailable' <<<"$SO"; then
  ok "B9 symlink entry in jar → isolation refused (typed), whole-artifact fallback"
else no "B9 symlink entry in jar → isolation refused" "rc=$RC so=[$SO]"; fi

# B8: unzip absent → isolation impossible: whole-artifact fallback, typed, never OK.
rt B8 "$JAR3" STUB_SLEEP_CLASSES="B" RSDD_UNZIP_BIN="$ROOT/no-such-unzip" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: <whole-artifact> reason=timeout.*isolation=unavailable' <<<"$SO" && ! grep -q '^OK' <<<"$SO"; then
  ok "B8 unzip absent → <whole-artifact> unit, isolation=unavailable, DEGRADED rc=4"
else no "B8 unzip absent → typed whole-artifact fallback" "rc=$RC so=[$SO]"; fi

# ── Slice C: decompiler-failure marker scan (kit issue #1194) ────────────────
# Vineflower writes "// $VF: Couldn't be decompiled" INDENTED inside the method body; a column-0
# anchored scan misses it and no per-class fallback fires.  The scan must allow leading whitespace,
# and only a comment-leading line counts (a trailing "// $VF:" after code is not a marker).
mk_marker_case() { # <tag> <marker-text> <expected-rc> <expected-units> <label> [extra env...]
  local tag="$1" text="$2" wantrc="$3" want="$4" label="$5"; shift 5
  rt "$tag" "$JAR3" STUB_MARKER_CLASSES="B" STUB_MARKER_TEXT="$text" "$@" -- --engine vineflower
  if [ "$RC" -eq "$wantrc" ] && [ "$(units_of)" = "$want" ]; then ok "$tag $label"
  else no "$tag $label" "rc=$RC units=[$(units_of)] so=[$SO]"; fi
}
mk_marker_case C1 "$(printf '    // $VF: Couldn%st be decompiled' "'")" 4 "b/B" "indented marker → per-class fallback fires (unit b/B)"
if [ "$(engine_of C1 b/B.java)" = cfr ] && [ "$(engine_of C1 a/A.java)" = vineflower ] && [ "$(engine_of C1 c/C.java)" = vineflower ] \
  && grep -q '^UNIT: b/B reason=marker fallback=cfr result=ok' <<<"$SO" && ! grep -q '^OK' <<<"$SO"; then
  ok "C1b marker unit replaced by cfr, siblings keep vineflower, never OK"
else no "C1b marker unit replaced by cfr, siblings keep vineflower" "so=[$SO]"; fi

mk_marker_case C2 "$(printf '// $VF: Couldn%st be decompiled' "'")" 4 "b/B" "column-0 marker still detected"
mk_marker_case C3 "$(printf '\t\t// $VF: Couldn%st be decompiled' "'")" 4 "b/B" "tab-indented marker detected"
mk_marker_case C4 '    int x = 1; // $VF: just a trailing comment' 0 "" "trailing '// \$VF:' after code is NOT a marker → OK"
# C5: .class input carrying a marker → fallback on that class.
rt C5 "$FAKE_CLASS" STUB_MARKER_CLASSES="Test" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: Test reason=marker fallback=cfr result=ok' <<<"$SO" && [ "$(engine_of C5 Test.java)" = cfr ]; then
  ok "C5 marker on a .class input → cfr fallback, DEGRADED rc=4"
else no "C5 marker on a .class input → cfr fallback" "rc=$RC so=[$SO]"; fi

# C6: timeout unit and marker unit in one jar → both reported, each with its own reason.
rt C6 "$JAR3" STUB_SLEEP_CLASSES="A" STUB_MARKER_CLASSES="B" STUB_MARKER_TEXT='    // $VF: marker' -- --engine vineflower
if [ "$RC" -eq 4 ] && [ "$(units_of)" = "a/A b/B" ] && grep -q '^UNIT: a/A reason=timeout' <<<"$SO" \
  && grep -q '^UNIT: b/B reason=marker' <<<"$SO" && [ "$(engine_of C6 c/C.java)" = vineflower ]; then
  ok "C6 timeout unit + marker unit both named with their own reason"
else no "C6 timeout unit + marker unit" "rc=$RC units=[$(units_of)] so=[$SO]"; fi

# C8: whole-artifact fallback output is final — a marker in the FALLBACK engine's files must not
#     trigger a second per-class pass (here unzip is absent, so the whole jar fell back to cfr).
rt C8 "$JAR3" STUB_SLEEP_CLASSES="B" STUB_MARKER_CLASSES="B" STUB_CFR_MARKER=1 RSDD_UNZIP_BIN="$ROOT/no-such-unzip" -- --engine vineflower
if [ "$RC" -eq 4 ] && [ "$(units_of)" = "<whole-artifact>" ]; then
  ok "C8 marker in whole-artifact fallback output is not re-scanned"
else no "C8 marker in whole-artifact fallback output is not re-scanned" "rc=$RC units=[$(units_of)] so=[$SO]"; fi

# C7: marker found but the fallback engine is unavailable → the marked primary output is KEPT:
#     DEGRADED (not PARTIAL), unit typed fallback=unavailable result=kept-primary.
rt C7 "$JAR3" STUB_MARKER_CLASSES="B" STUB_MARKER_TEXT='    // $VF: marker' CFR_JAR="$ROOT/absent-cfr.jar" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED' <<<"$SO" && grep -q '^UNIT: b/B reason=marker fallback=unavailable result=kept-primary' <<<"$SO" \
  && [ "$(engine_of C7 b/B.java)" = vineflower ]; then
  ok "C7 marker + fallback absent → DEGRADED, unit kept-primary (output not lost)"
else no "C7 marker + fallback absent → DEGRADED kept-primary" "rc=$RC so=[$SO]"; fi

# ── Prove-teeth (--prove-teeth) ──────────────────────────────────────────────
# Mutants live in $MUTANT_DIR (a sub-directory of ROOT) — never in the live tree.
# lib/tool-env.sh was copied there at setup so the relative source resolves.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls --"

  # teeth-1: condition always true → always takes the -jar $IN branch.
  # For .class input, procyon is incorrectly called with -jar <class>.
  # Test (a) asserts -jar <class> is absent → this mutant makes (a) go RED.
  # Mutants are created in $MUTANT_DIR (inside temp ROOT); lib/ was copied there
  # at setup time so that the relative source "$HERE/lib/tool-env.sh" resolves.
  sed 's/== \*\.jar/== */' "$SUT" > "$MUT1"
  chmod +x "$MUT1"
  argv_m1="$(run_engine "$MUT1" "$ROOT/log-m1.txt" "$FAKE_CLASS" "$FAKE_OUT" --engine procyon)"
  if printf '%s\n' "$argv_m1" | grep -qF -- "-jar $FAKE_CLASS"; then
    ok "teeth-1: always-jar mutant passes -jar <class> — test (a) bites" ""
  else
    no "teeth-1: always-jar mutant must produce -jar <class>" "argv=[$argv_m1]"
  fi

  # teeth-2: condition always false → always takes the no-jar branch.
  # For .jar input, -jar <jar> is now absent from the procyon argv.
  # Test (b) asserts -jar <jar> is present → this mutant makes (b) go RED.
  sed 's/== \*\.jar/== NEVER_MATCH/' "$SUT" > "$MUT2"
  chmod +x "$MUT2"
  argv_m2="$(run_engine "$MUT2" "$ROOT/log-m2.txt" "$FAKE_JAR" "$FAKE_OUT" --engine procyon)"
  if ! printf '%s\n' "$argv_m2" | grep -qF -- "-jar $FAKE_JAR"; then
    ok "teeth-2: never-jar mutant omits -jar <jar> — test (b) bites" ""
  else
    no "teeth-2: never-jar mutant must omit -jar <jar>" "argv=[$argv_m2]"
  fi

  # MNJ1 TEETH — remove the .java non-empty guard; NJ1 must go RED.
  # The mutant strips 'find ... *.java ... exit 1' so the engine's empty output passes to OK.
  echo "-- MNJ1 mutation: remove .java non-empty guard; NJ1 must go RED --"
  MNJ1="$MUTANT_DIR/decompile-java.mnj1.sh"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  if ! MUTANT_TMPROOT="$ROOT" mutant_sed "$SUT" "$MNJ1" 's/^elif ! has_java "\$OUT"; then$/elif false; then/'; then
    no "MNJ1 setup: could not build mutant (guard line not found, or refused by lib/mutant.sh)" ""
  else
    chmod +x "$MNJ1"
    _mnj1_out="$ROOT/mnj1-out"
    JAVA_HOME="$FAKE_JAVA_HOME" \
      VINEFLOWER_JAR="$FAKE_VINEFLOWER" \
      JAVA_ARGV_LOG="$ROOT/mnj1.log" \
      bash "$MNJ1" "$FAKE_CLASS" "$_mnj1_out" --engine vineflower \
      >"$ROOT/mnj1.stdout" 2>/dev/null; _mnj1rc=$?
    if [ "$_mnj1rc" -eq 0 ] && grep -q '^OK' "$ROOT/mnj1.stdout"; then
      ok "MNJ1-killed: guard-removed mutant exits 0+OK on no .java → NJ1 bites" ""
    else
      no "MNJ1-killed: guard-removed mutant must print OK on no .java (got rc=$_mnj1rc) — NJ1 has no teeth" ""
    fi
  fi

  # Slice-A mutants: each must flip the matching A-case.  build_mut <name> <sed-expr>; sets MUT.
  build_mut() {
    MUT="$MUTANT_DIR/decompile-java.$1.sh"
    if MUTANT_TMPROOT="$ROOT" mutant_sed "$SUT" "$MUT" "$2"; then chmod +x "$MUT"; return 0; fi
    no "teeth-$1 setup: could not build mutant (anchor not found, or refused by lib/mutant.sh)" ""; return 1
  }
  echo "-- teeth: slice A (timeout + fallback) --"
  # mA1: never fall back → A1 loses the cfr output and the UNIT line.
  if build_mut mA1 's/^    fallback_unit "\$(unit_name)" "\$reason" "\$IN"$/    :/'; then
    RT_SUT="$MUT" rt mA1 "$FAKE_CLASS" STUB_SLEEP_CLASSES="Test" -- --engine vineflower
    if [ "$(engine_of mA1 Test.java)" != cfr ] && ! grep -q '^UNIT:' <<<"$SO"; then
      ok "teeth-mA1: no-fallback mutant produces no cfr output/UNIT → A1 bites"
    else no "teeth-mA1: no-fallback mutant still fell back — A1 has no teeth" "so=[$SO]"; fi
  fi
  # mA2: always print OK even with degraded units → A1/A2 lose DEGRADED.
  if build_mut mA2 's/^if \[ "\${#UNITS\[@\]}" -eq 0 \] && \[ -z "\$PROBE_DEGRADED" \]; then$/if true; then/'; then
    RT_SUT="$MUT" rt mA2 "$FAKE_CLASS" STUB_SLEEP_CLASSES="Test" -- --engine vineflower
    if grep -q '^OK' <<<"$SO" && [ "$RC" -eq 0 ]; then
      ok "teeth-mA2: always-OK mutant reports OK for a fallen-back unit → A1 bites"
    else no "teeth-mA2: always-OK mutant did not print OK — A1 has no teeth" "rc=$RC so=[$SO]"; fi
  fi
  # mA3: timeout indistinguishable from error → reason=timeout lost.
  if build_mut mA3 's/^reason_of() .*$/reason_of() { echo error; }/'; then
    RT_SUT="$MUT" rt mA3 "$FAKE_CLASS" STUB_SLEEP_CLASSES="Test" -- --engine vineflower
    if ! grep -q 'reason=timeout' <<<"$SO"; then
      ok "teeth-mA3: classification-removed mutant loses reason=timeout → A1 bites"
    else no "teeth-mA3: mutant still says reason=timeout — A1 has no teeth" "so=[$SO]"; fi
  fi
  # mA4: timeout probe removed → absent binary is no longer typed.
  if build_mut mA4 's/^  PROBE_DEGRADED="timeout-unavailable"$/  :/'; then
    RT_SUT="$MUT" rt mA4 "$FAKE_CLASS" RSDD_TIMEOUT_BIN="$ROOT/no-such-timeout" -- --engine vineflower
    if ! grep -q 'reason=timeout-unavailable' <<<"$SO"; then
      ok "teeth-mA4: probe-removed mutant loses reason=timeout-unavailable → A4 bites"
    else no "teeth-mA4: mutant still typed the missing binary — A4 has no teeth" "so=[$SO]"; fi
  fi
  echo "-- teeth: slice C (marker scan) --"
  # mC1: column-0 anchor (the #1194 bug) → indented marker missed.
  if build_mut mC1 's/^MARKER_RE=.\^\[\[:space:\]\]\*\/\/ /MARKER_RE=\x27^\/\/ /'; then
    RT_SUT="$MUT" rt mC1 "$JAR3" STUB_MARKER_CLASSES="B" STUB_MARKER_TEXT='    // $VF: marker' -- --engine vineflower
    if grep -q '^OK' <<<"$SO"; then ok "teeth-mC1: column-0 anchor misses the indented marker → C1 bites"
    else no "teeth-mC1: mutant still detected the indented marker — C1 has no teeth" "so=[$SO]"; fi
  fi
  # mC2: any '// $VF:' anywhere counts → trailing comment (C4) becomes a false marker.
  if build_mut mC2 's/^MARKER_RE=.*$/MARKER_RE=\x27\/\/ \\$VF: \x27/'; then
    RT_SUT="$MUT" rt mC2 "$JAR3" STUB_MARKER_CLASSES="B" STUB_MARKER_TEXT='    int x = 1; // $VF: just a trailing comment' -- --engine vineflower
    if ! grep -q '^OK' <<<"$SO"; then ok "teeth-mC2: unanchored mutant flags a trailing comment → C4 bites"
    else no "teeth-mC2: unanchored mutant still printed OK — C4 has no teeth" "so=[$SO]"; fi
  fi
  # mC3: re-scan fallback output → C8 gains a spurious marker unit.
  if build_mut mC3 's/^\[ -n "\$NO_SCAN" \] || scan_markers$/scan_markers/'; then
    RT_SUT="$MUT" rt mC3 "$JAR3" STUB_SLEEP_CLASSES="B" STUB_MARKER_CLASSES="B" STUB_CFR_MARKER=1 RSDD_UNZIP_BIN="$ROOT/no-such-unzip" -- --engine vineflower
    if [ "$(units_of)" != "<whole-artifact>" ]; then ok "teeth-mC3: no-guard mutant re-scans fallback output → C8 bites"
    else no "teeth-mC3: mutant did not re-scan — C8 has no teeth" "so=[$SO]"; fi
  fi
  echo "-- teeth: slice B (unit isolation) --"
  # mB1: isolation never runs → B1 degrades the whole artifact instead of one unit.
  if build_mut mB1 's/^    isolate_jar || {/    false || {/'; then
    RT_SUT="$MUT" rt mB1 "$JAR3" STUB_SLEEP_CLASSES="A" -- --engine vineflower
    if grep -q '^UNIT: <whole-artifact>' <<<"$SO" && [ "$(engine_of mB1 b/B.java)" = cfr ]; then
      ok "teeth-mB1: no-isolation mutant degrades the whole artifact → B1 bites"
    else no "teeth-mB1: no-isolation mutant still isolated — B1 has no teeth" "so=[$SO]"; fi
  fi
  # mB2: class-level bisect removed → every class in the failing package falls back (B7).
  if build_mut mB2 's/^    if \[ "\${#outer\[@\]}" -eq 1 \]; then fallback_unit/    if true; then fallback_unit/'; then
    RT_SUT="$MUT" rt mB2 "$JARP" STUB_SLEEP_CLASSES="A2" -- --engine vineflower
    if [ "$(engine_of mB2 a/A1.java)" = cfr ]; then
      ok "teeth-mB2: no-class-bisect mutant degrades sibling classes → B7 bites"
    else no "teeth-mB2: mutant kept siblings on vineflower — B7 has no teeth" "so=[$SO]"; fi
  fi
  # mB3: symlink guard removed → B9 no longer refuses isolation.
  if build_mut mB3 's/^  if \[ -n "\$(find "\$EXT" -type l -print -quit)" \]; then rm -rf/  if false; then rm -rf/'; then
    RT_SUT="$MUT" rt mB3 "$JARL" STUB_SLEEP_CLASSES="B" -- --engine vineflower
    if ! grep -q 'isolation=unavailable' <<<"$SO"; then
      ok "teeth-mB3: guard-removed mutant extracts a symlinked jar → B9 bites"
    else no "teeth-mB3: mutant still refused the symlinked jar — B9 has no teeth" "so=[$SO]"; fi
  fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
