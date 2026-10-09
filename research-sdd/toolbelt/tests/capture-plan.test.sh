#!/usr/bin/env bash
# capture-plan.test.sh — RED-first contract tests for capture-plan.v1 (U-N8 / item 8)
# Written BEFORE capture_plan.py; suite exits 2 ("SUT not found") until GREEN.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../capture_plan.py"; REL="capture_plan.py"
if [ "${1:-}" = "--teeth-child" ]; then   # argument-selected SUT for the mutation teeth (fails closed below)
  SUT="${2:-}"
  [ -f "$SUT" ] || { echo "FATAL: --teeth-child needs an existing SUT file, got [$SUT]" >&2; exit 2; }
  echo "TEETH-CHILD: SUT=$SUT"
fi
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
IFS= read -r -d '' PY_SRC <<'PY'
import importlib.util, json, os, subprocess, sys, tempfile, unittest.mock
from pathlib import Path
sut = Path(sys.argv[1])
sp = importlib.util.spec_from_file_location("capture_plan", sut)
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

# ── T1: dry-run NEVER captures; plan+det written; no subprocess; no socket ───
with tempfile.TemporaryDirectory() as td:
    R = Path(td); out = R/"out"
    try:
        with unittest.mock.patch("subprocess.Popen", side_effect=AssertionError("Popen!")), \
             unittest.mock.patch("subprocess.run",   side_effect=AssertionError("run!")):
            rc = m.plan_capture(m._parser(["plan","--interface","eth0","--output",str(out)]))
        assert rc == 3, f"expected 3, got {rc}"
        produced = {p.name for p in out.iterdir()} if out.exists() else set()
        assert "capture-plan.v1.json" in produced, f"capture-plan.v1.json missing; got {produced}"
        assert "vm-determinism.v1.json" in produced, "vm-determinism.v1.json missing"
        pcap_files = [n for n in produced if n.endswith(".pcap")]
        assert not pcap_files, f"unexpected pcap files in output: {pcap_files}"
        assert not hasattr(m, "socket"), "module must not import socket"
        ok("T1: dry-run never captures; plan+det written; no subprocess; no socket")
    except Exception as e: nok("T1: dry-run-never-captures", str(e))

# ── T2: flag absent → exit 3 (authorization-required), zero side effects ─────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); out = R/"out"
    try:
        r = cli("plan","--interface","eth0","--output",str(out))
        assert r.returncode == 3, f"got {r.returncode}"
        ok("T2: flag absent → exit 3 (authorization-required)")
    except Exception as e: nok("T2: flag-absent-exit3", str(e))

# ── T3: --allow-live-capture + dumpcap-free env → exit 2 (preflight gate-refuse) ──
with tempfile.TemporaryDirectory() as td:
    R = Path(td); out = R/"out"
    try:
        # Use an empty dir as PATH so dumpcap is unreachable — prevents any real capture.
        nodumpcap_dir = R/"nobin"; nodumpcap_dir.mkdir()
        e3 = os.environ.copy()
        e3.update({"RSDD_LIVE_CAPTURE_EXECUTOR": "", "PATH": str(nodumpcap_dir)})
        e3.pop("RSDD_CAPTURE_IFACES", None)
        r = subprocess.run(
            [sys.executable, str(sut), "plan", "--interface", "eth0",
             "--output", str(out), "--allow-live-capture"],
            capture_output=True, text=True, env=e3)
        assert r.returncode == 2, f"got {r.returncode}\n{r.stderr[:120]}"
        ok("T3: --allow-live-capture + dumpcap-free env → exit 2 (preflight gate-refuse)")
    except Exception as e: nok("T3: allow-live-capture-hard-refuse", str(e))

# ── T4: well-formed spec → correct plan with intended argv ────────────────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); out = R/"out"
    try:
        rc = m.plan_capture(m._parser([
            "plan","--interface","eth1","--bpf-filter","tcp port 443",
            "--snaplen","1500","--duration-seconds","120","--packet-count","5000",
            "--output",str(out),
        ]))
        assert rc == 3
        p = json.loads((out/"capture-plan.v1.json").read_text())
        assert p["schema_version"] == "capture-plan.v1", f"schema={p['schema_version']!r}"
        cs = p["capture_spec"]
        assert cs["interface"] == "eth1"
        assert cs["bpf_filter"] == "tcp port 443"
        assert cs["snaplen"] == 1500
        assert cs["duration_seconds"] == 120
        assert cs["packet_count_cap"] == 5000
        argv = p["planned_argv"]
        assert isinstance(argv, list), "planned_argv must be list"
        assert all(isinstance(a, str) for a in argv), "planned_argv elements must be str"
        assert "eth1" in argv, f"interface not in argv: {argv}"
        assert "tcp port 443" in argv, f"bpf filter not in argv: {argv}"
        ok("T4: well-formed spec → correct plan with intended argv")
    except Exception as e: nok("T4: well-formed-plan", str(e))

