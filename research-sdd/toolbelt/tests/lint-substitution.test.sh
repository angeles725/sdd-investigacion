#!/usr/bin/env bash
# lint-substitution.test.sh — RED-first harness for lint-substitution.sh (kit issue #1121).
#
# Covers: existence/executable, FORM-A detection (unquoted bare-variable replacement operand)
# and its quoted negative control, FORM-B detection (awk interval expression inside an
# awk-invoking file) and its negative control, the three-state §7 discipline (absent-input,
# empty-input, no-match/violations-found), and a LIVE-CORPUS acceptance case (§7 "acceptance is
# a fleet sweep, not the fixtures") that runs the real lint against the real toolbelt tree and
# asserts zero violations — this is the regression guard that keeps the quoting fix (and the
# lib/retro-grammar.sh mawk-interval fix) from silently regressing.
#
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lint-substitution.sh"
TOOLBELT_ROOT="$HERE/.."

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== lint-substitution.test.sh =="

# 1. Existence
[ -f "$SUT" ] \
  && ok "1 lint-substitution.sh exists at $SUT" \
  || no "1 lint-substitution.sh NOT found at $SUT"

# 2. Executable
[ -f "$SUT" ] && [ -x "$SUT" ] \
  && ok "2 lint-substitution.sh is executable" \
  || no "2 lint-substitution.sh NOT executable (missing +x bit)"

if [ ! -f "$SUT" ]; then
  for n in 3 4 5 6 7 8 9 10; do no "$n (skipped: SUT missing)"; done
  echo "== $pass passed · $fail failed =="; exit 2
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 3. Absent-input: root does not exist -> exit 2, ABSENT-INPUT on stderr.
OUT="$(bash "$SUT" "$TMP/does-not-exist" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'ABSENT-INPUT'; then
  ok "3 absent root -> exit 2, ABSENT-INPUT reported"
else
  no "3 absent root failed (exit=$RC out=[$OUT])"
fi

# 4. Empty-input: root exists but has 0 *.sh files -> exit 0, EMPTY-INPUT reported (never
#    silently equal to the "0 violations / no-match" case, per §7 three-state discipline).
mkdir -p "$TMP/empty-root"
OUT="$(bash "$SUT" "$TMP/empty-root" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'EMPTY-INPUT'; then
  ok "4 empty root (0 .sh files) -> exit 0, EMPTY-INPUT reported"
else
  no "4 empty root failed (exit=$RC out=[$OUT])"
fi

# 5. FORM-A positive: unquoted bare-variable replacement operand -> exit 1, FORM-A reported.
# NOTE: the fixture's own vulnerable line is built via a PLACEHOLDER + runtime substitution
# (not spelled out literally here) so this TEST FILE's own source does not self-match the lint
# it exercises — see the analogous self-match note in lint-substitution.sh's own header comment.
mkdir -p "$TMP/formA-bad"
_fa_tpl='content="hello world"
anchor="hello"
repl="a&b"
printf %s "PLACEHOLDER{content/"PLACEHOLDERanchor"/PLACEHOLDERrepl}"'
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "${_fa_tpl//PLACEHOLDER/\$}"
} > "$TMP/formA-bad/site.sh"
unset _fa_tpl
OUT="$(bash "$SUT" "$TMP/formA-bad" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF 'FORM-A'; then
  ok "5 FORM-A unquoted bare-variable replacement -> exit 1, FORM-A reported"
else
  no "5 FORM-A positive failed (exit=$RC out=[$OUT])"
fi

# 6. FORM-A negative: the SAME site, properly quoted -> exit 0, no violation.
mkdir -p "$TMP/formA-good"
{
  printf '#!/usr/bin/env bash\n'
  printf 'content="hello world"\n'
  printf 'anchor="hello"\n'
  printf 'repl="a&b"\n'
  printf 'printf %%s "${content/"$anchor"/"$repl"}"\n'
} > "$TMP/formA-good/site.sh"
OUT="$(bash "$SUT" "$TMP/formA-good" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'NO-MATCH'; then
  ok "6 FORM-A quoted replacement -> exit 0, no violation (negative control)"
