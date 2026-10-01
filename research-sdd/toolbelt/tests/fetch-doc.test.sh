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

# ─── redirect-resolution tests (Tests 11-31+): PR #1155 round-2/round-3 design ────────
# Register the URL reached through PERMANENT redirects (301/308) only — the retro D4 scenario
# (docs reorg / slug change). Stop resolving at the FIRST TEMPORARY redirect (302/303/307), a
# non-http(s) redirect target, a probe failure, a Location-less hop, or a hop cap — so a
# short-lived signed CDN/S3/GitHub-asset URL reached only through a temporary hop is NEVER
# registered (R4), and a hostile/misconfigured non-http(s) Location is NEVER followed (round-3
# security hardening). Applies to BOTH doc and web modes (R1) via ONE shared helper,
# fetch_and_register() (round-3 dedup), since the D4 evidence rows are all web-snapshots.
#
# Hermetic: no network. A generic curl STUB on PATH classifies each invocation:
#   - PROBE (any arg mentions 'http_code'): resolve_permanent_redirect's per-hop check.
#       - HEAD probe: '-I' present (the round-3 RS1 default — avoids downloading the body twice).
#       - GET-fallback probe: '-I' absent (has -r 0-0 instead; used when HEAD answers 405/501/000).
#   - DOWNLOAD (the rest): fetch_and_register's actual content fetch — honors '-L' (round-3 RS2):
#       WITH '-L' it follows the FULL chain (any redirect code) to the final target, like real
#       curl; WITHOUT '-L' it returns a distinct "REDIRECT body (no -L)" stub for a URL that is
#       itself still a redirect, so a test can tell "downloaded the real content" apart from
#       "downloaded the redirect response" — proving '-L' is load-bearing, not just present.
#
# Routing: $STUB_ROUTES is a newline-separated "<url> <code> <location-or-dash>" table (dash = no
# Location). Unmatched URLs default to a plain 200, no Location (the no-redirect baseline).
# Special controls:
#   $STUB_PROBE_FAIL_URL  — the probe (HEAD AND its GET fallback) for this exact URL fails
#                            outright (simulated network error) on every hop that hits it.
#   $STUB_HEAD_FAIL_URL   — ONLY the HEAD probe for this exact URL returns 405 (forcing the
#                            GET-fallback path); the GET-fallback probe for the SAME URL is then
#                            answered normally from $STUB_ROUTES (proves the 405→GET path works),
#                            UNLESS $STUB_GET_FALLBACK_FAIL_URL also names it (below).
#   $STUB_GET_FALLBACK_FAIL_URL — ONLY the GET-fallback probe (never the HEAD probe) for this
#                            exact URL fails outright — used together with $STUB_HEAD_FAIL_URL to
#                            simulate "HEAD says 405, AND the GET retry also fails".
#   $STUB_HEAD_ROUTES     — a SEPARATE routing table (same "<url> <code> <location-or-dash>"
#                            format) consulted ONLY for HEAD probes when it names the url;
#                            otherwise HEAD falls back to the shared $STUB_ROUTES answer (round-4
#                            N2: lets a test say "HEAD answers 403/404 for this url, but GET
#                            would answer 301" — a divergence real CDN/S3 fronts exhibit).
#   $STUB_HEAD_CONNECT_FAIL_URL — the HEAD probe for this exact URL fails at the CONNECT stage
#                            (round-4 N3), exiting with $STUB_HEAD_CONNECT_FAIL_RC (default 7 —
#                            "couldn't connect") and printing NOTHING — unambiguous, so no
#                            GET-fallback retry should follow (see $STUB_PROBE_COUNT_FILE below).
#   $STUB_HEAD_BLACKHOLE_URL — the HEAD probe for this exact URL exits 28 ("Operation timed
#                            out") with %{time_connect}=0 (round-5 N2'/N3': the connect phase
#                            itself never completed) — ambiguous rc, but the zero time_connect
#                            disambiguates it as connect-class too; no GET-fallback retry.
#   $STUB_HEAD_HANG_URL   — the HEAD probe for this exact URL exits 28 with a NONZERO
#                            %{time_connect} (default 1.234000, override via
#                            $STUB_HEAD_HANG_TIME_CONNECT) — "connected, then the response hung"
#                            — the GET-fallback retry SHOULD still be attempted.
#   $STUB_PROBE_COUNT_FILE — when set, EVERY probe call (HEAD or GET-fallback) appends the
#                            requested url to this file — lets a test count how many probe
#                            ATTEMPTS a single hop actually cost (N3: exactly one on a connect
#                            failure, two on a 405/501/000/other-4xx-5xx fallback).
#   $STUB_DOWNLOAD_FAIL=1 — every DOWNLOAD call fails outright (simulates a total curl transfer
#                            failure, to exercise the wget fallback).
#   $STUB_DOWNLOAD_EMPTY=1 — every DOWNLOAD call "succeeds" (exit 0, like a 200 response) but
#                            writes ZERO bytes to its -o target (round-4 N4: a successful-looking
#                            fetch with an empty body).
# A companion wget STUB writes a fixed body to its -O target so the fallback path can "succeed",
# unless $STUB_WGET_FAIL=1 (round-4 RDD), in which case it fails outright and writes nothing.
stubbin="$TMP/stubbin"; mkdir -p "$stubbin"
cat > "$stubbin/curl" <<'STUBEOF'
#!/usr/bin/env bash
set -u
is_probe=0; is_head=0; has_L=0
for arg in "$@"; do
  case "$arg" in *http_code*) is_probe=1 ;; esac
  [ "$arg" = "-I" ] && is_head=1
  [ "$arg" = "-L" ] && has_L=1
done
out=""; url=""; prev=""
for arg in "$@"; do
  [ "$prev" = "-o" ] && out="$arg"
  case "$arg" in http://*|https://*|file://*) url="$arg" ;; esac
  prev="$arg"
done

# route <url> <table> — prints "<code> <location-or-empty>" for <url> from <table> (a
# "<url> <code> <location-or-dash>" newline-separated string), defaulting to "200 " (no
# redirect) when unmatched.
route(){
  local u="$1" table="$2" code="200" loc=""
  while IFS=' ' read -r r_url r_code r_loc; do
    [ -z "${r_url:-}" ] && continue
    if [ "$r_url" = "$u" ]; then
      code="$r_code"; [ "${r_loc:-}" = "-" ] && loc="" || loc="${r_loc:-}"
      break
    fi
  done <<<"$table"
  printf '%s %s' "$code" "$loc"
}
# head_routes_has <url> — true if $STUB_HEAD_ROUTES names <url> as its own row.
head_routes_has(){ printf '%s\n' "${STUB_HEAD_ROUTES:-}" | grep -qF "$1 "; }

if [ "$is_probe" -eq 1 ]; then
  if [ -n "${STUB_PROBE_FAIL_URL:-}" ] && [ "$url" = "$STUB_PROBE_FAIL_URL" ]; then
    echo "curl: (stub) simulated probe network failure" >&2
    # Defaults to a NON-connect-class exit code (round-5 N1'): exit 6 is now unambiguously
    # "connect-stage failure" (SENTINEL-CONNECT-SKIP), which would skip the GET-fallback probe
    # entirely and starve any plain-suite (non-teeth) assertion that expects the GET-fallback
    # path to actually run. $STUB_PROBE_FAIL_RC lets a test opt back into a connect-class code
    # (6/7/28) when THAT is specifically what it wants to exercise.
    exit "${STUB_PROBE_FAIL_RC:-22}"
  fi
  if [ "$is_head" -eq 0 ] && [ -n "${STUB_GET_FALLBACK_FAIL_URL:-}" ] && [ "$url" = "$STUB_GET_FALLBACK_FAIL_URL" ]; then
    echo "curl: (stub) simulated GET-fallback probe failure" >&2
    exit 6
  fi
  [ -n "${STUB_PROBE_COUNT_FILE:-}" ] && echo "$url" >> "$STUB_PROBE_COUNT_FILE"
  if [ "$is_head" -eq 1 ]; then
    if [ -n "${STUB_HEAD_CONNECT_FAIL_URL:-}" ] && [ "$url" = "$STUB_HEAD_CONNECT_FAIL_URL" ]; then
      echo "curl: (stub) simulated connect-stage failure" >&2
      exit "${STUB_HEAD_CONNECT_FAIL_RC:-7}"
    fi
    if [ -n "${STUB_HEAD_BLACKHOLE_URL:-}" ] && [ "$url" = "$STUB_HEAD_BLACKHOLE_URL" ]; then
      # curl exit 28 ("Operation timed out") with %{time_connect}=0 — the connect phase itself
      # never completed (round-5 N2'/N3': ambiguous rc, disambiguated by time_connect).
      # $STUB_HEAD_BLACKHOLE_TIME_CONNECT overrides the reported value (#1285 item 5: the bare
      # `0` and EMPTY spellings); `-` not `:-` so an explicitly EMPTY override stays empty.
      printf '000 %s ' "${STUB_HEAD_BLACKHOLE_TIME_CONNECT-0.000000}"
      exit 28
    fi
    if [ -n "${STUB_HEAD_HANG_URL:-}" ] && [ "$url" = "$STUB_HEAD_HANG_URL" ]; then
      # curl exit 28 with a NONZERO %{time_connect} — connected fine, then the RESPONSE hung
      # past --max-time. The host IS reachable; the GET-fallback retry is worth attempting.
      printf '000 %s ' "${STUB_HEAD_HANG_TIME_CONNECT:-1.234000}"
      exit 28
    fi
    if [ -n "${STUB_HEAD_FAIL_URL:-}" ] && [ "$url" = "$STUB_HEAD_FAIL_URL" ]; then
      printf '405 0.010000 '
      exit 0
    fi
    if head_routes_has "$url"; then
      r="$(route "$url" "${STUB_HEAD_ROUTES:-}")"
    else
      r="$(route "$url" "${STUB_ROUTES:-}")"
    fi
    printf '%s 0.020000 %s' "${r%% *}" "${r#* }"
    exit 0
  fi
  route "$url" "${STUB_ROUTES:-}"
  exit 0
fi

# DOWNLOAD call.
if [ "${STUB_DOWNLOAD_FAIL:-0}" = "1" ]; then
  echo "curl: (stub) simulated download transfer failure" >&2
  exit 7
fi
if [ "${STUB_DOWNLOAD_PARTIAL:-0}" = "1" ]; then
  # Mid-transfer failure (#1285): curl has already written PART of the body to -o when it dies.
  [ -n "$out" ] && printf 'PARTIAL-BODY' > "$out"
  echo "curl: (stub) simulated mid-transfer failure" >&2
  exit 18
fi
if [ "${STUB_DOWNLOAD_HANG:-0}" = "1" ]; then
  # Interruptible hang (#1285 item 2): partial bytes on disk, then block until signalled.
  [ -n "$out" ] && printf 'PARTIAL-BODY' > "$out"
  [ -n "${STUB_HANG_MARKER:-}" ] && : > "$STUB_HANG_MARKER"
  sleep 30 & wait $!
  exit 0
fi
if [ "${STUB_DOWNLOAD_EMPTY:-0}" = "1" ]; then
  [ -n "$out" ] && : > "$out"
  exit 0
fi
target="$url"
if [ "$has_L" -eq 1 ]; then
  # Follow the FULL chain (any 3xx with a Location — permanent OR temporary) to the final
  # target, mirroring real curl -L, which fetches content and is not the permanent-only
  # resolver (that is resolve_permanent_redirect's job, done separately, BEFORE this call).
  hops=0
  while [ "$hops" -lt 20 ]; do
    r="$(route "$target" "${STUB_ROUTES:-}")"; rcode="${r%% *}"; rloc="${r#* }"
    case "$rcode" in 3??) [ -n "$rloc" ] || break ;; *) break ;; esac
    target="$rloc"; hops=$((hops + 1))
  done
else
  # No -L: a single hop only. If $target itself is STILL a redirect per STUB_ROUTES, the "body"
  # is a distinct REDIRECT-page stub — never the real final content (mirrors real curl's
  # non-follow behavior: `-f` does not fail on 3xx, so it happily "succeeds" with the wrong body).
  r="$(route "$target" "${STUB_ROUTES:-}")"; rcode="${r%% *}"
  case "$rcode" in
    3??) [ -n "$out" ] && printf 'stub REDIRECT body (no -L) for %s\n' "$target" >"$out"; exit 0 ;;
  esac
fi
[ -n "$out" ] && printf 'stub body for %s\n' "$target" >"$out"
exit 0
STUBEOF
chmod +x "$stubbin/curl"
cat > "$stubbin/wget" <<'STUBEOF'
#!/usr/bin/env bash
out=""; prev=""
for arg in "$@"; do [ "$prev" = "-O" ] && out="$arg"; prev="$arg"; done
if [ "${STUB_WGET_FAIL:-0}" = "1" ]; then
  # Real `wget -O` CREATES/TRUNCATES its target file even when the request fails (round-5 R1) —
  # mirror that here so a test relying only on the stub cannot miss a caller that forgets to
  # clean up $dest on wget failure.
  [ -n "$out" ] && : > "$out"
  echo "wget: (stub) simulated wget failure" >&2
  exit 4
fi
[ -n "$out" ] && printf 'stub wget body\n' >"$out"
exit 0
STUBEOF
chmod +x "$stubbin/wget"

