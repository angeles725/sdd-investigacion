#!/usr/bin/env bash
# sweep-retros-hook.test.sh — red-first harness for sweep-retros-hook.sh.
# Covers: existence, executable, operational-failure banner, success header,
#         summary mode (absent collapse, "N more" limit, Summary: byte-identity, --full passthrough),
#         mutation proof.
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
  for n in 3 4 5 6 7 8 9; do no "$n (skipped: hook missing)"; done
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

# ---- Summary mode tests -----------------------------------------------------

# Helper: build a sweep stub with N PENDING rows + 2 absent targets.
_build_sweep_out() {
  local n_pending="$1"
  local i ep txt
  ep=1000  # base epoch for oldest-first ordering
  txt=""
  txt="${txt}INFO: corpus not found (absent-input): /targets/absent-a"$'\n'
  txt="${txt}INFO: corpus not found (absent-input): /targets/absent-b"$'\n'
  for i in $(seq 1 "$n_pending"); do
    txt="${txt}PENDING  /targets/t/retros/retro${i}.md"$'\n'
    txt="${txt}         target: /targets/t  ·  ~${i} proposed deltas  ·  status: pending  ·  age: ${i}d"$'\n'
    ep=$((ep + 86400))
  done
  txt="${txt}"$'\n'
  txt="${txt}Summary: ${n_pending} pending / $((n_pending + 3)) retros across targets."$'\n'
  txt="${txt}INFO: 2 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above."$'\n'
  printf '%s' "$txt"
}

# Helper: extract additionalContext from jq-wrapped hook output (or pass through on fallback).
_hook_content() { printf '%s\n' "$1" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || printf '%s\n' "$1"; }

# 6. Summary mode (default, 0 pending + absent targets): absent collapse line still prints.
#    A silent clean run is the defect — sentinel/collapse lines MUST appear.
write_stub 0 "$(_build_sweep_out 0)"
OUT6="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
_content6="$(_hook_content "$OUT6")"
printf '%s\n' "$_content6" | grep -qE 'INFO: 2 target\(s\) not traversed' \
  && ok "6 summary mode, 0 pending + 2 absent: absent collapse line present (no silent clean)" \
  || no "6 summary mode, 0 pending + 2 absent: absent collapse line MISSING"

# 7. Summary mode: absent collapse line says "run --full to list them" (not "see INFO lines above").
printf '%s\n' "$_content6" | grep -q 'run --full to list them' \
  && ok "7 summary mode: absent collapse line says 'run --full to list them'" \
  || no "7 summary mode: absent collapse line missing --full hint"

# 8. Summary mode with >5 pending: only 5 PENDING lines shown + "N more" message.
write_stub 0 "$(_build_sweep_out 8)"
OUT8="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
_content8="$(_hook_content "$OUT8")"
_cnt8="$(printf '%s\n' "$_content8" | grep -c '^PENDING')" || _cnt8=0
[ "$_cnt8" -eq 5 ] \
  && ok "8 summary mode, 8 pending: exactly 5 PENDING lines shown (got $_cnt8)" \
  || no "8 summary mode, 8 pending: expected 5 PENDING lines, got $_cnt8"

printf '%s\n' "$_content8" | grep -q 'and 3 more' \
  && ok "8b summary mode: '… and 3 more' message present" \
  || no "8b summary mode: '… and 3 more' message MISSING"

# 9. Summary: line is byte-identical in default (summary) mode and --full mode.
_sweep9_out="$(_build_sweep_out 7)"
write_stub 0 "$_sweep9_out"
OUT9_SUMM="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
OUT9_FULL="$(bash "$TMP/sweep-retros-hook.sh" --full 2>&1)"
_sum_summ="$(printf '%s\n' "$(_hook_content "$OUT9_SUMM")" | grep '^Summary:')"
_sum_full="$(printf '%s\n' "$(_hook_content "$OUT9_FULL")" | grep '^Summary:')"
[ "$_sum_summ" = "$_sum_full" ] \
  && ok "9 Summary: line byte-identical in summary and --full modes" \
  || no "9 Summary: line differs: summary=[$_sum_summ] full=[$_sum_full]"

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

  # Tooth C: mutant drops the absent-collapse line (ABSENT-COLLAPSE-PRINT) → test 6 goes RED.
  # Mutant: replace "print; next  # ABSENT-COLLAPSE-PRINT" with just "next" — line is suppressed.
  echo "-- teeth C: absent-collapse line dropped → test 6 must catch it --"
  sed 's/print; next  # ABSENT-COLLAPSE-PRINT/next/' \
    "$SUT" > "$TMP/mutant-hook-c.sh"
  chmod +x "$TMP/mutant-hook-c.sh"
  write_stub 0 "$(_build_sweep_out 0)"
  cp "$TMP/mutant-hook-c.sh" "$TMP/sweep-retros-hook.sh"
  MUTANT_OUT_C="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
  _mc="$(_hook_content "$MUTANT_OUT_C")"
  if ! printf '%s\n' "$_mc" | grep -qE 'INFO: 2 target\(s\) not traversed'; then
    ok "teeth C: absent-collapse-drop mutant suppresses collapse line → test 6 would catch it (RED)"
  else
    no "teeth C: mutant still emits collapse line — tooth has no bite"
  fi

  # Tooth D: mutant alters Summary: line in summary mode → test 9 byte-equality goes RED.
  # Mutant: replace "print; next  # SUMMARY-LINE-PRINT" with a version that appends " MUTATED".
  # Using gsub so the substitution happens inside awk, altering the line content.
  echo "-- teeth D: Summary: line mutated in summary mode → test 9 must catch it --"
  sed 's/print; next  # SUMMARY-LINE-PRINT/$0 = $0 " MUTATED"; print; next/' \
    "$SUT" > "$TMP/mutant-hook-d.sh"
  chmod +x "$TMP/mutant-hook-d.sh"
  write_stub 0 "$(_build_sweep_out 7)"
  cp "$TMP/mutant-hook-d.sh" "$TMP/sweep-retros-hook.sh"
  OUT_D_SUMM="$(bash "$TMP/sweep-retros-hook.sh" 2>&1)"
  OUT_D_FULL="$(bash "$TMP/sweep-retros-hook.sh" --full 2>&1)"
  _ds="$(printf '%s\n' "$(_hook_content "$OUT_D_SUMM")" | grep '^Summary:')"
  _df="$(printf '%s\n' "$(_hook_content "$OUT_D_FULL")" | grep '^Summary:')"
  if [ "$_ds" != "$_df" ]; then
    ok "teeth D: Summary-altered mutant → summary mode differs from --full → test 9 would catch it (RED)"
  else
    no "teeth D: Summary: lines still match on mutant — tooth has no bite"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
