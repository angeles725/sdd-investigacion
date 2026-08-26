#!/usr/bin/env bash
# fetch-doc.test.sh — RED-FIRST harness for fetch-doc.sh's reg() SOURCES.md registrar.
#
# The load-bearing behaviour (retro delta): reg() must insert a new source row at the END OF THE (first)
# MARKDOWN TABLE, not blindly at EOF. A real SOURCES.md (the bootstrap template's own shape) carries trailing
# prose sections (## Structure / ## Notes) AFTER the table; a blind `>> "$md"` appends new rows BELOW those
# sections, splitting the document into two disconnected table fragments. The discriminating case feeds a
# SOURCES.md whose table is followed by a `## Structure` section and asserts the new row lands ABOVE it
# (inside the table). --prove-teeth reverts reg() to an EOF append and asserts the row then lands BELOW the
# prose, proving the placement assertion is genuinely load-bearing and not theater.
#
# reg() is unit-tested by SOURCING fetch-doc.sh (its main dispatch is guarded), so no network fetch runs.
#
# Usage: fetch-doc.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error (SUT missing).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../fetch-doc.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# runreg <script> <sdir> <file> <kind> <origin> <sha> — call reg() from <script> in an isolated subshell
# (source defines the function; the guarded main never runs; set +e keeps a reg failure from killing us).
# shellcheck source=../fetch-doc.sh
runreg(){ local s="$1"; shift; ( set +e; source "$s" >/dev/null 2>&1; reg "$@" ); }
# lineno <file> <fixed-string> — 1-based line number of the first line CONTAINING the string, or 0.
lineno(){ awk -v s="$2" 'index($0,s){print NR; exit}' "$1"; }

echo "== fetch-doc.test.sh (SUT: $(basename "$SUT")) =="

# 1 — reg() CREATES SOURCES.md with the header when absent, and the new row is the last table line.
d="$TMP/create/sources"; mkdir -p "$d"
runreg "$SUT" "$d" "$d/datasheets/a.pdf" "datasheet" "https://x/a.pdf" "deadbeef"
if [ -f "$d/SOURCES.md" ] \
   && grep -q '^| File | Type |' "$d/SOURCES.md" \
   && grep -q '| datasheets/a.pdf | datasheet | https://x/a.pdf |' "$d/SOURCES.md"; then
  ok "reg() creates SOURCES.md with header + registers the row"
else no "create: SOURCES.md not built as expected :: $(head -6 "$d/SOURCES.md" 2>/dev/null | tr '\n' '/')"; fi

# 2 — CORE (retro delta): a SOURCES.md whose table is followed by a '## Structure' prose section — the new
#     row must land ABOVE '## Structure' (end of table), NOT appended at EOF below it. RED before the fix.
d="$TMP/trailing/sources"; mkdir -p "$d"
cat > "$d/SOURCES.md" <<'EOF'
# Preserved external sources

| File | Type | Origin (URL) | Date (UTC) | sha256 | Blocks that cite it |
|---|---|---|---|---|---|
| datasheets/example.pdf | datasheet | https://... | 2026-06-28T00:00:00Z | abc123 | [Block K] |

## Structure

```
sources/
  datasheets/
```
EOF
runreg "$SUT" "$d" "$d/manuals/new.pdf" "manuals" "https://y/new.pdf" "cafef00d"
row_line="$(lineno "$d/SOURCES.md" 'manuals/new.pdf')"
struct_line="$(lineno "$d/SOURCES.md" '## Structure')"
if [ "$row_line" -gt 0 ] && [ "$struct_line" -gt 0 ] && [ "$row_line" -lt "$struct_line" ]; then
  ok "new row inserted at END OF TABLE, above '## Structure' (row L$row_line < struct L$struct_line)"
else no "trailing-prose: row L$row_line vs struct L$struct_line (want row < struct — appended below prose?)"; fi

# 3 — the inserted row is CONTIGUOUS with the existing table (immediately after the last prior table row),
#     so the two rows form ONE table, not two fragments.
prev_line="$(lineno "$d/SOURCES.md" 'datasheets/example.pdf')"
if [ "$row_line" = "$((prev_line + 1))" ]; then
  ok "new row is contiguous with the existing table (L$row_line == L$prev_line + 1) — one table, no fragment"
else no "contiguity: new row L$row_line, prior row L$prev_line (want L$((prev_line+1)))"; fi