# runchain <mode> <dir> <typed-url> [extra doc args...] — invoke the SUT with the stub curl/wget
# on PATH and the current $STUB_* controls exported.
runchain(){ local mode="$1" dir="$2" url="$3"; shift 3
  PATH="$stubbin:$PATH" bash "$SUT" "$mode" "$url" "$dir" "$@" >/dev/null 2>"$TMP/runchain.err"
}
# origin_of <sources-md> <needle> — the Origin (URL) cell of the row whose File cell matches <needle>.
origin_of(){ awk -F' \\| ' -v n="$2" '$0 ~ n {gsub(/^\| */,"",$1); print $3; exit}' "$1" 2>/dev/null; }
# runresolve <script> <url> — call resolve_permanent_redirect() from <script> DIRECTLY (source,
# guarded main never runs — same technique as runreg()), with the stub curl on PATH and the
# current $STUB_* controls exported. Tests the pure resolution logic in isolation from the
# download/wget-fallback layer, which would otherwise MASK a broken guard (an internal empty-URL
# bug gets silently recovered by the wget fallback at the pipeline level — see case 17 below) and
# so cannot prove the guard itself is load-bearing. Wrapped in `timeout` (round-3 RS3): a genuine
# redirect LOOP or a broken hop-bound must not hang the test suite — the timeout, not a passing
# assertion, is what catches those mutants (see runresolve_bounded below for the ones that need
# the actual exit code).
# shellcheck source=../fetch-doc.sh
runresolve(){ local s="$1" url="$2"
  ( set +e; PATH="$stubbin:$PATH"; export PATH
    timeout 8 bash -c 'set -e; source "$1" >/dev/null 2>&1; resolve_permanent_redirect "$2"' _ "$s" "$url" 2>/dev/null )
}
# runresolve_err <script> <url> <errfile> — like runresolve, but PRESERVES resolve's own stderr
# into <errfile> (truncated first) instead of discarding it, for tests asserting NOTICE content.
runresolve_err(){ local s="$1" url="$2" errfile="$3" _out
  : > "$errfile"
  _out="$( ( set +e; PATH="$stubbin:$PATH"; export PATH
    timeout 8 bash -c 'set -e; source "$1" >/dev/null 2>&1; resolve_permanent_redirect "$2"' _ "$s" "$url" ) 2>"$errfile" )"
  printf '%s' "$_out"
}
# runresolve_bounded <script> <url> <out-var> <rc-var> — like runresolve_err, but ALSO captures
# the exit code into <rc-var> (round-3 RS3: a `while true` or dropped-increment mutant makes the
# resolve genuinely never return on a redirect LOOP fixture — `timeout`'s kill, exit 124, is the
# signal that the hop bound stopped protecting us; the real SUT must return 0 well inside the cap).
runresolve_bounded(){ local s="$1" url="$2" _outvar="$3" _rcvar="$4" _out _rc errfile="$TMP/bounded.err"
  : > "$errfile"
  _out="$( ( set +e; PATH="$stubbin:$PATH"; export PATH
    timeout 8 bash -c 'set -e; source "$1" >/dev/null 2>&1; resolve_permanent_redirect "$2"' _ "$s" "$url" ) 2>"$errfile" )"
  _rc=$?
  printf -v "$_outvar" '%s' "$_out"
  printf -v "$_rcvar" '%s' "$_rc"
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

# 16 — S1a: the PROBE request itself fails outright (simulated network error, BOTH the HEAD
#      probe and its GET fallback) — must not crash; resolves to the ORIGINAL typed URL (the
#      last known-good URL before the failed hop) and names it in a stderr notice (round-3 RS5).
STUB_ROUTES=""; STUB_PROBE_FAIL_URL="http://s16.example/a"
export STUB_ROUTES STUB_PROBE_FAIL_URL
got16="$(runresolve_err "$SUT" "http://s16.example/a" "$TMP/r16.err")"
unset STUB_PROBE_FAIL_URL
if [ "$got16" = "http://s16.example/a" ] && grep -qi 'redirect probe failed' "$TMP/r16.err"; then
  ok "resolve: S1a — a failed redirect PROBE falls back to the typed URL, no crash, with a notice"
else no "R16: expected http://s16.example/a + probe-fail notice, got '$got16' err='$(cat "$TMP/r16.err")'"; fi

# 17 — S1b (§7 silent-zero) — CORE: a 301 response with NO Location header (malformed) must not
#      advance to an empty URL. Tested at the FUNCTION level, not the pipeline: the pipeline's own
#      wget-fallback safety net (S2) would silently recover an internal empty-URL bug by falling
#      back to $URL anyway, masking whether THIS guard specifically is load-bearing.
#      N1 (plain-suite pin): the LOC-GUARD itself is SILENT on this case (no stderr notice at
#      all) — the SCHEME-GUARD right below it would ALSO refuse an empty Location (it does not
#      match http://*|https://*), but WITH ITS OWN "refused non-http(s)" notice. Asserting that
#      notice is ABSENT here pins which guard actually fired, distinctly from --prove-teeth's
#      mutant-only distinction (round-3 N1, closed properly in round 4).
STUB_ROUTES='http://s17.example/a 301 -'
export STUB_ROUTES
got17="$(runresolve_err "$SUT" "http://s17.example/a" "$TMP/r17.err")"
if [ "$got17" = "http://s17.example/a" ] && [ -n "$got17" ] && ! grep -qi 'refused non-http' "$TMP/r17.err"; then
  ok "resolve: S1b — a 301 with no Location does not resolve to an empty URL (loc-guard is silent here, not the scheme guard)"
else no "R17: expected non-empty 'http://s17.example/a' + no scheme-refusal notice, got '$got17' err='$(cat "$TMP/r17.err")'"; fi

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

# 20b — N4: the SAME shared download call (fetch_and_register, round-3 dedup) protects web mode
#       too — a single fix now covers both, so this is one more invocation of the same guard.
d20b="$TMP/rr-20b/target"; mkdir -p "$d20b"
STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1
export STUB_ROUTES STUB_DOWNLOAD_FAIL
runchain web "$d20b" "http://s20b.example/a"
unset STUB_DOWNLOAD_FAIL
if grep -q 'simulated download transfer failure' "$TMP/runchain.err"; then
  ok "web: S3 — the same shared download call preserves curl's diagnostic in web mode too"
else no "R20b: curl's own failure diagnostic missing from stderr (web) :: $(cat "$TMP/runchain.err")"; fi

# 21 — CORE (round-3 RR1): full pipeline, DOC mode — registers the PERMANENT-resolved URL for a
#      real redirect chain, not the typed one. Round-2 had NO pipeline-level test of this: only
#      function-level tests (11-14, 16, 17, 19) and the wget-fallback path (18, which EXPECTS the
#      typed URL) exercised doc mode; a regression dropping doc's resolve call, or a `reg` call
#      hardcoded back to `$URL`, would both go undetected.
d21="$TMP/rr-21/target"; mkdir -p "$d21"
STUB_ROUTES='http://s21.example/a 301 http://s21.example/moved'
export STUB_ROUTES
runchain doc "$d21" "http://s21.example/a" datasheets "r21.html"
got21="$(origin_of "$d21/sources/SOURCES.md" 'r21\.html')"
if [ "$got21" = "http://s21.example/moved" ]; then
  ok "doc: RR1 — registers the PERMANENT-resolved URL (wiring), not the originally typed one"
else no "R21: expected http://s21.example/moved, got '$got21' (err: $(cat "$TMP/runchain.err"))"; fi

# 22 — RDD/RS4: the "registered X (permanent redirect from Y)" notice fires exactly once, and
#      only AFTER a successful download — reusing case 21's successful resolution. This is the
#      positive counterpart to case 18's wget-fallback notice; the two must never coexist for
#      the same run (round-3 N1: printing the resolve notice unconditionally BEFORE the download
#      outcome is known produces a contradictory second "registered ..." line when the download
#      then fails and wget takes over — fetch_and_register fixes this by moving the notice after
#      a CONFIRMED successful download).
if grep -qF 'fetch-doc: registered http://s21.example/moved (permanent redirect from http://s21.example/a)' "$TMP/runchain.err" \
   && [ "$(grep -c 'registered' "$TMP/runchain.err")" = "1" ]; then
  ok "doc: notice fires exactly once, after a successful download, naming both URLs"
else no "R22: notice missing or duplicated :: $(cat "$TMP/runchain.err")"; fi

# 23 — RS4: 308 (permanent, like 301) resolves the SAME way a 301 chain does — the
#      SENTINEL-PERMANENT-ONLY case pattern must include BOTH, not just 301.
STUB_ROUTES='http://s23.example/a 308 http://s23.example/moved'
export STUB_ROUTES
got23="$(runresolve "$SUT" "http://s23.example/a")"
if [ "$got23" = "http://s23.example/moved" ]; then
  ok "resolve: 308 (permanent) redirect resolves the same as 301"
else no "R23: expected http://s23.example/moved, got '$got23'"; fi

# 24 — RS4: 303 (temporary, like 302) stops resolution — registers the typed URL, never the
#      redirect target.
STUB_ROUTES='http://s24.example/a 303 http://cdn.example/signed-303'
export STUB_ROUTES
got24="$(runresolve "$SUT" "http://s24.example/a")"
if [ "$got24" = "http://s24.example/a" ]; then
  ok "resolve: 303 (temporary) redirect stops resolution, like 302"
else no "R24: expected http://s24.example/a, got '$got24'"; fi

# 25 — RS4: 307 (temporary, like 302) stops resolution too.
STUB_ROUTES='http://s25.example/a 307 http://cdn.example/signed-307'
export STUB_ROUTES
got25="$(runresolve "$SUT" "http://s25.example/a")"
if [ "$got25" = "http://s25.example/a" ]; then
  ok "resolve: 307 (temporary) redirect stops resolution, like 302"
else no "R25: expected http://s25.example/a, got '$got25'"; fi

# 26 — CORE (round-3 security hardening): a permanent-redirect response whose Location has a
#      NON-http(s) scheme (file:, javascript:, data:, ...) is REFUSED outright — never followed,
#      regardless of the 301/308 code. Only http/https Location targets ever advance the chain.
STUB_ROUTES='http://s26.example/a 301 file:///etc/passwd'
export STUB_ROUTES
got26="$(runresolve_err "$SUT" "http://s26.example/a" "$TMP/r26.err")"
if [ "$got26" = "http://s26.example/a" ] && grep -qi 'refused non-http' "$TMP/r26.err"; then
  ok "resolve: security — a non-http(s) redirect scheme is refused, keeping the last good URL"
else no "R26: expected http://s26.example/a + refusal notice, got '$got26' err='$(cat "$TMP/r26.err")'"; fi

# 26b — the same guard AFTER at least one legitimate permanent hop: resolves to the LAST
#       PERMANENT (already-resolved) URL, not the typed one and not the refused target — proving
#       "last good" is not always merely "the original".
STUB_ROUTES=$'http://s26b.example/a 301 http://s26b.example/mid\nhttp://s26b.example/mid 301 javascript:alert(1)'
export STUB_ROUTES
got26b="$(runresolve_err "$SUT" "http://s26b.example/a" "$TMP/r26b.err")"
if [ "$got26b" = "http://s26b.example/mid" ] && grep -qi 'refused non-http' "$TMP/r26b.err"; then
  ok "resolve: security — scheme refusal after a real hop keeps the last PERMANENT url, not the typed one"
else no "R26b: expected http://s26b.example/mid + refusal notice, got '$got26b' err='$(cat "$TMP/r26b.err")'"; fi

# 27 — RS1: a server that answers HEAD with 405 (Method Not Allowed) is NOT treated as a dead
#      end — the probe retries with a GET (capped to a 0-byte range) and still resolves correctly.
STUB_ROUTES='http://s27.example/a 301 http://s27.example/moved'; STUB_HEAD_FAIL_URL='http://s27.example/a'
export STUB_ROUTES STUB_HEAD_FAIL_URL
got27="$(runresolve "$SUT" "http://s27.example/a")"
unset STUB_HEAD_FAIL_URL
if [ "$got27" = "http://s27.example/moved" ]; then
  ok "resolve: RS1 — a HEAD-405 response falls back to a GET probe and still resolves correctly"
else no "R27: expected http://s27.example/moved, got '$got27'"; fi

# 28 — CORE (round-3 RS3): a genuine redirect LOOP (A permanently redirects to B, B permanently
#      redirects back to A) must TERMINATE — the hop cap is the ONLY thing that stops it, since
#      no other break condition (temporary redirect, bad scheme, missing Location, probe failure)
#      is ever reached. Must complete well inside the `timeout` wrapper, return a non-empty URL,
#      and name the hop cap on stderr.
STUB_ROUTES=$'http://loop.example/a 301 http://loop.example/b\nhttp://loop.example/b 301 http://loop.example/a'
export STUB_ROUTES
runresolve_bounded "$SUT" "http://loop.example/a" got28 rc28
# shellcheck disable=SC2154  # got28/rc28 are assigned indirectly via printf -v inside runresolve_bounded
if [ "$rc28" = "0" ] && [ -n "$got28" ] && grep -qi 'hop cap' "$TMP/bounded.err"; then
  ok "resolve: RS3 — a genuine redirect loop terminates via the hop cap, not by hanging"
else no "R28: expected rc=0 + non-empty + hop-cap notice, got rc=$rc28 out='$got28' err='$(cat "$TMP/bounded.err")'"; fi

