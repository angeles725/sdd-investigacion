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

# kit issue #1142 review round 3 (nit): this used to be a hand-maintained literal list
# ("3 4 5 6 7 8 9 10") that silently fell behind as cases were added past 10 — built from the
# actual case count instead so a new case is automatically covered by the early-bail path too.
LAST_CASE_NUM=15
if [ ! -f "$SUT" ]; then
  for n in $(seq 3 "$LAST_CASE_NUM"); do no "$n (skipped: SUT missing)"; done
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
# it exercises. lint-substitution.sh's own header uses the SAME avoidance technique for its
# illustrative examples (kit issue #1142 review round 3, nit: an earlier draft of this note
# pointed at a dedicated header comment that does not exist — there is no single named note,
# each header example is individually reworded to avoid a literal self-matching shape).
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

# 11. FORM-A WIDENED FORMS (kit issue #1142 review, §7 "enumerate forms against the real tree"):
#     the original regex only matched a bare $name / ${name} replacement. Each line below is one
#     of the review's own synthetic probes, each independently confirmed (empirically, bash 5.2)
#     to carry the same '&' semantics as the original defect. Built via placeholder substitution
#     at runtime (not spelled out literally here) so this test file does not self-match the lint
#     it exercises — same technique cases 5/7 already use.
mkdir -p "$TMP/formA-widened"
# Three distinct placeholders (OPEN/CLOSE/DOLLAR) build correct ${...} shapes at runtime.
_fa2_tpl='arrv=(a b); s1=x; s2=x; s3=x; pre=x; y=x
printf %s "OPENarrv[@]/p/DOLLARyCLOSE"
printf %s "OPENs1/OPENpreCLOSE/DOLLARyCLOSE"
printf %s "OPENs2/p/OPENy:-zCLOSECLOSE"
printf %s "OPENs3/p/DOLLAR(echo hi)CLOSE"'
_fa2_body="${_fa2_tpl//OPEN/\$\{}"
_fa2_body="${_fa2_body//CLOSE/\}}"
_fa2_body="${_fa2_body//DOLLAR/\$}"
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "$_fa2_body"
} > "$TMP/formA-widened/site.sh"
OUT="$(bash "$SUT" "$TMP/formA-widened" 2>&1)"; RC=$?
_fa2_count="$(printf '%s\n' "$OUT" | grep -cF 'FORM-A')"
if [ "$RC" -eq 1 ] && [ "$_fa2_count" -eq 4 ]; then
  ok "11 FORM-A widened forms: array subscript, braced pattern, default-value replacement, command-substitution replacement all detected (4 sites)"
else
  no "11 FORM-A widened forms failed (exit=$RC count=$_fa2_count out=[$OUT])"
fi

