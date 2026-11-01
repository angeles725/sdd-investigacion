#!/usr/bin/env python3
"""serial-frame-capture — passive serial frame capture (serial-frame.v1).

HARDWARE PROBE: requires a real serial port and ``--allow-live-probe``.
Without that flag the wrapper exits 3 and writes an offline plan only —
zero serial I/O is performed.

Modes:

  sweep    --port <dev> [--seconds N] --output <json>
           Try common baud rates in sequence, capture a short window at each,
           score which baud rate produces framed (low-entropy, repeating) traffic.
           Use to identify the correct baud rate before a full capture.

  capture  --port <dev> --baud <N> [--seconds N] [--gap-ms N] --output <json>
           Capture at one baud, split the byte stream into frames by idle-gap
           heuristic, and emit the frame list as JSON evidence.  Use the output
           as input to ``serial-frame-analyze`` for offline RE work.

Guard: without ``--allow-live-probe`` exits 3 and writes an offline plan.
With    ``--allow-live-probe`` real serial I/O is performed via pyserial.
Plan-only mode works without pyserial installed.

Live probe requires pyserial (``pip install pyserial``).  Plan-only mode
works without it.

Exit codes:
  3  plan-only (``--allow-live-probe`` absent; zero serial I/O)
  0  complete — frames captured or baud sweep finished
  1  no data — port opened but no frames received within the window
  2  operational error — port unavailable, pyserial missing, or I/O failure
"""
import argparse
import json
import math
import os
import sys

SCHEMA = "serial-frame.v1"
COMMON_BAUDS = [2400, 4800, 9600, 19200, 38400, 57600, 115200]

# Frame cap for live capture — prevents OOM on continuous streams
_MAX_FRAMES = 1_000
# Per-baud read cap (bytes) during sweep — prevents indefinite reads
_MAX_READ_PER_BAUD = 64 * 1024  # 64 KB

_O_NOFOLLOW = getattr(os, 'O_NOFOLLOW', 0)
_O_CLOEXEC  = getattr(os, 'O_CLOEXEC', 0)


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def _open_wo_new(path: str) -> int:
    """Open *path* write-only for a new file; refuse symlinks and pre-existing files.

    Uses O_CREAT|O_EXCL|O_NOFOLLOW.  Pattern from qnx6_read.py.
    """
    return os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC,
        0o600,
    )


def _write_json(path: str, data: dict) -> None:
    """Write *data* as key-sorted JSON to *path*, refusing symlinks (O_NOFOLLOW)."""
    content = (json.dumps(data, indent=2, sort_keys=True) + '\n').encode('utf-8')
    fd = _open_wo_new(path)
    try:
        os.write(fd, content)
    finally:
        os.close(fd)


def _write_text_log(path: str, frames_raw: list) -> None:
    """Write *frames_raw* as canonical text frame log (one frame per line).

    Format: ``{t_rel:.6f}  len={N}  {HH HH ...}``
    This is the canonical serial-frame.v1 text-log format consumed by
    serial-frame-analyze.
    """
    lines = []
    for ts, fr in frames_raw:
        hex_bytes = ' '.join(f'{b:02x}' for b in fr)
        lines.append(f'{ts:.6f}  len={len(fr)}  {hex_bytes}\n')
    content = ''.join(lines).encode('utf-8')
    fd = _open_wo_new(path)
    try:
        os.write(fd, content)
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# Entropy helper
# ---------------------------------------------------------------------------

def _entropy(data: bytes) -> float:
    if not data:
        return 0.0
    counts = [0] * 256
    for b in data:
        counts[b] += 1
    n = len(data)
    return -sum((c / n) * math.log2(c / n) for c in counts if c)


# ---------------------------------------------------------------------------
# Plan-only JSON builders
# ---------------------------------------------------------------------------

def _plan_sweep(port: str, seconds: float) -> dict:
    return {
        "guard": "hardware probe requires --allow-live-probe; no serial I/O issued",
        "mode": "sweep",
        "plan": {
            "baud_rates": COMMON_BAUDS,
            "note": "passive read-only; no data transmitted to the device",
            "port": port,
            "seconds_per_baud": seconds,
        },
        "schema": SCHEMA,
        "status": "plan-only",
        "tool": "serial-frame-capture",
    }


def _plan_capture(port: str, baud: int, seconds: float, gap_ms: float) -> dict:
    return {
        "guard": "hardware probe requires --allow-live-probe; no serial I/O issued",
        "mode": "capture",
        "plan": {
            "baud": baud,
            "gap_ms": gap_ms,
            "note": "passive read-only; no data transmitted to the device",
            "port": port,
            "seconds": seconds,
        },
        "schema": SCHEMA,
        "status": "plan-only",
        "tool": "serial-frame-capture",
    }


# ---------------------------------------------------------------------------
# Live probe helpers (only reachable with --allow-live-probe)
# ---------------------------------------------------------------------------

