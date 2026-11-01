#!/usr/bin/env python3
"""Compatibility shim for bog_nav.py, ported to Go: `rsdd niagara bog-nav` (kit issue #2397).

bog-nav.sh and every other caller still run this path with `--input BOG --output JSON`. The extractor now
lives in research-sdd/rsdd/internal/niagara (the shared .bog reader plus the bog-nav command); this file only
hands the arguments to rsdd through lib/rsdd-exec.sh, the Phase 1 shim helper, which resolves $RSDD_BIN, then
<kit>/bin/rsdd, rebuilds when the Go sources are newer, and emits a typed `degraded: rsdd-unavailable` line
with exit 2 when no binary and no Go toolchain exist. It is removed in phase 8 with the other shims.
"""

import os
import sys

_SCRIPT = (
    '. "$1/lib/rsdd-exec.sh" 2>/dev/null || '
    '{ printf \'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\\n\' "$2" >&2; exit 2; }; '
    'shift 2; rsdd_exec niagara bog-nav "$@"'
)


def main():
    here = os.path.dirname(os.path.realpath(__file__))
    argv = ["bash", "-c", _SCRIPT, "bog-nav", here, os.path.join(here, "bog_nav.py")] + sys.argv[1:]
    try:
        os.execvp("bash", argv)
    except OSError as exc:
        sys.stderr.write("degraded: rsdd-unavailable — cannot exec bash: %s\n" % exc.strerror)
        sys.exit(2)


if __name__ == "__main__":
    main()
