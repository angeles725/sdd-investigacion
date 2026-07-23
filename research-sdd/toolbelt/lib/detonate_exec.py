#!/usr/bin/env python3
"""Live hostile-sample detonation executor — disposable-VM isolation (D2).

Boots a qemu-system-<arch> VM carrying the sample disk.  Pre-boot and
post-teardown sha256 of the scratch disk populate ``vm_pre_snapshot`` /
``vm_post_snapshot`` in the frozen ``vm-run-receipt.v1``.

Real in-guest detonation is the HUMAN'S GATED MANUAL STEP.  This module is
OFFLINE-testable: the fake qemu shim in tests/ stands in for the binary.
NEVER detonates real malware in CI.

Selected locally in detonate_plan.py when ``--allow-exec``.
NEVER in plan_common.select_executor.
RSDD_EXEC_EXECUTOR env stub wins (gate.py:113).
Boot engine: vm_boot_core.run_vm (guaranteed reap/teardown/wall-bound).
"""
from __future__ import annotations
import sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from vm_exec_common import run_evaluate  # noqa: E402

# Evidence schema for the live detonation receipt.
SCHEMA_VERSION: str = "detonate-run.v1"


# ---------------------------------------------------------------------------
# Public executor
# ---------------------------------------------------------------------------

class DetonateVmExecutor:
    """Live hostile-sample VM detonation executor.

    Satisfies the _HasEvaluate protocol (duck-typed by run_gate_epilogue).
    Selected locally in detonate_plan.py; NEVER in plan_common.select_executor.
    """

    def __init__(self, output_dir: Path) -> None:
        self._output_dir = output_dir

    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:
        """Boot qemu-system with sample+scratch+rootfs disk slots; populate snapshot hashes.

        Delegates to the shared vm_exec_common.run_evaluate seam.  This executor
        contributes only its schema_version (``detonate-run.v1``) and plan_label
        (``detonate``) for diagnostic strings.

        GateError propagates unchanged (→ exit 2 at the CLI boundary).
        """
        return run_evaluate(plan, SCHEMA_VERSION, "detonate")
