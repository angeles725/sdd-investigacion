#!/usr/bin/env bash
# verify-doc-consistency.test.sh — test suite for verify-doc-consistency.sh.
#
# Covers:
#   1–2   harness checks (SUT and fixtures exist)
#   3     CHECK 1 fires: declared count (2) != real count (3)
#   4     CHECK 2 fires: §3 not referenced in bad-skill or empty promptloop
#   5     CHECK 3 fires: retros/nonexistent-fixture.md resolves under neither root
#   6     repo-root fallback: retros/repo-only.md resolves at repo root → no WARN
#   7     all bad-scenario findings appear in summary (≥1)
#   8     exit 0 on advisory findings (WARN-only instrument)
#   9     clean scenario: zero WARN lines emitted
#   10    clean scenario: summary shows 0 findings in all categories (incl. readme-range)
#   11    operational failure: missing METHODOLOGY → exit 1
#   12    summary always proves the instrument looked (real_count in output)
#   13    operational failure: unreadable METHODOLOGY → exit 1 (root-safe; skipped as root)
#   14    CHECK 4 fires: README declares §1–§2 but real count is 3 → readme-range WARN
#   15a/b README absent: degraded WARN fires; exit code stays 0 (NOT 1)
#   16    README present but no §-range: distinct "declares no §-range" WARN fires
#   17    summary proves README was checked (§-range upper shown; anti-silent-zero)
#   18    anchor: skill-decoy has "5 sections" decoy before "all 3 sections"; hardened
#          anchor picks 3 (not 5) → no stale-count WARN
#   --prove-teeth:
#         CHECK 1/2/3 mutants + readability guard (existing) ·
#         README-RANGE-GREP mutant (new) · SKILL-COUNT-GREP anchor mutant (new) —
#         each proves the corresponding assertion goes red under a real mutation
#
# Exit: 0 all held · 1 regression · 2 harness error (SUT missing)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-doc-consistency.sh"
FIXTURES="$HERE/fixtures/doc-consistency"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== verify-doc-consistency.test.sh =="

# --- 1. SUT exists -----------------------------------------------------------
[ -f "$SUT" ] \
  && ok "1 SUT exists at $SUT" \
  || { no "1 SUT NOT found at $SUT"; echo "== $pass passed · $fail failed =="; exit 2; }

# --- 2. Fixtures directory exists -------------------------------------------
[ -d "$FIXTURES" ] \
  && ok "2 fixtures directory exists" \
  || { no "2 fixtures directory not found at $FIXTURES"; echo "== $pass passed · $fail failed =="; exit 2; }

# Fixture paths
METHOD="$FIXTURES/method-3.md"
SKILL_BAD="$FIXTURES/skill-bad.md"
SKILL_CLEAN="$FIXTURES/skill-clean.md"
SKILL_DECOY="$FIXTURES/skill-decoy.md"
PROMPTLOOP="$FIXTURES/promptloop-empty.md"
README_MISMATCH="$FIXTURES/readme-mismatch.md"
README_MATCH="$FIXTURES/readme-match.md"
README_NO_RANGE="$FIXTURES/readme-no-range.md"
KIT_ROOT="$FIXTURES"          # kit root for citation resolution
REPO_ROOT="$FIXTURES/repo-root"  # repo root for citation resolution

# Helper: run guard with controlled fixture paths; captures combined stdout+stderr.
run_bad() {
  RSDD_METHODOLOGY="$METHOD" \
  RSDD_SKILL="$SKILL_BAD" \
  RSDD_PROMPTLOOP="$PROMPTLOOP" \
  RSDD_README="$README_MISMATCH" \
  RSDD_KIT="$KIT_ROOT" \
  RSDD_REPO="$REPO_ROOT" \
    bash "$SUT" 2>&1
}

run_clean() {
  RSDD_METHODOLOGY="$METHOD" \
  RSDD_SKILL="$SKILL_CLEAN" \
  RSDD_PROMPTLOOP="$PROMPTLOOP" \
  RSDD_README="$README_MATCH" \
  RSDD_KIT="$KIT_ROOT" \
  RSDD_REPO="$REPO_ROOT" \
    bash "$SUT" 2>&1
}

BAD_OUT="$(run_bad)"
# Empty-capture guard: a fork-fail on the capture yields empty, not a content failure.
[ -n "$BAD_OUT" ] || no "BAD_OUT: SUT produced no output (capture fork-fail?)"

# --- 3. CHECK 1 fires: declared count (2) != real count (3) -----------------
_lower="${BAD_OUT,,}"
re='count mismatch|declares no section'
[[ "$_lower" =~ $re ]] \
  && ok "3 CHECK 1: stale-count WARN fires when declared (2) != real (3)" \
  || no "3 CHECK 1: expected count-mismatch WARN (out=[$BAD_OUT])"

# --- 4. CHECK 2 fires: §3 not referenced ------------------------------------
re='§3'
[[ "$BAD_OUT" =~ $re ]] \
  && ok "4 CHECK 2: orphan §3 WARN fires" \
  || no "4 CHECK 2: expected §3 orphan WARN (out=[$BAD_OUT])"

# --- 5. CHECK 3 fires: retros/nonexistent-fixture.md resolves under neither root ---
[[ "$BAD_OUT" == *nonexistent-fixture* ]] \
  && [[ "$BAD_OUT" == *'does not exist'* ]] \
  && ok "5 CHECK 3: broken citation WARN fires for retros/nonexistent-fixture.md" \
  || no "5 CHECK 3: expected broken-citation WARN for nonexistent-fixture.md (out=[$BAD_OUT])"

