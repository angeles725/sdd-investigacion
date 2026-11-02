"""Parity driver for internal/adapter/helpers: runs the REAL adapter_helpers.py and prints one JSON list.

usage: python3 -I parity_driver.py <toolbelt-dir> <op>   (JSON list of cases on stdin)

Ops: norm, parts, repr, normpath, realpath, schema, trunc, warn, safe_bind,
venv_root, bind, emit, consts. Each case yields {"ok", "class", "msg", "cause", "value"};
emit adds "stderr".
"""
import contextlib
import io
import json
import os
import sys
from pathlib import Path

toolbelt = sys.argv[1]
sys.path.insert(0, toolbelt)
sys.path.insert(0, os.path.join(toolbelt, "lib"))
import adapter_helpers as ah  # noqa: E402

op = sys.argv[2]
cases = json.load(sys.stdin)


def result(fn):
    try:
        return {"ok": True, "value": fn()}
    except Exception as exc:  # noqa: BLE001 - the class name is the contract
        cause = type(exc.__cause__).__name__ if exc.__cause__ is not None else ""
        return {"ok": False, "class": type(exc).__name__, "msg": str(exc), "cause": cause,
                "adapter": isinstance(exc, ah.AdapterError)}


def env(c):
    os.chdir(c["cwd"])
    os.environ["HOME"] = c["home"]


def do_realpath(c):
    os.chdir(c["cwd"])
    return result(lambda: os.path.realpath(c["path"]))


def do_safe_bind(c):
    env(c)
    return result(lambda: ah.assert_safe_bind_root(Path(c["path"])))


def do_venv_root(c):
    env(c)
    return result(lambda: str(ah.venv_root_for(Path(c["path"]))))


def do_bind(c):
    env(c)
    writable = [(Path(h), s) for h, s in c["writable"]]
    return result(lambda: ah.bind_venv(c["prefix"], Path(c["path"]),
                                       etc_ro_bind_try=tuple(c["etc"]), writable=writable))


def do_warn(c):
    buf = io.StringIO()
    with contextlib.redirect_stderr(buf):
        ah.warn_evidence(schema=c["schema"], destination=c["dest"], detail=c["detail"])
    return {"ok": True, "value": buf.getvalue()}


def do_emit(c):
    root = c["root"]
    buf = io.StringIO()

    def run():
        ah.emit_evidence(
            stage=Path(root + "/stage"), schema=c["schema"], domain=c["domain"],
            input_identity=c["input"], isolation=c["isolation"],
            limitations=c["limitations"], errors=c["errors"], manifest_spec=c["spec"],
            manifest_cli=Path(root + "/stub/stub.py"), destination=Path(root + "/" + c["dest"]),
            timeout=c["timeout"])

    with contextlib.redirect_stderr(buf):
        r = result(run)
    r["stderr"] = buf.getvalue()
    return r


ops = {
    "norm": lambda c: result(lambda: str(Path(c["s"]))),
    "parts": lambda c: result(lambda: list(Path(c["s"]).parts)),
    "repr": lambda c: result(lambda: repr(c["s"])),
    "normpath": lambda c: result(lambda: os.path.normpath(c["s"])),
    "realpath": do_realpath,
    "schema": lambda c: result(lambda: bool(ah._SAFE_SCHEMA_RE.match(c["s"]))),
    "trunc": lambda c: result(lambda: list(ah.run_truncation(c["errors"], c["tool"]))),
    "warn": do_warn,
    "safe_bind": do_safe_bind,
    "venv_root": do_venv_root,
    "bind": do_bind,
    "emit": do_emit,
    "consts": lambda c: result(lambda: {"pcap": sorted(m.hex() for m in ah._PCAP_MAGIC), "pcapng": ah._PCAPNG_MAGIC.hex()}),
}
json.dump([ops[op](c) for c in cases], sys.stdout)