# 4 — NO trailing prose (table is the whole body): reg() still appends at the end (backward-compatible).
d="$TMP/notrail/sources"; mkdir -p "$d"
cat > "$d/SOURCES.md" <<'EOF'
# Preserved external sources

| File | Type | Origin (URL) | Date (UTC) | sha256 | Blocks that cite it |
|---|---|---|---|---|---|
| datasheets/first.pdf | datasheet | https://... | 2026-06-28T00:00:00Z | abc | [Block 1] |
EOF
runreg "$SUT" "$d" "$d/manuals/second.pdf" "manuals" "https://z/second.pdf" "b0b0"
last="$(tail -1 "$d/SOURCES.md")"
if grep -q 'manuals/second.pdf' <<<"$last"; then
  ok "no trailing prose → row appended at end of table (last line), backward-compatible"
else no "no-trail: last line is '$last' (want the new row)"; fi

# 5 — CORE (retro delta / FIX): a source VALUE containing a BACKSLASH must be written BYTE-IDENTICALLY.
#     `awk -v newrow="$row"` subjects the value to awk's C-style escape processing (\t → TAB, \b → backspace),
#     so a basename/URL with a backslash is MANGLED in the SOURCES.md cell — diverging from the literal value
#     verify-sources.sh later cross-checks. Passing via the environment (ENVIRON["newrow"], no -v) preserves
#     it verbatim. RED before the fix: the written cell differs from the input origin.
d="$TMP/backslash/sources"; mkdir -p "$d"
bsurl='https://ex/a\test\back.pdf'   # literal backslash-t and backslash-b — the exact escape trap
runreg "$SUT" "$d" "$d/datasheets/x.pdf" "datasheet" "$bsurl" "feed"
if grep -qF "$bsurl" "$d/SOURCES.md"; then
  ok "backslash-bearing source value written byte-identically (no awk -v escape corruption)"
else no "backslash corrupted: row=$(grep -F 'datasheets/x.pdf' "$d/SOURCES.md" | head -1)"; fi

# ─── doc-mode PDF integration tests (run the SUT as a process; no network) ─────────────
# Guards: curl for file:// fetching (wget cannot fetch file:// URLs), file(1) for PDF
# detection, and pdftotext for Test 6's extraction assertion.
# The fixture is a valid minimal PDF decoded from base64 (Catalog→Pages→Page→Contents
# stream "BT /F1 12 Tf 100 700 Td (Hello) Tj ET" with a correct xref table, ~535 bytes).
# pdftotext extracts "Hello" from it, so Test 6 is non-vacuous: the old dump line would
# have created sources/extracted/test.txt from this fixture.
_pdf_fixture="$TMP/valid.pdf"
base64 -d <<'ENDPDF' > "$_pdf_fixture"
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
_have_curl=false
command -v curl >/dev/null 2>&1 && _have_curl=true
_pdf_ok=false
if command -v file >/dev/null 2>&1 && file -b "$_pdf_fixture" 2>/dev/null | grep -qi pdf; then _pdf_ok=true; fi
_have_pdftotext=false
if command -v pdftotext >/dev/null 2>&1; then
  _ptxt_out="$(pdftotext "$_pdf_fixture" - 2>/dev/null)"
  if [ -n "$_ptxt_out" ]; then _have_pdftotext=true; fi
fi

if ! $_have_curl; then
  printf '  SKIP  doc-pdf-{6..8}: curl not available (wget cannot fetch file:// URLs)\n'
elif ! $_pdf_ok; then
  printf '  SKIP  doc-pdf-{6..8}: file(1) did not classify valid PDF fixture as PDF\n'
