#!/usr/bin/env bash
# target-paths.test.sh — unit suite for lib/target-paths.sh (table-row-scoped path derivation).
# Pins: table-row paths returned; prose citations excluded; truncated table-row path passes
# through (PARTIAL warn preserved); $RESEARCH_HOME rows resolved; absent file → exit 1.
#
# Usage: target-paths.test.sh [--prove-teeth]
# Exit: 0 = all passed · 1 = regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/target-paths.sh"
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
# call <lib> <fn> <targets_md>: source lib in a subprocess, invoke fn with targets_md as $1.
call() { "$BASH_BIN" --norc -c "source '$1'; $2 \"\$1\"" -- "$3"; }

# Shared fixture: one real table row, one truncated table row, one prose path citation.
FX="${ROOT}/fixture.md"
cat > "$FX" << 'EOF'
# Targets

Prose citation only: (`/prose/should/not/appear`).

| # | name | path |
|---|------|------|
| 1 | real      | `/table/real/path` |
| 2 | truncated | `/home/x/.../trunc-target` |
EOF

echo "== target-paths.test.sh (SUT: $(basename "$LIB")) =="

# 1a — table-row abs path IS returned by target_paths_all.
# 1b — prose abs path is NOT returned (key defect guard).
out="$(call "$LIB" target_paths_all "$FX")"
if   grep -qF '/table/real/path'        <<<"$out"; then ok "1a table-row abs path returned"
else no "1a table-row abs path returned" "out=[$out]"; fi
if ! grep -qF '/prose/should/not/appear' <<<"$out"; then ok "1b prose abs path excluded (defect guard)"
else no "1b prose abs path excluded (defect guard)" "prose leaked: [$out]"; fi

# 2 — truncated table-row path passes through (caller can warn; anti-silent-zero preserved).
if grep -qF '/home/x/.../trunc-target' <<<"$out"; then ok "2 truncated table-row path passes through"
else no "2 truncated table-row path passes through" "out=[$out]"; fi

# 3 — $RESEARCH_HOME table-row expanded; $RESEARCH_HOME in prose NOT returned.
FX3="${ROOT}/f3.md"
cat > "$FX3" << 'EOF'
# Targets
Prose mentioning `$RESEARCH_HOME/prose-rh` for context only.

| # | name | path |
|---|------|------|
| 1 | rh | `$RESEARCH_HOME/rh-target` |
EOF
out3="$("$BASH_BIN" --norc -c "source '$LIB'; RESEARCH_HOME=/home/rh target_paths_all \"\$1\"" -- "$FX3")"
if   grep -qF '/home/rh/rh-target'  <<<"$out3" \
  && ! grep -qF '/home/rh/prose-rh' <<<"$out3"; then
  ok "3 \$RESEARCH_HOME: table-row expanded; prose excluded"
else no "3 \$RESEARCH_HOME: table-row expanded; prose excluded" "out=[$out3]"; fi

# 4 — absent file → non-zero exit + stderr 'cannot read' (anti-silent-zero).
err4="$("$BASH_BIN" --norc -c "source '$LIB'; target_paths_all '/no/such/TARGETS.md'" 2>&1 >/dev/null)"
rc4=$?
if [ "$rc4" -ne 0 ] && grep -q 'cannot read' <<<"$err4"; then
  ok "4 absent file → non-zero exit + stderr 'cannot read'"
else no "4 absent file → non-zero exit + stderr 'cannot read'" "rc=$rc4 err=[$err4]"; fi

# 5 — target_paths_pairs: table-row as raw-tab-expanded pair; prose excluded.
out5="$(call "$LIB" target_paths_pairs "$FX")"
if   grep -qP '/table/real/path\t/table/real/path' <<<"$out5" \
  && ! grep -qF '/prose/should/not/appear' <<<"$out5"; then
  ok "5 pairs: table row as raw\\texpanded; prose excluded"
else no "5 pairs: table row as raw\\texpanded; prose excluded" "out=[$out5]"; fi

# 6 — target_paths_all with no argument → non-zero exit + stderr 'no argument' (anti-silent-zero).
# Pre-fix: `[ -n "$f" ] || return 0` — exits 0 silently. That is the defect.
# Post-fix must exit non-zero with a message containing "no argument".
err6="$("$BASH_BIN" --norc -c "source '$LIB'; target_paths_all" 2>&1 >/dev/null)"
rc6=$?
if [ "$rc6" -ne 0 ] && grep -q 'no argument' <<<"$err6"; then
  ok "6 target_paths_all no-arg → non-zero exit + stderr 'no argument'"
