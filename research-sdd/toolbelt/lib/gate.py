#!/usr/bin/env python3
"""Fail-closed gate authorization — Research-SDD gated adapters (U-F1).
Capability → CLI flag → test-seam env var:
  exec  --allow-exec  RSDD_EXEC_EXECUTOR | live-capture  --allow-live-capture  RSDD_LIVE_CAPTURE_EXECUTOR
  docker  --allow-docker  RSDD_DOCKER_EXECUTOR
Default OFF, fail-closed. See gate-authorization.v1.md.
"""
from __future__ import annotations
import argparse, importlib.util, json, os, sys
from pathlib import Path
from typing import Any, Callable

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
from adapter_core import AdapterError, write as _write        # noqa: E402
from adapter_helpers import assert_safe_bind_root, BindScopeError  # noqa: E402

# Capability tokens
CAP_EXEC         = "exec"
CAP_LIVE_CAPTURE = "live-capture"
CAP_DOCKER       = "docker"
CAPABILITIES: frozenset[str] = frozenset({CAP_EXEC, CAP_LIVE_CAPTURE, CAP_DOCKER})
_CAP_FLAG: dict[str, str] = {
    CAP_EXEC: "--allow-exec", CAP_LIVE_CAPTURE: "--allow-live-capture", CAP_DOCKER: "--allow-docker",
}
# Each cap owns exactly one env var — no cross-cap bleed is possible.
_CAP_ENV: dict[str, str] = {
    CAP_EXEC: "RSDD_EXEC_EXECUTOR", CAP_LIVE_CAPTURE: "RSDD_LIVE_CAPTURE_EXECUTOR",
    CAP_DOCKER: "RSDD_DOCKER_EXECUTOR",
}
EXIT_AUTH_REQUIRED: int = 3  # distinct from generic error (2)
EXIT_ERROR: int = 2          # hard refuse or error (gate contract)


class GateError(AdapterError):
    """Hard gate failure (no live executor / unknown cap / bad path) → exit 2."""


def cap_flag(cap: str) -> str:
    """CLI flag for *cap*; GateError if unknown."""
    try: return _CAP_FLAG[cap]
    except KeyError: raise GateError(f"unknown capability: {cap!r}; known: {sorted(CAPABILITIES)}")


def cap_env_var(cap: str) -> str:
    """Test-seam env var name for *cap*; GateError if unknown."""
    try: return _CAP_ENV[cap]
    except KeyError: raise GateError(f"unknown capability: {cap!r}; known: {sorted(CAPABILITIES)}")


def build_auth_required(
    cap: str, plan: dict[str, Any], would_be_receipt_spec: dict[str, Any] | None = None,
    *, plan_written: bool = False,
) -> dict[str, Any]:
    """Build the authorization-required result dict (7 required fields, always present)."""
    flag = cap_flag(cap)
    recorded = (
        " The offline run-plan has been recorded; no live resource was touched."
        if plan_written else
        " No live resource was touched."
    )
    return {
        "schema_version": "gate-authorization.v1",
        "outcome": "authorization-required", "capability": cap, "flag": flag,
        "message": (
            f"Capability {cap!r} requires {flag}. Pass {flag} to enable live execution.{recorded}"
        ),
        "plan": plan, "would_be_receipt_spec": would_be_receipt_spec,
    }


def require_capability(
    cap: str, allow: bool, plan: dict[str, Any],
    would_be_receipt_spec: dict[str, Any] | None = None,
) -> dict[str, Any] | None:
    """None if authorized (allow=True); auth-required dict if allow=False. GateError on unknown cap."""
    if cap not in CAPABILITIES:
        raise GateError(f"unknown capability: {cap!r}; known: {sorted(CAPABILITIES)}")
    return None if allow else build_auth_required(cap, plan, would_be_receipt_spec)


def execute_or_plan(
    cap: str, allow: bool, plan: dict[str, Any],
    live_executor: Callable[[dict[str, Any]], dict[str, Any]] | None = None,
    would_be_receipt_spec: dict[str, Any] | None = None,
    output_dir: Path | None = None,
    plan_written: bool | None = None,
) -> dict[str, Any]:
    """Gate entry point.

    allow=False  → write offline plan to output_dir (if given, path-checked); return auth-required.
    allow=True   → resolve executor (RSDD_<CAP>_EXECUTOR env var, then live_executor arg).
                   GateError if neither is available (caller exits 2). NEVER cross-cap bleed.
    Executor seam failure contract: if the resolved executor raises at runtime, the exception
    is wrapped in GateError and the gate exits 2; no raw traceback propagates to the CLI.

    plan_written: optional override for the auth-required message.  When None (default),
    the value is derived from output_dir (plan_written = output_dir is not None), preserving
    backward-compatible behavior.  Pass plan_written=True explicitly when the caller already
    wrote its own plan file to disk BEFORE calling execute_or_plan (e.g. run_gate_epilogue),
    so the gate-authorization message correctly says the plan was recorded.
    """
    if cap not in CAPABILITIES:
        raise GateError(f"unknown capability: {cap!r}; known: {sorted(CAPABILITIES)}")
    if not allow:
        if output_dir is not None:
            _write_offline(plan, would_be_receipt_spec, output_dir)
        _plan_written = plan_written if plan_written is not None else (output_dir is not None)
        return build_auth_required(cap, plan, would_be_receipt_spec,
                                   plan_written=_plan_written)
    # Authorized path: cap-scoped env var only — no other cap's var is read here.
    stub_path = os.environ.get(_CAP_ENV[cap], "").strip()
    if stub_path:
        executor: Callable[[dict[str, Any]], dict[str, Any]] = _load_stub(stub_path)
    elif live_executor is not None:
        executor = live_executor
    else:
        raise GateError(
            f"live executor not implemented for {cap!r}; "
            f"pass live_executor= or set {_CAP_ENV[cap]} for testing"
        )
    try:
        return executor(plan)
    except GateError:
        raise
    except Exception as exc:
        raise GateError(f"executor raised during {cap!r} execution: {exc}") from exc


