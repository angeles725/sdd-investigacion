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

NOTE: keep in sync with detonate_exec.py — both executors share the same
host-layer seam (pre_boot + snapshot_hook + run_vm delegation).  Only
SCHEMA_VERSION, class names, diagnostic/error-message strings, and comments differ.
"""
from __future__ import annotations
import hashlib, os, shutil, sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import docker_common as _dc    # noqa: E402
import vm_boot_core as _vbc   # noqa: E402
import vm_disk_policy as _vdp  # noqa: E402
from gate import GateError     # noqa: E402

# Evidence schema for the live trace receipt.
SCHEMA_VERSION: str = "trace-run.v1"

# Sentinel value emitted by trace_plan.build_plan for the scratch disk path.
# The live executor substitutes it with the actual per-run host path before Popen.
# NOTE: byte-identical to detonate_exec._SCRATCH_SENTINEL — keep in sync.
_SCRATCH_SENTINEL: str = "/rsdd/scratch.img"

# Pre-allocated scratch disk size (zeroed sparse blob; guest agent formats as needed).
_SCRATCH_SIZE: int = 4 * 1024 * 1024  # 4 MiB


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _sha256_o_nofollow(path: str) -> str:
    """sha256 of file at *path* opened with O_NOFOLLOW; return 'sha256:<hex>'.

    NOTE: byte-identical to detonate_exec._sha256_o_nofollow — keep in sync.
    """
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(path, flags)
    try:
        h = hashlib.sha256()
        while True:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            h.update(chunk)
        return "sha256:" + h.hexdigest()
    finally:
        os.close(fd)


def _preflight(plan: dict[str, Any]) -> None:
    """Defense-in-depth preflight for trace plans.  GateError → exit 2.

    Validates:
    (a) planned_argv is a list[str].
    (b) Per-drive containment policy via vm_disk_policy (run_dir=None; scope
        check deferred to evaluate() once run_dir is known).
    (c) qemu binary exists on PATH.
    (d) /tmp/rsdd is a real non-symlink directory.

    NOTE: structurally identical to detonate_exec._preflight — keep in sync.
    """
    argv = plan.get("planned_argv")
    if not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
        raise GateError("plan.planned_argv must be a list of strings")
    # Per-drive rules without scope check (run_dir not yet created).
    _vdp.check_disk_policy(argv, run_dir=None)
    # qemu binary must be on PATH.
    qbin = _vbc.resolve_qbin(plan, argv)
    if not qbin or shutil.which(qbin) is None:
        raise GateError(
            f"qemu binary {qbin!r} not found on PATH; "
            "install qemu-system and retry"
        )
    _dc.verify_rsdd_root()


def _thin_preflight(plan: dict[str, Any]) -> None:
    """Minimal preflight re-check passed to run_vm.

    evaluate() has already done full validation.  run_vm only needs the binary
    on PATH and /tmp/rsdd accessible (both are stable across the microsecond
    between evaluate() checks and run_vm's Popen call).

    NOTE: structurally identical to detonate_exec._thin_preflight — keep in sync.
    """
    argv = plan.get("planned_argv", [])
    qbin = _vbc.resolve_qbin(plan, argv)
    if not qbin or shutil.which(qbin) is None:
        raise GateError(
            f"qemu binary {qbin!r} not found on PATH (disappeared since preflight)"
        )
    _dc.verify_rsdd_root()


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

        Steps
        -----
        1. Preflight: per-drive containment belt + qbin on PATH (no run_dir scope yet).
        2. pre_boot closure (injected into run_vm): receives run_vm's single run_dir,
           creates fresh scratch.img there, substitutes _SCRATCH_SENTINEL in exec_argv,
           and re-checks disk_policy with the real run_dir (scope check live).
        3. snapshot_hook (injected into run_vm): hashes {run_dir}/scratch.img before
           boot (pre) and inside the guaranteed teardown region (post).  Hash failures
           are caught fail-soft by run_vm's _safe_snapshot — they never discard evidence.
        4. Delegate to vm_boot_core.run_vm (guaranteed reap/wall/receipt engine).
           run_vm creates and owns the SINGLE per-run directory; pre_boot writes
           scratch.img into it so output_files() scans it into outputs[].
        5. Inject argv_deltas + trace-run.v1 schema into the evidence dict.

        NOTE: structurally identical to detonate_exec.DetonateVmExecutor.evaluate —
        keep in sync.  GateError propagates unchanged (→ exit 2 at the CLI boundary).
        """
        # Step 1 — full preflight (no run_dir scope check yet; sentinel in argv is OK).
        _preflight(plan)

        # Step 2 — pre_boot closure: run_vm calls this AFTER creating its (single)
        # run_dir and AFTER preflight, BEFORE the pre-snapshot and Popen.
        # argv_deltas is captured by the closure and injected into ev in Step 5.
        argv_deltas: list[dict[str, Any]] = []

        def pre_boot(run_dir: str, exec_argv: list[str]) -> list[str]:
            """Create scratch.img in run_vm's run_dir; substitute sentinel in exec_argv."""
            scratch_path = f"{run_dir}/scratch.img"
            # Create fresh zeroed scratch disk (O_NOFOLLOW, fail-closed).
            try:
                flags = (os.O_WRONLY | os.O_CREAT | os.O_TRUNC
                         | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
                fd = os.open(scratch_path, flags, 0o600)
                try:
                    os.ftruncate(fd, _SCRATCH_SIZE)
                finally:
                    os.close(fd)
            except OSError as exc:
                raise GateError(
                    f"failed to create scratch disk at {scratch_path!r}: {exc}"
                ) from exc

            # Substitute _SCRATCH_SENTINEL → real per-run scratch path.
            new_argv: list[str] = []
            for tok in exec_argv:
                if _SCRATCH_SENTINEL in tok:
                    new_tok = tok.replace(_SCRATCH_SENTINEL, scratch_path)
                    argv_deltas.append({
                        "type": "scratch-sentinel-substitution",
                        "from": tok,
                        "to": new_tok,
                    })
                    new_argv.append(new_tok)
                else:
                    new_argv.append(tok)

            if not argv_deltas:
                raise GateError(
                    f"scratch sentinel {_SCRATCH_SENTINEL!r} not found in planned_argv; "
                    "trace plan must include the scratch sentinel drive"
                )

            # Re-check disk policy with real run_dir scope.
            _vdp.check_disk_policy(new_argv, run_dir=run_dir)
            return new_argv

        # Step 3 — snapshot hook: hash {run_dir}/scratch.img using run_dir param
        # (same single directory as pre_boot).  OSError propagates to run_vm's
        # _safe_snapshot helper, which catches it → None + stderr WARNING (fail-soft).
        def snapshot_hook(phase: str, run_dir: str) -> dict[str, str]:
            """sha256 of {run_dir}/scratch.img; phase is 'pre' or 'post'."""
            return {"sha256": _sha256_o_nofollow(f"{run_dir}/scratch.img")}

        # Step 4 — delegate to the shared boot/reap/receipt engine.
        # run_vm owns the single run_dir; pre_boot writes scratch.img into it so
        # output_files(run_dir) returns [scratch.img, serial.log] → outputs[] coherent.
        ev = _vbc.run_vm(
            plan, preflight=_thin_preflight,
            snapshot_hook=snapshot_hook, pre_boot=pre_boot,
        )

        # Step 5 — inject trace-specific fields.
        ev["schema_version"] = SCHEMA_VERSION
        ev["argv_deltas"] = argv_deltas  # override run_vm's empty list

        return ev
