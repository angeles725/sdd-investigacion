#!/usr/bin/env python3
"""corroborate_kaitai.py — Kaitai Struct binary parsing evidence adapter.

Two-stage pipeline:
  Stage 1 (JVM, network-denied): ksc --target python --debug → generates
    engine/gen/<meta_id>.py inside the sandbox work dir.
  Stage 2 (kaitai Python, network-denied): driver walks SEQ_FIELDS+_debug
    offsets to produce bounded JSON evidence.

Binary data never touches Stage 1; Stage 1 output is a pure Python file
that has no network/exec capability of its own (it calls kaitaistruct read
methods only).

Usage:
  corroborate-kaitai.sh --input BINARY --ksy STRUCT.ksy --output DIR

Exit codes:
  0  complete (no errors)
  1  analysis failed (parse error or timeout) — evidence still published
  2  fatal: bad inputs, compile failure, or internal error — no evidence
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Toolbelt imports
# ---------------------------------------------------------------------------
_HERE = Path(__file__).parent
sys.path.insert(0, str(_HERE))
from lib.adapter_core import (
    AdapterError,
    executable,
    identity,
    publish,
    require_private,
    run_bounded,
    sandbox,
    stage_file,
    write,
)
from lib.adapter_helpers import ManifestError, emit_evidence, run_truncation

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
_SCHEMA = "kaitai-evidence.v1"
_KSY_MAX_BYTES = 1 * 1024 * 1024     # 1 MiB: oversized KSY is a usage error
_DEFAULT_TIMEOUT = 300                # Stage 2 wall-clock limit (seconds)
_COMPILE_TIMEOUT = 60                 # Stage 1 wall-clock limit (seconds)
_OUTPUT_CAP_BYTES = 4 * 1024 * 1024  # 4 MiB driver output cap
_COMPILE_CAP_BYTES = 2 * 1024 * 1024 # 2 MiB ksc output cap

_PROFILE: dict[str, Any] = {
    "name": "bubblewrap-kaitai-offline",
    "network_access": False,
    "static_only": True,
    "target_execution": False,
}

_LIMITATIONS: list[str] = [
    "Kaitai Struct driver operates read-only; the binary is never executed.",
    "Only top-level SEQ_FIELDS are walked; implicit/computed fields and "
    "instances are not captured.",
    "Bubblewrap on WSL2 is defense-in-depth, not a hostile-parser security "
    "boundary; use a disposable VM for adversarial binaries.",
]

# Top-level paths the toolchain resolver must never bind as a root.
_TOOLCHAIN_BLOCKED_EXACT: frozenset[str] = frozenset({
    "/", "/home", "/root",
    "/usr", "/bin", "/sbin", "/lib", "/lib64",
    "/etc", "/tmp", "/proc", "/sys", "/dev", "/run",
})


# ---------------------------------------------------------------------------
# Error class
# ---------------------------------------------------------------------------

class KaitaiError(AdapterError):
    """Fail-closed error for the kaitai evidence adapter."""


# ---------------------------------------------------------------------------
# Toolchain scope guards
# ---------------------------------------------------------------------------

def _toolchain_scope_guard(p: Path) -> None:
    """Pure shape check — rejects system roots and shallow paths.

    Raises KaitaiError when:
    - str(p) is in _TOOLCHAIN_BLOCKED_EXACT.
    - p has fewer than 4 path components (e.g. /home/linuxbrew has 3).
    """
    s = str(p)
    if s in _TOOLCHAIN_BLOCKED_EXACT:
        raise KaitaiError(f"path rejected by toolchain scope guard: {s!r}")
    if len(p.parts) < 4:
        raise KaitaiError(
            f"path too shallow for toolchain binding (< 4 components): {s!r}"
        )


def _jdk_home_guard(home: Path) -> None:
    """Validate JDK home directory using strong FS markers."""
    _toolchain_scope_guard(home)
    for marker in (home / "bin" / "java", home / "release"):
        if not marker.is_file():
            raise KaitaiError(f"JDK home missing expected marker {marker.name}: {home}")


# ---------------------------------------------------------------------------
# Brew-root utilities
# ---------------------------------------------------------------------------

def _brew_root_for(p: Path) -> Path | None:
    """Walk ancestors of *p* to find the brew installation root.

    The brew root is identified by the simultaneous presence of ``Cellar/``
    and ``bin/`` as direct children.  Returns None when *p* is not under a
    brew installation (system paths, etc.).
    """
    for parent in [p, *p.parents]:
        if not parent.is_dir():
            continue
        if (parent / "Cellar").is_dir() and (parent / "bin").is_dir():
            return parent
    return None


def _bind_tree(p: Path) -> list[str]:
    """Return bwrap args: ``--dir`` stubs for ancestors + ``--ro-bind`` for *p*."""
    parts = p.parts
    args: list[str] = []
    for i in range(1, len(parts)):
        args += ["--dir", str(Path(*parts[: i + 1]))]
    args += ["--ro-bind", str(p), str(p)]
    return args


def _ld_so_stub_for(prefix: Path) -> list[str]:
    """Find the brew ld.so symlink under *prefix* and recreate it in the sandbox.

    Walks from *prefix* upward to find ``<brew_root>/lib/ld.so`` (a symlink
    to the system loader).  Returns ``--dir`` + ``--symlink`` args, or ``[]``
    when no such symlink is found.
    """
    for p in [prefix, *prefix.parents]:
        ld_so = p / "lib" / "ld.so"
        try:
            if ld_so.is_symlink():
                target = os.readlink(str(ld_so))
                return ["--dir", str(ld_so.parent), "--symlink", target, str(ld_so)]
        except OSError:
            continue
    return []


# ---------------------------------------------------------------------------
# JVM toolchain binding (Stage 1)
# ---------------------------------------------------------------------------

def _jdk_home_for() -> Path:
    """Resolve the JDK home directory (parent of bin/java)."""
    java_raw = os.environ.get("RSDD_JAVA", "java")
    java_path = Path(java_raw)
    if not java_path.is_absolute():
        found = shutil.which(java_raw)
        if not found:
            raise KaitaiError(
                "java executable not found; install via brew or set RSDD_JAVA"
            )
        java_path = Path(found)
    java_resolved = java_path.resolve(strict=True)
    jdk_home = java_resolved.parent.parent
    _jdk_home_guard(jdk_home)
    return jdk_home


def _ksc_exe_for() -> Path:
    """Resolve the kaitai-struct-compiler executable (returns realpath)."""
    ksc_raw = os.environ.get("RSDD_KSC", "kaitai-struct-compiler")
    ksc_path = Path(ksc_raw)
    if not ksc_path.is_absolute():
        found = shutil.which(ksc_raw)
        if not found:
            raise KaitaiError(
                "kaitai-struct-compiler not found; install via brew or set RSDD_KSC"
            )
        ksc_path = Path(found)
    if not os.access(str(ksc_path), os.X_OK):
        raise KaitaiError(f"ksc not executable: {ksc_path}")
    return ksc_path.resolve(strict=True)


def _ksc_version(ksc_exe: Path) -> str:
    """Return ksc version string (best-effort)."""
    try:
        r = subprocess.run(
            [str(ksc_exe), "--version"],
            capture_output=True, text=True, timeout=30,
        )
        out = (r.stdout + r.stderr).strip()
        return out[:100] if out else "unknown"
    except Exception as exc:
        return f"unknown ({exc})"


def _bind_jvm_toolchain(
    prefix: list[str],
    ksc_resolved: Path,
    jdk_home: Path,
    gen_host_dir: Path,
) -> list[str]:
    """Extend *prefix* with bwrap args for ksc + JDK + writable gen dir.

    When ksc lives in a brew installation, the entire brew root is bound
    read-only (containing ksc jar, JDK, and all symlinks intact).  When ksc
    is in a system path already covered by sandbox() (/usr, /bin …) no extra
    bind is added.  The gen dir receives a writable ``--bind`` so ksc can
    write the generated .py.

    ``/etc/alternatives`` is bind-tried read-only so that update-alternatives
    symlinks (e.g. /usr/bin/awk → /etc/alternatives/awk → /usr/bin/gawk)
    resolve correctly inside the sandbox when the ksc wrapper script calls awk.
    """
    extra: list[str] = []

    # /etc/alternatives symlink farm — needed by ksc shell wrapper for awk etc.
    extra += ["--ro-bind-try", "/etc/alternatives", "/etc/alternatives"]

    brew = _brew_root_for(ksc_resolved)
    if brew is not None:
        _toolchain_scope_guard(brew)
        extra += _bind_tree(brew)
        extra += _ld_so_stub_for(brew)
    # If brew is None: ksc is in a system path already bound by sandbox().

    # JDK home: if it shares the same brew root, already covered above.
    jdk_brew = _brew_root_for(jdk_home)
    if jdk_brew is not None and jdk_brew != brew:
        _toolchain_scope_guard(jdk_brew)
        extra += _bind_tree(jdk_brew)
        extra += _ld_so_stub_for(jdk_brew)

    # Writable output directory for the generated .py file
    extra += [
        "--dir", "/tmp/rsdd/gen",
        "--bind", str(gen_host_dir), "/tmp/rsdd/gen",
    ]

    return prefix[:-1] + extra + ["--"]


# ---------------------------------------------------------------------------
# Kaitai Python venv binding (Stage 2)
# ---------------------------------------------------------------------------

def _bind_kaitai_venv(prefix: list[str], kaitai_py: Path) -> list[str]:
    """Extend *prefix* with bwrap args for the kaitai Python venv.

    The kaitai Python at ~/.local/share/rsdd-kaitai/bin/python has a
    symlink chain that venv_root_for() cannot follow (it resolves to the brew
    Cellar Python, which has no pyvenv.cfg).  This function reads pyvenv.cfg
    manually and binds BOTH the venv root AND the brew Cellar Python, then
    recreates the opt→Cellar symlink and the ld.so stub.

    Security: same scope guards as bind_venv(); no write access.
    """
    # 1. Derive venv_root from the raw (not resolved) path so we stop at the
    #    venv boundary rather than following symlinks into the brew Cellar.
    kp = kaitai_py.expanduser()
    venv_root = kp.parent.parent

    _toolchain_scope_guard(venv_root)
    pyvenv = venv_root / "pyvenv.cfg"
    if not pyvenv.is_file():
        raise KaitaiError(
            f"kaitai Python is not inside a venv (no pyvenv.cfg): {venv_root}"
        )

    # Belt: venv_root must not be the real home directory
    home = Path(os.path.expanduser("~")).resolve()
    if venv_root.resolve() == home:
        raise KaitaiError("kaitai Python venv must not be the home directory")

    # 2. Parse pyvenv.cfg to find the brew Python executable
    cfg: dict[str, str] = {}
    for line in pyvenv.read_text().splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip()

    brew_exe_str = cfg.get("executable", "")
    if not brew_exe_str:
        raise KaitaiError(f"pyvenv.cfg missing 'executable' key: {pyvenv}")
    brew_exe = Path(brew_exe_str)

    # 3. brew_prefix = parent of the bin/ dir inside the Cellar version
    brew_prefix = brew_exe.parent.parent
    _toolchain_scope_guard(brew_prefix)
    if not brew_exe.is_file():
        raise KaitaiError(f"brew Python executable not found: {brew_exe}")

    # 4. Derive opt symlink to recreate in sandbox
    #    pyvenv.cfg 'home' = /…/opt/python@X.Y/bin  →  opt_py = opt/python@X.Y
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
# Stage helpers
# ---------------------------------------------------------------------------

def _get_gen_stem(gen_dir: Path) -> str:
    """Return the stem of the single .py generated by ksc.

    Raises KaitaiError when there is not exactly one non-symlink .py file.
    """
    pys = [f for f in gen_dir.iterdir() if f.suffix == ".py" and f.is_file()]
    if len(pys) != 1:
        raise KaitaiError(
            f"expected exactly one generated .py in {gen_dir}, found: "
            + str([f.name for f in pys])
        )
    return pys[0].stem


def _read_stdout_json(stdout_path: Path) -> tuple[dict | None, str | None]:
    """Parse JSON from the driver's stdout file.

    Returns ``(dict, None)`` on success, ``(None, error_str)`` on failure.
    An empty file is treated as an error (driver did not produce output).
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


