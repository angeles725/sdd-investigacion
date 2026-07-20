#!/usr/bin/env python3
"""Define, build, validate, and verify deterministic in-VM run receipts (vm-run-receipt.v1).

This module only reads supplied hashes and artifact files; it never launches a VM.
"""
from __future__ import annotations

import argparse, copy, hashlib, json, math, os, re, sys
from pathlib import Path
from typing import Any

_LIB = Path(__file__).parent / "lib"
sys.path.insert(0, str(_LIB))
from adapter_core import (AdapterError, canonical_bytes,  # noqa: E402
                          identity as _file_identity,
                          write as _write, publish as _publish)

SCHEMA_VERSION = "vm-run-receipt.v1"
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SECRET_KEY_RE = re.compile(r"(?i)(secret|token|passw(?:or)?d|credential|private|api[_-]?key|auth|cookie)")
SECRET_VALUE_RE = re.compile(
    r"(?i)(bearer\s+\S+|ghp_[A-Za-z0-9]{20,}|xoxb-[A-Za-z0-9-]{10,}"
    r"|eyJ[A-Za-z0-9_-]{10,}\.|AKIA[0-9A-Z]{16}|-----BEGIN\s+[^-]*PRIVATE KEY-----"
    r"|(?:secret|token|passw(?:or)?d|api[_-]?key|authorization|cookie)\s*[:=])"
)
SECRET_OPTION_RE = re.compile(
    r"(?i)(?:^|[-_])(?:passw(?:or)?d|token|secret|credential|private[-_]?key"
    r"|api[-_]?key|authorization|cookie)(?:$|[-_])"
)
ENV_ALLOWLIST: frozenset[str] = frozenset({
    "HOME", "JAVA_HOME", "LANG", "LC_ALL", "PATH", "SHELL",
    "TMPDIR", "TZ", "USER", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
})
_SPEC_FIELDS = frozenset({
    "schema_version", "tool", "limits", "vm_pre_snapshot", "vm_post_snapshot",
    "inputs", "outputs", "exit_status", "environment", "observed",
})
_RECEIPT_FIELDS = _SPEC_FIELDS | {"identity"}


class VmReceiptError(AdapterError):
    """Fail-closed contract violation for vm-run-receipt."""


# -- primitive validators --------------------------------------------------

def _digest(v: Any, ctx: str) -> str:
    if not isinstance(v, str) or not HASH_RE.fullmatch(v):
        raise VmReceiptError(f"{ctx}: invalid SHA-256 digest")
    return v

def _pos_int(v: Any, ctx: str) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or v <= 0:
        raise VmReceiptError(f"{ctx}: must be a positive integer")
    return v

def _nonneg_int(v: Any, ctx: str) -> int:
    if isinstance(v, bool) or not isinstance(v, int) or v < 0:
        raise VmReceiptError(f"{ctx}: must be a non-negative integer")
    return v

def _str(v: Any, ctx: str) -> str:
    if not isinstance(v, str) or not v.strip():
        raise VmReceiptError(f"{ctx}: must be a non-empty string")
    return v

def _safe_argv(argv: Any) -> list[str]:
    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        raise VmReceiptError("tool.argv must be a non-empty string array")
    for i, item in enumerate(argv):
        opt = item.split("=", 1)[0]
        if SECRET_VALUE_RE.search(item) or (opt.startswith("-") and SECRET_OPTION_RE.search(opt.lstrip("-"))):
            raise VmReceiptError(f"tool.argv[{i}] is secret-like; redact before capture")
    return list(argv)

def _safe_env(env: Any) -> dict[str, str]:
    if env is None: return {}
    if not isinstance(env, dict): raise VmReceiptError("environment must be an object")
    clean: dict[str, str] = {}
    for k, v in env.items():
        if not isinstance(k, str) or k not in ENV_ALLOWLIST or SECRET_KEY_RE.search(k):
            raise VmReceiptError(f"environment key {k!r} is not allowlisted or is secret-like")
        if not isinstance(v, str) or SECRET_VALUE_RE.search(v):
            raise VmReceiptError(f"environment value for {k!r} is invalid or secret-like")
        clean[k] = v
    return clean

def _snapshot(v: Any, ctx: str) -> dict[str, Any] | None:
    if v is None: return None
    if not isinstance(v, dict) or set(v) != {"sha256"}:
        raise VmReceiptError(f"{ctx}: must be {{sha256}} or null")
    return {"sha256": _digest(v["sha256"], f"{ctx}.sha256")}

