#!/usr/bin/env bash
# vm-run.test.sh — RED-first contract tests for vm-run-plan.v1 (U-V3 / item 3)
# Written BEFORE vm_run.py; suite exits 2 ("SUT not found") until GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../vm_run.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
import gzip, importlib.util, io, json, lzma, os, struct, subprocess, sys, tempfile, unittest.mock
from pathlib import Path
sut = Path(sys.argv[1])
sp = importlib.util.spec_from_file_location("vm_run", sut)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
sys.path.insert(0, str(sut.parent / "lib")); sys.path.insert(0, str(sut.parent))
passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))
def cli(*a, xe=None):
    e = os.environ.copy();
    if xe: e.update(xe)
    return subprocess.run([sys.executable, str(sut), *map(str, a)], capture_output=True, text=True, env=e)
def _gz(content: bytes, isize_override: int | None = None) -> bytes:
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as g: g.write(content)
    data = bytearray(buf.getvalue())
    if isize_override is not None: struct.pack_into("<I", data, len(data) - 4, isize_override & 0xFFFFFFFF)
    return bytes(data)
def _xz(c: bytes) -> bytes: return lzma.compress(c, format=lzma.FORMAT_XZ, preset=0)

# ── T1: dry-run never executes (Popen/run patched to raise) ──────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); arch = R/"input.gz"; arch.write_bytes(_gz(b"hello test data")); out = R/"out"
    try:
        with unittest.mock.patch("subprocess.Popen", side_effect=AssertionError("Popen!")), \
             unittest.mock.patch("subprocess.run",  side_effect=AssertionError("run!")):
            rc = m.plan_run(m._parser(["plan","--input",str(arch),"--output",str(out),
                                       "--codec","gzip","--max-output-bytes","1048576"]))
        assert rc == 3, f"expected 3, got {rc}"
        produced = {p.name for p in out.iterdir()} if out.exists() else set()
        assert "vm-run-plan.v1.json" in produced and "vm-determinism.v1.json" in produced
        extra = produced - {"vm-run-plan.v1.json","vm-determinism.v1.json"}
        assert not extra, f"unexpected files: {extra}"
        ok("T1: dry-run never executes; only plan+determinism written; no subprocess")
    except Exception as e: nok("T1: dry-run-never-executes", str(e))
# ── T2: flag absent → exit 3 ─────────────────────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); arch = R/"i.gz"; arch.write_bytes(_gz(b"flag-absent")); out = R/"out"
    try:
        r = cli("plan","--input",str(arch),"--output",str(out),"--codec","gzip")
        assert r.returncode == 3, f"got {r.returncode}"
        ok("T2: flag absent → exit 3 (authorization-required)")
    except Exception as e: nok("T2: flag-absent-exit3", str(e))
# ── T3: --allow-exec + no live executor → exit 2 ─────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); arch = R/"i.gz"; arch.write_bytes(_gz(b"allow-exec")); out = R/"out"
    try:
        r = cli("plan","--input",str(arch),"--output",str(out),"--codec","gzip",
                "--allow-exec", xe={"RSDD_EXEC_EXECUTOR": ""})
        assert r.returncode == 2, f"got {r.returncode}\n{r.stderr[:100]}"
        ok("T3: --allow-exec + no live executor → exit 2 (gate hard-refuse)")
    except Exception as e: nok("T3: allow-exec-hard-refuse", str(e))
# ── T4: gzip bomb (ISIZE > cap) → exit 2, no output ─────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); arch = R/"bomb.gz"; arch.write_bytes(_gz(b"tiny", isize_override=200*1024*1024)); out = R/"out"
    try:
        r = cli("plan","--input",str(arch),"--output",str(out),"--codec","gzip","--max-output-bytes",str(128*1024*1024))
        assert r.returncode == 2, f"got {r.returncode}"
        assert not out.exists() or not any(True for _ in out.iterdir()), "output should be empty"
        ok("T4: gzip ISIZE > cap → exit 2, no output published")
    except Exception as e: nok("T4: bomb-bound-gzip", str(e))
