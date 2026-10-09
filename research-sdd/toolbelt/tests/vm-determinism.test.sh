#!/usr/bin/env bash
# vm-determinism.test.sh — RED-first contract tests for vm-determinism.v1 (U-F2 / item 12)
# Written BEFORE lib/vm_plan.py; all cases fail with exit 2 ("SUT not found") until GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../lib/vm_plan.py"; REL="lib/vm_plan.py"
if [ "${1:-}" = "--teeth-child" ]; then   # argument-selected SUT for the mutation teeth (fails closed below)
  SUT="${2:-}"
  [ -f "$SUT" ] || { echo "FATAL: --teeth-child needs an existing SUT file, got [$SUT]" >&2; exit 2; }
  echo "TEETH-CHILD: SUT=$SUT"
fi
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
IFS= read -r -d '' PY_SRC <<'PY'
import copy, hashlib, importlib.util, json, re, subprocess, sys, tempfile, unittest.mock
from pathlib import Path
sut = Path(sys.argv[1])
sp = importlib.util.spec_from_file_location("vm_plan", sut)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
sys.path.insert(0, str(sut.parent.parent))
import vm_receipt
passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))
def cli(*a): return subprocess.run([sys.executable, str(sut), *map(str, a)], capture_output=True, text=True)
RID = "sha256:" + "a"*64; REPID = "sha256:" + "b"*64; FAKE = "sha256:" + "f"*64
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
def _ts():
    return {"schema_version":"vm-determinism.v1","receipt_identity":RID,"seed":42,
            "clock":{"mode":"pinned","epoch":"2026-07-21T00:00:00Z"},
            "limits_conformance":{"cpu_within":True,"mem_within":True,"wall_within":True,"output_within":True},
            "reproducible":{"basis":"identity-match","replicate_identity":RID}}

# 1: declared:true when all predicate conditions hold
try:
    r = m.build_determinism(_ts())
    assert r["reproducible"]["declared"] is True and r["reproducible"]["basis"] == "identity-match"
    assert HASH_RE.match(r["identity"]); ok("declared:true when all predicate conditions hold")
except Exception as e: nok("declared:true predicate", str(e))

# 2-8: each condition individually falsified → declared:false
for label, mutate in [
    ("cpu_within=False",     lambda s: s["limits_conformance"].__setitem__("cpu_within", False)),
    ("mem_within=False",     lambda s: s["limits_conformance"].__setitem__("mem_within", False)),
    ("wall_within=False",    lambda s: s["limits_conformance"].__setitem__("wall_within", False)),
    ("output_within=False",  lambda s: s["limits_conformance"].__setitem__("output_within", False)),
    ("clock.mode=host",      lambda s: s["clock"].update(mode="host", epoch=None)),
    ("seed=null",            lambda s: s.__setitem__("seed", None)),
    ("replicate_id!=rid",    lambda s: s["reproducible"].__setitem__("replicate_identity", REPID)),
]:
    try:
        s = _ts(); s["reproducible"]["basis"] = "unverified"; mutate(s)
        r = m.build_determinism(s)
        assert r["reproducible"]["declared"] is False, f"got {r['reproducible']['declared']}"
        ok(f"declared:false when {label}")
    except Exception as e: nok(f"condition {label}", str(e))

# 9-10: determinism (same inputs → identical; reordered-key spec → same identity)
try:
    r1 = m.build_determinism(_ts()); r2 = m.build_determinism(_ts())
    assert m.canonical_bytes(r1) == m.canonical_bytes(r2) and r1["identity"] == r2["identity"]
    ok("determinism: same inputs → identical identity (byte-stable)")
    shuffled = {"schema_version":"vm-determinism.v1","receipt_identity":RID,"seed":42,
                "clock":{"epoch":"2026-07-21T00:00:00Z","mode":"pinned"},
                "limits_conformance":{"output_within":True,"wall_within":True,"mem_within":True,"cpu_within":True},
                "reproducible":{"replicate_identity":RID,"basis":"identity-match"}}
    assert r1["identity"] == m.build_determinism(shuffled)["identity"]
    ok("determinism: reordered-key spec → same identity")
except Exception as e: nok("determinism", str(e))

