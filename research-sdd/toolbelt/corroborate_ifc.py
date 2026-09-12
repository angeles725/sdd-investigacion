#!/usr/bin/env python3
"""Produce bounded offline entity inventory from an IFC/BIM model file.

Runs ifcopenshell (0.8.5, rsdd-ifc venv) inside a network-denied Bubblewrap
sandbox to parse an IFC file and emit a deterministic entity-histogram
evidence envelope.

Reports COUNTS + a BOUNDED, sorted entity histogram — never raw geometry or
unbounded attribute trees.  Any cap that fires is reported in limitations and
entity_histogram.truncated is set to true; truncation is never silent.

Anti-silent-zero (§7): three states are always distinguishable:
  - absent-input: stage_file() raises AdapterError before the driver runs.
  - empty-input:  valid IFC with zero entities → total_entities=0, items=[].
  - no-match:     entities exist; the histogram covers ALL types (no filter).
A zero count in entity_histogram.total_entities proves the driver actually
looked and found an empty model, not that it failed to open the file.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
sys.path.insert(0, str(_HERE))
from lib.adapter_core import (
    AdapterError,
    executable,
    require_private,
    run_bounded,
    sandbox,
    stage_file,
)
from lib.adapter_helpers import (
    ManifestError,
    VenvBindError,
    assert_safe_bind_root,
    BindScopeError,
    emit_evidence,
    run_truncation,
)
from lib.isolation_profile import PROFILE_BWRAP_IFC_OFFLINE

SCHEMA = "ifc-evidence.v1"
_PROFILE = PROFILE_BWRAP_IFC_OFFLINE

# Default venv Python path (overridable via RSDD_IFC_PY env var)
_DEFAULT_IFC_PY = Path("~/.local/share/rsdd-ifc/bin/python")
# Default driver path (overridable via RSDD_IFC_DRIVER env var for testing)
_DEFAULT_IFC_DRIVER = _HERE / "lib" / "ifc_driver.py"

# Cap constants
_MAX_TYPES_DEFAULT = 200       # maximum entity types listed
_OUTPUT_CAP_BYTES = 4 * 1024 * 1024  # 4 MiB driver output cap

_LIMITATIONS: list[str] = [
    "ifcopenshell performs static IFC parsing; geometry and parametric data "
    "are not evaluated.",
    "Only entity types present in the file are reported; the histogram is "
    "bounded by --max-types; any cap that fires is recorded in limitations.",
    "Bubblewrap on WSL2 provides network isolation but is not a full hostile-"
    "parser security boundary; use a disposable VM for adversarial IFC files.",
    "Caps (--max-types, --timeout) bound resource use; any cap that fires is "
    "reported in limitations and truncated is set true — never silent.",
]


class IFCError(AdapterError):
    """Fail-closed error for the IFC evidence adapter."""


# ---------------------------------------------------------------------------
# IFC venv binding helpers (analogous to _bind_kaitai_venv in corroborate_kaitai.py)
# ---------------------------------------------------------------------------

def _bind_tree(p: Path) -> list[str]:
    """Return bwrap args: --dir stubs for ancestors + --ro-bind for p."""
    parts = p.parts
    args: list[str] = []
    for i in range(1, len(parts)):
        args += ["--dir", str(Path(*parts[: i + 1]))]
    args += ["--ro-bind", str(p), str(p)]
    return args


def _ld_so_stub_for(prefix: Path) -> list[str]:
    """Find the brew ld.so symlink under *prefix* and recreate it in the sandbox."""
    for p in [prefix, *prefix.parents]:
        ld_so = p / "lib" / "ld.so"
        try:
            if ld_so.is_symlink():
                target = os.readlink(str(ld_so))
                return ["--dir", str(ld_so.parent), "--symlink", target, str(ld_so)]
        except OSError:
            continue
    return []


def _ifc_scope_guard(p: Path) -> None:
    """Bind-scope check for IFC venv paths.  Raises IFCError on violation."""
    try:
        assert_safe_bind_root(p)
    except BindScopeError as exc:
        raise IFCError(f"IFC venv path rejected by bind-scope guard: {exc}") from exc


def _bind_ifc_venv(prefix: list[str], ifc_py: Path) -> list[str]:
    """Extend *prefix* with bwrap args for the rsdd-ifc Python venv.

    The IFC Python at ~/.local/share/rsdd-ifc/bin/python has a symlink chain
    (via the brew Cellar Python) that venv_root_for() cannot follow.  This
    function reads pyvenv.cfg manually and binds BOTH the venv root AND the
    brew Cellar Python, then recreates the opt→Cellar symlink and ld.so stub.

    Security: same scope guards as bind_venv(); no write access.
    """
    if not prefix or prefix[-1] != "--":
        raise IFCError("bwrap prefix must end with '--' (produced by sandbox())")

    # Derive venv_root from unexpanded path to stop at the venv boundary
    ifc_py_expanded = ifc_py.expanduser()
    venv_root = ifc_py_expanded.parent.parent

    _ifc_scope_guard(venv_root)
    pyvenv = venv_root / "pyvenv.cfg"
    if not pyvenv.is_file():
        raise IFCError(
            f"IFC Python is not inside a venv (no pyvenv.cfg): {venv_root}"
        )

    # Belt: venv_root must not be the real home directory
    home = Path(os.path.expanduser("~")).resolve()
    if venv_root.resolve() == home:
        raise IFCError("IFC Python venv must not be the home directory")

    # Parse pyvenv.cfg to find the brew Python executable
    cfg: dict[str, str] = {}
    for line in pyvenv.read_text().splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip()

    brew_exe_str = cfg.get("executable", "")
    if not brew_exe_str:
        raise IFCError(f"pyvenv.cfg missing 'executable' key: {pyvenv}")
    brew_exe = Path(brew_exe_str)

    # brew_prefix = parent of bin/ dir inside the Cellar version
    brew_prefix = brew_exe.parent.parent
    _ifc_scope_guard(brew_prefix)
    if not brew_exe.is_file():
        raise IFCError(f"brew Python executable not found: {brew_exe}")

    # Recreate the opt→Cellar symlink if present
    opt_args: list[str] = []
    brew_home_str = cfg.get("home", "")
    if brew_home_str:
        opt_py = Path(brew_home_str).parent  # strip /bin
        if os.path.islink(str(opt_py)):
            opt_target = os.readlink(str(opt_py))
            opt_parent = opt_py.parent
            opt_args = [
                "--dir", str(opt_parent),
                "--symlink", opt_target, str(opt_py),
            ]

    extra: list[str] = []
    extra += _bind_tree(venv_root)
    extra += _bind_tree(brew_prefix)
    extra += opt_args
    extra += _ld_so_stub_for(brew_prefix)

    return prefix[:-1] + extra + ["--"]


# ---------------------------------------------------------------------------
# Driver stdout reader
# ---------------------------------------------------------------------------

def _read_stdout_json(stdout_path: Path) -> tuple[dict[str, Any] | None, str | None]:
    """Parse JSON from the driver's stdout file.

    Returns (dict, None) on success, (None, error_str) on failure.
    An empty file is treated as an error (driver produced no output).
    """
    try:
        text = stdout_path.read_text(errors="replace").strip()
    except OSError as exc:
        return None, f"cannot read driver output: {exc}"
    if not text:
        return None, "driver produced no output (empty stdout)"
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        return None, f"driver output is not valid JSON: {exc}"
    if not isinstance(data, dict):
        return None, f"driver output is not a JSON object: {type(data).__name__}"
    return data, None


# ---------------------------------------------------------------------------
# Entity histogram builder (sort + cap, applied in outer adapter for testability)
# ---------------------------------------------------------------------------

def _build_entity_histogram(
    entity_counts: dict[str, int],
    max_types: int,
) -> dict[str, Any]:
    """Build bounded, sorted entity histogram from raw driver counts.

    Sort order: count DESC then type name ASC (deterministic).
    Cap: max_types limits items list; truncated=True when cap fires.
    Anti-silent-zero: total_entities=0 proves the instrument looked and found
    nothing — never returns a bare 0 that could mean "driver did not run".
    """
    total_entities = sum(entity_counts.values())
    total_types = len(entity_counts)

    all_items = [
        {"type": t, "count": c}
        for t, c in entity_counts.items()
    ]
    # Deterministic sort: count DESC, then type ASC
    all_items.sort(key=lambda x: (-x['count'], x['type']))

    cap_hit = total_types > max_types
    sampled_items = all_items[:max_types]

    return {
        "items": sampled_items,
        "total_entities": total_entities,
        "total_types": total_types,
        "truncated": cap_hit,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="corroborate-ifc")
    p.add_argument("--input", type=Path, required=True,
                   help="IFC/BIM model file to analyse")
    p.add_argument("--output", type=Path, required=True,
                   help="New output directory (must not exist)")
    p.add_argument("--timeout", type=int, default=120,
                   help="Wall-clock timeout for the driver (seconds, default 120)")
    p.add_argument("--max-types", type=int, default=_MAX_TYPES_DEFAULT,
                   help=f"Maximum entity types in histogram (default {_MAX_TYPES_DEFAULT})")
    p.add_argument("--manifest-cli", type=Path, required=True,
                   help=argparse.SUPPRESS)
    return p


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:  # noqa: C901
    args = _parser().parse_args(argv)
    stage: Path | None = None

    try:
        # Caps validation
        if args.timeout < 1:
            raise IFCError("--timeout must be >= 1")
        if args.max_types < 1:
            raise IFCError("--max-types must be >= 1")

        # Output path safety
        if ".." in args.output.parts or "\\" in str(args.output):
            raise IFCError("output must be a canonical path")

        parent = args.output.parent.resolve(strict=True)
        require_private(parent)

        destination = parent / args.output.name
        if destination.exists() or destination.is_symlink():
            raise IFCError("output must be a new non-colliding path")

        # Manifest CLI must exist
        manifest_cli = args.manifest_cli.resolve(strict=True)

        # Resolve bwrap
        search = os.environ.get("PATH", "")
        bwrap_exe, bwrap_record = executable(
            "bwrap", os.environ.get("RSDD_BWRAP"), search
        )

        # Resolve IFC venv Python
        ifc_py_raw = Path(os.environ.get("RSDD_IFC_PY", str(_DEFAULT_IFC_PY)))

        # Resolve driver script (RSDD_IFC_DRIVER allows test override)
        driver_raw = Path(
            os.environ.get("RSDD_IFC_DRIVER", str(_DEFAULT_IFC_DRIVER))
        )
        driver_path = driver_raw.resolve(strict=True)

        # Probe venv (quick check before staging)
        ifc_py_expanded = ifc_py_raw.expanduser()
        if not ifc_py_expanded.exists():
            raise IFCError(
                f"IFC venv Python not found: {ifc_py_raw}\n"
                f"Install with: python3 -m venv ~/.local/share/rsdd-ifc && "
                f"~/.local/share/rsdd-ifc/bin/pip install ifcopenshell"
            )

        # Create staging directory
        stage = parent / f".{destination.name}.stage"
        stage.mkdir(mode=0o700)
        (stage / "input").mkdir()
        (stage / "engine").mkdir()

        # Stage the input IFC file
        source_record, staged_record = stage_file(
            args.input,
            stage / "input" / "model.ifc",
            "input/model.ifc",
            0o400,
        )

        # Stage the driver script
        drv_src, drv_staged = stage_file(
            driver_path,
            stage / "engine" / "ifc_driver.py",
            "engine/ifc_driver.py",
            0o500,
        )

        # Sandbox environment
        env: dict[str, str] = {
            "HOME": "/tmp/rsdd/home",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/usr/sbin:/bin:/sbin",
            "TMPDIR": "/tmp/rsdd",
            "TZ": "UTC",
        }

        # Build bwrap prefix: base sandbox + IFC venv bind
        prefix = sandbox(bwrap_exe, env)
        prefix = _bind_ifc_venv(prefix, ifc_py_raw)

        # Inside-sandbox paths (match sandbox() work-dir bind at /tmp/rsdd/work/)
        input_in_sandbox = "/tmp/rsdd/work/input/model.ifc"
        driver_in_sandbox = "/tmp/rsdd/work/engine/ifc_driver.py"

        # Canonical driver argv (deterministic; uses fixed sandbox paths)
        driver_argv_canonical: list[str] = [
            str(ifc_py_raw.expanduser()),
            driver_in_sandbox,
            "--input", input_in_sandbox,
        ]

        driver_cmd = prefix + driver_argv_canonical

        # Run driver under bounded subprocess control
        run_record, run_errors = run_bounded(
            driver_cmd,
            stage,
            env,
            timeout=args.timeout,
            max_bytes=_OUTPUT_CAP_BYTES,
        )

        # Read driver JSON output
        stdout_path = stage / "engine" / "stdout.txt"
        driver_result, parse_json_error = _read_stdout_json(stdout_path)

        # Run-cap truncation
        run_trunc, trunc_lims = run_truncation(run_errors, "ifc-driver")

        # Extract results from driver output
        all_limitations = list(_LIMITATIONS) + trunc_lims
        all_errors: list[str] = list(run_errors)

        if parse_json_error:
            all_errors.append(f"driver-output-error: {parse_json_error}")

        parse_error: str | None = None
        entity_histogram: dict[str, Any]

        if driver_result is not None:
            parse_error = driver_result.get("parse_error")
            if parse_error:
                all_errors.append(f"parse-error: {parse_error}")

            raw_counts: dict[str, int] = driver_result.get("entity_counts", {})
            entity_histogram = _build_entity_histogram(raw_counts, args.max_types)
            if run_trunc:
                entity_histogram["truncated"] = True
            if entity_histogram["truncated"]:
                all_limitations.append(
                    f"histogram truncated: entity-type cap {args.max_types} reached "
                    f"(total_types={entity_histogram['total_types']})"
                )

            ifc_domain: dict[str, Any] = {
                "schema_version": driver_result.get("schema_version"),
                "units": driver_result.get("units", {"length": None, "area": None}),
                "entity_histogram": entity_histogram,
                "project": {
                    "name": driver_result.get("project_name"),
                    "site_count": driver_result.get("site_count", 0),
                },
                "driver_argv": driver_cmd,
            }
        else:
            # Driver produced no output (timeout, fatal crash, etc.)
            entity_histogram = {
                "items": [],
                "total_entities": 0,
                "total_types": 0,
                "truncated": run_trunc,
            }
            ifc_domain = {
                "schema_version": None,
                "units": {"length": None, "area": None},
                "entity_histogram": entity_histogram,
                "project": {"name": None, "site_count": 0},
                "driver_argv": driver_cmd,
            }
            if not all_errors:
                all_errors.append("driver produced no output")

        domain: dict[str, Any] = {"ifc": ifc_domain}

        manifest_spec: dict[str, Any] = {
            "argv": driver_cmd,
            "completeness": "failed" if all_errors else "complete",
            "environment": env,
            "errors": all_errors,
            "findings": [],
            "input": {
                "detected_type": "IFC/BIM model",
                "path": "input/model.ifc",
            },
            "isolation_profile": _PROFILE,
            "limitations": all_limitations,
            "outputs": [f"{SCHEMA}.json"],
            "run": run_record,
            "schema_version": "analysis-manifest.v1",
            "stderr_path": "engine/stderr.txt",
            "stdout_path": "engine/stdout.txt",
            "tool": {
                "artifacts": [],
                "executable": str(bwrap_exe),
                "name": "ifcopenshell",
                "version": "0.8.5",
            },
        }

        emit_evidence(
            stage=stage,
            schema=SCHEMA,
            domain=domain,
            input_identity={"source": source_record, "staged": staged_record},
            isolation={"launcher": bwrap_record, "profile": _PROFILE},
            limitations=all_limitations,
            errors=all_errors,
            manifest_spec=manifest_spec,
            manifest_cli=manifest_cli,
            destination=destination,
            timeout=60,
        )
        stage = None
        return 1 if all_errors else 0

    except (IFCError, AdapterError, ManifestError, VenvBindError,
            OSError, subprocess.SubprocessError) as exc:
        print(f"corroborate-ifc: {exc}", file=sys.stderr)
        return 2
    finally:
        if stage is not None and stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    sys.exit(main())