# 29 — CORE (round-3 RS2): '-L' on the download is load-bearing. A 301 (permanent) THEN a 302
#      (temporary, to the real content) — SOURCES.md registers the PERMANENT stop, but the
#      DOWNLOADED FILE's body must be the FINAL (post-302) content: '-L' still follows the
#      temporary hop to fetch the actual bytes, even though resolution stopped short of it.
d29="$TMP/rr-29/target"; mkdir -p "$d29"
STUB_ROUTES=$'http://s29.example/a 301 http://s29.example/permanent\nhttp://s29.example/permanent 302 http://s29.example/final-content'
export STUB_ROUTES
runchain doc "$d29" "http://s29.example/a" datasheets "r29.html"
if grep -qF 'stub body for http://s29.example/final-content' "$d29/sources/datasheets/r29.html" 2>/dev/null; then
  ok "doc: RS2 — -L follows the temporary hop to fetch the FINAL content, not the redirect page"
else no "R29: downloaded body is not the final content :: $(cat "$d29/sources/datasheets/r29.html" 2>/dev/null || echo MISSING)"; fi

# 30 — nit (round-1 N2 / round-3): a literal '|' in a Location header must be percent-encoded
#      (%7C) BEFORE it becomes part of the resolved/registered URL — a raw '|' would shift the
#      SOURCES.md row's column count.
STUB_ROUTES='http://s30.example/a 301 http://s30.example/a|b'
export STUB_ROUTES
got30="$(runresolve "$SUT" "http://s30.example/a")"
if [ "$got30" = "http://s30.example/a%7Cb" ]; then
  ok "resolve: nit — a literal | in the Location is percent-encoded (%7C) before resolving"
else no "R30: expected http://s30.example/a%7Cb, got '$got30'"; fi

# 31 — RS5: a probe failure AT HOP >= 2 (after at least one successful permanent hop) keeps the
#      LAST PERMANENT url, never reverting to the originally typed one — matches the updated
#      METHODOLOGY §5 wording exactly (round-3 doctrine fix).
STUB_ROUTES='http://s31.example/a 301 http://s31.example/mid'; STUB_PROBE_FAIL_URL='http://s31.example/mid'
export STUB_ROUTES STUB_PROBE_FAIL_URL
got31="$(runresolve_err "$SUT" "http://s31.example/a" "$TMP/r31.err")"
unset STUB_PROBE_FAIL_URL
if [ "$got31" = "http://s31.example/mid" ] && grep -qi 'redirect probe failed' "$TMP/r31.err"; then
  ok "resolve: RS5 — a probe failure after a real hop keeps the last PERMANENT url + notice"
else no "R31: expected http://s31.example/mid + probe-fail notice, got '$got31' err='$(cat "$TMP/r31.err")'"; fi
unset STUB_ROUTES

# 32 — N2: HEAD answers 403 (not a redirect, not 2xx) — falls back to GET, which correctly
#      reports the real 301 redirect target (some CDN/S3 fronts answer HEAD differently than GET).
STUB_HEAD_ROUTES='http://s32.example/a 403 -'
STUB_ROUTES='http://s32.example/a 301 http://s32.example/moved'
export STUB_HEAD_ROUTES STUB_ROUTES
got32="$(runresolve "$SUT" "http://s32.example/a")"
unset STUB_HEAD_ROUTES
if [ "$got32" = "http://s32.example/moved" ]; then
  ok "resolve: N2 — HEAD-403 falls back to GET, which reports the real redirect"
else no "R32: expected http://s32.example/moved, got '$got32'"; fi

# 33 — N2: same divergence with HEAD-404.
STUB_HEAD_ROUTES='http://s33.example/a 404 -'
STUB_ROUTES='http://s33.example/a 301 http://s33.example/moved'
export STUB_HEAD_ROUTES STUB_ROUTES
got33="$(runresolve "$SUT" "http://s33.example/a")"
unset STUB_HEAD_ROUTES
if [ "$got33" = "http://s33.example/moved" ]; then
  ok "resolve: N2 — HEAD-404 falls back to GET, which reports the real redirect"
else no "R33: expected http://s33.example/moved, got '$got33'"; fi

# 34 — CORE (round-4 N3): a CONNECT-stage HEAD failure (curl exit 7 — could not connect) is NOT
#      retried via GET — costs exactly ONE probe attempt for this hop, not two, since retrying an
#      unreachable host would just double the wait for nothing.
STUB_ROUTES=""; STUB_HEAD_CONNECT_FAIL_URL='http://s34.example/a'
_pcf34="$TMP/probe-count-34.txt"; : > "$_pcf34"
STUB_PROBE_COUNT_FILE="$_pcf34"
export STUB_ROUTES STUB_HEAD_CONNECT_FAIL_URL STUB_PROBE_COUNT_FILE
got34="$(runresolve "$SUT" "http://s34.example/a")"
unset STUB_HEAD_CONNECT_FAIL_URL STUB_PROBE_COUNT_FILE
n34="$(grep -c '^http://s34\.example/a$' "$_pcf34")"
if [ "$got34" = "http://s34.example/a" ] && [ "$n34" = "1" ]; then
  ok "resolve: N3 — a connect-stage HEAD failure skips the GET-fallback retry (1 probe attempt)"
else no "R34: expected typed URL + 1 probe attempt, got '$got34' attempts=$n34"; fi

# 35 — N3 contrast: an ordinary fallback-triggering HEAD answer (405, NOT a connect failure) DOES
#      retry via GET — 2 probe attempts FOR THIS SPECIFIC HOP (HEAD + GET-fallback), confirming
#      34's "1" is a real distinction and not an artifact of the counting mechanism. Counted per-
#      URL rather than as a chain total, since the chain legitimately probes the NEXT hop too
#      once this one resolves (a separate, expected attempt against a different URL).
STUB_ROUTES='http://s35.example/a 301 http://s35.example/moved'; STUB_HEAD_FAIL_URL='http://s35.example/a'
_pcf35="$TMP/probe-count-35.txt"; : > "$_pcf35"
STUB_PROBE_COUNT_FILE="$_pcf35"
export STUB_ROUTES STUB_HEAD_FAIL_URL STUB_PROBE_COUNT_FILE
got35="$(runresolve "$SUT" "http://s35.example/a")"
unset STUB_HEAD_FAIL_URL STUB_PROBE_COUNT_FILE
n35="$(grep -c '^http://s35\.example/a$' "$_pcf35")"
if [ "$got35" = "http://s35.example/moved" ] && [ "$n35" = "2" ]; then
  ok "resolve: N3 contrast — a 405 HEAD DOES retry via GET (2 probe attempts)"
else no "R35: expected resolved URL + 2 probe attempts, got '$got35' attempts=$n35"; fi

# 36 — CORE (round-4 N4): a successful permanent-redirect resolve followed by an EMPTY download
#      body must NOT print the "registered X (permanent redirect from Y)" notice — the empty-
#      body rejection happens right after fetch_and_register returns, so printing the notice
#      first would misleadingly claim a registration that never actually happens (the same false-
#      success shape round-2 N1 fixed on the wget-fallback path, reappearing on the success path).
d36="$TMP/rr-36/target"; mkdir -p "$d36"
STUB_ROUTES='http://s36.example/a 301 http://s36.example/moved'; STUB_DOWNLOAD_EMPTY=1
export STUB_ROUTES STUB_DOWNLOAD_EMPTY
_rc36=0
runchain doc "$d36" "http://s36.example/a" datasheets "r36.html" || _rc36=$?
unset STUB_DOWNLOAD_EMPTY
_row36=false
[ -f "$d36/sources/SOURCES.md" ] && grep -q 'r36\.html' "$d36/sources/SOURCES.md" && _row36=true
if [ "$_rc36" -ne 0 ] && ! $_row36 && ! grep -qi 'permanent redirect from' "$TMP/runchain.err"; then
  ok "doc: N4 — empty body after a successful resolve prints NO premature 'registered' notice"
else no "R36: rc=$_rc36 row=$_row36 err='$(cat "$TMP/runchain.err")'"; fi

# 37 — CORE (round-4 RDD, round-5 R1): the primary download fails AND wget ALSO fails —
#      NOTHING is registered, a typed failure notice is printed, the run exits non-zero, and NO
#      debris is left behind: real `wget -O` creates/truncates its target even on failure, and
#      the caller's own empty-body cleanup never runs on this exit path (R1) — so the destination
#      file itself must be gone, not merely absent from SOURCES.md.
d37="$TMP/rr-37/target"; mkdir -p "$d37"
STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; STUB_WGET_FAIL=1
export STUB_ROUTES STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
_rc37=0
runchain doc "$d37" "http://s37.example/a" datasheets "r37.html" || _rc37=$?
unset STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
_row37=false
[ -f "$d37/sources/SOURCES.md" ] && grep -q 'r37\.html' "$d37/sources/SOURCES.md" && _row37=true
if [ "$_rc37" -ne 0 ] && ! $_row37 \
   && [ -z "$(find "$d37/sources/datasheets" -type f)" ] \
   && grep -qi 'wget fallback ALSO failed' "$TMP/runchain.err" \
   && ! grep -qi 'registered requested URL' "$TMP/runchain.err"; then
  ok "doc: RDD/R1 — wget ALSO failing registers nothing and leaves NO file behind"
else no "R37: rc=$_rc37 row=$_row37 file-exists=$([ -e "$d37/sources/datasheets/r37.html" ] && echo yes || echo no) err='$(cat "$TMP/runchain.err")'"; fi

# 37b — RDD/R1 (web): same contract in web mode — $dest there is fetch_and_register's mktemp
#      HTML file, whose name is not known outside the process, so this scopes $TMPDIR to a
#      fresh, otherwise-empty directory and asserts it is EMPTY afterward (no leaked temp file).
d37b="$TMP/rr-37b/target"; mkdir -p "$d37b"
d37b_tmpdir="$TMP/rr-37b-tmpdir"; mkdir -p "$d37b_tmpdir"
STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; STUB_WGET_FAIL=1
export STUB_ROUTES STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
_rc37b=0
TMPDIR="$d37b_tmpdir" runchain web "$d37b" "http://s37b.example/a" || _rc37b=$?
unset STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
slug37b="$(echo "http://s37b.example/a" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g' | cut -c1-80)"
_row37b=false
[ -f "$d37b/sources/SOURCES.md" ] && grep -q "$slug37b" "$d37b/sources/SOURCES.md" && _row37b=true
_leaked37b="$(find "$d37b_tmpdir" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$_rc37b" -ne 0 ] && ! $_row37b && [ "$_leaked37b" = "0" ] \
   && grep -qi 'wget fallback ALSO failed' "$TMP/runchain.err" \
   && ! grep -qi 'registered requested URL' "$TMP/runchain.err"; then
  ok "web: RDD/R1 — wget ALSO failing registers nothing and leaks NO temp HTML file"
else no "R37b: rc=$_rc37b row=$_row37b leaked=$_leaked37b err='$(cat "$TMP/runchain.err")'"; fi
unset STUB_ROUTES

# 39 — CORE (round-5 N2'/N3'): curl exit 28 with %{time_connect}=0 (the connect phase never
#      completed — a "blackhole"/unreachable host) is STILL treated as connect-class: no
#      GET-fallback retry, exactly like exit 6/7.
STUB_ROUTES=""; STUB_HEAD_BLACKHOLE_URL='http://s39.example/a'
_pcf39="$TMP/probe-count-39.txt"; : > "$_pcf39"
STUB_PROBE_COUNT_FILE="$_pcf39"
export STUB_ROUTES STUB_HEAD_BLACKHOLE_URL STUB_PROBE_COUNT_FILE
got39="$(runresolve "$SUT" "http://s39.example/a")"
unset STUB_HEAD_BLACKHOLE_URL STUB_PROBE_COUNT_FILE
n39="$(grep -c '^http://s39\.example/a$' "$_pcf39")"
if [ "$got39" = "http://s39.example/a" ] && [ "$n39" = "1" ]; then
  ok "resolve: N2'/N3' — exit 28 with time_connect=0 (blackhole) still skips the GET-fallback retry"
else no "R39: expected typed URL + 1 probe attempt, got '$got39' attempts=$n39"; fi

# 40 — CORE (round-5 N2'/N3'): curl exit 28 with a NONZERO %{time_connect} (connected, then the
#      RESPONSE hung past --max-time) is NOT treated as connect-class — the host IS reachable,
#      so the GET-fallback retry IS attempted, and correctly resolves the real redirect.
STUB_ROUTES='http://s40.example/a 301 http://s40.example/moved'; STUB_HEAD_HANG_URL='http://s40.example/a'
_pcf40="$TMP/probe-count-40.txt"; : > "$_pcf40"
STUB_PROBE_COUNT_FILE="$_pcf40"
export STUB_ROUTES STUB_HEAD_HANG_URL STUB_PROBE_COUNT_FILE
got40="$(runresolve "$SUT" "http://s40.example/a")"
unset STUB_HEAD_HANG_URL STUB_PROBE_COUNT_FILE
n40="$(grep -c '^http://s40\.example/a$' "$_pcf40")"
if [ "$got40" = "http://s40.example/moved" ] && [ "$n40" = "2" ]; then
  ok "resolve: N2'/N3' — exit 28 with a nonzero time_connect (hung, not blackhole) DOES retry via GET"
else no "R40: expected http://s40.example/moved + 2 probe attempts, got '$got40' attempts=$n40"; fi
unset STUB_ROUTES

