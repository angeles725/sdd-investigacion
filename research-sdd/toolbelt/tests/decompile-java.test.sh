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
#   STUB_FAIL_WHOLE      non-empty: vineflower exits 1 when given the .jar itself (whole-jar run only)
#   STUB_SLEEP_MIN       N: vineflower sleeps when the input holds >= N top-level classes
#   STUB_EMPTY_MIN       N: vineflower exits 0 writing nothing when a DIR input holds >= N classes
#   STUB_OMIT_CLASSES    space list of class basenames vineflower silently leaves out of its output
#   STUB_IGNORE_TERM     non-empty: a "sleeping" vineflower ignores SIGTERM (only SIGKILL stops it → rc 137)
#   STUB_STRIP_LAYOUT    non-empty: every engine writes output paths that follow the PACKAGE (BOOT-INF/classes/,
#                        WEB-INF/classes/ and META-INF/versions/N/ prefixes dropped), like real CFR/Procyon
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
[ "$eng" = vineflower ] && [ -n "${STUB_FAIL_WHOLE:-}" ] && [[ "$IN" == *.jar ]] && exit 1
ncls="$(printf '%s\n' "$classes" | grep -vc '\$')"
[ "$eng" = vineflower ] && [ -n "${STUB_SLEEP_MIN:-}" ] && [ "$ncls" -ge "$STUB_SLEEP_MIN" ] && exec sleep "${STUB_SLEEP:-3}"
[ "$eng" = vineflower ] && [ -n "${STUB_EMPTY_MIN:-}" ] && [ -d "$IN" ] && [ "$ncls" -ge "$STUB_EMPTY_MIN" ] && exit 0
if [ "$eng" = vineflower ]; then
  for c in $classes; do b="$(basename "$c" .class)"
    for s in ${STUB_SLEEP_CLASSES:-}; do [ "$b" = "$s" ] && { [ -n "${STUB_IGNORE_TERM:-}" ] && { trap '' TERM; for _ in $(seq 1 100); do sleep 0.2; done; exit 0; }; exec sleep "${STUB_SLEEP:-3}"; }; done
  done
fi
for c in $classes; do
  b="$(basename "$c" .class)"
  case "$b" in *\$*) o="${b%%\$*}"; grep -qx "$(dirname "$c")/$o.class\|$o.class" <<<"$classes" && continue ;; esac
  omit=""; for m in ${STUB_OMIT_CLASSES:-}; do [ "$b" = "$m" ] && omit=1; done
  [ "$eng" = vineflower ] && [ -n "$omit" ] && continue
  oc="$c"; [ -z "${STUB_STRIP_LAYOUT:-}" ] || { oc="${oc#BOOT-INF/classes/}"; oc="${oc#WEB-INF/classes/}"; oc="${oc#META-INF/versions/*/}"; }
  mkdir -p "$OUT/$(dirname "$oc")"
  { echo "// engine=$eng"; echo "class $b {"
    if [ "$eng" = vineflower ] || [ -n "${STUB_CFR_MARKER:-}" ]; then
      def="$(printf '    // $VF: Couldn%st be decompiled' "'")"
      for m in ${STUB_MARKER_CLASSES:-}; do
        [ "$b" = "$m" ] && printf '%s\n' "${STUB_MARKER_TEXT:-$def}"
      done
    fi
    echo "}"; } > "$OUT/${oc%.class}.java"
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
  if [ -n "${RT_PRESEED:-}" ]; then # stale files (older than the run) already sitting in a REUSED out-dir
    local pf; for pf in $RT_PRESEED; do
      mkdir -p "$ROOT/o-$tag/$(dirname "$pf")"; echo "// engine=stale" > "$ROOT/o-$tag/$pf"
      touch -d '2 days ago' "$ROOT/o-$tag/$pf"
    done
  fi
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
rt C6 "$JAR3" STUB_SLEEP_CLASSES="A" STUB_MARKER_CLASSES="B" -- --engine vineflower
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
rt C7 "$JAR3" STUB_MARKER_CLASSES="B" CFR_JAR="$ROOT/absent-cfr.jar" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED' <<<"$SO" && grep -q '^UNIT: b/B reason=marker fallback=unavailable result=kept-primary' <<<"$SO" \
  && [ "$(engine_of C7 b/B.java)" = vineflower ]; then
  ok "C7 marker + fallback absent → DEGRADED, unit kept-primary (output not lost)"
