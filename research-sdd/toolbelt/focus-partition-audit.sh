#!/usr/bin/env bash
# focus-partition-audit.sh — cross-check FOCUSES.md against the subject-tree UNIT universe.
# Usage: focus-partition-audit.sh <corpus-dir> --subject <root> [--depth N] [--ext csv] [--top N]
#        [--focuses-file <path>]
#
# Answers a different question than coverage-map.sh: coverage-map asks "did a corpus BLOCK ever
# cite this module?" (evidence a claim was made). This asks "does ANY FOCUSES.md row CHARTER this
# module to a focus at all?" (evidence the module is even someone's job) — the corpus-level
# partition check kit issue #1105 names: a per-focus coverage audit proves each focus is
# internally complete, never that the whole artifact universe is partitioned across any focus
# (niagara-research 2026-09-14-module-mechanics-coverage-run-retro D1: 3+ focused runs closed
# "modules done" while 30 of 664 module dirs were never chartered to any focus).
#
# unit      = directory at --depth under --subject containing >=1 file with a listed extension —
#             the exact same definition coverage-map.sh uses for --depth/--ext (default depth=1,
#             ext=java); pass --depth/--ext to change the unit granularity for a non-Java target.
# family    = units sharing the maximal run of ASCII lowercase letters at the START of their
#             basename (the text before the first uppercase letter, digit, or non-letter) — e.g.
#             lonAaon/lonAbb/lonActech share family "lon". A basename whose leading run is under
#             3 chars (or absent, e.g. it starts uppercase) is its own singleton family. This is
#             an ADVISORY grouping for readable rollups only — verify by hand (CLAUDE.md §7); it
#             is not a claim about which modules are actually related.
# chartered = a unit's basename appears, as an EXACT token, inside a FOCUSES.md backtick-code
#             span (`` `like-this` ``) from a CLASSIFIED table row, either as the whole span or as
#             one of the span's '/'-separated components. Bare mentions in ordinary prose NEVER
#             count — measured against the real niagara-research FOCUSES.md (2026-09-25): it uses
#             plain English words ("schedule", "event", "converters"...) as BOTH real module
#             basenames and as ordinary prose/method-call fragments in the very same file
#             (`` `Clock.schedule` `` — java.util.Clock's method, nothing to do with the `schedule`
#             module). Splitting the span on '.' as well as '/' turns that one span into a false
#             "schedule" charter; splitting ONLY on '/' avoids it while still catching genuine
#             path-style citations (`` `organized/<module>/...` ``). Direct analogue of
#             coverage-map.sh's "bare stems never count" (METHODOLOGY §3), applied to
#             charter-declaration prose instead of block citations.
#
# Four/five distinguishable states (CLAUDE.md §7 — absent/empty/no-match/unclassifiable, plus the
# runtime probe's degraded):
#   subject absent/not-traversable            -> "subject: absent-input ..."   exit 1
#   subject present, 0 class-file units       -> "subject: empty-input ..."    exit 0
#   FOCUSES.md absent (default or --focuses-file) -> "focuses: absent-input ..." exit 0 — most
#       targets are single-focus and legitimately carry no FOCUSES.md; every unit is reported
#       unchartered rather than a silent zero (the file was never read, so it never gets to claim
#       otherwise).
#   FOCUSES.md present, 0 classified+unclassifiable table rows -> "focuses: empty-input ..." exit 0
#   FOCUSES.md has classified rows, 0 chartering tokens         -> "focuses: no-match ..."   exit 0
#   A table row missing its identity (Focus) cell is UNCLASSIFIABLE: counted and reported, never
#   silently absorbed into or dropped from the classified total (§7 false-negative direction).
#
# Read-only, propose-never-apply: never writes to corpus-dir or subject (CLAUDE.md §8).
#
# Exit: 0 ok (findings included) · 1 operational failure (subject not traversable) ·
#       2 bad arguments · 3 degraded (a required PATH tool is missing)
set -uo pipefail

