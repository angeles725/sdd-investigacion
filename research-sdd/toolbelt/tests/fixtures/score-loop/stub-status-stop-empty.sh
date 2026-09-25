#!/usr/bin/env bash
# Fixture stub for research-sdd-status.sh: reports STOP + a GENUINELY DECLARED, fully-drained
# campaign queue (pending=0 active=0), used to test score-loop-transcript.sh's C4 "STOP honored"
# pass path without needing a fully-scaffolded research corpus (RESEARCH-STATE.md etc). Must
# stay a declared-and-drained shape, not the undeclared "none (...)" shape (kit issue #1107) —
# see stub-status-stop-no-queue.sh for that one, which is what a real "no queue was ever
# declared" corpus reports.
if [[ "${2:-}" == "--next" ]]; then
  echo "STOP | read-only-investigable exhausted (0)"
else
  echo "  campaign        : pending=0 active=0 done=2 bound-stopped=0 rejected=0"
fi
