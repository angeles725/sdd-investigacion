#!/usr/bin/env python3
"""Shared plan-adapter boilerplate for Research-SDD toolbelt plan adapters (U-24.2a/b).

6 of 7 plan adapters use the shared helpers here: emba_plan, fact_plan, vm_run,
trace_plan, qemu_plan, detonate_plan. capture_plan keeps a local PlanOnlyExecutor
variant by design — its limitations string is "outputs-unknown-until-live-capture"
(not "outputs-unknown-until-live-run"), as required by capture-plan.v1.md.

All helpers are behavior-preserving extractions: identical logic, no functional change.
Dependency direction: plan_common → gate → adapter_core (never the reverse).
"""
from __future__ import annotations
import json, re, sys
from pathlib import Path
from typing import Any, Callable, Protocol

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from adapter_core import AdapterError                                        # noqa: E402
from gate import execute_or_plan, EXIT_AUTH_REQUIRED, EXIT_ERROR, GateError  # noqa: E402

# Re-export key symbols so callers can import them from here.
__all__ = [
    "PlanOnlyExecutor",
    "select_executor",
    "make_dry_run_det_spec",
    "run_gate_epilogue",
    "run_adapter_main",
    "reject_mount_delimiters",
    "validate_token",
    "add_max_input_bytes_arg",
    "EXIT_AUTH_REQUIRED",
    "EXIT_ERROR",
    "GateError",
]


# ---------------------------------------------------------------------------
# 1. PlanOnlyExecutor + select_executor seam
# ---------------------------------------------------------------------------

class PlanOnlyExecutor:
    """Offline executor: no subprocess, records executed=False.

    schema_version is the adapter's own schema identifier string
    (e.g. 'emba-plan.v1', 'fact-plan.v1', 'vm-run-plan.v1').
    Identical to the local PlanOnlyExecutor defined in each plan adapter;
    extracted here to remove the 7-copy duplication (D2).
    """

    def __init__(self, schema_version: str) -> None:
        self._schema_version = schema_version

    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:
        return {
            "schema_version": self._schema_version,
            "executed": False,
            "outputs": [],
            "limitations": ["outputs-unknown-until-live-run"],
        }


def select_executor(allow_live: bool, schema_version: str) -> PlanOnlyExecutor | None:
    """PlanOnlyExecutor for dry-run; None when live (gate hard-refuses, seam still works)."""
    return None if allow_live else PlanOnlyExecutor(schema_version)


# ---------------------------------------------------------------------------
# 2. Dry-run determinism-spec builder
# ---------------------------------------------------------------------------

def make_dry_run_det_spec() -> dict[str, Any]:
    """Return the canonical dry-run vm-determinism.v1 spec dict (new dict each call).

    Every plan adapter uses this identical spec: declared=False, basis=dry-run-plan,
    receipt_identity=None, seed=0, clock pinned to UNIX epoch, all limits False.
    Pass the returned dict directly to build_determinism() from vm_plan.
    """
    return {
        "schema_version": "vm-determinism.v1",
        "receipt_identity": None,
        "seed": 0,
        "clock": {"mode": "pinned", "epoch": "1970-01-01T00:00:00Z"},
        "limits_conformance": {
            "cpu_within": False,
            "mem_within": False,
            "wall_within": False,
            "output_within": False,
        },
        "reproducible": {"basis": "dry-run-plan", "replicate_identity": None},
    }


# ---------------------------------------------------------------------------
# 3. Gate epilogue helper
# ---------------------------------------------------------------------------

class _HasEvaluate(Protocol):
    """Duck-typed executor contract: any object with evaluate(plan)->dict satisfies this.

    The shared PlanOnlyExecutor (above) and capture_plan's local PlanOnlyExecutor both
    satisfy this Protocol even though they are distinct classes. capture_plan's variant
    uses "outputs-unknown-until-live-capture" while the shared one uses
    "outputs-unknown-until-live-run" — they must remain separate (see capture-plan.v1.md).
    """
    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]: ...


def run_gate_epilogue(
    cap: str,
    allow: bool,
    plan: dict[str, Any],
    executor: _HasEvaluate | None,
    prefix: str,
) -> int:
    """Common gate-routing tail shared by all plan adapters.

    - Calls execute_or_plan with live_executor=executor.evaluate (or None).
    - GateError → print to stderr, return 2.
    - outcome == 'authorization-required' → return EXIT_AUTH_REQUIRED (3).
    - Success → print JSON result to stdout, return 0.

    prefix is the adapter name used in error messages (e.g. 'emba-plan').
    executor is duck-typed (_HasEvaluate): accepts the shared PlanOnlyExecutor and
    capture_plan's local variant without requiring a common base class.
    """
    try:
        result = execute_or_plan(
            cap, allow, plan,
            live_executor=executor.evaluate if executor is not None else None,
            would_be_receipt_spec=None,
            output_dir=None,
        )
    except GateError as exc:
        print(f"{prefix}: {exc}", file=sys.stderr)
        return 2
    if result.get("outcome") == "authorization-required":
        return EXIT_AUTH_REQUIRED
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


