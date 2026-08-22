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
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
