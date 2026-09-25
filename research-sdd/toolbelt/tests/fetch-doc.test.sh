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

# ─── redirect-resolution tests (Tests 11-19): PR #1155 round-2 design decision ────────
# Register the URL reached through PERMANENT redirects (301/308) only — the retro D4 scenario
# (docs reorg / slug change). Stop resolving at the FIRST TEMPORARY redirect (302/303/307), so a
# short-lived signed CDN/S3/GitHub-asset URL reached only through one is NEVER registered (R4).
# Applies to BOTH doc and web modes (R1) since the D4 evidence rows are all web-snapshots.
#
# Hermetic: no network. A generic curl STUB on PATH distinguishes a PROBE call (has a -w argument
# naming 'http_code' — resolve_permanent_redirect's per-hop, non-`-L` check) from a DOWNLOAD call
# (the rest), and answers a probe by looking up "<url> <code> <location-or-dash>" rows from
# $STUB_ROUTES (newline-separated; unmatched URLs default to a plain 200, no Location — the
# no-redirect baseline). $STUB_PROBE_FAIL_URL makes the probe for that one URL fail outright
# (network-error simulation); $STUB_DOWNLOAD_FAIL=1 makes every download call fail (simulating a
# total curl transfer failure, to exercise the wget fallback). A companion wget STUB writes a
# fixed body to its -O target so the fallback path can actually "succeed".
stubbin="$TMP/stubbin"; mkdir -p "$stubbin"
cat > "$stubbin/curl" <<'STUBEOF'
#!/usr/bin/env bash
set -u
is_probe=0
for arg in "$@"; do case "$arg" in *http_code*) is_probe=1 ;; esac; done
out=""; url=""; prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  case "$arg" in http://*|https://*|file://*) url="$arg" ;; esac
  prev="$arg"
done
if [ "$is_probe" -eq 1 ]; then
  if [ -n "${STUB_PROBE_FAIL_URL:-}" ] && [ "$url" = "$STUB_PROBE_FAIL_URL" ]; then
    echo "curl: (stub) simulated probe network failure" >&2
    exit 6
  fi
  code="200"; loc=""
  while IFS=' ' read -r r_url r_code r_loc; do
    [ -z "${r_url:-}" ] && continue
    if [ "$r_url" = "$url" ]; then
      code="$r_code"; [ "${r_loc:-}" = "-" ] && loc="" || loc="${r_loc:-}"
      break
    fi
  done <<<"${STUB_ROUTES:-}"
  printf '%s %s' "$code" "$loc"
  exit 0
fi
if [ "${STUB_DOWNLOAD_FAIL:-0}" = "1" ]; then
  echo "curl: (stub) simulated download transfer failure" >&2
  exit 7
fi
[ -n "$out" ] && printf 'stub body for %s\n' "$url" >"$out"
exit 0
STUBEOF
chmod +x "$stubbin/curl"
cat > "$stubbin/wget" <<'STUBEOF'
#!/usr/bin/env bash
out=""; prev=""
for arg in "$@"; do [ "$prev" = "-O" ] && out="$arg"; prev="$arg"; done
[ -n "$out" ] && printf 'stub wget body\n' >"$out"
exit 0
STUBEOF
chmod +x "$stubbin/wget"

# runchain <mode> <dir> <typed-url> [extra doc args...] — invoke the SUT with the stub curl/wget
# on PATH and the current $STUB_ROUTES / $STUB_PROBE_FAIL_URL / $STUB_DOWNLOAD_FAIL exported.
runchain(){ local mode="$1" dir="$2" url="$3"; shift 3
  PATH="$stubbin:$PATH" bash "$SUT" "$mode" "$url" "$dir" "$@" >/dev/null 2>"$TMP/runchain.err"
}
# origin_of <sources-md> <needle> — the Origin (URL) cell of the row whose File cell matches <needle>.
origin_of(){ awk -F' \\| ' -v n="$2" '$0 ~ n {gsub(/^\| */,"",$1); print $3; exit}' "$1" 2>/dev/null; }
# runresolve <script> <url> — call resolve_permanent_redirect() from <script> DIRECTLY (source,
# guarded main never runs — same technique as runreg()), with the stub curl on PATH and the
# current $STUB_ROUTES / $STUB_PROBE_FAIL_URL exported. Tests the pure resolution logic in
# isolation from the download/wget-fallback layer, which would otherwise MASK a broken guard (an
# internal empty-URL bug gets silently recovered by the wget fallback at the pipeline level — see
# case 17 below) and so cannot prove the guard itself is load-bearing.
# shellcheck source=../fetch-doc.sh
runresolve(){ local s="$1" url="$2"
  ( set +e; PATH="$stubbin:$PATH"; source "$s" >/dev/null 2>&1; resolve_permanent_redirect "$url" 2>/dev/null )
}

