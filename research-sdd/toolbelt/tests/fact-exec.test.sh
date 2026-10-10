#!/usr/bin/env bash
# fact-exec.test.sh — TDD RED→GREEN for LiveFactExecutor (U-live-docker-fact Unit B2).
# RED: exits 2 (SUT absent) before lib/fact_exec.py + wiring in fact_plan.py.
# All docker/network calls are offline (fake shim + loopback ThreadingHTTPServer).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lib/fact_exec.py"; REL="lib/fact_exec.py"
FACT="$HERE/../fact_plan.py"
if [ "${1:-}" = "--teeth-child" ]; then   # argument-selected SUT for the mutation teeth (fails closed below)
  SUT="${2:-}"
  [ -f "$SUT" ] || { echo "FATAL: --teeth-child needs an existing SUT file, got [$SUT]" >&2; exit 2; }
  FACT="$(dirname "$SUT")/../fact_plan.py"   # the CLI cases must import the SAME staged lib/ the mutant lives in
  echo "TEETH-CHILD: SUT=$SUT"
fi
[ -f "$SUT" ]  || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$FACT" ] || { echo "FATAL: fact_plan.py not found: $FACT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
IFS= read -r -d '' PY_SRC <<'PY'
import atexit, hashlib, http.server, importlib.util, json, os, re, shutil, subprocess, sys, tempfile, threading, time
from pathlib import Path

# #2090: the SUT's host run-dir root is $RSDD_VM_ROOT (default /tmp/rsdd). Point it at a suite-private sandbox so no
# run dir lands in /tmp/rsdd, and attribute run dirs BY IDENTITY (_produced) for the FACT-NOLEAK guard at the end.
_SBX = tempfile.mkdtemp(prefix="fe-sbx-")
atexit.register(shutil.rmtree, _SBX, ignore_errors=True)
_SBX_ROOT = os.path.join(_SBX, "rsdd")
os.environ["RSDD_VM_ROOT"] = _SBX_ROOT
_GLOBAL_ROOT = Path("/tmp/rsdd")
def _global_names() -> set:
    try: return {x.name for x in _GLOBAL_ROOT.glob("rsdd-*")}
    except OSError: return set()
_global_before = _global_names()
_produced = set()

sut_path  = Path(sys.argv[1])
fact_path = Path(sys.argv[2])
sys.path.insert(0, str(sut_path.parent))   # lib/ — gate, adapter_core, docker_common
sp = importlib.util.spec_from_file_location("fact_exec", sut_path)
m  = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
_orig_mrs = m._dc.make_run_subdir
def _rec_mrs(*a, **k):
    r = _orig_mrs(*a, **k); _produced.add(r); return r
m._dc.make_run_subdir = _rec_mrs   # in-process runs; CLI children are recorded from the paths in their output

passed = 0; failed = 0
def ok(n):      global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""):global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))

def cli(*a, xe=None):
    e = os.environ.copy()
    if xe: e.update(xe)
    r = subprocess.run([sys.executable, str(fact_path), *map(str, a)],
                       capture_output=True, text=True, env=e)
    _produced.update(re.findall(r"/[^\s\"']*?/rsdd-[0-9a-f]{32}", r.stdout + r.stderr))
    return r

