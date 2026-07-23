#!/usr/bin/env bash
# trace-exec.test.sh — Strict-TDD RED-first parity + exec tests for TraceVmExecutor (D3).
# All cases are OFFLINE; the fake qemu shim stubs the binary.
# Real in-guest tracing is the human's gated MANUAL step — NEVER run in CI.
#
# PARITY CONTRACT: every rejection case detonate-exec.test.sh covers MUST also be
# covered here (shared vm_disk_policy checker; trace containment >= detonate).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT_EXEC="$HERE/../lib/trace_exec.py"
SUT_PLAN="$HERE/../trace_plan.py"
[ -f "$SUT_PLAN" ] || { echo "FATAL: trace_plan.py not found: $SUT_PLAN" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

python3 - "$SUT_EXEC" "$SUT_PLAN" <<'PY'
import json, os, signal, subprocess, sys, tempfile, time
from pathlib import Path

sut_exec_path = Path(sys.argv[1])
plan_path     = Path(sys.argv[2])

sys.path.insert(0, str(sut_exec_path.parent))
sys.path.insert(0, str(sut_exec_path.parent.parent))

passed = 0; failed = 0
def ok(n):      global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""):  global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))

def cli(*a, xe=None):
    e = os.environ.copy()
    if xe: e.update(xe)
    return subprocess.run([sys.executable, str(plan_path), *map(str, a)],
                          capture_output=True, text=True, env=e)

# ELF header: x86_64 little-endian (same as detonate tests)
_X64 = b'\x7fELF\x02\x01\x01' + b'\x00'*9 + b'\x02\x00\x3e\x00'

# Fake bwrap: exec everything after "--"
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

# Fake qemu shim for trace (containment-identical to detonate shim):
# - records argv (QEMU_SHIM_RECORD)
# - handles --version
# - supports QEMU_SPAWN_CHILD / QEMU_CHILD_PID_FILE (process-tree reap tests)
# - finds writable-persistent -drive (snapshot=off AND NOT readonly=on) and writes
#   canned post-trace bytes so vm_pre_snapshot != vm_post_snapshot
# - removes scratch on TRACE_REMOVE_SCRATCH_POST (fail-soft test)
_QEMU_TRACE = """\
#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
rec = os.environ.get("QEMU_SHIM_RECORD", "")
if rec:
    try: c = json.loads(open(rec).read())
    except: c = []
    c.append(args); open(rec, "w").write(json.dumps(c))
if args and args[0] == "--version":
    print("QEMU emulator version 8.0.0 (fake-trace)"); sys.exit(0)
cpf = os.environ.get("QEMU_CHILD_PID_FILE", "")
if cpf and os.environ.get("QEMU_SPAWN_CHILD", ""):
    pid = os.fork()
    if pid == 0: time.sleep(300); sys.exit(0)
    open(cpf, "w").write(str(pid))
i = 0
while i < len(args):
    if args[i] == "-drive" and i + 1 < len(args):
        spec = args[i + 1]
        kv = {}
        for part in spec.split(","):
            if "=" in part:
                k, _, v = part.partition("=")
                kv[k.strip()] = v.strip()
        fp = kv.get("file", "")
        ro = kv.get("readonly", "off")
        snap = kv.get("snapshot", "off")
        if fp and ro != "on" and snap == "off":
            try:
                with open(fp, "r+b") as f:
                    f.seek(0); f.write(b"TRACE_RUN_CANNED_DATA_v1\\x00")
            except Exception:
                pass
            if os.environ.get("TRACE_REMOVE_SCRATCH_POST"):
                try: os.unlink(fp)
                except Exception: pass
    i += 1
sys.stdout.write("fake-serial: trace guest booted\\n"); sys.stdout.flush()
sl = float(os.environ.get("QEMU_RUN_SLEEP", "0"))
if sl: time.sleep(sl)
sys.exit(int(os.environ.get("QEMU_RUN_EXIT", "0")))
"""

