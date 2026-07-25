#!/usr/bin/env bash
# kaitai-driver-walk-memcap.test.sh
# Standalone test for kaitai_driver walk-phase MemoryError guard.
#
# Does NOT require ksc, bwrap, or the kaitai venv.  Uses system python3 and
# a mocked kaitaistruct so this suite always runs in CI-like environments.
#
# What it pins:
#   A MemoryError raised during _walk (after a successful parse) must cause the
#   driver to emit a memory_cap:true JSON signal on stdout and exit 0 — NOT
#   crash with exit 1 and empty stdout (generic adapter error).
#
# Mutation proof: remove the walk-phase try/except MemoryError guard from
# kaitai_driver.py and this test REDs — the injected MemoryError propagates
# uncaught, the driver exits non-zero, stdout is empty, and the assertion
# on ret==0 / memory_cap:true fails.
#
# House style: mirrors capa.test.sh / kaitai.test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER_LIB="$HERE/../lib"

# ---------------------------------------------------------------------------
# Dependency guard
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: kaitai-driver-walk-memcap (python3 not found)"
  echo "== 0 passed · 0 failed =="
  exit 0
fi

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# T1: walk-phase MemoryError → memory_cap:true, exit 0.
#     Injects MemoryError by monkeypatching kaitai_driver._walk.
#     Mocks kaitaistruct so no venv is needed.
# ---------------------------------------------------------------------------
if python3 - "$DRIVER_LIB" <<'PY'
import sys, os, json, types, tempfile, importlib.util

driver_lib = sys.argv[1]

# Load kaitai_driver as a fresh module (not added to sys.modules)
spec = importlib.util.spec_from_file_location(
    "_kd_test", os.path.join(driver_lib, "kaitai_driver.py")
)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)

# ---- Minimal mock kaitaistruct -----------------------------------------
fake_ks = types.ModuleType("kaitaistruct")
fake_ks.__version__ = "mock-0.0"

class _KS:
    """Minimal KaitaiStruct stand-in: accepts a stream, exposes _io."""
    def __init__(self, _io=None):
        self._io = _io

class _KStream:
    """Minimal KaitaiStream stand-in."""
    def __init__(self, data):
        pass

fake_ks.KaitaiStruct = _KS
fake_ks.KaitaiStream = _KStream
# -------------------------------------------------------------------------

