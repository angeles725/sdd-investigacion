#!/usr/bin/env python3
"""Produce bounded, offline pcap evidence from a Wireshark capture file.

Runs capinfos (summary) and tshark -z io,phs (protocol hierarchy) inside a
network-denied Bubblewrap sandbox.  Never touches the network, never replays
traffic, never executes the capture contents.
"""
from __future__ import annotations
import argparse, json, os, re, shutil, subprocess, sys
from pathlib import Path
from typing import Any
sys.path.insert(0, str(Path(__file__).parent))
from lib.adapter_core import (
    AdapterError, executable, identity,
    require_private, run_bounded, sandbox, stage_file,
)
from lib.adapter_helpers import (
    _PCAP_MAGIC, _PCAPNG_MAGIC,
    emit_evidence,
)

SCHEMA = "pcap-evidence.v1"
_PROFILE = {
    "name": "bubblewrap-pcap-offline",
    "network_access": False, "static_only": True, "target_execution": False,
}
_LIMITATIONS = [
    "capinfos and tshark operate read-only on the capture file; "
    "no live capture, injection, or replay occurs.",
    "Protocol dissection is heuristic; encrypted or tunnelled traffic "
    "may not be identified correctly.",
    "Bubblewrap on WSL2 is defense-in-depth, not a hostile-parser security "
    "boundary; use a disposable VM for hostile captures.",
]


class PcapError(AdapterError):
    """Fail-closed error for the pcap evidence adapter."""


