#!/usr/bin/env python3
"""Determinism-evidence schema (vm-determinism.v1) — U-F2 item 12.
Wraps vm-run-receipt.v1 by identity hash; never extends or executes anything.
"""
from __future__ import annotations
import argparse, copy, hashlib, json, re, sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent; _TB = _HERE.parent
for _p in (str(_HERE), str(_TB)):
    if _p not in sys.path: sys.path.insert(0, _p)
from adapter_core import AdapterError, canonical_bytes, write as _write  # noqa: E402
from adapter_helpers import assert_safe_bind_root                        # noqa: E402

def _vm_receipt():
    import vm_receipt; return vm_receipt  # noqa: PLC0415

SCHEMA_VERSION = "vm-determinism.v1"
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
_VALID_BASES  = frozenset({"identity-match", "dry-run-plan", "unverified"})
_CONF_KEYS    = frozenset({"cpu_within", "mem_within", "wall_within", "output_within"})
_REPRO_SPEC   = frozenset({"basis", "replicate_identity"})
_REPRO_REC    = _REPRO_SPEC | {"declared"}
_SPEC_FIELDS  = frozenset({"schema_version", "receipt_identity", "seed", "clock",
                            "limits_conformance", "reproducible"})
_RECORD_FIELDS = _SPEC_FIELDS | {"identity"}


class VmDeterminismError(AdapterError):
    """Fail-closed contract violation for vm-determinism.v1."""


def _chk_hash(v: Any, ctx: str) -> str | None:
    if v is not None and (not isinstance(v, str) or not HASH_RE.fullmatch(v)):
        raise VmDeterminismError(f"{ctx}: must be sha256:<64hex> or null")
    return v

def _predicate(lc: dict, clock: dict, seed: Any, rid: Any, repid: Any) -> bool:
    """True iff all offline reproducibility conditions hold (fail-closed)."""
    return (all(lc.get(k) is True for k in _CONF_KEYS)
            and clock.get("mode") == "pinned"
            and seed is not None
            and rid is not None and repid is not None and rid == repid)

def _record_id(r: dict) -> str:
    s = copy.deepcopy(r); s.pop("identity", None)
    return "sha256:" + hashlib.sha256(canonical_bytes(s)).hexdigest()

def _derive_conformance(receipt: dict) -> dict:
    """Re-derive limits_conformance from receipt observed/limits/outputs."""
    lim, obs, total = receipt["limits"], receipt["observed"], sum(o["size"] for o in receipt.get("outputs", []))
    return {"cpu_within":  obs["cpu_seconds_measured"] <= lim["cpu_seconds"],
            "mem_within":  obs["mem_bytes_peak"]        <= lim["mem_bytes"],
            "wall_within": obs["wall_seconds_measured"] <= lim["wall_seconds"],
            "output_within": total                      <= lim["output_bytes"]}


def build_determinism(spec: dict[str, Any]) -> dict[str, Any]:
    """Build a canonical vm-determinism.v1 record; computes declared + identity."""
    if not isinstance(spec, dict) or set(spec) != _SPEC_FIELDS:
        raise VmDeterminismError(
            f"spec fields invalid; missing={sorted(_SPEC_FIELDS-set(spec)) if isinstance(spec,dict) else []}")
    if spec["schema_version"] != SCHEMA_VERSION:
        raise VmDeterminismError(f"unknown schema_version: {spec['schema_version']!r}")
    ri   = _chk_hash(spec["receipt_identity"], "receipt_identity")
    seed = spec["seed"]
    if seed is not None and (isinstance(seed, bool) or not isinstance(seed, int) or seed < 0):
        raise VmDeterminismError("seed must be a non-negative integer or null")
    clock = spec["clock"]
    if not isinstance(clock, dict) or set(clock) != {"mode", "epoch"}:
        raise VmDeterminismError("clock must have exactly {mode, epoch}")
    if clock["mode"] not in ("pinned", "host"):
        raise VmDeterminismError(f"clock.mode must be 'pinned' or 'host', got {clock['mode']!r}")
    if clock["mode"] == "pinned" and (not isinstance(clock["epoch"], str) or not clock["epoch"].strip()):
        raise VmDeterminismError("clock.epoch must be non-empty string when mode='pinned'")
    if clock["mode"] == "host" and clock["epoch"] is not None:
        raise VmDeterminismError("clock.epoch must be null when mode='host'")
    lc = spec["limits_conformance"]
    if not isinstance(lc, dict) or set(lc) != _CONF_KEYS or not all(isinstance(lc[k], bool) for k in _CONF_KEYS):
        raise VmDeterminismError(f"limits_conformance must have 4 booleans: {sorted(_CONF_KEYS)}")
    repro = spec["reproducible"]
    if not isinstance(repro, dict) or set(repro) != _REPRO_SPEC:
        raise VmDeterminismError(f"reproducible spec must have exactly {sorted(_REPRO_SPEC)}")
    basis = repro["basis"]
    if basis not in _VALID_BASES:
        raise VmDeterminismError(f"reproducible.basis must be one of {sorted(_VALID_BASES)}")
    repid    = _chk_hash(repro["replicate_identity"], "reproducible.replicate_identity")
    declared = _predicate(lc, clock, seed, ri, repid)
    if declared and basis != "identity-match":
        raise VmDeterminismError(f"basis must be 'identity-match' when predicate holds, got {basis!r}")
    if not declared and basis == "identity-match":
        raise VmDeterminismError("basis cannot be 'identity-match' when declared=False")
    record: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION, "receipt_identity": ri, "seed": seed,
        "clock": {"epoch": clock["epoch"], "mode": clock["mode"]},
        "limits_conformance": {k: lc[k] for k in sorted(_CONF_KEYS)},
        "reproducible": {"basis": basis, "declared": declared, "replicate_identity": repid},
        "identity": "",
    }
    record["identity"] = _record_id(record)
    return record