# ---------------------------------------------------------------------------
# Fake docker shim — records argv to DOCKER_SHIM_RECORD.
# Handles: image inspect, compose up/ps/down, docker inspect (containers).
# ---------------------------------------------------------------------------
_SHIM = """\
#!/usr/bin/env python3
import json, os, sys, time
a = sys.argv[1:]; cmd = a[0] if a else ""

rec = os.environ.get("DOCKER_SHIM_RECORD", "")
if rec:
    try: c = json.loads(open(rec).read())
    except: c = []
    c.append(a); open(rec, "w").write(json.dumps(c))

def _image_inspect_exit():
    return int(os.environ.get("DOCKER_INSPECT_EXIT", "0"))

if cmd == "image" and len(a) > 1 and a[1] == "inspect":
    e = _image_inspect_exit()
    if e: print("no such image", file=sys.stderr); sys.exit(e)
    tag = a[2] if len(a) > 2 else ""
    bad_id = os.environ.get("DOCKER_IMAGE_ID_DIGEST_UNKNOWN", "")
    if tag == "sha256:" + "a" * 64 and not bad_id:
        dh = "a" * 64; repo = f"fkiecad/fact_frontend@sha256:{dh}"
    elif tag == "sha256:" + "b" * 64 and not bad_id:
        dh = "b" * 64; repo = f"fkiecad/fact_core@sha256:{dh}"
    elif tag == "sha256:" + "c" * 64 and not bad_id:
        dh = "c" * 64; repo = f"fkiecad/fact_db@sha256:{dh}"
    elif tag.startswith("sha256:") and bad_id:
        dh = "d" * 64; repo = f"unknown@sha256:{dh}"
    elif "frontend" in tag:
        dh = "a" * 64; repo = f"fkiecad/fact_frontend@sha256:{dh}"
    elif "core" in tag or "fact_core" in tag:
        dh = "b" * 64; repo = f"fkiecad/fact_core@sha256:{dh}"
    elif "db" in tag:
        dh = "c" * 64; repo = f"fkiecad/fact_db@sha256:{dh}"
    else:
        dh = "d" * 64; repo = f"unknown@sha256:{dh}"
    print(json.dumps([{"Id": f"sha256:{dh}", "RepoDigests": [repo]}]))
    sys.exit(0)

elif cmd == "compose":
    # Determine sub-command (up / ps / down) skipping flags and their values
    idx = 1
    subcmd = ""
    while idx < len(a):
        tok = a[idx]
        if tok in ("-p", "-f", "--file", "--project-name", "--project-directory"):
            idx += 2; continue
        if tok.startswith("-"):
            idx += 1; continue
        subcmd = tok; break
    if subcmd == "up":
        sl = float(os.environ.get("DOCKER_COMPOSE_SLEEP", "0"))
        if sl: time.sleep(sl)
        sys.exit(int(os.environ.get("DOCKER_COMPOSE_UP_EXIT", "0")))
    elif subcmd == "ps":
        out = os.environ.get("DOCKER_PS_OUTPUT", "c1abc123\\nc2abc456\\nc3abc789\\n")
        sys.stdout.write(out); sys.exit(0)
    elif subcmd == "down":
        sys.exit(0)
    else:
        sys.exit(0)

elif cmd == "inspect":
    # Container inspect — return canned JSON
    canned = os.environ.get("DOCKER_CONTAINER_INSPECT_JSON", "")
    if canned:
        sys.stdout.write(canned); sys.exit(0)
    # Default: passes post-up verification (empty Mounts → no mount violations)
    # The project name is dynamic (fact-<uuid8>); empty Mounts sidesteps the
    # project-name prefix check so tests don't need cross-call state sharing.
    cid = a[1] if len(a) > 1 else "c1"
    data = [{
        "Id": f"sha256:{'a'*64}",
        "Image": f"sha256:{'a'*64}",
        "Config": {"Image": "fkiecad/fact_frontend:latest"},
        "Mounts": [],
        "NetworkSettings": {
            "Networks": {"bridge": {"IPAddress": "172.20.0.2"}}
        }
    }]
    sys.stdout.write(json.dumps(data)); sys.exit(0)

elif cmd == "network" and len(a) > 1 and a[1] == "inspect":
    internal = os.environ.get("DOCKER_NETWORK_INTERNAL", "true") != "false"
    net_name = a[2] if len(a) > 2 else "unknown"
    print(json.dumps([{"Name": net_name, "Internal": internal}]))
    sys.exit(0)

elif cmd in ("kill", "rm"):
    sys.exit(0)

sys.exit(1)
"""

def _shim(tmp: Path) -> str:
    """Install fake docker shim in tmp; return PATH string."""
    fd = tmp / "docker"; fd.write_text(_SHIM); fd.chmod(0o755)
    return str(tmp) + ":" + os.environ.get("PATH", "")

def _fw(tmp: Path, content: bytes = b"FIRM" + b"\x00" * 16):
    """Write firmware file; return (path, sha256_hex)."""
    fw = tmp / "fw.bin"; fw.write_bytes(content)
    sha = "sha256:" + hashlib.sha256(content).hexdigest()
    return fw, sha

# ---------------------------------------------------------------------------
# Loopback HTTP stub — PUT capture, readiness + analysis status sequence.
# ---------------------------------------------------------------------------
class _StubHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        srv = self.server
        if self.path == "/rest/firmware":
            # readiness check
            code = getattr(srv, "readiness_code", 200)
            self.send_response(code); self.end_headers()
            if code == 200: self.wfile.write(b"[]")
        elif self.path.startswith("/rest/firmware/"):
            uid = self.path[len("/rest/firmware/"):]
            ovr = getattr(srv, "analysis_body_override", None)
            if ovr is not None:
                body = ovr
            elif getattr(srv, "analysis_never_done", False):
                body = json.dumps({"uid": uid, "analysis_status": {"is_finished": False}}).encode()
            else:
                body = json.dumps({"uid": uid, "analysis_status": {"is_finished": True, "status": "done"}}).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def do_PUT(self):
        cl = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(cl)
        self.server.put_body = body
        code = getattr(self.server, "put_status_code", 200)
        resp = json.dumps({"uid": "fact-test-uid-sha256"}).encode()
        self.send_response(code); self.end_headers()
        if code == 200: self.wfile.write(resp)
    def log_message(self, *_): pass

def _http_server():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
    srv.put_body = b""; srv.put_status_code = 200
    srv.readiness_code = 200; srv.analysis_never_done = False
    srv.analysis_body_override = None
    t = threading.Thread(target=srv.serve_forever, daemon=True); t.start()
    return srv

Path("/tmp/rsdd").mkdir(exist_ok=True)   # preflight verify_rsdd_root needs this

# ── RED1 (regression): allow=False + spy → exit 3, compose never spawned ─────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp); rec = tmp / "c.json"; p = _shim(tmp)
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                xe={"PATH": p, "DOCKER_SHIM_RECORD": str(rec), "RSDD_DOCKER_EXECUTOR": ""})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        compose_calls = [c for c in calls if c and c[0] == "compose"]
        assert r.returncode == 3 and compose_calls == [], \
            f"rc={r.returncode} compose_calls={compose_calls}"
        ok("RED1: allow=False → exit 3, compose never spawned")
    except Exception as e: nok("RED1", str(e))

