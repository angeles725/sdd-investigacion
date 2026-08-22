#!/usr/bin/env bash
# detect-tools.test.sh — contract for detect-tools.sh --require gate.
#
# Covers the three-state discipline (§7):
#   MISSING      — tool genuinely absent → --require fails loud, names tool
#   UNUSABLE     — found but smoke test failed → --require fails loud (distinct message)
#   PROBE_FAILED — probe could not run (timeout/127) → --require fails as "could not determine"
#                  and must NOT be classified as a clean MISSING
#
# Tests: (a) no --require → exit 0 unchanged; (b) --require present → exit 0;
#        (c) --require absent → non-zero + loud stderr naming tool;
#        (d) probe-failed → non-zero + "could not determine" + NOT MISSING in report;
#        (e) unknown tool name → exit 2.
#
# Usage: detect-tools.test.sh [--prove-teeth]
# Exit:  0 = all pass · 1 = regression · 2 = harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DETECT="$HERE/../detect-tools.sh"
[ -f "$DETECT" ] || { echo "FATAL: script under test not found: $DETECT" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

mkexec() {
  local p="$1" body="$2"
  mkdir -p "$(dirname "$p")"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$p"
  chmod +x "$p"
}

echo "== detect-tools.test.sh =="

# Hermetic env: redirect HOME and BREW so no real host tools are discovered.
FAKE_HOME="$ROOT/home"
FAKE_BREW="$ROOT/brew"
mkdir -p "$FAKE_HOME"

# a — no --require: exit 0, cache written (default behavior byte-for-byte unchanged)
CACHE_A="$ROOT/cache-a.txt"
rc_a=0
HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_A" --quiet >/dev/null 2>&1 || rc_a=$?
if [ "$rc_a" -eq 0 ] && [ -f "$CACHE_A" ]; then
  ok "a no --require: exits 0 and writes cache" "(rc=$rc_a)"
else
  no "a no --require: exits 0 and writes cache" \
     "rc=$rc_a cache=$([ -f "$CACHE_A" ] && echo exists || echo missing)"
fi

# b — --require <present tool>: exit 0 when tool is AVAILABLE
BIN_B="$ROOT/bin-b"; mkdir -p "$BIN_B"
mkexec "$BIN_B/objdump" 'echo objdump-fake-2.39; exit 0'
CACHE_B="$ROOT/cache-b.txt"
rc_b=0
PATH="$BIN_B:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_B" --quiet --require objdump >/dev/null 2>&1 || rc_b=$?
if [ "$rc_b" -eq 0 ]; then
  ok "b --require present tool: exits 0" "(rc=$rc_b)"
else
  no "b --require present tool: exits 0" \
     "rc=$rc_b $(grep -E 'objdump' "$CACHE_B" 2>/dev/null | head -1 || true)"
fi

# c — --require <absent tool>: non-zero + loud stderr naming the tool.
# Ghidra needs GHIDRA_HOME / analyzeHeadless / /opt/ghidra* — all absent in this env.
CACHE_C="$ROOT/cache-c.txt"
stderr_c="$ROOT/stderr-c.txt"
rc_c=0
env -u ANALYZE_HEADLESS -u GHIDRA_HOME -u GHIDRA_INSTALL_DIR \
  HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_C" --quiet --require ghidra >/dev/null 2>"$stderr_c" || rc_c=$?
# Assert MISSING explicitly: on a host where ghidra half-resolves (UNUSABLE) or
# fully resolves (AVAILABLE), this fails LOUD instead of silently passing on the
# wrong branch or eroding coverage of the MISSING path this case documents.
if [ "$rc_c" -ne 0 ] && grep -qi 'ghidra' "$stderr_c" && grep -q 'MISSING' "$stderr_c"; then
  ok "c --require absent tool: non-zero + stderr names tool" "(rc=$rc_c)"
else
  no "c --require absent tool: non-zero + stderr names tool" \
     "rc=$rc_c stderr=[$(cat "$stderr_c" 2>/dev/null)]"
fi

# d — probe-failed: non-zero + "could not determine" in stderr + NOT MISSING in report.
# Stub objdump to sleep longer than RSDD_PROBE_TIMEOUT; timeout returns 124 (probe killed).
# The critical three-state check: timed-out probe must NOT read as a clean MISSING.
BIN_D="$ROOT/bin-d"; mkdir -p "$BIN_D"
mkexec "$BIN_D/objdump" 'sleep 5'   # killed by timeout at 0.1 s → exit 124 from timeout
CACHE_D="$ROOT/cache-d.txt"
stderr_d="$ROOT/stderr-d.txt"
rc_d=0
RSDD_PROBE_TIMEOUT=0.1 PATH="$BIN_D:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_D" --quiet --require objdump >/dev/null 2>"$stderr_d" || rc_d=$?
report_d="$(cat "$CACHE_D" 2>/dev/null || true)"
objdump_line="$(printf '%s\n' "$report_d" | grep -E 'objdump' | head -1 || true)"
if [ "$rc_d" -ne 0 ] \
   && grep -qi 'could not determine' "$stderr_d" \
   && ! printf '%s\n' "$objdump_line" | grep -q 'MISSING'; then
  ok "d probe-failed: non-zero + could-not-determine + not MISSING" "(rc=$rc_d)"
else
  no "d probe-failed: non-zero + could-not-determine + not MISSING" \
     "rc=$rc_d msg=[$(cat "$stderr_d" 2>/dev/null)] line=[$objdump_line]"
fi

# e — unknown tool name → exit 2 (usage error, like existing invalid-arg path)
rc_e=0
HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$ROOT/cache-e.txt" --quiet \
  --require nonexistent-xyz-tool 2>/dev/null >/dev/null || rc_e=$?
if [ "$rc_e" -eq 2 ]; then
  ok "e unknown tool name: exit 2" "(rc=$rc_e)"
else
  no "e unknown tool name: exit 2" "rc=$rc_e"
fi

# f — python_row probe-failed: marker_single found but probe times out → PROBE_FAILED + "could not determine"
# RSDD_PYTHON_PROBE_TIMEOUT overrides the python-specific probe timeout (default 20 s).
BIN_F="$ROOT/bin-f"; mkdir -p "$BIN_F"
mkexec "$BIN_F/marker_single" 'sleep 5'   # killed by timeout at 0.1 s → exit 124
CACHE_F="$ROOT/cache-f.txt"
stderr_f="$ROOT/stderr-f.txt"
rc_f=0
RSDD_PROBE_TIMEOUT=0.1 RSDD_PYTHON_PROBE_TIMEOUT=0.1 \
  PATH="$BIN_F:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_F" --quiet --require marker >/dev/null 2>"$stderr_f" || rc_f=$?
report_f="$(cat "$CACHE_F" 2>/dev/null || true)"
marker_line="$(printf '%s\n' "$report_f" | grep -F '  marker ' | head -1 || true)"
if [ "$rc_f" -ne 0 ] \
   && grep -qi 'could not determine' "$stderr_f" \
   && printf '%s\n' "$marker_line" | grep -q 'PROBE_FAILED'; then
  ok "f python_row probe-failed: non-zero + could-not-determine + PROBE_FAILED" "(rc=$rc_f)"
else
  no "f python_row probe-failed: non-zero + could-not-determine + PROBE_FAILED" \
     "rc=$rc_f msg=[$(cat "$stderr_f" 2>/dev/null)] line=[$marker_line]"
fi

# g — jarrow probe-failed: vineflower jar found, unzip absent → rc 127 → PROBE_FAILED + "could not determine"
# PATH is restricted to $BIN_G (has timeout, grep, head via symlinks; no unzip) so command -v
# unzip returns empty. rsdd_probe_java_jar then returns 127, which jarrow must classify as
# PROBE_FAILED, not UNUSABLE.  Symlinks avoid the #!/usr/bin/env bash lookup when PATH lacks bash.
BIN_G="$ROOT/bin-g"; mkdir -p "$BIN_G"
ln -sf /usr/bin/dirname "$BIN_G/dirname"   # needed so detect-tools.sh can set HERE and source tool-env.sh
ln -sf /usr/bin/timeout "$BIN_G/timeout"   # needed by rsdd_run_probe / rsdd_capture_probe
ln -sf /usr/bin/grep "$BIN_G/grep"         # needed by --require gate (grep -F / -oE)
ln -sf /usr/bin/head "$BIN_G/head"         # needed by --require gate (head -1)
ln -sf /usr/bin/date "$BIN_G/date"         # avoids noisy date-not-found in $stderr_g
printf 'FAKE-JAR-CONTENT\n' > "$ROOT/fake-vineflower.jar"
CACHE_G="$ROOT/cache-g.txt"
stderr_g="$ROOT/stderr-g.txt"
rc_g=0
VINEFLOWER_JAR="$ROOT/fake-vineflower.jar" \
  PATH="$BIN_G" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  /bin/bash "$DETECT" --cache "$CACHE_G" --quiet --require vineflower >/dev/null 2>"$stderr_g" || rc_g=$?
report_g="$(cat "$CACHE_G" 2>/dev/null || true)"
vineflower_line="$(printf '%s\n' "$report_g" | grep -F 'Vineflower' | head -1 || true)"
if [ "$rc_g" -ne 0 ] \
   && grep -qi 'could not determine' "$stderr_g" \
   && printf '%s\n' "$vineflower_line" | grep -q 'PROBE_FAILED'; then
  ok "g jarrow probe-failed (unzip absent rc 127): non-zero + could-not-determine + PROBE_FAILED" "(rc=$rc_g)"
else
  no "g jarrow probe-failed (unzip absent rc 127): non-zero + could-not-determine + PROBE_FAILED" \
     "rc=$rc_g msg=[$(cat "$stderr_g" 2>/dev/null)] line=[$vineflower_line]"
fi

# h — Java secondary probe: rsdd_resolve_java_home is force-failed via SHIM so detect-tools.sh
# takes the secondary-probe branch.  A fake java in BIN_H sleeps longer than RSDD_PROBE_TIMEOUT
# → rsdd_run_probe returns 124 → Java 21 row must show PROBE_FAILED, not MISSING.
#
# SHIM technique: a fake lib/tool-env.sh sources the real library then redefines
# rsdd_resolve_java_home() { return 1; }.  detect-tools.sh resolves HERE via
# BASH_SOURCE[0] which points to the symlink inside SHIM_H, so it sources the shim lib.
BIN_H="$ROOT/bin-h"; mkdir -p "$BIN_H"
ln -sf /bin/bash          "$BIN_H/bash"     # env bash → resolves via BIN_H for mkexec stubs
ln -sf /usr/bin/dirname   "$BIN_H/dirname"  # detect-tools.sh HERE computation
ln -sf /usr/bin/timeout   "$BIN_H/timeout"  # rsdd_run_probe
ln -sf /usr/bin/grep      "$BIN_H/grep"     # --require gate
ln -sf /usr/bin/head      "$BIN_H/head"     # --require gate
ln -sf /usr/bin/date      "$BIN_H/date"     # report header date
ln -sf /usr/bin/sleep     "$BIN_H/sleep"    # fake java stub body
mkexec "$BIN_H/java" 'sleep 5'             # killed by timeout at 0.1 s → rc 124

SHIM_H="$ROOT/shim-h"
mkdir -p "$SHIM_H/lib"
# Build shim lib/tool-env.sh: source real library then override rsdd_resolve_java_home.
REAL_TOOL_ENV="$HERE/../lib/tool-env.sh"
printf '. "%s"\nrsdd_resolve_java_home() { return 1; }\n' \
  "$REAL_TOOL_ENV" > "$SHIM_H/lib/tool-env.sh"
# Symlink detect-tools.sh into SHIM_H so BASH_SOURCE[0] → SHIM_H → HERE=SHIM_H.
ln -sf "$DETECT" "$SHIM_H/detect-tools.sh"

CACHE_H="$ROOT/cache-h.txt"
stderr_h="$ROOT/stderr-h.txt"
rc_h=0
RSDD_PROBE_TIMEOUT=0.1 \
  PATH="$BIN_H" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  /bin/bash "$SHIM_H/detect-tools.sh" \
  --cache "$CACHE_H" --quiet --require java >/dev/null 2>"$stderr_h" || rc_h=$?
report_h="$(cat "$CACHE_H" 2>/dev/null || true)"
java_line_h="$(printf '%s\n' "$report_h" | grep -F 'Java 21' | head -1 || true)"
if [ "$rc_h" -ne 0 ] \
   && grep -qi 'could not determine' "$stderr_h" \
   && printf '%s\n' "$java_line_h" | grep -q 'PROBE_FAILED'; then
  ok "h Java secondary probe: shim+sleeping java → PROBE_FAILED" "(rc=$rc_h)"
else
  no "h Java secondary probe: shim+sleeping java → PROBE_FAILED" \
     "rc=$rc_h msg=[$(cat "$stderr_h" 2>/dev/null)] line=[$java_line_h]"
fi

# ── Prove-teeth (--prove-teeth) ──────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls --"

  # teeth-1 (targets test c): mutant forces gate_rc=0 for absent tools.
  # A gate_rc that never goes to 1 has no bite for MISSING/UNUSABLE cases.
  # Verify: mutant exits 0 for absent ghidra → test-c assertion [ rc -ne 0 ] would FAIL.
  MUT1="$ROOT/detect-mut1.sh"
  sed 's/gate_rc=1/gate_rc=0/g' "$DETECT" > "$MUT1"
  chmod +x "$MUT1"
  rc_m1=0
  env -u ANALYZE_HEADLESS -u GHIDRA_HOME -u GHIDRA_INSTALL_DIR \
    HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUT1" --cache "$ROOT/cache-m1.txt" --quiet --require ghidra \
    >/dev/null 2>/dev/null || rc_m1=$?
  if [ "$rc_m1" -eq 0 ]; then
    ok "teeth-1: gate_rc=0 mutant exits 0 for absent tool — test-c bites" "(mutant rc=0)"
  else
    no "teeth-1: mutant must exit 0 for absent tool" "mutant rc=$rc_m1"
  fi

  # teeth-2 (targets test d): mutant replaces PROBE_FAILED with MISSING everywhere.
  # Timed-out objdump → report says MISSING → --require evaluates as MISSING → prints
  # "MISSING — install it" (not "could not determine") → test-d stderr check goes RED.
  MUT2="$ROOT/detect-mut2.sh"
  sed 's/PROBE_FAILED/MISSING/g' "$DETECT" > "$MUT2"
  chmod +x "$MUT2"
  stderr_m2="$ROOT/stderr-m2.txt"
  RSDD_PROBE_TIMEOUT=0.1 PATH="$BIN_D:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUT2" --cache "$ROOT/cache-m2.txt" --quiet --require objdump \
    >/dev/null 2>"$stderr_m2" || true
  if ! grep -qi 'could not determine' "$stderr_m2"; then
    ok "teeth-2: PROBE_FAILED→MISSING mutant lacks 'could not determine' — test-d bites" \
       "(message absent)"
  else
    no "teeth-2: mutant must not have 'could not determine'" \
       "stderr=[$(cat "$stderr_m2" 2>/dev/null)]"
  fi

  # teeth-3 (targets test f): MUT2 (PROBE_FAILED→MISSING globally) run against test-f setup.
  # python_row timeout → mutant prints MISSING, not PROBE_FAILED → test-f assertion bites.
  RSDD_PROBE_TIMEOUT=0.1 RSDD_PYTHON_PROBE_TIMEOUT=0.1 \
    PATH="$BIN_F:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUT2" --cache "$ROOT/cache-m2f.txt" --quiet \
    >/dev/null 2>/dev/null || true
  marker_line_m2f="$(cat "$ROOT/cache-m2f.txt" 2>/dev/null | grep -F '  marker ' | head -1 || true)"
  if ! printf '%s\n' "$marker_line_m2f" | grep -q 'PROBE_FAILED'; then
    ok "teeth-3: PROBE_FAILED→MISSING mutant: marker timeout shows MISSING — test-f bites" \
       "(PROBE_FAILED absent from report)"
  else
    no "teeth-3: mutant must NOT emit PROBE_FAILED for marker timeout" \
       "line=[$marker_line_m2f]"
  fi

  # teeth-4 (targets test g): MUT2 run against test-g setup (vineflower jar, unzip absent).
  # jarrow rc 127 → mutant prints MISSING, not PROBE_FAILED → test-g assertion bites.
  VINEFLOWER_JAR="$ROOT/fake-vineflower.jar" \
    PATH="$BIN_G" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    /bin/bash "$MUT2" --cache "$ROOT/cache-m2g.txt" --quiet \
    >/dev/null 2>/dev/null || true
  vineflower_line_m2g="$(cat "$ROOT/cache-m2g.txt" 2>/dev/null | grep -F 'Vineflower' | head -1 || true)"
  if ! printf '%s\n' "$vineflower_line_m2g" | grep -q 'PROBE_FAILED'; then
    ok "teeth-4: PROBE_FAILED→MISSING mutant: vineflower 127 shows MISSING — test-g bites" \
       "(PROBE_FAILED absent from report)"
  else
    no "teeth-4: mutant must NOT emit PROBE_FAILED for vineflower 127" \
       "line=[$vineflower_line_m2g]"
  fi

  # teeth-h (targets test h): MUT2 (PROBE_FAILED→MISSING) run via same SHIM + BIN_H.
  # rsdd_resolve_java_home=1 → secondary probe → sleeping java timeout → mutant prints
  # MISSING instead of PROBE_FAILED → Java 21 line has no PROBE_FAILED → test-h bites.
  SHIM_H_MUT="$ROOT/shim-h-mut"
  mkdir -p "$SHIM_H_MUT/lib"
  printf '. "%s"\nrsdd_resolve_java_home() { return 1; }\n' \
    "$REAL_TOOL_ENV" > "$SHIM_H_MUT/lib/tool-env.sh"
  ln -sf "$MUT2" "$SHIM_H_MUT/detect-tools.sh"

  RSDD_PROBE_TIMEOUT=0.1 \
    PATH="$BIN_H" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    /bin/bash "$SHIM_H_MUT/detect-tools.sh" \
    --cache "$ROOT/cache-mh.txt" --quiet \
    >/dev/null 2>/dev/null || true
  java_line_mh="$(cat "$ROOT/cache-mh.txt" 2>/dev/null | grep -F 'Java 21' | head -1 || true)"
  if ! printf '%s\n' "$java_line_mh" | grep -q 'PROBE_FAILED'; then
    ok "teeth-h: PROBE_FAILED→MISSING mutant: Java secondary probe shows MISSING — test-h bites" \
       "(PROBE_FAILED absent from report)"
  else
    no "teeth-h: mutant must NOT emit PROBE_FAILED for Java secondary probe timeout" \
       "line=[$java_line_mh]"
  fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
