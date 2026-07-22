#!/usr/bin/env python3
"""Generic process-tree reaper shared across executors.

Rule of three: docker_exec._docker_kill (container), capture_exec._reap
(single-proc), and the future qemu executor (process GROUP via killpg) are
three consumers. This module extracts the common reap logic so each executor
delegates here instead of duplicating it.

NOT docker-specific: no docker imports, no gate/adapter_core deps.
"""
from __future__ import annotations
import os, signal, subprocess
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    pass  # no runtime imports needed beyond stdlib


def reap_process_tree(
    proc: "subprocess.Popen[bytes]",
    *,
    grace_s: int = 5,
    use_group: bool = False,
) -> None:
    """Best-effort SIGTERM → grace → SIGKILL reap. Never raises.

    Parameters
    ----------
    proc:
        The Popen object to reap.
    grace_s:
        Seconds to wait between SIGTERM and SIGKILL.
    use_group:
        If True, send signals to the entire process GROUP via os.killpg.
        Use this for processes spawned with ``start_new_session=True``
        (e.g. qemu, which may fork helper processes).  The pgid is captured
        BEFORE the first signal to avoid a pid-reuse race.
        If False, signal only the single process (single-proc mode:
        equivalent to the original capture_exec._reap behaviour).
    """
    if proc.poll() is not None:
        return  # already exited — no-op

    # Capture pgid before sending any signal: after SIGTERM the process
    # may exit and its pid could be recycled, making getpgid() fail.
    pgid: int | None = None
    if use_group:
        try:
            pgid = os.getpgid(proc.pid)
            # Guard: if proc's group equals the reaper's own group, killpg
            # would self-signal the orchestrator.  Fall back to single-proc.
            if pgid == os.getpgrp():
                pgid = None
        except Exception:
            pgid = None  # fall back to single-proc if pgid unavailable

    # ── SIGTERM ──────────────────────────────────────────────────────────────
    try:
        if use_group and pgid is not None:
            os.killpg(pgid, signal.SIGTERM)
        else:
            proc.send_signal(signal.SIGTERM)
    except Exception:
        pass

    # ── wait grace period; SIGKILL always fires in finally ───────────────────
    try:
        proc.wait(timeout=grace_s)
    except Exception:
        pass
    finally:
        try:
            if use_group and pgid is not None:
                os.killpg(pgid, signal.SIGKILL)
            else:
                proc.kill()
        except Exception:
            pass

    # ── final drain wait ─────────────────────────────────────────────────────
    try:
        proc.wait(timeout=5)
    except Exception:
        pass
