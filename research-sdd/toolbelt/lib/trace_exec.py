#!/usr/bin/env python3
"""Live in-VM trace executor — disposable-VM isolation (D3).

Boots a qemu-system-<arch> VM carrying the target disk.  The guest-side
rsdd-agent reads the tracer selection from the kernel cmdline
(rsdd.tracer=strace|ltrace|gdb-batch) and wraps the sample accordingly,
writing trace output to the scratch disk.  Pre-boot and post-teardown sha256
of the scratch disk populate ``vm_pre_snapshot`` / ``vm_post_snapshot`` in
the frozen ``vm-run-receipt.v1``.

Host attack surface is IDENTICAL to DetonateVmExecutor (D2).  Containment is
enforced by the SAME shared ``vm_disk_policy.check_disk_policy``.  The only
delta from detonate is guest-side: the rsdd-agent wraps the sample in the
requested tracer instead of executing it directly.

Real in-guest tracing is the HUMAN'S GATED MANUAL STEP.  This module is
OFFLINE-testable: the fake qemu shim in tests/ stands in for the binary.
NEVER traces real malware in CI.

Selected locally in trace_plan.py when ``--allow-exec``.
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

# Evidence schema for the live trace receipt.
SCHEMA_VERSION: str = "trace-run.v1"


# ---------------------------------------------------------------------------
# Public executor
# ---------------------------------------------------------------------------

class TraceVmExecutor:
    """Live in-VM trace executor (strace/ltrace/gdb-batch via guest-side agent).

    Satisfies the _HasEvaluate protocol (duck-typed by run_gate_epilogue).
    Selected locally in trace_plan.py; NEVER in plan_common.select_executor.

    Host containment is IDENTICAL to DetonateVmExecutor: same bwrap namespace
    isolation, same qemu -nic none/-accel tcg/-sandbox on belt, same per-drive
    disk policy enforced by the shared vm_disk_policy module.  The only delta
    is guest-side: the rsdd-agent wraps the sample in the requested tracer.
    """

    def __init__(self, output_dir: Path) -> None:
        self._output_dir = output_dir

    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:
        """Boot qemu-system with target+scratch+rootfs disk slots; populate snapshot hashes.

        Delegates to the shared vm_exec_common.run_evaluate seam.  This executor
        contributes only its schema_version (``trace-run.v1``) and plan_label
        (``trace``) for diagnostic strings.

        GateError propagates unchanged (→ exit 2 at the CLI boundary).
        """
        return run_evaluate(plan, SCHEMA_VERSION, "trace")
