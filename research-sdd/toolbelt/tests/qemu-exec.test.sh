#!/usr/bin/env bash
# qemu-exec.test.sh — TDD RED→GREEN for LiveQemuBootExecutor (V1b).
# RED: exits 2 (SUT absent) before lib/qemu_exec.py + qemu_plan.py wiring.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lib/qemu_exec.py"
PLAN="$HERE/../qemu_plan.py"
# --prove-teeth child run: `--teeth-child <staged lib/qemu_exec.py>` (an argument, never an environment
# variable, so ambient env cannot swap the SUT of a plain run) runs the whole suite against a staged
# mutant tree; its qemu_plan.py CLI is the staged copy next to it.
if [ "${1:-}" = "--teeth-child" ]; then
  [ -f "${2:-}" ] || { echo "FATAL: --teeth-child needs an existing staged SUT file, got [${2:-}]" >&2; exit 2; }
  SUT="$2"; PLAN="$(dirname "$2")/../qemu_plan.py"
  echo "TEETH-CHILD: SUT=$SUT"
fi
[ -f "$SUT" ]  || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$PLAN" ] || { echo "FATAL: qemu_plan.py not found: $PLAN" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
# --prove-teeth: a temp root for the staged mutants and the python section's counts file.
MUT=""; TEETH_COUNTS=""
trap '[ -z "$MUT" ] || rm -rf "$MUT"' EXIT
if [ "${1:-}" = "--prove-teeth" ]; then
  MUT="$(mktemp -d)" || { echo "FATAL: mktemp failed" >&2; exit 2; }
  TEETH_COUNTS="$MUT/py-counts"
fi
RSDD_TEETH_COUNTS="$TEETH_COUNTS" python3 - "$SUT" "$PLAN" <<'PY'
import atexit, hashlib, importlib.util, json, os, shutil, signal, struct, subprocess, sys, tempfile, time, unittest.mock
from pathlib import Path

# #2061: the SUT's host run-dir root is $RSDD_VM_ROOT (default /tmp/rsdd). Point it, and TMPDIR, at a
# suite-private sandbox so no run dir lands in /tmp/rsdd (invisible to run-all's TMPDIR leftovers check).
_SBX = tempfile.mkdtemp(prefix="qe-sbx-")
atexit.register(shutil.rmtree, _SBX, ignore_errors=True)
_SBX_ROOT = os.path.join(_SBX, "rsdd")
os.environ["TMPDIR"] = _SBX; tempfile.tempdir = None
os.environ["RSDD_VM_ROOT"] = _SBX_ROOT
_GLOBAL_ROOT = Path("/tmp/rsdd")
def _global_names() -> set:
    try: return {x.name for x in _GLOBAL_ROOT.glob("rsdd-*")}
    except OSError: return set()
_global_before = _global_names()

sut_path = Path(sys.argv[1]); plan_path = Path(sys.argv[2])
sys.path.insert(0, str(sut_path.parent))
sp = importlib.util.spec_from_file_location("qemu_exec", sut_path)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)

# Run-dir IDENTITY: every run dir this suite produces is recorded (in-process via a recorder around
# make_run_subdir, CLI runs via their serial_log), so the global-root guard fails on and removes
# only dirs this suite made -- never another suite's, whatever files they hold.
_produced = set()
_orig_mrs = m._dc.make_run_subdir
def _rec_mrs(*a, **k):
    r = _orig_mrs(*a, **k); _produced.add(r); return r
m._dc.make_run_subdir = _rec_mrs

passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))
def cli(*a, xe=None):
    e = os.environ.copy()
    if xe: e.update(xe)
    r = subprocess.run([sys.executable, str(plan_path), *map(str, a)],
                       capture_output=True, text=True, env=e)
    try: _produced.add(str(Path(json.loads(r.stdout)["serial_log"]).parent))
    except Exception: pass
    return r

# ELF header: x86_64 little-endian (e_machine=62=0x3e)
_X64 = b'\x7fELF\x02\x01\x01' + b'\x00'*9 + b'\x02\x00\x3e\x00'

# Fake bwrap shim: exec's everything after "--"
_BWRAP = """\
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
try:
    sep = args.index("--"); cmd = args[sep+1:]
    if cmd: os.execvp(cmd[0], cmd)
except (ValueError, IndexError): pass
sys.exit(0)
"""

# Fake qemu-system-x86_64: records argv, handles --version, sleeps, exits.
# QEMU_SPAWN_CHILD=1 + QEMU_CHILD_PID_FILE: fork a long-lived child; test reap.
_QEMU = """\
#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
rec = os.environ.get("QEMU_SHIM_RECORD", "")
if rec:
    try: c = json.loads(open(rec).read())
    except: c = []
    c.append(args); open(rec, "w").write(json.dumps(c))
if args and args[0] == "--version":
    print("QEMU emulator version 8.0.0 (fake)"); sys.exit(0)
cpf = os.environ.get("QEMU_CHILD_PID_FILE", "")
if cpf and os.environ.get("QEMU_SPAWN_CHILD", ""):
    pid = os.fork()
    if pid == 0: time.sleep(300); sys.exit(0)
    open(cpf, "w").write(str(pid))
sys.stdout.write("fake-serial: kernel booted\\n"); sys.stdout.flush()
sl = float(os.environ.get("QEMU_RUN_SLEEP", "0"))
if sl: time.sleep(sl)
sys.exit(int(os.environ.get("QEMU_RUN_EXIT", "0")))
"""