def _artifacts(items: Any, ctx: str) -> list[dict[str, Any]]:
    if not isinstance(items, list): raise VmReceiptError(f"{ctx}: must be an array")
    result = []
    for i, item in enumerate(items):
        if not isinstance(item, dict) or set(item) != {"path", "sha256", "size"}:
            raise VmReceiptError(f"{ctx}[{i}]: must have exactly path, sha256, size")
        p = _str(item["path"], f"{ctx}[{i}].path")
        if Path(p).is_absolute() or ".." in Path(p).parts:
            raise VmReceiptError(f"{ctx}[{i}].path must be a relative confined path (no absolute or '..' components): {p!r}")
        result.append({"path": p,
                        "sha256": _digest(item["sha256"], f"{ctx}[{i}].sha256"),
                        "size": _nonneg_int(item["size"], f"{ctx}[{i}].size")})
    return sorted(result, key=lambda r: r["path"])

def _exit_status(v: Any) -> dict[str, Any]:
    if not isinstance(v, dict) or set(v) != {"exit_code", "signal"}:
        raise VmReceiptError("exit_status must have exactly exit_code and signal")
    ec, sig = v["exit_code"], v["signal"]
    if (ec is None) == (sig is None):
        raise VmReceiptError("exit_status requires exactly one non-null: exit_code or signal")
    if ec is not None and (isinstance(ec, bool) or not isinstance(ec, int) or ec < 0):
        raise VmReceiptError("exit_status.exit_code must be a non-negative integer")
    if sig is not None and (isinstance(sig, bool) or not isinstance(sig, int) or sig <= 0):
        raise VmReceiptError("exit_status.signal must be a positive integer")
    return {"exit_code": ec, "signal": sig}

def _limits(v: Any) -> dict[str, Any]:
    expected = {"cpu_seconds", "mem_bytes", "output_bytes", "wall_seconds"}
    if not isinstance(v, dict) or set(v) != expected:
        raise VmReceiptError(f"limits must have exactly {sorted(expected)}")
    return {k: _pos_int(v[k], f"limits.{k}") for k in sorted(expected)}

def _observed(v: Any) -> dict[str, Any]:
    required = {"cpu_seconds_measured", "mem_bytes_peak",
                "wall_ended_at", "wall_seconds_measured", "wall_started_at"}
    if not isinstance(v, dict) or set(v) != required:
        raise VmReceiptError(f"observed fields invalid; expected {sorted(required)}")
    for k in ("wall_started_at", "wall_ended_at"):
        if not isinstance(v[k], str) or not v[k].strip():
            raise VmReceiptError(f"observed.{k} must be a non-empty string")
    for k in ("cpu_seconds_measured", "mem_bytes_peak", "wall_seconds_measured"):
        if (isinstance(v[k], bool) or not isinstance(v[k], (int, float))
                or not math.isfinite(v[k]) or v[k] < 0):
            raise VmReceiptError(f"observed.{k} must be a non-negative finite number")
    return dict(v)

def _identity(receipt: dict[str, Any]) -> str:
    stable = copy.deepcopy(receipt)
    stable.pop("identity", None)
    stable.pop("observed", None)
    return "sha256:" + hashlib.sha256(canonical_bytes(stable)).hexdigest()


# -- public API ------------------------------------------------------------

def build_receipt(spec: dict[str, Any]) -> dict[str, Any]:
    """Build a canonical deterministic vm-run-receipt from a spec with pre-computed hashes."""
    if not isinstance(spec, dict) or set(spec) != _SPEC_FIELDS:
        raise VmReceiptError(f"spec fields invalid; missing={sorted(_SPEC_FIELDS - set(spec))}")
    if spec["schema_version"] != SCHEMA_VERSION:
        raise VmReceiptError(f"unknown schema_version: {spec['schema_version']!r}")
    ts = spec["tool"]
    if not isinstance(ts, dict) or set(ts) != {"argv", "name", "sha256", "version"}:
        raise VmReceiptError("tool must have exactly argv, name, sha256, version")
    receipt: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION, "identity": "",
        "tool": {"argv": _safe_argv(ts["argv"]), "name": _str(ts["name"], "tool.name"),
                 "sha256": _digest(ts["sha256"], "tool.sha256"),
                 "version": _str(ts["version"], "tool.version")},
        "limits": _limits(spec["limits"]),
        "vm_pre_snapshot": _snapshot(spec["vm_pre_snapshot"], "vm_pre_snapshot"),
        "vm_post_snapshot": _snapshot(spec["vm_post_snapshot"], "vm_post_snapshot"),
        "inputs": _artifacts(spec["inputs"], "inputs"),
        "outputs": _artifacts(spec["outputs"], "outputs"),
        "exit_status": _exit_status(spec["exit_status"]),
        "environment": _safe_env(spec["environment"]),
        "observed": _observed(spec["observed"]),
    }
    receipt["identity"] = _identity(receipt)
    validate_receipt(receipt)
    return receipt


