"""Parity driver for internal/core/proc: runs the REAL adapter_core.run_bounded and prints one JSON object.

usage: python3 -I parity_driver.py <toolbelt-dir> <cwd> <timeout-s> <max-bytes> <argv...>

<cwd> must exist; the driver creates <cwd>/engine for run_bounded's output files. The Go parity test
runs core/proc.Run on the same command and compares.
"""
import base64
import json
import os
import sys

toolbelt, cwd, timeout, max_bytes, argv = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5:]
sys.path.insert(0, os.path.join(toolbelt, "lib"))
import adapter_core  # noqa: E402
from pathlib import Path  # noqa: E402

root = Path(cwd)
(root / "engine").mkdir()
try:
    record, errors = adapter_core.run_bounded(argv, root, {"PATH": "/usr/bin:/bin"}, timeout, max_bytes)
except OSError as exc:
    print(json.dumps({"ok": False, "class": type(exc).__name__}))
    sys.exit(0)


def b64(name):
    return base64.b64encode((root / "engine" / name).read_bytes()).decode()


print(json.dumps({"ok": True, "errors": errors, "exit_code": record["exit_code"], "signal": record["signal"],
                  "stdout": b64("stdout.txt"), "stderr": b64("stderr.txt")}))
