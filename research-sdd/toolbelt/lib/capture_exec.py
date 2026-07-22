#!/usr/bin/env python3
"""Live capture executor for --allow-live-capture (C1 only).
Spawns dumpcap (Wireshark's privilege-separated capture engine) into a per-run
subdir under /tmp/rsdd. Honours the planned_argv from capture_plan.py; only
two argv transforms: (1) -w rewrite to per-run subdir, (2) -a filesize: cap
addition. Bounded by: dumpcap -c/-a duration:, the added -a filesize:, and an
independent client-side wall deadline (duration + grace).

RESIDUAL RISKS: root/CAP_NET_RAW operator prerequisite (setcap cap_net_raw+ep,
never sudo); shared-host capture observes other tenants' traffic (RSDD_CAPTURE_IFACES
allowlist scopes interface, not traffic content); BPF over-breadth not semantically
enforceable (dumpcap compiles it and fails closed on invalid syntax — discrete argv
token, no injection); iface-rename TOCTOU between allowlist check and open (minor,
documented); partial pcap on wall-timeout is expected valid output, not an error.

Wired locally in capture_plan.py. NEVER in plan_common.select_executor.
RSDD_LIVE_CAPTURE_EXECUTOR env stub wins inside gate.py when set (seam priority).
"""
from __future__ import annotations
import os, shutil, signal, subprocess, sys, threading, time, uuid
from pathlib import Path
from typing import Any

_HERE = Path(__file__).parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import docker_common as _dc
from capture_analyze import analyze_pcap  # C2: offline pcap corroboration handoff
from gate import GateError

SCHEMA_VERSION: str = "capture-run.v1"
_WALL_GRACE_S: int = 5      # client wall = plan duration + this grace
_SIGTERM_GRACE_S: int = 5   # wait between SIGTERM and SIGKILL
_FILESIZE_KB_MAX: int = 524288  # 512 MiB hard ceiling (forward-compatible)


def _filesize_kb(packet_count: int, snaplen: int) -> int:
    """Upper-bound file size in kB for dumpcap -a filesize: (×1000, not KiB).

    Accounts for 24-byte pcap global header and 16-byte per-record header.
    Capped at _FILESIZE_KB_MAX (512 MiB). Defaults (10000×65535) exceed cap by design.
    """
    raw = (24 + packet_count * (snaplen + 16)) // 1000 + 1
    return min(raw, _FILESIZE_KB_MAX)


def _reap(proc: subprocess.Popen) -> None:  # type: ignore[type-arg]
    """Best-effort SIGTERM→SIGKILL reap. Never raises. No-op if proc already exited."""
    if proc.poll() is not None:
        return
    try:
        proc.send_signal(signal.SIGTERM)
    except Exception:
        pass
    try:
        proc.wait(timeout=_SIGTERM_GRACE_S)
    except Exception:
        pass
    finally:
        try:
            proc.kill()
        except Exception:
            pass
    try:
        proc.wait(timeout=5)
    except Exception:
        pass


# ---------------------------------------------------------------------------
# Preflight helpers (public for unit tests)
# ---------------------------------------------------------------------------

def check_dumpcap_privilege() -> None:
    """(a) Verify dumpcap present + has capture privilege via -D probe. GateError otherwise."""
    if shutil.which("dumpcap") is None:
        raise GateError("dumpcap not found on PATH; install Wireshark/dumpcap and retry")
    try:
        r = subprocess.run(["dumpcap", "-D"], capture_output=True, timeout=10)
    except subprocess.TimeoutExpired:
        raise GateError("dumpcap -D timed out; check privilege / network stack")
    if r.returncode != 0:
        raise GateError(
            "insufficient privilege: dumpcap needs CAP_NET_RAW "
            "(setcap cap_net_raw+ep /usr/bin/dumpcap) or root; "
            "refusing — will not auto-escalate"
        )


def check_iface_allowlist(iface: str) -> None:
    """(b) Interface must be in RSDD_CAPTURE_IFACES (comma-list). GateError otherwise."""
    raw = os.environ.get("RSDD_CAPTURE_IFACES", "").strip()
    if not raw:
        raise GateError(
            "RSDD_CAPTURE_IFACES env var is not set; "
            "set it to a comma-separated list of allowed capture interfaces "
            "(e.g. RSDD_CAPTURE_IFACES=eth0,lo)"
        )
    allowed = {s.strip() for s in raw.split(",") if s.strip()}
    if iface not in allowed:
        raise GateError(
            f"interface {iface!r} is not in RSDD_CAPTURE_IFACES allowlist "
            f"(allowed: {sorted(allowed)}); update RSDD_CAPTURE_IFACES to permit it"
        )


def validate_plan_argv(argv: list[str]) -> None:
    """(c) Structural: planned_argv must be dumpcap with -c, -a duration:, -w. GateError otherwise."""
    if not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
        raise GateError("plan.planned_argv must be a list of strings")
    if not argv or argv[0] != "dumpcap":
        raise GateError("plan.planned_argv must begin with 'dumpcap'; got: " + repr(argv[:2]))
    if "-c" not in argv:
        raise GateError("plan.planned_argv missing -c (packet-count cap); plan is unbounded")
    has_duration = any(
        a.startswith("duration:") for i, a in enumerate(argv)
        if i > 0 and argv[i - 1] == "-a"
    )
    if not has_duration:
        raise GateError(
            "plan.planned_argv missing -a duration:N (wall cap); plan is unbounded"
        )
    if "-w" not in argv:
        raise GateError("plan.planned_argv missing -w (output file)")


def _extract_iface(argv: list[str]) -> str:
    try:
        return argv[argv.index("-i") + 1]
    except (ValueError, IndexError):
        raise GateError("plan.planned_argv missing -i IFACE (interface not specified)")


