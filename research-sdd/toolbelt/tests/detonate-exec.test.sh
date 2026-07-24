#!/usr/bin/env bash
# detonate-exec.test.sh — Strict-TDD RED-first tests for DetonateVmExecutor (D2).
# All cases are OFFLINE; the fake qemu shim stubs the binary.
# Real in-guest detonation is the human's gated MANUAL step — NEVER run in CI.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT_EXEC="$HERE/../lib/detonate_exec.py"
SUT_PLAN="$HERE/../detonate_plan.py"
[ -f "$SUT_PLAN" ] || { echo "FATAL: detonate_plan.py not found: $SUT_PLAN" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

python3 - "$SUT_EXEC" "$SUT_PLAN" <<'PY'
import importlib.util, json, os, signal, subprocess, sys, tempfile, time
from pathlib import Path

sut_exec_path = Path(sys.argv[1])
plan_path     = Path(sys.argv[2])

# Load detonate_exec (may fail until GREEN; each test guards with try/except)
sys.path.insert(0, str(sut_exec_path.parent))
sys.path.insert(0, str(sut_exec_path.parent.parent))

passed = 0; failed = 0
def ok(n):  global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))

def cli(*a, xe=None):
    e = os.environ.copy()
    if xe: e.update(xe)
    return subprocess.run([sys.executable, str(plan_path), *map(str, a)],
                          capture_output=True, text=True, env=e)

# ELF header: x86_64 little-endian
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

# Extended fake qemu shim for detonate:
# - records argv (QEMU_SHIM_RECORD)
# - handles --version
# - supports QEMU_SPAWN_CHILD / QEMU_CHILD_PID_FILE (child-process reap tests)
# - finds writable-persistent -drive (snapshot=off AND NOT readonly=on) and writes
#   canned post-detonation bytes so vm_pre_snapshot != vm_post_snapshot
_QEMU_DETONATE = """\
#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
rec = os.environ.get("QEMU_SHIM_RECORD", "")
if rec:
    try: c = json.loads(open(rec).read())
    except: c = []
    c.append(args); open(rec, "w").write(json.dumps(c))
if args and args[0] == "--version":
    print("QEMU emulator version 8.0.0 (fake-detonate)"); sys.exit(0)
cpf = os.environ.get("QEMU_CHILD_PID_FILE", "")
if cpf and os.environ.get("QEMU_SPAWN_CHILD", ""):
    pid = os.fork()
    if pid == 0: time.sleep(300); sys.exit(0)
    open(cpf, "w").write(str(pid))
# Write canned bytes to each writable-persistent drive (snapshot=off, not readonly).
# This makes vm_pre_snapshot != vm_post_snapshot.
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
                    f.seek(0); f.write(b"DETONATE_RUN_CANNED_DATA_v1\\x00")
            except Exception:
                pass
            if os.environ.get("DETONATE_REMOVE_SCRATCH_POST"):
                try: os.unlink(fp)
                except Exception: pass
    i += 1
sys.stdout.write("fake-serial: detonate guest booted\\n"); sys.stdout.flush()
sl = float(os.environ.get("QEMU_RUN_SLEEP", "0"))
if sl: time.sleep(sl)
sys.exit(int(os.environ.get("QEMU_RUN_EXIT", "0")))
"""

def _shims(tmp: Path) -> str:
    for name, body in [("bwrap", _BWRAP), ("qemu-system-x86_64", _QEMU_DETONATE)]:
        p = tmp / name; p.write_text(body); p.chmod(0o755)
    return str(tmp) + ":" + os.environ.get("PATH", "")

def _elf(tmp: Path) -> Path:
    p = tmp / "sample.elf"; p.write_bytes(_X64); return p

Path("/tmp/rsdd").mkdir(exist_ok=True)

# ── RED1: gate-closed (no --allow-exec) → exit 3, shim NEVER spawned ────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp); rec = tmp / "calls.json"
    try:
        r = cli("plan", "--sample", str(elf), "--output", str(tmp/"out"),
                xe={"PATH": p, "QEMU_SHIM_RECORD": str(rec), "RSDD_EXEC_EXECUTOR": ""})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        assert r.returncode == 3 and calls == [], \
            f"rc={r.returncode} calls={calls}"
        ok("RED1: gate-closed → exit 3, shim never spawned")
    except Exception as e: nok("RED1", str(e))

