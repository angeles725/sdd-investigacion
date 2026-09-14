#!/usr/bin/env bash
# Test suite for corroborate-bacnet.sh (bacnet-evidence.v1)
# SENTINEL-NO-TEETH-BANNER (do not remove — run-all.sh teeth coverage)
#
# All tests are OFFLINE: no live BACnet/IP network is required.
# The plan-only guard (exit 3 without --allow-live-probe) is the primary
# testable surface; live probing requires a reachable BACnet/IP device.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../corroborate-bacnet.sh"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ---------------------------------------------------------------------------
# T1: absent --allow-live-probe → exit 3 (plan-only guard)
# Uses 192.0.2.1 (TEST-NET, RFC 5737) — guaranteed unreachable even if the
# guard were somehow bypassed; exit 3 must come from the guard, not a timeout.
# ---------------------------------------------------------------------------
"$SUT" --host 192.0.2.1 --output "$ROOT/t1" 2>/dev/null
_t1_code=$?
if [ "$_t1_code" -eq 3 ]; then
  ok "plan-only guard: exit 3 without --allow-live-probe"
else
  no "plan-only guard: expected exit 3, got $_t1_code"
fi

# ---------------------------------------------------------------------------
# T2: plan-only JSON written and schema is correct
# ---------------------------------------------------------------------------
if python3 - "$ROOT/t1/bacnet-evidence.v1.json" <<'PY'
import json, sys, os
p = sys.argv[1]
assert os.path.exists(p), f"plan-only JSON not written at: {p}"
d = json.load(open(p))
assert d.get('schema') == 'bacnet-evidence.v1', \
    f"wrong schema: {d.get('schema')!r}"
assert d.get('status') == 'plan-only', \
    f"expected plan-only, got: {d.get('status')!r}"
assert d.get('host') == '192.0.2.1', \
    f"host mismatch: {d.get('host')!r}"
assert isinstance(d.get('port'), int), \
    f"port not int: {d.get('port')!r}"
assert 'guard' in d, "guard field missing from plan-only output"
plan = d.get('plan', {})
assert plan.get('read_only') is True, "plan.read_only must be true"
probes = plan.get('probes', [])
assert 'unicast-who-is' in probes, "unicast-who-is missing from plan.probes"
assert 'read-bdt' in probes, "read-bdt missing from plan.probes"
PY
then ok "plan-only JSON schema: required fields present and correct"
else no "plan-only JSON schema"; fi

# ---------------------------------------------------------------------------
# T3: missing --host → non-zero exit (argparse error)
# ---------------------------------------------------------------------------
if ! "$SUT" --output "$ROOT/t3" 2>/dev/null; then
  ok "missing --host: non-zero exit"
else
  no "missing --host: expected non-zero exit, got 0"
fi

# ---------------------------------------------------------------------------
# T4: missing --output → non-zero exit (argparse error)
# Note: --allow-live-probe absent still fires, but argparse handles --output
# first (both are required). Without --allow-live-probe the guard is also
# active; this test checks the arg-validation layer specifically.
# ---------------------------------------------------------------------------
if ! "$SUT" --host 192.0.2.1 2>/dev/null; then
  ok "missing --output: non-zero exit"
else
  no "missing --output: expected non-zero exit, got 0"
fi

# ---------------------------------------------------------------------------
# T5: --json flag writes valid JSON to stdout (plan-only path)
# ---------------------------------------------------------------------------
_t5_out="$("$SUT" --host 192.0.2.1 --output "$ROOT/t5" --json 2>/dev/null || true)"
if python3 - <<PY
import json, sys
s = """$_t5_out"""
try:
    d = json.loads(s)
except json.JSONDecodeError as e:
    sys.exit(1)
assert d.get('schema') == 'bacnet-evidence.v1', f"wrong schema: {d.get('schema')!r}"
sys.exit(0)
PY
then ok "--json flag: stdout is valid bacnet-evidence.v1 JSON"
else no "--json flag: stdout is not valid JSON or wrong schema"; fi

# ---------------------------------------------------------------------------
# T6: --port override is reflected in the plan-only output
# ---------------------------------------------------------------------------
"$SUT" --host 192.0.2.1 --port 47809 --output "$ROOT/t6" 2>/dev/null || true
if python3 - "$ROOT/t6/bacnet-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get('port') == 47809, f"port not reflected: {d.get('port')!r}"
PY
then ok "--port override reflected in plan-only output"
else no "--port override"; fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
# --prove-teeth mutation control
# ---------------------------------------------------------------------------
echo "--- mutation control ---"
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/corroborate_bacnet.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  corroborate_bacnet.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed · $MUT_PASS mut-pass · 1 mut-fail =="
  exit 1
fi

# Mutation M1: change sys.exit(3) to sys.exit(0) in the plan-only guard.
# Expected: plan-only guard exits 0 instead of 3 → T1's exit-3 check fires.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/sys\.exit(3)/sys.exit(0)  # MUTANT-M1/' "$MUTDIR/corroborate_bacnet.py"

if cmp -s "$ORIG_PY" "$MUTDIR/corroborate_bacnet.py"; then
  # Fallback: mutation expression did not match — try alternate form
  cp "$ORIG_PY" "$MUTDIR/corroborate_bacnet.py"
  sed -i "s/\"status\": \"plan-only\"/\"status\": \"live-probe\"  # MUTANT-M1/" \
    "$MUTDIR/corroborate_bacnet.py"
fi

MUTOUT="$ROOT/mut_t1"
mkdir -p "$MUTOUT"
python3 "$MUTDIR/corroborate_bacnet.py" \
    --host 192.0.2.1 --output "$MUTOUT" 2>/dev/null
_m1_code=$?

if [ "$_m1_code" -eq 3 ]; then
  # Mutant still exits 3 — mutation had no effect or wrong fallback
  mut_no "M1 exit-3 mutation NOT detected (mutant still exits 3)"
elif [ "$_m1_code" -eq 0 ]; then
  # Mutant exits 0 — the T1 assertion (code == 3) would fail
  mut_ok "M1 exit-3 mutation detected: mutant exits 0 (T1 would catch this)"
else
  # Any non-zero ≠ 3: the original assertion would also fire (code != 3)
  mut_ok "M1 exit-3 mutation detected: mutant exits $_m1_code ≠ 3 (T1 would catch this)"
fi

# Mutation M2: change plan-only status value so schema check (T2) fires.
cp "$ORIG_PY" "$MUTDIR/corroborate_bacnet.py"
sed -i "s/\"plan-only\"/\"broken-plan\"  # MUTANT-M2/" "$MUTDIR/corroborate_bacnet.py"

if cmp -s "$ORIG_PY" "$MUTDIR/corroborate_bacnet.py"; then
  mut_no "M2 status mutation had no effect — check sed expression"
else
  MUTOUT2="$ROOT/mut_t2"
  mkdir -p "$MUTOUT2"
  python3 "$MUTDIR/corroborate_bacnet.py" \
      --host 192.0.2.1 --output "$MUTOUT2" 2>/dev/null || true
  if python3 - "$MUTOUT2/bacnet-evidence.v1.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
# This assertion SHOULD FAIL for the mutant (status is "broken-plan", not "plan-only")
assert d.get('status') == 'plan-only', "status not plan-only"
PY
  then
    mut_no "M2 status mutation NOT detected (T2 did not fire)"
  else
    mut_ok "M2 status mutation detected: T2 schema check would fire"
  fi
fi

rm -rf "$MUTDIR"

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
