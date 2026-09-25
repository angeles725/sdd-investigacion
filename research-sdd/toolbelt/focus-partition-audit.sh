#!/usr/bin/env bash
# focus-partition-audit.sh — cross-check FOCUSES.md (+ the RESEARCH-STATE files it names) against
# the subject-tree UNIT universe.
# Usage: focus-partition-audit.sh <corpus-dir> --subject <root> [--depth N] [--ext csv] [--top N]
#        [--focuses-file <path>]
#
# Answers a different question than coverage-map.sh: coverage-map asks "did a corpus BLOCK ever
# cite this module?" (evidence a claim was made). This asks "does ANY FOCUSES.md row CHARTER this
# module to a focus at all?" (evidence the module is even someone's job) — the corpus-level
# partition check kit issue #1105 names: a per-focus coverage audit proves each focus is
# internally complete, never that the whole artifact universe is partitioned across any focus.
#
# unit      = directory at --depth under --subject containing >=1 file with a listed extension —
#             the exact same definition coverage-map.sh uses for --depth/--ext (default depth=1,
#             ext=java); pass --depth/--ext to change the unit granularity for a non-Java target.
# family    = units sharing the maximal run of ASCII lowercase letters at the START of their
#             basename (the text before the first uppercase letter, digit, or non-letter) — e.g.
#             lonAaon/lonAbb/lonActech share family "lon". A basename whose leading run is under
#             3 chars (or absent, e.g. it starts uppercase) is its own singleton family. This is
#             an ADVISORY grouping for readable rollups only — the OPERATOR decides the real queue
#             grouping (METHODOLOGY §8c); it is not a claim about which modules are actually
#             related.
#
# CHARTER SOURCE (kit issue #1123/#1106 round 2): niagara-research does NOT charter modules in
# FOCUSES.md's own prose — it charters them in the per-focus `RESEARCH-STATE-<focus>.md` file that
# row names (measured 2026-09-25: `modbusCore` is chartered at `RESEARCH-STATE-modbus.md:4` and
# `RESEARCH-STATE-module-mechanics.md:74`, never inside FOCUSES.md itself). So the charter source
# for a CLASSIFIED row is that row's OWN cells PLUS the content of the RESEARCH-STATE file its
# Research-State/State-file column names (resolved relative to FOCUSES.md's directory). A row
# whose named file cannot be read (declared but absent, or unreadable) does not make its units
# UNCHARTERED — it WARNs, and the run's reported UNCHARTERED count becomes an UPPER bound (the
# true count may be lower — mirrors coverage-map.sh's own unreadable-block-file precedent).
#
# A unit is CHARTERED when its basename resolves against that combined text through any of:
#   - an exact backtick-code token (the whole span, e.g. `` `modbusCore` ``),
#   - one of the span's '/'-separated path components (e.g. `` `organized/modbusCore/...` ``),
#   - one of the span's WHITESPACE-separated tokens, when a span lists several bare identifiers
#     (e.g. `` `check-coverage.py honeywellSpyderTool XL10NextGen` ``),
#   - the module portion of a `<module>-<profile>` suffix form, `<profile>` one of the Niagara
#     module-profile suffixes rt/wb/ux/se (e.g. `` `modbusCore-wb` `` charters `modbusCore`),
#   - a GLOB token (containing '*' or '?', e.g. `` `clHVAC*` ``) matched against unit basenames
#     with shell glob semantics — counted separately as "glob-chartered", never silently folded
#     into the plain exact-token count or left to fall through as unchartered.
# Bare mentions in ordinary PROSE never count — measured against the real niagara-research
# FOCUSES.md (2026-09-25): it uses plain English words ("schedule", "event", "converters"...) as
# BOTH real module basenames and as ordinary prose/method-call fragments in the very same file
# (`` `Clock.schedule` `` — java.util.Clock's method, nothing to do with the `schedule` module).
# Splitting a span on '.' as well as '/' turns that one span into a false "schedule" charter;
# splitting only on whitespace and '/' avoids it while still catching genuine path/list forms.
# Direct analogue of coverage-map.sh's "bare stems never count" (METHODOLOGY §3), applied to
# charter-declaration prose instead of block citations.
#
# Distinguishable states (CLAUDE.md §7 — absent/empty/no-match/unclassifiable, plus the runtime
# probe's degraded; each state is typed and mutually exclusive — never two states in one run):
#   subject absent/not-traversable            -> "subject: absent-input ..."   exit 1
#   subject present, 0 class-file units       -> "subject: empty-input ..."    exit 0
#   FOCUSES.md absent (default or --focuses-file) -> "focuses: absent-input ..." exit 0 — most
#       targets are single-focus and legitimately carry no FOCUSES.md; every unit is reported
#       unchartered rather than a silent zero (the file was never read, so it never gets to claim
#       otherwise).
#   FOCUSES.md exists but is not readable      -> "focuses: unreadable ..."    exit 0 (WARN-only;
#       distinct from absent — the file was FOUND but could not be READ, never folded into a
#       confident 0/0)
#   FOCUSES.md present, 0 classified+unclassifiable table rows -> "focuses: empty-input ..." exit 0
#   FOCUSES.md has classified rows, 0 chartering tokens         -> "focuses: no-match ..."   exit 0
#   A table row missing its identity (Focus) cell, or a line that merely CONTAINS a '|' without
#   the leading-pipe table-row shape (prose with an embedded '|' is not a row), is UNCLASSIFIABLE:
#   counted and reported, never silently absorbed into or dropped from the classified total.
#
# Read-only, propose-never-apply: never writes to corpus-dir or subject (CLAUDE.md §8).
#
# Exit: 0 ok (findings included) · 1 operational failure (subject not traversable) ·
#       2 bad arguments (including a non-integer --depth/--top) ·
#       3 degraded (a required PATH tool is missing, or mktemp/find operationally failed)
set -uo pipefail