# --- 6. repo-root fallback: retros/repo-only.md must NOT produce a WARN -----
# skill-bad.md cites retros/repo-only.md which exists at $REPO_ROOT/retros/repo-only.md
# but NOT at $KIT_ROOT/retros/repo-only.md. Guard must resolve it at repo root → no WARN.
[[ "$BAD_OUT" == *repo-only* ]] \
  && no "6 CHECK 3 repo-root fallback: got unexpected WARN for repo-only.md (out=[$BAD_OUT])" \
  || ok "6 CHECK 3 repo-root fallback: retros/repo-only.md (repo-root-only) produces no WARN"

# --- 7. All findings appear in bad-scenario summary -------------------------
_lower="${BAD_OUT,,}"
re='findings:.*[1-9]'
[[ "$_lower" =~ $re ]] \
  && ok "7 bad-scenario summary reports ≥1 findings" \
  || no "7 bad-scenario summary: expected ≥1 findings (out=[$BAD_OUT])"

# --- 8. Exit 0 on advisory findings (WARN-only) -----------------------------
BAD_RC=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_BAD" \
         RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_MISMATCH" \
         RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
         bash "$SUT" 2>&1; echo $?)
# Extract last line (exit code) without forking: ##*$'\n' strips everything through last newline.
[[ "${BAD_RC##*$'\n'}" == "0" ]] \
  && ok "8 exit 0 on advisory findings (WARN-only instrument)" \
  || no "8 expected exit 0 on findings (got $BAD_RC)"

# --- 9. Clean scenario: zero WARN lines emitted -----------------------------
CLEAN_OUT="$(run_clean)"
# Empty-capture guard.
[ -n "$CLEAN_OUT" ] || no "CLEAN_OUT: SUT produced no output (capture fork-fail?)"
# ^WARN line-anchor: prepend \n so every line start is preceded by \n in the LHS;
# pattern $'\n'WARN then matches any line starting with WARN without relying on ^ inside
# a group (which glibc ERE may not treat as a start anchor).
re=$'\n'WARN
[[ $'\n'"$CLEAN_OUT" =~ $re ]] \
  && no "9 clean scenario: unexpected WARN line (out=[$CLEAN_OUT])" \
  || ok "9 clean scenario: no WARN lines emitted"

# --- 10. Clean scenario: summary shows 0 findings in all categories ---------
re='Findings:.*0 stale-count.*0 orphan.*0 broken.*0 readme-range'
[[ "$CLEAN_OUT" =~ $re ]] \
  && ok "10 clean scenario: summary shows 0 findings in all categories (incl. readme-range)" \
  || no "10 clean summary expected 0 findings incl. readme-range (out=[$CLEAN_OUT])"

# --- 11. Operational failure: missing METHODOLOGY → exit 1 ------------------
OP_RC=$(RSDD_METHODOLOGY="/nonexistent/method.md" RSDD_SKILL="$SKILL_CLEAN" \
        RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_MATCH" \
        RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
        bash "$SUT" 2>&1; echo $?)
[[ "${OP_RC##*$'\n'}" == "1" ]] \
  && ok "11 exit 1 on missing METHODOLOGY (operational failure)" \
  || no "11 expected exit 1 for missing METHODOLOGY (got $OP_RC)"

# --- 12. Summary proves instrument looked (anti-silent-zero) ----------------
# The clean summary must include the real_count (3) in the "## N. sections" phrase.
re='checked METHODOLOGY\.md \([0-9]+ top-level'
[[ "$CLEAN_OUT" =~ $re ]] \
  && ok "12 summary proves instrument looked (real_count printed in summary)" \
  || no "12 summary missing proof of what was checked (out=[$CLEAN_OUT])"

# --- 13. Operational failure: unreadable METHODOLOGY → exit 1 ---------------
# An exists-but-unreadable METHODOLOGY must fail operationally, NOT yield real_count=0
# and spurious findings. chmod 000 is still readable as root, so skip when euid==0.
if [ "$(id -u)" -eq 0 ]; then
  echo "  SKIP  13 unreadable-METHODOLOGY test (running as root: chmod 000 still readable)"
else
  UNREADABLE="$(mktemp)"
  cp "$METHOD" "$UNREADABLE"
  chmod 000 "$UNREADABLE"
  UR_RC=$(RSDD_METHODOLOGY="$UNREADABLE" RSDD_SKILL="$SKILL_CLEAN" \
          RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_MATCH" \
          RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
          bash "$SUT" 2>&1; echo $?)
  chmod 644 "$UNREADABLE"; rm -f "$UNREADABLE"
  [[ "${UR_RC##*$'\n'}" == "1" ]] \
    && ok "13 exit 1 on unreadable METHODOLOGY (operational failure)" \
    || no "13 expected exit 1 for unreadable METHODOLOGY (got $UR_RC)"
fi

# --- 14. CHECK 4 fires: README declares §1–§2 but real count is 3 -----------
# run_bad() uses README_MISMATCH (declares §1–§2). method-3.md has 3 sections.
# Guard must emit a readme-range WARN visible in BAD_OUT.
re='README.*§1.*§2|§1.*§2.*METHODOLOGY'
[[ "$BAD_OUT" =~ $re ]] \
  && ok "14 CHECK 4: readme-range WARN fires (README declares §1–§2, real count is 3)" \
  || no "14 CHECK 4: expected README-range WARN for §1–§2 vs real 3 (out=[$BAD_OUT])"

