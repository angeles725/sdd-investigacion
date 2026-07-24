#!/usr/bin/env python3
"""Shared VM boot engine — Popen + wall timeout + guaranteed process-tree reap + receipt build.

Extracted from qemu_exec.LiveQemuBootExecutor.evaluate (D0 refactor).
Shared by LiveQemuBootExecutor (snapshot_hook=None) and future DetonateVmExecutor /
TraceVmExecutor (snapshot_hook computes scratch-disk sha256 pre-boot and post-teardown).

This module is OFFLINE: no real QEMU is launched; the fake shim in tests/ stubs the
binary.  Real VM boot is the user's gated manual step (never automated in CI).
"""
from __future__ import annotations
import datetime, shutil, signal, subprocess, sys, threading, time, uuid
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import docker_common as _dc   # noqa: E402
import proc_common as _pc     # noqa: E402

SCHEMA_VERSION: str = "vm-boot-run.v1"
_WALL_GRACE_S: int = 5
_SIGTERM_GRACE_S: int = 5


def _argv_after_sep(argv: list[str]) -> list[str]:
    """Return tokens after bwrap '--' separator (the inner qemu command)."""
    try:
        return argv[argv.index("--") + 1:]
    except ValueError:
        return argv


def resolve_qbin(plan: dict[str, Any], argv: list[str]) -> str | None:
    """Return qemu binary name from plan dict or by scanning argv after '--'.
    Post-preflight the result is guaranteed non-None (preflight rejects missing binary).
    """
    return plan.get("qemu_binary") or next(
        (t for t in _argv_after_sep(argv) if t.startswith("qemu")), None
    )


