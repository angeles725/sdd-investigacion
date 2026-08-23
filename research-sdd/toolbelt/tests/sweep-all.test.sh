#!/usr/bin/env bash
# sweep-all.test.sh — RED-first harness for sweep-all.sh (U-A20).
#
# Assertions (in order):
#   1. sweep-all.sh exists on disk
#   2. sweep-all.sh is executable
#   3. All-pass: all 6 stubs exit 0 → sweep-all exits 0
#   4. One-fail: one stub exits 1 → sweep-all exits non-zero
#   5. Run-all: even when one stub fails, all 6 stubs are called (no early bail)
#   6. Banners: PASS banner for passing script; FAIL banner for failing script
#   7. Timeout: a hanging stub is killed after timeout → sweep-all exits non-zero
#   8. Timeout-banner: the FAIL banner includes a timeout indication for the killed script
#
# All behavioral tests (3-8) are implemented by copying sweep-all.sh into a temp dir
# alongside stub replacements of the six canonical scripts, so sweep-all.sh's own
# TOOLBELT=$(dirname $0) resolution finds the stubs rather than the real scripts.
#
# Usage: sweep-all.test.sh
# Exit : 0 all held · 1 regression · 2 harness error

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"
SUT="$TOOLBELT/sweep-all.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== sweep-all.test.sh =="

# ---- 1. Existence ----------------------------------------------------------
[ -f "$SUT" ] \
  && ok "1 sweep-all.sh exists at $SUT" \
  || no "1 sweep-all.sh NOT found at $SUT"

# ---- 2. Executable ---------------------------------------------------------
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 sweep-all.sh is executable" \
  || no "2 sweep-all.sh is NOT executable (missing +x bit)"

# ---- Bail early if SUT is missing: behavioral tests need it ----------------
if [ ! -f "$SUT" ]; then
  for n in 3 4 5 6 7 8; do
    no "$n (skipped: sweep-all.sh missing — cannot test behavior)"
  done
  echo "== $pass passed · $fail failed =="
  exit 1
fi

# ---- Temp workspace --------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/toolbelt"
mkdir -p "$FAKE"
cp "$SUT" "$FAKE/sweep-all.sh"
chmod +x "$FAKE/sweep-all.sh"

CANONICAL=(sweep-retros.sh sweep-audits.sh sweep-breakthroughs.sh verify-registry.sh verify-kit-clean.sh sweep-tools.sh)

# make_stub <name> <exit_code> — write a stub script that logs its name then exits
make_stub() {
  local name="$1" rc="${2:-0}"
  printf '#!/usr/bin/env bash\necho "stub:%s"\nexit %s\n' "$name" "$rc" > "$FAKE/$name"
  chmod +x "$FAKE/$name"
}

# make_logging_stub <name> <exit_code> <log_file> — stub that logs call to a file
make_logging_stub() {
  local name="$1" rc="$2" log="$3"
  printf '#!/usr/bin/env bash\necho "%s" >> %s\necho "stub:%s"\nexit %s\n' \
    "$name" "$log" "$name" "$rc" > "$FAKE/$name"
  chmod +x "$FAKE/$name"
}

# make_hanging_stub <name> <log_file> — stub that logs its name then sleeps forever
make_hanging_stub() {
  local name="$1" log="$2"
  printf '#!/usr/bin/env bash\necho "%s" >> %s\necho "stub:%s hanging"\nsleep 9999\n' \
    "$name" "$log" "$name" > "$FAKE/$name"
  chmod +x "$FAKE/$name"
}

# ---- 3. All-pass → exit 0 --------------------------------------------------
for s in "${CANONICAL[@]}"; do make_stub "$s" 0; done
OUT="$(bash "$FAKE/sweep-all.sh" 2>&1)"; RC=$?
[ "$RC" -eq 0 ] \
  && ok "3 all-pass: all 6 stubs pass → sweep-all exits 0" \
  || no "3 all-pass: expected exit 0 got $RC (out=[$OUT])"

# ---- 4. One-fail → exit non-zero ------------------------------------------
for s in "${CANONICAL[@]}"; do make_stub "$s" 0; done
make_stub "sweep-audits.sh" 1   # override one to fail
OUT="$(bash "$FAKE/sweep-all.sh" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] \
  && ok "4 one-fail: sweep-audits.sh exits 1 → sweep-all exits non-zero (rc=$RC)" \
  || no "4 one-fail: expected non-zero exit, got 0 (out=[$OUT])"

