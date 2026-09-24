#!/usr/bin/env bash
# verify-cd-physical.test.sh — behavior + mutation-control suite for verify-cd-physical.sh
# (kit issue #1024 round 4, item 3: the systemic lint guard against the logical-cd-through-a-
# symlinked-toolbelt bug class).
#
# Checks (functional, always run):
#   1  script exists and is executable
#   2  a non-climbing dirname($0) derivation (no "..") is NOT flagged (harmless, over 70 real
#      toolbelt scripts use exactly this idiom)
#   3  a climbing derivation lacking -P IS flagged (HIT), exit 1
#   4  the identical climbing derivation WITH cd -P/pwd -P is NOT flagged, exit 0
#   5  a chained two-hop derivation (var A non-climbing, var B climbs via A) is flagged on the
#      SECOND line, proving taint propagates across lines/variables
#   6  a `cd`/`pwd` unrelated to $0/BASH_SOURCE (dirname of an arbitrary variable) is excluded
#   7  a `VAR1=...; VAR2=...` two-statement physical line (';'-separated) is split and taint
#      still propagates from VAR1 to VAR2 on the same line
#   8  the allow-marker `# LINT-CD-PHYSICAL-OK: <reason>` on the flagged line suppresses the HIT
#      (reported as ALLOWED) and the run still exits 0
#   9  the allow-marker on the line BEFORE the flagged line also works
#   10 an allow-marker with NO reason text still counts as a HIT (reason is required)
#   11 absent-input: no scan directory found → exit 2, typed message
#   12 empty-input: scan directory exists, no *.sh files → exit 2, typed message
#   13 no-match: files scanned, pattern never seen → exit 0, typed "no-match" message (not a bare
#      silent 0 — CLAUDE.md §7 anti-silent-zero)
#   14 real-corpus smoke test: running against this kit's OWN toolbelt/+install/ trees exits 0
#      (every real hit found by the initial sweep is either fixed or allow-marked — see the PR body
#      for the pre-fix hit list) and does not crash
#
# --prove-teeth: a fixture script with a logical (non -P) climbing cd must make the lint FAIL;
# the identical fixture given -P must make it PASS — proving the checker's core distinction has
# teeth, not just its own self-tests.
#
# Usage: verify-cd-physical.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-cd-physical.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== verify-cd-physical.test.sh =="

# ── 1. Script exists and is executable ───────────────────────────────────────
[ -f "$SUT" ] && ok "1 script exists" || no "1 script missing: $SUT"
[ -x "$SUT" ] && ok "2 script executable" || no "2 script not executable"

# mkbox <name> : an empty scan-target directory under $TMP
mkbox() { local d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# ── 3. Non-climbing derivation is NOT flagged ────────────────────────────────
box3="$(mkbox case-safe)"
cat > "$box3/safe.sh" <<'EOF'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "$HERE"
EOF
OUT3="$(bash "$SUT" "$box3" 2>&1)"; RC3=$?
if [ "$RC3" -eq 0 ] && ! printf '%s' "$OUT3" | grep -q 'HIT'; then
  ok "3 non-climbing dirname(\$0) derivation is NOT flagged (harmless, exit 0)"
else
  no "3 non-climbing derivation was wrongly flagged (rc=$RC3 out=[$OUT3])"
fi

# ── 4. Climbing derivation lacking -P IS flagged ─────────────────────────────
box4="$(mkbox case-climb-bad)"
cat > "$box4/bad.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.." && pwd)"
echo "$KIT"
EOF
OUT4="$(bash "$SUT" "$box4" 2>&1)"; RC4=$?
if [ "$RC4" -eq 1 ] && printf '%s' "$OUT4" | grep -q 'HIT.*bad\.sh:2'; then
  ok "4 climbing derivation lacking -P IS flagged (HIT, exit 1)"
else
  no "4 climbing derivation should have been flagged (rc=$RC4 out=[$OUT4])"
fi

# ── 5. Identical climbing derivation WITH -P is NOT flagged ─────────────────
box5="$(mkbox case-climb-fixed)"
cat > "$box5/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
echo "$KIT"
EOF
OUT5="$(bash "$SUT" "$box5" 2>&1)"; RC5=$?
if [ "$RC5" -eq 0 ] && ! printf '%s' "$OUT5" | grep -q 'HIT'; then
  ok "5 climbing derivation WITH -P is NOT flagged (exit 0)"
else
  no "5 -P'd climbing derivation was wrongly flagged (rc=$RC5 out=[$OUT5])"
fi

# ── 5b. `cd -P` alone (no `pwd -P`) is NOT flagged — verified empirically that `cd -P` alone is
#        load-bearing; a following bare `pwd` is redundant, not required. Kit issue #976/#984
#        (PR #1029)'s own fix to stage-retro.sh's KIT_REPO line uses exactly this shape.
box5b="$(mkbox case-climb-cdp-only)"
cat > "$box5b/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd -P "$(dirname "$0")/.." && pwd)"
echo "$KIT"
EOF
OUT5B="$(bash "$SUT" "$box5b" 2>&1)"; RC5B=$?
if [ "$RC5B" -eq 0 ] && ! printf '%s' "$OUT5B" | grep -q 'HIT'; then
  ok "5b climbing derivation with cd -P alone (bare pwd) is NOT flagged (exit 0)"
