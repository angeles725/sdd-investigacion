#!/usr/bin/env bash
# suite.sh — a fixture suite for job-budget.test.sh (kit issue #2338), copied beside a run-all.sh copy as
# <name>.test.sh. It does one "work" phase of its own, then a teeth batch of four jobs through lib/mutant.sh
# (default MUTANT_JOBS): every phase is one watch.sh run on the shared JB_LIVE dir, so the largest JB_PEAKS
# line is the most jobs that ran at once across every suite of the run.
set -uo pipefail
. "$(dirname "$0")/lib/mutant.sh"
me="$(basename "$0" .test.sh)"
bash "$JB_WATCH" "$JB_LIVE" "$me-work" 1 "$JB_PEAKS"
d="$(mktemp -d)"; c=0
v(){ [ "$2" = 0 ] || c=$((c + 1)); }
mutant_jobs_begin "$d" || exit 2
for n in 1 2 3 4; do mutant_job "t$n" bash "$JB_WATCH" "$JB_LIVE" "$me-t$n" 1 "$JB_PEAKS"; done
mutant_jobs_end c v
rm -rf "$d"
echo "== 1 passed · $c failed =="
[ "$c" -eq 0 ]
