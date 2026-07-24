#!/usr/bin/env bash
# detonate-plan.test.sh — RED-first contract tests for detonate-plan.v1 (U-V11 / item 11)
# Written BEFORE detonate_plan.py; suite exits 2 ("SUT not found") until GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../detonate_plan.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
import importlib.util, json, os, subprocess, sys, tempfile, unittest.mock
from pathlib import Path
sut = Path(sys.argv[1])
sp = importlib.util.spec_from_file_location("detonate_plan", sut)
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

# ── T1: dry-run NEVER executes; plan+det written; no subprocess; no socket ──────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16); out = R/"out"
    try:
        with unittest.mock.patch("subprocess.Popen", side_effect=AssertionError("Popen!")), \
             unittest.mock.patch("subprocess.run",   side_effect=AssertionError("run!")):
            rc = m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        assert rc == 3, f"expected 3, got {rc}"
        produced = {p.name for p in out.iterdir()} if out.exists() else set()
        assert "detonate-plan.v1.json" in produced and "vm-determinism.v1.json" in produced
        assert not produced - {"detonate-plan.v1.json","vm-determinism.v1.json"}
        assert not hasattr(m, "socket"), "module must not import socket"
        ok("T1: dry-run never executes; plan+det written; no subprocess; no socket")
    except Exception as e: nok("T1: dry-run-never-executes", str(e))

# ── T2: flag absent → exit 3 (authorization-required) ───────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--sample",str(s),"--output",str(out))
        assert r.returncode == 3, f"got {r.returncode}"
        ok("T2: flag absent → exit 3 (authorization-required)")
    except Exception as e: nok("T2: flag-absent-exit3", str(e))

# ── T3: --allow-exec + qemu binary not on PATH → exit 2 (preflight GateError) ───
# D2 wires DetonateVmExecutor. When qemu-system binary is absent → _preflight
# raises GateError → exit 2.  Restrict PATH to an empty temp dir so qemu is gone.
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16); out = R/"out"
    with tempfile.TemporaryDirectory() as empty_bin:
        try:
            r = cli("plan","--sample",str(s),"--output",str(out),
                    "--allow-exec", xe={"RSDD_EXEC_EXECUTOR": "", "PATH": empty_bin})
            assert r.returncode == 2, f"got {r.returncode}\n{r.stderr[:120]}"
            ok("T3: --allow-exec + qemu not on PATH → exit 2 (preflight GateError)")
        except Exception as e: nok("T3: allow-exec-hard-refuse", str(e))

# ── T4: network defaults "none"; non-none refused; mount_plan + snapshot correct ─
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"MZ" + b"\x00"*18)
    out = R/"out"; out2 = R/"out2"
    try:
        rc = m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        assert rc == 3
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        assert p["network"] == "none" and p["network_policy"]["mode"] == "none"
        mp = p["mount_plan"]
        assert mp["sample_ro"] == "/input/sample" and mp["output_writable"] == "/tmp/rsdd/out"
        # C3: host_writable must equal scratch_persistent (not "none" — corrects the false claim
        # that no host path is writable; it IS writable via the scratch file bind).
        assert mp.get("host_writable") == mp.get("scratch_persistent"), (
            f"host_writable {mp.get('host_writable')!r} must equal "
            f"scratch_persistent {mp.get('scratch_persistent')!r}"
        )
        snap = p["snapshot_policy"]
        assert snap["pre_run"]["intent"] == "capture-before-detonation"
        assert snap["post_run"]["intent"] == "capture-after-detonation"
        ok("T4a: network='none'; mount_plan RO; host_writable==scratch_persistent; snapshot pre+post")
    except Exception as e: nok("T4a: network-mount-snapshot", str(e))
    try:
        r = cli("plan","--sample",str(s),"--output",str(out2),"--network","internet")
        assert r.returncode == 2, f"got {r.returncode}"
        ok("T4b: --network internet refused → exit 2 (only 'none' supported)")
    except Exception as e: nok("T4b: non-none-network-refused", str(e))

