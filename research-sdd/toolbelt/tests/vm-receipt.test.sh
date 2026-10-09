#!/usr/bin/env bash
# vm-receipt.test.sh — contract tests for vm-run-receipt.v1
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../vm_receipt.py"; REL="vm_receipt.py"
if [ "${1:-}" = "--teeth-child" ]; then   # argument-selected SUT for the mutation teeth (fails closed below)
  SUT="${2:-}"
  [ -f "$SUT" ] || { echo "FATAL: --teeth-child needs an existing SUT file, got [$SUT]" >&2; exit 2; }
  echo "TEETH-CHILD: SUT=$SUT"
fi
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
IFS= read -r -d '' PY_SRC <<'PY'
import copy,hashlib,importlib.util,json,subprocess,sys,tempfile
from pathlib import Path
sut=Path(sys.argv[1])
s=importlib.util.spec_from_file_location("vm_receipt",sut); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
passed=0
def ok(n): global passed; passed+=1; print(f"  PASS  {n}")
def run(*a): return subprocess.run([sys.executable,str(sut),*map(str,a)],capture_output=True,text=True)
SHA=lambda b:"sha256:"+hashlib.sha256(b).hexdigest()
FAKE="sha256:"+"a"*64
OBS={"wall_started_at":"2026-07-20T10:00:00Z","wall_ended_at":"2026-07-20T10:05:00Z","wall_seconds_measured":300,"cpu_seconds_measured":250,"mem_bytes_peak":1073741824}
with tempfile.TemporaryDirectory() as tmp:
    R=Path(tmp)
    (R/"input.bin").write_bytes(b"input data"); (R/"output.txt").write_bytes(b"output data")
    spec={
        "schema_version":"vm-run-receipt.v1",
        "tool":{"name":"qemu-test","version":"1.0","argv":["/usr/bin/qemu","--snapshot","input.bin"],"sha256":FAKE},
        "limits":{"cpu_seconds":300,"mem_bytes":2147483648,"wall_seconds":600,"output_bytes":104857600},
        "vm_pre_snapshot":{"sha256":FAKE},"vm_post_snapshot":{"sha256":FAKE},
        "inputs":[{"path":"input.bin","sha256":SHA(b"input data"),"size":10}],
        "outputs":[{"path":"output.txt","sha256":SHA(b"output data"),"size":11}],
        "exit_status":{"exit_code":0,"signal":None},
        "environment":{},
        "observed":OBS,
    }
    r1=m.build_receipt(spec); r2=m.build_receipt(spec)
    assert m.canonical_bytes(r1)==m.canonical_bytes(r2)
    ok("build_receipt is byte-identical for identical inputs (determinism)")
    later=copy.deepcopy(spec); later["observed"].update(wall_started_at="2026-07-21T12:00:00Z",wall_seconds_measured=999)
    r3=m.build_receipt(later)
    assert r1["identity"]==r3["identity"]
    ok("identity digest is stable across different observed values")
    assert(r1["tool"]["argv"]==spec["tool"]["argv"] and r1["limits"]["cpu_seconds"]==300
           and r1["vm_pre_snapshot"]["sha256"]==FAKE and r1["inputs"][0]["sha256"]==SHA(b"input data")
           and r1["exit_status"]["exit_code"]==0 and r1["exit_status"]["signal"] is None
           and "observed" in r1 and r1["observed"]["wall_started_at"]==OBS["wall_started_at"])
    ok("receipt content-addresses tool/limits/snapshots/artifacts/exit_status and records observed")
    m.verify_receipt(r1,R)
    ok("verify_receipt passes when artifacts match recorded digests")
    (R/"output.txt").write_bytes(b"tampered!")
    try: m.verify_receipt(r1,R); assert False,"verify_receipt must fail closed on artifact digest mismatch"
    except m.VmReceiptError: ok("verify_receipt fails closed on artifact digest mismatch")
    (R/"output.txt").write_bytes(b"output data")
    for label,mutate in [
        ("missing required field",     lambda d: d.pop("limits")),
        ("bad digest shape in snapshot",lambda d: d["vm_pre_snapshot"].update(sha256="not-a-hash")),
        ("zero limit",                  lambda d: d["limits"].update(cpu_seconds=0)),
        ("negative limit",              lambda d: d["limits"].update(mem_bytes=-1)),
        ("secret-like argv option",     lambda d: d["tool"]["argv"].__setitem__(1,"--token=abc")),
        ("secret env key",              lambda d: d["environment"].update(PASSWORD="hunter2")),
        ("secret env value",            lambda d: d["environment"].update(LANG="Bearer supersecrettoken")),
        ("both exit_code and signal",   lambda d: d["exit_status"].update(signal=9)),
        ("neither exit_code nor signal",lambda d: d["exit_status"].update(exit_code=None,signal=None)),
    ]:
        t=copy.deepcopy(r1); mutate(t)
        try: m.validate_receipt(t); assert False,"expected VmReceiptError for: "+label
        except m.VmReceiptError: ok(f"validate_receipt rejects {label}")
    sf=R/"spec.json"; sf.write_text(json.dumps(spec)); rf=R/"receipt.json"
    assert run("build","--spec",sf,"--output",rf).returncode==0,run("build","--spec",sf,"--output",rf).stderr
    assert run("validate",rf).returncode==0
    assert run("verify","--artifacts-dir",R,rf).returncode==0
    assert run("build","--spec",sf,"--output",rf).returncode==2,"should refuse to overwrite without --overwrite"
    assert run("build","--overwrite","--spec",sf,"--output",rf).returncode==0
    ok("CLI build/validate/verify round-trip and overwrite guard")
    # --- TDD RED tests: security fixes (fail before fix, pass after) ---------
    import stat as _stat
    try:
        m._artifacts([{"path":"/etc/passwd","sha256":FAKE,"size":10}],"inputs")
        assert False,"_artifacts must reject absolute artifact path"
    except m.VmReceiptError: ok("_artifacts rejects absolute artifact path")
    try:
        m._artifacts([{"path":"../escape","sha256":FAKE,"size":10}],"inputs")
        assert False,"_artifacts must reject dotdot path '../escape'"
    except m.VmReceiptError: ok("_artifacts rejects dotdot path '../escape'")
    try:
        m._observed({**OBS,"mem_bytes_peak":float("nan")})
        assert False,"_observed must reject NaN mem_bytes_peak"
    except m.VmReceiptError: ok("_observed rejects NaN mem_bytes_peak")
    try:
        m._observed({**OBS,"cpu_seconds_measured":float("inf")})
        assert False,"_observed must reject +inf cpu_seconds_measured"
    except m.VmReceiptError: ok("_observed rejects +inf cpu_seconds_measured")
    _ep=Path("/etc/passwd")
    if _ep.exists() and _stat.S_ISREG(_ep.lstat().st_mode):
        _,_ps,_ph=m._file_identity(_ep)
        try:
            _evil=m.build_receipt({**spec,"inputs":[{"path":"/etc/passwd","sha256":_ph,"size":_ps}]})
            m.verify_receipt(_evil,R)
            assert False,"CRITICAL: verify_receipt escaped artifacts_dir to verify /etc/passwd"
        except m.VmReceiptError: ok("path-traversal: absolute path rejected, artifacts_dir confined")
    m.verify_receipt(r1,R)
    ok("regression: valid relative artifact path still verifies after hardening")