def _shims(tmp: Path) -> str:
    """Install fake bwrap + qemu-system-x86_64 in tmp; return prepended PATH."""
    for name, body in [("bwrap", _BWRAP), ("qemu-system-x86_64", _QEMU_TRACE)]:
        p = tmp / name; p.write_text(body); p.chmod(0o755)
    return str(tmp) + ":" + os.environ.get("PATH", "")

def _elf(tmp: Path) -> Path:
    p = tmp / "sample.elf"; p.write_bytes(_X64); return p

Path("/tmp/rsdd").mkdir(exist_ok=True)

# Reference argv matching the qemu+disk plan shape emitted by the rebuilt trace_plan.
# Used by PARITY tests that call check_disk_policy directly (no executor needed).
# Includes all bwrap teeth required by issue #61 (--cap-drop ALL,
# --unshare-pid, --tmpfs) and the scratch file bind (INV-2 / issue #60).
# NOTE: _GOOD_ARGV is duplicated verbatim in detonate-exec.test.sh; both copies must stay
# in sync (the bash heredoc harness has no shared-include path for these fixtures).
_SCRATCH_PATH = "/rsdd/rsdd-test/scratch.img"
_GOOD_ARGV = [
    "bwrap",
    "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
    "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
    "--bind", _SCRATCH_PATH, _SCRATCH_PATH,
    "--ro-bind", "/store/rootfs.img", "/input/rootfs",
    "--ro-bind", "/store/sample.bin", "/input/sample",
    "--",
    "qemu-system-x86_64",
    "-m", "256", "-smp", "1", "-accel", "tcg",
    "-nic", "none", "-nodefaults",
    "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
    "-drive", "file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio",
    "-drive", f"file={_SCRATCH_PATH},snapshot=off,format=raw,if=virtio",
    "-drive", "file=/input/rootfs,snapshot=on,format=raw,if=virtio",
]

# ── TRACE-RED1: gate-closed (no --allow-exec) → exit 3, shim NEVER spawned ──────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp); rec = tmp / "calls.json"
    try:
        r = cli("plan", "--target", str(elf), "--tracer", "strace",
                "--output", str(tmp / "out"),
                xe={"PATH": p, "QEMU_SHIM_RECORD": str(rec), "RSDD_EXEC_EXECUTOR": ""})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        assert r.returncode == 3 and calls == [], \
            f"rc={r.returncode} calls={calls}"
        ok("TRACE-RED1: gate-closed → exit 3, shim never spawned")
    except Exception as e: nok("TRACE-RED1", str(e))

# ── PARITY-1: sample not readonly=on → GateError (matches detonate rejection) ───
try:
    import vm_disk_policy as _vdp
    from gate import GateError
    _bad_p1 = list(_GOOD_ARGV)
    idx = _bad_p1.index("file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio")
    _bad_p1[idx] = "file=/input/sample,snapshot=off,format=raw,if=virtio"
    try:
        _vdp.check_disk_policy(_bad_p1, run_dir="/rsdd/rsdd-test")
        nok("PARITY-1: expected GateError for sample not readonly=on")
    except GateError as e:
        if "readonly" in str(e).lower() or "sample" in str(e).lower():
            ok("PARITY-1: sample not readonly=on → GateError (parity with detonate)")
        else:
            nok("PARITY-1", f"GateError but msg omits readonly/sample: {e}")
except Exception as e: nok("PARITY-1", str(e))

# ── PARITY-2: scratch outside run_dir → GateError ────────────────────────────────
try:
    import vm_disk_policy as _vdp2
    from gate import GateError
    _bad_p2 = list(_GOOD_ARGV)
    idx2 = _bad_p2.index(f"file={_SCRATCH_PATH},snapshot=off,format=raw,if=virtio")
    _bad_p2[idx2] = "file=/tmp/outside/scratch.img,snapshot=off,format=raw,if=virtio"
    try:
        _vdp2.check_disk_policy(_bad_p2, run_dir="/rsdd/rsdd-test")
        nok("PARITY-2: expected GateError for scratch outside run_dir")
    except GateError as e:
        if "outside" in str(e).lower() or "run_dir" in str(e).lower() or "scratch" in str(e).lower():
            ok("PARITY-2: scratch outside run_dir → GateError (parity with detonate)")
        else:
            nok("PARITY-2", f"GateError msg omits scope: {e}")