# ── RED2/GREEN: allow=True + fake docker + HTTP stub → exit 0 + fact-run.v1 ──
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp); p = _shim(tmp); srv = _http_server()
    port = srv.server_address[1]
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                "--allow-docker", "--rest-base-url", f"http://127.0.0.1:{port}",
                xe={"PATH": p, "RSDD_DOCKER_EXECUTOR": "",
                    "DOCKER_FAKE_PROJECT": "fact-testproj"})
        assert r.returncode == 0, f"rc={r.returncode}\nstderr={r.stderr[:400]}"
        res = json.loads(r.stdout)
        assert res.get("schema_version") == "fact-run.v1", f"schema={res.get('schema_version')}"
        assert res.get("executed") is True
        pn = res.get("project_name", "")
        assert pn.startswith("fact-"), f"project_name={pn!r}"
        digests = res.get("image_digests", {})
        assert "frontend" in digests and "backend" in digests and "db" in digests, \
            f"digests={digests}"
        assert res.get("firmware_uid"), "firmware_uid missing"
        assert srv.put_body != b"", "no PUT body received by stub"
        ok("RED2/GREEN: allow=True + stub → exit 0, fact-run.v1, PUT received")
    except Exception as e: nok("RED2/GREEN", str(e))
    finally: srv.shutdown()

# ── FLAGSHIP-DOWN1: compose up fails → exit 2 AND down appears in shim record ─
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp); rec = tmp/"c.json"; p = _shim(tmp)
    srv = _http_server(); port = srv.server_address[1]
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                "--allow-docker", "--rest-base-url", f"http://127.0.0.1:{port}",
                xe={"PATH": p, "RSDD_DOCKER_EXECUTOR": "",
                    "DOCKER_COMPOSE_UP_EXIT": "1",
                    "DOCKER_SHIM_RECORD": str(rec)})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        # find a 'compose ... down' call
        down_calls = [c for c in calls
                      if c and c[0] == "compose" and "down" in c]
        assert r.returncode == 2, f"rc={r.returncode}"
        assert down_calls, f"no 'compose down' in shim record on up-fail: {calls}"
        ok("FLAGSHIP-DOWN1: compose up exit 1 → exit 2 AND down called")
    except Exception as e: nok("FLAGSHIP-DOWN1", str(e))
    finally: srv.shutdown()

# ── FLAGSHIP-DOWN2: PUT returns 500 → exit 2 AND down appears ────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp); rec = tmp/"c.json"; p = _shim(tmp)
    srv = _http_server(); srv.put_status_code = 500; port = srv.server_address[1]
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                "--allow-docker", "--rest-base-url", f"http://127.0.0.1:{port}",
                xe={"PATH": p, "RSDD_DOCKER_EXECUTOR": "",
                    "DOCKER_SHIM_RECORD": str(rec)})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        down_calls = [c for c in calls if c and c[0] == "compose" and "down" in c]
        assert r.returncode == 2, f"rc={r.returncode}"
        assert down_calls, f"no 'compose down' in shim record on PUT 500: {calls}"
        ok("FLAGSHIP-DOWN2: PUT 500 → exit 2 AND down called")
    except Exception as e: nok("FLAGSHIP-DOWN2", str(e))
    finally: srv.shutdown()

# ── FLAGSHIP-DOWN3: analysis never-done (1-poll wall) → exit 2 AND down ───────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp); rec = tmp/"c.json"; p = _shim(tmp)
    srv = _http_server(); srv.analysis_never_done = True; port = srv.server_address[1]
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                "--allow-docker", "--rest-base-url", f"http://127.0.0.1:{port}",
                "--wall-seconds", "3",
                xe={"PATH": p, "RSDD_DOCKER_EXECUTOR": "",
                    "DOCKER_SHIM_RECORD": str(rec)})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        down_calls = [c for c in calls if c and c[0] == "compose" and "down" in c]
        assert r.returncode == 2, f"rc={r.returncode}\nstderr={r.stderr[:300]}"
        assert down_calls, f"no 'compose down' in shim record on analysis-timeout: {calls}"
        ok("FLAGSHIP-DOWN3: analysis-timeout → exit 2 AND down called")
    except Exception as e: nok("FLAGSHIP-DOWN3", str(e))
    finally: srv.shutdown()

# ── FLAGSHIP-DOWN4: image inspect fails → exit 2 AND compose never started ───
# (preflight fails before up, so no down expected — compose was never spawned)
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp); rec = tmp/"c.json"; p = _shim(tmp)
    srv = _http_server(); port = srv.server_address[1]
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                "--allow-docker", "--rest-base-url", f"http://127.0.0.1:{port}",
                xe={"PATH": p, "RSDD_DOCKER_EXECUTOR": "",
                    "DOCKER_INSPECT_EXIT": "1",
                    "DOCKER_SHIM_RECORD": str(rec)})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        up_calls = [c for c in calls if c and c[0] == "compose" and "up" in c]
        assert r.returncode == 2, f"rc={r.returncode}"
        assert up_calls == [], f"compose up must not be called on preflight failure: {up_calls}"
        ok("FLAGSHIP-DOWN4: image inspect fail → exit 2, compose never started")
    except Exception as e: nok("FLAGSHIP-DOWN4", str(e))
    finally: srv.shutdown()

