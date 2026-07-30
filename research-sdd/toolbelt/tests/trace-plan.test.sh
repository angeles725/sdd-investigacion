#!/usr/bin/env bash
# trace-plan.test.sh — RED-first contract tests for trace-plan.v1 (U-V9 / item 9)
# Written BEFORE trace_plan.py; suite exits 2 ("SUT not found") until GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../trace_plan.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
import importlib.util, json, os, subprocess, sys, tempfile, types, unittest.mock
from pathlib import Path
sut = Path(sys.argv[1])
sp = importlib.util.spec_from_file_location("trace_plan", sut)
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
# A minimal binary-like file content (identity doesn't care about format).
_BIN = b"\x7fELF\x02\x01\x01\x00" + b"\x00" * 8  # ELF magic + padding

# ── T1: dry-run NEVER executes (Popen/run patched to raise) ──────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"target.bin"; tgt.write_bytes(_BIN); out = R/"out"
    try:
        with unittest.mock.patch("subprocess.Popen", side_effect=AssertionError("Popen!")), \
             unittest.mock.patch("subprocess.run",   side_effect=AssertionError("run!")):
            rc = m.plan_trace(m._parser(["plan","--target",str(tgt),"--tracer","strace",
                                         "--output",str(out)]))
        assert rc == 3, f"expected 3, got {rc}"
        produced = {p.name for p in out.iterdir()} if out.exists() else set()
        assert "trace-plan.v1.json"   in produced, f"plan missing; got {produced}"
        assert "vm-determinism.v1.json" in produced, f"det missing; got {produced}"
        extra = produced - {"trace-plan.v1.json", "vm-determinism.v1.json"}
        assert not extra, f"unexpected files: {extra}"
        ok("T1: dry-run never executes; plan+det written; no subprocess triggered")
    except Exception as e: nok("T1: dry-run-never-executes", str(e))

# ── T2: flag absent → exit 3 (authorization-required) ────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.bin"; tgt.write_bytes(_BIN); out = R/"out"
    try:
        r = cli("plan","--target",str(tgt),"--tracer","strace","--output",str(out))
        assert r.returncode == 3, f"got {r.returncode}"
        ok("T2: flag absent → exit 3 (authorization-required)")
    except Exception as e: nok("T2: flag-absent-exit3", str(e))

# ── T3: --allow-exec + qemu not on PATH → exit 2 (preflight GateError) ───────
# D3: local wiring adds TraceVmExecutor; preflight must reject when qemu is absent.
# Restrict PATH to an empty temp dir so qemu-system-* is not found.
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.bin"; tgt.write_bytes(_BIN); out = R/"out"
    with tempfile.TemporaryDirectory() as empty_bin:
        try:
            r = cli("plan","--target",str(tgt),"--tracer","strace","--output",str(out),
                    "--allow-exec", xe={"RSDD_EXEC_EXECUTOR": "", "PATH": empty_bin})
            assert r.returncode == 2, f"got {r.returncode}\n{r.stderr[:120]}"
            ok("T3: --allow-exec + qemu not on PATH → exit 2 (preflight GateError)")
        except Exception as e: nok("T3: allow-exec-hard-refuse", str(e))

