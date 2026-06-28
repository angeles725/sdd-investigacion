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
  printf '| %s | %s | %s | %s | %s | |\n' \
    "${file#"$sdir"/}" "$kind" "$origin" "$(date -u +%FT%TZ)" "${sha:0:16}…" >> "$md"
}

MODE="${1:?usage: fetch-doc.sh doc|web|ocr ...}"

case "$MODE" in
  ocr)
    PDF="${2:?pdf required}"
    command -v tesseract >/dev/null || { echo "tesseract not installed" >&2; exit 3; }
    pdftoppm -r 300 -png "$PDF" /tmp/ocr_$$ >/dev/null 2>&1 || { echo "pdftoppm falló" >&2; exit 3; }
    for img in /tmp/ocr_$$-*.png; do tesseract "$img" stdout 2>/dev/null; done
    rm -f /tmp/ocr_$$-*.png
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
