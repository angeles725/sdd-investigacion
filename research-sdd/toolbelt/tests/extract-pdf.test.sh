#!/usr/bin/env bash
# extract-pdf.test.sh — TDD tests for extract-pdf.sh's mojibake detection.
#
# Core behaviour under test:
#   A PDF whose text layer decodes to zero ASCII letters (broken/absent ToUnicode
#   CMap — the classic UTF-8-as-Latin-1 double-encoding pattern) must be routed
#   to Tier 2 (re-render / OCR), NOT returned verbatim as "text-layer" output.
#   A PDF with genuine readable text must continue to route to Tier 1 (unchanged).
#
# Fixtures are generated at runtime from PyMuPDF (fitz).  The suite is skipped
# when python3+fitz or the poppler tools are absent, so it is CI-safe.
#
# Usage: extract-pdf.test.sh [--prove-teeth]
# Exit:  0 all held · 1 regression · 2 harness error (SUT or critical tool missing)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../extract-pdf.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== extract-pdf.test.sh (SUT: $(basename "$SUT")) =="

# ── Tool guards ───────────────────────────────────────────────────────────────
# Fixture creation requires python3 + fitz (PyMuPDF); SUT requires poppler.
# Whole-suite skip uses the "SKIP: ..." prefix so run-all.sh classifies it as
# a skipped suite rather than a failed one.
_skip_all() { echo "SKIP: $*"; echo "== 0 passed · 0 failed =="; exit 0; }

command -v python3 >/dev/null 2>&1 || _skip_all "python3 not found — needed to create PDF fixtures"
python3 -c "import fitz" 2>/dev/null   || _skip_all "PyMuPDF/fitz not found — needed to create PDF fixtures"
for _t in pdfinfo pdftotext pdffonts; do
  command -v "$_t" >/dev/null 2>&1 || _skip_all "$_t not in PATH — required by SUT"
done

# ── Fixture: good text PDF ────────────────────────────────────────────────────
# FONTS > 0, CHARS > 100, high ASCII ratio — should route to Tier 1.
GOOD_PDF="$TMP/good.pdf"
python3 - "$GOOD_PDF" <<'PY'
import sys, fitz
doc = fitz.open()
page = doc.new_page(width=612, height=792)
rect = fitz.Rect(50, 50, 560, 750)
text = ("This is a properly encoded research document with readable text content. " * 8)
page.insert_textbox(rect, text, fontsize=10)
doc.save(sys.argv[1])
PY
[ -f "$GOOD_PDF" ] || { echo "FATAL: could not create good-text fixture" >&2; exit 2; }

# ── Fixture: mojibake PDF ─────────────────────────────────────────────────────
# FONTS > 0, CHARS > 100, zero ASCII letters — signature of broken ToUnicode CMap.
# Latin-1 supplement chars (U+00A0–U+00FE) are representable in Helvetica/WinAnsi
# and are the classic artefact of UTF-8-as-Latin-1 double-encoding.
MOJI_PDF="$TMP/mojibake.pdf"
python3 - "$MOJI_PDF" <<'PY'
import sys, fitz
doc = fitz.open()
page = doc.new_page(width=612, height=792)
rect = fitz.Rect(50, 50, 560, 750)
garbage = "".join(chr(c) for c in range(0xA0, 0xFF)) * 6  # 570 chars, 0 ASCII letters
page.insert_textbox(rect, garbage, fontsize=10)
doc.save(sys.argv[1])
PY
[ -f "$MOJI_PDF" ] || { echo "FATAL: could not create mojibake fixture" >&2; exit 2; }