except Exception as e: nok("PARITY-2", str(e))

# ── PARITY-3: -netdev → GateError ────────────────────────────────────────────────
try:
    import vm_disk_policy as _vdp3
    from gate import GateError
    _bad = list(_GOOD_ARGV) + ["-netdev", "user,id=net0"]
    try:
        _vdp3.check_disk_policy(_bad, run_dir="/rsdd/rsdd-test")
        nok("PARITY-3: expected GateError for -netdev")
    except GateError as e:
        if "-netdev" in str(e):
            ok("PARITY-3: -netdev → GateError names flag (parity with detonate)")
        else:
            nok("PARITY-3", f"GateError but msg omits -netdev: {e}")
except Exception as e: nok("PARITY-3", str(e))

# ── PARITY-4: -net → GateError ───────────────────────────────────────────────────
try:
    import vm_disk_policy as _vdp4
    from gate import GateError
    _bad = list(_GOOD_ARGV) + ["-net", "nic"]
    try:
        _vdp4.check_disk_policy(_bad, run_dir="/rsdd/rsdd-test")
        nok("PARITY-4: expected GateError for -net")
    except GateError as e:
        if "-net" in str(e):
            ok("PARITY-4: -net → GateError names flag (parity with detonate)")
        else:
            nok("PARITY-4", f"GateError but msg omits -net: {e}")
except Exception as e: nok("PARITY-4", str(e))

# ── PARITY-5: -enable-kvm → GateError ────────────────────────────────────────────
try:
    import vm_disk_policy as _vdp5
    from gate import GateError
    _bad = list(_GOOD_ARGV) + ["-enable-kvm"]
    try:
        _vdp5.check_disk_policy(_bad, run_dir="/rsdd/rsdd-test")
        nok("PARITY-5: expected GateError for -enable-kvm")
    except GateError as e:
        if "-enable-kvm" in str(e):
            ok("PARITY-5: -enable-kvm → GateError names flag (parity with detonate)")
        else:
            nok("PARITY-5", f"GateError but msg omits -enable-kvm: {e}")
except Exception as e: nok("PARITY-5", str(e))

# ── PARITY-6: -virtfs → GateError ────────────────────────────────────────────────
try:
    import vm_disk_policy as _vdp6
    from gate import GateError
    _bad = list(_GOOD_ARGV) + ["-virtfs", "local,path=/,security_model=none"]
    try:
        _vdp6.check_disk_policy(_bad, run_dir="/rsdd/rsdd-test")
        nok("PARITY-6: expected GateError for -virtfs")
    except GateError as e:
        if "-virtfs" in str(e):
            ok("PARITY-6: -virtfs → GateError names flag (parity with detonate)")
        else:
            nok("PARITY-6", f"GateError but msg omits -virtfs: {e}")
except Exception as e: nok("PARITY-6", str(e))

# ── PARITY-7: format=qcow2 → GateError ───────────────────────────────────────────
try:
    import vm_disk_policy as _vdp7
    from gate import GateError
    _qcow = list(_GOOD_ARGV)
    idx_q = _qcow.index(f"file={_SCRATCH_PATH},snapshot=off,format=raw,if=virtio")
    _qcow[idx_q] = f"file={_SCRATCH_PATH},snapshot=off,format=qcow2,if=virtio"
    try:
        _vdp7.check_disk_policy(_qcow, run_dir="/rsdd/rsdd-test")
        nok("PARITY-7: expected GateError for format=qcow2")
    except GateError as e:
        if "qcow2" in str(e) or "raw" in str(e) or "format" in str(e):
            ok("PARITY-7: format=qcow2 → GateError names format/qcow2 (parity with detonate)")
        else:
            nok("PARITY-7", f"GateError msg omits format: {e}")