# 40b/40c — #1285 item 5: the OTHER spellings of "the connect phase never completed" — a bare `0`
#      and an EMPTY time_connect — must also skip the GET-fallback retry (exactly 1 probe attempt).
for _tc in "0" ""; do
  _lbl="${_tc:-empty}"
  STUB_ROUTES=""; STUB_HEAD_BLACKHOLE_URL="http://s40-$_lbl.example/a"; STUB_HEAD_BLACKHOLE_TIME_CONNECT="$_tc"
  _pcf40x="$TMP/probe-count-40-$_lbl.txt"; : > "$_pcf40x"; STUB_PROBE_COUNT_FILE="$_pcf40x"
  export STUB_ROUTES STUB_HEAD_BLACKHOLE_URL STUB_HEAD_BLACKHOLE_TIME_CONNECT STUB_PROBE_COUNT_FILE
  got40x="$(runresolve "$SUT" "http://s40-$_lbl.example/a")"
  unset STUB_HEAD_BLACKHOLE_URL STUB_HEAD_BLACKHOLE_TIME_CONNECT STUB_PROBE_COUNT_FILE
  n40x="$(grep -c "^http://s40-$_lbl\.example/a\$" "$_pcf40x")"
  if [ "$got40x" = "http://s40-$_lbl.example/a" ] && [ "$n40x" = "1" ]; then
    ok "resolve: #1285 — exit 28 with time_connect='${_tc}' ($_lbl) skips the GET-fallback retry"
  else no "R40x[$_lbl]: expected typed URL + 1 probe attempt, got '$got40x' attempts=$n40x"; fi
done
unset STUB_ROUTES

# ─── #1285 item 1: a failed re-fetch must leave an already-registered file byte-identical ───
# mkexisting <dir> <name> — seed sources/datasheets/<name> with known evidence; echo its path.
mkexisting(){ mkdir -p "$1/sources/datasheets"; printf 'REGISTERED-EVIDENCE\n' > "$1/sources/datasheets/$2"; printf '%s' "$1/sources/datasheets/$2"; }
EVID_SUM="$(printf 'REGISTERED-EVIDENCE\n' | sha256sum | cut -d' ' -f1)"
sum_of(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 41 — curl AND wget both fail outright on a re-fetch: the existing file survives, byte-identical.
d41="$TMP/rr-41/target"; f41="$(mkexisting "$d41" r41.pdf)"
STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; STUB_WGET_FAIL=1; export STUB_ROUTES STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
_rc41=0; runchain doc "$d41" "http://s41.example/a" datasheets "r41.pdf" || _rc41=$?
unset STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
if [ "$_rc41" -ne 0 ] && [ "$(sum_of "$f41")" = "$EVID_SUM" ]; then
  ok "doc: #1285 — re-fetch with curl AND wget failing leaves the registered file byte-identical"
else no "R41: rc=$_rc41 sum=$(sum_of "$f41") exists=$([ -e "$f41" ] && echo yes || echo no)"; fi

# 42 — curl dies MID-TRANSFER (partial bytes written) and wget fails: still byte-identical, no debris.
d42="$TMP/rr-42/target"; f42="$(mkexisting "$d42" r42.pdf)"
STUB_ROUTES=""; STUB_DOWNLOAD_PARTIAL=1; STUB_WGET_FAIL=1; export STUB_ROUTES STUB_DOWNLOAD_PARTIAL STUB_WGET_FAIL
_rc42=0; runchain doc "$d42" "http://s42.example/a" datasheets "r42.pdf" || _rc42=$?
unset STUB_DOWNLOAD_PARTIAL STUB_WGET_FAIL
_debris42="$(find "$d42/sources/datasheets" -type f ! -name r42.pdf | wc -l | tr -d ' ')"
if [ "$_rc42" -ne 0 ] && [ "$(sum_of "$f42")" = "$EVID_SUM" ] && [ "$_debris42" = "0" ]; then
  ok "doc: #1285 — a partial curl transfer never overwrites the registered file; no part-file debris"
else no "R42: rc=$_rc42 sum=$(sum_of "$f42") debris=$_debris42"; fi

# 43 — a 200 with an EMPTY body on a re-fetch must not delete or truncate the registered file.
d43="$TMP/rr-43/target"; f43="$(mkexisting "$d43" r43.pdf)"
STUB_ROUTES=""; STUB_DOWNLOAD_EMPTY=1; export STUB_ROUTES STUB_DOWNLOAD_EMPTY
_rc43=0; runchain doc "$d43" "http://s43.example/a" datasheets "r43.pdf" || _rc43=$?
unset STUB_DOWNLOAD_EMPTY
if [ "$_rc43" -ne 0 ] && [ "$(sum_of "$f43")" = "$EVID_SUM" ] && grep -qi 'empty body' "$TMP/runchain.err"; then
  ok "doc: #1285 — an empty-body re-fetch fails loudly and leaves the registered file intact"
else no "R43: rc=$_rc43 sum=$(sum_of "$f43") err='$(cat "$TMP/runchain.err")'"; fi

# 44 — positive control: a SUCCESSFUL re-fetch replaces the file with the new bytes (the part-file
#      move actually happens) and leaves no part file behind.
d44="$TMP/rr-44/target"; f44="$(mkexisting "$d44" r44.pdf)"
STUB_ROUTES=""; export STUB_ROUTES
_rc44=0; runchain doc "$d44" "http://s44.example/a" datasheets "r44.pdf" || _rc44=$?
_debris44="$(find "$d44/sources/datasheets" -type f ! -name r44.pdf | wc -l | tr -d ' ')"
if [ "$_rc44" -eq 0 ] && grep -qF 'stub body for http://s44.example/a' "$f44" && [ "$_debris44" = "0" ]; then
  ok "doc: #1285 — a successful re-fetch replaces the file and leaves no part file"
else no "R44: rc=$_rc44 body='$(cat "$f44" 2>/dev/null)' debris=$_debris44"; fi
unset STUB_ROUTES

# 44b — fetch_and_register called DIRECTLY (no main dispatch, so no EXIT trap): when curl and wget
#      both fail it must clean up its OWN part file (in-function cleanup, independent of the trap).
d44b="$TMP/rr-44b"; mkdir -p "$d44b"
STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; STUB_WGET_FAIL=1; export STUB_ROUTES STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
# shellcheck source=../fetch-doc.sh
( set +e; PATH="$stubbin:$PATH"; export PATH; source "$SUT" >/dev/null 2>&1
  fetch_and_register "http://s44b.example/a" "$d44b/out.html" >/dev/null 2>&1 )
unset STUB_DOWNLOAD_FAIL STUB_WGET_FAIL STUB_ROUTES
if [ -z "$(find "$d44b" -type f)" ]; then
  ok "fetch_and_register: curl+wget failure leaves no part file even without the main-dispatch trap"
else no "R44b: debris: $(find "$d44b" -type f | tr '\n' ' ')"; fi

# ─── #1285 item 2: trap cleanup ───
# 45 — SIGTERM mid-download (doc): the partial bytes are removed and the registered file survives.
d45="$TMP/rr-45/target"; f45="$(mkexisting "$d45" r45.pdf)"
STUB_ROUTES=""; STUB_DOWNLOAD_HANG=1; STUB_HANG_MARKER="$TMP/hang45.marker"; rm -f "$STUB_HANG_MARKER"
export STUB_ROUTES STUB_DOWNLOAD_HANG STUB_HANG_MARKER
# setsid gives the run its own process GROUP, so the TERM below reaches the script AND its download
# subshell/curl exactly as a terminal's Ctrl-C does (killing only the script would leave bash
# deferring its trap until the 30 s stub returns, which proves nothing about the cleanup).
if ! command -v setsid >/dev/null 2>&1; then
  printf '  SKIP  R45: setsid not available (cannot signal a whole process group)\n'
else
PATH="$stubbin:$PATH" setsid bash "$SUT" doc "http://s45.example/a" "$d45" datasheets "r45.pdf" >/dev/null 2>&1 &
_pid45=$!
for _ in $(seq 1 100); do [ -e "$STUB_HANG_MARKER" ] && break; sleep 0.1; done
kill -TERM -- "-$_pid45" 2>/dev/null; wait "$_pid45" 2>/dev/null
unset STUB_DOWNLOAD_HANG STUB_HANG_MARKER
_debris45="$(find "$d45/sources/datasheets" -type f ! -name r45.pdf | wc -l | tr -d ' ')"
if [ -e "$TMP/hang45.marker" ] && [ "$_debris45" = "0" ] && [ "$(sum_of "$f45")" = "$EVID_SUM" ]; then
  ok "doc: #1285 — SIGTERM mid-download leaves no partial file and the registered file intact"
else no "R45: marker=$([ -e "$TMP/hang45.marker" ] && echo y || echo n) debris=$_debris45 sum=$(sum_of "$f45")"; fi
fi
unset STUB_ROUTES STUB_DOWNLOAD_HANG STUB_HANG_MARKER

# 46 — web: a failing post-download step (cp into an unwritable web-snapshots dir) must not leak the
#      mktemp HTML. (The HTML is rm'd right after the cp, so ONLY a failing cp/pandoc step leaks it.)
d46="$TMP/rr-46/target"; mkdir -p "$d46/sources/web-snapshots"; chmod 555 "$d46/sources/web-snapshots"
d46_tmpdir="$TMP/rr-46-tmpdir"; mkdir -p "$d46_tmpdir"
if { : > "$d46/sources/web-snapshots/.probe"; } 2>/dev/null; then
  printf '  SKIP  R46: cannot make the snapshot dir unwritable here (root?)\n'
else
  STUB_ROUTES=""; export STUB_ROUTES
  _rc46=0; TMPDIR="$d46_tmpdir" runchain web "$d46" "http://s46.example/a" || _rc46=$?
  _leak46="$(find "$d46_tmpdir" -mindepth 1 | wc -l | tr -d ' ')"
  if [ "$_rc46" -ne 0 ] && [ "$_leak46" = "0" ]; then
    ok "web: #1285 — a failing post-download step leaks NO mktemp HTML"
  else no "R46: rc=$_rc46 leaked=$_leak46 ($(ls "$d46_tmpdir" | tr '\n' ' '))"; fi
  unset STUB_ROUTES
fi
chmod 755 "$d46/sources/web-snapshots"

# ─── #1285 item 3: runtime-dependency probe ───
# 47 — neither curl nor wget on PATH: a typed DEGRADED error naming BOTH tools, exit 3, nothing
#      registered — not the misleading "wget fallback ALSO failed".
nodl="$TMP/nodl-bin"; mkdir -p "$nodl"
for _t in bash mkdir basename sed cut date awk mktemp mv rm sha256sum file grep cat dirname tr; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$nodl/$_t"
done
d47="$TMP/rr-47/target"; mkdir -p "$d47"
_rc47=0; PATH="$nodl" "$nodl/bash" "$SUT" doc "http://s47.example/a.pdf" "$d47" datasheets "r47.pdf" >/dev/null 2>"$TMP/err47.txt" || _rc47=$?
if [ "$_rc47" -eq 3 ] && grep -qi 'DEGRADED' "$TMP/err47.txt" && grep -q 'curl' "$TMP/err47.txt" \
   && grep -q 'wget' "$TMP/err47.txt" && ! grep -qi 'ALSO failed' "$TMP/err47.txt" \
   && [ ! -e "$d47/sources/SOURCES.md" ]; then
  ok "doc: #1285 — neither curl nor wget → typed DEGRADED error naming both tools, exit 3"
else no "R47: rc=$_rc47 err='$(cat "$TMP/err47.txt")'"; fi
d47w="$TMP/rr-47w/target"; mkdir -p "$d47w"
_rc47w=0; PATH="$nodl" "$nodl/bash" "$SUT" web "http://s47.example/a" "$d47w" >/dev/null 2>"$TMP/err47w.txt" || _rc47w=$?
if [ "$_rc47w" -eq 3 ] && grep -qi 'DEGRADED' "$TMP/err47w.txt"; then
  ok "web: #1285 — neither curl nor wget → typed DEGRADED error, exit 3"
else no "R47w: rc=$_rc47w err='$(cat "$TMP/err47w.txt")'"; fi

# ─── #1285 item 6: kit CLAUDE.md §9 — artifacts are English ───
if ! grep -q 'falló' "$SUT"; then
  ok "language: no Spanish 'falló' message left in fetch-doc.sh (§9)"
else no "R48: fetch-doc.sh still contains the Spanish pdftoppm message"; fi
if grep -q 'pdftoppm failed' "$SUT"; then
  ok "language: the pdftoppm failure message is English"
else no "R48b: English pdftoppm failure message not found"; fi

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

  # ── teeth for resolve_permanent_redirect() / fetch_and_register() (Tests 11-31) — every mutant
  # below is anchored on a SENTINEL comment (N4: a stable token, not a line number or exact-code
  # match), so a future reformat that keeps the sentinel keeps the mutant working, and a real
  # semantic edit that drops the sentinel fails loudly (the grep-guard) instead of silently
  # mutating the wrong thing. Nontrivial replacement text (embedded quotes, %s specifiers) is
  # written via a sed SCRIPT FILE (mkmut) rather than an inline sed one-liner, to avoid fragile
  # nested-quote escaping — round-3 fix for the round-2 "mislabelled SENTINEL-S3" nit, whose
  # anchor was actually the literal code text, not a sentinel at all.

  # mkmut <name> <sed-script-stdin> — writes a sed script to $TMP/<name>.sed and applies it to
  # $SUT, producing $TMP/<name>.sh. Echoes the mutant path on success.
  # CORE (round-4 Q2): validates the produced mutant with `bash -n` before handing it back. A
  # syntactically-broken mutant (e.g. a delete that leaves an empty if/then/fi body) crashes on
  # EVERY invocation — a test run against it then "passes" for every assertion simultaneously,
  # which is FABLE-maxim theater (kit CLAUDE.md §2/§4), not a genuine kill. On a syntax error,
  # mkmut prints the diagnostic to stderr and returns nothing (empty stdout), so the caller's own
  # "could not build mutant" check fires instead of silently scoring a broken mutant as a pass.
  mkmut(){ local script="$TMP/$1.sed" out="$TMP/$1.sh" synerr="$TMP/$1.syntax.err"
    cat > "$script"
    sed -f "$script" "$SUT" > "$out"
    if ! bash -n "$out" 2>"$synerr"; then
      printf 'mkmut: FATAL — mutant "%s" is not valid bash (bash -n): %s\n' "$1" "$(cat "$synerr")" >&2
      return 1
    fi
    # SENTINEL-MKMUT-GUARD (round-5 S1): an EMPTY mutant, or one byte-identical to the SUT (the sed
    # script matched nothing), cannot be a kill — refuse it so the caller's own "could not build
    # mutant" branch fires instead of scoring a no-op as a mutation control.
    if [ ! -s "$out" ]; then
      printf 'mkmut: FATAL — mutant "%s" is empty (sed script produced no output)\n' "$1" >&2
      return 1
    fi
    if cmp -s "$out" "$SUT"; then
      printf 'mkmut: FATAL — mutant "%s" is identical to the SUT (sed script matched nothing)\n' "$1" >&2
      return 1
    fi
    printf '%s' "$out"
  }

  # ── mkmut self-tests (round-5 S1) — the mutation helper itself must never hand back a mutant
  # that cannot be a kill: an EMPTY file (sed script that deletes everything) or one BYTE-IDENTICAL
  # to the SUT (sed script that matched nothing). Several callers guard with `grep -q <text that
  # also occurs in the original>`, so an identical/empty mutant sailed through that guard and was
  # scored as a kill — a mutation control that silently tests nothing (kit CLAUDE.md §4/§7).
  echo "-- mkmut self-test (round-5 S1): no-op sed script must be refused --"
  _noop_out="$(mkmut s1-noop <<'SED' 2>"$TMP/s1-noop.err"
s/THIS-TEXT-NEVER-OCCURS-IN-THE-SUT-9f3a/x/
SED
)" && _noop_rc=0 || _noop_rc=$?
  if [ "$_noop_rc" -ne 0 ] && [ -z "$_noop_out" ] && grep -qi 'identical' "$TMP/s1-noop.err"; then
    ok "mkmut S1: a sed script that changes nothing (mutant == original) is refused, not returned"
  else no "mkmut S1: no-op mutant not refused (rc=$_noop_rc out='$_noop_out' err='$(cat "$TMP/s1-noop.err")')"; fi

  echo "-- mkmut self-test (round-5 S1): empty-output sed script must be refused --"
  _empty_out="$(mkmut s1-empty <<'SED' 2>"$TMP/s1-empty.err"
