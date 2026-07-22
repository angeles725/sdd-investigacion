#!/usr/bin/env python3
"""Produce bounded, offline obfuscated-string inventory from a PE/ELF binary.

Runs floss (FLARE Labs Obfuscated String Solver v3.1.1) inside a network-denied
Bubblewrap sandbox to extract and inventory obfuscated strings from a binary.

Reports COUNTS + a BOUNDED, digested sample of extracted strings — never an
unbounded raw dump.  Truncation is ALWAYS visible: any cap that fires records a
human-readable limitation string and sets truncated=true.

Static, stack, tight, and decoded string categories are extracted when floss
supports the binary format (PE32/PE32+).  For formats where floss only extracts
static strings (ELF, raw data), the non-zero exit is recorded as an error but
evidence is still published (status=failed, not exit 2).

A binary where floss finds no strings (exits 0 with empty JSON or no JSON)
produces a valid status=complete empty inventory.
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
from lib.adapter_helpers import ManifestError, VenvBindError, bind_venv, emit_evidence, run_truncation
from lib.isolation_profile import PROFILE_BWRAP_FLOSS_OFFLINE

SCHEMA = "floss-evidence.v1"

_PROFILE = PROFILE_BWRAP_FLOSS_OFFLINE

_LIMITATIONS: list[str] = [
    "floss performs static + emulation-based string recovery; results vary by binary "
    "format and obfuscation technique.",
    "Stack string, tight string, and decoded string extraction requires PE format; ELF "
    "and other formats yield static strings only — a non-zero exit is recorded as an "
    "error and evidence is published with status=failed.",
    "Bubblewrap on WSL2 provides network isolation but is not a full hostile-parser "
    "security boundary; use a disposable VM for actively hostile samples.",
    "Caps (--max-strings, --max-string-len, --timeout) and output/process limits bound "
    "resource use; any cap that fires is reported in limitations and truncated is set "
    "true — never silent.",
]

# Combined stdout+stderr cap for run_bounded (4 MiB is generous for floss JSON output).
_MAX_OUTPUT_BYTES: int = 4 * 1024 * 1024

# String categories emitted by `floss -j`, in canonical order.
_CATEGORIES: tuple[str, ...] = (
    "static_strings",
    "stack_strings",
    "tight_strings",
    "decoded_strings",
)


class FlossError(AdapterError):
    """Fail-closed error for the floss evidence adapter."""


# ---------------------------------------------------------------------------
# Version probe
# ---------------------------------------------------------------------------

def _version(floss_exe: Path) -> str:
    """Return the floss version string (host-side probe; no network access)."""
    try:
        result = subprocess.run(
            [str(floss_exe), "--version"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        line = result.stdout.strip() or result.stderr.strip()
        return line.splitlines()[0] if line else "unknown"
    except Exception:
        return "unknown"


# ---------------------------------------------------------------------------
# Floss stdout JSON reader (O_NOFOLLOW-safe)
# ---------------------------------------------------------------------------

def _read_stdout_json(stdout_path: Path) -> tuple[dict[str, Any] | None, str | None]:
    """Read stdout.txt with O_NOFOLLOW + lstat/S_ISREG and parse as JSON.

    Returns ``(parsed_dict, None)`` on success, ``(None, None)`` when the
    file is empty (no output produced), or ``(None, error_str)`` when the
    file is non-empty but the JSON is malformed.  The error string is a
    human-readable description suitable for inclusion in the evidence errors
    list — malformed JSON on exit-0 is now an explicit error (``status=failed``),
    not silently promoted to an empty inventory.

    Raises FlossError when a symlink or non-regular file is detected (TOCTOU-safe):
    - lstat before open: rejects symlinks and non-regular files.
    - O_NOFOLLOW on open: kernel-level symlink rejection (belt-and-suspenders).
    - fstat after read: detects TOCTOU modification between lstat and read.
    """
    NOFOLLOW: int = getattr(os, "O_NOFOLLOW", 0)
    CLOEXEC: int = getattr(os, "O_CLOEXEC", 0)

    try:
        meta = stdout_path.lstat()
    except OSError as exc:
        raise FlossError(f"cannot stat floss stdout: {stdout_path}") from exc

    if stat.S_ISLNK(meta.st_mode):
        raise FlossError(f"symlink detected at floss output path: {stdout_path}")
    if not stat.S_ISREG(meta.st_mode):
        raise FlossError(f"floss stdout is not a regular file: {stdout_path}")
    if meta.st_size == 0:
        return None, None

    try:
        fd = os.open(stdout_path, os.O_RDONLY | NOFOLLOW | CLOEXEC)
    except OSError as exc:
        raise FlossError(
            f"cannot open floss stdout (symlink?): {stdout_path}"
        ) from exc
    try:
        before = os.fstat(fd)
        raw = os.read(fd, max(1, meta.st_size + 1))
        after = os.fstat(fd)
        fields = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)
        if fields(before) != fields(after):
            raise FlossError("floss stdout changed while reading (TOCTOU)")
    finally:
        os.close(fd)

    if not raw:
        return None, None

    try:
        return json.loads(raw), None
    except json.JSONDecodeError as exc:
        return None, f"malformed JSON in floss stdout: {exc}"


# ---------------------------------------------------------------------------
# Bounded inventory builder
# ---------------------------------------------------------------------------

def _build_inventory(
    floss_json: dict[str, Any] | None,
    max_strings: int,
    max_string_len: int,
) -> tuple[dict[str, Any], list[str]]:
    """Build bounded string inventory from parsed floss JSON.

    Returns (inventory_dict, extra_limitations).

    Caps enforced:
    - Total string count across all categories: when max_strings is exhausted,
      no further strings are sampled.  truncated=True and a limitation string
      are recorded — never silent.
    - Per-string value length: strings longer than max_string_len are truncated
      to max_string_len.  truncated=True and a limitation string are recorded
      when any string is truncated — never silent.

    Determinism: strings within each category are sorted by (offset, value)
    before sampling.  The same binary + same floss version + same caps always
    produce identical output.

    inventory_dict layout:
        static_strings:  {count, sampled, truncated, strings: [{offset, encoding, value, sha256}]}
        stack_strings:   same
        tight_strings:   same
        decoded_strings: same
        total_count:     int
        total_sampled:   int
        truncated:       bool  (True when ANY cap fired)
        floss_version:   str   (populated by caller)
        argv:            list  (populated by caller)
        caps:            dict  (populated by caller)
        tool:            dict  (populated by caller)
    """
    extra_limitations: list[str] = []

    if floss_json is None:
        # floss produced no output (e.g., file with no detectable content).
        empty_cat: dict[str, Any] = {
            "count": 0, "sampled": 0, "strings": [], "truncated": False,
        }
        return {
            "decoded_strings": dict(empty_cat),
            "stack_strings": dict(empty_cat),
            "static_strings": dict(empty_cat),
            "tight_strings": dict(empty_cat),
            "total_count": 0,
            "total_sampled": 0,
            "truncated": False,
        }, []

    strings_block = floss_json.get("strings", {})

    remaining_budget: int = max_strings
    string_cap_hit: bool = False
    length_cap_hit: bool = False

    categories: dict[str, Any] = {}
    total_count: int = 0
    total_sampled: int = 0

    for cat in _CATEGORIES:
        raw_list: list[dict[str, Any]] = strings_block.get(cat, [])
        count: int = len(raw_list)
        total_count += count

        # Sort within category for determinism: (offset, string_value).
        try:
            sorted_raw = sorted(
                raw_list,
                key=lambda e: (e.get("offset", 0), e.get("string", "")),
            )
        except (TypeError, KeyError):
            sorted_raw = list(raw_list)

        sampled: list[dict[str, Any]] = []

        for entry in sorted_raw:
            if string_cap_hit or remaining_budget <= 0:
                # Boolean flag tracks cap; do NOT scan the list to infer it.
                string_cap_hit = True
                break

            raw_val: str = entry.get("string", "")

            # Per-string length cap: truncate and record flag once.
            if len(raw_val) > max_string_len:
                raw_val = raw_val[:max_string_len]
                if not length_cap_hit:
                    length_cap_hit = True

            digest = "sha256:" + hashlib.sha256(
                raw_val.encode("utf-8", errors="replace")
            ).hexdigest()

            sampled.append({
                "encoding": entry.get("encoding"),
                "offset": entry.get("offset", 0),
                "sha256": digest,
                "value": raw_val,
            })
            remaining_budget -= 1

        # Boolean truncated flag per category: True when more strings exist than sampled.
        cat_truncated: bool = count > len(sampled)
        categories[cat] = {
            "count": count,
            "sampled": len(sampled),
            "strings": sampled,
            "truncated": cat_truncated,
        }
        total_sampled += len(sampled)

    # Overall truncated = True when ANY cap fired (string count or length).
    # Determined by boolean flags — never by scanning string values.
    # (total_count > total_sampled) is a redundant third term: if it is true,
    # string_cap_hit must also be true by construction.
    overall_truncated: bool = string_cap_hit or length_cap_hit

    if string_cap_hit:
        extra_limitations.append(
            f"inventory truncated: string cap {max_strings} reached"
        )
    if length_cap_hit:
        extra_limitations.append(
            f"inventory truncated: string-length cap {max_string_len} reached"
        )

    return {
        **categories,
        "total_count": total_count,
        "total_sampled": total_sampled,
        "truncated": overall_truncated,
    }, extra_limitations


# ---------------------------------------------------------------------------
# CLI and main
# ---------------------------------------------------------------------------

def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="corroborate-floss")
    p.add_argument(
        "--input", type=Path, required=True,
        help="PE/ELF binary to analyse",
    )
    p.add_argument(
        "--output", type=Path, required=True,
        help="New output directory (must not exist)",
    )
    p.add_argument(
        "--timeout", type=int, default=120,
        help="Wall-clock timeout for floss (seconds, default 120)",
    )
    p.add_argument(
        "--max-strings", type=int, default=2000,
        help="Maximum total strings sampled across all categories (default 2000)",
    )
    p.add_argument(
        "--max-string-len", type=int, default=256,
        help="Maximum length of each sampled string value (default 256)",
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
            raise FlossError("--timeout must be >= 1")
        if args.max_strings < 1:
            raise FlossError("--max-strings must be >= 1")
        if args.max_string_len < 1:
            raise FlossError("--max-string-len must be >= 1")

        # Output path safety.
        if ".." in args.output.parts or "\\" in str(args.output):
            raise FlossError("output must be a canonical path")

        parent = args.output.parent.resolve(strict=True)
        require_private(parent)

        destination = parent / args.output.name
        if destination.exists() or destination.is_symlink():
            raise FlossError("output must be a new non-colliding path")

        # Manifest CLI must exist.
        manifest_cli = args.manifest_cli.resolve(strict=True)

        # Resolve tools.
        search = os.environ.get("PATH", "")
        bwrap_exe, bwrap_record = executable("bwrap", os.environ.get("RSDD_BWRAP"), search)
        floss_exe, floss_record = executable(
            "floss", os.environ.get("RSDD_FLOSS"), search
        )

        floss_version = _version(floss_exe)

        # Staging directory.
        stage = parent / f".{destination.name}.stage"
        stage.mkdir(mode=0o700)
        (stage / "input").mkdir()
        (stage / "engine").mkdir()

        # Stage the input.
        source_record, staged_record = stage_file(
            args.input,
            stage / "input" / "binary.bin",
            "input/binary.bin",
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

        # Build bwrap prefix and extend with floss venv bind.
        # /etc/passwd and /etc/group are bound read-only via the allowed narrow
        # exception in bind_venv: vivisect calls getpass.getuser() → pwd.getpwuid().
        prefix = sandbox(bwrap_exe, env)
        prefix = bind_venv(
            prefix, floss_exe,
            etc_ro_bind_try=("/etc/passwd", "/etc/group"),
        )

        # Input inside the sandbox is at the read-only work-dir bind.
        input_in_sandbox = "/tmp/rsdd/work/input/binary.bin"

        # Canonical inside-sandbox argv for floss (paths are fixed, deterministic).
        # Stored in the evidence JSON for auditability.  Run-specific host paths
        # (bwrap binds) are only in the manifest spec, not in the evidence JSON,
        # to preserve byte-for-byte determinism across calls with different output names.
        floss_argv_canonical: list[str] = [
            str(floss_exe),
            "-j",
            input_in_sandbox,
        ]

        # Full bwrap+floss command executed by run_bounded.
        floss_cmd = prefix + floss_argv_canonical
        floss_idx = len(prefix)  # index of floss_exe in floss_cmd

        # Run floss under bounded subprocess control.
        # Output is captured to stage/engine/stdout.txt and stage/engine/stderr.txt.
        floss_run, run_errors = run_bounded(
            floss_cmd,
            stage,
            env,
            timeout=args.timeout,
            max_bytes=_MAX_OUTPUT_BYTES,
        )

        # Read floss JSON output from stdout.txt with O_NOFOLLOW protection.
        # Returns (dict|None, error_str|None): non-empty malformed stdout is now
        # an explicit error (status=failed) rather than a silent empty inventory.
        stdout_path = stage / "engine" / "stdout.txt"
        floss_json, parse_error = _read_stdout_json(stdout_path)

        # Build bounded inventory from floss JSON (None = empty/malformed output).
        inventory, inv_limitations = _build_inventory(
            floss_json,
            max_strings=args.max_strings,
            max_string_len=args.max_string_len,
        )

        # Propagate run-cap truncation into the inventory's top-level truncated flag.
        # Satisfies the incomplete-run visibility convention: any cap that fires sets
        # truncated=true — timeout, output-cap, and process-cap are all included.
        run_trunc, trunc_lims = run_truncation(run_errors, "floss")
        inventory["truncated"] = inventory["truncated"] or run_trunc

        # Aggregate limitations and errors.
        all_limitations = _LIMITATIONS + inv_limitations + trunc_lims
        all_errors = run_errors + ([parse_error] if parse_error else [])

        # Annotate the inventory with tool metadata and caps.
        # These fields are deterministic (same across identical invocations).
        inventory["argv"] = floss_argv_canonical
        inventory["caps"] = {
            "max_string_len": args.max_string_len,
            "max_strings": args.max_strings,
            "timeout": args.timeout,
        }
        inventory["floss_version"] = floss_version
        inventory["tool"] = floss_record

        # Build evidence domain (under the "strings" key — avoids reserved keys).
        domain: dict[str, Any] = {
            "strings": inventory,
        }

        # Build manifest spec.
        manifest_spec: dict[str, Any] = {
            "argv": floss_cmd,
            "completeness": "failed" if all_errors else "complete",
            "environment": env,
            "errors": all_errors,
            "findings": [],
            "input": {
                "detected_type": "PE/ELF binary",
                "path": "input/binary.bin",
            },
            "isolation_profile": _PROFILE,
            "limitations": all_limitations,
            "outputs": [f"{SCHEMA}.json"],
            "run": floss_run,
            "schema_version": "analysis-manifest.v1",
            "stderr_path": "engine/stderr.txt",
            "stdout_path": "engine/stdout.txt",
            "tool": {
                "artifacts": [
                    {"argv_index": floss_idx, "path": str(floss_exe)},
                ],
                "executable": str(bwrap_exe),
                "name": "floss",
                "version": floss_version,
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

    except (FlossError, AdapterError, ManifestError, OSError,
            subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"corroborate-floss: {exc}", file=sys.stderr)
        return 2
    finally:
        if stage is not None and stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    sys.exit(main())
