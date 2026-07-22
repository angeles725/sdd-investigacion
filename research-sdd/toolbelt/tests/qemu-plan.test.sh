#!/usr/bin/env bash
# qemu-plan.test.sh — RED-first contract tests for qemu-plan.v1 (U-V10 / item 10)
# Written BEFORE qemu_plan.py; suite exits 2 ("SUT not found") until GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../qemu_plan.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
import importlib.util, json, os, subprocess, sys, tempfile, unittest.mock
from pathlib import Path
sut = Path(sys.argv[1])
sp = importlib.util.spec_from_file_location("qemu_plan", sut)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
sys.path.insert(0, str(sut.parent / "lib")); sys.path.insert(0, str(sut.parent))
passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))
def cli(*a, xe=None):
    e = os.environ.copy()
    if xe: e.update(xe)
    return subprocess.run([sys.executable, str(sut), *map(str, a)],
                          capture_output=True, text=True, env=e)
# Minimal ELF headers (20 bytes): e_ident[16] + e_type[2] + e_machine[2]
_ARM  = b'\x7fELF\x01\x01\x01' + b'\x00'*9 + b'\x02\x00\x28\x00'  # EM_ARM=40, LE
_AA64 = b'\x7fELF\x02\x01\x01' + b'\x00'*9 + b'\x02\x00\xb7\x00'  # EM_AARCH64=183, LE
_X64  = b'\x7fELF\x02\x01\x01' + b'\x00'*9 + b'\x02\x00\x3e\x00'  # EM_X86_64=62, LE
_BAD  = b'\x00ELF\x02\x01\x01' + b'\x00'*9 + b'\x02\x00\x3e\x00'  # bad magic
_UNK  = b'\x7fELF\x02\x01\x01' + b'\x00'*9 + b'\x02\x00\xff\xff'  # unknown e_machine

# ── T1: dry-run NEVER executes (Popen/run patched to raise) ──────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        with unittest.mock.patch("subprocess.Popen", side_effect=AssertionError("Popen!")), \
             unittest.mock.patch("subprocess.run",   side_effect=AssertionError("run!")):
            rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-user",
                                         "--output",str(out)]))
        assert rc == 3, f"expected 3, got {rc}"
        produced = {p.name for p in out.iterdir()} if out.exists() else set()
        assert "qemu-plan.v1.json" in produced and "vm-determinism.v1.json" in produced
        assert not produced - {"qemu-plan.v1.json","vm-determinism.v1.json"}, f"extra: {produced}"
        ok("T1: dry-run never executes; plan+det written; no subprocess triggered")
    except Exception as e: nok("T1: dry-run-never-executes", str(e))

# ── T2: flag absent → exit 3 ─────────────────────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        r = cli("plan","--target",str(tgt),"--mode","qemu-user","--output",str(out))
        assert r.returncode == 3, f"got {r.returncode}"
        ok("T2: flag absent → exit 3 (authorization-required)")
    except Exception as e: nok("T2: flag-absent-exit3", str(e))

# ── T3: --allow-exec + no live executor → exit 2 ─────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        r = cli("plan","--target",str(tgt),"--mode","qemu-user","--output",str(out),
                "--allow-exec", xe={"RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 2, f"got {r.returncode}\n{r.stderr[:120]}"
        ok("T3: --allow-exec + no live executor → exit 2 (gate hard-refuse)")
    except Exception as e: nok("T3: allow-exec-hard-refuse", str(e))

# ── T4: qemu-user mode → well-formed plan + correct argv ─────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-user",
                                     "--output",str(out)]))
        assert rc == 3
        p = json.loads((out/"qemu-plan.v1.json").read_text())
        assert p["schema_version"] == "qemu-plan.v1"
        assert p["mode"] == "qemu-user" and p["arch"] == "arm"
        assert p["qemu_binary"] == "qemu-arm", f"binary={p['qemu_binary']!r}"
        argv = p["planned_argv"]
        assert "bwrap" in argv and "qemu-arm" in argv and "/input/target" in argv
        assert "--unshare-net" in argv and "--cap-drop" in argv and "ALL" in argv
        ok("T4: qemu-user + ARM → well-formed plan with correct intended argv")
    except Exception as e: nok("T4: qemu-user-arm-plan", str(e))

