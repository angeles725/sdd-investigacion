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
# curl PROBE, following ONLY PERMANENT redirects (301/308). Registers only what a docs-reorg /
# slug-change redirect (METHODOLOGY.md §5, retro D4) actually resolves to. Stops advancing — and
# keeps whatever URL it is currently holding — at the FIRST TEMPORARY redirect (302/303/307), a
# non-http(s) redirect target, a non-redirect response, a probe failure, a hop with no Location
# header, or MAX_HOPS. This is deliberate, not a limitation:
#   - a temporary redirect is how a short-lived signed CDN/S3/GitHub-asset URL is served;
#     registering one would put an expiring, credential-bearing link in SOURCES.md;
#   - a non-http(s) scheme (file:, javascript:, data:, ...) in a Location header is either a
#     misconfigured server or a hostile redirect target — never something to preserve as a
#     citable source URL (security hardening, round-3 review).
# Prints the RESOLVED url to stdout. Prints a stderr notice on each abnormal stop (scheme
# refused, probe failed, hop cap reached) so the reason resolution stopped is never silent —
# but prints NO "this is what got registered" claim: that announcement belongs to the CALLER
# (fetch_and_register, below), which knows whether the subsequent download actually succeeded.
# curl's own -S diagnostics are never redirected away (a probe failure must stay visible), so
# this function relies only on its own `|| break` / `[ -n ]` / scheme-check guards below — never
# on `2>/dev/null` — to stay silent-zero-safe (kit CLAUDE.md §7): an empty or malformed probe
# output must fall back to the last known-good URL, never register "".
resolve_permanent_redirect() {
  local cur="$1" hop=0 probe code loc head_rc
  local max_hops=10  # SENTINEL-MAXHOPS-VALUE (bounded hop loop — kit review PR #1155 round 2/3)
  local max_time=20  # SENTINEL-MAX-TIME (curl --max-time per hop, round 3 RS1 — bound a hanging probe)
  local connect_timeout=10  # SENTINEL-CONNECT-TIMEOUT (round-4 N3 — bounds the connect/TLS phase
  # separately from --max-time, so a connect-level failure can be told apart from a slow response)
  # SENTINEL-HOP-BOUND: the loop below must stop once `hop` reaches this bound — a chain of
  # permanent redirects longer than max_hops is followed only up to the cap, never indefinitely
  # (round-3 RS3: a genuine A<->B redirect LOOP never satisfies any other break condition, so
  # this bound is the ONLY thing that terminates it).
  while [ "$hop" -lt "$max_hops" ]; do
    # SENTINEL-PROBE-METHOD (round-3 RS1, round-4 N2/N3): HEAD first, not GET — a GET probe
    # downloads and discards the full response body on every hop, doubling transfer cost for a
    # large manual or PDF. HEAD is treated as a DEFINITIVE answer only for a redirect code
    # (301/302/303/307/308) or a real 2xx; anything else — 4xx, 5xx, 000/malformed, or empty —
    # is retried via a GET probe capped to a zero-byte range (`-r 0-0`), since some CDN/S3 fronts
    # answer HEAD with e.g. 403 while GET on the SAME url is a genuine redirect (N2). The retry is
    # skipped when the HEAD probe itself failed at the CONNECT stage (curl exit 6/7/28: could not
    # resolve host / could not connect / operation timed out) — retrying an unreachable host would
    # just double the wait for nothing (N3); that case falls straight through to the probe-failure
    # notice below.
    # SENTINEL-HEAD-GUARD: the assignment is the CONDITION of this if (exempt from `set -e`
    # regardless of whether the caller's errexit propagates into this function's call context —
    # see fetch_and_register's own doc comment on inherit_errexit), so a HEAD probe that fails
    # outright can never abort the script; it is captured as a normal (non-2xx/3xx) head_rc below.
    if probe="$(curl -sS -I -o /dev/null --connect-timeout "$connect_timeout" --max-time "$max_time" -w '%{http_code} %{redirect_url}' "$cur")"; then
      head_rc=0
    else
      head_rc=$?; probe=""
    fi
    code="${probe%% *}"
    case "$code" in
      301|302|303|307|308|2??) : ;;  # HEAD gave a definitive answer — use it as-is
      *)
        case "$head_rc" in
          6|7|28) : ;;  # SENTINEL-CONNECT-SKIP: connect-stage failure — do not retry via GET
          *)
            # SENTINEL-PROBE-FALLBACK-GET
            probe="$(curl -sS -o /dev/null --connect-timeout "$connect_timeout" --max-time "$max_time" -r 0-0 -w '%{http_code} %{redirect_url}' "$cur")" || probe=""
            ;;
        esac
        ;;
    esac
    code="${probe%% *}"; loc="${probe#* }"
    if [ -z "$code" ]; then
      # SENTINEL-PROBE-FAIL-NOTICE: BOTH the HEAD probe and its GET fallback failed outright
      # (network error, timeout, malformed URL) — not a real HTTP response, just no transfer at
      # all. `cur` (the last successfully resolved PERMANENT url — the ORIGINAL typed url on the
      # very first hop) is kept; this is a probe-level failure, distinct from a non-redirect
      # terminal response (200/404/...), which needs no notice at all — it is simply "done".
      printf 'fetch-doc: redirect probe failed for %s; keeping %s\n' "$cur" "$cur" >&2
      break
    fi
    case "$code" in
      # SENTINEL-PERMANENT-ONLY: only 301/308 advance the chain. Any other code — including a
      # temporary redirect (302/303/307) — stops resolution here, keeping `cur` as the answer.
      301|308)
        # SENTINEL-LOC-GUARD: a permanent-redirect response with NO Location header is malformed;
        # advancing to an empty `loc` would eventually register an empty origin cell (§7).
        [ -n "$loc" ] || break
        case "$loc" in
          # SENTINEL-SCHEME-GUARD (round-3 security hardening): only follow a Location whose
          # scheme is http or https. A `file:`/`javascript:`/`data:`/other-scheme target is
          # refused outright — this can only come from a misconfigured or hostile server, never
          # a legitimate docs-reorg redirect, and it is NEVER something to write into SOURCES.md.
          http://*|https://*) : ;;
          *)
            printf 'fetch-doc: refused non-http(s) redirect scheme (%s); keeping %s\n' "$loc" "$cur" >&2
            break
            ;;
        esac
        # Percent-encode a literal `|` BEFORE it ever becomes part of the chain (round-3 nit,
        # round-1 N2): a server-controlled Location containing `|` would otherwise shift the
        # SOURCES.md row's column count when this URL is later registered.
        loc="${loc//|/%7C}"
        cur="$loc"; hop=$((hop + 1))
        ;;
      *) break ;;
    esac
  done
  if [ "$hop" -eq "$max_hops" ]; then
    # SENTINEL-HOPCAP-NOTICE: the loop above exits via its OWN condition (not a `break`) only
    # when `hop` reached max_hops through max_hops consecutive successful permanent advances —
    # i.e. the hop budget, not a terminal response, is what stopped resolution.
    printf 'fetch-doc: hop cap (%s) reached; keeping %s\n' "$max_hops" "$cur" >&2
  fi
  printf '%s' "$cur"
}