# ---------- runtime-dependency probe (CLAUDE.md §7 — could the instrument even run?)
# Only POSIX-mandated core utilities are used (find/awk/grep/sort/sed) — no jq/git/python3/
# compiled-tool dependency. Probed explicitly anyway: a missing one should surface as a typed
# `degraded` exit, not a confusing mid-run crash that looks like a false empty/zero finding.
for _fpa_dep in find awk grep sort sed; do
  # SENTINEL-H: dependency probe (drop this loop body to swallow a missing tool as a silent pass)
  if ! command -v "$_fpa_dep" >/dev/null 2>&1; then
    printf 'degraded: %s not found in PATH\n' "$_fpa_dep" >&2
    exit 3
  fi
done

# ---------- defaults
DEPTH=1
EXT_CSV="java"
TOP=0
SUBJECT=""
CORPUS_DIR=""
FOCUSES_FILE=""
FOCUSES_FILE_EXPLICIT=0

# ---------- argument parsing
if [ $# -eq 0 ]; then
  printf 'Usage: focus-partition-audit.sh <corpus-dir> --subject <root> [--depth N] [--ext csv] [--top N] [--focuses-file <path>]\n' >&2
  exit 2
fi
CORPUS_DIR="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    --subject)       [ $# -ge 2 ] || { printf 'FATAL: --subject requires a value\n' >&2; exit 2; }
                     SUBJECT="$2"; shift 2 ;;
    --depth)         [ $# -ge 2 ] || { printf 'FATAL: --depth requires a value\n' >&2; exit 2; }
                     DEPTH="$2"; shift 2 ;;
    --ext)           [ $# -ge 2 ] || { printf 'FATAL: --ext requires a value\n' >&2; exit 2; }
                     EXT_CSV="$2"; shift 2 ;;
    --top)           [ $# -ge 2 ] || { printf 'FATAL: --top requires a value\n' >&2; exit 2; }
                     TOP="$2"; shift 2 ;;
    --focuses-file)  [ $# -ge 2 ] || { printf 'FATAL: --focuses-file requires a value\n' >&2; exit 2; }
                     FOCUSES_FILE="$2"; FOCUSES_FILE_EXPLICIT=1; shift 2 ;;
    *) printf 'FATAL: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [ -z "$SUBJECT" ]; then
  printf 'FATAL: --subject is required\n' >&2; exit 2
fi

# ---------- three-state: subject root absent or not traversable
if [ ! -d "$SUBJECT" ] || [ ! -x "$SUBJECT" ]; then
  printf 'subject: absent-input (%s not traversable)\n' "$SUBJECT"
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---------- extension list (one per line)
printf '%s\n' "$EXT_CSV" | tr ',' '\n' | grep -v '^$' > "$TMP/exts.txt"

# ---------- find units: dirs at --depth under --subject containing >=1 file with listed ext
# (identical definition/loop to coverage-map.sh --depth/--ext, so the two tools agree on "unit")
: > "$TMP/units.txt"
while IFS= read -r dir; do
  while IFS= read -r ext; do
    if find "$dir" -maxdepth 999 -type f -name "*.${ext}" -print -quit 2>/dev/null | grep -q .; then
      printf '%s\n' "$dir" >> "$TMP/units.txt"
      break
    fi
  done < "$TMP/exts.txt"
done < <(find "$SUBJECT" -mindepth "$DEPTH" -maxdepth "$DEPTH" -type d 2>/dev/null | sort)

TOTAL=$(wc -l < "$TMP/units.txt" | tr -d ' ')

# ---------- three-state: subject empty for the listed extensions
if [ "$TOTAL" -eq 0 ]; then
  printf 'subject: empty-input (0 class-file units)\n'
  printf 'FOCUSES.md rows: 0 classified, 0 unclassifiable (source: n/a)\n'
  printf 'chartering tokens: 0\n'
  printf 'units: 0/0 chartered \xc2\xb7 0 unchartered\n'
  printf 'families: 0 total \xc2\xb7 0 fully-unchartered\n'
  exit 0
fi

# ---------- resolve FOCUSES.md location
if [ "$FOCUSES_FILE_EXPLICIT" -eq 0 ]; then
  FOCUSES_FILE="$CORPUS_DIR/FOCUSES.md"
