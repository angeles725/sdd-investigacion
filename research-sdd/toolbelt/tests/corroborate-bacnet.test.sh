#!/usr/bin/env bash
# Test suite for corroborate-bacnet.sh (bacnet-evidence.v1)
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
# Pipe output to a file first to avoid interpolating JSON into a Python
# triple-quoted string (fragile if the JSON contains special characters).
# ---------------------------------------------------------------------------
"$SUT" --host 192.0.2.1 --output "$ROOT/t5" --json > "$ROOT/t5_stdout.json" 2>/dev/null || true
if python3 - "$ROOT/t5_stdout.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get('schema') == 'bacnet-evidence.v1', f"wrong schema: {d.get('schema')!r}"
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
# T7: bad --port (>65535) with --allow-live-probe → exit 2 (op error), no evidence file
# Tests live-probe exception handling: OverflowError on sendto with port out of range.
# 192.0.2.1 (TEST-NET, RFC 5737) is guaranteed unreachable; the port overflow fires
# before any kernel I/O, so this test sends no real network frames.
# ---------------------------------------------------------------------------
_t7_outdir="$ROOT/t7"
mkdir -p "$_t7_outdir"
"$SUT" --host 192.0.2.1 --port 70000 --allow-live-probe --output "$_t7_outdir" 2>/dev/null
_t7_code=$?
if [ "$_t7_code" -eq 2 ] && [ ! -f "$_t7_outdir/bacnet-evidence.v1.json" ]; then
  ok "bad-port exit-2: exits 2 with no evidence file on port overflow"
else
  no "bad-port exit-2: expected exit 2 + no evidence; got exit $_t7_code, evidence=$([ -f "$_t7_outdir/bacnet-evidence.v1.json" ] && echo yes || echo no)"
fi

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
echo "-- teeth: bacnet mutation controls --"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth || exit 2
# The mutants are python files: skip the bash -n syntax check (the helper still refuses empty,
# identical, live-tree and symlink mutants, and a stage that matches nothing).
# MUTANT_SYNTAX=none (python mutants) is scoped per call in mk_sed, never exported (#1814)
mk_sed() { local l="$1" o="$2"; shift 2; MUTANT_SYNTAX=none mutant_chain "$l" "$ORIG_PY" "$o" "$@" || { fail=$((fail+1)); return 1; }; }
tooth() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/corroborate_bacnet.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  corroborate_bacnet.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi

MUTDIR="$ROOT/mutants"; mkdir -p "$MUTDIR"
# fresh_run.sh ADAPTER.py ARGS... — run the adapter with its own empty --output dir, so the mutant
# never starts from the original's leftovers. After the run it prints the `status` field of the
# bacnet-evidence.v1.json artifact written to that dir (the artifact T2 asserts on) as
# `STATUS: <value>` and exits with the adapter's own exit code. corroborate_bacnet.py imports only the standard
# library (no sibling module), so a standalone mutant file runs exactly like the original.
cat > "$MUTDIR/fresh_run.sh" <<'SH'
#!/usr/bin/env bash
o="$(mktemp -d)"; trap 'rm -rf "$o"' EXIT
adapter="$1"; shift
python3 "$adapter" "$@" --output "$o/out"; rc=$?
python3 - "$o/out/bacnet-evidence.v1.json" <<'PY'
import json, sys
try:
    print("STATUS:", json.load(open(sys.argv[1])).get("status"))
except (OSError, ValueError) as e:
    print("STATUS: <no evidence artifact>", e)
PY
exit "$rc"
SH

# M1: the plan-only guard exits 0 instead of 3 (T1's exit-3 check). The original must exit
# EXACTLY 3 and the mutant EXACTLY 0.
mk_sed "M1 plan-only guard exit code" "$MUTDIR/m1.py" 's/sys\.exit(3)/sys.exit(0)  # MUTANT-M1/' \
  && tooth "teeth: M1 plan-only guard exit 3 -> 0" 3 0 "$MUTDIR/m1.py" --orig "$ORIG_PY" -- \
       bash "$MUTDIR/fresh_run.sh" @SUT@ --host 192.0.2.1

# M2: the plan-only status value changes (T2's schema check). The sed includes the trailing comma
# so the mutant stays valid python (a comment would swallow it and turn a status change into a
# crash). Both runs exit 3; the verdict is the status read from the evidence artifact (same file
# T2 asserts on): "plan-only" on the original, the mutated value on the mutant.
mk_sed "M2 plan-only status value" "$MUTDIR/m2.py" 's/"plan-only",/"broken-plan",  # MUTANT-M2/' \
  && tooth "teeth: M2 plan-only status value" 3 3 "$MUTDIR/m2.py" --orig "$ORIG_PY" \
       --good-has '^STATUS: plan-only$' --bad-has '^STATUS: broken-plan$' --bad-lacks '^STATUS: plan-only$' -- \
       bash "$MUTDIR/fresh_run.sh" @SUT@ --host 192.0.2.1

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