def validate_determinism(record: dict[str, Any]) -> None:
    """Validate a vm-determinism.v1 record (no file access).

    Reconstructs a spec, re-runs build_determinism, and asserts identity +
    declared are consistent with the canonical output (fail-closed).
    """
    if not isinstance(record, dict) or set(record) != _RECORD_FIELDS:
        raise VmDeterminismError(
            f"record fields invalid; missing={sorted(_RECORD_FIELDS-set(record)) if isinstance(record,dict) else []}")
    repro = record.get("reproducible", {})
    if not isinstance(repro, dict) or "declared" not in repro:
        raise VmDeterminismError("reproducible.declared missing")
    declared = repro["declared"]
    if not isinstance(declared, bool):
        raise VmDeterminismError("reproducible.declared must be a boolean")
    if not isinstance(record.get("identity", ""), str) or not HASH_RE.fullmatch(record.get("identity", "")):
        raise VmDeterminismError("identity must be sha256:<64hex>")
    spec = {k: v for k, v in record.items() if k != "identity"}
    spec["reproducible"] = {k: v for k, v in repro.items() if k != "declared"}
    rebuilt = build_determinism(spec)
    if rebuilt["identity"] != record["identity"]:
        raise VmDeterminismError("record identity does not match canonical content-addressed fields")
    if rebuilt["reproducible"]["declared"] != declared:
        raise VmDeterminismError(f"reproducible.declared={declared} inconsistent with offline predicate")


def verify_determinism(record: dict[str, Any], receipt_path: Path) -> None:
    """Cross-check *record* against the receipt at *receipt_path* (reads one file)."""
    validate_determinism(record)
    vr = _vm_receipt()
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise VmDeterminismError(f"cannot read receipt: {exc}") from exc
    try:
        vr.validate_receipt(receipt)
    except vr.VmReceiptError as exc:
        raise VmDeterminismError(f"referenced receipt invalid: {exc}") from exc
    stable = copy.deepcopy(receipt); stable.pop("identity", None); stable.pop("observed", None)
    actual_id = "sha256:" + hashlib.sha256(canonical_bytes(stable)).hexdigest()
    if actual_id != record["receipt_identity"]:
        raise VmDeterminismError(
            f"receipt identity mismatch: file={actual_id!r} record={record['receipt_identity']!r}")
    actual_lc = _derive_conformance(receipt); stored_lc = record["limits_conformance"]
    for k in sorted(_CONF_KEYS):
        if actual_lc[k] != stored_lc[k]:
            raise VmDeterminismError(f"limits_conformance.{k}: derived={actual_lc[k]} stored={stored_lc[k]}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--spec", type=Path, required=True); b.add_argument("--output", type=Path, required=True)
    b.add_argument("--overwrite", action="store_true")
    sub.add_parser("validate").add_argument("record", type=Path)
    v = sub.add_parser("verify"); v.add_argument("--receipt", type=Path, required=True); v.add_argument("record", type=Path)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "build":
            assert_safe_bind_root(args.output.parent.resolve())
            rec = build_determinism(json.loads(args.spec.read_text(encoding="utf-8")))
            if not args.overwrite and args.output.exists():
                raise VmDeterminismError("output exists; use --overwrite to replace")
            _write(args.output, rec)
        elif args.cmd == "validate":
            validate_determinism(json.loads(args.record.read_text(encoding="utf-8")))
        else:
            verify_determinism(json.loads(args.record.read_text(encoding="utf-8")), args.receipt)
    except (VmDeterminismError, AdapterError, OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"vm-plan: {exc}", file=sys.stderr); return 2
    return 0

if __name__ == "__main__":
    sys.exit(main())
