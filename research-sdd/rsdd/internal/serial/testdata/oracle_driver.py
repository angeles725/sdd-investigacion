"""Parity oracle for rsdd serial serial-frame-analyze / serial-frame-capture: runs the frozen legacy scripts.

usage: python3 -I oracle_driver.py LEGACY_ANALYZE_PY LEGACY_CAPTURE_PY < cases.json > results.json

cases: [{"tool": "analyze"|"capture", "argv": [...], "outputs": {"json": path, "log": path},
         "script": {"<baud>"|"default": [[hex, advance_seconds] | {"err": text}, ...]}, "fail_open": [baud, ...]}, ...]
result per case: {"rc": int, "stderr": str, "traceback": bool, "outputs": {name: b64 | null}}

The capture module is run against a stub `serial` module and a fake time.monotonic: a stub port serves its
script one read at a time, moving the fake clock by the step's advance (or by its own timeout once the script is
spent), so the live paths are deterministic. Output paths are read back after each case.
"""
import base64
import contextlib
import importlib.util
import io
import json
import os
import sys
import time
import types


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


analyze = load("legacy_analyze", sys.argv[1])
capture = load("legacy_capture", sys.argv[2])

clock = [1000.0]
time.monotonic = lambda: clock[0]
CASE = {}


class SerialException(OSError):
    pass


class Serial:
    def __init__(self, port, baud, **kw):
        if baud in CASE.get("fail_open", []):
            raise SerialException(f"stub open failed at {baud}")
        script = CASE.get("script", {})
        steps = script.get(str(baud), script.get("default", []))
        self.steps = list(steps)
        self.timeout = kw["timeout"]

    def read(self, n):
        if not self.steps:
            clock[0] += self.timeout
            return b""
        step = self.steps.pop(0)
        if isinstance(step, dict):
            raise SerialException(step["err"])
        data, advance = step
        clock[0] += advance
        return bytes.fromhex(data)

    def close(self):
        pass


stub = types.ModuleType("serial")
stub.Serial, stub.SerialException = Serial, SerialException
sys.modules["serial"] = stub

results = []
for case in json.load(sys.stdin):
    CASE.clear()
    CASE.update(case)
    clock[0] = 1000.0
    mod = analyze if case["tool"] == "analyze" else capture
    sys.argv = ["legacy"] + case["argv"]
    err = io.StringIO()
    traceback = False
    with contextlib.redirect_stderr(err):
        try:
            rc = mod.main()
        except SystemExit as exc:
            rc = exc.code if isinstance(exc.code, int) else 1
        except BaseException:
            rc, traceback = 1, True
    outs = {}
    for name, path in case.get("outputs", {}).items():
        if os.path.isfile(path) and not os.path.islink(path):
            with open(path, "rb") as f:
                outs[name] = base64.b64encode(f.read()).decode()
        else:
            outs[name] = None
    results.append({"rc": rc, "stderr": err.getvalue(), "traceback": traceback, "outputs": outs})
json.dump(results, sys.stdout)