# ── TOCTOU: firmware tampered after plan-build → GateError → exit 2 ───────────
# Unit test on _read_firmware_toctou directly (plan sha256 ≠ actual bytes).
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    original = b"ORIGINAL-FIRMWARE" + b"\x00" * 32
    tampered = b"TAMPERED-FIRMWARE" + b"\x00" * 32
    fw_path = tmp / "fw.bin"; fw_path.write_bytes(original)
    orig_sha = "sha256:" + hashlib.sha256(original).hexdigest()
    plan = {"firmware": {"path": str(fw_path), "sha256": orig_sha, "size": len(original)}}
    # tamper the file AFTER plan.firmware.sha256 was set
    fw_path.write_bytes(tampered)
    try:
        from gate import GateError
        m._read_firmware_toctou(plan)
        nok("TOCTOU: expected GateError on mismatch")
    except GateError as exc:
        assert "mismatch" in str(exc).lower() or "toctou" in str(exc).lower(), \
            f"unexpected GateError message: {exc}"
        ok("TOCTOU: tampered firmware → GateError (hash mismatch)")
    except Exception as e: nok("TOCTOU", str(e))

# ── TOCTOU-clean: unmodified firmware → bytes returned, sha256 matches ────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    content = b"GOOD-FIRMWARE" + b"\x00" * 16
    fw_path = tmp / "fw.bin"; fw_path.write_bytes(content)
    sha = "sha256:" + hashlib.sha256(content).hexdigest()
    plan = {"firmware": {"path": str(fw_path), "sha256": sha, "size": len(content)}}
    try:
        from gate import GateError
        fw_bytes = m._read_firmware_toctou(plan)
        assert fw_bytes == content, f"returned bytes differ from written bytes"
        assert hashlib.sha256(fw_bytes).hexdigest() == sha[len("sha256:"):], "hash mismatch"
        ok("TOCTOU-clean: unmodified firmware → correct bytes returned")
    except Exception as e: nok("TOCTOU-clean", str(e))

# ── NON-LOOPBACK: --rest-base-url non-loopback → exit 2 (anti-exfiltration) ──
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp); p = _shim(tmp)
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                "--allow-docker", "--rest-base-url", "http://0.0.0.0:9100",
                "--wall-seconds", "3",   # bounds the run if the loopback guard is ever removed (mutant): it fails at the readiness poll, never hangs
                xe={"PATH": p, "RSDD_DOCKER_EXECUTOR": ""})
        # 0.0.0.0 is not loopback (the guard refuses it) yet the kernel routes it to the local host (`ip route get 0.0.0.0` -> dev lo),
        # so even a mutant run that skips the guard sends nothing off-host. The reason text pins the guard itself, not a later failure.
        assert r.returncode == 2, f"rc={r.returncode}"
        assert "is not loopback" in r.stderr, "refusal must come from the loopback guard (reason text missing)"
        ok("NON-LOOPBACK: non-loopback URL → exit 2 (refused)")
    except Exception as e: nok("NON-LOOPBACK", str(e))

# ── NO-DOCKER: docker absent → exit 2 ────────────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp)
    srv = _http_server(); port = srv.server_address[1]
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                "--allow-docker", "--rest-base-url", f"http://127.0.0.1:{port}",
                xe={"PATH": str(tmp), "RSDD_DOCKER_EXECUTOR": ""})
        assert r.returncode == 2, f"rc={r.returncode}"
        ok("NO-DOCKER: docker absent from PATH → exit 2")
    except Exception as e: nok("NO-DOCKER", str(e))
    finally: srv.shutdown()

# ── IMAGE-ABSENT: all 3 image inspects fail → exit 2 ─────────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp); p = _shim(tmp)
    srv = _http_server(); port = srv.server_address[1]
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                "--allow-docker", "--rest-base-url", f"http://127.0.0.1:{port}",
                xe={"PATH": p, "RSDD_DOCKER_EXECUTOR": "", "DOCKER_INSPECT_EXIT": "1"})
        assert r.returncode == 2, f"rc={r.returncode}"
        ok("IMAGE-ABSENT: images absent locally → exit 2")
    except Exception as e: nok("IMAGE-ABSENT", str(e))
    finally: srv.shutdown()

# ── UNIT-forbid_privileged: --privileged in planned_argv → GateError ──────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    sys.path.insert(0, str(sut_path.parent))
    import docker_common as _dc
    from gate import GateError
    bad_argv = ["docker", "compose", "-p", "fact", "--privileged", "up", "-d"]
    try:
        _dc.forbid_privileged(bad_argv)
        nok("UNIT-forbid_privileged: expected GateError")
    except GateError:
        ok("UNIT-forbid_privileged: --privileged in argv → GateError")
    except Exception as e: nok("UNIT-forbid_privileged", str(e))

