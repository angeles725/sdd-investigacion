#!/usr/bin/env python3
"""Regenerate the jsonout golden fixtures from the REAL Python encoders.

Run as:  python3 -I regen.py [OUTDIR]     (default OUTDIR = this directory)

The three modes use the exact json.dumps arguments of the kit sources:
  canonical : research-sdd/toolbelt/lib/adapter_core.py:84      sort_keys, separators (",", ":")
  unicode   : research-sdd/toolbelt/analysis_manifest.py:45 and zip_metadata.py:22
              ensure_ascii=False + the canonical arguments
  indented  : the _write_json helpers (bog_nav.py:95, module_find.py:47, ...)  indent=2, sort_keys
Each ends with a newline and is written as UTF-8 bytes.
"""
import json
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
out = sys.argv[1] if len(sys.argv) > 1 else here
os.makedirs(out, exist_ok=True)
with open(os.path.join(here, "inputs.json"), encoding="utf-8") as fh:
    cases = json.load(fh)["cases"]

modes = {
    "canonical": lambda v: json.dumps(v, sort_keys=True, separators=(",", ":")) + "\n",
    "unicode": lambda v: json.dumps(v, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n",
    "indented": lambda v: json.dumps(v, indent=2, sort_keys=True) + "\n",
}
for case in cases:
    for mode, fn in modes.items():
        with open(os.path.join(out, "%s.%s.golden" % (case["name"], mode)), "wb") as fh:
            fh.write(fn(case["doc"]).encode("utf-8"))
