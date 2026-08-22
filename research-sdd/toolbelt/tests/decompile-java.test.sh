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
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