else
  no "6 FORM-A negative failed (exit=$RC out=[$OUT])"
fi

# 7. FORM-B positive: an awk interval expression inside an awk-invoking file -> exit 1, FORM-B.
# Same self-match avoidance as case 5: the interval '{1,6}' is assembled from a placeholder at
# runtime, not spelled out contiguously in this file's own source.
mkdir -p "$TMP/formB-bad"
_fb_tpl='{ if ($0 ~ /^#{PLACEHOLDER}[[:space:]]/) print "dirty" }'
_fb_awk="'${_fb_tpl//PLACEHOLDER/1,6}'"
{
  printf '#!/usr/bin/env bash\n'
  printf 'awk %s\n' "$_fb_awk"
} > "$TMP/formB-bad/site.sh"
unset _fb_tpl _fb_awk
OUT="$(bash "$SUT" "$TMP/formB-bad" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF 'FORM-B'; then
  ok "7 FORM-B awk interval expression -> exit 1, FORM-B reported"
else
  no "7 FORM-B positive failed (exit=$RC out=[$OUT])"
fi

# 8. FORM-B negative: the SAME awk-invoking file, chained '?' instead of an interval -> exit 0.
mkdir -p "$TMP/formB-good"
{
  printf '#!/usr/bin/env bash\n'
  printf 'awk %s\n' \
    "'{ if (\$0 ~ /^##?#?#?#?#?[[:space:]]/) print \"dirty\" }'"
} > "$TMP/formB-good/site.sh"
OUT="$(bash "$SUT" "$TMP/formB-good" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'NO-MATCH'; then
  ok "8 FORM-B chained-? (not an interval) -> exit 0, no violation (negative control)"
else
  no "8 FORM-B negative failed (exit=$RC out=[$OUT])"
fi

# 9. FORM-B is scoped to awk-invoking files: the SAME interval-looking text in a file that never
#    mentions awk must NOT be flagged (declared scope boundary, not a general regex-literal scan).
mkdir -p "$TMP/formB-noawk"
{
  printf '#!/usr/bin/env bash\n'
  printf '# just a comment that happens to contain a tilde and braces: ~ {1,6} / not awk /\n'
  printf 'echo hi\n'
} > "$TMP/formB-noawk/site.sh"
OUT="$(bash "$SUT" "$TMP/formB-noawk" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'NO-MATCH'; then
  ok "9 FORM-B scope: interval-looking text in a non-awk file is not flagged"
else
  no "9 FORM-B scope failed (exit=$RC out=[$OUT])"
fi

# 10. LIVE-CORPUS acceptance (§7 "acceptance is a fleet sweep, not the fixtures"): the real lint
#     against the real toolbelt tree must report 0 violations — this is the regression guard for
#     kit issue #1121's fix (17+ quoted sites, lib/retro-grammar.sh's mawk-portable rewrite).
OUT="$(bash "$SUT" "$TOOLBELT_ROOT" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF 'NO-MATCH'; then
  ok "10 live-corpus: real toolbelt tree scans clean (0 violations)"
