#!/usr/bin/env python3
"""Live FACT Core executor — runs behind --allow-docker (U-live-docker-fact Unit B2).
Wired locally in fact_plan.py; NEVER in plan_common.select_executor (13 callers).
RSDD_DOCKER_EXECUTOR env stub wins over this executor when set (gate.py precedence).

RESIDUAL RISKS:
  (1) dockerd trust boundary: daemon compromise bypasses internal:true isolation.
  (2) inspect→up digest race ×3: local image may be replaced between inspect and up;
      post-up verification narrows but does not fully close this window.
  (3) service-name constants vs user compose files: post-up verification catches
      unexpected containers but the pre-verification window remains.
  (4) internal:true egress claim relies on override file + post-up check; FACT plugins
      needing egress will degrade silently.
  (5) loopback REST impersonation: any local process can intercept 127.0.0.1.
  (6) down -v = no cross-run DB persistence in v1; each run is ephemeral.
  (7) compose exit codes are less standardised than 'docker run' 125/126/127.
"""
from __future__ import annotations

import hashlib
import json as _json
import os
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any
from urllib import request as _url_req
from urllib.parse import urlparse

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import docker_common as _dc       # noqa: E402
from gate import GateError         # noqa: E402

# Re-exports
OUTPUT_CAP: int = _dc.OUTPUT_CAP
_OUTPUT_CAP: int = _dc._OUTPUT_CAP  # backward-compat alias
SCHEMA_VERSION: str = "fact-run.v1"

# Firmware read cap — plan.firmware.size + 1 byte overflow check; hard ceiling 256 MiB
_FIRMWARE_HARD_CAP: int = 256 * 1024 * 1024

# Polling controls (wall_seconds is the outer deadline)
_POLL_INTERVAL_S: float = 1.0   # sleep between polls (short for tests)
_POLL_CAP_BYTES: int = 64 * 1024         # readiness drain + PUT response cap (tiny by contract)
_ANALYSIS_CAP_BYTES: int = 64 * 1024 * 1024  # analysis body cap: 64 MiB (fits full-plugin results)
_MAX_POLLS: int = 1000            # absolute safety ceiling (wall_seconds wins in practice)

# Loopback-only enforcement (anti-exfiltration)
_LOOPBACK_HOSTS: frozenset[str] = frozenset({"127.0.0.1", "localhost", "::1"})


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _check_loopback(url: str) -> None:
    """Assert --rest-base-url resolves to loopback; GateError otherwise."""
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if host not in _LOOPBACK_HOSTS:
        raise GateError(
            f"--rest-base-url host {host!r} is not loopback (127.0.0.1/localhost); "
            f"non-loopback URLs refused (anti-exfiltration)"
        )


def _read_bounded(resp: Any, cap: int) -> tuple[bytes, bool]:
    """Read HTTP response body in 64 KiB chunks until EOF or cap+1 bytes.

    HTTPResponse.read(amt) can short-read on chunked transfer-encoding, so
    a single read() call is NOT sufficient — we must loop.

    Returns (body_bytes, exceeded_cap).  exceeded_cap is True when the body
    is larger than cap (we read cap+1 bytes and more may follow).
    """
    buf = bytearray()
    limit = cap + 1
    chunk = 65536  # 64 KiB per iteration
    while len(buf) < limit:
        to_read = min(chunk, limit - len(buf))
        data = resp.read(to_read)
        if not data:
            break
        buf.extend(data)
    exceeded = len(buf) > cap
    return bytes(buf), exceeded


