#!/usr/bin/env bash
# emba-plan.test.sh — RED-first contract tests for emba-plan.v1 (U-D17 / item 17)
# Written BEFORE emba_plan.py; suite exits 2 ("SUT not found") until GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../emba_plan.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
import importlib.util, json, os, subprocess, sys, tempfile, unittest.mock
from pathlib import Path
sut = Path(sys.argv[1])
sp = importlib.util.spec_from_file_location("emba_plan", sut)
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

# ── T1: dry-run NEVER runs docker; plan+det written; no subprocess; no socket ─
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16); out = R/"out"
    try:
        with unittest.mock.patch("subprocess.Popen", side_effect=AssertionError("Popen!")), \
             unittest.mock.patch("subprocess.run",   side_effect=AssertionError("run!")):
            rc = m.plan_emba(m._parser(["plan","--firmware",str(fw),"--output",str(out)]))
        assert rc == 3, f"expected 3, got {rc}"
        produced = {p.name for p in out.iterdir()} if out.exists() else set()
        assert "emba-plan.v1.json" in produced, f"plan missing; got {produced}"
        assert "vm-determinism.v1.json" in produced, "det missing"
        assert not hasattr(m, "socket"), "module must not import socket"
        ok("T1: dry-run never runs docker; plan+det written; no subprocess; no socket")
    except Exception as e: nok("T1: dry-run-never-runs-docker", str(e))

# ── T2: flag absent → exit 3 (authorization-required), zero side effects ──────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--firmware",str(fw),"--output",str(out))
        assert r.returncode == 3, f"got {r.returncode}"
        ok("T2: flag absent → exit 3 (authorization-required)")
    except Exception as e: nok("T2: flag-absent-exit3", str(e))

# ── T3: --allow-docker + no executor → exit 2 (gate hard-refuse) ──────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--firmware",str(fw),"--output",str(out),
                "--allow-docker", xe={"RSDD_DOCKER_EXECUTOR": ""})
        assert r.returncode == 2, f"got {r.returncode}\n{r.stderr[:120]}"
        ok("T3: --allow-docker + no executor → exit 2 (gate hard-refuse)")
    except Exception as e: nok("T3: allow-docker-hard-refuse", str(e))

# ── T4: well-formed → correct docker argv; NO --privileged; privilege as data ──
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16); out = R/"out"
    try:
        rc = m.plan_emba(m._parser([
            "plan","--firmware",str(fw),"--image-tag","embeddedanalyzer/emba:v1.4",
            "--cpus","2","--memory","4g","--pids-limit","256","--output",str(out),
        ]))
        assert rc == 3
        p = json.loads((out/"emba-plan.v1.json").read_text())
        assert p["schema_version"] == "emba-plan.v1", f"schema={p['schema_version']!r}"
        argv = p["planned_argv"]
        assert isinstance(argv, list) and all(isinstance(a, str) for a in argv)
        assert argv[0] == "docker" and "--rm" in argv
        assert "embeddedanalyzer/emba:v1.4" in argv
        # resource limits present as discrete elements
        assert "--cpus" in argv and "--memory" in argv and "--pids-limit" in argv
        # firmware mounted read-only
        assert any(a.endswith(":/firmware:ro") for a in argv), f"no :ro mount; {argv}"
        # network isolation
        ni = argv.index("--network"); assert argv[ni + 1] == "none", f"network={argv[ni+1]!r}"
        # writable output to /tmp/rsdd
        assert any("/tmp/rsdd" in a for a in argv), f"no /tmp/rsdd mount; {argv}"
        # NO blanket --privileged
        assert "--privileged" not in argv, f"--privileged found in argv: {argv}"
        # privilege requirement recorded as data, not enabled
        pr = p.get("privilege_requirement", {})
        assert pr.get("requires_privileged") is True, "privilege_requirement missing"
        assert pr.get("status") == "refused-in-plan", f"status={pr.get('status')!r}"
        ok("T4: correct docker argv; no --privileged; privilege requirement as data")
    except Exception as e: nok("T4: well-formed-plan-argv", str(e))

# ── T5: image-tag injection (metacharacters, leading dash) → exit 2, no traceback
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16)
    for label, form in [
        ("semicolon",    ["plan","--firmware",str(fw),"--image-tag","emba; rm -rf /","--output",str(R/"o1")]),
        ("pipe",         ["plan","--firmware",str(fw),"--image-tag","emba|evil",     "--output",str(R/"o2")]),
        ("dollar",       ["plan","--firmware",str(fw),"--image-tag","emba$HOME",      "--output",str(R/"o3")]),
        ("leading-dash", ["plan","--firmware",str(fw),"--image-tag=--evil-tag",       "--output",str(R/"o4")]),
    ]:
        try:
            r = cli(*form)
            assert r.returncode == 2, f"{label}: got {r.returncode}"
            assert "Traceback" not in r.stderr, f"{label}: traceback in stderr"
            ok(f"T5-{label}: image-tag injection rejected → exit 2, no traceback")
        except Exception as e: nok(f"T5-{label}: image-tag-injection", str(e))