# ── T4: strace → well-formed qemu-system+disk plan (D3 rebuild) ──────────────
# D3 rebuild: planned_argv is now the qemu-system+disk form (tracer in kernel cmdline).
# Tracer selection encoded as: -append "init=/rsdd-agent rsdd.tracer=strace"
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.bin"; tgt.write_bytes(_BIN); out = R/"out"
    try:
        rc = m.plan_trace(m._parser(["plan","--target",str(tgt),"--tracer","strace",
                                     "--output",str(out)]))
        assert rc == 3  # auth-required (no --allow-exec)
        p = json.loads((out/"trace-plan.v1.json").read_text())
        assert p["schema_version"] == "trace-plan.v1"
        assert p["tracer"] == "strace"
        argv = p["planned_argv"]
        assert "bwrap" in argv, f"bwrap missing: {argv}"
        assert "--unshare-net" in argv, f"--unshare-net missing"
        assert "--cap-drop" in argv and "ALL" in argv, "--cap-drop ALL missing"
        # qemu-system-* must appear (D3 rebuild: no strace/ltrace/gdb as host-level cmd)
        assert any(a.startswith("qemu-system-") for a in argv), \
            f"no qemu-system-* found in argv: {argv}"
        # per-drive disk slots: sample ro, scratch persistent, rootfs COW
        drive_specs = [argv[i+1] for i,t in enumerate(argv) if t=="-drive" and i+1<len(argv)]
        assert any("/input/sample" in d and "readonly=on" in d for d in drive_specs), \
            f"sample readonly drive missing: {drive_specs}"
        assert any("/rsdd/scratch.img" in d and "snapshot=off" in d
                   and "readonly=on" not in d for d in drive_specs), \
            f"scratch sentinel drive missing: {drive_specs}"
        assert any("/input/rootfs" in d and "snapshot=on" in d for d in drive_specs), \
            f"rootfs COW drive missing: {drive_specs}"
        # tracer encoded in kernel cmdline
        assert "-append" in argv, f"-append missing from argv (tracer selection): {argv}"
        assert any("rsdd.tracer=strace" in a for a in argv), \
            f"rsdd.tracer=strace not found in any argv token: {argv}"
        ok("T4: strace → qemu-system+disk plan; tracer in kernel cmdline (D3 rebuild)")
    except Exception as e: nok("T4: strace-plan-argv-vm-disk-form", str(e))

# ── T5: ltrace → qemu-system+disk plan (D3 rebuild) ─────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.bin"; tgt.write_bytes(_BIN); out = R/"out"
    try:
        rc = m.plan_trace(m._parser(["plan","--target",str(tgt),"--tracer","ltrace",
                                     "--output",str(out)]))
        assert rc == 3
        p = json.loads((out/"trace-plan.v1.json").read_text())
        assert p["tracer"] == "ltrace"
        argv = p["planned_argv"]
        assert any(a.startswith("qemu-system-") for a in argv), \
            f"no qemu-system-* in argv: {argv}"
        assert "-append" in argv
        assert any("rsdd.tracer=ltrace" in a for a in argv), \
            f"rsdd.tracer=ltrace not found: {argv}"
        ok("T5: ltrace → qemu-system+disk plan; tracer in kernel cmdline (D3 rebuild)")
    except Exception as e: nok("T5: ltrace-plan-argv-vm-disk-form", str(e))

# ── T6: gdb-batch → qemu-system+disk plan (D3 rebuild) ──────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.bin"; tgt.write_bytes(_BIN); out = R/"out"
    try:
        rc = m.plan_trace(m._parser(["plan","--target",str(tgt),"--tracer","gdb-batch",
                                     "--output",str(out)]))
        assert rc == 3
        p = json.loads((out/"trace-plan.v1.json").read_text())
        assert p["tracer"] == "gdb-batch"
        argv = p["planned_argv"]
        assert any(a.startswith("qemu-system-") for a in argv), \
            f"no qemu-system-* in argv: {argv}"
        assert "-append" in argv
        assert any("rsdd.tracer=gdb-batch" in a for a in argv), \
            f"rsdd.tracer=gdb-batch not found: {argv}"
        ok("T6: gdb-batch → qemu-system+disk plan; tracer in kernel cmdline (D3 rebuild)")
    except Exception as e: nok("T6: gdb-batch-plan-argv-vm-disk-form", str(e))

