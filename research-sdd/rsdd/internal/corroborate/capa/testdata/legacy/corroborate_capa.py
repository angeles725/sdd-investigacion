#!/usr/bin/env python3
"""Produce bounded offline capability inventory from a PE/ELF/.NET binary.

Runs capa (FLARE capa 9.4.0, pipx venv) inside a network-denied Bubblewrap
sandbox to identify ATT&CK / MBC capabilities matched by capa's rule set.

Reports COUNTS + a BOUNDED, sorted capability list — never raw disassembly or
unbounded rule-match trees.  Any cap that fires is reported in limitations and
capabilities.truncated is set to true; truncation is never silent.

A binary where capa finds zero capabilities (exits 0, empty rules dict) is a
valid status=complete empty inventory.  A binary capa cannot analyze (non-zero
exit, e.g. unsupported format) records the error and publishes status=failed.
Malformed capa JSON on exit-0 is an explicit error, never silently empty.

Rules-dir bind safety
---------------------
The default capa-rules directory lives under /home, which adapter_core.sandbox()
blocks via _RO_INPUT_BLOCKED_ROOTS to prevent credential exposure.  This adapter
adds a SINGLE, EXPLICIT, NARROWLY VALIDATED read-only bind of the resolved rules
directory at /tmp/rsdd/capa-rules (inside the tmpfs that sandbox() already sets
up), analogous in spirit to how bind_venv narrowly ro-binds the tool venv.  No
parent directory is ever bound; no /home subtree is exposed.  See _validate_rules_dir
and _bind_rules below for the exact validation and binding logic.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from lib.adapter_core import (
    AdapterError,
    executable,
    require_private,
    run_bounded,
    sandbox,
    stage_file,
)
from lib.adapter_helpers import (
    BindScopeError, ManifestError, VenvBindError,
    assert_safe_bind_root, bind_venv, emit_evidence, run_truncation,
)
from lib.isolation_profile import PROFILE_BWRAP_CAPA_OFFLINE

SCHEMA = "capa-evidence.v1"

_PROFILE = PROFILE_BWRAP_CAPA_OFFLINE

_LIMITATIONS: list[str] = [
    "capa performs static analysis using the vivisect backend; results vary by "
    "binary format (PE, ELF, .NET) and may miss capabilities requiring dynamic analysis.",
    "Only capabilities matched by the supplied rule set are reported; the installed "
    "capa version is captured dynamically in capabilities.capa_version.",
    "Bubblewrap on WSL2 provides network isolation but is not a full hostile-parser "
    "security boundary; use a disposable VM for actively hostile samples.",
    "Caps (--max-capabilities, --timeout) and output/process limits bound resource "
    "use; any cap that fires is reported in limitations and truncated is set "
    "true — never silent.",
]

# Combined stdout+stderr cap (capa JSON includes verbose match trees).
_MAX_OUTPUT_BYTES: int = 16 * 1024 * 1024  # 16 MiB

# Fixed inside-sandbox path where the capa-rules directory is bound.
# Lives inside the /tmp/rsdd tmpfs that sandbox() sets up, so no host paths
# under /home are reachable.
_SANDBOX_RULES_PATH: str = "/tmp/rsdd/capa-rules"


class CapaError(AdapterError):
    """Fail-closed error for the capa evidence adapter."""


# ---------------------------------------------------------------------------
# Version probe
# ---------------------------------------------------------------------------

def _version(capa_exe: Path) -> str:
    """Return the capa version string (host-side probe; no network access)."""
    try:
        result = subprocess.run(
            [str(capa_exe), "--version"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        line = result.stdout.strip() or result.stderr.strip()
        return line.splitlines()[0] if line else "unknown"
    except Exception:
        return "unknown"


# ---------------------------------------------------------------------------
# Rules-dir validation and sandbox binding (local to this adapter)
# ---------------------------------------------------------------------------

# Plausibility marker constants (local — specific to capa-rules structure).
# _RULES_BLOCKED_EXACT removed: consolidated into adapter_helpers._BLOCKED_BIND_ROOTS
# and adapter_helpers.assert_safe_bind_root.
_CAPA_RULES_STRUCTURAL_SUBDIRS: frozenset[str] = frozenset(  # plausibility marker
    {"nursery", "lib", "host-interaction", "persistence", "collection", "discovery"}
)
_MIN_YML_COUNT: int = 50  # real capa-rules repo has ~1000; 50 is conservative


def _rules_scope_guard(resolved: Path) -> None:
    """Raise CapaError when *resolved* is a blocked root or too broad to bind.

    Pure shape check delegated to adapter_helpers.assert_safe_bind_root.
    BindScopeError is caught and re-raised as CapaError to preserve the
    adapter-specific error type for callers and tests that catch CapaError.
    The capa-rules plausibility marker (.yml count / structural subdirs) is
    kept separately in _validate_rules_dir.
    """
    try:
        assert_safe_bind_root(resolved)
    except BindScopeError as exc:
        raise CapaError(f"--rules path rejected by bind-scope guard: {exc}") from exc


def _validate_rules_dir(rules_path: Path) -> Path:
    """Validate the capa rules directory and return the resolved absolute path.

    Safety design
    -------------
    The capa-rules directory lives under /home, which adapter_core.sandbox()
    blocks via _RO_INPUT_BLOCKED_ROOTS to prevent credential exposure.  Rather
    than re-opening broad /home access, this adapter adds a SINGLE, EXPLICIT,
    NARROWLY VALIDATED read-only bind of exactly the resolved rules directory.

    Validation guards (applied in order):
    1. Symlink rejection: lstat() must show S_ISDIR, not S_ISLNK.  Symlinks are
       rejected even when the target is a valid rules directory, because a
       symlink can be redirected to a sensitive or attacker-controlled path.
    2. Existence and type: path must exist and be a directory.
    3. Plausibility: at least one .yml rule file must exist anywhere inside the
       directory.  An empty directory or non-rules directory is rejected early
       before the sandbox bind.

    Raises CapaError for any validation failure (fail-closed — no evidence
    is published and no sandbox is launched).
    """
    expanded = rules_path.expanduser()

    # Guard 1: reject symlinks before resolve().
    try:
        meta = expanded.lstat()
    except OSError as exc:
        raise CapaError(f"--rules path does not exist: {rules_path}") from exc

    if stat.S_ISLNK(meta.st_mode):
        raise CapaError(
            f"--rules must not be a symlink (symlink-to-rules-dir is rejected to "
            f"prevent redirection to a sensitive path): {rules_path}"
        )

    # Guard 2: must be a directory.
    if not stat.S_ISDIR(meta.st_mode):
        raise CapaError(f"--rules is not a directory: {rules_path}")

    resolved = expanded.resolve()

    # Guard 3 (SCOPE): reject broad or dangerous paths before any FS walk.
    # Mirrors venv_root_for() in lib/adapter_helpers.py; see _rules_scope_guard.
    _rules_scope_guard(resolved)

    # Guard 4: plausibility — require ≥ _MIN_YML_COUNT .yml files OR a known
    # capa-rules structural subdir at the top level.  A directory that merely
    # contains a stray .yml (e.g. ~/.github/workflows/ci.yml) is rejected.
    yml_count = 0
    has_structural_subdir = False
    for root_str, dirs, files in os.walk(resolved):
        if Path(root_str) == resolved:
            has_structural_subdir = any(d in _CAPA_RULES_STRUCTURAL_SUBDIRS for d in dirs)
        for fname in files:
            if fname.endswith(".yml"):
                yml_count += 1
        if yml_count >= _MIN_YML_COUNT or has_structural_subdir:
            break
        dirs[:] = dirs[:100]

    if not (yml_count >= _MIN_YML_COUNT or has_structural_subdir):
        raise CapaError(
            f"--rules directory does not appear to be a capa-rules directory "
            f"(found {yml_count} .yml files; expected ≥ {_MIN_YML_COUNT} or a "
            f"known structural subdir like nursery/, lib/, host-interaction/): {resolved}"
        )

    return resolved


def _bind_rules(prefix: list[str], resolved_rules: Path) -> list[str]:
    """Extend a bwrap prefix with a read-only bind of the resolved rules dir.

    Safety design
    -------------
    Inserts BEFORE the trailing '--' so bwrap processes these mounts after
    the --tmpfs /tmp/rsdd setup from sandbox().  Binds ONLY the exact resolved
    rules directory — never any parent.  Target path is fixed at
    _SANDBOX_RULES_PATH (/tmp/rsdd/capa-rules), inside the tmpfs.

    No /home, /root, or credential-bearing path is exposed by this bind; the
    rules directory is a read-only data directory validated by _validate_rules_dir.

    Raises CapaError when the prefix does not end with '--'.
    """
    if not prefix or prefix[-1] != "--":
        raise CapaError("bwrap prefix must end with '--' (produced by adapter_core.sandbox())")
    extra: list[str] = [
        "--dir", _SANDBOX_RULES_PATH,
        "--ro-bind", str(resolved_rules), _SANDBOX_RULES_PATH,
    ]
    return prefix[:-1] + extra + ["--"]


# ---------------------------------------------------------------------------
# Rules directory identity digest
# ---------------------------------------------------------------------------

def _rules_path_digest(rules_dir: Path) -> str:
    """Compute a stable structural path digest for the rules directory.

    Hashes the sorted list of relative .yml file paths (not file contents)
    for a fast, stable, discriminating fingerprint of the rules directory.
    The digest changes when rules are added, removed, or renamed, but NOT
    when contents change.  Named ``rules_path_digest`` (not ``rules_identity``)
    to make the path-only semantics explicit.
    """
    paths = sorted(
        str(p.relative_to(rules_dir))
        for p in rules_dir.rglob("*.yml")
    )
    combined = "\n".join(paths).encode("utf-8")
    return "sha256:" + hashlib.sha256(combined).hexdigest()


# ---------------------------------------------------------------------------
# capa stdout JSON reader (O_NOFOLLOW-safe)
# ---------------------------------------------------------------------------

def _read_stdout_json(stdout_path: Path) -> tuple[dict[str, Any] | None, str | None]:
    """Read stdout.txt with O_NOFOLLOW + lstat/S_ISREG and parse as JSON.

    Returns ``(parsed_dict, None)`` on success, ``(None, None)`` when the
    file is empty (no output), or ``(None, error_str)`` when the file is
    non-empty but the JSON is malformed.  Malformed JSON on exit-0 is an
    explicit error (status=failed), not silently promoted to empty inventory.

    Raises CapaError when a symlink or non-regular file is detected (TOCTOU-safe):
    - lstat before open: rejects symlinks and non-regular files.
    - O_NOFOLLOW on open: kernel-level symlink rejection (belt-and-suspenders).
    - fstat after read: detects TOCTOU modification between lstat and read.
    """
    NOFOLLOW: int = getattr(os, "O_NOFOLLOW", 0)
    CLOEXEC: int = getattr(os, "O_CLOEXEC", 0)

    try:
        meta = stdout_path.lstat()
    except OSError as exc:
        raise CapaError(f"cannot stat capa stdout: {stdout_path}") from exc

    if stat.S_ISLNK(meta.st_mode):
        raise CapaError(f"symlink detected at capa output path: {stdout_path}")
    if not stat.S_ISREG(meta.st_mode):
        raise CapaError(f"capa stdout is not a regular file: {stdout_path}")
    if meta.st_size == 0:
        return None, None

    try:
        fd = os.open(stdout_path, os.O_RDONLY | NOFOLLOW | CLOEXEC)
    except OSError as exc:
        raise CapaError(f"cannot open capa stdout (symlink?): {stdout_path}") from exc
    try:
        before = os.fstat(fd)
        raw = os.read(fd, max(1, meta.st_size + 1))
        after = os.fstat(fd)
        fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)
        if fields(before) != fields(after):
            raise CapaError("capa stdout changed while reading (TOCTOU)")
    finally:
        os.close(fd)

    if not raw:
        return None, None

    try:
        return json.loads(raw), None
    except json.JSONDecodeError as exc:
        return None, f"malformed JSON in capa stdout: {exc}"


# ---------------------------------------------------------------------------
# Bounded inventory builder
# ---------------------------------------------------------------------------

def _build_inventory(
    capa_json: dict[str, Any] | None,
    max_capabilities: int,
) -> tuple[dict[str, Any], list[str]]:
    """Build bounded capability inventory from parsed capa JSON.

    Returns (inventory_dict, extra_limitations).

    Empty-inventory cases (capa_json is None, or rules dict is empty):
      Returns an inventory with total_count=0, total_sampled=0, truncated=False.
      status=complete (not status=failed) — zero capabilities is a valid result.

    Sorting: items sorted by (namespace, name) for determinism.

    Cap enforcement (max_capabilities):
      When the number of matched capabilities exceeds max_capabilities, the
      items list is bounded to max_capabilities entries.  truncated=True and a
      human-readable limitation string are recorded — never silent.

    inventory_dict layout:
        total_count:    int   — all capabilities capa matched
        total_sampled:  int   — entries in the bounded items list
        truncated:      bool  — True when the capability cap fired
        items:          list  — bounded sorted capability records:
            [{name, namespace, attack_ids, mbc_ids, match_count}]
    (capa_version, rules_identity, argv, caps, tool populated by caller)
    """
    extra_limitations: list[str] = []

    _empty: dict[str, Any] = {
        "total_count": 0,
        "total_sampled": 0,
        "truncated": False,
        "items": [],
    }

    if capa_json is None:
        return dict(_empty), []

    rules: Any = capa_json.get("rules", {})
    if not isinstance(rules, dict):
        return dict(_empty), [f"capa JSON 'rules' is not a dict (schema drift): {type(rules).__name__!r}"]
    if not rules:
        return dict(_empty), []

    # Build unsorted list from all matched rules.
    all_items: list[dict[str, Any]] = []
    for rule_name, rule_body in rules.items():
        meta = rule_body.get("meta", {})
        matches = rule_body.get("matches", [])

        attack_ids: list[str] = [
            entry["id"]
            for entry in meta.get("attack", [])
            if entry.get("id")
        ]
        mbc_ids: list[str] = [
            entry["id"]
            for entry in meta.get("mbc", [])
            if entry.get("id")
        ]
        all_items.append({
            "attack_ids": attack_ids,
            "match_count": len(matches),
            "mbc_ids": mbc_ids,
            "name": rule_name,
            "namespace": meta.get("namespace", ""),
        })

    total_count: int = len(all_items)

    # Sort deterministically: (namespace, name).
    all_items.sort(key=lambda e: (e["namespace"], e["name"]))

    # Apply capability cap.
    cap_hit: bool = total_count > max_capabilities
    sampled_items = all_items[:max_capabilities]

    if cap_hit:
        extra_limitations.append(
            f"inventory truncated: capability cap {max_capabilities} reached "
            f"(total_count={total_count})"
        )

    return {
        "items": sampled_items,
        "total_count": total_count,
        "total_sampled": len(sampled_items),
        "truncated": cap_hit,
    }, extra_limitations


# ---------------------------------------------------------------------------
# CLI and main
# ---------------------------------------------------------------------------

def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="corroborate-capa")
    p.add_argument(
        "--input", type=Path, required=True,
        help="PE/ELF/.NET binary to analyse",
    )
    p.add_argument(
        "--output", type=Path, required=True,
        help="New output directory (must not exist)",
    )
    p.add_argument(
        "--rules", type=Path, default=Path("~/.local/share/capa-rules"),
        help="capa rules directory (default: ~/.local/share/capa-rules)",
    )
    p.add_argument(
        "--timeout", type=int, default=300,
        help="Wall-clock timeout for capa (seconds, default 300)",
    )
    p.add_argument(
        "--max-capabilities", type=int, default=500,
        help="Maximum capabilities sampled in the inventory (default 500)",
    )
    p.add_argument(
        "--manifest-cli", type=Path, required=True, help=argparse.SUPPRESS,
    )
    return p


def main(argv: list[str] | None = None) -> int:  # noqa: C901
    args = _parser().parse_args(argv)
    stage: Path | None = None

    try:
        # Caps validation.
        if args.timeout < 1:
            raise CapaError("--timeout must be >= 1")
        if args.max_capabilities < 1:
            raise CapaError("--max-capabilities must be >= 1")

        # Output path safety.
        if ".." in args.output.parts or "\\" in str(args.output):
            raise CapaError("output must be a canonical path")

        parent = args.output.parent.resolve(strict=True)
        require_private(parent)

        destination = parent / args.output.name
        if destination.exists() or destination.is_symlink():
            raise CapaError("output must be a new non-colliding path")

        # Manifest CLI must exist.
        manifest_cli = args.manifest_cli.resolve(strict=True)

        # Validate rules directory (fail-closed; no broad /home exposure).
        resolved_rules = _validate_rules_dir(args.rules)

        # Resolve tools.
        search = os.environ.get("PATH", "")
        bwrap_exe, bwrap_record = executable("bwrap", os.environ.get("RSDD_BWRAP"), search)
        capa_exe, capa_record = executable(
            "capa", os.environ.get("RSDD_CAPA"), search
        )

        capa_version = _version(capa_exe)
        rules_id = _rules_path_digest(resolved_rules)

        # Staging directory.
        stage = parent / f".{destination.name}.stage"
        stage.mkdir(mode=0o700)
        (stage / "input").mkdir()
        (stage / "engine").mkdir()

        # Stage the input binary.
        source_record, staged_record = stage_file(
            args.input,
            stage / "input" / "binary.bin",
            "input/binary.bin",
            0o400,
        )

        # Sandbox environment.
        env: dict[str, str] = {
            "HOME": "/tmp/rsdd/home",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/usr/sbin:/bin:/sbin",
            "TMPDIR": "/tmp/rsdd",
            "TZ": "UTC",
            "XDG_CACHE_HOME": "/tmp/rsdd/cache",
            "XDG_CONFIG_HOME": "/tmp/rsdd/config",
            "XDG_DATA_HOME": "/tmp/rsdd/data",
        }

        # Build bwrap prefix:
        # 1. Base sandbox (network-denied, cap-drop ALL, etc.)
        # 2. capa venv bind (read-only; /etc/passwd+/etc/group for vivisect getpwuid)
        # 3. capa-rules dir bind (read-only; exact resolved dir only, not any parent)
        prefix = sandbox(bwrap_exe, env)
        prefix = bind_venv(
            prefix, capa_exe,
            etc_ro_bind_try=("/etc/passwd", "/etc/group"),
        )
        prefix = _bind_rules(prefix, resolved_rules)

        # Inside-sandbox binary path (matches sandbox() work-dir bind).
        input_in_sandbox = "/tmp/rsdd/work/input/binary.bin"

        # Canonical capa argv (deterministic; uses fixed sandbox paths).
        capa_argv_canonical: list[str] = [
            str(capa_exe),
            "-r", _SANDBOX_RULES_PATH,
            "-j",
            input_in_sandbox,
        ]

        capa_cmd = prefix + capa_argv_canonical
        capa_idx = len(prefix)

        # Run capa under bounded subprocess control.
        capa_run, run_errors = run_bounded(
            capa_cmd,
            stage,
            env,
            timeout=args.timeout,
            max_bytes=_MAX_OUTPUT_BYTES,
        )

        # Read capa JSON output with O_NOFOLLOW protection.
        stdout_path = stage / "engine" / "stdout.txt"
        capa_json, parse_error = _read_stdout_json(stdout_path)

        # Build bounded capability inventory.
        inventory, inv_limitations = _build_inventory(
            capa_json,
            max_capabilities=args.max_capabilities,
        )

        # Propagate run-cap truncation into the inventory truncated flag.
        run_trunc, trunc_lims = run_truncation(run_errors, "capa")
        inventory["truncated"] = inventory["truncated"] or run_trunc

        # Aggregate limitations and errors.
        all_limitations = _LIMITATIONS + inv_limitations + trunc_lims
        all_errors = run_errors + ([parse_error] if parse_error else [])

        # Annotate inventory with tool metadata and caps.
        inventory["argv"] = capa_argv_canonical
        inventory["caps"] = {
            "max_capabilities": args.max_capabilities,
            "timeout": args.timeout,
        }
        inventory["capa_version"] = capa_version
        inventory["rules_path_digest"] = rules_id
        inventory["tool"] = capa_record

        # Evidence domain.
        domain: dict[str, Any] = {
            "capabilities": inventory,
        }

        # Manifest spec.
        manifest_spec: dict[str, Any] = {
            "argv": capa_cmd,
            "completeness": "failed" if all_errors else "complete",
            "environment": env,
            "errors": all_errors,
            "findings": [],
            "input": {
                "detected_type": "PE/ELF/.NET binary",
                "path": "input/binary.bin",
            },
            "isolation_profile": _PROFILE,
            "limitations": all_limitations,
            "outputs": [f"{SCHEMA}.json"],
            "run": capa_run,
            "schema_version": "analysis-manifest.v1",
            "stderr_path": "engine/stderr.txt",
            "stdout_path": "engine/stdout.txt",
            "tool": {
                "artifacts": [
                    {"argv_index": capa_idx, "path": str(capa_exe)},
                ],
                "executable": str(bwrap_exe),
                "name": "capa",
                "version": capa_version,
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

    except (CapaError, AdapterError, ManifestError, VenvBindError, OSError,
            subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"corroborate-capa: {exc}", file=sys.stderr)
        return 2
    finally:
        if stage is not None and stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    sys.exit(main())
