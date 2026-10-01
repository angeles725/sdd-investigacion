#!/usr/bin/env bash
# mutant.test.sh — suite for tests/lib/mutant.sh (kit issue #943, root class "teeth pass for the
# wrong reason"). The helper builds a mutant COPY of a SUT in a temp dir and REFUSES a mutant that
# is absent, empty, byte-identical to the original (the mutation never applied), not valid bash,
# or placed outside the temp root (it would land in the live tree — kit issue #1156).
#
# Usage: mutant.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 setup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="${MUTANT_LIB:-$HERE/lib/mutant.sh}"
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$LIB"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

ORIG="$TMP/orig.sh"
printf '#!/usr/bin/env bash\nif true; then\n  echo hello\nfi\n' > "$ORIG"

# expect_rc <label> <want-rc> <want-stderr-substring> <cmd...> — runs cmd, checks the exact rc and
# that stderr names the specific refusal (a bare non-zero is not enough: "any failure" is the
# wrong-reason class this helper exists to stop).
expect_rc(){
  local label="$1" want="$2" needle="$3"; shift 3
  local err rc
  err="$("$@" 2>&1 >/dev/null)"; rc=$?
  if [ "$rc" -eq "$want" ] && [[ "$err" == *"$needle"* ]]; then ok "$label"
  else no "$label (rc=$rc want=$want; stderr=[$err])"; fi
}

# 1 — happy path: applied mutation returns 0, differs from the original, original untouched.
out="$TMP/m1.sh"
mutant_sed "$ORIG" "$out" 's/hello/goodbye/' 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ] && grep -q goodbye "$out" && grep -q hello "$ORIG" && ! cmp -s "$ORIG" "$out"; then
  ok "happy path: mutant built, differs from SUT, SUT unchanged"
else no "happy path failed (rc=$rc)"; fi

# 2 — no-match: the sed script matches nothing, so the mutant is byte-identical.
out="$TMP/m2.sh"
expect_rc "no-match: byte-identical mutant is refused (rc 4, says identical)" 4 "identical" \
  mutant_sed "$ORIG" "$out" 's/NO_SUCH_ANCHOR/x/'
if [ ! -e "$out" ]; then ok "no-match: refused mutant file is not left behind"
else no "no-match: refused mutant file still exists"; fi

# 3 — empty mutant.
out="$TMP/m3.sh"
expect_rc "empty: a mutant that deletes everything is refused (rc 3, says empty)" 3 "empty" \
  mutant_sed "$ORIG" "$out" 'd'
if [ ! -e "$out" ]; then ok "empty: refused mutant file is not left behind"
else no "empty: refused mutant file still exists"; fi

# 4 — syntax: a delete that leaves a dangling `if` is refused by default, allowed when opted out.
out="$TMP/m4.sh"
expect_rc "syntax: mutant that is not valid bash is refused (rc 5, says bash -n)" 5 "bash -n" \
  mutant_sed "$ORIG" "$out" '/^fi$/d'
out="$TMP/m4b.sh"
MUTANT_SYNTAX=none mutant_sed "$ORIG" "$out" '/^fi$/d' 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then ok "syntax opt-out: MUTANT_SYNTAX=none skips the bash -n check"
else no "syntax opt-out: rc=$rc"; fi

# 5 — absent / empty original are distinct from an empty mutant.
out="$TMP/m5.sh"
expect_rc "absent original: refused (rc 2, says not a readable file)" 2 "not a readable file" \
  mutant_sed "$TMP/does-not-exist.sh" "$out" 's/a/b/'
: > "$TMP/empty-orig.sh"
expect_rc "empty original: refused (rc 3, says original is empty)" 3 "original is empty" \
  mutant_sed "$TMP/empty-orig.sh" "$out" 's/a/b/'

# 6 — sed itself fails (unterminated s command).
out="$TMP/m6.sh"
expect_rc "sed failure: refused (rc 6, says sed failed)" 6 "sed failed" \
  mutant_sed "$ORIG" "$out" 's/a'

# 7 — never overwrite the original.
expect_rc "self-overwrite: OUT equal to the original path is refused (rc 7)" 7 "same path" \
  mutant_sed "$ORIG" "$ORIG" 's/hello/x/'