# ── T4c: planned_argv contains scratch bind triple AFTER --tmpfs (INV-2 / F5) ─
# RED-F5: the scratch file-scoped bind must appear AFTER --tmpfs so it is not
# re-masked.  Ordering is load-bearing (bwrap applies mount ops in argv order).
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"MZ" + b"\x00"*18)
    out3 = R/"out3"
    try:
        rc = m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out3)]))
        assert rc == 3
        p = json.loads((out3/"detonate-plan.v1.json").read_text())
        argv = p["planned_argv"]
        scratch = p["mount_plan"]["scratch_persistent"]
        # The contiguous triple ["--bind", scratch, scratch] must be present
        bind_idx = None
        for i in range(len(argv) - 2):
            if argv[i] == "--bind" and argv[i+1] == scratch and argv[i+2] == scratch:
                bind_idx = i
                break
        assert bind_idx is not None, (
            f"planned_argv missing contiguous ['--bind', {scratch!r}, {scratch!r}]; "
            f"argv={argv}"
        )
        # --tmpfs must appear BEFORE the bind (ordering-aware — bwrap applies in order)
        tmpfs_idx = argv.index("--tmpfs") if "--tmpfs" in argv else None
        assert tmpfs_idx is not None, "--tmpfs missing from planned_argv"
        assert bind_idx > tmpfs_idx, (
            f"--bind {scratch!r} ... at index {bind_idx} must come AFTER "
            f"--tmpfs at index {tmpfs_idx} (re-masking guard)"
        )
        ok("T4c: planned_argv contains scratch --bind triple strictly after --tmpfs (INV-2 / F5)")
    except Exception as e: nok("T4c: scratch-bind-after-tmpfs", str(e))

# ── T5: output /home → bind-scope exit 2; disk=ephemeral; argv has --unshare-net ─
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--sample",str(s),"--output","/home/detonate-unsafe")
        assert r.returncode == 2, f"got {r.returncode}"
        ok("T5a: output under /home → exit 2 (bind-scope guard)")
    except Exception as e: nok("T5a: bind-path-safety", str(e))
    try:
        rc = m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        assert rc == 3
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        # D1 rebuild: disk.mode changed to per-drive-policy (global -snapshot dropped)
        assert p["disk"]["mode"] == "per-drive-policy" and p["disk"]["post_snapshot_capture"]
        argv = p["planned_argv"]
        assert "--unshare-net" in argv and "--cap-drop" in argv and "ALL" in argv
        assert "bwrap" in argv
        # /input/sample now appears inside a -drive value, not as standalone executable
        assert any("/input/sample" in a for a in argv), \
            "/input/sample not found anywhere in planned_argv (should be in -drive value)"
        ok("T5b: disk=per-drive-policy; argv has --unshare-net + --cap-drop ALL; sample in -drive")
    except Exception as e: nok("T5b: disk-argv-containment", str(e))
    try:
        p5c = json.loads((out/"detonate-plan.v1.json").read_text())
        argv5c = p5c["planned_argv"]
        # Fix 1: bwrap prefix MUST include --unshare-ipc, --unshare-uts, --unshare-cgroup
        # (restored — hostile-sample bwrap needs full namespace isolation beyond just net+pid).
        assert "--unshare-ipc" in argv5c, "--unshare-ipc missing from bwrap prefix"
        assert "--unshare-uts" in argv5c, "--unshare-uts missing from bwrap prefix"
        assert "--unshare-cgroup" in argv5c, "--unshare-cgroup missing from bwrap prefix"
        # qemu inner belt
        assert "-accel" in argv5c and argv5c[argv5c.index("-accel")+1] == "tcg", \
            "-accel tcg missing from planned_argv"
        assert "-nic" in argv5c and argv5c[argv5c.index("-nic")+1] == "none", \
            "-nic none missing from planned_argv"
        assert "-smp" in argv5c and argv5c[argv5c.index("-smp")+1] == "1", \
            "-smp 1 missing from planned_argv"
        assert "-nodefaults" in argv5c, "-nodefaults missing from planned_argv"
        assert any(a.startswith("on,") for a in argv5c), \
            "-sandbox on,... value missing from planned_argv"
        ok("T5c: bwrap --unshare-ipc/uts/cgroup present; qemu inner belt: -accel tcg, -nic none, -smp 1, -nodefaults, -sandbox on")
    except Exception as e: nok("T5c: bwrap-ns-ipc-uts-cgroup-and-inner-belt", str(e))