# --- 15. README absent: degraded WARN fires; exit code stays 0 --------------
README_ABSENT_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_CLEAN" \
                    RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="/nonexistent/readme.md" \
                    RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                    bash "$SUT" 2>&1; echo $?)
# Empty-capture guard (echo $? ensures content, but guard is a safety net).
[ -n "$README_ABSENT_OUT" ] || no "README_ABSENT_OUT: SUT produced no output (capture fork-fail?)"
# Case-insensitive: lowercase both operands; pattern is already lowercase.
_lower="${README_ABSENT_OUT,,}"
re='readme.*not found'
[[ "$_lower" =~ $re ]] \
  && ok "15a README absent: degraded WARN fires" \
  || no "15a expected degraded WARN for absent README (out=[$README_ABSENT_OUT])"
[[ "${README_ABSENT_OUT##*$'\n'}" == "0" ]] \
  && ok "15b README absent: exit code stays 0 (degraded mode, NOT operational failure)" \
  || no "15b expected exit 0 for absent README (got last_line=${README_ABSENT_OUT##*$'\n'})"

# --- 16. README present but no §-range: distinct WARN fires -----------------
README_NO_RANGE_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_CLEAN" \
                      RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_NO_RANGE" \
                      RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                      bash "$SUT" 2>&1)
# Empty-capture guard.
[ -n "$README_NO_RANGE_OUT" ] || no "README_NO_RANGE_OUT: SUT produced no output (capture fork-fail?)"
# Case-insensitive: lowercase both operands.
_lower="${README_NO_RANGE_OUT,,}"
re='declares no.*§-range|no.*§-range'
[[ "$_lower" =~ $re ]] \
  && ok "16 README present but no §-range: distinct 'declares no §-range' WARN fires" \
  || no "16 expected 'declares no §-range' WARN (out=[$README_NO_RANGE_OUT])"

# --- 17. Summary proves README was checked (anti-silent-zero) ---------------
# The clean summary must include the §-range upper bound in the "§-range upper: N" phrase.
re='§-range upper: [0-9]+'
[[ "$CLEAN_OUT" =~ $re ]] \
  && ok "17 summary proves README was checked (§-range upper printed; anti-silent-zero)" \
  || no "17 summary missing README §-range upper bound (out=[$CLEAN_OUT])"

# --- 18. Anchor: skill-decoy picks "all 3 sections" not "5 sections" decoy --
# skill-decoy.md has "5 sections" (decoy) BEFORE "all 3 sections" (real declaration).
# The hardened anchor 'all[[:space:]]+[0-9]+[[:space:]]+sections' skips the decoy
# and picks 3. A naive '[0-9]+[[:space:]]+sections' would pick the decoy 5.
DECOY_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_DECOY" \
            RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_MATCH" \
            RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
            bash "$SUT" 2>&1)
# Empty-capture guard.
[ -n "$DECOY_OUT" ] || no "DECOY_OUT: SUT produced no output (capture fork-fail?)"
# ^WARN.*... line-anchor: prepend \n so \nWARN anchors per-line without ^ inside a group.
re=$'\n''WARN.*(count mismatch|declares no section)'
[[ $'\n'"$DECOY_OUT" =~ $re ]] \
  && no "18 anchor: hardened anchor should pick 'all 3 sections' but got stale-count WARN (out=[$DECOY_OUT])" \
  || ok "18 anchor: hardened anchor picks 'all 3 sections' from decoy-SKILL → no stale-count WARN"

# =============================================================================
# 19 — kit issue #1024 round 3, MEDIUM: symlinked toolbelt (render dir)
# =============================================================================
# KIT="$(cd "$(dirname "$0")/.." && pwd)" resolved "harmlessly" through a render dir's symlinked
# toolbelt/ (single ".." lands on the render dir either way), but _cit_repo's SECOND climb
# ("parent of KIT") then landed on .../research-sdd/profile/ instead of the real repo root —
# reproduced: a citation that resolves via the repo-root fallback when run directly against the
# kit was reported BROKEN when run through a real install's render dir (1 broken citation vs 0).
INSTALLER_19="$HERE/../../install/research-sdd-install.sh"
if [ -f "$INSTALLER_19" ]; then
  HOME_19="$(mktemp -d)"
  bash "$INSTALLER_19" --home "$HOME_19" --harness reasonix >/dev/null 2>&1
  RENDER_19="$HOME_19/.reasonix/research-sdd/profile/general"
  if [ -x "$RENDER_19/toolbelt/verify-doc-consistency.sh" ]; then
    OUT_KIT_19="$(bash "$SUT" 2>&1)"
    OUT_RENDER_19="$(bash "$RENDER_19/toolbelt/verify-doc-consistency.sh" 2>&1)"
    BROKEN_KIT_19="$(printf '%s' "$OUT_KIT_19" | grep -oE '[0-9]+ broken citation' | grep -oE '^[0-9]+')"
    BROKEN_RENDER_19="$(printf '%s' "$OUT_RENDER_19" | grep -oE '[0-9]+ broken citation' | grep -oE '^[0-9]+')"
    if [ -n "$BROKEN_KIT_19" ] && [ "$BROKEN_KIT_19" = "$BROKEN_RENDER_19" ]; then
      ok "19 SYMLINK-TOOLBELT: broken-citation count through the render matches the direct kit run ($BROKEN_KIT_19)"
    else
      no "19 SYMLINK-TOOLBELT: broken-citation count differs through the render (kit=$BROKEN_KIT_19 render=$BROKEN_RENDER_19)"
    fi
  else
    no "19 SYMLINK-TOOLBELT setup: rendered toolbelt/verify-doc-consistency.sh not found at $RENDER_19"
  fi
  rm -rf "$HOME_19"
