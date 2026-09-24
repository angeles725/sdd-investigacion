#!/usr/bin/env bash
# Fixture stub for research-sdd-status.sh: reports STOP + an empty campaign queue,
# used to test score-loop-transcript.sh's C4 "STOP honored" pass path without needing
# a fully-scaffolded research corpus (RESEARCH-STATE.md etc).
if [[ "${2:-}" == "--next" ]]; then
  echo "STOP | read-only-investigable exhausted (0)"
else
  echo "  campaign        : none"
fi