# ── T5: xz bomb (index size > cap) → exit 2 ──────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); arch = R/"test.xz"; arch.write_bytes(_xz(b"x"*1024)); out = R/"out"
    try:
        r = cli("plan","--input",str(arch),"--output",str(out),"--codec","xz","--max-output-bytes","512")
        assert r.returncode == 2, f"got {r.returncode}"
        ok("T5: xz index size > cap → exit 2 (bomb bound)")
    except Exception as e: nok("T5: bomb-bound-xz", str(e))
# ── T6: gzip ISIZE + xz index read without inflation ─────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); content = b"metadata-only-test-content"
    try:
        gz = R/"t.gz"; gz.write_bytes(_gz(content))
        assert m.read_declared_size(gz, "gzip") == len(content) % (2**32)
        xz = R/"t.xz"; xz.write_bytes(_xz(content))
        assert m.read_declared_size(xz, "xz") == len(content)
        ok("T6: gzip ISIZE + xz index return correct size without inflation")
    except Exception as e: nok("T6: metadata-only-read", str(e))
# ── T7: same input → identical plan (determinism) ────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); arch = R/"det.gz"; arch.write_bytes(_gz(b"determinism-test")); out1 = R/"r1"; out2 = R/"r2"
    try:
        m.plan_run(m._parser(["plan","--input",str(arch),"--output",str(out1),"--codec","gzip"]))
        m.plan_run(m._parser(["plan","--input",str(arch),"--output",str(out2),"--codec","gzip"]))
        p1 = json.loads((out1/"vm-run-plan.v1.json").read_text())
        p2 = json.loads((out2/"vm-run-plan.v1.json").read_text())
        assert p1 == p2, "plans differ"
        ok("T7: same input → identical plan (deterministic)")
    except Exception as e: nok("T7: determinism-same-input", str(e))
# ── T8: determinism record state ─────────────────────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); arch = R/"dr.gz"; arch.write_bytes(_gz(b"dry-run-det")); out = R/"out"
    try:
        m.plan_run(m._parser(["plan","--input",str(arch),"--output",str(out),"--codec","gzip"]))
        det = json.loads((out/"vm-determinism.v1.json").read_text())
        assert det["reproducible"]["declared"] is False
        assert det["reproducible"]["basis"] == "dry-run-plan"
        assert det["receipt_identity"] is None
        ok("T8: det record: declared:false, basis:dry-run-plan, receipt_identity:null")
    except Exception as e: nok("T8: determinism-record-state", str(e))
# ── T9: output under /home → exit 2 (bind-scope guard) ───────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); arch = R/"s.gz"; arch.write_bytes(_gz(b"bind-safety"))
    try:
        r = cli("plan","--input",str(arch),"--output","/home/vm-run-unsafe","--codec","gzip")
        assert r.returncode == 2, f"got {r.returncode}"
        ok("T9: output under /home → exit 2 (bind-scope guard)")
    except Exception as e: nok("T9: bind-path-safety", str(e))
# ── T10: unknown format → exit 2, no traceback ───────────────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); bad = R/"bad.bin"; bad.write_bytes(b"\x00\x01\x02\x03\x04\x05\x06\x07"); out = R/"out"
    try:
        r = cli("plan","--input",str(bad),"--output",str(out),"--codec","auto")
        assert r.returncode == 2, f"got {r.returncode}"
        assert "Traceback" not in r.stderr, f"traceback: {r.stderr[:200]}"
        ok("T10: unknown format → exit 2, no traceback")
    except Exception as e: nok("T10: malformed-input", str(e))