# ---- 5. Run-all: all 4 called even when one fails --------------------------
CALL_LOG="$TMP/call5.log"; rm -f "$CALL_LOG"
for s in "${CANONICAL[@]}"; do
  make_logging_stub "$s" 0 "$CALL_LOG"
done
# Override sweep-audits.sh to fail (still log its call first)
make_logging_stub "sweep-audits.sh" 1 "$CALL_LOG"
OUT="$(bash "$FAKE/sweep-all.sh" 2>&1)"; RC=$?
called_count="$(grep -c '^' "$CALL_LOG" 2>/dev/null || echo 0)"
[ "$called_count" -eq 6 ] && [ "$RC" -ne 0 ] \
  && ok "5 run-all: all 6 stubs called despite failure (calls=$called_count, rc=$RC)" \
  || no "5 run-all: expected calls=6 rc!=0, got calls=$called_count rc=$RC (out=[$OUT])"

# ---- 6. PASS/FAIL banners per script ---------------------------------------
for s in "${CANONICAL[@]}"; do make_stub "$s" 0; done
make_stub "sweep-retros.sh" 1   # retros fails; others pass
OUT="$(bash "$FAKE/sweep-all.sh" 2>&1)"
pass_banner=0; fail_banner=0
printf '%s\n' "$OUT" | grep -qiE 'PASS.*sweep-audits' && pass_banner=1
printf '%s\n' "$OUT" | grep -qiE 'FAIL.*sweep-retros' && fail_banner=1
[ "$pass_banner" -eq 1 ] && [ "$fail_banner" -eq 1 ] \
  && ok "6 banners: PASS for passing scripts, FAIL for failing scripts" \
  || no "6 banners: expected PASS(sweep-audits) and FAIL(sweep-retros) in output (out=[$OUT])"

# ---- 7. Timeout → exits non-zero after short timeout ----------------------
CALL_LOG7="$TMP/call7.log"; rm -f "$CALL_LOG7"
for s in "${CANONICAL[@]}"; do
  make_logging_stub "$s" 0 "$CALL_LOG7"
done
# Override sweep-audits.sh (second script) to hang after logging its call
make_hanging_stub "sweep-audits.sh" "$CALL_LOG7"
# Use a 1-second timeout so the test completes quickly
OUT="$(RSDD_SWEEP_TIMEOUT=1 bash "$FAKE/sweep-all.sh" 2>&1)"; RC=$?
[ "$RC" -ne 0 ] \
  && ok "7 timeout: hanging stub killed → sweep-all exits non-zero (rc=$RC)" \
  || no "7 timeout: expected non-zero exit after timeout, got 0"

# ---- 8. Timeout banner includes timeout indication -------------------------
printf '%s\n' "$OUT" | grep -qiE 'FAIL.*sweep-audits.*(timeout|timed)' \
  && ok "8 timeout-banner: FAIL banner mentions timeout for killed script" \
  || no "8 timeout-banner: expected FAIL+timeout indication (out=[$OUT])"

# ---- Teeth: prove run-all invariant catches a dropped script ----------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: early-bail mutant must be caught by run-all assertion --"
  CALL_LOG_T="$TMP/callT.log"; rm -f "$CALL_LOG_T"
  for s in "${CANONICAL[@]}"; do make_logging_stub "$s" 0 "$CALL_LOG_T"; done
  # Mutant sweep-all.sh: exits immediately after first script passes (dropping the other 4).
  sed '/^for script/a\\  break' "$FAKE/sweep-all.sh" > "$TMP/mutant-sweep-all.sh"
  chmod +x "$TMP/mutant-sweep-all.sh"
  bash "$TMP/mutant-sweep-all.sh" > /dev/null 2>&1 || true
  mutant_calls="$(grep -c '^' "$CALL_LOG_T" 2>/dev/null || echo 0)"
  if [ "$mutant_calls" -lt 6 ]; then
    ok "teeth: early-bail mutant calls $mutant_calls < 6 → run-all check would catch it (RED)"
  else
    no "teeth: mutant called $mutant_calls scripts — run-all check is THEATER"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
