#!/usr/bin/env bash
# verify-retro.test.sh — RED-FIRST regression harness for verify-retro.sh (U17 / #479).
#
# Tests the §18 conformance checker across four §7 failure classes:
#   1. marker-missing   — no review-status marker in leading comment block
#   2. absent-section   — no delta heading of any kind
#   3. unrecognised-heading — delta-intent heading outside the canonical grammar
#   4. empty-section    — recognised heading with zero table rows (and no §18 honesty line)
#
# Conforming states:
#   - canonical/deprecated heading + ≥1 data row
#   - §18 honesty line "no new deltas; the kit already covers this run"
#   - <!-- kit-retro: exclude --> without a review-status marker → declared non-kit, skipped
#
# Multi-defect: a single retro may fail multiple independent checks.
# The tool emits ONE finding line per failed check and exits 1 once.
#
# TEETH (--prove-teeth): sentinel-based mutants prove each guard actually bites.
#
# Usage: verify-retro.test.sh [--prove-teeth]     Exit: 0 = all held · 1 = regression

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-retro.sh"
FIX="$HERE/fixtures/verify-retro"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# assert_exit <expected-exit> <label> <file>
assert_exit() {
  local want="$1" label="$2" file="$3"
  local got; bash "$SUT" "$file" >/dev/null 2>&1; got=$?
  [ "$got" = "$want" ] && ok "$label (exit $got)" || no "$label — want exit $want, got $got"
}

# assert_exit2 <expected-exit> <label> <file> — captures stdout+stderr for exit-code assertion
assert_exit2() {
  local want="$1" label="$2" file="$3"
  local got; bash "$SUT" "$file" >"$TMP/out.txt" 2>&1; got=$?
  [ "$got" = "$want" ] && ok "$label (exit $got)" || no "$label — want exit $want, got $got"
}

# assert_out_contains <label> <pattern> <outfile> — grep -qF in captured stdout
assert_out_contains() {
  grep -qF "$2" "$3" 2>/dev/null && ok "$1 (contains: $2)" || no "$1 — pattern not found: [$2]"
}

# assert_out_absent <label> <pattern> <outfile>
assert_out_absent() {
  grep -qF "$2" "$3" 2>/dev/null && no "$1 — pattern should be ABSENT: [$2]" || ok "$1 (absent: $2)"
}

echo "== verify-retro.test.sh (SUT: $(basename "$SUT")) =="

# ─── BAD ARGS (exit 2) ───────────────────────────────────────────────────────

bash "$SUT" >"$TMP/noarg.out" 2>&1; _rc=$?
[ "$_rc" = 2 ] && ok "BAD: no arg → exit 2" || no "BAD: no arg — want 2, got $_rc"

bash "$SUT" "$TMP/nonexistent-file.md" >"$TMP/nofile.out" 2>&1; _rc=$?
[ "$_rc" = 2 ] && ok "BAD: file not found → exit 2" || no "BAD: file not found — want 2, got $_rc"

touch "$TMP/not-markdown.txt"
bash "$SUT" "$TMP/not-markdown.txt" >"$TMP/nomd.out" 2>&1; _rc=$?
[ "$_rc" = 2 ] && ok "BAD: not a .md file → exit 2" || no "BAD: not a .md → want 2, got $_rc"

# ─── CONFORMING (exit 0) ─────────────────────────────────────────────────────

bash "$SUT" "$FIX/conforming.md" >"$TMP/conf.out" 2>&1
assert_exit2 0 "CONF: conforming retro → exit 0" "$FIX/conforming.md"
bash "$SUT" "$FIX/conforming.md" >"$TMP/conf.out" 2>&1
assert_out_contains "  CONF: output says OK" "OK: conforming" "$TMP/conf.out"

# ─── HONESTY LINE (exit 0) ───────────────────────────────────────────────────

bash "$SUT" "$FIX/honesty-line.md" >"$TMP/honesty.out" 2>&1
assert_exit2 0 "HONESTY: §18 honesty line → exit 0" "$FIX/honesty-line.md"
bash "$SUT" "$FIX/honesty-line.md" >"$TMP/honesty.out" 2>&1
assert_out_contains "  HONESTY: output says OK" "OK: conforming" "$TMP/honesty.out"

# ─── KIT-RETRO: EXCLUDE (exit 0) ─────────────────────────────────────────────

