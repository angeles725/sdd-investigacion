#!/usr/bin/env python3
"""Live Docker executor for EMBA — runs behind --allow-docker (U-live-docker-emba).
Wired locally in emba_plan.py; NEVER in plan_common.select_executor (13 callers).
RSDD_DOCKER_EXECUTOR env stub wins over this executor when set (gate.py precedence).
RESIDUAL RISKS: (1) dockerd trust boundary bypasses --network=none isolation on daemon
compromise; (2) EMBA without --privileged gives partial results; (3) per-run
/tmp/rsdd/rsdd-<uuid> subdirs largely resolve concurrent-run collision; daemon-side
mount-path TOCTOU remains inside the documented dockerd trust boundary; (4) digest
resolved at exec time (not user-pinned), local image replacement race possible between
inspect and run; (5) docker exit 127 is indistinguishable between EMBA internal
"command not found" and container startup failure — both map to GateError (exit 2).
"""
from __future__ import annotations
import json, os, shutil, stat, subprocess, sys, threading, time, uuid
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from adapter_core import AdapterError, identity as _file_identity  # noqa: E402
from gate import GateError                                          # noqa: E402
from plan_common import reject_mount_delimiters                     # noqa: E402

_OUTPUT_CAP: int = 1 * 1024 * 1024  # ~1 MiB stdout/stderr cap
SCHEMA_VERSION: str = "emba-run.v1"


def _preflight(plan: dict[str, Any]) -> None:
    """Defense-in-depth preflight (gate-authorization.v1 rule 4). GateError → exit 2.
    (a) docker binary; (b) structural argv guard; (c) TOCTOU firmware hash; (e) /tmp/rsdd.
    Step (d) image+RepoDigest is handled by _resolve_digest in evaluate().
    """
    # (a) docker binary present
    if shutil.which("docker") is None:
        raise GateError("docker not found on PATH; install docker and retry")
    # (b) structural argv guard — treat plan as untrusted input
    argv = plan.get("planned_argv")
    if not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
        raise GateError("plan.planned_argv must be a list of strings")
    try:
        ni = argv.index("--network")
        if ni + 1 >= len(argv) or argv[ni + 1] != "none":
            raise GateError("plan.planned_argv --network value must be 'none'")
    except ValueError:
        raise GateError("plan.planned_argv is missing --network none (required)")
    if "--privileged" in argv:
        raise GateError("plan.planned_argv contains --privileged; refused by live executor")
    # (c) TOCTOU: re-hash firmware; mismatch → refuse
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
        raise GateError(f"TOCTOU: firmware sha256 changed (expected={fw_sha!r}, got={actual!r})")
    # (e) /tmp/rsdd must be a real non-symlink directory
    try:
        st = Path("/tmp/rsdd").lstat()
    except OSError as exc:
        raise GateError(f"/tmp/rsdd inaccessible: {exc}") from exc
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode):
        raise GateError("/tmp/rsdd must be a real non-symlink directory")