# ── T6: symlink → exit 2, no traceback; missing file → exit 2, no traceback ─────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); real = R/"real.bin"; real.write_bytes(b"\x7fELF" + b"\x00"*16)
    link = R/"link.bin"; link.symlink_to(real); out = R/"out"
    for label, target in [("symlink", str(link)), ("missing", str(R/"gone.bin"))]:
        try:
            r = cli("plan","--sample",target,"--output",str(out))
            assert r.returncode == 2, f"{label}: got {r.returncode}"
            assert "Traceback" not in r.stderr, f"{label}: traceback in stderr"
            ok(f"T6-{label}: exit 2, no traceback (O_NOFOLLOW/missing guard)")
        except Exception as e: nok(f"T6-{label}: clean-error", str(e))

# ── T7: same input → identical plan (determinism); det declared:false ────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"d.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out1 = R/"r1"; out2 = R/"r2"
    try:
        m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out1)]))
        m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out2)]))
        p1 = json.loads((out1/"detonate-plan.v1.json").read_text())
        p2 = json.loads((out2/"detonate-plan.v1.json").read_text())
        assert p1 == p2, "plans differ — not deterministic"
        det = json.loads((out1/"vm-determinism.v1.json").read_text())
        assert det["reproducible"]["declared"] is False
        assert det["reproducible"]["basis"] == "dry-run-plan"
        assert det["receipt_identity"] is None
        ok("T7: same input → identical plan; det declared:false, basis:dry-run-plan")
    except Exception as e: nok("T7: determinism-record-state", str(e))


# ── T_CAP1: --max-input-bytes below sample size → exit 2, clean error, no traceback ──
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*96); out = R/"out"
    # sample is 100 bytes; cap is 5 bytes → must be rejected
    try:
        r = cli("plan","--sample",str(s),"--output",str(out),"--max-input-bytes","5")
        assert r.returncode == 2, f"got {r.returncode}"
        assert "Traceback" not in r.stderr, f"traceback in stderr: {r.stderr[:200]}"
        assert ("exceeds" in r.stderr or "max-input" in r.stderr), \
               f"missing cap rejection message: {r.stderr[:200]}"
        ok("T_CAP1: --max-input-bytes below sample size → exit 2, clean error, no traceback")
    except Exception as e: nok("T_CAP1: cap-below-sample-size", str(e))

# ── T_CAP2: --max-input-bytes above sample size → plan byte-identical to no-flag run ─
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out_capped = R/"out_capped"; out_baseline = R/"out_baseline"
    # sample is 20 bytes; 2 GiB cap is well above → normal plan must be emitted (exit 3)
    try:
        r_capped = cli("plan","--sample",str(s),"--output",str(out_capped),"--max-input-bytes","2147483648")
        assert r_capped.returncode == 3, f"expected 3 (auth-required), got {r_capped.returncode}\n{r_capped.stderr[:200]}"
        r_base = cli("plan","--sample",str(s),"--output",str(out_baseline))
        assert r_base.returncode == 3, f"baseline expected 3, got {r_base.returncode}"
        p_capped = json.loads((out_capped/"detonate-plan.v1.json").read_text())
        p_baseline = json.loads((out_baseline/"detonate-plan.v1.json").read_text())
        assert p_capped == p_baseline, f"plan with above-cap differs from no-flag plan"
        ok("T_CAP2: --max-input-bytes above sample size → plan byte-identical to no-flag")
    except Exception as e: nok("T_CAP2: cap-above-sample-size", str(e))

# ── T_CAP3: no flag → identity byte-identical to baseline (regression guard) ──────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out1 = R/"out1"; out2 = R/"out2"
    try:
        r1 = cli("plan","--sample",str(s),"--output",str(out1))
        r2 = cli("plan","--sample",str(s),"--output",str(out2))
        assert r1.returncode == 3 and r2.returncode == 3, "baseline runs did not exit 3"
        p1 = json.loads((out1/"detonate-plan.v1.json").read_text())
        p2 = json.loads((out2/"detonate-plan.v1.json").read_text())
        assert p1 == p2, "two no-flag runs differ — non-deterministic"
        # check that the sample sha256 field is present (identity ran normally)
        assert p1["sample"]["sha256"].startswith("sha256:"), "sha256 not present in plan"
        ok("T_CAP3: no --max-input-bytes flag → byte-identical baseline (regression guard)")
    except Exception as e: nok("T_CAP3: no-flag-regression", str(e))

