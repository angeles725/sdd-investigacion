#!/usr/bin/env bash
# Fixture stub for research-sdd-status.sh: reports an active/pending campaign and a
# non-STOP --next result, used to test score-loop-transcript.sh's C4 "STOP honored"
# fail path (the STOP token was in the final return, but the corpus itself disagrees).
if [[ "${2:-}" == "--next" ]]; then
  echo "NEXT | high | some-open-gap"
else
  echo "  campaign        : pending=1 active=1 done=2 bound-stopped=0 rejected=0"
fi