d
SED
)" && _empty_rc=0 || _empty_rc=$?
  if [ "$_empty_rc" -ne 0 ] && [ -z "$_empty_out" ] && grep -qi 'empty' "$TMP/s1-empty.err"; then
    ok "mkmut S1: a sed script that produces an EMPTY mutant is refused, not returned"
  else no "mkmut S1: empty mutant not refused (rc=$_empty_rc out='$_empty_out' err='$(cat "$TMP/s1-empty.err")')"; fi

  echo "-- mkmut self-test (round-5 S1): a real, changing mutant is still returned --"
  _good_out="$(mkmut s1-good <<'SED' 2>"$TMP/s1-good.err"
1s/^/# MUTANT: s1-good first-line marker\n/
SED
)" && _good_rc=0 || _good_rc=$?
  if [ "$_good_rc" -eq 0 ] && [ -s "$_good_out" ] && ! cmp -s "$_good_out" "$SUT"; then
    ok "mkmut S1: a non-empty mutant that differs from the SUT is returned unchanged"
  else no "mkmut S1: good mutant rejected or mangled (rc=$_good_rc out='$_good_out' err='$(cat "$TMP/s1-good.err")')"; fi

  echo "-- teeth: SENTINEL-MKMUT-GUARD (round-5 S1) — strip the empty/identical guard from mkmut --"
  # Re-define mkmut from THIS file's own text with the guard line deleted, then prove the no-op
  # case would have been wrongly accepted — i.e. the three assertions above bite.
  _mk_src="$(sed -n '/^  mkmut(){/,/^  }$/p' "$0")"
  _mk_mut="$(printf '%s\n' "$_mk_src" | sed '/SENTINEL-MKMUT-GUARD/,/^    printf /{/^    printf /!d;}')"
  if [ -z "$_mk_src" ] || [ "$_mk_src" = "$_mk_mut" ]; then
    no "teeth-mkmut-guard: could not build mutant of mkmut (SENTINEL-MKMUT-GUARD block not found — did mkmut change?)"
  else
    _saved_mkmut="$(declare -f mkmut)"
    eval "$_mk_mut"
    _m_out="$(mkmut s1-teeth-noop <<'SED' 2>/dev/null
s/THIS-TEXT-NEVER-OCCURS-IN-THE-SUT-9f3a/x/
SED
)" || _m_out=""
    eval "$_saved_mkmut"
    if [ -n "$_m_out" ] && cmp -s "$_m_out" "$SUT"; then
      ok "teeth-mkmut-guard: guard-less mkmut returns an identical-to-SUT mutant → mkmut S1 assertions have teeth"
    else no "teeth-mkmut-guard: guard-less mkmut still refused the no-op mutant (out='$_m_out') — S1 does NOT depend on the guard (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-PERMANENT-ONLY — widen 301|308 to also treat 302/303/307 as permanent --"
  pmutant="$(mkmut permanent-only <<'SED'
/SENTINEL-PERMANENT-ONLY/,/301|308)/ s/301|308)/301|302|303|307|308)/
SED
)"
  if ! grep -q '301|302|303|307|308)' "$pmutant"; then
    no "teeth-permanent-only: could not build mutant (case pattern not found — did the SUT change?)"
  else
    STUB_ROUTES='http://s13.example/a 302 http://cdn.example/signed?sig=cafef00d'; export STUB_ROUTES
    got13m="$(runresolve "$pmutant" "http://s13.example/a")"
    if [ "$got13m" = "http://cdn.example/signed?sig=cafef00d" ]; then
      ok "teeth-permanent-only: mutant follows the temporary redirect into the signed URL → R12/R13 has teeth"
    else no "teeth-permanent-only: mutant still stopped at '$got13m' — R12/R13 does NOT depend on the 301|308 guard (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-PERMANENT-ONLY (RS4) — narrow 301|308 to drop 308 support --"
  narrow308mutant="$(mkmut narrow-308 <<'SED'
/SENTINEL-PERMANENT-ONLY/,/301|308)/ s/301|308)/301)/
SED
)"
  if ! grep -qE '^\s*301\)\s*$' "$narrow308mutant"; then
    no "teeth-narrow-308: could not build mutant (case pattern not found — did the SUT change?)"
  else
    STUB_ROUTES='http://s23.example/a 308 http://s23.example/moved'; export STUB_ROUTES
    got23m="$(runresolve "$narrow308mutant" "http://s23.example/a")"
    if [ "$got23m" = "http://s23.example/a" ]; then
      ok "teeth-narrow-308: mutant no longer treats 308 as permanent (stays at typed URL) → R23 has teeth"
    else no "teeth-narrow-308: mutant still resolved 308 to '$got23m' — R23 does NOT depend on 308 being listed (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-LOC-GUARD — remove the empty-Location guard --"
  # Note: with the loc-guard removed, an empty Location does NOT escape as a broken/empty URL —
  # the SCHEME-GUARD right below it also rejects an empty string (it does not match http://*|
  # https://*), so the RESOLVED VALUE stays the typed URL either way (defense in depth, by
  # design). The observable difference is which guard fired: the real code breaks SILENTLY on
  # an empty Location (no notice at all); the mutant falls through to the scheme guard, which
  # DOES print its own "refused non-http(s)" notice. That stderr signature is the flip signal.
  lmutant="$(mkmut loc-guard <<'SED'
/SENTINEL-LOC-GUARD/,/cur="$loc"/ s/\[ -n "\$loc" \] || break/: # MUTANT: loc-guard removed/
SED
)"
  if ! grep -q 'MUTANT: loc-guard removed' "$lmutant"; then
    no "teeth-loc-guard: could not build mutant (guard line not found — did the SUT change?)"
  else
    STUB_ROUTES='http://s17.example/a 301 -'; export STUB_ROUTES
    got17m="$(runresolve_err "$lmutant" "http://s17.example/a" "$TMP/teeth-loc-guard.err")"
    if [ "$got17m" = "http://s17.example/a" ] && grep -qi 'refused non-http' "$TMP/teeth-loc-guard.err"; then
      ok "teeth-loc-guard: mutant falls through to the scheme guard on empty Location (real code is silent here) → R17 has teeth"
    else no "teeth-loc-guard: mutant got='$got17m' err='$(cat "$TMP/teeth-loc-guard.err")' — R17 does NOT depend on the loc guard specifically (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-SCHEME-GUARD — accept a non-http(s) redirect scheme --"
  schememutant="$(mkmut scheme-guard <<'SED'
/SENTINEL-SCHEME-GUARD/,/http:\/\/\*|https:\/\/\*/ s#http://\*|https://\*) : ;;#*) : ;;#
SED
)"
  if ! grep -qE '^\s*\*\) : ;;$' "$schememutant"; then
    no "teeth-scheme-guard: could not build mutant (scheme case pattern not found — did the SUT change?)"
  else
    STUB_ROUTES='http://s26.example/a 301 file:///etc/passwd'; export STUB_ROUTES
    got26m="$(runresolve "$schememutant" "http://s26.example/a")"
    if [ "$got26m" = "file:///etc/passwd" ]; then
      ok "teeth-scheme-guard: mutant follows the non-http(s) Location into file:// → security check has teeth"
    else no "teeth-scheme-guard: mutant still refused, got '$got26m' — security check does NOT depend on the scheme guard (THEATER)"; fi
  fi

  echo "-- teeth: nit — remove the percent-encoding of a literal | in the Location --"
  # CORE (round-5 S1): the MUTANT-marker guard form (positive check for the inserted marker) is
  # used here rather than "is the ORIGINAL text still present?" — the inverted form scores an
  # EMPTY $mutant (mkmut's own bash -n rejection, or any other build failure) as "original text
  # absent" → "mutant built successfully", which is a silent false kill (kit CLAUDE.md §7).
  pipemutant="$(mkmut pipe-encode <<'SED'
s/loc="\${loc\/\/|\/%7C}"/:  # MUTANT: percent-encoding removed/
SED
)"
  if ! grep -q 'MUTANT: percent-encoding removed' "$pipemutant"; then
    no "teeth-pipe-encode: could not build mutant (encoding line not found, or bash -n rejected it — did the SUT change?)"
  else
    STUB_ROUTES='http://s30.example/a 301 http://s30.example/a|b'; export STUB_ROUTES
    got30m="$(runresolve "$pipemutant" "http://s30.example/a")"
    if [ "$got30m" = 'http://s30.example/a|b' ]; then
      ok "teeth-pipe-encode: mutant registers the raw un-encoded | → R30 has teeth"
    else no "teeth-pipe-encode: mutant produced '$got30m' — R30 does NOT depend on the encoding line (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-HEAD-GUARD — remove the HEAD probe's own && / || failure protection --"
  # The HEAD probe's crash-guard is `&& head_rc=0 || head_rc=$?` on the assignment itself
  # (round-5: rewritten from round-4's if/then/else so a PARTIAL curl output, e.g.
  # %{time_connect} on a mid-response timeout, is preserved rather than discarded). Stripping the
  # trailing `&& .../|| ...` leaves a BARE assignment, reproducing exactly the crash risk that
  # construct exists to prevent.
  headguardmutant="$(mkmut head-guard <<'SED'
s/" && head_rc=0 || head_rc=\$?$/"  # MUTANT: head-guard removed/
SED
)"
  if ! grep -q 'MUTANT: head-guard removed' "$headguardmutant"; then
    no "teeth-head-guard: could not build mutant (HEAD-probe guard line not found, or bash -n rejected it — did the SUT change?)"
  else
    STUB_ROUTES=""; STUB_PROBE_FAIL_URL="http://s16.example/a"; export STUB_ROUTES STUB_PROBE_FAIL_URL
    got16m="$(runresolve "$headguardmutant" "http://s16.example/a")"
    unset STUB_PROBE_FAIL_URL
    if [ "$got16m" != "http://s16.example/a" ]; then
      ok "teeth-head-guard: mutant does NOT gracefully fall back on a failed HEAD probe (set -e kills the resolve) → R16 has teeth"
    else no "teeth-head-guard: mutant still fell back to the typed URL — R16 does NOT depend on the HEAD probe's guard (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-PROBE-FALLBACK-GET — remove the GET-fallback probe's own failure guard --"
  # CORE (round-5 S1): MUTANT-marker form, not "is the original ' || probe=\"\"' still present?"
  # (see the pipe-encode comment above for why the inverted form is unsafe).
  getguardmutant="$(mkmut get-guard <<'SED'
