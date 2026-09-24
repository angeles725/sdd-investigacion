#!/usr/bin/env bash
# verify-cd-physical.test.sh — behavior + mutation-control suite for verify-cd-physical.sh
# (kit issue #1024 round 4, item 3: the systemic lint guard against the logical-cd-through-a-
# symlinked-toolbelt bug class; round 5 adds the §7 precision fixes and the default-scope change).
#
# Checks (functional, always run — kit issue #1024 round 5, general cleanup: this list is kept in
# sync with the test numbers actually used below; a numbering drift here once meant this comment
# no longer described the tests it claimed to):
#   1    script exists
#   2    script executable
#   3    a non-climbing dirname($0) derivation (no "..") is NOT flagged (harmless, over 70 real
#        toolbelt scripts use exactly this idiom)
#   4    a climbing derivation lacking -P IS flagged (HIT), exit 1
#   5    the identical climbing derivation WITH cd -P/pwd -P is NOT flagged, exit 0
#   5b   `cd -P` alone (bare `pwd`, no `-P` on it) is NOT flagged — `cd -P` alone is load-bearing
#   5c   word-boundary precision: `$KX` does not falsely match a tainted `K` (round 5, Opus #2)
#   5d   per-cd-invocation precision: `cd .. && cd -P .` IS flagged — the climbing `cd` has no
#        `-P` of its own, even though a later, non-climbing `cd -P` sits on the same line
#   5e   cheap shape: `dirname -- "$0"` is recognised as rooted (round 5, Opus #2)
#   5f   cheap shape: `dirname "${0}"` (braced form) is recognised as rooted
#   5g   cheap shape: a `local`/`export` prefix before the variable name is recognised
#   5h   the `;`-split cannot glob-expand a line holding a literal glob metacharacter (RDD
#        R4-unquoted-split-globs)
#   5i   climb_seen (formerly the misleadingly-named pattern_seen): an all-compliant file is NOT
#        reported as no-match — the construct was seen, it just happened to pass
#   6    a chained two-hop derivation (var A non-climbing, var B climbs via A) is flagged on the
#        SECOND line, proving taint propagates across lines/variables
#   7    a `cd`/`pwd` unrelated to $0/BASH_SOURCE (dirname of an arbitrary variable) is excluded
#   8    a `VAR1=...; VAR2=...` two-statement physical line (';'-separated) is split and taint
#        still propagates from VAR1 to VAR2 on the same line
#   9    the allow-marker `# LINT-CD-PHYSICAL-OK: <reason>` on the flagged line suppresses the HIT
#        (reported as ALLOWED) and the run still exits 0
#   10   the allow-marker on the line BEFORE the flagged line also works
#   11   an allow-marker with NO reason text still counts as a HIT (reason is required)
#   12   absent-input: no scan directory found → exit 2, typed message
#   13   empty-input: scan directory exists, no *.sh files → exit 2, typed message
#   14   no-match: files scanned, pattern never seen → exit 0, typed "no-match" message (not a
#        bare silent 0 — CLAUDE.md §7 anti-silent-zero)
#   15   real-corpus smoke test: a bare, no-argument `verify-cd-physical.sh` on the real kit
#        exits 0 (round 5, Opus finding 1 — no whole-file `grep -v` filter; the default scope now
#        excludes tests/ entirely, so there is nothing left for a filter to hide)
#   15b  an EXPLICIT tests/ directory argument is still scanned in full — default-scope exclusion
#        is a default, not a capability limit (round 5, Opus finding 1)
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

# ── 5c. Word-boundary precision (kit issue #1024 round 5, Opus finding 2, §7): a plain substring
#        check would let `$KX` count as a reference to a tainted `K` — `$KX` is a genuinely
#        unrelated path here and must not be flagged.
box5c="$(mkbox case-word-boundary)"
cat > "$box5c/fixed.sh" <<'EOF'
#!/usr/bin/env bash
K="$(cd "$(dirname "$0")" && pwd)"
KX="/unrelated/path"
OTHER="$(cd "$KX/.." && pwd)"
EOF
OUT5C="$(bash "$SUT" "$box5c" 2>&1)"; RC5C=$?
if [ "$RC5C" -eq 0 ] && ! printf '%s' "$OUT5C" | grep -q 'HIT'; then
  ok "5c word-boundary: \$KX does not falsely match a tainted K"
