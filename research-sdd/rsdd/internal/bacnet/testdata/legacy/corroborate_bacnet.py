#!/usr/bin/env python3
"""
corroborate_bacnet.py — BACnet/IP reachability and BBMD evidence wrapper (bacnet-evidence.v1).

READ-ONLY: sends Who-Is (unicast + broadcast), Read-BDT, Read-FDT only.
State-changing operations (Write-BDT, Register-Foreign-Device) are never sent.

Guard: without --allow-live-probe exits 3 and writes an offline probe plan only.
With --allow-live-probe real UDP frames are sent to the specified host.

Wire constants from ANSI/ASHRAE 135:
  BVLC type=0x81; Original-Unicast=0x0A, Original-Broadcast=0x0B, Forwarded=0x04
  Read-BDT=0x02, Read-BDT-Ack=0x03, Read-FDT=0x06, Read-FDT-Ack=0x07
  Unconfirmed-Request=0x10; Who-Is=0x08, I-Am=0x00
"""
import argparse
import json
import os
import socket
import struct
import sys
import time

# ---------------------------------------------------------------------------
# Wire constants (ANSI/ASHRAE 135 BACnet/IP)
# ---------------------------------------------------------------------------
BVLC_TYPE             = 0x81
FN_ORIGINAL_UNICAST   = 0x0A
FN_ORIGINAL_BROADCAST = 0x0B
FN_FORWARDED_NPDU     = 0x04
FN_READ_BDT           = 0x02
FN_READ_BDT_ACK       = 0x03
FN_READ_FDT           = 0x06
FN_READ_FDT_ACK       = 0x07
APDU_UNCONFIRMED      = 0x10
SVC_WHO_IS            = 0x08
SVC_I_AM              = 0x00
DEFAULT_PORT          = 47808  # 0xBAC0


# ---------------------------------------------------------------------------
# Frame builders
# ---------------------------------------------------------------------------

def _encode_unsigned(val):
    """Minimal-length big-endian unsigned, at least 1 byte."""
    if val == 0:
        return b"\x00"
    out = b""
    while val > 0:
        out = bytes([val & 0xFF]) + out
        val >>= 8
    return out


def _context_unsigned(tag, val):
    """Context-tagged unsigned integer for Who-Is range limits."""
    data = _encode_unsigned(val)
    if len(data) > 4:
        raise ValueError("BACnet instance out of range")
    return bytes([(tag << 4) | 0x08 | len(data)]) + data


def _bvlc(fn, payload):
    return struct.pack(">BBH", BVLC_TYPE, fn, 4 + len(payload)) + payload


def build_who_is(low=None, high=None, broadcast=True):
    apdu = bytes([APDU_UNCONFIRMED, SVC_WHO_IS])
    if low is not None and high is not None:
        apdu += _context_unsigned(0, low) + _context_unsigned(1, high)
    npdu = bytes([0x01, 0x00]) + apdu
    return _bvlc(FN_ORIGINAL_BROADCAST if broadcast else FN_ORIGINAL_UNICAST, npdu)


def build_read_bdt():
    return _bvlc(FN_READ_BDT, b"")


def build_read_fdt():
    return _bvlc(FN_READ_FDT, b"")


# ---------------------------------------------------------------------------
# Frame parsers
# ---------------------------------------------------------------------------

def _parse_bvlc(data):
    """Return (function_code, payload) or (None, None)."""
    if len(data) < 4 or data[0] != BVLC_TYPE:
        return None, None
    fn = data[1]
    (ln,) = struct.unpack(">H", data[2:4])
    return fn, data[4:ln] if ln <= len(data) else data[4:]


def _parse_i_am(apdu):
    """Return device instance from an I-Am APDU, or None."""
    if len(apdu) < 2 or apdu[0] != APDU_UNCONFIRMED or apdu[1] != SVC_I_AM:
        return None
    body = apdu[2:]
    if len(body) < 5 or body[0] != 0xC4:
        return None
    (objid,) = struct.unpack(">I", body[1:5])
    return (objid & 0x3FFFFF) if (objid >> 22) == 8 else None  # 8 = device object


def _extract_i_am(fn, payload):
    """Extract I-Am instance from a BVLL payload; return (instance_or_None, orig_addr_or_None)."""
    orig = None
    if fn in (FN_ORIGINAL_UNICAST, FN_ORIGINAL_BROADCAST):
        npdu = payload
    elif fn == FN_FORWARDED_NPDU:
        if len(payload) < 6:
            return None, None
        orig, npdu = payload[:6], payload[6:]
    else:
        return None, None

    if len(npdu) < 2:
        return None, orig

    ctrl, idx = npdu[1], 2
    if ctrl & 0x20:
        if len(npdu) < idx + 3:
            return None, orig
        idx += 3 + npdu[idx + 2]
    if ctrl & 0x08:
        if len(npdu) < idx + 3:
            return None, orig
        idx += 3 + npdu[idx + 2]
    if ctrl & 0x20:
        idx += 1
    return _parse_i_am(npdu[idx:]), orig