bash "$SUT" "$FIX/kit-retro-exclude.md" >"$TMP/excl.out" 2>&1
assert_exit2 0 "EXCL: kit-retro: exclude → exit 0" "$FIX/kit-retro-exclude.md"
bash "$SUT" "$FIX/kit-retro-exclude.md" >"$TMP/excl.out" 2>&1
assert_out_contains "  EXCL: output says kit-retro: exclude" "kit-retro: exclude" "$TMP/excl.out"

# ─── MARKER MISSING (exit 1) ─────────────────────────────────────────────────

bash "$SUT" "$FIX/marker-missing.md" >"$TMP/mmark.out" 2>&1
assert_exit2 1 "MMARK: marker-missing → exit 1" "$FIX/marker-missing.md"
bash "$SUT" "$FIX/marker-missing.md" >"$TMP/mmark.out" 2>&1
assert_out_contains "  MMARK: names class marker-missing" "FAIL [marker-missing]" "$TMP/mmark.out"
assert_out_contains "  MMARK: fix line mentions review-status" "review-status: pending" "$TMP/mmark.out"

# ─── ABSENT SECTION (exit 1) ─────────────────────────────────────────────────

bash "$SUT" "$FIX/absent-section.md" >"$TMP/abs.out" 2>&1
assert_exit2 1 "ABS: absent-section → exit 1" "$FIX/absent-section.md"
bash "$SUT" "$FIX/absent-section.md" >"$TMP/abs.out" 2>&1
assert_out_contains "  ABS: names class absent-section" "FAIL [absent-section]" "$TMP/abs.out"
assert_out_contains "  ABS: fix mentions Proposed kit deltas" "Proposed kit deltas" "$TMP/abs.out"
assert_out_absent   "  ABS: does NOT also say empty-section" "FAIL [empty-section]" "$TMP/abs.out"

# ─── UNRECOGNISED HEADING WITH ROWS (exit 1, single finding) ─────────────────

bash "$SUT" "$FIX/unrecognised-heading.md" >"$TMP/unrec.out" 2>&1
assert_exit2 1 "UNREC: unrecognised heading → exit 1" "$FIX/unrecognised-heading.md"
bash "$SUT" "$FIX/unrecognised-heading.md" >"$TMP/unrec.out" 2>&1
assert_out_contains "  UNREC: names class unrecognised-heading" "FAIL [unrecognised-heading]" "$TMP/unrec.out"
assert_out_contains "  UNREC: names the actual heading" "Consolidated kit deltas by DESTINATION FILE" "$TMP/unrec.out"
assert_out_contains "  UNREC: fix mentions Proposed kit deltas" "Proposed kit deltas" "$TMP/unrec.out"
# KEY: rows exist but section still fails — no zero-rows finding
assert_out_absent   "  UNREC: no zero-rows finding (rows exist)" "FAIL [zero-rows]" "$TMP/unrec.out"

# ─── EMPTY SECTION — canonical heading, zero rows (exit 1) ───────────────────

bash "$SUT" "$FIX/empty-section.md" >"$TMP/empty.out" 2>&1
assert_exit2 1 "EMPTY: empty-section → exit 1" "$FIX/empty-section.md"
bash "$SUT" "$FIX/empty-section.md" >"$TMP/empty.out" 2>&1
assert_out_contains "  EMPTY: names class empty-section" "FAIL [empty-section]" "$TMP/empty.out"
assert_out_contains "  EMPTY: fix mentions adding a row" "add at least one data row" "$TMP/empty.out"
# Should NOT report absent-section or unrecognised-heading
assert_out_absent   "  EMPTY: not absent-section" "FAIL [absent-section]" "$TMP/empty.out"
assert_out_absent   "  EMPTY: not unrecognised" "FAIL [unrecognised-heading]" "$TMP/empty.out"

# ─── MULTI-DEFECT (unrecognised-heading + zero-rows, exit 1, two findings) ────

bash "$SUT" "$FIX/multi-defect.md" >"$TMP/multi.out" 2>&1
assert_exit2 1 "MULTI: multi-defect → exit 1 (once)" "$FIX/multi-defect.md"
bash "$SUT" "$FIX/multi-defect.md" >"$TMP/multi.out" 2>&1
assert_out_contains "  MULTI: names class unrecognised-heading" "FAIL [unrecognised-heading]" "$TMP/multi.out"
assert_out_contains "  MULTI: names class zero-rows" "FAIL [zero-rows]" "$TMP/multi.out"
# Count that there are exactly 2 FAIL lines
_fail_count=$(grep -c 'FAIL \[' "$TMP/multi.out" 2>/dev/null || echo 0)
[ "$_fail_count" = 2 ] && ok "  MULTI: exactly 2 FAIL lines (two findings)" \
  || no "  MULTI: expected 2 FAIL lines, got $_fail_count"

