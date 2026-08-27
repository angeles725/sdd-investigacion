#!/usr/bin/env bash
# sweep-retros-hook.test.sh — red-first harness for sweep-retros-hook.sh.
# Covers: existence, executable, operational-failure banner, success header, mutation proof.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-retros-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== sweep-retros-hook.test.sh =="

# 1. Existence
[ -f "$SUT" ] \
  && ok "1 hook exists at $SUT" \
  || no "1 hook NOT found at $SUT"

# 2. Executable
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 hook is executable" \
  || no "2 hook NOT executable (missing +x bit)"

if [ ! -f "$SUT" ]; then
  for n in 3 4; do no "$n (skipped: hook missing)"; done
  echo "== $pass passed · $fail failed =="; exit 2
fi

# ---- Temp workspace ---------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# write_stub <exit_code> <output_text> — creates TMP/sweep-retros.sh + refreshes hook copy.
write_stub() {
  local rc="$1" txt="$2"
  printf '%s\n' "$txt" > "$TMP/stub-out.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit %s\n' "$TMP/stub-out.txt" "$rc" \
    > "$TMP/sweep-retros.sh"
  chmod +x "$TMP/sweep-retros.sh"
  cp "$SUT" "$TMP/sweep-retros-hook.sh"
  chmod +x "$TMP/sweep-retros-hook.sh"
}

# 3. Operational failure (sweep exits non-zero) → "could not run" banner, NOT normal header.
write_stub 1 "sweep-retros: cannot find TARGETS.md"
OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'could not run\|error\|exit 1' \
  && ok "3 sweep failure (rc=1) → operational-failure banner emitted" \
  || no "3 sweep failure → expected 'could not run' banner (exit=$RC out=[$OUT])"

# 4. Success (sweep exits 0) → normal header present in output.
write_stub 0 "TARGET  demo  · 0 open retros"
OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'retro sweep\|§18' \
  && ok "4 success (rc=0) → normal retro header emitted" \
  || no "4 success → expected normal header (exit=$RC out=[$OUT])"

# 5. Failure banner uses singular "retro sweep" (not "retros sweep").
write_stub 1 "sweep-retros: cannot find TARGETS.md"
OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'retro sweep could not run' \
  && ok "5 failure banner wording: 'retro sweep could not run' (singular, not 'retros')" \
  || no "5 failure banner wording: expected 'retro sweep could not run' (exit=$RC out=[$OUT])"

# 6. Clean sentinel → hook SILENT (no output to session).
write_stub 0 "Summary: 0 pending / 0 retros across targets.
RSDD-STATE: clean"
OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"; RC=$?
[ -z "$OUT" ] \
  && ok "6 RSDD-STATE: clean → hook silent (no output)" "(exit $RC)" \
  || no "6 RSDD-STATE: clean → hook must be silent (got: exit=$RC out=[$OUT])"

# 7. Attention sentinel → hook EMITS.
write_stub 0 "PENDING  /some/retro.md
RSDD-STATE: attention"
OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"; RC=$?
[ -n "$OUT" ] \
  && ok "7 RSDD-STATE: attention → hook emits" "(exit $RC)" \
  || no "7 RSDD-STATE: attention → hook must emit (exit=$RC)"

