#!/usr/bin/env bash
# qemu-exec.test.sh — TDD RED→GREEN for LiveQemuBootExecutor (V1b).
# RED: exits 2 (SUT absent) before lib/qemu_exec.py + qemu_plan.py wiring.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lib/qemu_exec.py"
PLAN="$HERE/../qemu_plan.py"
[ -f "$SUT" ]  || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$PLAN" ] || { echo "FATAL: qemu_plan.py not found: $PLAN" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" "$PLAN" <<'PY'
import importlib.util, json, os, signal, struct, subprocess, sys, tempfile, time
from pathlib import Path

sut_path = Path(sys.argv[1]); plan_path = Path(sys.argv[2])
sys.path.insert(0, str(sut_path.parent))
sp = importlib.util.spec_from_file_location("qemu_exec", sut_path)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)

passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))
def cli(*a, xe=None):
    e = os.environ.copy()
    if xe: e.update(xe)
    return subprocess.run([sys.executable, str(plan_path), *map(str, a)],
                          capture_output=True, text=True, env=e)

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

Path("/tmp/rsdd").mkdir(exist_ok=True)

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

# ── RED9: no shell=True in qemu_exec.py ───────────────────────────────────────
try:
    src = sut_path.read_text()
    assert "shell=True" not in src, "shell=True found in qemu_exec.py!"
    ok("RED9: no shell=True in qemu_exec.py")
except Exception as e: nok("RED9", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