def _addr6(b):
    """Format 6-byte BACnet/IP address as 'A.B.C.D:0xPPPP'."""
    return f"{'.'.join(str(x) for x in b[:4])}:0x{(b[4]<<8)|b[5]:04X}"


def _parse_bdt_ack(data):
    fn, payload = _parse_bvlc(data)
    if fn != FN_READ_BDT_ACK:
        return None
    return [
        {"addr": _addr6(payload[i:i+6]), "mask": ".".join(str(b) for b in payload[i+6:i+10])}
        for i in range(0, len(payload) - 9, 10)
    ]


def _parse_fdt_ack(data):
    fn, payload = _parse_bvlc(data)
    if fn != FN_READ_FDT_ACK:
        return None
    return [
        {"addr": _addr6(payload[i:i+6]),
         "ttl_s": (payload[i+6] << 8) | payload[i+7],
         "remaining_s": (payload[i+8] << 8) | payload[i+9]}
        for i in range(0, len(payload) - 9, 10)
    ]


def _same_24(a, b):
    return a.split(".")[:3] == b.split(".")[:3]


# ---------------------------------------------------------------------------
# Socket / collect helpers
# ---------------------------------------------------------------------------

def _make_socket(src_port, timeout):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    except OSError:
        pass
    try:
        s.bind(("0.0.0.0", src_port))
    except OSError as e:
        print(f"corroborate-bacnet: ERROR — cannot bind :{src_port} ({e}); "
              "retry with --src-port 0", file=sys.stderr)
        sys.exit(2)
    s.settimeout(timeout)
    return s


