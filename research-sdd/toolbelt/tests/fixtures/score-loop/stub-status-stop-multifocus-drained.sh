#!/usr/bin/env bash
# Fixture stub for research-sdd-status.sh: reports STOP, with TWO focuses each carrying a
# genuinely declared, fully-drained campaign queue — the LABELLED shape
# campaign_status_block() prints once more than one focus has a queue (kit issue #1107 round 2
# BLOCKER: `campaign[alpha] :` / `campaign[beta]  :`, never a single bare `campaign        :`
# line). Byte-shape matches the real script's printf (`'  %-16s: pending=%d active=%d
# done=%d bound-stopped=%d rejected=%d\n'` with `_cqb_flabel="[<slug>]"`) and the reviewer's
# reproduction against tests/fixtures/campaign-queue/multi-focus-mixed. Used to test
# score-loop-transcript.sh's C4 "STOP honored" pass path across ALL matching lines, not just
# the first.
if [[ "${2:-}" == "--next" ]]; then
  echo "STOP | read-only-investigable exhausted (0)"
else
  echo "  campaign[alpha] : pending=0 active=0 done=1 bound-stopped=0 rejected=0"
  echo "  campaign[beta]  : pending=0 active=0 done=1 bound-stopped=0 rejected=0"
fi