# ---------- runtime-dependency probe (CLAUDE.md §7 — could the instrument even run?)
# Every external (non-builtin) command this script invokes: find/awk/grep/sort/sed for the core
# logic, plus wc/tr/mktemp/basename/head/rm for bookkeeping and cleanup. All POSIX-mandated core
# utilities — no jq/git/python3/compiled-tool dependency — but probed anyway: a missing one should
# surface as a typed `degraded` exit, not a confusing mid-run crash that looks like a false
# empty/zero finding, or (F5, round 2) a SILENT zero when e.g. `wc` is the one that is missing.
for _fpa_dep in find awk grep sort sed wc tr mktemp basename head rm; do
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
# F7 (round 2): --depth/--top must be non-negative integers, never silently coerced into a `find`
# call that then just returns nothing (which used to print a confident "subject: empty-input").
case "$DEPTH" in
  ''|*[!0-9]*) printf 'FATAL: --depth must be a non-negative integer, got: %s\n' "$DEPTH" >&2; exit 2 ;;
esac
case "$TOP" in
  ''|*[!0-9]*) printf 'FATAL: --top must be a non-negative integer, got: %s\n' "$TOP" >&2; exit 2 ;;
esac

# ---------- three-state: subject root absent or not traversable
if [ ! -d "$SUBJECT" ] || [ ! -x "$SUBJECT" ]; then
  printf 'subject: absent-input (%s not traversable)\n' "$SUBJECT"
  exit 1
fi

TMP="$(mktemp -d)" || { printf 'degraded: mktemp -d failed\n' >&2; exit 3; }
trap 'rm -rf "$TMP"' EXIT

# ---------- extension list (one per line)
printf '%s\n' "$EXT_CSV" | tr ',' '\n' | grep -v '^$' > "$TMP/exts.txt"

# ---------- find units: dirs at --depth under --subject containing >=1 file with listed ext
# (same definition/loop as coverage-map.sh --depth/--ext, so the two tools agree on "unit")
# The OUTER walk's exit status is checked explicitly (round 2, F5/§7): a `find` that fails
# operationally (unreadable subtree, bad argument the shell didn't already reject) must not be
# silently read as "0 units found" — that is a DEGRADED run, not an empty one.
if ! find "$SUBJECT" -mindepth "$DEPTH" -maxdepth "$DEPTH" -type d > "$TMP/dirs_raw.txt" 2>"$TMP/dirs_err.txt"; then
  printf 'degraded: find over %s failed: %s\n' "$SUBJECT" "$(head -1 "$TMP/dirs_err.txt" 2>/dev/null)" >&2
  exit 3
