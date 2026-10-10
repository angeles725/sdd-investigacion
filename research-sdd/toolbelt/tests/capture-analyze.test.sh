#!/usr/bin/env bash
# capture-analyze.test.sh — TDD RED→GREEN for analyze_pcap (C2 offline pcap handoff).
# RED: exits 2 (SUT not found) before lib/capture_analyze.py exists.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
if [ "${1:-}" = "--teeth-child" ]; then   # argument-selected SUT for the mutation teeth (fails closed below)
  ARG="${2:-}"
  [ -f "$ARG" ] || { echo "FATAL: --teeth-child needs an existing SUT file, got [$ARG]" >&2; exit 2; }
  echo "TEETH-CHILD: SUT=$ARG"
  case "$ARG" in */lib/*) ROOT="$(cd "$(dirname "$ARG")/.." && pwd)" ;; *) ROOT="$(cd "$(dirname "$ARG")" && pwd)" ;; esac
fi
SUT="$ROOT/lib/capture_analyze.py"
CE="$ROOT/lib/capture_exec.py"
PLAN="$ROOT/capture_plan.py"
if [ "${1:-}" = "--teeth-child" ]; then   # the mutated file replaces its own slot; every other slot stays in the staged tree
  case "$ARG" in
    */lib/*) case "$(basename "$ARG")" in
      capture_analyze.py) SUT="$ARG" ;;
      capture_exec.py) CE="$ARG" ;;
    esac ;;
    *) case "$(basename "$ARG")" in
      capture_plan.py) PLAN="$ARG" ;;
    esac ;;
  esac
fi
[ -f "$SUT" ] || { echo "FATAL: capture_analyze.py not found: $SUT" >&2; exit 2; }
[ -f "$CE" ] || { echo "FATAL: capture_exec.py not found: $CE" >&2; exit 2; }
[ -f "$PLAN" ] || { echo "FATAL: capture_plan.py not found: $PLAN" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
IFS= read -r -d '' PY_SRC <<'PY'
import importlib.util, json, os, struct, subprocess, sys, tempfile
from pathlib import Path

sut_path, ce_path, plan_path = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sys.path.insert(0, str(sut_path.parent))  # lib/ on path for gate, docker_common, etc.
sp = importlib.util.spec_from_file_location("capture_analyze", sut_path)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)

passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))

PCAP_MAGIC = struct.pack("<IHHIIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1)

# ── Shared fake dumpcap shim (mirror capture-exec.test.sh idiom) ─────────────────────
_DUMPCAP_SHIM = """\
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
    print("1. eth0 (Ethernet)"); sys.exit(int(os.environ.get("DUMPCAP_D_EXIT", "0")))
for i, a in enumerate(args):
    if a == "-w" and i + 1 < len(args):
        try:
            with open(args[i + 1], "wb") as f: f.write(PCAP_MAGIC)
        except: pass
        break
sl = float(os.environ.get("DUMPCAP_SLEEP", "0"))
if sl: time.sleep(sl)
sys.exit(int(os.environ.get("DUMPCAP_EXIT", "0")))
"""

# ── Analyzer stubs — env-controlled exit / sleep / record ────────────────────────────
_STUB = """\
#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
out = next((args[i+1] for i, a in enumerate(args) if a == "--output" and i+1 < len(args)), None)
rec = os.environ.get("STUB_RECORD", "")
if rec:
    try: c = json.loads(open(rec).read())
    except: c = []
    c.append(args); open(rec, "w").write(json.dumps(c))
sl = float(os.environ.get("STUB_SLEEP", "0"))
if sl: time.sleep(sl)
ec = int(os.environ.get("STUB_EXIT", "0"))
if out and ec == 0:
    with open(out, "w") as f: f.write(json.dumps({"schema": "stub", "ok": True}))
sys.exit(ec)
"""

_FAIL_STUB = """\
#!/usr/bin/env python3
import json, os, sys
rec = os.environ.get("STUB_RECORD", "")
if rec:
    try: c = json.loads(open(rec).read())
    except: c = []
    c.append(sys.argv[1:]); open(rec, "w").write(json.dumps(c))
sys.exit(2)
"""

# ── Helpers ──────────────────────────────────────────────────────────────────────────
def _shim(tmp: Path) -> str:
    p = tmp / "dumpcap"; p.write_text(_DUMPCAP_SHIM); p.chmod(0o755)
    return str(tmp) + ":" + os.environ.get("PATH", "")

def _make_stub(tmp: Path, name: str = "_stub.py", content: str | None = None) -> str:
    s = tmp / name; s.write_text(content if content is not None else _STUB); s.chmod(0o755)
    return str(s)

def _set_env(d: dict) -> dict:
    old = {k: os.environ.get(k) for k in d}
    os.environ.update(d); return old

def _restore_env(old: dict) -> None:
    for k, v in old.items():
        if v is None: os.environ.pop(k, None)
        else: os.environ[k] = v

def cli(*a, xe: dict | None = None):
    e = os.environ.copy()
    if xe: e.update(xe)
    return subprocess.run([sys.executable, str(plan_path), *map(str, a)],
                          capture_output=True, text=True, env=e)

Path("/tmp/rsdd").mkdir(exist_ok=True)

# ── T-STATIC: no in-process import of analyzers in capture_exec or capture_analyze ──
try:
    for path, label in [(ce_path, "capture_exec.py"), (sut_path, "capture_analyze.py")]:
        src = path.read_text()
        for banned in ("import corroborate_pcap", "import pcap_flows"):
            assert banned not in src, f"BANNED import found in {label}: {banned!r}"
    ok("T-STATIC: no 'import corroborate_pcap/pcap_flows' in capture_exec or capture_analyze")
except Exception as e: nok("T-STATIC", str(e))

# ── T-BEHAVIORAL: argv[0]==sys.executable, argv[1] endswith analyzer script path ─────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    pcap = tmp / "test.pcap"; pcap.write_bytes(PCAP_MAGIC)
    stub = _make_stub(tmp); rec = tmp / "rec.json"
    old = _set_env({"RSDD_CORROBORATE_PCAP": stub, "RSDD_PCAP_FLOWS": stub,
                    "STUB_RECORD": str(rec), "RSDD_PCAP_ANALYZER_TIMEOUT_S": "10"})
    try:
        res = m.analyze_pcap(str(pcap), str(tmp))
        assert res.get("attempted") is True, f"attempted={res.get('attempted')}"
        for entry in res.get("analyzers", []):
            argv = entry["argv"]
            assert argv[0] == sys.executable, f"argv[0]={argv[0]!r} != sys.executable"
            assert argv[1].endswith(".py"), f"argv[1]={argv[1]!r} not a .py script"
        ok("T-BEHAVIORAL: argv[0]==sys.executable AND argv[1] endswith .py (exec-of-file)")
    except Exception as e: nok("T-BEHAVIORAL", str(e))
    finally: _restore_env(old)

# ── T-ARGS: --input / --output / --manifest-cli exact paths; both analyzers in order ─
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    pcap = tmp / "test.pcap"; pcap.write_bytes(PCAP_MAGIC)
    stub = _make_stub(tmp); rec = tmp / "rec.json"
    old = _set_env({"RSDD_CORROBORATE_PCAP": stub, "RSDD_PCAP_FLOWS": stub,
                    "STUB_RECORD": str(rec), "RSDD_PCAP_ANALYZER_TIMEOUT_S": "10"})
    try:
        res = m.analyze_pcap(str(pcap), str(tmp))
        entries = res.get("analyzers", [])
        assert len(entries) == 2, f"expected 2 analyzers, got {len(entries)}"
        assert entries[0]["name"] == "corroborate_pcap", f"a[0].name={entries[0]['name']}"
        assert entries[1]["name"] == "pcap_flows",       f"a[1].name={entries[1]['name']}"
        for entry in entries:
            argv = entry["argv"]
            idx = argv.index("--input");        assert argv[idx+1] == str(pcap)
            idx = argv.index("--manifest-cli"); assert argv[idx+1].endswith("analysis_manifest.py")
        idx0 = entries[0]["argv"].index("--output")
        assert entries[0]["argv"][idx0+1].endswith("pcap-evidence.v1.json")
        idx1 = entries[1]["argv"].index("--output")
        assert entries[1]["argv"][idx1+1].endswith("pcap-flows.v1.json")
        ok("T-ARGS: --input/--output/--manifest-cli correct for both analyzers in order")
    except Exception as e: nok("T-ARGS", str(e))
    finally: _restore_env(old)

# ── T-RECEIPT: full CLI path — analysis key in capture-run.v1 output JSON ────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim(tmp)
    stub = _make_stub(tmp)
    r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
            "--allow-live-capture",
            xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0",
                "RSDD_CORROBORATE_PCAP": stub, "RSDD_PCAP_FLOWS": stub,
                "RSDD_PCAP_ANALYZER_TIMEOUT_S": "10"})
    try:
        assert r.returncode == 0, f"rc={r.returncode}\n{r.stderr[:200]}"
        res = json.loads(r.stdout)
        an = res.get("analysis", {})
        assert an.get("attempted") is True, f"analysis.attempted={an.get('attempted')}"
        entries = an.get("analyzers", [])
        assert len(entries) == 2, f"expected 2 entries, got {len(entries)}"
        assert entries[0].get("exit_code") == 0, f"a[0].exit_code={entries[0].get('exit_code')}"
        assert entries[1].get("exit_code") == 0, f"a[1].exit_code={entries[1].get('exit_code')}"
        ok("T-RECEIPT: CLI analysis key present with both analyzers exit_code=0")
    except Exception as e: nok("T-RECEIPT", str(e))

# ── T-FIRST-FAILS: corr exits 2, flows exits 0 — BOTH attempted (sequential continues) ─
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    pcap = tmp / "test.pcap"; pcap.write_bytes(PCAP_MAGIC)
    fail_stub = _make_stub(tmp, "fail.py", _FAIL_STUB)
    ok_stub   = _make_stub(tmp, "ok.py"); rec = tmp / "rec.json"
    old = _set_env({"RSDD_CORROBORATE_PCAP": fail_stub, "RSDD_PCAP_FLOWS": ok_stub,
                    "STUB_RECORD": str(rec), "RSDD_PCAP_ANALYZER_TIMEOUT_S": "10"})
    try:
        res = m.analyze_pcap(str(pcap), str(tmp))
        assert res.get("attempted") is True
        entries = res.get("analyzers", [])
        assert entries[0].get("exit_code") == 2, f"corr exit={entries[0].get('exit_code')}"
        assert entries[1].get("exit_code") == 0, f"flows exit={entries[1].get('exit_code')}"
        ok("T-FIRST-FAILS: corr exits 2; flows still attempted and exits 0")
    except Exception as e: nok("T-FIRST-FAILS", str(e))
    finally: _restore_env(old)

# ── T-TIMEOUT: stub sleeps 10, outer timeout=2 → timed_out=True, no CLI GateError ────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    pcap = tmp / "test.pcap"; pcap.write_bytes(PCAP_MAGIC)
    stub = _make_stub(tmp)
    old = _set_env({"RSDD_CORROBORATE_PCAP": stub, "RSDD_PCAP_FLOWS": stub,
                    "STUB_SLEEP": "10", "RSDD_PCAP_ANALYZER_TIMEOUT_S": "2"})
    try:
        res = m.analyze_pcap(str(pcap), str(tmp))
        assert res.get("attempted") is True
        entries = res.get("analyzers", [])
        assert entries[0].get("timed_out") is True, f"a[0].timed_out={entries[0].get('timed_out')}"
        ok("T-TIMEOUT: stub sleep 10 → outer timeout 2s → timed_out=True")
    except Exception as e: nok("T-TIMEOUT", str(e))
    finally: _restore_env(old)

# ── T-EMPTY: 0-byte pcap → attempted=False, skipped_reason set, zero spawns ──────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    pcap = tmp / "empty.pcap"; pcap.write_bytes(b"")
    stub = _make_stub(tmp); rec = tmp / "rec.json"
    old = _set_env({"RSDD_CORROBORATE_PCAP": stub, "RSDD_PCAP_FLOWS": stub,
                    "STUB_RECORD": str(rec), "RSDD_PCAP_ANALYZER_TIMEOUT_S": "10"})
    try:
        res = m.analyze_pcap(str(pcap), str(tmp))
        assert res.get("attempted") is False, f"attempted={res.get('attempted')}"
        assert "missing-or-empty-pcap" in (res.get("skipped_reason") or "")
        calls = json.loads(rec.read_text()) if rec.exists() else []
        assert calls == [], f"stubs were spawned: {calls}"
        ok("T-EMPTY: 0-byte pcap → attempted=False, skipped_reason, zero spawns")
    except Exception as e: nok("T-EMPTY", str(e))
    finally: _restore_env(old)

# ── T-GATE: allow=False → exit 3 (auth-required) AND zero analyzer spawns ────────────
with tempfile.TemporaryDirectory() as td:
    tmp = Path(td); p = _shim(tmp)
    stub = _make_stub(tmp); rec = tmp / "rec.json"
    r = cli("plan", "--interface", "eth0", "--output", str(tmp/"out"),
            xe={"PATH": p, "RSDD_LIVE_CAPTURE_EXECUTOR": "", "RSDD_CAPTURE_IFACES": "eth0",
                "RSDD_CORROBORATE_PCAP": stub, "RSDD_PCAP_FLOWS": stub,
                "STUB_RECORD": str(rec), "RSDD_PCAP_ANALYZER_TIMEOUT_S": "10"})
    try:
        assert r.returncode == 3, f"rc={r.returncode}"
        calls = json.loads(rec.read_text()) if rec.exists() else []
        assert calls == [], f"analyzers were spawned without --allow-live-capture: {calls}"
        ok("T-GATE: allow=False → exit 3, zero analyzer spawns")
    except Exception as e: nok("T-GATE", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
if [ "${1:-}" != "--prove-teeth" ]; then python3 -c "$PY_SRC" "$SUT" "$CE" "$PLAN"; exit $?; fi

# ── MUTATION TEETH (--prove-teeth) ─────────────────────────────────────────────
# Plain run first: its case lines are kept, its aggregate is replaced by ONE combined aggregate at the end
# (run-all.sh reads the LAST `== N passed · N failed ==` line).
py_out="$(python3 -c "$PY_SRC" "$SUT" "$CE" "$PLAN")"; py_rc=$?
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
if mutant_py_stage_control teeth-control "$HERE" "$SELF" "$MUT" "lib/capture_analyze.py"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
tt teeth-exit-code lib/capture_analyze.py '"exit_code":      exit_code,' '"exit_code":      0,' 'FAIL  T-FIRST-FAILS: corr exit=0'
tt teeth-timed-out lib/capture_analyze.py '            timed_out = True' '            timed_out = False' 'FAIL  T-TIMEOUT: a.0..timed_out=False'
tt teeth-empty-pcap lib/capture_analyze.py 'p.stat().st_size == 0' 'p.stat().st_size < 0' 'FAIL  T-EMPTY: attempted=True'
tt teeth-gate-allow capture_plan.py 'run_gate_epilogue(CAP_LIVE_CAPTURE, args.allow_live_capture, plan' 'run_gate_epilogue(CAP_LIVE_CAPTURE, True, plan' 'FAIL  T-GATE: rc='

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
