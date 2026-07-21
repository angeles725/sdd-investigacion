#!/usr/bin/env bash
# vm-receipt.test.sh — contract tests for vm-run-receipt.v1
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../vm_receipt.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
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
    try: m.verify_receipt(r1,R); assert False
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
