#!/usr/bin/env bash
# fact-plan.test.sh — RED-first contract tests for fact-plan.v1 (U-D18 / item 18)
# Written BEFORE fact_plan.py; suite exits 2 ("SUT not found") until GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../fact_plan.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
import hashlib, importlib.util, json, os, subprocess, sys, tempfile, unittest.mock
from pathlib import Path
sut = Path(sys.argv[1])
sp = importlib.util.spec_from_file_location("fact_plan", sut)
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
# ── T1: dry-run NEVER runs docker/compose; plan+det written; no subprocess ──────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16); out = R/"out"
    try:
        with unittest.mock.patch("subprocess.Popen", side_effect=AssertionError("Popen!")), \
             unittest.mock.patch("subprocess.run",   side_effect=AssertionError("run!")):
            rc = m.plan_fact(m._parser(["plan","--firmware",str(fw),"--output",str(out)]))
        assert rc == 3, f"expected 3, got {rc}"
        produced = {p.name for p in out.iterdir()} if out.exists() else set()
        assert "fact-plan.v1.json" in produced, f"plan missing; got {produced}"
        assert "vm-determinism.v1.json" in produced, "det missing"
        assert not hasattr(m, "socket"), "module must not import socket"
        ok("T1: dry-run never runs docker/compose; plan+det written; no subprocess; no socket")
    except Exception as e: nok("T1: dry-run-never-runs-docker", str(e))
# ── T2: flag absent → exit 3; T3: --allow-docker + no executor → exit 2 ─────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16); out = R/"out"
    try:
        r = cli("plan","--firmware",str(fw),"--output",str(out))
        assert r.returncode == 3, f"got {r.returncode}"
        ok("T2: flag absent → exit 3 (authorization-required)")
    except Exception as e: nok("T2: flag-absent-exit3", str(e))
    try:
        r = cli("plan","--firmware",str(fw),"--output",str(out),
                "--allow-docker", xe={"RSDD_DOCKER_EXECUTOR": ""})
        assert r.returncode == 2, f"got {r.returncode}\n{r.stderr[:120]}"
        ok("T3: --allow-docker + no executor → exit 2 (gate hard-refuse)")
    except Exception as e: nok("T3: allow-docker-hard-refuse", str(e))
# ── T4: well-formed → compose argv; NO --network host; NO --privileged; internal-bridge ─
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16); out = R/"out"
    try:
        rc = m.plan_fact(m._parser([
            "plan","--firmware",str(fw),"--project-name","testproject",
            "--frontend-tag","fkiecad/fact_frontend:v4.0",
            "--backend-tag","fkiecad/fact_core:v4.0","--db-tag","fkiecad/fact_db:v4.0",
            "--output",str(out),
        ]))
        assert rc == 3
        p = json.loads((out/"fact-plan.v1.json").read_text())
        assert p["schema_version"] == "fact-plan.v1"
        argv = p["deployment"]["planned_argv"]
        assert isinstance(argv, list) and all(isinstance(a, str) for a in argv)
        assert argv[0] == "docker" and argv[1] == "compose" and "up" in argv and "-d" in argv
        assert "testproject" in argv and p["deployment"]["image_tags"]["frontend"] == "fkiecad/fact_frontend:v4.0"
        assert "--privileged" not in argv, f"--privileged in argv"
        assert "--network" not in argv, f"--network in argv (must use internal bridge by default)"
        assert p["network"] == "internal-bridge", f"network={p['network']!r}"
        sub = p["submission"]
        assert sub["mode"] == "rest-api" and sub["firmware_sha256"] == p["firmware"]["sha256"]
        assert p["persistent_storage"]["scope"] == "compose-project-scoped"
        ok("T4: compose argv; no --network host; no --privileged; internal-bridge; submission plan")
    except Exception as e: nok("T4: well-formed-plan", str(e))
# ── T5: image-tag injection → exit 2, no traceback ───────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16)
    for label, form in [
        ("semicolon",    ["plan","--firmware",str(fw),"--frontend-tag","img; rm -rf /","--output",str(R/"o1")]),
        ("leading-dash", ["plan","--firmware",str(fw),"--frontend-tag=--evil",         "--output",str(R/"o2")]),
        ("dollar",       ["plan","--firmware",str(fw),"--backend-tag","fact$HOME",      "--output",str(R/"o3")]),
    ]:
        try:
            r = cli(*form)
            assert r.returncode == 2 and "Traceback" not in r.stderr, f"{label}: rc={r.returncode}"
            ok(f"T5-{label}: image-tag injection rejected → exit 2, no traceback")
        except Exception as e: nok(f"T5-{label}: image-tag-injection", str(e))
# ── T6: project-name injection → exit 2, no traceback ────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16)
    for label, form in [
        ("semicolon",    ["plan","--firmware",str(fw),"--project-name","proj; evil","--output",str(R/"p1")]),
        ("leading-dash", ["plan","--firmware",str(fw),"--project-name=--evil",     "--output",str(R/"p2")]),
        ("space",        ["plan","--firmware",str(fw),"--project-name","bad proj",  "--output",str(R/"p3")]),
    ]:
        try:
            r = cli(*form)
            assert r.returncode == 2 and "Traceback" not in r.stderr, f"{label}: rc={r.returncode}"
            ok(f"T6-{label}: project-name injection rejected → exit 2, no traceback")
        except Exception as e: nok(f"T6-{label}: project-name-injection", str(e))
