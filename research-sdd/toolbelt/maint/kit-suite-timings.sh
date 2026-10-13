#!/usr/bin/env bash
# kit-suite-timings.sh — rank the gate's suites by wall time over the history run-all.sh appends (kit issue #2230).
#
# Usage: kit-suite-timings.sh [--file PATH] [--suite SUBSTR] [--top N]
#
#   --file PATH     history to read (default ${XDG_STATE_HOME:-$HOME/.local/state}/research-sdd/suite-timings.log).
#                   One row per suite per run: `<date> <head> <suite> <seconds> <rc>`.
#   --suite SUBSTR  only suites whose path contains SUBSTR.
#   --top N         print the N slowest by median (default 20, integer >= 1).
#
# Per suite: n (runs), median, p90 (nearest rank), max, in seconds, over the rows with rc 0 (a failing run can stop early and
# would understate the suite). Sorted by median, slowest first.
#
# Three states are told apart (CLAUDE.md section 7), each printed as a typed line on stdout with exit 0:
#   ABSENT-INPUT  the history file does not exist (no gate run has recorded timings)
#   EMPTY-INPUT   the file exists and has no rows
#   NO-MATCH      rows exist; none had rc 0 and matched the filter
# A row that is not `<date> <head> <suite> <number> <integer>` is counted as malformed and reported, never silently dropped.
# Exit: 0 report or a typed state above · 1 the file exists but cannot be read · 2 usage.
set -uo pipefail

file="${XDG_STATE_HOME:-${HOME:-}/.local/state}/research-sdd/suite-timings.log"
filter=""; top=20
while [ $# -gt 0 ]; do
  case "$1" in
    --file)  [ $# -ge 2 ] || { echo "kit-suite-timings: --file needs a value" >&2; exit 2; }; file="$2"; shift 2 ;;
    --suite) [ $# -ge 2 ] || { echo "kit-suite-timings: --suite needs a value" >&2; exit 2; }; filter="$2"; shift 2 ;;
    --top)   [ $# -ge 2 ] || { echo "kit-suite-timings: --top needs a value" >&2; exit 2; }; top="$2"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "kit-suite-timings: unknown argument '$1' (usage: kit-suite-timings.sh [--file PATH] [--suite SUBSTR] [--top N])" >&2; exit 2 ;;
  esac
done
case "$top" in ""|*[!0-9]*|0) echo "kit-suite-timings: --top must be an integer >= 1 (got '$top')" >&2; exit 2 ;; esac

if [ ! -e "$file" ]; then
  echo "kit-suite-timings: ABSENT-INPUT — $file not found (no gate run has recorded timings yet)"; exit 0
fi
if [ ! -f "$file" ] || [ ! -r "$file" ]; then
  echo "kit-suite-timings: $file is not a readable file" >&2; exit 1
fi
if [ ! -s "$file" ]; then
  echo "kit-suite-timings: EMPTY-INPUT — $file exists and has no rows"; exit 0
fi

# One awk pass: validate each row, keep rc 0 rows that match the filter, then per-suite sorted statistics.
report="$(awk -v filter="$filter" '
  NF == 0 { next }
  { total++ }
  NF != 5 || $4 !~ /^[0-9]+(\.[0-9]+)?$/ || $5 !~ /^[0-9]+$/ { bad++; next }
  $5 != 0 { failing++; next }
  filter != "" && index($3, filter) == 0 { next }
  { used++; n[$3]++; v[$3, n[$3]] = $4 + 0 }
  END {
    printf "ROWS %d %d %d %d\n", total, used, bad + 0, failing + 0
    for (s in n) {
      c = n[s]
      for (i = 2; i <= c; i++) { x = v[s, i]; j = i - 1; while (j >= 1 && v[s, j] > x) { v[s, j + 1] = v[s, j]; j-- } v[s, j + 1] = x }
      med = (c % 2) ? v[s, (c + 1) / 2] : (v[s, c / 2] + v[s, c / 2 + 1]) / 2
      r = int(0.9 * c); if (r < 0.9 * c) r++; if (r < 1) r = 1
      printf "SUITE %.1f %d %.1f %.1f %s\n", med, c, v[s, r], v[s, c], s
    }
  }' "$file")" || { echo "kit-suite-timings: could not read $file" >&2; exit 1; }

read -r _ total used bad failing <<<"$(grep -m1 '^ROWS ' <<<"$report")"
if [ "${used:-0}" -eq 0 ]; then
  echo "kit-suite-timings: NO-MATCH — $total row(s) read ($bad malformed, $failing with rc != 0); none had rc 0${filter:+ and a path containing '$filter'}"
  exit 0
fi
echo "kit-suite-timings: $file — $total row(s) read, $used used (rc 0${filter:+, path contains '$filter'}), $bad malformed skipped, $failing with rc != 0 not counted"
printf '%8s %5s %8s %8s  %s\n' median runs p90 max suite
grep '^SUITE ' <<<"$report" | LC_ALL=C sort -k2,2nr -k6,6 | awk -v t="$top" 'NR <= t' | while read -r _ med c p90 max s; do
  printf '%8s %5s %8s %8s  %s\n' "$med" "$c" "$p90" "$max" "$s"
done
exit 0
