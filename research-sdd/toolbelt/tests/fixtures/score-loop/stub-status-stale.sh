#!/usr/bin/env bash
# Fixture stub for research-sdd-status.sh: reports STALE on --next (RESEARCH-STATE
# internally inconsistent), used to test score-loop-transcript.sh's C4 degraded path
# when the corpus's own status instrument cannot be trusted.
if [[ "${2:-}" == "--next" ]]; then
  echo "STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh /synthetic"
else
  echo "  campaign        : none"
fi
