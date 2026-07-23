#!/usr/bin/env bash
# docker-exec.test.sh — TDD RED→GREEN for LiveDockerExecutor (U-live-docker-emba).
# RED: exits 2 (SUT absent) before lib/docker_exec.py + emba_plan.py wiring.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lib/docker_exec.py"
EMBA="$HERE/../emba_plan.py"
[ -f "$SUT" ]  || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$EMBA" ] || { echo "FATAL: emba_plan.py not found: $EMBA" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" "$EMBA" <<'PY'
import hashlib, importlib.util, json, os, subprocess, sys, tempfile
from pathlib import Path

sut_path = Path(sys.argv[1]); emba_path = Path(sys.argv[2])
sys.path.insert(0, str(sut_path.parent))   # lib/ — gate, adapter_core, plan_common
sp = importlib.util.spec_from_file_location("docker_exec", sut_path)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)

passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))
def cli(*a, xe=None):
    e = os.environ.copy()
    if xe: e.update(xe)
    return subprocess.run([sys.executable, str(emba_path), *map(str, a)],
                          capture_output=True, text=True, env=e)

# Fake docker shim — records calls to DOCKER_SHIM_RECORD.
# image inspect → JSON with RepoDigests (DOCKER_INSPECT_EXIT to force failure).
# run → optional stdout emission (DOCKER_RUN_STDOUT_BYTES), optional output-file write
#       (DOCKER_WRITE_OUTPUT_FILE into the -v mount), then sleeps DOCKER_RUN_SLEEP
#       and exits DOCKER_RUN_EXIT.  kill/rm → exit 0.
_SHIM = """\
#!/usr/bin/env python3
import json,os,sys,time
a=sys.argv[1:]; cmd=a[0] if a else ""
rec=os.environ.get("DOCKER_SHIM_RECORD","")
if rec:
    try: c=json.loads(open(rec).read())
    except: c=[]
    c.append(a); open(rec,"w").write(json.dumps(c))
if cmd=="image" and len(a)>1 and a[1]=="inspect":
    e=int(os.environ.get("DOCKER_INSPECT_EXIT","0"))
    if e: print("no such image",file=sys.stderr); sys.exit(e)
    print(json.dumps([{"Id":"sha256:"+"a"*64,"RepoDigests":["embeddedanalyzer/emba@sha256:"+"b"*64]}]))
    sys.exit(0)
elif cmd=="run":
    sb=int(os.environ.get("DOCKER_RUN_STDOUT_BYTES","0"))
    if sb: sys.stdout.buffer.write(b"X"*sb); sys.stdout.buffer.flush()
    wf=os.environ.get("DOCKER_WRITE_OUTPUT_FILE","")
    if wf:
        for i,arg in enumerate(a):
            if arg=="-v" and i+1<len(a) and "/tmp/rsdd" in a[i+1]:
                host=a[i+1].split(":")[0]; os.makedirs(host,exist_ok=True)
                open(os.path.join(host,wf),"w").write("emba-output")
    sl=float(os.environ.get("DOCKER_RUN_SLEEP","0"))
    if sl: time.sleep(sl)
    sys.exit(int(os.environ.get("DOCKER_RUN_EXIT","0")))
elif cmd in("kill","rm"): sys.exit(0)
sys.exit(1)
"""

def _shim(tmp: Path) -> str:
    fd = tmp / "docker"; fd.write_text(_SHIM); fd.chmod(0o755)
    return str(tmp) + ":" + os.environ.get("PATH", "")

def _fw(tmp: Path):
    fw = tmp/"fw.bin"; d = b"FIRM"+b"\x00"*16; fw.write_bytes(d)
    return fw, "sha256:"+hashlib.sha256(d).hexdigest()

Path("/tmp/rsdd").mkdir(exist_ok=True)  # preflight (e) requires real dir

