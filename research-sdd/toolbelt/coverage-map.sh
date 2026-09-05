#!/usr/bin/env bash
# coverage-map.sh — subject-coverage map: which modules in a source tree the corpus has ever cited.
# Usage: coverage-map.sh <corpus-dir> --subject <root> [--depth N] [--ext csv] [--top N]
#        [--exclude-file <path>] [--exclude <glob>] ...
#
# units   = directories at --depth under --subject containing ≥1 file with a listed extension.
# index   = basename-without-ext → module; drop basenames in >1 module (ambiguous) and <4 chars.
# cited   = module whose unambiguous basename appears as <basename>.<ext> (extension-bearing, word-
#           bounded, case-sensitive) in a corpus block file, OR whose directory name appears as a
#           path token (<mod>/) in a block file.  Bare stems NEVER count (METHODOLOGY §3).
# ranking = uncited modules sorted by file count descending.
# exclude = --exclude-file (default: <corpus-dir>/coverage-exclude.txt when it exists, else none)
#           and/or repeated --exclude <glob>; drops whole units from total/cited/uncited.
#           The tool NEVER writes the exclude file (propose-never-apply).
#
# Three distinguishable states (CLAUDE.md §7):
#   subject absent/not-traversable  → "subject: absent-input …"  exit 1
#   subject present, 0 class files  → "subject: empty-input …"   exit 0
#   corpus present, 0 citations     → "no-match …"               exit 0
#   corpus has 0 block files        → "corpus: empty-input …"    exit 0
# Findings (no-match, uncited) never change the exit code; only operational failure exits nonzero.
#
# Exit: 0 ok · 1 operational failure (subject not traversable) · 2 bad arguments
set -uo pipefail

# ---------- defaults
DEPTH=1
EXT_CSV="java"
TOP=0
SUBJECT=""
CORPUS_DIR=""
EXCL_FILE=""
EXCL_FILE_EXPLICIT=0
EXCL_EXTRA=""

# ---------- argument parsing
if [ $# -eq 0 ]; then
  printf 'Usage: coverage-map.sh <corpus-dir> --subject <root> [--depth N] [--ext csv] [--top N]\n' >&2
  exit 2
fi
CORPUS_DIR="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    --subject)      [ $# -ge 2 ] || { printf 'FATAL: --subject requires a value\n' >&2; exit 2; }
                    SUBJECT="$2"; shift 2 ;;
    --depth)        [ $# -ge 2 ] || { printf 'FATAL: --depth requires a value\n' >&2; exit 2; }
                    DEPTH="$2"; shift 2 ;;
    --ext)          [ $# -ge 2 ] || { printf 'FATAL: --ext requires a value\n' >&2; exit 2; }
                    EXT_CSV="$2"; shift 2 ;;
    --top)          [ $# -ge 2 ] || { printf 'FATAL: --top requires a value\n' >&2; exit 2; }
                    TOP="$2"; shift 2 ;;
    --exclude-file) [ $# -ge 2 ] || { printf 'FATAL: --exclude-file requires a value\n' >&2; exit 2; }
                    EXCL_FILE="$2"; EXCL_FILE_EXPLICIT=1; shift 2 ;;
    --exclude)      [ $# -ge 2 ] || { printf 'FATAL: --exclude requires a value\n' >&2; exit 2; }
                    EXCL_EXTRA="${EXCL_EXTRA:+${EXCL_EXTRA}
}$2"; shift 2 ;;
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

# ---------- exclusion config
# Default exclude file: <corpus-dir>/coverage-exclude.txt when it exists and not overridden
if [ "$EXCL_FILE_EXPLICIT" -eq 0 ] && [ -f "$CORPUS_DIR/coverage-exclude.txt" ]; then
  EXCL_FILE="$CORPUS_DIR/coverage-exclude.txt"
fi
# Collect --exclude args (one glob per line; filter blank lines)
: > "$TMP/excl_args.txt"
printf '%s\n' "$EXCL_EXTRA" | grep -v '^$' >> "$TMP/excl_args.txt" || true
# Build combined pattern list (skip blank lines and #-comment lines from file)
: > "$TMP/excl_patterns.txt"
if [ -n "$EXCL_FILE" ] && [ -f "$EXCL_FILE" ]; then
  grep -v '^[[:space:]]*#' "$EXCL_FILE" | grep -v '^[[:space:]]*$' \
    >> "$TMP/excl_patterns.txt" || true