# ── T_OSE: OSError from mkdir (output path is an existing file) → exit 2, clean error ──
# RED: before Fix 1, OSError escapes uncaught → Python traceback + exit 1.
# GREEN: after Fix 1, run_adapter_main catches OSError → "detonate-plan: ..." stderr + exit 2.
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    # Block mkdir by creating a regular file at the output path
    out_blocked = R/"out_blocked"
    out_blocked.write_bytes(b"x")  # file, not directory
    try:
        r = cli("plan","--sample",str(s),"--output",str(out_blocked))
        assert r.returncode == 2, \
            f"expected 2 (OSError caught by wrapper), got {r.returncode}\n{r.stderr[:200]}"
        assert "Traceback" not in r.stderr, \
            f"traceback in stderr (wrapper absent):\n{r.stderr[:200]}"
        assert "detonate-plan:" in r.stderr, \
            f"missing 'detonate-plan:' prefix in stderr:\n{r.stderr[:120]}"
        ok("T_OSE: OSError from mkdir blocked by file → exit 2, clean error, no traceback")
    except Exception as e: nok("T_OSE: ose-mkdir-blocked", str(e))


# ── T_DIS1: planned_argv is qemu-system form (not host-bwrap direct exec) ────
# D1 RED: old argv was "bwrap ... -- /input/sample"; new form must have qemu-system.
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out = R/"out"
    try:
        rc = m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        assert rc == 3
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        argv = p["planned_argv"]
        # Must contain a qemu-system-* binary token (not direct host execution)
        qemu_tokens = [t for t in argv if t.startswith("qemu-system-")]
        assert qemu_tokens, f"no qemu-system-* token in planned_argv; got: {argv}"
        # Must contain -drive flag
        assert "-drive" in argv, "-drive flag missing from planned_argv"
        # /input/sample must NOT appear as a standalone executable token
        # (it must only appear embedded in a -drive file= value)
        try:
            raw_idx = argv.index("/input/sample")
            # If found as standalone, it should be preceded by -drive's value --
            # i.e., it must NOT be right after "--" (the bwrap separator)
            sep_idx = argv.index("--") if "--" in argv else -1
            assert raw_idx != sep_idx + 1, \
                "/input/sample is still the direct host executable (rejected host-exec form)"
        except ValueError:
            pass  # /input/sample not standalone — correct; it's in a -drive value
        ok("T_DIS1: planned_argv is qemu-system form (not host-bwrap direct exec)")
    except Exception as e: nok("T_DIS1: qemu-system-form", str(e))

# ── T_DIS2: all -drive values have format=raw ─────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out = R/"out"
    try:
        m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        argv = p["planned_argv"]
        drive_values = [argv[i+1] for i, t in enumerate(argv)
                        if t == "-drive" and i+1 < len(argv)]
        assert drive_values, "no -drive values found in planned_argv"
        for dv in drive_values:
            assert "format=raw" in dv, \
                f"-drive value missing format=raw: {dv!r}"
        ok("T_DIS2: all -drive values contain format=raw")
    except Exception as e: nok("T_DIS2: all-drives-format-raw", str(e))

# ── T_DIS3: sample drive is readonly=on,snapshot=off ─────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out = R/"out"
    try:
        m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        argv = p["planned_argv"]
        drive_values = [argv[i+1] for i, t in enumerate(argv)
                        if t == "-drive" and i+1 < len(argv)]
        sample_drives = [d for d in drive_values if "/input/sample" in d]
        assert sample_drives, "no /input/sample drive found in planned_argv"
        sd = sample_drives[0]
        assert "readonly=on" in sd, f"sample drive missing readonly=on: {sd!r}"
        assert "snapshot=off" in sd, f"sample drive missing snapshot=off: {sd!r}"
        ok("T_DIS3: sample drive has readonly=on + snapshot=off")
    except Exception as e: nok("T_DIS3: sample-drive-readonly", str(e))