# 11-15: validate_determinism rejects bad records
for label, corrupt in [
    ("bad schema_version",           lambda r: r.__setitem__("schema_version","wrong")),
    ("bad receipt_identity",         lambda r: r.__setitem__("receipt_identity","not-a-hash")),
    ("unknown clock.mode",           lambda r: r["clock"].__setitem__("mode","random")),
    ("missing field (seed)",         lambda r: r.pop("seed")),
    ("declared:true+predicate fail", lambda r: r["limits_conformance"].__setitem__("cpu_within",False)),
]:
    try:
        bad = copy.deepcopy(m.build_determinism(_ts())); corrupt(bad)
        try: m.validate_determinism(bad); nok(f"validate should reject: {label}")
        except m.VmDeterminismError: ok(f"validate_determinism rejects {label}")
    except Exception as e: nok(f"validate {label}", str(e))

# 16-20: real vm_receipt integration
OBS = {"wall_started_at":"2026-07-20T10:00:00Z","wall_ended_at":"2026-07-20T10:05:00Z",
       "wall_seconds_measured":300,"cpu_seconds_measured":250,"mem_bytes_peak":1073741824}
SHA = lambda b: "sha256:" + hashlib.sha256(b).hexdigest()
with tempfile.TemporaryDirectory() as tmp:
    R = Path(tmp)
    (R/"input.bin").write_bytes(b"input data"); (R/"output.txt").write_bytes(b"output data")
    rcpt_spec = {"schema_version":"vm-run-receipt.v1",
                 "tool":{"name":"qemu","version":"1.0","argv":["/usr/bin/qemu","--snapshot"],"sha256":FAKE},
                 "limits":{"cpu_seconds":300,"mem_bytes":2147483648,"wall_seconds":600,"output_bytes":104857600},
                 "vm_pre_snapshot":{"sha256":FAKE},"vm_post_snapshot":{"sha256":FAKE},
                 "inputs":[{"path":"input.bin","sha256":SHA(b"input data"),"size":10}],
                 "outputs":[{"path":"output.txt","sha256":SHA(b"output data"),"size":11}],
                 "exit_status":{"exit_code":0,"signal":None},"environment":{},"observed":OBS}
    rcpt = vm_receipt.build_receipt(rcpt_spec); rid = rcpt["identity"]
    rpath = R/"receipt.json"; rpath.write_text(json.dumps(rcpt))
    det_spec = {**_ts(),"receipt_identity":rid,"reproducible":{"basis":"identity-match","replicate_identity":rid}}
    try:
        det = m.build_determinism(det_spec); m.validate_determinism(det)
        assert det["receipt_identity"] == rid; ok("compose with real vm_receipt: reference + validate")
    except Exception as e: nok("compose with real vm_receipt", str(e))
    try:
        m.verify_determinism(det, rpath); ok("verify_determinism passes with real receipt")
    except Exception as e: nok("verify_determinism real receipt", str(e))
    try:
        bad = copy.deepcopy(det); bad["receipt_identity"] = FAKE
        try: m.verify_determinism(bad, rpath); nok("verify should fail for wrong receipt_identity")
        except m.VmDeterminismError: ok("verify_determinism fails closed on wrong receipt_identity")
    except Exception as e: nok("verify wrong receipt_identity", str(e))
    try:
        lc_s = {**det_spec,"limits_conformance":{**det_spec["limits_conformance"],"cpu_within":False},
                "reproducible":{"basis":"unverified","replicate_identity":rid}}
        bad_lc = m.build_determinism(lc_s)
        try: m.verify_determinism(bad_lc, rpath); nok("verify should fail on lc contradiction")
        except m.VmDeterminismError: ok("verify_determinism fails when limits_conformance contradicts receipt")
    except Exception as e: nok("verify limits_conformance mismatch", str(e))
    try:
        dry = {"schema_version":"vm-determinism.v1","receipt_identity":None,"seed":0,
               "clock":{"mode":"pinned","epoch":"2026-07-21T00:00:00Z"},
               "limits_conformance":{"cpu_within":False,"mem_within":False,"wall_within":False,"output_within":False},
               "reproducible":{"basis":"dry-run-plan","replicate_identity":None}}
        r = m.build_determinism(dry)
        assert r["reproducible"]["declared"] is False and r["reproducible"]["basis"] == "dry-run-plan"
        assert r["receipt_identity"] is None; ok("dry-run spec: declared:false, basis:dry-run-plan, receipt_identity:null")
    except Exception as e: nok("dry-run spec", str(e))