else
  no "5c word-boundary: \$KX was wrongly treated as a reference to tainted K (rc=$RC5C out=[$OUT5C])"
fi

# ── 5d. Per-cd-invocation -P precision (kit issue #1024 round 5, Opus finding 2, §7): "does -P
#        appear ANYWHERE on the line" let `cd .. && cd -P .` slip through — the second,
#        non-climbing `cd -P` "covered" the first, climbing `cd ..`, which has none of its own.
box5d="$(mkbox case-climb-precision)"
cat > "$box5d/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")" && cd .. && cd -P . && pwd)"
EOF
OUT5D="$(bash "$SUT" "$box5d" 2>&1)"; RC5D=$?
if [ "$RC5D" -eq 1 ] && printf '%s' "$OUT5D" | grep -q 'HIT.*fixed\.sh:2'; then
  ok "5d per-cd precision: 'cd .. && cd -P .' IS flagged — the climbing cd has no -P of its own"
else
  no "5d per-cd precision: 'cd .. && cd -P .' was wrongly left unflagged (rc=$RC5D out=[$OUT5D])"
fi

# ── 5e. Cheap shape: `dirname -- "$0"` is recognised as rooted (kit issue #1024 round 5, Opus
#        finding 2) — the literal `--` token used to make this invisible to the rooted check.
box5e="$(mkbox case-dirname-dashdash)"
cat > "$box5e/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname -- "$0")/.." && pwd)"
EOF
OUT5E="$(bash "$SUT" "$box5e" 2>&1)"; RC5E=$?
if [ "$RC5E" -eq 1 ] && printf '%s' "$OUT5E" | grep -q 'HIT.*fixed\.sh:2'; then
  ok "5e cheap shape: 'dirname -- \"\$0\"' is recognised as a rooted, climbing derivation"
else
  no "5e cheap shape: 'dirname -- \"\$0\"' was not recognised (rc=$RC5E out=[$OUT5E])"
fi

# ── 5f. Cheap shape: `dirname "${0}"` (braced form) is recognised as rooted.
box5f="$(mkbox case-dirname-braced)"
cat > "$box5f/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "${0}")/.." && pwd)"
EOF
OUT5F="$(bash "$SUT" "$box5f" 2>&1)"; RC5F=$?
if [ "$RC5F" -eq 1 ] && printf '%s' "$OUT5F" | grep -q 'HIT.*fixed\.sh:2'; then
  ok "5f cheap shape: 'dirname \"\${0}\"' (braced) is recognised as a rooted, climbing derivation"
else
  no "5f cheap shape: 'dirname \"\${0}\"' was not recognised (rc=$RC5F out=[$OUT5F])"
fi

# ── 5g. Cheap shape: a `local`/`export` prefix before the variable name is recognised.
box5g="$(mkbox case-local-export)"
cat > "$box5g/fixed.sh" <<'EOF'
#!/usr/bin/env bash
local KIT="$(cd "$(dirname "$0")/.." && pwd)"
export KIT2="$(cd "$KIT/.." && pwd)"
EOF
OUT5G="$(bash "$SUT" "$box5g" 2>&1)"; RC5G=$?
if [ "$RC5G" -eq 1 ] && printf '%s' "$OUT5G" | grep -q 'HIT.*fixed\.sh:2'; then
  ok "5g cheap shape: a 'local' prefix before the variable name is recognised"
else
  no "5g cheap shape: 'local KIT=...' was not recognised (rc=$RC5G out=[$OUT5G])"
fi

