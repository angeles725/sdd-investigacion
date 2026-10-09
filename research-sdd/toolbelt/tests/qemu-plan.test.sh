#!/usr/bin/env bash
# qemu-plan.test.sh — RED-first contract tests for qemu-plan.v1 (U-V10 / item 10)
# Written BEFORE qemu_plan.py; suite exits 2 ("SUT not found") until GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../qemu_plan.py"; REL="qemu_plan.py"
if [ "${1:-}" = "--teeth-child" ]; then   # argument-selected SUT for the mutation teeth (fails closed below)
  SUT="${2:-}"
  [ -f "$SUT" ] || { echo "FATAL: --teeth-child needs an existing SUT file, got [$SUT]" >&2; exit 2; }
  echo "TEETH-CHILD: SUT=$SUT"
fi
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
IFS= read -r -d '' PY_SRC <<'PY'
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
        assert r.returncode == 2 and "Traceback" not in r.stderr, \
            f"arch reader did not refuse the symlink: rc={r.returncode} {r.stderr[:200]}"
        assert "cannot read ELF header" in r.stderr, f"arch reader did not refuse the symlink: {r.stderr[:200]}"
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

# ── T14b: output == $HOME (belt rule) → exit 2, nothing written (safe fixture: HOME is a temp dir) ──
with tempfile.TemporaryDirectory() as td:
    R = Path(td); h = R/"h"; h.mkdir(); tgt = R/"t.elf"; tgt.write_bytes(_ARM)
    try:
        r = cli("plan","--target",str(tgt),"--mode","qemu-user","--output",str(h), xe={"HOME": str(h)})
        assert r.returncode == 2, f"got {r.returncode}"
        assert "real home directory" in r.stderr, f"stderr: {r.stderr[:200]}"
        assert not list(h.iterdir()), f"files written under HOME: {[p.name for p in h.iterdir()]}"
        ok("T14b: output == $HOME → exit 2, nothing written (bind-scope belt)")
    except Exception as e: nok("T14b: bind-scope-home-belt", str(e))


# ── T_CAP1: --max-input-bytes below target size → exit 2, clean error, no traceback ──
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"target.elf"; tgt.write_bytes(_ARM + b"\x00"*80); out = R/"out"
    # target is > 80 bytes; cap is 5 bytes → identity must reject it
    try:
        r = cli("plan","--target",str(tgt),"--mode","qemu-user","--output",str(out),"--max-input-bytes","5")
        assert r.returncode == 2, f"got {r.returncode}"
        assert "Traceback" not in r.stderr, f"traceback in stderr: {r.stderr[:200]}"
        assert ("exceeds" in r.stderr or "max-input" in r.stderr), \
               f"missing cap rejection message: {r.stderr[:200]}"
        ok("T_CAP1: --max-input-bytes below target size → exit 2, clean error, no traceback")
    except Exception as e: nok("T_CAP1: cap-below-target-size", str(e))


# ── T_CONTAIN1: qemu-system plan has -nic none (qemu-level net isolation) ────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-system",
                                     "--output",str(out)]))
        assert rc == 3
        p = json.loads((out/"qemu-plan.v1.json").read_text())
        argv = p["planned_argv"]
        assert "-nic" in argv and "none" in argv, f"-nic none missing from argv: {argv}"
        idx = argv.index("-nic")
        assert argv[idx + 1] == "none", f"-nic followed by {argv[idx+1]!r}, expected 'none'"
        ok("T_CONTAIN1: qemu-system plan has -nic none (qemu-level net isolation)")
    except Exception as e: nok("T_CONTAIN1: -nic-none-present", str(e))

# ── T_CONTAIN2: qemu-system plan has -nodefaults ─────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-system",
                                     "--output",str(out)]))
        assert rc == 3
        argv = json.loads((out/"qemu-plan.v1.json").read_text())["planned_argv"]
        assert "-nodefaults" in argv, f"-nodefaults missing from argv: {argv}"
        ok("T_CONTAIN2: qemu-system plan has -nodefaults")
    except Exception as e: nok("T_CONTAIN2: -nodefaults-present", str(e))

# ── T_CONTAIN3: qemu-system plan has -sandbox on (qemu seccomp sandbox) ──────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-system",
                                     "--output",str(out)]))
        assert rc == 3
        argv = json.loads((out/"qemu-plan.v1.json").read_text())["planned_argv"]
        assert "-sandbox" in argv, f"-sandbox missing from argv: {argv}"
        idx = argv.index("-sandbox")
        assert argv[idx + 1].startswith("on"), \
            f"-sandbox not 'on...', got {argv[idx+1]!r}"
        ok("T_CONTAIN3: qemu-system plan has -sandbox on (qemu seccomp sandbox)")
    except Exception as e: nok("T_CONTAIN3: -sandbox-on-present", str(e))

# ── T_CONTAIN4: qemu-system plan has -smp (vCPU bound) ───────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-system",
                                     "--output",str(out)]))
        assert rc == 3
        argv = json.loads((out/"qemu-plan.v1.json").read_text())["planned_argv"]
        assert "-smp" in argv, f"-smp missing from argv: {argv}"
        idx = argv.index("-smp")
        assert argv[idx + 1].isdigit(), f"-smp value not a digit: {argv[idx+1]!r}"
        ok("T_CONTAIN4: qemu-system plan has -smp <N> (vCPU bound)")
    except Exception as e: nok("T_CONTAIN4: -smp-present", str(e))