# ---------------------------------------------------------------------------
# 4. Bind-mount delimiter guard
# ---------------------------------------------------------------------------

def reject_mount_delimiters(path_str: str, what: str, exc_cls: type) -> None:
    """-v colon and --mount comma delimiter guard for Docker bind-mount paths.

    Raises exc_cls when path_str contains ':' or ',', which cannot be safely
    expressed in a Docker bind-mount spec without losing the read-only
    least-privilege guarantee (lesson from U-D17 / D3 dedup).

    what is a human-readable label (e.g. 'firmware path', 'compose-file path').
    exc_cls is the adapter's error class (e.g. EmbaPlanError, FactPlanError).
    """
    if ":" in path_str or "," in path_str:
        raise exc_cls(
            f"{what} contains a character unsafe for a Docker bind-mount spec"
            f" (':' or ','): {path_str}"
        )


# ---------------------------------------------------------------------------
# 5. Optional input-size cap argument (F2 — U-24.F2)
# ---------------------------------------------------------------------------

def add_max_input_bytes_arg(p: Any) -> None:
    """Add --max-input-bytes N to a plan-adapter argparse sub-parser.

    Default: None (absent or not set) → zero behavior change; no cap is passed
    to identity(), and the adapter behaves byte-identically to its pre-F2 state.

    When set to N: identity() is called with max_bytes=N.  Inputs whose size
    exceeds N bytes fail closed with AdapterError("input exceeds max-input-bytes"),
    which each adapter catches and converts to a clean stderr message + exit 2.

    This is the canonical single place that documents and registers the flag;
    importing it from plan_common avoids six near-identical copies across adapters.
    """
    p.add_argument(
        "--max-input-bytes",
        type=int, default=None, dest="max_input_bytes",
        metavar="N",
        help="Optional input-size cap in bytes (default: unlimited). "
             "When set, inputs exceeding N bytes are rejected with exit 2 "
             "(fail-closed via adapter_core.identity max_bytes). "
             "Absent/None: behavior is byte-identical to the pre-F2 baseline.",
    )


# ---------------------------------------------------------------------------
# 6. Generic charset token validator
# ---------------------------------------------------------------------------

def validate_token(
    value: str,
    label: str,
    pat: re.Pattern[str],
    exc_cls: type,
) -> str:
    """Generic charset + leading-dash validator; raises exc_cls on violation.

    Each adapter keeps its OWN regex constant (pat) so the allowed charset is
    never merged or loosened across adapters — this is a security invariant.
    For example, emba's _TAG_RE and _PROFILE_RE remain byte-for-byte unchanged
    in emba_plan.py; only the validation logic is shared here.

    Checks (in order):
    1. value must not be empty.
    2. value must not start with '-' (prevents leading-dash injection).
    3. value must fully match pat (charset guard).
    """
    if not value:
        raise exc_cls(f"{label} must not be empty")
    if value.startswith("-"):
        raise exc_cls(f"{label} must not start with '-': {value!r}")
    if not pat.fullmatch(value):
        raise exc_cls(f"{label} has unsafe chars: {value!r}")
    return value


# ---------------------------------------------------------------------------
# 7. Shared adapter-main outer error handler
# ---------------------------------------------------------------------------

def run_adapter_main(fn: Callable[[], int], prog: str) -> int:
    """Shared outer error handler for plan-adapter main() entry points.

    Calls fn() and returns its result normally. If fn() raises AdapterError
    (including subclasses GateError, BindScopeError) or OSError (e.g. EROFS,
    EACCES, ENOSPC, ENOTDIR from output_dir.mkdir() or adapter_core.write()
    during a disk failure or unexpected FS condition), prints '<prog>: <msg>'
    to stderr and returns EXIT_ERROR (2).

    KeyboardInterrupt and SystemExit are NOT caught and propagate normally.
    Normal return values from fn() — including EXIT_AUTH_REQUIRED (3) from
    run_gate_epilogue when authorization is required — pass through unchanged.
    auth-required is a normal integer return, not an exception, so it is never
    remapped to 2 by this wrapper.

    Wire each adapter's plan_xxx() call in main() through this wrapper so that
    disk failures produce a clean "<adapter>: <msg>" stderr line and exit 2
    instead of a Python traceback and exit 1.
    """
    try:
        return fn()
    except (AdapterError, OSError) as exc:
        print(f"{prog}: {exc}", file=sys.stderr)
        return EXIT_ERROR