def run_vm(
    plan: dict[str, Any],
    *,
    preflight: Any,
    snapshot_hook: Any = None,
    pre_boot: Any = None,
) -> dict[str, Any]:
    """Boot a QEMU VM; return vm-boot-run.v1 evidence dict.

    Parameters
    ----------
    plan:
        vm-plan dict.  Must include ``planned_argv`` (list[str]) and ``limits`` sub-dict.
    preflight:
        Caller-supplied validation callable ``(plan) -> None``.  GateError from preflight
        propagates unchanged (→ exit 2 at the CLI boundary).
    snapshot_hook:
        Optional callable ``(phase: str, run_dir: str) -> {sha256: str}``.
        ``phase="pre"`` is called AFTER run_dir is created and pre_boot runs, BEFORE Popen.
        ``phase="post"`` is called INSIDE the guaranteed teardown region (finally block).
        Hash errors are caught by the internal ``_safe_snapshot`` helper and returned as
        ``None`` with a stderr WARNING — they NEVER raise-through or discard evidence.
        When ``None`` (V1b / LiveQemuBootExecutor behaviour), ``vm_pre_snapshot`` and
        ``vm_post_snapshot`` in the receipt remain ``None`` (byte-identical to D0).
    pre_boot:
        Optional callable ``(run_dir: str, exec_argv: list[str]) -> list[str]``.
        Called AFTER run_dir is created and AFTER preflight, BEFORE the pre-snapshot
        and Popen.  Returns the (possibly substituted) exec_argv.  The callback may
        create files in run_dir (e.g. scratch.img) so they appear in output_files()
        and are hashed by snapshot_hook.  When ``None``, exec_argv is unchanged.
    """
    preflight(plan)
    exec_argv: list[str] = list(plan["planned_argv"])
    lim = plan.get("limits", {})
    wall_s = int(lim.get("wall_seconds", 60))
    # Post-preflight: qbin is guaranteed non-None and on PATH.
    qbin = resolve_qbin(plan, exec_argv)

    # Per-run subdir (O_NOFOLLOW fd-anchored) — the SINGLE run_dir for this call.
    run_dir = _dc.make_run_subdir(uuid.uuid4().hex)
    serial_log = f"{run_dir}/serial.log"
    argv_deltas: list[dict[str, Any]] = []

    # INV-5: reap run_dir on any exception raised BEFORE Popen succeeds.
    # Once Popen returns, the existing try/finally below owns teardown and
    # intentionally retains run_dir as evidence (see detonate-run.v1.md §run_dir).
    try:
        # pre_boot seam: caller may create files (e.g. scratch.img) and substitute
        # tokens in exec_argv.  Runs BEFORE the pre-snapshot so created files are hashed.
        if pre_boot is not None:
            exec_argv = pre_boot(run_dir, exec_argv)

        # Fail-soft snapshot helper: hash errors → None + stderr WARNING, NEVER raise-through.
        def _safe_snapshot(phase: str, _run_dir: str) -> "dict[str, str] | None":
            if snapshot_hook is None:
                return None
            try:
                return snapshot_hook(phase, _run_dir)
            except Exception as exc:
                print(
                    f"WARNING: vm {phase}-snapshot hash failed (non-fatal): {exc}",
                    file=sys.stderr,
                )
                return None

        # Pre-boot snapshot seam (D2: hash scratch disk before boot; D0/boot: None).
        pre_snap: dict[str, str] | None = _safe_snapshot("pre", run_dir)

        post_snap: dict[str, str] | None = None
        raw_out: list[bytes] = [b""]; raw_err: list[bytes] = [b""]
        # Discrete list[str] argv — no shell expansion surface.
        proc = subprocess.Popen(
            exec_argv, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except BaseException:
        shutil.rmtree(run_dir, ignore_errors=True)
        try:
            if Path(run_dir).exists():
                print(f"WARNING: run_dir reap incomplete: {run_dir}", file=sys.stderr)
        except Exception:
            pass
        raise
    t_out = t_err = None
    t0 = time.monotonic(); t_start = datetime.datetime.utcnow()
    timed_out = False; exit_code: int | None = None

    try:
        t_out = threading.Thread(
            target=_dc.drain_pipe, args=(proc.stdout, _dc.OUTPUT_CAP, raw_out), daemon=True)
        t_err = threading.Thread(
            target=_dc.drain_pipe, args=(proc.stderr, _dc.OUTPUT_CAP, raw_err), daemon=True)
        t_out.start(); t_err.start()
        try:
            exit_code = proc.wait(timeout=wall_s + _WALL_GRACE_S)
        except subprocess.TimeoutExpired:
            timed_out = True
    finally:
        # GUARANTEED process-TREE teardown on EVERY exit path including BaseException.
        _pc.reap_process_tree(proc, grace_s=_SIGTERM_GRACE_S, use_group=True)
        for t in (t_out, t_err):
            if t is not None and t.ident is not None:
                t.join(timeout=5)
        # Post-teardown snapshot INSIDE the guaranteed region so it runs on timeout
        # and BaseException paths.  Fail-soft: hash error → post_snap=None + WARNING;
        # serial_log / pre_snap / outcome are NEVER discarded by a failing post-hash.
        post_snap = _safe_snapshot("post", run_dir)

    t_end = datetime.datetime.utcnow()
    duration_s = time.monotonic() - t0
    if exit_code is None:
        exit_code = proc.poll()

    stdout, stdout_trunc = _dc.cap(raw_out[0])
    stderr, stderr_trunc = _dc.cap(raw_err[0])

    # Save serial console (stdout under -nographic) to run_dir.
    try:
        with open(serial_log, "wb") as f:
            f.write(raw_out[0][:_dc.OUTPUT_CAP])
    except OSError:
        pass

    outcome = ("timeout-killed" if timed_out
               else ("success" if (exit_code is not None and exit_code == 0) else "boot-failure"))

    # Build vm-run-receipt.v1 (best-effort; failure is non-fatal).
    out_files = _dc.output_files(Path(run_dir))
    receipt_identity: str | None = None
    det_identity: str | None = None
    try:
        import vm_receipt as _vr, vm_plan as _vp
        from adapter_core import identity as _fi
        qbin_path = shutil.which(qbin) or qbin
        try: _, _, qbin_sha = _fi(Path(qbin_path))
        except Exception: qbin_sha = "sha256:" + "0" * 64
        try:
            _vr2 = subprocess.run([qbin_path, "--version"],
                                  capture_output=True, timeout=5)
            qbin_ver = _vr2.stdout.decode("utf-8", errors="replace").split("\n")[0].strip() or "unknown"
        except Exception:
            qbin_ver = "unknown"
        # F1 fix: detonate plans store the sample under "sample" (not "target").
        # Trace/boot plans use "target". Fall back to "sample" so inputs[] is
        # always populated, cryptographically binding the receipt to the input.
        _tgt = plan.get("target")
        _smp = plan.get("sample")
        tgt = _tgt or _smp or {}
        label = "kernel" if _tgt else "sample"
        inputs_r = ([{"path": label, "sha256": tgt["sha256"], "size": tgt["size"]}]
                    if tgt.get("sha256") and tgt.get("size") is not None else [])
        outputs_r = [{"path": Path(f["path"]).name, "sha256": f["sha256"], "size": f["size"]}
                     for f in out_files]
        total_out = sum(f["size"] for f in out_files)
        obs_wall = round(duration_s, 3)
        es = ({"exit_code": None, "signal": int(signal.SIGKILL)} if timed_out
              else ({"exit_code": exit_code, "signal": None} if (exit_code or 0) >= 0
                    else {"exit_code": None, "signal": -(exit_code or -9)}))
        spec = {
            "schema_version": "vm-run-receipt.v1",
            "tool": {"argv": exec_argv, "name": qbin, "sha256": qbin_sha, "version": qbin_ver},
            "limits": {"cpu_seconds": int(lim.get("cpu_seconds", 30)),
                       "mem_bytes": int(lim.get("mem_bytes", 256 << 20)),
                       "wall_seconds": wall_s,
                       "output_bytes": int(lim.get("output_bytes", 128 << 20))},
            "vm_pre_snapshot": pre_snap, "vm_post_snapshot": post_snap,
            "inputs": inputs_r, "outputs": outputs_r, "exit_status": es,
            "environment": {},
            "observed": {"cpu_seconds_measured": 0.0, "mem_bytes_peak": 0,
                         "wall_seconds_measured": obs_wall,
                         "wall_started_at": t_start.strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z",
                         "wall_ended_at": t_end.strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"},
        }
        receipt = _vr.build_receipt(spec)
        receipt_identity = receipt["identity"]
        from adapter_core import canonical_bytes as _cb
        try:
            with open(f"{run_dir}/vm-run-receipt.v1.json", "wb") as f:
                f.write(_cb(receipt))
        except Exception:
            pass
        det_spec = {
            "schema_version": "vm-determinism.v1",
            "receipt_identity": receipt_identity,
            "seed": 0, "clock": {"mode": "host", "epoch": None},
            "limits_conformance": {"cpu_within": False, "mem_within": False,
                                   "wall_within": obs_wall <= wall_s,
                                   "output_within": total_out <= int(lim.get("output_bytes", 128 << 20))},
            "reproducible": {"basis": "unverified", "replicate_identity": None},
        }
        det = _vp.build_determinism(det_spec)
        det_identity = det["identity"]
    except ImportError:
        pass  # optional module: vm_receipt/vm_plan/adapter_core importable only via CLI entry-point
    except Exception as exc:
        # Non-fatal: live malware-boot evidence must survive a receipt build bug.
        print(f"WARNING: vm-run-receipt build failed (non-fatal): {exc}", file=sys.stderr)

    ev: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION, "executed": True, "outcome": outcome,
        "exec_argv": exec_argv, "argv_deltas": argv_deltas,
        "exit_code": exit_code if not timed_out else None,
        "exit_reason": "timeout" if timed_out else None,
        "duration_s": round(duration_s, 3), "serial_log": serial_log,
        "stdout": stdout, "stderr": stderr,
        "stdout_truncated": stdout_trunc, "stderr_truncated": stderr_trunc,
        "output_files": out_files,
    }
    if receipt_identity:
        ev["vm_receipt_identity"] = receipt_identity
    if det_identity:
        ev["vm_determinism_identity"] = det_identity
    return ev
