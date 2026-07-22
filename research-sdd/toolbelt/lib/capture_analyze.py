#!/usr/bin/env python3
"""Offline pcap corroboration handoff (C2).

Spawns corroborate_pcap.py and pcap_flows.py as SEPARATE unprivileged child
processes after live capture completes.  NEVER imports those modules — exec-of-file
only (start_new_session=True).  Analyzers self-sandbox via adapter_core.sandbox.

Env seams (mirror RSDD_TSHARK idiom):
  RSDD_CORROBORATE_PCAP / RSDD_PCAP_FLOWS   — script path override for tests
  RSDD_PCAP_ANALYZER_TIMEOUT_S              — outer wall per child (default 300, min 1)
"""
from __future__ import annotations
import os, signal, subprocess, sys
from pathlib import Path
from typing import Any

_TOOLBELT = Path(__file__).parent.parent          # lib/ → toolbelt root
_MANIFEST  = str(_TOOLBELT / "analysis_manifest.py")
_DEFAULT_CORROBORATE = str(_TOOLBELT / "corroborate_pcap.py")
_DEFAULT_PCAP_FLOWS  = str(_TOOLBELT / "pcap_flows.py")
_OUTER_TIMEOUT_DEFAULT: int = 300
_CHILD_TIMEOUT_S:   str = "30"
_CHILD_MAX_BYTES:   str = "1000000"
_CHILD_MAX_STREAMS: str = "128"
_STDERR_TAIL:       int = 500


def _outer_timeout() -> int:
    try:
        raw = os.environ.get("RSDD_PCAP_ANALYZER_TIMEOUT_S", "")
        return max(1, int(raw)) if raw else _OUTER_TIMEOUT_DEFAULT
    except (ValueError, TypeError):
        return _OUTER_TIMEOUT_DEFAULT


def _script(env_key: str, default: str) -> str:
    return os.environ.get(env_key, "").strip() or default


def _run_one(name: str, script: str, pcap_path: str, output_path: str,
             timeout_s: int) -> dict[str, Any]:
    """Spawn one analyzer child.  Never raises — failure is DATA."""
    argv: list[str] = [
        sys.executable, script,
        "--input",           pcap_path,
        "--output",          output_path,
        "--timeout-seconds", _CHILD_TIMEOUT_S,
        "--max-bytes",       _CHILD_MAX_BYTES,
        "--manifest-cli",    _MANIFEST,
    ]
    if name == "pcap_flows":
        argv += ["--max-streams", _CHILD_MAX_STREAMS]

    timed_out: bool    = False
    exit_code:  int    = -1
    stderr_bytes: bytes = b""
    try:
        # start_new_session=True → pgid == proc.pid; killpg targets child tree only.
        proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                start_new_session=True)
        try:
            _, stderr_bytes = proc.communicate(timeout=timeout_s)
            exit_code = proc.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            # SIGTERM → 5 s grace → SIGKILL (bwrap --die-with-parent tears engines down).
            try: os.killpg(proc.pid, signal.SIGTERM)
            except Exception: pass
            try: proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try: os.killpg(proc.pid, signal.SIGKILL)
                except Exception: pass
            try:
                _, stderr_bytes = proc.communicate()
                exit_code = proc.returncode
            except Exception: pass
    except Exception:
        pass

    p_out = Path(output_path)
    return {
        "name":           name,
        "argv":           argv,
        "exit_code":      exit_code,
        "timed_out":      timed_out,
        "output_json":    output_path if p_out.exists() else None,
        "output_present": p_out.exists(),
        "stderr_tail":    stderr_bytes[-_STDERR_TAIL:].decode("utf-8", errors="replace"),
    }


def analyze_pcap(pcap_path: str, run_dir: str) -> dict[str, Any]:
    """Spawn both offline pcap analyzers sequentially as separate child processes.

    Returns {"attempted": False, "skipped_reason": "missing-or-empty-pcap"} when
    the pcap is absent or 0 bytes (no children spawned).  Otherwise returns
    {"attempted": True, "analyzers": [corroborate_entry, flows_entry]} — the second
    analyzer is always attempted even if the first fails.  Never raises.
    """
    p = Path(pcap_path)
    if not p.exists() or p.stat().st_size == 0:
        return {"attempted": False, "skipped_reason": "missing-or-empty-pcap"}

    timeout_s   = _outer_timeout()
    corr_script = _script("RSDD_CORROBORATE_PCAP", _DEFAULT_CORROBORATE)
    flow_script = _script("RSDD_PCAP_FLOWS",       _DEFAULT_PCAP_FLOWS)
    rd          = Path(run_dir)
    return {
        "attempted": True,
        "analyzers": [
            _run_one("corroborate_pcap", corr_script, pcap_path,
                     str(rd / "pcap-evidence.v1.json"), timeout_s),
            _run_one("pcap_flows",       flow_script,  pcap_path,
                     str(rd / "pcap-flows.v1.json"),   timeout_s),
        ],
    }
