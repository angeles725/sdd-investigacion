#!/usr/bin/env bash
# Fixture stub for research-sdd-status.sh: reports STOP, with one focus's campaign queue
# drained (alpha: pending=0 active=0) and a SIBLING focus's queue genuinely non-empty (beta:
# pending=1 active=0) — the exact shape from the round 2 BLOCKER report reproduced against
# tests/fixtures/campaign-queue/multi-focus-mixed (kit issue #1107). Used to test that
# score-loop-transcript.sh's C4 reads every labelled `campaign[<focus>] :` line rather than
# only the first: a real, still-open sibling queue must turn this into a `fail`, never a
# `pass` and never a false `n/a`.
if [[ "${2:-}" == "--next" ]]; then
  echo "STOP | read-only-investigable exhausted (0)"
else
  echo "  campaign[alpha] : pending=0 active=0 done=1 bound-stopped=0 rejected=0"
  echo "  campaign[beta]  : pending=1 active=0 done=0 bound-stopped=0 rejected=0"
fi
