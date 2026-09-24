#!/usr/bin/env bash
# Fixture stub for research-sdd-status.sh: always fails (simulates a broken/misconfigured
# status instrument), used to test score-loop-transcript.sh's C4 degraded path.
echo "synthetic operational failure" >&2
exit 1
