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
# ── Tests 3–4: tier2_marker / tier2_docling [ -s "$2" ] guard ─────────────────
# These tests use a minimal pre-built PDF (base64-embedded, no fitz needed) and
# stub converters controlled via PATH.  They run ahead of the fitz skip guard so
# that CI environments without PyMuPDF still exercise the new guard.
#
# The minimal PDF is the same fixture used by fetch-doc.test.sh: a valid Catalog→
# Pages→Page→Contents PDF (type1/Helvetica, "Hello" text, correct xref, ~535 B).
_min_pdf="$TMP/minimal.pdf"
base64 -d <<'ENDPDF' > "$_min_pdf"
JVBERi0xLjQKMSAwIG9iajw8L1R5cGUvQ2F0YWxvZy9QYWdlcyAyIDAgUj4+ZW5kb2JqCjIgMCBv
Ymo8PC9UeXBlL1BhZ2VzL0tpZHNbMyAwIFJdL0NvdW50IDE+PmVuZG9iagozIDAgb2JqPDwvVHlw
ZS9QYWdlL1BhcmVudCAyIDAgUi9NZWRpYUJveFswIDAgNjEyIDc5Ml0vUmVzb3VyY2VzPDwvRm9u
dDw8L0YxIDUgMCBSPj4+Pi9Db250ZW50cyA0IDAgUj4+ZW5kb2JqCjQgMCBvYmo8PC9MZW5ndGgg
Mzc+PgpzdHJlYW0KQlQgL0YxIDEyIFRmIDEwMCA3MDAgVGQgKEhlbGxvKSBUaiBFVAplbmRzdHJl
YW0KZW5kb2JqCjUgMCBvYmo8PC9UeXBlL0ZvbnQvU3VidHlwZS9UeXBlMS9CYXNlRm9udC9IZWx2
ZXRpY2E+PmVuZG9iagp4cmVmCjAgNgowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAw
MDAgbiAKMDAwMDAwMDA1MiAwMDAwMCBuIAowMDAwMDAwMTAxIDAwMDAwIG4gCjAwMDAwMDAyMTEg
MDAwMDAgbiAKMDAwMDAwMDI5NSAwMDAwMCBuIAp0cmFpbGVyPDwvU2l6ZSA2L1Jvb3QgMSAwIFI+
PgpzdGFydHhyZWYKMzU2CiUlRU9GCg==
ENDPDF

if ! command -v pdfinfo >/dev/null 2>&1; then
  printf '  SKIP  tier2_marker/docling guard tests: pdfinfo not in PATH (required by SUT)\n'
else
  mkdir -p "$TMP/bin"

  # stub: exits 0 but creates no .md in --output_dir (failure case)
  _stub_noop="$TMP/bin/marker_single"
  printf '#!/bin/sh\n# stub: exits 0, produces no .md in --output_dir\nexit 0\n' > "$_stub_noop"
  chmod +x "$_stub_noop"

  _rc3=0
  PATH="$TMP/bin:$PATH" bash "$SUT" -f --engine marker \
    -o "$TMP/out-marker-noop.md" "$_min_pdf" >/dev/null 2>&1 || _rc3=$?
  if [ "$_rc3" -ne 0 ] && [ ! -s "$TMP/out-marker-noop.md" ]; then
    ok "tier2_marker [ -s guard ]: stub-no-output → non-zero exit, no output file"
  else
    no "tier2_marker [ -s guard ]: expected failure; got rc=$_rc3 file=$([ -s "$TMP/out-marker-noop.md" ] && echo non-empty || echo empty/absent)"
  fi

  _stub_docling="$TMP/bin/docling"
  printf '#!/bin/sh\n# stub: exits 0, produces no .md in --output_dir\nexit 0\n' > "$_stub_docling"
  chmod +x "$_stub_docling"

  _rc4=0
  PATH="$TMP/bin:$PATH" bash "$SUT" -f --engine docling \
    -o "$TMP/out-docling-noop.md" "$_min_pdf" >/dev/null 2>&1 || _rc4=$?
  if [ "$_rc4" -ne 0 ] && [ ! -s "$TMP/out-docling-noop.md" ]; then
    ok "tier2_docling [ -s guard ]: stub-no-output → non-zero exit, no output file"
  else
    no "tier2_docling [ -s guard ]: expected failure; got rc=$_rc4 file=$([ -s "$TMP/out-docling-noop.md" ] && echo non-empty || echo empty/absent)"
  fi

  if [ "${1:-}" = "--prove-teeth" ]; then
    # Teeth A: success-path stub + guard mutated to always return 1 → SUT must fail
    echo "-- teeth A: tier2_marker size-guard mutated to 'return 1'; success-stub must then fail --"
    cat > "$_stub_noop" <<'STUBEOF'