def _live_sweep(serial, port: str, seconds: float) -> dict:
    """Run a baud-rate sweep (passive read-only) and return evidence dict."""
    import time as _time

    baud_results = []
    for baud in COMMON_BAUDS:
        ser = None
        try:
            ser = serial.Serial(
                port, baud, bytesize=8, parity='N', stopbits=1,
                timeout=0.2, rtscts=False, dsrdtr=False,
                write_timeout=0,
            )
            t0 = _time.monotonic()
            raw = bytearray()
            while _time.monotonic() - t0 < seconds:
                if len(raw) >= _MAX_READ_PER_BAUD:
                    break
                chunk = ser.read(4096)
                if chunk:
                    raw += chunk
            ser.close()
            ser = None
            h = _entropy(bytes(raw)) if raw else 0.0
            unique = len(set(raw))
            likely_framed = bool(raw) and h < 6.5 and len(raw) > 40
            baud_results.append({
                "baud": baud,
                "byte_count": len(raw),
                "entropy": round(h, 4),
                "likely_framed": likely_framed,
                "sample_hex": raw[:24].hex(),
                "unique_byte_values": unique,
            })
        except serial.SerialException as exc:
            baud_results.append({
                "baud": baud,
                "error": str(exc),
                "likely_framed": False,
            })
        finally:
            if ser is not None:
                try:
                    ser.close()
                except Exception:
                    pass

    best = next((r for r in reversed(baud_results) if r.get("likely_framed")), None)
    # §7: if every baud failed to open OR yielded zero bytes → status:failed / exit 1
    any_data = any(r.get("byte_count", 0) > 0 for r in baud_results)
    sweep_status = "complete" if any_data else "failed"  # sweep-all-fail
    return {
        "mode": "sweep",
        "results": {
            "baud_rates": baud_results,
            "best_candidate": best.get("baud") if best else None,
        },
        "schema": SCHEMA,
        "status": sweep_status,
        "summary": {
            "baud_count": len(baud_results),
            "likely_framed_count": sum(1 for r in baud_results if r.get("likely_framed")),
        },
        "tool": "serial-frame-capture",
    }


def _live_capture(serial, port: str, baud: int, seconds: float, gap_ms: float) -> tuple:
    """Capture frames at *baud* for *seconds* seconds using idle-gap framing.

    Returns ``(doc, frames_raw)`` where:
    - ``doc``        key-sorted JSON-ready evidence dict
    - ``frames_raw`` list of ``(t_rel_s, bytes)`` tuples for text-log output
    """
    import time as _time

    ser = serial.Serial(
        port, baud, bytesize=8, parity='N', stopbits=1,
        timeout=0.02, rtscts=False, dsrdtr=False,
        write_timeout=0,
    )
    gap = gap_ms / 1000.0
    frames_raw: list = []   # (t_rel, bytes)
    cur = bytearray()
    last_rx = None
    t0 = _time.monotonic()

    try:
        while _time.monotonic() - t0 < seconds:
            if len(frames_raw) >= _MAX_FRAMES:
                break
            chunk = ser.read(256)
            now = _time.monotonic()
            if chunk:
                if last_rx is not None and (now - last_rx) > gap and cur:
                    frames_raw.append((last_rx - t0, bytes(cur)))
                    cur = bytearray()
                cur += chunk
                last_rx = now
        if cur:
            frames_raw.append(((last_rx or t0) - t0, bytes(cur)))
    finally:
        ser.close()

    truncated = len(frames_raw) >= _MAX_FRAMES
    frames_out = [
        {
            "hex": fr.hex(),
            "length": len(fr),
            "t_rel_s": round(ts, 6),
        }
        for ts, fr in frames_raw
    ]
    frame_count = len(frames_out)
    distinct = len(set(len(fr) for _, fr in frames_raw)) if frames_raw else 0
    doc = {
        "frames": frames_out,
        "input": {
            "baud": baud,
            "gap_ms": gap_ms,
            "port": port,
            "seconds": seconds,
        },
        "mode": "capture",
        "schema": SCHEMA,
        "status": "complete" if frame_count > 0 else "no-data",
        "summary": {
            "distinct_lengths": distinct,
            "frame_count": frame_count,
            "truncated": truncated,
        },
        "tool": "serial-frame-capture",
        "truncated": truncated,
    }
    return doc, frames_raw


# ---------------------------------------------------------------------------
# Subcommand handlers
# ---------------------------------------------------------------------------

def _cmd_sweep(args: argparse.Namespace) -> int:
    if not args.allow_live_probe:
        doc = _plan_sweep(args.port, args.seconds)
        try:
            _write_json(args.output, doc)
        except OSError as exc:
            sys.stderr.write(f"serial-frame-capture: {args.output}: {exc.strerror}\n")
            return 2
        sys.exit(3)

    # Live probe — import pyserial here so plan-only mode works without it
    try:
        import serial as _serial  # type: ignore[import-untyped]
    except ImportError:
        sys.stderr.write(
            "serial-frame-capture: pyserial not installed; "
            "install it for live capture: pip install pyserial\n"
        )
        return 2
    except Exception as exc:
        sys.stderr.write(f"serial-frame-capture: import error: {exc}\n")
        err_doc = {
            "errors": [str(exc)],
            "mode": "sweep",
            "schema": SCHEMA,
            "status": "failed",
            "tool": "serial-frame-capture",
        }
        try:
            _write_json(args.output, err_doc)
        except OSError:
            pass
        return 2

    try:
        doc = _live_sweep(_serial, args.port, args.seconds)
    except _serial.SerialException as exc:
        sys.stderr.write(f"serial-frame-capture: {args.port}: {exc}\n")
        return 2
    except OSError as exc:
        sys.stderr.write(f"serial-frame-capture: {exc}\n")
        return 2

    try:
        _write_json(args.output, doc)
    except OSError as exc:
        sys.stderr.write(f"serial-frame-capture: {args.output}: {exc.strerror}\n")
        return 2

    return 0 if doc["status"] == "complete" else 1