# 21-22: CLI build/validate/overwrite guard + bind safety
with tempfile.TemporaryDirectory() as tmp:
    R = Path(tmp); sp_path = R/"spec.json"; out = R/"det.json"; sp_path.write_text(json.dumps(_ts()))
    try:
        assert cli("build","--spec",sp_path,"--output",out).returncode == 0
        assert cli("validate",out).returncode == 0
        assert cli("build","--spec",sp_path,"--output",out).returncode == 2, "should refuse overwrite"
        assert cli("build","--overwrite","--spec",sp_path,"--output",out).returncode == 0
        ok("CLI: build/validate round-trip and overwrite guard")
        r = cli("build","--spec",sp_path,"--output","/home/vm-det.json")
        assert r.returncode == 2, f"expected 2, got {r.returncode}"
        ok("CLI: bind safety — /home rejected as output parent")
    except Exception as e: nok("CLI tests", str(e))

# 23: no live execution
try:
    with unittest.mock.patch("subprocess.Popen", side_effect=AssertionError("Popen!")):
        with unittest.mock.patch("subprocess.run", side_effect=AssertionError("run!")):
            _ = m.build_determinism(_ts())
    ok("no live execution: build_determinism calls no subprocess")
except Exception as e: nok("no live execution", str(e))

if failed: print(f"\n== {passed} passed · {failed} failed =="); sys.exit(1)
print(f"\n== {passed} passed · 0 failed ==")
PY
if [ "${1:-}" != "--prove-teeth" ]; then python3 -c "$PY_SRC" "$SUT"; exit $?; fi

# ── MUTATION TEETH (--prove-teeth) ─────────────────────────────────────────────
# Plain run first: its case lines are kept, its aggregate is replaced by ONE combined aggregate at the end
# (run-all.sh reads the LAST `== N passed · N failed ==` line).
py_out="$(python3 -c "$PY_SRC" "$SUT")"; py_rc=$?
printf '%s\n' "$py_out" | grep -v '^== [0-9]* passed'
pass="$(printf '%s\n' "$py_out" | sed -n 's/^== \([0-9]*\) passed · \([0-9]*\) failed ==$/\1/p' | tail -1)"
fail="$(printf '%s\n' "$py_out" | sed -n 's/^== \([0-9]*\) passed · \([0-9]*\) failed ==$/\2/p' | tail -1)"
if [ -z "$pass" ] || [ -z "$fail" ]; then
  echo "  FAIL  plain run: no aggregate line (rc=$py_rc) - the suite did not report; teeth would prove nothing"; pass=0; fail=1
fi
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_py_stage_control mutant_py_tooth mutant_py_crash_strict mutant_cleanup_register || exit 2
SELF="$HERE/$(basename "$0")"
MUT="$(mktemp -d)" || exit 2
mutant_cleanup_register "$MUT" || exit 2
tt() { if mutant_py_tooth "$1" "$HERE" "$SELF" "$MUT" "$REL" "${@:2}"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
echo "-- teeth: each guarded behaviour must be load-bearing (staged tree, one mutant per check) --"
if mutant_py_stage_control teeth-control "$HERE" "$SELF" "$MUT" "$REL"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
tt teeth-clock-mode 'and clock.get("mode") == "pinned"' 'and True' "FAIL  condition clock.mode=host: basis must be 'identity-match'"
tt teeth-seed-null 'and seed is not None' 'and True' "FAIL  condition seed=null: basis must be 'identity-match'"
tt teeth-replicate-id 'and rid is not None and repid is not None and rid == repid)' 'and rid is not None and repid is not None)' "FAIL  condition replicate_id!=rid: basis must be 'identity-match'"
tt teeth-lc-contradiction 'if actual_lc[k] != stored_lc[k]:' 'if False:' 'FAIL  verify should fail on lc contradiction'
# Not mutated (measured equivalent mutant): verify_determinism's `actual_id != record["receipt_identity"]` check - the "wrong receipt_identity"
# case is rejected earlier by validate_determinism's record-identity check, so the verify-side guard is never the one that fires.

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