# ── Fixture sanity checks (probe properties, not extract-pdf behaviour) ───────
_g_fonts=$(pdffonts "$GOOD_PDF" 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')
_g_chars=$(pdftotext -f 1 -l 5 "$GOOD_PDF" - 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')
_g_ascii=$(pdftotext -f 1 -l 5 "$GOOD_PDF" - 2>/dev/null | tr -cd 'A-Za-z0-9' | wc -c | tr -d ' ')
_m_fonts=$(pdffonts "$MOJI_PDF" 2>/dev/null | tail -n +3 | wc -l | tr -d ' ')
_m_chars=$(pdftotext -f 1 -l 5 "$MOJI_PDF" - 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')
_m_ascii=$(pdftotext -f 1 -l 5 "$MOJI_PDF" - 2>/dev/null | tr -cd 'A-Za-z0-9' | wc -c | tr -d ' ')

if [ "${_g_fonts:-0}" -gt 0 ] && [ "${_g_chars:-0}" -gt 100 ] && [ "${_g_ascii:-0}" -gt 50 ]; then
  ok "fixture-sanity: good PDF — fonts=${_g_fonts} chars=${_g_chars} ascii=${_g_ascii} (readable)"
else
  no "fixture-sanity: good PDF fails probe expectations (fonts=${_g_fonts} chars=${_g_chars} ascii=${_g_ascii})"
fi

if [ "${_m_fonts:-0}" -gt 0 ] && [ "${_m_chars:-0}" -gt 100 ] && [ "${_m_ascii:-0}" -eq 0 ]; then
  ok "fixture-sanity: mojibake PDF — fonts=${_m_fonts} chars=${_m_chars} ascii=${_m_ascii} (garbage)"
else
  no "fixture-sanity: mojibake PDF fails probe expectations (fonts=${_m_fonts} chars=${_m_chars} ascii=${_m_ascii})"
fi

# ── Test 1: good text → Tier 1 (method=pymupdf or pdftotext) ─────────────────
OUT_GOOD="$TMP/out-good.md"
if bash "$SUT" -f -o "$OUT_GOOD" "$GOOD_PDF" >/dev/null 2>&1 && [ -f "$OUT_GOOD" ]; then
  _method=$(awk '/^method:/{print $2; exit}' "$OUT_GOOD")
  case "$_method" in
    pymupdf|pdftotext)
      ok "good-text: routes to Tier 1 (method=$_method) — no change to valid text handling";;
    *)
      no "good-text: expected Tier-1 method (pymupdf|pdftotext), got '$_method'";;
  esac
else
  no "good-text: extract-pdf.sh failed or produced no output on valid-text fixture"
fi

# ── Test 2 (RED→GREEN): mojibake must NOT route to Tier 1 ────────────────────
# Before the fix: HAS_TEXT=1 (FONTS>0, CHARS>100) → Tier 1 → garbage written
#   verbatim with method=pdftotext or method=pymupdf (BUG).
# After the fix: mojibake detected (0 ASCII letters) → HAS_TEXT overridden to 0
#   → Tier 2 runs (OCR/render), method is NOT pdftotext/pymupdf.
OUT_MOJI="$TMP/out-moji.md"
_moji_rc=0
bash "$SUT" -f -o "$OUT_MOJI" "$MOJI_PDF" >/dev/null 2>&1 || _moji_rc=$?
if [ "$_moji_rc" -eq 0 ] && [ -f "$OUT_MOJI" ]; then
  _method=$(awk '/^method:/{print $2; exit}' "$OUT_MOJI")
  case "$_method" in
    pdftotext|pymupdf)
      no "mojibake: routed to Tier 1 (method=$_method) — garbage chars returned as 'text-layer' output (BUG)";;
    *)
      ok "mojibake: did NOT route to Tier 1 (method=$_method) — garbage text not returned verbatim";;
  esac
elif [ "$_moji_rc" -ne 0 ]; then
  # A non-zero exit is also acceptable: the script correctly refused to return garbage
  # and reported failure because no suitable Tier-2 tool was available.
  if command -v pdftoppm >/dev/null 2>&1 && command -v tesseract >/dev/null 2>&1; then
    no "mojibake: extract-pdf.sh failed (rc=$_moji_rc) despite pdftoppm+tesseract being available"
  else
    ok "mojibake: extract-pdf.sh failed (rc=$_moji_rc) — correctly refused to return garbage; Tier-2 tools absent"
  fi
else
  no "mojibake: extract-pdf.sh exited 0 but produced no output file"
fi

# ── Teeth: neuter IS_MOJIBAKE override → mojibake must then route to Tier 1 ──
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter IS_MOJIBAKE override; expect Tier-1 method on mojibake fixture --"
  MUTANT="$TMP/extract-pdf.MUTANT.sh"
  # Pin IS_MOJIBAKE to 0 by replacing the final override line with a no-op.
  # The detector still runs but its conclusion never reaches the dispatch logic.
  # The address+substitution form replaces the entire matching LINE, avoiding the
  # partial-match trap where a substring replacement leaves an invalid prefix.
  sed '/IS_MOJIBAKE.*HAS_TEXT=0/s/.*/: # NEUTERED mojibake override/' "$SUT" > "$MUTANT"
  if ! grep -q 'NEUTERED mojibake override' "$MUTANT"; then
    no "teeth: could not build mutant (override line not found — did SUT change?)"
  else
    OUT_TEETH="$TMP/out-teeth.md"
    bash "$MUTANT" -f -o "$OUT_TEETH" "$MOJI_PDF" >/dev/null 2>&1 || true
    if [ -f "$OUT_TEETH" ]; then
      _method=$(awk '/^method:/{print $2; exit}' "$OUT_TEETH")
      case "$_method" in
        pdftotext|pymupdf)
          ok "teeth: neutered mutant routes mojibake to Tier 1 (method=$_method) — Test 2 has teeth";;
        *)
          no "teeth: neutered mutant still uses method='$_method' — Test 2 does NOT depend on mojibake check (THEATER)";;
      esac
    else
      no "teeth: neutered mutant produced no output on mojibake fixture"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