def _cmd_capture(args: argparse.Namespace) -> int:
    if not args.allow_live_probe:
        doc = _plan_capture(args.port, args.baud, args.seconds, args.gap_ms)
        try:
            _write_json(args.output, doc)
        except OSError as exc:
            sys.stderr.write(f"serial-frame-capture: {args.output}: {exc.strerror}\n")
            return 2
        sys.exit(3)

    # Live probe — import pyserial here so plan-only mode works without it
    try:
        import serial as _serial  # type: ignore[import-untyped]
    except ImportError:
        sys.stderr.write(
            "serial-frame-capture: pyserial not installed; "
            "install it for live capture: pip install pyserial\n"
        )
        return 2
    except Exception as exc:
        sys.stderr.write(f"serial-frame-capture: import error: {exc}\n")
        err_doc = {
            "errors": [str(exc)],
            "mode": "capture",
            "schema": SCHEMA,
            "status": "failed",
            "tool": "serial-frame-capture",
        }
        try:
            _write_json(args.output, err_doc)
        except OSError:
            pass
        return 2

    try:
        doc, frames_raw = _live_capture(_serial, args.port, args.baud, args.seconds, args.gap_ms)
    except _serial.SerialException as exc:
        sys.stderr.write(f"serial-frame-capture: {args.port}: {exc}\n")
        return 2
    except OSError as exc:
        sys.stderr.write(f"serial-frame-capture: {exc}\n")
        return 2

    # Write optional text log (canonical serial-frame.v1 format for serial-frame-analyze)
    if getattr(args, 'log', None) and frames_raw:
        try:
            _write_text_log(args.log, frames_raw)
        except OSError as exc:
            sys.stderr.write(f"serial-frame-capture: {args.log}: {exc.strerror}\n")
            return 2

    try:
        _write_json(args.output, doc)
    except OSError as exc:
        sys.stderr.write(f"serial-frame-capture: {args.output}: {exc.strerror}\n")
        return 2

    frame_count = doc["summary"]["frame_count"]
    return 0 if frame_count > 0 else 1


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog='serial-frame-capture',
        description=(
            'Passive serial frame capture (serial-frame.v1). '
            'READ-ONLY: no data transmitted to the target device. '
            'Requires --allow-live-probe (after the subcommand) to perform real serial I/O.'
        ),
    )
    sub = p.add_subparsers(dest='cmd', required=True)

    sw = sub.add_parser('sweep', help='try common baud rates and score each')
    sw.add_argument(
        '--port', required=True, metavar='DEV',
        help='serial port device path (e.g. /dev/ttyUSB0)',
    )
    sw.add_argument(
        '--seconds', type=float, default=4.0, metavar='N',
        help='listen window per baud rate in seconds (default 4.0)',
    )
    sw.add_argument(
        '--output', required=True, metavar='JSON',
        help='output JSON evidence file (must not already exist)',
    )
    sw.add_argument(
        '--allow-live-probe', action='store_true',
        help='perform real serial I/O; absent → exit 3 (plan-only)',
    )

    cap = sub.add_parser('capture', help='capture at one baud rate and emit frame list')
    cap.add_argument(
        '--port', required=True, metavar='DEV',
        help='serial port device path (e.g. /dev/ttyUSB0)',
    )
    cap.add_argument(
        '--baud', type=int, required=True, metavar='N',
        help='baud rate (e.g. 19200)',
    )
    cap.add_argument(
        '--seconds', type=float, default=30.0, metavar='N',
        help='capture duration in seconds (default 30.0)',
    )
    cap.add_argument(
        '--gap-ms', type=float, default=8.0, metavar='MS',
        help='idle-gap threshold for frame boundary detection in ms (default 8.0)',
    )
    cap.add_argument(
        '--output', required=True, metavar='JSON',
        help='output JSON evidence file (must not already exist)',
    )
    cap.add_argument(
        '--log', metavar='TXT',
        help=(
            'write captured frames as canonical text log '
            '(<t_rel> len=<N> <HH HH ...>; must not already exist); '
            'suitable as input to serial-frame-analyze'
        ),
    )
    cap.add_argument(
        '--allow-live-probe', action='store_true',
        help='perform real serial I/O; absent → exit 3 (plan-only)',
    )

    return p


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    args = _build_parser().parse_args()
    if args.cmd == 'sweep':
        return _cmd_sweep(args)
    else:
        return _cmd_capture(args)


if __name__ == '__main__':
    sys.exit(main())
