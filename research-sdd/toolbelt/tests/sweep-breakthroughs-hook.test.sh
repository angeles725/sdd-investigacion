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
MUT=""; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" ${MUT:+"$MUT"}' EXIT

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
<<<"$OUT" grep -qi 'could not run\|error\|exit 1' \
  && ok "3 sweep failure (rc=1) → operational-failure banner emitted" \
  || no "3 sweep failure → expected 'could not run' banner (exit=$RC out=[$OUT])"

# 4. Success (sweep exits 0) → normal header present in output.
write_stub 0 "TARGET  demo  · 0 drifted breakthroughs"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
<<<"$OUT" grep -qi 'breakthrough\|§22' \
  && ok "4 success (rc=0) → normal breakthrough header emitted" \
  || no "4 success → expected normal header (exit=$RC out=[$OUT])"

# 5. Default mode collapses N per-target absent-input INFO lines to one counted line.
#    The counted line must carry "run --full to list them." Per-target lines must be absent.
#    RED before implementation: current hook has no filtering → per-target lines pass through,
#    aggregate line keeps "see INFO lines above" (not "run --full").
write_stub 0 "$STUB_ABSENT"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && <<<"$OUT" grep -q 'run --full to list them' \
   && ! <<<"$OUT" grep -q 'corpus not found (absent-input):'; then
  ok "5 default mode: 3 absent targets → aggregate counted line (run --full), no per-target lines"
else
  no "5 default mode: aggregate 'run --full' absent or per-target lines present (exit=$RC out=[$OUT])"
fi

# 6. --full passes per-target absent-input lines through unchanged (byte-identical passthrough).
#    Regression guard: --full output must contain the per-target lines from the sweep.
write_stub 0 "$STUB_ABSENT"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" --full 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && <<<"$OUT" grep -q 'corpus not found (absent-input): /fake/path1'; then
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
   && ! <<<"$OUT" grep -q 'corpus exists, no block files (empty-input):' \
   && <<<"$OUT" grep -qF 'INFO: 2 corpus(es) empty-input — run --full to list them'; then
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
   && ! <<<"$OUT" grep -q 'no tagged breakthroughs in corpus (no-match' \
   && <<<"$OUT" grep -qF 'INFO: 3 corpus(es) no-match — run --full to list them'; then
  ok "8 default mode: 3 no-match targets → no per-target lines, exact summary 'INFO: 3 corpus(es) no-match — run --full to list them'"
else
  no "8 default mode: per-target no-match lines present OR exact summary missing (exit=$RC out=[$OUT])"
fi

# 9. --full mode passes through both empty-input and no-match per-target lines.
#    Uses STUB_EMPTY_NOMATCH (both classes) to verify full passthrough.
write_stub 0 "$STUB_EMPTY_NOMATCH"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" --full 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && <<<"$OUT" grep -q 'corpus exists, no block files (empty-input): /fake/empty1' \
   && <<<"$OUT" grep -q 'no tagged breakthroughs in corpus (no-match'; then
  ok "9 --full mode: per-target empty-input and no-match lines passed through"
else
  no "9 --full mode: per-target lines NOT found in output (exit=$RC out=[$OUT])"
fi


# 10. Combined: 2 empty-input + 3 no-match, no absent (END{} path).
#     Exact combined text: 'INFO: 2 corpus(es) empty-input, 3 no-match — run --full to list them'.
write_stub 0 "$STUB_EMPTY_NOMATCH"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && ! <<<"$OUT" grep -qF 'corpus exists, no block files (empty-input):' \
   && ! <<<"$OUT" grep -qF 'no tagged breakthroughs in corpus (no-match' \
   && <<<"$OUT" grep -qF 'INFO: 2 corpus(es) empty-input, 3 no-match — run --full to list them'; then
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
   && ! <<<"$OUT" grep -qF 'corpus exists, no block files (empty-input):' \
   && <<<"$OUT" grep -qF 'INFO: 1 corpus(es) empty-input — run --full to list them'; then
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
   && ! <<<"$OUT" grep -qF 'no tagged breakthroughs in corpus (no-match' \
   && <<<"$OUT" grep -qF 'INFO: 1 corpus(es) no-match — run --full to list them'; then
  ok "12 single no-match → exact summary 'INFO: 1 corpus(es) no-match — run --full to list them'"
else
  no "12 single no-match: exact summary missing or per-target line present (exit=$RC out=[$OUT])"
fi