# ── T_DIS4: rootfs drive is snapshot=on (COW — ephemeral writes) ──────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out = R/"out"
    try:
        m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        argv = p["planned_argv"]
        drive_values = [argv[i+1] for i, t in enumerate(argv)
                        if t == "-drive" and i+1 < len(argv)]
        rootfs_drives = [d for d in drive_values if "/input/rootfs" in d]
        assert rootfs_drives, "no /input/rootfs drive found in planned_argv"
        rd = rootfs_drives[0]
        assert "snapshot=on" in rd, \
            f"rootfs drive must be snapshot=on (COW); got: {rd!r}"
        ok("T_DIS4: rootfs drive has snapshot=on (COW, ephemeral)")
    except Exception as e: nok("T_DIS4: rootfs-drive-cow", str(e))

# ── T_DIS5: scratch drive has snapshot=off (writes persist for host reading) ──
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out = R/"out"
    try:
        m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        argv = p["planned_argv"]
        drive_values = [argv[i+1] for i, t in enumerate(argv)
                        if t == "-drive" and i+1 < len(argv)]
        # scratch is the one drive that is NOT /input/sample and NOT /input/rootfs
        scratch_drives = [d for d in drive_values
                          if "/input/sample" not in d and "/input/rootfs" not in d]
        assert scratch_drives, "no scratch drive found (expected exactly one non-input drive)"
        sd = scratch_drives[0]
        assert "snapshot=off" in sd, \
            f"scratch drive must be snapshot=off (persistent); got: {sd!r}"
        ok("T_DIS5: scratch drive has snapshot=off (host reads post-teardown)")
    except Exception as e: nok("T_DIS5: scratch-drive-persistent", str(e))

# ── T_DIS6: planned_argv passes vm_disk_policy.check_disk_policy ─────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out = R/"out"
    try:
        m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        argv = p["planned_argv"]
        # Import vm_disk_policy for the plan-level check (no run_dir at plan time)
        import importlib.util as _ilu
        _vdp_path = sut.parent / "lib" / "vm_disk_policy.py"
        _vdp_sp = _ilu.spec_from_file_location("vm_disk_policy", _vdp_path)
        _vdp = _ilu.module_from_spec(_vdp_sp); _vdp_sp.loader.exec_module(_vdp)
        _vdp.check_disk_policy(argv)  # no run_dir (plan-level check)
        ok("T_DIS6: plan's planned_argv passes vm_disk_policy.check_disk_policy")
    except Exception as e: nok("T_DIS6: plan-passes-disk-policy", str(e))

# ── T_DIS7: no global -snapshot flag in detonate planned_argv ─────────────────
# Design §4: global -snapshot DROPPED; per-drive policy replaces it.
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out = R/"out"
    try:
        m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        argv = p["planned_argv"]
        assert "-snapshot" not in argv, \
            "global -snapshot must NOT appear in detonate planned_argv (per-drive policy replaces it)"
        ok("T_DIS7: global -snapshot absent (per-drive policy in use)")
    except Exception as e: nok("T_DIS7: no-global-snapshot", str(e))

# ── T_DIS8: disk.mode reflects per-drive policy ───────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out = R/"out"
    try:
        m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        assert p["disk"]["mode"] == "per-drive-policy", \
            f"disk.mode should be 'per-drive-policy', got {p['disk']['mode']!r}"
        assert p["disk"]["post_snapshot_capture"] is True, \
            "disk.post_snapshot_capture must be True"
        ok("T_DIS8: disk.mode='per-drive-policy' and post_snapshot_capture=True")
    except Exception as e: nok("T_DIS8: disk-mode-per-drive-policy", str(e))

# ── T_DIS9: plan has arch and qemu_binary fields ──────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"sample.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16)
    out = R/"out"
    try:
        m.plan_detonate(m._parser(["plan","--sample",str(s),"--output",str(out)]))
        p = json.loads((out/"detonate-plan.v1.json").read_text())
        assert "arch" in p, "plan missing 'arch' field"
        assert "qemu_binary" in p, "plan missing 'qemu_binary' field"
        assert p["qemu_binary"].startswith("qemu-system-"), \
            f"qemu_binary should start with 'qemu-system-'; got {p['qemu_binary']!r}"
        ok("T_DIS9: plan has 'arch' and 'qemu_binary' (qemu-system-*) fields")
    except Exception as e: nok("T_DIS9: arch-and-qemu-binary", str(e))