# ── RED2: sample -drive missing readonly=on → GateError (exit 2), no boot ────
# Tests check_disk_policy via vm_exec_common._preflight at the unit level.
try:
    import vm_disk_policy as _vdp
    from gate import GateError

    # GOOD_ARGV matches detonate_plan.build_plan output shape.
    # Includes all bwrap teeth required by issue #61 (--cap-drop ALL,
    # --unshare-pid, --tmpfs) and the scratch file bind (INV-2 / issue #60).
    # NOTE: _GOOD_ARGV is duplicated verbatim in trace-exec.test.sh; both copies must stay
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

    # swap readonly=on → writable on the sample drive
    _bad2 = list(_GOOD_ARGV)
    idx = _bad2.index("file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio")
    _bad2[idx] = "file=/input/sample,snapshot=off,format=raw,if=virtio"
    try:
        _vdp.check_disk_policy(_bad2, run_dir="/rsdd/rsdd-test")
        nok("RED2: expected GateError for sample not readonly=on")
    except GateError as e:
        if "readonly" in str(e).lower() or "sample" in str(e).lower():
            ok("RED2: sample not readonly=on → GateError (names readonly/sample)")
        else:
            nok("RED2", f"GateError but msg doesn't mention readonly/sample: {e}")
except Exception as e: nok("RED2", str(e))

# ── RED3: scratch outside run_dir → GateError ────────────────────────────────
try:
    from gate import GateError
    import vm_disk_policy as _vdp2
    _bad3 = list(_GOOD_ARGV)
    # Replace scratch path with one outside run_dir
    idx3 = _bad3.index(f"file={_SCRATCH_PATH},snapshot=off,format=raw,if=virtio")
    _bad3[idx3] = "file=/tmp/outside/scratch.img,snapshot=off,format=raw,if=virtio"
    try:
        _vdp2.check_disk_policy(_bad3, run_dir="/rsdd/rsdd-test")
        nok("RED3: expected GateError for scratch outside run_dir")
    except GateError as e:
        if "outside" in str(e).lower() or "run_dir" in str(e).lower() or "scratch" in str(e).lower():
            ok("RED3: scratch outside run_dir → GateError")
        else:
            nok("RED3", f"GateError but msg doesn't mention scope: {e}")
except Exception as e: nok("RED3", str(e))

# ── RED3b: forbidden flags → GateError (each must name the forbidden flag) ───
try:
    from gate import GateError
    import vm_disk_policy as _vdp3
    for label, bad_flag in [
        ("-netdev",    ["-netdev", "user"]),
        ("-enable-kvm",["-enable-kvm"]),
    ]:
        _bad3b = list(_GOOD_ARGV) + bad_flag
        try:
            _vdp3.check_disk_policy(_bad3b, run_dir="/rsdd/rsdd-test")
            nok(f"RED3b-{label}: expected GateError")
        except GateError as e:
            flag = bad_flag[0]
            if flag in str(e):
                ok(f"RED3b-{label}: forbidden flag {flag!r} → GateError names flag")
            else:
                nok(f"RED3b-{label}", f"GateError but msg omits {flag!r}: {e}")
    # format=qcow2
    _qcow_argv = list(_GOOD_ARGV)
    idx_q = _qcow_argv.index(f"file={_SCRATCH_PATH},snapshot=off,format=raw,if=virtio")
    _qcow_argv[idx_q] = f"file={_SCRATCH_PATH},snapshot=off,format=qcow2,if=virtio"
    try:
        _vdp3.check_disk_policy(_qcow_argv, run_dir="/rsdd/rsdd-test")
        nok("RED3b-qcow2: expected GateError")
    except GateError as e:
        if "qcow2" in str(e) or "raw" in str(e) or "format" in str(e):
            ok("RED3b-qcow2: format=qcow2 → GateError names format/qcow2/raw")
        else:
            nok("RED3b-qcow2", f"GateError but msg omits format: {e}")
    # second writable disk
    _dbl = list(_GOOD_ARGV) + ["-drive", f"file={_SCRATCH_PATH}2,snapshot=off,format=raw,if=virtio"]
    try:
        _vdp3.check_disk_policy(_dbl, run_dir="/rsdd/rsdd-test")
        nok("RED3b-double-scratch: expected GateError for 2 writable disks")
    except GateError as e:
        ok(f"RED3b-double-scratch: 2 writable disks → GateError: {str(e)[:60]}")
except Exception as e: nok("RED3b", str(e))