# 8. Missing sentinel → hook EMITS (§7 anti-silent-zero).
write_stub 0 "Summary: 0 pending / 0 retros across targets."
OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"; RC=$?
[ -n "$OUT" ] \
  && ok "8 missing RSDD-STATE sentinel → hook emits (anti-silent-zero)" "(exit $RC)" \
  || no "8 missing RSDD-STATE sentinel → hook must emit (exit=$RC)"

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: hook must go red when rc-check is neutered --"

  # Tooth A: mutant hook never checks rc — always takes the success path.
  # Test 3 (operational-failure → banner) must catch this and go RED.
  sed 's/if \[ "\$rc" -ne 0 \]/if false/' \
    "$SUT" > "$TMP/mutant-hook.sh"
  chmod +x "$TMP/mutant-hook.sh"
  write_stub 1 "sweep-retros: cannot find TARGETS.md"
  cp "$TMP/mutant-hook.sh" "$TMP/sweep-retros-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
  if ! printf '%s\n' "$MUTANT_OUT" | grep -qi 'could not run\|exit 1'; then
    ok "teeth A: rc-neutered mutant omits failure banner → test 3 would catch it (RED)"
  else
    no "teeth A: mutant still emits failure banner — sed pattern may not match fixed hook"
  fi

  # Tooth B: revert failure-banner wording to "retros sweep" → test 5 goes RED.
  sed 's/retro sweep could not run/retros sweep could not run/' \
    "$SUT" > "$TMP/mutant-hook.sh"
  chmod +x "$TMP/mutant-hook.sh"
  write_stub 1 "sweep-retros: cannot find TARGETS.md"
  cp "$TMP/mutant-hook.sh" "$TMP/sweep-retros-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
  if ! printf '%s\n' "$MUTANT_OUT" | grep -qi 'retro sweep could not run'; then
    ok "teeth B: reverted to 'retros sweep' mutant → test 5 would catch it (RED)"
  else
    no "teeth B: mutant still matches 'retro sweep could not run' — tooth has no bite"
  fi

  # Tooth H-a: mutate guard = "clean" → = "NEVER" → clean sentinel no longer silences → test 6 RED.
  echo "-- teeth H-a: = \"clean\" → = \"NEVER\" guard; clean sentinel must NOT silence (test 6 RED) --"
  if ! grep -qF '= "clean"' "$SUT"; then
    no "teeth H-a: = \"clean\" guard not found in hook SUT" "anchor not found — hook SUT drifted?"
  else
    sed 's/= "clean"/= "NEVER"/' "$SUT" > "$TMP/mutant-hook-ha.sh"
    chmod +x "$TMP/mutant-hook-ha.sh"
    write_stub 0 "Summary: 0 pending / 0 retros across targets.
RSDD-STATE: clean"
    cp "$TMP/mutant-hook-ha.sh" "$TMP/sweep-retros-hook.sh"
    MUTANT_OUT_HA="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
    if [ -n "$MUTANT_OUT_HA" ]; then
      ok "teeth H-a: clean-guard mutant emits on clean sentinel → test 6 would go RED (has teeth)"
    else
      no "teeth H-a: mutant still silences on clean — sed pattern may be no-op"
    fi
  fi

  # Tooth H-b: mutate ${state:-} → ${state:-clean} → missing sentinel silences wrongly → test 8 RED.
  echo "-- teeth H-b: \${state:-} → \${state:-clean}; missing sentinel must NOT silence (test 8 RED) --"
  if ! grep -qF '${state:-}' "$SUT"; then
    no "teeth H-b: \${state:-} not found in hook SUT" "anchor not found — hook SUT drifted?"
  else
    sed 's/\${state:-}/\${state:-clean}/g' "$SUT" > "$TMP/mutant-hook-hb.sh"
    chmod +x "$TMP/mutant-hook-hb.sh"
    write_stub 0 "Summary: 0 pending / 0 retros across targets."
    cp "$TMP/mutant-hook-hb.sh" "$TMP/sweep-retros-hook.sh"
    MUTANT_OUT_HB="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
    if [ -z "$MUTANT_OUT_HB" ]; then
      ok "teeth H-b: default-clean mutant silences missing sentinel → test 8 would go RED (has teeth)"
    else
      no "teeth H-b: mutant still emits on missing sentinel — sed pattern may be no-op"
    fi
  fi

  # Tooth H-c: remove sentinel-parse line → state always empty → hook always emits (anti-silent-zero).
  echo "-- teeth H-c: remove sentinel-parse from hook; hook must still emit on any output (test 8 RED) --"
  if ! grep -qF 'grep .^RSDD-STATE.' "$SUT" && ! grep -qF "grep '^RSDD-STATE:'" "$SUT"; then
    no "teeth H-c: sentinel-parse grep not found in hook SUT" "anchor not found — hook SUT drifted?"
  else
    sed '/grep.*RSDD-STATE/d; /state:-/d' "$SUT" > "$TMP/mutant-hook-hc.sh"
    chmod +x "$TMP/mutant-hook-hc.sh"
    write_stub 0 "RSDD-STATE: clean"
    cp "$TMP/mutant-hook-hc.sh" "$TMP/sweep-retros-hook.sh"
    MUTANT_OUT_HC="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
    # Without sentinel-parse, no silence-on-clean logic runs → hook always emits → test 6 RED
    if [ -n "$MUTANT_OUT_HC" ]; then
      ok "teeth H-c: sentinel-removed mutant emits on clean → test 6 would go RED (has teeth)"
    else
      no "teeth H-c: mutant still silences — sed pattern may be no-op"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