else no "C7 marker + fallback absent → DEGRADED kept-primary" "rc=$RC so=[$SO]"; fi

# ── Review round 1: primary state, orphan/empty coverage (B1, B2) ───────────
# E1/E2: the whole-jar run fails but every package succeeds alone → no UNIT, yet the summary
#        must still carry the degraded PRIMARY status (never a bare OK).
rt E1 "$JAR3" STUB_FAIL_WHOLE=1 -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED.*primary=error isolation=package' <<<"$SO" && ! grep -q '^OK' <<<"$SO" \
  && [ -z "$(units_of)" ] && [ "$(engine_of E1 b/B.java)" = vineflower ]; then
  ok "E1 whole-jar error, all packages fine alone → DEGRADED primary=error isolation=package, no units"
else no "E1 whole-jar error recovered per package → typed primary state" "rc=$RC so=[$SO]"; fi
rt E2 "$JAR3" STUB_SLEEP_MIN=3 -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED.*primary=timeout isolation=package' <<<"$SO" && [ -z "$(units_of)" ]; then
  ok "E2 whole-jar timeout, all packages fine alone → DEGRADED primary=timeout isolation=package"
else no "E2 whole-jar timeout recovered per package → typed primary state" "rc=$RC so=[$SO]"; fi
# E3: package AND jar time out, every class fine alone → class-level isolation, still degraded.
rt E3 "$JARP" STUB_SLEEP_MIN=2 -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED.*primary=timeout isolation=class' <<<"$SO" && [ -z "$(units_of)" ] \
  && [ "$(engine_of E3 a/A2.java)" = vineflower ]; then
  ok "E3 hang only at package level, classes fine alone → DEGRADED isolation=class, no units"
else no "E3 class-level recovery → typed primary state" "rc=$RC so=[$SO]"; fi

# E4: a package rerun exiting 0 with NO output is not dropped: bisected; a lone empty class → reason=empty.
rt E4 "$JARP" STUB_FAIL_WHOLE=1 STUB_EMPTY_MIN=2 -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED.*isolation=class' <<<"$SO" && [ "$(engine_of E4 a/A1.java)" = vineflower ]; then
  ok "E4 package rerun exit 0 + no output → bisected, classes recovered, never silently dropped"
else no "E4 empty package rerun is bisected" "rc=$RC so=[$SO]"; fi
JARE="$ROOT/empty1.jar"; mkjar "$JARE" a/A.class
rt E5 "$JARE" STUB_FAIL_WHOLE=1 STUB_EMPTY_MIN=1 -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: a/A reason=empty fallback=cfr result=ok' <<<"$SO" && [ "$(engine_of E5 a/A.java)" = cfr ]; then
  ok "E5 lone class rerun exit 0 + no output → UNIT reason=empty, cfr fallback"
else no "E5 lone empty class → reason=empty" "rc=$RC so=[$SO]"; fi

# E6: orphan '$' classes (Scala Foo$, package$, orphan inner) are units of their own, never skipped.
JARZ="$ROOT/orphan.jar"; mkjar "$JARZ" 'z/Z$.class' 'z/Z$1.class' y/Y.class
rt E6 "$JARZ" STUB_SLEEP_CLASSES='Z$' -- --engine vineflower
if [ "$RC" -eq 4 ] && [ "$(units_of)" = 'z/Z$' ] && [ "$(engine_of E6 'z/Z$.java')" = cfr ] \
  && [ "$(engine_of E6 'z/Z$1.java')" = vineflower ] && [ "$(engine_of E6 y/Y.java)" = vineflower ]; then
  ok "E6 orphan Z\$ + Z\$1 (no outer Z) → each its own unit; only the hanging Z\$ degraded"