# fetch_and_register <url> <dest-file> — resolves the PERMANENT-redirect destination for <url>
# (resolve_permanent_redirect above), downloads it to <dest-file> via `curl -L` (still following
# ANY further hop, including a temporary one, to reach the actual bytes — resolution and content-
# fetching are different concerns), and prints to stdout the URL that should be REGISTERED in
# SOURCES.md. Shared by BOTH doc and web mode (round-3 RR1/RDD: one call site, one set of
# guarantees, instead of two near-identical blocks that can silently drift apart).
#
# Registered value:
#   - on a successful download: the PERMANENT-resolved url. The "registered X (permanent
#     redirect from Y)" notice fires HERE, AFTER the download is confirmed — never inside
#     resolve_permanent_redirect() itself — so a subsequent total download failure can never
#     produce two contradictory "registered ..." lines (round-3 RDD/N1: the resolve notice used
#     to fire unconditionally, then a wget-fallback notice could immediately contradict it).
#   - on a total download failure (curl fails outright): wget against the ORIGINALLY TYPED url
#     (wget cannot resolve/confirm redirects the way the probe does). If wget ALSO fails, NOTHING
#     is registered (round-4 RDD — see below); otherwise the ORIGINALLY TYPED url is registered,
#     announced on stderr, never silently.
#
# errexit note (round-4 RDD): this function is always invoked as `X="$(fetch_and_register ...)"`
# — a command substitution. By default bash does NOT propagate `set -e` into a command-
# substitution subshell (`shopt -s inherit_errexit` is off, and this script does not enable it),
# so a plain failing command INSIDE this function (e.g. a bare `wget ...` call) would NOT abort
# anything on its own — execution would silently continue to the next line regardless of wget's
# exit status. Every command whose failure must be handled is therefore tested EXPLICITLY (`if
# cmd; then/else`) rather than left to rely on errexit — see the wget branch below and
# SENTINEL-HEAD-GUARD above for the same discipline inside resolve_permanent_redirect().
# curl's own -S diagnostics are never redirected away (round-2 S3).
fetch_and_register() {
  local url="$1" dest="$2" effective
  effective="$(resolve_permanent_redirect "$url")"
  # SENTINEL-DOWNLOAD: the single shared download call — `-L` is load-bearing (round-3 RS2): the
  # PERMANENT-resolved url may still sit behind one more (temporary) hop to reach the bytes, and
  # without `-L` curl saves the REDIRECT RESPONSE itself as the "document", not the real content.
  if curl -fsS -L "$effective" -o "$dest"; then
    # SENTINEL-EMPTY-BEFORE-NOTICE (round-4 N4): a 200 response can still carry an EMPTY body —
    # print the success notice only once the destination is confirmed non-empty. Printing it
    # unconditionally right after curl exits 0 would announce a "registered" URL for a fetch
    # that is about to be rejected by the caller's own `[ -s "$dest" ]` empty-body check, with
    # nothing actually registered in SOURCES.md — the exact false-success shape round-2 N1 fixed
    # on the wget-fallback path, reappearing here on the success path.
    if [ -s "$dest" ] && [ "$effective" != "$url" ]; then
      printf 'fetch-doc: registered %s (permanent redirect from %s)\n' "$effective" "$url" >&2
    fi
    printf '%s' "$effective"
  else
    # SENTINEL-WGET-GUARD (round-4 RDD): wget's own exit status is checked EXPLICITLY (see the
    # errexit note above) — a failing wget must never be treated as a successful fallback. On
    # failure, NOTHING is registered: no "registered ..." line of any kind, a typed failure
    # notice instead, and a non-zero exit from THIS subshell — which the caller's own
    # `EFFECTIVE_URL="$(fetch_and_register ...)"` assignment (running under REAL `set -e`, since
    # that call site is not itself inside another command substitution) turns into an immediate
    # script abort, exactly like any other failed command substitution assignment.
    if wget -q "$url" -O "$dest"; then
      echo "fetch-doc: registered requested URL (wget fallback; effective URL unknown)" >&2
      printf '%s' "$url"
    else
      echo "fetch-doc: wget fallback ALSO failed for $url; nothing registered" >&2
      exit 1
    fi
  fi
}

# Main dispatch is guarded so the file can be SOURCED to unit-test reg(), resolve_permanent_redirect()
# and fetch_and_register() in isolation (tests/fetch-doc.test.sh) without triggering a network
# fetch. When sourced, BASH_SOURCE[0] != $0, so nothing below runs.
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
    # SENTINEL-DOC-RESOLVE (round-3 RR1): doc mode's own call into the shared resolve+download+
    # register-value pipeline — this is the specific wiring a doc-mode-only mutant must prove
    # matters, mirroring SENTINEL-WEB-RESOLVE below.
    EFFECTIVE_URL="$(fetch_and_register "$URL" "$DEST")"
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
    HTML="$(mktemp)"
    # SENTINEL-WEB-RESOLVE (round-1 R1): web mode registers URLs exactly the same way doc mode
    # does — the D4 evidence (cloudflare/retros/2026-08-28-ztna-focus-close.md) is 4 redirected
    # Cloudflare DOC URLs, and every one of those rows is type web-snapshot (fetched via THIS
    # mode, not doc). Round 3: now the SAME shared call as doc mode, not a parallel copy.
    EFFECTIVE_URL="$(fetch_and_register "$URL" "$HTML")"
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
