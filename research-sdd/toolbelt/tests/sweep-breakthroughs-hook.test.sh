#!/usr/bin/env bash
# sweep-breakthroughs-hook.test.sh — red-first harness for sweep-breakthroughs-hook.sh.
# Covers: existence, executable, operational-failure banner, success header,
#         absent-input collapse (default mode vs. --full),
#         empty-input + no-match collapse (#974: per-target INFO lines → counted summaries),
#         mutation proof.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-breakthroughs-hook.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== sweep-breakthroughs-hook.test.sh =="

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

# write_stub <exit_code> <output_text> — creates TMP/sweep-breakthroughs.sh + refreshes hook copy.
write_stub() {
  local rc="$1" txt="$2"
  printf '%s\n' "$txt" > "$TMP/stub-out.txt"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit %s\n' "$TMP/stub-out.txt" "$rc" \
    > "$TMP/sweep-breakthroughs.sh"
  chmod +x "$TMP/sweep-breakthroughs.sh"
  cp "$SUT" "$TMP/sweep-breakthroughs-hook.sh"
  chmod +x "$TMP/sweep-breakthroughs-hook.sh"
}

# Stub output simulating a sweep with 3 absent targets + aggregate line.
# Matches what sweep-breakthroughs.sh emits after the §501 change.
STUB_ABSENT='INFO: corpus not found (absent-input): /fake/path1
INFO: corpus not found (absent-input): /fake/path2
INFO: corpus not found (absent-input): /fake/path3

Summary: 0 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
INFO: 3 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.
Ledger consistent — all tagged breakthroughs indexed, no drift.'

# 3. Operational failure (sweep exits non-zero) → "could not run" banner, NOT normal header.
write_stub 1 "sweep-breakthroughs: cannot find TARGETS.md"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'could not run\|error\|exit 1' \
  && ok "3 sweep failure (rc=1) → operational-failure banner emitted" \
  || no "3 sweep failure → expected 'could not run' banner (exit=$RC out=[$OUT])"

# 4. Success (sweep exits 0) → normal header present in output.
write_stub 0 "TARGET  demo  · 0 drifted breakthroughs"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | grep -qi 'breakthrough\|§22' \
  && ok "4 success (rc=0) → normal breakthrough header emitted" \
  || no "4 success → expected normal header (exit=$RC out=[$OUT])"

# 5. Default mode collapses N per-target absent-input INFO lines to one counted line.
#    The counted line must carry "run --full to list them." Per-target lines must be absent.
#    RED before implementation: current hook has no filtering → per-target lines pass through,
#    aggregate line keeps "see INFO lines above" (not "run --full").
write_stub 0 "$STUB_ABSENT"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
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
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" --full 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && printf '%s\n' "$OUT" | grep -q 'corpus not found (absent-input): /fake/path1'; then
  ok "6 --full mode: per-target absent-input lines passed through"
else
  no "6 --full mode: per-target line NOT found in output (exit=$RC out=[$OUT])"
fi

# ---- Tests 7-9: empty-input and no-match collapse (#974) --------------------

# Stub: ONLY 2 empty-input, NO no-match, NO absent (exercises EMPTY-only END{} path).
STUB_EMPTY_ONLY='INFO: corpus exists, no block files (empty-input): /fake/empty1
INFO: corpus exists, no block files (empty-input): /fake/empty2

Summary: 0 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
Ledger consistent — all tagged breakthroughs indexed, no drift.'

# Stub: ONLY 3 no-match, NO empty-input, NO absent (exercises NOMATCH-only END{} path).
STUB_NOMATCH_ONLY='INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): /fake/nm1
INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): /fake/nm2
INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): /fake/nm3

Summary: 3 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
Ledger consistent — all tagged breakthroughs indexed, no drift.'

# Stub: 2 empty-input + 3 no-match, NO absent (exercises combined END{} path; used by test 9 --full).
STUB_EMPTY_NOMATCH='INFO: corpus exists, no block files (empty-input): /fake/empty1
INFO: corpus exists, no block files (empty-input): /fake/empty2
INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): /fake/nm1
INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): /fake/nm2
INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): /fake/nm3

Summary: 3 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
Ledger consistent — all tagged breakthroughs indexed, no drift.'

# 7. Default mode collapses empty-input lines to one counted summary; per-target lines absent.
#    Summary line must be present (anti-silent-zero §7: empty-input ≠ absent-input ≠ no-match).
#    Uses STUB_EMPTY_ONLY so only the empty-input branch fires (END{} fallback, no absent).
#    RED before implementation: current hook passes empty-input lines through unchanged.
write_stub 0 "$STUB_EMPTY_ONLY"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && ! printf '%s\n' "$OUT" | grep -q 'corpus exists, no block files (empty-input):' \
   && printf '%s\n' "$OUT" | grep -qF 'INFO: 2 corpus(es) empty-input — run --full to list them'; then
  ok "7 default mode: 2 empty-input targets → no per-target lines, exact summary 'INFO: 2 corpus(es) empty-input — run --full to list them'"