# ── T11: planned argv has --unshare-net, --cap-drop ALL, --tmpfs ─────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); arch = R/"argv.gz"; arch.write_bytes(_gz(b"argv-test")); out = R/"out"
    try:
        m.plan_run(m._parser(["plan","--input",str(arch),"--output",str(out),"--codec","gzip"]))
        argv = json.loads((out/"vm-run-plan.v1.json").read_text())["planned_argv"]
        assert "--unshare-net" in argv
        idx = argv.index("--cap-drop"); assert argv[idx+1] == "ALL"
        assert "--tmpfs" in argv
        ok("T11: planned argv has --unshare-net, --cap-drop ALL, --tmpfs")
    except Exception as e: nok("T11: planned-argv-security-flags", str(e))

# ── T12: xz implausibly large backward field → structured error, no traceback ──
with tempfile.TemporaryDirectory() as td:
    R = Path(td); craft = R/"crafted.xz"; out = R/"out"
    # backward=262144 → idx_size=(262144+1)*4=1048580 > _MAX_XZ_INDEX_BYTES(1 MiB).
    # footer layout: 4B crc32 placeholder | 4B backward (LE) | 2B stream-flags | 2B "YZ"
    backward = 262144
    footer = b'\x00'*4 + struct.pack("<I", backward) + b'\x00\x00' + b'YZ'
    craft.write_bytes(b'\x00'*20 + footer)  # 32 bytes total — passes the sz>=32 guard
    try:
        r = cli("plan","--input",str(craft),"--output",str(out),"--codec","xz")
        assert r.returncode == 2, f"got {r.returncode}"
        assert "Traceback" not in r.stderr, f"traceback leaked: {r.stderr[:300]}"
        assert "implausibly large" in r.stderr, \
            f"expected 'implausibly large' in stderr; got: {r.stderr[:300]}"
        ok("T12: xz large backward → implausibly large error, clean exit, no traceback")
    except Exception as e: nok("T12: xz-large-backward-clean-error", str(e))


# ── T_CAP1: --max-input-bytes below archive size → exit 2, clean error, no traceback ──
with tempfile.TemporaryDirectory() as td:
    R = Path(td); arch = R/"input.gz"; arch.write_bytes(_gz(b"\x00"*50)); out = R/"out"
    # archive is > 50 bytes as gzip; cap set to 5 bytes → identity must reject it
    try:
        r = cli("plan","--input",str(arch),"--output",str(out),"--codec","gzip","--max-input-bytes","5")
        assert r.returncode == 2, f"got {r.returncode}"
        assert "Traceback" not in r.stderr, f"traceback in stderr: {r.stderr[:200]}"
        assert ("exceeds" in r.stderr or "max-input" in r.stderr), \
               f"missing cap rejection message: {r.stderr[:200]}"
        ok("T_CAP1: --max-input-bytes below archive size → exit 2, clean error, no traceback")
    except Exception as e: nok("T_CAP1: cap-below-archive-size", str(e))

# ── T_NOFOLLOW: read_declared_size rejects symlinked archive (O_NOFOLLOW) ────────
# RED before vm_run.py is updated: open() follows symlinks → succeeds → fails assertion.
# GREEN after: os.open with O_NOFOLLOW raises ELOOP → VmRunError raised.
with tempfile.TemporaryDirectory() as td:
    R = Path(td)
    real_gz = R / "real.gz"; real_gz.write_bytes(_gz(b"symlink-test-content"))
    symlink_gz = R / "link.gz"; symlink_gz.symlink_to(real_gz)
    try:
        try:
            m.read_declared_size(symlink_gz, "gzip")
            nok("T_NOFOLLOW: read_declared_size accepted symlink — should have rejected it")
        except m.VmRunError:
            ok("T_NOFOLLOW: read_declared_size rejects symlinked archive (O_NOFOLLOW → VmRunError)")
        except Exception as e:
            nok("T_NOFOLLOW: unexpected exception type", str(e))
    except Exception as e: nok("T_NOFOLLOW: test setup failed", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