else no "6 target_paths_all no-arg → non-zero exit + stderr 'no argument'" "rc=$rc6 err=[$err6]"; fi

# 7 — target_paths_pairs with no argument → same contract.
err7="$("$BASH_BIN" --norc -c "source '$LIB'; target_paths_pairs" 2>&1 >/dev/null)"
rc7=$?
if [ "$rc7" -ne 0 ] && grep -q 'no argument' <<<"$err7"; then
  ok "7 target_paths_pairs no-arg → non-zero exit + stderr 'no argument'"
else no "7 target_paths_pairs no-arg → non-zero exit + stderr 'no argument'" "rc=$rc7 err=[$err7]"; fi

# 8 — RESEARCH_HOME with trailing slash: target_paths_all must strip it so the expanded
# path has no // (trailing slash in rh + "/" separator = double slash without %/ fix).
FX8="${ROOT}/f8.md"
cat > "$FX8" << 'EOF'
# Targets
| # | name | path |
|---|------|------|
| 1 | rh | `$RESEARCH_HOME/sub-target` |
EOF
out8="$("$BASH_BIN" --norc -c "source '$LIB'; RESEARCH_HOME='/rh-slash/' target_paths_all \"\$1\"" -- "$FX8")"
if echo "$out8" | grep -qF '/rh-slash/sub-target' && ! echo "$out8" | grep -qF '//'; then
  ok "8 RESEARCH_HOME trailing slash → expanded path has no double slash"
else no "8 RESEARCH_HOME trailing slash → expected /rh-slash/sub-target without //" "out=[$out8]"; fi

# 9 — RESEARCH_HOME containing '&': target_paths_all must return literal path without
# awk sub() & expansion (ENVIRON-based awk so & is never treated as matched-text).
FX9="${ROOT}/f9.md"
cat > "$FX9" << 'EOF'
# Targets
| # | name | path |
|---|------|------|
| 1 | rh | `$RESEARCH_HOME/tgt` |
EOF
out9="$("$BASH_BIN" --norc -c "source '$LIB'; RESEARCH_HOME='/rh&amp/path' target_paths_all \"\$1\"" -- "$FX9")"
if echo "$out9" | grep -qF '/rh&amp/path/tgt'; then
  ok "9 RESEARCH_HOME with '&' → literal path returned (ENVIRON-based awk, no & expansion)"
else no "9 RESEARCH_HOME with '&' → expected literal /rh&amp/path/tgt" "out=[$out9]"; fi

# --- summary ---
echo ""
total=$((pass+fail))
[ "$total" -gt 0 ] || { echo "FATAL: zero tests executed." >&2; exit 2; }
if [ "$fail" -gt 0 ]; then
  printf 'RESULT: %d passed / %d FAILED\n' "$pass" "$fail"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"
  [ "${1:-}" = "--prove-teeth" ] || exit 1
else
  printf 'RESULT: %d passed / 0 failed\n' "$pass"
  printf '== %d passed · 0 failed ==\n' "$pass"
  [ "${1:-}" = "--prove-teeth" ] || exit 0
fi

# --- teeth: pre-fix (wide-scan) mutant must leak prose, proving case 1b bites ---
echo ""
echo "-- teeth: wide-scan (pre-fix) mutant; expect prose path to leak in case 1b --"
anchor='grep -E'
if ! grep -qF "$anchor" "$LIB"; then
  no "teeth: locate table-row filter in LIB" "anchor not found — LIB drifted?"
else
  MUTANT="${ROOT}/tp-mutant.sh"
  cat > "$MUTANT" << 'MUTANT_SRC'
if ! declare -F target_paths_all >/dev/null 2>&1; then
  target_paths_all() {
    local f="${1:-}"; [ -n "$f" ] || return 0
    [ -f "$f" ] || { echo "target-paths: cannot read ${f}" >&2; return 1; }
    grep -oE '`/[^`]+`' "$f" 2>/dev/null | tr -d '`' | sort -u
  }
  target_paths_pairs() {
    local f="${1:-}"; [ -n "$f" ] || return 0
    [ -f "$f" ] || { echo "target-paths: cannot read ${f}" >&2; return 1; }
    grep -oE '`/[^`]+`' "$f" 2>/dev/null | tr -d '`' | awk '{print $0"\t"$0}' | sort -u
  }
fi
MUTANT_SRC
  mut="$(call "$MUTANT" target_paths_all "$FX" 2>/dev/null)"
  if grep -qF '/prose/should/not/appear' <<<"$mut"; then
    ok "teeth: wide-scan mutant leaks prose (case 1b has teeth)"
  else no "teeth: wide-scan mutant must leak prose (case 1b is THEATER)" "mut=[$mut]"; fi