/SENTINEL-PROBE-FALLBACK-GET/,+1 s/ || probe=""$/  # MUTANT: get-guard removed/
SED
)"
  if ! grep -q 'MUTANT: get-guard removed' "$getguardmutant"; then
    no "teeth-get-guard: could not build mutant (GET-fallback guard line not found, or bash -n rejected it — did the SUT change?)"
  else
    # HEAD returns 405 for this url (forcing the GET fallback), AND the GET-fallback probe for
    # the SAME url fails outright — the real SUT catches this via the mutated-away guard.
    STUB_ROUTES=""; STUB_HEAD_FAIL_URL="http://s16b.example/a"; STUB_GET_FALLBACK_FAIL_URL="http://s16b.example/a"
    export STUB_ROUTES STUB_HEAD_FAIL_URL STUB_GET_FALLBACK_FAIL_URL
    got16bm="$(runresolve "$getguardmutant" "http://s16b.example/a")"
    unset STUB_HEAD_FAIL_URL STUB_GET_FALLBACK_FAIL_URL
    if [ "$got16bm" != "http://s16b.example/a" ]; then
      ok "teeth-get-guard: mutant does NOT gracefully fall back when the GET-fallback probe ALSO fails → RS1 has teeth"
    else no "teeth-get-guard: mutant still fell back to the typed URL — RS1's GET-fallback guard does NOT bite (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-PROBE-METHOD (RS1/N2/N3) — remove the HEAD-fallback decision entirely --"
  # Replaces the outer `case "$code" in 301|302|...|2?? ) ... *) <fallback decision> ;; esac`
  # with a bare `*) : ;;` catch-all — HEAD's own code/redirect_url is used as-is, no matter what
  # it was, and the GET-fallback path (405/501/000/other-4xx-5xx, N2) is never reached. Anchored
  # on the UNIQUE "301|302|303|307|308|2??) : ;;" line so the range cannot re-match the LATER,
  # unrelated 301|308 permanent-only case a few lines down.
  nofallbackmutant="$(mkmut no-405-fallback <<'SED'
/301|302|303|307|308|2??) : ;;/,/^    esac$/c\
      *) : ;;  # MUTANT: 405/501/000/N2/N3 fallback entirely removed\
    esac
SED
)"
  if ! grep -q 'MUTANT: 405/501/000/N2/N3 fallback entirely removed' "$nofallbackmutant"; then
    no "teeth-no-405-fallback: could not build mutant (HEAD-fallback case block not found, or bash -n rejected it — did the SUT change?)"
  else
    STUB_ROUTES='http://s27.example/a 301 http://s27.example/moved'; STUB_HEAD_FAIL_URL='http://s27.example/a'
    export STUB_ROUTES STUB_HEAD_FAIL_URL
    got27m="$(runresolve "$nofallbackmutant" "http://s27.example/a")"
    unset STUB_HEAD_FAIL_URL
    if [ "$got27m" != "http://s27.example/moved" ]; then
      ok "teeth-no-405-fallback: mutant treats HEAD-405 as a dead end (no GET retry) → RS1/R27 has teeth"
    else no "teeth-no-405-fallback: mutant still resolved via GET fallback — RS1/R27 does NOT depend on the 405 branch (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-CONNECT-SKIP (round-4 N3) — always retry via GET, even on a connect-stage (6/7) failure --"
  connectskipmutant="$(mkmut connect-skip <<'SED'
s/6|7) skip_fallback=1 ;;/999) skip_fallback=1 ;;  # MUTANT: connect-skip removed/
SED
)"
  if ! grep -q 'MUTANT: connect-skip removed' "$connectskipmutant"; then
    no "teeth-connect-skip: could not build mutant (6|7 case arm not found, or bash -n rejected it — did the SUT change?)"
  else
    STUB_ROUTES=""; STUB_HEAD_CONNECT_FAIL_URL='http://s34.example/a'
    _pcf34m="$TMP/probe-count-34m.txt"; : > "$_pcf34m"
    STUB_PROBE_COUNT_FILE="$_pcf34m"
    export STUB_ROUTES STUB_HEAD_CONNECT_FAIL_URL STUB_PROBE_COUNT_FILE
    runresolve "$connectskipmutant" "http://s34.example/a" >/dev/null  # only the attempt count matters here
    unset STUB_HEAD_CONNECT_FAIL_URL STUB_PROBE_COUNT_FILE
    n34cs="$(grep -c '^http://s34\.example/a$' "$_pcf34m")"
    if [ "$n34cs" -gt "1" ]; then
      ok "teeth-connect-skip: mutant retries via GET even on a connect failure ($n34cs attempts, not 1) → N3/R34 has teeth"
    else no "teeth-connect-skip: mutant still made only 1 attempt — N3/R34 does NOT depend on the connect-skip check (THEATER)"; fi
  fi

  echo "-- teeth: exit-28 disambiguation (round-5 N2'/N3') — always skip on exit 28, ignoring time_connect --"
  connect28mutant="$(mkmut connect28-disambig <<'SED'
/^          28)$/,/^            ;;$/c\
          28) skip_fallback=1 ;;  # MUTANT: 28-disambiguation removed
SED
)"
  if ! grep -q 'MUTANT: 28-disambiguation removed' "$connect28mutant"; then
    no "teeth-connect28: could not build mutant (28 case arm not found, or bash -n rejected it — did the SUT change?)"
  else
    STUB_ROUTES='http://s40.example/a 301 http://s40.example/moved'; STUB_HEAD_HANG_URL='http://s40.example/a'
    _pcf40m="$TMP/probe-count-40m.txt"; : > "$_pcf40m"
    STUB_PROBE_COUNT_FILE="$_pcf40m"
    export STUB_ROUTES STUB_HEAD_HANG_URL STUB_PROBE_COUNT_FILE
    got40m="$(runresolve "$connect28mutant" "http://s40.example/a")"
    unset STUB_HEAD_HANG_URL STUB_PROBE_COUNT_FILE
    n40m="$(grep -c '^http://s40\.example/a$' "$_pcf40m")"
    if [ "$got40m" != "http://s40.example/moved" ] && [ "$n40m" = "1" ]; then
      ok "teeth-connect28: mutant wrongly skips the retry for a hung-but-reachable host too → N2'/N3'/R40 has teeth"
    else no "teeth-connect28: mutant got='$got40m' attempts=$n40m — N2'/N3'/R40 does NOT depend on the time_connect check (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-PROBE-FAIL-NOTICE — neuter the probe-failure stderr notice (keep the break) --"
  # CORE (round-5 S1): MUTANT-marker form, not "is the original notice text still present?".
  failnoticemutant="$(mkmut fail-notice <<'SED'
/SENTINEL-PROBE-FAIL-NOTICE/,/^      break$/ {
  s/printf 'fetch-doc: redirect probe failed.*/:  # MUTANT: fail-notice removed/
}
SED
)"
  if ! grep -q 'MUTANT: fail-notice removed' "$failnoticemutant"; then
    no "teeth-fail-notice: could not build mutant (notice printf not found, or bash -n rejected it — did the SUT change?)"
  else
    STUB_ROUTES=""; STUB_PROBE_FAIL_URL="http://s16.example/a"; export STUB_ROUTES STUB_PROBE_FAIL_URL
    got16nm="$(runresolve_err "$failnoticemutant" "http://s16.example/a" "$TMP/teeth-failnotice.err")"
    unset STUB_PROBE_FAIL_URL
    if [ "$got16nm" = "http://s16.example/a" ] && ! grep -qi 'redirect probe failed' "$TMP/teeth-failnotice.err"; then
      ok "teeth-fail-notice: mutant resolves correctly but prints NO probe-fail notice → RS5/R16 has teeth"
    else no "teeth-fail-notice: mutant behavior unexpected (got='$got16nm' err='$(cat "$TMP/teeth-failnotice.err")') — THEATER"; fi
  fi

  echo "-- teeth: SENTINEL-HOPCAP-NOTICE — neuter the hop-cap-reached stderr notice --"
  # CORE (round-5 S1): MUTANT-marker form, not "is the original notice text still present?".
  hopcapmutant="$(mkmut hopcap-notice <<'SED'
s/printf 'fetch-doc: hop cap.*/:  # MUTANT: hopcap notice removed/
SED
)"
  if ! grep -q 'MUTANT: hopcap notice removed' "$hopcapmutant"; then
    no "teeth-hopcap-notice: could not build mutant (notice printf not found, or bash -n rejected it — did the SUT change?)"
  else
    STUB_ROUTES=$'http://loop.example/a 301 http://loop.example/b\nhttp://loop.example/b 301 http://loop.example/a'
    export STUB_ROUTES
    runresolve_bounded "$hopcapmutant" "http://loop.example/a" got28m rc28m
    # shellcheck disable=SC2154  # assigned indirectly via printf -v inside runresolve_bounded
    if [ "$rc28m" = "0" ] && ! grep -qi 'hop cap' "$TMP/bounded.err"; then
      ok "teeth-hopcap-notice: mutant terminates correctly but prints NO hop-cap notice → R28 has teeth"
    else no "teeth-hopcap-notice: mutant rc=$rc28m err='$(cat "$TMP/bounded.err")' — THEATER"; fi
  fi

  echo "-- teeth: SENTINEL-HOP-BOUND (RS3) — while true instead of the bounded loop --"
  whiletruemutant="$(mkmut while-true <<'SED'
s/while \[ "\$hop" -lt "\$max_hops" \]; do/while true; do  # MUTANT: unbounded/
SED
)"
  if ! grep -q 'MUTANT: unbounded' "$whiletruemutant"; then
    no "teeth-while-true: could not build mutant (while condition not found — did the SUT change?)"
  else
    STUB_ROUTES=$'http://loop.example/a 301 http://loop.example/b\nhttp://loop.example/b 301 http://loop.example/a'
    export STUB_ROUTES
    runresolve_bounded "$whiletruemutant" "http://loop.example/a" got28wt rc28wt
    # shellcheck disable=SC2154  # assigned indirectly via printf -v inside runresolve_bounded
    if [ "$rc28wt" = "124" ]; then
      ok "teeth-while-true: mutant never terminates on a genuine redirect loop (timeout kills it, rc=124) → R28 has teeth"
    else no "teeth-while-true: mutant terminated with rc=$rc28wt (expected 124/timeout) — R28 does NOT depend on the loop bound (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-HOP-BOUND (RS3) — drop the hop increment (bound never advances) --"
  noincrmutant="$(mkmut no-increment <<'SED'
s/cur="\$loc"; hop=\$((hop + 1))/cur="$loc"  # MUTANT: hop increment dropped/
SED
)"
  if ! grep -q 'MUTANT: hop increment dropped' "$noincrmutant"; then
    no "teeth-no-increment: could not build mutant (increment line not found — did the SUT change?)"
  else
    STUB_ROUTES=$'http://loop.example/a 301 http://loop.example/b\nhttp://loop.example/b 301 http://loop.example/a'
    export STUB_ROUTES
    runresolve_bounded "$noincrmutant" "http://loop.example/a" got28ni rc28ni
    # shellcheck disable=SC2154  # assigned indirectly via printf -v inside runresolve_bounded
    if [ "$rc28ni" = "124" ]; then
      ok "teeth-no-increment: mutant's hop never advances so the bound never fires (timeout kills it, rc=124) → R28 has teeth"
    else no "teeth-no-increment: mutant terminated with rc=$rc28ni (expected 124/timeout) — R28 does NOT depend on the increment (THEATER)"; fi
  fi
  unset STUB_ROUTES

  echo "-- teeth: SENTINEL-DOC-RESOLVE (round-3 RR1) — doc mode skips redirect resolution entirely --"
  docresolvemutant="$(mkmut doc-resolve <<'SED'
/SENTINEL-DOC-RESOLVE/,/fetch_and_register "\$URL" "\$DEST"/ {
  s%EFFECTIVE_URL="\$(fetch_and_register "\$URL" "\$DEST")"%curl -fsSL "$URL" -o "$DEST" 2>/dev/null || wget -q "$URL" -O "$DEST"; EFFECTIVE_URL="$URL"  # MUTANT: doc resolve skipped%
}
SED
)"
  if ! grep -q 'MUTANT: doc resolve skipped' "$docresolvemutant"; then
    no "teeth-doc-resolve: could not build mutant (doc-mode call line not found — did the SUT change?)"
  else
    d21m="$TMP/teeth-doc-resolve/target"; mkdir -p "$d21m"
    STUB_ROUTES='http://s21.example/a 301 http://s21.example/moved'; export STUB_ROUTES
    PATH="$stubbin:$PATH" bash "$docresolvemutant" doc "http://s21.example/a" "$d21m" datasheets "r21m.html" >/dev/null 2>/dev/null
    got21m="$(origin_of "$d21m/sources/SOURCES.md" 'r21m\.html')"
    if [ "$got21m" = "http://s21.example/a" ]; then
      ok "teeth-doc-resolve: mutant registers the typed (unresolved) URL in doc mode → RR1/R21 has teeth"
    else no "teeth-doc-resolve: mutant still registered '$got21m' — RR1/R21 does NOT depend on doc-mode wiring (THEATER)"; fi
  fi

  echo "-- teeth: RR1 — doc mode's reg() call hardcoded back to \$URL instead of \$EFFECTIVE_URL --"
  docregmutant="$(mkmut doc-reg-url <<'SED'
