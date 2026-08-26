#!/usr/bin/env bash
# verify-doc-consistency.test.sh — test suite for verify-doc-consistency.sh.
#
# Covers:
#   1–2   harness checks (SUT and fixtures exist)
#   3     CHECK 1 fires: declared count (2) != real count (3)
#   4     CHECK 2 fires: §3 not referenced in bad-skill or empty promptloop
#   5     CHECK 3 fires: retros/nonexistent-fixture.md resolves under neither root
#   6     repo-root fallback: retros/repo-only.md resolves at repo root → no WARN
#   7     all three bad-scenario findings appear in summary
#   8     exit 0 on advisory findings (WARN-only instrument)
#   9     clean scenario: zero WARN lines emitted
#   10    clean scenario: summary shows 0 findings in all categories
#   11    operational failure: missing METHODOLOGY → exit 1
#   12    summary always proves the instrument looked (real_count in output)
#   13    operational failure: unreadable METHODOLOGY → exit 1 (root-safe; skipped as root)
#   --prove-teeth:
#         one mutant per check (CHECK 1/2/3) plus the readability guard — each proves the
#         corresponding assertion goes red under a real mutation (theater controls fail loud)
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
PROMPTLOOP="$FIXTURES/promptloop-empty.md"
KIT_ROOT="$FIXTURES"          # kit root for citation resolution
REPO_ROOT="$FIXTURES/repo-root"  # repo root for citation resolution

# Helper: run guard with controlled fixture paths; captures combined stdout+stderr.
run_bad() {
  RSDD_METHODOLOGY="$METHOD" \
  RSDD_SKILL="$SKILL_BAD" \
  RSDD_PROMPTLOOP="$PROMPTLOOP" \
  RSDD_KIT="$KIT_ROOT" \
  RSDD_REPO="$REPO_ROOT" \
    bash "$SUT" 2>&1
}

run_clean() {
  RSDD_METHODOLOGY="$METHOD" \
  RSDD_SKILL="$SKILL_CLEAN" \
  RSDD_PROMPTLOOP="$PROMPTLOOP" \
  RSDD_KIT="$KIT_ROOT" \
  RSDD_REPO="$REPO_ROOT" \
    bash "$SUT" 2>&1
}

BAD_OUT="$(run_bad)"

# --- 3. CHECK 1 fires: declared count (2) != real count (3) -----------------
printf '%s\n' "$BAD_OUT" | grep -qiE 'count mismatch|declares no section' \
  && ok "3 CHECK 1: stale-count WARN fires when declared (2) != real (3)" \
  || no "3 CHECK 1: expected count-mismatch WARN (out=[$BAD_OUT])"

# --- 4. CHECK 2 fires: §3 not referenced ------------------------------------
printf '%s\n' "$BAD_OUT" | grep -qE '§3' \
  && ok "4 CHECK 2: orphan §3 WARN fires" \
  || no "4 CHECK 2: expected §3 orphan WARN (out=[$BAD_OUT])"

# --- 5. CHECK 3 fires: retros/nonexistent-fixture.md resolves under neither root ---
printf '%s\n' "$BAD_OUT" | grep -q 'nonexistent-fixture' \
  && printf '%s\n' "$BAD_OUT" | grep -q 'does not exist' \
  && ok "5 CHECK 3: broken citation WARN fires for retros/nonexistent-fixture.md" \
  || no "5 CHECK 3: expected broken-citation WARN for nonexistent-fixture.md (out=[$BAD_OUT])"

# --- 6. repo-root fallback: retros/repo-only.md must NOT produce a WARN -----
# skill-bad.md cites retros/repo-only.md which exists at $REPO_ROOT/retros/repo-only.md
# but NOT at $KIT_ROOT/retros/repo-only.md. Guard must resolve it at repo root → no WARN.
printf '%s\n' "$BAD_OUT" | grep -q 'repo-only' \
  && no "6 CHECK 3 repo-root fallback: got unexpected WARN for repo-only.md (out=[$BAD_OUT])" \
  || ok "6 CHECK 3 repo-root fallback: retros/repo-only.md (repo-root-only) produces no WARN"

# --- 7. All findings appear in bad-scenario summary -------------------------
printf '%s\n' "$BAD_OUT" | grep -qiE 'Findings:.*[1-9]' \
  && ok "7 bad-scenario summary reports ≥1 findings" \
  || no "7 bad-scenario summary: expected ≥1 findings (out=[$BAD_OUT])"

