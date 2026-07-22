#!/usr/bin/env bash
# gate.test.sh — contract tests for gate-authorization (U-F1)
# TDD RED → GREEN: all assertions written before lib/gate.py existed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../lib/gate.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
import importlib.util, json, os, subprocess, sys, tempfile
from pathlib import Path

sut = Path(sys.argv[1])
sp = importlib.util.spec_from_file_location("gate", sut)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))
def cli(*a, xe=None):
    e = os.environ.copy()
    if xe: e.update(xe)
    return subprocess.run([sys.executable, str(sut), *map(str, a)], capture_output=True, text=True, env=e)

PLAN = {"schema": "gate-plan.v1", "tool": "t", "argv": ["/bin/t"]}
CAPS = [m.CAP_EXEC, m.CAP_LIVE_CAPTURE, m.CAP_DOCKER]
ALL_EVS = {m.cap_env_var(c): None for c in CAPS}

# helper: clear seam env vars, return backup for restoration
def _clear():
    bk = {m.cap_env_var(c): os.environ.pop(m.cap_env_var(c), None) for c in CAPS}
    return bk
def _restore(bk):
    for k, v in bk.items():
        if v is not None: os.environ[k] = v

# ── 1: constants, flag mapping, and unknown-cap fail-closed ───────────────
try:
    assert m.CAP_EXEC == "exec" and m.CAP_LIVE_CAPTURE == "live-capture" and m.CAP_DOCKER == "docker"
    flags = {m.cap_flag(c) for c in CAPS}
    assert flags == {"--allow-exec", "--allow-live-capture", "--allow-docker"}, str(flags)
    try: m.execute_or_plan("bad-cap", False, PLAN); nok("unknown cap should raise GateError")
    except m.GateError: pass
    ok("constants: 3 distinct flags; unknown capability → GateError (fail-closed)")
except Exception as e: nok("constants / unknown cap", str(e))

# ── 2: allow=False → auth-required result + executor never invoked ──────────
try:
    _executor_called = []
    def _sentinel_executor(p):
        _executor_called.append(True)
        raise AssertionError("executor must not be called when allow=False")
    r = m.execute_or_plan(m.CAP_EXEC, False, PLAN, live_executor=_sentinel_executor)
    assert not _executor_called, f"live_executor was called {len(_executor_called)} time(s)"
    assert r["outcome"] == "authorization-required" and r["capability"] == "exec"
    assert r["flag"] == "--allow-exec"
    for f in ("message", "plan", "would_be_receipt_spec", "schema_version"): assert f in r, f"missing {f!r}"
    ok("allow=False → auth-required (7 fields present) + executor never invoked")
except Exception as e: nok("allow=False behavior", str(e))

# ── 3: allow=True + no executor → GateError for all 3 caps; CLI exit 2 ────
bk = _clear()
try:
    for c in CAPS:
        try: m.execute_or_plan(c, True, PLAN, live_executor=None)
        except m.GateError: ok(f"allow=True + no executor ({c!r}) → GateError (hard refuse)")
        except Exception as e: nok(f"hard refuse ({c!r})", str(e))
finally: _restore(bk)
with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as _f:
    json.dump(PLAN, _f); pp = Path(_f.name)
try:
    r = cli("authorize", "--cap", "exec", "--allow-exec", "--plan", pp,
            xe={m.cap_env_var(c): "" for c in CAPS})
    if r.returncode == 2: ok("CLI: --allow-exec + no executor → exit 2")
    else: nok("CLI hard refuse exit code", f"got {r.returncode}\nstderr={r.stderr[:150]}")
finally: pp.unlink(missing_ok=True)

# ── 4: CLI: flag absent → exit EXIT_AUTH_REQUIRED (3) ─────────────────────
with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as _f:
    json.dump(PLAN, _f); pp = Path(_f.name)
try:
    r = cli("authorize", "--cap", "exec", "--plan", pp)
    if r.returncode == m.EXIT_AUTH_REQUIRED:
        ok(f"CLI: flag absent → exit {m.EXIT_AUTH_REQUIRED} (authorization-required)")
    else: nok("CLI flag-absent exit code", f"got {r.returncode}")
finally: pp.unlink(missing_ok=True)

# ── 5: RSDD_EXEC_EXECUTOR stub called exactly once with the plan ───────────
with tempfile.TemporaryDirectory() as _td:
    tp = Path(_td); rec = tp / "calls.json"; stub = tp / "s.py"
    stub.write_text(
        "import json; from pathlib import Path\n"
        f"_r=Path({str(rec)!r})\n"
        "def execute(p):\n"
        "    c=json.loads(_r.read_text()) if _r.exists() else []\n"
        "    c.append(p);_r.write_text(json.dumps(c))\n"
        "    return{'outcome':'executed','plan':p}\n"
    )
    ev = m.cap_env_var(m.CAP_EXEC); old = os.environ.get(ev)
    os.environ[ev] = str(stub)
    try:
        result = m.execute_or_plan(m.CAP_EXEC, True, PLAN)
        calls = json.loads(rec.read_text()) if rec.exists() else []
        assert len(calls) == 1 and calls[0] == PLAN and result["outcome"] == "executed"
        ok("RSDD_EXEC_EXECUTOR stub called exactly once with correct plan")
    except Exception as e: nok("RSDD_EXEC_EXECUTOR stub", str(e))
    finally:
        if old is not None: os.environ[ev] = old
        else: os.environ.pop(ev, None)

