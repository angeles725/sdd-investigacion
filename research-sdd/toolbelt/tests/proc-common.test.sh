#!/usr/bin/env bash
# proc-common.test.sh — TDD RED→GREEN for lib/proc_common.reap_process_tree.
# RED: exits 2 (SUT not found) before lib/proc_common.py is created.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lib/proc_common.py"; REL="lib/proc_common.py"
if [ "${1:-}" = "--teeth-child" ]; then   # argument-selected SUT for the mutation teeth (fails closed below)
  SUT="${2:-}"
  [ -f "$SUT" ] || { echo "FATAL: --teeth-child needs an existing SUT file, got [$SUT]" >&2; exit 2; }
  echo "TEETH-CHILD: SUT=$SUT"
fi
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
IFS= read -r -d '' PY_SRC <<'PY'
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
mutant_bootstrap mutant_py_stage_control mutant_py_tooth || exit 2
SELF="$HERE/$(basename "$0")"
MUT="$(mktemp -d)" || exit 2
mutant_cleanup_register "$MUT" || exit 2
tt() { if mutant_py_tooth "$1" "$HERE" "$SELF" "$MUT" "$REL" "${@:2}"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
echo "-- teeth: each guarded behaviour must be load-bearing (staged tree, one mutant per check) --"
if mutant_py_stage_control teeth-control "$HERE" "$SELF" "$MUT" "$REL"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

# PC1/PC2/PC6 mutants leave their `sleep 30` victims to expire on their own (the reaper is the thing being broken).
tt teeth-PC1 'if proc.poll() is not None:' 'if True:' 'FAIL  PC1: process still alive'
tt teeth-PC2 'pgid = os.getpgid(proc.pid)' 'pgid = os.getpgid(proc.pid) + 99999' 'FAIL  PC2: process still alive after group reap'
tt teeth-PC6 'if pgid == os.getpgrp():' 'if False:' 'FAIL  PC6: reaper killed by own killpg'

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
