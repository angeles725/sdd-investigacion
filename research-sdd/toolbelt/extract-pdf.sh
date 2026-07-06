#!/usr/bin/env bash
#
# extract-pdf.sh — Research-SDD PDF → page-anchored Markdown extractor.
#
# WHY: pdftotext dumps a wall of text (tables mangled) and `-nopgbrk` DESTROYS the
# page mapping that the citation model needs (`x.pdf :p.N`). This wrapper produces
# .md that (a) keeps tables, (b) carries a `<!-- p.N -->` anchor before every page,
# and (c) records the extraction METHOD so OCR-derived text (error-prone) is flagged.
#
# TWO TIERS (auto-selected by probing the text layer):
#   Tier 1 — PDF HAS a text layer   → pymupdf4llm (tables + page anchors). Fast, no OCR.
#   Tier 2 — PDF is SCANNED (fonts=0)→ add a text layer, then Tier 1:
#              premium: marker | docling  (best structure on hard scans, needs --premium)
#              default: ocrmypdf -l spa+eng --force-ocr  → Tier 1
#              bare    : pdftoppm + tesseract -l spa+eng (parallel), page-anchored
#
# RULE: never OCR a PDF that already has a text layer. OCR is a FALLBACK, not the default.
# RULE: heavy OCR sweeps should be DELEGATED (research-sweep-cheap), not run on the driver.
# RULE: extract only the page RANGE a gap needs; do not convert whole books blindly.
#
# Usage:
#   extract-pdf.sh [options] <input.pdf>
#     -o FILE        output .md path (default: <pdf-dir>/../text-extracts/<name>.md)
#     -p RANGE       page range: "N" or "N-M" (default: all pages)
#     --lang L       OCR languages for Tier 2 (default: spa+eng)
#     --premium      prefer marker/docling for scanned PDFs (if installed)
#     --engine E     force: pymupdf | pdftotext | ocrmypdf | marker | docling | tesseract
#     -f, --force    overwrite an existing extract (default: skip if present — idempotent)
#     -q, --quiet    only print the output path
#     -h, --help     this help
#
# Prints, on success: the output path, the method used, and a SOURCES.md-ready row.
set -uo pipefail

# ── Tool resolution ──────────────────────────────────────────────────────────
VENV="${RESEARCH_SDD_VENV:-$HOME/.local/share/research-sdd-tools/venv}"
VPY="$VENV/bin/python"
[ -x "$VPY" ] || VPY=""                         # venv optional; degrade gracefully
OCRMYPDF="$VENV/bin/ocrmypdf";   [ -x "$OCRMYPDF" ] || OCRMYPDF="$(command -v ocrmypdf || true)"
MARKER="$VENV/bin/marker_single"; [ -x "$MARKER" ] || MARKER="$(command -v marker_single || true)"
DOCLING="$VENV/bin/docling";     [ -x "$DOCLING" ] || DOCLING="$(command -v docling || true)"
have() { command -v "$1" >/dev/null 2>&1; }
die()  { echo "extract-pdf: $*" >&2; exit 1; }

# ── Args ─────────────────────────────────────────────────────────────────────
OUT=""; RANGE=""; LANG_OCR="spa+eng"; PREMIUM=0; ENGINE=""; FORCE=0; QUIET=0; IN=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2;;
    -p) RANGE="$2"; shift 2;;
    --lang) LANG_OCR="$2"; shift 2;;
    --premium) PREMIUM=1; shift;;
    --engine) ENGINE="$2"; shift 2;;
    -f|--force) FORCE=1; shift;;
    -q|--quiet) QUIET=1; shift;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    -*) die "unknown option: $1";;
    *) IN="$1"; shift;;
  esac
done
[ -n "$IN" ] || die "no input PDF (use -h for help)"
[ -f "$IN" ] || die "file not found: $IN"
have pdfinfo || die "poppler (pdfinfo) not in PATH"

IN="$(readlink -f "$IN")"
NAME="$(basename "${IN%.*}")"
if [ -z "$OUT" ]; then
  OUT="$(dirname "$IN")/../text-extracts/${NAME}.md"
fi
mkdir -p "$(dirname "$OUT")"

# Idempotency
if [ -f "$OUT" ] && [ "$FORCE" -eq 0 ]; then
  [ "$QUIET" -eq 1 ] && echo "$OUT" || echo "extract-pdf: cached (use -f to redo) -> $OUT"
  exit 0
fi

SHA="$(sha256sum "$IN" | cut -d' ' -f1)"
PAGES_TOTAL="$(pdfinfo "$IN" 2>/dev/null | awk '/^Pages:/{print $2}')"

# Page-range flags for the poppler/pymupdf tools
PF=""; PL=""
if [ -n "$RANGE" ]; then
  PF="${RANGE%%-*}"; PL="${RANGE##*-}"
fi