except Exception as e: nok("PARITY-7", str(e))

# ── PARITY-8: second writable disk → GateError ───────────────────────────────────
try:
    import vm_disk_policy as _vdp8
    from gate import GateError
    _dbl = list(_GOOD_ARGV) + ["-drive", f"file={_SCRATCH_PATH}2,snapshot=off,format=raw,if=virtio"]
    try:
        _vdp8.check_disk_policy(_dbl, run_dir="/rsdd/rsdd-test")
        nok("PARITY-8: expected GateError for 2 writable disks")
    except GateError as e:
        ok(f"PARITY-8: 2 writable disks → GateError (parity with detonate): {str(e)[:60]}")
except Exception as e: nok("PARITY-8", str(e))

# ── PARITY-9: /dev/ path → GateError ─────────────────────────────────────────────
try:
    import vm_disk_policy as _vdp9
    from gate import GateError
    _dev = list(_GOOD_ARGV)
    idx_dev = _dev.index(f"file={_SCRATCH_PATH},snapshot=off,format=raw,if=virtio")
    _dev[idx_dev] = "file=/dev/sda,snapshot=off,format=raw,if=virtio"
    try:
        _vdp9.check_disk_policy(_dev, run_dir="/rsdd/rsdd-test")
        nok("PARITY-9: expected GateError for host device path /dev/sda")
    except GateError as e:
        if "/dev/" in str(e) or "device" in str(e).lower():
            ok("PARITY-9: /dev/ path → GateError names device (parity with detonate)")
        else:
            nok("PARITY-9", f"GateError msg omits /dev/: {e}")
except Exception as e: nok("PARITY-9", str(e))

# ── PARITY-10: -device vfio* → GateError ─────────────────────────────────────────
try:
    import vm_disk_policy as _vdp10
    from gate import GateError
    _vfio = list(_GOOD_ARGV) + ["-device", "vfio-pci,host=00:00.0"]
    try:
        _vdp10.check_disk_policy(_vfio, run_dir="/rsdd/rsdd-test")
        nok("PARITY-10: expected GateError for -device vfio*")
    except GateError as e:
        ok(f"PARITY-10: -device vfio* → GateError (parity with detonate): {str(e)[:60]}")
except Exception as e: nok("PARITY-10", str(e))

# ── PARITY-11: missing required belt flag (-nodefaults) → GateError ──────────────
try:
    import vm_disk_policy as _vdp11
    from gate import GateError
    _no_def = [t for t in _GOOD_ARGV if t != "-nodefaults"]
    try:
        _vdp11.check_disk_policy(_no_def, run_dir="/rsdd/rsdd-test")
        nok("PARITY-11: expected GateError for missing -nodefaults belt flag")
    except GateError as e:
        if "nodefaults" in str(e) or "missing" in str(e).lower() or "required" in str(e).lower():
            ok("PARITY-11: missing -nodefaults → GateError (parity with detonate)")
        else:
            nok("PARITY-11", f"GateError msg omits nodefaults/missing/required: {e}")
except Exception as e: nok("PARITY-11", str(e))