def _read_firmware_toctou(plan: dict[str, Any]) -> bytes:
    """Read firmware bytes ONCE via O_NOFOLLOW, bounded by plan.firmware.size + hard cap.

    Hash-of-what-you-send: these exact bytes are PUT to FACT later, fully closing the
    TOCTOU window (no mount race; data in-memory from open() through PUT).

    GateError on:
    - missing plan fields
    - symlink at firmware path (O_NOFOLLOW)
    - size overflow (plan.firmware.size + 1 or _FIRMWARE_HARD_CAP)
    - sha256 mismatch (firmware changed since plan build)
    """
    fw = plan.get("firmware") or {}
    fw_path = fw.get("path", "")
    fw_sha256 = fw.get("sha256", "")
    fw_size_declared = int(fw.get("size", 0))
    if not fw_path or not fw_sha256:
        raise GateError("plan.firmware.path or plan.firmware.sha256 missing (FACT TOCTOU)")

    # Bound: declared size + 1 (overflow detection), ceiling at hard cap
    max_read = min(fw_size_declared + 1, _FIRMWARE_HARD_CAP)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(fw_path, flags)
    except OSError as exc:
        raise GateError(f"FACT TOCTOU: cannot open firmware {fw_path!r}: {exc}") from exc

    try:
        buf = bytearray()
        chunk_size = 65536
        while len(buf) < max_read:
            to_read = min(chunk_size, max_read - len(buf))
            chunk = os.read(fd, to_read)
            if not chunk:
                break
            buf.extend(chunk)
        # Overflow check: if we hit max_read and there's more data, reject
        if len(buf) >= max_read:
            extra = os.read(fd, 1)
            if extra:
                raise GateError(
                    f"FACT TOCTOU: firmware exceeds declared size {fw_size_declared} "
                    f"and/or hard cap {_FIRMWARE_HARD_CAP} bytes; refused"
                )
    except GateError:
        raise
    except OSError as exc:
        raise GateError(f"FACT TOCTOU: I/O error reading firmware: {exc}") from exc
    finally:
        os.close(fd)

    fw_bytes = bytes(buf)
    actual_sha = "sha256:" + hashlib.sha256(fw_bytes).hexdigest()
    if actual_sha != fw_sha256:
        raise GateError(
            f"FACT TOCTOU: firmware sha256 mismatch "
            f"(plan expected={fw_sha256!r}, actual={actual_sha!r}); "
            f"firmware may have been tampered between plan build and execution"
        )
    return fw_bytes


def _write_compose_override(run_dir: str, frontend_ref: str, backend_ref: str, db_ref: str) -> str:
    """Write per-run compose override YAML pinning images to digest refs + internal network.

    The override file is appended as the SECOND -f arg so it takes precedence over the
    user's compose file.  It pins all three service images and sets the default network
    to internal:true (no outbound egress).

    Returns the absolute path to the written override file.  GateError on write failure.
    """
    content = (
        "services:\n"
        f"  frontend:\n"
        f"    image: \"{frontend_ref}\"\n"
        f"  backend:\n"
        f"    image: \"{backend_ref}\"\n"
        f"  db:\n"
        f"    image: \"{db_ref}\"\n"
        "networks:\n"
        "  default:\n"
        "    internal: true\n"
    )
    override_path = os.path.join(run_dir, "fact-override.yml")
    try:
        with open(override_path, "w") as fh:
            fh.write(content)
    except OSError as exc:
        raise GateError(f"failed to write compose override file: {exc}") from exc
    return override_path


def _compose_down(base_argv: list[str]) -> None:
    """Best-effort compose down -v.  NEVER raises.  Keeps full -f args + -p project."""
    try:
        subprocess.run(base_argv + ["down", "-v"], timeout=60, capture_output=True)
    except Exception:
        pass


def _readiness_poll(rest_url: str, deadline: float) -> None:
    """Poll GET {rest_url}/rest/firmware until 2xx or deadline.  GateError on timeout."""
    target = rest_url.rstrip("/") + "/rest/firmware"
    polls = 0
    while time.monotonic() < deadline and polls < _MAX_POLLS:
        polls += 1
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            req = _url_req.Request(target, method="GET")
            with _url_req.urlopen(req, timeout=min(5.0, remaining)) as resp:
                resp.read(_POLL_CAP_BYTES)  # drain bounded; discard
                if resp.status < 400:
                    return  # ready
        except Exception:
            pass
        time.sleep(_POLL_INTERVAL_S)
    raise GateError("FACT REST API did not become ready within wall_seconds (readiness poll)")


