#!/usr/bin/env python3
"""Produce bounded, offline recursive extraction inventory from a firmware/opaque-binary image.

Runs unblob (v26.6.4) inside a network-denied Bubblewrap sandbox to extract
and inventory the contents of a binary image.  Reports STRUCTURE only: paths,
sizes, sha256 digests, types, and depth.  Never emits raw payload bytes or
secret values.

Extraction happens in a private temp directory that is removed before
publication; the published output contains only the evidence envelope
(unblob-evidence.v1.json) and the analysis manifest, never extracted payload.
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
from lib.adapter_helpers import ManifestError, bind_venv, emit_evidence, run_truncation
from lib.isolation_profile import PROFILE_BWRAP_UNBLOB_OFFLINE

SCHEMA = "unblob-evidence.v1"

_PROFILE = PROFILE_BWRAP_UNBLOB_OFFLINE

_LIMITATIONS: list[str] = [
    "unblob extracts structure only; semantic analysis of content is not performed.",
    "Inventory entries are regular files only; directories, symlinks, special files, "
    "and hardlinked files are skipped (each skip is recorded as an error string).",
    "unblob type identification is based on magic bytes and heuristics; encrypted or "
    "obfuscated formats may not be identified and will produce empty inventories.",
    "Bubblewrap on WSL2 provides network isolation but is not a full hostile-parser "
    "security boundary; use a disposable VM for actively hostile firmware.",
    "Caps (--max-entries, --max-total-bytes, --max-depth, --timeout) limit resource "
    "use; any cap that fires is reported in limitations and never silently truncated.",
]

# Combined stdout+stderr cap for run_bounded (4 MiB is generous for unblob console output).
_MAX_OUTPUT_BYTES: int = 4 * 1024 * 1024


class UnblobError(AdapterError):
    """Fail-closed error for the unblob evidence adapter."""


# ---------------------------------------------------------------------------
# Version probe
# ---------------------------------------------------------------------------

def _version(unblob_exe: Path) -> str:
    """Return the unblob version string (host-side probe; no network access)."""
    try:
        result = subprocess.run(
            [str(unblob_exe), "--version"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        line = result.stdout.strip() or result.stderr.strip()
        return line.splitlines()[0] if line else "unknown"
    except Exception:
        return "unknown"


# ---------------------------------------------------------------------------
# Inventory walk
# ---------------------------------------------------------------------------

# Name of the unblob JSON report written into the extraction directory.
# This file is read for metadata but excluded from the inventory.
_UNBLOB_REPORT_NAME: str = "unblob-report.json"


def _walk_extracted(
    extracted_root: Path,
    max_entries: int,
    max_total_bytes: int,
    max_depth: int,
) -> tuple[list[dict[str, Any]], list[str], list[str]]:
    """Walk the unblob extraction tree and build a bounded inventory.

    Returns (entries, limitations, errors).

    entries  — sorted list of {path, size, sha256, depth, type} for regular files.
    limitations — cap-trip strings (entry cap, bytes cap, depth cap).
    errors   — per-file issues (symlinks skipped, special files, hardlinks, TOCTOU).

    Safety invariants:
    - O_NOFOLLOW on every file open (TOCTOU-safe, symlink-safe).
    - os.walk(followlinks=False) — no symlink directory traversal.
    - path-traversal check (.., absolute) — fail-closed.
    - symlinks, special files, hardlinks: skipped + recorded in errors (never silent).
    - All caps recorded in limitations when tripped.
    """
    NOFOLLOW: int = getattr(os, "O_NOFOLLOW", 0)
    CLOEXEC: int = getattr(os, "O_CLOEXEC", 0)

    entries: list[dict[str, Any]] = []
    limitations: list[str] = []
    errors: list[str] = []
    total_bytes: int = 0

    depth_cap_hit = False
    entry_cap_hit = False
    bytes_cap_hit = False

    for dirpath_str, dirs, filenames in os.walk(extracted_root, followlinks=False):
        dirpath = Path(dirpath_str)

        # Depth of this directory relative to the extraction root.
        try:
            rel_dir = dirpath.relative_to(extracted_root)
        except ValueError:
            errors.append(f"path escape detected at directory level: {dirpath}")
            dirs.clear()
            continue

        dir_depth = len(rel_dir.parts)
        file_depth_here = dir_depth + 1  # depth of files inside this directory

        # Prune subdirectories that would produce files beyond max_depth.
        # Record the depth-cap limitation exactly once when non-empty dirs are pruned
        # at the boundary.  The limitation must be recorded HERE (not after dirs.clear()),
        # because os.walk never yields a directory deeper than max_depth once dirs are
        # cleared — the "file_depth_here > max_depth" branch is unreachable dead code.
        if file_depth_here >= max_depth:
            if dirs and not depth_cap_hit:
                depth_cap_hit = True
                limitations.append(
                    f"inventory truncated: depth cap {max_depth} reached"
                )
            dirs.clear()

        for name in sorted(filenames):
            if entry_cap_hit or bytes_cap_hit:
                break

            # Exclude the unblob metadata report from the inventory.
            if name == _UNBLOB_REPORT_NAME and dirpath == extracted_root:
                continue

            full = dirpath / name

            # Path traversal — should never occur with os.walk but checked explicitly.
            try:
                rel = full.relative_to(extracted_root)
            except ValueError:
                errors.append(f"path escape: {full}")
                continue
            for part in rel.parts:
                if part == "..":
                    raise UnblobError(f"path traversal detected in extracted tree: {rel}")
            if rel.is_absolute():
                raise UnblobError(f"absolute path in extracted tree: {rel}")

            # Lstat (no symlink follow).
            try:
                meta = full.lstat()
            except OSError as exc:
                errors.append(f"cannot stat {rel}: {exc}")
                continue

            # Reject non-regular entries (skip with recorded error).
            if stat.S_ISLNK(meta.st_mode):
                errors.append(f"symlink skipped: {rel}")
                continue
            if not stat.S_ISREG(meta.st_mode):
                errors.append(f"special file skipped: {rel}")
                continue
            if meta.st_nlink != 1:
                errors.append(f"hardlinked file skipped: {rel}")
                continue

            # Entry cap.
            if len(entries) >= max_entries:
                if not entry_cap_hit:
                    entry_cap_hit = True
                    limitations.append(
                        f"inventory truncated: entry cap {max_entries} reached"
                    )
                dirs.clear()
                break

            # Bytes cap (pre-check with declared size).
            if total_bytes + meta.st_size > max_total_bytes:
                if not bytes_cap_hit:
                    bytes_cap_hit = True
                    limitations.append(
                        f"inventory truncated: total-bytes cap {max_total_bytes} reached"
                    )
                dirs.clear()
                break

            # Open with O_NOFOLLOW (TOCTOU-safe).
            try:
                fd = os.open(full, os.O_RDONLY | NOFOLLOW | CLOEXEC)
            except OSError as exc:
                errors.append(f"cannot open {rel} (symlink?): {exc}")
                continue

            try:
                before = os.fstat(fd)
                digest = hashlib.sha256()
                read_total = 0
                while chunk := os.read(fd, 1 << 20):
                    digest.update(chunk)
                    read_total += len(chunk)
                after = os.fstat(fd)
                fields = lambda x: (x.st_dev, x.st_ino, x.st_size, x.st_mtime_ns)
                if fields(before) != fields(after) or read_total != before.st_size:
                    errors.append(f"file changed while hashing: {rel}")
                    continue
            finally:
                os.close(fd)

            total_bytes += meta.st_size
            entries.append({
                "depth": file_depth_here,
                "path": str(rel),
                "sha256": "sha256:" + digest.hexdigest(),
                "size": meta.st_size,
                "type": "file",
            })

        if entry_cap_hit or bytes_cap_hit:
            dirs.clear()

    return sorted(entries, key=lambda e: e["path"]), limitations, errors


# ---------------------------------------------------------------------------
# CLI and main
# ---------------------------------------------------------------------------

def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="corroborate-unblob")
    p.add_argument("--input", type=Path, required=True, help="Firmware/opaque-binary image to analyse")
    p.add_argument("--output", type=Path, required=True, help="New output directory (must not exist)")
    p.add_argument("--timeout", type=int, default=120, help="Wall-clock timeout for unblob (seconds, default 120)")
    p.add_argument("--max-entries", type=int, default=10_000, help="Maximum inventory entries (default 10000)")
    p.add_argument("--max-total-bytes", type=int, default=256 * 1024 * 1024, help="Maximum total inventoried bytes (default 256 MiB)")
    p.add_argument("--max-depth", type=int, default=10, help="Maximum extraction/inventory depth (default 10)")
    p.add_argument("--manifest-cli", type=Path, required=True, help=argparse.SUPPRESS)
    return p


def main(argv: list[str] | None = None) -> int:  # noqa: C901
    args = _parser().parse_args(argv)
    stage: Path | None = None
    extract_tmp: Path | None = None

    try:
        # Caps validation.
        if args.timeout < 1:
            raise UnblobError("--timeout must be >= 1")
        if args.max_entries < 1:
            raise UnblobError("--max-entries must be >= 1")
        if args.max_total_bytes < 1:
            raise UnblobError("--max-total-bytes must be >= 1")
        if args.max_depth < 1:
            raise UnblobError("--max-depth must be >= 1")

        # Output path safety.
        if ".." in args.output.parts or "\\" in str(args.output):
            raise UnblobError("output must be a canonical path")

        parent = args.output.parent.resolve(strict=True)
        require_private(parent)

        destination = parent / args.output.name
        if destination.exists() or destination.is_symlink():
            raise UnblobError("output must be a new non-colliding path")

        # Manifest CLI must exist.
        manifest_cli = args.manifest_cli.resolve(strict=True)

        # Resolve tools.
        search = os.environ.get("PATH", "")
        bwrap_exe, bwrap_record = executable("bwrap", os.environ.get("RSDD_BWRAP"), search)
        unblob_exe, unblob_record = executable(
            "unblob", os.environ.get("RSDD_UNBLOB"), search
        )

        unblob_version = _version(unblob_exe)

        # Staging directories.
        stage = parent / f".{destination.name}.stage"
        stage.mkdir(mode=0o700)
        (stage / "input").mkdir()
        (stage / "engine").mkdir()

        # Extraction temp (separate from stage — never published).
        extract_tmp = parent / f".{destination.name}.extract"
        extract_tmp.mkdir(mode=0o700)
        extract_dir = extract_tmp / "extracted"
        extract_dir.mkdir()

        # Stage the input.
        source_record, staged_record = stage_file(
            args.input,
            stage / "input" / "firmware.bin",
            "input/firmware.bin",
            0o400,
        )

        # Build sandbox environment.
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

        # Build bwrap prefix and extend with venv + extraction dir binds.
        # The extraction dir is a writable adapter-controlled temp dir; it
        # deliberately bypasses _RO_INPUT_BLOCKED_ROOTS (see bind_venv docstring).
        prefix = sandbox(bwrap_exe, env)
        prefix = bind_venv(
            prefix, unblob_exe,
            writable=[(extract_dir, "/tmp/rsdd/extract")],
        )

        # Input inside the sandbox is accessible via the read-only work-dir bind.
        input_in_sandbox = "/tmp/rsdd/work/input/firmware.bin"

        # Canonical inside-sandbox argv for unblob (paths are fixed, deterministic).
        # This is what gets stored in the evidence JSON for auditability.
        unblob_argv_canonical = [
            str(unblob_exe),
            "--extract-dir", "/tmp/rsdd/extract",
            "--report", "/tmp/rsdd/extract/unblob-report.json",
            "--log", "/tmp/rsdd/data/unblob.log",
            "-d", str(args.max_depth),
            input_in_sandbox,
        ]

        # Full bwrap+unblob command executed by run_bounded (includes run-specific
        # host paths such as --bind <extract_dir> /tmp/rsdd/extract; stored in the
        # manifest spec for provenance but NOT in the evidence JSON to preserve
        # byte-for-byte determinism across calls with different output names).
        unblob_cmd = prefix + unblob_argv_canonical
        unblob_idx = len(prefix)  # index of unblob_exe in unblob_cmd

        # Run unblob under bounded subprocess control.
        unblob_run, run_errors = run_bounded(
            unblob_cmd,
            stage,
            env,
            timeout=args.timeout,
            max_bytes=_MAX_OUTPUT_BYTES,
        )

        # Build inventory from the extraction temp directory.
        entries, walk_limitations, walk_errors = _walk_extracted(
            extract_dir,
            args.max_entries,
            args.max_total_bytes,
            args.max_depth,
        )

        # Read unblob's report (best-effort; ignored if missing or malformed).
        # O_NOFOLLOW prevents following a symlink planted by a malicious firmware.
        report_path = extract_dir / "unblob-report.json"
        unblob_report_entries: int = 0
        try:
            _rnofollow = getattr(os, "O_NOFOLLOW", 0)
            _rcloexec = getattr(os, "O_CLOEXEC", 0)
            _rmeta = report_path.lstat()
            if stat.S_ISREG(_rmeta.st_mode):
                _rfd = os.open(report_path, os.O_RDONLY | _rnofollow | _rcloexec)
                try:
                    raw = json.loads(os.read(_rfd, max(1, _rmeta.st_size)))
                    unblob_report_entries = len(raw) if isinstance(raw, list) else 0
                finally:
                    os.close(_rfd)
        except (json.JSONDecodeError, OSError):
            pass

        # Delete extraction temp — do NOT publish extracted payload.
        shutil.rmtree(extract_tmp)
        extract_tmp = None

        # Propagate run-cap truncation: timeout/output-cap/process-cap make the
        # extraction incomplete even when the walk itself saw no files.
        run_trunc, trunc_lims = run_truncation(run_errors, "unblob")

        # Aggregate errors (subprocess + walk).
        all_errors = run_errors + walk_errors
        all_limitations = _LIMITATIONS + walk_limitations + trunc_lims

        # Build evidence domain (under the "extraction" key — avoids reserved keys).
        # argv uses inside-sandbox canonical paths (deterministic for same input/args).
        # run (with timestamps) is intentionally omitted here; it is in manifest_spec
        # only.  This keeps the evidence JSON byte-for-byte reproducible across
        # otherwise identical invocations that differ only in timing.
        domain: dict[str, Any] = {
            "extraction": {
                "argv": unblob_argv_canonical,
                "caps": {
                    "max_depth": args.max_depth,
                    "max_entries": args.max_entries,
                    "max_total_bytes": args.max_total_bytes,
                    "timeout": args.timeout,
                },
                "entries": entries,
                "entry_count": len(entries),
                "tool": unblob_record,
                "total_size_bytes": sum(e["size"] for e in entries),
                "truncated": bool(walk_limitations) or run_trunc,
                "unblob_report_tasks": unblob_report_entries,
            }
        }

        # Build manifest spec.
        manifest_spec: dict[str, Any] = {
            "argv": unblob_cmd,
            "completeness": "failed" if all_errors else "complete",
            "environment": env,
            "errors": all_errors,
            "findings": [],
            "input": {
                "detected_type": "firmware/opaque binary",
                "path": "input/firmware.bin",
            },
            "isolation_profile": _PROFILE,
            "limitations": all_limitations,
            "outputs": [f"{SCHEMA}.json"],
            "run": unblob_run,
            "schema_version": "analysis-manifest.v1",
            "stderr_path": "engine/stderr.txt",
            "stdout_path": "engine/stdout.txt",
            "tool": {
                "artifacts": [
                    {"argv_index": unblob_idx, "path": str(unblob_exe)},
                ],
                "executable": str(bwrap_exe),
                "name": "unblob",
                "version": unblob_version,
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

    except (UnblobError, AdapterError, ManifestError, OSError,
            subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"corroborate-unblob: {exc}", file=sys.stderr)
        return 2
    finally:
        if extract_tmp is not None and extract_tmp.exists():
            shutil.rmtree(extract_tmp)
        if stage is not None and stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    sys.exit(main())
