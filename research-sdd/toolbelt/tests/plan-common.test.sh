#!/usr/bin/env bash
# plan-common.test.sh — unit tests for lib/plan_common.py (U-24.2a)
# Tests the extracted shared plan-adapter helpers in isolation.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../lib/plan_common.py"; REL="lib/plan_common.py"
if [ "${1:-}" = "--teeth-child" ]; then   # argument-selected SUT for the mutation teeth (fails closed below)
  SUT="${2:-}"
  [ -f "$SUT" ] || { echo "FATAL: --teeth-child needs an existing SUT file, got [$SUT]" >&2; exit 2; }
  echo "TEETH-CHILD: SUT=$SUT"
fi
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
IFS= read -r -d '' PY_SRC <<'PY'
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

# ── PC-7: run_adapter_main — AdapterError → EXIT_ERROR (2), message on stderr ──
try:
    import io
    from adapter_core import AdapterError
    # run_adapter_main must exist
    if not hasattr(m, "run_adapter_main"):
        raise AttributeError("run_adapter_main not found in plan_common")
    captured_stderr = io.StringIO()
    with unittest.mock.patch("sys.stderr", captured_stderr):
        rc = m.run_adapter_main(
            lambda: (_ for _ in ()).throw(AdapterError("disk-full-test")),
            "test-adapter"
        )
    assert rc == 2, f"AdapterError case: expected EXIT_ERROR(2), got {rc}"
    err_text = captured_stderr.getvalue()
    assert "test-adapter: disk-full-test" in err_text, \
        f"missing 'prog: msg' in stderr: {err_text!r}"
    ok("PC-7: run_adapter_main: AdapterError → EXIT_ERROR (2), 'prog: msg' on stderr")
except Exception as e: nok("PC-7: run_adapter_main AdapterError", str(e))

# ── PC-8: run_adapter_main — OSError → EXIT_ERROR (2), message on stderr ────────
try:
    captured_stderr = io.StringIO()
    with unittest.mock.patch("sys.stderr", captured_stderr):
        rc = m.run_adapter_main(
            lambda: (_ for _ in ()).throw(OSError("no space left on device")),
            "test-adapter"
        )
    assert rc == 2, f"OSError case: expected EXIT_ERROR(2), got {rc}"
    err_text = captured_stderr.getvalue()
    assert "test-adapter: no space left on device" in err_text, \
        f"missing 'prog: msg' in stderr: {err_text!r}"
    ok("PC-8: run_adapter_main: OSError → EXIT_ERROR (2), 'prog: msg' on stderr")
except Exception as e: nok("PC-8: run_adapter_main OSError", str(e))

# ── PC-9: run_adapter_main — normal return passes through (auth-required=3, ok=0) ─
try:
    rc_auth = m.run_adapter_main(lambda: 3, "test-adapter")
    assert rc_auth == 3, f"auth-required return: expected 3, got {rc_auth}"
    rc_ok = m.run_adapter_main(lambda: 0, "test-adapter")
    assert rc_ok == 0, f"success return: expected 0, got {rc_ok}"
    rc_err = m.run_adapter_main(lambda: 2, "test-adapter")
    assert rc_err == 2, f"error return: expected 2, got {rc_err}"
    ok("PC-9: run_adapter_main: normal returns (0, 2, 3) pass through unchanged")
except Exception as e: nok("PC-9: run_adapter_main pass-through", str(e))

# ── PC-10: run_adapter_main — KeyboardInterrupt propagates (not swallowed) ──────
try:
    raised = False
    try:
        m.run_adapter_main(
            lambda: (_ for _ in ()).throw(KeyboardInterrupt()),
            "test-adapter"
        )
    except KeyboardInterrupt:
        raised = True
    assert raised, "KeyboardInterrupt was NOT re-raised by run_adapter_main"
    ok("PC-10: run_adapter_main: KeyboardInterrupt propagates (not swallowed)")
except Exception as e: nok("PC-10: run_adapter_main KeyboardInterrupt", str(e))

# ── PC-11: run_gate_epilogue passes plan_written=True to execute_or_plan ─────────
# RED before plan_common.py is updated: plan_written kwarg not passed → assertion fails.
# GREEN after: run_gate_epilogue explicitly passes plan_written=True.
try:
    from gate import CAP_EXEC as _CAP11
    _plan11 = {"schema_version": "test.v1"}
    _captured11: dict = {}
    def _fake_eop11(cap, allow, plan, **kwargs):
        _captured11.clear(); _captured11.update(kwargs)
        return {"outcome": "authorization-required"}
    with unittest.mock.patch.object(m, "execute_or_plan", side_effect=_fake_eop11):
        m.run_gate_epilogue(_CAP11, False, _plan11, None, "test-prefix")
    assert _captured11.get("plan_written") is True, (
        f"run_gate_epilogue must pass plan_written=True; captured kwargs: {_captured11!r}"
    )
    ok("PC-11: run_gate_epilogue passes plan_written=True to execute_or_plan")