def _load_stub(path_str: str) -> Callable[[dict[str, Any]], dict[str, Any]]:
    """Load test-seam executor from Python file (must export execute(plan)->dict).

    Path-scope guard (mirrors _write_offline's assert_safe_bind_root): the
    realpath of *path_str* must satisfy the same bind-scope constraints as
    any host path bound into a sandbox.  This prevents arbitrary code loading
    from credential-bearing or system-root paths via the RSDD_*_EXECUTOR seam.
    """
    resolved = os.path.realpath(path_str)
    try:
        assert_safe_bind_root(Path(resolved))
    except BindScopeError as exc:
        raise GateError(f"stub path is outside the allowed scope: {exc}") from exc
    # Scope-check note: reuses assert_safe_bind_root for parity with _write_offline.
    # Residual: constrains system-root/shallow-home paths but does NOT lock the stub to a
    # dedicated trusted root (/tmp/<sub>/x.py remains loadable). Accepted — the seam is
    # env-gated (RSDD_*_EXECUTOR). Resolving once closes the symlink-swap TOCTOU window.
    path = Path(resolved)          # load the same resolved path that was scope-checked
    if not path.is_file():
        raise GateError(f"RSDD executor stub not found: {path_str!r}")
    ms = importlib.util.spec_from_file_location("_rsdd_gate_stub", path)
    if ms is None or ms.loader is None:
        raise GateError(f"stub is not a loadable Python module: {path_str!r}")
    mod = importlib.util.module_from_spec(ms)
    try:
        ms.loader.exec_module(mod)
    except Exception as exc:
        raise GateError(f"stub failed to load ({type(exc).__name__}): {path_str!r}") from exc
    fn = getattr(mod, "execute", None)
    if not callable(fn):
        raise GateError(f"stub has no callable 'execute': {path_str!r}")
    return fn


def _write_offline(
    plan: dict[str, Any], receipt_spec: dict[str, Any] | None, output_dir: Path,
) -> None:
    """Write gate-plan.json (+ optional would-be-receipt-spec.json) after bind-root check."""
    assert_safe_bind_root(Path(os.path.realpath(output_dir)))
    output_dir.mkdir(parents=True, exist_ok=True)
    _write(output_dir / "gate-plan.json", plan)
    if receipt_spec is not None:
        _write(output_dir / "would-be-receipt-spec.json", receipt_spec)


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="gate.py", description="Research-SDD gate authorization")
    sub = ap.add_subparsers(dest="cmd")
    ch = sub.add_parser("authorize")
    ch.add_argument("--cap", required=True, choices=sorted(CAPABILITIES))
    ch.add_argument("--allow-exec",         action="store_true", default=False)
    ch.add_argument("--allow-live-capture", action="store_true", default=False)
    ch.add_argument("--allow-docker",       action="store_true", default=False)
    ch.add_argument("--plan", required=True, type=Path)
    ch.add_argument("--output-dir", type=Path, default=None)
    args = ap.parse_args(argv)
    if args.cmd is None:
        ap.print_help(); sys.exit(EXIT_ERROR)
    allow_map = {CAP_EXEC: args.allow_exec, CAP_LIVE_CAPTURE: args.allow_live_capture,
                 CAP_DOCKER: args.allow_docker}
    try: plan = json.loads(args.plan.read_text())
    except (OSError, json.JSONDecodeError) as exc: print(f"error: {exc}", file=sys.stderr); sys.exit(EXIT_ERROR)
    if not isinstance(plan, dict):
        print("error: plan must be a JSON object (dict)", file=sys.stderr); sys.exit(EXIT_ERROR)
    try:
        result = execute_or_plan(args.cap, allow_map[args.cap], plan, output_dir=args.output_dir)
    except GateError as exc: print(f"error: {exc}", file=sys.stderr); sys.exit(EXIT_ERROR)
    print(json.dumps(result, indent=2, sort_keys=True))
    if result.get("outcome") == "authorization-required":
        sys.exit(EXIT_AUTH_REQUIRED)


if __name__ == "__main__":
    main()
