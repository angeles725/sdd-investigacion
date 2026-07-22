#!/usr/bin/env python3
"""Generic Docker helpers shared across live-executor adapters (EMBA, FACT, …).

This module contains the adapter-agnostic primitives extracted from docker_exec.py
(Unit B1 refactor — resolves deferred 4R Readability finding).  Callers import
from here; they must not import directly from each other.

Dependency direction: docker_common → gate, adapter_core, plan_common (never reverse).
"""
from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from adapter_core import AdapterError, identity as _file_identity  # noqa: E402
from gate import GateError                                          # noqa: E402
from plan_common import reject_mount_delimiters                     # noqa: E402

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_OUTPUT_CAP: int = 1 * 1024 * 1024  # ~1 MiB stdout/stderr cap per stream (source of truth)


# ---------------------------------------------------------------------------
# Binary / capability guards
# ---------------------------------------------------------------------------

def check_docker_binary() -> None:
    """(a) Verify docker binary is present on PATH; GateError otherwise."""
    if shutil.which("docker") is None:
        raise GateError("docker not found on PATH; install docker and retry")


def forbid_privileged(argv: list[str]) -> None:
    """Reject --privileged in argv; GateError if present."""
    if "--privileged" in argv:
        raise GateError("plan.planned_argv contains --privileged; refused by live executor")


def assert_network_policy(argv: list[str], mode: str) -> None:
    """Enforce network isolation policy on planned_argv.

    mode="require-none"  EMBA: '--network none' must be present (exact current behavior).
    mode="forbid"        FACT: '--network' must be absent entirely.

    GateError on violation; ValueError on unknown mode.
    """
    if mode == "require-none":
        try:
            ni = argv.index("--network")
            if ni + 1 >= len(argv) or argv[ni + 1] != "none":
                raise GateError("plan.planned_argv --network value must be 'none'")
        except ValueError:
            raise GateError("plan.planned_argv is missing --network none (required)")
    elif mode == "forbid":
        if "--network" in argv:
            raise GateError(
                "plan.planned_argv contains --network; forbidden for this executor"
            )
    else:
        raise ValueError(f"unknown assert_network_policy mode: {mode!r}")


# ---------------------------------------------------------------------------
# Image digest resolution
# ---------------------------------------------------------------------------

def resolve_digest(image_tag: str) -> tuple[str, str]:
    """Return (sha256:…, repo@sha256:…) via local docker image inspect.

    GateError if the image is absent locally or has no RepoDigest.
    Never pulls; fails closed.
    """
    try:
        r = subprocess.run(
            ["docker", "image", "inspect", image_tag],
            capture_output=True, text=True, timeout=30,
        )
    except subprocess.TimeoutExpired:
        raise GateError(f"docker image inspect timed out for {image_tag!r}")
    if r.returncode != 0:
        raise GateError(
            f"image {image_tag!r} not found locally — pull manually (no network during run)"
        )
    try:
        info = json.loads(r.stdout)
    except json.JSONDecodeError as exc:
        raise GateError(f"docker image inspect returned invalid JSON: {exc}") from exc
    if not info or not isinstance(info, list):
        raise GateError(f"docker image inspect empty result for {image_tag!r}")
    digests: list[str] = info[0].get("RepoDigests") or []
    if not digests:
        raise GateError(
            f"image {image_tag!r} has no RepoDigest; pull manually before running"
        )
    ref = digests[0]
    if "@sha256:" not in ref:
        raise GateError(f"RepoDigest has unexpected format: {ref!r}")
    return "sha256:" + ref.split("@sha256:", 1)[1], ref


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def cap(data: bytes) -> tuple[str, bool]:
    """Decode and cap at _OUTPUT_CAP bytes; return (text, truncated_flag)."""
    if len(data) > _OUTPUT_CAP:
        return data[:_OUTPUT_CAP].decode("utf-8", errors="replace"), True
    return data.decode("utf-8", errors="replace"), False