def _put_firmware(rest_url: str, fw_bytes: bytes, deadline: float) -> str:
    """PUT firmware bytes to /rest/firmware (never retried).

    Returns the uid from the JSON response.  GateError on HTTP error or bad response.
    """
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise GateError("wall_seconds deadline exceeded before REST PUT firmware")
    target = rest_url.rstrip("/") + "/rest/firmware"
    req = _url_req.Request(target, data=fw_bytes, method="PUT")
    req.add_header("Content-Type", "application/octet-stream")
    try:
        with _url_req.urlopen(req, timeout=min(60.0, remaining)) as resp:
            raw = resp.read(_POLL_CAP_BYTES)
            status = resp.status
    except Exception as exc:
        raise GateError(f"FACT REST PUT /rest/firmware failed: {exc}") from exc
    if status not in (200, 201, 202):
        raise GateError(
            f"FACT REST PUT /rest/firmware returned HTTP {status}; expected 200/201/202"
        )
    try:
        resp_body = _json.loads(raw)
    except Exception as exc:
        raise GateError(f"FACT REST PUT response is not valid JSON: {exc}") from exc
    uid = resp_body.get("uid") or resp_body.get("firmware_uid") or ""
    if not uid:
        raise GateError("FACT REST PUT response missing 'uid' field")
    return str(uid)


def _analysis_poll(rest_url: str, uid: str, deadline: float) -> dict[str, Any]:
    """Poll GET /rest/firmware/{uid} until is_finished or deadline.

    Returns the final analysis JSON body.  GateError on timeout or too many polls.

    Error classification:
    - Connection / HTTP errors (urlopen raises) → retry (service not yet ready).
    - Body > _ANALYSIS_CAP_BYTES → hard GateError (oversized); NEVER retried.
    - Complete 2xx body with invalid JSON → hard GateError (broken server); NEVER
      retried (retrying reproduces the false-timeout masking bug in another form).
    - analysis_status not finished → sleep and retry.
    """
    target = rest_url.rstrip("/") + "/rest/firmware/" + uid
    polls = 0
    while time.monotonic() < deadline and polls < _MAX_POLLS:
        polls += 1
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        req = _url_req.Request(target, method="GET")
        try:
            with _url_req.urlopen(req, timeout=min(5.0, remaining)) as resp:
                raw, exceeded = _read_bounded(resp, _ANALYSIS_CAP_BYTES)
        except Exception:
            # Genuine connection / HTTP error → retry (not-ready)
            time.sleep(_POLL_INTERVAL_S)
            continue
        if exceeded:
            raise GateError(
                f"FACT analysis response exceeds {_ANALYSIS_CAP_BYTES}-byte cap "
                f"(uid={uid!r}); body too large — not retried"
            )
        try:
            body = _json.loads(raw)
        except Exception as exc:
            raise GateError(
                f"FACT analysis response is not valid JSON (uid={uid!r}): {exc}; "
                f"body snippet: {raw[:200]!r}"
            ) from exc
        if not isinstance(body, dict):
            time.sleep(_POLL_INTERVAL_S)
            continue
        astatus = body.get("analysis_status", {})
        if isinstance(astatus, dict):
            if astatus.get("is_finished") or astatus.get("finished"):
                return body
            # continue polling while status is processing/scheduled
        elif astatus in ("done", "finished", "complete"):
            return body
        time.sleep(_POLL_INTERVAL_S)
    raise GateError(
        f"FACT analysis for uid={uid!r} did not complete within wall_seconds (analysis poll)"
    )