else no "E6 orphan \$ classes are units" "rc=$RC units=[$(units_of)] so=[$SO]"; fi
JARO="$ROOT/onlyorphan.jar"; mkjar "$JARO" 'z/Z$.class' 'z/Z$1.class'
rt E7 "$JARO" STUB_FAIL_WHOLE=1 -- --engine vineflower
if [ "$RC" -eq 4 ] && [ -f "$ROOT/o-E7/z/Z\$.java" ] && [ -f "$ROOT/o-E7/z/Z\$1.java" ]; then
  ok "E7 package of only '\$' classes → both decompiled and present in output"
else no "E7 package of only \$ classes" "rc=$RC so=[$SO]"; fi

# E8: coverage sweep — an engine that silently omits a class from an otherwise fine rerun → reason=missing.
rt E8 "$JARP" STUB_FAIL_WHOLE=1 STUB_OMIT_CLASSES="A2" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: a/A2 reason=missing fallback=cfr result=ok' <<<"$SO" && [ "$(engine_of E8 a/A2.java)" = cfr ] \
  && [ "$(engine_of E8 a/A1.java)" = vineflower ]; then
  ok "E8 class silently omitted by the primary → UNIT reason=missing, cfr fallback"
else no "E8 omitted class is covered by a UNIT" "rc=$RC so=[$SO]"; fi

# ── Review round 1: marker precision, killed, marked fallback, total budget ─
# F1: informational '$VF:' comments (real niagara5 corpus: 68 'synthetic class', 2 'Extended synchronized
#     range', hundreds of 'Could not verify finally blocks') are NOT failures → file stays primary, OK.
mk_marker_case F1a '    // $VF: synthetic class' 0 "" "informational 'synthetic class' stays primary (OK)"
mk_marker_case F1b '    // $VF: Extended synchronized range to monitorexit' 0 "" "informational 'Extended synchronized range' stays primary (OK)"
mk_marker_case F1c '    // $VF: Could not verify finally blocks. A semaphore variable has been added to preserve control flow.' 0 "" "quality warning 'finally blocks' stays primary (OK)"
mk_marker_case F1d '    // $VF: Could not properly define all variable types!' 0 "" "quality warning 'variable types' stays primary (OK)"
# F2: a string literal mentioning the failure text is not a comment.
mk_marker_case F2 '    String s = "// $VF: Couldn'"'"'t be decompiled";' 0 "" "failure text inside a string literal is NOT a marker (OK)"
# F3: other engines' failure comments are detected (anchored as comments).
mk_marker_case F3a ' * Unable to fully structure code' 4 "b/B" "CFR block-comment failure text detected"
mk_marker_case F3b '    // This method has failed to decompile.  When submitting a bug report, please provide this class file' 4 "b/B" "CFR line-comment failure text detected"

# F4: a fallback whose OWN output is marked never reports result=ok.
rt F4 "$FAKE_CLASS" STUB_SLEEP_CLASSES="Test" STUB_MARKER_CLASSES="Test" STUB_CFR_MARKER=1 -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: Test reason=timeout fallback=cfr result=marked' <<<"$SO" && ! grep -q 'result=ok' <<<"$SO"; then
  ok "F4 fallback output itself marked → result=marked (not ok), still DEGRADED"
else no "F4 marked fallback output must not be result=ok" "rc=$RC so=[$SO]"; fi

# F5: SIGKILL (timeout --kill-after, rc 137) is reason=killed, distinct from a plain timeout.
rt F5 "$FAKE_CLASS" STUB_SLEEP_CLASSES="Test" STUB_IGNORE_TERM=1 RSDD_KILL_AFTER=1 -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: Test reason=killed' <<<"$SO"; then ok "F5 SIGTERM-ignoring engine killed (137) → reason=killed"
else no "F5 rc 137 → reason=killed" "rc=$RC so=[$SO]"; fi