if grep -q hello "$ORIG"; then ok "self-overwrite: original bytes intact"
else no "self-overwrite: original was modified"; fi

# 8 — placement: an OUT outside the temp root (e.g. beside the SUT in the live tree) is refused
# BEFORE anything is written (kit issue #1156).
live_out="$HERE/mutant-live-tree-probe.$$.sh"
expect_rc "placement: OUT under the live tests dir is refused (rc 8, says temp root)" 8 "temp root" \
  mutant_sed "$ORIG" "$live_out" 's/hello/x/'
if [ ! -e "$live_out" ]; then ok "placement: nothing was written to the live tree"
else no "placement: refused mutant was written to the live tree"; rm -f "$live_out"; fi

# 9 — mutant_verify on an externally built mutant (non-sed construction).
ext="$TMP/ext.sh"; cp "$ORIG" "$ext"
expect_rc "verify: externally built identical copy is refused (rc 4)" 4 "identical" \
  mutant_verify "$ORIG" "$ext"
printf '#!/usr/bin/env bash\necho changed\n' > "$ext"
mutant_verify "$ORIG" "$ext" 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then ok "verify: externally built differing mutant is accepted"
else no "verify: rc=$rc"; fi

# 10 — list edges: the anchor on the FIRST line, LAST line (no trailing newline) and a
# single-line original all register as applied mutations.
printf 'first\nmiddle\nlast' > "$TMP/edge.sh"
for pair in 's/^first$/FIRST/' 's/^last$/LAST/' 's/^middle$/MIDDLE/'; do
  MUTANT_SYNTAX=none mutant_sed "$TMP/edge.sh" "$TMP/edge.out" "$pair" 2>/dev/null; rc=$?
  if [ "$rc" -eq 0 ]; then ok "edge: $pair applies"; else no "edge: $pair refused (rc=$rc)"; fi
done
printf 'solo\n' > "$TMP/solo.sh"
MUTANT_SYNTAX=none mutant_sed "$TMP/solo.sh" "$TMP/solo.out" 's/solo/duo/' 2>/dev/null; rc=$?
if [ "$rc" -eq 0 ]; then ok "edge: single-line original mutates"
else no "edge: single-line original refused (rc=$rc)"; fi

# --- teeth: mutate the HELPER (built with the helper) and require the specific case to go red ---
if [ "${1:-}" = "--prove-teeth" ]; then
  SELFTEST="$HERE/mutant.test.sh"
  # teeth_case <name> <sed-script> <expected FAIL substring>
  teeth_case(){
    local name="$1" script="$2" needle="$3" m="$TMP/helper-$1.sh" res
    if ! mutant_sed "$LIB" "$m" "$script" 2>"$TMP/helper-$name.err"; then
      no "teeth $name: could not build a valid helper mutant ($(cat "$TMP/helper-$name.err"))"; return
    fi
    res="$(MUTANT_LIB="$m" bash "$SELFTEST" 2>&1)"
    if grep -qF "  FAIL  $needle" <<<"$res"; then
      ok "teeth $name: mutated helper turns the named case red"
    else no "teeth $name: mutated helper did NOT fail case [$needle] — check is THEATER"; fi
  }
  echo "-- teeth: helper mutants (each must fail the specific case, not just any case) --"
  teeth_case identical '/SENTINEL-IDENTICAL-CHECK/,+3s/return 4/:/' \
    "no-match: byte-identical mutant is refused"
  teeth_case empty '/SENTINEL-EMPTY-CHECK/,+3s/return 3/:/' \
    "empty: a mutant that deletes everything is refused"
  teeth_case syntax '/SENTINEL-SYNTAX-CHECK/,+6s/return 5/:/' \
    "syntax: mutant that is not valid bash is refused"
  teeth_case placement '/SENTINEL-PLACEMENT-CHECK/,+6s/return 8/:/' \
    "placement: OUT under the live tests dir is refused"
  teeth_case selfoverwrite '/SENTINEL-SELF-CHECK/,+3s/return 7/:/' \
    "self-overwrite: OUT equal to the original path is refused"
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