print(f"== {passed} passed · 0 failed ==")
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
# This suite reports a bite as an uncaught AssertionError (it has no nok()), so the Traceback header is the expected signal:
# the crash filter is the strict one MINUS Traceback, and every BAD_HAS pins the AssertionError message text.
CRASH_NOTB="$(mutant_py_crash_strict | sed 's/^Traceback|//')"
tt teeth-digest-mismatch 'if actual_size != rec["size"] or actual_sha != rec["sha256"]:' 'if False:' 'AssertionError: verify_receipt must fail closed on artifact digest mismatch' "$CRASH_NOTB"
tt teeth-dotdot 'if Path(p).is_absolute() or ".." in Path(p).parts:' 'if Path(p).is_absolute():' "AssertionError: _artifacts must reject dotdot path '../escape'" "$CRASH_NOTB"
tt teeth-absolute 'if Path(p).is_absolute() or ".." in Path(p).parts:' 'if ".." in Path(p).parts:' 'AssertionError: _artifacts must reject absolute artifact path' "$CRASH_NOTB"
tt teeth-nan 'or not math.isfinite(v[k]) or v[k] < 0):' 'or v[k] < 0):' 'AssertionError: _observed must reject NaN mem_bytes_peak' "$CRASH_NOTB"
# Not mutated (measured equivalent mutants - no case isolates them): the validate_receipt field checks the corrupt-record table exercises
# (zero limit via _posint, exit_status both/neither) - each mutant was run and the suite stayed green, because validate_receipt's identity
# check rejects every mutated record first; and the verify_receipt "resolves outside artifacts_dir" confinement - the absolute /etc/passwd
# case is rejected earlier by _artifacts, so no case reaches that guard on its own.

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
