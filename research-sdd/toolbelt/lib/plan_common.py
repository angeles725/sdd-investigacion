#!/usr/bin/env python3
"""Shared plan-adapter boilerplate for Research-SDD toolbelt plan adapters (U-24.2a).

Extracted from emba_plan.py, fact_plan.py, vm_run.py. Remaining adapters
(trace_plan.py, qemu_plan.py, detonate_plan.py, capture_plan.py) migrate in U-24.2b.

All helpers are behavior-preserving extractions: identical logic, no functional change.
Dependency direction: plan_common → gate → adapter_core (never the reverse).
"""
from __future__ import annotations
import json, re, sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from gate import execute_or_plan, EXIT_AUTH_REQUIRED, GateError  # noqa: E402

# Re-export EXIT_AUTH_REQUIRED so callers can import it from here if needed.
__all__ = [
    "PlanOnlyExecutor",
    "select_executor",
    "make_dry_run_det_spec",
    "run_gate_epilogue",
    "reject_mount_delimiters",
    "validate_token",
    "EXIT_AUTH_REQUIRED",
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

def run_gate_epilogue(
    cap: str,
    allow: bool,
    plan: dict[str, Any],
    executor: PlanOnlyExecutor | None,
    prefix: str,
) -> int:
    """Common gate-routing tail shared by all plan adapters.

    - Calls execute_or_plan with live_executor=executor.evaluate (or None).
    - GateError → print to stderr, return 2.
    - outcome == 'authorization-required' → return EXIT_AUTH_REQUIRED (3).
    - Success → print JSON result to stdout, return 0.

    prefix is the adapter name used in error messages (e.g. 'emba-plan').
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
# 5. Generic charset token validator
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