# ── TRACE-RED4: sentinel substitution recorded in argv_deltas; scratch path real ──
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--tracer", "strace",
                "--output", str(tmp / "out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        res = json.loads(r.stdout)
        exec_argv = res.get("exec_argv", [])
        sentinel = "/rsdd/scratch.img"
        drive_specs = [exec_argv[i + 1] for i, t in enumerate(exec_argv)
                       if t == "-drive" and i + 1 < len(exec_argv)]
        scratch_specs = [s for s in drive_specs
                         if "snapshot=off" in s and "readonly=on" not in s]
        assert scratch_specs, f"no writable-persistent -drive in exec_argv: {exec_argv}"
        assert all(sentinel not in s for s in scratch_specs), \
            f"sentinel still present in scratch drive spec: {scratch_specs}"
        import re as _re
        for s in scratch_specs:
            m2 = _re.search(r"file=([^,]+)", s)
            assert m2, f"no file= in scratch spec: {s}"
            sp = m2.group(1)
            assert sp.startswith("/tmp/rsdd/"), \
                f"scratch path not under /tmp/rsdd: {sp!r}"
        deltas = res.get("argv_deltas", [])
        assert deltas, "argv_deltas empty — substitution not recorded"
        assert any(sentinel in str(d) for d in deltas), \
            f"argv_deltas doesn't mention sentinel {sentinel!r}: {deltas}"
        ok("TRACE-RED4: sentinel substituted in exec_argv, recorded in argv_deltas")
    except Exception as e: nok("TRACE-RED4", str(e))

# ── TRACE-RED5: wall-timeout → outcome=timeout-killed, process-TREE reaped ───────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--tracer", "strace",
                "--output", str(tmp / "out"), "--allow-exec", "--wall-seconds", "1",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": "", "QEMU_RUN_SLEEP": "15"})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:300]}"
        res = json.loads(r.stdout)
        assert res.get("outcome") == "timeout-killed", f"outcome={res.get('outcome')}"
        ok("TRACE-RED5: wall-timeout → outcome=timeout-killed")
    except Exception as e: nok("TRACE-RED5", str(e))

# ── TRACE-RED6: child-process reap on teardown ────────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp); cpf = tmp / "child.pid"
    try:
        r = cli("plan", "--target", str(elf), "--tracer", "strace",
                "--output", str(tmp / "out"), "--allow-exec", "--wall-seconds", "1",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": "",
                    "QEMU_RUN_SLEEP": "15", "QEMU_SPAWN_CHILD": "1",
                    "QEMU_CHILD_PID_FILE": str(cpf)})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:300]}"
        if cpf.exists():
            child_pid = int(cpf.read_text().strip())
            time.sleep(0.3)
            try:
                os.kill(child_pid, 0)
                nok("TRACE-RED6", f"child pid={child_pid} still alive after killpg")
            except OSError:
                ok("TRACE-RED6: child reaped via killpg (process-TREE killed)")
        else:
            nok("TRACE-RED6", "child pid file not created — shim must write it (QEMU_SPAWN_CHILD=1)")
    except Exception as e: nok("TRACE-RED6", str(e))

