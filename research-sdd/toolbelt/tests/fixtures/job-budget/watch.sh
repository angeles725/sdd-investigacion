#!/usr/bin/env bash
# watch.sh LIVE NAME BARRIER PEAKS — one measured "job" of job-budget.test.sh (kit issue #2338). It leaves the
# marker LIVE/NAME while it runs, waits (bound 10 s) until BARRIER markers exist, samples the marker count for
# 0.5 s, appends the most it saw to PEAKS and removes its marker: the largest PEAKS line is the concurrency.
# Without a reachable barrier a broken budget can only be MISSED on a slow host (a false PASS), never invented.
live="$1" name="$2" bar="$3" peaks="$4"
: > "$live/$name"
i=0; while [ "$(ls -A "$live" | wc -l)" -lt "$bar" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
p=0; i=0
while [ "$i" -lt 10 ]; do n="$(ls -A "$live" | wc -l)"; [ "$n" -gt "$p" ] && p="$n"; sleep 0.05; i=$((i + 1)); done
printf '%s\n' "$p" >> "$peaks"
rm -f "$live/$name"
