#!/usr/bin/env bash
# plan-common.test.sh — unit tests for lib/plan_common.py (U-24.2a)
# Tests the extracted shared plan-adapter helpers in isolation.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../lib/plan_common.py"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
python3 - "$SUT" <<'PY'
import importlib.util, json, os, re, sys, tempfile, unittest.mock
from pathlib import Path
sut = Path(sys.argv[1])
sys.path.insert(0, str(sut.parent))          # lib/ (so gate imports work)
sp = importlib.util.spec_from_file_location("plan_common", sut)
m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
passed = 0; failed = 0
def ok(n): global passed; passed += 1; print(f"  PASS  {n}")
def nok(n, r=""): global failed; failed += 1; print(f"  FAIL  {n}" + (f": {r}" if r else ""))

# ── PC-1: PlanOnlyExecutor.evaluate returns correct shape with parameterized sv ─
try:
    sv = "test-plan.v1"
    ex = m.PlanOnlyExecutor(sv)
    result = ex.evaluate({})
    assert result["schema_version"] == sv, f"schema_version={result['schema_version']!r}"
    assert result["executed"] is False, "executed must be False"
    assert result["outputs"] == [], f"outputs={result['outputs']!r}"
    assert result["limitations"] == ["outputs-unknown-until-live-run"], \
        f"limitations={result['limitations']!r}"
    ok("PC-1: PlanOnlyExecutor.evaluate returns correct shape with parameterized schema_version")
except Exception as e: nok("PC-1: PlanOnlyExecutor.evaluate", str(e))

# ── PC-2: select_executor seam — False→PlanOnlyExecutor, True→None ─────────────
try:
    sv = "emba-plan.v1"
    ex = m.select_executor(False, sv)
    assert isinstance(ex, m.PlanOnlyExecutor), f"expected PlanOnlyExecutor, got {type(ex)}"
    assert ex.evaluate({})["schema_version"] == sv, "schema_version mismatch"
    live = m.select_executor(True, sv)
    assert live is None, f"expected None for allow_live=True, got {live!r}"
    ok("PC-2: select_executor(False,...) → PlanOnlyExecutor; select_executor(True,...) → None")
except Exception as e: nok("PC-2: select_executor", str(e))

# ── PC-3: make_dry_run_det_spec — correct canonical fields, new dict each call ──
try:
    spec = m.make_dry_run_det_spec()
    assert spec["schema_version"] == "vm-determinism.v1", \
        f"schema_version={spec['schema_version']!r}"
    assert spec["receipt_identity"] is None
    assert spec["seed"] == 0
    assert spec["clock"] == {"mode": "pinned", "epoch": "1970-01-01T00:00:00Z"}, \
        f"clock={spec['clock']!r}"
    lc = spec["limits_conformance"]
    for k in ("cpu_within", "mem_within", "wall_within", "output_within"):
        assert lc[k] is False, f"limits_conformance.{k} must be False"
    assert spec["reproducible"] == {"basis": "dry-run-plan", "replicate_identity": None}, \
        f"reproducible={spec['reproducible']!r}"
    spec2 = m.make_dry_run_det_spec()
    assert spec is not spec2, "must return a new dict each call (not a shared singleton)"
    ok("PC-3: make_dry_run_det_spec returns canonical dry-run spec, new dict each call")
except Exception as e: nok("PC-3: make_dry_run_det_spec", str(e))

# ── PC-4: reject_mount_delimiters rejects ':' and ',', passes clean path ─────
class _MntErr(Exception): pass
try:
    # colon
    try:
        m.reject_mount_delimiters("/tmp/bad:path", "test path", _MntErr)
        nok("PC-4a: colon not rejected"); raise AssertionError
    except _MntErr as exc:
        assert "bind-mount" in str(exc), f"'bind-mount' missing from: {exc}"
        ok("PC-4a: reject_mount_delimiters rejects ':' with bind-mount message")
    # comma
    try:
        m.reject_mount_delimiters("/tmp/bad,path", "test path", _MntErr)
        nok("PC-4b: comma not rejected"); raise AssertionError
    except _MntErr as exc:
        assert "bind-mount" in str(exc)
        ok("PC-4b: reject_mount_delimiters rejects ',' with bind-mount message")
    # clean path must not raise
    m.reject_mount_delimiters("/tmp/clean-path", "test path", _MntErr)
    ok("PC-4c: reject_mount_delimiters passes clean path without raising")