else
  no "19 SYMLINK-TOOLBELT setup: installer not found at $INSTALLER_19"
fi

# =============================================================================
# 20-23 — kit issue #1003 rework round 2, F5: PROMPT-LOOP-APPENDIX.md § coverage.
# CHECK 2's orphan scan must also read PROMPT-LOOP-APPENDIX.md, so a §N reference
# that lives ONLY there (a situational rule moved out of PROMPT-LOOP.md core) does
# not read as an orphan section forever after every future slice.
# =============================================================================
SKILL_MISSING3="$FIXTURES/skill-missing-3.md"
APPENDIX_HAS3="$FIXTURES/appendix-has-3.md"
APPENDIX_EMPTY="$FIXTURES/appendix-empty.md"

# --- 20. §3 lives only in the appendix → no orphan §3 WARN ------------------
OUT_20=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_MISSING3" \
         RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_PROMPTLOOP_APPENDIX="$APPENDIX_HAS3" \
         RSDD_README="$README_MATCH" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
         bash "$SUT" 2>&1)
[ -n "$OUT_20" ] || no "OUT_20: SUT produced no output (capture fork-fail?)"
re=$'\n''WARN.*§3'
if [[ $'\n'"$OUT_20" =~ $re ]]; then
  no "20 CHECK 2 appendix coverage: unexpected §3 orphan WARN even though appendix carries §3 (out=[$OUT_20])"
else
  ok "20 CHECK 2 appendix coverage: §3 referenced only in PROMPT-LOOP-APPENDIX.md → no orphan §3 WARN"
fi

# --- 21. appendix present but EMPTY → §3 orphan WARN still fires (no free pass) --
# Anti-silent-zero: the appendix's mere PRESENCE must not suppress the finding —
# only its actual CONTENT (a real §3 reference) may.
OUT_21=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_MISSING3" \
         RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_PROMPTLOOP_APPENDIX="$APPENDIX_EMPTY" \
         RSDD_README="$README_MATCH" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
         bash "$SUT" 2>&1)
[ -n "$OUT_21" ] || no "OUT_21: SUT produced no output (capture fork-fail?)"
re=$'\n''WARN.*§3'
if [[ $'\n'"$OUT_21" =~ $re ]]; then
  ok "21 CHECK 2 appendix coverage: empty appendix does NOT suppress the §3 orphan WARN (no free pass on presence alone)"
else
  no "21 CHECK 2 appendix coverage: §3 orphan WARN missing even though no file actually references §3 (out=[$OUT_21])"
fi

# --- 22. appendix ABSENT → degraded WARN naming the appendix; §3 still orphan; exit 0 --
OUT_22=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_MISSING3" \
         RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_PROMPTLOOP_APPENDIX="$FIXTURES/nonexistent-appendix.md" \
         RSDD_README="$README_MATCH" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
         bash "$SUT" 2>&1); RC_22=$?
[ -n "$OUT_22" ] || no "OUT_22: SUT produced no output (capture fork-fail?)"
re_absent='PROMPT-LOOP-APPENDIX\.md not found'
re_orphan=$'\n''WARN.*§3'
re_summary_absent='PROMPT-LOOP-APPENDIX\.md \(absent\)'
if [[ "$OUT_22" =~ $re_absent ]] && [[ $'\n'"$OUT_22" =~ $re_orphan ]] && [ "$RC_22" -eq 0 ] && [[ "$OUT_22" =~ $re_summary_absent ]]; then
  ok "22 CHECK 2 appendix coverage: missing appendix → degraded WARN naming it, §3 still orphan, exit 0, summary says '(absent)'"
else
  no "22 CHECK 2 appendix coverage: expected degraded WARN + §3 orphan + exit 0 + summary '(absent)' (rc=$RC_22 out=[$OUT_22])"
fi

# --- 23. summary's "(checked)"/"(absent)" claim is DERIVED from the actual scan, not a hardcoded
# string (kit issue #1003 round 3, N3/RDD-WARNING — the prior version of this test only checked
# that the literal filename appeared, which is true even when the file was never scanned; see the
# mutation control below for the actual anti-silent-zero proof). Real proof here: the SAME summary
# line reads "(checked)" on the present-and-scanned fixture (OUT_20) and "(absent)" on the
# genuinely-absent fixture (OUT_22) — two different, self-consistent claims, not one constant string.
re_summary_checked='PROMPT-LOOP-APPENDIX\.md \(checked\)'
if [[ "$OUT_20" =~ $re_summary_checked ]] && [[ "$OUT_22" =~ $re_summary_absent ]]; then
  ok "23 summary's appendix-scan status is derived, not hardcoded: '(checked)' when scanned (OUT_20), '(absent)' when not (OUT_22)"
else
  no "23 summary does not distinguish checked vs. absent appendix status (OUT_20=[$OUT_20] OUT_22=[$OUT_22])"
fi

# --- 24. CHECK 5: every PROMPT-LOOP-APPENDIX.md#<anchor> citation in PROMPT-LOOP.md must resolve
# to a real '## <anchor>' heading in the appendix (kit issue #1003 round 3, RDD suggestion).
PROMPTLOOP_ANCHOR_OK="$FIXTURES/promptloop-anchor-ok.md"
PROMPTLOOP_ANCHOR_BAD="$FIXTURES/promptloop-anchor-bad.md"
APPENDIX_WITH_ANCHOR="$FIXTURES/appendix-with-anchor.md"