# ── UNIT-assert_network_policy-forbid: --network present → GateError ──────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    bad_argv = ["docker", "compose", "-p", "fact", "--network", "bridge", "up", "-d"]
    try:
        _dc.assert_network_policy(bad_argv, "forbid")
        nok("UNIT-network-forbid: expected GateError")
    except GateError:
        ok("UNIT-network-forbid: --network in compose argv → GateError (forbid mode)")
    except Exception as e: nok("UNIT-network-forbid", str(e))

# ── UNIT-loopback check: non-loopback URL → GateError directly ───────────────
try:
    m._check_loopback("http://192.168.1.1:9100")
    nok("UNIT-loopback: expected GateError")
except Exception as exc:
    from gate import GateError
    if isinstance(exc, GateError):
        ok("UNIT-loopback: non-loopback host → GateError")
    else: nok("UNIT-loopback", str(exc))

# ── UNIT-make_run_subdir-parameterised: FACT uses custom root ─────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    custom_root = str(tmp)
    try:
        result = _dc.make_run_subdir("testid", root=custom_root)
        expected = f"{custom_root}/rsdd-testid"
        assert result == expected, f"got {result!r}, want {expected!r}"
        assert Path(result).is_dir(), f"subdir not created: {result}"
        ok("UNIT-make_run_subdir-parameterised: custom root → correct subdir created")
    except Exception as e: nok("UNIT-make_run_subdir-parameterised", str(e))

# ── T-A1 (RED→GREEN): _analysis_poll returns >64 KiB body (was false-timeout) ─
# Stub serves a ~200 KiB valid finished body.  OLD code reads only _POLL_CAP_BYTES
# (64 KiB), truncates, json.loads raises, except → continue → timeout GateError.
# NEW code: _read_bounded reads full body up to _ANALYSIS_CAP_BYTES → returns body.
with tempfile.TemporaryDirectory() as td:
    srv = _http_server(); port = srv.server_address[1]
    large_body = json.dumps({
        "uid": "u1",
        "analysis_status": {"is_finished": True},
        "padding": "x" * (200 * 1024),
    }).encode()
    srv.analysis_body_override = large_body
    try:
        from gate import GateError as _GE
        deadline = time.monotonic() + 5.0
        result = m._analysis_poll(f"http://127.0.0.1:{port}", "u1", deadline)
        assert isinstance(result, dict), f"expected dict, got {type(result)}"
        assert result.get("analysis_status", {}).get("is_finished") is True, \
            f"is_finished not True: {result.get('analysis_status')}"
        ok("T-A1: _analysis_poll returns >64 KiB finished body (no false-timeout)")
    except _GE as exc:
        nok("T-A1", f"GateError (false-timeout in RED): {exc}")
    except Exception as e:
        nok("T-A1", str(e))
    finally:
        srv.shutdown()

# ── T-A2 (RED→GREEN): analysis body > _ANALYSIS_CAP_BYTES → labeled GateError ─
# Monkeypatch cap to 1 KiB; stub serves 2 KiB body.  Must raise GateError
# mentioning "cap"/"exceeds"/"oversized" — not a timeout, and not a normal return.
# RED: attribute missing / check absent → body returned normally (no error).
with tempfile.TemporaryDirectory() as td:
    srv = _http_server(); port = srv.server_address[1]
    oversized_body = json.dumps({
        "uid": "u2",
        "analysis_status": {"is_finished": True},
        "padding": "y" * (2 * 1024),
    }).encode()
    srv.analysis_body_override = oversized_body
    old_cap = getattr(m, "_ANALYSIS_CAP_BYTES", None)
    m._ANALYSIS_CAP_BYTES = 1024
    try:
        from gate import GateError as _GE
        deadline = time.monotonic() + 5.0
        m._analysis_poll(f"http://127.0.0.1:{port}", "u2", deadline)
        nok("T-A2", "expected GateError for oversized body but got normal return (RED)")
    except _GE as exc:
        msg = str(exc).lower()
        if not any(w in msg for w in ("cap", "oversized", "exceeds", "too large")):
            nok("T-A2", f"GateError must mention cap/oversized, got: {exc}")
        else:
            ok("T-A2: oversized analysis body → labeled GateError (not timeout)")
    except Exception as e:
        nok("T-A2", str(e))
    finally:
        if old_cap is not None: m._ANALYSIS_CAP_BYTES = old_cap
        elif hasattr(m, "_ANALYSIS_CAP_BYTES"): del m._ANALYSIS_CAP_BYTES
        srv.shutdown()

# ── T-A3 (RED→GREEN): complete 2xx body with invalid JSON → hard GateError ────
# OLD code: json.loads fails → except → continue → loops to deadline → GateError
# "did not complete" (false timeout, NOT mentioning JSON).
# NEW code: raises GateError immediately with a JSON-related message.
with tempfile.TemporaryDirectory() as td:
    srv = _http_server(); port = srv.server_address[1]
    srv.analysis_body_override = b"not-valid-json!!!"
    try:
        from gate import GateError as _GE
        deadline = time.monotonic() + 3.0
        m._analysis_poll(f"http://127.0.0.1:{port}", "u3", deadline)
        nok("T-A3", "expected GateError for invalid JSON body but got normal return")
    except _GE as exc:
        msg = str(exc).lower()
        if "did not complete" in msg:
            nok("T-A3", f"false-timeout (RED confirmed): got timeout, want JSON error: {exc}")
        elif not any(w in msg for w in ("json", "invalid", "parse")):
            nok("T-A3", f"GateError should mention JSON, got: {exc}")
        else:
            ok("T-A3: complete 2xx invalid-JSON body → hard GateError (not timeout)")
    except Exception as e:
        nok("T-A3", str(e))
    finally:
        srv.shutdown()