def _preflight(plan: dict[str, Any]) -> None:
    """Defense-in-depth preflight (gate-authorization.v1 rule 4). GateError → exit 2."""
    check_dumpcap_privilege()                         # (a) binary + privilege
    argv = plan.get("planned_argv", [])
    validate_plan_argv(argv)                          # (b) structural — ensures list[str] before iface extract
    check_iface_allowlist(_extract_iface(argv))       # (c) allowlist
    _dc.verify_rsdd_root()                            # (d) /tmp/rsdd real dir


# ---------------------------------------------------------------------------
# Executor
# ---------------------------------------------------------------------------

class LiveCaptureExecutor:
    """Live capture executor for --allow-live-capture (C1 only).
    Satisfies _HasEvaluate protocol. Selected locally in capture_plan.py;
    NEVER wired into plan_common.select_executor (13 other callers stay plan-only).
    """

    def __init__(self, output_dir: Path) -> None:
        self._output_dir = output_dir

    def evaluate(self, plan: dict[str, Any]) -> dict[str, Any]:  # noqa: C901
        """Run dumpcap; return capture-run.v1 dict. GateError on preflight failure (exit 2).
        Wall-timeout is a labeled outcome (timeout-partial), not an error: dumpcap SIGTERM
        flushes a valid partial pcap before dying.
        """
        _preflight(plan)
        planned_argv: list[str] = list(plan.get("planned_argv", []))
        cap_spec = plan.get("capture_spec", {})
        duration_s: int = int(cap_spec.get("duration_seconds", 60))
        packet_count: int = int(cap_spec.get("packet_count_cap", 10_000))
        snaplen: int = int(cap_spec.get("snaplen", 65535))

        # Filesize cap in kB (×1000, per dumpcap -a filesize: semantics).
        filesize_kb = _filesize_kb(packet_count, snaplen)

        # Per-run output subdir (O_NOFOLLOW fd-anchored — closes pcap -w symlink TOCTOU).
        run_uuid = uuid.uuid4().hex
        run_dir = _dc.make_run_subdir(run_uuid)
        pcap_path = f"{run_dir}/capture.pcap"

        # Transform 1: rewrite -w to per-run subdir.
        exec_argv = list(planned_argv)
        argv_deltas: list[dict[str, str]] = []
        try:
            w_idx = exec_argv.index("-w")
            old_w = exec_argv[w_idx + 1]
            exec_argv[w_idx + 1] = pcap_path
            argv_deltas.append({"transform": "output-path", "from": old_w, "to": pcap_path})
        except (ValueError, IndexError):
            raise GateError("plan.planned_argv missing -w (output file)")

        # Transform 2: add -a filesize:<KB> (absent from plan, required for byte bounds).
        filesize_arg = f"filesize:{filesize_kb}"
        exec_argv += ["-a", filesize_arg]
        argv_deltas.append({"transform": "add-filesize-cap", "value": filesize_arg})

        wall_deadline = duration_s + _WALL_GRACE_S

        # Bounded streaming drain: one daemon thread per pipe.
        raw_out: list[bytes] = [b""]
        raw_err: list[bytes] = [b""]
        # Intentionally no shell invocation — discrete list[str] argv has no shell-expansion surface.
        proc = subprocess.Popen(exec_argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        t_out: threading.Thread | None = None
        t_err: threading.Thread | None = None
        t0 = time.monotonic()
        timed_out = False
        exit_code: int = -1
        try:
            t_out = threading.Thread(
                target=_dc.drain_pipe, args=(proc.stdout, _dc.OUTPUT_CAP, raw_out), daemon=True)
            t_err = threading.Thread(
                target=_dc.drain_pipe, args=(proc.stderr, _dc.OUTPUT_CAP, raw_err), daemon=True)
            t_out.start()
            t_err.start()
            try:
                exit_code = proc.wait(timeout=wall_deadline)
            except subprocess.TimeoutExpired:
                timed_out = True
                # SIGTERM first — dumpcap flushes a valid partial pcap on SIGTERM.
                try: proc.send_signal(signal.SIGTERM)
                except Exception: pass
                try: proc.wait(timeout=_SIGTERM_GRACE_S)
                except subprocess.TimeoutExpired:
                    try: proc.kill()
                    except Exception: pass
                try: exit_code = proc.wait(timeout=5)
                except Exception: exit_code = -1
        finally:
            # Reap FIRST — eliminates any orphaned root dumpcap on every exit path.
            # No-op when proc already exited (poll() guard in _reap).
            _reap(proc)
            # Join drain threads only after proc is dead (pipes reach EOF).
            for t in (t_out, t_err):
                if t is not None and t.ident is not None:
                    t.join(timeout=5)

        duration_actual = time.monotonic() - t0
        stdout, stdout_trunc = _dc.cap(raw_out[0])
        stderr, stderr_trunc = _dc.cap(raw_err[0])

        # C2: offline pcap corroboration handoff.  Run AFTER drain-join so pcap is fully
        # flushed, BEFORE output_files() so analysis JSONs appear in the receipt.
        # Analyzer failure is DATA — never raises GateError; CLI exit stays 0 on capture ok.
        analysis = analyze_pcap(pcap_path, run_dir)

        return {
            "schema_version": SCHEMA_VERSION,
            "executed": True,
            "outcome": "timeout-partial" if timed_out else "success",
            "exec_argv": exec_argv,
            "argv_deltas": argv_deltas,
            "pcap_path": pcap_path,
            "exit_code": exit_code,
            "duration_s": round(duration_actual, 3),
            "stdout": stdout, "stderr": stderr,
            "stdout_truncated": stdout_trunc, "stderr_truncated": stderr_trunc,
            "output_files": _dc.output_files(Path(run_dir)),
            "analysis": analysis,
        }