# ── Probe the text layer ─────────────────────────────────────────────────────
FONTS=0
have pdffonts && FONTS="$(pdffonts "$IN" 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')"
CHARS="$(pdftotext -f 1 -l 5 "$IN" - 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')"
HAS_TEXT=0
{ [ "${FONTS:-0}" -gt 0 ] && [ "${CHARS:-0}" -gt 100 ]; } && HAS_TEXT=1

# ── Tier 1: pymupdf4llm (text layer → markdown with tables + page anchors) ───
tier1_pymupdf() {  # $1=source pdf  $2=out md  $3=method-label
  local src="$1" out="$2" method="$3"
  [ -n "$VPY" ] || return 3
  "$VPY" - "$src" "$out" "$method" "$SHA" "$PAGES_TOTAL" "${PF:-}" "${PL:-}" <<'PY'
import sys
src, out, method, sha, total, pf, pl = sys.argv[1:8]
try:
    import pymupdf4llm, fitz
except Exception as e:
    print(f"IMPORT_FAIL {e}", file=sys.stderr); sys.exit(3)
doc = fitz.open(src)
pages = None
if pf and pl:
    pages = list(range(int(pf)-1, int(pl)))          # 0-indexed
chunks = pymupdf4llm.to_markdown(doc, pages=pages, page_chunks=True)
# pymupdf4llm 1.28 leaves metadata['page']=None; derive the real page from the
# requested list (or sequential order when extracting all pages).
pagelist = pages if pages is not None else list(range(len(chunks)))
parts = []
for i, ch in enumerate(chunks):
    n = pagelist[i] + 1
    parts.append(f"\n\n<!-- ===== p.{n} ===== -->\n\n{ch['text'].rstrip()}")
body = "".join(parts).lstrip()
hdr = (f"---\nsource_pdf: {src}\nsha256: {sha}\npages_total: {total}\n"
       f"page_range: {pf+'-'+pl if pf and pl else 'all'}\nmethod: {method}\n"
       f"reliability: {'ocr-lossy' if 'ocr' in method or 'tesseract' in method or 'marker' in method or 'docling' in method else 'text-layer'}\n---\n\n")
open(out, "w").write(hdr + body + "\n")
print("OK")
PY
}

# ── Tier 1 fallback: pdftotext WITH page breaks (never -nopgbrk) ─────────────
tier1_pdftotext() {  # $1=src $2=out $3=method
  local src="$1" out="$2" method="$3" rng=""
  [ -n "$PF" ] && rng="-f $PF -l $PL"
  { echo "---"; echo "source_pdf: $src"; echo "sha256: $SHA";
    echo "pages_total: $PAGES_TOTAL"; echo "method: $method"; echo "reliability: text-layer"; echo "---"; echo; } > "$out"
  # pdftotext emits form-feed (\f) between pages; split on it to anchor each page.
  pdftotext -layout $rng "$src" - 2>/dev/null | awk -v p="${PF:-1}" '
    BEGIN{ printf "\n<!-- ===== p.%d ===== -->\n\n", p }
    {
      n = split($0, a, "\f")
      printf "%s", a[1]
      for (i=2; i<=n; i++) { p++; printf "\n\n<!-- ===== p.%d ===== -->\n\n%s", p, a[i] }
      printf "\n"
    }' >> "$out"
  [ -s "$out" ] && echo OK || return 1
}

# ── Tier 2 premium: marker / docling (scanned → md directly) ─────────────────
tier2_marker() {  # $1=src $2=out
  [ -n "$MARKER" ] || return 3
  local tmp; tmp="$(mktemp -d)"
  "$MARKER" "$1" --output_dir "$tmp" --output_format markdown >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  local md; md="$(find "$tmp" -name '*.md' | head -1)"
  [ -n "$md" ] || { rm -rf "$tmp"; return 1; }
  { echo "---"; echo "source_pdf: $1"; echo "sha256: $SHA"; echo "pages_total: $PAGES_TOTAL";
    echo "method: marker"; echo "reliability: ocr-lossy"; echo "---"; echo; cat "$md"; } > "$2"
  rm -rf "$tmp"; echo OK
}
tier2_docling() {  # $1=src $2=out
  [ -n "$DOCLING" ] || return 3
  local tmp; tmp="$(mktemp -d)"
  "$DOCLING" "$1" --to md --output "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  local md; md="$(find "$tmp" -name '*.md' | head -1)"
  [ -n "$md" ] || { rm -rf "$tmp"; return 1; }
  { echo "---"; echo "source_pdf: $1"; echo "sha256: $SHA"; echo "pages_total: $PAGES_TOTAL";
    echo "method: docling"; echo "reliability: ocr-lossy"; echo "---"; echo; cat "$md"; } > "$2"
  rm -rf "$tmp"; echo OK
}