def drain_pipe(pipe: Any, cap_bytes: int, result: list[bytes]) -> None:
    """Daemon reader thread: drain *pipe* in 64 KiB chunks, retaining at most
    cap_bytes+1 bytes.  The extra byte lets cap() detect truncation.  Bytes
    beyond the cap are discarded while the pipe is still drained so the child
    process never blocks on a full OS pipe buffer.
    result[0] is set before the thread exits.
    """
    buf = bytearray()
    chunk = 65536  # 64 KiB
    try:
        while True:
            data = pipe.read(chunk)
            if not data:
                break
            remaining = cap_bytes + 1 - len(buf)
            if remaining > 0:
                buf.extend(data[:remaining])
            # discard the rest but keep draining
    except Exception:
        pass
    finally:
        try:
            pipe.close()
        except Exception:
            pass
    result[0] = bytes(buf)


def output_files(output_dir: Path) -> list[dict[str, Any]]:
    """Return sha256+size identity for regular files in output_dir (best-effort)."""
    files: list[dict[str, Any]] = []
    try:
        for p in sorted(output_dir.iterdir()):
            if p.is_file() and not p.is_symlink():
                try:
                    _, sz, sha = _file_identity(p)
                    files.append({"path": str(p), "size": sz, "sha256": sha})
                except Exception:
                    pass
    except Exception:
        pass
    return files


# ---------------------------------------------------------------------------
# /tmp/rsdd isolation helpers
# ---------------------------------------------------------------------------

def verify_rsdd_root() -> None:
    """/tmp/rsdd must exist as a real (non-symlink) directory; GateError otherwise."""
    try:
        st = Path("/tmp/rsdd").lstat()
    except OSError as exc:
        raise GateError(f"/tmp/rsdd inaccessible: {exc}") from exc
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        raise GateError("/tmp/rsdd must be a real non-symlink directory")


def make_run_subdir(run_uuid: str) -> str:
    """Create /tmp/rsdd/rsdd-{run_uuid} anchored via O_NOFOLLOW|O_DIRECTORY.

    Opening /tmp/rsdd with these flags means the subdir creation is bound to the
    verified directory fd, eliminating any symlink race between verify_rsdd_root()
    and mkdir.  UUID collision is astronomically unlikely; treated as safe to proceed.

    Returns the host path of the created subdir.  GateError on OS failure.
    """
    _O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
    _O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
    try:
        rsdd_fd = os.open("/tmp/rsdd", os.O_RDONLY | _O_NOFOLLOW | _O_DIRECTORY)
    except OSError as exc:
        raise GateError(f"failed to open /tmp/rsdd for per-run subdir: {exc}") from exc
    try:
        try:
            os.mkdir(f"rsdd-{run_uuid}", 0o700, dir_fd=rsdd_fd)
        except FileExistsError:
            pass  # UUID collision is astronomically unlikely; safe to proceed
        except OSError as exc:
            raise GateError(f"failed to create per-run output subdir: {exc}") from exc
    finally:
        os.close(rsdd_fd)
    return f"/tmp/rsdd/rsdd-{run_uuid}"


# ---------------------------------------------------------------------------
# Firmware identity (TOCTOU guard)
# ---------------------------------------------------------------------------

def verify_firmware_identity(plan: dict[str, Any]) -> None:
    """(c) TOCTOU: re-hash firmware at plan['firmware']['path'] and compare to
    plan['firmware']['sha256'].  GateError on mismatch or missing fields.

    Generic over plan shape; both EMBA and FACT plans carry the same firmware
    sub-dict, so this check is shared without modification.
    """
    fw = plan.get("firmware") or {}
    fw_path, fw_sha = fw.get("path", ""), fw.get("sha256", "")
    if not fw_path or not fw_sha:
        raise GateError("plan.firmware.path or plan.firmware.sha256 missing")
    reject_mount_delimiters(os.path.realpath(fw_path), "firmware path (TOCTOU)", GateError)
    try:
        _, _, actual = _file_identity(Path(fw_path))
    except AdapterError as exc:
        raise GateError(f"TOCTOU firmware re-hash failed: {exc}") from exc
    if actual != fw_sha:
        raise GateError(
            f"TOCTOU: firmware sha256 changed (expected={fw_sha!r}, got={actual!r})"
        )