# 13. Ordering robustness: per-target empty-input and no-match lines appear both BEFORE and AFTER
#     the absent aggregate line. The hook must count ALL of them and emit the TOTAL in one summary.
#     RED on current commit: piggyback emits with partial counts and emitted flag suppresses END{},
#     so late ei/nm lines are silently undercounted (§7 violation).
_STUB_MIXED_EI_NM='INFO: corpus not found (absent-input): /fake/absent1
INFO: corpus exists, no block files (empty-input): /fake/ei_early
INFO: no tagged breakthroughs in corpus (no-match): /fake/nm_early

Summary: 1 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted.
INFO: 1 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.
INFO: corpus exists, no block files (empty-input): /fake/ei_late
INFO: no tagged breakthroughs in corpus (no-match): /fake/nm_late
Ledger consistent — all tagged breakthroughs indexed, no drift.'
write_stub 0 "$_STUB_MIXED_EI_NM"
OUT="$(bash "$TMP/sweep-breakthroughs-hook.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && ! <<<"$OUT" grep -qF 'corpus exists, no block files (empty-input):' \
   && ! <<<"$OUT" grep -qF 'no tagged breakthroughs in corpus (no-match' \
   && <<<"$OUT" grep -qF 'INFO: 2 corpus(es) empty-input, 2 no-match — run --full to list them'; then
  ok "13 ordering robustness: 1 early + 1 late ei/nm → TOTAL count=2 each in one combined summary (END emission)"
else
  no "13 ordering robustness: expected 'INFO: 2 corpus(es) empty-input, 2 no-match' but got wrong counts or per-target lines present (exit=$RC out=[$OUT])"
fi

# ---- Teeth (mutation proof) -------------------------------------------------
# --- mutation-control helpers (kit issues #943, #1299) ---------------------------------------------
# Every mutant is built as a COPY of the SUT under $MUT (a temp dir outside the live tree) by the shared
# lib/mutant.sh, which REFUSES an empty, byte-identical, syntax-broken or live-tree mutant and a dead sed
# stage; each control then asserts the GOOD verdict on the original AND the SPECIFIC BAD verdict on the
# mutant (exact rc on both sides: a crashing mutant is not teeth).
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
typeset -f mutant_chain >/dev/null 2>&1 && typeset -f mutant_tooth >/dev/null 2>&1 \
  || { echo "FATAL: lib/mutant.sh did not define mutant_chain/mutant_tooth ($HERE/lib/mutant.sh)" >&2; exit 2; }
