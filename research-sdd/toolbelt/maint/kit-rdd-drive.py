#!/usr/bin/env python3
"""kit-rdd-drive.py [--max-steps N] <cwd> <first-json-file>

Compatibility shim (kit issue #2394, epic #2270). Ported to Go: `rsdd maint rdd-drive`
(research-sdd/rsdd/internal/maint/rdddrive.go). The contract, the typed exit states and the allowlist are
documented there and pinned by tests/kit-rdd-drive.test.sh. This file stays a Python entry point only so that
its caller (maint/kit-pr-pipeline.sh) and the tool registry row keep working unchanged; it is removed in
phase 8 together with its caller.

The shim hands over to lib/rsdd-exec.sh (the canonical rsdd resolver: $RSDD_BIN, then <kit>/bin/rsdd, rebuilt
when the Go sources are newer) and never runs anything itself.
"""
import os
import sys

_SH = '. "$1/../lib/rsdd-exec.sh" 2>/dev/null || { echo "degraded: rsdd-unavailable - lib/rsdd-exec.sh missing" >&2; exit 3; }; shift; rsdd_exec maint rdd-drive "$@"'
os.execvp("bash", ["bash", "-c", _SH, "kit-rdd-drive", os.path.dirname(os.path.realpath(__file__))] + sys.argv[1:])
