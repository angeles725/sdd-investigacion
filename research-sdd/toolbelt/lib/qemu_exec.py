#!/usr/bin/env python3
"""Live QEMU system-mode boot executor — disposable-VM isolation substrate (V1b).
Spawns qemu-system-{arch} in a per-run bwrap subdir; stdout (serial -nographic) captured.
NEVER boots a real VM in CI. Real boot = user's gated manual step.
Selected locally in qemu_plan.py when --allow-exec AND mode==qemu-system.
NEVER in plan_common.select_executor. RSDD_EXEC_EXECUTOR env stub wins (gate.py:113).
Boot engine extracted to vm_boot_core.py (D0 refactor); evaluate() delegates there.
"""
from __future__ import annotations
import os, shutil, stat, sys, tempfile
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import docker_common as _dc    # noqa: E402
import vm_boot_core as _vbc   # noqa: E402
import vm_pin as _vp          # noqa: E402
from gate import GateError     # noqa: E402

# Re-export schema version from the boot engine for any callers that import it here.
SCHEMA_VERSION: str = _vbc.SCHEMA_VERSION

# V1a containment flags that MUST appear in planned_argv.
_REQUIRED = frozenset({"-nic", "-nodefaults", "-snapshot", "-sandbox", "-accel", "-smp", "--unshare-net"})
# Flags forbidden WHOLESALE (any occurrence → GateError). Includes -net/-netdev so
# -net user,hostfwd=... and -net tap are both refused; the legit plan never emits them.
_FORBIDDEN = frozenset({"-virtfs", "-fsdev", "-enable-kvm", "-runas", "-net", "-netdev"})
# -device values that must never appear (host passthrough / guest-to-host FS vectors).
_DEVICE_DENY_PREFIXES = ("vfio", "virtio-9p")
# Value predicates enforced on EVERY occurrence of each flag (not just the first).
_VALUE_OK = {
    "-nic":     lambda v: v == "none",
    "-accel":   lambda v: v == "tcg",
    "-sandbox": lambda v: v.startswith("on") and "=allow" not in v,
    "-smp":     lambda v: v == "1",
    "-drive":   lambda v: "readonly=on" in v or "snapshot=on" in v,
}


def _check_argv(argv: list[str]) -> None:
    """Single-pass argv scanner: REQUIRED presence check then per-flag predicates on
    EVERY occurrence. Replaces the old index()-based _check_containment (first-occurrence
    only) and _check_forbidden (missed -net variants, dead 9p token, no -smp bound).

    Scans the FULL argv including the bwrap prefix (same scope as before); a bwrap
    value that collides with a flag name fails closed — acceptable for a
    malware-isolation substrate where a plan dict is untrusted input.
    """
    missing = sorted(_REQUIRED - set(argv))
    if missing:
        raise GateError(f"planned_argv missing required containment flag(s): {missing}")
    for i, tok in enumerate(argv):
        nxt = argv[i + 1] if i + 1 < len(argv) else ""
        if tok in _FORBIDDEN:
            raise GateError(f"planned_argv contains forbidden flag {tok!r}")
        if tok == "-device" and nxt.startswith(_DEVICE_DENY_PREFIXES):
            raise GateError(f"planned_argv -device {nxt!r} forbidden (passthrough/9p refused)")
        rule = _VALUE_OK.get(tok)
        if rule and not rule(nxt):
            raise GateError(f"planned_argv {tok} value {nxt!r} violates containment")


def _rsdd_root() -> str:
    """Host run-dir root: $RSDD_VM_ROOT (explicit override, used by the test suite sandbox), else /tmp/rsdd (#2061)."""
    return os.environ.get("RSDD_VM_ROOT") or _dc._DEFAULT_RSDD_ROOT


def _pin_target(plan: dict[str, Any], argv: list[str], stage: str) -> list[str]:
    """Bind exec to the planned identity (#2078): pin the target via vm_pin (open once, hash the copy,
    refuse on mismatch) and point the bwrap --ro-bind source at the private copy."""
    tgt = plan.get("target") or {}
    path = tgt.get("path", "")
    if not path:
        return argv
    dest = _vp.pin_file(path, tgt.get("sha256"), tgt.get("size"), stage, "kernel/target", "boot")
    return _vp.rebind_source(argv, path, dest)


def _preflight(plan: dict[str, Any]) -> None:
    """Defense-in-depth preflight. GateError → exit 2 on any violation."""
    if plan.get("mode") == "qemu-user":
        raise GateError(
            "qemu-user mode uses host-kernel translation — refused; "
            "only qemu-system is bootable in this executor"
        )
    argv = plan.get("planned_argv")
    if not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
        raise GateError("plan.planned_argv must be a list of strings")
    _check_argv(argv)
    # qemu binary on PATH
    qbin = _vbc.resolve_qbin(plan, argv)
    if not qbin or shutil.which(qbin) is None:
        raise GateError(f"qemu binary {qbin!r} not found on PATH; install qemu and retry")
    # Kernel target: must exist as a non-symlink regular file
    tgt = plan.get("target", {}).get("path", "")
    if tgt:
        try:
            st = Path(tgt).lstat()
        except OSError as exc:
            raise GateError(f"kernel/target path inaccessible: {exc}") from exc
        if stat.S_ISLNK(st.st_mode):
            raise GateError(f"kernel/target is a symlink (rejected: TOCTOU): {tgt!r}")
        if not stat.S_ISREG(st.st_mode):
            raise GateError(f"kernel/target is not a regular file: {tgt!r}")
    root = _rsdd_root()
    if root != _dc._DEFAULT_RSDD_ROOT:
        os.makedirs(root, mode=0o700, exist_ok=True)
    _dc.verify_rsdd_root(root)


class LiveQemuBootExecutor:
    """Live QEMU system-mode boot executor. Satisfies _HasEvaluate protocol.
    Selected locally in qemu_plan.py; NEVER in plan_common.select_executor.
    """

    def __init__(self, output_dir: Path) -> None:
        self._output_dir = output_dir

    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:
        """Boot qemu-system; return vm-boot-run.v1 dict. GateError on preflight fail (exit 2).
        Wall-timeout → labeled outcome 'timeout-killed'; process-TREE reaped via killpg.
        Delegates to vm_boot_core.run_vm with snapshot_hook=None (V1b: snapshots stay null).
        """
        stage = tempfile.mkdtemp(prefix="rsdd-qemu-target-")  # private 0700, honours TMPDIR
        try:
            return _vbc.run_vm(
                plan, preflight=_preflight, snapshot_hook=None,
                pre_boot=lambda run_dir, argv: _pin_target(plan, argv, stage),
                root=_rsdd_root(),
            )
        finally:
            shutil.rmtree(stage, ignore_errors=True)