else
  d="$TMP/doc-pdf/target"; mkdir -p "$d"
  _out78="$TMP/doc78.out"; _err78="$TMP/doc78.err"
  bash "$SUT" doc "file://$_pdf_fixture" "$d" datasheets "test.pdf" >"$_out78" 2>"$_err78"

  # 6 — flat .txt must NOT be created under sources/extracted/.
  # Requires pdftotext: only when pdftotext can extract text from the fixture is this
  # assertion non-vacuous — with the old dump line restored in a mutant, pdftotext creates
  # the .txt; without it (real SUT), the .txt must be absent.
  if ! $_have_pdftotext; then
    printf '  SKIP  doc-pdf-6: pdftotext absent or produced no text from fixture\n'
  elif [ ! -f "$d/sources/extracted/test.txt" ]; then
    ok "doc-pdf: flat .txt NOT created under sources/extracted/ (no false pdftotext dump)"
  else
    no "doc-pdf-notxt: flat .txt WAS created at sources/extracted/test.txt — must not exist after fix"
  fi

  # 7 — extract-pdf.sh hint must be printed on stderr or stdout
  if grep -q 'extract-pdf\.sh' "$_err78" || grep -q 'extract-pdf\.sh' "$_out78"; then
    ok "doc-pdf: extract-pdf.sh hint IS printed"
  else
    no "doc-pdf-hint: hint not printed (stderr: $(cat "$_err78"); stdout: $(cat "$_out78"))"
  fi

  # 8 — PDF must still be saved and registered in SOURCES.md (core fetch+reg unaffected)
  if [ -f "$d/sources/datasheets/test.pdf" ] \
     && [ -f "$d/sources/SOURCES.md" ] \
     && grep -q 'datasheets/test.pdf' "$d/sources/SOURCES.md"; then
    ok "doc-pdf: PDF saved to datasheets/ and registered in SOURCES.md"
  else
    no "doc-pdf-reg: PDF not saved or not registered (datasheets: $(ls "$d/sources/datasheets/" 2>/dev/null || echo MISSING); SOURCES: $([ -f "$d/sources/SOURCES.md" ] && echo present || echo MISSING))"
  fi
fi

# NEGATIVE CONTROL — revert reg() to a blind EOF append; the trailing-prose fixture must then place the row
# BELOW '## Structure', proving case 2's placement assertion has teeth.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: force the awk insert to the EOF-append branch (last=0); expect the row BELOW '## Structure' --"
  mutant="$TMP/fetch-doc.MUTANT.sh"
  # Neuter the end-of-table insert: pin the tracked last-table-row index to 0 so the END block always takes
  # the `last==0` fallback (append newrow at EOF) — the old buggy behaviour.
  sed 's/intable=1; last=NR/intable=1; last=0/' "$SUT" > "$mutant"
  if ! grep -q 'intable=1; last=0' "$mutant"; then
    no "teeth: could not build mutant (reg() awk-insert line not found — did the SUT change?)"
  else
    d="$TMP/teeth/sources"; mkdir -p "$d"
    cat > "$d/SOURCES.md" <<'EOF'
# Preserved external sources

| File | Type | Origin (URL) | Date (UTC) | sha256 | Blocks that cite it |
|---|---|---|---|---|---|
| datasheets/example.pdf | datasheet | https://... | 2026-06-28T00:00:00Z | abc123 | [Block K] |

## Structure