echo ""
echo "== $pass passed · $fail failed =="
echo ""

# ─── TEETH (--prove-teeth) ────────────────────────────────────────────────────

if [ "${1:-}" != "--prove-teeth" ]; then
  if [ "$fail" -gt 0 ]; then exit 1; fi
  exit 0
fi

echo "== TEETH: mutation controls =="
teeth_pass=0; teeth_fail=0
tok() { printf '  PASS  %s\n' "$1"; teeth_pass=$((teeth_pass+1)); }
tno() { printf '  FAIL  %s\n' "$1"; teeth_fail=$((teeth_fail+1)); }

# Helper: create a mutant by deleting lines between sentinel pair
make_mutant_delete_sentinel() {
  local sentinel="$1" src="$2" dst="$3"
  sed "/# ${sentinel}-START/,/# ${sentinel}-END/d" "$src" > "$dst"
  chmod +x "$dst"
}

# Helper: create a mutant by replacing a specific pattern
make_mutant_replace() {
  local pattern="$1" replacement="$2" src="$3" dst="$4"
  sed "s|${pattern}|${replacement}|g" "$src" > "$dst"
  chmod +x "$dst"
}

# MUTANT M1: strip the marker check → marker-missing fixture must exit 1 but mutant returns 0
M1="$TMP/mutant_m1.sh"
make_mutant_delete_sentinel "SENTINEL-MARKER-CHECK" "$SUT" "$M1"
bash "$M1" "$FIX/marker-missing.md" >/dev/null 2>&1; _rc=$?
[ "$_rc" = 0 ] && tok "M1: marker mutant accepts missing-marker (control goes RED → $SUT guard bites)" \
  || tno "M1: marker mutant did NOT accept missing-marker (control should have been RED)"

# MUTANT M2: make empty-section check always pass (change _cd -eq 0 to never-match)
# We replace the empty-section failure condition to never trigger
M2="$TMP/mutant_m2.sh"
# The mutant deletes the SENTINEL-DELTA-CHECK block and replaces it with a dummy
# Instead, we directly mutate the condition: replace "_cd" -eq 0 with _cd -eq -999
make_mutant_replace '_cd" -eq 0' '_cd" -eq -999' "$SUT" "$M2"
bash "$M2" "$FIX/empty-section.md" >/dev/null 2>&1; _rc=$?
[ "$_rc" = 0 ] && tok "M2: zero-row mutant accepts empty-section (control goes RED → $SUT guard bites)" \
  || tno "M2: zero-row mutant did NOT accept empty-section (control should have been RED)"

# MUTANT M3: strip the unrecognised-heading FAIL block (leaving zero-rows sub-check intact)
# With the FAIL block deleted, unrecognised-heading-with-rows exits 0 (no failures accumulated),
# proving the guard at SENTINEL-UNREC-FAIL bites in the SUT.
M3="$TMP/mutant_m3.sh"
make_mutant_delete_sentinel "SENTINEL-UNREC-FAIL" "$SUT" "$M3"
bash "$M3" "$FIX/unrecognised-heading.md" >/dev/null 2>&1; _rc=$?
[ "$_rc" = 0 ] && tok "M3: unrec-fail mutant accepts unrecognised-heading-with-rows (control goes RED → $SUT guard bites)" \
  || tno "M3: unrec-fail mutant did NOT accept unrecognised-heading-with-rows (control should have been RED)"

# MUTANT M4: strip honesty check → honesty-line fixture must exit 0 but mutant returns 1
M4="$TMP/mutant_m4.sh"
make_mutant_delete_sentinel "SENTINEL-HONESTY-CHECK" "$SUT" "$M4"
bash "$M4" "$FIX/honesty-line.md" >/dev/null 2>&1; _rc=$?
[ "$_rc" = 1 ] && tok "M4: honesty mutant rejects honesty-line fixture (control goes RED → $SUT honesty check bites)" \
  || tno "M4: honesty mutant did NOT reject honesty-line fixture (control should have been RED)"

echo ""
echo "== Teeth: $teeth_pass passed (mutation controls went RED), $teeth_fail failed =="
if [ "$fail" -gt 0 ] || [ "$teeth_fail" -gt 0 ]; then exit 1; fi
exit 0