def validate_receipt(receipt: dict[str, Any]) -> None:
    """Validate receipt structure and contract (no file access)."""
    if not isinstance(receipt, dict) or set(receipt) != _RECEIPT_FIELDS:
        raise VmReceiptError(f"receipt fields invalid; missing={sorted(_RECEIPT_FIELDS - set(receipt))}")
    if receipt["schema_version"] != SCHEMA_VERSION:
        raise VmReceiptError(f"unknown schema_version: {receipt['schema_version']!r}")
    if not isinstance(receipt["identity"], str) or not HASH_RE.fullmatch(receipt["identity"]):
        raise VmReceiptError("identity must be a sha256:<64 hex> string")
    t = receipt["tool"]
    if not isinstance(t, dict) or set(t) != {"argv", "name", "sha256", "version"}:
        raise VmReceiptError("tool fields invalid")
    _str(t["name"], "tool.name"); _str(t["version"], "tool.version")
    _safe_argv(t["argv"]); _digest(t["sha256"], "tool.sha256")
    _limits(receipt["limits"])
    _snapshot(receipt["vm_pre_snapshot"], "vm_pre_snapshot")
    _snapshot(receipt["vm_post_snapshot"], "vm_post_snapshot")
    _artifacts(receipt["inputs"], "inputs"); _artifacts(receipt["outputs"], "outputs")
    _exit_status(receipt["exit_status"]); _safe_env(receipt["environment"])
    _observed(receipt["observed"])
    if receipt["identity"] != _identity(receipt):
        raise VmReceiptError("receipt identity does not match canonical content-addressed fields")


def verify_receipt(receipt: dict[str, Any], artifacts_dir: Path) -> None:
    """Rehash inputs and outputs under artifacts_dir; fail closed on any mismatch."""
    validate_receipt(receipt)
    root = artifacts_dir.resolve()
    for ctx, records in (("inputs", receipt["inputs"]), ("outputs", receipt["outputs"])):
        for i, rec in enumerate(records):
            resolved = (root / rec["path"]).resolve()
            if not (resolved == root or root in resolved.parents):
                raise VmReceiptError(
                    f"{ctx}[{i}] {rec['path']!r} resolves outside artifacts_dir"
                )
            try:
                _, actual_size, actual_sha = _file_identity(resolved)
            except AdapterError as exc:
                raise VmReceiptError(f"{ctx}[{i}] {rec['path']!r} cannot be verified: {exc}") from exc
            if actual_size != rec["size"] or actual_sha != rec["sha256"]:
                raise VmReceiptError(f"{ctx}[{i}] {rec['path']!r}: digest or size mismatch")


# -- CLI -------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="command", required=True)
    b = sub.add_parser("build"); b.add_argument("--spec", type=Path, required=True)
    b.add_argument("--output", type=Path, required=True); b.add_argument("--overwrite", action="store_true")
    v = sub.add_parser("validate"); v.add_argument("receipt", type=Path)
    r = sub.add_parser("verify"); r.add_argument("--artifacts-dir", type=Path, required=True)
    r.add_argument("receipt", type=Path)
    args = p.parse_args(argv)
    try:
        if args.command == "build":
            data = json.loads(args.spec.read_text(encoding="utf-8"))
            receipt = build_receipt(data)
            if args.overwrite:
                _write(args.output, receipt)
            else:
                _tmp = args.output.with_name("." + args.output.name + ".pub.tmp")
                _tmp.write_bytes(canonical_bytes(receipt))
                with _tmp.open("rb") as _f:
                    os.fsync(_f.fileno())
                try:
                    _publish(_tmp, args.output)
                except OSError:
                    _tmp.unlink(missing_ok=True)
                    raise VmReceiptError("receipt exists; use --overwrite to replace it")
                except BaseException:
                    _tmp.unlink(missing_ok=True)
                    raise
        elif args.command == "validate":
            validate_receipt(json.loads(args.receipt.read_text(encoding="utf-8")))
        else:
            verify_receipt(json.loads(args.receipt.read_text(encoding="utf-8")), args.artifacts_dir)
    except (VmReceiptError, AdapterError, OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"vm-receipt: {exc}", file=sys.stderr); return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
