#!/usr/bin/env python3
"""Run the REAL frozen legacy zip_metadata.py / zip_stored.py parsers over a batch of cases for the Go parity tests.

Usage:  python3 -I parity_driver.py <legacy-dir> <op>      (JSON array on stdin, JSON array on stdout)

Ops (one result per input case, same order):
  inventory      {path, max_cd, max_entries, max_field, max_report}
                 -> {ok, canon, meta_sha256} | {ok:false, msg}     canon is zm.canonical(parsed) as text
  stored_inspect {path, max_metadata, max_entries, max_path, max_depth, max_entry, max_total, max_report}
                 -> {ok, canon} | {ok:false, msg}                  canon is zm.canonical(records) as text
  nfc            a string                      -> {value: unicodedata.normalize("NFC", s), cn: some character is unassigned (Cn) in this Python's Unicode}
  decode         {hex, enc}                    -> {value: bytes.fromhex(hex).decode(enc, errors="replace")}
  pyint          a string                      -> {ok, value} | {ok:false}    int(s) as argparse's type=int
  path           a string                      -> {name, parent}              pathlib.Path(s).name and str(.parent)
"""
import hashlib
import json
import os
import pathlib
import sys
import types
import unicodedata

legacy_dir, op = sys.argv[1], sys.argv[2]
sys.path.insert(0, legacy_dir)
import zip_metadata as zm  # noqa: E402
import zip_stored as zs  # noqa: E402


def fail(exc):
    return {"ok": False, "msg": str(exc), "class": type(exc).__name__}


def inventory(c):
    fd = os.open(c["path"], os.O_RDONLY)
    try:
        parsed, meta = zm.inventory(fd, os.fstat(fd).st_size, c["max_cd"], c["max_entries"], c["max_field"], c["max_report"])
        return {"ok": True, "canon": zm.canonical(parsed).decode(), "meta_sha256": hashlib.sha256(meta).hexdigest()}
    except Exception as exc:  # the oracle reports every failure class; the Go side compares the message
        return fail(exc)
    finally:
        os.close(fd)


def stored_inspect(c):
    fd = os.open(c["path"], os.O_RDONLY)
    args = types.SimpleNamespace(max_metadata_bytes=c["max_metadata"], max_entries=c["max_entries"], max_path_bytes=c["max_path"],
                                 max_depth=c["max_depth"], max_entry_bytes=c["max_entry"], max_total_bytes=c["max_total"],
                                 max_report_bytes=c["max_report"])
    try:
        records = zs.inspect(fd, os.fstat(fd).st_size, args)
        return {"ok": True, "canon": zm.canonical(records).decode()}
    except Exception as exc:
        return fail(exc)
    finally:
        os.close(fd)


def pyint(s):
    try:
        return {"ok": True, "value": int(s)}
    except ValueError:
        return {"ok": False}


ops = {
    "inventory": inventory,
    "stored_inspect": stored_inspect,
    "nfc": lambda s: {"value": unicodedata.normalize("NFC", s), "cn": any(unicodedata.category(ch) == "Cn" for ch in s)},
    "decode": lambda c: {"value": bytes.fromhex(c["hex"]).decode(c["enc"], errors="replace")},
    "pyint": pyint,
    "path": lambda p: {"name": pathlib.Path(p).name, "parent": str(pathlib.Path(p).parent)},
}
cases = json.load(sys.stdin)
json.dump([ops[op](c) for c in cases], sys.stdout)
