#!/usr/bin/env python3
"""QEMU emulation PLAN (dry-run) adapter (U-V10 / item 10).
Produces qemu-plan.v1 + vm-determinism.v1. NEVER executes: no QEMU launched,
no subprocess spawned, no target emulated. Live exec gated behind --allow-exec.
See gate-authorization.v1.md and qemu-plan.v1.md.
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

SCHEMA_VERSION = "qemu-plan.v1"
_ELF_MAGIC = b"\x7fELF"; _ELF_MIN = 20  # need e_machine at byte-offset 18

# e_machine → qemu arch suffix (RAW BYTES only; user: qemu-{a}, system: qemu-system-{a})
_EM_TO_QEMU: dict[int, str] = {
    3: "i386", 8: "mips", 20: "ppc", 21: "ppc64",
    40: "arm", 42: "sh4", 62: "x86_64", 183: "aarch64", 243: "riscv64",
}
_DEFAULT_CPU = 30; _DEFAULT_MEM = 256 << 20; _DEFAULT_WALL = 60; _DEFAULT_OUT = 128 << 20


class QemuPlanError(AdapterError): ...


def _read_elf_arch(path: Path) -> str:
    """Read e_machine (raw bytes, O_NOFOLLOW) → qemu arch suffix; QemuPlanError on any fault."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
        try: hdr = os.read(fd, _ELF_MIN)
        finally: os.close(fd)
    except OSError as exc:
        raise QemuPlanError(f"cannot read ELF header: {exc}") from exc
    if len(hdr) < _ELF_MIN:
        raise QemuPlanError(f"file too short for ELF header: {len(hdr)} < {_ELF_MIN} bytes")
    if hdr[:4] != _ELF_MAGIC:
        raise QemuPlanError(f"not an ELF file (magic 0x{hdr[:4].hex()})")
    ei_data = hdr[5]
    if   ei_data == 1: fmt = "<H"
    elif ei_data == 2: fmt = ">H"
    else: raise QemuPlanError(f"unknown ELF data encoding EI_DATA={ei_data}")
    e_machine = struct.unpack_from(fmt, hdr, 18)[0]
    arch = _EM_TO_QEMU.get(e_machine)
    if arch is None:
        raise QemuPlanError(f"unsupported e_machine=0x{e_machine:04x}: not in qemu arch mapping")
    return arch


def build_plan(target: Path, mode: str, arch: str, caps: dict[str, int], *,
               input_sha: str, input_size: int) -> dict[str, Any]:
    """Build qemu-plan.v1 record (pure planning, no subprocess)."""
    mem_mb = max(1, caps["mem_bytes"] >> 20)
    if mode == "qemu-user":
        qbin = f"qemu-{arch}"; inner = [qbin, "/input/target"]
        mnt: dict[str, str] = {"target_ro": "/input/target", "output_writable": "/tmp/rsdd/out"}
    else:
        qbin = f"qemu-system-{arch}"
        # Containment belt flags (belt-and-suspenders on top of outer bwrap):
        # -smp 1          : bound vCPUs to 1 (cpu_seconds is a time cap, not core count)
        # -accel tcg      : offline-testable software emulation; NO -enable-kvm (user opt-in)
        # -nic none       : qemu-level net isolation; bwrap --unshare-net is the outer belt
        # -nodefaults     : suppress all default devices (minimise attack surface)
        # -sandbox on,... : qemu's own seccomp sandbox (deny obsolete/spawn/privilege syscalls)
        # -snapshot       : guest disk writes discarded; NOTE: vacuous without a -drive
        #                   (no disk image in this planning unit — see V1b detonation slice)
        inner = [qbin,
                 "-kernel", "/input/target",
                 "-m", str(mem_mb),
                 "-smp", "1",
                 "-accel", "tcg",
                 "-nic", "none",
                 "-nodefaults",
                 "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
                 "-nographic", "-no-reboot", "-snapshot"]
        mnt = {"target_ro": "/input/target", "output_writable": "/tmp/rsdd/out",
               "disk_snapshot": "ephemeral"}
    argv: list[str] = [
        "bwrap", "--die-with-parent", "--new-session",
        "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
        "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
        "--ro-bind", str(target.resolve()), "/input/target", "--", *inner,
    ]
    return {
        "schema_version": SCHEMA_VERSION, "mode": mode, "arch": arch, "qemu_binary": qbin,
        "target": {"path": str(target.resolve()), "sha256": input_sha, "size": input_size},
        "limits": {"cpu_seconds": caps["cpu_seconds"], "mem_bytes": caps["mem_bytes"],
                   "wall_seconds": caps["wall_seconds"], "output_bytes": caps["output_bytes"]},
        "mount_plan": mnt, "planned_argv": argv,
        "outputs": [], "limitations": ["outputs-unknown-until-live-run"],
    }


