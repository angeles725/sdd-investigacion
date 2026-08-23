#!/usr/bin/env bash
# test-lane.test.sh — contract for lib/test-lane.sh.
#
# Covers:
#   a) RSDD_TEST_LANE unset   → rsdd_lane echoes "fast" (default)
#   b) RSDD_TEST_LANE=fast    → echoes "fast"
#   c) RSDD_TEST_LANE=slow    → echoes "slow"
#   d) RSDD_TEST_LANE=all     → echoes "all"
#   e) RSDD_TEST_LANE=garbage → FAILS CLOSED (non-zero + stderr, NOT silent)
#   f) rsdd_lane_fixture path → resolves expected fixture path deterministically
#   g) rsdd_lane_fixture missing args → returns non-zero
#   h) direct execution guard → non-zero exit when run directly
#
# --prove-teeth block:
#   M1 — change "return 1" to "return 0" → garbage no longer fails → assertion e goes RED
#   M2 — change default from "fast" to "slow" → assertion a goes RED
#
# Usage: test-lane.test.sh [--prove-teeth]
# Exit:  0 = all pass · 1 = regression · 2 = harness error

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/test-lane.sh"
[ -f "$LIB" ] || { echo "FATAL: lib/test-lane.sh not found: $LIB" >&2; exit 2; }

# shellcheck source=../lib/test-lane.sh
. "$LIB"