else
  no "5b cd-P-only climbing derivation was wrongly flagged (rc=$RC5B out=[$OUT5B])"
fi

# ── 6. Chained two-hop derivation: taint propagates across lines ────────────
box6="$(mkbox case-chained)"
cat > "$box6/chained.sh" <<'EOF'
#!/usr/bin/env bash
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SELF_DIR/.." && pwd)"
echo "$KIT"
EOF
OUT6="$(bash "$SUT" "$box6" 2>&1)"; RC6=$?
if [ "$RC6" -eq 1 ] && printf '%s' "$OUT6" | grep -q 'HIT.*chained\.sh:3' \
   && ! printf '%s' "$OUT6" | grep -q 'chained\.sh:2'; then
  ok "6 chained derivation: line 3 (the climb) is flagged, line 2 (safe hop) is not"
else
  no "6 chained-derivation taint propagation failed (rc=$RC6 out=[$OUT6])"
fi

# ── 7. dirname of an unrelated variable is excluded ──────────────────────────
box7="$(mkbox case-unrelated)"
cat > "$box7/unrelated.sh" <<'EOF'
#!/usr/bin/env bash
retro="$1"
target_root="$(cd "$(dirname "$(dirname "$retro")")" && pwd)"
echo "$target_root"
EOF
OUT7="$(bash "$SUT" "$box7" 2>&1)"; RC7=$?
if [ "$RC7" -eq 0 ] && ! printf '%s' "$OUT7" | grep -q 'HIT'; then
  ok "7 dirname of an unrelated variable (not \$0/BASH_SOURCE) is excluded"
else
  no "7 unrelated dirname was wrongly flagged (rc=$RC7 out=[$OUT7])"
fi

# ── 8. ';'-separated two-statement line: taint propagates on the same line ──
box8="$(mkbox case-semicolon)"
cat > "$box8/semi.sh" <<'EOF'
#!/usr/bin/env bash
here="$(cd "$(dirname "$0")" && pwd)"; KIT="$(cd "$here/.." && pwd)"
echo "$KIT"
EOF
OUT8="$(bash "$SUT" "$box8" 2>&1)"; RC8=$?
if [ "$RC8" -eq 1 ] && printf '%s' "$OUT8" | grep -q 'HIT.*semi\.sh:2'; then
  ok "8 ';'-separated statement on one physical line: taint propagates, climb flagged"
else
  no "8 ';'-separated statement taint propagation failed (rc=$RC8 out=[$OUT8])"
fi

# ── 9. Allow-marker on the flagged line suppresses the HIT ───────────────────
box9="$(mkbox case-allow-same-line)"
cat > "$box9/allowed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.." && pwd)"  # LINT-CD-PHYSICAL-OK: fixture, deliberately harmless
echo "$KIT"
EOF
OUT9="$(bash "$SUT" "$box9" 2>&1)"; RC9=$?
if [ "$RC9" -eq 0 ] && printf '%s' "$OUT9" | grep -q 'ALLOWED.*allowed\.sh:2' \
   && ! printf '%s' "$OUT9" | grep -q 'HIT'; then
  ok "9 allow-marker on the flagged line suppresses the HIT (ALLOWED, exit 0)"
else
  no "9 same-line allow-marker did not suppress the HIT (rc=$RC9 out=[$OUT9])"
fi

# ── 10. Allow-marker on the line BEFORE the flagged line also works ─────────
box10="$(mkbox case-allow-prev-line)"
cat > "$box10/allowed2.sh" <<'EOF'
#!/usr/bin/env bash
# LINT-CD-PHYSICAL-OK: fixture, deliberately harmless (marker on the line before)
KIT="$(cd "$(dirname "$0")/.." && pwd)"
echo "$KIT"
EOF
OUT10="$(bash "$SUT" "$box10" 2>&1)"; RC10=$?
if [ "$RC10" -eq 0 ] && printf '%s' "$OUT10" | grep -q 'ALLOWED.*allowed2\.sh:3' \
   && ! printf '%s' "$OUT10" | grep -q 'HIT'; then
  ok "10 allow-marker on the PRECEDING line also suppresses the HIT"
else
  no "10 preceding-line allow-marker did not suppress the HIT (rc=$RC10 out=[$OUT10])"
fi

# ── 11. Allow-marker with no reason text still counts as a HIT ──────────────
box11="$(mkbox case-allow-empty-reason)"
cat > "$box11/emptyreason.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.." && pwd)"  # LINT-CD-PHYSICAL-OK:
echo "$KIT"
EOF
OUT11="$(bash "$SUT" "$box11" 2>&1)"; RC11=$?
if [ "$RC11" -eq 1 ] && printf '%s' "$OUT11" | grep -q 'HIT.*emptyreason\.sh:2'; then
  ok "11 allow-marker with an empty reason still counts as a HIT (reason is required)"
