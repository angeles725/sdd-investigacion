"""Parity driver for the Go bacnet tests: runs the REAL frozen legacy corroborate_bacnet.py frame builders and parsers
over a batch of cases in one process (argv: <legacy dir> <op>; stdin: JSON list of cases; stdout: JSON list)."""
import importlib
import json
import sys

sys.path.insert(0, sys.argv[1])
m = importlib.import_module("corroborate_bacnet")
op = sys.argv[2]
cases = json.load(sys.stdin)
out = []
for c in cases:
    if op == "build":
        k = c["kind"]
        if k == "unicast":
            b = m.build_who_is(broadcast=False)
        elif k == "broadcast":
            b = m.build_who_is(broadcast=True)
        elif k == "bdt":
            b = m.build_read_bdt()
        else:
            b = m.build_read_fdt()
        out.append({"hex": b.hex()})
    elif op == "parse":
        data = bytes.fromhex(c)
        fn, payload = m._parse_bvlc(data)
        r = {"fn": fn, "payload": None if payload is None else payload.hex()}
        inst, _ = m._extract_i_am(fn, payload) if fn is not None else (None, None)
        r["inst"] = inst
        r["bdt"] = m._parse_bdt_ack(data)
        r["fdt"] = m._parse_fdt_ack(data)
        out.append(r)
    elif op == "same24":
        out.append({"same": m._same_24(c[0], c[1])})
    else:
        raise SystemExit("unknown op " + op)
json.dump(out, sys.stdout)