# ── RED1 (regression): allow=False + spy docker → exit 3, spy never invoked ──
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp); rec=tmp/"c.json"; p=_shim(tmp)
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),
              xe={"PATH":p,"DOCKER_SHIM_RECORD":str(rec),"RSDD_DOCKER_EXECUTOR":""})
        calls=json.loads(rec.read_text()) if rec.exists() else []
        assert r.returncode==3 and calls==[], f"rc={r.returncode} calls={calls}"
        ok("RED1: allow=False → exit 3 (auth-required), spy docker never invoked")
    except Exception as e: nok("RED1", str(e))

# ── RED2/GREEN: allow=True + fake docker → exit 0 + emba-run.v1 receipt ──────
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp); p=_shim(tmp)
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),"--allow-docker",
              xe={"PATH":p,"RSDD_DOCKER_EXECUTOR":""})
        assert r.returncode==0, f"rc={r.returncode}\n{r.stderr[:300]}"
        res=json.loads(r.stdout)
        assert res.get("schema_version")=="emba-run.v1" and res.get("executed") is True
        ea=res.get("exec_argv",[]); dl=res.get("argv_deltas",[])
        assert any("@sha256:" in a for a in ea), f"no digest in exec_argv: {ea}"
        assert "embeddedanalyzer/emba:latest" not in ea, "original tag still present"
        assert "--name" in ea and ea[ea.index("--name")+1].startswith("rsdd-")
        assert len(dl)==3 and dl[0]["transform"]=="image-digest" and dl[1]["transform"]=="inject-name"
        assert dl[2]["transform"]=="output-subdir", f"third delta wrong: {dl[2]}"
        assert any("/tmp/rsdd/rsdd-" in tok for tok in ea), f"no per-run mount in exec_argv: {ea}"
        assert "/tmp/rsdd:/tmp/rsdd" not in ea, "stale shared mount still in exec_argv"
        assert res.get("image_digest","").startswith("sha256:") and res.get("exit_code")==0
        assert "stdout_truncated" in res and "stderr_truncated" in res
        ok("RED2/GREEN: allow=True + fake docker → exit 0, emba-run.v1, three transforms verified")
    except Exception as e: nok("RED2/GREEN", str(e))

# ── G-failure-125: docker run exit 125 → adapter exit 2 ──────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp); p=_shim(tmp)
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),"--allow-docker",
              xe={"PATH":p,"DOCKER_RUN_EXIT":"125","RSDD_DOCKER_EXECUTOR":""})
        assert r.returncode==2, f"rc={r.returncode}"
        ok("G-failure-125: docker exit 125 → adapter exit 2")
    except Exception as e: nok("G-failure-125", str(e))

# ── G-timeout: wall=1s, run sleeps 3s → exit 2, kill path exercised ──────────
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp); rec=tmp/"c.json"; p=_shim(tmp)
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),
              "--allow-docker","--wall-seconds","1",
              xe={"PATH":p,"DOCKER_RUN_SLEEP":"3","DOCKER_SHIM_RECORD":str(rec),
                  "RSDD_DOCKER_EXECUTOR":""})
        calls=json.loads(rec.read_text()) if rec.exists() else []
        cmds=[c[0] for c in calls if c]
        assert r.returncode==2 and ("kill" in cmds or "rm" in cmds), \
               f"rc={r.returncode} cmds={cmds}"
        ok("G-timeout: wall exceeded → exit 2, kill path exercised")
    except Exception as e: nok("G-timeout", str(e))

# ── G-image-not-local: docker inspect exit 1 → adapter exit 2 ────────────────
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp); p=_shim(tmp)
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),"--allow-docker",
              xe={"PATH":p,"DOCKER_INSPECT_EXIT":"1","RSDD_DOCKER_EXECUTOR":""})
        assert r.returncode==2, f"rc={r.returncode}"
        ok("G-image-not-local: image absent locally → exit 2")
    except Exception as e: nok("G-image-not-local", str(e))

# ── G-no-docker: docker absent from PATH → exit 2 ────────────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp)
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),"--allow-docker",
              xe={"PATH":str(tmp),"RSDD_DOCKER_EXECUTOR":""})
        assert r.returncode==2, f"rc={r.returncode}"
        ok("G-no-docker: docker absent from PATH → exit 2")
    except Exception as e: nok("G-no-docker", str(e))