fi

: > "$TMP/row_cells.txt"
ROWS_CLASSIFIED=0
ROWS_UNCLASSIFIABLE=0

if [ ! -f "$FOCUSES_FILE" ]; then
  printf 'focuses: absent-input (no FOCUSES.md at %s)\n' "$FOCUSES_FILE"
else
  # ---------- parse FOCUSES.md as a markdown table: first non-separator '|' line is the header,
  # every later '|' line is a data row. A data row's FIRST cell is its identity (Focus name);
  # empty after markup-strip (backtick/bold), or fewer than 2 cells, makes the row UNCLASSIFIABLE
  # (counted, excluded from the charter-token corpus — never silently merged into "classified").
  awk -v cellfile="$TMP/row_cells.txt" -v countfile="$TMP/row_counts.txt" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function strip_markup(s,   r) {
      r = trim(s)
      gsub(/\*\*/, "", r)
      sub(/^`/, "", r); sub(/`$/, "", r)
      return trim(r)
    }
    BEGIN { hdone = 0; classified = 0; unclass = 0 }
    {
      if (index($0, "|") == 0) next
      line = $0
      sub(/^\|/, "", line); sub(/\|$/, "", line)
      n = split(line, a, "|")
      issep = 1
      for (k = 1; k <= n; k++) { if (trim(a[k]) !~ /^:?-+:?$/) { issep = 0; break } }
      if (issep) next
      if (!hdone) { hdone = 1; next }
      # SENTINEL-F: unclassifiable-row gate (identity cell required; loosen to n<1 to mutate)
      ident = (n >= 1) ? strip_markup(a[1]) : ""
      if (n < 2 || ident == "") { unclass++; next }
      classified++
      for (k = 1; k <= n; k++) print trim(a[k]) > cellfile
    }
    END { printf "%d\t%d\n", classified, unclass > countfile }
  ' "$FOCUSES_FILE"
  if [ -f "$TMP/row_counts.txt" ]; then
    read -r ROWS_CLASSIFIED ROWS_UNCLASSIFIABLE < "$TMP/row_counts.txt"
  fi
fi

printf 'FOCUSES.md rows: %d classified, %d unclassifiable (source: %s)\n' \
  "$ROWS_CLASSIFIED" "$ROWS_UNCLASSIFIABLE" "${FOCUSES_FILE:-n/a}"

# ---------- three-state: FOCUSES.md present but zero table rows at all (classified or not)
if [ "$ROWS_CLASSIFIED" -eq 0 ] && [ "$ROWS_UNCLASSIFIABLE" -eq 0 ] && [ -f "$FOCUSES_FILE" ]; then
  printf 'focuses: empty-input (0 table rows in %s)\n' "$FOCUSES_FILE"
fi

# ---------- extract chartering tokens: backtick spans from CLASSIFIED rows only, split on '/'
# only. SENTINEL-C: do not add '.'/'-'/'_' to the split class — see header comment, Clock.schedule.
# Each candidate (whole span, or a '/'-separated piece of it) must look like a bare identifier —
# SENTINEL-B: the backtick requirement itself is what keeps ordinary prose from ever counting;
# loosening this to scan raw cell prose (not just backtick spans) reintroduces exactly the
# Clock.schedule-style false charter this tool exists to avoid.
grep -oE '`[^`]+`' "$TMP/row_cells.txt" 2>/dev/null \
  | sed -e 's/^`//' -e 's/`$//' \
  | awk -F'/' '{ for (i = 1; i <= NF; i++) print $i }' \
  | grep -E '^[A-Za-z][A-Za-z0-9_.-]*$' \
  | sort -u > "$TMP/charter_tokens.txt"
TOKEN_COUNT=$(wc -l < "$TMP/charter_tokens.txt" | tr -d ' ')
printf 'chartering tokens: %d\n' "$TOKEN_COUNT"

if [ "$TOKEN_COUNT" -eq 0 ] && [ "$ROWS_CLASSIFIED" -gt 0 ]; then
  printf 'focuses: no-match (0 chartering tokens found in %d classified row(s))\n' "$ROWS_CLASSIFIED"