# 11 — a chain of TWO permanent redirects (301, 301) resolves fully; the FINAL permanently-
#      resolved URL is returned, not the typed URL and not any intermediate hop.
STUB_ROUTES=$'http://s11.example/a 301 http://s11.example/b\nhttp://s11.example/b 301 http://s11.example/c'
export STUB_ROUTES
got11="$(runresolve "$SUT" "http://s11.example/a")"
if [ "$got11" = "http://s11.example/c" ]; then
  ok "resolve: permanent-redirect chain (301→301) resolves to the final URL"
else no "R11: expected http://s11.example/c, got '$got11'"; fi

# 12 — CORE (design decision): permanent redirect (301) THEN a temporary one (302, to a
#      short-lived signed URL) — resolves to the LAST PERMANENT URL, never the signed target and
#      never the originally typed one (a genuine permanent redirect DID happen first).
STUB_ROUTES=$'http://s12.example/a 301 http://s12.example/permanent\nhttp://s12.example/permanent 302 http://cdn.example/signed?sig=deadbeef&exp=60'
export STUB_ROUTES
got12="$(runresolve "$SUT" "http://s12.example/a")"
if [ "$got12" = "http://s12.example/permanent" ]; then
  ok "resolve: permanent-then-temporary chain stops at the last PERMANENT url, not the signed target"
else no "R12: expected http://s12.example/permanent, got '$got12'"; fi

# 13 — CORE (design decision, R4): the FIRST hop is already a temporary redirect (302) straight to
#      a signed URL — resolves to the ORIGINALLY TYPED url, unchanged (never the signed target).
STUB_ROUTES='http://s13.example/a 302 http://cdn.example/signed?sig=cafef00d'
export STUB_ROUTES
got13="$(runresolve "$SUT" "http://s13.example/a")"
if [ "$got13" = "http://s13.example/a" ]; then
  ok "resolve: immediate temporary redirect resolves to the ORIGINAL typed URL, not the signed target"
else no "R13: expected http://s13.example/a, got '$got13'"; fi

# 14 — baseline regression: no redirect at all (plain 200) — resolves to the typed URL unchanged.
STUB_ROUTES=""
export STUB_ROUTES
got14="$(runresolve "$SUT" "http://s14.example/plain")"
if [ "$got14" = "http://s14.example/plain" ]; then
  ok "resolve: no redirect (200) resolves to the typed URL unchanged"
else no "R14: expected http://s14.example/plain, got '$got14'"; fi

# 15 — R1: full pipeline, WEB mode — applies the SAME permanent-redirect-only resolution as doc
#      mode and registers the RESOLVED url in SOURCES.md (wiring check: web mode must actually
#      call resolve_permanent_redirect() and use its result, not just have the function exist).
d15="$TMP/rr-15/target"; mkdir -p "$d15"
STUB_ROUTES='http://s15.example/a 301 http://s15.example/moved'
export STUB_ROUTES
runchain web "$d15" "http://s15.example/a"
slug15="$(echo "http://s15.example/a" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g' | cut -c1-80)"
got15="$(origin_of "$d15/sources/SOURCES.md" "$slug15")"
if [ "$got15" = "http://s15.example/moved" ]; then
  ok "web: R1 — same permanent-redirect resolution applies in web mode (wiring)"
else no "R15: expected http://s15.example/moved, got '$got15' (err: $(cat "$TMP/runchain.err"))"; fi

