#!/usr/bin/env bash
# capture-exec.test.sh — TDD RED→GREEN for LiveCaptureExecutor (C1 live-capture).
# RED: exits 2 (SUT not found) before lib/capture_exec.py + capture_plan.py wiring.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
if [ "${1:-}" = "--teeth-child" ]; then   # argument-selected SUT for the mutation teeth (fails closed below)
  ARG="${2:-}"
  [ -f "$ARG" ] || { echo "FATAL: --teeth-child needs an existing SUT file, got [$ARG]" >&2; exit 2; }
  echo "TEETH-CHILD: SUT=$ARG"
  case "$ARG" in */lib/*) ROOT="$(cd "$(dirname "$ARG")/.." && pwd)" ;; *) ROOT="$(cd "$(dirname "$ARG")" && pwd)" ;; esac
fi
SUT="$ROOT/lib/capture_exec.py"
PLAN="$ROOT/capture_plan.py"
if [ "${1:-}" = "--teeth-child" ]; then   # the mutated file replaces its own slot; every other slot stays in the staged tree
  case "$ARG" in
    */lib/*) case "$(basename "$ARG")" in
      capture_exec.py) SUT="$ARG" ;;
    esac ;;
    *) case "$(basename "$ARG")" in
      capture_plan.py) PLAN="$ARG" ;;
    esac ;;
  esac
fi
[ -f "$SUT" ] || { echo "FATAL: capture_exec.py not found: $SUT" >&2; exit 2; }
[ -f "$PLAN" ] || { echo "FATAL: capture_plan.py not found: $PLAN" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
IFS= read -r -d '' PY_SRC <<'PY'
import importlib.util, json, os, subprocess, struct, sys, tempfile
from pathlib import Path

sut_path = Path(sys.argv[1]); plan_path = Path(sys.argv[2])
sys.path.insert(0, str(sut_path.parent))   # lib/ — gate, docker_common, adapter_core
sp = importlib.util.spec_from_file_location("capture_exec", sut_path)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)

passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))
def cli(*a, xe=None):
    e = os.environ.copy()
    if xe: e.update(xe)
    return subprocess.run([sys.executable, str(plan_path), *map(str, a)],
                          capture_output=True, text=True, env=e)

# Fake dumpcap shim: -D → canned interface list (DUMPCAP_D_EXIT controls failure).
# Capture mode: write valid pcap magic to -w path, record argv to DUMPCAP_RECORD,
# sleep DUMPCAP_SLEEP, exit DUMPCAP_EXIT.
_SHIM = """\
#!/usr/bin/env python3
import json, os, struct, sys, time
PCAP_MAGIC = struct.pack("<IHHIIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1)
args = sys.argv[1:]
rec = os.environ.get("DUMPCAP_RECORD", "")
if rec:
    try: c = json.loads(open(rec).read())
    except: c = []
    c.append(args); open(rec, "w").write(json.dumps(c))
if args and args[0] == "-D":
    e = int(os.environ.get("DUMPCAP_D_EXIT", "0"))
    if e:
        print("You don't have permission to capture on that device", file=sys.stderr)
        sys.exit(e)
    print("1. eth0 (Ethernet)")
    print("2. lo (Loopback)")
    sys.exit(0)
for i, a in enumerate(args):
    if a == "-w" and i + 1 < len(args):
        # Only a per-run path (/tmp/rsdd/rsdd-<uuid>/...) is ever written: a mutant that leaves -w unrewritten
        # must not create /tmp/rsdd/capture.pcap on the host.
        if "/rsdd-" in args[i + 1]:
            try:
                with open(args[i + 1], "wb") as f: f.write(PCAP_MAGIC)
            except Exception: pass
        break
sl = float(os.environ.get("DUMPCAP_SLEEP", "0"))
if sl: time.sleep(sl)
sys.exit(int(os.environ.get("DUMPCAP_EXIT", "0")))
"""

def _shim(tmp: Path) -> str:
    fd = tmp / "dumpcap"; fd.write_text(_SHIM); fd.chmod(0o755)
    return str(tmp) + ":" + os.environ.get("PATH", "")

# Startup-free blocking shim for RED8 (#2092). The client wall deadline (duration + grace) starts at spawn, so a
# Python shim whose interpreter startup is slowed by machine load could be SIGTERMed before it wrote the pcap.
# This /bin/sh shim writes the pcap magic with a builtin printf, then exec's a sleep far beyond any budget: the
# timeout path is always taken and the case never races interpreter startup.
_SHIM_BLOCK = """\
#!/bin/sh
if [ "$1" = "-D" ]; then echo "1. eth0 (Ethernet)"; echo "2. lo (Loopback)"; exit 0; fi
prev=
for a in "$@"; do
  if [ "$prev" = "-w" ]; then
    case "$a" in */rsdd-*) printf '\\324\\303\\262\\241\\002\\000\\004\\000\\000\\000\\000\\000\\000\\000\\000\\000\\377\\377\\000\\000\\001\\000\\000\\000' > "$a" ;; esac
  fi
  prev=$a