fi
sort "$TMP/dirs_raw.txt" > "$TMP/dirs.txt"

: > "$TMP/units.txt"
while IFS= read -r dir; do
  while IFS= read -r ext; do
    if find "$dir" -maxdepth 999 -type f -name "*.${ext}" -print -quit 2>/dev/null | grep -q .; then
      printf '%s\n' "$dir" >> "$TMP/units.txt"
      break
    fi
  done < "$TMP/exts.txt"
done < "$TMP/dirs.txt"

TOTAL=$(wc -l < "$TMP/units.txt" | tr -d ' ')

# ---------- three-state: subject empty for the listed extensions
if [ "$TOTAL" -eq 0 ]; then
  printf 'subject: empty-input (0 class-file units)\n'
  printf 'FOCUSES.md rows: 0 classified, 0 unclassifiable (source: n/a)\n'
  printf 'chartering tokens: 0 (0 plain, 0 glob)\n'
  printf 'unresolved RESEARCH-STATE references: 0\n'
  printf 'units: 0/0 chartered \xc2\xb7 0 unchartered (0 glob-chartered)\n'
  printf 'families: 0 total \xc2\xb7 0 fully-unchartered\n'
  exit 0
fi

# ---------- resolve FOCUSES.md location
if [ "$FOCUSES_FILE_EXPLICIT" -eq 0 ]; then
  FOCUSES_FILE="$CORPUS_DIR/FOCUSES.md"
fi

: > "$TMP/row_cells.txt"
: > "$TMP/state_refs.txt"
ROWS_CLASSIFIED=0
ROWS_UNCLASSIFIABLE=0

if [ ! -f "$FOCUSES_FILE" ]; then
  printf 'focuses: absent-input (no FOCUSES.md at %s)\n' "$FOCUSES_FILE"
elif [ ! -r "$FOCUSES_FILE" ]; then
  # F-round2: an existing-but-unreadable file is its OWN typed state — never folded into a
  # confident "0 classified, 0 unclassifiable" as if the file were simply empty or absent.
  printf 'focuses: unreadable (%s exists but is not readable)\n' "$FOCUSES_FILE"
