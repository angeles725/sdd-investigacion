#!/usr/bin/env python3
"""Hostile-sample DETONATION PLAN (dry-run) adapter (U-V11 / item 11).
Produces detonate-plan.v1 + vm-determinism.v1. NEVER executes: no VM boot,
no subprocess spawned, no sample detonated. Live exec gated behind --allow-exec.
See gate-authorization.v1.md and detonate-plan.v1.md.
"""
from __future__ import annotations
import argparse, os, sys
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
    add_max_input_bytes_arg,
)

SCHEMA_VERSION = "detonate-plan.v1"
_DEFAULT_CPU = 30; _DEFAULT_MEM = 256 << 20; _DEFAULT_WALL = 60; _DEFAULT_OUT = 128 << 20
_MAGIC_HINTS: list[tuple[bytes, str]] = [
    (b"\x7fELF",        "elf"),
    (b"MZ",             "pe"),
    (b"\xca\xfe\xba\xbe", "macho-fat"),
    (b"PK\x03\x04",    "zip"),
    (b"\x1f\x8b",      "gzip"),
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


def build_plan(sample: Path, caps: dict[str, int], *,
               input_sha: str, input_size: int,
               type_hint: str, os_image: str | None) -> dict[str, Any]:
    """Build detonate-plan.v1 record (pure planning, no subprocess)."""
    argv: list[str] = [
        "bwrap", "--die-with-parent", "--new-session",
        "--unshare-net", "--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup",
        "--cap-drop", "ALL",
        "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
        "--ro-bind", str(sample.resolve()), "/input/sample", "--",
        "/input/sample",
    ]
    return {
        "schema_version": SCHEMA_VERSION,
        "sample": {"path": str(sample.resolve()), "sha256": input_sha,
                   "size": input_size, "type_hint": type_hint},
        # SAFETY-CRITICAL: hostile sample MUST NEVER reach a live network.
        # Emitted unconditionally as "none"; args.network is not read by design —
        # the --network CLI flag exists only to reject non-"none" values at parse time.
        "network": "none",
        "network_policy": {"mode": "none",
                           "justification": "hostile-sample: network isolation mandatory; "
                                            "non-none modes unsupported and refused"},
        "disk": {"mode": "ephemeral-snapshot",
                 "pre_snapshot_digest": None, "post_snapshot_capture": True},
        "mount_plan": {"sample_ro": "/input/sample",
                       "output_writable": "/tmp/rsdd/out", "host_writable": "none"},
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
    try: _, input_size, input_sha = _file_identity(sample, max_bytes=args.max_input_bytes)
    except AdapterError as exc:
        print(f"detonate-plan: {exc}", file=sys.stderr); return 2
    caps = {"cpu_seconds": args.cpu_seconds, "mem_bytes": args.max_mem_bytes,
            "wall_seconds": args.wall_seconds, "output_bytes": args.max_output_bytes}
    for k, v in caps.items():
        if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
            print(f"detonate-plan: cap {k!r} must be positive int", file=sys.stderr); return 2
    plan = build_plan(sample, caps, input_sha=input_sha, input_size=input_size,
                      type_hint=type_hint, os_image=args.os_image)
    try: determinism = build_determinism(make_dry_run_det_spec())
    except VmDeterminismError as exc:
        print(f"detonate-plan: determinism error: {exc}", file=sys.stderr); return 2
    executor = select_executor(args.allow_exec, SCHEMA_VERSION)
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
                   help="authorize live execution (no live executor in this unit → exit 2)")
    add_max_input_bytes_arg(p)
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parser(argv)
    return plan_detonate(args) if args.cmd == "plan" else 2


if __name__ == "__main__":
    sys.exit(main())