# 16 — S1a: the PROBE request itself fails outright (simulated network error) — must not crash;
#      resolves to the ORIGINAL typed URL (the last known-good URL before the failed hop).
STUB_ROUTES=""; STUB_PROBE_FAIL_URL="http://s16.example/a"
export STUB_ROUTES STUB_PROBE_FAIL_URL
got16="$(runresolve "$SUT" "http://s16.example/a")"
unset STUB_PROBE_FAIL_URL
if [ "$got16" = "http://s16.example/a" ]; then
  ok "resolve: S1a — a failed redirect PROBE falls back to the typed URL, no crash"
else no "R16: expected http://s16.example/a, got '$got16'"; fi

# 17 — S1b (§7 silent-zero) — CORE: a 301 response with NO Location header (malformed) must not
#      advance to an empty URL. Tested at the FUNCTION level, not the pipeline: the pipeline's own
#      wget-fallback safety net (S2) would silently recover an internal empty-URL bug by falling
#      back to $URL anyway, masking whether THIS guard specifically is load-bearing.
STUB_ROUTES='http://s17.example/a 301 -'
export STUB_ROUTES
got17="$(runresolve "$SUT" "http://s17.example/a")"
if [ "$got17" = "http://s17.example/a" ] && [ -n "$got17" ]; then
  ok "resolve: S1b — a 301 with no Location does not resolve to an empty URL"
else no "R17: expected non-empty 'http://s17.example/a', got '$got17'"; fi

# 18 — S2 (doc): the actual DOWNLOAD fails after a permanent redirect resolved — wget fallback
#      registers the TYPED url (never the resolved-but-undownloadable one) and announces the
#      reversion on stderr, never silently.
d18="$TMP/rr-18/target"; mkdir -p "$d18"
STUB_ROUTES='http://s18.example/a 301 http://s18.example/resolved'; STUB_DOWNLOAD_FAIL=1
export STUB_ROUTES STUB_DOWNLOAD_FAIL
runchain doc "$d18" "http://s18.example/a" datasheets "r18.html"
unset STUB_DOWNLOAD_FAIL
got18="$(origin_of "$d18/sources/SOURCES.md" 'r18\.html')"
if [ "$got18" = "http://s18.example/a" ] && grep -qi 'wget fallback' "$TMP/runchain.err"; then
  ok "doc: S2 — wget fallback registers the typed URL and announces the reversion on stderr"
else no "R18: expected typed URL + stderr notice, got origin='$got18' err='$(cat "$TMP/runchain.err")'"; fi

# 18b — S2 (web): same wget-fallback contract in web mode.
d18b="$TMP/rr-18b/target"; mkdir -p "$d18b"
STUB_ROUTES='http://s18b.example/a 301 http://s18b.example/resolved'; STUB_DOWNLOAD_FAIL=1
export STUB_ROUTES STUB_DOWNLOAD_FAIL
runchain web "$d18b" "http://s18b.example/a"
unset STUB_DOWNLOAD_FAIL
slug18b="$(echo "http://s18b.example/a" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g' | cut -c1-80)"
got18b="$(origin_of "$d18b/sources/SOURCES.md" "$slug18b")"
if [ "$got18b" = "http://s18b.example/a" ] && grep -qi 'wget fallback' "$TMP/runchain.err"; then
  ok "web: S2 — wget fallback registers the typed URL and announces the reversion on stderr"
else no "R18b: expected typed URL + stderr notice, got origin='$got18b' err='$(cat "$TMP/runchain.err")'"; fi

# 19 — bounded hop loop: a chain of exactly 3 permanent redirects resolves fully under the
#      default cap (max_hops=10) — the positive baseline the hop-bound teeth mutant diffs
#      against (a mutant lowering the cap below 3 must stop short of the final hop).
STUB_ROUTES=$'http://s19.example/a 301 http://s19.example/h1\nhttp://s19.example/h1 301 http://s19.example/h2\nhttp://s19.example/h2 301 http://s19.example/h3'
export STUB_ROUTES
got19="$(runresolve "$SUT" "http://s19.example/a")"
if [ "$got19" = "http://s19.example/h3" ]; then
  ok "resolve: a 3-hop permanent chain resolves fully under the default (10) hop cap"