# ── T-B (RED→GREEN): digest membership — unknown image ID digest → exit 2 + down
# Shim: DOCKER_IMAGE_ID_DIGEST_UNKNOWN=1 → image inspect by sha256 ID returns a
# digest NOT in resolved_digests.  _post_up_verify must fire → exit 2 + down called.
# RED: no ID-based inspect in _post_up_verify → exit 0 (check absent).
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp); rec = tmp/"c.json"; p = _shim(tmp)
    srv = _http_server(); port = srv.server_address[1]
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                "--allow-docker", "--rest-base-url", f"http://127.0.0.1:{port}",
                xe={"PATH": p, "RSDD_DOCKER_EXECUTOR": "",
                    "DOCKER_IMAGE_ID_DIGEST_UNKNOWN": "1",
                    "DOCKER_SHIM_RECORD": str(rec)})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        down_calls = [c for c in calls if c and c[0] == "compose" and "down" in c]
        assert r.returncode == 2, \
            f"rc={r.returncode} (expected 2; digest membership check absent in RED)"
        assert down_calls, f"no 'compose down' in shim record: {calls}"
        ok("T-B: unknown image digest → exit 2 + down called (digest membership check)")
    except Exception as e:
        nok("T-B", str(e))
    finally:
        srv.shutdown()

# ── T-B2 (RED→GREEN): network internal check — Internal:false → exit 2 + down ─
# Shim: DOCKER_NETWORK_INTERNAL=false → network inspect returns Internal:false.
# _post_up_verify must detect non-internal network → exit 2 + down called.
# RED: no network check in _post_up_verify → exit 0 (check absent).
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); fw, _ = _fw(tmp); rec = tmp/"c.json"; p = _shim(tmp)
    srv = _http_server(); port = srv.server_address[1]
    try:
        r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                "--allow-docker", "--rest-base-url", f"http://127.0.0.1:{port}",
                xe={"PATH": p, "RSDD_DOCKER_EXECUTOR": "",
                    "DOCKER_NETWORK_INTERNAL": "false",
                    "DOCKER_SHIM_RECORD": str(rec)})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        down_calls = [c for c in calls if c and c[0] == "compose" and "down" in c]
        assert r.returncode == 2, \
            f"rc={r.returncode} (expected 2; network internal check absent in RED)"
        assert down_calls, f"no 'compose down' in shim record: {calls}"
        ok("T-B2: network Internal:false → exit 2 + down called (network internal check)")
    except Exception as e:
        nok("T-B2", str(e))
    finally:
        srv.shutdown()

# ── Post-up containment (canned `docker inspect` / `compose ps -q` via the shim) ─
# The container's Image is the frontend config ID the shim resolves to a known digest, so only the
# mount / container-count checks can reject these runs. Each must exit 2 AND tear the project down.
def _containment(label, why, extra_env, reason, mounts=None, inspect_json=None):
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td); fw, _ = _fw(tmp); rec = tmp/"c.json"; p = _shim(tmp)
        srv = _http_server(); port = srv.server_address[1]
        env = {"PATH": p, "RSDD_DOCKER_EXECUTOR": "", "DOCKER_SHIM_RECORD": str(rec), **extra_env}
        if mounts is not None:
            env["DOCKER_CONTAINER_INSPECT_JSON"] = json.dumps([{
                "Id": "sha256:" + "a"*64, "Image": "sha256:" + "a"*64,
                "Config": {"Image": "fkiecad/fact_frontend:latest"}, "Mounts": mounts,
                "NetworkSettings": {"Networks": {"bridge": {"IPAddress": "172.20.0.2"}}}}])
        if inspect_json is not None: env["DOCKER_CONTAINER_INSPECT_JSON"] = inspect_json
        try:
            r = cli("plan", "--firmware", str(fw), "--output", str(tmp/"out"),
                    "--allow-docker", "--rest-base-url", f"http://127.0.0.1:{port}", xe=env)
            calls = json.loads(rec.read_text()) if rec.exists() else []
            down_calls = [c for c in calls if c and c[0] == "compose" and "down" in c]
            assert r.returncode == 2, f"rc={r.returncode} (expected 2; {why} absent)"
            assert down_calls, f"no 'compose down' in shim record: {calls}"
            # the rejection must come from THIS check: another check failing later would also exit 2
            assert reason in r.stderr, f"stderr lacks the expected reason {reason!r} ({why} absent)"
            ok(f"{label}: {why} → exit 2 + down called")
        except Exception as e: nok(label, str(e))
        finally: srv.shutdown()

_containment("T-MOUNT-BIND", "unexpected host bind mount rejected",
             {}, "unexpected bind mount", mounts=[{"Type": "bind", "Source": "/etc"}])