# ── TRACE-RED7: receipt round-trip: vm_pre_snapshot != vm_post_snapshot ──────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--tracer", "strace",
                "--output", str(tmp / "out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        res = json.loads(r.stdout)
        serial_log = res.get("serial_log", "")
        assert serial_log, "serial_log missing from evidence"
        run_dir = str(Path(serial_log).parent)
        receipt_path = f"{run_dir}/vm-run-receipt.v1.json"
        assert Path(receipt_path).exists(), f"receipt not found at {receipt_path}"
        receipt = json.loads(open(receipt_path).read())
        pre  = receipt.get("vm_pre_snapshot")
        post = receipt.get("vm_post_snapshot")
        assert pre  is not None, "vm_pre_snapshot is null"
        assert post is not None, "vm_post_snapshot is null"
        assert isinstance(pre, dict) and "sha256" in pre,   f"pre not {{sha256}}: {pre}"
        assert isinstance(post, dict) and "sha256" in post, f"post not {{sha256}}: {post}"
        assert pre["sha256"] != post["sha256"], \
            "vm_pre == vm_post (fake shim must write to scratch)"
        assert pre["sha256"].startswith("sha256:"),  f"pre malformed: {pre}"
        assert post["sha256"].startswith("sha256:"), f"post malformed: {post}"
        assert res.get("vm_receipt_identity", "").startswith("sha256:"), \
            "vm_receipt_identity missing or malformed"
        output_names = [o["path"] for o in receipt.get("outputs", [])]
        assert "scratch.img" in output_names, \
            f"scratch.img not in receipt.outputs[]: {output_names}"
        # Detect SCHEMA_VERSION argument swap between trace_exec and detonate_exec.
        assert res.get("schema_version") == "trace-run.v1", \
            f"schema_version={res.get('schema_version')!r} (expected 'trace-run.v1')"
        ok("TRACE-RED7: vm_pre != vm_post, both {sha256}, receipt validates, scratch in outputs[], schema_version=trace-run.v1")
    except Exception as e: nok("TRACE-RED7", str(e))

# ── TRACE-RED8: no shell=True in trace_exec.py ───────────────────────────────────
try:
    if sut_exec_path.exists():
        src = sut_exec_path.read_text()
        assert "shell=True" not in src, "shell=True found in trace_exec.py!"
        ok("TRACE-RED8: no shell=True in trace_exec.py")
    else:
        nok("TRACE-RED8", f"trace_exec.py not found at {sut_exec_path} (GREEN after Task A)")
except Exception as e: nok("TRACE-RED8", str(e))

# ── TRACE-RED10: scratch.img in receipt.outputs[] AND sha256 coherent ────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--tracer", "strace",
                "--output", str(tmp / "out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        res = json.loads(r.stdout)
        serial_log = res.get("serial_log", "")
        assert serial_log, "serial_log missing"
        run_dir_r = Path(serial_log).parent
        receipt_path = run_dir_r / "vm-run-receipt.v1.json"
        assert receipt_path.exists(), f"receipt not found at {receipt_path}"
        receipt = json.loads(receipt_path.read_text())
        outputs = receipt.get("outputs", [])
        output_names = [o["path"] for o in outputs]
        assert "scratch.img" in output_names, \
            f"scratch.img not in outputs[]: {output_names}"
        post_snap = receipt.get("vm_post_snapshot")
        assert post_snap and "sha256" in post_snap, f"vm_post_snapshot missing: {post_snap}"
        scratch_entry = next((o for o in outputs if o["path"] == "scratch.img"), None)
        assert scratch_entry, "scratch.img entry not found in outputs[]"
        assert post_snap["sha256"] == scratch_entry["sha256"], (
            f"vm_post_snapshot.sha256 != outputs[scratch.img].sha256: "
            f"{post_snap['sha256']!r} != {scratch_entry['sha256']!r}"
        )
        ok("TRACE-RED10: scratch.img in outputs[] AND vm_post_snapshot.sha256 coherent")
    except Exception as e: nok("TRACE-RED10", str(e))

# ── TRACE-RED11: exactly ONE /tmp/rsdd/rsdd-* dir per evaluate() ─────────────────
import glob as _glob
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        before = set(_glob.glob("/tmp/rsdd/rsdd-*"))
        r = cli("plan", "--target", str(elf), "--tracer", "strace",
                "--output", str(tmp / "out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        after = set(_glob.glob("/tmp/rsdd/rsdd-*"))
        new_dirs = after - before
        assert len(new_dirs) == 1, (
            f"expected exactly 1 new run_dir per evaluate(), got {len(new_dirs)}: "
            f"{sorted(new_dirs)}"
        )
        ok("TRACE-RED11: exactly 1 run_dir per evaluate() (single-run_dir seam)")
    except Exception as e: nok("TRACE-RED11", str(e))

# ── TRACE-RED12: post-snapshot failure → fail-soft (evidence preserved, post=null) ─
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--tracer", "strace",
                "--output", str(tmp / "out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": "",
                    "TRACE_REMOVE_SCRATCH_POST": "1"})
        assert r.returncode == 0, (
            f"run must succeed even on post-snapshot failure (fail-soft), "
            f"got rc={r.returncode}: {r.stderr[:300]}"
        )
        res = json.loads(r.stdout)
        assert res.get("outcome") in ("success", "boot-failure", "timeout-killed"), \
            f"outcome missing or unexpected: {res.get('outcome')}"
        serial_log = res.get("serial_log", "")
        assert serial_log and Path(serial_log).exists(), \
            f"serial_log missing or gone: {serial_log!r}"
        run_dir_r = Path(serial_log).parent
        receipt_path = run_dir_r / "vm-run-receipt.v1.json"
        assert receipt_path.exists(), f"receipt not found at {receipt_path}"
        receipt = json.loads(receipt_path.read_text())
        pre_snap = receipt.get("vm_pre_snapshot")
        assert pre_snap and "sha256" in pre_snap, \
            f"vm_pre_snapshot should be present (hashed before scratch removed): {pre_snap}"
        post_snap = receipt.get("vm_post_snapshot")
        assert post_snap is None, \
            f"vm_post_snapshot should be null (fail-soft), got: {post_snap}"
        ok("TRACE-RED12: post-snapshot failure → fail-soft (evidence preserved, post=null)")
    except Exception as e: nok("TRACE-RED12", str(e))

# ── TRACE-RED13: TraceVmExecutor.evaluate() wires check_disk_policy (integration path) ──
# Routes a bad plan (real scratch path + -netdev user) through evaluate() directly.
# RED proof: if vm_exec_common._preflight's check_disk_policy call were removed,
# pre_boot would raise "sentinel not found" (different msg); the
# "-netdev"/"forbidden" assertion below would FAIL → RED confirmed, _preflight is load-bearing.
# The 11 PARITY tests call check_disk_policy directly and would NOT catch this gap.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp); rec = tmp / "calls.json"
    try:
        import trace_exec as _te
        from gate import GateError
        # Use a real scratch path (not the sentinel) so that if line 94 were removed,
        # pre_boot would raise "sentinel not found" instead of a disk-policy error.
        # Include all bwrap teeth (issue #61) so -netdev is the only violation.
        _bad13_argv = [
            "bwrap",
            "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
            "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
            "--bind", _SCRATCH_PATH, _SCRATCH_PATH,
            "--ro-bind", "/store/rootfs.img", "/input/rootfs",
            "--ro-bind", "/store/sample.bin", "/input/sample",
            "--",
            "qemu-system-x86_64",
            "-m", "256", "-smp", "1", "-accel", "tcg",
            "-nic", "none", "-nodefaults",
            "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
            "-drive", "file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio",
            "-drive", f"file={_SCRATCH_PATH},snapshot=off,format=raw,if=virtio",
            "-drive", "file=/input/rootfs,snapshot=on,format=raw,if=virtio",
            "-netdev", "user,id=net0",  # forbidden: caught by check_disk_policy
        ]
        _bad13_plan = {"qemu_binary": "qemu-system-x86_64", "planned_argv": _bad13_argv}
        _old_path = os.environ.get("PATH", "")
        _old_rec  = os.environ.get("QEMU_SHIM_RECORD")
        os.environ["PATH"]             = p
        os.environ["QEMU_SHIM_RECORD"] = str(rec)
        try:
            _exe13  = _te.TraceVmExecutor(tmp / "out")
            _raised = None
            try:
                _exe13.evaluate(_bad13_plan)
            except Exception as _exc13:
                _raised = _exc13
        finally:
            os.environ["PATH"] = _old_path
            if _old_rec is None: os.environ.pop("QEMU_SHIM_RECORD", None)
            else:                os.environ["QEMU_SHIM_RECORD"] = _old_rec
        _calls13 = json.loads(rec.read_text()) if rec.exists() else []
        assert _calls13 == [], \
            f"shim was spawned — check_disk_policy wiring broken: {_calls13}"
        assert isinstance(_raised, GateError), \
            f"expected GateError from evaluate(), got {type(_raised).__name__}: {_raised}"
        assert "-netdev" in str(_raised) or "forbidden" in str(_raised).lower(), \
            f"GateError must cite -netdev/forbidden (not sentinel/other): {_raised}"
        ok("TRACE-RED13: evaluate() wires check_disk_policy — bad plan rejects before boot")
    except Exception as e: nok("TRACE-RED13", str(e))

# ── RED-F5A: exec_argv contains scratch file bind AFTER --tmpfs (INV-2 / F5) ──
# Mirror of detonate-exec.test.sh::RED-F5A. After evaluate(), the substituted
# exec_argv must have --bind <P> <P> where P is the real scratch path, AFTER --tmpfs.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--target", str(elf), "--tracer", "strace",
                "--output", str(tmp / "out"), "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        res = json.loads(r.stdout)
        exec_argv = res.get("exec_argv", [])
        drive_specs = [exec_argv[i+1] for i, t in enumerate(exec_argv)
                       if t == "-drive" and i+1 < len(exec_argv)]
        scratch_specs = [s for s in drive_specs
                         if "snapshot=off" in s and "readonly=on" not in s]
        assert scratch_specs, f"no writable-persistent -drive in exec_argv: {exec_argv}"
        import re as _re2
        m3 = _re2.search(r"file=([^,]+)", scratch_specs[0])
        assert m3, f"no file= in scratch spec: {scratch_specs[0]}"
        scratch_path = m3.group(1)
        bind_idx = None
        for i in range(len(exec_argv) - 2):
            if exec_argv[i] == "--bind" and exec_argv[i+1] == scratch_path and exec_argv[i+2] == scratch_path:
                bind_idx = i
                break
        assert bind_idx is not None, (
            f"exec_argv missing ['--bind', {scratch_path!r}, {scratch_path!r}]; "
            f"exec_argv={exec_argv}"
        )
        tmpfs_idx = exec_argv.index("--tmpfs") if "--tmpfs" in exec_argv else None
        assert tmpfs_idx is not None, "--tmpfs missing from exec_argv"
        assert bind_idx > tmpfs_idx, (
            f"--bind at {bind_idx} must be AFTER --tmpfs at {tmpfs_idx}"
        )
        ok("RED-F5A: exec_argv has scratch --bind <P> <P> strictly after --tmpfs (INV-2 / F5)")
    except Exception as e: nok("RED-F5A: scratch-bind-in-exec-argv", str(e))

# ── TRACE-RED-F2: plan_label names "trace" in sentinel-missing GateError ──────────
# Swapping plan_label args in detonate_exec.py/trace_exec.py would flip the label here.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp)
    try:
        import trace_exec as _te_f2; from gate import GateError
        # _GOOD_ARGV has no sentinel (/rsdd/rsdd-test/scratch.img ≠ /rsdd/scratch.img);
        # _preflight passes, pre_boot finds no sentinel → GateError naming executor.
        _f2t_plan = {"qemu_binary": "qemu-system-x86_64", "planned_argv": list(_GOOD_ARGV)}
        _old = os.environ.get("PATH", ""); os.environ["PATH"] = p
        try:
            _raised_f2t = None
            try: _te_f2.TraceVmExecutor(tmp / "out").evaluate(_f2t_plan)
            except Exception as _e: _raised_f2t = _e
        finally: os.environ["PATH"] = _old
        assert isinstance(_raised_f2t, GateError), f"expected GateError: {_raised_f2t!r}"
        assert "trace plan" in str(_raised_f2t), f"GateError must name 'trace plan': {_raised_f2t}"
        ok("TRACE-RED-F2: sentinel-free plan → GateError names 'trace plan' (plan_label wired)")
    except Exception as e: nok("TRACE-RED-F2: plan_label-trace", str(e))

# ── TRACE-RED-INV3-adversarial ────────────────────────────────────────────────
# Mirror of the detonate-side adversarial property on the trace executor path.
# Proves INV-3 is enforced on shared code regardless of which executor calls it.
try:
    import vm_exec_common as _vecTINV3
    _t_sent = "/rsdd/scratch.img"
    _t_real = "/tmp/rsdd/rsdd-T/scratch.img"
    _adv_t = ["-drive", f"file={_t_sent}.bak,snapshot=off,format=raw,if=virtio"]
    _newT, _deltasT = _vecTINV3._substitute_scratch_sentinel(_adv_t, _t_real)
    assert _newT[1] == _adv_t[1], \
        f"trace: drive prefix spec incorrectly rewritten to {_newT[1]!r}"
    assert _deltasT == [], f"unexpected delta on trace path: {_deltasT}"
    ok("TRACE-RED-INV3-adversarial: file= prefix untouched on trace path (INV-3)")
except Exception as e: nok("TRACE-RED-INV3-adversarial", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