fi

# ---------- per-unit basenames (one per line, same order as units.txt)
: > "$TMP/mod_basenames.txt"
while IFS= read -r unit; do
  basename "$unit" >> "$TMP/mod_basenames.txt"
done < "$TMP/units.txt"

# ---------- chartered / unchartered classification
: > "$TMP/chartered.txt"
: > "$TMP/uncharted.txt"
while IFS= read -r unit; do
  mod="$(basename "$unit")"
  # SENTINEL-D: exact-token equality (loosen to substring/-F to mutate — e.g. "modbus" would
  # then falsely "charter" "modbusCore" via substring containment)
  if grep -qxF "$mod" "$TMP/charter_tokens.txt" 2>/dev/null; then
    printf '%s\n' "$mod" >> "$TMP/chartered.txt"
  else
    fc=0
    while IFS= read -r ext; do
      n=$(find "$unit" -type f -name "*.${ext}" 2>/dev/null | wc -l)
      fc=$((fc + n))
    done < "$TMP/exts.txt"
    printf '%d\t%s\n' "$fc" "$mod" >> "$TMP/uncharted.txt"
  fi
done < "$TMP/units.txt"

CHARTERED=$(wc -l < "$TMP/chartered.txt" | tr -d ' ')
# SENTINEL-A: unchartered count (mutant target — hardcode to 0)
UNCHARTERED=$(wc -l < "$TMP/uncharted.txt" | tr -d ' ')

if [ "$CHARTERED" -eq 0 ]; then
  printf 'no-match (%d units, 0 chartered)\n' "$TOTAL"
fi
printf 'units: %d/%d chartered \xc2\xb7 %d unchartered\n' "$CHARTERED" "$TOTAL" "$UNCHARTERED"

# ---------- family grouping (advisory rollup; see header comment)
# NOTE: uses FILENAME (not the common "FNR==NR" idiom) to tell the chartered-set file from the
# basenames file — FNR==NR silently breaks here because chartered.txt is legitimately empty on
# many real runs (0 chartered units), and an empty first file never advances NR ahead of FNR, so
# every line of the SECOND file would be misread as chartered-set input too (0 families output).
awk -F'\t' -v chartfile="$TMP/chartered.txt" '
  FILENAME == chartfile { chartered[$0] = 1; next }
  {
    mod = $0
    key = mod
    # SENTINEL-E: family min-length-3 gate (drop the length(k)>=3 check to mutate — merges
    # unrelated units whose basenames share only 1-2 leading lowercase chars into one family)
    if (match(mod, /^[a-z]+/)) {
      k = substr(mod, RSTART, RLENGTH)
      if (length(k) >= 3) key = k
    }
    total[key]++
    if (mod in chartered) fam_chartered[key]++
  }
  END {
    for (f in total) {
      fc = fam_chartered[f] + 0
      printf "%s\t%d\t%d\t%d\n", f, total[f], fc, total[f] - fc
    }
  }
' "$TMP/chartered.txt" "$TMP/mod_basenames.txt" | sort > "$TMP/families.txt"

FAMILIES_TOTAL=$(wc -l < "$TMP/families.txt" | tr -d ' ')
FAMILIES_UNCHARTERED=$(awk -F'\t' '$3 == 0 { c++ } END { print c + 0 }' "$TMP/families.txt")
printf 'families: %d total \xc2\xb7 %d fully-unchartered\n' "$FAMILIES_TOTAL" "$FAMILIES_UNCHARTERED"

# ---------- --top N rankings
if [ "$TOP" -gt 0 ]; then
  printf -- '-- top %d unchartered units (file count desc) --\n' "$TOP"
  sort -rn "$TMP/uncharted.txt" | head -n "$TOP"
  printf -- '-- top %d fully-unchartered families (member units desc) --\n' "$TOP"
  awk -F'\t' '$3 == 0 { printf "%d\t%s\n", $2, $1 }' "$TMP/families.txt" | sort -rn | head -n "$TOP"
fi
