"""Parity oracle for rsdd formats squashfs-extract: drives the frozen legacy squashfs_extract.py.

usage: python3 -I oracle_driver.py LEGACY_SQUASHFS_EXTRACT_PY TOOLBELT_DIR  < ops.json  > results.json

The legacy script imports adapter_core and isolation_profile from <its own dir>/lib; it now lives in testdata,
so the frozen toolbelt lib directory is put on sys.path first (the script's own sys.path insert then points at a
directory that does not exist, which is harmless).

ops: [{"op": "find", "data_hex": str}
      {"op": "walk", "root": str, "max_entries": int, "max_bytes": int}
      {"op": "closed", "stage": str, "files": [str], "dirs": [str]}
      {"op": "cli", "argv": [str]}]
result per op: {"ok": bool, "value": ..., "error": str}; for "cli": {"rc": int, "stderr": str}
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
from pathlib import Path

legacy_path, toolbelt = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(toolbelt, "lib"))
spec = importlib.util.spec_from_file_location("legacy_squashfs_extract", legacy_path)
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)

results = []
for op in json.load(sys.stdin):
    kind = op["op"]
    try:
        if kind == "find":
            results.append({"ok": True, "value": legacy.find_squashfs_offset(bytes.fromhex(op["data_hex"]))})
        elif kind == "walk":
            results.append({"ok": True, "value": legacy.walk_tree(Path(op["root"]), op["max_entries"], op["max_bytes"])})
        elif kind == "closed":
            legacy.validate_closed(Path(op["stage"]), set(op["files"]), set(op["dirs"]))
            results.append({"ok": True, "value": None})
        elif kind == "cli":
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                rc = legacy.main(op["argv"])
            results.append({"rc": rc, "stderr": err.getvalue()})
        else:
            results.append({"ok": False, "error": "unknown op " + kind})
    except Exception as exc:  # the legacy error classes carry the message the port must reproduce
        results.append({"ok": False, "error": str(exc), "class": type(exc).__name__})
json.dump(results, sys.stdout)