except AssertionError: pass  # sub-test already nok'd above
except Exception as e: nok("PC-4: reject_mount_delimiters", str(e))

# ── PC-5: validate_token — empty / leading-dash / bad-charset / valid ─────────
_PAT_SIMPLE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
class _VErr(Exception): pass
try:
    # empty string → exc
    try:
        m.validate_token("", "label", _PAT_SIMPLE, _VErr)
        nok("PC-5a: empty string not rejected"); raise AssertionError
    except _VErr: ok("PC-5a: validate_token rejects empty string")
    # leading dash → exc
    try:
        m.validate_token("--evil", "label", _PAT_SIMPLE, _VErr)
        nok("PC-5b: leading-dash not rejected"); raise AssertionError
    except _VErr: ok("PC-5b: validate_token rejects leading dash")
    # bad charset (space) → exc
    try:
        m.validate_token("bad value", "label", _PAT_SIMPLE, _VErr)
        nok("PC-5c: bad charset not rejected"); raise AssertionError
    except _VErr: ok("PC-5c: validate_token rejects bad charset (space)")
    # valid → returns value unchanged
    r = m.validate_token("valid-token.v1", "label", _PAT_SIMPLE, _VErr)
    assert r == "valid-token.v1", f"expected 'valid-token.v1', got {r!r}"
    ok("PC-5d: validate_token returns valid value unchanged")
    # regex is parameterized — a different pattern rejects different inputs
    _PAT_STRICT = re.compile(r'^[a-z]+$')
    try:
        m.validate_token("MixedCase", "label", _PAT_STRICT, _VErr)
        nok("PC-5e: stricter pattern not enforced"); raise AssertionError
    except _VErr: ok("PC-5e: validate_token uses caller's regex (strict pattern rejects MixedCase)")
except AssertionError: pass
except Exception as e: nok("PC-5: validate_token", str(e))

# ── PC-6: run_gate_epilogue — GateError→2, auth-required→3, success→0 ────────
# Use patch.object(m, ...) so the patch targets the module object directly
# (importlib.util loads do not register in sys.modules by name).
try:
    from gate import CAP_EXEC, GateError, EXIT_AUTH_REQUIRED
    plan = {"schema_version": "test.v1"}
    # GateError → 2
    with unittest.mock.patch.object(m, "execute_or_plan",
                                     side_effect=GateError("deliberate-error")):
        rc = m.run_gate_epilogue(CAP_EXEC, False, plan, None, "test-prefix")
    assert rc == 2, f"GateError case: expected 2, got {rc}"
    ok("PC-6a: run_gate_epilogue: GateError → exit 2")
    # outcome=='authorization-required' → EXIT_AUTH_REQUIRED (3)
    auth_dict = {"outcome": "authorization-required"}
    with unittest.mock.patch.object(m, "execute_or_plan", return_value=auth_dict):
        rc = m.run_gate_epilogue(CAP_EXEC, False, plan, None, "test-prefix")
    assert rc == EXIT_AUTH_REQUIRED == 3, f"auth case: expected 3, got {rc}"
    ok("PC-6b: run_gate_epilogue: authorization-required outcome → EXIT_AUTH_REQUIRED (3)")
    # success result → exit 0
    ok_dict = {"outcome": "plan-recorded"}
    with unittest.mock.patch.object(m, "execute_or_plan", return_value=ok_dict):
        rc = m.run_gate_epilogue(CAP_EXEC, True, plan, None, "test-prefix")
    assert rc == 0, f"success case: expected 0, got {rc}"
    ok("PC-6c: run_gate_epilogue: success outcome → exit 0")
    # executor.evaluate is passed as live_executor when executor is not None
    sv = "test-plan.v1"
    ex = m.PlanOnlyExecutor(sv)
    captured = {}
    def _fake_eop(cap, allow, plan, live_executor=None, **kw):
        captured["live_executor"] = live_executor
        return {"outcome": "done"}
    with unittest.mock.patch.object(m, "execute_or_plan", side_effect=_fake_eop):
        m.run_gate_epilogue(CAP_EXEC, True, plan, ex, "test-prefix")
    lv = captured.get("live_executor")
    assert lv is not None and getattr(lv, "__self__", None) is ex, \
        f"live_executor not bound to executor: {captured}"
    ok("PC-6d: run_gate_epilogue passes executor.evaluate as live_executor when executor is not None")
except Exception as e: nok("PC-6: run_gate_epilogue", str(e))

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PY