# ── 5h. Unquoted split cannot glob (kit issue #1024 round 5, Opus finding 2, RDD
#        R4-unquoted-split-globs): a line containing a literal glob metacharacter must not make
#        the checker crash, hang, or silently expand against real filesystem entries. Build the
#        fixture directory FIRST so a glob-vulnerable split would have something to expand into.
box5h="$(mkbox case-unquoted-split-globs)"
touch "$box5h/somefile.txt" "$box5h/anotherfile.txt"
cat > "$box5h/fixed.sh" <<'EOF'
#!/usr/bin/env bash
# a semicolon-separated line whose second statement's comment-adjacent text holds glob chars
here="$(cd "$(dirname "$0")" && pwd)"; KIT="$(cd "$here/.." && pwd)" # matches *.txt or [ab]*
EOF
OUT5H="$(bash "$SUT" "$box5h" 2>&1)"; RC5H=$?
if [ "$RC5H" -eq 1 ] && printf '%s' "$OUT5H" | grep -q 'HIT.*fixed\.sh:3' \
   && ! printf '%s' "$OUT5H" | grep -qi 'somefile\|anotherfile'; then
  ok "5h unquoted-split-globs: a glob-metachar-bearing line is handled correctly, no glob expansion leaked"
else
  no "5h unquoted-split-globs: glob metacharacters affected the result (rc=$RC5H out=[$OUT5H])"
fi

# ── 5i. climb_seen (formerly the misleadingly-named pattern_seen, kit issue #1024 round 5,
#        general cleanup): a file where EVERY climbing derivation is correctly -P'd must NOT be
#        reported as "no-match" — the construct WAS seen, it just happened to be compliant.
box5i="$(mkbox case-climb-seen-compliant)"
cat > "$box5i/fixed.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
echo "$KIT"
EOF
OUT5I="$(bash "$SUT" "$box5i" 2>&1)"; RC5I=$?
if [ "$RC5I" -eq 0 ] && ! printf '%s' "$OUT5I" | grep -qi 'no-match'; then
  ok "5i climb_seen: an all-compliant file is NOT reported as no-match (the pattern was seen)"
else
  no "5i climb_seen: an all-compliant file was wrongly reported as no-match (rc=$RC5I out=[$OUT5I])"
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

# ── 15. Real-corpus smoke test: bare `verify-cd-physical.sh` on the real kit ────
# kit issue #1024 round 5, Opus finding 1: no whole-file `grep -v` filter here any more — that
# filter hid real hits behind a name match, which is exactly the failure mode this suite exists
# to prevent elsewhere. The DEFAULT SCOPE now excludes tests/ entirely (see the SUT's own header
# comment), so this direct no-argument invocation never reaches this test file's own literal
# heredoc fixtures, or stage-retro.test.sh's (kit issue #976/#984, PR #1029 — not this PR's file),
# or any other *.test.sh's SUT-locating boilerplate — there is nothing left to filter. Assert the
# CHECKER'S OWN EXIT CODE directly (round 5, RDD R4/R3), not a derived "no HIT line" proxy.
OUT15="$(bash "$SUT" 2>&1)"; RC15=$?
if [ "$RC15" -eq 0 ]; then
  ok "15 real-corpus smoke test: bare 'verify-cd-physical.sh' on the real kit exits 0 (no filter, no args)"
else
  no "15 real-corpus smoke test: bare run found un-allow-marked hits (rc=$RC15) — out=[$OUT15]"
fi

# ── 15b. Default-scope exclusion is a DEFAULT, not a capability limit (kit issue #1024 round 5,
#         Opus finding 1): an EXPLICIT tests/ directory argument must still be scanned in full —
#         a real climbing violation placed directly under an explicitly-named tests/ dir must
#         still be caught.
box15b="$(mkbox case-explicit-tests-dir)"
mkdir -p "$box15b/tests"
cat > "$box15b/tests/some.test.sh" <<'EOF'
#!/usr/bin/env bash
KIT="$(cd "$(dirname "$0")/.." && pwd)"
EOF
OUT15B="$(bash "$SUT" "$box15b/tests" 2>&1)"; RC15B=$?
if [ "$RC15B" -eq 1 ] && printf '%s' "$OUT15B" | grep -q 'HIT.*some\.test\.sh:2'; then
  ok "15b explicit tests/ directory argument is still scanned in full (default-scope exclusion is a default, not a limit)"
else
  no "15b explicit tests/ directory argument was not scanned (rc=$RC15B out=[$OUT15B])"
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