with tempfile.TemporaryDirectory() as tmpdir:
    # Fake parser: parses successfully (Demo._read is a no-op)
    with open(os.path.join(tmpdir, "demo.py"), "w") as f:
        f.write("from kaitaistruct import KaitaiStruct, KaitaiStream\n")
        f.write("class Demo(KaitaiStruct):\n")
        f.write("    def _read(self): pass\n")

    # Minimal binary (content irrelevant: Demo._read ignores it)
    with open(os.path.join(tmpdir, "sample.bin"), "wb") as f:
        f.write(b"test")

    # Inject fake kaitaistruct before driver loads the generated module
    sys.modules["kaitaistruct"] = fake_ks

    # Deterministic injection: _walk raises MemoryError on first call
    def _raise_walk_oom(*a, **kw):
        raise MemoryError("injected walk OOM")
    driver._walk = _raise_walk_oom

    # Capture fd 1 (driver uses os.write(1, ...), not sys.stdout)
    rfd, wfd = os.pipe()
    saved_fd1 = os.dup(1)
    os.dup2(wfd, 1)
    os.close(wfd)

    old_argv = sys.argv[:]
    sys.argv = [
        "kaitai_driver",
        "--module-dir", tmpdir,
        "--stem", "demo",
        "--input", os.path.join(tmpdir, "sample.bin"),
    ]

    try:
        ret = driver.main()
    except SystemExit as e:
        ret = int(e.code) if e.code is not None else 0
    except Exception:
        ret = 99
    finally:
        sys.argv = old_argv
        sys.modules.pop("kaitaistruct", None)

    # Restore fd 1; close the write end so the pipe reaches EOF
    os.dup2(saved_fd1, 1)
    os.close(saved_fd1)

    # Drain the pipe
    chunks = []
    while True:
        chunk = os.read(rfd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    os.close(rfd)

    captured = b"".join(chunks)

    # ---- Assertions --------------------------------------------------------
    assert ret == 0, f"expected exit 0, got {ret} (guard missing?)"
    assert captured, "stdout empty — expected memory-cap JSON"
    result = json.loads(captured.decode("utf-8"))
    assert result.get("memory_cap") is True, \
        f"memory_cap must be True, got {result.get('memory_cap')!r}"
    assert result.get("truncated") is True, \
        f"truncated must be True on memory-cap, got {result.get('truncated')!r}"
    print(
        f"OK: memory_cap={result['memory_cap']} truncated={result['truncated']} exit=0"
    )
PY
then ok "T1: walk-phase MemoryError → memory_cap:true exit:0 (monkeypatched _walk)"
else no "T1: walk-phase MemoryError guard"
fi

# ---------------------------------------------------------------------------
# T2: write-all loop correctly assembles multiple partial os.write calls.
#
# Monkeypatches driver.os.write to return 1 byte at a time for fd 1.
# Before the fix (single os.write): only 1 byte reaches the pipe; json.loads
# fails → test exits non-zero → RED.
# After the fix (write-all loop): driver keeps calling os.write until all
# bytes are flushed; json.loads succeeds and write_call_count > 1 → GREEN.
#
# Honesty note: this is NOT a kernel-induced short write.  It is a
# deterministic monkeypatch that simulates partial returns.  A true
# kernel-level short write on a normal pipe is not achievable with small
# payloads (result_bytes is well under PIPE_BUF).  This test pins that the
# loop body advances the offset on each call and does not terminate early.
# ---------------------------------------------------------------------------
if python3 - "$DRIVER_LIB" <<'PY'
import sys, os, json, types, tempfile, importlib.util

driver_lib = sys.argv[1]

spec = importlib.util.spec_from_file_location(
    "_kd_t2", os.path.join(driver_lib, "kaitai_driver.py")
)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)

fake_ks = types.ModuleType("kaitaistruct")
fake_ks.__version__ = "mock-0.0"

class _KS:
    def __init__(self, _io=None): self._io = _io
class _KStream:
    def __init__(self, data): pass
fake_ks.KaitaiStruct = _KS
fake_ks.KaitaiStream = _KStream

with tempfile.TemporaryDirectory() as tmpdir:
    with open(os.path.join(tmpdir, "demo.py"), "w") as f:
        f.write("from kaitaistruct import KaitaiStruct, KaitaiStream\n")
        f.write("class Demo(KaitaiStruct):\n")
        f.write("    def _read(self): pass\n")
    with open(os.path.join(tmpdir, "sample.bin"), "wb") as f:
        f.write(b"test")

    sys.modules["kaitaistruct"] = fake_ks

    real_write = driver.os.write
    write_call_count = [0]

    def partial_write(fd, data):
        """Return only 1 byte per call for fd 1 to force the write-all loop."""
        write_call_count[0] += 1
        if fd == 1 and len(data) > 1:
            real_write(fd, bytes(data[:1]))
            return 1
        return real_write(fd, data)

    driver.os.write = partial_write

    rfd, wfd = os.pipe()
    saved_fd1 = os.dup(1)
    os.dup2(wfd, 1)
    os.close(wfd)

    old_argv = sys.argv[:]
    sys.argv = [
        "kaitai_driver",
        "--module-dir", tmpdir,
        "--stem", "demo",
        "--input", os.path.join(tmpdir, "sample.bin"),
    ]

    try:
        ret = driver.main()
    except SystemExit as e:
        ret = int(e.code) if e.code is not None else 0
    except Exception as e:
        ret = 99
        print(f"driver.main raised: {e}", file=sys.stderr)
    finally:
        sys.argv = old_argv
        sys.modules.pop("kaitaistruct", None)
        driver.os.write = real_write

    os.dup2(saved_fd1, 1)
    os.close(saved_fd1)

    chunks = []
    while True:
        chunk = os.read(rfd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    os.close(rfd)

    captured = b"".join(chunks)

    assert ret == 0, f"expected exit 0, got {ret}"
    assert captured, "stdout empty"
    result = json.loads(captured.decode("utf-8"))
    assert result.get("memory_cap") is False, (
        f"expected memory_cap:false on happy path, got {result.get('memory_cap')!r}"
    )
    assert write_call_count[0] > 1, (
        f"write_call_count={write_call_count[0]}: expected >1 calls (loop), "
        "got 1 — single os.write still present (write-all loop not in place)"
    )
    print(f"OK: {len(captured)} bytes written in {write_call_count[0]} partial write calls")
PY
then ok "T2: write-all loop handles partial os.write (monkeypatched 1 byte/call)"
else no "T2: write-all loop"
fi

# ---------------------------------------------------------------------------
# T3: os.write returning 0 mid-payload must produce a non-zero exit code.
#
# A zero return from os.write signals a broken fd — no progress is possible.
# The loop must exit with return 1 (failure) rather than break+return 0
# (which would silently report success after emitting a truncated prefix).
#
# Before fix (break → return 0): ret=0 → assert ret != 0 fails → RED.
# After fix  (return 1)        : ret=1 → assert ret != 0 passes → GREEN.
#
# M6 mutation (delete the `if _n == 0` branch entirely): the loop spins
# indefinitely (_offset never advances past the stalled byte) → HANGS.
# ---------------------------------------------------------------------------
if python3 - "$DRIVER_LIB" <<'PY'
import sys, os, json, types, tempfile, importlib.util

driver_lib = sys.argv[1]

spec = importlib.util.spec_from_file_location(
    "_kd_t3", os.path.join(driver_lib, "kaitai_driver.py")
)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)