else
  # ---------- parse FOCUSES.md as a markdown table: first table-shaped line is the header
  # (captured by name for the Research-State/State-file column, mirroring
  # research-sdd-status.sh's own header-detection convention), every later table-shaped line is a
  # data row. F6 (round 2): a table-ROW-shaped line must itself START with '|' after optional
  # leading whitespace — a prose line that merely CONTAINS a '|' (e.g. "bit48=ADMIN_READ|ADMIN_WRITE")
  # is not a table row and must never be classified or unclassified as one.
  # A data row's FIRST cell is its identity (Focus name); empty after markup-strip (backtick/bold),
  # or fewer than 2 cells, makes the row UNCLASSIFIABLE (counted, excluded from the charter-token
  # corpus — never silently merged into "classified").
  awk -v cellfile="$TMP/row_cells.txt" -v countfile="$TMP/row_counts.txt" -v statefile="$TMP/state_refs.txt" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function strip_markup(s,   r) {
      r = trim(s)
      gsub(/\*\*/, "", r)
      sub(/^`/, "", r); sub(/`$/, "", r)
      return trim(r)
    }
    BEGIN { hdone = 0; classified = 0; unclass = 0; sfcol = 0 }
    {
      # SENTINEL-ROW: table-row shape (leading pipe required; loosen to index($0,"|") to mutate)
      if ($0 !~ /^[ \t]*\|/) next
      line = $0
      sub(/^\|/, "", line); sub(/\|$/, "", line)
      n = split(line, a, "|")
      issep = 1
      for (k = 1; k <= n; k++) { if (trim(a[k]) !~ /^:?-+:?$/) { issep = 0; break } }
      if (issep) next
      if (!hdone) {
        hdone = 1
        for (k = 1; k <= n; k++) {
          h = tolower(trim(a[k]))
          if (h == "research-state" || h == "state file") sfcol = k
        }
        next
      }
      # SENTINEL-F: unclassifiable-row gate (identity cell required; loosen to n<1 to mutate)
      ident = (n >= 1) ? strip_markup(a[1]) : ""
      if (n < 2 || ident == "") { unclass++; next }
      classified++
      for (k = 1; k <= n; k++) print trim(a[k]) > cellfile
      if (sfcol > 0 && sfcol <= n) {
        sref = strip_markup(a[sfcol])
        if (sref != "") print sref > statefile
      }
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
if [ -f "$FOCUSES_FILE" ] && [ -r "$FOCUSES_FILE" ] && [ "$ROWS_CLASSIFIED" -eq 0 ] && [ "$ROWS_UNCLASSIFIABLE" -eq 0 ]; then
  printf 'focuses: empty-input (0 table rows in %s)\n' "$FOCUSES_FILE"
fi

# ---------- resolve every referenced RESEARCH-STATE file, appending its content to the charter
# corpus (round 2, F1): niagara-research charters modules THERE, not in FOCUSES.md's own prose.
# A declared-but-unreadable reference is never treated as "no charter" — it WARNs, and the run's
# reported UNCHARTERED count becomes an UPPER bound (coverage-map.sh's own unreadable-block-file
# pattern: a low count must prove it looked, not merely that it produced a number).
STATE_RESOLVED=0
STATE_UNRESOLVED=0
: > "$TMP/state_unresolved_names.txt"
if [ -s "$TMP/state_refs.txt" ] && [ -f "$FOCUSES_FILE" ]; then
  FOCUSES_DIR="$(dirname "$FOCUSES_FILE")"
  sort -u "$TMP/state_refs.txt" > "$TMP/state_refs_uniq.txt"
  while IFS= read -r sref; do
    sfile="$FOCUSES_DIR/$sref"
    if [ -f "$sfile" ] && [ -r "$sfile" ]; then
      cat "$sfile" >> "$TMP/row_cells.txt"
      STATE_RESOLVED=$((STATE_RESOLVED + 1))
    else
      STATE_UNRESOLVED=$((STATE_UNRESOLVED + 1))
      printf '%s\n' "$sref" >> "$TMP/state_unresolved_names.txt"
    fi
  done < "$TMP/state_refs_uniq.txt"
fi
printf 'unresolved RESEARCH-STATE references: %d\n' "$STATE_UNRESOLVED"
if [ "$STATE_UNRESOLVED" -gt 0 ]; then
  printf 'WARN: %d referenced RESEARCH-STATE file(s) unreadable/absent (%s) — unchartered counts are UPPER bounds\n' \
    "$STATE_UNRESOLVED" "$(tr '\n' ',' < "$TMP/state_unresolved_names.txt" | sed 's/,$//')" >&2
fi

# ---------- extract chartering tokens: backtick spans from the combined charter corpus (CLASSIFIED
# FOCUSES.md rows + resolved RESEARCH-STATE content), split on whitespace, then '/' and ',' only.
# SENTINEL-C: do not add '.'/'-'/'_' to the split class — see header comment, Clock.schedule.
# ',' is added (round 2, F3): the real RESEARCH-STATE files write a shared-prefix profile-suffix
# list as ONE span, e.g. `` `opcUaServer-rt,-wb` `` (comma joins "-rt" and "-wb" under one
# `opcUaServer-` prefix) — measured 2026-09-25: 8 real spans in RESEARCH-STATE-framework-drivers.md
# alone use this form (opcUaClient/opcUaServer/obixDriver/mbus/opc/weather/knxnetIp/
# abstractMqttDriver). Splitting on ',' turns "opcUaServer-rt,-wb" into "opcUaServer-rt" (a valid
# profile-suffix token below) and "-wb" (rejected by the identifier-shape filter — it does not
# start with a letter); no new prose-collision risk measured (unlike '.', a bare comma never joins
# an ordinary-English false-positive-prone word to unrelated text in this corpus).
# SENTINEL-B: the backtick requirement itself is what keeps ordinary prose from ever counting;
# loosening this to scan raw cell prose (not just backtick spans) reintroduces exactly the
# Clock.schedule-style false charter this tool exists to avoid.
grep -oE '`[^`]+`' "$TMP/row_cells.txt" 2>/dev/null \
  | sed -e 's/^`//' -e 's/`$//' \
  | awk '{ for (i = 1; i <= NF; i++) print $i }' \
  | awk -F'[/,]' '{ for (i = 1; i <= NF; i++) print $i }' \
  > "$TMP/raw_candidates.txt"

# Plain identifier tokens (exact-match pool).
grep -E '^[A-Za-z][A-Za-z0-9_.-]*$' "$TMP/raw_candidates.txt" | sort -u > "$TMP/plain_tokens_base.txt"
# Profile-suffix form: `<module>-rt|wb|ux|se` also charters `<module>` (Niagara module-profile
# convention; measured 2026-09-25: `driver-rt`, `basicDriver-rt`, `modbusCore-wb` in the real
# RESEARCH-STATE files).
awk -F'-' '{
  if (NF >= 2) {
    suf = $NF
    if (suf == "rt" || suf == "wb" || suf == "ux" || suf == "se") {
      base = $1
      for (i = 2; i < NF; i++) base = base "-" $i
      print base
    }
  }
}' "$TMP/plain_tokens_base.txt" > "$TMP/plain_tokens_suffix.txt"
sort -u "$TMP/plain_tokens_base.txt" "$TMP/plain_tokens_suffix.txt" > "$TMP/charter_tokens.txt"
PLAIN_TOKEN_COUNT=$(wc -l < "$TMP/charter_tokens.txt" | tr -d ' ')

