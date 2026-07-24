#!/usr/bin/env python3
"""kaitai_driver.py — sandboxed binary parser worker for corroborate_kaitai.py.

Runs inside bwrap (Stage 2).  Only stdlib + kaitaistruct are imported at runtime;
the toolbelt is NOT on sys.path and must not be imported here.

Protocol
--------
  stdin  : empty (binary is passed as --input)
  stdout : one JSON object (driver result)
  stderr : diagnostic text (captured by parent)
  exit 0 : driver ran (parse_error may still be set for format violations)
  exit 1 : fatal — could not import/find the generated parser class

Output schema
-------------
  {
    "root_type"      : str,
    "module"         : str,
    "fields"         : [ FieldRecord, ... ],
    "counts"         : { "total_fields": int, "sampled": int },
    "truncated"      : bool,
    "depth_cap"      : bool,
    "value_trunc"    : bool,
    "memory_cap"     : bool,   # true when RLIMIT_AS exhaustion fires during parse
    "parse_error"    : str | null,
    "runtime_version": str
  }

FieldRecord
-----------
  path, name, type, start, end, size, [value], [depth_cap], [count]
"""
from __future__ import annotations

import argparse
import collections
import hashlib
import importlib.util
import inspect
import json
import os
import resource
import sys
from io import BytesIO
from pathlib import Path
from typing import Any, Generator

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_MAX_REPR = 256   # fallback repr truncation for unknown types


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _sha256(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def _encode_bytes_value(raw: bytes, max_bytes: int) -> dict:
    truncated = len(raw) > max_bytes
    return {
        "hex": raw[:max_bytes].hex(),
        "sha256": _sha256(raw),
        "size": len(raw),
        "value_truncated": truncated,
    }


def _encode_str_value(s: str, max_bytes: int) -> dict:
    encoded = s.encode("utf-8", errors="replace")
    truncated = len(s) > max_bytes
    return {
        "value": s[:max_bytes],
        "sha256": _sha256(encoded),
        "size": len(encoded),
        "value_truncated": truncated,
    }


# ---------------------------------------------------------------------------
# Recursive field walk
# ---------------------------------------------------------------------------

def _walk(
    obj: Any,
    path_prefix: str,
    total: list,          # [int] — mutable counter for ALL visited fields
    sampled_limit: int,   # max fields to yield (field cap)
    depth: int,
    max_depth: int,
    max_value_bytes: int,
    depth_cap_flag: list, # [bool] — set to [True] when depth cap fires
    value_trunc_flag: list,  # [bool] — set to [True] when any value is truncated
) -> Generator[dict, None, None]:
    """Yield FieldRecord dicts for all reachable fields, respecting caps."""
    # kaitaistruct is guaranteed importable here: main() returns 1 before
    # calling _walk when the import fails.
    import kaitaistruct
    KaitaiStruct = kaitaistruct.KaitaiStruct

    seq_fields = getattr(obj, "SEQ_FIELDS", None)
    if not seq_fields:
        return

    # Try to get _debug info (defaultdict populated during _read)
    debug_map = getattr(obj, "_debug", {})

    for name in seq_fields:
        total[0] += 1

        full_path = f"{path_prefix}.{name}" if path_prefix else name
        db = debug_map.get(name) if debug_map else {}
        start = db.get("start") if db else None
        end = db.get("end") if db else None
        size = (end - start) if (end is not None and start is not None) else None

        value = getattr(obj, name, None)

        rec: dict = {
            "path": full_path,
            "name": name,
            "start": start,
            "end": end,
            "size": size,
        }

        # Determine type
        if value is None:
            rec["type"] = "null"
        elif isinstance(value, KaitaiStruct):
            rec["type"] = "struct"
            if depth >= max_depth:
                rec["depth_cap"] = True
                depth_cap_flag[0] = True
        elif isinstance(value, list):
            rec["type"] = "list"
            rec["count"] = len(value)
        elif isinstance(value, bytes):
            rec["type"] = "bytes"
            v = _encode_bytes_value(value, max_value_bytes)
            rec["value"] = v
            if v["value_truncated"]:
                value_trunc_flag[0] = True
        elif isinstance(value, str):
            rec["type"] = "str"
            v = _encode_str_value(value, max_value_bytes)
            rec["value"] = v
            if v["value_truncated"]:
                value_trunc_flag[0] = True
        elif isinstance(value, bool):
            rec["type"] = "bool"
            rec["value"] = value
        elif isinstance(value, int):
            rec["type"] = "int"
            rec["value"] = value
        elif isinstance(value, float):
            rec["type"] = "float"
            rec["value"] = value
        else:
            rec["type"] = type(value).__name__
            rec["value"] = repr(value)[:_MAX_REPR]

        # Yield if within sampled limit
        yielded = total[0] <= sampled_limit
        if yielded:
            yield rec

        # Recurse into struct children (if not depth-capped)
        if rec["type"] == "struct" and not rec.get("depth_cap"):
            yield from _walk(
                value,
                full_path,
                total,
                sampled_limit,
                depth + 1,
                max_depth,
                max_value_bytes,
                depth_cap_flag,
                value_trunc_flag,
            )


# ---------------------------------------------------------------------------
# Module loading
# ---------------------------------------------------------------------------

def _load_generated_module(module_dir: Path, stem: str):
    """Import the ksc-generated Python module from *module_dir*/<stem>.py."""
    src = module_dir / f"{stem}.py"
    if not src.is_file():
        raise FileNotFoundError(f"generated parser not found: {src}")
    spec = importlib.util.spec_from_file_location(stem, src)
    if spec is None:
        raise ImportError(f"cannot create spec for {src}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[stem] = mod
    spec.loader.exec_module(mod)
    return mod


def _find_root_class(mod, hint: str | None):
    """Return the kaitai root class from *mod*, using *hint* if given."""
    try:
        import kaitaistruct
        KaitaiStruct = kaitaistruct.KaitaiStruct
    except ImportError:
        raise SystemExit("kaitaistruct not importable")

    candidates = [
        (name, obj)
        for name, obj in inspect.getmembers(mod, inspect.isclass)
        if issubclass(obj, KaitaiStruct) and obj is not KaitaiStruct
    ]
    if not candidates:
        raise ValueError("no KaitaiStruct subclass found in generated module")

    if hint:
        # exact match first, then case-insensitive
        for name, cls in candidates:
            if name == hint:
                return name, cls
        for name, cls in candidates:
            if name.lower() == hint.lower():
                return name, cls
        raise ValueError(f"class {hint!r} not found; available: {[n for n, _ in candidates]}")

    # Heuristic: prefer the class whose name matches the module stem (ksc convention).
    # ksc capitalises and camel-cases the meta.id; e.g. id=nested_demo → NestedDemo.
    # Normalise by stripping underscores before comparing so the heuristic matches
    # both the plain (id=demo → Demo) and the snake_case (id=nested_demo → NestedDemo)
    # forms.
    stem = getattr(mod, "__name__", "")
    stem_norm = stem.lower().replace("_", "")
    for name, cls in candidates:
        if name.lower().replace("_", "") == stem_norm:
            return name, cls
    # Fallback: inspect.getmembers returns members in alphabetical order (not source
    # order).  For standard ksc output the root class name typically sorts first, but
    # this is not guaranteed when multiple KaitaiStruct subclasses are present.
    return candidates[0]


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Kaitai Struct sandboxed driver")
    p.add_argument("--module-dir", required=True)
    p.add_argument("--stem", required=True, help="generated .py stem (= meta.id)")
    p.add_argument("--root-class", default=None, help="override root class name")
    p.add_argument("--input", required=True, help="binary file to parse")
    p.add_argument("--max-fields", type=int, default=2000)
    p.add_argument("--max-depth", type=int, default=32)
    p.add_argument("--max-value-bytes", type=int, default=64)
    p.add_argument("--max-memory-mb", type=int, default=256)
    return p.parse_args()


def main() -> int:  # noqa: C901 — intentionally comprehensive for safety
    args = _parse_args()

    # ---- Memory limit (RLIMIT_AS) ----------------------------------------
    mem_bytes = args.max_memory_mb * 1024 * 1024
    try:
        resource.setrlimit(resource.RLIMIT_AS, (mem_bytes, mem_bytes))
    except (ValueError, resource.error):
        pass  # non-fatal; sandbox CPU/time limits still apply

    # ---- Resolve paths -----------------------------------------------------
    module_dir = Path(args.module_dir)
    input_path = Path(args.input)

    # ---- Load generated module --------------------------------------------
    try:
        mod = _load_generated_module(module_dir, args.stem)
    except Exception as exc:
        print(f"FATAL: cannot load generated module: {exc}", file=sys.stderr)
        return 1

    # ---- Find root class --------------------------------------------------
    try:
        class_name, RootCls = _find_root_class(mod, args.root_class)
    except Exception as exc:
        print(f"FATAL: root class not found: {exc}", file=sys.stderr)
        return 1

    module_name = mod.__name__

    # ---- Import kaitaistruct (for stream and version) ----------------------
    try:
        import kaitaistruct
        runtime_version = kaitaistruct.__version__
        KaitaiStream = kaitaistruct.KaitaiStream
    except ImportError:
        print("FATAL: kaitaistruct not importable", file=sys.stderr)
        return 1

    # ---- Pre-serialize memory-cap result (before binary read) ----------------
    # After RLIMIT_AS exhaustion, even tiny Python allocations (list literals,
    # string formatting, dict construction) can fail with a second MemoryError
    # because the process may already be at its address-space ceiling.
    # Serialise the memory-cap result NOW, while the process has ample headroom,
    # so the except-MemoryError handler can emit it via a single os.write()
    # syscall — no new memory from the Python allocator is required.
    _memory_cap_result_bytes: bytes = (json.dumps(
        {
            "root_type": class_name,
            "module": module_name,
            "fields": [],
            "counts": {"total_fields": 0, "sampled": 0},
            "truncated": True,
            "depth_cap": False,
            "value_trunc": False,
            "memory_cap": True,
            "parse_error": None,
            "runtime_version": runtime_version,
        },
        separators=(",", ":"),
        default=str,
    ) + "\n").encode("utf-8")

    # ---- Parse binary ------------------------------------------------------
    try:
        raw = input_path.read_bytes()
    except OSError as exc:
        print(f"FATAL: cannot read input: {exc}", file=sys.stderr)
        return 1

    parse_error: str | None = None
    obj = None
    try:
        obj = RootCls(KaitaiStream(BytesIO(raw)))
        obj._read()
    except MemoryError:
        # RLIMIT_AS exhaustion: a resource-cap event, not a malformed-input
        # parse error.  Write the pre-serialized JSON via os.write (no new
        # Python allocations) so the result is reliably emitted even when the
        # process is near or at its address-space limit.
        try:
            os.write(1, _memory_cap_result_bytes)
        except OSError:
            return 1
        return 0
    except Exception as exc:
        # Parse error is NOT fatal; we still walk what was set
        parse_error = f"{type(exc).__name__}: {exc}"

    # ---- Walk fields -------------------------------------------------------
    total = [0]
    depth_cap_flag = [False]
    value_trunc_flag = [False]
    fields: list[dict] = []

    if obj is not None:
        for rec in _walk(
            obj,
            "",
            total,
            args.max_fields,
            0,
            args.max_depth,
            args.max_value_bytes,
            depth_cap_flag,
            value_trunc_flag,
        ):
            fields.append(rec)

    total_fields = total[0]
    sampled = len(fields)
    truncated = (
        (sampled < total_fields)
        or depth_cap_flag[0]
        or value_trunc_flag[0]
    )

    result = {
        "root_type": class_name,
        "module": module_name,
        "fields": fields,
        "counts": {
            "total_fields": total_fields,
            "sampled": sampled,
        },
        "truncated": truncated,
        "depth_cap": depth_cap_flag[0],
        "value_trunc": value_trunc_flag[0],
        "memory_cap": False,
        "parse_error": parse_error,
        "runtime_version": runtime_version,
    }

    json.dump(result, sys.stdout, separators=(",", ":"), default=str)
    sys.stdout.write("\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