# ── T7: unsupported tracer → clean structured error, no traceback ─────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.bin"; tgt.write_bytes(_BIN); out = R/"out"
    try:
        # Bypass argparse by using a direct namespace (CLI would catch this via choices).
        args = types.SimpleNamespace(target=str(tgt), output=str(out), tracer="evil-tracer",
                                     allow_exec=False, cpu_seconds=30, max_mem_bytes=256<<20,
                                     wall_seconds=60, max_output_bytes=128<<20)
        rc = m.plan_trace(args)
        assert rc == 2, f"expected 2, got {rc}"
        ok("T7: unsupported tracer → exit 2, clean error (no traceback from plan_trace)")
    except Exception as e: nok("T7: unsupported-tracer-clean-error", str(e))

# ── T8: missing target → clean structured error, no traceback ────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); out = R/"out"
    try:
        r = cli("plan","--target",str(R/"nonexistent.bin"),"--tracer","strace","--output",str(out))
        assert r.returncode == 2, f"got {r.returncode}"
        assert "Traceback" not in r.stderr, f"traceback: {r.stderr[:300]}"
        ok("T8: missing target → exit 2, no traceback")
    except Exception as e: nok("T8: missing-target-clean-error", str(e))

# ── T9: symlink target → clean structured error, no traceback ────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); real = R/"real.bin"; real.write_bytes(_BIN)
    link = R/"link.bin"; link.symlink_to(real); out = R/"out"
    try:
        r = cli("plan","--target",str(link),"--tracer","strace","--output",str(out))
        assert r.returncode == 2, f"got {r.returncode}"
        assert "Traceback" not in r.stderr, f"traceback: {r.stderr[:300]}"
        ok("T9: symlink target → exit 2, no traceback (O_NOFOLLOW guard)")
    except Exception as e: nok("T9: symlink-target-clean-error", str(e))

# ── T10: same input → identical plan (determinism) ───────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"det.bin"; tgt.write_bytes(_BIN); out1 = R/"r1"; out2 = R/"r2"
    try:
        m.plan_trace(m._parser(["plan","--target",str(tgt),"--tracer","strace","--output",str(out1)]))
        m.plan_trace(m._parser(["plan","--target",str(tgt),"--tracer","strace","--output",str(out2)]))
        p1 = json.loads((out1/"trace-plan.v1.json").read_text())
        p2 = json.loads((out2/"trace-plan.v1.json").read_text())
        assert p1 == p2, "plans differ"
        ok("T10: same input → identical plan (deterministic)")
    except Exception as e: nok("T10: determinism-same-input", str(e))

# ── T11: determinism record state ────────────────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"dr.bin"; tgt.write_bytes(_BIN); out = R/"out"
    try:
        m.plan_trace(m._parser(["plan","--target",str(tgt),"--tracer","ltrace","--output",str(out)]))
        det = json.loads((out/"vm-determinism.v1.json").read_text())
        assert det["reproducible"]["declared"] is False
        assert det["reproducible"]["basis"] == "dry-run-plan"
        assert det["receipt_identity"] is None
        ok("T11: det record: declared:false, basis:dry-run-plan, receipt_identity:null")
    except Exception as e: nok("T11: determinism-record-state", str(e))

# ── T12: output under /home → exit 2 (bind-scope guard) ──────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.bin"; tgt.write_bytes(_BIN)
    try:
        r = cli("plan","--target",str(tgt),"--tracer","strace","--output","/home/trace-plan-unsafe")
        assert r.returncode == 2, f"got {r.returncode}"
        ok("T12: output under /home → exit 2 (bind-scope guard)")
    except Exception as e: nok("T12: bind-path-safety", str(e))