# 12. FORM-B WIDENED FORMS (kit issue #1142 review): the original regex only matched '~ /re/'.
#     Covers a bare awk pattern, a negated bare pattern, a regex passed to match(), and an
#     exact-count interval (no comma) — each a live site the review found missed.
mkdir -p "$TMP/formB-widened"
_fb2_tpl='awk {
if (/^#{INTRVL}[[:space:]]/) print "a"
if (!/^#{INTRVL}[[:space:]]/) print "b"
if (match($0, /^#{INTRVL}[[:space:]]/)) print "c"
if ($0 ~ /^#{EXACT}[[:space:]]/) print "d"
}'
_fb2_body="${_fb2_tpl//INTRVL/1,6}"
_fb2_body="${_fb2_body//EXACT/6}"
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "$_fb2_body"
} > "$TMP/formB-widened/site.sh"
OUT="$(bash "$SUT" "$TMP/formB-widened" 2>&1)"; RC=$?
_fb2_count="$(printf '%s\n' "$OUT" | grep -cF 'FORM-B')"
if [ "$RC" -eq 1 ] && [ "$_fb2_count" -eq 4 ]; then
  ok "12 FORM-B widened forms: bare pattern, negated bare pattern, match() argument, exact-count interval all detected (4 sites)"
else
  no "12 FORM-B widened forms failed (exit=$RC count=$_fb2_count out=[$OUT])"
fi

# 13. DEFAULT (no-argument) invocation scans BOTH research-sdd/toolbelt AND research-sdd/install
#     (kit issue #1142 review finding #3: install/tests/research-sdd-install.test.sh had a real
#     site; the lint's coverage must match CLAUDE.md §5's shellcheck glob, which names both trees).
#     Hardened (kit issue #1142 review round 3, blocking finding #3): the mention of each root's
#     NAME in the output was previously the only check, and it printed unconditionally regardless
#     of whether that root was actually WALKED — a regression back to toolbelt-only scanning
#     (e.g. `for _root in "${ROOTS[@]:0:1}"`) still named both roots in the ROOTS[*] header and
#     stayed green. Assert the reported "scanned N file(s)" count against an INDEPENDENT `find`
#     count over both roots instead, so a root silently dropped from the actual walk changes N and
#     is caught.
INSTALL_ROOT="$(cd -P "$TOOLBELT_ROOT/../install" 2>/dev/null && pwd)"
_c13_expected="$(find "$TOOLBELT_ROOT" -type f -name '*.sh' | wc -l)"
if [ -n "$INSTALL_ROOT" ]; then
  _c13_expected=$((_c13_expected + $(find "$INSTALL_ROOT" -type f -name '*.sh' | wc -l)))
fi
OUT="$(cd "$TOOLBELT_ROOT" && bash "$SUT" 2>&1)"; RC=$?
_c13_scanned="$(printf '%s\n' "$OUT" | grep -oE 'scanned [0-9]+ file' | grep -oE '[0-9]+')"
if [ "$RC" -eq 0 ] \
   && printf '%s\n' "$OUT" | grep -qF 'NO-MATCH' \
   && printf '%s\n' "$OUT" | grep -q 'research-sdd/toolbelt' \
   && printf '%s\n' "$OUT" | grep -q 'research-sdd/install' \
   && [ -n "$_c13_scanned" ] && [ "$_c13_scanned" -eq "$_c13_expected" ]; then
  ok "13 default no-argument invocation scans both trees, scanned count ($_c13_scanned) matches an independent find count ($_c13_expected), 0 violations"
else
  no "13 default invocation failed (exit=$RC scanned=[$_c13_scanned] expected=[$_c13_expected] out=[$OUT])"
fi

# 14. FORM-A TRIGGER-ANYWHERE (kit issue #1142 review round 3, blocking finding #1): the operand
#     used to be flagged only when it STARTED with an unquoted $/backtick; retro-gate.sh:210 was
#     missed because its operand starts with a literal escaped backslash and only carries the
#     risky unquoted expansion LATER. Each sub-form below is one of the review's own synthetic
#     probes (plus the exact retro-gate.sh:210 shape), built via placeholder substitution at
#     runtime so this file does not self-match its own SUT.
mkdir -p "$TMP/formA-anywhere"
_fa3_tpl='dq=Q; s=x; y=x; ref=y
printf %s "OPENs/OPENdqCLOSE/BSBSDOLLARdqCLOSE"
printf %s "OPENs/y/QaQDOLLARyCLOSE"
printf %s "OPEN1/y/DOLLARyCLOSE"
printf %s "OPENATSIGN/y/DOLLARyCLOSE"
printf %s "OPENBANGref/y/DOLLARyCLOSE"'
_fa3_body="${_fa3_tpl//OPEN/\$\{}"
_fa3_body="${_fa3_body//CLOSE/\}}"
_fa3_body="${_fa3_body//DOLLAR/\$}"
_fa3_body="${_fa3_body//BSBS/\\\\}"
_fa3_body="${_fa3_body//Q/\"}"
_fa3_body="${_fa3_body//ATSIGN/@}"
_fa3_body="${_fa3_body//BANG/!}"
{
  printf '#!/usr/bin/env bash\n'
  printf '%s\n' "$_fa3_body"
  # Bare backtick-pair replacement (built with printf %b so this source line itself never
  # contains a literal, executable backtick pair).
  printf '%b\n' 'm2=${x/y/\140cmd\140}'
} > "$TMP/formA-anywhere/site.sh"
unset _fa3_tpl _fa3_body
OUT="$(bash "$SUT" "$TMP/formA-anywhere" 2>&1)"; RC=$?
_fa3_count="$(printf '%s\n' "$OUT" | grep -cF 'FORM-A')"
if [ "$RC" -eq 1 ] && [ "$_fa3_count" -eq 6 ]; then
  ok "14 FORM-A trigger-anywhere: retro-gate.sh:210 shape (escaped backslash then bare \$), mixed quoted-prefix, positional param (\$1), special param (\$@), indirect ref (\$!ref), bare backtick pair — all 6 detected"
else
  no "14 FORM-A trigger-anywhere failed (exit=$RC count=$_fa3_count out=[$OUT])"
fi

# 15. FAIL-CLOSED on an unreadable file (kit issue #1142 review round 3, blocking finding #2, §7):
#     a per-file grep read failure (rc>=2) used to be silenced ('2>/dev/null', rc never checked),
#     so a chmod-000 file read as a confident 0-violations pass. root bypasses all permission
#     checks, so this case cannot exercise anything meaningful there — skip with an explicit
#     notice rather than a false pass or a false fail.
if [ "$(id -u)" -eq 0 ]; then
  ok "15 fail-closed-on-unreadable-file: SKIP — running as root, chmod 000 has no effect, cannot exercise this case"
else
  mkdir -p "$TMP/unreadable"
  printf '#!/usr/bin/env bash\nx=${a/b/c}\n' > "$TMP/unreadable/site.sh"
  chmod 000 "$TMP/unreadable/site.sh"
  OUT="$(bash "$SUT" "$TMP/unreadable" 2>&1)"; RC=$?
  chmod 644 "$TMP/unreadable/site.sh"
  if [ "$RC" -eq 2 ] && printf '%s\n' "$OUT" | grep -qF 'DEGRADED'; then
    ok "15 fail-closed-on-unreadable-file: chmod-000 file -> exit 2, DEGRADED reported (not a confident 0)"
  else
    no "15 fail-closed-on-unreadable-file failed (exit=$RC out=[$OUT])"
  fi
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
  # kit issue #1142 review round 3: the gate used to be a single `if grep -qE ...; then` line
  # right after the sentinel; it is now `_lint_scan '...' "$f"` (n) followed by
  # `if [[ "$_LINT_SCAN_RC" -eq 0 ]]; then` (n again) — target the SECOND line after the sentinel.
  sed '/SENTINEL-AWK-GATE/{n;n;s/^  if \[\[ "\$_LINT_SCAN_RC" -eq 0 \]\]; then$/  if true; then/}' "$SUT" > "$TMP/mutant-gate.sh"
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

  # Tooth E (kit issue #1142 review round 3, finding #1): neuter the trigger-ANYWHERE widening
  # back to trigger-at-position-0-only, by capping the prefix repetition at {0}. Case 14's
  # retro-gate.sh:210 shape and its mixed-quoted-prefix shape (the two sub-forms that specifically
  # NEED a nonzero prefix before the trigger) must then FALSE-PASS, proving the widening itself
  # has real teeth — the other 4 sub-forms in case 14 already start with the trigger at position
  # 0 and are expected to still be caught either way, so this asserts a COUNT DROP, not zero.
  sed 's/replplain_re})\*\${_lint_repltrigger_re}/replplain_re}){0}\${_lint_repltrigger_re}/' "$SUT" > "$TMP/mutant-anywhere.sh"
  chmod +x "$TMP/mutant-anywhere.sh"
  if cmp -s "$SUT" "$TMP/mutant-anywhere.sh"; then
    no "teeth E: trigger-anywhere mutation was a byte-identical no-op — sed pattern did not match"
  else
    MOUT="$(bash "$TMP/mutant-anywhere.sh" "$TMP/formA-anywhere" 2>&1)"; MRC=$?
    _me_count="$(printf '%s\n' "$MOUT" | grep -cF 'FORM-A')"
    # exactly the 2 sub-forms that need a nonzero prefix before the trigger (the
    # retro-gate.sh:210 shape and the mixed-quoted-prefix shape) stop matching; the other 4
    # (positional/special/indirect param, bare backtick pair) already have the trigger at
    # position 0 and are unaffected by this specific mutation — asserting the EXACT drop (6->4)
    # is a stronger check than a bare "< 6".
    if [ "$MRC" -eq 1 ] && [ "$_me_count" -eq 4 ]; then
      ok "teeth E: trigger capped to position-0-only -> retro-gate.sh:210 shape and the mixed-quote shape no longer detected (count 6 -> $_me_count) -> trigger-anywhere widening has real teeth"
    else
      no "teeth E: mutant did not drop to the expected 4 sub-forms (count=$_me_count, exit=$MRC) — mutation not exercised (THEATER)"
    fi
  fi

  # Tooth F (kit issue #1142 review round 3, finding #2): neuter the fail-closed rc threshold
  # (>=2 becomes >=99, i.e. never for a real grep exit code). Case 15's chmod-000 fixture must
  # then FALSE-PASS (a confident NO-MATCH instead of DEGRADED+exit 2), proving the fail-closed
  # check itself has real teeth. Skipped under the same root guard as case 15.
  if [ "$(id -u)" -eq 0 ]; then
    ok "teeth F: SKIP — running as root, chmod 000 has no effect, cannot exercise this mutant"
  else
    sed 's/_LINT_SCAN_RC" -ge 2/_LINT_SCAN_RC" -ge 99/' "$SUT" > "$TMP/mutant-failclosed.sh"
    chmod +x "$TMP/mutant-failclosed.sh"
    if cmp -s "$SUT" "$TMP/mutant-failclosed.sh"; then
      no "teeth F: fail-closed-threshold mutation was a byte-identical no-op — sed pattern did not match"
    else
      mkdir -p "$TMP/unreadable-teeth"
      printf '#!/usr/bin/env bash\nx=${a/b/c}\n' > "$TMP/unreadable-teeth/site.sh"
      chmod 000 "$TMP/unreadable-teeth/site.sh"
      MOUT="$(bash "$TMP/mutant-failclosed.sh" "$TMP/unreadable-teeth" 2>&1)"; MRC=$?
      chmod 644 "$TMP/unreadable-teeth/site.sh"
      if [ "$MRC" -eq 0 ] && printf '%s\n' "$MOUT" | grep -qF 'NO-MATCH'; then
        ok "teeth F: fail-closed threshold neutered -> chmod-000 file FALSE-PASSES as a confident 0 -> case 15's DEGRADED design has real teeth"
      else
        no "teeth F: mutant still failed closed (exit=$MRC) — mutation not exercised (THEATER) :: out=[$MOUT]"
      fi
    fi
  fi

  # Tooth G (kit issue #1142 review round 3, blocking finding #3): neuter the ROOTS loop to only
  # ever walk the FIRST configured root — install is never actually scanned even though it is
  # still named in the ROOTS[*] header. Case 13's independent-find-count assertion must then go
  # red (the reported "scanned N" drops below the independent count), proving the hardened
  # assertion — not just the root-name mention — has real teeth. lint-substitution.sh derives its
  # default roots from ITS OWN location (SCRIPT_DIR/BASH_SOURCE), so a bare copy of the mutant
  # elsewhere would silently scan whatever happens to sit at ITS new location instead — an
  # isolated toolbelt/install-SHAPED pair (same trick run-all.test.sh's mut_workdir() uses) keeps
  # the mutant's own default-root resolution meaningful without touching the live tree.
  mkdir -p "$TMP/isog/toolbelt" "$TMP/isog/install"
  sed 's/for _root in "\${ROOTS\[@\]}"; do/for _root in "${ROOTS[@]:0:1}"; do/' "$SUT" > "$TMP/isog/toolbelt/lint-substitution.sh"
  chmod +x "$TMP/isog/toolbelt/lint-substitution.sh"
  if cmp -s "$SUT" "$TMP/isog/toolbelt/lint-substitution.sh"; then
    no "teeth G: ROOTS-loop mutation was a byte-identical no-op — sed pattern did not match"
  else
    printf '#!/usr/bin/env bash\necho ok\n' > "$TMP/isog/toolbelt/other.sh"
    printf '#!/usr/bin/env bash\necho ok\n' > "$TMP/isog/install/other.sh"
    cp "$SUT" "$TMP/isog/toolbelt/lint-substitution-ctrl.sh"
    chmod +x "$TMP/isog/toolbelt/lint-substitution-ctrl.sh"
    CTRL_OUT="$(cd "$TMP/isog/toolbelt" && bash "$TMP/isog/toolbelt/lint-substitution-ctrl.sh" 2>&1)"; CTRL_RC=$?
    _cg_expected="$(printf '%s\n' "$CTRL_OUT" | grep -oE 'scanned [0-9]+ file' | grep -oE '[0-9]+')"
    # isolated toolbelt/ holds 3 files (the mutant script itself, this control copy, and
    # other.sh); isolated install/ holds 1 (other.sh) — an unmutated scan of both is 4.
    if [ "$CTRL_RC" -ne 0 ] || [ "$_cg_expected" != "4" ]; then
      no "teeth G: precondition failed — the real (unmutated) lint did not report scanning all 4 isolated-fixture files (out=[$CTRL_OUT])"
    else
      MOUT="$(cd "$TMP/isog/toolbelt" && bash "$TMP/isog/toolbelt/lint-substitution.sh" 2>&1)"; MRC=$?
      _mg_scanned="$(printf '%s\n' "$MOUT" | grep -oE 'scanned [0-9]+ file' | grep -oE '[0-9]+')"
      if [ "$MRC" -eq 0 ] && [ "$_mg_scanned" = "3" ]; then
        ok "teeth G: ROOTS loop capped to the first root only -> scanned count drops from 4 to $_mg_scanned (install fixture never walked) -> case 13's hardened assertion has real teeth"
      else
        no "teeth G: mutant's scanned count did not drop as expected (scanned=$_mg_scanned, exit=$MRC) — mutation not exercised (THEATER)"
      fi
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