# ── T5: interface injection → clean structured error, exit 2, NOT in argv ─────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); out = R/"out"
    try:
        r = cli("plan","--interface","eth0; rm -rf /","--output",str(out))
        assert r.returncode == 2, f"got {r.returncode}"
        assert "Traceback" not in r.stderr, f"traceback in stderr: {r.stderr[:300]}"
        assert not (out/"capture-plan.v1.json").exists(), "plan must not be written on injection"
        ok("T5: interface injection → exit 2, no traceback, not written to plan")
    except Exception as e: nok("T5: interface-injection-rejected", str(e))

# ── T6: duration + packet caps bounded; defaults applied when omitted ─────────
with tempfile.TemporaryDirectory() as td:
    R = Path(td); out = R/"out"
    try:
        rc = m.plan_capture(m._parser(["plan","--interface","eth0","--output",str(out)]))
        assert rc == 3
        p = json.loads((out/"capture-plan.v1.json").read_text())
        cs = p["capture_spec"]
        assert isinstance(cs["duration_seconds"], int) and cs["duration_seconds"] > 0
        assert isinstance(cs["packet_count_cap"], int) and cs["packet_count_cap"] > 0
        assert isinstance(cs["snaplen"], int) and cs["snaplen"] > 0
        argv = p["planned_argv"]
        joined = " ".join(argv)
        assert str(cs["duration_seconds"]) in joined, f"duration not in argv: {argv}"
        assert str(cs["packet_count_cap"]) in joined, f"packet_count not in argv: {argv}"
        ok("T6: duration + packet caps bounded; defaults applied when omitted")
    except Exception as e: nok("T6: caps-and-defaults", str(e))

# ── T7: output /home → bind-scope exit 2 (no pcap written to host) ───────────
with tempfile.TemporaryDirectory() as td:
    try:
        r = cli("plan","--interface","eth0","--output","/home/capture-plan-unsafe")
        assert r.returncode == 2, f"got {r.returncode}"
        ok("T7: output under /home → exit 2 (bind-scope guard)")
    except Exception as e: nok("T7: bind-path-safety", str(e))

# ── T8: same spec → identical plan; det declared:false, basis:dry-run-plan ───
with tempfile.TemporaryDirectory() as td:
    R = Path(td); out1 = R/"r1"; out2 = R/"r2"
    try:
        m.plan_capture(m._parser(["plan","--interface","eth0","--output",str(out1)]))
        m.plan_capture(m._parser(["plan","--interface","eth0","--output",str(out2)]))
        p1 = json.loads((out1/"capture-plan.v1.json").read_text())
        p2 = json.loads((out2/"capture-plan.v1.json").read_text())
        assert p1 == p2, f"plans differ — not deterministic"
        det = json.loads((out1/"vm-determinism.v1.json").read_text())
        assert det["reproducible"]["declared"] is False
        assert det["reproducible"]["basis"] == "dry-run-plan"
        assert det["receipt_identity"] is None
        ok("T8: same input → identical plan; det declared:false, basis:dry-run-plan")
    except Exception as e: nok("T8: determinism-record-state", str(e))

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
mutant_bootstrap mutant_py_stage_control mutant_py_tooth mutant_py_crash_strict mutant_cleanup_register || exit 2
SELF="$HERE/$(basename "$0")"
MUT="$(mktemp -d)" || exit 2
mutant_cleanup_register "$MUT" || exit 2
tt() { if mutant_py_tooth "$1" "$HERE" "$SELF" "$MUT" "$REL" "${@:2}"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
echo "-- teeth: each guarded behaviour must be load-bearing (staged tree, one mutant per check) --"
if mutant_py_stage_control teeth-control "$HERE" "$SELF" "$MUT" "$REL"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
tt teeth-gate-flag 'run_gate_epilogue(CAP_LIVE_CAPTURE, args.allow_live_capture, plan' 'run_gate_epilogue(CAP_LIVE_CAPTURE, True, plan' 'FAIL  T2: flag-absent-exit3: got 0'
tt teeth-bpf-argv 'argv += ["-f", bpf]' 'argv += []' 'FAIL  T4: well-formed-plan: bpf filter not in argv'
tt teeth-iface-injection 'if not _IFACE_RE.fullmatch(name):' 'if False:' 'FAIL  T5: interface-injection-rejected: got 3'
tt teeth-duration-argv 'f"duration:{duration}",' '"duration:0",' 'FAIL  T6: caps-and-defaults: duration not in argv'
# Not mutated: T7 (bind-scope) - with assert_safe_bind_root off the run would mkdir/write under /home on the host; unsafe to execute.

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
