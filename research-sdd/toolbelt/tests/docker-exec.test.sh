#!/usr/bin/env bash
# docker-exec.test.sh — TDD RED→GREEN for LiveDockerExecutor (U-live-docker-emba).
# RED: exits 2 (SUT absent) before lib/docker_exec.py + emba_plan.py wiring.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
if [ "${1:-}" = "--teeth-child" ]; then   # argument-selected SUT for the mutation teeth (fails closed below)
  ARG="${2:-}"
  [ -f "$ARG" ] || { echo "FATAL: --teeth-child needs an existing SUT file, got [$ARG]" >&2; exit 2; }
  echo "TEETH-CHILD: SUT=$ARG"
  case "$ARG" in */lib/*) ROOT="$(cd "$(dirname "$ARG")/.." && pwd)" ;; *) ROOT="$(cd "$(dirname "$ARG")" && pwd)" ;; esac
fi
SUT="$ROOT/lib/docker_exec.py"
EMBA="$ROOT/emba_plan.py"
if [ "${1:-}" = "--teeth-child" ]; then   # the mutated file replaces its own slot; every other slot stays in the staged tree
  case "$ARG" in
    */lib/*) case "$(basename "$ARG")" in
      docker_exec.py) SUT="$ARG" ;;
    esac ;;
    *) case "$(basename "$ARG")" in
      emba_plan.py) EMBA="$ARG" ;;
    esac ;;
  esac
fi
[ -f "$SUT" ] || { echo "FATAL: docker_exec.py not found: $SUT" >&2; exit 2; }
[ -f "$EMBA" ] || { echo "FATAL: emba_plan.py not found: $EMBA" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
IFS= read -r -d '' PY_SRC <<'PY'
import atexit, hashlib, importlib.util, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

# #2090: the SUT's host run-dir root is $RSDD_VM_ROOT (default /tmp/rsdd). Point it at a suite-private sandbox so no
# run dir lands in /tmp/rsdd, and attribute run dirs BY IDENTITY (_produced) for the DOCKER-NOLEAK guard at the end.
_SBX = tempfile.mkdtemp(prefix="de-sbx-")
atexit.register(shutil.rmtree, _SBX, ignore_errors=True)
_SBX_ROOT = os.path.join(_SBX, "rsdd")
os.environ["RSDD_VM_ROOT"] = _SBX_ROOT
_GLOBAL_ROOT = Path("/tmp/rsdd")
def _global_names() -> set:
    try: return {x.name for x in _GLOBAL_ROOT.glob("rsdd-*")}
    except OSError: return set()
_global_before = _global_names()
_produced = set()

sut_path = Path(sys.argv[1]); emba_path = Path(sys.argv[2])
sys.path.insert(0, str(sut_path.parent))   # lib/ — gate, adapter_core, plan_common
sp = importlib.util.spec_from_file_location("docker_exec", sut_path)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
_orig_mrs = m._dc.make_run_subdir
def _rec_mrs(*a, **k):
    r = _orig_mrs(*a, **k); _produced.add(r); return r
m._dc.make_run_subdir = _rec_mrs   # in-process runs; CLI children are recorded from the paths in their output

passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))
def cli(*a, xe=None):
    e = os.environ.copy()
    if xe: e.update(xe)
    r = subprocess.run([sys.executable, str(emba_path), *map(str, a)],
                       capture_output=True, text=True, env=e)
    _produced.update(re.findall(r"/[^\s\"']*?/rsdd-[0-9a-f]{32}", r.stdout + r.stderr))
    return r

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
                host=a[i+1].split(":")[0]
                # Only a per-run dir is ever written: a mutant that leaves the shared /tmp/rsdd mount
                # unrewritten must not drop files into the host's shared /tmp/rsdd.
                if "/rsdd-" in host:
                    os.makedirs(host,exist_ok=True)
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
        assert any(tok.startswith(_SBX_ROOT + "/rsdd-") for tok in ea), f"no per-run mount under the sandbox root in exec_argv: {ea}"
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
        assert "not found locally" in r.stderr, f"inspect failure not reported as such: {r.stderr[:200]}"
        ok("G-image-not-local: image absent locally → exit 2")
    except Exception as e: nok("G-image-not-local", str(e))

# ── G-no-docker: docker absent from PATH → exit 2 ────────────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,_=_fw(tmp)
    try:
        r=cli("plan","--firmware",str(fw),"--output",str(tmp/"out"),"--allow-docker",
              xe={"PATH":str(tmp),"RSDD_DOCKER_EXECUTOR":""})
        assert r.returncode==2, f"rc={r.returncode}"
        assert "docker not found on PATH" in r.stderr, f"missing binary not reported as such: {r.stderr[:200]}"
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
        assert any(mv.startswith(_SBX_ROOT + "/rsdd-") for mv in mounts), f"no per-run mount under the sandbox root: {mounts}"
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
# Fixture: a docker shim on PATH and a plan whose firmware identity is VALID, so the only
# thing that can refuse each plan is the structural guard under test.
from gate import GateError
with tempfile.TemporaryDirectory() as td:
    tmp=Path(td); fw,fsha=_fw(tmp); _old_path=os.environ.get("PATH","")
    os.environ["PATH"]=_shim(tmp)
    try:
        for label, argv in [
            ("no --network none", ["docker","run","--rm"]),
            ("--privileged",      ["docker","run","--network","none","--privileged"]),
        ]:
            bad_plan={"planned_argv":argv,"firmware":{"path":str(fw),"sha256":fsha}}
            try:
                m._preflight(bad_plan); nok(f"G-unit-{label}: expected GateError")
            except GateError: ok(f"G-unit-{label}: bad plan → GateError")
            except Exception as e: nok(f"G-unit-{label}", str(e))
    finally: os.environ["PATH"]=_old_path

# ── ROOT-*: the explicit $RSDD_VM_ROOT override is validated (#2090 review W1/W2) ──
# Owner check (st_uid != euid) cannot be exercised unprivileged (no chown to a foreign uid): only the mode half is tested.
def _root_case(label, setup, expect_err):
    _old = os.environ.get("RSDD_VM_ROOT"); _cwd = os.getcwd()
    with tempfile.TemporaryDirectory(prefix="de-root-") as _td:
        try:
            os.chdir(_td)
            os.environ["RSDD_VM_ROOT"] = setup(_td)
            try:
                got = m._dc.ensure_rsdd_root()
                if expect_err: nok(label, f"expected GateError, got {got!r}")
                else:
                    st = os.lstat(got); assert (st.st_mode & 0o777) == 0o700, oct(st.st_mode)
                    ok(label)
            except GateError:
                ok(label) if expect_err else nok(label, "unexpected GateError")
            except Exception as e: nok(label, repr(e))
        finally:
            os.chdir(_cwd)
            if _old is None: os.environ.pop("RSDD_VM_ROOT", None)
            else: os.environ["RSDD_VM_ROOT"] = _old
def _s_symlink(td): os.mkdir(td + "/real"); os.symlink(td + "/real", td + "/lnk"); return td + "/lnk"
def _s_file(td): Path(td + "/f").write_text("x"); return td + "/f"
def _s_missing(td): return td + "/new/root"
def _s_rel(td): return "rel-root"
def _s_mode(td): os.mkdir(td + "/wr", 0o700); os.chmod(td + "/wr", 0o770); return td + "/wr"
_root_case("ROOT-SYMLINK: symlink override root -> GateError", _s_symlink, True)
_root_case("ROOT-FILE: regular-file override root -> GateError", _s_file, True)
_root_case("ROOT-MISSING: missing override root is created as a 0700 dir", _s_missing, False)
_root_case("ROOT-RELATIVE: relative override root -> GateError", _s_rel, True)
_root_case("ROOT-MODE: group-writable override root -> GateError", _s_mode, True)

# ── DOCKER-NOLEAK (#2090): no run dir THIS suite produced landed under the global /tmp/rsdd ──
# Attribution is by identity (_produced), never by content. Other new rsdd-* entries belong to someone else
# (a concurrent suite): INFO only, never failed on or deleted.
_leaked = sorted(p for p in _produced if p.startswith(str(_GLOBAL_ROOT) + os.sep))
if _leaked:
    nok("DOCKER-NOLEAK: new entries under /tmp/rsdd", f"{len(_leaked)} e.g. {_leaked[:2]}")
    for _p in _leaked:  # remove ONLY the dirs this suite produced
        shutil.rmtree(_p, ignore_errors=True)
else:
    ok("DOCKER-NOLEAK: no run dir produced by this suite under /tmp/rsdd")
_other = _global_names() - _global_before - {os.path.basename(p) for p in _leaked}
if _other: print(f"  INFO  {len(_other)} other new rsdd-* entries under /tmp/rsdd (not this suite's; left alone)")

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
if [ "${1:-}" != "--prove-teeth" ]; then python3 -c "$PY_SRC" "$SUT" "$EMBA"; exit $?; fi

# ── MUTATION TEETH (--prove-teeth) ─────────────────────────────────────────────
# Plain run first: its case lines are kept, its aggregate is replaced by ONE combined aggregate at the end
# (run-all.sh reads the LAST `== N passed · N failed ==` line).
py_out="$(python3 -c "$PY_SRC" "$SUT" "$EMBA")"; py_rc=$?
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
tt() { if mutant_py_tooth "$1" "$HERE" "$SELF" "$MUT" "${@:2}"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
echo "-- teeth: each guarded behaviour must be load-bearing (staged tree, one mutant per check) --"
if mutant_py_stage_control teeth-control "$HERE" "$SELF" "$MUT" "lib/docker_exec.py"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
tt teeth-gate-allow emba_plan.py 'run_gate_epilogue(CAP_DOCKER, args.allow_docker, plan' 'run_gate_epilogue(CAP_DOCKER, True, plan' 'FAIL  RED1: rc='
tt teeth-timeout-kill lib/docker_exec.py '_docker_kill(container_name)   # then best-effort container cleanup' 'pass' 'FAIL  G-timeout: rc=2 cmds='
tt teeth-output-cap lib/docker_exec.py 'stdout, stdout_trunc = _dc.cap(raw_out[0])' 'stdout, stdout_trunc = raw_out[0].decode(errors="replace"), False' 'FAIL  CRIT1: large-stdout-cap: stdout_truncated=False'
tt teeth-exit-126 lib/docker_exec.py 'exit_code in (125, 126, 127)' 'exit_code in (125, 127)' 'FAIL  CRIT3-126: rc=0'
tt teeth-root-hardcoded lib/docker_exec.py '_dc.make_run_subdir(run_uuid, rsdd_root)' '_dc.make_run_subdir(run_uuid)' 'FAIL  DOCKER-NOLEAK: new entries under /tmp/rsdd'
tt teeth-root-noverify lib/docker_common.py 'verify_rsdd_root(root)  # override root' 'os.lstat = os.stat  # verify deleted; also blind the later lstat so the mode check cannot back it up' 'FAIL  ROOT-SYMLINK'
tt teeth-root-nomode lib/docker_common.py 'if st.st_uid != os.geteuid() or st.st_mode & 0o022:' 'if False:' 'FAIL  ROOT-MODE'
tt teeth-root-noabs lib/docker_common.py 'if not os.path.isabs(root):' 'if False:' 'FAIL  ROOT-RELATIVE'
tt teeth-run-subdir lib/docker_exec.py 'exec_argv = [new_mount if tok == old_mount else tok for tok in exec_argv]' 'pass' 'FAIL  RED2/GREEN: no per-run mount under the sandbox root in exec_argv'

tt teeth-exit-125 lib/docker_exec.py 'exit_code in (125, 126, 127)' 'exit_code in (126, 127)' 'FAIL  G-failure-125: rc=0'
tt teeth-exit-127 lib/docker_exec.py 'exit_code in (125, 126, 127)' 'exit_code in (125, 126)' 'FAIL  CRIT3-127: rc=0'
tt teeth-image-local lib/docker_common.py '    if r.returncode != 0:
        raise GateError(
            f"image {image_tag!r} not found locally' '    if False:
        raise GateError(
            f"image {image_tag!r} not found locally' 'FAIL  G-image-not-local: inspect failure not reported as such'
tt teeth-no-docker lib/docker_common.py 'if shutil.which("docker") is None:' 'if False:' 'FAIL  G-no-docker: '
tt teeth-network-none lib/docker_exec.py '_dc.assert_network_policy(argv, "require-none")' 'pass' 'FAIL  G-unit-no --network none: expected GateError'
tt teeth-forbid-privileged lib/docker_exec.py '_dc.forbid_privileged(argv)' 'pass' 'FAIL  G-unit---privileged: expected GateError'
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
