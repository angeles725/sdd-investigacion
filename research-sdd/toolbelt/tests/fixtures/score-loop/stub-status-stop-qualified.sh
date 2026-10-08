#!/usr/bin/env bash
# Fixture stub for research-sdd-status.sh (kit #1995): reports a declared, drained campaign queue and a
# `--next` verdict line taken verbatim from $STUB_STOP_LINE, so a test can feed score-loop-transcript.sh's C4
# any STOP form the real status script emits (bare, `[issue-coverage: unverified]`, `[backlog-unreadable: ...]`,
# `no active focus (...)`, `outline fully covered (...)`) or an unknown one.
if [[ "${2:-}" == "--next" ]]; then
  printf '%s\n' "${STUB_STOP_LINE:-STOP | read-only-investigable exhausted (0)}"
else
  echo "  campaign        : pending=0 active=0 done=2 bound-stopped=0 rejected=0"
fi