else
  no "7 default mode: per-target empty-input lines present OR exact summary missing (exit=$RC out=[$OUT])"
fi

# 8. Default mode collapses no-match lines to one counted summary; per-target lines absent.
#    Summary line must be present (anti-silent-zero §7).
#    Uses STUB_NOMATCH_ONLY so only the no-match branch fires (END{} fallback, no absent).
#    RED before implementation: current hook passes no-match lines through unchanged.
write_stub 0 "$STUB_NOMATCH_ONLY"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && ! printf '%s\n' "$OUT" | grep -q 'no tagged breakthroughs in corpus (no-match' \
   && printf '%s\n' "$OUT" | grep -qF 'INFO: 3 corpus(es) no-match — run --full to list them'; then
  ok "8 default mode: 3 no-match targets → no per-target lines, exact summary 'INFO: 3 corpus(es) no-match — run --full to list them'"
else
  no "8 default mode: per-target no-match lines present OR exact summary missing (exit=$RC out=[$OUT])"
fi

# 9. --full mode passes through both empty-input and no-match per-target lines.
#    Uses STUB_EMPTY_NOMATCH (both classes) to verify full passthrough.
write_stub 0 "$STUB_EMPTY_NOMATCH"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" --full 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && printf '%s\n' "$OUT" | grep -q 'corpus exists, no block files (empty-input): /fake/empty1' \
   && printf '%s\n' "$OUT" | grep -q 'no tagged breakthroughs in corpus (no-match'; then
  ok "9 --full mode: per-target empty-input and no-match lines passed through"
else
  no "9 --full mode: per-target lines NOT found in output (exit=$RC out=[$OUT])"
fi

# Stub: 1 absent + 1 empty-input + 2 no-match (exercises piggyback path with combined summary).
STUB_ABSENT_EMPTY_NOMATCH='INFO: corpus not found (absent-input): /fake/absent1
INFO: corpus exists, no block files (empty-input): /fake/ei1
INFO: no tagged breakthroughs in corpus (no-match): /fake/nm1
INFO: no tagged breakthroughs in corpus (no-match): /fake/nm2

Summary: 2 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
INFO: 1 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.
Ledger consistent — all tagged breakthroughs indexed, no drift.'

# 10. Combined: 2 empty-input + 3 no-match, no absent (END{} path).
#     Exact combined text: 'INFO: 2 corpus(es) empty-input, 3 no-match — run --full to list them'.
write_stub 0 "$STUB_EMPTY_NOMATCH"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && ! printf '%s\n' "$OUT" | grep -qF 'corpus exists, no block files (empty-input):' \
   && ! printf '%s\n' "$OUT" | grep -qF 'no tagged breakthroughs in corpus (no-match' \
   && printf '%s\n' "$OUT" | grep -qF 'INFO: 2 corpus(es) empty-input, 3 no-match — run --full to list them'; then
  ok "10 combined: 2 empty + 3 no-match → exact combined summary line (anti-silent-zero §7)"
else
  no "10 combined: per-target lines present or exact combined summary missing (exit=$RC out=[$OUT])"
fi

# 11. Single empty-input target (count=1).
#     Verifies the counter works for the single-target edge case.
_STUB_SINGLE_EI='INFO: corpus exists, no block files (empty-input): /fake/only-empty

Summary: 0 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
Ledger consistent — all tagged breakthroughs indexed, no drift.'
write_stub 0 "$_STUB_SINGLE_EI"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && ! printf '%s\n' "$OUT" | grep -qF 'corpus exists, no block files (empty-input):' \
   && printf '%s\n' "$OUT" | grep -qF 'INFO: 1 corpus(es) empty-input — run --full to list them'; then
  ok "11 single empty-input → exact summary 'INFO: 1 corpus(es) empty-input — run --full to list them'"
else
  no "11 single empty-input: exact summary missing or per-target line present (exit=$RC out=[$OUT])"
fi

# 12. Single no-match target (count=1).
_STUB_SINGLE_NM='INFO: no tagged breakthroughs in corpus (no-match): /fake/only-nm

Summary: 0 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
Ledger consistent — all tagged breakthroughs indexed, no drift.'
write_stub 0 "$_STUB_SINGLE_NM"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && ! printf '%s\n' "$OUT" | grep -qF 'no tagged breakthroughs in corpus (no-match' \
   && printf '%s\n' "$OUT" | grep -qF 'INFO: 1 corpus(es) no-match — run --full to list them'; then
  ok "12 single no-match → exact summary 'INFO: 1 corpus(es) no-match — run --full to list them'"
