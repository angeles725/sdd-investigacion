#!/usr/bin/env bash
# fetch-doc.sh — downloads and PRESERVES external sources (datasheets, manuals,
# forums, links) inside TARGET/sources/ with a traceable record in SOURCES.md.
# fetch-doc downloads and registers; page-anchored extraction is extract-pdf.sh's job.
# Research-SDD rule: URLs die; evidence does not.
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

# resolve_permanent_redirect <url> — walks the redirect chain from <url> via a bounded per-hop
# curl PROBE (no -L; one request per hop), following ONLY PERMANENT redirects (301/308).
# Registers only what a docs-reorg / slug-change redirect (METHODOLOGY.md §5, retro D4) actually
# resolves to. Stops advancing — and keeps whatever URL it is currently holding — at the FIRST
# TEMPORARY redirect (302/303/307), a non-redirect response, a probe failure, a hop with no
# Location header, or MAX_HOPS: this is deliberate, not a limitation — a temporary redirect is
# how a short-lived signed CDN/S3/GitHub-asset URL is served, and registering THAT would put an
# expiring, credential-bearing link in SOURCES.md instead of the stable page the operator typed
# or the permanent location it moved to. Prints the resolved URL to stdout; prints one line to
# stderr naming both URLs when they differ. curl's own -S diagnostics are never redirected away
# (a probe failure must stay visible), so this function relies only on the `|| break` / `[ -n ]`
# guards below — never on `2>/dev/null` — to stay silent-zero-safe (kit CLAUDE.md §7): an empty
# or malformed probe output must fall back to the last known-good URL, never register "".
resolve_permanent_redirect() {
  local start="$1" cur="$1" hop=0 probe code loc
  local max_hops=10  # SENTINEL-MAXHOPS-VALUE (bounded hop loop — kit review PR #1155 round 2)
  # SENTINEL-HOP-BOUND: the loop below must stop once `hop` reaches this bound — a chain of
  # permanent redirects longer than max_hops is followed only up to the cap, never indefinitely.
  while [ "$hop" -lt "$max_hops" ]; do
    # SENTINEL-PROBE-GUARD: a probe request that fails outright (network error, bad URL) must
    # break out with `cur` unchanged — never let the failure propagate past this function.
    probe="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$cur")" || break
    code="${probe%% *}"; loc="${probe#* }"
    case "$code" in
      # SENTINEL-PERMANENT-ONLY: only 301/308 advance the chain. Any other code — including a
      # temporary redirect (302/303/307) — stops resolution here, keeping `cur` as the answer.
      301|308)
        # SENTINEL-LOC-GUARD: a permanent-redirect response with NO Location header is malformed;
        # advancing to an empty `loc` would eventually register an empty origin cell (§7).
        [ -n "$loc" ] || break
        cur="$loc"; hop=$((hop + 1))
        ;;
      *) break ;;
    esac
  done
  if [ "$cur" != "$start" ]; then
    printf 'registered %s (permanent redirect from %s)\n' "$cur" "$start" >&2
  fi
  printf '%s' "$cur"
}

