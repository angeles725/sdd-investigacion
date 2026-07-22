#!/usr/bin/env python3
"""Live traffic capture PLAN (dry-run) adapter (U-N8 / item 8).
Produces capture-plan.v1 + vm-determinism.v1. NEVER captures:
no socket opened, no interface bound, no subprocess spawned.
Live capture gated behind --allow-live-capture.
See gate-authorization.v1.md and capture-plan.v1.md.
"""
from __future__ import annotations
import argparse, os, re, sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent; _LIB = _HERE / "lib"
for _p in (str(_LIB), str(_HERE)):
    if _p not in sys.path: sys.path.insert(0, _p)

from adapter_core import AdapterError, write as _write                     # noqa: E402
from adapter_helpers import assert_safe_bind_root, BindScopeError          # noqa: E402
from gate import CAP_LIVE_CAPTURE                                            # noqa: E402
from vm_plan import build_determinism, VmDeterminismError                  # noqa: E402
from plan_common import make_dry_run_det_spec, run_gate_epilogue, run_adapter_main  # noqa: E402

SCHEMA_VERSION = "capture-plan.v1"

# Safe charset for interface names: alphanumeric + VLAN/subinterface chars.
# Rejects all shell metacharacters before the name reaches planned_argv.
_IFACE_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,62}$')
_MAX_BPF_LEN     = 512       # longer BPF expressions are implausible; rejected
_REQUIRED_OS_CAP = "CAP_NET_RAW"  # recorded as data; future executor must acquire it
_DEFAULT_DURATION = 60        # seconds
_DEFAULT_PACKETS  = 10_000    # packet count
_DEFAULT_SNAPLEN  = 65535     # bytes per packet (full-frame)


class CapturePlanError(AdapterError): ...


class PlanOnlyExecutor:
    """Offline executor: no subprocess, no socket, records executed=False.

    INTENTIONALLY NOT migrated to plan_common.PlanOnlyExecutor. The limitations
    string here is "outputs-unknown-until-live-capture" (capture-specific), whereas
    the shared class uses "outputs-unknown-until-live-run". capture-plan.v1.md
    requires the capture-specific string; merging the two classes would silently
    change the schema contract for this adapter. The _HasEvaluate Protocol in
    plan_common allows both classes to satisfy run_gate_epilogue's type without
    requiring a shared base class.
    """
    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:
        return {"schema_version": SCHEMA_VERSION, "executed": False,
                "outputs": [], "limitations": ["outputs-unknown-until-live-capture"]}


def validate_iface(name: str) -> str:
    """Validate interface name; CapturePlanError if unsafe charset or too long."""
    if not name:
        raise CapturePlanError("interface name must not be empty")
    if not _IFACE_RE.fullmatch(name):
        raise CapturePlanError(
            f"interface name contains unsafe characters "
            f"(only [A-Za-z0-9._:-] allowed, max 63 chars): {name!r}"
        )
    return name


def validate_bpf(expr: str | None) -> str | None:
    """Sanity-check BPF filter (length + NUL); never compiled or executed here."""
    if expr is None:
        return None
    if len(expr) > _MAX_BPF_LEN:
        raise CapturePlanError(f"BPF filter too long ({len(expr)} > {_MAX_BPF_LEN} chars)")
    if '\x00' in expr:
        raise CapturePlanError("BPF filter must not contain NUL bytes")
    return expr


def build_plan(iface: str, bpf: str | None, snaplen: int,
               duration: int, packet_count: int) -> dict[str, Any]:
    """Build capture-plan.v1 record (pure planning — no subprocess, no socket)."""
    # Interface and BPF are discrete argv list elements; no shell string concatenation.
    argv: list[str] = [
        "dumpcap",
        "-i", iface,
        "-s", str(snaplen),
        "-a", f"duration:{duration}",
        "-c", str(packet_count),
        "-w", "/tmp/rsdd/capture.pcap",
    ]
    if bpf is not None:
        argv += ["-f", bpf]
    return {
        "schema_version": SCHEMA_VERSION,
        "capture_spec": {
            "interface": iface,
            "bpf_filter": bpf,
            "snaplen": snaplen,
            "duration_seconds": duration,
            "packet_count_cap": packet_count,
        },
        "output": {"path": "/tmp/rsdd/capture.pcap", "format": "pcap"},
        "required_os_capability": _REQUIRED_OS_CAP,
        "planned_argv": argv,
        "outputs": [],
        "limitations": ["outputs-unknown-until-live-capture"],
    }


