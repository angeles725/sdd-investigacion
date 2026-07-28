#!/usr/bin/env bash
# census-target.sh — file-type histogram over ALL files in a research target.
# BOOTSTRAP mandatory step a2 (METHODOLOGY §6). Run BEFORE building the coverage matrix.
#
# WHY: a coverage matrix built from what you already noticed cannot surface what you never
# looked at. This failure is not laziness — it is structural: if you populate the backlog
# from files that already drew your attention, the invisible corpus (Access databases nobody
# opened, Visio diagrams nobody printed, compiled DDC programs nobody counted) never enters
# any gap. One three-second command surfaces all of it.
#
# Usage:  census-target.sh <target-path> [--threshold-count N] [--threshold-mb M]
# Defaults: N=5 (types with >= N files are starred), M=1 (OR >= M MB aggregate are starred)
# Output:   extension histogram, count + aggregate MB, sorted by count descending.
#           A type exceeding either threshold is marked * — it must be either CLAIMED by a
#           gap in the backlog or DISMISSED in RESEARCH-STATE '## Dismissed file types'.
# Exit:   0 = ok (information tool; the audit obligation is on the researcher)
#         2 = bad args
set -uo pipefail

TARGET=""
THRESH_COUNT=5
THRESH_MB=1

# Parse: first non-flag positional is TARGET; --threshold-count and --threshold-mb are optional.
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold-count) THRESH_COUNT="${2:-5}"; shift 2;;
    --threshold-mb)    THRESH_MB="${2:-1}";    shift 2;;
    -h|--help)
      echo "usage: census-target.sh <target-path> [--threshold-count N] [--threshold-mb M]" >&2
      exit 0;;
    -*)
      echo "census-target: unknown flag: $1" >&2; exit 2;;
    *)
      if [ -z "$TARGET" ]; then TARGET="$1"; else echo "census-target: unexpected extra arg: $1" >&2; exit 2; fi
      shift;;
  esac
done

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "usage: census-target.sh <target-path> [--threshold-count N] [--threshold-mb M]" >&2
  exit 2
fi

THRESH_MB_BYTES=$(( THRESH_MB * 1048576 ))

echo "== File-type census: ${TARGET} =="
echo "   Threshold: >= ${THRESH_COUNT} files OR >= ${THRESH_MB} MB aggregate → starred (*)"
echo "   Starred types must be CLAIMED by a backlog gap OR DISMISSED with a reason."
echo ""
printf "  %-16s  %8s  %10s  %s\n" "Extension" "Files" "Size MB" "Flag"
printf "  %-16s  %8s  %10s  %s\n" "---------" "-----" "-------" "----"

# Collect size+path for every non-git file, then aggregate by extension.
# find -printf '%s %p\n' yields bytes then full path with zero subprocesses —
# one scan vs. one stat(1) per file. Path may contain spaces; awk reconstructs
# it as substr($0, length($1) + 2). The sort prefix keeps output stable.
# Stderr is captured so unreadable subtrees surface as a WARNING instead of
# silent undercounts — the structural failure this tool was built to prevent.
_ferr=$(mktemp)
find "$TARGET" -type f -not -path '*/.git/*' -printf '%s %p\n' 2>"$_ferr" \
  | awk -v tc="$THRESH_COUNT" -v tm="$THRESH_MB_BYTES" '
  {
    sz = $1
    # path = everything after the size field and one space
    path = substr($0, length($1) + 2)
    # extract basename (last path component)
    n = split(path, a, "/"); base = a[n]
    # extract extension: last .xxx where . is NOT the first character of basename
    # (so .dotfiles have no extension)
    if (match(base, /\.[^.]+$/) && RSTART > 1) {
      ext = tolower(substr(base, RSTART + 1))
    } else {
      ext = "(no ext)"
    }
    cnt[ext]++
    bytes[ext] += sz
  }
  END {
    for (e in cnt) {
      mb = bytes[e] / 1048576.0
      flag = (cnt[e] >= tc + 0 || bytes[e] >= tm + 0) ? "*" : ""
      # sort key: zero-padded count (descending after sort -rn)
      printf "%010d\t%-16s  %8d  %10.1f  %s\n", cnt[e], e, cnt[e], mb, flag
    }
  }' \
  | sort -rn \
  | sed 's/^[0-9]*\t/  /'
_unreadable=$(wc -l < "$_ferr")
rm -f "$_ferr"
if [ "$_unreadable" -gt 0 ]; then
  # Route to stdout so the warning travels with any captured output (e.g. `> census.txt` or
  # a paste into RESEARCH-STATE). An undercount invisible only on stderr is indistinguishable
  # from a clean census once the report is archived — the exact failure this tool was built
  # to prevent, re-entering one level up. Placement here (after the histogram, before the
  # audit-obligation block) keeps the caveat next to the numbers it qualifies.
  printf 'WARNING: %d path(s) could not be traversed (permission denied); counts above may undercount the corpus.\n' "$_unreadable"
fi

echo ""
echo "== Audit obligation for starred types (*) =="
echo "   Each starred type must appear in one of:"
echo "   1. A pending or covered gap in RESEARCH-STATE '## Gap-backlog' that explicitly"
echo "      names or encompasses this file type."
echo "   2. RESEARCH-STATE '## Dismissed file types' section:"
echo "      - .<ext> — <N> files · <M> MB — dismissed: <reason>"
echo "   A starred type in neither is an unclosed audit hole."
