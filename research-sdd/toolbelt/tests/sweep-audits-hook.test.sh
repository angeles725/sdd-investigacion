#!/usr/bin/env bash
# sweep-audits-hook.test.sh — red-first harness for sweep-audits-hook.sh.
# Covers: existence, executable, operational-failure banner, success header,
#         absent-input collapse (default mode vs. --full), mutation proof.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-audits-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== sweep-audits-hook.test.sh =="

# 1. Existence
[ -f "$SUT" ] \
  && ok "1 hook exists at $SUT" \
  || no "1 hook NOT found at $SUT"

# 2. Executable
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 hook is executable" \
  || no "2 hook NOT executable (missing +x bit)"

if [ ! -f "$SUT" ]; then
  for n in 3 4 5 6; do no "$n (skipped: hook missing)"; done
  echo "== $pass passed · $fail failed =="; exit 2
fi

# ---- Temp workspace ---------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# write_stub <exit_code> <output_text> — creates TMP/sweep-audits.sh + refreshes hook copy.
write_stub() {
  local rc="$1" txt="$2"
  printf '%s\n' "$txt" > "$TMP/stub-out.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit %s\n' "$TMP/stub-out.txt" "$rc" \
    > "$TMP/sweep-audits.sh"
  chmod +x "$TMP/sweep-audits.sh"
  cp "$SUT" "$TMP/sweep-audits-hook.sh"
  chmod +x "$TMP/sweep-audits-hook.sh"
}

# Stub output simulating a sweep with 3 absent targets + aggregate line.
# Matches what sweep-audits.sh already emits (it has the aggregate line since before §501).
STUB_ABSENT='INFO: corpus not found (absent-input): /fake/path1
INFO: corpus not found (absent-input): /fake/path2
INFO: corpus not found (absent-input): /fake/path3

Summary: 0 pending / 0 audits across targets.
INFO: 3 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.
Nothing to review.'

# 3. Operational failure (sweep exits non-zero) → "could not run" banner, NOT normal header.
write_stub 1 "sweep-audits: cannot find TARGETS.md"
OUT="$(bash "$TMP/sweep-audits-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'could not run\|error\|exit 1' \
  && ok "3 sweep failure (rc=1) → operational-failure banner emitted" \
  || no "3 sweep failure → expected 'could not run' banner (exit=$RC out=[$OUT])"

# 4. Success (sweep exits 0) → normal header present in output.
write_stub 0 "TARGET  demo  · 0 open audits"
OUT="$(bash "$TMP/sweep-audits-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'pending audits\|§13' \
  && ok "4 success (rc=0) → normal audit header emitted" \
  || no "4 success → expected normal header (exit=$RC out=[$OUT])"

# 5. Default mode collapses N per-target absent-input INFO lines to one counted line.
#    The counted line must carry "run --full to list them." Per-target lines must be absent.
#    RED before implementation: current hook has no filtering → per-target lines pass through,
#    aggregate line keeps "see INFO lines above" (not "run --full").
write_stub 0 "$STUB_ABSENT"
OUT="$(bash "$TMP/sweep-audits-hook.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && printf '%s\n' "$OUT" | grep -q 'run --full to list them' \
   && ! printf '%s\n' "$OUT" | grep -q 'corpus not found (absent-input):'; then
  ok "5 default mode: 3 absent targets → aggregate counted line (run --full), no per-target lines"
else
  no "5 default mode: aggregate 'run --full' absent or per-target lines present (exit=$RC out=[$OUT])"
fi

# 6. --full passes per-target absent-input lines through unchanged (byte-identical passthrough).
#    Regression guard: --full output must contain the per-target lines from the sweep.
write_stub 0 "$STUB_ABSENT"
OUT="$(bash "$TMP/sweep-audits-hook.sh" --full 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && printf '%s\n' "$OUT" | grep -q 'corpus not found (absent-input): /fake/path1'; then
  ok "6 --full mode: per-target absent-input lines passed through"
else
  no "6 --full mode: per-target line NOT found in output (exit=$RC out=[$OUT])"
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: hook must go red when rc-check is neutered --"

  # Tooth A: mutant hook never checks rc — always takes the success path.
  # Test 3 (operational-failure → banner) must catch this and go RED.
  sed 's/if \[ "\$rc" -ne 0 \]/if false/' \
    "$SUT" > "$TMP/mutant-hook.sh"
  chmod +x "$TMP/mutant-hook.sh"
  write_stub 1 "sweep-audits: cannot find TARGETS.md"
  cp "$TMP/mutant-hook.sh" "$TMP/sweep-audits-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-audits-hook.sh" 2>&1)"
  if ! printf '%s\n' "$MUTANT_OUT" | grep -qi 'could not run\|exit 1'; then
    ok "teeth A: rc-neutered mutant omits failure banner → test 3 would catch it (RED)"
  else
    no "teeth A: mutant still emits failure banner — sed pattern may not match fixed hook"
  fi

  echo "-- teeth B (§7 anti-silent-zero): neuter ABSENT-COLLAPSE-PRINT → absent targets silently dropped → test 5 RED --"
  # Tooth B: mutant drops the 'print' from the aggregate absent-input block (keeps 'next').
  # Per-target lines are still filtered by their own rule; aggregate line is NOT emitted.
  # Result: nothing about absent targets disclosed → test 5 ('run --full to list them' absent) → RED.
  write_stub 0 "$STUB_ABSENT"
  sed 's/print; next  # ABSENT-COLLAPSE-PRINT/next  # ABSENT-COLLAPSE-DISABLED/' \
    "$SUT" > "$TMP/mutant-hook-B.sh"
  chmod +x "$TMP/mutant-hook-B.sh"
  cp "$TMP/mutant-hook-B.sh" "$TMP/sweep-audits-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-audits-hook.sh" 2>&1)"
  if ! printf '%s\n' "$MUTANT_OUT" | grep -q 'run --full to list them'; then
    ok "teeth B: ABSENT-COLLAPSE-PRINT neutered → absent targets silently dropped → test 5 RED"
  else
    no "teeth B: mutant still shows 'run --full' — sed pattern may not match hook"
  fi

  echo "-- teeth C: invert full-guard condition → --full mode also filtered → test 6 RED --"
  # Tooth C: mutant changes the FULL-PASSTHROUGH-GUARD condition so the awk filter runs
  # in --full mode too (condition becomes _full=1, which IS true in --full mode).
  # Per-target lines are then absent in --full output → test 6 ('per-target line present') → RED.
  write_stub 0 "$STUB_ABSENT"
  sed 's/\[ "\$_full" = 0 \]; then  # FULL-PASSTHROUGH-GUARD/[ "$_full" = 1 ]; then  # FULL-PASSTHROUGH-GUARD/' \
    "$SUT" > "$TMP/mutant-hook-C.sh"
  chmod +x "$TMP/mutant-hook-C.sh"
  cp "$TMP/mutant-hook-C.sh" "$TMP/sweep-audits-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-audits-hook.sh" --full 2>&1)"
  if ! printf '%s\n' "$MUTANT_OUT" | grep -q 'corpus not found (absent-input): /fake/path1'; then
    ok "teeth C: full-guard inverted → per-target lines absent in --full → test 6 RED"
  else
    no "teeth C: mutant still shows per-target line in --full — sed pattern may not match hook"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