# ── T_CAP1: --max-input-bytes below target size → exit 2, clean error, no traceback ──
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"target.bin"; tgt.write_bytes(_BIN + b"\x00"*80); out = R/"out"
    # target is > 80 bytes; cap is 5 bytes → identity must reject it
    try:
        r = cli("plan","--target",str(tgt),"--tracer","strace","--output",str(out),"--max-input-bytes","5")
        assert r.returncode == 2, f"got {r.returncode}"
        assert "Traceback" not in r.stderr, f"traceback in stderr: {r.stderr[:200]}"
        assert ("exceeds" in r.stderr or "max-input" in r.stderr), \
               f"missing cap rejection message: {r.stderr[:200]}"
        ok("T_CAP1: --max-input-bytes below target size → exit 2, clean error, no traceback")
    except Exception as e: nok("T_CAP1: cap-below-target-size", str(e))

# ── T-scratch-bind: planned_argv contains scratch bind triple AFTER --tmpfs (INV-2/F5) ─
# Mirror of detonate-plan.test.sh::T4c. Ordering is load-bearing.
with tempfile.TemporaryDirectory() as td:
    R = Path(td); tgt = R/"t.bin"; tgt.write_bytes(_BIN); out = R/"out"
    try:
        rc = m.plan_trace(m._parser(["plan","--target",str(tgt),"--tracer","strace",
                                     "--output",str(out)]))
        assert rc == 3
        p = json.loads((out/"trace-plan.v1.json").read_text())
        argv = p["planned_argv"]
        mp = p["mount_plan"]
        # C3: host_writable must equal scratch_persistent
        assert mp.get("host_writable") == mp.get("scratch_persistent"), (
            f"host_writable {mp.get('host_writable')!r} must equal "
            f"scratch_persistent {mp.get('scratch_persistent')!r}"
        )
        scratch = mp["scratch_persistent"]
        # contiguous bind triple must be present
        bind_idx = None
        for i in range(len(argv) - 2):
            if argv[i] == "--bind" and argv[i+1] == scratch and argv[i+2] == scratch:
                bind_idx = i
                break
        assert bind_idx is not None, (
            f"planned_argv missing ['--bind', {scratch!r}, {scratch!r}]; argv={argv}"
        )
        tmpfs_idx = argv.index("--tmpfs") if "--tmpfs" in argv else None
        assert tmpfs_idx is not None, "--tmpfs missing from planned_argv"
        assert bind_idx > tmpfs_idx, (
            f"--bind at {bind_idx} must come AFTER --tmpfs at {tmpfs_idx}"
        )
        ok("T-scratch-bind: planned_argv has scratch --bind triple strictly after --tmpfs (INV-2/F5)")
    except Exception as e: nok("T-scratch-bind: scratch-bind-after-tmpfs", str(e))

# ── TP-RTMOUNT — runtime-tree bind tests (mirrors detonate; gaps 1/3/4) ──────────
# RED: --qemu-root unknown → rc=2. GREEN: rt bind + absolute qbin + in-tree kernel.
# ── TP-RTMOUNT: plan has --ro-bind <src> /rsdd/rt when --qemu-root given ─────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3, f"got {r.returncode}; stderr={r.stderr[:200]}"
        argv = json.loads((out/"trace-plan.v1.json").read_text())["planned_argv"]
        rt_idx = next((i for i in range(len(argv)-2)
                       if argv[i]=="--ro-bind" and argv[i+2]=="/rsdd/rt"), None)
        assert rt_idx is not None, f"no --ro-bind ... /rsdd/rt in argv"
        assert argv[rt_idx+1] == "/opt/rsdd/rt"
        ok("TP-RTMOUNT: --qemu-root → trace planned_argv has --ro-bind /opt/rsdd/rt /rsdd/rt")
    except Exception as e: nok("TP-RTMOUNT", str(e))
# ── TP-RTMOUNT-RO: rt bind is --ro-bind (not --bind) ─────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3
        argv = json.loads((out/"trace-plan.v1.json").read_text())["planned_argv"]
        rw = [(argv[i+1],argv[i+2]) for i in range(len(argv)-2) if argv[i]=="--bind"]
        assert all(dst != "/rsdd/rt" for _,dst in rw), \
            f"runtime tree bind must be --ro-bind: {rw}"
        ok("TP-RTMOUNT-RO: trace runtime tree bind is --ro-bind (read-only)")
    except Exception as e: nok("TP-RTMOUNT-RO", str(e))