# mk_sed LABEL OUT EXPR...  build $OUT from $SUT with one sed stage per EXPR (mutant_chain refuses a dead
# stage); a refusal is counted as a failure here, the helper itself never touches the counters.
mk_sed(){
  local out="$2"
  mkdir -p "$(dirname "$out")"
  mutant_chain "$1" "$SUT" "$out" "${@:3}" || { fail=$((fail+1)); return 1; }
}
# tooth LABEL GOOD_RC BAD_RC MUTANT [--orig PATH] [--good-has RE] [--bad-lacks RE] [--bad-has RE] -- ARGV...
# Counting wrapper over the shared mutant_tooth (which prints its own PASS/FAIL line). The pre-migration
# local helper matched patterns case-insensitively, so MUTANT_TOOTH_ICASE keeps that behaviour exactly.
tooth(){
  if MUTANT_TOOTH_ICASE=1 mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
# hook_tooth LABEL GOOD_RC BAD_RC MUTANT [tooth opts] -- ARGV...   the hook locates its sweep stub next to
# itself, so the stub currently in $TMP (set by write_stub for this scenario) is copied beside the mutant;
# the ORIGINAL runs from $TMP's hook copy (also refreshed by write_stub).
hook_tooth(){
  local label="$1" grc="$2" brc="$3" mut="$4"; shift 4
  cp "$TMP/sweep-breakthroughs.sh" "$(dirname "$mut")/sweep-breakthroughs.sh"
  tooth "$label" "$grc" "$brc" "$mut" --orig "$TMP/sweep-breakthroughs-hook.sh" "$@"
}

if [ "${1:-}" = "--prove-teeth" ]; then
  MUT="$(mktemp -d)"
  H='sweep-breakthroughs-hook.sh'
  echo "-- teeth: hook must go red when rc-check is neutered --"

  # Tooth A: mutant hook never checks rc — always takes the success path. Test 3 must go RED.
  write_stub 1 "sweep-breakthroughs: cannot find TARGETS.md"
  mk_sed "teeth A" "$MUT/A/$H" 's/if \[ "\$rc" -ne 0 \]/if false/' \
    && hook_tooth "teeth A: rc-neutered mutant omits failure banner → test 3 would catch it (RED)" 0 0 "$MUT/A/$H" \
         --good-has 'breakthroughs sweep could not run' --bad-lacks 'could not run|exit 1' \
         --bad-has 'Research-SDD breakthrough ledger sweep' -- bash @SUT@

  echo "-- teeth B (§7 anti-silent-zero): neuter ABSENT-COLLAPSE-PRINT → absent targets silently dropped → test 5 RED --"
  # Tooth B: drops the 'print' from the aggregate absent-input block (keeps 'next').
  write_stub 0 "$STUB_ABSENT"
  mk_sed "teeth B" "$MUT/B/$H" 's/print; next  # ABSENT-COLLAPSE-PRINT/next  # ABSENT-COLLAPSE-DISABLED/' \
    && hook_tooth "teeth B: ABSENT-COLLAPSE-PRINT neutered → absent targets silently dropped → test 5 RED" 0 0 "$MUT/B/$H" \
         --good-has 'run --full to list them' --bad-lacks 'run --full to list them' \
         --bad-has 'Research-SDD breakthrough ledger sweep' -- bash @SUT@

  echo "-- teeth C: invert full-guard condition → --full mode also filtered → test 6 RED --"
  # Tooth C: the awk filter also runs in --full mode (condition becomes _full=1).
  write_stub 0 "$STUB_ABSENT"
  mk_sed "teeth C" "$MUT/C/$H" 's/\[ "\$_full" = 0 \]; then  # FULL-PASSTHROUGH-GUARD/[ "$_full" = 1 ]; then  # FULL-PASSTHROUGH-GUARD/' \
    && hook_tooth "teeth C: full-guard inverted → per-target lines absent in --full → test 6 RED" 0 0 "$MUT/C/$H" \
         --good-has 'corpus not found \(absent-input\): /fake/path1' \
         --bad-lacks 'corpus not found \(absent-input\): /fake/path1' \
         --bad-has 'Research-SDD breakthrough ledger sweep' -- bash @SUT@ --full

  echo "-- teeth D (#974): neuter EMPTY-COLLAPSE-COUNT → ei stays 0 → no summary → test 7 RED --"
  # Tooth D: drops ei++ from the EMPTY-COLLAPSE-COUNT line (keeps 'next'); STUB_EMPTY_ONLY (test 7's stub).
  write_stub 0 "$STUB_EMPTY_ONLY"
  mk_sed "teeth D" "$MUT/D/$H" 's/ei++; next  # EMPTY-COLLAPSE-COUNT/next  # EMPTY-COLLAPSE-DISABLED/' \
    && hook_tooth "teeth D: EMPTY-COLLAPSE-COUNT neutered → ei=0 → empty-input summary absent → test 7 RED" 0 0 "$MUT/D/$H" \
         --good-has 'INFO: [0-9]+ corpus\(es\) empty-input — run --full to list them' \
         --bad-lacks 'INFO: [0-9]+ corpus\(es\) empty-input' --bad-has 'Ledger consistent' -- bash @SUT@

  echo "-- teeth E (#974): neuter NOMATCH-COLLAPSE-COUNT → nm stays 0 → no summary → test 8 RED --"
  # Tooth E: drops nm++ from the NOMATCH-COLLAPSE-COUNT line (keeps 'next'); STUB_NOMATCH_ONLY (test 8's stub).
  write_stub 0 "$STUB_NOMATCH_ONLY"
  mk_sed "teeth E" "$MUT/E/$H" 's/nm++; next  # NOMATCH-COLLAPSE-COUNT/next  # NOMATCH-COLLAPSE-DISABLED/' \
    && hook_tooth "teeth E: NOMATCH-COLLAPSE-COUNT neutered → nm=0 → no-match summary absent → test 8 RED" 0 0 "$MUT/E/$H" \
         --good-has 'INFO: [0-9]+ corpus\(es\) no-match — run --full to list them' \
         --bad-lacks 'INFO: [0-9]+ corpus\(es\) no-match' --bad-has 'Ledger consistent' -- bash @SUT@

  echo "-- teeth F (#974): neuter COMBINED-COLLAPSE-EMIT in END → combined count suppressed → test 13 RED --"
  # Tooth F: the combined condition never fires (ei > 0 && nm > 0 → 0); only the ei-only branch
  # fires, so the combined exact text of test 13 disappears while an ei-only summary appears.
  write_stub 0 "$_STUB_MIXED_EI_NM"
  mk_sed "teeth F" "$MUT/F/$H" 's/ei > 0 && nm > 0/0/' \
    && hook_tooth "teeth F: COMBINED-COLLAPSE-EMIT neutered → combined summary absent → test 13 RED" 0 0 "$MUT/F/$H" \
         --good-has 'INFO: 2 corpus\(es\) empty-input, 2 no-match — run --full to list them' \
         --bad-lacks 'INFO: 2 corpus\(es\) empty-input, 2 no-match' \
         --bad-has 'INFO: 2 corpus\(es\) empty-input — run --full' -- bash @SUT@
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
