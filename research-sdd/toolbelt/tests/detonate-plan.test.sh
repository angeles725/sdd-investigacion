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

# ── T3: --allow-exec + no live executor → exit 2 (gate hard-refuse) ─────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); s = R/"s.bin"; s.write_bytes(b"\x7fELF" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--sample",str(s),"--output",str(out),
                "--allow-exec", xe={"RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 2, f"got {r.returncode}\n{r.stderr[:120]}"
        ok("T3: --allow-exec + no live executor → exit 2 (gate hard-refuse)")
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
        assert mp.get("host_writable") == "none"
        snap = p["snapshot_policy"]
        assert snap["pre_run"]["intent"] == "capture-before-detonation"
        assert snap["post_run"]["intent"] == "capture-after-detonation"
        ok("T4a: network='none'; mount_plan RO; snapshot_policy pre+post")
    except Exception as e: nok("T4a: network-mount-snapshot", str(e))
    try:
        r = cli("plan","--sample",str(s),"--output",str(out2),"--network","internet")
        assert r.returncode == 2, f"got {r.returncode}"
        ok("T4b: --network internet refused → exit 2 (only 'none' supported)")
    except Exception as e: nok("T4b: non-none-network-refused", str(e))

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
        assert p["disk"]["mode"] == "ephemeral-snapshot" and p["disk"]["post_snapshot_capture"]
        argv = p["planned_argv"]
        assert "--unshare-net" in argv and "--cap-drop" in argv and "ALL" in argv
        assert "bwrap" in argv and "/input/sample" in argv
        ok("T5b: disk=ephemeral-snapshot; argv has --unshare-net + --cap-drop ALL")
    except Exception as e: nok("T5b: disk-argv-containment", str(e))
    try:
        p5c = json.loads((out/"detonate-plan.v1.json").read_text())
        argv5c = p5c["planned_argv"]
        assert "--unshare-ipc" in argv5c, "--unshare-ipc missing from planned_argv"
        assert "--unshare-uts" in argv5c, "--unshare-uts missing from planned_argv"
        assert "--unshare-cgroup" in argv5c, "--unshare-cgroup missing from planned_argv"
        ok("T5c: argv has --unshare-ipc + --unshare-uts + --unshare-cgroup (namespace isolation)")
    except Exception as e: nok("T5c: namespace-isolation-flags", str(e))

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

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