# F6: total isolation budget exhausted → whole-artifact fallback with a typed reason.
rt F6 "$JAR3" STUB_SLEEP_CLASSES="A B C" RSDD_DECOMPILE_ISOLATE_BUDGET=1 -- --engine vineflower
if [ "$RC" -eq 4 ] && [ "$(units_of)" = "<whole-artifact>" ] && grep -q '^UNIT: <whole-artifact> reason=total_budget_exhausted fallback=cfr result=ok' <<<"$SO" \
  && [ "$(engine_of F6 a/A.java)" = cfr ] && [ "$(engine_of F6 c/C.java)" = cfr ]; then
  ok "F6 isolation budget exhausted → <whole-artifact> reason=total_budget_exhausted, cfr"
else no "F6 budget exhaustion is typed and falls back whole-artifact" "rc=$RC so=[$SO]"; fi
rt F6b "$JAR3" STUB_SLEEP_CLASSES="A B C" RSDD_DECOMPILE_ISOLATE_BUDGET=0 -- --engine vineflower
if [ "$(units_of)" = "a/A b/B c/C" ]; then ok "F6b budget 0 = unlimited → per-unit isolation as before"
else no "F6b budget 0 = unlimited" "so=[$SO]"; fi

# G: Vineflower comments that say the output is WRONG or will not compile are failures (fall back);
#    'Could not handle exception ranges with multiple entries' stays informational (decision).
mk_marker_case G1 '    // $VF: Accidentally destroyed if statement, the decompiled code is not correct!' 4 "b/B" "'decompiled code is not correct' → per-class fallback"
mk_marker_case G2 '    // $VF: Invalid label' 4 "b/B" "'Invalid label' → per-class fallback"
mk_marker_case G3 '    // $VF: Made invalid labels' 4 "b/B" "'Made invalid labels' → per-class fallback"
mk_marker_case G4 '    // $VF: Could not handle exception ranges with multiple entries' 0 "" "'exception ranges with multiple entries' stays primary (informational)"

# ── Issue #1320 items 3-4: coverage sweep on the success path, freshness of covered files ──
# H1: whole-jar run exits 0 but silently omits a class → never a bare OK (item 3).
rt H1 "$JARP" STUB_OMIT_CLASSES="A2" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED' <<<"$SO" && ! grep -q '^OK' <<<"$SO" \
  && grep -q '^UNIT: a/A2 reason=missing fallback=cfr result=ok' <<<"$SO" \
  && [ "$(engine_of H1 a/A2.java)" = cfr ] && [ "$(engine_of H1 a/A1.java)" = vineflower ]; then
  ok "H1 whole-jar success omitting a class → UNIT reason=missing, DEGRADED rc=4, never OK"
else no "H1 whole-jar success omitting a class → typed missing unit" "rc=$RC so=[$SO]"; fi
# H2: whole-jar run covering every unit class stays a bare OK (the sweep has no false positive).
rt H2 "$JARO" -- --engine vineflower
if [ "$RC" -eq 0 ] && grep -q '^OK' <<<"$SO"; then ok "H2 whole-jar success covering every unit (orphans incl.) → OK"
else no "H2 full coverage stays OK" "rc=$RC so=[$SO]"; fi
# H3: coverage sweep impossible (unzip absent) → typed degraded probe, never a silent OK.
rt H3 "$JARP" RSDD_UNZIP_BIN="$ROOT/no-such-unzip" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED.*reason=coverage-sweep-unavailable' <<<"$SO" && ! grep -q '^OK' <<<"$SO"; then
  ok "H3 unzip absent on a whole-jar success → DEGRADED reason=coverage-sweep-unavailable"
else no "H3 sweep unavailable is typed" "rc=$RC so=[$SO]"; fi
# H4: a STALE a/A2.java in a reused out-dir is not coverage (item 4) — failure path and success path.
RT_PRESEED="a/A2.java" rt H4a "$JARP" STUB_FAIL_WHOLE=1 STUB_OMIT_CLASSES="A2" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: a/A2 reason=missing' <<<"$SO" && [ "$(engine_of H4a a/A2.java)" = cfr ]; then
  ok "H4a stale file in reused out-dir does not hide an omitted class (failure path)"