# --- 8. Exit 0 on advisory findings (WARN-only) -----------------------------
BAD_RC=$(RSDD_METHODOLOGY="$METHOD" RSDD_SKILL="$SKILL_BAD" \
         RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
         bash "$SUT" 2>&1; echo $?)
printf '%s\n' "$BAD_RC" | tail -1 | grep -q '^0$' \
  && ok "8 exit 0 on advisory findings (WARN-only instrument)" \
  || no "8 expected exit 0 on findings (got $BAD_RC)"

# --- 9. Clean scenario: zero WARN lines emitted -----------------------------
CLEAN_OUT="$(run_clean)"
printf '%s\n' "$CLEAN_OUT" | grep -qE '^WARN' \
  && no "9 clean scenario: unexpected WARN line (out=[$CLEAN_OUT])" \
  || ok "9 clean scenario: no WARN lines emitted"

# --- 10. Clean scenario: summary shows 0 findings in all categories ---------
printf '%s\n' "$CLEAN_OUT" | grep -qE 'Findings:.*0 stale-count.*0 orphan.*0 broken' \
  && ok "10 clean scenario: summary shows 0 findings in all categories" \
  || no "10 clean summary expected 0 findings (out=[$CLEAN_OUT])"

# --- 11. Operational failure: missing METHODOLOGY → exit 1 ------------------
OP_RC=$(RSDD_METHODOLOGY="/nonexistent/method.md" RSDD_SKILL="$SKILL_CLEAN" \
        RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
        bash "$SUT" 2>&1; echo $?)
printf '%s\n' "$OP_RC" | tail -1 | grep -q '^1$' \
  && ok "11 exit 1 on missing METHODOLOGY (operational failure)" \
  || no "11 expected exit 1 for missing METHODOLOGY (got $OP_RC)"

# --- 12. Summary proves instrument looked (anti-silent-zero) ----------------
# The clean summary must include the real_count (3) in the "## N. sections" phrase.
printf '%s\n' "$CLEAN_OUT" | grep -qE 'checked METHODOLOGY\.md \([0-9]+ top-level' \
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
          RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
          bash "$SUT" 2>&1; echo $?)
  chmod 644 "$UNREADABLE"; rm -f "$UNREADABLE"
  printf '%s\n' "$UR_RC" | tail -1 | grep -q '^1$' \
    && ok "13 exit 1 on unreadable METHODOLOGY (operational failure)" \
    || no "13 expected exit 1 for unreadable METHODOLOGY (got $UR_RC)"
fi

# =============================================================================
# Teeth — mutation proof (one mutant per check + the readability guard)
# =============================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  mutant="$(mktemp)"; mutant2="$(mktemp)"; mutant3="$(mktemp)"; mutant4="$(mktemp)"
  trap 'rm -f "$mutant" "$mutant2" "$mutant3" "$mutant4"' EXIT

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
                 RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                 bash "$mutant" 2>&1)
    if printf '%s\n' "$MUTANT_OUT" | grep -qE '^WARN'; then
      ok "teeth CHECK 1: broken real-count mutant WARNs on clean fixture → test 9 would go RED"
    else
      no "teeth CHECK 1: mutant produced no WARN on clean fixture — no effect (THEATER)"
    fi
    if printf '%s\n' "$MUTANT_OUT" | grep -qE 'Findings:.*[1-9]'; then
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
                  RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                  bash "$mutant2" 2>&1)
    if printf '%s\n' "$MUTANT2_OUT" | grep -qE '^WARN.*top-level METHODOLOGY'; then
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
                  RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                  bash "$mutant3" 2>&1)
    if printf '%s\n' "$MUTANT3_OUT" | grep -q 'repo-only'; then
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
                RSDD_PROMPTLOOP="$PROMPTLOOP" RSDD_KIT="$KIT_ROOT" RSDD_REPO="$REPO_ROOT" \
                bash "$mutant4" 2>&1; echo $?)
      chmod 644 "$UR2"; rm -f "$UR2"
      if printf '%s\n' "$MUT4_RC" | tail -1 | grep -q '^1$'; then
        no "teeth OP: mutant still exited 1 on unreadable file — no effect (THEATER)"
      else
        ok "teeth OP: no-readability-guard mutant fails to exit 1 on unreadable METHODOLOGY → test 13 would go RED"
      fi
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