# ── RED4: sentinel substitution recorded in argv_deltas; scratch path real ────
# Requires D2 wiring (DetonateVmExecutor) + live executor. RED until GREEN.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--sample", str(elf), "--output", str(tmp/"out"),
                "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        res = json.loads(r.stdout)
        exec_argv = res.get("exec_argv", [])
        # scratch drive must NOT contain the sentinel literal
        sentinel = "/rsdd/scratch.img"
        drive_specs = [exec_argv[i+1] for i, t in enumerate(exec_argv)
                       if t == "-drive" and i+1 < len(exec_argv)]
        scratch_specs = [s for s in drive_specs
                         if "snapshot=off" in s and "readonly=on" not in s]
        assert scratch_specs, f"no writable-persistent -drive found in exec_argv: {exec_argv}"
        assert all(sentinel not in s for s in scratch_specs), \
            f"sentinel still present in scratch drive spec: {scratch_specs}"
        # scratch path must be a real absolute path
        import re as _re
        for s in scratch_specs:
            m = _re.search(r"file=([^,]+)", s)
            assert m, f"no file= in scratch spec: {s}"
            sp = m.group(1)
            assert sp.startswith("/tmp/rsdd/") or sp.startswith("/tmp/rsdd"), \
                f"scratch path not under /tmp/rsdd: {sp!r}"
        # argv_deltas must mention the substitution
        deltas = res.get("argv_deltas", [])
        assert deltas, f"argv_deltas empty — substitution not recorded"
        assert any(sentinel in str(d) for d in deltas), \
            f"argv_deltas doesn't mention sentinel {sentinel!r}: {deltas}"
        ok("RED4: sentinel substituted in exec_argv, recorded in argv_deltas")
    except Exception as e: nok("RED4", str(e))

# ── RED5: wall-timeout → outcome=timeout-killed, process-TREE reaped ─────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--sample", str(elf), "--output", str(tmp/"out"),
                "--allow-exec", "--wall-seconds", "1",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": "", "QEMU_RUN_SLEEP": "15"})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:300]}"
        res = json.loads(r.stdout)
        assert res.get("outcome") == "timeout-killed", f"outcome={res.get('outcome')}"
        ok("RED5: wall-timeout → outcome=timeout-killed")
    except Exception as e: nok("RED5", str(e))

# ── RED6: child-process reap on BaseException teardown ───────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp); cpf = tmp / "child.pid"
    try:
        r = cli("plan", "--sample", str(elf), "--output", str(tmp/"out"),
                "--allow-exec", "--wall-seconds", "1",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": "",
                    "QEMU_RUN_SLEEP": "15", "QEMU_SPAWN_CHILD": "1",
                    "QEMU_CHILD_PID_FILE": str(cpf)})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:300]}"
        if cpf.exists():
            child_pid = int(cpf.read_text().strip())
            time.sleep(0.3)
            try:
                os.kill(child_pid, 0)
                nok("RED6", f"child pid={child_pid} still alive after killpg")
            except OSError:
                ok("RED6: child reaped via killpg (process-TREE killed)")
        else:
            nok("RED6", "child pid file not created — shim must write it (QEMU_SPAWN_CHILD=1 set)")
    except Exception as e: nok("RED6", str(e))

# ── RED7: receipt round-trip: vm_pre_snapshot != vm_post_snapshot ────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--sample", str(elf), "--output", str(tmp/"out"),
                "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        res = json.loads(r.stdout)
        # Find receipt from serial_log path → run_dir
        serial_log = res.get("serial_log", "")
        assert serial_log, f"serial_log missing from evidence"
        run_dir = str(Path(serial_log).parent)
        receipt_path = f"{run_dir}/vm-run-receipt.v1.json"
        assert Path(receipt_path).exists(), f"receipt not found at {receipt_path}"
        receipt = json.loads(open(receipt_path).read())
        pre  = receipt.get("vm_pre_snapshot")
        post = receipt.get("vm_post_snapshot")
        assert pre  is not None, f"vm_pre_snapshot is null in receipt"
        assert post is not None, f"vm_post_snapshot is null in receipt"
        assert isinstance(pre,  dict) and "sha256" in pre,  f"pre not {{sha256}}: {pre}"
        assert isinstance(post, dict) and "sha256" in post, f"post not {{sha256}}: {post}"
        assert pre["sha256"]  != post["sha256"], \
            f"vm_pre_snapshot == vm_post_snapshot (fake shim must write to scratch)"
        assert pre["sha256"].startswith("sha256:"),  f"pre sha256 malformed: {pre}"
        assert post["sha256"].startswith("sha256:"), f"post sha256 malformed: {post}"
        # receipt identity must be present
        assert res.get("vm_receipt_identity", "").startswith("sha256:"), \
            f"vm_receipt_identity missing or malformed"
        # (R3 WARNING fix) scratch.img must appear in receipt.outputs[]
        output_names = [o["path"] for o in receipt.get("outputs", [])]
        assert "scratch.img" in output_names, \
            f"scratch.img not in receipt.outputs[] (R3 evidence chain): {output_names}"
        # Detect SCHEMA_VERSION argument swap between detonate_exec and trace_exec.
        assert res.get("schema_version") == "detonate-run.v1", \
            f"schema_version={res.get('schema_version')!r} (expected 'detonate-run.v1')"
        ok("RED7: vm_pre_snapshot != vm_post_snapshot, both {sha256}, receipt validates, scratch in outputs[], schema_version=detonate-run.v1")
    except Exception as e: nok("RED7", str(e))

