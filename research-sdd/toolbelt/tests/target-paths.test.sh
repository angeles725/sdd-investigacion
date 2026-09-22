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

echo ""
if [ "$fail" -gt 0 ]; then
  printf 'RESULT (with teeth): %d passed / %d FAILED\n' "$pass" "$fail"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"; exit 1
else
  printf 'RESULT (with teeth): %d passed / 0 failed\n' "$pass"
  printf '== %d passed · 0 failed ==\n' "$pass"; exit 0
fi