fake_ks = types.ModuleType("kaitaistruct")
fake_ks.__version__ = "mock-0.0"

class _KS:
    def __init__(self, _io=None): self._io = _io
class _KStream:
    def __init__(self, data): pass
fake_ks.KaitaiStruct = _KS
fake_ks.KaitaiStream = _KStream

with tempfile.TemporaryDirectory() as tmpdir:
    with open(os.path.join(tmpdir, "demo.py"), "w") as f:
        f.write("from kaitaistruct import KaitaiStruct, KaitaiStream\n")
        f.write("class Demo(KaitaiStruct):\n")
        f.write("    def _read(self): pass\n")
    with open(os.path.join(tmpdir, "sample.bin"), "wb") as f:
        f.write(b"test")

    sys.modules["kaitaistruct"] = fake_ks

    real_write = driver.os.write
    call_count = [0]

    def zero_after_first(fd, data):
        """Write one byte normally on the first call; return 0 on all subsequent
        calls to simulate a stalled / broken fd mid-payload."""
        call_count[0] += 1
        if fd == 1:
            if call_count[0] == 1:
                real_write(fd, bytes(data[:1]))
                return 1
            return 0
        return real_write(fd, data)

    driver.os.write = zero_after_first

    rfd, wfd = os.pipe()
    saved_fd1 = os.dup(1)
    os.dup2(wfd, 1)
    os.close(wfd)

    old_argv = sys.argv[:]
    sys.argv = [
        "kaitai_driver",
        "--module-dir", tmpdir,
        "--stem", "demo",
        "--input", os.path.join(tmpdir, "sample.bin"),
    ]

    try:
        ret = driver.main()
    except SystemExit as e:
        ret = int(e.code) if e.code is not None else 0
    except Exception as e:
        ret = 99
        print(f"driver.main raised: {e}", file=sys.stderr)
    finally:
        sys.argv = old_argv
        sys.modules.pop("kaitaistruct", None)
        driver.os.write = real_write

    os.dup2(saved_fd1, 1)
    os.close(saved_fd1)

    chunks = []
    while True:
        chunk = os.read(rfd, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    os.close(rfd)

    captured = b"".join(chunks)

    assert ret != 0, (
        f"expected non-zero exit (partial write is failure), "
        f"got exit={ret} wrote={len(captured)} bytes — "
        "break+return 0 still present (silent truncation)"
    )
    print(f"OK: exit={ret} wrote={len(captured)} bytes before 0-return → non-zero exit")
PY
then ok "T3: os.write returning 0 mid-payload → exit non-zero (not silent truncation)"
else no "T3: zero-return exit code"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