#!/bin/sh
# stub: exits 0 and creates a .md with content in --output_dir
nextdir=0; tmpdir=""
for a; do
  if [ "$nextdir" = 1 ]; then tmpdir="$a"; nextdir=0
  elif [ "$a" = "--output_dir" ]; then nextdir=1; fi
done
[ -n "$tmpdir" ] && mkdir -p "$tmpdir" && printf '# Stub output\n\nContent.\n' > "$tmpdir/output.md"
exit 0
STUBEOF
    chmod +x "$_stub_noop"

    MUTANT_A="$TMP/extract-pdf.MUTANT-sz-A.sh"
    sed '/^tier2_marker()/,/^tier2_docling()/ {
      s/\[ -s "[$]2" \] && echo OK || return 1/return 1/
    }' "$SUT" > "$MUTANT_A"

    if ! grep -q 'return 1$' "$MUTANT_A"; then
      no "teeth-A: could not build tier2_marker size-guard mutant"
    else
      _rcA=0
      PATH="$TMP/bin:$PATH" bash "$MUTANT_A" -f --engine marker \
        -o "$TMP/out-mutA.md" "$_min_pdf" >/dev/null 2>&1 || _rcA=$?
      if [ "$_rcA" -ne 0 ]; then
        ok "teeth-A: size-guard mutant (always return 1) causes failure → guard has teeth on success path"
      else
        no "teeth-A: size-guard mutant still exits 0 — guard is NOT load-bearing (THEATER)"
      fi
    fi

    # Teeth B: failure-path stub (no .md) + [ -n "$md" ] guard removed
    # Without that guard, cat "" fails but set -uo/no-e lets echo OK run (YAML header
    # written before cat); so SUT exits 0.  Test expects non-zero → would be RED.
    echo "-- teeth B: [ -n \"\$md\" ] guard removed; stub-no-output must then cause SUT to exit 0 --"
    printf '#!/bin/sh\n# stub: exits 0, produces no .md\nexit 0\n' > "$_stub_noop"
    chmod +x "$_stub_noop"

    MUTANT_B="$TMP/extract-pdf.MUTANT-sz-B.sh"
    sed '/^tier2_marker()/,/^tier2_docling()/ {
      s/\[ -n "\$md" \] || { rm -rf "\$tmp"; return 1; }/: # NEUTERED md-guard/
    }' "$SUT" > "$MUTANT_B"

    if ! grep -q 'NEUTERED md-guard' "$MUTANT_B"; then
      no "teeth-B: could not build [ -n \"\$md\" ] mutant"
    else
      _rcB=0
      PATH="$TMP/bin:$PATH" bash "$MUTANT_B" -f --engine marker \
        -o "$TMP/out-mutB.md" "$_min_pdf" >/dev/null 2>&1 || _rcB=$?
      # Mutant exits 0 (YAML header written before cat "" fails; [ -s ] sees header).
      if [ "$_rcB" -eq 0 ]; then
        ok "teeth-B: guard-removed mutant exits 0 on stub-no-output → failure-path test has teeth"
      else
        no "teeth-B: guard-removed mutant exits non-zero (rc=$_rcB) — teeth unclear"
      fi
    fi
  fi
fi

# ── fitz-dependent tests (mojibake detection) ─────────────────────────────────
# Run only when python3+fitz+poppler are all present; print per-section SKIP
# messages otherwise so the global summary still reflects the counts above.
_have_fitz=false
_have_poppler=true
command -v python3 >/dev/null 2>&1 && python3 -c "import fitz" 2>/dev/null && _have_fitz=true
for _t in pdfinfo pdftotext pdffonts; do
  command -v "$_t" >/dev/null 2>&1 || { _have_poppler=false; break; }
done

if ! $_have_fitz || ! $_have_poppler; then
  if ! $_have_poppler; then
    printf '  SKIP  mojibake tests: pdffonts/pdftotext/pdfinfo not in PATH\n'
  else
    printf '  SKIP  mojibake tests: python3+fitz not found\n'
  fi
else

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
fi  # end fitz-dependent block

# Whole-suite skip: when NO case ran (tier2 needs pdfinfo; mojibake needs
# python3+fitz+poppler — all can be absent on CI), emit a "SKIP:" line so
# run-all.sh classifies this as a SKIPPED suite, not a "zero test cases" failure
# (run-all.sh:144 keys skip off '^SKIP:'; without it a fully-skipped run is a fail).
if [ $((pass + fail)) -eq 0 ]; then
  echo "SKIP: extract-pdf.test.sh — required tools absent (pdfinfo/poppler/fitz); no cases executed"
  exit 0
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