# ── T6: profile injection → exit 2, no traceback ─────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16)
    for label, form in [
        ("semicolon",    ["plan","--firmware",str(fw),"--profile","prof; evil","--output",str(R/"p1")]),
        ("leading-dash", ["plan","--firmware",str(fw),"--profile=--evil",     "--output",str(R/"p2")]),
        ("space",        ["plan","--firmware",str(fw),"--profile","bad prof",  "--output",str(R/"p3")]),
    ]:
        try:
            r = cli(*form)
            assert r.returncode == 2, f"{label}: got {r.returncode}"
            assert "Traceback" not in r.stderr, f"{label}: traceback in stderr"
            ok(f"T6-{label}: profile injection rejected → exit 2, no traceback")
        except Exception as e: nok(f"T6-{label}: profile-injection", str(e))

# ── T7: firmware symlink/missing → exit 2, no traceback (O_NOFOLLOW) ─────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); real = R/"real.bin"; real.write_bytes(b"\x7fELF" + b"\x00"*16)
    link = R/"link.bin"; link.symlink_to(real); out = R/"out"
    for label, target in [("symlink", str(link)), ("missing", str(R/"gone.bin"))]:
        try:
            r = cli("plan","--firmware",target,"--output",str(out))
            assert r.returncode == 2, f"{label}: got {r.returncode}"
            assert "Traceback" not in r.stderr, f"{label}: traceback in stderr"
            ok(f"T7-{label}: firmware {label} → exit 2, no traceback (O_NOFOLLOW guard)")
        except Exception as e: nok(f"T7-{label}: firmware-{label}", str(e))

# ── T8: output under /home → bind-scope exit 2 ───────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16)
    try:
        r = cli("plan","--firmware",str(fw),"--output","/home/emba-plan-unsafe")
        assert r.returncode == 2, f"got {r.returncode}"
        ok("T8: output under /home → exit 2 (bind-scope guard)")
    except Exception as e: nok("T8: bind-path-safety", str(e))

# ── T9: same input → identical plan; det declared:false, basis:dry-run-plan ───
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16)
    out1 = R/"r1"; out2 = R/"r2"
    try:
        m.plan_emba(m._parser(["plan","--firmware",str(fw),"--output",str(out1)]))
        m.plan_emba(m._parser(["plan","--firmware",str(fw),"--output",str(out2)]))
        p1 = json.loads((out1/"emba-plan.v1.json").read_text())
        p2 = json.loads((out2/"emba-plan.v1.json").read_text())
        assert p1 == p2, "plans differ — not deterministic"
        det = json.loads((out1/"vm-determinism.v1.json").read_text())
        assert det["reproducible"]["declared"] is False
        assert det["reproducible"]["basis"] == "dry-run-plan"
        assert det["receipt_identity"] is None
        ok("T9: same input → identical plan; det declared:false, basis:dry-run-plan")
    except Exception as e: nok("T9: determinism-record", str(e))

# ── T10: firmware path with ':' → exit 2, no traceback, no plan written ───────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); bad_dir = R/"fw:evil"; dir_ok = False
    try: bad_dir.mkdir(); dir_ok = True
    except OSError: pass
    if dir_ok:
        fw = bad_dir/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16); out = R/"out"
        try:
            r = cli("plan","--firmware",str(fw),"--output",str(out))
            assert r.returncode == 2, f"got {r.returncode}"
            assert "Traceback" not in r.stderr, "traceback in stderr"
            assert "':'" in r.stderr or "bind-mount" in r.stderr, f"missing rejection msg: {r.stderr[:120]}"
            assert not (out/"emba-plan.v1.json").exists(), "plan file must not be written"
            ok("T10: firmware path with ':' → exit 2, no traceback, no plan written")
        except Exception as e: nok("T10: firmware-colon-path", str(e))
    else:
        try:
            m.build_plan(R/"fw:evil"/"fw.bin","embeddedanalyzer/emba:latest",None,"2","4g",256,3600,input_sha="sha256:abc",input_size=20)
            nok("T10: firmware-colon-path", "EmbaPlanError not raised")
        except m.EmbaPlanError as exc:
            ok("T10: firmware path with ':' → EmbaPlanError (unit fallback)") if "':'" in str(exc) or "bind-mount" in str(exc) else nok("T10", f"wrong msg: {exc}")
        except Exception as exc: nok("T10: firmware-colon-path", str(exc))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