# ── T7: firmware symlink/missing → exit 2, no traceback (O_NOFOLLOW) ─────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); real = R/"real.bin"; real.write_bytes(b"\x7fELF" + b"\x00"*16)
    link = R/"link.bin"; link.symlink_to(real); out = R/"out"
    for label, target in [("symlink", str(link)), ("missing", str(R/"gone.bin"))]:
        try:
            r = cli("plan","--firmware",target,"--output",str(out))
            assert r.returncode == 2 and "Traceback" not in r.stderr, f"{label}: rc={r.returncode}"
            ok(f"T7-{label}: firmware {label} → exit 2, no traceback (O_NOFOLLOW guard)")
        except Exception as e: nok(f"T7-{label}: firmware-{label}", str(e))
# ── T8: output under /home → bind-scope exit 2 ───────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16)
    try:
        r = cli("plan","--firmware",str(fw),"--output","/home/fact-plan-unsafe")
        assert r.returncode == 2, f"got {r.returncode}"
        ok("T8: output under /home → exit 2 (bind-scope guard)")
    except Exception as e: nok("T8: bind-path-safety", str(e))
# ── T9: same input → identical plan; det declared:false, basis:dry-run-plan ──────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16)
    out1 = R/"r1"; out2 = R/"r2"
    try:
        m.plan_fact(m._parser(["plan","--firmware",str(fw),"--output",str(out1)]))
        m.plan_fact(m._parser(["plan","--firmware",str(fw),"--output",str(out2)]))
        p1 = json.loads((out1/"fact-plan.v1.json").read_text())
        p2 = json.loads((out2/"fact-plan.v1.json").read_text())
        assert p1 == p2, "plans differ"
        det = json.loads((out1/"vm-determinism.v1.json").read_text())
        assert det["reproducible"]["declared"] is False and det["reproducible"]["basis"] == "dry-run-plan"
        assert det["receipt_identity"] is None
        ok("T9: same input → identical plan; det declared:false, basis:dry-run-plan")
    except Exception as e: nok("T9: determinism-record", str(e))
# ── T10: firmware path ':' or ',' → exit 2, no plan written (U-D17 lesson) ───────
with tempfile.TemporaryDirectory() as td:
    R = Path(td)
    for delim, dname in [("colon", "fw:evil"), ("comma", "fw,evil")]:
        bad_dir = R/dname; bad_dir.mkdir()
        fw = bad_dir/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16); out = R/f"out-{delim}"
        try:
            r = cli("plan","--firmware",str(fw),"--output",str(out))
            assert r.returncode == 2 and "Traceback" not in r.stderr
            assert "':'" in r.stderr or "','" in r.stderr or "bind-mount" in r.stderr
            assert not (out/"fact-plan.v1.json").exists(), f"{delim}: plan must not be written"
            ok(f"T10-{delim}: firmware path with '{delim}' → exit 2, no plan written")
        except Exception as e: nok(f"T10-{delim}: firmware-{delim}-path", str(e))
# ── T11: compose-file path ':' or ',' → exit 2, no traceback (U-D17 lesson) ─────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16)
    for delim, bad_cf in [("colon", "/tmp/bad:path/docker-compose.yml"),
                           ("comma", "/tmp/bad,path/docker-compose.yml")]:
        try:
            r = cli("plan","--firmware",str(fw),"--compose-file",bad_cf,"--output",str(R/f"cf-{delim}"))
            assert r.returncode == 2 and "Traceback" not in r.stderr, f"cf-{delim}: rc={r.returncode}"
            ok(f"T11-{delim}: compose-file path with '{delim}' → exit 2, no traceback")
        except Exception as e: nok(f"T11-{delim}: compose-file-{delim}", str(e))
# ── T12: plugin injection → exit 2, no traceback ─────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); fw = R/"fw.bin"; fw.write_bytes(b"FIRM" + b"\x00"*16)
    for label, form in [
        ("semicolon",    ["plan","--firmware",str(fw),"--plugin","plug; evil","--output",str(R/"g1")]),
        ("leading-dash", ["plan","--firmware",str(fw),"--plugin=--evil",     "--output",str(R/"g2")]),
        ("space",        ["plan","--firmware",str(fw),"--plugin","bad plugin","--output",str(R/"g3")]),
    ]:
        try:
            r = cli(*form)
            assert r.returncode == 2 and "Traceback" not in r.stderr, f"{label}: rc={r.returncode}"
            ok(f"T12-{label}: plugin injection rejected → exit 2, no traceback")
        except Exception as e: nok(f"T12-{label}: plugin-injection", str(e))
# ── T13: submission sha256 matches firmware identity ──────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); content = b"DEADBEEF" * 32; fw = R/"fw.bin"; fw.write_bytes(content); out = R/"out"
    try:
        m.plan_fact(m._parser(["plan","--firmware",str(fw),"--output",str(out)]))
        p = json.loads((out/"fact-plan.v1.json").read_text())
        expected = "sha256:" + hashlib.sha256(content).hexdigest()
        assert p["firmware"]["sha256"] == expected and p["submission"]["firmware_sha256"] == expected
        ok("T13: submission sha256 matches firmware identity")
    except Exception as e: nok("T13: submission-sha256-identity", str(e))
print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