def _post_up_verify(
    exec_argv_base: list[str],
    project_name: str,
    resolved_digests: frozenset[str],
    run_dir_host: str,
    fw_path: str,
) -> None:
    """Verify post-up security invariants via compose ps -q + docker inspect.

    Checks:
    - At least one container is running.
    - Each container's image digest is in the pre-resolved digest set.
    - Bind mounts are limited to firmware path and per-run subdir.
    - Volumes are project-scoped (name starts with project_name).
    - GateError on any violation.
    """
    try:
        ps_r = subprocess.run(
            exec_argv_base + ["ps", "-q"],
            capture_output=True, text=True, timeout=15,
        )
    except subprocess.TimeoutExpired:
        raise GateError("post-up verification: compose ps -q timed out")
    if ps_r.returncode != 0:
        raise GateError(
            f"post-up verification: compose ps -q failed (exit {ps_r.returncode})"
        )
    cids = [c.strip() for c in ps_r.stdout.strip().splitlines() if c.strip()]
    if not cids:
        raise GateError("post-up verification: no containers running (compose ps -q empty)")

    for cid in cids:
        try:
            insp_r = subprocess.run(
                ["docker", "inspect", cid],
                capture_output=True, text=True, timeout=15,
            )
        except subprocess.TimeoutExpired:
            raise GateError(f"post-up verification: docker inspect timed out for {cid}")
        if insp_r.returncode != 0:
            raise GateError(f"post-up verification: docker inspect failed for {cid}")
        try:
            info = _json.loads(insp_r.stdout)
        except Exception as exc:
            raise GateError(
                f"post-up verification: docker inspect returned invalid JSON for {cid}: {exc}"
            ) from exc
        if not info or not isinstance(info, list):
            raise GateError(f"post-up verification: docker inspect empty for {cid}")
        c = info[0]

        # Mount containment check
        for mount in (c.get("Mounts") or []):
            mtype = mount.get("Type", "")
            if mtype == "volume":
                vol_name = mount.get("Name", "")
                if vol_name and not vol_name.startswith(project_name):
                    raise GateError(
                        f"post-up verification: container {cid} has volume {vol_name!r} "
                        f"not scoped to project {project_name!r}"
                    )
            elif mtype == "bind":
                src = mount.get("Source", "")
                if not (src == fw_path or src.startswith(run_dir_host)):
                    raise GateError(
                        f"post-up verification: container {cid} has unexpected bind mount "
                        f"{src!r} (only firmware and per-run subdir are allowed)"
                    )

        # Digest membership check: container Image field is a config ID, NOT a repo
        # digest — compare via docker image inspect <ID> → RepoDigests.
        image_id = c.get("Image", "")
        if not image_id:
            raise GateError(
                f"post-up verification: container {cid} has no Image field"
            )
        try:
            img_r = subprocess.run(
                ["docker", "image", "inspect", image_id],
                capture_output=True, text=True, timeout=15,
            )
        except subprocess.TimeoutExpired:
            raise GateError(
                f"post-up verification: docker image inspect timed out for {image_id!r}"
            )
        if img_r.returncode != 0:
            raise GateError(
                f"post-up verification: docker image inspect failed for {image_id!r}"
            )
        try:
            img_info = _json.loads(img_r.stdout)
        except Exception as exc:
            raise GateError(
                f"post-up verification: docker image inspect invalid JSON for "
                f"{image_id!r}: {exc}"
            ) from exc
        if not img_info or not isinstance(img_info, list):
            raise GateError(
                f"post-up verification: docker image inspect empty for {image_id!r}"
            )
        repo_digests: list[str] = img_info[0].get("RepoDigests") or []
        if not repo_digests:
            raise GateError(
                f"post-up verification: image {image_id!r} has no RepoDigests; "
                f"cannot verify digest membership (fail closed)"
            )
        img_digests: set[str] = set()
        for rd in repo_digests:
            if "@sha256:" in rd:
                img_digests.add("sha256:" + rd.split("@sha256:", 1)[1])
        if not img_digests.intersection(resolved_digests):
            raise GateError(
                f"post-up verification: container {cid} image {image_id!r} digest "
                f"not in pre-resolved set; possible image substitution (fail closed)"
            )

    # Network internal check: default network must be internal:true.
    net_name = f"{project_name}_default"
    try:
        net_r = subprocess.run(
            ["docker", "network", "inspect", net_name],
            capture_output=True, text=True, timeout=15,
        )
    except subprocess.TimeoutExpired:
        raise GateError(
            f"post-up verification: docker network inspect timed out for {net_name!r}"
        )
    if net_r.returncode != 0:
        raise GateError(
            f"post-up verification: docker network inspect failed for {net_name!r} "
            f"(exit {net_r.returncode})"
        )
    try:
        net_info = _json.loads(net_r.stdout)
    except Exception as exc:
        raise GateError(
            f"post-up verification: docker network inspect invalid JSON for "
            f"{net_name!r}: {exc}"
        ) from exc
    if not net_info or not isinstance(net_info, list):
        raise GateError(
            f"post-up verification: docker network inspect empty for {net_name!r}"
        )
    if net_info[0].get("Internal") is not True:
        raise GateError(
            f"post-up verification: network {net_name!r} is not internal:true; "
            f"egress isolation not confirmed (fail closed)"
        )