except Exception as e: nok("PC-11: run_gate_epilogue plan_written=True", str(e))

# ── PC-RTO: read_target_once derives head, size and sha256 from ONE fd (#2077) ──
import hashlib
with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; data = b"\x7fELF" + bytes(range(60)) * 3; t.write_bytes(data)
    try:
        head, size, sha = m.read_target_once(t, None)
        assert head == data[:20] and size == len(data) and sha == "sha256:" + hashlib.sha256(data).hexdigest(), (head, size, sha)
        ok("PC-RTO1: head/size/sha256 match the file")
    except Exception as e: nok("PC-RTO1: head-size-sha-match", str(e))

with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(b"\x7fELF" + b"A"*64)
    ino = os.stat(t).st_ino; real_read = os.read; fired = []
    def mut_read(fd, n):
        if not fired and os.fstat(fd).st_ino == ino:
            fired.append(1)
            with open(t, "ab") as fh: fh.write(b"tail")
        return real_read(fd, n)
    try:
        with unittest.mock.patch("os.read", mut_read):
            try: m.read_target_once(t, None); got = "accepted"
            except m.AdapterError as exc: got = str(exc)
        assert fired, "mutation hook never fired"
        assert got.startswith("file changed while hashing"), f"in-place mutation mid-read: {got}"
        ok("PC-RTO2: in-place mutation after the header read -> refused")
    except Exception as e: nok("PC-RTO2: mutation-mid-read-refused", str(e))

with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; a = b"\x7fELF" + b"A"*64; t.write_bytes(a)
    ino = os.stat(t).st_ino; real_read = os.read; fired = []
    def over_read(fd, n):
        r = real_read(fd, n)
        if not fired and os.fstat(fd).st_ino == ino:
            fired.append(1)
            with open(t, "r+b") as fh: fh.write(b"\x7fELF" + b"B"*8)   # same size, header bytes rewritten
        return r
    try:
        with unittest.mock.patch("os.read", over_read):
            try: head, _, sha = m.read_target_once(t, None); got = (head, sha)
            except m.AdapterError: got = None
        assert fired, "overwrite hook never fired"
        if got is not None:
            assert got[0] == a[:20] and got[1] == "sha256:" + hashlib.sha256(a).hexdigest(), f"header/hash disagree: {got}"
        ok("PC-RTO3: same-size overwrite after the header read -> refused or head/sha from the same bytes")
    except Exception as e: nok("PC-RTO3: header-hash-agreement", str(e))

with tempfile.TemporaryDirectory() as td:
    R = Path(td); t = R/"t.bin"; t.write_bytes(b"\x7fELF" + b"A"*64); ln = R/"ln"; ln.symlink_to(t); d = R/"d"; d.mkdir()
    def refusal(p, cap):
        try: m.read_target_once(p, cap); return "accepted"
        except m.AdapterError as exc: return str(exc)
    try:
        assert refusal(ln, None) == f"cannot open regular non-symlink file: {ln}", refusal(ln, None)
        assert refusal(d, None) == f"not a regular file: {d}", refusal(d, None)
        assert refusal(t, 8) == "input exceeds max-input-bytes", refusal(t, 8)
        ok("PC-RTO4: symlink / directory / over-cap refused with identity's exact messages")
    except Exception as e: nok("PC-RTO4: refusal-messages", str(e))

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

tt teeth-PC-4a 'if ":" in path_str or "," in path_str:' 'if "," in path_str:' 'FAIL  PC-4a: colon not rejected'
tt teeth-PC-6b $'if result.get("outcome") == "authorization-required":\n        return EXIT_AUTH_REQUIRED' $'if result.get("outcome") == "authorization-required":\n        return 0' 'FAIL  PC-6: run_gate_epilogue: auth case: expected 3, got 0'
tt teeth-PC-7 'except (AdapterError, OSError) as exc:' 'except OSError as exc:' 'FAIL  PC-7: run_adapter_main AdapterError: disk-full-test'
tt teeth-PC-10 'except (AdapterError, OSError) as exc:' 'except BaseException as exc:' 'FAIL  PC-10: run_adapter_main KeyboardInterrupt: KeyboardInterrupt was NOT re-raised'

tt teeth-rto-fstat-recheck 'if fields(before) != fields(after) or total != before.st_size:' 'if False:' 'FAIL  PC-RTO2: mutation-mid-read-refused'
tt teeth-rto-seed-digest 'digest = hashlib.sha256(); digest.update(head); total = len(head)' 'os.lseek(fd, 0, os.SEEK_SET); digest = hashlib.sha256(); total = 0; before = os.fstat(fd)' 'FAIL  PC-RTO3: header-hash-agreement'
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