def _check_magic(path: Path) -> None:
    """Open with O_NOFOLLOW and verify libpcap/pcapng magic bytes."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise PcapError(f"not a pcap/pcapng file: {path}") from exc
    try:
        magic = os.read(fd, 4)
    finally:
        os.close(fd)
    if magic not in _PCAP_MAGIC and magic != _PCAPNG_MAGIC:
        raise PcapError(f"not a pcap/pcapng file (magic: {magic.hex()})")


def _parse_capinfos(text: str) -> dict[str, Any]:
    """Extract deterministic fields from capinfos key-value output."""
    kv: dict[str, str] = {}
    for line in text.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            kv[k.strip()] = v.strip()

    def _int(key: str) -> int:
        val = kv.get(key, "0")
        return int(val.split()[0]) if val.split() else 0

    def _float(key: str) -> float:
        val = kv.get(key, "0")
        return float(val.split()[0]) if val.split() else 0.0

    try:
        return {
            "capture_duration_s": _float("Capture duration"),
            "data_size_bytes": _int("Data size"),
            "encapsulation": kv.get("File encapsulation", "unknown"),
            "file_size_bytes": _int("File size"),
            "packet_count": _int("Number of packets"),
        }
    except (ValueError, IndexError) as exc:
        raise PcapError(f"capinfos output unparseable: {exc}") from exc


def _parse_phs(text: str) -> list[dict[str, Any]]:
    """Parse tshark -z io,phs output into a sorted, stable list."""
    protocols: list[dict[str, Any]] = []
    in_section = False
    for line in text.splitlines():
        if "===" in line:
            in_section = not in_section
            continue
        if not in_section:
            continue
        m = re.match(r"^(\s*)(\S+)\s+frames:(\d+)\s+bytes:(\d+)", line)
        if not m:
            continue
        protocols.append({
            "bytes": int(m.group(4)),
            "frames": int(m.group(3)),
            "level": len(m.group(1)) // 2,
            "protocol": m.group(2),
        })
    return sorted(protocols, key=lambda p: (p["level"], p["protocol"]))


def main(argv: list[str] | None = None) -> int:  # noqa: C901
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--timeout-seconds", type=int, default=30)
    ap.add_argument("--max-bytes", type=int, default=1_000_000)
    ap.add_argument("--manifest-cli", type=Path, required=True, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    stage: Path | None = None
    try:
        if args.timeout_seconds < 1 or args.max_bytes < 1:
            raise PcapError("caps must be positive")
        _check_magic(args.input)
        source, _, _ = identity(args.input)
        parent = args.output.parent.resolve(strict=True)
        require_private(parent)
        destination = parent / args.output.name
        if destination.exists() or destination.is_symlink() or source == destination:
            raise PcapError("output must be a new non-colliding path")

        stage = parent / f".{destination.name}.stage"
        stage.mkdir(mode=0o700)
        (stage / "input").mkdir()
        (stage / "engine").mkdir()
        source_record, staged_record = stage_file(
            args.input, stage / "input/capture.pcap", "input/capture.pcap", 0o400
        )

        search = os.environ.get("PATH", "")
        bwrap, bwrap_record = executable("bwrap", os.environ.get("RSDD_BWRAP"), search)
        capinfos_path, capinfos_record = executable(
            "capinfos", os.environ.get("RSDD_CAPINFOS"), search
        )
        tshark_path, tshark_record = executable(
            "tshark", os.environ.get("RSDD_TSHARK"), search
        )

        env = {
            "HOME": "/tmp/rsdd/home", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/usr/sbin:/bin:/sbin", "TMPDIR": "/tmp/rsdd", "TZ": "UTC",
            "XDG_CACHE_HOME": "/tmp/rsdd/cache", "XDG_CONFIG_HOME": "/tmp/rsdd/config",
            "XDG_DATA_HOME": "/tmp/rsdd/data",
        }
        prefix = sandbox(bwrap, env)

        # Version probe (runs inside sandbox for consistency)
        ver = subprocess.run(
            prefix + [str(tshark_path), "-v"], cwd=stage, env=env,
            capture_output=True, text=True, timeout=10,
        )
        tshark_version = ver.stdout.splitlines()[0] if ver.stdout.strip() else "unknown"

        # --- capinfos run (writes engine/stdout.txt) ---
        capinfos_cmd = prefix + [str(capinfos_path), "input/capture.pcap"]
        _, capinfos_errors = run_bounded(
            capinfos_cmd, stage, env, args.timeout_seconds, args.max_bytes
        )
        capinfos_text = (stage / "engine/stdout.txt").read_text(errors="replace")
        summary = _parse_capinfos(capinfos_text) if not capinfos_errors else {}

        # --- tshark protocol hierarchy (overwrites engine/stdout.txt + stderr.txt) ---
        tshark_inner = [str(tshark_path), "-q", "-z", "io,phs", "-r", "input/capture.pcap"]
        tshark_cmd = prefix + tshark_inner
        tshark_idx = tshark_cmd.index(str(tshark_path))
        tshark_run, tshark_errors = run_bounded(
            tshark_cmd, stage, env, args.timeout_seconds, args.max_bytes
        )
        tshark_text = (stage / "engine/stdout.txt").read_text(errors="replace")
        protocols = _parse_phs(tshark_text) if not tshark_errors else []

        all_errors = capinfos_errors + tshark_errors
        status = "failed" if all_errors else "complete"

        emit_evidence(
            stage=stage,
            schema=SCHEMA,
            domain={
                "capinfos": {"argv": capinfos_cmd, "summary": summary, "tool": capinfos_record},
                "protocol_hierarchy": {"argv": tshark_cmd, "protocols": protocols, "tool": tshark_record},
            },
            input_identity={"source": source_record, "staged": staged_record},
            isolation={"launcher": bwrap_record, "profile": _PROFILE},
            limitations=_LIMITATIONS,
            errors=all_errors,
            manifest_spec={
                "argv": tshark_cmd,
                "completeness": status,
                "environment": env,
                "errors": all_errors,
                "findings": [],
                "input": {"detected_type": "network capture (pcap/pcapng)", "path": "input/capture.pcap"},
                "isolation_profile": _PROFILE,
                "limitations": _LIMITATIONS,
                "outputs": [f"{SCHEMA}.json"],
                "run": tshark_run,
                "schema_version": "analysis-manifest.v1",
                "stderr_path": "engine/stderr.txt",
                "stdout_path": "engine/stdout.txt",
                "tool": {
                    "artifacts": [{"argv_index": tshark_idx, "path": str(tshark_path)}],
                    "executable": str(bwrap),
                    "name": "tshark",
                    "version": tshark_version,
                },
            },
            manifest_cli=args.manifest_cli,
            destination=destination,
        )
        stage = None
        return 1 if all_errors else 0

    except (PcapError, AdapterError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"corroborate-pcap: {exc}", file=sys.stderr)
        return 2
    finally:
        if stage is not None and stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    sys.exit(main())