# ── RED8: no shell=True in detonate_exec.py OR lib/vm_exec_common.py ─────────
# vm_exec_common.py owns the extracted host-layer subprocess code; detonate is
# the canonical scan owner (TRACE-RED8 does NOT cover vm_exec_common.py).
try:
    if sut_exec_path.exists():
        src = sut_exec_path.read_text()
        assert "shell=True" not in src, "shell=True found in detonate_exec.py!"
        _cpath = sut_exec_path.parent / "vm_exec_common.py"
        assert _cpath.exists(), f"vm_exec_common.py not found at {_cpath}"
        assert "shell=True" not in _cpath.read_text(), "shell=True found in vm_exec_common.py!"
        ok("RED8: no shell=True in detonate_exec.py or vm_exec_common.py")
    else:
        # File doesn't exist yet — will be RED once the file is created
        nok("RED8", f"detonate_exec.py not found at {sut_exec_path} (GREEN after Task A)")
except Exception as e: nok("RED8", str(e))

# ── RED10: scratch.img in receipt.outputs[] AND vm_post_snapshot.sha256 coherent ─
# Fixes R3 CRITICAL: scratch absent from outputs[] → evidence chain unverifiable.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--sample", str(elf), "--output", str(tmp/"out"),
                "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        res = json.loads(r.stdout)
        serial_log = res.get("serial_log", "")
        assert serial_log, "serial_log missing from evidence"
        run_dir_r = Path(serial_log).parent
        receipt_path = run_dir_r / "vm-run-receipt.v1.json"
        assert receipt_path.exists(), f"receipt not found at {receipt_path}"
        receipt = json.loads(receipt_path.read_text())
        # scratch.img must be in outputs[]
        outputs = receipt.get("outputs", [])
        output_names = [o["path"] for o in outputs]
        assert "scratch.img" in output_names, \
            f"scratch.img not in receipt.outputs[]: {output_names}"
        # vm_post_snapshot.sha256 must equal outputs[scratch.img].sha256
        post_snap = receipt.get("vm_post_snapshot")
        assert post_snap is not None and "sha256" in post_snap, \
            f"vm_post_snapshot missing or malformed: {post_snap}"
        scratch_entry = next((o for o in outputs if o["path"] == "scratch.img"), None)
        assert scratch_entry is not None, "scratch.img entry not found in outputs[]"
        assert post_snap["sha256"] == scratch_entry["sha256"], (
            f"vm_post_snapshot.sha256 != outputs[scratch.img].sha256: "
            f"{post_snap['sha256']!r} != {scratch_entry['sha256']!r}"
        )
        ok("RED10: scratch.img in outputs[] AND vm_post_snapshot.sha256 == outputs[scratch.img].sha256")
    except Exception as e: nok("RED10", str(e))

# ── RED11: exactly ONE /tmp/rsdd/rsdd-* dir created per evaluate() ────────────
# Fixes R4 CRITICAL: double run_dir leak (evaluate creates run_dir-A; run_vm creates run_dir-B).
import glob as _glob
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        before = set(_glob.glob("/tmp/rsdd/rsdd-*"))
        r = cli("plan", "--sample", str(elf), "--output", str(tmp/"out"),
                "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        after = set(_glob.glob("/tmp/rsdd/rsdd-*"))
        new_dirs = after - before
        assert len(new_dirs) == 1, (
            f"expected exactly 1 new run_dir per evaluate(), got {len(new_dirs)}: "
            f"{sorted(new_dirs)}"
        )
        ok("RED11: exactly 1 run_dir created per evaluate() (no double-dir leak)")
    except Exception as e: nok("RED11", str(e))

# ── RED12: post-snapshot failure → fail-soft (evidence preserved, vm_post_snapshot=null) ──
# Fixes R4 WARNING: post-hash outside try/finally — a failing post-hash discards all evidence.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--sample", str(elf), "--output", str(tmp/"out"),
                "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": "",
                    "DETONATE_REMOVE_SCRATCH_POST": "1"})
        assert r.returncode == 0, (
            f"run must succeed even when post-snapshot fails (fail-soft), "
            f"got rc={r.returncode}: {r.stderr[:300]}"
        )
        res = json.loads(r.stdout)
        assert res.get("outcome") in ("success", "boot-failure", "timeout-killed"), \
            f"outcome missing or unexpected: {res.get('outcome')}"
        serial_log = res.get("serial_log", "")
        assert serial_log, "serial_log missing from evidence"
        assert Path(serial_log).exists(), f"serial_log file gone: {serial_log!r}"
        run_dir_r = Path(serial_log).parent
        receipt_path = run_dir_r / "vm-run-receipt.v1.json"
        assert receipt_path.exists(), f"receipt not found at {receipt_path}"
        receipt = json.loads(receipt_path.read_text())
        # pre_snapshot must be present (hashed before shim removed scratch)
        pre_snap = receipt.get("vm_pre_snapshot")
        assert pre_snap is not None and "sha256" in pre_snap, \
            f"vm_pre_snapshot should be present (hashed before scratch removed), got: {pre_snap}"
        # post_snapshot must be null (fail-soft when scratch was removed)
        post_snap = receipt.get("vm_post_snapshot")
        assert post_snap is None, \
            f"vm_post_snapshot should be null (fail-soft), got: {post_snap}"
        ok("RED12: post-snapshot failure → fail-soft (evidence preserved, vm_post_snapshot=null)")
    except Exception as e: nok("RED12", str(e))

