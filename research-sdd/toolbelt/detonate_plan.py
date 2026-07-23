#!/usr/bin/env python3
"""Hostile-sample DETONATION PLAN (dry-run) adapter (U-V11 / item 11).
Produces detonate-plan.v1 + vm-determinism.v1. NEVER executes: no VM boot,
no subprocess spawned, no sample detonated. Live exec gated behind --allow-exec.
See gate-authorization.v1.md and detonate-plan.v1.md.

D1 rebuild: planned_argv now emits the qemu-system+disk form (see detonate-plan.v1.md).
Global -snapshot replaced by per-drive containment policy (lib/vm_disk_policy.py).
Live DetonateVmExecutor is wired in D2; D1 remains plan-only.
"""
from __future__ import annotations
import argparse, os, struct, sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent; _LIB = _HERE / "lib"
for _p in (str(_LIB), str(_HERE)):
    if _p not in sys.path: sys.path.insert(0, _p)

from adapter_core import AdapterError, identity as _file_identity, write as _write  # noqa: E402
from adapter_helpers import assert_safe_bind_root, BindScopeError              # noqa: E402
from gate import CAP_EXEC                                                       # noqa: E402
from vm_plan import build_determinism, VmDeterminismError                      # noqa: E402
from plan_common import (                                                        # noqa: E402
    PlanOnlyExecutor, select_executor, make_dry_run_det_spec, run_gate_epilogue,
    run_adapter_main, add_max_input_bytes_arg,
)

SCHEMA_VERSION = "detonate-plan.v1"
_DEFAULT_CPU = 30; _DEFAULT_MEM = 256 << 20; _DEFAULT_WALL = 60; _DEFAULT_OUT = 128 << 20

# Plan-time sentinel for the scratch disk path.
# The live executor (D2) substitutes the actual per-run path before calling Popen.
_SCRATCH_SENTINEL: str = "/rsdd/scratch.img"
_DEFAULT_KERNEL: str = "/rsdd/vmlinuz"
_DEFAULT_ROOTFS: str = "/rsdd/rootfs.img"

# ELF e_machine → qemu-system arch suffix.
# NOTE: byte-identical to qemu_plan._EM_TO_QEMU — keep in sync manually.
# Not imported to avoid promoting a private symbol across module boundaries.
_EM_TO_QEMU: dict[int, str] = {
    3: "i386", 8: "mips", 20: "ppc", 21: "ppc64",
    40: "arm", 42: "sh4", 62: "x86_64", 183: "aarch64", 243: "riscv64",
}

_MAGIC_HINTS: list[tuple[bytes, str]] = [
    (b"\x7fELF",          "elf"),
    (b"MZ",               "pe"),
    (b"\xca\xfe\xba\xbe", "macho-fat"),
    (b"PK\x03\x04",       "zip"),
    (b"\x1f\x8b",         "gzip"),
]


class DetonatePlanError(AdapterError): ...


def _sniff_type(path: Path) -> str:
    """Read 4 bytes O_NOFOLLOW → type hint; 'unknown' on any error (metadata-only)."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
        try: magic = os.read(fd, 4)
        finally: os.close(fd)
    except OSError:
        return "unknown"
    for sig, hint in _MAGIC_HINTS:
        if magic[:len(sig)] == sig: return hint
    return "unknown"


def _sniff_arch(path: Path) -> str:
    """Read ELF e_machine O_NOFOLLOW → qemu arch suffix; 'x86_64' on any fault."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
        try: hdr = os.read(fd, 20)
        finally: os.close(fd)
    except OSError:
        return "x86_64"
    if len(hdr) < 20 or hdr[:4] != b"\x7fELF":
        return "x86_64"
    ei_data = hdr[5]
    if ei_data == 1: fmt = "<H"
    elif ei_data == 2: fmt = ">H"
    else: return "x86_64"
    e_machine = struct.unpack_from(fmt, hdr, 18)[0]
    return _EM_TO_QEMU.get(e_machine, "x86_64")


