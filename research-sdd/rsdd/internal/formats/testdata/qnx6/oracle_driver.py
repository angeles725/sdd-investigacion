"""Parity oracle for rsdd formats qnx6-read: runs the frozen legacy qnx6_read.py on a batch of cases.

usage: python3 -I oracle_driver.py LEGACY_QNX6_READ_PY  < cases.json  > results.json

cases: [{"op": "list"|"extract", "input": str, "output": str, "partition_offset": int, "fs_path": str}, ...]
result per case: {"rc": int, "stderr": str, "traceback": bool, "output_b64": str|null}
An exception that escapes the legacy command is what the real script turns into a traceback and exit 1.
"""
import argparse
import base64
import contextlib
import importlib.util
import io
import json
import os
import sys

spec = importlib.util.spec_from_file_location("legacy_qnx6", sys.argv[1])
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)

results = []
for case in json.load(sys.stdin):
    ns = argparse.Namespace(input=case["input"], output=case["output"],
                            partition_offset=case.get("partition_offset", 0), fs_path=case.get("fs_path"))
    err = io.StringIO()
    traceback = False
    with contextlib.redirect_stderr(err):
        try:
            rc = legacy.cmd_list(ns) if case["op"] == "list" else legacy.cmd_extract(ns)
        except BaseException:
            rc, traceback = 1, True
    out = None
    if os.path.isfile(case["output"]) and not os.path.islink(case["output"]):
        with open(case["output"], "rb") as f:
            out = base64.b64encode(f.read()).decode()
    results.append({"rc": rc, "stderr": err.getvalue(), "traceback": traceback, "output_b64": out})
json.dump(results, sys.stdout)