# ── 6: cross-cap isolation — exec seam ↛ live-capture; docker seam ↛ exec ─
with tempfile.TemporaryDirectory() as _td:
    stub = Path(_td) / "s.py"
    stub.write_text("def execute(p): return {'outcome':'ok','plan':p}\n")
    bk = _clear()
    os.environ[m.cap_env_var(m.CAP_EXEC)] = str(stub)
    try:
        try: m.execute_or_plan(m.CAP_LIVE_CAPTURE, True, PLAN)
        except m.GateError: ok("cross-cap: exec seam does not authorize live-capture")
        except Exception as e: nok("cross-cap exec→lc", str(e))
    finally: _restore(bk)
    bk2 = _clear()
    os.environ[m.cap_env_var(m.CAP_DOCKER)] = str(stub)
    try:
        try: m.execute_or_plan(m.CAP_EXEC, True, PLAN)
        except m.GateError: ok("cross-cap: docker seam does not authorize exec")
        except Exception as e: nok("cross-cap docker→exec", str(e))
    finally: _restore(bk2)

# ── 7: auth-required schema stable + require_capability semantics ──────────
try:
    for c in CAPS:
        r = m.build_auth_required(c, PLAN)
        for f in ("outcome","capability","flag","message","plan","would_be_receipt_spec","schema_version"):
            assert f in r, f"missing {f!r} for {c!r}"
        assert r["outcome"] == "authorization-required" and r["capability"] == c
    assert m.require_capability(m.CAP_EXEC, True, PLAN) is None
    _r = m.require_capability(m.CAP_DOCKER, False, PLAN)
    assert _r["outcome"] == "authorization-required" and _r["capability"] == m.CAP_DOCKER
    ok("auth-required schema: 7 fields × 3 caps; require_capability None/auth-required")
except Exception as e: nok("schema stability + require_capability", str(e))

# ── 8: path safety — output_dir=/home raises bind-scope error ──────────────
try:
    from adapter_helpers import BindScopeError; from adapter_core import AdapterError
    try: m.execute_or_plan(m.CAP_EXEC, False, PLAN, output_dir=Path("/home"))
    except (BindScopeError, AdapterError, m.GateError):
        ok("path safety: output_dir=/home → bind-scope error (fail-closed)")
    except Exception as e: nok("path safety /home type", str(e))
except Exception as e: nok("path safety (outer)", str(e))

# ── 9: _load_stub robustness — non-.py and stub raising ImportError → GateError ─
with tempfile.TemporaryDirectory() as _td9:
    _tp9 = Path(_td9); _ev9 = m.cap_env_var(m.CAP_EXEC); _old9 = os.environ.get(_ev9)
    # 9a: non-.py extension (spec/loader None) → GateError, not AttributeError traceback
    _sh9 = _tp9 / "bad.sh"; _sh9.write_text("#!/bin/bash\necho bad\n")
    os.environ[_ev9] = str(_sh9)
    try:
        try: m.execute_or_plan(m.CAP_EXEC, True, PLAN)
        except m.GateError: ok("stub non-.py extension → GateError (not raw AttributeError)")
        except Exception as e: nok("stub non-.py ext type", str(e))
    finally:
        if _old9 is not None: os.environ[_ev9] = _old9
        else: os.environ.pop(_ev9, None)
    # 9b: .py stub that raises ImportError on exec_module → GateError, not traceback
    _bad9 = _tp9 / "bad.py"; _bad9.write_text("raise ImportError('missing-dep')\n")
    os.environ[_ev9] = str(_bad9)
    try:
        try: m.execute_or_plan(m.CAP_EXEC, True, PLAN)
        except m.GateError: ok("stub ImportError on load → GateError (not raw traceback)")
        except Exception as e: nok("stub ImportError type", str(e))
    finally:
        if _old9 is not None: os.environ[_ev9] = _old9
        else: os.environ.pop(_ev9, None)
# 9c: CLI — non-.py stub → exit 2 without traceback on stderr
with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as _f9:
    json.dump(PLAN, _f9); _pp9 = Path(_f9.name)
with tempfile.TemporaryDirectory() as _td9c:
    _sh9c = Path(_td9c) / "bad.sh"; _sh9c.write_text("#!/bin/bash\n")
    _r9 = cli("authorize", "--cap", "exec", "--allow-exec", "--plan", _pp9,
              xe={m.cap_env_var(m.CAP_EXEC): str(_sh9c)})
    if _r9.returncode == 2 and "Traceback" not in _r9.stderr:
        ok("CLI: non-.py stub → exit 2 without traceback")
    else: nok("CLI non-.py stub", f"exit={_r9.returncode} stderr={_r9.stderr[:200]}")
_pp9.unlink(missing_ok=True)

