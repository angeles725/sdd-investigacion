#!/usr/bin/env python3
"""ifc_driver.py — IFC/BIM model parser worker for corroborate_ifc.py.

Runs inside bwrap (network-denied, cap-drop ALL).  Imports stdlib + ifcopenshell.
The toolbelt lib/ is NOT on sys.path; no toolbelt module is imported here.

Protocol
--------
  stdin   : empty (input path passed as --input)
  stdout  : one JSON object (driver result); see schema below
  stderr  : diagnostic text; no tracebacks
  exit 0  : driver ran successfully
  exit 3  : ifcopenshell not importable (dependency missing)
  exit 4  : IFC parse error (bad format, unreadable file)

Output JSON schema
------------------
  {
    "schema_version": "IFC4" | "IFC2X3" | "IFC4X3" | ...,
    "units": {"length": str | null, "area": str | null},
    "entity_counts": {"IfcWall": 3, "IfcSpace": 1, ...},
    "total_types":   int,
    "project_name":  str | null,
    "site_count":    int,
    "parse_error":   str | null
  }

Anti-silent-zero
----------------
entity_counts is always present (empty dict when zero entities).  A missing or
absent-key result never replaces an explicit empty-dict result, so the caller
can distinguish "driver did not produce output" from "driver found zero entities".
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Dependency check — exit 3 when ifcopenshell is absent
# ---------------------------------------------------------------------------
try:
    import ifcopenshell  # type: ignore[import]
except ImportError as _e:
    print(f"ifc-driver: ifcopenshell not importable: {_e}", file=sys.stderr)
    sys.exit(3)

# ---------------------------------------------------------------------------
# Unit extraction helpers
# ---------------------------------------------------------------------------

_LENGTH_UNIT_NAMES: frozenset[str] = frozenset(
    {"METRE", "MILLIMETRE", "CENTIMETRE", "INCH", "FOOT", "YARD"}
)
_AREA_UNIT_NAMES: frozenset[str] = frozenset(
    {"SQUARE_METRE", "SQUARE_MILLIMETRE", "SQUARE_CENTIMETRE",
     "SQUARE_INCH", "SQUARE_FOOT", "SQUARE_YARD"}
)


def _extract_units(ifc: Any) -> dict[str, str | None]:
    """Return {"length": name|null, "area": name|null} from IfcUnitAssignment."""
    length: str | None = None
    area: str | None = None
    try:
        for assignment in ifc.by_type("IfcUnitAssignment"):
            for unit in (assignment.Units or []):
                unit_type = getattr(unit, "UnitType", None)
                unit_name = getattr(unit, "Name", None)
                if unit_type == "LENGTHUNIT" and length is None:
                    length = str(unit_name) if unit_name else None
                elif unit_type == "AREAUNIT" and area is None:
                    area = str(unit_name) if unit_name else None
    except Exception:  # noqa: BLE001 — best-effort; never crash on optional data
        pass
    return {"length": length, "area": area}


# ---------------------------------------------------------------------------
# Project/site extraction
# ---------------------------------------------------------------------------

_MAX_NAME_CHARS = 256  # cap on echoed string lengths


def _safe_str(val: Any) -> str | None:
    """Return a bounded string or None when val is absent/None."""
    if val is None:
        return None
    s = str(val)
    return s[:_MAX_NAME_CHARS] if s else None


def _extract_project_site(ifc: Any) -> tuple[str | None, int]:
    """Return (project_name, site_count)."""
    project_name: str | None = None
    try:
        projects = ifc.by_type("IfcProject")
        if projects:
            project_name = _safe_str(getattr(projects[0], "Name", None))
    except Exception:  # noqa: BLE001
        pass

    site_count = 0
    try:
        site_count = len(ifc.by_type("IfcSite"))
    except Exception:  # noqa: BLE001
        pass

    return project_name, site_count


# ---------------------------------------------------------------------------
# CLI and main
# ---------------------------------------------------------------------------

def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="ifc-driver")
    p.add_argument("--input", type=Path, required=True,
                   help="Staged IFC file to parse")
    return p


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    result: dict[str, Any] = {
        "schema_version": None,
        "units": {"length": None, "area": None},
        "entity_counts": {},
        "total_types": 0,
        "project_name": None,
        "site_count": 0,
        "parse_error": None,
    }

    try:
        ifc_path = args.input.resolve()
        if not ifc_path.exists():
            result["parse_error"] = f"input file not found: {args.input}"
            print(json.dumps(result, separators=(",", ":")), flush=True)
            return 4

        try:
            ifc = ifcopenshell.open(str(ifc_path))
        except Exception as exc:  # noqa: BLE001
            # Capture parse error without traceback
            msg = str(exc).splitlines()[0][:512]
            result["parse_error"] = f"ifcopenshell parse error: {msg}"
            print(json.dumps(result, separators=(",", ":")), flush=True)
            return 4

        # Schema version from file header
        result["schema_version"] = ifc.schema or "unknown"

        # Units
        result["units"] = _extract_units(ifc)

        # Entity histogram — raw counts per type
        entity_counts: dict[str, int] = {}
        try:
            # by_type("IfcRoot") covers most named entities; walk all types
            for entity in ifc:
                etype = entity.is_a()
                entity_counts[etype] = entity_counts.get(etype, 0) + 1
        except Exception:  # noqa: BLE001
            pass

        result["entity_counts"] = entity_counts
        result["total_types"] = len(entity_counts)

        # Project / site
        result["project_name"], result["site_count"] = _extract_project_site(ifc)

    except Exception as exc:  # noqa: BLE001
        msg = str(exc).splitlines()[0][:512]
        result["parse_error"] = f"unexpected error: {msg}"
        print(json.dumps(result, separators=(",", ":")), flush=True)
        return 4

    print(json.dumps(result, separators=(",", ":")), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
