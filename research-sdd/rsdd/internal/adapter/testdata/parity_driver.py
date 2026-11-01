"""Parity driver for internal/adapter: runs the REAL adapter_core.py and prints one JSON list.

usage: python3 -I parity_driver.py <toolbelt-dir> <op>   (JSON list of cases on stdin)

Ops: creds, private, sandbox, executable, realpath, resolve, which, parts,
repr, splitlines, fields. Each case yields {"ok", "class", "msg", "value"}.
"""
import json
import os
import sys
from pathlib import Path

toolbelt = sys.argv[1]
sys.path.insert(0, toolbelt)
sys.path.insert(0, os.path.join(toolbelt, "lib"))
import adapter_core  # noqa: E402
import shutil  # noqa: E402

op = sys.argv[2]
cases = json.load(sys.stdin)
_RealPath = Path
_real_exists = os.path.exists


def result(fn):
    try:
        return {"ok": True, "value": fn()}
    except Exception as exc:  # noqa: BLE001 - the class name is the contract
        return {"ok": False, "class": type(exc).__name__, "msg": str(exc)}


def do_creds(c):
    os.geteuid, os.getuid = (lambda: c["euid"]), (lambda: c["uid"])
    os.getegid, os.getgid = (lambda: c["egid"]), (lambda: c["gid"])
    return result(lambda: adapter_core.refuse_privileged_execution())


def do_private(c):
    return result(lambda: adapter_core.require_private(_RealPath(c["path"]), c["mountinfo"]))


def do_sandbox(c):
    hidden = set(c.get("hide") or [])
    os.path.exists = lambda p: False if p in hidden else _real_exists(p)
    os.getuid = lambda: c["uid"]
    adapter_core.Path = lambda p, *a: _RealPath(c["root"] if p == "/tmp/rsdd" else p, *a)
    os.chdir(c["cwd"])
    env = {k: v for k, v in c["env"]}
    return result(lambda: adapter_core.sandbox(_RealPath(c["bwrap"]), env, c["ro"]))


def do_executable(c):
    os.chdir(c["cwd"])
    def run():
        path, rec = adapter_core.executable(c["name"], c["configured"], c["search"])
        return {"path": str(path), "record": rec}
    return result(run)


def do_realpath(c):
    os.chdir(c["cwd"])
    return result(lambda: os.path.realpath(c["path"]))


def do_resolve(c):
    os.chdir(c["cwd"])
    return result(lambda: str(Path(c["path"]).resolve(strict=True)))


def do_which(c):
    os.chdir(c["cwd"])
    return result(lambda: shutil.which(c["cmd"], path=c["search"]))


ops = {
    "creds": do_creds, "private": do_private, "sandbox": do_sandbox,
    "executable": do_executable, "realpath": do_realpath, "resolve": do_resolve,
    "which": do_which,
    "parts": lambda c: result(lambda: list(Path(c["s"]).parts)),
    "repr": lambda c: result(lambda: repr(c["s"])),
    "splitlines": lambda c: result(lambda: c["s"].splitlines()),
    "fields": lambda c: result(lambda: c["s"].split()),
}
json.dump([ops[op](c) for c in cases], sys.stdout)