0,/reg "\$SDIR" "\$DEST" "\$SUB" "\$EFFECTIVE_URL" "\$SHA"/ s//reg "$SDIR" "$DEST" "$SUB" "$URL" "$SHA"  # MUTANT: reg uses $URL/
SED
)"
  if ! grep -q 'MUTANT: reg uses \$URL' "$docregmutant"; then
    no "teeth-doc-reg-url: could not build mutant (doc reg() call line not found — did the SUT change?)"
  else
    d21r="$TMP/teeth-doc-reg/target"; mkdir -p "$d21r"
    STUB_ROUTES='http://s21.example/a 301 http://s21.example/moved'; export STUB_ROUTES
    PATH="$stubbin:$PATH" bash "$docregmutant" doc "http://s21.example/a" "$d21r" datasheets "r21r.html" >/dev/null 2>/dev/null
    got21r="$(origin_of "$d21r/sources/SOURCES.md" 'r21r\.html')"
    if [ "$got21r" = "http://s21.example/a" ]; then
      ok "teeth-doc-reg-url: mutant registers \$URL despite correct resolution → RR1/R21 has teeth"
    else no "teeth-doc-reg-url: mutant still registered '$got21r' — RR1/R21 does NOT depend on the reg() call's variable (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-WEB-RESOLVE — web mode skips redirect resolution (registers \$URL directly) --"
  wmutant="$(mkmut web-resolve <<'SED'
/SENTINEL-WEB-RESOLVE/,/fetch_and_register "\$URL" "\$HTML"/ {
  s%EFFECTIVE_URL="\$(fetch_and_register "\$URL" "\$HTML")"%curl -fsSL "$URL" -o "$HTML" 2>/dev/null || wget -q "$URL" -O "$HTML"; EFFECTIVE_URL="$URL"  # MUTANT: web resolve skipped%
}
SED
)"
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

  echo "-- teeth: SENTINEL-DOWNLOAD — neuter (not delete) the post-download 'registered X (permanent redirect' notice --"
  # CORE (round-4 Q2): the notice line is the ONLY statement inside its `if [ -s "$dest" ] &&
  # [ "$effective" != "$url" ]; then ... fi` body (round-4 N4 wrapped it in that empty-body
  # guard). A plain `/pattern/d` LINE DELETE — round-3's original mutant — leaves an EMPTY
  # then-body, which is a bash SYNTAX ERROR: the mutant never runs at all, "no notice on stderr"
  # holds trivially (wrong-reason "pass", not a kill — kit CLAUDE.md §4), and EVERY OTHER
  # assertion against that same broken mutant would spuriously "pass" too. Substituting `:` (a
  # no-op) keeps the if/then/fi structurally valid while still removing the notice's actual
  # effect. mkmut's own `bash -n` check (Q2) would catch the delete-based version outright; this
  # mutant is additionally asserted to register the CORRECT resolved URL, proving the control
  # isolates "no notice" from "no registration" — a broken mutant could accidentally satisfy the
  # OLD "no notice" check while ALSO failing to register anything, and the assertion would not
  # have been able to tell those apart.
  resolvenoticemutant="$(mkmut resolve-notice <<'SED'
s/printf 'fetch-doc: registered %s (permanent redirect from %s)\\n' "\$effective" "\$url" >&2/:  # MUTANT: resolve notice neutered/
SED
)"
  if ! grep -q 'MUTANT: resolve notice neutered' "$resolvenoticemutant"; then
    no "teeth-resolve-notice: could not build mutant (notice printf not found, or bash -n rejected it — did the SUT change?)"
  else
    d22m="$TMP/teeth-resolve-notice/target"; mkdir -p "$d22m"
    STUB_ROUTES='http://s21.example/a 301 http://s21.example/moved'; export STUB_ROUTES
    PATH="$stubbin:$PATH" bash "$resolvenoticemutant" doc "http://s21.example/a" "$d22m" datasheets "r22m.html" >/dev/null 2>"$TMP/teeth-resolve-notice.err"
    got22m="$(origin_of "$d22m/sources/SOURCES.md" 'r22m\.html')"
    if [ "$got22m" = "http://s21.example/moved" ] && ! grep -qi 'permanent redirect from' "$TMP/teeth-resolve-notice.err"; then
      ok "teeth-resolve-notice: mutant registers the resolved URL correctly but prints NO resolution notice → R22 has teeth"
    else no "teeth-resolve-notice: mutant origin='$got22m' err='$(cat "$TMP/teeth-resolve-notice.err")' — THEATER"; fi
  fi

  echo "-- teeth: SENTINEL-DOWNLOAD — wget-fallback branch returns \$effective instead of \$url --"
  wrongvarmutant="$(mkmut wrong-var <<'SED'
/wget -q "\$url" -O "\$dest"/,/^  fi$/ {
  s/printf '%s' "\$url"/printf '%s' "$effective"  # MUTANT: wrong variable on fallback/
}
SED
)"
  if ! grep -q 'MUTANT: wrong variable on fallback' "$wrongvarmutant"; then
    no "teeth-wrong-var: could not build mutant (fallback return line not found — did the SUT change?)"
  else
    d18wv="$TMP/teeth-wrong-var/target"; mkdir -p "$d18wv"
    STUB_ROUTES='http://s18.example/a 301 http://s18.example/resolved'; STUB_DOWNLOAD_FAIL=1
    export STUB_ROUTES STUB_DOWNLOAD_FAIL
    PATH="$stubbin:$PATH" bash "$wrongvarmutant" doc "http://s18.example/a" "$d18wv" datasheets "r18wv.html" >/dev/null 2>/dev/null
    unset STUB_DOWNLOAD_FAIL
    got18wv="$(origin_of "$d18wv/sources/SOURCES.md" 'r18wv\.html')"
    if [ "$got18wv" = "http://s18.example/resolved" ]; then
      ok "teeth-wrong-var: mutant registers the resolved-but-undownloadable URL after wget fallback → R18 has teeth"
    else no "teeth-wrong-var: mutant registered '$got18wv' (expected the resolved url) — R18 does NOT depend on returning \$url (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-WGET-GUARD (round-4 RDD) — ignore wget's own exit status --"
  # Reverts the explicit `if wget -q ...; then ... else ... exit 1; fi` (round-4) back to an
  # unconditional call + success notice — the exact shape that silently registered a "successful"
  # wget fallback even when wget itself had failed (errexit does not propagate into this
  # command-substitution-invoked function by default — see the errexit note above the function).
  wgetignoremutant="$(mkmut wget-ignore-status <<'SED'
/^    if have_cmd wget && wget -q "\$url" -O "\$dest" && \[ -s "\$dest" \]; then$/,/^    fi$/c\
    wget -q "$url" -O "$dest"  # MUTANT: wget status ignored\
    echo "fetch-doc: registered requested URL (wget fallback; effective URL unknown)" >&2\
    printf '%s' "$url"
SED
)"
  if ! grep -q 'MUTANT: wget status ignored' "$wgetignoremutant"; then
    no "teeth-wget-ignore-status: could not build mutant (wget if/else block not found, or bash -n rejected it — did the SUT change?)"
  else
    d37m="$TMP/teeth-wget-ignore/target"; mkdir -p "$d37m"
    STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; STUB_WGET_FAIL=1
    export STUB_ROUTES STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
    _rc37m=0
    PATH="$stubbin:$PATH" bash "$wgetignoremutant" doc "http://s37.example/a" "$d37m" datasheets "r37m.html" >/dev/null 2>"$TMP/teeth-wget-ignore.err" || _rc37m=$?
    unset STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
    if grep -qi 'registered requested URL' "$TMP/teeth-wget-ignore.err"; then
      ok "teeth-wget-ignore-status: mutant falsely announces a 'registered' URL despite wget's own failure → RDD/R37 has teeth"
    else no "teeth-wget-ignore-status: mutant rc=$_rc37m err='$(cat "$TMP/teeth-wget-ignore.err")' — RDD/R37 does NOT depend on checking wget's status (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-WGET-CLEANUP (round-5 R1) — drop the rm -f \$dest cleanup before exit 1 --"
  wgetcleanupmutant="$(mkmut wget-cleanup <<'SED'