_containment("T-MOUNT-VOL", "volume not scoped to the project rejected",
             {}, "not scoped to project", mounts=[{"Type": "volume", "Name": "someone-elses-volume"}])
_containment("T-NO-CIDS", "empty `compose ps -q` (no containers) rejected",
             {"DOCKER_PS_OUTPUT": ""}, "no containers running")
# The shim writes DOCKER_CONTAINER_INSPECT_JSON verbatim, so malformed replies can be fixtured too.
_containment("T-INSPECT-BADJSON", "docker inspect reply that is not JSON rejected",
             {}, "docker inspect returned invalid JSON", inspect_json="this is not json")
_containment("T-INSPECT-EMPTY", "empty docker inspect list rejected",
             {}, "docker inspect empty", inspect_json="[]")
_containment("T-INSPECT-NOIMAGE", "container with no Image field rejected",
             {}, "has no Image field", inspect_json=json.dumps([{"Id": "x", "Mounts": []}]))

# ── TOCTOU-symlink: a symlink at the firmware path must be refused (O_NOFOLLOW) ──
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    content = b"REAL-FIRMWARE" + b"\x00" * 16
    real = tmp / "real.bin"; real.write_bytes(content)
    link = tmp / "link.bin"; link.symlink_to(real)
    plan = {"firmware": {"path": str(link), "sha256": "sha256:" + hashlib.sha256(content).hexdigest(),
                         "size": len(content)}}
    try:
        from gate import GateError
        m._read_firmware_toctou(plan)
        nok("TOCTOU-symlink: expected GateError for symlink firmware")
    except GateError as exc:
        if "cannot open" in str(exc): ok("TOCTOU-symlink: symlink firmware → GateError (O_NOFOLLOW)")
        else: nok("TOCTOU-symlink", f"wrong GateError: {exc}")
    except Exception as e: nok("TOCTOU-symlink", str(e))

# ── TOCTOU-overflow: file larger than the declared size must be refused ───────
# The recorded sha is of the first declared+1 bytes, so ONLY the overflow check can reject
# (without it the truncated read would hash clean and be accepted).
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    content = b"OVERSIZE-FIRMWARE" + b"\x00" * 83
    fw_path = tmp / "fw.bin"; fw_path.write_bytes(content)
    declared = 10
    plan = {"firmware": {"path": str(fw_path),
                         "sha256": "sha256:" + hashlib.sha256(content[:declared + 1]).hexdigest(),
                         "size": declared}}
    try:
        from gate import GateError
        m._read_firmware_toctou(plan)
        nok("TOCTOU-overflow: expected GateError for oversize firmware")
    except GateError as exc:
        if "exceeds declared size" in str(exc): ok("TOCTOU-overflow: oversize firmware → GateError (declared-size overflow)")
        else: nok("TOCTOU-overflow", f"wrong GateError: {exc}")
    except Exception as e: nok("TOCTOU-overflow", str(e))

# ── FACT-NOLEAK (#2090): no run dir THIS suite produced landed under the global /tmp/rsdd ──
# Attribution is by identity (_produced), never by content. Other new rsdd-* entries belong to someone else
# (a concurrent suite): INFO only, never failed on or deleted.
_leaked = sorted(p for p in _produced if p.startswith(str(_GLOBAL_ROOT) + os.sep))
if _leaked:
    nok("FACT-NOLEAK: new entries under /tmp/rsdd", f"{len(_leaked)} e.g. {_leaked[:2]}")
    for _p in _leaked:  # remove ONLY the dirs this suite produced
        shutil.rmtree(_p, ignore_errors=True)
else:
    ok("FACT-NOLEAK: no run dir produced by this suite under /tmp/rsdd")
_other = _global_names() - _global_before - {os.path.basename(p) for p in _leaked}
if _other: print(f"  INFO  {len(_other)} other new rsdd-* entries under /tmp/rsdd (not this suite's; left alone)")

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
if [ "${1:-}" != "--prove-teeth" ]; then python3 -c "$PY_SRC" "$SUT" "$FACT"; exit $?; fi

