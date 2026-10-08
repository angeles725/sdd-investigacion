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
# Usage:  census-target.sh <target-path> [--threshold-count N] [--threshold-mb M] [--state <RESEARCH-STATE.md>]
# Defaults: N=5 (types with >= N files are starred), M=1 (OR >= M MB aggregate are starred)
# Output:   extension histogram, count + aggregate MB, sorted by count descending.
#           A type exceeding either threshold is marked * — it must be either CLAIMED by a
#           gap in the backlog or DISMISSED in RESEARCH-STATE '## Dismissed file types'.
# --state (kit #965): cross-check every starred type against the state file's '## Gap-backlog'
#           and '## Dismissed file types' sections. WARN-only (exit stays 0). One typed
#           'Audit cross-check:' line: OK | WARNING (names the unclosed types) | NO-STARRED |
#           INHERITED (declared inherited census, read only from the Dismissed section) |
#           DEGRADED (state absent, state not readable, or neither section present) | not run
#           (no --state). HTML comments and fenced blocks are ignored (template text claims
#           nothing). The match is a LITERAL type name as a standalone token (case-insensitive;
#           'notes.js' / 'x.js.map' claim nothing; types of 1-2 characters need their leading
#           dot; '(no ext)' for extensionless files). --state '' exits 2. A gap that
#           encompasses a type without naming it ("all images") is reported as a WARNING and
#           must be confirmed by hand — the instrument reports what it matched, not what a
#           human would read as covered.
# Exit:   0 = ok (information tool; the audit obligation is on the researcher)
#         2 = bad args
set -uo pipefail

TARGET=""
THRESH_COUNT=5
THRESH_MB=1
STATE=""

# Parse: first non-flag positional is TARGET; --threshold-count and --threshold-mb are optional.
while [ $# -gt 0 ]; do
  case "$1" in
    --threshold-count) THRESH_COUNT="${2:-5}"; shift 2;;
    --threshold-mb)    THRESH_MB="${2:-1}";    shift 2;;
    --state)
      if [ $# -lt 2 ] || [ -z "$2" ]; then echo "census-target: --state needs a non-empty path" >&2; exit 2; fi
      STATE="$2"; shift 2;;
    -h|--help)
      echo "usage: census-target.sh <target-path> [--threshold-count N] [--threshold-mb M] [--state <RESEARCH-STATE.md>]" >&2
      exit 0;;
    -*)
      echo "census-target: unknown flag: $1" >&2; exit 2;;
    *)
      if [ -z "$TARGET" ]; then TARGET="$1"; else echo "census-target: unexpected extra arg: $1" >&2; exit 2; fi
      shift;;
  esac
done

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "usage: census-target.sh <target-path> [--threshold-count N] [--threshold-mb M] [--state <RESEARCH-STATE.md>]" >&2
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
_hist=$(find "$TARGET" -type f -not -path '*/.git/*' -printf '%s %p\n' 2>"$_ferr" \
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
  | sed 's/^[0-9]*\t/  /')
[ -n "$_hist" ] && printf '%s\n' "$_hist"
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

# --- Audit cross-check (kit #965) -------------------------------------------------------------
# Starred rows end in '*'; the extension is every field before the trailing count/size/flag
# triple ('(no ext)' spans two fields).
echo ""
if [ -z "$STATE" ]; then
  echo "Audit cross-check: not run (pass --state <RESEARCH-STATE.md> to cross-check starred types against the backlog and Dismissed file types)"
  exit 0
fi
if [ ! -e "$STATE" ]; then
  echo "Audit cross-check: DEGRADED — state file absent (${STATE}); starred types were NOT cross-checked"
  exit 0
fi
if [ ! -f "$STATE" ] || [ ! -r "$STATE" ]; then
  echo "Audit cross-check: DEGRADED — state file not readable (${STATE}; a directory or no read permission); starred types were NOT cross-checked"
  exit 0