def _resolve_digest(image_tag: str) -> tuple[str, str]:
    """Preflight step (d): return (sha256:..., repo@sha256:...) via local inspect.
    GateError if absent or no RepoDigest. Never pulls; fails closed.
    """
    try:
        r = subprocess.run(["docker", "image", "inspect", image_tag],
                           capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        raise GateError(f"docker image inspect timed out for {image_tag!r}")
    if r.returncode != 0:
        raise GateError(f"image {image_tag!r} not found locally — pull manually (no network during run)")
    try:
        info = json.loads(r.stdout)
    except json.JSONDecodeError as exc:
        raise GateError(f"docker image inspect returned invalid JSON: {exc}") from exc
    if not info or not isinstance(info, list):
        raise GateError(f"docker image inspect empty result for {image_tag!r}")
    digests: list[str] = (info[0].get("RepoDigests") or [])
    if not digests:
        raise GateError(f"image {image_tag!r} has no RepoDigest; pull manually before running")
    ref = digests[0]
    if "@sha256:" not in ref:
        raise GateError(f"RepoDigest has unexpected format: {ref!r}")
    return "sha256:" + ref.split("@sha256:", 1)[1], ref


def _cap(data: bytes) -> tuple[str, bool]:
    """Decode and cap at _OUTPUT_CAP bytes; return (text, truncated_flag)."""
    if len(data) > _OUTPUT_CAP:
        return data[:_OUTPUT_CAP].decode("utf-8", errors="replace"), True
    return data.decode("utf-8", errors="replace"), False


def _docker_kill(name: str) -> None:
    """Best-effort docker kill + rm -f; always attempts both; never raises."""
    try: subprocess.run(["docker", "kill", name], timeout=10, capture_output=True)
    except Exception: pass
    try: subprocess.run(["docker", "rm", "-f", name], timeout=10, capture_output=True)
    except Exception: pass


def _drain_pipe(pipe: Any, cap_bytes: int, result: list[bytes]) -> None:
    """Daemon reader thread: drains *pipe* in 64 KiB chunks, retaining at most
    cap_bytes+1 bytes. The extra byte lets _cap() detect truncation. Bytes beyond
    the cap are discarded while the pipe is still drained so the child process
    never blocks on a full OS pipe buffer. result[0] is set before the thread exits.
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


def _output_files(output_dir: Path) -> list[dict[str, Any]]:
    """Return sha256+size identity for regular files in output_dir (best-effort)."""
    files: list[dict[str, Any]] = []
    try:
        for p in sorted(output_dir.iterdir()):
            if p.is_file() and not p.is_symlink():
                try:
                    _, sz, sha = _file_identity(p)
                    files.append({"path": str(p), "size": sz, "sha256": sha})
                except Exception: pass
    except Exception: pass
    return files


class LiveDockerExecutor:
    """Live Docker executor for EMBA. Satisfies _HasEvaluate protocol.
    Selected locally in emba_plan.py; NEVER wired into plan_common.select_executor.
    """

    def __init__(self, output_dir: Path) -> None:
        self._output_dir = output_dir

    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:
        """Run EMBA via Docker; return emba-run.v1 dict. GateError → exit 2 on:
        preflight failure, docker exit 125/126/127, or wall-clock timeout
        (proc.kill() first, then best-effort _docker_kill). Three sanctioned transforms:
        (1) digest substitution, (2) --name injection, (3) output-subdir per-run isolation.
        """
        _preflight(plan)
        planned_argv: list[str] = list(plan["planned_argv"])
        image_tag: str = plan["image"]["tag"]
        wall_seconds: int = int(plan["resource_limits"]["wall_seconds"])

        # Transform 1: tag → repo@sha256:digest (preflight step d).
        image_digest, digest_ref = _resolve_digest(image_tag)
        exec_argv = [digest_ref if tok == image_tag else tok for tok in planned_argv]

        # Transform 2: inject --name rsdd-<uuid> after 'docker run'.
        if len(exec_argv) < 2 or exec_argv[0] != "docker" or exec_argv[1] != "run":
            raise GateError("planned_argv does not begin with 'docker run'")
        container_name = f"rsdd-{uuid.uuid4().hex}"
        exec_argv = exec_argv[:2] + ["--name", container_name] + exec_argv[2:]

        argv_deltas: list[dict[str, str]] = [
            {"transform": "image-digest", "from": image_tag, "to": digest_ref},
            {"transform": "inject-name", "value": container_name},
        ]

        # Transform 3: per-run output subdir — closes TOCTOU on mount source and
        # fixes output_files to scan the directory EMBA actually writes into.
        # Open /tmp/rsdd with O_NOFOLLOW|O_DIRECTORY so the subdir is anchored to
        # the verified fd; no symlink race between preflight (e) and mkdir.
        run_uuid = container_name[len("rsdd-"):]  # reuse UUID for container correlation
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
        run_dir_host = f"/tmp/rsdd/rsdd-{run_uuid}"
        old_mount = "/tmp/rsdd:/tmp/rsdd"
        new_mount = f"{run_dir_host}:/tmp/rsdd"
        exec_argv = [new_mount if tok == old_mount else tok for tok in exec_argv]
        argv_deltas.append({"transform": "output-subdir", "from": old_mount, "to": new_mount})

        # Bounded streaming read: one daemon thread per pipe retains at most
        # _OUTPUT_CAP+1 bytes and drains the rest so the child never blocks.
        raw_out: list[bytes] = [b""]
        raw_err: list[bytes] = [b""]
        proc = subprocess.Popen(exec_argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        t_out = threading.Thread(
            target=_drain_pipe, args=(proc.stdout, _OUTPUT_CAP, raw_out), daemon=True)
        t_err = threading.Thread(
            target=_drain_pipe, args=(proc.stderr, _OUTPUT_CAP, raw_err), daemon=True)
        t_out.start(); t_err.start()

        t0 = time.monotonic()
        timed_out = False
        exit_code: int = -1

        try:
            exit_code = proc.wait(timeout=wall_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            proc.kill()                    # reap subprocess promptly FIRST
            _docker_kill(container_name)   # then best-effort container cleanup

        t_out.join(timeout=5)
        t_err.join(timeout=5)
        duration_s = time.monotonic() - t0

        if timed_out:
            raise GateError(f"EMBA {container_name!r} exceeded wall_seconds={wall_seconds}; killed")
        if exit_code in (125, 126, 127):
            raise GateError(f"docker infrastructure error (exit {exit_code}) for {container_name!r}")

        stdout, stdout_trunc = _cap(raw_out[0])
        stderr, stderr_trunc = _cap(raw_err[0])
        return {
            "schema_version": SCHEMA_VERSION,
            "executed": True,
            "exec_argv": exec_argv,
            "argv_deltas": argv_deltas,
            "image_digest": image_digest,
            "exit_code": exit_code,
            "duration_s": round(duration_s, 3),
            "stdout": stdout, "stderr": stderr,
            "stdout_truncated": stdout_trunc, "stderr_truncated": stderr_trunc,
            "output_files": _output_files(Path(run_dir_host)),
        }