# ── T-RTMOUNT — runtime-tree bind tests (gaps 1/3/4) ────────────────────────────
# RED: --qemu-root unknown → rc=2. GREEN: rt bind + absolute qbin + in-tree kernel.
# ── T-RTMOUNT: plan has --ro-bind <src> /rsdd/rt when --qemu-root given ────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--sample",str(s),"--output",str(out),"--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3, f"got {r.returncode}; stderr={r.stderr[:200]}"
        argv = json.loads((out/"detonate-plan.v1.json").read_text())["planned_argv"]
        rt_dest = "/rsdd/rt"
        rt_idx = next((i for i in range(len(argv)-2)
                       if argv[i]=="--ro-bind" and argv[i+2]==rt_dest), None)
        assert rt_idx is not None, f"no --ro-bind ... {rt_dest!r} in argv"
        assert argv[rt_idx+1] == "/opt/rsdd/rt", f"SRC != /opt/rsdd/rt; got {argv[rt_idx+1]!r}"
        ok("T-RTMOUNT: --qemu-root → planned_argv has --ro-bind /opt/rsdd/rt /rsdd/rt")
    except Exception as e: nok("T-RTMOUNT", str(e))
# ── T-RTMOUNT-RO: runtime tree bind is --ro-bind (NOT --bind) ───────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--sample",str(s),"--output",str(out),"--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3
        argv = json.loads((out/"detonate-plan.v1.json").read_text())["planned_argv"]
        rw = [(argv[i+1],argv[i+2]) for i in range(len(argv)-2) if argv[i]=="--bind"]
        assert all(dst != "/rsdd/rt" for _,dst in rw), \
            f"runtime tree bind must be --ro-bind, not --bind: {rw}"
        ok("T-RTMOUNT-RO: runtime tree bind is --ro-bind (read-only)")
    except Exception as e: nok("T-RTMOUNT-RO", str(e))
# ── T-RTMOUNT-AFTER-TMPFS: rt bind is after --tmpfs (INV-2 ordering) ────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--sample",str(s),"--output",str(out),"--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3
        argv = json.loads((out/"detonate-plan.v1.json").read_text())["planned_argv"]
        tmpfs_i = argv.index("--tmpfs")
        rt_i = next(i for i in range(len(argv)-2) if argv[i]=="--ro-bind" and argv[i+2]=="/rsdd/rt")
        assert rt_i > tmpfs_i, f"rt bind at {rt_i} must be after --tmpfs at {tmpfs_i}"
        ok("T-RTMOUNT-AFTER-TMPFS: rt bind is after --tmpfs (INV-2 / ordering)")
    except Exception as e: nok("T-RTMOUNT-AFTER-TMPFS", str(e))
# ── T-QBIN-ABSOLUTE: first token after -- is absolute in-tree qbin ───────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--sample",str(s),"--output",str(out),"--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3
        argv = json.loads((out/"detonate-plan.v1.json").read_text())["planned_argv"]
        sep_i = argv.index("--"); qbin_tok = argv[sep_i+1]
        assert qbin_tok.startswith("/rsdd/rt/"), f"qbin not absolute in-tree: {qbin_tok!r}"
        assert "qemu-system-" in qbin_tok, f"qbin missing 'qemu-system-': {qbin_tok!r}"
        ok("T-QBIN-ABSOLUTE: qbin token after '--' is absolute in-tree path under /rsdd/rt")
    except Exception as e: nok("T-QBIN-ABSOLUTE", str(e))
# ── T-KERNEL-INTREE: default -kernel is /rsdd/rt/vmlinuz when --qemu-root ────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--sample",str(s),"--output",str(out),"--qemu-root","/opt/rsdd/rt")
        assert r.returncode == 3
        argv = json.loads((out/"detonate-plan.v1.json").read_text())["planned_argv"]
        k_idx = argv.index("-kernel") if "-kernel" in argv else None
        assert k_idx is not None, "-kernel missing from argv"
        assert argv[k_idx+1].startswith("/rsdd/rt/"), \
            f"default kernel must be in-tree when --qemu-root: {argv[k_idx+1]!r}"
        ok("T-KERNEL-INTREE: default -kernel is under /rsdd/rt when --qemu-root given")
    except Exception as e: nok("T-KERNEL-INTREE", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
