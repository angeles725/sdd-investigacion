#!/usr/bin/env python3
"""Bounded gzip/xz-in-disposable-VM DRY-RUN adapter (U-V3 / item 3).
Produces vm-run-plan.v1 + vm-determinism.v1. NEVER executes: no VM boot,
no subprocess, no archive inflation. Live exec gated behind --allow-exec.
See gate-authorization.v1.md and vm-run-plan.v1.md.
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
    add_max_input_bytes_arg,
)

SCHEMA_VERSION = "vm-run-plan.v1"
_GZIP_MAGIC = b"\x1f\x8b"; _XZ_MAGIC = b"\xfd7zXZ\x00"
_CODEC_DECOMP: dict[str, list[str]] = {"gzip": ["gzip", "-dc"], "xz": ["xz", "-dc"]}
_DEFAULT_CPU = 30; _DEFAULT_MEM = 256 << 20; _DEFAULT_WALL = 60; _DEFAULT_OUT = 128 << 20
# A real xz Stream Index is tiny; 1 MiB is already orders of magnitude above any
# legitimate value, so anything larger is either corrupted or adversarially crafted.
_MAX_XZ_INDEX_BYTES = 1 << 20


class VmRunError(AdapterError): ...


def _decode_vli(data: bytes, offset: int) -> tuple[int, int]:
    """Decode XZ variable-length integer. Returns (value, new_offset)."""
    value = shift = 0
    while offset < len(data):
        byte = data[offset]; offset += 1
        value |= (byte & 0x7F) << shift
        if not (byte & 0x80): return value, offset
        shift += 7
        if shift > 63: raise VmRunError("xz VLI overflows 63 bits")
    raise VmRunError("xz VLI truncated")


def read_declared_size(archive: Path, codec: str) -> int:
    """Read declared size from METADATA only — never inflates.
    gzip: ISIZE (last 4 bytes, mod 2^32, UNTRUSTED); xz: Index VLI sum (authoritative).
    """
    try:
        sz = archive.stat().st_size
        if codec == "gzip":
            if sz < 18: raise VmRunError(f"too small to be gzip: {sz}B")
            with open(archive, "rb") as f:
                f.seek(-4, 2); isize_b = f.read(4)
            if len(isize_b) != 4: raise VmRunError("cannot read gzip ISIZE trailer")
            return struct.unpack("<I", isize_b)[0]  # mod 2^32, untrusted
        elif codec == "xz":
            if sz < 32: raise VmRunError(f"too small to be xz: {sz}B")
            with open(archive, "rb") as f:
                f.seek(-12, 2); footer = f.read(12)
            if len(footer) != 12 or footer[10:12] != b"YZ":
                raise VmRunError("invalid xz stream footer (magic 'YZ' absent)")
            backward = struct.unpack_from("<I", footer, 4)[0]
            idx_size = (backward + 1) * 4
            if idx_size > _MAX_XZ_INDEX_BYTES:
                raise VmRunError(f"xz index size implausibly large: {idx_size} bytes")
            if idx_size + 12 > sz: raise VmRunError("xz index exceeds file bounds")
            with open(archive, "rb") as f:
                f.seek(-(12 + idx_size), 2)
                try:
                    idx = f.read(idx_size)
                except MemoryError:
                    raise VmRunError(f"xz index allocation failed ({idx_size} bytes): file may be crafted")
            if not idx or idx[0] != 0x00: raise VmRunError("xz index: wrong indicator byte")
            off = 1; n_rec, off = _decode_vli(idx, off); total = 0
            for _ in range(n_rec):
                _, off = _decode_vli(idx, off)
                usz, off = _decode_vli(idx, off); total += usz
            return total
        raise VmRunError(f"unsupported codec: {codec!r}")
    except (OSError, struct.error) as exc:
        raise VmRunError(f"cannot read declared size from {archive}: {exc}") from exc


def _detect_codec(path: Path) -> str:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
        try: magic = os.read(fd, 6)
        finally: os.close(fd)
    except OSError as exc: raise VmRunError(f"cannot read magic bytes: {exc}") from exc
    if magic[:2] == _GZIP_MAGIC: return "gzip"
    if magic[:6] == _XZ_MAGIC:   return "xz"
    raise VmRunError(f"unknown format (magic 0x{magic[:6].hex()}): only gzip/xz supported")


def build_plan(archive: Path, caps: dict[str, int], codec: str, *,
               input_sha: str, input_size: int, declared_size: int) -> dict[str, Any]:
    """Build vm-run-plan.v1 (pure planning, no subprocess)."""
    over_bound = declared_size > caps["output_bytes"]
    argv: list[str] = [
        "bwrap", "--die-with-parent", "--new-session",
        "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
        "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/work", "--dir", "/tmp/rsdd/out",
        "--ro-bind", str(archive.resolve()), "/input/archive", "--",
        *_CODEC_DECOMP[codec], "/input/archive",
    ]
    lims = ["outputs-unknown-until-live-run"]
    if over_bound: lims.append("decompression-bomb-bound-exceeded: plan refused")
    caveat = ("gzip ISIZE is mod-2^32 and untrusted; use xz for authoritative bounds"
              if codec == "gzip" else "xz index size is authoritative per xz stream spec")
    return {
        "schema_version": SCHEMA_VERSION, "codec": codec, "over_bound": over_bound,
        "input": {"path": str(archive.resolve()), "sha256": input_sha, "size": input_size,
                  "declared_decompressed_bytes": declared_size, "declared_size_caveat": caveat},
        "limits": {"cpu_seconds": caps["cpu_seconds"], "mem_bytes": caps["mem_bytes"],
                   "wall_seconds": caps["wall_seconds"], "output_bytes": caps["output_bytes"]},
        "mount_plan": {"input_ro": "/input/archive", "output_writable": "/tmp/rsdd/out",
                       "tmpfs_work": "/tmp/rsdd"},
        "planned_argv": argv, "outputs": [], "limitations": lims,
    }


def plan_run(args: Any) -> int:
    """Build plan + determinism record, route through gate. Returns exit code."""
    output_dir = Path(args.output)
    try: assert_safe_bind_root(Path(os.path.realpath(output_dir)))
    except BindScopeError as exc:
        print(f"vm-run: unsafe output path: {exc}", file=sys.stderr); return 2
    archive = Path(args.input)
    codec = args.codec
    if codec == "auto":
        try: codec = _detect_codec(archive)
        except VmRunError as exc: print(f"vm-run: {exc}", file=sys.stderr); return 2
    caps = {"cpu_seconds": args.cpu_seconds, "mem_bytes": args.max_mem_bytes,
            "wall_seconds": args.wall_seconds, "output_bytes": args.max_output_bytes}
    for k, v in caps.items():
        if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
            print(f"vm-run: cap {k!r} must be positive int", file=sys.stderr); return 2
    try: _, input_size, input_sha = _file_identity(archive, max_bytes=args.max_input_bytes)
    except AdapterError as exc: print(f"vm-run: {exc}", file=sys.stderr); return 2
    try: declared_size = read_declared_size(archive, codec)
    except VmRunError as exc: print(f"vm-run: {exc}", file=sys.stderr); return 2
    plan = build_plan(archive, caps, codec,
                      input_sha=input_sha, input_size=input_size, declared_size=declared_size)
    if plan["over_bound"]:
        print(f"vm-run: decompression-bomb bound: declared {declared_size} > cap {caps['output_bytes']}",
              file=sys.stderr); return 2
    # Dry-run determinism record: declared=false, basis=dry-run-plan, receipt_identity=null
    try: determinism = build_determinism(make_dry_run_det_spec())
    except VmDeterminismError as exc:
        print(f"vm-run: determinism error: {exc}", file=sys.stderr); return 2
    executor = select_executor(args.allow_exec, SCHEMA_VERSION)
    output_dir.mkdir(parents=True, exist_ok=True)
    _write(output_dir / "vm-run-plan.v1.json", plan)
    _write(output_dir / "vm-determinism.v1.json", determinism)
    return run_gate_epilogue(CAP_EXEC, args.allow_exec, plan, executor, "vm-run")


def _parser(argv: list[str] | None = None) -> Any:
    ap = argparse.ArgumentParser(prog="vm_run.py", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="Build vm-run-plan.v1 (dry-run only)")
    p.add_argument("--input",  required=True, metavar="ARCHIVE")
    p.add_argument("--output", required=True, metavar="DIR")
    p.add_argument("--codec",  default="auto", choices=["gzip", "xz", "auto"])
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
    return plan_run(args) if args.cmd == "plan" else 2


if __name__ == "__main__":
    sys.exit(main())