pass=0; fail=0
ok() { printf '  PASS  %-64s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-64s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== test-lane.test.sh =="

# a — unset RSDD_TEST_LANE defaults to "fast"
result_a=""
rc_a=0
result_a="$(unset RSDD_TEST_LANE; rsdd_lane)" || rc_a=$?
if [[ "$rc_a" -eq 0 && "$result_a" == "fast" ]]; then
  ok "a unset RSDD_TEST_LANE: defaults to fast" "(got: $result_a)"
else
  no "a unset RSDD_TEST_LANE: defaults to fast" "rc=$rc_a got=[$result_a]"
fi

# b — RSDD_TEST_LANE=fast echoes "fast"
result_b=""
rc_b=0
result_b="$(RSDD_TEST_LANE=fast rsdd_lane)" || rc_b=$?
if [[ "$rc_b" -eq 0 && "$result_b" == "fast" ]]; then
  ok "b RSDD_TEST_LANE=fast: echoes fast" "(got: $result_b)"
else
  no "b RSDD_TEST_LANE=fast: echoes fast" "rc=$rc_b got=[$result_b]"
fi

# c — RSDD_TEST_LANE=slow echoes "slow"
result_c=""
rc_c=0
result_c="$(RSDD_TEST_LANE=slow rsdd_lane)" || rc_c=$?
if [[ "$rc_c" -eq 0 && "$result_c" == "slow" ]]; then
  ok "c RSDD_TEST_LANE=slow: echoes slow" "(got: $result_c)"
else
  no "c RSDD_TEST_LANE=slow: echoes slow" "rc=$rc_c got=[$result_c]"
fi

# d — RSDD_TEST_LANE=all echoes "all"
result_d=""
rc_d=0
result_d="$(RSDD_TEST_LANE=all rsdd_lane)" || rc_d=$?
if [[ "$rc_d" -eq 0 && "$result_d" == "all" ]]; then
  ok "d RSDD_TEST_LANE=all: echoes all" "(got: $result_d)"
else
  no "d RSDD_TEST_LANE=all: echoes all" "rc=$rc_d got=[$result_d]"
fi

# e — RSDD_TEST_LANE=garbage FAILS CLOSED (non-zero + stderr, NOT silent)
rc_e=0
stderr_e=""
result_e=""
stderr_e="$(RSDD_TEST_LANE=garbage rsdd_lane 2>&1 >/dev/null)" || rc_e=$?
result_e="$(RSDD_TEST_LANE=garbage rsdd_lane 2>/dev/null)" || true
if [[ "$rc_e" -ne 0 && -n "$stderr_e" && -z "$result_e" ]]; then
  ok "e RSDD_TEST_LANE=garbage: fails closed (non-zero + stderr)" "(rc=$rc_e msg=[$stderr_e])"
else
  no "e RSDD_TEST_LANE=garbage: fails closed (non-zero + stderr)" \
     "rc=$rc_e stderr=[$stderr_e] stdout=[$result_e]"
fi

# f — rsdd_lane_fixture resolves expected path
result_f=""
rc_f=0
result_f="$(rsdd_lane_fixture my-suite my-fixture)" || rc_f=$?
toolbelt_dir="$(dirname "$HERE")"
expected_f="${toolbelt_dir}/tests/fixtures/lane/my-suite/my-fixture.json"
if [[ "$rc_f" -eq 0 && "$result_f" == "$expected_f" ]]; then
  ok "f rsdd_lane_fixture: resolves expected path" "(got: $result_f)"
else
  no "f rsdd_lane_fixture: resolves expected path" \
     "rc=$rc_f got=[$result_f] want=[$expected_f]"
fi

# g — rsdd_lane_fixture with missing args returns non-zero
rc_g=0
rsdd_lane_fixture >/dev/null 2>&1 || rc_g=$?
if [[ "$rc_g" -ne 0 ]]; then
  ok "g rsdd_lane_fixture no args: non-zero exit" "(rc=$rc_g)"
else
  no "g rsdd_lane_fixture no args: non-zero exit" "rc=$rc_g"
fi

# h — direct execution guard: running lib/test-lane.sh directly must exit non-zero
rc_h=0
bash "$LIB" >/dev/null 2>&1 || rc_h=$?
if [[ "$rc_h" -ne 0 ]]; then
  ok "h direct execution guard: non-zero when run directly" "(rc=$rc_h)"
else
  no "h direct execution guard: non-zero when run directly" "rc=$rc_h (expected non-zero)"
fi

# ── Summary ────────────────────────────────────────────────────────────────────

echo "== $pass passed · $fail failed =="

# ── Prove-teeth block ──────────────────────────────────────────────────────────
if [[ "${1:-}" != "--prove-teeth" ]]; then
  exit "$(( fail > 0 ? 1 : 0 ))"
fi

echo ""
echo "=== --prove-teeth: verifying mutation controls ==="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
teeth_pass=0; teeth_fail=0
tok() { printf '  PASS  [teeth] %-56s %s\n' "$1" "${2:-}"; teeth_pass=$((teeth_pass+1)); }
ton() { printf '  FAIL  [teeth] %-56s %s\n' "$1" "${2:-}"; teeth_fail=$((teeth_fail+1)); }

# Build a mutant lib directory so BASH_SOURCE resolves via $TMP/lib/.
mkdir -p "$TMP/lib"

# Mutation tests use fresh bash processes so the idempotency guard in each mutant
# starts clean — inherited-function scope would prevent the guard from firing.

# ── M1: change "return 1" to "return 0" → garbage must now succeed (assertion e goes RED) ──
echo "-- teeth M1: return 1 → return 0; garbage must no longer fail --"
MUTANT_M1="$TMP/lib/test-lane.M1.sh"
sed 's/return 1/return 0/g' "$LIB" > "$MUTANT_M1"
if ! grep -q 'return 0' "$MUTANT_M1"; then
  ton "M1: could not build mutant (return 1 not found — SUT drifted?)" ""
else
  rc_m1=0
  result_m1="$(bash -c ". \"$MUTANT_M1\"; RSDD_TEST_LANE=garbage rsdd_lane 2>/dev/null")" \
    || rc_m1=$?
  if [[ "$rc_m1" -eq 0 ]]; then
    tok "M1: mutant (return 1→0) lets garbage pass; assertion e would go RED" \
        "(got: [$result_m1])"
  else
    ton "M1: mutant still exits non-zero on garbage — M1 has no teeth" \
        "rc=$rc_m1"
  fi
fi

# ── M2: change default from "fast" to "slow" → assertion a goes RED ──
echo "-- teeth M2: default fast → slow; assertion a must go RED --"
MUTANT_M2="$TMP/lib/test-lane.M2.sh"
sed 's/RSDD_TEST_LANE:-fast/RSDD_TEST_LANE:-slow/' "$LIB" > "$MUTANT_M2"
if ! grep -q 'RSDD_TEST_LANE:-slow' "$MUTANT_M2"; then
  ton "M2: could not build mutant (default pattern not found — SUT drifted?)" ""
else
  result_m2=""
  result_m2="$(bash -c "unset RSDD_TEST_LANE; . \"$MUTANT_M2\"; rsdd_lane")" || true
  if [[ "$result_m2" != "fast" ]]; then
    tok "M2: mutant default is slow (not fast); assertion a would go RED" \
        "(got: $result_m2)"
  else
    ton "M2: mutant default is still fast — M2 has no teeth" \
        "(got: $result_m2)"
  fi
fi

echo ""
echo "== teeth: $teeth_pass passed · $teeth_fail failed =="
echo "== $pass passed · $fail failed =="

final_rc=0
[[ $fail -gt 0 || $teeth_fail -gt 0 ]] && final_rc=1
exit "$final_rc"