else
  no "11 empty-reason allow-marker wrongly suppressed the HIT (rc=$RC11 out=[$OUT11])"
fi

# ── 12. absent-input: no scan directory found ────────────────────────────────
OUT12="$(bash "$SUT" "$TMP/does-not-exist-$$" 2>&1)"; RC12=$?
if [ "$RC12" -eq 2 ] && printf '%s' "$OUT12" | grep -qi 'absent-input'; then
  ok "12 absent-input: no scan directory found → exit 2, typed message"
else
  no "12 absent-input state not reported (rc=$RC12 out=[$OUT12])"
fi

# ── 13. empty-input: directory exists, no *.sh files ────────────────────────
box13="$(mkbox case-empty)"
printf 'not a shell script\n' > "$box13/readme.txt"
OUT13="$(bash "$SUT" "$box13" 2>&1)"; RC13=$?
if [ "$RC13" -eq 2 ] && printf '%s' "$OUT13" | grep -qi 'empty-input'; then
  ok "13 empty-input: directory exists, no *.sh files → exit 2, typed message"
else
  no "13 empty-input state not reported (rc=$RC13 out=[$OUT13])"
fi

# ── 14. no-match: files scanned, pattern never seen ──────────────────────────
box14="$(mkbox case-nomatch)"
cat > "$box14/plain.sh" <<'EOF'
#!/usr/bin/env bash
echo "hello world"
EOF
OUT14="$(bash "$SUT" "$box14" 2>&1)"; RC14=$?
if [ "$RC14" -eq 0 ] && printf '%s' "$OUT14" | grep -qi 'no-match'; then
  ok "14 no-match: files scanned, pattern never seen → exit 0, typed message"
else
  no "14 no-match state not reported (rc=$RC14 out=[$OUT14])"
fi

# ── 15. Real-corpus smoke test: this kit's own toolbelt/+install/ trees ─────
# Every real hit the initial sweep found is by now either fixed (-P applied) or allow-marked
# (stage-retro.sh: routed to its own PR; several test-driver SUT-locating derivations: never
# reached through a real render, allow-marked with that reason) — see the PR body for the
# pre-fix hit list this suite's own sweep produced.
#
# EXCLUDED, deliberately: THIS test file's own HIT/no-marker heredoc fixtures (tests 4, 11, and
# the teeth block above) are literal unmarked bad-pattern text BY DESIGN — marking them would
# break the very sub-tests that prove the checker detects an unmarked HIT at all. Their lines are
# filtered out of THIS assertion's view of the corpus; every other file, including every other
# *.test.sh, is held to the real, unfiltered standard.
#
# ALSO EXCLUDED: stage-retro.test.sh (kit issue #976/#984, PR #1029 — merged, not this PR's file
# to edit or allow-mark). It carries the IDENTICAL self-referential pattern: its own teeth build
# a mutant by string-substituting a "neutered" (deliberately -P-less) copy of an anchor line
# inside a quoted bash string literal, not executable code — the same false-positive class as
# this suite's own fixtures above, just in a file this PR does not own.
OUT15="$(bash "$SUT" 2>&1 | grep -v -e 'verify-cd-physical\.test\.sh' -e 'stage-retro\.test\.sh')"
RC15=0; printf '%s' "$OUT15" | grep -q '^HIT' && RC15=1
if [ "$RC15" -eq 0 ]; then
  ok "15 real-corpus smoke test: this kit's own toolbelt/+install/ trees are clean (excluding this suite's own fixture text)"
else
  no "15 real-corpus smoke test found un-allow-marked hits (rc=$RC15) — out=[$OUT15]"
fi

# ── TEETH ─────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: a fixture with a logical (non -P) climbing cd must FAIL; -P must PASS --"
  boxT="$(mkbox teeth-fixture)"
  cat > "$boxT/mut.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.." && pwd)"
echo "$KIT"
EOF
  OUTT1="$(bash "$SUT" "$boxT" 2>&1)"; RCT1=$?
  if [ "$RCT1" -eq 1 ]; then
    ok "teeth: logical (non -P) fixture makes the lint FAIL — the core distinction has teeth"
  else
    no "teeth: logical (non -P) fixture did NOT fail the lint — check is THEATER (rc=$RCT1 out=[$OUTT1])"
  fi
  sed -i 's/cd "\$(dirname "\$0")\/\.\." \&\& pwd/cd -P "$(dirname "$0")\/.." \&\& pwd -P/' "$boxT/mut.sh"
  OUTT2="$(bash "$SUT" "$boxT" 2>&1)"; RCT2=$?
  if [ "$RCT2" -eq 0 ]; then
    ok "teeth: the SAME fixture with -P applied makes the lint PASS — confirms it was the -P that mattered"
  else
    no "teeth: -P'd fixture still fails the lint — check has no bite (rc=$RCT2 out=[$OUTT2])"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