# ── T_CONTAIN5: qemu-system plan has -accel tcg (default offline accel) ──────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-system",
                                     "--output",str(out)]))
        assert rc == 3
        argv = json.loads((out/"qemu-plan.v1.json").read_text())["planned_argv"]
        assert "-accel" in argv, f"-accel missing from argv: {argv}"
        idx = argv.index("-accel")
        assert argv[idx + 1] == "tcg", f"-accel value is {argv[idx+1]!r}, expected 'tcg'"
        assert "-enable-kvm" not in argv, f"-enable-kvm found in argv (must not be default)"
        ok("T_CONTAIN5: qemu-system plan has -accel tcg, no -enable-kvm")
    except Exception as e: nok("T_CONTAIN5: -accel-tcg-present", str(e))

# ── T_CONTAIN6: containment flags NOT present in qemu-user mode plan ─────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; tgt.write_bytes(_ARM); out = R/"out"
    try:
        rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-user",
                                     "--output",str(out)]))
        assert rc == 3
        argv = json.loads((out/"qemu-plan.v1.json").read_text())["planned_argv"]
        # qemu-user mode is plan-only; containment flags are qemu-system-only
        assert "-nic" not in argv, f"-nic found in qemu-user argv (should be system-only)"
        assert "-sandbox" not in argv, f"-sandbox found in qemu-user argv (should be system-only)"
        ok("T_CONTAIN6: containment flags absent in qemu-user plan (system-only)")
    except Exception as e: nok("T_CONTAIN6: user-mode-no-contain-flags", str(e))

# ── T_TOCTOU1: target swapped between header read and hashing (#2069) ────────
# The wrapper swaps the target file the moment a SECOND open of it is attempted. Single-open code never
# triggers the swap; two-open code sees file B at the hash and describes two different files.
import hashlib
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; out = R/"out"
    a_bytes = _ARM + b'A'*64; b_bytes = _X64 + b'B'*64
    tgt.write_bytes(a_bytes); alt = R/"alt.elf"; alt.write_bytes(b_bytes)
    real_open = os.open; opens = []
    def swap_open(p, *a, **k):
        if str(p) == str(tgt):
            opens.append(1)
            if len(opens) == 2: os.replace(alt, tgt)
        return real_open(p, *a, **k)
    try:
        with unittest.mock.patch("os.open", swap_open):
            rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-user","--output",str(out)]))
        assert rc in (2, 3), f"unexpected rc {rc}"
        if rc == 3:
            p = json.loads((out/"qemu-plan.v1.json").read_text())
            want = "sha256:" + hashlib.sha256(a_bytes).hexdigest()
            assert p["arch"] == "arm" and p["target"]["sha256"] == want, \
                f"plan describes different files: arch={p['arch']} sha256={p['target']['sha256']} (arm bytes hash {want})"
        assert len(opens) == 1, f"target opened {len(opens)} times, expected exactly one open"
        ok("T_TOCTOU1: target opened once; arch and sha256 describe the same bytes")
    except Exception as e: nok("T_TOCTOU1: single-open-consistent-identity", str(e))

# ── T_TOCTOU2: target mutated in place after the header read → refused ───────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.elf"; out = R/"out"
    tgt.write_bytes(_ARM + b'A'*64)
    ino = os.stat(tgt).st_ino; real_read = os.read; fired = []
    def mut_read(fd, n):
        if not fired and os.fstat(fd).st_ino == ino:
            fired.append(1)
            with open(tgt, "ab") as fh: fh.write(b'tail')
        return real_read(fd, n)
    try:
        with unittest.mock.patch("os.read", mut_read):
            rc = m.plan_qemu(m._parser(["plan","--target",str(tgt),"--mode","qemu-user","--output",str(out)]))
        assert fired, "mutation hook never fired (target not read via os.read)"
        assert rc == 2, f"in-place mutation mid-read accepted: rc={rc}"
        assert not (out/"qemu-plan.v1.json").exists(), "plan written for a mutated target"
        ok("T_TOCTOU2: in-place mutation between header read and hash → refused (exit 2)")
    except Exception as e: nok("T_TOCTOU2: mutation-mid-read-refused", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
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
tt teeth-nic '"-nic", "none",' '"-nic", "user",' 'FAIL  T_CONTAIN1: -nic-none-present: -nic none missing from argv'
tt teeth-nodefaults '"-nodefaults",' '"-nographic",' 'FAIL  T_CONTAIN2: -nodefaults-present: -nodefaults missing from argv'
tt teeth-sandbox '"-sandbox", "on,' '"-sandbox", "off,' "FAIL  T_CONTAIN3: -sandbox-on-present: -sandbox not 'on"
tt teeth-smp '"-smp", "1",' '"-smp", "x",' 'FAIL  T_CONTAIN4: -smp-present: -smp value not a digit'
tt teeth-accel '"-accel", "tcg",' '"-accel", "kvm",' "FAIL  T_CONTAIN5: -accel-tcg-present: -accel value is 'kvm'"
tt teeth-input-cap '_read_target(target, args.max_input_bytes)' '_read_target(target, None)' 'FAIL  T_CAP1: cap-below-target-size: got 3'
tt teeth-single-open 'os.lseek(fd, 0, os.SEEK_SET)' 'os.close(fd); fd = os.open(path, flags)' 'FAIL  T_TOCTOU1: single-open-consistent-identity: target opened 2 times'
tt teeth-fstat-recheck 'if fields(before) != fields(after) or total != before.st_size:' 'if False:' 'FAIL  T_TOCTOU2: mutation-mid-read-refused: in-place mutation mid-read accepted'
tt teeth-arch-nofollow 'getattr(os, "O_NOFOLLOW", 0)' '0' 'FAIL  T11: symlink-target-clean-error: arch reader did not refuse the symlink'
tt teeth-bind-scope 'assert_safe_bind_root(Path(os.path.realpath(output_dir)))' 'pass' 'FAIL  T14b: bind-scope-home-belt: got 3'

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
