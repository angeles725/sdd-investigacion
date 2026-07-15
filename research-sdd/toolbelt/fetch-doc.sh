#!/usr/bin/env bash
# fetch-doc.sh — downloads and PRESERVES external sources (datasheets, manuals,
# forums, links) inside TARGET/sources/, with text extraction and a traceable
# record in SOURCES.md. Research-SDD rule: URLs die; evidence does not.
#
# Usage:
#   fetch-doc.sh doc <url> <target-dir> [datasheets|manuals] [name]
#   fetch-doc.sh web <url> <target-dir>          # page/forum -> markdown (pandoc)
#   fetch-doc.sh ocr <pdf>                        # OCR of a scanned PDF (tesseract)
set -euo pipefail

reg() { # registers a row in SOURCES.md
  local sdir="$1" file="$2" kind="$3" origin="$4" sha="$5"
  local md="$sdir/SOURCES.md"
  if [ ! -f "$md" ]; then
    printf '# External sources preserved\n\n| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |\n|---|---|---|---|---|---|\n' > "$md"
  fi
  # Store the FULL 64-hex sha256 in the registry CELL (not a truncated display) so verify-sources.sh LEVEL 6 can
  # recompute and enforce it — a truncated cell is only WARN-checkable and lets a tampered snapshot pass silently.
  local row
  row="$(printf '| %s | %s | %s | %s | %s | |' \
    "${file#"$sdir"/}" "$kind" "$origin" "$(date -u +%FT%TZ)" "$sha")"
  # Insert the row at the END OF THE (first) MARKDOWN TABLE, NOT blindly at EOF. A SOURCES.md whose table is
  # followed by trailing prose (## Structure / ## Notes — the bootstrap template's own shape) would otherwise
  # get new rows appended AFTER those sections, splitting the document into two disconnected table fragments
  # (a future stricter markdown-table parser would then drop or mis-associate the orphaned rows). awk walks the
  # FIRST contiguous run of `|`-rows (blank lines inside the table are tolerated) and prints the new row right
  # after its last line; with no table at all (or a table that IS the whole body) it appends, as before.
  local tmp; tmp="$(mktemp)"
  # Pass the row through the ENVIRONMENT, NOT `awk -v`: `-v` subjects the value to awk's C-style backslash-
  # escape processing (\t → TAB, \b → backspace), mangling a basename/URL that contains a backslash so the
  # written cell diverges from the literal value verify-sources.sh later cross-checks. ENVIRON is verbatim.
  newrow="$row" awk '
    { buf[NR]=$0
      if ($0 ~ /^[[:space:]]*\|/) { if (!closed) { intable=1; last=NR } }
      else if ($0 !~ /^[[:space:]]*$/) { if (intable) closed=1 } }
    END {
      if (last==0) { for(i=1;i<=NR;i++) print buf[i]; print ENVIRON["newrow"] }
      else { for(i=1;i<=NR;i++){ print buf[i]; if(i==last) print ENVIRON["newrow"] } } }
  ' "$md" > "$tmp" && mv "$tmp" "$md"
}

# Main dispatch is guarded so the file can be SOURCED to unit-test reg() in isolation (tests/fetch-doc.test.sh)
# without triggering a network fetch. When sourced, BASH_SOURCE[0] != $0, so nothing below runs.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
MODE="${1:?usage: fetch-doc.sh doc|web|ocr ...}"

case "$MODE" in
  ocr)
    PDF="${2:?pdf required}"
    command -v tesseract >/dev/null || { echo "tesseract not installed" >&2; exit 3; }
    OCR_DIR="$(mktemp -d)"; trap 'rm -rf "$OCR_DIR"' EXIT
    pdftoppm -r 300 -png "$PDF" "$OCR_DIR/ocr" >/dev/null 2>&1 || { echo "pdftoppm falló" >&2; exit 3; }
    for img in "$OCR_DIR"/ocr-*.png; do tesseract "$img" stdout 2>/dev/null; done
    ;;
  doc)
    URL="${2:?url}"; TDIR="${3:?target-dir}"; SUB="${4:-datasheets}"
    SDIR="$TDIR/sources"; mkdir -p "$SDIR/$SUB" "$SDIR/extracted"
    NAME="${5:-$(basename "${URL%%\?*}")}"; DEST="$SDIR/$SUB/$NAME"
    curl -fsSL "$URL" -o "$DEST" || wget -q "$URL" -O "$DEST"
    SHA="$(sha256sum "$DEST" | cut -d' ' -f1)"
    # extracts text if it is a PDF (so blocks can cite page/section)
    if file -b "$DEST" | grep -qi pdf; then
      pdftotext -layout "$DEST" "$SDIR/extracted/${NAME%.*}.txt" 2>/dev/null || true
    fi
    reg "$SDIR" "$DEST" "$SUB" "$URL" "$SHA"
    echo "OK: $URL -> $DEST  (sha256 ${SHA:0:16}…, registered in SOURCES.md)"
    ;;
  web)
    URL="${2:?url}"; TDIR="${3:?target-dir}"
    SDIR="$TDIR/sources"; mkdir -p "$SDIR/web-snapshots"
    SLUG="$(echo "$URL" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g' | cut -c1-80)"
    DEST="$SDIR/web-snapshots/$SLUG.md"
    HTML="$(mktemp)"; curl -fsSL "$URL" -o "$HTML" || wget -q "$URL" -O "$HTML"
    if command -v pandoc >/dev/null; then
      pandoc -f html -t gfm "$HTML" -o "$DEST" 2>/dev/null || cp "$HTML" "$DEST"
    else cp "$HTML" "$DEST"; fi
    rm -f "$HTML"
    SHA="$(sha256sum "$DEST" | cut -d' ' -f1)"
    reg "$SDIR" "$DEST" "web-snapshot" "$URL" "$SHA"
    echo "OK: $URL -> $DEST  (snapshot markdown, registered)"
    ;;
  *) echo "unknown mode: $MODE (doc|web|ocr)" >&2; exit 2 ;;
esac
fi