# ── T5: qemu-system mode → correct plan + disk_snapshot ──────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-system",
                                     "--output",str(out)]))
        assert rc == 3
        p = json.loads((out/"qemu-plan.v1.json").read_text())
        assert p["mode"] == "qemu-system" and p["qemu_binary"] == "qemu-system-arm"
        assert p["mount_plan"].get("disk_snapshot") == "ephemeral"
        argv = p["planned_argv"]
        assert "qemu-system-arm" in argv and "-snapshot" in argv and "-nographic" in argv
        ok("T5: qemu-system + ARM → well-formed plan with disk_snapshot=ephemeral")
    except Exception as e: nok("T5: qemu-system-arm-plan", str(e))

# ── T6: ELF AArch64 → qemu-aarch64; T7: ELF x86_64 → qemu-x86_64 ───────────
for t_name, t_bytes, t_arch, t_bin in [
    ("T6: ELF AArch64 (e_machine=183)", _AA64, "aarch64", "qemu-aarch64"),
    ("T7: ELF x86_64 (e_machine=62)",   _X64,  "x86_64",  "qemu-x86_64"),
]:
    with tempfile.TemporaryDirectory() as td:
        R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(t_bytes); out = R/"out"
        try:
            rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-user",
                                         "--output",str(out)]))
            assert rc == 3
            p = json.loads((out/"qemu-plan.v1.json").read_text())
            assert p["arch"] == t_arch and p["qemu_binary"] == t_bin, \
                f"arch={p['arch']!r} bin={p['qemu_binary']!r}"
            ok(f"{t_name} → {t_bin} detected correctly")
        except Exception as e: nok(t_name, str(e))

# ── T8-T10: malformed ELF → exit 2, no traceback (parametrized) ──────────────
for t_name, t_bytes in [
    ("T8: too-short file (4 bytes)", b'\x7fELF'),
    ("T9: bad ELF magic",            _BAD),
    ("T10: unknown e_machine",       _UNK),
]:
    with tempfile.TemporaryDirectory() as td:
        R = Path(td); tgt = R/"e.elf"; tgt.write_bytes(t_bytes); out = R/"out"
        try:
            r = cli("plan","--target",str(tgt),"--mode","qemu-user","--output",str(out))
            assert r.returncode == 2, f"got {r.returncode}"
            assert "Traceback" not in r.stderr, f"traceback: {r.stderr[:300]}"
            ok(f"{t_name} → exit 2, no traceback")
        except Exception as e: nok(t_name, str(e))

# ── T11: symlink target → exit 2, no traceback (O_NOFOLLOW) ──────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); real = R/"r.elf"; real.write_bytes(_ARM)
    link = R/"l.elf"; link.symlink_to(real); out = R/"out"
    try:
        r = cli("plan","--target",str(link),"--mode","qemu-user","--output",str(out))
        assert r.returncode == 2 and "Traceback" not in r.stderr
        ok("T11: symlink target → exit 2, no traceback (O_NOFOLLOW guard)")
    except Exception as e: nok("T11: symlink-target-clean-error", str(e))

# ── T12: same input → identical plan identity (determinism) ──────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"d.elf"; tgt.write_bytes(_ARM); out1 = R/"r1"; out2 = R/"r2"
    try:
        m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-user","--output",str(out1)]))
        m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-user","--output",str(out2)]))
        p1 = json.loads((out1/"qemu-plan.v1.json").read_text())
        p2 = json.loads((out2/"qemu-plan.v1.json").read_text())
        assert p1 == p2, "plans differ"
        ok("T12: same input → identical plan (deterministic)")
    except Exception as e: nok("T12: determinism-same-input", str(e))

# ── T13: determinism record declared:false, basis:dry-run-plan ───────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"d.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-user","--output",str(out)]))
        det = json.loads((out/"vm-determinism.v1.json").read_text())
        assert det["reproducible"]["declared"] is False
        assert det["reproducible"]["basis"] == "dry-run-plan"
        assert det["receipt_identity"] is None
        ok("T13: det record: declared:false, basis:dry-run-plan, receipt_identity:null")
    except Exception as e: nok("T13: determinism-record-state", str(e))

# ── T14: output under /home → exit 2 (bind-scope guard) ──────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM)
    try:
        r = cli("plan","--target",str(tgt),"--mode","qemu-user","--output","/home/qemu-plan-unsafe")
        assert r.returncode == 2, f"got {r.returncode}"
        ok("T14: output under /home → exit 2 (bind-scope guard)")
    except Exception as e: nok("T14: bind-path-safety", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