/SENTINEL-WGET-CLEANUP/,/ALSO failed/ {
  s/rm -f "\$dest"/:  # MUTANT: wget-failure cleanup removed/
}
SED
)"
  # R3-wget-cleanup-mutant-overbroad (#1285): the range above confines the mutation to the ONE
  # `rm -f` inside the SENTINEL-WGET-CLEANUP block; the other `rm -f "$dest"` sites stay intact.
  if ! grep -q 'MUTANT: wget-failure cleanup removed' "$wgetcleanupmutant" \
     || [ "$(grep -c 'MUTANT: wget-failure cleanup removed' "$wgetcleanupmutant")" != "1" ]; then
    no "teeth-wget-cleanup: could not build a single-site mutant (rm -f \"\$dest\" in the WGET-CLEANUP block not found exactly once, or bash -n rejected it — did the SUT change?)"
  else
    d37c="$TMP/teeth-wget-cleanup"; mkdir -p "$d37c/datasheets"
    STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; STUB_WGET_FAIL=1
    export STUB_ROUTES STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
    # Call fetch_and_register DIRECTLY (sourced): the main dispatch's EXIT trap is a second line of
    # defence that would mask a missing in-function rm, so the in-function cleanup is tested alone.
    # shellcheck disable=SC1090
    ( set +e; PATH="$stubbin:$PATH"; export PATH; source "$wgetcleanupmutant" >/dev/null 2>&1
      fetch_and_register "http://s37.example/a" "$d37c/datasheets/r37c.html" >/dev/null 2>&1 )
    unset STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
    if [ -n "$(find "$d37c/datasheets" -type f)" ]; then
      ok "teeth-wget-cleanup: mutant leaves the 0-byte debris file behind → R1/R37 has teeth"
    else no "teeth-wget-cleanup: mutant still cleaned up the file — R1/R37 does NOT depend on this rm -f (THEATER)"; fi
  fi

  # ── #1285 teeth (built with lib/mutant.sh, kit #943: refuses an empty/identical/live-tree mutant) ──
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"

  echo "-- teeth: SENTINEL-PART-FILE (#1285 item 1) — download straight into the destination --"
  if ! mutant_sed "$SUT" "$TMP/part-file.MUT.sh" 's/local dest="\$final\.part\.\$\$"/local dest="$final"  # MUTANT: part file removed/'; then
    no "teeth-part-file: could not build mutant (part-file assignment not found, or refused by lib/mutant.sh)"
  else
    dpm="$TMP/teeth-part-file/target"; fpm="$(mkexisting "$dpm" tpm.pdf)"
    STUB_ROUTES=""; STUB_DOWNLOAD_PARTIAL=1; STUB_WGET_FAIL=1; export STUB_ROUTES STUB_DOWNLOAD_PARTIAL STUB_WGET_FAIL
    PATH="$stubbin:$PATH" bash "$TMP/part-file.MUT.sh" doc "http://spm.example/a" "$dpm" datasheets "tpm.pdf" >/dev/null 2>&1
    unset STUB_DOWNLOAD_PARTIAL STUB_WGET_FAIL
    if [ "$(sum_of "$fpm")" != "$EVID_SUM" ]; then
      ok "teeth-part-file: mutant lets a failed re-fetch destroy the registered file → R41/R42 have teeth"
    else no "teeth-part-file: mutant left the registered file intact — R41/R42 do NOT depend on the part file (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-TRAP (#1285 item 2) — drop the EXIT cleanup trap (doc and web) --"
  if ! command -v setsid >/dev/null 2>&1; then
    printf '  SKIP  teeth-trap-doc: setsid not available\n'
  elif ! mutant_sed "$SUT" "$TMP/trap-doc.MUT.sh" "s/trap 'rm -f \"\$DEST\.part\.\$\$\"' EXIT; /: /"; then
    no "teeth-trap-doc: could not build mutant (doc EXIT trap not found, or refused by lib/mutant.sh)"
  else
    dtd="$TMP/teeth-trap-doc/target"; mkexisting "$dtd" ttd.pdf >/dev/null
    STUB_ROUTES=""; STUB_DOWNLOAD_HANG=1; STUB_HANG_MARKER="$TMP/hang-ttd.marker"; rm -f "$STUB_HANG_MARKER"
    export STUB_ROUTES STUB_DOWNLOAD_HANG STUB_HANG_MARKER
    PATH="$stubbin:$PATH" setsid bash "$TMP/trap-doc.MUT.sh" doc "http://std.example/a" "$dtd" datasheets "ttd.pdf" >/dev/null 2>&1 &
    _ptd=$!
    for _ in $(seq 1 100); do [ -e "$STUB_HANG_MARKER" ] && break; sleep 0.1; done
    kill -TERM -- "-$_ptd" 2>/dev/null; wait "$_ptd" 2>/dev/null
    unset STUB_DOWNLOAD_HANG STUB_HANG_MARKER STUB_ROUTES
    if [ -n "$(find "$dtd/sources/datasheets" -type f ! -name ttd.pdf)" ]; then
      ok "teeth-trap-doc: mutant leaves the partial file behind after SIGTERM → R45 has teeth"
    else no "teeth-trap-doc: mutant still left no debris — R45 does NOT depend on the EXIT trap (THEATER)"; fi
  fi
  if ! mutant_sed "$SUT" "$TMP/trap-web.MUT.sh" "s/trap 'rm -f \"\$HTML\" \"\$HTML\.part\.\$\$\"' EXIT; /: /"; then
    no "teeth-trap-web: could not build mutant (web EXIT trap not found, or refused by lib/mutant.sh)"
  else
    dtw="$TMP/teeth-trap-web/target"; mkdir -p "$dtw/sources/web-snapshots"; chmod 555 "$dtw/sources/web-snapshots"
    dtw_tmp="$TMP/teeth-trap-web-tmp"; mkdir -p "$dtw_tmp"
    if { : > "$dtw/sources/web-snapshots/.probe"; } 2>/dev/null; then
      printf '  SKIP  teeth-trap-web: cannot make the snapshot dir unwritable here (root?)\n'
    else
      STUB_ROUTES=""; export STUB_ROUTES
      TMPDIR="$dtw_tmp" PATH="$stubbin:$PATH" bash "$TMP/trap-web.MUT.sh" web "http://stw.example/a" "$dtw" >/dev/null 2>&1
      unset STUB_ROUTES
      if [ -n "$(find "$dtw_tmp" -mindepth 1)" ]; then
        ok "teeth-trap-web: mutant leaks the mktemp HTML when a post-download step fails → R46 has teeth"
      else no "teeth-trap-web: mutant leaked nothing — R46 does NOT depend on the web EXIT trap (THEATER)"; fi
    fi
    chmod 755 "$dtw/sources/web-snapshots"
  fi

  echo "-- teeth: probe_downloaders (#1285 item 3) — remove the startup dependency probe --"
  if ! mutant_sed "$SUT" "$TMP/probe.MUT.sh" 's/^    probe_downloaders$/    :  # MUTANT: probe removed/'; then
    no "teeth-probe: could not build mutant (probe_downloaders calls not found, or refused by lib/mutant.sh)"
  else
    dpr="$TMP/teeth-probe/target"; mkdir -p "$dpr"
    _rcpr=0; PATH="$nodl" "$nodl/bash" "$TMP/probe.MUT.sh" doc "http://spr.example/a.pdf" "$dpr" datasheets "tpr.pdf" >/dev/null 2>"$TMP/err-probe.txt" || _rcpr=$?
    if [ "$_rcpr" -ne 3 ] || ! grep -qi 'DEGRADED' "$TMP/err-probe.txt"; then
      ok "teeth-probe: mutant without the probe loses the typed DEGRADED error (rc=$_rcpr) → R47 has teeth"
    else no "teeth-probe: mutant still emitted the DEGRADED error — R47 does NOT depend on the probe (THEATER)"; fi
  fi

  echo "-- teeth: time_connect edges (#1285 item 5) — bare 0, empty, always-retry-on-28 --"
  # tc_mutant <name> <sed-expr> <time_connect-value> <label> <test-ids> — the mutant must RETRY (2 attempts)
  # where the real SUT makes 1.
  tc_mutant(){ local name="$1" expr="$2" tcv="$3" lbl="$4" ids="$5" m="$TMP/$1.MUT.sh" n
    if ! mutant_sed "$SUT" "$m" "$expr"; then
      no "teeth-$name: could not build mutant (case alternative not found, or refused by lib/mutant.sh)"; return
    fi
    STUB_ROUTES=""; STUB_HEAD_BLACKHOLE_URL="http://s-$name.example/a"; STUB_HEAD_BLACKHOLE_TIME_CONNECT="$tcv"
    local pcf="$TMP/probe-count-$name.txt"; : > "$pcf"; STUB_PROBE_COUNT_FILE="$pcf"
    export STUB_ROUTES STUB_HEAD_BLACKHOLE_URL STUB_HEAD_BLACKHOLE_TIME_CONNECT STUB_PROBE_COUNT_FILE
    runresolve "$m" "http://s-$name.example/a" >/dev/null
    unset STUB_HEAD_BLACKHOLE_URL STUB_HEAD_BLACKHOLE_TIME_CONNECT STUB_PROBE_COUNT_FILE STUB_ROUTES
    n="$(grep -c "^http://s-$name\.example/a\$" "$pcf")"
    if [ "$n" -gt 1 ]; then ok "teeth-$name: mutant retries via GET ($n attempts, real SUT makes 1) for $lbl → $ids has teeth"
    else no "teeth-$name: mutant still made $n attempt(s) — $ids does NOT depend on $lbl (THEATER)"; fi
  }
  tc_mutant tc-bare-zero 's/^\( *\)0|0\.000000|/\10.000000|/' "0" "a bare 0 time_connect" "R40b"
  tc_mutant tc-empty 's/0\.000000000|"") skip_fallback=1/0.000000000) skip_fallback=1/' "" "an empty time_connect" "R40c"
  tc_mutant tc-always-retry-28 's/0|0\.000000|0\.000000000|"") skip_fallback=1/0|0.000000|0.000000000|"") skip_fallback=0/' "0.000000" "a zero time_connect (always-retry-on-28)" "R39"

  echo "-- teeth: SENTINEL-DOWNLOAD — neuter the wget-fallback stderr notice --"
  # CORE (round-5 S1): MUTANT-marker form, not "is the original notice text still present?".
  nmutant="$(mkmut wget-notice <<'SED'
s/echo "fetch-doc: registered requested URL (wget fallback.*/:  # MUTANT: wget notice removed/
SED
)"
  if ! grep -q 'MUTANT: wget notice removed' "$nmutant"; then
    no "teeth-wget-notice: could not build mutant (notice echo not found, or bash -n rejected it — did the SUT change?)"
  else
    d18n="$TMP/teeth-wget-notice/target"; mkdir -p "$d18n"
    STUB_ROUTES='http://s18.example/a 301 http://s18.example/resolved'; STUB_DOWNLOAD_FAIL=1
    export STUB_ROUTES STUB_DOWNLOAD_FAIL
    PATH="$stubbin:$PATH" bash "$nmutant" doc "http://s18.example/a" "$d18n" datasheets "r18n.html" >/dev/null 2>"$TMP/teeth-notice.err"
    unset STUB_DOWNLOAD_FAIL
    if ! grep -qi 'wget fallback' "$TMP/teeth-notice.err"; then
      ok "teeth-wget-notice: mutant emits NO reversion notice on wget fallback → R18 has teeth"
    else no "teeth-wget-notice: mutant still emitted the notice — R18 does NOT depend on the echo (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-DOWNLOAD — restore 2>/dev/null on the shared download call (swallows curl -S diagnostics) --"
  smutant="$(mkmut download-stderr <<'SED'
s/curl -fsS -L "\$effective" -o "\$dest"; then/curl -fsS -L "$effective" -o "$dest" 2>\/dev\/null; then/
SED
)"
  if ! grep -q 'curl -fsS -L "\$effective" -o "\$dest" 2>/dev/null; then' "$smutant"; then
    no "teeth-download-stderr: could not build mutant (shared download line not found — did the SUT change?)"
  else
    d_s3="$TMP/teeth-s3/target"; mkdir -p "$d_s3"
    STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; export STUB_ROUTES STUB_DOWNLOAD_FAIL
    PATH="$stubbin:$PATH" bash "$smutant" doc "http://s3.example/a" "$d_s3" datasheets "r-s3.html" >/dev/null 2>"$TMP/teeth-s3.err"
    got_s3w="$TMP/teeth-s3-web/target"; mkdir -p "$got_s3w"
    PATH="$stubbin:$PATH" bash "$smutant" web "http://s3w.example/a" "$got_s3w" >/dev/null 2>"$TMP/teeth-s3-web.err"
    unset STUB_DOWNLOAD_FAIL
    if ! grep -q 'simulated download transfer failure' "$TMP/teeth-s3.err" \
       && ! grep -q 'simulated download transfer failure' "$TMP/teeth-s3-web.err"; then
      ok "teeth-download-stderr: 2>/dev/null mutant swallows curl's own diagnostic in BOTH modes → S3/N4 has teeth"
    else no "teeth-download-stderr: mutant's stderr still carried the diagnostic somewhere — S3 check does NOT depend on keeping stderr (THEATER)"; fi
  fi

  echo "-- teeth: SENTINEL-DOWNLOAD (RS2) — drop -L on the shared download call --"
  noLmutant="$(mkmut no-L <<'SED'
s/curl -fsS -L "\$effective" -o "\$dest"; then/curl -fsS "$effective" -o "$dest"; then  # MUTANT: -L dropped/
SED
)"
  if ! grep -q 'MUTANT: -L dropped' "$noLmutant"; then
    no "teeth-no-L: could not build mutant (shared download line not found — did the SUT change?)"
  else
    d29m="$TMP/teeth-no-L/target"; mkdir -p "$d29m"
    STUB_ROUTES=$'http://s29.example/a 301 http://s29.example/permanent\nhttp://s29.example/permanent 302 http://s29.example/final-content'
    export STUB_ROUTES
    PATH="$stubbin:$PATH" bash "$noLmutant" doc "http://s29.example/a" "$d29m" datasheets "r29m.html" >/dev/null 2>/dev/null
    if grep -qF 'stub REDIRECT body (no -L) for http://s29.example/permanent' "$d29m/sources/datasheets/r29m.html" 2>/dev/null; then
      ok "teeth-no-L: mutant downloads the REDIRECT response, not the final content → R29/RS2 has teeth"
    else no "teeth-no-L: mutant body unexpected :: $(cat "$d29m/sources/datasheets/r29m.html" 2>/dev/null || echo MISSING) — THEATER"; fi
  fi

  echo "-- teeth: SENTINEL-MAXHOPS-VALUE — lower the hop cap below the length of a real chain --"
  hmutant2="$(mkmut maxhops <<'SED'
s/max_hops=10  # SENTINEL-MAXHOPS-VALUE.*/max_hops=2  # MUTANT: hop cap lowered/
SED
)"
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
  unset STUB_ROUTES

  echo "-- teeth: RDD/N1 — restore the OLD unconditional pre-download notice ordering --"
  # Proves the CURRENT design choice (notice fires only AFTER a confirmed successful download)
  # is load-bearing: reverting to the old ordering (announce the resolution BEFORE attempting
  # the download) produces the exact contradiction N1 flagged — a "registered X (permanent
  # redirect ...)" line immediately followed by a "registered requested URL (wget fallback ...)"
  # line for the SAME run, when the download then fails and wget takes over.
  oldordermutant="$(mkmut old-order <<'SED'
/effective="\$(resolve_permanent_redirect "\$url")"/a\
  if [ "$effective" != "$url" ]; then printf '"'"'fetch-doc: registered %s (permanent redirect from %s)\n'"'"' "$effective" "$url" >&2; fi  # MUTANT: old unconditional pre-download notice
SED
)"
  if ! grep -q 'MUTANT: old unconditional pre-download notice' "$oldordermutant"; then
    no "teeth-old-order: could not build mutant (resolve-call line not found — did the SUT change?)"
  else
    d18oo="$TMP/teeth-old-order/target"; mkdir -p "$d18oo"
    STUB_ROUTES='http://s18.example/a 301 http://s18.example/resolved'; STUB_DOWNLOAD_FAIL=1
    export STUB_ROUTES STUB_DOWNLOAD_FAIL
    PATH="$stubbin:$PATH" bash "$oldordermutant" doc "http://s18.example/a" "$d18oo" datasheets "r18oo.html" >/dev/null 2>"$TMP/teeth-old-order.err"
    unset STUB_DOWNLOAD_FAIL
    if [ "$(grep -c 'registered' "$TMP/teeth-old-order.err")" -ge 2 ]; then
      ok "teeth-old-order: mutant produces TWO contradictory 'registered ...' lines on wget fallback → N1/RDD has teeth"
    else no "teeth-old-order: mutant produced $(grep -c 'registered' "$TMP/teeth-old-order.err") 'registered' line(s) (expected >=2) :: $(cat "$TMP/teeth-old-order.err") — THEATER"; fi
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
    echo "-- teeth: neuter SENTINEL-EMPTY-GUARD (doc mode); empty body must then register + OK --"
    # The empty-body guard lives in fetch_and_register (#1285 moved it before the part-file move).
    # lib/mutant.sh (kit #943) refuses an empty/identical/live-tree mutant.
    # shellcheck source=lib/mutant.sh
    . "$HERE/lib/mutant.sh"
    gmutant="$TMP/fetch-doc.GMUTANT.sh"
    if ! mutant_sed "$SUT" "$gmutant" 's/if \[ ! -s "\$dest" \]; then/if false; then  # MUTANT: empty guard removed/'; then
      no "teeth-doc-empty: could not build guard mutant (empty-guard line not found, or refused by lib/mutant.sh)"
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

    echo "-- teeth: neuter SENTINEL-EMPTY-GUARD (web mode); empty HTML must then register + OK --"
    gwmutant="$TMP/fetch-doc.GWMUTANT.sh"
    # Same single shared guard serves web mode (the HTML snapshot goes through fetch_and_register).
    if ! mutant_sed "$SUT" "$gwmutant" 's/if \[ ! -s "\$dest" \]; then/if false; then  # MUTANT: empty guard removed/'; then
      no "teeth-web-empty: could not build guard mutant (empty-guard line not found, or refused by lib/mutant.sh)"
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