# ── RED13: receipt inputs[] bound to sample sha256 (F1: detonate uses "sample" key) ─────────
# Before F1 fix: plan.get("target", {}) in vm_boot_core.py returns {} for detonate plans
# because detonate_plan.py stores sample under key "sample", NOT "target" → inputs: [].
# After F1 fix: fallback to plan.get("sample") populates inputs[] with the sample entry.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--sample", str(elf), "--output", str(tmp/"out"),
                "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        res = json.loads(r.stdout)
        serial_log = res.get("serial_log", "")
        assert serial_log, "serial_log missing from evidence"
        run_dir_r = Path(serial_log).parent
        receipt_path = run_dir_r / "vm-run-receipt.v1.json"
        assert receipt_path.exists(), f"receipt not found at {receipt_path}"
        receipt = json.loads(receipt_path.read_text())
        inputs = receipt.get("inputs", [])
        assert len(inputs) > 0, (
            "receipt inputs[] is EMPTY — detonate-plan stores sample under key 'sample', "
            "but vm_boot_core.py only checks plan.get('target') → F1 not yet fixed"
        )
        # Verify the sha256 in inputs[] matches what detonate_plan recorded for the sample
        plan_file = tmp / "out" / "detonate-plan.v1.json"
        assert plan_file.exists(), f"plan file not found: {plan_file}"
        plan_data = json.loads(plan_file.read_text())
        expected_sha = plan_data["sample"]["sha256"]
        assert any(e["sha256"] == expected_sha for e in inputs), (
            f"inputs[] does not contain sample sha256 {expected_sha!r}: {inputs}"
        )
        ok("RED13: receipt inputs[] non-empty and contains sample sha256 (F1 fixed)")
    except Exception as e: nok("RED13", str(e))