def build_plan(sample: Path, caps: dict[str, int], *,
               input_sha: str, input_size: int,
               type_hint: str, os_image: str | None,
               arch: str, kernel_path: str, rootfs_path: str) -> dict[str, Any]:
    """Build detonate-plan.v1 record (pure planning, no subprocess).

    Disk slots (per-drive containment policy — see detonate-plan.v1.md):
      /input/sample  → readonly=on, snapshot=off  (sample identity immutable)
      /rsdd/scratch.img  → snapshot=off           (persistent; host reads post-teardown)
      /input/rootfs  → snapshot=on                (COW; guest OS writes discarded)

    Global -snapshot is intentionally ABSENT; per-drive policy replaces it.
    """
    mem_mb = max(1, caps["mem_bytes"] >> 20)
    qbin = f"qemu-system-{arch}"
    argv: list[str] = [
        "bwrap", "--die-with-parent", "--new-session",
        "--unshare-net", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup",
        "--cap-drop", "ALL",
        "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
        "--ro-bind", rootfs_path, "/input/rootfs",
        "--ro-bind", str(sample.resolve()), "/input/sample", "--",
        qbin,
        "-kernel", kernel_path,
        "-m", str(mem_mb),
        "-smp", "1",
        "-accel", "tcg",
        "-nic", "none",
        "-nodefaults",
        "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
        "-nographic", "-no-reboot",
        # Disk slots — per-drive containment (replaces global -snapshot):
        "-drive", "file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio",
        "-drive", f"file={_SCRATCH_SENTINEL},snapshot=off,format=raw,if=virtio",
        "-drive", "file=/input/rootfs,snapshot=on,format=raw,if=virtio",
    ]
    return {
        "schema_version": SCHEMA_VERSION,
        "arch": arch,
        "qemu_binary": qbin,
        "sample": {"path": str(sample.resolve()), "sha256": input_sha,
                   "size": input_size, "type_hint": type_hint},
        # SAFETY-CRITICAL: hostile sample MUST NEVER reach a live network.
        "network": "none",
        "network_policy": {"mode": "none",
                           "justification": "hostile-sample: network isolation mandatory; "
                                            "non-none modes unsupported and refused"},
        "disk": {
            # Per-drive policy replaces the old global -snapshot approach (D1 rebuild).
            # The live executor (D2) creates scratch.img in run_dir and substitutes
            # _SCRATCH_SENTINEL in exec_argv before Popen.
            "mode": "per-drive-policy",
            "pre_snapshot_digest": None,
            "post_snapshot_capture": True,
        },
        "mount_plan": {
            "sample_ro": "/input/sample",
            "rootfs_ro": "/input/rootfs",
            "scratch_persistent": _SCRATCH_SENTINEL,
            "output_writable": "/tmp/rsdd/out",
            "host_writable": "none",
        },
        "limits": {"cpu_seconds": caps["cpu_seconds"], "mem_bytes": caps["mem_bytes"],
                   "wall_seconds": caps["wall_seconds"], "output_bytes": caps["output_bytes"]},
        "snapshot_policy": {
            "pre_run":  {"intent": "capture-before-detonation", "sha256": None},
            "post_run": {"intent": "capture-after-detonation",  "sha256": None},
        },
        "os_image": os_image, "planned_argv": argv,
        "outputs": [], "limitations": ["outputs-unknown-until-live-run"],
    }