```
sources/
```
EOF
    runreg "$mutant" "$d" "$d/manuals/new.pdf" "manuals" "https://y/new.pdf" "cafef00d"
    r="$(lineno "$d/SOURCES.md" 'manuals/new.pdf')"; s="$(lineno "$d/SOURCES.md" '## Structure')"
    if [ "$r" -gt "$s" ]; then
      ok "teeth: EOF-append mutant lands the row BELOW '## Structure' (L$r > L$s) → case 2 has teeth"
    else no "teeth: mutant row L$r vs struct L$s (want row > struct) — case 2 does NOT depend on the insert (THEATER)"; fi
  fi

  echo "-- teeth: revert ENVIRON→ awk -v; expect the backslash cell to be escape-corrupted (not byte-identical) --"
  vmutant="$TMP/fetch-doc.VMUTANT.sh"
  sed 's/newrow="$row" awk/awk -v newrow="$row"/; s/ENVIRON\["newrow"\]/newrow/g' "$SUT" > "$vmutant"
  if ! grep -q 'awk -v newrow="$row"' "$vmutant"; then
    no "teeth: could not build the -v mutant (ENVIRON insert line not found — did the SUT change?)"
  else
    d="$TMP/teeth-bs/sources"; mkdir -p "$d"
    bsurl='https://ex/a\test\back.pdf'
    runreg "$vmutant" "$d" "$d/datasheets/x.pdf" "datasheet" "$bsurl" "feed"
    if ! grep -qF "$bsurl" "$d/SOURCES.md"; then
      ok "teeth: awk -v mutant escape-corrupts the backslash cell → case 5 has teeth"
    else no "teeth: -v mutant preserved the backslash — case 5 does NOT depend on ENVIRON (THEATER)"; fi
  fi

  # Teeth for case 7 (hint): delete the printf hint line; expect hint absent → proves case 7 is not theater.
  if $_pdf_ok && $_have_curl; then
    echo "-- teeth: delete PDF hint printf; expect hint absent → case 7 has teeth --"
    hmutant="$TMP/fetch-doc.HMUTANT.sh"
    # Replace the printf hint with a no-op ':' — deleting the line entirely produces an empty
    # if/then/fi which bash rejects as a syntax error (then branch must have ≥1 statement).
    sed 's/printf .hint: PDF saved.*/>\/dev\/null \&\&: # MUTANT hint removed/' "$SUT" > "$hmutant"
    if ! bash -n "$hmutant" >/dev/null 2>&1; then
      no "teeth-hint: mutant failed bash -n (invalid syntax after hint line substitution)"
    elif grep -q 'hint: PDF saved' "$hmutant"; then
      no "teeth-hint: could not build hint mutant (hint printf line not found in SUT — did the SUT change?)"
    else
      d="$TMP/teeth-hint/target"; mkdir -p "$d"
      _err_th="$TMP/teeth-hint.err"; _out_th="$TMP/teeth-hint.out"
      bash "$hmutant" doc "file://$_pdf_fixture" "$d" datasheets "test.pdf" >"$_out_th" 2>"$_err_th"
      if ! grep -q 'extract-pdf\.sh' "$_err_th" && ! grep -q 'extract-pdf\.sh' "$_out_th"; then
        ok "teeth-hint: hint-deleted mutant prints NO hint → case 7 has teeth (not theater)"
      else
        no "teeth-hint: mutant still printed extract-pdf.sh — case 7 does NOT depend on hint printf (THEATER)"
      fi
    fi
  fi

  # Teeth for case 6 (no-pdftotext-dump): re-insert the removed pdftotext dump line into a
  # mutant, run on the valid PDF fixture, and assert extracted/test.txt IS created — proving
  # Test 6 bites. The real SUT must NOT create it; the mutant MUST.
  if $_have_curl && $_pdf_ok && $_have_pdftotext; then
    echo "-- teeth: re-insert pdftotext dump into mutant; expect extracted/test.txt created → case 6 has teeth --"
    dmutant="$TMP/fetch-doc.DMUTANT.sh"
    # Inject mkdir -p + pdftotext dump immediately after the hint printf line in doc mode
    # (inside the PDF if-block), restoring the old pre-fix behavior.
    awk '/printf .hint: PDF saved.*>&2/ {
      print
      print "      mkdir -p \"$SDIR/extracted\""
      print "      pdftotext -layout \"$DEST\" \"$SDIR/extracted/${NAME%.*}.txt\" 2>/dev/null || true"
      next
    }
    { print }' "$SUT" > "$dmutant"
    if ! bash -n "$dmutant" >/dev/null 2>&1; then
      no "teeth-dump: mutant failed bash -n (injection produced invalid syntax)"
    elif ! grep -q 'pdftotext -layout' "$dmutant"; then
      no "teeth-dump: could not build dump mutant (hint printf line not found — did the SUT change?)"
    else
      d6m="$TMP/teeth-dump/target"; mkdir -p "$d6m"
      bash "$dmutant" doc "file://$_pdf_fixture" "$d6m" datasheets "test.pdf" >/dev/null 2>&1
      if [ -f "$d6m/sources/extracted/test.txt" ] && [ -s "$d6m/sources/extracted/test.txt" ]; then
        ok "teeth-dump: dump mutant created non-empty extracted/test.txt → case 6 has teeth (not theater)"
      else
        no "teeth-dump: dump mutant did NOT create extracted/test.txt — case 6 does NOT bite (THEATER)"
      fi
    fi
  fi
fi

# ─── doc-mode empty-body guard (Tests 9–10) ──────────────────────────────────
# A 200-with-empty-body must NOT be registered in SOURCES.md (§7 false-success fix).
# We use a real 0-byte file and fetch it with file://, which curl handles.
# These tests are guarded by $_have_curl (same guard as Tests 6-8).
_empty_doc="$TMP/empty.bin"; : > "$_empty_doc"    # guaranteed 0-byte file
_empty_html="$TMP/empty.html"; : > "$_empty_html"

if ! $_have_curl; then
  printf '  SKIP  doc-empty-{9..10}: curl not available\n'
