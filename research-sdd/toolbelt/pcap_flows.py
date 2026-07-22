#!/usr/bin/env python3
"""Reconstruct TCP/UDP transport flows from a pcap/pcapng capture file.

Enumerates TCP and UDP conversations (tshark -z conv,tcp / conv,udp) and
computes per-TCP-stream reassembled-payload SHA-256 digests via
tshark -z follow,tcp,raw,N.  Never touches the network, never replays traffic.
"""
from __future__ import annotations
import argparse, hashlib, json, os, re, shutil, subprocess, sys
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
from lib.isolation_profile import PROFILE_BWRAP_PCAP_OFFLINE

SCHEMA = "pcap-flows.v1"
MAX_STREAMS = 128  # default cap for per-stream follow loop (--max-streams override)
_PROFILE = PROFILE_BWRAP_PCAP_OFFLINE
_LIMITATIONS = [
    "tshark operates read-only; no live capture, injection, or replay occurs.",
    "TCP stream indices are encounter-order (0..N-1 where N = unique tcp.stream count).",
    "Per-stream evidence stores SHA-256 of reassembled payload — raw bytes never written.",
    "Bubblewrap on WSL2 is defense-in-depth; use a disposable VM for hostile captures.",
]

class PcapFlowsError(AdapterError):
    """Fail-closed error for the pcap-flows adapter."""