fi
_stars=$(printf '%s\n' "$_hist" | awk 'NF >= 4 && $NF == "*" { e = ""; for (i = 1; i <= NF - 3; i++) e = e (i > 1 ? " " : "") $i; print e }')
# Live text = the state file minus HTML comments (single- and multi-line; template text lives
# there) and fenced blocks (examples). A heading inside either is therefore not a section.
_live=$(awk '
  { line = $0; out = ""
    while (length(line) > 0) {
      if (inc) { i = index(line, "-->"); if (i == 0) line = ""; else { line = substr(line, i + 3); inc = 0 } }
      else { i = index(line, "<!--"); if (i == 0) { out = out line; line = "" } else { out = out substr(line, 1, i - 1); line = substr(line, i + 4); inc = 1 } }
    }
    if (out ~ /^[[:space:]]*(```|~~~)/) { fence = !fence; next }
    if (!fence) print out
  }' "$STATE")
# Claim text = the two sections that can close the obligation (any other section is out of scope).
_claims=$(awk '/^##[[:space:]]/ { p = ($0 ~ /^##[[:space:]]+(Gap-backlog|Dismissed file types)/) } p' <<<"$_live")
_dismissed=$(awk '/^##[[:space:]]/ { p = ($0 ~ /^##[[:space:]]+Dismissed file types/) } p' <<<"$_live")
_has_backlog=no; grep -qE '^##[[:space:]]+Gap-backlog' <<<"$_live" && _has_backlog=yes
_has_dismissed=no; grep -qE '^##[[:space:]]+Dismissed file types' <<<"$_live" && _has_dismissed=yes
if [ "$_has_backlog" = no ] && [ "$_has_dismissed" = no ]; then
  echo "Audit cross-check: DEGRADED — state has neither a '## Gap-backlog' nor a '## Dismissed file types' section outside comments and fenced blocks (${STATE}); no claim could be read"
  exit 0
fi
if [ -z "$_stars" ]; then
  echo "Audit cross-check: NO-STARRED — no type met the thresholds; nothing to cross-check"
  exit 0
fi
_total=$(printf '%s\n' "$_stars" | wc -l)
if grep -qiE '^[[:space:]]*-[[:space:]]*none[[:space:]]+(—|--)[[:space:]]+census inherited' <<<"$_dismissed"; then
  echo "Audit cross-check: INHERITED — Dismissed file types declares a census inherited from the parent corpus; ${_total} starred type(s) not cross-checked here"
  exit 0
fi
# A claim is a standalone type token in live prose: not preceded by an alphanumeric, '_', '.', '/'
# or '-' (so 'notes.js', 'a/js' and 'non-js' claim nothing), not followed by an alphanumeric or
# '_' or by '.'+alphanumeric (so 'x.js.map' claims nothing, a sentence-final '.js.' does). Types
# of 1-2 characters need their leading dot ('c', 'js' as bare words are ordinary prose).
_lead='(^|[^[:alnum:]_./-])'
_trail='([^[:alnum:]_.]|\.([^[:alnum:]_]|$)|$)'
_holes=""; _nholes=0
while IFS= read -r _e; do
  [ -n "$_e" ] || continue
  if [ "$_e" = "(no ext)" ]; then
    grep -qiF -- "(no ext)" <<<"$_claims" && continue
  else
    # Escape regex metacharacters in the extension.
    _re=$(printf '%s' "$_e" | sed 's/[][\.*^$+?(){}|/-]/\\&/g')
    if [ "${#_e}" -le 2 ]; then _dot='\.'; else _dot='\.?'; fi
    grep -qiE -- "${_lead}${_dot}${_re}${_trail}" <<<"$_claims" && continue
  fi
  _nholes=$((_nholes + 1))
  if [ "$_e" = "(no ext)" ]; then _holes="${_holes} (no ext)"; else _holes="${_holes} .${_e}"; fi
done <<< "$_stars"
if [ "$_nholes" -gt 0 ]; then
  echo "Audit cross-check: WARNING: ${_nholes} of ${_total} starred type(s) named in neither Gap-backlog nor Dismissed file types:${_holes}"
  echo "   (literal-name match only: a gap that encompasses a type without naming it must be confirmed by hand)"
else
  echo "Audit cross-check: OK — all ${_total} starred type(s) are named in Gap-backlog or Dismissed file types (by literal name; a type named in a gap that does not cover it still reads OK)"
fi
[ "$_has_dismissed" = no ] && echo "   note: state has no '## Dismissed file types' section"
exit 0