fi

# Teeth for cases 6 and 7: mutant restores the pre-fix silent-zero no-arg behavior.
# Delete the SENTINEL-TP-ALL-NOARG block (the fix guard) from the lib;
# with the guard gone the no-arg code falls through to the absent-file check which
# emits "cannot read" (not "no argument"). Case 6's assertion requires "no argument"
# in stderr, which the mutant lacks → case 6 goes RED → the guard bites.
echo "-- teeth 6: no-arg guard for target_paths_all --"
if ! grep -qF '# SENTINEL-TP-ALL-NOARG-START' "$LIB"; then
  no "teeth 6: locate SENTINEL-TP-ALL-NOARG-START in LIB" "anchor not found — LIB drifted?"
else
  MUTANT_TP6="${ROOT}/tp-noarg-all-mutant.sh"
  sed '/# SENTINEL-TP-ALL-NOARG-START/,/# SENTINEL-TP-ALL-NOARG-END/d' "$LIB" > "$MUTANT_TP6"
  err_m6="$("$BASH_BIN" --norc -c "source '$MUTANT_TP6'; target_paths_all" 2>&1 >/dev/null)"
  # Mutant exits non-zero (absent-file path fires) but says "cannot read", not "no argument".
  if ! grep -q 'no argument' <<<"$err_m6"; then
    ok "teeth 6: no-arg mutant lacks 'no argument' in stderr (case 6 has teeth)"
  else no "teeth 6: mutant unexpectedly has 'no argument' — case 6 is THEATER" "err_m6=[$err_m6]"; fi
fi

echo "-- teeth 7: no-arg guard for target_paths_pairs --"
if ! grep -qF '# SENTINEL-TP-PAIRS-NOARG-START' "$LIB"; then
  no "teeth 7: locate SENTINEL-TP-PAIRS-NOARG-START in LIB" "anchor not found — LIB drifted?"
else
  MUTANT_TP7="${ROOT}/tp-noarg-pairs-mutant.sh"
  sed '/# SENTINEL-TP-PAIRS-NOARG-START/,/# SENTINEL-TP-PAIRS-NOARG-END/d' "$LIB" > "$MUTANT_TP7"
  err_m7="$("$BASH_BIN" --norc -c "source '$MUTANT_TP7'; target_paths_pairs" 2>&1 >/dev/null)"
  if ! grep -q 'no argument' <<<"$err_m7"; then
    ok "teeth 7: no-arg mutant lacks 'no argument' in stderr (case 7 has teeth)"
  else no "teeth 7: mutant unexpectedly has 'no argument' — case 7 is THEATER" "err_m7=[$err_m7]"; fi
fi

# Teeth for case 8: removing the rh%/ normalization must make // appear in the expanded path.
echo "-- teeth 8: trailing-slash normalization for target_paths_all --"
MUTANT_TP8="${ROOT}/tp-slash-mutant.sh"
sed '/rh="\${rh%\/}"/d' "$LIB" > "$MUTANT_TP8"
# (a) mutant must differ from SUT
if ! diff -q "$LIB" "$MUTANT_TP8" >/dev/null 2>&1; then
  ok "teeth 8 (a): mutant differs from SUT"
else no "teeth 8 (a): sed did not change the file — mutant == SUT (theater)"; fi
# (b) bash -n must pass on mutant
_m8_bn_err=$(bash -n "$MUTANT_TP8" 2>&1); _m8_bn_rc=$?
if [ "$_m8_bn_rc" -eq 0 ]; then
  ok "teeth 8 (b): mutant passes bash -n"
else no "teeth 8 (b): mutant has bash syntax error (crash-based theater)" "err=[$_m8_bn_err]"; fi
# (d) control: SUT gives correct path (no //); mutant introduces //
out_m8_ctrl="$("$BASH_BIN" --norc -c "source '$LIB'; RESEARCH_HOME='/rh-slash/' target_paths_all \"\$1\"" -- "$FX8" 2>/dev/null)"
if echo "$out_m8_ctrl" | grep -qF '/rh-slash/sub-target' && ! echo "$out_m8_ctrl" | grep -qF '//'; then
  ok "teeth 8 (d) ctrl: SUT strips trailing slash (no // in expanded path)"
else no "teeth 8 (d) ctrl: SUT output unexpected (case 8 premise broken)" "out=[$out_m8_ctrl]"; fi
out_m8="$("$BASH_BIN" --norc -c "source '$MUTANT_TP8'; RESEARCH_HOME='/rh-slash/' target_paths_all \"\$1\"" -- "$FX8" 2>/dev/null)"
if echo "$out_m8" | grep -qF '//'; then
  ok "teeth 8: no-norm mutant produces // in path (case 8 has teeth)"