# ── TP-RTMOUNT-AFTER-TMPFS: rt bind is after --tmpfs (INV-2) ─────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3
        argv = json.loads((out/"trace-plan.v1.json").read_text())["planned_argv"]
        tmpfs_i = argv.index("--tmpfs")
        rt_i = next(i for i in range(len(argv)-2) if argv[i]=="--ro-bind" and argv[i+2]=="/rsdd/rt")
        assert rt_i > tmpfs_i
        ok("TP-RTMOUNT-AFTER-TMPFS: trace rt bind is after --tmpfs (INV-2 / ordering)")
    except Exception as e: nok("TP-RTMOUNT-AFTER-TMPFS", str(e))
# ── TP-QBIN-ABSOLUTE: first token after -- is absolute in-tree qbin ──────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3
        argv = json.loads((out/"trace-plan.v1.json").read_text())["planned_argv"]
        qbin_tok = argv[argv.index("--")+1]
        assert qbin_tok.startswith("/rsdd/rt/") and "qemu-system-" in qbin_tok, \
            f"qbin not absolute in-tree: {qbin_tok!r}"
        ok("TP-QBIN-ABSOLUTE: trace qbin token after '--' is absolute in-tree path")
    except Exception as e: nok("TP-QBIN-ABSOLUTE", str(e))
# ── TP-KERNEL-INTREE: default -kernel is /rsdd/rt/vmlinuz when --qemu-root ────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3
        argv = json.loads((out/"trace-plan.v1.json").read_text())["planned_argv"]
        k_idx = argv.index("-kernel")
        assert argv[k_idx+1].startswith("/rsdd/rt/"), \
            f"default kernel must be in-tree: {argv[k_idx+1]!r}"
        ok("TP-KERNEL-INTREE: trace default -kernel is under /rsdd/rt when --qemu-root")
    except Exception as e: nok("TP-KERNEL-INTREE", str(e))

# ── TP-BROAD-WARN: broad --qemu-root dirs → WARNING on stderr; exit code unchanged ───────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN)
    for broad in ["/", "/usr", "/lib", "/lib64", "/bin", "/sbin", "/etc"]:
        out = R/f"out_{broad.lstrip('/') or 'root'}"
        try:
            r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                    "--qemu-root",broad)
            assert r.returncode == 3, f"{broad}: exit code {r.returncode} (expected 3)"
            assert "WARNING" in r.stderr, (
                f"{broad}: no WARNING in stderr; got: {r.stderr[:300]}"
            )
            ok(f"TP-BROAD-WARN {broad}: WARNING on stderr; exit code unchanged (3)")
        except Exception as e: nok(f"TP-BROAD-WARN {broad}", str(e))
# ── TP-BROAD-NOWARN: non-broad --qemu-root → no WARNING on stderr ────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3, f"got {r.returncode}"
        assert "WARNING" not in r.stderr, (
            f"unexpected WARNING in stderr for narrow --qemu-root: {r.stderr[:200]}"
        )
        ok("TP-BROAD-NOWARN: --qemu-root /opt/rsdd/rt → no WARNING on stderr")
    except Exception as e: nok("TP-BROAD-NOWARN", str(e))

# ── TP-RTMOUNT-MOUNTPLAN: mount_plan has runtime_tree_ro when --qemu-root given ─────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3, f"got {r.returncode}; stderr={r.stderr[:200]}"
        mp = json.loads((out/"trace-plan.v1.json").read_text())["mount_plan"]
        assert "runtime_tree_ro" in mp, f"mount_plan missing runtime_tree_ro; keys={list(mp)}"
        assert mp["runtime_tree_ro"] == "/rsdd/rt", f"runtime_tree_ro={mp['runtime_tree_ro']!r}"
        ok("TP-RTMOUNT-MOUNTPLAN: mount_plan has runtime_tree_ro='/rsdd/rt' when --qemu-root")
    except Exception as e: nok("TP-RTMOUNT-MOUNTPLAN", str(e))