# Glob tokens (a distinct pool — matched with shell glob semantics per unit, never merged into the
# exact-match pool and never silently dropped as "not identifier-shaped").
grep -E '^[A-Za-z][A-Za-z0-9_.*?-]*[*?][A-Za-z0-9_.*?-]*$' "$TMP/raw_candidates.txt" \
  | sort -u > "$TMP/glob_tokens.txt"
GLOB_TOKEN_COUNT=$(wc -l < "$TMP/glob_tokens.txt" | tr -d ' ')

TOKEN_COUNT=$((PLAIN_TOKEN_COUNT + GLOB_TOKEN_COUNT))
printf 'chartering tokens: %d (%d plain, %d glob)\n' "$TOKEN_COUNT" "$PLAIN_TOKEN_COUNT" "$GLOB_TOKEN_COUNT"

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
: > "$TMP/glob_chartered.txt"
: > "$TMP/uncharted.txt"
while IFS= read -r unit; do
  mod="$(basename "$unit")"
  matched=0
  # SENTINEL-D: exact-token equality (loosen to substring/-F to mutate — e.g. "modbus" would
  # then falsely "charter" "modbusCore" via substring containment)
  if grep -qxF "$mod" "$TMP/charter_tokens.txt" 2>/dev/null; then
    printf '%s\n' "$mod" >> "$TMP/chartered.txt"
    matched=1
  elif [ -s "$TMP/glob_tokens.txt" ]; then
    while IFS= read -r pat; do
      # SENTINEL-G: glob match (shell case pattern) — a token from FOCUSES.md's own vetted
      # identifier+wildcard charset, never arbitrary/attacker-controlled input.
      # shellcheck disable=SC2254
      case "$mod" in
        $pat) matched=1; printf '%s\n' "$mod" >> "$TMP/chartered.txt"
              printf '%s\n' "$mod" >> "$TMP/glob_chartered.txt"; break ;;
      esac
    done < "$TMP/glob_tokens.txt"
  fi
  if [ "$matched" -eq 0 ]; then
    fc=0
    while IFS= read -r ext; do
      n=$(find "$unit" -type f -name "*.${ext}" 2>/dev/null | wc -l)
      fc=$((fc + n))
    done < "$TMP/exts.txt"
    printf '%d\t%s\n' "$fc" "$mod" >> "$TMP/uncharted.txt"
  fi
done < "$TMP/units.txt"

CHARTERED=$(wc -l < "$TMP/chartered.txt" | tr -d ' ')
GLOB_CHARTERED=$(wc -l < "$TMP/glob_chartered.txt" | tr -d ' ')
# SENTINEL-A: unchartered count (mutant target — hardcode to 0; anchored to line start so it
# cannot also clobber FAMILIES_UNCHARTERED= below, which contains the same substring)
UNCHARTERED=$(wc -l < "$TMP/uncharted.txt" | tr -d ' ')

printf 'units: %d/%d chartered \xc2\xb7 %d unchartered (%d glob-chartered)\n' \
  "$CHARTERED" "$TOTAL" "$UNCHARTERED" "$GLOB_CHARTERED"

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