# ── 10: execute_or_plan wraps a raising executor → GateError / exit 2 ────────
with tempfile.TemporaryDirectory() as _td10:
    _stub10 = Path(_td10) / "raiser.py"
    _stub10.write_text("def execute(p): raise RuntimeError('boom from executor')\n")
    _ev10 = m.cap_env_var(m.CAP_EXEC); _old10 = os.environ.get(_ev10)
    os.environ[_ev10] = str(_stub10)
    try:
        try: m.execute_or_plan(m.CAP_EXEC, True, PLAN)
        except m.GateError: ok("executor raises RuntimeError → GateError (seam wrapped)")
        except Exception as e: nok("executor-raises type", str(e))
    finally:
        if _old10 is not None: os.environ[_ev10] = _old10
        else: os.environ.pop(_ev10, None)
with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as _f10:
    json.dump(PLAN, _f10); _pp10 = Path(_f10.name)
with tempfile.TemporaryDirectory() as _td10c:
    _stub10c = Path(_td10c) / "raiser.py"
    _stub10c.write_text("def execute(p): raise RuntimeError('boom from executor')\n")
    _r10 = cli("authorize", "--cap", "exec", "--allow-exec", "--plan", _pp10,
               xe={m.cap_env_var(m.CAP_EXEC): str(_stub10c)})
    if _r10.returncode == 2:
        ok("CLI: executor raises → exit 2 (not 1 / raw traceback)")
    else: nok("CLI executor-raises exit", f"exit={_r10.returncode} stderr={_r10.stderr[:200]}")
_pp10.unlink(missing_ok=True)

# ── 11: executor precedence — RSDD env var wins over live_executor arg ────────
with tempfile.TemporaryDirectory() as _td11:
    _rec11 = Path(_td11) / "winner.txt"
    _stub11 = Path(_td11) / "env_stub.py"
    _stub11.write_text(
        "from pathlib import Path\n"
        f"_r=Path({str(_rec11)!r})\n"
        "def execute(p): _r.write_text('env-stub'); return{'outcome':'env-stub','plan':p}\n"
    )
    _ev11 = m.cap_env_var(m.CAP_EXEC); _old11 = os.environ.get(_ev11)
    os.environ[_ev11] = str(_stub11)
    _live_called11 = []
    def _live_ex11(p): _live_called11.append(True); return {"outcome": "live-executor", "plan": p}
    try:
        _res11 = m.execute_or_plan(m.CAP_EXEC, True, PLAN, live_executor=_live_ex11)
        assert _rec11.exists() and _rec11.read_text() == "env-stub", "env stub did not run"
        assert not _live_called11, "live_executor was invoked despite RSDD env var being set"
        assert _res11["outcome"] == "env-stub", f"wrong outcome: {_res11['outcome']}"
        ok("executor precedence: RSDD env var wins over live_executor arg")
    except Exception as e: nok("executor precedence", str(e))
    finally:
        if _old11 is not None: os.environ[_ev11] = _old11
        else: os.environ.pop(_ev11, None)

# ── 12: build_auth_required message accuracy — output_dir=None → no "recorded" claim ─
try:
    _r12 = m.execute_or_plan(m.CAP_EXEC, False, PLAN, output_dir=None)
    assert "recorded" not in _r12["message"], (
        f"message falsely claims plan was recorded when output_dir=None: {_r12['message']!r}"
    )
    ok("allow=False + output_dir=None → message does not claim plan was recorded")
except Exception as e: nok("message accuracy output_dir=None", str(e))
with tempfile.TemporaryDirectory() as _td12:
    _od12 = Path(_td12) / "out"
    try:
        _r12b = m.execute_or_plan(m.CAP_EXEC, False, PLAN, output_dir=_od12)
        assert "recorded" in _r12b["message"], (
            f"message missing 'recorded' claim when output_dir given: {_r12b['message']!r}"
        )
        ok("allow=False + output_dir set → message claims plan was recorded")
    except Exception as e: nok("message accuracy output_dir set", str(e))

# ── 13: plan must be a JSON object — [] → exit 2 (schema validation) ─────────
with tempfile.NamedTemporaryFile(suffix=".json", mode="w", delete=False) as _f13:
    json.dump([], _f13); _pp13 = Path(_f13.name)
try:
    _r13 = cli("authorize", "--cap", "exec", "--plan", _pp13)
    if _r13.returncode == 2:
        ok("CLI: plan=[] (non-dict) → exit 2 (schema validation)")
    else: nok("plan non-dict exit code", f"exit={_r13.returncode} stderr={_r13.stderr[:150]}")
finally:
    _pp13.unlink(missing_ok=True)

# ── 14: execute_or_plan plan_written=True override → message claims plan recorded ─
# RED before gate.py adds plan_written param: TypeError → test fails.
# GREEN after: plan_written=True causes build_auth_required to say "recorded".
try:
    _r14 = m.execute_or_plan(m.CAP_EXEC, False, PLAN, plan_written=True)
    assert "recorded" in _r14["message"], (
        f"plan_written=True override: message should claim 'recorded': {_r14['message']!r}"
    )
    ok("allow=False + plan_written=True override → message claims plan was recorded")
except Exception as e: nok("plan_written=True override", str(e))

print(f"== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
