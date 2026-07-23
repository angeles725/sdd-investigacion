#!/usr/bin/env python3
"""Live QEMU system-mode boot executor — disposable-VM isolation substrate (V1b).
Spawns qemu-system-{arch} in a per-run bwrap subdir; stdout (serial -nographic) captured.
NEVER boots a real VM in CI. Real boot = user's gated manual step.
Selected locally in qemu_plan.py when --allow-exec AND mode==qemu-system.
NEVER in plan_common.select_executor. RSDD_EXEC_EXECUTOR env stub wins (gate.py:113).
"""
from __future__ import annotations
import datetime, os, shutil, signal, stat, subprocess, sys, threading, time, uuid
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import docker_common as _dc    # noqa: E402
import proc_common as _pc      # noqa: E402
from gate import GateError     # noqa: E402

SCHEMA_VERSION: str = "vm-boot-run.v1"
_WALL_GRACE_S: int = 5
_SIGTERM_GRACE_S: int = 5

# V1a containment flags that MUST appear in planned_argv.
_REQUIRED = frozenset({"-nic", "-nodefaults", "-snapshot", "-sandbox", "-accel", "-smp", "--unshare-net"})
# Flags forbidden WHOLESALE (any occurrence → GateError). Includes -net/-netdev so
# -net user,hostfwd=... and -net tap are both refused; the legit plan never emits them.
_FORBIDDEN = frozenset({"-virtfs", "-fsdev", "-enable-kvm", "-runas", "-net", "-netdev"})
# -device values that must never appear (host passthrough / guest-to-host FS vectors).
_DEVICE_DENY_PREFIXES = ("vfio", "virtio-9p")
# Value predicates enforced on EVERY occurrence of each flag (not just the first).
_VALUE_OK = {
    "-nic":     lambda v: v == "none",
    "-accel":   lambda v: v == "tcg",
    "-sandbox": lambda v: v.startswith("on") and "=allow" not in v,
    "-smp":     lambda v: v == "1",
    "-drive":   lambda v: "readonly=on" in v or "snapshot=on" in v,
}


def _argv_after_sep(argv: list[str]) -> list[str]:
    """Return tokens after bwrap '--' separator (the inner qemu command)."""
    try:
        return argv[argv.index("--") + 1:]
    except ValueError:
        return argv


def _resolve_qbin(plan: dict[str, Any], argv: list[str]) -> str | None:
    """Return qemu binary name from plan dict or by scanning argv after '--'.
    Post-preflight the result is guaranteed non-None (preflight rejects missing binary).
    """
    return plan.get("qemu_binary") or next(
        (t for t in _argv_after_sep(argv) if t.startswith("qemu")), None
    )


def _check_argv(argv: list[str]) -> None:
    """Single-pass argv scanner: REQUIRED presence check then per-flag predicates on
    EVERY occurrence. Replaces the old index()-based _check_containment (first-occurrence
    only) and _check_forbidden (missed -net variants, dead 9p token, no -smp bound).

    Scans the FULL argv including the bwrap prefix (same scope as before); a bwrap
    value that collides with a flag name fails closed — acceptable for a
    malware-isolation substrate where a plan dict is untrusted input.
    """
    missing = sorted(_REQUIRED - set(argv))
    if missing:
        raise GateError(f"planned_argv missing required containment flag(s): {missing}")
    for i, tok in enumerate(argv):
        nxt = argv[i + 1] if i + 1 < len(argv) else ""
        if tok in _FORBIDDEN:
            raise GateError(f"planned_argv contains forbidden flag {tok!r}")
        if tok == "-device" and nxt.startswith(_DEVICE_DENY_PREFIXES):
            raise GateError(f"planned_argv -device {nxt!r} forbidden (passthrough/9p refused)")
        rule = _VALUE_OK.get(tok)
        if rule and not rule(nxt):
            raise GateError(f"planned_argv {tok} value {nxt!r} violates containment")


def _preflight(plan: dict[str, Any]) -> None:
    """Defense-in-depth preflight. GateError → exit 2 on any violation."""
    if plan.get("mode") == "qemu-user":
        raise GateError(
            "qemu-user mode uses host-kernel translation — refused; "
            "only qemu-system is bootable in this executor"
        )
    argv = plan.get("planned_argv")
    if not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
        raise GateError("plan.planned_argv must be a list of strings")
    _check_argv(argv)
    # qemu binary on PATH
    qbin = _resolve_qbin(plan, argv)
    if not qbin or shutil.which(qbin) is None:
        raise GateError(f"qemu binary {qbin!r} not found on PATH; install qemu and retry")
    # Kernel target: must exist as a non-symlink regular file
    tgt = plan.get("target", {}).get("path", "")
    if tgt:
        try:
            st = Path(tgt).lstat()
        except OSError as exc:
            raise GateError(f"kernel/target path inaccessible: {exc}") from exc
        if stat.S_ISLNK(st.st_mode):
            raise GateError(f"kernel/target is a symlink (rejected: TOCTOU): {tgt!r}")
        if not stat.S_ISREG(st.st_mode):
            raise GateError(f"kernel/target is not a regular file: {tgt!r}")
    _dc.verify_rsdd_root()


class LiveQemuBootExecutor:
    """Live QEMU system-mode boot executor. Satisfies _HasEvaluate protocol.
    Selected locally in qemu_plan.py; NEVER in plan_common.select_executor.
    """

    def __init__(self, output_dir: Path) -> None:
        self._output_dir = output_dir

    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:  # noqa: C901
        """Boot qemu-system; return vm-boot-run.v1 dict. GateError on preflight fail (exit 2).
        Wall-timeout → labeled outcome 'timeout-killed'; process-TREE reaped via killpg.
        """
        _preflight(plan)
        exec_argv: list[str] = list(plan["planned_argv"])
        lim = plan.get("limits", {})
        wall_s = int(lim.get("wall_seconds", 60))
        # _preflight guarantees binary on PATH; no divergent fallback needed.
        qbin = _resolve_qbin(plan, exec_argv)

        # Per-run subdir (O_NOFOLLOW fd-anchored).
        run_dir = _dc.make_run_subdir(uuid.uuid4().hex)
        serial_log = f"{run_dir}/serial.log"
        # exec_argv == planned_argv (no token mutations); serial_log is a top-level field.
        argv_deltas: list[dict[str, Any]] = []

        raw_out: list[bytes] = [b""]; raw_err: list[bytes] = [b""]
        # Discrete list[str] argv — no shell expansion surface.
        proc = subprocess.Popen(
            exec_argv, start_new_session=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
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
            tgt = plan.get("target", {})
            inputs_r = ([{"path": "kernel", "sha256": tgt["sha256"], "size": tgt["size"]}]
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
                "vm_pre_snapshot": None, "vm_post_snapshot": None,
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
