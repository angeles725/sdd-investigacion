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
import subprocess, sys, threading, time, uuid
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import docker_common as _dc                                         # noqa: E402
from gate import GateError                                          # noqa: E402

# Re-export: test suite references m._OUTPUT_CAP on this module directly.
_OUTPUT_CAP: int = _dc._OUTPUT_CAP
SCHEMA_VERSION: str = "emba-run.v1"


def _preflight(plan: dict[str, Any]) -> None:
    """Defense-in-depth preflight (gate-authorization.v1 rule 4). GateError → exit 2.
    (a) docker binary; (b) structural argv guard; (c) TOCTOU firmware hash; (e) /tmp/rsdd.
    Step (d) image+RepoDigest is handled by _dc.resolve_digest in evaluate().
    Thin composition: generic checks delegated to docker_common; name kept here so
    the test suite can call m._preflight() directly on this module.
    """
    # (a) docker binary present
    _dc.check_docker_binary()
    # (b) structural argv guard — treat plan as untrusted input
    argv = plan.get("planned_argv")
    if not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
        raise GateError("plan.planned_argv must be a list of strings")
    # EMBA requires --network none (exact behavior preserved)
    _dc.assert_network_policy(argv, "require-none")
    _dc.forbid_privileged(argv)
    # (c) TOCTOU: re-hash firmware; mismatch → refuse
    _dc.verify_firmware_identity(plan)
    # (e) /tmp/rsdd must be a real non-symlink directory
    _dc.verify_rsdd_root()


def _docker_kill(name: str) -> None:
    """Best-effort docker kill + rm -f; always attempts both; never raises."""
    try: subprocess.run(["docker", "kill", name], timeout=10, capture_output=True)
    except Exception: pass
    try: subprocess.run(["docker", "rm", "-f", name], timeout=10, capture_output=True)
    except Exception: pass


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
        image_digest, digest_ref = _dc.resolve_digest(image_tag)
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
        # _dc.make_run_subdir opens /tmp/rsdd with O_NOFOLLOW|O_DIRECTORY so the
        # subdir is anchored to the verified fd; no symlink race between preflight
        # step (e) and mkdir.
        run_uuid = container_name[len("rsdd-"):]  # reuse UUID for container correlation
        run_dir_host = _dc.make_run_subdir(run_uuid)
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
            target=_dc.drain_pipe, args=(proc.stdout, _OUTPUT_CAP, raw_out), daemon=True)
        t_err = threading.Thread(
            target=_dc.drain_pipe, args=(proc.stderr, _OUTPUT_CAP, raw_err), daemon=True)
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

        stdout, stdout_trunc = _dc.cap(raw_out[0])
        stderr, stderr_trunc = _dc.cap(raw_err[0])
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
            "output_files": _dc.output_files(Path(run_dir_host)),
        }