else
  # Test 9: doc mode — empty body must cause non-zero exit and must NOT register a row
  d9="$TMP/empty-doc/target"; mkdir -p "$d9"
  _rc9=0
  bash "$SUT" doc "file://$_empty_doc" "$d9" datasheets "empty.bin" \
    >/dev/null 2>"$TMP/err9.txt" || _rc9=$?
  _row9=false
  [ -f "$d9/sources/SOURCES.md" ] && grep -q 'empty.bin' "$d9/sources/SOURCES.md" && _row9=true
  if [ "$_rc9" -ne 0 ] && ! $_row9; then
    ok "doc empty-body: non-zero exit and no SOURCES.md row registered"
  else
    no "doc empty-body: expected failure+no-row; got rc=$_rc9 row=$_row9 (err: $(cat "$TMP/err9.txt"))"
  fi

  # Test 10: web mode — empty HTML body must cause non-zero exit and must NOT register
  d10="$TMP/empty-web/target"; mkdir -p "$d10"
  _rc10=0
  bash "$SUT" web "file://$_empty_html" "$d10" \
    >/dev/null 2>"$TMP/err10.txt" || _rc10=$?
  _slug10="$(echo "file://$_empty_html" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g' | cut -c1-80)"
  _dest10="$d10/sources/web-snapshots/$_slug10.md"
  _row10=false
  [ -f "$d10/sources/SOURCES.md" ] && grep -q "$_slug10" "$d10/sources/SOURCES.md" && _row10=true
  if [ "$_rc10" -ne 0 ] && ! $_row10; then
    ok "web empty-body: non-zero exit and no SOURCES.md row registered"
  else
    no "web empty-body: expected failure+no-row; got rc=$_rc10 row=$_row10 dest-exists=$([ -s "$_dest10" ] && echo yes || echo no) (err: $(cat "$TMP/err10.txt"))"
  fi

  # ── Teeth for doc empty-body guard ───────────────────────────────────────────
  if [ "${1:-}" = "--prove-teeth" ]; then
    echo "-- teeth: remove doc [ -s \"\$DEST\" ] guard; empty body must then register + OK --"
    gmutant="$TMP/fetch-doc.GMUTANT.sh"
    # Remove the empty-body guard line in doc mode (the [ -s "$DEST" ] line we added).
    sed '/\[ -s "\$DEST" \] || { echo "fetch-doc: empty body/d' "$SUT" > "$gmutant"
    if grep -q '\[ -s "\$DEST" \]' "$gmutant"; then
      no "teeth-doc-empty: could not build guard mutant ([ -s \"\$DEST\" ] line still present)"
    else
      d9m="$TMP/teeth-doc-empty/target"; mkdir -p "$d9m"
      _rc9m=0
      bash "$gmutant" doc "file://$_empty_doc" "$d9m" datasheets "empty.bin" \
        >/dev/null 2>/dev/null || _rc9m=$?
      _row9m=false
      [ -f "$d9m/sources/SOURCES.md" ] && grep -q 'empty.bin' "$d9m/sources/SOURCES.md" && _row9m=true
      if [ "$_rc9m" -eq 0 ] && $_row9m; then
        ok "teeth-doc-empty: guard-removed mutant exits 0 and registers row → Test 9 has teeth"
      else
        no "teeth-doc-empty: mutant rc=$_rc9m row=$_row9m (expected 0+row)"
      fi
    fi

    echo "-- teeth: remove web [ -s \"\$HTML\" ] guard; empty HTML must then register + OK --"
    gwmutant="$TMP/fetch-doc.GWMUTANT.sh"
    # Remove the [ -s "$HTML" ] guard line in web mode (checks raw download before pandoc).
    sed '/\[ -s "\$HTML" \] || { echo "fetch-doc: empty body/d' "$SUT" > "$gwmutant"
    if grep -q '"fetch-doc: empty body.*\$HTML' "$gwmutant"; then
      no "teeth-web-empty: could not build guard mutant (guard line still present)"
    else
      d10m="$TMP/teeth-web-empty/target"; mkdir -p "$d10m"
      _rc10m=0
      bash "$gwmutant" web "file://$_empty_html" "$d10m" \
        >/dev/null 2>/dev/null || _rc10m=$?
      _slug10m="$(echo "file://$_empty_html" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g' | cut -c1-80)"
      _row10m=false
      [ -f "$d10m/sources/SOURCES.md" ] && grep -q "$_slug10m" "$d10m/sources/SOURCES.md" && _row10m=true
      if [ "$_rc10m" -eq 0 ] && $_row10m; then
        ok "teeth-web-empty: guard-removed mutant exits 0 and registers row → Test 10 has teeth"
      else
        no "teeth-web-empty: mutant rc=$_rc10m row=$_row10m (expected 0+row)"
      fi
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