# ---------------------------------------------------------------------------
# LiveFactExecutor
# ---------------------------------------------------------------------------

class LiveFactExecutor:
    """Live FACT Core executor. Satisfies _HasEvaluate protocol.

    Selected locally in fact_plan.py; NEVER wired into plan_common.select_executor.
    Executor resolution order: RSDD_DOCKER_EXECUTOR env stub > this class (gate seam).
    """

    def __init__(
        self,
        output_dir: Path,
        rest_base_url: str = "http://127.0.0.1:9100",
    ) -> None:
        self._output_dir = output_dir
        self._rest_base_url = rest_base_url.rstrip("/")

    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:
        """Run FACT Core via Docker Compose; return fact-run.v1 dict.

        GateError (→ exit 2) on: non-loopback URL, preflight failure,
        image absent locally, TOCTOU mismatch, compose up failure, post-up
        verify failure, REST PUT failure, analysis timeout.

        Three B2 transforms (non-applicable EMBA transforms replaced):
          T1: override-file pinning (replaces argv digest substitution)
          T2: per-run project name fact-<uuid8> (replaces --name injection)
          T3: per-run output subdir via make_run_subdir (same as EMBA)
        """
        # ── Anti-exfiltration guard ────────────────────────────────────────────
        _check_loopback(self._rest_base_url)

        # ── Preflight ─────────────────────────────────────────────────────────
        _dc.check_docker_binary()
        deployment = plan.get("deployment") or {}
        planned_argv = deployment.get("planned_argv") or []
        if not isinstance(planned_argv, list) or not all(
            isinstance(a, str) for a in planned_argv
        ):
            raise GateError("plan.deployment.planned_argv must be a list of strings")
        image_tags = deployment.get("image_tags") or {}
        frontend_tag = image_tags.get("frontend", "")
        backend_tag  = image_tags.get("backend",  "")
        db_tag       = image_tags.get("db",       "")
        if not frontend_tag or not backend_tag or not db_tag:
            raise GateError(
                "plan.deployment.image_tags missing one or more of frontend/backend/db"
            )
        compose_file: str | None = deployment.get("compose_file")
        wall_seconds = int((plan.get("resource_limits") or {}).get("wall_seconds", 7200))

        # ── Global monotonic deadline (hoisted to span ALL phases) ────────────────
        t0       = time.monotonic()
        deadline = t0 + wall_seconds

        # FACT: --network must be ABSENT from compose argv (internal bridge via override)
        _dc.assert_network_policy(planned_argv, "forbid")
        # No --privileged anywhere in planned argv
        _dc.forbid_privileged(planned_argv)
        # /tmp/rsdd must be a real non-symlink directory
        _dc.verify_rsdd_root()

        # ── Resolve 3 image digests (local inspect, NO pull) ──────────────────
        frontend_digest, frontend_ref = _dc.resolve_digest(frontend_tag)
        backend_digest,  backend_ref  = _dc.resolve_digest(backend_tag)
        db_digest,       db_ref       = _dc.resolve_digest(db_tag)
        resolved_digests = frozenset({frontend_digest, backend_digest, db_digest})

        # ── FACT TOCTOU: read firmware bytes once (hash-of-what-you-send) ─────
        fw_bytes = _read_firmware_toctou(plan)
        fw_path = (plan.get("firmware") or {}).get("path", "")

        # ── T2: per-run project name + T3: per-run output subdir ──────────────
        run_uuid_full = uuid.uuid4().hex
        run_uuid8     = run_uuid_full[:8]
        project_name  = f"fact-{run_uuid8}"
        run_dir_host  = _dc.make_run_subdir(run_uuid_full)

        # ── T1: write compose override file pinning images + internal network ──
        override_path = _write_compose_override(
            run_dir_host, frontend_ref, backend_ref, db_ref
        )

        # ── Build compose argv ─────────────────────────────────────────────────
        exec_argv_base = ["docker", "compose", "-p", project_name]
        if compose_file:
            exec_argv_base += ["-f", compose_file]
        exec_argv_base += ["-f", override_path]
        exec_argv_up = exec_argv_base + ["up", "-d"]

        raw_out: list[bytes] = [b""]
        raw_err: list[bytes] = [b""]

        # Spawn compose up; teardown is in finally from this point forward.
        proc = subprocess.Popen(
            exec_argv_up,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            t_out = threading.Thread(
                target=_dc.drain_pipe,
                args=(proc.stdout, _dc.OUTPUT_CAP, raw_out),
                daemon=True,
            )
            t_err = threading.Thread(
                target=_dc.drain_pipe,
                args=(proc.stderr, _dc.OUTPUT_CAP, raw_err),
                daemon=True,
            )
            t_out.start()
            t_err.start()

            # Wait for compose up with remaining wall budget
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                proc.kill()
                raise GateError("wall_seconds deadline exceeded before compose up completed")
            try:
                exit_code = proc.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                proc.kill()
                raise GateError(
                    f"FACT compose up exceeded wall_seconds={wall_seconds}; killed"
                )
            finally:
                t_out.join(timeout=5)
                t_err.join(timeout=5)

            if exit_code != 0:
                up_err_snippet = _dc.cap(raw_err[0])[0][:300]
                raise GateError(
                    f"FACT compose up failed (exit {exit_code}): {up_err_snippet}"
                )

            # ── Post-up verification ───────────────────────────────────────────
            _post_up_verify(
                exec_argv_base, project_name,
                resolved_digests, run_dir_host, fw_path,
            )

            # ── Readiness poll ─────────────────────────────────────────────────
            _readiness_poll(self._rest_base_url, deadline)

            # ── REST PUT firmware (never retried) ──────────────────────────────
            uid = _put_firmware(self._rest_base_url, fw_bytes, deadline)

            # ── Analysis poll ──────────────────────────────────────────────────
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise GateError("wall_seconds deadline exceeded before analysis poll")
            analysis_result = _analysis_poll(self._rest_base_url, uid, deadline)

            # ── Collect output files from per-run dir ──────────────────────────
            duration_s = time.monotonic() - t0
            up_stdout, up_stdout_trunc = _dc.cap(raw_out[0])
            up_stderr, up_stderr_trunc = _dc.cap(raw_err[0])

            return {
                "schema_version": SCHEMA_VERSION,
                "executed": True,
                "project_name": project_name,
                "exec_argv_up": exec_argv_up,
                "argv_deltas": [
                    {"transform": "project-name",    "value": project_name},
                    {"transform": "override-pinning", "override_file": override_path},
                    {"transform": "output-subdir",    "run_dir": run_dir_host},
                ],
                "image_digests": {
                    "frontend": frontend_digest,
                    "backend":  backend_digest,
                    "db":       db_digest,
                },
                "firmware_uid": uid,
                "analysis_result": analysis_result,
                "duration_s": round(duration_s, 3),
                "up_stdout": up_stdout,
                "up_stderr": up_stderr,
                "up_stdout_truncated": up_stdout_trunc,
                "up_stderr_truncated": up_stderr_trunc,
                "output_files": _dc.output_files(Path(run_dir_host)),
            }

        finally:
            _compose_down(exec_argv_base)