# ── Tier 2 default: ocrmypdf → text layer → Tier 1 ───────────────────────────
tier2_ocrmypdf() {  # $1=src $2=out
  [ -n "$OCRMYPDF" ] || return 3
  local tmp; tmp="$(mktemp --suffix=.pdf)"
  "$OCRMYPDF" -l "$LANG_OCR" --force-ocr --output-type pdf "$1" "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  tier1_pymupdf "$tmp" "$2" "ocrmypdf+pymupdf"; local rc=$?
  rm -f "$tmp"; return $rc
}

# ── Tier 2 bare: pdftoppm + tesseract (parallel), page-anchored ──────────────
tier2_tesseract() {  # $1=src $2=out
  have pdftoppm && have tesseract || return 3
  local tmp; tmp="$(mktemp -d)"; local f="${PF:-1}" l="${PL:-$PAGES_TOTAL}"
  pdftoppm -r 300 -gray -f "$f" -l "$l" "$1" "$tmp/pg" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  # OCR each page in parallel; one text file per page.
  ls "$tmp"/pg-*.pgm 2>/dev/null | xargs -P"$(nproc)" -I{} sh -c \
    'tesseract "{}" "${1%.pgm}" -l '"$LANG_OCR"' --psm 1 >/dev/null 2>&1' _ {}
  { echo "---"; echo "source_pdf: $1"; echo "sha256: $SHA"; echo "pages_total: $PAGES_TOTAL";
    echo "method: tesseract"; echo "reliability: ocr-lossy"; echo "---"; echo; } > "$2"
  local n="$f"
  for txt in $(ls "$tmp"/pg-*.txt 2>/dev/null | sort); do
    printf '\n<!-- ===== p.%d ===== -->\n\n' "$n" >> "$2"; cat "$txt" >> "$2"; n=$((n+1))
  done
  rm -rf "$tmp"; [ -s "$2" ] && echo OK || return 1
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
METHOD=""; RC=1
[ "$FORCE" -eq 1 ] && rm -f "$OUT"      # avoid false-success on a stale file
# Success = the tier command exits 0 AND produced a non-empty $OUT (stdout is ignored,
# since MuPDF/OCR libs print progress noise there).
run() { "$@" >/dev/null 2>&1 && [ -s "$OUT" ]; }

if [ -n "$ENGINE" ]; then
  case "$ENGINE" in
    pymupdf)   run tier1_pymupdf "$IN" "$OUT" "pymupdf"   && METHOD="pymupdf"   && RC=0;;
    pdftotext) run tier1_pdftotext "$IN" "$OUT" "pdftotext" && METHOD="pdftotext" && RC=0;;
    ocrmypdf)  run tier2_ocrmypdf "$IN" "$OUT" && METHOD="ocrmypdf+pymupdf" && RC=0;;
    marker)    run tier2_marker "$IN" "$OUT"   && METHOD="marker"   && RC=0;;
    docling)   run tier2_docling "$IN" "$OUT"  && METHOD="docling"  && RC=0;;
    tesseract) run tier2_tesseract "$IN" "$OUT"&& METHOD="tesseract"&& RC=0;;
    *) die "unknown engine: $ENGINE";;
  esac
elif [ "$HAS_TEXT" -eq 1 ]; then
  # Tier 1
  if run tier1_pymupdf "$IN" "$OUT" "pymupdf"; then METHOD="pymupdf"; RC=0
  elif run tier1_pdftotext "$IN" "$OUT" "pdftotext"; then METHOD="pdftotext"; RC=0; fi
else
  # Tier 2 (scanned)
  if [ "$PREMIUM" -eq 1 ] && run tier2_marker "$IN" "$OUT"; then METHOD="marker"; RC=0
  elif [ "$PREMIUM" -eq 1 ] && run tier2_docling "$IN" "$OUT"; then METHOD="docling"; RC=0
  elif run tier2_ocrmypdf "$IN" "$OUT"; then METHOD="ocrmypdf+pymupdf"; RC=0
  elif run tier2_tesseract "$IN" "$OUT"; then METHOD="tesseract"; RC=0; fi
fi

[ "$RC" -eq 0 ] || die "extraction failed (text_layer=$HAS_TEXT fonts=$FONTS chars=$CHARS; check that the venv or ocrmypdf/tesseract are available)"

# ── Report ───────────────────────────────────────────────────────────────────
if [ "$QUIET" -eq 1 ]; then
  echo "$OUT"
else
  REL="text-layer"; case "$METHOD" in *ocr*|marker|docling|tesseract) REL="ocr-lossy (verify numbers/quotes)";; esac
  echo "extract-pdf: OK"
  echo "  method     : $METHOD  [$REL]"
  echo "  text_layer : $([ "$HAS_TEXT" -eq 1 ] && echo yes || echo 'no (scanned)')  (fonts=$FONTS, sample_chars=$CHARS)"
  echo "  pages      : ${RANGE:-all}/$PAGES_TOTAL"
  echo "  output     : $OUT"
  echo "  SOURCES.md : | $(basename "$IN") | PDF | local | ${SHA:0:12}… | method:$METHOD |"
fi