else no "H4a stale file counted as coverage (failure path)" "rc=$RC so=[$SO]"; fi
RT_PRESEED="a/A2.java" rt H4b "$JARP" STUB_OMIT_CLASSES="A2" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: a/A2 reason=missing' <<<"$SO" && [ "$(engine_of H4b a/A2.java)" = cfr ]; then
  ok "H4b stale file in reused out-dir does not hide an omitted class (success path)"
else no "H4b stale file counted as coverage (success path)" "rc=$RC so=[$SO]"; fi

# ── Issue #1320 item 5: prefix-layout jars (output paths follow the package) ──
JARB="$ROOT/prefix.jar"; mkjar "$JARB" BOOT-INF/classes/a/A.class BOOT-INF/classes/b/B.class META-INF/versions/9/c/C.class
# I1: whole-jar success with package-relative output paths is full coverage, not three missing units.
rt I1 "$JARB" STUB_STRIP_LAYOUT=1 -- --engine vineflower
if [ "$RC" -eq 0 ] && grep -q '^OK' <<<"$SO"; then ok "I1 prefix-layout jar, package-relative output → OK (no false missing)"
else no "I1 prefix-layout whole-jar success" "rc=$RC so=[$SO]"; fi
# I2: failure path: every class recovered per package → no UNIT, never reason=missing.
rt I2 "$JARB" STUB_STRIP_LAYOUT=1 STUB_FAIL_WHOLE=1 -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^DEGRADED.*primary=error isolation=package' <<<"$SO" && [ -z "$(units_of)" ] \
  && [ "$(engine_of I2 a/A.java)" = vineflower ] && [ "$(engine_of I2 c/C.java)" = vineflower ]; then
  ok "I2 prefix-layout jar, failure path → classes recovered, no reason=missing units"
else no "I2 prefix-layout failure path" "rc=$RC so=[$SO]"; fi
# I3: a failure marker on a prefix-layout class still reaches the per-class fallback (class entry resolved).
rt I3 "$JARB" STUB_STRIP_LAYOUT=1 STUB_MARKER_CLASSES="B" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: b/B reason=marker fallback=cfr result=ok' <<<"$SO" && [ "$(engine_of I3 b/B.java)" = cfr ]; then
  ok "I3 prefix-layout marker → class entry found, cfr fallback"
else no "I3 prefix-layout marker fallback" "rc=$RC so=[$SO]"; fi
# I4: a class genuinely omitted from a prefix-layout jar is still caught (the normalization has no blind spot).
rt I4 "$JARB" STUB_STRIP_LAYOUT=1 STUB_OMIT_CLASSES="B" -- --engine vineflower
if [ "$RC" -eq 4 ] && grep -q '^UNIT: BOOT-INF/classes/b/B reason=missing fallback=cfr result=ok' <<<"$SO" && [ "$(engine_of I4 b/B.java)" = cfr ] \
  && [ "$(units_of)" = "BOOT-INF/classes/b/B" ]; then
  ok "I4 prefix-layout omitted class → UNIT reason=missing (only that one)"
else no "I4 prefix-layout omission is typed" "rc=$RC so=[$SO]"; fi
# I5: the fallback output of a missing prefix-layout unit is not re-handled by the marker scan (one unit, not two).
rt I5 "$JARB" STUB_STRIP_LAYOUT=1 STUB_OMIT_CLASSES="B" STUB_MARKER_CLASSES="B" STUB_CFR_MARKER=1 -- --engine vineflower
if [ "$RC" -eq 4 ] && [ "$(units_of)" = "BOOT-INF/classes/b/B" ] && grep -q 'reason=missing fallback=cfr result=marked' <<<"$SO"; then
  ok "I5 prefix-layout fallback output not re-scanned → exactly one unit"