# Main dispatch is guarded so the file can be SOURCED to unit-test reg() and
# resolve_permanent_redirect() in isolation (tests/fetch-doc.test.sh) without triggering a
# network fetch. When sourced, BASH_SOURCE[0] != $0, so nothing below runs.
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
    SDIR="$TDIR/sources"; mkdir -p "$SDIR/$SUB"
    NAME="${5:-$(basename "${URL%%\?*}")}"; DEST="$SDIR/$SUB/$NAME"
    # Resolve the PERMANENT-redirect-only destination BEFORE downloading (see
    # resolve_permanent_redirect above) so SOURCES.md registers the stable, re-fetchable URL
    # rather than an ephemeral signed one. -L is still used for the actual download: a
    # permanently-resolved URL may still sit behind one more (temporary) hop to reach the bytes.
    EFFECTIVE_URL="$(resolve_permanent_redirect "$URL")"
    # SENTINEL-WGET-FALLBACK (doc): curl's own -S diagnostics are NOT discarded (S3) — a total
    # download failure must stay visible, not read as a silent "empty body".
    if ! curl -fsS -L "$EFFECTIVE_URL" -o "$DEST"; then
      wget -q "$URL" -O "$DEST"
      # SENTINEL-WGET-NOTICE (doc): wget cannot resolve/confirm redirects the way the probe
      # above does, so the registered URL reverts to the originally typed one — and that
      # reversion is announced, never silent.
      echo "fetch-doc: registered requested URL (wget fallback; effective URL unknown)" >&2
      # SENTINEL-WGET-RESET (doc): without this, EFFECTIVE_URL would still hold the
      # (possibly undownloadable) permanently-resolved URL instead of the URL wget actually used.
      EFFECTIVE_URL="$URL"
    fi
    [ -s "$DEST" ] || { echo "fetch-doc: empty body: $URL" >&2; rm -f "$DEST"; exit 1; }
    SHA="$(sha256sum "$DEST" | cut -d' ' -f1)"
    # When the saved file is a PDF, recommend the canonical page-anchored extraction tool.
    # pdftotext -layout produces a FLAT .txt with NO page anchors — blocks cannot cite
    # page/section from it (§5). Page-anchored extraction belongs to extract-pdf.sh, which
    # produces sources/extracted/<name>.md with YAML front-matter (METHODOLOGY.md §5/§15).
    # pipefail-audit: external `file -b` producer. Fleet max <100 B (single-line type description).
    # Race onset for external producers: ~64 KB. Fleet max << onset; structurally safe.
    if file -b "$DEST" | grep -qi pdf; then
      printf 'hint: PDF saved. For page-anchored citations (§5), run: extract-pdf.sh "%s"  (a flat pdftotext dump has no page anchors and must not be cited).\n' "$DEST" >&2
    fi
    reg "$SDIR" "$DEST" "$SUB" "$EFFECTIVE_URL" "$SHA"
    echo "OK: $URL -> $DEST  (sha256 ${SHA:0:16}…, registered in SOURCES.md)"
    ;;
  web)
    URL="${2:?url}"; TDIR="${3:?target-dir}"
    SDIR="$TDIR/sources"; mkdir -p "$SDIR/web-snapshots"
    SLUG="$(echo "$URL" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g' | cut -c1-80)"
    DEST="$SDIR/web-snapshots/$SLUG.md"
    # SENTINEL-WEB-RESOLVE (R1): web mode registers URLs exactly the same way doc mode does — the
    # D4 evidence (cloudflare/retros/2026-08-28-ztna-focus-close.md) is 4 redirected Cloudflare
    # DOC URLs, and every one of those rows is type web-snapshot (fetched via THIS mode, not doc).
    EFFECTIVE_URL="$(resolve_permanent_redirect "$URL")"
    HTML="$(mktemp)"
    # SENTINEL-WGET-FALLBACK (web): curl's own -S diagnostics are NOT discarded (S3).
    if ! curl -fsS -L "$EFFECTIVE_URL" -o "$HTML"; then
      wget -q "$URL" -O "$HTML"
      # SENTINEL-WGET-NOTICE (web): same reversion-is-announced contract as doc mode.
      echo "fetch-doc: registered requested URL (wget fallback; effective URL unknown)" >&2
      # SENTINEL-WGET-RESET (web): same as doc — without this, EFFECTIVE_URL would still hold
      # the resolved-but-undownloadable URL instead of the URL wget actually used.
      EFFECTIVE_URL="$URL"
    fi
    [ -s "$HTML" ] || { echo "fetch-doc: empty body: $URL" >&2; rm -f "$HTML"; exit 1; }
    if command -v pandoc >/dev/null; then
      pandoc -f html -t gfm "$HTML" -o "$DEST" 2>/dev/null || cp "$HTML" "$DEST"
    else cp "$HTML" "$DEST"; fi
    rm -f "$HTML"
    SHA="$(sha256sum "$DEST" | cut -d' ' -f1)"
    reg "$SDIR" "$DEST" "web-snapshot" "$EFFECTIVE_URL" "$SHA"
    echo "OK: $URL -> $DEST  (snapshot markdown, registered)"
    ;;
  *) echo "unknown mode: $MODE (doc|web|ocr)" >&2; exit 2 ;;
esac
fi