OUT_24OK=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_CLEAN" \
           RSDD_PROMPTLOOP="$PROMPTLOOP_ANCHOR_OK" RSDD_PROMPTLOOP_APPENDIX="$APPENDIX_WITH_ANCHOR" \
           RSDD_README="$README_MATCH" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
           bash "$SUT" 2>&1)
[ -n "$OUT_24OK" ] || no "OUT_24OK: SUT produced no output (capture fork-fail?)"
if [[ $'\n'"$OUT_24OK" =~ $'\n''WARN.*anchor' ]]; then
  no "24a CHECK 5: unexpected anchor WARN when the cited anchor genuinely exists (out=[$OUT_24OK])"
else
  ok "24a CHECK 5: a citation to an anchor that genuinely exists in the appendix produces no anchor WARN"
fi

OUT_24BAD=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_CLEAN" \
            RSDD_PROMPTLOOP="$PROMPTLOOP_ANCHOR_BAD" RSDD_PROMPTLOOP_APPENDIX="$APPENDIX_WITH_ANCHOR" \
            RSDD_README="$README_MATCH" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
            bash "$SUT" 2>&1)
[ -n "$OUT_24BAD" ] || no "OUT_24BAD: SUT produced no output (capture fork-fail?)"
if [[ "$OUT_24BAD" =~ WARN.*does-not-exist-anchor ]]; then
  ok "24b CHECK 5: a citation to a nonexistent anchor produces a named anchor WARN"
else
  no "24b CHECK 5: expected an anchor WARN naming 'does-not-exist-anchor' (out=[$OUT_24BAD])"
fi
if [[ "$OUT_24BAD" == *'broken appendix-anchor citation(s)'* ]] && [[ "$OUT_24BAD" == *'Findings: 0 stale-count · 0 orphan section(s) · 0 broken citation(s) · 0 readme-range · 1 broken appendix-anchor'* ]]; then
  ok "24c CHECK 5: summary Findings line counts exactly 1 broken appendix-anchor citation"
else
  no "24c CHECK 5: summary Findings line did not report exactly 1 broken appendix-anchor citation (out=[$OUT_24BAD])"
fi