def _build_limitations_and_errors(
    driver_result: dict | None,
    run_errors: list[str],
    parse_json_error: str | None,
) -> tuple[list[str], list[str], bool]:
    """Return (limitations, errors, truncated) from driver output and run errors."""
    limitations: list[str] = list(_LIMITATIONS)
    errors: list[str] = list(run_errors)
    truncated = False

    # run_bounded cap errors (timeout, output-cap, process-cap) → truncated + limitations.
    # analyzer-exit:N is NOT a truncation event — the tool ran to completion.
    run_trunc, cap_lims = run_truncation(run_errors, "kaitai-driver")
    limitations.extend(cap_lims)
    if run_trunc:
        truncated = True

    if parse_json_error:
        errors.append(f"driver-output-error: {parse_json_error}")

    if driver_result is not None:
        parse_error = driver_result.get("parse_error")
        if parse_error:
            errors.append(f"parse-error: {parse_error}")

        if driver_result.get("truncated"):
            truncated = True
            if driver_result.get("depth_cap"):
                limitations.append(
                    "structure walk depth cap fired — sub-struct children not included"
                )
            if driver_result.get("value_trunc"):
                limitations.append(
                    "field value bytes cap fired — large values shown truncated"
                )
            counts = driver_result.get("counts", {})
            sampled = counts.get("sampled", 0)
            total = counts.get("total_fields", 0)
            if sampled < total:
                limitations.append(
                    f"field count cap fired — {sampled} of {total} fields sampled"
                )

    return limitations, errors, truncated


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Kaitai Struct binary parsing evidence adapter",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--input", type=Path, required=True,
                   help="Binary file to parse")
    p.add_argument("--ksy", type=Path, required=True,
                   help="Kaitai Struct definition (.ksy)")
    p.add_argument("--output", type=Path, required=True,
                   help="Output directory (must not exist)")
    p.add_argument("--timeout", type=int, default=_DEFAULT_TIMEOUT,
                   help="Stage-2 parse timeout in seconds (default %(default)s)")
    p.add_argument("--compile-timeout", type=int, default=_COMPILE_TIMEOUT,
                   help="Stage-1 ksc compile timeout (default %(default)s)")
    p.add_argument("--max-fields", type=int, default=2000,
                   help="Maximum SEQ_FIELDS to include in output (default %(default)s)")
    p.add_argument("--max-depth", type=int, default=32,
                   help="Maximum recursion depth for nested structs (default %(default)s)")
    p.add_argument("--max-value-bytes", type=int, default=64,
                   help="Maximum bytes/chars per leaf value (default %(default)s)")
    p.add_argument("--max-memory-mb", type=int, default=256,
                   help="RLIMIT_AS cap for the driver process (default %(default)s)")
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
        # ------------------------------------------------------------------ #
        # Pre-flight checks
        # ------------------------------------------------------------------ #
        if args.timeout < 1 or args.compile_timeout < 1:
            raise KaitaiError("timeout values must be positive")
        if args.max_fields < 1 or args.max_depth < 1 or args.max_value_bytes < 1:
            raise KaitaiError("cap values must be positive")

        # Input validation: no symlinks, no already-existing output.
        # (stage_file enforces O_NOFOLLOW and size caps; this is the pre-flight
        # check for the output path and filesystem type only.)
        parent = args.output.parent.resolve(strict=True)
        require_private(parent)
        destination = parent / args.output.name
        if destination.exists() or destination.is_symlink():
            raise KaitaiError("output directory must not exist")

        # ------------------------------------------------------------------ #
        # Resolve toolchain
        # ------------------------------------------------------------------ #
        search = os.environ.get("PATH", "")
        bwrap, bwrap_record = executable("bwrap", os.environ.get("RSDD_BWRAP"), search)

        ksc_resolved = _ksc_exe_for()
        jdk_home = _jdk_home_for()
        ksc_ver = _ksc_version(ksc_resolved)

        kaitai_py_raw = Path(os.environ.get("RSDD_KAITAI_PY", "~/.local/share/rsdd-kaitai/bin/python"))
        kaitai_py_resolved = kaitai_py_raw.expanduser().resolve(strict=True)

        # Resolve driver.py path
        driver_lib = _HERE / "lib" / "kaitai_driver.py"
        if not driver_lib.is_file():
            raise KaitaiError(f"kaitai_driver.py not found: {driver_lib}")

        # ------------------------------------------------------------------ #
        # Create stage directory
        # ------------------------------------------------------------------ #
        stage = parent / f".{destination.name}.stage"
        stage.mkdir(mode=0o700)
        (stage / "input").mkdir()
        (stage / "engine").mkdir()
        (stage / "engine" / "gen").mkdir()

        # Stage ksy (size-capped)
        ksy_src, ksy_staged = stage_file(
            args.ksy, stage / "input/struct.ksy", "input/struct.ksy", 0o400,
            max_bytes=_KSY_MAX_BYTES,
        )

        # NOTE: binary staged AFTER Stage 1 so the JVM sandbox never contains
        # untrusted bytes — see "Stage binary" block below.

        # ------------------------------------------------------------------ #
        # Stage 1: ksc compile ksy → Python
        # ------------------------------------------------------------------ #
        env_stage1: dict[str, str] = {
            "HOME": "/tmp/rsdd/home",
            "JAVA_HOME": str(jdk_home),
            "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/usr/sbin:/bin:/sbin",
            "TMPDIR": "/tmp/rsdd", "TZ": "UTC",
        }
        # Add brew bin to PATH if ksc is in a brew installation
        brew_root = _brew_root_for(ksc_resolved)
        if brew_root is not None:
            env_stage1["PATH"] = str(brew_root / "bin") + ":" + env_stage1["PATH"]

        prefix_s1 = sandbox(bwrap, env_stage1)
        gen_host_dir = stage / "engine" / "gen"
        prefix_s1 = _bind_jvm_toolchain(prefix_s1, ksc_resolved, jdk_home, gen_host_dir)

        ksc_cmd = prefix_s1 + [
            str(ksc_resolved),
            "--target", "python",
            "--outdir", "/tmp/rsdd/gen",
            "--debug",
            "/tmp/rsdd/work/input/struct.ksy",
        ]
        s1_run, s1_errors = run_bounded(
            ksc_cmd, stage, env_stage1,
            args.compile_timeout, _COMPILE_CAP_BYTES,
        )

        # ksc must succeed; any error is fatal (exit 2, no evidence)
        if s1_errors:
            ksc_stderr = (stage / "engine/stderr.txt").read_text(errors="replace")
            raise KaitaiError(
                f"ksc compile failed (errors={s1_errors}): {ksc_stderr[:500]!r}"
            )
        if s1_run.get("exit_code") != 0:
            ksc_stderr = (stage / "engine/stderr.txt").read_text(errors="replace")
            raise KaitaiError(
                f"ksc exited {s1_run.get('exit_code')}: {ksc_stderr[:500]!r}"
            )

        # Rename stage1 stdout/stderr before stage2 overwrites them
        (stage / "engine/stdout.txt").rename(stage / "engine/compile-stdout.txt")
        (stage / "engine/stderr.txt").rename(stage / "engine/compile-stderr.txt")

        # Verify exactly one generated .py and get its stem
        stem = _get_gen_stem(gen_host_dir)

        # Identity of generated parser (for evidence)
        _, parser_size, parser_sha256 = identity(gen_host_dir / f"{stem}.py")

        # ------------------------------------------------------------------ #
        # Stage binary (after Stage 1 — keeps untrusted bytes out of JVM sandbox)
        # ------------------------------------------------------------------ #
        bin_src, bin_staged = stage_file(
            args.input, stage / "input/binary.bin", "input/binary.bin", 0o400,
        )

        # ------------------------------------------------------------------ #
        # Stage the driver (after Stage 1 so its paths are known)
        # ------------------------------------------------------------------ #
        drv_src, drv_staged = stage_file(
            driver_lib, stage / "engine/driver.py", "engine/driver.py", 0o500,
        )

        # ------------------------------------------------------------------ #
        # Stage 2: kaitai Python driver parses the binary
        # ------------------------------------------------------------------ #
        env_stage2: dict[str, str] = {
            "HOME": "/tmp/rsdd/home",
            "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/usr/sbin:/bin:/sbin",
            "TMPDIR": "/tmp/rsdd", "TZ": "UTC",
        }
        prefix_s2 = sandbox(bwrap, env_stage2)
        prefix_s2 = _bind_kaitai_venv(prefix_s2, kaitai_py_raw)

        stage2_cmd = prefix_s2 + [
            str(kaitai_py_raw.expanduser()),  # venv path, NOT resolved brew path
            "/tmp/rsdd/work/engine/driver.py",
            "--module-dir", "/tmp/rsdd/work/engine/gen",
            "--stem", stem,
            "--input", "/tmp/rsdd/work/input/binary.bin",
            "--max-fields", str(args.max_fields),
            "--max-depth", str(args.max_depth),
            "--max-value-bytes", str(args.max_value_bytes),
            "--max-memory-mb", str(args.max_memory_mb),
        ]
        s2_run, s2_errors = run_bounded(
            stage2_cmd, stage, env_stage2,
            args.timeout, _OUTPUT_CAP_BYTES,
        )

        # ------------------------------------------------------------------ #
        # Parse driver output
        # ------------------------------------------------------------------ #
        driver_result, parse_json_err = _read_stdout_json(stage / "engine/stdout.txt")

        limitations, errors, truncated = _build_limitations_and_errors(
            driver_result, s2_errors, parse_json_err,
        )

        # ------------------------------------------------------------------ #
        # Build evidence domain
        # ------------------------------------------------------------------ #
        if driver_result is not None:
            structure = {
                "root_type": driver_result.get("root_type"),
                "module": driver_result.get("module"),
                "fields": driver_result.get("fields", []),
                "counts": driver_result.get("counts", {"total_fields": 0, "sampled": 0}),
                "truncated": truncated,
                "parse_error": driver_result.get("parse_error"),
            }
            runtime_version = driver_result.get("runtime_version", "unknown")
        else:
            # Driver did not produce output (timeout without output, etc.)
            structure = {
                "root_type": None,
                "module": stem,
                "fields": [],
                "counts": {"total_fields": 0, "sampled": 0},
                "truncated": True,
                "parse_error": parse_json_err or "driver produced no output",
            }
            runtime_version = "unknown"
            if not errors:
                errors.append("driver produced no output")

        domain: dict[str, Any] = {
            "compile": {
                "generated_parser": {
                    "path": f"engine/gen/{stem}.py",
                    "sha256": parser_sha256,
                    "size": parser_size,
                },
                "ksc_version": ksc_ver,
            },
            "ksy_identity": {
                "sha256": ksy_src["sha256"],
                "size": ksy_src["size"],
                "path": ksy_src["path"],
            },
            "runtime_version": runtime_version,
            "structure": structure,
        }

        input_identity = {
            "source": bin_src,
            "staged": bin_staged,
        }
        isolation = {
            "launcher": {"path": bwrap_record["path"], "sha256": bwrap_record["sha256"]},
            "profile": _PROFILE,
        }

        # ------------------------------------------------------------------ #
        # Manifest spec (Stage 2 run is the primary recorded tool run)
        # ------------------------------------------------------------------ #
        completeness = "failed" if errors else "complete"
        manifest_spec: dict[str, Any] = {
            "argv": stage2_cmd,
            "completeness": completeness,
            "environment": env_stage2,
            "errors": errors,
            "findings": [],
            "input": {
                "detected_type": "binary/kaitai-struct-parsed",
                "path": "input/binary.bin",
            },
            "isolation_profile": _PROFILE,
            "limitations": limitations,
            "outputs": [
                f"{_SCHEMA}.json",
                "input/struct.ksy",
                "engine/driver.py",
                f"engine/gen/{stem}.py",
                "engine/compile-stdout.txt",
                "engine/compile-stderr.txt",
            ],
            "run": s2_run,
            "schema_version": "analysis-manifest.v1",
            "stderr_path": "engine/stderr.txt",
            "stdout_path": "engine/stdout.txt",
            "tool": {
                "artifacts": [],
                "executable": str(bwrap),
                "name": "kaitai-struct-driver",
                "version": runtime_version,
            },
        }

        # ------------------------------------------------------------------ #
        # Emit evidence (writes JSON + manifest + publishes)
        # ------------------------------------------------------------------ #
        emit_evidence(
            stage=stage,
            schema=_SCHEMA,
            domain=domain,
            input_identity=input_identity,
            isolation=isolation,
            limitations=limitations,
            errors=errors,
            manifest_spec=manifest_spec,
            manifest_cli=args.manifest_cli,
            destination=destination,
            timeout=60,
        )
        stage = None
        return 1 if errors else 0

    except (KaitaiError, AdapterError, ManifestError, OSError) as exc:
        print(f"corroborate-kaitai: {exc}", file=sys.stderr)
        return 2
    except subprocess.SubprocessError as exc:
        print(f"corroborate-kaitai: subprocess error: {exc}", file=sys.stderr)
        return 2
    finally:
        if stage is not None and stage.is_dir():
            shutil.rmtree(stage)


if __name__ == "__main__":
    sys.exit(main())