# ── CRIT1: large stdout (> _OUTPUT_CAP) → receipt capped + stdout_truncated ──
# Cap contract: executor must never return more than _OUTPUT_CAP chars per stream.
# With threaded drain, only _OUTPUT_CAP+1 bytes are retained during reading.
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp); p=_shim(tmp)
    cap=m._OUTPUT_CAP; emit=cap+4096
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),"--allow-docker",
              xe={"PATH":p,"DOCKER_RUN_STDOUT_BYTES":str(emit),"RSDD_DOCKER_EXECUTOR":""})
        assert r.returncode==0, f"rc={r.returncode}\n{r.stderr[:200]}"
        res=json.loads(r.stdout)
        assert res.get("stdout_truncated") is True, f"stdout_truncated={res.get('stdout_truncated')}"
        assert len(res.get("stdout",""))==cap, f"stdout len={len(res.get('stdout',''))}, want {cap}"
        ok("CRIT1: stdout > _OUTPUT_CAP → capped at _OUTPUT_CAP, stdout_truncated=True")
    except Exception as e: nok("CRIT1: large-stdout-cap", str(e))

# ── CRIT2: per-run output subdir in exec_argv + output_files from subdir ──────
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp); p=_shim(tmp)
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),"--allow-docker",
              xe={"PATH":p,"DOCKER_WRITE_OUTPUT_FILE":"emba-result.txt","RSDD_DOCKER_EXECUTOR":""})
        assert r.returncode==0, f"rc={r.returncode}\n{r.stderr[:300]}"
        res=json.loads(r.stdout)
        ea=res.get("exec_argv",[]); dl=res.get("argv_deltas",[])
        assert len(dl)==3 and dl[2]["transform"]=="output-subdir", f"argv_deltas={dl}"
        mounts=[tok for tok in ea if "/tmp/rsdd" in tok]
        assert any("/tmp/rsdd/rsdd-" in mv for mv in mounts), f"no per-run mount: {mounts}"
        assert "/tmp/rsdd:/tmp/rsdd" not in ea, "stale shared mount"
        of=res.get("output_files",[])
        assert any("emba-result.txt" in f.get("path","") and "/rsdd-" in f.get("path","")
                   for f in of), f"output_files missing per-run file: {of}"
        ok("CRIT2: per-run subdir in exec_argv; output_files from per-run dir")
    except Exception as e: nok("CRIT2: per-run-subdir", str(e))

# ── CRIT3-126: docker exit 126 → adapter exit 2 ──────────────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp); p=_shim(tmp)
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),"--allow-docker",
              xe={"PATH":p,"DOCKER_RUN_EXIT":"126","RSDD_DOCKER_EXECUTOR":""})
        assert r.returncode==2, f"rc={r.returncode}"
        ok("CRIT3-126: docker exit 126 → adapter exit 2")
    except Exception as e: nok("CRIT3-126", str(e))

# ── CRIT3-127: docker exit 127 → adapter exit 2 ──────────────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp); p=_shim(tmp)
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),"--allow-docker",
              xe={"PATH":p,"DOCKER_RUN_EXIT":"127","RSDD_DOCKER_EXECUTOR":""})
        assert r.returncode==2, f"rc={r.returncode}"
        ok("CRIT3-127: docker exit 127 → adapter exit 2")
    except Exception as e: nok("CRIT3-127", str(e))

# ── Unit: structural plan guards → GateError ─────────────────────────────────
from gate import GateError
for label, bad_plan in [
    ("no --network none", {"planned_argv":["docker","run","--rm"]}),
    ("--privileged",      {"planned_argv":["docker","run","--network","none","--privileged"]}),
]:
    try:
        m._preflight(bad_plan); nok(f"G-unit-{label}: expected GateError")
    except GateError: ok(f"G-unit-{label}: bad plan → GateError")
    except Exception as e: nok(f"G-unit-{label}", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