# ── RED-F5A: exec_argv contains scratch file bind AFTER --tmpfs (INV-2 / F5) ──
# After evaluate(), the substituted exec_argv must have --bind <P> <P> where P
# is the real per-run scratch path AND the bind index is > --tmpfs index.
# Ordering is load-bearing: a bind before --tmpfs is silently re-masked.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
    try:
        r = cli("plan", "--sample", str(elf), "--output", str(tmp/"out"),
                "--allow-exec",
                xe={"PATH": p, "RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:400]}"
        res = json.loads(r.stdout)
        exec_argv = res.get("exec_argv", [])
        # find writable-persistent drive path (real per-run scratch)
        drive_specs = [exec_argv[i+1] for i, t in enumerate(exec_argv)
                       if t == "-drive" and i+1 < len(exec_argv)]
        scratch_specs = [s for s in drive_specs
                         if "snapshot=off" in s and "readonly=on" not in s]
        assert scratch_specs, f"no writable-persistent -drive in exec_argv: {exec_argv}"
        import re as _re
        m2 = _re.search(r"file=([^,]+)", scratch_specs[0])
        assert m2, f"no file= in scratch spec: {scratch_specs[0]}"
        scratch_path = m2.group(1)
        # exec_argv must contain contiguous ["--bind", scratch_path, scratch_path]
        bind_idx = None
        for i in range(len(exec_argv) - 2):
            if exec_argv[i] == "--bind" and exec_argv[i+1] == scratch_path and exec_argv[i+2] == scratch_path:
                bind_idx = i
                break
        assert bind_idx is not None, (
            f"exec_argv missing ['--bind', {scratch_path!r}, {scratch_path!r}]; "
            f"exec_argv={exec_argv}"
        )
        # --tmpfs must appear before the bind
        tmpfs_idx = exec_argv.index("--tmpfs") if "--tmpfs" in exec_argv else None
        assert tmpfs_idx is not None, "--tmpfs missing from exec_argv"
        assert bind_idx > tmpfs_idx, (
            f"--bind at {bind_idx} must be AFTER --tmpfs at {tmpfs_idx} "
            "(ordering guard: bind before tmpfs is silently re-masked)"
        )
        ok("RED-F5A: exec_argv has scratch --bind <P> <P> strictly after --tmpfs (INV-2 / F5)")
    except Exception as e: nok("RED-F5A: scratch-bind-in-exec-argv", str(e))

# ── RED-F2: plan_label names "detonate" in sentinel-missing GateError ────────────
# Swapping plan_label args in detonate_exec.py/trace_exec.py would flip the label here.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp)
    try:
        import detonate_exec as _de; from gate import GateError
        # _GOOD_ARGV has no sentinel (/rsdd/rsdd-test/scratch.img ≠ /rsdd/scratch.img);
        # _preflight passes, pre_boot finds no sentinel → GateError naming executor.
        _f2_plan = {"qemu_binary": "qemu-system-x86_64", "planned_argv": list(_GOOD_ARGV)}
        _old = os.environ.get("PATH", ""); os.environ["PATH"] = p
        try:
            _raised_f2 = None
            try: _de.DetonateVmExecutor(tmp / "out").evaluate(_f2_plan)
            except Exception as _e: _raised_f2 = _e
        finally: os.environ["PATH"] = _old
        assert isinstance(_raised_f2, GateError), f"expected GateError: {_raised_f2!r}"
        assert "detonate plan" in str(_raised_f2), f"GateError must name 'detonate plan': {_raised_f2}"
        ok("RED-F2: sentinel-free plan → GateError names 'detonate plan' (plan_label wired)")
    except Exception as e: nok("RED-F2: plan_label-detonate", str(e))

# ── RED-INV3: position-aware sentinel substitution (INV-3 / F4) ──────────────
# Tests for _substitute_scratch_sentinel() in vm_exec_common.
#
# Three structural positions in the planned argv:
#   1. --bind SRC  (complete-token match; tok == _SCRATCH_SENTINEL)
#   2. --bind DEST (complete-token match; tok == _SCRATCH_SENTINEL)
#   3. -drive file= (key-scoped infix: substitute within file= value only)
#
# Adversarial invariant: ANY other token containing the sentinel — whether as an
# exact match (e.g. -kernel /rsdd/scratch.img) or a substring (e.g. -bios
# /rsdd/scratch.img.bak) — MUST NOT be rewritten.  This is the core F4 defect.

_SENT3 = "/rsdd/scratch.img"
_REAL3 = "/tmp/rsdd/rsdd-TESTRUN/scratch.img"

# Adversarial argv: sentinel in all 3 structural positions PLUS two extra tokens
# that contain the sentinel in the wrong structural position.  The old substring
# scan rewrites both; the position-aware code must leave them untouched.
_ADV_ARGV = [
    "bwrap",
    "--tmpfs", "/tmp/rsdd",
    "--bind", _SENT3, _SENT3,                                   # positions 1 & 2
    "--ro-bind", "/input/rootfs", "/input/rootfs",
    "--",
    "qemu-system-x86_64",
    "-m", "256",
    "-drive", f"file={_SENT3},snapshot=off,format=raw,if=virtio",  # position 3
    # Adversarial token A: exact sentinel value in wrong structural position.
    # Old substring scan rewrites this; new code must NOT.
    "-kernel", _SENT3,
    # Adversarial token B: sentinel as a prefix of a larger path in wrong position.
    # Old substring scan also rewrites this; new code must NOT.
    "-bios", f"{_SENT3}.bak",
]

# ── RED-INV3-bind-subst ──────────────────────────────────────────────────────
try:
    import vm_exec_common as _vec
    _new3a, _deltas3a = _vec._substitute_scratch_sentinel(_ADV_ARGV, _REAL3)
    _bind3a = _new3a.index("--bind")
    _src3a  = _new3a[_bind3a + 1]
    _dst3a  = _new3a[_bind3a + 2]
    assert _src3a == _REAL3, f"--bind SRC not substituted: {_src3a!r}"
    assert _dst3a == _REAL3, f"--bind DEST not substituted: {_dst3a!r}"
    assert any(d["from"] == _SENT3 for d in _deltas3a), \
        f"delta missing for --bind substitution: {_deltas3a}"
    ok("RED-INV3-bind-subst: --bind SRC and DEST substituted to real scratch path (INV-3)")
except Exception as e: nok("RED-INV3-bind-subst", str(e))

# ── RED-INV3-drive-subst ─────────────────────────────────────────────────────
try:
    import vm_exec_common as _vec2
    _new3b, _deltas3b = _vec2._substitute_scratch_sentinel(_ADV_ARGV, _REAL3)
    _drive3b = _new3b.index("-drive")
    _spec3b  = _new3b[_drive3b + 1]
    assert f"file={_REAL3}" in _spec3b, \
        f"-drive file= not substituted: {_spec3b!r}"
    assert ",snapshot=off,format=raw,if=virtio" in _spec3b, \
        f"rest of drive spec corrupted after substitution: {_spec3b!r}"
    assert _SENT3 not in _spec3b, \
        f"sentinel still present in drive spec after substitution: {_spec3b!r}"
    ok("RED-INV3-drive-subst: -drive file= substituted, rest of spec intact (INV-3)")
except Exception as e: nok("RED-INV3-drive-subst", str(e))

# ── RED-INV3-adversarial ─────────────────────────────────────────────────────
# Core F4 assertion.  The old substring scan rewrites -kernel /rsdd/scratch.img
# and -bios /rsdd/scratch.img.bak; the new position-aware code must leave both
# untouched.
try:
    import vm_exec_common as _vec3
    _new3c, _ = _vec3._substitute_scratch_sentinel(_ADV_ARGV, _REAL3)
    # Adversarial A: -kernel /rsdd/scratch.img must NOT be rewritten
    _ki = _new3c.index("-kernel") if "-kernel" in _new3c else None
    assert _ki is not None, "-kernel disappeared from argv"
    _kv = _new3c[_ki + 1]
    assert _kv == _SENT3, \
        f"-kernel value was incorrectly rewritten to {_kv!r}; expected {_SENT3!r} (INV-3 / F4)"
    # Adversarial B: -bios /rsdd/scratch.img.bak must NOT be rewritten
    _bi = _new3c.index("-bios") if "-bios" in _new3c else None
    assert _bi is not None, "-bios disappeared from argv"
    _bv = _new3c[_bi + 1]
    _expected_bios = f"{_SENT3}.bak"
    assert _bv == _expected_bios, \
        f"-bios value was incorrectly rewritten to {_bv!r}; expected {_expected_bios!r} (INV-3 / F4)"
    ok("RED-INV3-adversarial: unrelated tokens with sentinel NOT rewritten (INV-3 / F4 core)")
except Exception as e: nok("RED-INV3-adversarial", str(e))

# ── RED-INV3-sentinel-absent ─────────────────────────────────────────────────
# When the sentinel is absent from exec_argv entirely, deltas must be empty and
# argv must be returned unchanged.  (pre_boot then raises GateError — existing
# behavior preserved.)
try:
    import vm_exec_common as _vec4
    _no_sent = [
        "bwrap", "--bind", "/real/path", "/real/path",
        "-drive", "file=/real/path,snapshot=off,format=raw,if=virtio",
    ]
    _new3d, _deltas3d = _vec4._substitute_scratch_sentinel(_no_sent, _REAL3)
    assert _deltas3d == [], \
        f"expected empty deltas when sentinel absent: {_deltas3d}"
    assert _new3d == _no_sent, \
        f"argv mutated when sentinel absent: {_new3d}"
    ok("RED-INV3-sentinel-absent: no sentinel → empty deltas, argv unchanged (INV-3)")
except Exception as e: nok("RED-INV3-sentinel-absent", str(e))

# ── RED-INV3-drive-prefix ─────────────────────────────────────────────────────
# A -drive whose file= value is the sentinel as a PREFIX of a longer path MUST
# be left untouched.  The exact-match guard (Fix 1) enforces this.
# Mutation proof: reverting Fix 1 to substring check reds this test.
try:
    import vm_exec_common as _vecDP
    _adv_prefix = [
        "-drive", f"file={_SENT3}.bak,snapshot=off,format=raw,if=virtio",
    ]
    _newDP, _deltasDP = _vecDP._substitute_scratch_sentinel(_adv_prefix, _REAL3)
    assert _newDP[1] == _adv_prefix[1], \
        f"drive prefix spec incorrectly rewritten to {_newDP[1]!r}"
    assert _deltasDP == [], f"unexpected delta for drive prefix: {_deltasDP}"
    ok("RED-INV3-drive-prefix: file= prefix path left untouched (INV-3 / F4)")
except Exception as e: nok("RED-INV3-drive-prefix", str(e))

# ── RED-INV3-nonfile-key ──────────────────────────────────────────────────────
# A -drive spec where the sentinel appears in a NON-file key (e.g. id=) MUST be
# left untouched.  Only the file= key is eligible for substitution.
# Mutation proof: reverting exact-equality `part == "file=" + _SCRATCH_SENTINEL` to substring check reds this.
try:
    import vm_exec_common as _vecNF
    _adv_nonfile = [
        "-drive", f"file=/some/real.img,id={_SENT3}",
    ]
    _newNF, _deltasNF = _vecNF._substitute_scratch_sentinel(_adv_nonfile, _REAL3)
    assert _newNF[1] == _adv_nonfile[1], \
        f"non-file-key spec incorrectly rewritten to {_newNF[1]!r}"
    assert _deltasNF == [], f"unexpected delta for non-file-key: {_deltasNF}"
    ok("RED-INV3-nonfile-key: sentinel in id= key left untouched (INV-3 / F4)")
except Exception as e: nok("RED-INV3-nonfile-key", str(e))

# ── RED-INV3-eval-seam: evaluate()-level adversarial -kernel not substituted (INV-3 seam) ──
# Mutation proof: revert pre_boot call site to substring loop → -kernel wrongly rewritten → FAILS.
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp)
    try:
        import detonate_exec as _de2; from gate import GateError
        _av2 = ["bwrap","--unshare-net","--unshare-pid","--cap-drop","ALL","--tmpfs","/tmp/rsdd","--dir","/tmp/rsdd/out",
                "--bind",_SENT3,_SENT3,"--ro-bind","/store/rootfs.img","/input/rootfs","--ro-bind","/store/sample.bin","/input/sample","--",
                "qemu-system-x86_64","-m","256","-smp","1","-accel","tcg","-nic","none","-nodefaults",
                "-sandbox","on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
                "-kernel",_SENT3,"-drive","file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio",
                "-drive",f"file={_SENT3},snapshot=off,format=raw,if=virtio","-drive","file=/input/rootfs,snapshot=on,format=raw,if=virtio"]
        _old2 = os.environ.get("PATH",""); os.environ["PATH"] = p
        try: _r2 = _de2.DetonateVmExecutor(tmp/"out").evaluate({"qemu_binary":"qemu-system-x86_64","planned_argv":_av2})
        finally: os.environ["PATH"] = _old2
        _ea2 = _r2.get("exec_argv",[]); _ki2 = _ea2.index("-kernel") if "-kernel" in _ea2 else None
        assert _ki2 is not None and _ea2[_ki2+1]==_SENT3 and any(_ea2[i]=="--bind" and _ea2[i+1]!=_SENT3 for i in range(len(_ea2)-1)), f"INV-3 seam: -kernel={_ea2[_ki2+1] if _ki2 is not None else 'missing'!r} or --bind not substituted"
        ok("RED-INV3-eval-seam: evaluate() seam — -kernel untouched, --bind/-drive substituted (INV-3)")
    except Exception as e: nok("RED-INV3-eval-seam", str(e))
# ── RED-INV5-earlyfail: early pre_boot failure → run_dir reaped (INV-5) ─────
# Before fix: GateError inside pre_boot (sentinel absent) leaves run_dir orphaned
# because the try/finally reap guard only begins AFTER Popen succeeds.
# INV-5 requires teardown on EVERY exit path — this regression test enforces it.
# RED proof: on unfixed code, _after - _before == 1 (one orphaned rsdd-* dir).
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shims(tmp)
    try:
        import detonate_exec as _de_inv5; from gate import GateError as _GE_INV5
        # _GOOD_ARGV has no sentinel (/rsdd/scratch.img); pre_boot creates
        # scratch.img in run_dir then raises GateError("sentinel not found").
        # This is a mid-pre_boot failure that hits run_dir BEFORE Popen.
        _inv5_plan = {"qemu_binary": "qemu-system-x86_64", "planned_argv": list(_GOOD_ARGV)}
        _old_inv5 = os.environ.get("PATH", ""); os.environ["PATH"] = p
        _before_inv5 = set(_glob.glob("/tmp/rsdd/rsdd-*"))
        try:
            _raised_inv5 = None
            try: _de_inv5.DetonateVmExecutor(tmp / "out").evaluate(_inv5_plan)
            except Exception as _e_inv5: _raised_inv5 = _e_inv5
        finally: os.environ["PATH"] = _old_inv5
        _after_inv5 = set(_glob.glob("/tmp/rsdd/rsdd-*"))
        _leaked_inv5 = _after_inv5 - _before_inv5
        assert isinstance(_raised_inv5, _GE_INV5), (
            f"expected GateError (sentinel absent), got {type(_raised_inv5).__name__}: {_raised_inv5!r}"
        )
        assert "not found in planned_argv" in str(_raised_inv5), (
            f"expected pre_boot sentinel error, got: {_raised_inv5!r}"
        )
        assert len(_leaked_inv5) == 0, (
            f"INV-5 FAIL: {len(_leaked_inv5)} orphaned run_dir(s) leaked after pre_boot "
            f"GateError: {sorted(_leaked_inv5)}"
        )
        ok("RED-INV5-earlyfail: pre_boot GateError → run_dir reaped, 0 orphans (INV-5)")
    except Exception as e: nok("RED-INV5-earlyfail", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