else no "I5 prefix-layout handled-set uses the package-relative key" "rc=$RC so=[$SO]"; fi

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
  if build_mut mA2 's/^if \[ "\${#UNITS\[@\]}" -eq 0 \] && .*; then$/if true; then/'; then
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
  echo "-- teeth: review round 1 (primary state, orphans, empty, coverage) --"
  # mE1: primary state ignored → E1/E2/E3 print a bare OK again (B1).
  if build_mut mE1 's/ \&\& \[ -z "\$PRIMARY_STATE" \]; then$/; then/'; then
    RT_SUT="$MUT" rt mE1 "$JAR3" STUB_FAIL_WHOLE=1 -- --engine vineflower
    if grep -q '^OK' <<<"$SO"; then ok "teeth-mE1: primary-state-ignored mutant prints bare OK → E1 bites"
    else no "teeth-mE1: mutant still degraded — E1 has no teeth" "so=[$SO]"; fi
  fi
  # mE2: '$' classes never units → E6/E7 (B2a).
  if build_mut mE2 's/^    \*.\$.\*) o=.*$/    *"\$"*) return 1 ;;/'; then
    RT_SUT="$MUT" rt mE2 "$JARZ" STUB_SLEEP_CLASSES='Z$' -- --engine vineflower
    if [ -z "$(units_of)" ]; then ok "teeth-mE2: orphans-skipped mutant loses the Z\$ unit → E6 bites"
    else no "teeth-mE2: mutant still reported the orphan unit — E6 has no teeth" "so=[$SO]"; fi
  fi
  # mE3: empty package rerun dropped → E4/E5 (B2b).
  if build_mut mE3 's/^      bisect_package "\$pkg" "\$n" empty .*$/      :/'; then
    RT_SUT="$MUT" rt mE3 "$JARE" STUB_FAIL_WHOLE=1 STUB_EMPTY_MIN=1 -- --engine vineflower
    if ! grep -q 'reason=empty' <<<"$SO"; then ok "teeth-mE3: empty-dropped mutant loses reason=empty → E5 bites"
    else no "teeth-mE3: mutant still typed reason=empty — E5 has no teeth" "so=[$SO]"; fi
  fi
  # mE4: coverage sweep removed → E8.
  if build_mut mE4 's/ || fallback_unit "\$unit" missing "\$f"$/ || :/'; then
    RT_SUT="$MUT" rt mE4 "$JARP" STUB_FAIL_WHOLE=1 STUB_OMIT_CLASSES="A2" -- --engine vineflower
    if ! grep -q 'reason=missing' <<<"$SO"; then ok "teeth-mE4: sweep-removed mutant loses reason=missing → E8 bites"
    else no "teeth-mE4: mutant still reported the omitted class — E8 has no teeth" "so=[$SO]"; fi
  fi
  echo "-- teeth: review round 1 (marker precision, killed, marked fallback, budget) --"
  # mF1: broad '$VF:' anchor (pre-review behaviour) → informational comments flagged (F1).
  if build_mut mF1 's/^MARKER_RE=.*$/MARKER_RE=\x27^[[:space:]]*\/\/ \\$VF: \x27/'; then
    RT_SUT="$MUT" rt mF1 "$JAR3" STUB_MARKER_CLASSES="B" STUB_MARKER_TEXT='    // $VF: synthetic class' -- --engine vineflower
    if ! grep -q '^OK' <<<"$SO"; then ok "teeth-mF1: broad-anchor mutant flags 'synthetic class' → F1 bites"
    else no "teeth-mF1: mutant did not flag the informational comment — F1 has no teeth" "so=[$SO]"; fi
  fi
  # mF2: marked fallback output reported ok (F4).
  if build_mut mF2 's/if file_has_marker "\$mf"; then/if false; then/'; then
    RT_SUT="$MUT" rt mF2 "$FAKE_CLASS" STUB_SLEEP_CLASSES="Test" STUB_MARKER_CLASSES="Test" STUB_CFR_MARKER=1 -- --engine vineflower
    if grep -q 'result=ok' <<<"$SO"; then ok "teeth-mF2: no-marker-check mutant reports a marked fallback as ok → F4 bites"
    else no "teeth-mF2: mutant still said result=marked — F4 has no teeth" "so=[$SO]"; fi
  fi
  # mF3: 137 conflated with timeout (F5).
  if build_mut mF3 's/\[ "\$1" -eq 137 \]; then echo killed/[ "$1" -eq 0 ]; then echo killed/'; then
    RT_SUT="$MUT" rt mF3 "$FAKE_CLASS" STUB_SLEEP_CLASSES="Test" STUB_IGNORE_TERM=1 RSDD_KILL_AFTER=1 -- --engine vineflower
    if ! grep -q 'reason=killed' <<<"$SO"; then ok "teeth-mF3: killed-removed mutant loses reason=killed → F5 bites"
    else no "teeth-mF3: mutant still typed killed — F5 has no teeth" "so=[$SO]"; fi
  fi
  # mF4: budget never checked (F6).
  if build_mut mF4 's/^budget_exhausted() .*$/budget_exhausted() { return 1; }/'; then
    RT_SUT="$MUT" rt mF4 "$JAR3" STUB_SLEEP_CLASSES="A B C" RSDD_DECOMPILE_ISOLATE_BUDGET=1 -- --engine vineflower
    if ! grep -q 'total_budget_exhausted' <<<"$SO"; then ok "teeth-mF4: budget-ignored mutant never exhausts → F6 bites"
    else no "teeth-mF4: mutant still hit the budget — F6 has no teeth" "so=[$SO]"; fi
  fi
  # mG1: drop the 'decompiled code is not correct' alternative → G1 prints a bare OK again.
  if build_mut mG1 's/|\[^!\]\*decompiled code is not correct//'; then
    RT_SUT="$MUT" rt mG1 "$JAR3" STUB_MARKER_CLASSES="B" STUB_MARKER_TEXT='    // $VF: Accidentally destroyed if statement, the decompiled code is not correct!' -- --engine vineflower
    if grep -q '^OK' <<<"$SO"; then ok "teeth-mG1: alternative-dropped mutant prints bare OK for wrong code → G1 bites"
    else no "teeth-mG1: mutant still flagged the wrong-code comment — G1 has no teeth" "so=[$SO]"; fi
  fi
  echo "-- teeth: slice C (marker scan) --"
  # mC1: column-0 anchor (the #1194 bug) → indented marker missed.
  if build_mut mC1 's/^MARKER_RE=.\^\[\[:space:\]\]\*/MARKER_RE=\x27^/'; then
    RT_SUT="$MUT" rt mC1 "$JAR3" STUB_MARKER_CLASSES="B" -- --engine vineflower
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
  if build_mut mB1 's/^    irc=0; isolate_jar .. irc=\$?$/    irc=1/'; then
    RT_SUT="$MUT" rt mB1 "$JAR3" STUB_SLEEP_CLASSES="A" -- --engine vineflower
    if grep -q '^UNIT: <whole-artifact>' <<<"$SO" && [ "$(engine_of mB1 b/B.java)" = cfr ]; then
      ok "teeth-mB1: no-isolation mutant degrades the whole artifact → B1 bites"
    else no "teeth-mB1: no-isolation mutant still isolated — B1 has no teeth" "so=[$SO]"; fi
  fi
  # mB2: class-level bisect removed → every class in the failing package falls back (B7).
  if build_mut mB2 's/^    if \[ "\${#outer\[@\]}" -eq 1 \] \&\& \[ "\$reason" != empty \]; then fallback_unit/    if true; then fallback_unit/'; then
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
  echo "-- teeth: issue #1320 items 3-4 (success-path sweep, stale files) --"
  # mH1: no sweep after a whole-jar success → H1 prints a bare OK again (item 3).
  if build_mut mH1 's/^  if ensure_ext; then sweep_coverage$/  if ensure_ext; then :/'; then
    RT_SUT="$MUT" rt mH1 "$JARP" STUB_OMIT_CLASSES="A2" -- --engine vineflower
    if grep -q '^OK' <<<"$SO"; then ok "teeth-mH1: no-success-sweep mutant prints bare OK for an omitted class → H1 bites"
    else no "teeth-mH1: mutant still swept — H1 has no teeth" "so=[$SO]"; fi
  fi
  # mH2: sweep-unavailable probe dropped → H3 goes back to a silent OK.
  if build_mut mH2 's/^  else PROBE_DEGRADED=.*coverage-sweep-unavailable"; fi$/  else :; fi/'; then
    RT_SUT="$MUT" rt mH2 "$JARP" RSDD_UNZIP_BIN="$ROOT/no-such-unzip" -- --engine vineflower
    if grep -q '^OK' <<<"$SO"; then ok "teeth-mH2: probe-dropped mutant prints OK without a sweep → H3 bites"
    else no "teeth-mH2: mutant still typed the missing sweep — H3 has no teeth" "so=[$SO]"; fi
  fi
  # mH3: any present file counts as coverage (pre-#1320 behaviour) → H4 stale file hides the omission.
  if build_mut mH3 's/ -nt "\$STAMP" \]/ -nt "$STAMP" -o 1 -eq 1 ]/g'; then
    RT_SUT="$MUT" RT_PRESEED="a/A2.java" rt mH3 "$JARP" STUB_FAIL_WHOLE=1 STUB_OMIT_CLASSES="A2" -- --engine vineflower
    if ! grep -q 'reason=missing' <<<"$SO"; then ok "teeth-mH3: freshness-dropped mutant treats a stale file as coverage → H4 bites"
    else no "teeth-mH3: mutant still saw the stale file as missing — H4 has no teeth" "so=[$SO]"; fi
  fi
  echo "-- teeth: issue #1320 item 5 (prefix-layout jars) --"
  # mI1: no layout normalization → I1 reports three false missing units.
  if build_mut mI1 's/^layout_key() {$/layout_key() { printf "%s\\n" "$1"; return 0/'; then
    RT_SUT="$MUT" rt mI1 "$JARB" STUB_STRIP_LAYOUT=1 -- --engine vineflower
    if ! grep -q '^OK' <<<"$SO"; then ok "teeth-mI1: identity-key mutant reports false missing units → I1 bites"
    else no "teeth-mI1: mutant still printed OK — I1 has no teeth" "so=[$SO]"; fi
  fi
  # mI2: class lookup without prefix candidates → I3 loses the per-class marker fallback.
  if build_mut mI2 's/ "\$EXT\/BOOT-INF\/classes\/\$u.class" "\$EXT\/WEB-INF\/classes\/\$u.class" "\$EXT"\/META-INF\/versions\/\*\/"\$u.class"//'; then
    RT_SUT="$MUT" rt mI2 "$JARB" STUB_STRIP_LAYOUT=1 STUB_MARKER_CLASSES="B" -- --engine vineflower
    if ! grep -q 'reason=marker fallback=cfr' <<<"$SO"; then ok "teeth-mI2: prefix-blind class lookup loses the marker fallback → I3 bites"
    else no "teeth-mI2: mutant still resolved the prefixed class — I3 has no teeth" "so=[$SO]"; fi
  fi
  # mI3: handled-set keyed on the raw unit name → I5 re-scans the fallback output as a second unit.
  if build_mut mI3 's/^  HANDLED\[.*\]=1$/  HANDLED["$1"]=1/'; then
    RT_SUT="$MUT" rt mI3 "$JARB" STUB_STRIP_LAYOUT=1 STUB_OMIT_CLASSES="B" STUB_MARKER_CLASSES="B" STUB_CFR_MARKER=1 -- --engine vineflower
    if [ "$(units_of)" != "BOOT-INF/classes/b/B" ]; then ok "teeth-mI3: raw-key mutant double-handles the unit → I5 bites"
    else no "teeth-mI3: mutant still reported one unit — I5 has no teeth" "so=[$SO]"; fi
  fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