fi
cat "$TMP/excl_args.txt" >> "$TMP/excl_patterns.txt"
# Determine source label for always-printed declaration line
if [ -n "$EXCL_FILE" ] && [ -f "$EXCL_FILE" ]; then
  EXCL_SOURCE="$EXCL_FILE"
elif grep -q . "$TMP/excl_args.txt" 2>/dev/null; then
  EXCL_SOURCE="command-line"
else
  EXCL_SOURCE="none"
fi

# ---------- extension list (one per line) and alternation for path-token grep
printf '%s\n' "$EXT_CSV" | tr ',' '\n' | grep -v '^$' > "$TMP/exts.txt"
ext_alt="$(printf '%s' "$EXT_CSV" | tr ',' '|' | tr -d ' ')"

# ---------- find units: dirs at --depth under --subject containing ≥1 file with listed ext
: > "$TMP/units_all.txt"
while IFS= read -r dir; do
  while IFS= read -r ext; do
    if find "$dir" -maxdepth 999 -type f -name "*.${ext}" -print -quit 2>/dev/null | grep -q .; then
      printf '%s\n' "$dir" >> "$TMP/units_all.txt"
      break
    fi
  done < "$TMP/exts.txt"
done < <(find "$SUBJECT" -mindepth "$DEPTH" -maxdepth "$DEPTH" -type d 2>/dev/null | sort)

TOTAL_ALL=$(wc -l < "$TMP/units_all.txt" | tr -d ' ')

# ---------- three-state: subject empty for the listed extensions
if [ "$TOTAL_ALL" -eq 0 ]; then
  printf 'subject: empty-input (0 class basenames)\n'
  printf 'ambiguous basenames excluded: 0\n'
  printf 'excluded by declaration: 0 unit(s) (none)\n'
  printf 'modules: 0/0 cited \xc2\xb7 0 never cited\n'
  exit 0
fi

# ---------- apply declared exclusions (drops whole units from total/cited/uncited)
EXCL_COUNT=0
: > "$TMP/units.txt"
while IFS= read -r unit; do
  _mod="$(basename "$unit")"
  _excl=0
  # shellcheck disable=SC2254
  while IFS= read -r _pat; do
    case "$_mod" in
      $_pat) _excl=1; break ;;
    esac
  done < "$TMP/excl_patterns.txt"
  if [ "$_excl" -eq 1 ]; then
    EXCL_COUNT=$((EXCL_COUNT + 1))
  else
    printf '%s\n' "$unit" >> "$TMP/units.txt"
  fi
done < "$TMP/units_all.txt"
TOTAL=$(wc -l < "$TMP/units.txt" | tr -d ' ')

# ---------- build basename → module index
# Each line: <basename><TAB><module-dirname>; collect ALL lengths first (ambiguity is counted
# across ALL basenames including short ones; short-basename drop happens after ambiguity count).
: > "$TMP/all_bn.txt"
while IFS= read -r unit; do
  mod="$(basename "$unit")"
  while IFS= read -r ext; do
    find "$unit" -type f -name "*.${ext}" 2>/dev/null \
      | while IFS= read -r f; do
          b="${f##*/}"; b="${b%.*}"
          printf '%s\t%s\n' "$b" "$mod"
        done
  done < "$TMP/exts.txt"
done < "$TMP/units.txt" | sort -u > "$TMP/all_bn.txt"

# SENTINEL-B: exclude ambiguous
# Count ambiguous across ALL basenames (including short); then drop both ambiguous AND short.
AMBIG=$(awk -F'\t' '{cnt[$1]++} END {n=0; for(b in cnt) if(cnt[b]>1) n++; print n+0}' "$TMP/all_bn.txt")
awk -F'\t' '{cnt[$1]++; last[$1]=$2}
            END {for(b in cnt) if(cnt[b]==1 && length(b)>=4) print b"\t"last[b]}' \
  "$TMP/all_bn.txt" | sort > "$TMP/unambig.txt"

# ---------- find block files in corpus using the kit discriminator
# Pattern: <prefix>-(block|bloque)<N>[optional-suffix].md at any depth under corpus-dir
find "$CORPUS_DIR" -type f -name "*.md" 2>/dev/null \
  | grep -E '[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' \
  | sort > "$TMP/blocks.txt"
BLOCK_COUNT=$(wc -l < "$TMP/blocks.txt" | tr -d ' ')