# ── TP-RTMOUNT-MOUNTPLAN-ABSENT: mount_plan omits runtime_tree_ro without --qemu-root ───
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out))
        assert r.returncode == 3, f"got {r.returncode}"
        mp = json.loads((out/"trace-plan.v1.json").read_text())["mount_plan"]
        assert "runtime_tree_ro" not in mp, (
            f"mount_plan must NOT contain runtime_tree_ro when --qemu-root absent; got {mp}"
        )
        ok("TP-RTMOUNT-MOUNTPLAN-ABSENT: mount_plan omits runtime_tree_ro when --qemu-root absent")
    except Exception as e: nok("TP-RTMOUNT-MOUNTPLAN-ABSENT", str(e))

# ── TP-BROAD-WARN-ROOT: /root triggers warning (issue #98, item 1) ───────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out_root"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","/root")
        assert r.returncode == 3, f"got {r.returncode}"
        assert "WARNING" in r.stderr, f"no WARNING for /root; stderr={r.stderr[:200]}"
        ok("TP-BROAD-WARN-ROOT: --qemu-root /root → WARNING on stderr (issue #98 item 1)")
    except Exception as e: nok("TP-BROAD-WARN-ROOT", str(e))

# ── TP-BROAD-WARN-EXIT0: WARNING on stderr AND stdout is pure JSON on exit 0 (issue #98, item 2)
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out_e0"
    stub = R/"stub.py"
    stub.write_text("def execute(p): return {'outcome': 'dry-run-stub', 'plan': p}\n")
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","/usr","--allow-exec",
                xe={"RSDD_EXEC_EXECUTOR": str(stub)})
        assert r.returncode == 0, f"expected exit 0 with stub; got {r.returncode}; stderr={r.stderr[:200]}"
        assert "WARNING" in r.stderr, f"WARNING missing on exit-0 path; stderr={r.stderr[:200]}"
        parsed = json.loads(r.stdout)
        assert isinstance(parsed, dict), "stdout is not a JSON object"
        ok("TP-BROAD-WARN-EXIT0: exit-0 path → WARNING on stderr + stdout is pure JSON")
    except Exception as e: nok("TP-BROAD-WARN-EXIT0", str(e))

# ── TP-CAPS-BEFORE-WARN: broad --qemu-root warning emitted even when caps invalid (issue #98, item 3)
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out_caps"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","/usr","--cpu-seconds","0")
        assert r.returncode == 2, f"expected exit 2 (cap error); got {r.returncode}"
        assert "WARNING" in r.stderr, f"WARNING not in stderr despite broad --qemu-root; stderr={r.stderr[:300]}"
        ok("TP-CAPS-BEFORE-WARN: broad --qemu-root warning emitted before cap validation (issue #98 item 3)")
    except Exception as e: nok("TP-CAPS-BEFORE-WARN", str(e))

# ── TP-EMPTY-QEMU-ROOT: empty --qemu-root → explicit reject (exit 2) (issue #98, item 4)
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(_BIN); out = R/"out_empty"
    try:
        r = cli("plan","--target",str(t),"--tracer","strace","--output",str(out),
                "--qemu-root","")
        assert r.returncode == 2, f"expected exit 2 for empty --qemu-root; got {r.returncode}"
        assert "empty" in r.stderr.lower(), f"expected 'empty' rejection msg; stderr={r.stderr[:200]}"
        ok("TP-EMPTY-QEMU-ROOT: empty --qemu-root → exit 2 with explicit rejection (issue #98 item 4)")
    except Exception as e: nok("TP-EMPTY-QEMU-ROOT", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