# =============================================================================
# Teeth — mutation proof (one mutant per check + the readability guard)
# =============================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  mutant="$(mktemp)"; mutant2="$(mktemp)"; mutant3="$(mktemp)"; mutant4="$(mktemp)"
  mutant5="$(mktemp)"; mutant6="$(mktemp)"; mutant7="$(mktemp)"
  mutant8="$(mktemp)"; mutant9="$(mktemp)"
  trap 'rm -f "$mutant" "$mutant2" "$mutant3" "$mutant4" "$mutant5" "$mutant6" "$mutant7" "$mutant8" "$mutant9"' EXIT

  # ---- CHECK 1 teeth: break SECTION-COUNT-GREP, clean fixture must WARN ------
  echo "-- teeth CHECK 1: SECTION-COUNT-GREP mutant must break the clean-scenario assertion --"
  # Mutate: replace the literal text [0-9]+ in the SECTION-COUNT-GREP sentinel line
  # with NOMATCH. sed BRE: \[ and \] are literal brackets; + is literal (not a
  # quantifier in BRE). Result: grep -E '^## NOMATCH.' never matches any ## N.
  # header, so real_count=0 while skill-clean.md declares "3 sections" → CHECK 1 fires.
  sed '/SECTION-COUNT-GREP/s/\[0-9\]+/NOMATCH/' "$SUT" > "$mutant"
  if ! grep -q 'NOMATCH' "$mutant"; then
    no "teeth CHECK 1: could not build mutant (SECTION-COUNT-GREP sentinel not found — did the guard change?)"
  else
    MUTANT_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_CLEAN" \
                 RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_MATCH" \
                 RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                 bash "$mutant" 2>&1)
    # Empty-capture guard.
    [ -n "$MUTANT_OUT" ] || no "MUTANT_OUT: SUT produced no output (capture fork-fail?)"
    re=$'\n'WARN
    if [[ $'\n'"$MUTANT_OUT" =~ $re ]]; then
      ok "teeth CHECK 1: broken real-count mutant WARNs on clean fixture → test 9 would go RED"
    else
      no "teeth CHECK 1: mutant produced no WARN on clean fixture — no effect (THEATER)"
    fi
    re='Findings:.*[1-9]'
    if [[ "$MUTANT_OUT" =~ $re ]]; then
      ok "teeth CHECK 1: mutant summary shows ≥1 finding → test 10 would go RED"
    else
      no "teeth CHECK 1: mutant summary still shows 0 findings — no effect on summary (THEATER)"
    fi
  fi

  # ---- CHECK 2 teeth: neuter orphan detection, clean fixture must false-WARN --
  echo "-- teeth CHECK 2: orphan-negation mutant must break the clean-scenario no-WARN assertion --"
  # Mutate: remove the ! negation from the orphan-detection grep condition.
  # Original: if ! grep -qE "§${n}..." — WARNs when pattern NOT found (section absent).
  # Mutant:   if   grep -qE "§${n}..." — WARNs when pattern IS found (section present).
  # On the clean fixture (all §N referenced), grep succeeds for every section →
  # a false WARN fires for each → test 9 (clean scenario: no WARN lines) goes RED.
  sed 's/if ! grep -qE/if grep -qE/' "$SUT" > "$mutant2"
  if grep -q 'if ! grep -qE' "$mutant2"; then
    no "teeth CHECK 2: could not build mutant (negation still present after sed — did the guard change?)"
  else
    MUTANT2_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_CLEAN" \
                  RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_MATCH" \
                  RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                  bash "$mutant2" 2>&1)
    # Empty-capture guard.
    [ -n "$MUTANT2_OUT" ] || no "MUTANT2_OUT: SUT produced no output (capture fork-fail?)"
    re=$'\n''WARN.*top-level METHODOLOGY'
    if [[ $'\n'"$MUTANT2_OUT" =~ $re ]]; then
      ok "teeth CHECK 2: negation-mutant false-WARNs orphans on clean fixture → test 9 would go RED"
    else
      no "teeth CHECK 2: mutant produced no orphan WARN on clean fixture — no effect (THEATER)"
    fi
  fi

  # ---- CHECK 3 teeth: drop repo-root fallback, repo-only cite must false-WARN -
  echo "-- teeth CHECK 3: no-repo-root mutant must break the repo-only-cite assertion (test 6) --"
  # Mutate: remove the repo-root fallback from the citation existence check.
  # Original: if [ ! -f "$kit_target" ] && [ ! -f "$repo_target" ]; then
  # Mutant:   if [ ! -f "$kit_target" ]; then
  # retros/repo-only.md exists only at repo root. Without the fallback, kit_target
  # does not resolve → false WARN fires for repo-only.md → test 6 goes RED.
  # sed BRE: \[ and \] are literal brackets; \$ is literal $; && is literal &&.
  sed 's/ && \[ ! -f "\$repo_target" \]//' "$SUT" > "$mutant3"
  if grep -q '"$repo_target"' "$mutant3"; then
    no "teeth CHECK 3: could not build mutant (repo-root clause still present — did the guard change?)"
  else
    MUTANT3_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_BAD" \
                  RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_MISMATCH" \
                  RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                  bash "$mutant3" 2>&1)
    # Empty-capture guard.
    [ -n "$MUTANT3_OUT" ] || no "MUTANT3_OUT: SUT produced no output (capture fork-fail?)"
    if [[ "$MUTANT3_OUT" == *repo-only* ]]; then
      ok "teeth CHECK 3: no-repo-root mutant false-WARNs for repo-only.md → test 6 would go RED"
    else
      no "teeth CHECK 3: mutant did not WARN for repo-only.md — no effect (THEATER)"
    fi
  fi

  # ---- readability-guard teeth: drop the [ -r ] check; unreadable file must stop exiting 1 --
  echo "-- teeth OP: readability-guard mutant must break the unreadable-METHODOLOGY assertion (test 13) --"
  if [ "$(id -u)" -eq 0 ]; then
    echo "  SKIP  teeth OP: running as root (chmod 000 still readable)"
  else
    # Mutate: strip the "|| [ ! -r "$RSDD_METHODOLOGY" ]" readability clause.
    # sed BRE: \[ \] literal brackets, \$ literal $. Only the -f check remains, so an
    # unreadable-but-existing file passes the guard → grep exit 2 → real_count=0 →
    # spurious findings and exit 0 instead of the operational exit 1 → test 13 goes RED.
    sed 's/ || \[ ! -r "\$RSDD_METHODOLOGY" \]//' "$SUT" > "$mutant4"
    if grep -q '! -r "$RSDD_METHODOLOGY"' "$mutant4"; then
      no "teeth OP: could not build mutant (readability clause still present — did the guard change?)"
    else
      UR2="$(mktemp)"; cp "$METHOD" "$UR2"; chmod 000 "$UR2"
      MUT4_RC=$(RSDD_METHODOLOGY="$UR2" RSDD_SKILL="$SKILL_CLEAN" \
                RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_MATCH" \
                RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                bash "$mutant4" 2>&1; echo $?)
      chmod 644 "$UR2"; rm -f "$UR2"
      if [[ "${MUT4_RC##*$'\n'}" == "1" ]]; then
        no "teeth OP: mutant still exited 1 on unreadable file — no effect (THEATER)"
      else
        ok "teeth OP: no-readability-guard mutant fails to exit 1 on unreadable METHODOLOGY → test 13 would go RED"
      fi
    fi
  fi

  # ---- README-range teeth: break README-RANGE-GREP; matching README must WARN --
  echo "-- teeth README-range: README-RANGE-GREP mutant must break the clean-README assertion (test 9) --"
  # Mutate: replace [0-9]+ in the README-RANGE-GREP sentinel line with NOMATCH.
  # Result: grep -oE '§1[-–]§NOMATCH' never matches any §1–§N declaration, so
  # readme_range_line is empty → "declares no §-range" WARN fires even on a correctly
  # declared README → test 9 (no WARN in clean scenario) goes RED.
  sed '/README-RANGE-GREP/s/\[0-9\]+/NOMATCH/' "$SUT" > "$mutant5"
  if ! grep -q 'NOMATCH' "$mutant5"; then
    no "teeth README-range: could not build mutant (README-RANGE-GREP sentinel not found — did the guard change?)"
  else
    MUTANT5_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_CLEAN" \
                  RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_MATCH" \
                  RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                  bash "$mutant5" 2>&1)
    # Empty-capture guard.
    [ -n "$MUTANT5_OUT" ] || no "MUTANT5_OUT: SUT produced no output (capture fork-fail?)"
    re=$'\n''WARN.*(§-range|README)'
    if [[ $'\n'"$MUTANT5_OUT" =~ $re ]]; then
      ok "teeth README-range: broken regex causes WARN on matching README → test 9 would go RED"
    else
      no "teeth README-range: mutant produced no README-range WARN on matching README — no effect (THEATER)"
    fi
  fi

  # ---- SKILL-COUNT-GREP anchor teeth: naive anchor picks decoy "5 sections" --
  echo "-- teeth ANCHOR: SKILL-COUNT-GREP naive mutant must break the decoy-SKILL assertion (test 18) --"
  # Mutate: on the SKILL-COUNT-GREP sentinel line, change 'all[' to '[' so the
  # anchor 'all[[:space:]]+[0-9]+[[:space:]]+sections' degrades to the naive
  # '[[:space:]]+[0-9]+[[:space:]]+sections'. On skill-decoy.md the naive pattern
  # hits "5 sections" first (the decoy line precedes the real one) → declared_count=5
  # ≠ real_count=3 → stale-count WARN fires → test 18 (no stale-count WARN on
  # decoy-SKILL) goes RED.
  sed '/SKILL-COUNT-GREP/s/all\[/[/' "$SUT" > "$mutant6"
  if grep -q "all\[" "$mutant6"; then
    no "teeth ANCHOR: could not build mutant (SKILL-COUNT-GREP anchor still has 'all[' — did the guard change?)"
  else
    MUTANT6_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_DECOY" \
                  RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_README="$README_MATCH" \
                  RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                  bash "$mutant6" 2>&1)
    # Empty-capture guard.
    [ -n "$MUTANT6_OUT" ] || no "MUTANT6_OUT: SUT produced no output (capture fork-fail?)"
    re=$'\n''WARN.*(count mismatch|declares no section)'
    if [[ $'\n'"$MUTANT6_OUT" =~ $re ]]; then
      ok "teeth ANCHOR: naive-anchor mutant picks decoy '5 sections' → stale-count WARN fires → test 18 would go RED"
    else
      no "teeth ANCHOR: mutant did not produce stale-count WARN on decoy-SKILL — no effect (THEATER)"
    fi
  fi

  # ---- CHECK 2 appendix-coverage teeth: drop the appendix from _check_files ---
  echo "-- teeth CHECK 2 appendix: no-appendix-scan mutant must break test 20 (§3-in-appendix-only) --"
  # Mutate: neuter the "-f "$RSDD_PROMPTLOOP_APPENDIX"" existence guard so the appendix
  # is NEVER added to _check_files even when it exists and carries the §N reference.
  # On test 20's fixtures (§3 lives only in the appendix), the orphan §3 WARN then
  # fires again → test 20 would go RED.
  sed 's/if \[ -f "\$RSDD_PROMPTLOOP_APPENDIX" \]; then/if false; then/' "$SUT" > "$mutant7"
  if grep -q 'if \[ -f "\$RSDD_PROMPTLOOP_APPENDIX" \]; then' "$mutant7"; then
    no "teeth CHECK 2 appendix: could not build mutant (appendix existence guard still present — did the guard change?)"
  else
    MUTANT7_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_MISSING3" \
                  RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_PROMPTLOOP_APPENDIX="$APPENDIX_HAS3" \
                  RSDD_README="$README_MATCH" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                  bash "$mutant7" 2>&1)
    [ -n "$MUTANT7_OUT" ] || no "MUTANT7_OUT: SUT produced no output (capture fork-fail?)"
    re=$'\n''WARN.*§3'
    if [[ $'\n'"$MUTANT7_OUT" =~ $re ]]; then
      ok "teeth CHECK 2 appendix: no-scan mutant false-WARNs §3 orphan even though the appendix carries it → test 20 would go RED"
    else
      no "teeth CHECK 2 appendix: mutant produced no §3 orphan WARN — no effect (THEATER)"
    fi
  fi

  # ---- N3 teeth: surgically delete ONLY the `_check_files+=` append line (reviewer's own repro) --
  echo "-- teeth N3: surgical append-line deletion must break test 23's '(checked)' claim on OUT_20 --"
  # Mutate: replace ONLY the `_check_files+=("$RSDD_PROMPTLOOP_APPENDIX")` line's effect with a
  # bash no-op (`:`), leaving the `-f` guard, the `else` WARN, and the _appendix_scan_status
  # derivation loop all textually intact and the script syntactically valid (a bare delete leaves
  # an empty then-branch, a bash syntax error — confirmed by hand: that construction fails to
  # parse, which would make this tooth prove nothing about the ACTUAL fix). This is deliberately
  # narrower than mutant7 (which neuters the whole `-f` guard) — it is the exact mutant the
  # round-2 reviewer ran and found that only test 20 caught (22/23 stayed green against the OLD
  # hardcoded-string summary). Because _appendix_scan_status is now derived by re-scanning
  # _check_files itself (not a separate flag), neutering this one line must ALSO flip OUT_20's
  # summary from "(checked)" to "(absent)" — proving test 23 is no longer independent of test
  # 20's coverage.
  sed 's/_check_files+=("\$RSDD_PROMPTLOOP_APPENDIX")/:/' "$SUT" > "$mutant8"
  if grep -q '_check_files+=("\$RSDD_PROMPTLOOP_APPENDIX")' "$mutant8"; then
    no "teeth N3: could not build mutant (append line still present — did the guard change?)"
  else
    MUTANT8_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_MISSING3" \
                  RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_PROMPTLOOP_APPENDIX="$APPENDIX_HAS3" \
                  RSDD_README="$README_MATCH" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                  bash "$mutant8" 2>&1)
    [ -n "$MUTANT8_OUT" ] || no "MUTANT8_OUT: SUT produced no output (capture fork-fail?)"
    if [[ "$MUTANT8_OUT" == *'PROMPT-LOOP-APPENDIX.md (absent)'* ]]; then
      ok "teeth N3: surgical append-line deletion flips OUT_20's summary to '(absent)' → test 23 would go RED"
    else
      no "teeth N3: mutant still reports '(checked)' on OUT_20 — summary status not actually derived from the scan (THEATER)"
    fi
  fi

  # ---- CHECK 5 teeth: neuter the anchor-citation loop; a broken anchor must stop WARNing --------
  echo "-- teeth CHECK 5: anchor-loop mutant must break test 24b (nonexistent-anchor WARN) --"
  # Mutate: force the CHECK 5 file-presence guard to false, so the anchor-citation loop never runs
  # even when both PROMPT-LOOP.md and the appendix exist.
  sed 's/if \[ -f "\$RSDD_PROMPTLOOP" \] \&\& \[ -f "\$RSDD_PROMPTLOOP_APPENDIX" \]; then/if false; then/' "$SUT" > "$mutant9"
  if grep -q 'if \[ -f "\$RSDD_PROMPTLOOP" \] \&\& \[ -f "\$RSDD_PROMPTLOOP_APPENDIX" \]; then' "$mutant9"; then
    no "teeth CHECK 5: could not build mutant (CHECK 5 guard still present — did the guard change?)"
  else
    MUTANT9_OUT=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_CLEAN" \
                  RSDD_PROMPTLOOP="$PROMPTLOOP_ANCHOR_BAD" RSDD_PROMPTLOOP_APPENDIX="$APPENDIX_WITH_ANCHOR" \
                  RSDD_README="$README_MATCH" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                  bash "$mutant9" 2>&1)
    [ -n "$MUTANT9_OUT" ] || no "MUTANT9_OUT: SUT produced no output (capture fork-fail?)"
    if [[ "$MUTANT9_OUT" =~ WARN.*does-not-exist-anchor ]]; then
      no "teeth CHECK 5: mutant still WARNs on the broken anchor — no effect (THEATER)"
    else
      ok "teeth CHECK 5: neutered anchor-citation guard silently drops the broken-anchor WARN → test 24b would go RED"
    fi
  fi

  # TOOTH SYMLINK-TOOLBELT: revert -P/pwd -P to plain cd/pwd (kit issue #1024 round 3, MEDIUM).
  # CRITICAL: never write a mutant "into a render dir's toolbelt/" — a real render's toolbelt/ IS
  # the real toolbelt (F1 completion symlinks it as a whole unit), so a cp through that path
  # would overwrite the LIVE tracked script (this happened once while writing this tooth; caught
  # by test 19 diverging unexpectedly, restored via git diff before commit). This tooth instead
  # builds a fully SYNTHETIC scratch kit (mktemp -d) that never touches the real toolbelt/.
  echo "-- teeth SYMLINK-TOOLBELT: revert -P to plain cd/pwd --"
  mutant_tsym="$(mktemp)"
  sed -e 's/cd -P "\$(dirname "\$0")\/\.\." \&\& pwd -P/cd "$(dirname "$0")\/.." \&\& pwd/' \
      -e 's/cd -P "\$KIT\/\.\." \&\& pwd -P/cd "$KIT\/.." \&\& pwd/' \
      "$SUT" > "$mutant_tsym"
  if diff -q "$SUT" "$mutant_tsym" >/dev/null 2>&1; then
    no "teeth SYMLINK-TOOLBELT pre-check: mutant = SUT — -P pattern not found"
  else
    ok "teeth SYMLINK-TOOLBELT pre-check: mutant differs (-P reverted to plain cd/pwd)"
  fi
  scratch_tsym="$(mktemp -d)"
  mkdir -p "$scratch_tsym/toolbelt" "$scratch_tsym/skills/research-sdd" "$scratch_tsym/profile/general"
  cp "$mutant_tsym" "$scratch_tsym/toolbelt/verify-doc-consistency.sh"
  chmod +x "$scratch_tsym/toolbelt/verify-doc-consistency.sh"
  printf '# retro\n\n## 1. Section\n' > "$scratch_tsym/METHODOLOGY.md"
  printf '# skill\n' > "$scratch_tsym/skills/research-sdd/SKILL.md"
  printf '# loop\n' > "$scratch_tsym/PROMPT-LOOP.md"
  ln -s "$scratch_tsym/toolbelt" "$scratch_tsym/profile/general/toolbelt"
  bash "$scratch_tsym/toolbelt/verify-doc-consistency.sh" >/dev/null 2>&1; RC_DIRECT_TSYM=$?
  bash "$scratch_tsym/profile/general/toolbelt/verify-doc-consistency.sh" >/dev/null 2>&1; RC_RENDER_TSYM=$?
  if [ "$RC_DIRECT_TSYM" -eq 0 ] && [ "$RC_RENDER_TSYM" -ne 0 ]; then
    ok "teeth SYMLINK-TOOLBELT: reverted mutant diverges through a symlinked toolbelt/ (direct=0 render=$RC_RENDER_TSYM) → -P fix has teeth"
  else
    no "teeth SYMLINK-TOOLBELT: reverted mutant did not diverge — -P fix check is THEATER (direct=$RC_DIRECT_TSYM render=$RC_RENDER_TSYM)"
  fi
  rm -rf "$scratch_tsym"
  rm -f "$mutant_tsym"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
