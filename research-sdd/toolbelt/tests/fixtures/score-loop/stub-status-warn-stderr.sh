#!/usr/bin/env bash
# Fixture stub for research-sdd-status.sh: reports STOP + an empty campaign queue on stdout,
# same as stub-status-stop-empty.sh, but ALSO writes a WARN line to stderr on every invocation.
# Used to test score-loop-transcript.sh's C4: a stderr WARN must never leak into the stdout
# string that ^STOP/^STALE are matched against (round 3 RDD fix).
if [[ "${2:-}" == "--next" ]]; then
  echo "WARN: synthetic stall notice (this must stay on stderr, never merged into stdout)" >&2
  echo "STOP | read-only-investigable exhausted (0)"
else
  echo "WARN: synthetic drift notice (this must stay on stderr, never merged into stdout)" >&2
  echo "  campaign        : none"
fi