else no "R19: expected http://s19.example/h3, got '$got19'"; fi
unset STUB_ROUTES

# 20 — S3 structural check: a total download failure's curl diagnostic must reach stderr (not be
#      redirected to /dev/null) — a silent "empty body" with no reason is a debugging regression.
d20="$TMP/rr-20/target"; mkdir -p "$d20"
STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1
export STUB_ROUTES STUB_DOWNLOAD_FAIL
runchain doc "$d20" "http://s20.example/a" datasheets "r20.html"
unset STUB_DOWNLOAD_FAIL
if grep -q 'simulated download transfer failure' "$TMP/runchain.err"; then
  ok "doc: S3 — a total download failure's curl diagnostic reaches stderr, not discarded"
else no "R20: curl's own failure diagnostic missing from stderr :: $(cat "$TMP/runchain.err")"; fi

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

  # ── teeth for resolve_permanent_redirect() (Tests 11-19) — every mutant below is anchored on a
  # SENTINEL comment (N4: a stable token, not a line number or exact-code match), so a future
  # reformat that keeps the sentinel keeps the mutant working, and a real semantic edit that drops
  # the sentinel fails loudly (the grep-guard) instead of silently mutating the wrong thing.

  echo "-- teeth: SENTINEL-PERMANENT-ONLY — widen 301|308 to also treat 302/303/307 as permanent --"
  pmutant="$TMP/fetch-doc.PMUTANT.sh"
  sed '/SENTINEL-PERMANENT-ONLY/,/301|308)/ s/301|308)/301|302|303|307|308)/' "$SUT" > "$pmutant"
  if ! grep -q '301|302|303|307|308)' "$pmutant"; then
    no "teeth-permanent-only: could not build mutant (case pattern not found — did the SUT change?)"
  else
    STUB_ROUTES='http://s13.example/a 302 http://cdn.example/signed?sig=cafef00d'; export STUB_ROUTES
    got13m="$(runresolve "$pmutant" "http://s13.example/a")"
    if [ "$got13m" = "http://cdn.example/signed?sig=cafef00d" ]; then
      ok "teeth-permanent-only: mutant follows the temporary redirect into the signed URL → R12/R13 has teeth"
    else no "teeth-permanent-only: mutant still stopped at '$got13m' — R12/R13 does NOT depend on the 301|308 guard (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-LOC-GUARD — remove the empty-Location guard --"
  lmutant="$TMP/fetch-doc.LMUTANT.sh"
  sed '/SENTINEL-LOC-GUARD/,/cur="\$loc"/ s/\[ -n "\$loc" \] || break/: # MUTANT: loc-guard removed/' "$SUT" > "$lmutant"
  if ! grep -q 'MUTANT: loc-guard removed' "$lmutant"; then
    no "teeth-loc-guard: could not build mutant (guard line not found — did the SUT change?)"
  else
    STUB_ROUTES='http://s17.example/a 301 -'; export STUB_ROUTES
    got17m="$(runresolve "$lmutant" "http://s17.example/a")"
    if [ "$got17m" != "http://s17.example/a" ]; then
      ok "teeth-loc-guard: mutant advances to a non-typed (empty/broken) URL on a Location-less 301 → R17 has teeth"
    else no "teeth-loc-guard: mutant still resolved to the typed URL — R17 does NOT depend on the loc guard (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-PROBE-GUARD — remove the '|| break' after the probe capture --"
  gmutant2="$TMP/fetch-doc.G2MUTANT.sh"
  sed '/SENTINEL-PROBE-GUARD/,/redirect_url/ s/")" || break$/")"/' "$SUT" > "$gmutant2"
  if grep -q '")" || break$' "$gmutant2"; then
    no "teeth-probe-guard: could not build mutant (probe-capture line unchanged — did the SUT change?)"
  else
    STUB_ROUTES=""; STUB_PROBE_FAIL_URL="http://s16.example/a"; export STUB_ROUTES STUB_PROBE_FAIL_URL
    got16m="$(runresolve "$gmutant2" "http://s16.example/a")"
    unset STUB_PROBE_FAIL_URL
    if [ "$got16m" != "http://s16.example/a" ]; then
      ok "teeth-probe-guard: mutant does NOT gracefully fall back on a failed probe (set -e kills the resolve) → R16 has teeth"
    else no "teeth-probe-guard: mutant still fell back to the typed URL — R16 does NOT depend on '|| break' (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-MAXHOPS-VALUE — lower the hop cap below the length of a real chain --"
  hmutant2="$TMP/fetch-doc.HOPMUTANT.sh"
  sed 's/max_hops=10  # SENTINEL-MAXHOPS-VALUE.*/max_hops=2  # MUTANT: hop cap lowered/' "$SUT" > "$hmutant2"
  if ! grep -q 'MUTANT: hop cap lowered' "$hmutant2"; then
    no "teeth-maxhops: could not build mutant (max_hops declaration not found — did the SUT change?)"
  else
    STUB_ROUTES=$'http://s19.example/a 301 http://s19.example/h1\nhttp://s19.example/h1 301 http://s19.example/h2\nhttp://s19.example/h2 301 http://s19.example/h3'
    export STUB_ROUTES
    got19m="$(runresolve "$hmutant2" "http://s19.example/a")"
    if [ "$got19m" = "http://s19.example/h2" ]; then
      ok "teeth-maxhops: cap=2 mutant stops at hop 2 (h2) instead of the full 3-hop chain (h3) → R19 has teeth"
    else no "teeth-maxhops: expected mutant to stop at h2, got '$got19m' — R19 does NOT depend on the hop cap (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-WEB-RESOLVE — web mode skips redirect resolution (registers \$URL directly) --"
  wmutant="$TMP/fetch-doc.WMUTANT.sh"
  sed '/SENTINEL-WEB-RESOLVE/,/resolve_permanent_redirect "\$URL"/ s/EFFECTIVE_URL="\$(resolve_permanent_redirect "\$URL")"/EFFECTIVE_URL="$URL"  # MUTANT: web resolve skipped/' "$SUT" > "$wmutant"
  if ! grep -q 'MUTANT: web resolve skipped' "$wmutant"; then
    no "teeth-web-resolve: could not build mutant (web-mode resolve call not found — did the SUT change?)"
  else
    d15m="$TMP/teeth-web-resolve/target"; mkdir -p "$d15m"
    STUB_ROUTES='http://s15.example/a 301 http://s15.example/moved'; export STUB_ROUTES
    PATH="$stubbin:$PATH" bash "$wmutant" web "http://s15.example/a" "$d15m" >/dev/null 2>"$TMP/teeth-web.err"
    slug15m="$(echo "http://s15.example/a" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g' | cut -c1-80)"
    got15m="$(origin_of "$d15m/sources/SOURCES.md" "$slug15m")"
    if [ "$got15m" = "http://s15.example/a" ]; then
      ok "teeth-web-resolve: mutant registers the typed (unresolved) URL in web mode → R1/R15 has teeth"
    else no "teeth-web-resolve: mutant still registered '$got15m' — R1/R15 does NOT depend on the web-mode wiring (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-WGET-NOTICE (doc) — delete the wget-fallback stderr notice --"
  nmutant="$TMP/fetch-doc.NMUTANT.sh"
  # The doc-mode SENTINEL-WGET-NOTICE comment spans TWO continuation lines before the echo
  # itself, so three getlines are needed to consume comment-line-2, comment-line-3, and the
  # echo (vs. SENTINEL-WGET-RESET's one continuation line + code line = two getlines below).
  awk '/SENTINEL-WGET-NOTICE \(doc\)/{print; getline; getline; getline; next} {print}' "$SUT" > "$nmutant"
  # web mode's own identical-text notice must survive untouched (scope check: doc's occurrence
  # count must drop from 2 to 1 — grep -q alone would false-pass on the surviving web copy).
  n_orig="$(grep -c 'registered requested URL (wget fallback' "$SUT")"
  n_mut="$(grep -c 'registered requested URL (wget fallback' "$nmutant")"
  if [ "$n_mut" -ge "$n_orig" ]; then
    no "teeth-wget-notice-doc: could not build mutant (doc notice echo still present: $n_orig -> $n_mut — did the SUT change?)"
  else
    d18n="$TMP/teeth-wget-notice/target"; mkdir -p "$d18n"
    STUB_ROUTES='http://s18.example/a 301 http://s18.example/resolved'; STUB_DOWNLOAD_FAIL=1
    export STUB_ROUTES STUB_DOWNLOAD_FAIL
    PATH="$stubbin:$PATH" bash "$nmutant" doc "http://s18.example/a" "$d18n" datasheets "r18n.html" >/dev/null 2>"$TMP/teeth-notice.err"
    unset STUB_DOWNLOAD_FAIL
    if ! grep -qi 'wget fallback' "$TMP/teeth-notice.err"; then
      ok "teeth-wget-notice-doc: mutant emits NO reversion notice on wget fallback → R18 has teeth"
    else no "teeth-wget-notice-doc: mutant still emitted the notice — R18 does NOT depend on the echo (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-WGET-RESET (doc) — delete the EFFECTIVE_URL reset after wget fallback --"
  rmutant="$TMP/fetch-doc.RMUTANT.sh"
  awk '/SENTINEL-WGET-RESET \(doc\)/{print; getline; getline; next} {print}' "$SUT" > "$rmutant"
  if grep -A2 'SENTINEL-WGET-RESET (doc)' "$rmutant" | grep -q 'EFFECTIVE_URL="\$URL"'; then
    no "teeth-wget-reset-doc: could not build mutant (reset line still present — did the SUT change?)"
  else
    d18r="$TMP/teeth-wget-reset/target"; mkdir -p "$d18r"
    STUB_ROUTES='http://s18.example/a 301 http://s18.example/resolved'; STUB_DOWNLOAD_FAIL=1
    export STUB_ROUTES STUB_DOWNLOAD_FAIL
    PATH="$stubbin:$PATH" bash "$rmutant" doc "http://s18.example/a" "$d18r" datasheets "r18r.html" >/dev/null 2>/dev/null
    unset STUB_DOWNLOAD_FAIL
    got18r="$(origin_of "$d18r/sources/SOURCES.md" 'r18r\.html')"
    if [ "$got18r" = "http://s18.example/resolved" ]; then
      ok "teeth-wget-reset-doc: mutant registers the resolved-but-undownloadable URL, not the typed one → R18 has teeth"
    else no "teeth-wget-reset-doc: mutant registered '$got18r' (expected the resolved url) — R18 does NOT depend on the reset (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-S3 — restore 2>/dev/null on the doc-mode download call (swallows curl -S diagnostics) --"
  smutant="$TMP/fetch-doc.SMUTANT.sh"
  sed 's/if ! curl -fsS -L "\$EFFECTIVE_URL" -o "\$DEST"; then/if ! curl -fsS -L "$EFFECTIVE_URL" -o "$DEST" 2>\/dev\/null; then/' "$SUT" > "$smutant"
  if ! grep -q 'curl -fsS -L "\$EFFECTIVE_URL" -o "\$DEST" 2>/dev/null; then' "$smutant"; then
    no "teeth-s3: could not build mutant (doc-mode download line not found — did the SUT change?)"
  else
    d_s3="$TMP/teeth-s3/target"; mkdir -p "$d_s3"
    STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; export STUB_ROUTES STUB_DOWNLOAD_FAIL
    PATH="$stubbin:$PATH" bash "$smutant" doc "http://s3.example/a" "$d_s3" datasheets "r-s3.html" >/dev/null 2>"$TMP/teeth-s3.err"
    unset STUB_DOWNLOAD_FAIL
    if ! grep -q 'simulated download transfer failure' "$TMP/teeth-s3.err"; then
      ok "teeth-s3: 2>/dev/null mutant swallows curl's own failure diagnostic → S3 structural check has teeth"
    else no "teeth-s3: mutant's stderr still carried the diagnostic — S3 check does NOT depend on keeping stderr (THEATER)"; fi
  fi
  unset STUB_ROUTES

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