else
  no "12 single no-match: exact summary missing or per-target line present (exit=$RC out=[$OUT])"
fi

# 13. Piggyback path: 1 absent + 1 empty-input + 2 no-match (STUB_ABSENT_EMPTY_NOMATCH).
#     Combined summary must appear BEFORE the absent aggregate line (piggyback grouping).
#     Exact text: 'INFO: 1 corpus(es) empty-input, 2 no-match — run --full to list them'.
write_stub 0 "$STUB_ABSENT_EMPTY_NOMATCH"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if command -v jq >/dev/null 2>&1; then
  _CONTENT13="$(printf '%s\n' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')"
else
  _CONTENT13="$OUT"
fi
_SUMMARY_LN13="$(printf '%s\n' "$_CONTENT13" | grep -nF 'corpus(es) empty-input, ' | head -1 | cut -d: -f1)"
_ABSENT_LN13="$(printf '%s\n' "$_CONTENT13" | grep -nF 'target(s) not traversed' | head -1 | cut -d: -f1)"
if [ "$RC" = 0 ] \
   && printf '%s\n' "$OUT" | grep -qF 'INFO: 1 corpus(es) empty-input, 2 no-match — run --full to list them' \
   && [ -n "$_SUMMARY_LN13" ] && [ -n "$_ABSENT_LN13" ] && [ "$_SUMMARY_LN13" -lt "$_ABSENT_LN13" ]; then
  ok "13 piggyback path: 1 absent + 1 ei + 2 nm → combined summary before absent aggregate (ORDER OK)"
else
  no "13 piggyback path: exact summary missing or ORDER wrong (summary=$_SUMMARY_LN13 absent=$_ABSENT_LN13 exit=$RC)"
fi

# 14. Ordering robustness: empty-input and no-match lines arrive AFTER the absent aggregate line.
#     The emitted flag must prevent double emission → exactly 1 summary line in output.
_STUB_LATE_EI_NM='INFO: corpus not found (absent-input): /fake/absent1
INFO: 1 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.
INFO: corpus exists, no block files (empty-input): /fake/ei_late
INFO: no tagged breakthroughs in corpus (no-match): /fake/nm_late

Summary: 0 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
Ledger consistent — all tagged breakthroughs indexed, no drift.'
write_stub 0 "$_STUB_LATE_EI_NM"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if command -v jq >/dev/null 2>&1; then
  _CONTENT14="$(printf '%s\n' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')"
else
  _CONTENT14="$OUT"
fi
_SUMMARY_COUNT14="$(printf '%s\n' "$_CONTENT14" | grep -oF 'corpus(es) empty-input' | wc -l | tr -d ' ')"
if [ "$RC" = 0 ] && [ "$_SUMMARY_COUNT14" = "1" ]; then
  ok "14 ordering robustness: late ei + nm lines → exactly 1 summary line (emitted flag works)"
else
  no "14 ordering robustness: expected 1 summary line, got '$_SUMMARY_COUNT14' (exit=$RC)"
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: hook must go red when rc-check is neutered --"

  # Tooth A: mutant hook never checks rc — always takes the success path.
  # Test 3 (operational-failure → banner) must catch this and go RED.
  sed 's/if \[ "\$rc" -ne 0 \]/if false/' \
    "$SUT" > "$TMP/mutant-hook.sh"
  chmod +x "$TMP/mutant-hook.sh"
  write_stub 1 "sweep-breakthroughs: cannot find TARGETS.md"
  cp "$TMP/mutant-hook.sh" "$TMP/sweep-breakthroughs-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"
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
  cp "$TMP/mutant-hook-B.sh" "$TMP/sweep-breakthroughs-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"
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
  cp "$TMP/mutant-hook-C.sh" "$TMP/sweep-breakthroughs-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" --full 2>&1)"
  if ! printf '%s\n' "$MUTANT_OUT" | grep -q 'corpus not found (absent-input): /fake/path1'; then
    ok "teeth C: full-guard inverted → per-target lines absent in --full → test 6 RED"
  else
    no "teeth C: mutant still shows per-target line in --full — sed pattern may not match hook"
  fi

  echo "-- teeth D (#974): neuter EMPTY-COLLAPSE-COUNT → ei stays 0 → no summary → test 7 RED --"
  # Tooth D: mutant drops ei++ from the EMPTY-COLLAPSE-COUNT line (keeps 'next').
  # Per-target empty-input lines are still suppressed; but ei stays 0 so no summary emitted.
  # Silent zero for empty-input → test 7 ('counted summary present') → RED.
  # Uses STUB_EMPTY_ONLY (same as test 7) so the only possible summary is the empty-input one.
  _stub_empty_only='INFO: corpus exists, no block files (empty-input): /fake/empty1