# ── MUTATION TEETH (--prove-teeth) ─────────────────────────────────────────────
# Plain run first: its case lines are kept, its aggregate is replaced by ONE combined aggregate at the end
# (run-all.sh reads the LAST `== N passed · N failed ==` line).
py_out="$(python3 -c "$PY_SRC" "$SUT" "$FACT")"; py_rc=$?
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
# The teardown lives in ONE `finally`; each mutant skips `compose down` only for the failure the named case provokes
# (matched on the GateError text), so each FLAGSHIP-DOWN case is bitten by its own mutant, not by a shared one.
DN='        _compose_down(exec_argv_base)'
dn() { printf '        if %s not in str(sys.exc_info()[1]): _compose_down(exec_argv_base)' "$1"; }
tt teeth-down-on-up-fail "$DN" "$(dn '"compose up failed"')" "FAIL  FLAGSHIP-DOWN1: no 'compose down' in shim record on up-fail"
tt teeth-down-on-put-fail "$DN" "$(dn '"REST PUT"')" "FAIL  FLAGSHIP-DOWN2: no 'compose down' in shim record on PUT 500"
tt teeth-down-on-timeout "$DN" "$(dn '"did not complete"')" "FAIL  FLAGSHIP-DOWN3: no 'compose down' in shim record on analysis-timeout"
tt teeth-down-on-network "$DN" "$(dn '"not internal:true"')" "FAIL  T-B2: no 'compose down' in shim record"
tt teeth-root-hardcoded '_dc.make_run_subdir(run_uuid_full, rsdd_root)' '_dc.make_run_subdir(run_uuid_full)' 'FAIL  FACT-NOLEAK: new entries under /tmp/rsdd'
# The failure itself must also be detected (exit 2), not just cleaned up.
tt teeth-up-exit-code 'if exit_code != 0:' 'if False:' 'FAIL  FLAGSHIP-DOWN1: rc=0'
tt teeth-put-failure 'raise GateError(f"FACT REST PUT /rest/firmware failed: {exc}") from exc' 'raw, status = b"{\"uid\": \"x\"}", 200' 'FAIL  FLAGSHIP-DOWN2: rc=0'
tt teeth-analysis-finished 'if astatus.get("is_finished") or astatus.get("finished"):' 'if True:' 'FAIL  FLAGSHIP-DOWN3: rc=0'
tt teeth-toctou-sha 'if actual_sha != fw_sha256:' 'if False:' 'FAIL  TOCTOU: expected GateError on mismatch'
tt teeth-digest-membership 'if not img_digests.intersection(resolved_digests):' 'if False:' 'FAIL  T-B: rc=0 \(expected 2; digest membership'
tt teeth-network-internal 'if net_info[0].get("Internal") is not True:' 'if False:' 'FAIL  T-B2: rc=0 \(expected 2; network internal'
tt teeth-analysis-cap-check 'if exceeded:' 'if False:' 'FAIL  T-A2: GateError must mention cap'
tt teeth-bounded-limit 'limit = cap + 1' 'limit = cap' 'FAIL  T-A2: GateError must mention cap'
# A 1 KiB cap makes the client hang up on the stub's 200 KiB body, so the stub's server thread prints a BrokenPipeError Traceback: that is
# stub noise, not a SUT crash. This one tooth therefore uses the strict filter MINUS the Traceback header; BAD_HAS pins the case's own text.
CRASH_NOTB="$(mutant_py_crash_strict | sed 's/^Traceback|//')"
tt teeth-analysis-cap-const '= 64 * 1024 * 1024' '= 1024' 'FAIL  T-A1: GateError \(false-timeout in RED\): FACT analysis response exceeds 1024-byte cap' "$CRASH_NOTB"
tt teeth-mount-bind 'if not (src == fw_path or src.startswith(run_dir_host)):' 'if False:' 'FAIL  T-MOUNT-BIND: rc=0 \(expected 2; unexpected host bind mount'
tt teeth-mount-volume 'if vol_name and not vol_name.startswith(project_name):' 'if False:' 'FAIL  T-MOUNT-VOL: rc=0 \(expected 2; volume not scoped'
tt teeth-no-containers 'if not cids:' 'if False:' 'FAIL  T-NO-CIDS: rc=0 \(expected 2; empty'
tt teeth-toctou-nofollow '| getattr(os, "O_NOFOLLOW", 0)' '' 'FAIL  TOCTOU-symlink: expected GateError for symlink firmware'
tt teeth-toctou-overflow 'if extra:' 'if False:' 'FAIL  TOCTOU-overflow: expected GateError for oversize firmware'
# The guard mutant is bitten by the direct UNIT-loopback case AND by the CLI case: the CLI case uses http://0.0.0.0:9100, which the guard
# refuses (not loopback) but the kernel routes to the local host (`ip route get 0.0.0.0` -> dev lo), so even the mutant run sends nothing
# off-host, and it asserts the guard's own "is not loopback" text, so a later failure (exit 2 at the readiness poll) cannot stand in for it.
tt teeth-loopback-guard 'if host not in _LOOPBACK_HOSTS:' 'if False:' 'FAIL  UNIT-loopback: expected GateError'
tt teeth-loopback-guard-cli 'if host not in _LOOPBACK_HOSTS:' 'if False:' 'FAIL  NON-LOOPBACK: refusal must come from the loopback guard'
tt teeth-inspect-badjson 'info = _json.loads(insp_r.stdout)' 'info = _json.loads(insp_r.stdout) if insp_r.stdout.lstrip().startswith("[") else [{"Image": "sha256:" + "a" * 64, "Mounts": []}]' 'FAIL  T-INSPECT-BADJSON: rc=0 \(expected 2; docker inspect reply that is not JSON'
tt teeth-inspect-empty 'if not info or not isinstance(info, list):' 'if False:' 'FAIL  T-INSPECT-EMPTY: '
tt teeth-inspect-noimage 'if not image_id:' 'if False:' 'FAIL  T-INSPECT-NOIMAGE: stderr lacks the expected reason'
# Not mutated (real reason): the docker-inspect TIMEOUT branches and the empty-RepoDigests check. The shim has no mode that makes a
# subprocess time out or that returns an image with RepoDigests absent while still resolving the pre-up digests, so no fixture can reach
# them yet; they need a new shim mode and are left for a follow-up.

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
