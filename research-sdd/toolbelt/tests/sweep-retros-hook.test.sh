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
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