else
  no "10 live-corpus failed — real toolbelt tree has violations (exit=$RC out=[$OUT])"
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for lint-substitution.sh --"

  # Tooth A: neuter formA_re so it can never match. Case 5's known-bad fixture must then
  # FALSE-PASS (exit 0, no violation), proving FORM-A detection has real teeth.
  sed "s#^formA_re=.*#formA_re='NEVER_MATCHES_THIS_STRING_XYZ123'#" "$SUT" > "$TMP/mutant-formA.sh"
  chmod +x "$TMP/mutant-formA.sh"
  MOUT="$(bash "$TMP/mutant-formA.sh" "$TMP/formA-bad" 2>&1)"; MRC=$?
  if [ "$MRC" -eq 0 ] && printf '%s\n' "$MOUT" | grep -qF 'NO-MATCH'; then
    ok "teeth A: formA_re neutered -> known FORM-A violation FALSE-PASSES -> case 5 has teeth"
  else
    no "teeth A: mutant still caught the FORM-A violation (exit=$MRC) — mutation not exercised (THEATER)"
  fi

  # Tooth B: neuter formB_re so it can never match. Case 7's known-bad fixture must then
  # FALSE-PASS, proving FORM-B detection has real teeth.
  sed "s#^formB_re=.*#formB_re='NEVER_MATCHES_THIS_STRING_XYZ123'#" "$SUT" > "$TMP/mutant-formB.sh"
  chmod +x "$TMP/mutant-formB.sh"
  MOUT="$(bash "$TMP/mutant-formB.sh" "$TMP/formB-bad" 2>&1)"; MRC=$?
  if [ "$MRC" -eq 0 ] && printf '%s\n' "$MOUT" | grep -qF 'NO-MATCH'; then
    ok "teeth B: formB_re neutered -> known FORM-B violation FALSE-PASSES -> case 7 has teeth"
  else
    no "teeth B: mutant still caught the FORM-B violation (exit=$MRC) — mutation not exercised (THEATER)"
  fi

  # Tooth C: force the violations-found branch to exit 0 instead of 1. Case 5/7's fixtures must
  # then still be REPORTED (the FORM-A/FORM-B line still prints) but the exit code teeth are what
  # case 5's `[ "$RC" -eq 1 ]` assertion actually depends on — proving the exit-code check bites.
  sed 's/^exit 1$/exit 0/' "$SUT" > "$TMP/mutant-exit.sh"
  chmod +x "$TMP/mutant-exit.sh"
  MOUT="$(bash "$TMP/mutant-exit.sh" "$TMP/formA-bad" 2>&1)"; MRC=$?
  if [ "$MRC" -eq 0 ] && printf '%s\n' "$MOUT" | grep -qF 'FORM-A'; then
    ok "teeth C: violations-found exit code neutered to 0 -> case 5's exit-1 assertion has teeth"
  else
    no "teeth C: mutant unexpectedly still exited non-zero (exit=$MRC) — mutation not exercised (THEATER)"
  fi

  # Tooth D: neuter the awk-invoking-file gate so FORM-B fires on ANY file, not just awk ones.
  # A file that has the REAL FORM-B shape (interval inside a `~ /.../ ` ERE literal) but never
  # mentions "awk" must then be FALSE-FLAGGED once the gate is neutered, proving the gate itself
  # (not just the regex) has real teeth. Case 9's own fixture is deliberately NOT FORM-B shaped
  # (the brace sits outside the slashes) so it cannot exercise this tooth — a fresh fixture is
  # built here, same placeholder-substitution technique as cases 5/7 avoid self-matching.
  mkdir -p "$TMP/formB-gate"
  _gate_tpl='if ($0 ~ /^#{PLACEHOLDER}[[:space:]]/) print "dirty"'
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "${_gate_tpl//PLACEHOLDER/1,6}"
  } > "$TMP/formB-gate/site.sh"
  unset _gate_tpl
  sed '/SENTINEL-AWK-GATE/{n;s/^  if grep -qE .*$/  if true; then/}' "$SUT" > "$TMP/mutant-gate.sh"
  chmod +x "$TMP/mutant-gate.sh"
  if cmp -s "$SUT" "$TMP/mutant-gate.sh"; then
    no "teeth D: awk-gate mutation was a byte-identical no-op — sed pattern did not match"
  else
    CTRL_OUT="$(bash "$SUT" "$TMP/formB-gate" 2>&1)"; CTRL_RC=$?
    if [ "$CTRL_RC" -ne 0 ]; then
      no "teeth D: precondition failed — the real (unmutated) lint already flags formB-gate fixture; it does not isolate the gate (out=[$CTRL_OUT])"
    else
      MOUT="$(bash "$TMP/mutant-gate.sh" "$TMP/formB-gate" 2>&1)"; MRC=$?
      if [ "$MRC" -eq 1 ] && printf '%s\n' "$MOUT" | grep -qF 'FORM-B'; then
        ok "teeth D: awk-invoking-file gate neutered -> a real FORM-B shape in a non-awk file FALSE-FLAGS -> scope gate has real teeth"
      else
        no "teeth D: mutant did not flag the non-awk FORM-B-shaped fixture (exit=$MRC) — mutation not exercised (THEATER)"
      fi
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