INFO: corpus exists, no block files (empty-input): /fake/empty2

Summary: 0 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
Ledger consistent — all tagged breakthroughs indexed, no drift.'
  write_stub 0 "$_stub_empty_only"
  sed 's/ei++; next  # EMPTY-COLLAPSE-COUNT/next  # EMPTY-COLLAPSE-DISABLED/' \
    "$SUT" > "$TMP/mutant-hook-D.sh"
  chmod +x "$TMP/mutant-hook-D.sh"
  cp "$TMP/mutant-hook-D.sh" "$TMP/sweep-breakthroughs-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"
  if ! printf '%s\n' "$MUTANT_OUT" | grep -qE 'INFO: [0-9]+ corpus\(es\) empty-input — run --full to list them'; then
    ok "teeth D: EMPTY-COLLAPSE-COUNT neutered → ei=0 → empty-input summary absent → test 7 RED"
  else
    no "teeth D: mutant still emits empty-input summary — sed pattern may not match hook"
  fi

  echo "-- teeth E (#974): neuter NOMATCH-COLLAPSE-COUNT → nm stays 0 → no summary → test 8 RED --"
  # Tooth E: mutant drops nm++ from the NOMATCH-COLLAPSE-COUNT line (keeps 'next').
  # Per-target no-match lines are still suppressed; but nm stays 0 so no summary emitted.
  # Silent zero for no-match → test 8 ('counted summary present') → RED.
  # Uses STUB_NOMATCH_ONLY (same as test 8) so the only possible summary is the no-match one.
  _stub_nomatch_only='INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): /fake/nm1
INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): /fake/nm2
INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): /fake/nm3

Summary: 3 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
Ledger consistent — all tagged breakthroughs indexed, no drift.'
  write_stub 0 "$_stub_nomatch_only"
  sed 's/nm++; next  # NOMATCH-COLLAPSE-COUNT/next  # NOMATCH-COLLAPSE-DISABLED/' \
    "$SUT" > "$TMP/mutant-hook-E.sh"
  chmod +x "$TMP/mutant-hook-E.sh"
  cp "$TMP/mutant-hook-E.sh" "$TMP/sweep-breakthroughs-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"
  if ! printf '%s\n' "$MUTANT_OUT" | grep -qE 'INFO: [0-9]+ corpus\(es\) no-match — run --full to list them'; then
    ok "teeth E: NOMATCH-COLLAPSE-COUNT neutered → nm=0 → no-match summary absent → test 8 RED"
  else
    no "teeth E: mutant still emits no-match summary — sed pattern may not match hook"
  fi

  echo "-- teeth F (#974): neuter PIGGYBACK-EMIT-CALL → combined summary after absent line → test 13 ORDER fails --"
  # Tooth F: mutant replaces emit_summary()  # PIGGYBACK-EMIT-CALL with a no-op shell colon.
  # With STUB_ABSENT_EMPTY_NOMATCH (1 absent + 1 ei + 2 nm), the summary is NOT emitted before
  # the absent aggregate line; END{} emits it after. ORDER check (test 13) → summary_ln > absent_ln → RED.
  write_stub 0 "$STUB_ABSENT_EMPTY_NOMATCH"
  sed 's/emit_summary()  # PIGGYBACK-EMIT-CALL/# PIGGYBACK-EMIT-DISABLED/' \
    "$SUT" > "$TMP/mutant-hook-F.sh"
  chmod +x "$TMP/mutant-hook-F.sh"
  cp "$TMP/mutant-hook-F.sh" "$TMP/sweep-breakthroughs-hook.sh"
  MUTANT_OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"
  if command -v jq >/dev/null 2>&1; then
    _CONTENT_F="$(printf '%s\n' "$MUTANT_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')"
  else
    _CONTENT_F="$MUTANT_OUT"
  fi
  _SUMMARY_LN_F="$(printf '%s\n' "$_CONTENT_F" | grep -nF 'corpus(es) empty-input, ' | head -1 | cut -d: -f1)"
  _ABSENT_LN_F="$(printf '%s\n' "$_CONTENT_F" | grep -nF 'target(s) not traversed' | head -1 | cut -d: -f1)"
  if [ -n "$_SUMMARY_LN_F" ] && [ -n "$_ABSENT_LN_F" ] && [ "$_SUMMARY_LN_F" -gt "$_ABSENT_LN_F" ]; then
    ok "teeth F: PIGGYBACK-EMIT-CALL neutered → combined summary after absent line → test 13 ORDER fails (RED)"
  else
    no "teeth F: mutant ORDER not reversed (summary=$_SUMMARY_LN_F absent=$_ABSENT_LN_F) — sed pattern may not match hook"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