else no "teeth 8: mutant did not produce //; case 8 is THEATER" "out=[$out_m8]"; fi

# Teeth for case 9: replacing ENVIRON lookup with sub()-based expansion must corrupt '&' path.
echo "-- teeth 9: ENVIRON-based awk (no sub() & expansion) for target_paths_all --"
MUTANT_TP9="${ROOT}/tp-amp-mutant.sh"
# Mutant: replace substr()/length() pfx2 path with sub() using a char-class regex
# ([$]RESEARCH_HOME[/] avoids \$ ambiguity); braces make it one compound statement
# so the existing else branch stays syntactically valid.
sed 's|print rh "/" substr($0, length(pfx2) + 1)|{ sub(/^[$]RESEARCH_HOME[/]/, rh "/"); print }|' \
  "$LIB" > "$MUTANT_TP9"
# (a) mutant must differ from SUT
if ! diff -q "$LIB" "$MUTANT_TP9" >/dev/null 2>&1; then
  ok "teeth 9 (a): mutant differs from SUT"
else no "teeth 9 (a): sed did not change the file — mutant == SUT (theater)"; fi
# (b) bash -n must pass on mutant
_m9_bn_err=$(bash -n "$MUTANT_TP9" 2>&1); _m9_bn_rc=$?
if [ "$_m9_bn_rc" -eq 0 ]; then
  ok "teeth 9 (b): mutant passes bash -n"
else no "teeth 9 (b): mutant has bash syntax error (crash-based theater)" "err=[$_m9_bn_err]"; fi
# (c) injected awk must parse on empty input (rc 0); isolated from the full bash context
_m9_awk_rc=0; echo '' | awk '{ sub(/^[$]RESEARCH_HOME[/]/, rh "/"); print }' >/dev/null 2>&1 \
  || _m9_awk_rc=$?
if [ "$_m9_awk_rc" -eq 0 ]; then
  ok "teeth 9 (c): injected awk parses on empty input"
else no "teeth 9 (c): injected awk has syntax error (crash-based theater)" "rc=$_m9_awk_rc"; fi
# (d) control: SUT preserves & literally; mutant corrupts it via sub() & expansion
out_m9_ctrl="$("$BASH_BIN" --norc -c "source '$LIB'; RESEARCH_HOME='/rh&amp/path' target_paths_all \"\$1\"" -- "$FX9" 2>/dev/null)"
if echo "$out_m9_ctrl" | grep -qF '/rh&amp/path/tgt'; then
  ok "teeth 9 (d) ctrl: SUT preserves & in RESEARCH_HOME path"
else no "teeth 9 (d) ctrl: SUT does not preserve & (case 9 premise broken)" "out=[$out_m9_ctrl]"; fi
out_m9="$("$BASH_BIN" --norc -c "source '$MUTANT_TP9'; RESEARCH_HOME='/rh&amp/path' target_paths_all \"\$1\"" -- "$FX9" 2>/dev/null)"
if ! echo "$out_m9" | grep -qF '/rh&amp/path/tgt'; then
  ok "teeth 9: sub()-mutant corrupts & path (case 9 has teeth)"
else no "teeth 9: mutant did not corrupt & path; case 9 is THEATER" "out=[$out_m9]"; fi
# Sabotage: the old injection (no braces → orphan else) causes an awk syntax error → crash.
# Assert assertion (c) catches it: the broken program must return non-zero on parse.
echo "-- teeth 9 sabotage: old broken-awk injection caught by assertion (c) --"
_sab9_rc=0
echo '' | awk 'BEGIN { rh="" }
  {
    pfx2 = "$RESEARCH_HOME/"
    if (substr($0, 1, length(pfx2)) == pfx2)
      sub(/^\$RESEARCH_HOME\//,rh "/"); print
    else
      print
  }' >/dev/null 2>&1 || _sab9_rc=$?
if [ "$_sab9_rc" -ne 0 ]; then
  ok "teeth 9 sabotage: crash-prone awk rejected by (c) parse check (theater blocked)"
else no "teeth 9 sabotage: old broken awk parsed — sabotage detection ineffective"; fi

echo ""
if [ "$fail" -gt 0 ]; then
  printf 'RESULT (with teeth): %d passed / %d FAILED\n' "$pass" "$fail"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"; exit 1
else
  printf 'RESULT (with teeth): %d passed / 0 failed\n' "$pass"
  printf '== %d passed · 0 failed ==\n' "$pass"; exit 0
fi