done
exec sleep 60
"""

def _shim_block(tmp: Path) -> str:
    fd = tmp / "dumpcap"; fd.write_text(_SHIM_BLOCK); fd.chmod(0o755)
    return str(tmp) + ":" + os.environ.get("PATH", "")

# Capture-clock shims (#2095). dumpcap's own -a duration: counts from capture start, so the client wall must too.
# _SHIM_SLOW: slow startup (sleep 7 > the 5 s grace) BEFORE the pcap appears, then a capture that ends within its
# 1 s duration -> a clean exit 0. _SHIM_NOSTART: never writes the pcap nor any output, blocks far past every budget.
_SHIM_SLOW = """\
#!/bin/sh
if [ "$1" = "-D" ]; then echo "1. eth0 (Ethernet)"; exit 0; fi
sleep 7
prev=
for a in "$@"; do
  if [ "$prev" = "-w" ]; then
    case "$a" in */rsdd-*) printf '\\324\\303\\262\\241\\002\\000\\004\\000\\000\\000\\000\\000\\000\\000\\000\\000\\377\\377\\000\\000\\001\\000\\000\\000' > "$a" ;; esac
  fi
  prev=$a
done
sleep 1
exit 0
"""
_SHIM_NOSTART = """\
#!/bin/sh
if [ "$1" = "-D" ]; then echo "1. eth0 (Ethernet)"; exit 0; fi
exec sleep 60
"""

def _shim_text(tmp: Path, text: str) -> str:
    fd = tmp / "dumpcap"; fd.write_text(text); fd.chmod(0o755)
    return str(tmp) + ":" + os.environ.get("PATH", "")

Path("/tmp/rsdd").mkdir(exist_ok=True)  # verify_rsdd_root requires a real dir

# ── RED1: allow=False → exit 3 (auth-required), dumpcap NEVER spawned ─────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); rec = tmp / "c.json"; p = _shim(tmp)
    try:
        r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
                xe={"PATH": p, "DUMPCAP_RECORD": str(rec),
                    "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0"})
        calls = json.loads(rec.read_text()) if rec.exists() else []
        assert r.returncode == 3 and calls == [], f"rc={r.returncode} calls={calls}"
        ok("RED1: allow=False → exit 3 (auth-required), dumpcap never spawned")
    except Exception as e: nok("RED1", str(e))

# ── RED2/GREEN: allow=True + fake dumpcap → exit 0 + capture-run.v1 receipt ──
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim(tmp)
    try:
        r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
                "--allow-live-capture",
                xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0"})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:300]}"
        res = json.loads(r.stdout)
        assert res.get("schema_version") == "capture-run.v1", f"sv={res.get('schema_version')}"
        assert res.get("executed") is True
        for k in ("exec_argv", "argv_deltas", "pcap_path", "output_files",
                  "exit_code", "duration_s", "stdout_truncated", "stderr_truncated"):
            assert k in res, f"missing key: {k}"
        ok("RED2/GREEN: allow=True + fake dumpcap → exit 0, capture-run.v1 receipt")
    except Exception as e: nok("RED2/GREEN", str(e))

# ── RED3: caps in exec_argv (-c, -a duration:, -a filesize:) ──────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim(tmp)
    try:
        r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
                "--allow-live-capture",
                xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0"})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:200]}"
        ea = json.loads(r.stdout).get("exec_argv", [])
        assert "-c" in ea, f"-c missing: {ea}"
        assert any(a.startswith("duration:") for i, a in enumerate(ea)
                   if i > 0 and ea[i-1] == "-a"), f"-a duration: missing: {ea}"
        assert any(a.startswith("filesize:") for i, a in enumerate(ea)
                   if i > 0 and ea[i-1] == "-a"), f"-a filesize: missing: {ea}"
        ok("RED3: caps (-c, -a duration:, -a filesize:) in exec_argv")
    except Exception as e: nok("RED3", str(e))

# ── RED4: iface NOT in RSDD_CAPTURE_IFACES allowlist → GateError exit 2 ──────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim(tmp)
    try:
        r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
                "--allow-live-capture",
                xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "wlan0,lo"})
        assert r.returncode == 2, f"rc={r.returncode}"
        ok("RED4: iface not in allowlist → GateError exit 2")
    except Exception as e: nok("RED4", str(e))

# ── RED5: RSDD_CAPTURE_IFACES absent → fail-closed GateError exit 2 ──────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim(tmp)
    env = os.environ.copy()
    env.update({"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": ""})
    env.pop("RSDD_CAPTURE_IFACES", None)
    try:
        r = subprocess.run(
            [sys.executable, str(plan_path), "plan", "--interface", "eth0",
             "--output", str(tmp/"out"), "--allow-live-capture"],
            capture_output=True, text=True, env=env)
        assert r.returncode == 2, f"rc={r.returncode}"
        assert "RSDD_CAPTURE_IFACES env var is not set" in r.stderr, f"unset-env message missing: {r.stderr[:200]}"
        ok("RED5: RSDD_CAPTURE_IFACES unset → fail-closed GateError exit 2")
    except Exception as e: nok("RED5", str(e))

# ── RED6: dumpcap -D permission failure → fail-closed, no sudo in stderr ──────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim(tmp)
    try:
        r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
                "--allow-live-capture",
                xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0",
                    "DUMPCAP_D_EXIT": "1"})
        assert r.returncode == 2, f"rc={r.returncode}"
        assert "sudo" not in r.stderr.lower(), f"stderr must not mention sudo: {r.stderr[:200]}"
        ok("RED6: dumpcap -D perm failure → fail-closed exit 2, no sudo")
    except Exception as e: nok("RED6", str(e))

# ── RED7: -w rewritten to per-run subdir, not /tmp/rsdd/capture.pcap ─────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim(tmp)
    try:
        r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
                "--allow-live-capture",
                xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0"})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:200]}"
        res = json.loads(r.stdout)
        ea = res.get("exec_argv", [])
        try: w_val = ea[ea.index("-w") + 1]
        except (ValueError, IndexError): raise AssertionError(f"-w not found: {ea}")
        assert w_val != "/tmp/rsdd/capture.pcap", f"-w not rewritten: {w_val}"
        assert "/tmp/rsdd/rsdd-" in w_val, f"-w not in per-run subdir: {w_val}"
        dl = res.get("argv_deltas", [])
        assert any(d.get("transform") == "output-path" for d in dl), f"no output-path delta: {dl}"
        ok("RED7: -w rewritten to per-run subdir, output-path delta recorded")
    except Exception as e: nok("RED7", str(e))

# ── RED8: wall-timeout → SIGTERM, partial pcap recorded, outcome=timeout-partial
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim_block(tmp)
    try:
        r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
                "--allow-live-capture", "--duration-seconds", "1",
                xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0"})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:300]}"
        res = json.loads(r.stdout)
        assert res.get("outcome") == "timeout-partial", f"outcome={res.get('outcome')}"
        of = res.get("output_files", []); pcap = res.get("pcap_path", "")
        assert of, f"output_files empty: {of}"
        assert any(f.get("path") == pcap for f in of), f"planned pcap not recorded: pcap={pcap} files={of}"
        ok("RED8: wall-timeout → SIGTERM, outcome=timeout-partial, pcap recorded")
    except Exception as e: nok("RED8", str(e))

# ── CLOCK1: slow dumpcap startup (> grace) then a capture within duration -> clean outcome (#2095)
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim_text(tmp, _SHIM_SLOW)
    try:
        r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
                "--allow-live-capture", "--duration-seconds", "1",
                xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0"})
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:300]}"
        res = json.loads(r.stdout)
        assert res.get("outcome") == "success", f"outcome={res.get('outcome')} exit={res.get('exit_code')}"
        assert res.get("exit_code") == 0, f"exit_code={res.get('exit_code')}"
        ok("CLOCK1: slow startup then in-duration capture -> outcome=success (clock starts at capture)")
    except Exception as e: nok("CLOCK1", str(e))

# ── CLOCK2: dumpcap that never starts capturing is killed by the ceiling -> timeout-partial (#2095)
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim_text(tmp, _SHIM_NOSTART)
    _saved = (getattr(m, "_STARTUP_BUDGET_S", 0), m._WALL_GRACE_S, m._SIGTERM_GRACE_S, dict(os.environ))
    try:
        import time as _t
        m._STARTUP_BUDGET_S = 1; m._WALL_GRACE_S = 1; m._SIGTERM_GRACE_S = 1
        os.environ.update({"PATH": p, "RSDD_CAPTURE_IFACES": "eth0"})
        plan = {"planned_argv": ["dumpcap", "-i", "eth0", "-c", "10", "-a", "duration:1", "-w", "/tmp/rsdd/capture.pcap"],
                "capture_spec": {"duration_seconds": 1, "packet_count_cap": 10, "snaplen": 65535}}
        t0 = _t.monotonic()
        res = m.LiveCaptureExecutor(tmp / "out").evaluate(plan)
        took = _t.monotonic() - t0
        assert res.get("outcome") == "timeout-partial", f"outcome={res.get('outcome')}"
        assert took < 15, f"ceiling did not fire promptly: {took:.1f}s"
        ok("CLOCK2: never-starting dumpcap killed by the ceiling, outcome=timeout-partial")
    except Exception as e: nok("CLOCK2", str(e))
    finally:
        m._STARTUP_BUDGET_S, m._WALL_GRACE_S, m._SIGTERM_GRACE_S = _saved[:3]
        os.environ.clear(); os.environ.update(_saved[3])

# ── RED9: no shell=True in capture_exec.py source ─────────────────────────────
try:
    src = sut_path.read_text()
    assert "shell=True" not in src, "shell=True found in capture_exec.py!"
    ok("RED9: no shell=True in capture_exec.py")
except Exception as e: nok("RED9", str(e))

# ── CRIT1: output_files recorded from per-run subdir ─────────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim(tmp)
    try:
        r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
                "--allow-live-capture",
                xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0"})
        assert r.returncode == 0, f"rc={r.returncode}"
        res = json.loads(r.stdout)
        of = res.get("output_files", [])
        assert of, f"output_files empty: {of}"
        assert any("/rsdd-" in f.get("path", "") for f in of), f"no per-run path: {of}"
        ok("CRIT1: output_files from per-run subdir with sha256+size")
    except Exception as e: nok("CRIT1", str(e))

# ── CRIT2: add-filesize-cap transform in argv_deltas ─────────────────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim(tmp)
    try:
        r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
                "--allow-live-capture",
                xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0"})
        assert r.returncode == 0, f"rc={r.returncode}"
        dl = json.loads(r.stdout).get("argv_deltas", [])
        assert any(d.get("transform") == "add-filesize-cap" for d in dl), f"missing: {dl}"
        ok("CRIT2: add-filesize-cap transform in argv_deltas")
    except Exception as e: nok("CRIT2", str(e))

# ── REAP_1: _reap reaped sleep-30 subprocess within grace period ──────────────
import subprocess as _sp
_proc = None
try:
    _proc = _sp.Popen(["sleep", "30"], stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)
    m._reap(_proc)
    assert _proc.poll() is not None, f"process still alive after _reap: poll={_proc.poll()}"
    ok("REAP_1: _reap reaped sleep-30 within grace period")
except AttributeError as e: nok("REAP_1", f"_reap not found: {e}")
except Exception as e: nok("REAP_1", str(e))
finally:
    # Kill only the exact spawned handle: a _reap mutant must not leave a 30 s orphan behind.
    if _proc is not None and _proc.poll() is None:
        _proc.kill(); _proc.wait(timeout=5)

# ── FILESIZE_1: _filesize_kb exact formula (kB) + cap engagement ──────────────
try:
    # (24 + 100*(1500+16)) // 1000 + 1 = 151624 // 1000 + 1 = 152
    got = m._filesize_kb(100, 1500)
    assert got == 152, f"expected 152, got {got}"
    # defaults (10000×65535) exceed cap → capped at _FILESIZE_KB_MAX
    capped = m._filesize_kb(10_000, 65535)
    assert capped == m._FILESIZE_KB_MAX, f"expected {m._FILESIZE_KB_MAX}, got {capped}"
    ok("FILESIZE_1: _filesize_kb exact formula (kB) + cap engagement")
except AttributeError as e: nok("FILESIZE_1", f"_filesize_kb not found: {e}")
except Exception as e: nok("FILESIZE_1", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
if [ "${1:-}" != "--prove-teeth" ]; then python3 -c "$PY_SRC" "$SUT" "$PLAN"; exit $?; fi

# ── MUTATION TEETH (--prove-teeth) ─────────────────────────────────────────────
# Plain run first: its case lines are kept, its aggregate is replaced by ONE combined aggregate at the end
# (run-all.sh reads the LAST `== N passed · N failed ==` line).
py_out="$(python3 -c "$PY_SRC" "$SUT" "$PLAN")"; py_rc=$?
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
tt() { if mutant_py_tooth "$1" "$HERE" "$SELF" "$MUT" "${@:2}"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
echo "-- teeth: each guarded behaviour must be load-bearing (staged tree, one mutant per check) --"
if mutant_py_stage_control teeth-control "$HERE" "$SELF" "$MUT" "lib/capture_exec.py"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
tt teeth-gate-allow capture_plan.py 'run_gate_epilogue(CAP_LIVE_CAPTURE, args.allow_live_capture, plan' 'run_gate_epilogue(CAP_LIVE_CAPTURE, True, plan' 'FAIL  RED1: rc='
tt teeth-iface-allowlist lib/capture_exec.py 'if iface not in allowed:' 'if False:' 'FAIL  RED4: rc='
tt teeth-iface-unset lib/capture_exec.py '    if not raw:' '    if False:' 'FAIL  RED5: unset-env message missing'
tt teeth-w-rewrite lib/capture_exec.py 'exec_argv[w_idx + 1] = pcap_path' 'pass' 'FAIL  RED7: -w not rewritten'
tt teeth-filesize-formula lib/capture_exec.py 'raw = (24 + packet_count * (snaplen + 16)) // 1000 + 1' 'raw = (24 + packet_count * (snaplen + 16)) // 1024 + 1' 'FAIL  FILESIZE_1: expected 152'
tt teeth-filesize-ceiling lib/capture_exec.py 'return min(raw, _FILESIZE_KB_MAX)' 'return raw' 'FAIL  FILESIZE_1: expected 524288'

tt teeth-filesize-delta lib/capture_exec.py 'argv_deltas.append({"transform": "add-filesize-cap", "value": filesize_arg})' 'pass' 'FAIL  CRIT2: missing'
tt teeth-timeout-outcome lib/capture_exec.py '                timed_out = True' '                timed_out = False' 'FAIL  RED8: outcome=success'
tt teeth-capture-clock lib/capture_exec.py '_STARTUP_BUDGET_S: int = 30 ' '_STARTUP_BUDGET_S: int = 0 ' 'FAIL  CLOCK1: outcome=timeout-partial'
tt teeth-reap lib/capture_exec.py '_pc.reap_process_tree(proc, grace_s=_SIGTERM_GRACE_S, use_group=False)' 'pass' 'FAIL  REAP_1: process still alive after _reap'
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