def _shims(tmp: Path) -> str:
    for name, body in [("bwrap", _BWRAP), ("qemu-system-x86_64", _QEMU)]:
        p = tmp / name; p.write_text(body); p.chmod(0o755)
    return str(tmp) + ":" + os.environ.get("PATH", "")

def _elf(tmp: Path) -> Path:
    p = tmp / "t.elf"; p.write_bytes(_X64); return p

# ── RED1: allow=False → exit 3 (auth-required), shim never invoked ───────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp); rec = tmp / "calls.json"
    try:
        r = cli("plan", "--target", str(elf), "--mode", "qemu-system",
                "--output", str(tmp/"out"),
                xe={"PATH": p, "QEMU_SHIM_RECORD": str(rec), "RSDD_EXEC_EXECUTOR": ""})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        assert r.returncode == 3 and calls == [], f"rc={r.returncode} calls={calls}"
        ok("RED1: allow=False → exit 3, shim never spawned")
    except Exception as e: nok("RED1", str(e))

# ── RED2/GREEN: allow=True + qemu-system + shim → exit 0 + vm-boot-run.v1 ────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--mode", "qemu-system",
                "--output", str(tmp/"out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        res = json.loads(r.stdout)
        assert res.get("schema_version") == "vm-boot-run.v1", f"sv={res.get('schema_version')}"
        assert res.get("executed") is True
        for k in ("exec_argv", "argv_deltas", "serial_log", "output_files",
                  "duration_s", "stdout_truncated", "stderr_truncated"):
            assert k in res, f"missing key: {k}"
        ok("RED2/GREEN: allow=True + qemu-system + shim → exit 0, vm-boot-run.v1 receipt")
    except Exception as e: nok("RED2/GREEN", str(e))

# ── RED3: containment flags in exec_argv ──────────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--mode", "qemu-system",
                "--output", str(tmp/"out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:200]}"
        ea = json.loads(r.stdout).get("exec_argv", [])
        assert "-nic" in ea and ea[ea.index("-nic")+1] == "none", f"-nic none missing: {ea}"
        assert "-nodefaults" in ea, f"-nodefaults missing: {ea}"
        assert "-snapshot" in ea, f"-snapshot missing: {ea}"
        assert "-accel" in ea and ea[ea.index("-accel")+1] == "tcg", f"-accel tcg missing: {ea}"
        assert "--unshare-net" in ea, f"--unshare-net missing: {ea}"
        assert "-sandbox" in ea, f"-sandbox missing: {ea}"
        ok("RED3: containment flags (-nic none, -nodefaults, -snapshot, -accel tcg, --unshare-net, -sandbox) in exec_argv")
    except Exception as e: nok("RED3", str(e))

# ── RED4: qemu-user + allow=True → refused (exit 2), no boot ─────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp); rec = tmp / "calls.json"
    try:
        r = cli("plan", "--target", str(elf), "--mode", "qemu-user",
                "--output", str(tmp/"out"), "--allow-exec",
                xe={"PATH": p, "QEMU_SHIM_RECORD": str(rec), "RSDD_EXEC_EXECUTOR": ""})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        assert r.returncode == 2, f"rc={r.returncode}"
        assert calls == [], f"shim was invoked (must not boot qemu-user): {calls}"
        assert "qemu-user live exec refused" in r.stderr, f"refusal reason missing from stderr: {r.stderr[:200]!r}"
        ok("RED4: qemu-user + allow=True → exit 2 (refused), shim never spawned")
    except Exception as e: nok("RED4", str(e))

# ── RED5: bad flags in plan → preflight GateError ────────────────────────────
# FIXED: inject into COMPLETE _good_argv (old [:-1] dropped -snapshot so the
# missing-flag check fired before the forbidden-flag check — vacuous RED).
# Assert GateError message names the injected flag (substring, not exact text).
from gate import GateError
_good_argv = [
    "bwrap", "--unshare-net", "--",
    "qemu-system-x86_64", "-kernel", "/input/target",
    "-m", "256", "-smp", "1", "-accel", "tcg",
    "-nic", "none", "-nodefaults",
    "-sandbox", "on,obsolete=deny",
    "-nographic", "-no-reboot", "-snapshot",
]
# PATH shim injected in-process: _preflight resolves the qemu binary AFTER the forbidden-flag scan, so
# on a host without qemu-system-* (CI) an unshimmed case raises a binary-not-found GateError instead.
with tempfile.TemporaryDirectory() as _r5_td:
    _r5_tmp = Path(_r5_td); _shims(_r5_tmp)
    _r5_saved = os.environ.get("PATH", "")
    os.environ["PATH"] = str(_r5_tmp) + ":" + _r5_saved
    try:
        for label, bad_argv in [
            ("-net user",    _good_argv + ["-net", "user"]),
            ("-netdev",      _good_argv + ["-netdev", "user"]),
            ("-virtfs",      _good_argv + ["-virtfs", "local,path=/tmp"]),
            ("-enable-kvm",  _good_argv + ["-enable-kvm"]),
            ("-device vfio", _good_argv + ["-device", "vfio-pci"]),
        ]:
            plan = {"mode": "qemu-system", "planned_argv": bad_argv,
                    "qemu_binary": "qemu-system-x86_64", "target": {}}
            flag = label.split()[0]  # "-net", "-netdev", "-virtfs", "-enable-kvm", "-device"
            try:
                m._preflight(plan); nok(f"RED5-{label}: expected GateError")
            except GateError as e:
                if flag in str(e): ok(f"RED5-{label}: bad flag → GateError naming {flag!r}")
                else: nok(f"RED5-{label}: GateError but msg omits {flag!r}: {e}")
            except Exception as e: nok(f"RED5-{label}", str(e))
    finally:
        os.environ["PATH"] = _r5_saved

# ── RED-NEW: scanner enforcement — duplicates and new-class flags ──────────────
# These 6 cases MUST reach nok() against current code (first-occurrence-only
# checks miss duplicates; virtio-9p/-smp/-net tap not checked at all).
# After scanner: each must raise GateError whose message names the flag.
# +2 sandbox=allow cases (V1b correction): old startswith("on") predicate accepts
#   on,spawn=allow / on,elevateprivileges=allow — these must also be RED until fixed.
# PATH shim injected in-process so _preflight reaches the scanner, not binary-not-found.
_smp2_argv = list(_good_argv)
_smp2_argv[_smp2_argv.index("-smp") + 1] = "2"

with tempfile.TemporaryDirectory() as _rn_td:
    _rn_tmp = Path(_rn_td); _shims(_rn_tmp)
    _rn_p = str(_rn_tmp) + ":" + os.environ.get("PATH", "")
    _saved_path = os.environ.get("PATH", "")
    os.environ["PATH"] = _rn_p
    try:
        for label, bad_argv, substr in [
            ("dup -nic user",           _good_argv + ["-nic", "user"],                      "-nic"),
            ("dup -accel kvm",          _good_argv + ["-accel", "kvm"],                     "-accel"),
            ("dup -sandbox off",        _good_argv + ["-sandbox", "off"],                   "-sandbox"),
            ("-device virtio-9p",       _good_argv + ["-device", "virtio-9p-pci"],          "-device"),
            ("-smp 2",                  _smp2_argv,                                          "-smp"),
            ("-net tap",                _good_argv + ["-net", "tap"],                        "-net"),
            ("-sandbox spawn=allow",    _good_argv + ["-sandbox", "on,spawn=allow"],         "-sandbox"),
            ("-sandbox elevate=allow",  _good_argv + ["-sandbox", "on,elevateprivileges=allow"], "-sandbox"),
        ]:
            plan = {"mode": "qemu-system", "planned_argv": bad_argv,
                    "qemu_binary": "qemu-system-x86_64", "target": {}}
            try:
                m._preflight(plan)
                nok(f"RED-NEW-{label}: expected GateError, but _preflight passed")
            except GateError as e:
                if substr in str(e): ok(f"RED-NEW-{label}: GateError names {substr!r}")
                else: nok(f"RED-NEW-{label}: GateError but msg omits {substr!r}: {e}")
            except Exception as e:
                nok(f"RED-NEW-{label}", str(e))
    finally:
        os.environ["PATH"] = _saved_path

# ── POSITIVE-CTRL: complete good plan passes _preflight ──────────────────────
with tempfile.TemporaryDirectory() as _pc_td:
    _pc_tmp = Path(_pc_td); _shims(_pc_tmp)
    _pc_p = str(_pc_tmp) + ":" + os.environ.get("PATH", "")
    _saved_path2 = os.environ.get("PATH", "")
    os.environ["PATH"] = _pc_p
    try:
        plan = {"mode": "qemu-system", "planned_argv": _good_argv,
                "qemu_binary": "qemu-system-x86_64", "target": {}}
        try:
            m._preflight(plan)
            ok("POSITIVE-CTRL: complete good plan passes _preflight")
        except GateError as e:
            nok("POSITIVE-CTRL: unexpected GateError", str(e))
        except Exception as e:
            nok("POSITIVE-CTRL", str(e))
    finally:
        os.environ["PATH"] = _saved_path2

# ── POSITIVE-HARDENED: qemu_plan.py:87 hardened -sandbox value passes _preflight ──
# Regression lock: on,obsolete=deny,...=deny must always pass (no =allow substring).
_hardened_sandbox_argv = [
    "bwrap", "--unshare-net", "--",
    "qemu-system-x86_64", "-kernel", "/input/target",
    "-m", "256", "-smp", "1", "-accel", "tcg",
    "-nic", "none", "-nodefaults",
    "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
    "-nographic", "-no-reboot", "-snapshot",
]
with tempfile.TemporaryDirectory() as _ph_td:
    _ph_tmp = Path(_ph_td); _shims(_ph_tmp)
    _ph_p = str(_ph_tmp) + ":" + os.environ.get("PATH", "")
    _saved_path3 = os.environ.get("PATH", "")
    os.environ["PATH"] = _ph_p
    try:
        plan = {"mode": "qemu-system", "planned_argv": _hardened_sandbox_argv,
                "qemu_binary": "qemu-system-x86_64", "target": {}}
        try:
            m._preflight(plan)
            ok("POSITIVE-HARDENED: qemu_plan.py hardened -sandbox value passes _preflight (regression lock)")
        except GateError as e:
            nok("POSITIVE-HARDENED: unexpected GateError for hardened -sandbox", str(e))
        except Exception as e:
            nok("POSITIVE-HARDENED", str(e))
    finally:
        os.environ["PATH"] = _saved_path3

# ── RED6: wall-timeout → outcome=timeout-killed, process reaped ───────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--mode", "qemu-system",
                "--output", str(tmp/"out"), "--allow-exec", "--wall-seconds", "1",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": "", "QEMU_RUN_SLEEP": "15"})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:300]}"
        res = json.loads(r.stdout)
        assert res.get("outcome") == "timeout-killed", f"outcome={res.get('outcome')}"
        ok("RED6: wall-timeout → outcome=timeout-killed")
    except Exception as e: nok("RED6", str(e))

# ── RED7: child-process reap — both parent and child killed on timeout ─────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    cpf = tmp / "child.pid"
    try:
        r = cli("plan", "--target", str(elf), "--mode", "qemu-system",
                "--output", str(tmp/"out"), "--allow-exec", "--wall-seconds", "1",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": "",
                    "QEMU_RUN_SLEEP": "15", "QEMU_SPAWN_CHILD": "1",
                    "QEMU_CHILD_PID_FILE": str(cpf)})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:300]}"
        if cpf.exists():
            child_pid = int(cpf.read_text().strip())
            time.sleep(0.3)  # brief settle
            try:
                os.kill(child_pid, 0)
                nok("RED7", f"child pid={child_pid} still alive after killpg")
                try:  # do not leak the survivor (its own session, so outside any group we hold)
                    _pg = os.getpgid(child_pid)
                    if _pg != os.getpgrp(): os.killpg(_pg, signal.SIGKILL)
                except OSError: pass
            except OSError:
                ok("RED7: child-process reaped via killpg (process-TREE killed)")
        else:
            nok("RED7", "child pid file not created — shim must write it (QEMU_SPAWN_CHILD=1 set)")
    except Exception as e: nok("RED7", str(e))