def plan_detonate(args: Any) -> int:
    """Build plan + determinism record, route through gate. Returns exit code."""
    output_dir = Path(args.output)
    try: assert_safe_bind_root(Path(os.path.realpath(output_dir)))
    except BindScopeError as exc:
        print(f"detonate-plan: unsafe output path: {exc}", file=sys.stderr); return 2
    sample = Path(args.sample)
    type_hint = _sniff_type(sample)  # metadata-only; degrades to "unknown" on any fault
    arch = _sniff_arch(sample)       # ELF e_machine → qemu arch; degrades to "x86_64"
    try: _, input_size, input_sha = _file_identity(sample, max_bytes=args.max_input_bytes)
    except AdapterError as exc:
        print(f"detonate-plan: {exc}", file=sys.stderr); return 2
    caps = {"cpu_seconds": args.cpu_seconds, "mem_bytes": args.max_mem_bytes,
            "wall_seconds": args.wall_seconds, "output_bytes": args.max_output_bytes}
    for k, v in caps.items():
        if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
            print(f"detonate-plan: cap {k!r} must be positive int", file=sys.stderr); return 2
    plan = build_plan(sample, caps, input_sha=input_sha, input_size=input_size,
                      type_hint=type_hint, os_image=args.os_image,
                      arch=arch, kernel_path=args.kernel, rootfs_path=args.rootfs)
    try: determinism = build_determinism(make_dry_run_det_spec())
    except VmDeterminismError as exc:
        print(f"detonate-plan: determinism error: {exc}", file=sys.stderr); return 2
    # Local wiring: DetonateVmExecutor for live exec path only.
    # DO NOT route through plan_common.select_executor — it serves other callers.
    # DO NOT modify lib/gate.py. RSDD_EXEC_EXECUTOR env stub wins (gate.py:113).
    if args.allow_exec:
        sys.path.insert(0, str(_LIB))
        from detonate_exec import DetonateVmExecutor   # noqa: E402
        executor: Any = DetonateVmExecutor(output_dir)
    else:
        # args.allow_exec is invariantly False in this branch; pass literal False
        # so it is explicit that this is the plan-only / gate-closed path.
        executor = select_executor(False, SCHEMA_VERSION)
    output_dir.mkdir(parents=True, exist_ok=True)
    _write(output_dir / "detonate-plan.v1.json", plan)
    _write(output_dir / "vm-determinism.v1.json", determinism)
    return run_gate_epilogue(CAP_EXEC, args.allow_exec, plan, executor, "detonate-plan")


def _parser(argv: list[str] | None = None) -> Any:
    ap = argparse.ArgumentParser(prog="detonate_plan.py", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="Build detonate-plan.v1 (dry-run only)")
    p.add_argument("--sample",   required=True, metavar="FILE")
    p.add_argument("--output",   required=True, metavar="DIR")
    p.add_argument("--os-image", default=None,  metavar="TAG", dest="os_image",
                   help="OS image tag for the disposable VM (recorded in plan, not executed)")
    p.add_argument("--kernel", default=_DEFAULT_KERNEL, metavar="PATH", dest="kernel",
                   help="VM kernel image path (recorded in plan, not executed; "
                        f"default: {_DEFAULT_KERNEL})")
    p.add_argument("--rootfs", default=_DEFAULT_ROOTFS, metavar="PATH", dest="rootfs",
                   help="VM rootfs image path for bwrap ro-bind (recorded in plan, not executed; "
                        f"default: {_DEFAULT_ROOTFS})")
    # --network exists solely to reject non-"none" values at the CLI level (see T4b).
    # args.network is intentionally never read: the emitted network mode is
    # unconditionally "none" regardless of what the caller passes.
    p.add_argument("--network",  default="none", choices=["none"],
                   help="Network isolation mode. Only 'none' is permitted.")
    p.add_argument("--cpu-seconds",      type=int, default=_DEFAULT_CPU)
    p.add_argument("--max-mem-bytes",    type=int, default=_DEFAULT_MEM)
    p.add_argument("--max-output-bytes", type=int, default=_DEFAULT_OUT)
    p.add_argument("--wall-seconds",     type=int, default=_DEFAULT_WALL)
    p.add_argument("--allow-exec", action="store_true", default=False,
                   help="authorize live execution (no live executor in D1 → exit 2)")
    add_max_input_bytes_arg(p)
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parser(argv)
    if args.cmd == "plan":
        return run_adapter_main(lambda: plan_detonate(args), "detonate-plan")
    return 2


if __name__ == "__main__":
    sys.exit(main())
