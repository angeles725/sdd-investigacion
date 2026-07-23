#!/usr/bin/env bash
# proc-common.test.sh — TDD RED→GREEN for lib/proc_common.reap_process_tree.
# RED: exits 2 (SUT not found) before lib/proc_common.py is created.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lib/proc_common.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
import importlib.util, os, subprocess, sys, time
from pathlib import Path

sut_path = Path(sys.argv[1])
sys.path.insert(0, str(sut_path.parent))
sp = importlib.util.spec_from_file_location("proc_common", sut_path)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)

passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))

# ── PC1: single-proc mode reaps sleep-30 within grace period ─────────────────
try:
    proc = subprocess.Popen(["sleep", "30"])
    m.reap_process_tree(proc, grace_s=5, use_group=False)
    assert proc.poll() is not None, f"process still alive: poll={proc.poll()}"
    ok("PC1: single-proc reap_process_tree reaps sleep-30 within grace period")
except Exception as e: nok("PC1", str(e))

# ── PC2: group mode reaps process spawned with start_new_session=True ─────────
try:
    # Spawn a process in its own session (new process group).
    # Use a simple sleep so it doesn't spawn child procs at this level,
    # but start_new_session=True ensures killpg path is exercised.
    proc = subprocess.Popen(["sleep", "30"], start_new_session=True)
    m.reap_process_tree(proc, grace_s=5, use_group=True)
    assert proc.poll() is not None, f"process still alive after group reap: poll={proc.poll()}"
    ok("PC2: group-mode reap_process_tree reaps start_new_session process")
except Exception as e: nok("PC2", str(e))

# ── PC3: never raises when proc already exited ────────────────────────────────
try:
    proc = subprocess.Popen(["true"])
    proc.wait()  # already exited
    m.reap_process_tree(proc, grace_s=5, use_group=False)  # must not raise
    ok("PC3: never raises when proc already exited (single-proc)")
except Exception as e: nok("PC3", str(e))

# ── PC4: group mode never raises when proc already exited ─────────────────────
try:
    proc = subprocess.Popen(["true"], start_new_session=True)
    proc.wait()
    m.reap_process_tree(proc, grace_s=5, use_group=True)  # must not raise
    ok("PC4: never raises when proc already exited (group mode)")
except Exception as e: nok("PC4", str(e))

# ── PC5: reap_process_tree is a callable with (proc, *, grace_s, use_group) ──
try:
    import inspect
    sig = inspect.signature(m.reap_process_tree)
    params = list(sig.parameters.keys())
    assert "proc" in params, f"'proc' not in params: {params}"
    assert "grace_s" in params, f"'grace_s' not in params: {params}"
    assert "use_group" in params, f"'use_group' not in params: {params}"
    ok("PC5: reap_process_tree signature has proc, grace_s, use_group")
except Exception as e: nok("PC5", str(e))

# ── PC6: use_group=True on non-isolated proc (same pgid) → single-proc fallback ─
try:
    import subprocess as _sp2, sys as _sys2, textwrap as _tw
    _code = _tw.dedent(f"""
        import sys, importlib.util, subprocess, os
        from pathlib import Path
        sut_path = Path({str(sut_path)!r})
        sp = importlib.util.spec_from_file_location("proc_common", sut_path)
        m2 = importlib.util.module_from_spec(sp); sp.loader.exec_module(m2)
        victim = subprocess.Popen(["sleep", "30"])
        m2.reap_process_tree(victim, grace_s=2, use_group=True)
        assert victim.poll() is not None, "victim still alive after reap"
        print("survived")
    """).strip()
    # start_new_session isolates the worker: if unfixed code fires killpg on its
    # own pgid the blast is contained to this subprocess, not the test runner.
    _r = _sp2.run(
        [_sys2.executable, "-c", _code],
        capture_output=True, text=True, timeout=15, start_new_session=True,
    )
    if _r.returncode == 0 and "survived" in _r.stdout:
        ok("PC6: use_group=True on same-pgid proc falls back to single-proc (reaper survives, victim reaped)")
    else:
        nok("PC6",
            f"reaper killed by own killpg (rc={_r.returncode}) — "
            f"guard pgid==os.getpgrp() missing in reap_process_tree")
except Exception as e: nok("PC6", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