# ── RED8: receipt identity present UNCONDITIONALLY (deps importable via CLI) ───
# vm_receipt/vm_plan/adapter_core confirmed importable via CLI entry-point path.
# Absence is no longer accepted as pass (old test was vacuous on missing receipt).
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--mode", "qemu-system",
                "--output", str(tmp/"out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:200]}"
        res = json.loads(r.stdout)
        assert "vm_receipt_identity" in res, \
            f"vm_receipt_identity missing (receipt build must succeed): {sorted(res.keys())}"
        assert res["vm_receipt_identity"].startswith("sha256:"), \
            f"vm_receipt_identity malformed: {res['vm_receipt_identity']}"
        ok("RED8: vm_receipt_identity present and sha256-prefixed (unconditional)")
    except Exception as e: nok("RED8", str(e))

# ── RED9: no shell=True in qemu_exec.py or lib/vm_boot_core.py ───────────────
# D0 moved Popen/run calls to vm_boot_core.py; guard the real spawn site too.
try:
    src = sut_path.read_text()
    assert "shell=True" not in src, "shell=True found in qemu_exec.py!"
    vbc_path = sut_path.parent / "vm_boot_core.py"
    vbc_src = vbc_path.read_text()
    assert "shell=True" not in vbc_src, "shell=True found in lib/vm_boot_core.py!"
    ok("RED9: no shell=True in qemu_exec.py or lib/vm_boot_core.py")
except Exception as e: nok("RED9", str(e))

# ── REG-LOCK: snapshot_hook=None → vm_pre/post_snapshot both null in receipt ──
# Approval test written pre-refactor: locks the V1b invariant that LiveQemuBootExecutor
# always emits null snapshots.  Must pass before AND after the D0 extraction.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--mode", "qemu-system",
                "--output", str(tmp/"out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:200]}"
        res = json.loads(r.stdout)
        # Derive run_dir from serial_log path (serial_log = {run_dir}/serial.log).
        serial_log = res.get("serial_log", "")
        assert serial_log, f"serial_log missing from evidence: {sorted(res.keys())}"
        run_dir = str(Path(serial_log).parent)
        receipt_path = f"{run_dir}/vm-run-receipt.v1.json"
        assert Path(receipt_path).exists(), \
            f"vm-run-receipt.v1.json not found at {receipt_path}"
        receipt = json.loads(open(receipt_path).read())
        assert receipt.get("vm_pre_snapshot") is None, \
            f"vm_pre_snapshot must be null, got: {receipt.get('vm_pre_snapshot')}"
        assert receipt.get("vm_post_snapshot") is None, \
            f"vm_post_snapshot must be null, got: {receipt.get('vm_post_snapshot')}"
        ok("REG-LOCK: vm_pre_snapshot=null and vm_post_snapshot=null in receipt (snapshot_hook=None preserved)")
    except Exception as e: nok("REG-LOCK", str(e))

# ── RED-INV5-popen-window: post-Popen/pre-finally exception must reap child ──
# Injects a raise at the FIRST time.monotonic() call, which sits in the
# unguarded window between Popen and the process-reap try/finally in the
# current code (lines 128-130 of vm_boot_core.py).
#
# Pre-fix (current code): the inner try/finally never starts → child leaks
#   (os.kill returns 0 = alive after the exception propagates).
# Post-fix: the window is closed (try starts immediately after Popen; t0 is
#   the FIRST statement inside the guarded region) → finally fires →
#   reap_process_tree kills the child (os.kill raises OSError = dead).
#
# Mutation proof: reverting only the fix (restoring the 3-line window) makes
# this test RED again, because the injection fires outside the try/finally.
import inspect, vm_boot_core as _vbc
# pre-#2061 run_vm has no root kwarg (then the suite must still run to completion to show REDs)
_ROOT_KW = {"root": _SBX_ROOT} if "root" in inspect.signature(_vbc.run_vm).parameters else {}
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    Path(_SBX_ROOT).mkdir(exist_ok=True)
    # Fake qemu: sleeps until killed; produces no output other than running.
    qemu_bin = tmp / "fake-qemu-inv5"
    qemu_bin.write_text(
        "#!/usr/bin/env python3\nimport time\ntime.sleep(300)\n"
    )
    qemu_bin.chmod(0o755)
    plan = {
        "planned_argv": [str(qemu_bin)],
        "qemu_binary": str(qemu_bin),
        "limits": {"wall_seconds": 30},
    }
    # Wrap subprocess.Popen to capture the spawned process object.
    real_popen = subprocess.Popen
    captured_proc = [None]
    def _capturing_popen(*args, **kwargs):
        p = real_popen(*args, **kwargs)
        captured_proc[0] = p
        return p
    # Patch time.monotonic to raise on its FIRST call inside run_vm.
    # Current code: that first call is in the unguarded window (line 129).
    # Fixed code:   that first call is INSIDE the inner try/finally (first line).
    real_mono = time.monotonic
    first_mono = [True]
    def _raising_monotonic():
        if first_mono[0]:
            first_mono[0] = False
            raise RuntimeError("injected-popen-window")
        return real_mono()
    caught_exc = [None]
    with unittest.mock.patch.object(subprocess, "Popen", _capturing_popen), \
         unittest.mock.patch.object(time, "monotonic", _raising_monotonic):
        try:
            _vbc.run_vm(plan, preflight=lambda p: None, **_ROOT_KW)
        except Exception as e:  # a run_vm root regression must fail this case, not crash the suite
            caught_exc[0] = e
    try:
        assert caught_exc[0] is not None and "injected-popen-window" in str(caught_exc[0]), \
            f"expected injected exception to propagate, got: {caught_exc[0]}"
        assert captured_proc[0] is not None, \
            "subprocess.Popen was not called — no child to check"
        child_pid = captured_proc[0].pid
        time.sleep(0.35)  # allow reap_process_tree to complete if fix is in place
        try:
            os.kill(child_pid, 0)
            # Child still alive — the window was not closed (pre-fix / regression).
            nok("RED-INV5-popen-window: child PID still alive after window exception "
                "(INV-5 process-tree violated — post-Popen/pre-finally gap open)")
        except OSError:
            # Child dead — finally fired and reaped the child (post-fix).
            ok("RED-INV5-popen-window: child reaped after window exception "
               "(INV-5 process-tree enforced — window closed)")
    except Exception as e:
        nok("RED-INV5-popen-window", str(e))
    finally:  # never leak the 300 s sleeper when the window is open (regression / mutant)
        _p = captured_proc[0]
        if _p is not None and _p.poll() is None:
            try: os.killpg(_p.pid, signal.SIGKILL)
            except OSError: pass
            try: _p.wait(5)
            except Exception: pass

# ── RSDD-TMP-ROUTE (#2061): run dirs honour TMPDIR, never the hard-coded /tmp/rsdd ──
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--mode", "qemu-system",
                "--output", str(tmp/"out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert "/tmp/rsdd/rsdd-" not in r.stdout and "/tmp/rsdd" not in r.stderr, \
            "RSDD-TMP-NOLEAK: new entries under /tmp/rsdd (run dir or error names the global root)"
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:200]}"
        sl = json.loads(r.stdout)["serial_log"]
        assert sl.startswith(_SBX_ROOT + os.sep), f"run dir outside $RSDD_VM_ROOT sandbox: {sl}"
        ok("RSDD-TMP-ROUTE: run dir created under $RSDD_VM_ROOT (sandbox), not /tmp/rsdd")
    except Exception as e: nok("RSDD-TMP-ROUTE", str(e))

# ── PIN fixtures (#2078): plan once, then swap the target before / during exec ────────
_BWRAP_SWAP = """\
#!/usr/bin/env python3
import hashlib, os, sys
args = sys.argv[1:]
sep = args.index("--"); pre = args[:sep]; cmd = args[sep+1:]
src = pre[pre.index("--ro-bind") + 1]
sw = os.environ.get("SWAP_PATH", "")
if sw:  # simulate an attacker swapping the planned path AFTER exec's check
    tmpf = sw + ".evil"; open(tmpf, "wb").write(b"EVIL-" * 64); os.replace(tmpf, sw)
open(os.environ["BIND_REC"], "w").write(hashlib.sha256(open(src, "rb").read()).hexdigest())
os.execvp(cmd[0], cmd)
"""

def _planned(tmp: Path, p: str, elf: Path) -> dict:
    cli("plan", "--target", str(elf), "--mode", "qemu-system", "--output", str(tmp/"out"),
        xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
    return json.loads((tmp/"out"/"qemu-plan.v1.json").read_text())

def _with_env(updates: dict, fn):
    saved = {k: os.environ.get(k) for k in updates}
    os.environ.update(updates)
    try: return fn()
    finally:
        for k, v in saved.items():
            if v is None: os.environ.pop(k, None)
            else: os.environ[k] = v

# ── PIN-REFUSE (#2078): target swapped between plan and exec → refusal, qemu never spawned ──
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp); rec = tmp / "calls.json"
    try:
        plan = _planned(tmp, p, elf)
        elf.write_bytes(elf.read_bytes()[:-1] + b"\x01")  # same size, different bytes
        try:
            _with_env({"PATH": p, "QEMU_SHIM_RECORD": str(rec)},
                      lambda: m.LiveQemuBootExecutor(tmp/"out").evaluate(plan))
            nok("PIN-REFUSE: swapped target was booted (no GateError)")
        except GateError as e:
            calls = json.loads(rec.read_text()) if rec.exists() else []
            assert "changed since plan" in str(e), f"unexpected message: {e}"
            assert calls == [], f"qemu spawned despite mismatch: {calls}"
            assert not list(Path(_SBX).glob("rsdd-qemu-target-*")), "stage dir leaked after refusal"
            ok("PIN-REFUSE: swap between plan and exec → GateError 'changed since plan', qemu never spawned")
    except Exception as e: nok("PIN-REFUSE", str(e))

# ── PIN-BIND (#2078): a swap AFTER exec's check cannot reach qemu (bind source is the verified copy) ──
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    (tmp/"bwrap").write_text(_BWRAP_SWAP); (tmp/"bwrap").chmod(0o755)
    brec = tmp / "bind.sha"
    try:
        plan = _planned(tmp, p, elf)
        res = _with_env({"PATH": p, "SWAP_PATH": str(elf), "BIND_REC": str(brec)},
                        lambda: m.LiveQemuBootExecutor(tmp/"out").evaluate(plan))
        assert res.get("executed") is True, f"not executed: {res}"
        planned_hex = plan["target"]["sha256"].removeprefix("sha256:")
        got = brec.read_text()
        assert elf.read_bytes().startswith(b"EVIL-"), "fixture: swap did not happen"
        assert got == planned_hex, f"qemu was handed swapped bytes: bind sha {got} != planned {planned_hex}"
        assert not list(Path(_SBX).glob("rsdd-qemu-target-*")), "stage dir leaked after run"
        ok("PIN-BIND: bwrap bind source holds the planned bytes even after the path is swapped")
    except Exception as e: nok("PIN-BIND", str(e))

# ── PIN-MULTI (#2078): a plan binding the target twice, or never, is refused, not half-pinned ──
for _mlabel, _mutate in [
    ("twice", lambda a, t: a[:a.index("--")] + ["--ro-bind", t, "/second"] + a[a.index("--"):]),
    ("never", lambda a, t: (lambda i: a[:i] + a[i + 3:])(next(j for j, x in enumerate(a) if x == "--ro-bind" and a[j + 1] == t))),
]:
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
        try:
            plan = _planned(tmp, p, elf)
            plan["planned_argv"] = _mutate(plan["planned_argv"], plan["target"]["path"])
            try:
                _with_env({"PATH": p}, lambda: m.LiveQemuBootExecutor(tmp/"out").evaluate(plan))
                nok(f"PIN-MULTI-{_mlabel}: plan with the target bound {_mlabel} was accepted")
            except GateError as e:
                assert "exactly one --ro-bind" in str(e), f"unexpected message: {e}"
                ok(f"PIN-MULTI-{_mlabel}: target bound {_mlabel} in planned_argv → GateError 'exactly one --ro-bind'")
        except Exception as e: nok(f"PIN-MULTI-{_mlabel}", str(e))

# ── RSDD-TMP-NOLEAK (#2061): no run dir THIS suite produced landed under the global /tmp/rsdd ──
# Attribution is by identity (_produced), not by file content. Other new rsdd-* entries are someone
# else's (a concurrent suite): reported as INFO, never failed on or deleted.
# Known limitation: a cli() child that creates its run dir and raises after Popen never prints serial_log,
# so that dir is not recorded and surfaces only as INFO; a wrong root is still detected by RSDD-TMP-ROUTE.
_leaked = sorted(p for p in _produced if p.startswith(str(_GLOBAL_ROOT) + os.sep))
if _leaked:
    nok("RSDD-TMP-NOLEAK: new entries under /tmp/rsdd", f"{len(_leaked)} e.g. {_leaked[:2]}")
    for _p in _leaked:  # remove ONLY the dirs this suite produced
        shutil.rmtree(_p, ignore_errors=True)
else:
    ok("RSDD-TMP-NOLEAK: no run dir produced by this suite under /tmp/rsdd")
_other = _global_names() - _global_before - {os.path.basename(p) for p in _leaked}
if _other: print(f"  INFO  {len(_other)} other new rsdd-* entries under /tmp/rsdd (not this suite's; left alone)")

_counts = os.environ.get("RSDD_TEETH_COUNTS", "")
if _counts:
    # --prove-teeth: the bash section adds its mutant results and prints the one final line.
    Path(_counts).write_text(f"{passed} {failed}\n")
    print(f"\n-- python section: {passed} passed · {failed} failed --")
else:
    print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
py_rc=$?
[ "${1:-}" = "--prove-teeth" ] || exit "$py_rc"

# ── Real-SUT mutants (--prove-teeth, kit issue #2053) ─────────────────────────
# Each mutant is a staged copy of the toolbelt (lib/*.py plus the top-level modules; the suite and
# qemu_plan.py put both on sys.path) with ONE sed-mutated file; the WHOLE suite is re-run against it
# with `--teeth-child` and the targeted case must FAIL. The bite pattern is that case's own FAIL
# label, and any crash-class output (ImportError, NameError, ...) disqualifies the mutant.
#
# mutant_vm_core_teeth (tests/lib/mutant.sh) is NOT used: its inv5/alloc scenarios need a pre_boot
# GateError ("scratch sentinel not found in planned_argv"), which LiveQemuBootExecutor never has
# (run_vm(..., pre_boot=None)), and its fixtures (_GOOD_ARGV) are being moved by PR #2046.
# The shared-core mutants below (killpg, reap, receipt identity) are therefore expressed on this
# suite's own qemu cases instead.
py_p=0; py_f=0
if [ -r "$TEETH_COUNTS" ] && read -r py_p py_f <"$TEETH_COUNTS" && [[ "$py_p" =~ ^[0-9]+$ && "$py_f" =~ ^[0-9]+$ ]]; then :; else
  echo "  FAIL  teeth: python section left no counts file [$TEETH_COUNTS]"; py_p=0; py_f=1
fi
echo "-- teeth: mutation controls (qemu-user refusal, -snapshot, forbidden flags, sandbox value, shell=True, killpg, reap, receipt identity, target pinning, RSDD_VM_ROOT) --"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain_or_count mutant_crash_re || exit 2
TOOLBELT="$(dirname "$HERE")"
b_pass=0; b_fail=0; _builds_failed=0
_CRASH="$(mutant_crash_re imp)|SyntaxError|IndentationError|NameError|AttributeError|TypeError|KeyError|UnboundLocalError|is not defined|No module named|cannot import name|has no attribute|object is not (callable|subscriptable|iterable)|positional argument|unexpected keyword argument|invalid syntax|referenced before assignment|unsupported operand"
# One UNMUTATED staged-tree control run (proves the staging; it must reproduce the python section's own
# result), then each mutant is run ONCE and compared against it: rc != 0, the targeted FAIL text present,
# no crash-class output. (mutant_tooth would re-run the original against the live tree for every mutant.)
_stage() { # DIR : copy lib/*.py and the top-level modules into DIR
  mkdir -p "$1/lib" && cp "$TOOLBELT"/lib/*.py "$1/lib/" && cp "$TOOLBELT"/*.py "$1/"
}
if _stage "$MUT/clean"; then
  _co="$(bash "$HERE/qemu-exec.test.sh" --teeth-child "$MUT/clean/lib/qemu_exec.py" 2>&1)"; _crc=$?
  if [ "$_crc" -eq 0 ] && grep -qE "^== ${py_p} passed · 0 failed ==\$" <<<"$_co" && ! grep -qE "$_CRASH" <<<"$_co"; then
    echo "  PASS  teeth-staging-control: unmutated staged tree passes ${py_p}/0"; b_pass=$((b_pass+1))
  else
    echo "  FAIL  teeth-staging-control: rc=$_crc, expected '== ${py_p} passed · 0 failed ==' and no crash output"; b_fail=$((b_fail+1))
  fi
else
  echo "  FAIL  teeth-staging-control: staging the clean mini-tree failed"; b_fail=$((b_fail+1))
fi
# _tooth LABEL BITE_REGEX FILE SED_EXPR... : mutate FILE (relative to the toolbelt) in a fresh staged copy.
# A non-empty _XFILE/_XEXPR additionally mutates a second staged file with that one expression.
_XFILE=""; _XEXPR=""
_tooth() {
  local label="$1" want="$2" file="$3" d out rc; shift 3
  d="$MUT/${label%%:*}"
  _stage "$d" || { echo "  FAIL  $label: staging the mini-tree failed"; return 1; }
  MUTANT_SYNTAX=none mutant_chain_or_count _builds_failed "$label" "$TOOLBELT/$file" "$d/$file" "$@" || return 1
  if [ -n "$_XFILE" ]; then
    MUTANT_SYNTAX=none mutant_chain_or_count _builds_failed "$label (2nd file)" "$TOOLBELT/$_XFILE" "$d/$_XFILE" "$_XEXPR" || return 1
  fi
  out="$(bash "$HERE/qemu-exec.test.sh" --teeth-child "$d/lib/qemu_exec.py" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then echo "  FAIL  $label — THEATER: mutant run passed (rc=0)"; return 1; fi
  if ! grep -qE -- "$want" <<<"$out"; then echo "  FAIL  $label — THEATER: mutant output lacks /$want/"; return 1; fi
  if grep -qE -- "$_CRASH" <<<"$out"; then echo "  FAIL  $label — THEATER: mutant output has crash-class text (a crash is not a bite)"; return 1; fi
  echo "  PASS  $label: case goes RED with the mutant [rc=$rc]"
}
_t() { if _tooth "$@"; then b_pass=$((b_pass+1)); else b_fail=$((b_fail+1)); fi; }
# RED4: the CLI refusal is one of several layers, but only it prints "qemu-user live exec refused"; without it
# the run still exits 2 (executor not implemented / missing containment flags) and RED4 now catches that by reason.
_t "qe-user-cli-refusal: qemu_plan.py qemu-user refusal removed" "FAIL  RED4: refusal reason missing" qemu_plan.py \
  's/if args.allow_exec and args.mode == "qemu-user":/if False:/'
# RED3 is shadowed by _REQUIRED (a plan-side drop alone dies at preflight), so the real regression is a
# CONSISTENT two-file removal of -snapshot.
_XFILE="qemu_plan.py"; _XEXPR='s/"-nographic", "-no-reboot", "-snapshot"\]/"-nographic", "-no-reboot"]/'
_t "qe-snapshot-dropped: -snapshot dropped from _REQUIRED and from the qemu_plan.py argv" "FAIL  RED3: -snapshot missing" lib/qemu_exec.py \
  's/"-nodefaults", "-snapshot", /"-nodefaults", /'
_XFILE=""; _XEXPR=""
_t "qe-net-allowed: -net no longer a forbidden flag" "FAIL  RED5--net user: expected GateError" lib/qemu_exec.py \
  's/"-runas", "-net", "-netdev"})/"-runas", "-netdev"})/'
_t "qe-virtfs-allowed: -virtfs no longer a forbidden flag" "FAIL  RED5--virtfs: expected GateError" lib/qemu_exec.py \
  's/frozenset({"-virtfs", /frozenset({/'
_t "qe-sandbox-allow: -sandbox value may carry =allow" "FAIL  RED-NEW--sandbox spawn=allow: expected GateError" lib/qemu_exec.py \
  's/ and "=allow" not in v//'
_t "qe-shell-true-exec: shell=True appears in qemu_exec.py" "FAIL  RED9: shell=True found in qemu_exec.py" lib/qemu_exec.py \
  '$a# shell=True'
_t "qe-shell-true-popen: the real Popen in vm_boot_core.py gains shell=True" "FAIL  RED9: shell=True found in lib/vm_boot_core.py" lib/vm_boot_core.py \
  's/^            exec_argv, start_new_session=True,$/            exec_argv, shell=True, start_new_session=True,/'
_t "qe-killpg-off: run_vm reaps the child but not its process group" "FAIL  RED7: child pid=[0-9]+ still alive after killpg" lib/vm_boot_core.py \
  's/^        _pc.reap_process_tree(proc, grace_s=_SIGTERM_GRACE_S, use_group=True)$/        _pc.reap_process_tree(proc, grace_s=_SIGTERM_GRACE_S, use_group=False)/'
_t "qe-no-reap: run_vm teardown no longer reaps the process tree" "FAIL  RED-INV5-popen-window: child PID still alive" lib/vm_boot_core.py \
  's/^        _pc.reap_process_tree(proc, grace_s=_SIGTERM_GRACE_S, use_group=True)$/        pass/'
_t "qe-receipt-id: vm_receipt_identity key renamed in the evidence" "FAIL  RED8: vm_receipt_identity missing" lib/vm_boot_core.py \
  's/ev\["vm_receipt_identity"\] = receipt_identity/ev["vm_receipt_id"] = receipt_identity/'
_t "qe-pin-no-verify: exec no longer refuses a target whose identity differs from the plan (#2078)" "FAIL  PIN-REFUSE: swapped target was booted" lib/qemu_exec.py \
  's/^    if not want or h.hexdigest() != want or (tgt.get("size") is not None and size != tgt\["size"\]):$/    if False:/'
_t "qe-pin-bind-original: bwrap --ro-bind source stays the original path, not the verified copy (#2078)" "FAIL  PIN-BIND: qemu was handed swapped bytes" lib/qemu_exec.py \
  's/out_argv = \[dest if (a == path and i > 0/out_argv = [dest if (False and i > 0/' 's/^    if n_sub != 1:$/    if False:/'
_t "qe-root-hardcoded: _rsdd_root ignores RSDD_VM_ROOT and returns /tmp/rsdd (#2061)" "FAIL  RSDD-TMP-ROUTE: RSDD-TMP-NOLEAK: new entries under /tmp/rsdd" lib/qemu_exec.py \
  's/^    return os.environ.get("RSDD_VM_ROOT") or _dc._DEFAULT_RSDD_ROOT$/    return _dc._DEFAULT_RSDD_ROOT/'
_t "qe-core-root-ignored: run_vm drops its root argument and uses the default /tmp/rsdd (#2061)" "FAIL  RSDD-TMP-ROUTE: RSDD-TMP-NOLEAK: new entries under /tmp/rsdd" lib/vm_boot_core.py \
  's/uuid.uuid4().hex, root or _dc._DEFAULT_RSDD_ROOT)/uuid.uuid4().hex)/'
_t "qe-stage-leak: the private target copy dir is no longer removed after the run (#2078)" "FAIL  PIN-(REFUSE|BIND): stage dir leaked" lib/qemu_exec.py \
  's/^            shutil.rmtree(stage, ignore_errors=True)$/            pass/'
_t "qe-pin-multi-bind: the exactly-one --ro-bind substitution guard is removed (#2078)" "FAIL  PIN-MULTI-(twice|never): " lib/qemu_exec.py \
  's/^    if n_sub != 1:$/    if False:/'
# Control: a NameError mutant prints the targeted `FAIL  RED8` label too, so only the crash-message forms in
# _CRASH can refuse it. The tooth machinery must REFUSE it (rc 1, crash-class text), not count it as a bite.
_ctl_out="$(_tooth "qe-ctl-nameerror: receipt_identity misspelled (NameError)" "FAIL  RED8" lib/vm_boot_core.py \
  's/ev\["vm_receipt_identity"\] = receipt_identity/ev["vm_receipt_identity"] = receipt_identityX/' 2>&1)"; _ctl_rc=$?
if [ "$_ctl_rc" -eq 1 ] && grep -qF "crash-class text" <<<"$_ctl_out"; then
  echo "  PASS  qe-ctl-nameerror: a NameError mutant is refused by the tooth machinery (crash message forms)"; b_pass=$((b_pass+1))
else
  echo "  FAIL  qe-ctl-nameerror: NameError mutant was not refused (rc=$_ctl_rc): $(tr '\n' ' ' <<<"$_ctl_out" | head -c 200)"; b_fail=$((b_fail+1))
fi

echo "== $((py_p + b_pass)) passed · $((py_f + b_fail)) failed =="
[ "$py_rc" -eq 0 ] && [ "$b_fail" -eq 0 ] || exit 1
exit 0