def plan_capture(args: Any) -> int:
    """Build plan + determinism record, route through gate. Returns exit code."""
    output_dir = Path(args.output)
    try:
        assert_safe_bind_root(Path(os.path.realpath(output_dir)))
    except BindScopeError as exc:
        print(f"capture-plan: unsafe output path: {exc}", file=sys.stderr)
        return 2

    try:
        iface = validate_iface(args.interface)
    except CapturePlanError as exc:
        print(f"capture-plan: {exc}", file=sys.stderr)
        return 2

    try:
        bpf = validate_bpf(args.bpf_filter)
    except CapturePlanError as exc:
        print(f"capture-plan: {exc}", file=sys.stderr)
        return 2

    for name, val in [("--snaplen", args.snaplen),
                      ("--duration-seconds", args.duration_seconds),
                      ("--packet-count", args.packet_count)]:
        if not isinstance(val, int) or isinstance(val, bool) or val <= 0:
            print(f"capture-plan: {name} must be a positive integer", file=sys.stderr)
            return 2

    plan = build_plan(iface, bpf, args.snaplen, args.duration_seconds, args.packet_count)
    try:
        determinism = build_determinism(make_dry_run_det_spec())
    except VmDeterminismError as exc:
        print(f"capture-plan: determinism error: {exc}", file=sys.stderr)
        return 2

    # Local wiring: LiveCaptureExecutor for live path, PlanOnlyExecutor for dry-run.
    # DO NOT route through plan_common.select_executor — it serves other callers
    # that must remain plan-only. DO NOT modify lib/gate.py.
    # RSDD_LIVE_CAPTURE_EXECUTOR env stub wins inside gate.py when set (seam priority).
    if args.allow_live_capture:
        from capture_exec import LiveCaptureExecutor  # noqa: E402
        executor = LiveCaptureExecutor(output_dir)
    else:
        executor = PlanOnlyExecutor()
    output_dir.mkdir(parents=True, exist_ok=True)
    _write(output_dir / "capture-plan.v1.json", plan)
    _write(output_dir / "vm-determinism.v1.json", determinism)
    return run_gate_epilogue(CAP_LIVE_CAPTURE, args.allow_live_capture, plan, executor, "capture-plan")


def _parser(argv: list[str] | None = None) -> Any:
    ap = argparse.ArgumentParser(prog="capture_plan.py", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="Build capture-plan.v1 (dry-run only)")
    p.add_argument("--interface",          required=True, metavar="IFACE",
                   help="Network interface (only [A-Za-z0-9._:-] allowed)")
    p.add_argument("--bpf-filter",         default=None,  metavar="EXPR", dest="bpf_filter",
                   help="BPF filter (recorded as data, never executed here)")
    p.add_argument("--snaplen",            type=int, default=_DEFAULT_SNAPLEN)
    p.add_argument("--duration-seconds",   type=int, default=_DEFAULT_DURATION,
                   dest="duration_seconds")
    p.add_argument("--packet-count",       type=int, default=_DEFAULT_PACKETS,
                   dest="packet_count")
    p.add_argument("--output",             required=True, metavar="DIR")
    p.add_argument("--allow-live-capture", action="store_true", default=False,
                   dest="allow_live_capture",
                   help="authorize live capture (spawns dumpcap via LiveCaptureExecutor)")
    return ap.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parser(argv)
    if args.cmd == "plan":
        return run_adapter_main(lambda: plan_capture(args), "capture-plan")
    return 2


if __name__ == "__main__":
    sys.exit(main())