def _collect(sock, deadline, want_iam=True):
    """Drain UDP responses until deadline; return list of (ip, port, fn, inst, fwd, raw)."""
    out = []
    while True:
        rem = deadline - time.monotonic()
        if rem <= 0:
            break
        sock.settimeout(max(0.01, rem))
        try:
            data, (rip, rport) = sock.recvfrom(1500)
        except (socket.timeout, OSError):
            break
        fn, payload = _parse_bvlc(data)
        if fn is None:
            continue
        inst, fwd = (_extract_i_am(fn, payload) if want_iam else (None, None))
        out.append((rip, rport, fn, inst, fwd, data))
    return out


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def _write(output_dir, doc):
    os.makedirs(output_dir, exist_ok=True)
    path = os.path.join(output_dir, "bacnet-evidence.v1.json")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")
    except OSError as e:
        print(f"corroborate-bacnet: ERROR — cannot write {path}: {e}", file=sys.stderr)
        sys.exit(2)
    return path


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description=(
            "BACnet/IP reachability and BBMD evidence probe (bacnet-evidence.v1). "
            "READ-ONLY. Requires --allow-live-probe to send real UDP frames."
        )
    )
    ap.add_argument("--host", required=True,
                    help="target BACnet/IP host (field device or BBMD IP)")
    ap.add_argument("--output", required=True,
                    help="output directory; bacnet-evidence.v1.json is written here")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT,
                    help=f"BACnet/IP UDP port (default {DEFAULT_PORT})")
    ap.add_argument("--src-port", type=int, default=0,
                    help="local UDP bind port (default 0 = ephemeral)")
    ap.add_argument("--local-bcast", default=None,
                    help="broadcast address of this interface (e.g. 192.168.1.255); "
                         "required for broadcast Who-Is test")
    ap.add_argument("--bbmd", default=None,
                    help="additional IP to probe as BBMD; --host is always probed")
    ap.add_argument("--timeout", type=float, default=3.0,
                    help="per-probe listen window in seconds (default 3.0)")
    ap.add_argument("--allow-live-probe", action="store_true",
                    help="send real BACnet/IP UDP frames; absent → exit 3 (plan-only)")
    ap.add_argument("--json", action="store_true",
                    help="also write evidence to stdout as JSON")
    args = ap.parse_args()

    # ------------------------------------------------------------------
    # PLAN-ONLY GUARD (CLAUDE.md §7 three states: plan-only / complete / error)
    # ------------------------------------------------------------------
    if not args.allow_live_probe:
        doc = {
            "schema": "bacnet-evidence.v1",
            "status": "plan-only",
            "host": args.host,
            "port": args.port,
            "guard": "live probe requires --allow-live-probe; no frames sent",
            "plan": {
                "protocol": "ANSI/ASHRAE 135 BACnet/IP",
                "read_only": True,
                "probes": ["unicast-who-is", "broadcast-who-is", "read-bdt", "read-fdt"],
                "note": "broadcast-who-is requires --local-bcast",
            },
        }
        _write(args.output, doc)
        if args.json:
            print(json.dumps(doc, indent=2, sort_keys=True))
        sys.exit(3)

    # ------------------------------------------------------------------
    # LIVE PROBE
    # ------------------------------------------------------------------
    sock = _make_socket(args.src_port, args.timeout)
    result = {
        "schema": "bacnet-evidence.v1",
        "status": "complete",
        "host": args.host,
        "port": args.port,
        "probes": {},
    }

    # 1 — directed unicast Who-Is (ICMP-equivalent, routed path)
    sock.sendto(build_who_is(broadcast=False), (args.host, args.port))
    r1 = _collect(sock, time.monotonic() + args.timeout)
    hits = [x for x in r1 if x[0] == args.host and x[3] is not None]
    result["probes"]["unicast_who_is"] = {
        "reachable": bool(hits),
        "instance": hits[0][3] if hits else None,
    }

    # 2 — local broadcast Who-Is (cross-subnet broadcast check)
    if args.local_bcast:
        sock.sendto(build_who_is(broadcast=True), (args.local_bcast, args.port))
        r2 = _collect(sock, time.monotonic() + args.timeout)
        resp = {}
        for rip, _, _, inst, _, _ in r2:
            if inst is not None:
                resp.setdefault(rip, set()).add(inst)
        crossed = {ip: sorted(v) for ip, v in resp.items() if _same_24(ip, args.host)}
        local   = {ip: sorted(v) for ip, v in resp.items() if not _same_24(ip, args.host)}
        result["probes"]["broadcast_who_is"] = {
            "local_bcast": args.local_bcast,
            "responders": {ip: sorted(v) for ip, v in resp.items()},
            "crossed_from_target_subnet": crossed,
            "same_as_local": local,
        }
    else:
        result["probes"]["broadcast_who_is"] = {
            "local_bcast": None,
            "note": "--local-bcast not provided; broadcast Who-Is skipped",
        }

    # 3 — Read-BDT / Read-FDT against candidate BBMDs
    candidates = list(dict.fromkeys(t for t in [args.host, args.bbmd] if t))
    bbmd_results = {}
    for tgt in candidates:
        sock.sendto(build_read_bdt(), (tgt, args.port))
        rb = _collect(sock, time.monotonic() + args.timeout, want_iam=False)
        entry = {"is_bbmd": False, "bdt": None, "fdt": None}
        for _, _, _, _, _, raw in rb:
            bdt = _parse_bdt_ack(raw)
            if bdt is not None:
                entry["is_bbmd"] = True
                entry["bdt"] = bdt
        if entry["is_bbmd"]:
            sock.sendto(build_read_fdt(), (tgt, args.port))
            rf = _collect(sock, time.monotonic() + args.timeout, want_iam=False)
            for _, _, _, _, _, raw in rf:
                fdt = _parse_fdt_ack(raw)
                if fdt is not None:
                    entry["fdt"] = fdt
        bbmd_results[tgt] = entry
    result["probes"]["bbmd_probe"] = bbmd_results
    sock.close()

    # Verdict
    unicast_ok   = result["probes"]["unicast_who_is"]["reachable"]
    bcast_ok     = bool(result["probes"]["broadcast_who_is"].get("crossed_from_target_subnet"))
    any_bbmd     = any(v["is_bbmd"] for v in bbmd_results.values())

    if bcast_ok or any_bbmd:
        code, verdict = "ok", (
            "REBIND OK — broadcast Who-Is reaches the target subnet"
            + (" (BBMD confirmed)" if any_bbmd else "")
            + ". Instance-based re-binding will work on an IP change."
        )
    elif unicast_ok:
        code, verdict = "rebind_fail", (
            "REBIND WILL FAIL — device responds to unicast but NOT broadcast Who-Is, "
            "and no BBMD answered. Configure a BBMD/Foreign-Device path or use a "
            "static IP / DHCP reservation."
        )
    else:
        code, verdict = "inconclusive", (
            "INCONCLUSIVE — device did not respond to directed unicast Who-Is. "
            "Verify --host, --port, firewall rules, and routing."
        )

    result["verdict_code"] = code
    result["verdict"]      = verdict

    _write(args.output, result)
    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if code == "ok" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OverflowError, OSError) as _exc:
        # Any unhandled socket/OS error from the live-probe path (e.g. bad port,
        # unresolvable host, ENETUNREACH, EPERM) is an operational error.
        # Exit 2 — no evidence file has been written at this point.
        print(f"corroborate-bacnet: ERROR — {_exc}", file=sys.stderr)
        sys.exit(2)
