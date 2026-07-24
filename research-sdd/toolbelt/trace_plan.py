#!/usr/bin/env python3
"""GDB/strace/ltrace IN-VM TRACE-PLAN (dry-run) adapter (U-V9 / item 9).
Produces trace-plan.v1 + vm-determinism.v1. NEVER executes: no VM boot,
no subprocess spawned, no target traced. Live exec gated behind --allow-exec.
See gate-authorization.v1.md and trace-plan.v1.md.

D3 rebuild: planned_argv now emits the qemu-system+disk form (same containment
as detonate-plan.v1). The tracer selection is encoded in the kernel cmdline
(-append "init=/rsdd-agent rsdd.tracer=<tracer>") for the guest-side agent.
Global -snapshot is ABSENT; per-drive containment policy (lib/vm_disk_policy.py)
replaces it. Live TraceVmExecutor is wired below when --allow-exec.
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

SCHEMA_VERSION = "trace-plan.v1"
_VALID_TRACERS: frozenset[str] = frozenset({"strace", "ltrace", "gdb-batch"})
_DEFAULT_CPU = 30; _DEFAULT_MEM = 256 << 20; _DEFAULT_WALL = 60; _DEFAULT_OUT = 128 << 20

# Plan-time sentinel for the scratch disk path.
# The live executor (D3) substitutes the actual per-run path before calling Popen.
_SCRATCH_SENTINEL: str = "/rsdd/scratch.img"
_DEFAULT_KERNEL: str = "/rsdd/vmlinuz"
_DEFAULT_ROOTFS: str = "/rsdd/rootfs.img"
# Sandbox destination for the optional runtime tree bind (--ro-bind <src> /rsdd/rt).
# Must match vm_disk_policy._RT_TREE_DEST.
_RT_TREE_DEST: str = "/rsdd/rt"

# ELF e_machine → qemu-system arch suffix.
# NOTE: byte-identical to detonate_plan._EM_TO_QEMU and qemu_plan._EM_TO_QEMU —
# keep in sync manually; not imported to avoid cross-module coupling.
_EM_TO_QEMU: dict[int, str] = {
    3: "i386", 8: "mips", 20: "ppc", 21: "ppc64",
    40: "arm", 42: "sh4", 62: "x86_64", 183: "aarch64", 243: "riscv64",
}

# Tracer-specific options recorded as data in the plan (not enforced at host level;
# the guest-side rsdd-agent reads these from the plan and uses them when tracing).
_TRACER_OPTIONS: dict[str, dict[str, Any]] = {
    "strace":    {"follow_forks": True,  "syscall_filter": None},
    "ltrace":    {"follow_forks": True,  "syscall_filter": None},
    "gdb-batch": {"follow_forks": False, "syscall_filter": None},
}


class TracePlanError(AdapterError): ...


def _sniff_arch(path: Path) -> str:
    """Read ELF e_machine O_NOFOLLOW → qemu arch suffix; 'x86_64' on any fault.

    NOTE: byte-identical to detonate_plan._sniff_arch — keep in sync manually.
    """
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


def build_plan(target: Path, tracer: str, caps: dict[str, int], *,
               input_sha: str, input_size: int,
               arch: str, kernel_path: str, rootfs_path: str,
               qemu_root: str | None = None) -> dict[str, Any]:
    """Build trace-plan.v1 record (pure planning, no subprocess).

    Disk slots (per-drive containment policy — see trace-plan.v1.md):
      /input/sample  → readonly=on, snapshot=off  (target identity immutable)
      /rsdd/scratch.img  → snapshot=off           (persistent; host reads post-teardown)
      /input/rootfs  → snapshot=on                (COW; guest OS writes discarded)

    Tracer selection is encoded in the qemu kernel cmdline as:
      -append "init=/rsdd-agent rsdd.tracer=<tracer>"
    The guest-side rsdd-agent reads this from /proc/cmdline and wraps the sample
    with the requested tracer (strace/ltrace/gdb-batch), writing trace output to
    the scratch disk. Host attack surface is IDENTICAL to detonate — containment
    is enforced by the SAME vm_disk_policy checker.

    Global -snapshot is intentionally ABSENT; per-drive policy replaces it.
    """
    mem_mb = max(1, caps["mem_bytes"] >> 20)
    qbin = f"qemu-system-{arch}"
    # When --qemu-root is provided, emit the runtime-tree bind and use an absolute
    # in-tree qbin path so R-REACH covers the binary.  Without --qemu-root the plan
    # is PLAN-ONLY with a relative qbin (old behaviour; live boot not supported).
    _qbin_argv: str = f"{_RT_TREE_DEST}/bin/{qbin}" if qemu_root is not None else qbin
    _rt_binds: list[str] = (
        ["--ro-bind", qemu_root, _RT_TREE_DEST] if qemu_root is not None else []
    )
    argv: list[str] = [
        "bwrap", "--die-with-parent", "--new-session",
        "--unshare-net", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup",
        "--cap-drop", "ALL",
        "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
        # F5 fix (INV-2): emit the scratch file-scoped bind AFTER --tmpfs so the
        # --tmpfs does not re-mask it (ordering is load-bearing in bwrap).
        # SRC == DEST (identity map) required by R-BIND-RW (identity bind, not directory).
        # The executor calls _substitute_scratch_sentinel() which rewrites exactly the
        # three structural positions; no other sentinel-containing token is touched (INV-3).
        # WHY file-scoped (not directory-scoped): a --bind <run_dir> <run_dir> exposes
        # the host run directory to guest writes; vm_boot_core.output_files() (line 160)
        # sweeps that directory into receipt outputs[], letting a qemu escape inject
        # artifacts into the frozen evidence chain. File-scoped bind shares only the
        # scratch inode. See design.md §3.2 and Experiment E.
        "--bind", _SCRATCH_SENTINEL, _SCRATCH_SENTINEL,
        *_rt_binds,  # runtime-tree bind (opt-in; empty when no --qemu-root)
        "--ro-bind", rootfs_path, "/input/rootfs",
        "--ro-bind", str(target.resolve()), "/input/sample", "--",
        _qbin_argv,
        "-kernel", kernel_path,
        "-m", str(mem_mb),
        "-smp", "1",
        "-accel", "tcg",
        "-nic", "none",
        "-nodefaults",
        "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
        "-nographic", "-no-reboot",
        # Guest-side tracer selection via kernel cmdline (host argv is identical to detonate).
        "-append", f"init=/rsdd-agent rsdd.tracer={tracer}",
        # Disk slots — per-drive containment (replaces global -snapshot):
        "-drive", "file=/input/sample,readonly=on,snapshot=off,format=raw,if=virtio",
        "-drive", f"file={_SCRATCH_SENTINEL},snapshot=off,format=raw,if=virtio",
        "-drive", "file=/input/rootfs,snapshot=on,format=raw,if=virtio",
    ]
    return {
        "schema_version": SCHEMA_VERSION,
        "arch": arch,
        "qemu_binary": qbin,
        "tracer": tracer,
        "tracer_options": dict(_TRACER_OPTIONS[tracer]),
        "target": {"path": str(target.resolve()), "sha256": input_sha, "size": input_size},
        # SAFETY-CRITICAL: target MUST NEVER reach a live network (same as detonate).
        "network": "none",
        "network_policy": {"mode": "none",
                           "justification": "trace-target: network isolation mandatory; "
                                            "non-none modes unsupported and refused"},
        "disk": {
            # Per-drive policy replaces the old global -snapshot approach (D3 rebuild).
            # The live executor (D3) creates scratch.img in run_dir and substitutes
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
            # C3: host_writable flips from "none" to the scratch sentinel.
            # Invariant: host_writable == scratch_persistent (one writable file bind).
            "host_writable": _SCRATCH_SENTINEL,
        },
        "limits": {"cpu_seconds": caps["cpu_seconds"], "mem_bytes": caps["mem_bytes"],
                   "wall_seconds": caps["wall_seconds"], "output_bytes": caps["output_bytes"]},
        "snapshot_policy": {
            "pre_run":  {"intent": "capture-before-trace", "sha256": None},
            "post_run": {"intent": "capture-after-trace",  "sha256": None},
        },
        "planned_argv": argv,
        "outputs": [], "limitations": ["outputs-unknown-until-live-run"],
    }


def plan_trace(args: Any) -> int:
    """Build plan + determinism record, route through gate. Returns exit code."""
    output_dir = Path(args.output)
    try: assert_safe_bind_root(Path(os.path.realpath(output_dir)))
    except BindScopeError as exc:
        print(f"trace-plan: unsafe output path: {exc}", file=sys.stderr); return 2
    if args.tracer not in _VALID_TRACERS:
        print(f"trace-plan: unsupported tracer: {args.tracer!r}; valid: {sorted(_VALID_TRACERS)}",
              file=sys.stderr); return 2
    target = Path(args.target)
    try: _, input_size, input_sha = _file_identity(target, max_bytes=args.max_input_bytes)
    except AdapterError as exc: print(f"trace-plan: {exc}", file=sys.stderr); return 2
    arch = _sniff_arch(target)   # ELF e_machine → qemu arch; degrades to "x86_64"
    caps = {"cpu_seconds": args.cpu_seconds, "mem_bytes": args.max_mem_bytes,
            "wall_seconds": args.wall_seconds, "output_bytes": args.max_output_bytes}
    for k, v in caps.items():
        if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
            print(f"trace-plan: cap {k!r} must be positive int", file=sys.stderr); return 2
    qemu_root = getattr(args, "qemu_root", None)
    kernel_path = args.kernel
    if qemu_root is not None and kernel_path == _DEFAULT_KERNEL:
        kernel_path = f"{_RT_TREE_DEST}/vmlinuz"
    try:
        plan = build_plan(target, args.tracer, caps, input_sha=input_sha, input_size=input_size,
                          arch=arch, kernel_path=kernel_path, rootfs_path=args.rootfs,
                          qemu_root=qemu_root)
    except (TracePlanError, KeyError) as exc:
        print(f"trace-plan: plan error: {exc}", file=sys.stderr); return 2
    # Dry-run determinism record: declared=false, basis=dry-run-plan, receipt_identity=null
    try: determinism = build_determinism(make_dry_run_det_spec())
    except VmDeterminismError as exc:
        print(f"trace-plan: determinism error: {exc}", file=sys.stderr); return 2
    # Local wiring: TraceVmExecutor for live exec path only.
    # DO NOT route through plan_common.select_executor — it serves other callers.
    # DO NOT modify lib/gate.py. RSDD_EXEC_EXECUTOR env stub wins (gate.py:113).
    if args.allow_exec:
        sys.path.insert(0, str(_LIB))
        from trace_exec import TraceVmExecutor   # noqa: E402
        executor: Any = TraceVmExecutor(output_dir)
    else:
        # args.allow_exec is invariantly False in this branch; pass literal False
        # so it is explicit that this is the plan-only / gate-closed path.
        executor = select_executor(False, SCHEMA_VERSION)
    output_dir.mkdir(parents=True, exist_ok=True)
    _write(output_dir / "trace-plan.v1.json", plan)
    _write(output_dir / "vm-determinism.v1.json", determinism)
    return run_gate_epilogue(CAP_EXEC, args.allow_exec, plan, executor, "trace-plan")


def _parser(argv: list[str] | None = None) -> Any:
    ap = argparse.ArgumentParser(prog="trace_plan.py", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="Build trace-plan.v1 (dry-run only)")
    p.add_argument("--target",  required=True, metavar="BINARY",
                   help="Target executable/sample to trace (must be a regular file, no symlinks)")
    p.add_argument("--output",  required=True, metavar="DIR")
    p.add_argument("--tracer",  required=True,
                   choices=["strace", "ltrace", "gdb-batch"],
                   help="Tracer: strace | ltrace | gdb-batch (selection encoded in kernel cmdline)")
    p.add_argument("--kernel", default=_DEFAULT_KERNEL, metavar="PATH", dest="kernel",
                   help="VM kernel image path (recorded in plan, not executed; "
                        f"default: {_DEFAULT_KERNEL})")
    p.add_argument("--rootfs", default=_DEFAULT_ROOTFS, metavar="PATH", dest="rootfs",
                   help="VM rootfs image path for bwrap ro-bind (recorded in plan, not executed; "
                        f"default: {_DEFAULT_ROOTFS})")
    p.add_argument("--qemu-root", default=None, metavar="DIR", dest="qemu_root",
                   help="host path to the QEMU runtime tree; emits --ro-bind <DIR> "
                        f"{_RT_TREE_DEST} and uses absolute in-tree qbin + kernel "
                        "(live boot: x86_64 only)")
    p.add_argument("--cpu-seconds",      type=int, default=_DEFAULT_CPU)
    p.add_argument("--max-mem-bytes",    type=int, default=_DEFAULT_MEM)
    p.add_argument("--max-output-bytes", type=int, default=_DEFAULT_OUT)
    p.add_argument("--wall-seconds",     type=int, default=_DEFAULT_WALL)
    p.add_argument("--allow-exec", action="store_true", default=False,
                   help="authorize live execution via TraceVmExecutor")
    add_max_input_bytes_arg(p)
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parser(argv)
    if args.cmd == "plan":
        return run_adapter_main(lambda: plan_trace(args), "trace-plan")
    return 2


if __name__ == "__main__":
    sys.exit(main())