def _check_magic(path: Path) -> None:
    """Open with O_NOFOLLOW and verify libpcap/pcapng magic bytes."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as exc:
        raise PcapFlowsError(f"not a pcap/pcapng file: {path}") from exc
    try:
        magic = os.read(fd, 4)
    finally:
        os.close(fd)
    if magic not in _PCAP_MAGIC and magic != _PCAPNG_MAGIC:
        raise PcapFlowsError(f"not a pcap/pcapng file (magic: {magic.hex()})")


def _parse_conversations(text: str, proto: str) -> list[dict[str, Any]]:
    """Extract one protocol's conversation rows from combined tshark -z conv output.

    Sections are bounded by '===' lines; rows contain '<->'.  tshark interleaves
    the literal word 'bytes' and float timestamps after each frame/byte pair, so
    only pure-integer tokens (isdigit filter) are extracted after the endpoint pair.
    Expected order: frames_b2a  bytes_b2a  frames_a2b  bytes_a2b  frames_total  bytes_total.
    Endpoints are canonicalized (smaller string first) for deterministic ordering.
    """
    target = f"{proto.upper()} Conversations"
    results: list[dict[str, Any]] = []
    in_section = in_right = False
    for line in text.splitlines():
        if "===" in line:
            if in_section and in_right:
                break           # closing '===' of our target section
            in_section = not in_section
            if not in_section:
                in_right = False
            continue
        if in_section and not in_right:
            if target in line:
                in_right = True
            continue
        if not (in_section and in_right) or "<->" not in line:
            continue
        # Partition on '<->' then extract endpoint_b as first whitespace-delimited token
        left, _, right = line.partition("<->")
        a = left.strip()
        right_s = right.lstrip()
        ws = re.search(r'\s', right_s)
        b = right_s[:ws.start()] if ws else right_s
        rest = right_s[ws.start():] if ws else ""
        # Skip 'bytes' literals, floats, and '|' visual separators; keep only integers
        nums = [t for t in rest.replace("|", " ").split() if re.match(r'^\d+$', t)]
        if len(nums) < 6:
            continue
        if a > b:
            a, b = b, a         # canonicalize endpoint order
            nums[:4] = nums[2:4] + nums[0:2]  # swap directional pairs to match new a/b
        results.append({"endpoint_a": a, "endpoint_b": b,
                         "frames_b2a": int(nums[0]), "bytes_b2a": int(nums[1]),
                         "frames_a2b": int(nums[2]), "bytes_a2b": int(nums[3]),
                         "frames_total": int(nums[4]), "bytes_total": int(nums[5])})
    return sorted(results, key=lambda c: (c["endpoint_a"], c["endpoint_b"]))


def _parse_follow(text: str, stream_idx: int) -> dict[str, Any]:
    """Parse tshark -z follow,tcp,raw,N and hash the reassembled payload.

    Between '===' delimiters: 'Node 0/1:' lines give endpoints; hex lines
    without a leading tab are client→server (Node 0); with a leading tab are
    server→client (Node 1).  SHA-256 covers all bytes in encounter order.
    Raw bytes are never stored — the digest is the deterministic fingerprint.
    """
    node0 = node1 = ""
    client_b = server_b = 0
    payload_complete = True
    h = hashlib.sha256()
    active = False
    for line in text.splitlines():
        if "===" in line:
            if active:
                break
            active = True
            continue
        if not active:
            continue
        if line.startswith("Node 0:"):
            node0 = line[7:].strip()
        elif line.startswith("Node 1:"):
            node1 = line[7:].strip()
        elif line.startswith("\t"):   # server→client hex (Node 1)
            try:
                raw = bytes.fromhex(line.strip()); h.update(raw); server_b += len(raw)
            except ValueError:
                payload_complete = False  # partial reassembly — digest is incomplete
        elif re.match(r'^[0-9a-fA-F]+$', line.strip()):  # client→server hex (Node 0)
            try:
                raw = bytes.fromhex(line.strip()); h.update(raw); client_b += len(raw)
            except ValueError:
                payload_complete = False  # partial reassembly — digest is incomplete
    return {"stream_index": stream_idx, "client": node0, "server": node1,
            "payload_sha256": "sha256:" + h.hexdigest(),
            "payload_bytes": client_b + server_b,
            "client_bytes": client_b, "server_bytes": server_b,
            "payload_complete": payload_complete}

def main(argv: list[str] | None = None) -> int:  # noqa: C901
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--timeout-seconds", type=int, default=30)
    ap.add_argument("--max-bytes", type=int, default=1_000_000)
    ap.add_argument("--max-streams", type=int, default=MAX_STREAMS,
                    help="maximum TCP stream follow passes (default %(default)s); "
                         "excess streams are counted but not analyzed")
    ap.add_argument("--manifest-cli", type=Path, required=True, help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    stage: Path | None = None
    try:
        if args.timeout_seconds < 1 or args.max_bytes < 1:
            raise PcapFlowsError("caps must be positive")
        _check_magic(args.input)
        source, _, _ = identity(args.input)
        parent = args.output.parent.resolve(strict=True)
        require_private(parent)
        destination = parent / args.output.name
        if destination.exists() or destination.is_symlink() or source == destination:
            raise PcapFlowsError("output must be a new non-colliding path")

        stage = parent / f".{destination.name}.stage"
        stage.mkdir(mode=0o700)
        (stage / "input").mkdir(); (stage / "engine").mkdir()
        source_record, staged_record = stage_file(
            args.input, stage / "input/capture.pcap", "input/capture.pcap", 0o400,
        )
        search = os.environ.get("PATH", "")
        bwrap, bwrap_record = executable("bwrap", os.environ.get("RSDD_BWRAP"), search)
        tshark_path, tshark_record = executable(
            "tshark", os.environ.get("RSDD_TSHARK"), search)
        env = {
            "HOME": "/tmp/rsdd/home", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/usr/sbin:/bin:/sbin", "TMPDIR": "/tmp/rsdd", "TZ": "UTC",
            "XDG_CACHE_HOME": "/tmp/rsdd/cache", "XDG_CONFIG_HOME": "/tmp/rsdd/config",
            "XDG_DATA_HOME": "/tmp/rsdd/data",
        }
        prefix = sandbox(bwrap, env)

        ver = subprocess.run(prefix + [str(tshark_path), "-v"], cwd=stage, env=env,
                             capture_output=True, text=True, timeout=10)
        tshark_version = ver.stdout.splitlines()[0] if ver.stdout.strip() else "unknown"

        # Step 1: discover unique TCP stream indices via field extraction
        _, fields_errors = run_bounded(
            prefix + [str(tshark_path), "-T", "fields", "-e", "tcp.stream",
                      "-r", "input/capture.pcap"],
            stage, env, args.timeout_seconds, args.max_bytes)
        fields_text = (stage / "engine/stdout.txt").read_text(errors="replace")
        # Blank tokens arise from non-TCP packets; isdigit filter removes them
        stream_ids = sorted(set(int(x) for x in fields_text.split() if x.strip().isdigit()))

        # Step 2: per-TCP-stream follow — SHA-256 of reassembled payload only
        stream_count_total = len(stream_ids)
        if stream_count_total > args.max_streams:
            print(
                f"pcap-flows: warning: {stream_count_total} TCP streams found; "
                f"analyzing only the first {args.max_streams} "
                f"(--max-streams={args.max_streams})",
                file=sys.stderr,
            )
            stream_ids = stream_ids[:args.max_streams]
        streams_truncated = stream_count_total > args.max_streams
        stream_follows: list[dict[str, Any]] = []
        follow_errors: list[str] = []
        for sid in stream_ids:
            _, ferrs = run_bounded(
                prefix + [str(tshark_path), "-q", "-z", f"follow,tcp,raw,{sid}",
                          "-r", "input/capture.pcap"],
                stage, env, args.timeout_seconds, args.max_bytes)
            stream_follows.append(_parse_follow(
                (stage / "engine/stdout.txt").read_text(errors="replace"), sid))
            follow_errors.extend(ferrs)

        # Step 3: conversation statistics — runs LAST so engine/stdout.txt holds
        # this output when the manifest is built (no save/restore needed)
        conv_cmd = prefix + [str(tshark_path), "-q", "-z", "conv,tcp", "-z", "conv,udp",
                             "-r", "input/capture.pcap"]
        conv_run, conv_errors = run_bounded(
            conv_cmd, stage, env, args.timeout_seconds, args.max_bytes)
        conv_stdout = (stage / "engine/stdout.txt").read_text(errors="replace")
        tcp_convs = _parse_conversations(conv_stdout, "tcp")
        udp_convs = _parse_conversations(conv_stdout, "udp")

        all_errors = fields_errors + follow_errors + conv_errors
        status = "failed" if all_errors else "complete"
        tshark_idx = conv_cmd.index(str(tshark_path))

        emit_evidence(
            stage=stage,
            schema=SCHEMA,
            domain={
                "conversations": {"argv": conv_cmd, "tcp": tcp_convs, "udp": udp_convs,
                                  "tool": tshark_record},
                "stream_count_total": stream_count_total,
                "streams_analyzed": len(stream_follows),
                "streams_truncated": streams_truncated,
                "tcp_stream_follows": stream_follows,
            },
            input_identity={"source": source_record, "staged": staged_record},
            isolation={"launcher": bwrap_record, "profile": _PROFILE},
            limitations=_LIMITATIONS,
            errors=all_errors,
            manifest_spec={
                "argv": conv_cmd, "completeness": status, "environment": env,
                "errors": all_errors, "findings": [],
                "input": {"detected_type": "network capture (pcap/pcapng)",
                          "path": "input/capture.pcap"},
                "isolation_profile": _PROFILE, "limitations": _LIMITATIONS,
                "outputs": [f"{SCHEMA}.json"], "run": conv_run,
                "schema_version": "analysis-manifest.v1",
                "stderr_path": "engine/stderr.txt", "stdout_path": "engine/stdout.txt",
                "tool": {"artifacts": [{"argv_index": tshark_idx, "path": str(tshark_path)}],
                         "executable": str(bwrap), "name": "tshark",
                         "version": tshark_version},
            },
            manifest_cli=args.manifest_cli,
            destination=destination,
            timeout=30,
        )
        stage = None
        return 1 if all_errors else 0

    except (PcapFlowsError, AdapterError, OSError,
            subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"pcap-flows: {exc}", file=sys.stderr)
        return 2
    finally:
        if stage is not None and stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    sys.exit(main())