# ---------- three-state: corpus has zero block files (distinct from zero citations)
if [ "$BLOCK_COUNT" -eq 0 ]; then
  printf 'corpus: empty-input (0 block files)\n'
  printf 'ambiguous basenames excluded: %d\n' "$AMBIG"
  printf 'excluded by declaration: %d unit(s) (%s)\n' "$EXCL_COUNT" "$EXCL_SOURCE"
  printf 'modules: 0/%d cited \xc2\xb7 %d never cited\n' "$TOTAL" "$TOTAL"
  if [ "$TOP" -gt 0 ]; then
    while IFS= read -r unit; do
      fc=0
      while IFS= read -r ext; do
        n=$(find "$unit" -type f -name "*.${ext}" 2>/dev/null | wc -l)
        fc=$((fc + n))
      done < "$TMP/exts.txt"
      printf '%d\t%s\n' "$fc" "$(basename "$unit")"
    done < "$TMP/units.txt" | sort -rn | head -n "$TOP"
  fi
  exit 0
fi

# ---------- concatenate all block files for fast repeated grep
xargs cat < "$TMP/blocks.txt" > "$TMP/corpus.txt" 2>/dev/null || true

# ---------- citation check: one pass per module
# SENTINEL-A: count uncited (mutant target)
: > "$TMP/cited.txt"
: > "$TMP/uncited.txt"

while IFS= read -r unit; do
  mod="$(basename "$unit")"
  cited=0

  # path-token check: <mod>[-/]<path>.<ext> — module leads to a class file (not a bare dir).
  # Only for module names ≥6 chars to avoid false-positives from common short names.
  if [ "${#mod}" -ge 6 ]; then
    re_mod="$(printf '%s' "$mod" | sed 's/[.+*?^${}|[\\()]/\\&/g')"
    # SENTINEL-F: path-token requires class-file extension (loosen to bare dir to mutate)
    _ptok_pat="(^|[^A-Za-z0-9_])${re_mod}[-/][^[:space:]]*\.(${ext_alt})\b"
    if grep -qE "$_ptok_pat" "$TMP/corpus.txt" 2>/dev/null; then
      cited=1
    fi
  fi

  # basename check: any unambiguous basename of this module, as <basename>.<ext> extension-bearing
  # token, word-bounded, case-sensitive.  Bare stems NEVER match (METHODOLOGY §3).
  if [ "$cited" -eq 0 ]; then
    awk -F'\t' -v m="$mod" '$2==m{print $1}' "$TMP/unambig.txt" > "$TMP/cur_raw_bns.txt"
    if [ -s "$TMP/cur_raw_bns.txt" ]; then
      : > "$TMP/cur_bns.txt"
      while IFS= read -r bn; do
        while IFS= read -r ext; do
          # SENTINEL-D: ext-bearing pattern (bare-stem mutant: remove extension)
          printf '%s.%s\n' "$bn" "$ext" >> "$TMP/cur_bns.txt"
        done < "$TMP/exts.txt"
      done < "$TMP/cur_raw_bns.txt"
      # SENTINEL-C: word-boundary grep on <basename>.<ext> tokens
      if grep -qwFf "$TMP/cur_bns.txt" "$TMP/corpus.txt" 2>/dev/null; then
        cited=1
      fi
    fi
  fi

  if [ "$cited" -eq 1 ]; then
    printf '%s\n' "$mod" >> "$TMP/cited.txt"
  else
    fc=0
    while IFS= read -r ext; do
      n=$(find "$unit" -type f -name "*.${ext}" 2>/dev/null | wc -l)
      fc=$((fc + n))
    done < "$TMP/exts.txt"
    printf '%d\t%s\n' "$fc" "$mod" >> "$TMP/uncited.txt"
  fi
done < "$TMP/units.txt"

CITED=$(wc -l < "$TMP/cited.txt" | tr -d ' ')
# SENTINEL-A: count uncited
UNCITED=$(wc -l < "$TMP/uncited.txt" | tr -d ' ')

# ---------- output
if [ "$CITED" -eq 0 ]; then
  printf 'no-match (%d modules, 0 cited)\n' "$TOTAL"
fi
printf 'ambiguous basenames excluded: %d\n' "$AMBIG"
# SENTINEL-E: excluded-by-declaration line (must always appear; silence → tooth e)
printf 'excluded by declaration: %d unit(s) (%s)\n' "$EXCL_COUNT" "$EXCL_SOURCE"
printf 'modules: %d/%d cited \xc2\xb7 %d never cited\n' "$CITED" "$TOTAL" "$UNCITED"

if [ "$TOP" -gt 0 ]; then
  sort -rn "$TMP/uncited.txt" | head -n "$TOP"
fi
