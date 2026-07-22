#!/usr/bin/env python3
"""GDB/strace/ltrace TRACE-PLAN (dry-run) adapter (U-V9 / item 9).
Produces trace-plan.v1 + vm-determinism.v1. NEVER executes: no tracer launched,
no subprocess spawned, no target executed. Live exec gated behind --allow-exec.
See gate-authorization.v1.md and trace-plan.v1.md.
"""
from __future__ import annotations
import argparse, json, os, sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent; _LIB = _HERE / "lib"
for _p in (str(_LIB), str(_HERE)):
    if _p not in sys.path: sys.path.insert(0, _p)

from adapter_core import AdapterError, identity as _file_identity, write as _write  # noqa: E402
from adapter_helpers import assert_safe_bind_root, BindScopeError              # noqa: E402
from gate import execute_or_plan, CAP_EXEC, EXIT_AUTH_REQUIRED, GateError     # noqa: E402
from vm_plan import build_determinism, VmDeterminismError                      # noqa: E402

SCHEMA_VERSION = "trace-plan.v1"
_VALID_TRACERS: frozenset[str] = frozenset({"strace", "ltrace", "gdb-batch"})
_DEFAULT_CPU = 30; _DEFAULT_MEM = 256 << 20; _DEFAULT_WALL = 60; _DEFAULT_OUT = 128 << 20

# Inner argv for each tracer (placed after bwrap's `--` separator).
# "/input/target" is appended by build_plan so the target path is a data field.
_TRACER_ARGV: dict[str, list[str]] = {
    "strace":    ["strace", "-f", "-o", "/tmp/rsdd/out/trace.log", "--"],
    "ltrace":    ["ltrace", "-f", "-o", "/tmp/rsdd/out/trace.log", "--"],
    "gdb-batch": ["gdb", "--batch", "-ex", "run", "-ex", "bt", "--args"],
}
# Tracer-specific options recorded as data (not enforced here; live executor uses them).
_TRACER_OPTIONS: dict[str, dict[str, Any]] = {
    "strace":    {"follow_forks": True,  "syscall_filter": None},
    "ltrace":    {"follow_forks": True,  "syscall_filter": None},
    "gdb-batch": {"follow_forks": False, "syscall_filter": None},
}


class TracePlanError(AdapterError): ...


class PlanOnlyExecutor:
    """Offline executor: no subprocess, records executed=False."""
    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:
        return {"schema_version": SCHEMA_VERSION, "executed": False,
                "outputs": [], "limitations": ["outputs-unknown-until-live-run"]}


def select_executor(allow_live: bool) -> PlanOnlyExecutor | None:
    """PlanOnlyExecutor for dry-run; None when live (gate hard-refuses, seam still works)."""
    return None if allow_live else PlanOnlyExecutor()


def build_plan(target: Path, tracer: str, caps: dict[str, int], *,
               input_sha: str, input_size: int) -> dict[str, Any]:
    """Build trace-plan.v1 record (pure planning, no subprocess)."""
    inner_argv = [*_TRACER_ARGV[tracer], "/input/target"]
    argv: list[str] = [
        "bwrap", "--die-with-parent", "--new-session",
        "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
        "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/out",
        "--ro-bind", str(target.resolve()), "/input/target", "--",
        *inner_argv,
    ]
    return {
        "schema_version": SCHEMA_VERSION,
        "tracer": tracer,
        "tracer_options": dict(_TRACER_OPTIONS[tracer]),
        "target": {"path": str(target.resolve()), "sha256": input_sha, "size": input_size},
        "limits": {
            "cpu_seconds": caps["cpu_seconds"], "mem_bytes": caps["mem_bytes"],
            "wall_seconds": caps["wall_seconds"], "output_bytes": caps["output_bytes"],
        },
        "mount_plan": {"target_ro": "/input/target", "output_writable": "/tmp/rsdd/out"},
        "planned_argv": argv,
        "outputs": [],
        "limitations": ["outputs-unknown-until-live-run"],
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
    try: _, input_size, input_sha = _file_identity(target)
    except AdapterError as exc: print(f"trace-plan: {exc}", file=sys.stderr); return 2
    caps = {"cpu_seconds": args.cpu_seconds, "mem_bytes": args.max_mem_bytes,
            "wall_seconds": args.wall_seconds, "output_bytes": args.max_output_bytes}
    for k, v in caps.items():
        if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
            print(f"trace-plan: cap {k!r} must be positive int", file=sys.stderr); return 2
    try:
        plan = build_plan(target, args.tracer, caps, input_sha=input_sha, input_size=input_size)
    except (TracePlanError, KeyError) as exc:
        print(f"trace-plan: plan error: {exc}", file=sys.stderr); return 2
    # Dry-run determinism record: declared=false, basis=dry-run-plan, receipt_identity=null
    det_spec: dict[str, Any] = {
        "schema_version": "vm-determinism.v1", "receipt_identity": None, "seed": 0,
        "clock": {"mode": "pinned", "epoch": "1970-01-01T00:00:00Z"},
        "limits_conformance": {"cpu_within": False, "mem_within": False,
                               "wall_within": False, "output_within": False},
        "reproducible": {"basis": "dry-run-plan", "replicate_identity": None},
    }
    try: determinism = build_determinism(det_spec)
    except VmDeterminismError as exc:
        print(f"trace-plan: determinism error: {exc}", file=sys.stderr); return 2
    executor = select_executor(args.allow_exec)
    output_dir.mkdir(parents=True, exist_ok=True)
    _write(output_dir / "trace-plan.v1.json", plan)
    _write(output_dir / "vm-determinism.v1.json", determinism)
    try:
        result = execute_or_plan(
            CAP_EXEC, args.allow_exec, plan,
            live_executor=executor.evaluate if executor is not None else None,
            would_be_receipt_spec=None, output_dir=None,
        )
    except GateError as exc: print(f"trace-plan: {exc}", file=sys.stderr); return 2
    if result.get("outcome") == "authorization-required":
        return EXIT_AUTH_REQUIRED  # 3
    print(json.dumps(result, indent=2, sort_keys=True)); return 0


def _parser(argv: list[str] | None = None) -> Any:
    ap = argparse.ArgumentParser(prog="trace_plan.py", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="Build trace-plan.v1 (dry-run only)")
    p.add_argument("--target",  required=True, metavar="BINARY",
                   help="Target executable/sample (must be a regular file, no symlinks)")
    p.add_argument("--output",  required=True, metavar="DIR")
    p.add_argument("--tracer",  required=True,
                   choices=["strace", "ltrace", "gdb-batch"],
                   help="Tracer: strace | ltrace | gdb-batch")
    p.add_argument("--cpu-seconds",      type=int, default=_DEFAULT_CPU)
    p.add_argument("--max-mem-bytes",    type=int, default=_DEFAULT_MEM)
    p.add_argument("--max-output-bytes", type=int, default=_DEFAULT_OUT)
    p.add_argument("--wall-seconds",     type=int, default=_DEFAULT_WALL)
    p.add_argument("--allow-exec", action="store_true", default=False,
                   help="authorize live execution (no live executor in this unit → exit 2)")
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parser(argv)
    return plan_trace(args) if args.cmd == "plan" else 2


if __name__ == "__main__":
    sys.exit(main())