def plan_qemu(args: Any) -> int:
    """Build plan + determinism record, route through gate. Returns exit code."""
    output_dir = Path(args.output)
    try: assert_safe_bind_root(Path(os.path.realpath(output_dir)))
    except BindScopeError as exc:
        print(f"qemu-plan: unsafe output path: {exc}", file=sys.stderr); return 2
    target = Path(args.target)
    try: arch = _read_elf_arch(target)
    except QemuPlanError as exc: print(f"qemu-plan: {exc}", file=sys.stderr); return 2
    try: _, input_size, input_sha = _file_identity(target, max_bytes=args.max_input_bytes)
    except AdapterError as exc: print(f"qemu-plan: {exc}", file=sys.stderr); return 2
    caps = {"cpu_seconds": args.cpu_seconds, "mem_bytes": args.max_mem_bytes,
            "wall_seconds": args.wall_seconds, "output_bytes": args.max_output_bytes}
    for k, v in caps.items():
        if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
            print(f"qemu-plan: cap {k!r} must be positive int", file=sys.stderr); return 2
    plan = build_plan(target, args.mode, arch, caps, input_sha=input_sha, input_size=input_size)
    try: determinism = build_determinism(make_dry_run_det_spec())
    except VmDeterminismError as exc:
        print(f"qemu-plan: determinism error: {exc}", file=sys.stderr); return 2
    # Local wiring: LiveQemuBootExecutor for qemu-system live path only.
    # DO NOT route through plan_common.select_executor — it serves other callers.
    # DO NOT modify lib/gate.py. RSDD_EXEC_EXECUTOR env stub wins (gate.py:113).
    if args.allow_exec and args.mode == "qemu-user":
        # qemu-user uses host-kernel translation — hard-refuse live exec in this unit.
        print("qemu-plan: qemu-user live exec refused; only qemu-system is bootable",
              file=sys.stderr)
        return 2
    if args.allow_exec and args.mode == "qemu-system":
        sys.path.insert(0, str(_LIB))
        from qemu_exec import LiveQemuBootExecutor   # noqa: E402
        executor: Any = LiveQemuBootExecutor(output_dir)
    else:
        executor = select_executor(args.allow_exec, SCHEMA_VERSION)
    output_dir.mkdir(parents=True, exist_ok=True)
    _write(output_dir / "qemu-plan.v1.json", plan)
    _write(output_dir / "vm-determinism.v1.json", determinism)
    return run_gate_epilogue(CAP_EXEC, args.allow_exec, plan, executor, "qemu-plan")


def _parser(argv: list[str] | None = None) -> Any:
    ap = argparse.ArgumentParser(prog="qemu_plan.py", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="Build qemu-plan.v1 (dry-run only)")
    p.add_argument("--target", required=True, metavar="BINARY")
    p.add_argument("--output", required=True, metavar="DIR")
    p.add_argument("--mode",   required=True, choices=["qemu-user", "qemu-system"])
    p.add_argument("--cpu-seconds",      type=int, default=_DEFAULT_CPU)
    p.add_argument("--max-mem-bytes",    type=int, default=_DEFAULT_MEM)
    p.add_argument("--max-output-bytes", type=int, default=_DEFAULT_OUT)
    p.add_argument("--wall-seconds",     type=int, default=_DEFAULT_WALL)
    p.add_argument("--allow-exec", action="store_true", default=False)
    add_max_input_bytes_arg(p)
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parser(argv)
    if args.cmd == "plan":
        return run_adapter_main(lambda: plan_qemu(args), "qemu-plan")
    return 2


if __name__ == "__main__":
    sys.exit(main())
