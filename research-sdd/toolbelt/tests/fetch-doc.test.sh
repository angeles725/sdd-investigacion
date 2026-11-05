#!/usr/bin/env bash
# fetch-doc.test.sh — harness for fetch-doc.sh (downloads and registers external sources under TARGET/sources).
#
# fetch-doc.sh is a compatibility shim over `rsdd sources fetch-doc` (Go). The black-box cases below run through it with
# the stub curl/wget/pandoc on a private PATH (no network): redirect registration, the part-file and overwrite policy,
# --replace archiving, cancellation by signal, the test seam, PDF/web integration and the snapshot names. The engine is
# pinned in Go (research-sdd/rsdd/internal/sources/...: a differential against the frozen script, a golden replay, unit
# tests, package teeth; internal/core/srcregistry for the SOURCES.md table). --prove-teeth mutates the SHIM (arguments,
# command and group name, exit code, the library guard); the old controls that edited the retired script body, and the
# cases that sourced its functions (reg, resolve_permanent_redirect, fetch_and_register, web_slug), are typed SKIPs
# naming the Go tests that replace them.
#
# Usage: fetch-doc.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error (SUT missing).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../fetch-doc.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
SUT_IS_SHIM=0; grep -q "rsdd_exec" "$SUT" && SUT_IS_SHIM=1
MUT=""
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" ${MUT:+"$MUT"}' EXIT
pass=0; fail=0; skips=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip(){ printf '  SKIP  %s\n' "$1"; skips=$((skips+1)); }
# --- mutation-control helpers (kit issues #943, #1299): lib/mutant.sh builds every mutant as a COPY (it refuses an empty,
# byte-identical, syntax-broken or live-tree one) and mutant_tooth asserts the exact verdict of the original and the mutant.
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_sed mutant_tooth || exit 2
MUT="$(mktemp -d)"
tooth(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
# The cases that sourced the script's functions moved to Go:
#   1-5 (reg(): create, end-of-table insert, contiguity, no trailing prose, backslash cell)
#         -> internal/core/srcregistry TestInsertRow*, TestParseRows*, TestFormatRowAndSafeCell and the differential
#            cases doc-registry-with-trailing-prose, doc-backslash-url
#   11-14, 16, 17, 19, 23-28, 30-35, 39, 40 (resolve_permanent_redirect called directly)
#         -> internal/sources/redirect (TestFollowsOnlyPermanentRedirects, TestRefusesNonHTTPSchemeWithNotice,
#            TestHopCapBoundsAChainAndALoop, TestHeadRefusedFallsBackToGet, TestConnectClassFailuresSkipTheGetRetry, ...)
#   44b (fetch_and_register called directly) -> internal/sources/download tests
#   71f-71i (web_slug sourced, no sha256 tool) -> internal/sources/slug tests, TestIntendedDivergences

# lineno <file> <fixed-string> — 1-based line number of the first line CONTAINING the string, or 0.
lineno(){ awk -v s="$2" 'index($0,s){print NR; exit}' "$1"; }

echo "== fetch-doc.test.sh (SUT: $(basename "$SUT")) =="


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
head_routes_has(){ <<<"${STUB_HEAD_ROUTES:-}" grep -qF "$1 "; }

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
  sleep "${STUB_HANG_SECS:-30}" & _sp=$!; [ -n "${STUB_HANG_PIDFILE:-}" ] && echo "$_sp" > "$STUB_HANG_PIDFILE"; wait $_sp
  # Reached only when NOT signalled (#1313): the download "completes" with NEW bytes and says so.
  [ -n "${STUB_HANG_DONE_MARKER:-}" ] && : > "$STUB_HANG_DONE_MARKER"
  [ -n "$out" ] && printf 'NEW-BYTES-AFTER-HANG\n' > "$out"
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
[ -n "$out" ] && printf '%s\n' "${STUB_BODY:-stub body for $target}" >"$out"
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
if [ "${STUB_WGET_EMPTY:-0}" = "1" ]; then
  # An "empty 200": wget exits 0 but wrote ZERO bytes (#1285 review B1).
  [ -n "$out" ] && : > "$out"
  exit 0
fi
[ -n "$out" ] && printf 'stub wget body\n' >"$out"
exit 0
STUBEOF
chmod +x "$stubbin/wget"

# runchain <mode> <dir> <typed-url> [extra doc args...] — invoke the SUT with the stub curl/wget
# on PATH and the current $STUB_* controls exported.
runchain(){ local mode="$1" dir="$2" url="$3"; shift 3
  PATH="$stubbin:$PATH" bash "$SUT" ${RC_REPLACE:+--replace} "$mode" "$url" "$dir" "$@" >/dev/null 2>"$TMP/runchain.err"
}
# origin_of <sources-md> <needle> — the Origin (URL) cell of the row whose File cell matches <needle>.

origin_of(){ awk -F' \\| ' -v n="$2" '$0 ~ n {gsub(/^\| */,"",$1); print $3; exit}' "$1" 2>/dev/null; }

# 15 — R1: full pipeline, WEB mode — applies the SAME permanent-redirect-only resolution as doc
#      mode and registers the RESOLVED url in SOURCES.md (wiring check: web mode must actually
#      call resolve_permanent_redirect() and use its result, not just have the function exist).
d15="$TMP/rr-15/target"; mkdir -p "$d15"
STUB_ROUTES='http://s15.example/a 301 http://s15.example/moved'
export STUB_ROUTES
runchain web "$d15" "http://s15.example/a"
slug15="s15.example_a"
got15="$(origin_of "$d15/sources/SOURCES.md" "$slug15")"
if [ "$got15" = "http://s15.example/moved" ]; then
  ok "web: R1 — same permanent-redirect resolution applies in web mode (wiring)"
else no "R15: expected http://s15.example/moved, got '$got15' (err: $(cat "$TMP/runchain.err"))"; fi


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
slug18b="s18b.example_a"
got18b="$(origin_of "$d18b/sources/SOURCES.md" "$slug18b")"
if [ "$got18b" = "http://s18b.example/a" ] && grep -qi 'wget fallback' "$TMP/runchain.err"; then
  ok "web: S2 — wget fallback registers the typed URL and announces the reversion on stderr"
else no "R18b: expected typed URL + stderr notice, got origin='$got18b' err='$(cat "$TMP/runchain.err")'"; fi


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
# #1354 (R3-37b-tmpdir-vacuous): an empty $TMPDIR proves nothing unless mktemp really created files THERE. This
# logging mktemp shim records every path it hands out, so the assertion below can require >=1 created AND 0 left.
mklog37b="$TMP/mklog37b-bin"; mkdir -p "$mklog37b"; _realmk37b="$(command -v mktemp)"
printf '#!/usr/bin/env bash\nr="$(%s "$@")" || exit $?\nprintf "%%s\\n" "$r" >> "$MKTEMP_LOG"\nprintf "%%s\\n" "$r"\n' "$_realmk37b" > "$mklog37b/mktemp"; chmod +x "$mklog37b/mktemp"
: > "$TMP/mklog37b.txt"
MKTEMP_LOG="$TMP/mklog37b.txt" PATH="$mklog37b:$PATH" TMPDIR="$d37b_tmpdir" runchain web "$d37b" "http://s37b.example/a" || _rc37b=$?
_made37b="$(awk -v p="$d37b_tmpdir/" 'index($0,p)==1{n++} END{print n+0}' "$TMP/mklog37b.txt")"
unset STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
slug37b="s37b.example_a"
_row37b=false
[ -f "$d37b/sources/SOURCES.md" ] && grep -q "$slug37b" "$d37b/sources/SOURCES.md" && _row37b=true
_leaked37b="$(find "$d37b_tmpdir" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$_rc37b" -ne 0 ] && ! $_row37b && [ "$_leaked37b" = "0" ] \
   && grep -qi 'wget fallback ALSO failed' "$TMP/runchain.err" \
   && ! grep -qi 'registered requested URL' "$TMP/runchain.err"; then
  ok "web: RDD/R1 — wget ALSO failing registers nothing and leaks NO temp HTML file"
else no "R37b: rc=$_rc37b row=$_row37b made-in-tmpdir=$_made37b leaked=$_leaked37b err='$(cat "$TMP/runchain.err")'"; fi
unset STUB_ROUTES


# ─── #1285 item 1: a failed re-fetch must leave an already-registered file byte-identical ───
# mkexisting <dir> <name> — seed sources/datasheets/<name> with known evidence; echo its path.
mkexisting(){ mkdir -p "$1/sources/datasheets"; printf 'REGISTERED-EVIDENCE\n' > "$1/sources/datasheets/$2"; printf '%s' "$1/sources/datasheets/$2"; }
EVID_SUM="$(printf 'REGISTERED-EVIDENCE\n' | sha256sum | cut -d' ' -f1)"
sum_of(){ sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 41 — curl AND wget both fail outright on a re-fetch: the existing file survives, byte-identical.
d41="$TMP/rr-41/target"; f41="$(mkexisting "$d41" r41.pdf)"
STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; STUB_WGET_FAIL=1; export STUB_ROUTES STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
_rc41=0; RC_REPLACE=1 runchain doc "$d41" "http://s41.example/a" datasheets "r41.pdf" || _rc41=$?
unset STUB_DOWNLOAD_FAIL STUB_WGET_FAIL
if [ "$_rc41" -ne 0 ] && [ "$(sum_of "$f41")" = "$EVID_SUM" ]; then
  ok "doc: #1285 — re-fetch with curl AND wget failing leaves the registered file byte-identical"
else no "R41: rc=$_rc41 sum=$(sum_of "$f41") exists=$([ -e "$f41" ] && echo yes || echo no)"; fi

# 42 — curl dies MID-TRANSFER (partial bytes written) and wget fails: still byte-identical, no debris.
d42="$TMP/rr-42/target"; f42="$(mkexisting "$d42" r42.pdf)"
STUB_ROUTES=""; STUB_DOWNLOAD_PARTIAL=1; STUB_WGET_FAIL=1; export STUB_ROUTES STUB_DOWNLOAD_PARTIAL STUB_WGET_FAIL
_rc42=0; RC_REPLACE=1 runchain doc "$d42" "http://s42.example/a" datasheets "r42.pdf" || _rc42=$?
unset STUB_DOWNLOAD_PARTIAL STUB_WGET_FAIL
_debris42="$(find "$d42/sources/datasheets" -type f ! -name r42.pdf | wc -l | tr -d ' ')"
if [ "$_rc42" -ne 0 ] && [ "$(sum_of "$f42")" = "$EVID_SUM" ] && [ "$_debris42" = "0" ]; then
  ok "doc: #1285 — a partial curl transfer never overwrites the registered file; no part-file debris"
else no "R42: rc=$_rc42 sum=$(sum_of "$f42") debris=$_debris42"; fi

# 43 — a 200 with an EMPTY body on a re-fetch must not delete or truncate the registered file.
d43="$TMP/rr-43/target"; f43="$(mkexisting "$d43" r43.pdf)"
STUB_ROUTES=""; STUB_DOWNLOAD_EMPTY=1; export STUB_ROUTES STUB_DOWNLOAD_EMPTY
_rc43=0; RC_REPLACE=1 runchain doc "$d43" "http://s43.example/a" datasheets "r43.pdf" || _rc43=$?
unset STUB_DOWNLOAD_EMPTY
if [ "$_rc43" -ne 0 ] && [ "$(sum_of "$f43")" = "$EVID_SUM" ] && grep -qi 'empty body' "$TMP/runchain.err"; then
  ok "doc: #1285 — an empty-body re-fetch fails loudly and leaves the registered file intact"
else no "R43: rc=$_rc43 sum=$(sum_of "$f43") err='$(cat "$TMP/runchain.err")'"; fi

# 43w — #1285 review B1: curl FAILS and wget returns an EMPTY 200 on a re-fetch. The registered file
#      must survive byte-identical, no row may be written, and the message must say "empty body"
#      (not the misleading "wget fallback ALSO failed").
d43w="$TMP/rr-43w/target"; f43w="$(mkexisting "$d43w" r43w.pdf)"
STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; STUB_WGET_EMPTY=1; export STUB_ROUTES STUB_DOWNLOAD_FAIL STUB_WGET_EMPTY
_rc43w=0; RC_REPLACE=1 runchain doc "$d43w" "http://s43w.example/a" datasheets "r43w.pdf" || _rc43w=$?
unset STUB_DOWNLOAD_FAIL STUB_WGET_EMPTY
_row43w=false; [ -f "$d43w/sources/SOURCES.md" ] && grep -q 'r43w\.pdf' "$d43w/sources/SOURCES.md" && _row43w=true
if [ "$_rc43w" -ne 0 ] && [ "$(sum_of "$f43w")" = "$EVID_SUM" ] && ! $_row43w \
   && grep -qi 'empty body' "$TMP/runchain.err" && ! grep -qi 'ALSO failed' "$TMP/runchain.err"; then
  ok "doc: #1285 B1 — curl fail + wget empty 200 leaves the registered file intact, no row, says 'empty body'"
else no "R43w: rc=$_rc43w sum=$(sum_of "$f43w") row=$_row43w err='$(cat "$TMP/runchain.err")'"; fi

# 43x — message: curl fails and wget is NOT INSTALLED -> say so, not "wget fallback ALSO failed".
curlonly="$TMP/curlonly-bin"; mkdir -p "$curlonly"
for _t in bash env mkdir basename sed cut date awk mktemp mv rm sha256sum file grep cat dirname tr; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$curlonly/$_t"
done
ln -sf "$stubbin/curl" "$curlonly/curl"
d43x="$TMP/rr-43x/target"; f43x="$(mkexisting "$d43x" r43x.pdf)"
STUB_ROUTES=""; STUB_DOWNLOAD_FAIL=1; export STUB_ROUTES STUB_DOWNLOAD_FAIL
_rc43x=0; PATH="$curlonly" "$curlonly/bash" "$SUT" --replace doc "http://s43x.example/a" "$d43x" datasheets "r43x.pdf" >/dev/null 2>"$TMP/err43x.txt" || _rc43x=$?
unset STUB_DOWNLOAD_FAIL
if [ "$_rc43x" -ne 0 ] && [ "$(sum_of "$f43x")" = "$EVID_SUM" ] && grep -qi 'wget is not installed' "$TMP/err43x.txt" \
   && ! grep -qi 'ALSO failed' "$TMP/err43x.txt"; then
  ok "doc: #1285 — curl fails and wget is absent: message says 'wget is not installed', file intact"
else no "R43x: rc=$_rc43x sum=$(sum_of "$f43x") err='$(cat "$TMP/err43x.txt")'"; fi

# 43y — wget-ONLY path (curl absent): redirect resolution is skipped (no curl probe noise) and the
#      typed URL is registered with the "effective URL unknown" notice.
wgetonly="$TMP/wgetonly-bin"; mkdir -p "$wgetonly"
for _t in bash env mkdir basename sed cut date awk mktemp mv rm sha256sum file grep cat dirname tr; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$wgetonly/$_t"
done
ln -sf "$stubbin/wget" "$wgetonly/wget"
d43y="$TMP/rr-43y/target"; mkdir -p "$d43y"
_rc43y=0; PATH="$wgetonly" "$wgetonly/bash" "$SUT" doc "http://s43y.example/a.pdf" "$d43y" datasheets "r43y.pdf" >/dev/null 2>"$TMP/err43y.txt" || _rc43y=$?
if [ "$_rc43y" -eq 0 ] && [ "$(origin_of "$d43y/sources/SOURCES.md" 'r43y\.pdf')" = "http://s43y.example/a.pdf" ] \
   && grep -qi 'effective URL unknown' "$TMP/err43y.txt" && ! grep -qi 'redirect probe failed' "$TMP/err43y.txt" \
   && ! grep -qi 'command not found' "$TMP/err43y.txt"; then
  ok "doc: #1285 — wget-only path skips redirect resolution and registers the requested URL (effective URL unknown)"
else no "R43y: rc=$_rc43y origin='$(origin_of "$d43y/sources/SOURCES.md" 'r43y\.pdf')' err='$(cat "$TMP/err43y.txt")'"; fi

skip "R44w: a pandoc plus cp that die mid-write: cp is no longer a dependency (the fallback copy is in process); atomic placement is pinned by internal/sources/place tests and the differential web pandoc-fail scenarios"
skip "R48b: the English pdftoppm failure message lives in the Go source, exercised by the differential OCR scenarios (pdftoppm-fail)"
skip "R60: a TERM during install+register is deferred (slow sha256sum stub): the hash is computed in process now; the window is fetchdoc TestSignalAfterTheInstallPointIsIgnoredSoRowAndBytesAgree"
skip "R66: TERM during mktemp leaks no temp file: the Go command runs no mktemp; TMPDIR stays clean after a cancel in fetchdoc TestSignalMidConversionKillsPandocAndInstallsNothing"

# 44 — positive control: a SUCCESSFUL re-fetch replaces the file with the new bytes (the part-file
#      move actually happens) and leaves no part file behind.
d44="$TMP/rr-44/target"; f44="$(mkexisting "$d44" r44.pdf)"
STUB_ROUTES=""; export STUB_ROUTES
_rc44=0; RC_REPLACE=1 runchain doc "$d44" "http://s44.example/a" datasheets "r44.pdf" || _rc44=$?
_debris44="$(find "$d44/sources/datasheets" -name "*.fetchdoc-part.*" | wc -l | tr -d ' ')"
if [ "$_rc44" -eq 0 ] && grep -qF 'stub body for http://s44.example/a' "$f44" && [ "$_debris44" = "0" ]; then
  ok "doc: #1285 — a successful re-fetch replaces the file and leaves no part file"
else no "R44: rc=$_rc44 body='$(cat "$f44" 2>/dev/null)' debris=$_debris44"; fi
unset STUB_ROUTES
skip "R44b: fetch_and_register called directly cleans its own part file: internal/sources/download TestWgetFailureModesNameTheirCause, TestCurlFailureFallsBackToWgetOnTheTypedURL"

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
PATH="$stubbin:$PATH" setsid bash "$SUT" --replace doc "http://s45.example/a" "$d45" datasheets "r45.pdf" >/dev/null 2>&1 &
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
if command -v file >/dev/null 2>&1 && <<<"$(file -b "$_pdf_fixture" 2>/dev/null)" grep -qi pdf; then _pdf_ok=true; fi
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

# 71 — #1904/#1897: web snapshot names must not collide when two URLs share a long prefix. Two URLs that
#      agree on the first 80 slug chars used to map to ONE name (second fetch refused, names opaque). Now:
#      distinct names (readable head+tail + 12 hex of sha256(full URL)), deterministic, short URLs unchanged.
long71="http://s71.example/$(printf 'p%.0s' $(seq 1 90))"
d71="$TMP/r71/target"; STUB_ROUTES=""; export STUB_ROUTES
_rc71a=0; runchain web "$d71" "${long71}/first" || _rc71a=$?
_rc71b=0; runchain web "$d71" "${long71}/second" || _rc71b=$?
n71="$(find "$d71/sources/web-snapshots" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
rows71="$(grep -c 'web-snapshot' "$d71/sources/SOURCES.md" 2>/dev/null || true)"
if [ "$_rc71a" -eq 0 ] && [ "$_rc71b" -eq 0 ] && [ "$n71" = "2" ] && [ "$rows71" = "2" ]; then
  ok "web: #1904 — two URLs sharing an 80-char prefix get two distinct snapshots, two rows"
else no "R71: rc=$_rc71a/$_rc71b files=$n71 rows=$rows71 :: $(cat "$TMP/runchain.err")"; fi
# 71b — deterministic: re-fetching the SAME long URL targets the SAME name (typed refusal exit 4, not a new file)
_rc71c=0; runchain web "$d71" "${long71}/first" || _rc71c=$?
n71c="$(find "$d71/sources/web-snapshots" -type f -name '*.md' | wc -l | tr -d ' ')"
if [ "$_rc71c" -eq 4 ] && [ "$n71c" = "2" ]; then ok "web: #1904 — the same long URL maps to the same name (deterministic; refused, nothing new)"
else no "R71b: rc=$_rc71c files=$n71c"; fi
# 71c — edge: a short URL keeps the legacy name (no hash suffix)
d71d="$TMP/r71d/target"; runchain web "$d71d" "http://s71d.example/a" || true
if [ -f "$d71d/sources/web-snapshots/s71d.example_a.md" ]; then ok "web: #1904 — a short URL keeps its legacy snapshot name"
else no "R71c: legacy short name missing: $(ls "$d71d/sources/web-snapshots" 2>/dev/null)"; fi
# 71d — edge: the name keeps the URL TAIL readable and stays within a bounded length
tail71="$(find "$d71/sources/web-snapshots" -type f -name '*second*' | head -1)"
if [ -n "$tail71" ] && [ "$(basename "$tail71" | wc -c)" -le 90 ]; then ok "web: #1904 — long-URL name keeps the tail ('second') and a bounded length"
else no "R71d: tail not readable or name too long: $(ls "$d71/sources/web-snapshots")"; fi
# 71e — the HASH must carry the distinction: two long URLs that share the first 46 AND last 20 slug chars and
#       differ only in the middle (a=1 vs a=2) collide on head+tail alone; only the hash separates them.
mid71="http://s71e.example/$(printf 'p%.0s' $(seq 1 90))?a=%s&$(printf 'q%.0s' $(seq 1 30))/end"
d71e="$TMP/r71e/target"; STUB_ROUTES=""; export STUB_ROUTES
_rc71e1=0; runchain web "$d71e" "$(printf "$mid71" 1)" || _rc71e1=$?
_rc71e2=0; runchain web "$d71e" "$(printf "$mid71" 2)" || _rc71e2=$?
n71e="$(find "$d71e/sources/web-snapshots" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
rows71e="$(grep -c 'web-snapshot' "$d71e/sources/SOURCES.md" 2>/dev/null || true)"
if [ "$_rc71e1" -eq 0 ] && [ "$_rc71e2" -eq 0 ] && [ "$n71e" = "2" ] && [ "$rows71e" = "2" ]; then
  ok "web: #1904 — URLs differing only in the MIDDLE (same head and tail) get distinct snapshots via the hash"
else no "R71e: rc=$_rc71e1/$_rc71e2 files=$n71e rows=$rows71e :: $(cat "$TMP/runchain.err")"; fi
unset STUB_ROUTES
# 71f — boundary: a slug of exactly 80 chars is unchanged (no -<hex>); exactly 81 is hashed and the name is 80 chars
skip "R71f, R71g: the web_slug 80/81-char boundary and scheme-in-hash are pinned in Go: internal/sources/slug TestWebBoundaryAt80, TestWebHashCoversTheSchemeAndTheFullURL"
skip "R71h, R71i: no sha256 tool is no longer a dependency (the hash is computed in process): fetchdoc TestIntendedDivergences/no-sha256-tool-is-not-a-dependency"

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
  _slug10="web-snapshot"   # the only snapshot a refused fetch could leave (its name is derived inside the command)
  _dest10="$d10/sources/web-snapshots/$_slug10.md"
  _row10=false
  [ -f "$d10/sources/SOURCES.md" ] && grep -q "$_slug10" "$d10/sources/SOURCES.md" && _row10=true
  if [ "$_rc10" -ne 0 ] && ! $_row10; then
    ok "web empty-body: non-zero exit and no SOURCES.md row registered"
  else
    no "web empty-body: expected failure+no-row; got rc=$_rc10 row=$_row10 dest-exists=$([ -s "$_dest10" ] && echo yes || echo no) (err: $(cat "$TMP/err10.txt"))"
  fi

fi

# ─── #1313: cancellation, overwrite policy, symlinked DEST, stale part sweep ───
# Hermetic: the stub curl/wget on PATH, no network. sha12 <file> — first 12 hex of a file's sha256.
sha12(){ sha256sum "$1" 2>/dev/null | cut -c1-12; }
sut(){ PATH="$stubbin:$PATH" bash "$SUT" "$@"; }
# row_cell <sources-md> <file-cell> <col> — column <col> (1=File … 5=sha256) of the row whose File cell equals <file-cell>.
row_cell(){ awk -F'|' -v f="$2" -v c="$(( $3 + 1 ))" '{ x=$2; gsub(/^ +| +$/,"",x); if (x==f) { y=$c; gsub(/^ +| +$/,"",y); print y; exit } }' "$1" 2>/dev/null; }

# R50 — TERM delivered to the SCRIPT PID ONLY (not the group) mid-download: the download child must be
#       killed, so it can never finish and replace the registered file; exit 143; no part file; no new row.
#       Pre-fix the subshell kept running, finished and mv'd NEW bytes over the registered file.
# run_term_to_pid_only <script> <dir> <done-marker> <started-marker> — echoes the script's exit code.
run_term_to_pid_only(){
  local script="$1" dir="$2" done_m="$3" start_m="$4" pid rc=0
  rm -f "$done_m" "$start_m"
  STUB_ROUTES="" STUB_DOWNLOAD_HANG=1 STUB_HANG_SECS=2 STUB_HANG_MARKER="$start_m" STUB_HANG_DONE_MARKER="$done_m" \
    PATH="$stubbin:$PATH" bash "$script" --replace doc "http://s50.example/a" "$dir" datasheets "r50.pdf" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$start_m" ] && break; sleep 0.1; done
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || rc=$?
  sleep 2.5   # past the stub's 2 s: a download that was NOT cancelled has finished by now
  echo "$rc"
}
d50="$TMP/rr-50/target"; f50="$(mkexisting "$d50" r50.pdf)"
rc50="$(run_term_to_pid_only "$SUT" "$d50" "$TMP/done50.marker" "$TMP/start50.marker")"
_part50="$(find "$d50/sources" -name '*.fetchdoc-part.*' | wc -l | tr -d ' ')"
if [ -e "$TMP/start50.marker" ] && [ "$rc50" = "143" ] && [ "$(sum_of "$f50")" = "$EVID_SUM" ] \
   && [ ! -e "$TMP/done50.marker" ] && [ "$_part50" = "0" ] && [ ! -e "$d50/sources/SOURCES.md" ]; then
  ok "doc: #1313 — TERM to the script pid only kills the download; registered file intact, no part file, no row, exit 143"
else no "R50: rc=$rc50 sum=$(sum_of "$f50") download-finished=$([ -e "$TMP/done50.marker" ] && echo y || echo n) parts=$_part50 sources-md=$([ -e "$d50/sources/SOURCES.md" ] && echo y || echo n)"; fi

# seed51 <dir> <name> <url> — a real fetch through the stub: registers <name> with a row (the body is derived from <url>).
seed51(){ STUB_ROUTES="" sut doc "$3" "$1" datasheets "$2" >/dev/null 2>&1; }

# R51 — re-fetching a REGISTERED name without --replace is refused (exit 4, typed) BEFORE any download:
#       bytes and row untouched, curl never probed.
d51="$TMP/rr-51/target"; mkdir -p "$d51"; seed51 "$d51" r51.pdf "http://s51.example/old"
f51="$d51/sources/datasheets/r51.pdf"; sum51="$(sum_of "$f51")"; md51_before="$(cat "$d51/sources/SOURCES.md")"
: > "$TMP/probe51.txt"
_rc51=0; STUB_ROUTES="" STUB_PROBE_COUNT_FILE="$TMP/probe51.txt" sut doc "http://s51.example/new" "$d51" datasheets r51.pdf >/dev/null 2>"$TMP/err51.txt" || _rc51=$?
if [ "$_rc51" = "4" ] && grep -q 'REFUSED' "$TMP/err51.txt" && [ "$(sum_of "$f51")" = "$sum51" ] \
   && [ "$(cat "$d51/sources/SOURCES.md")" = "$md51_before" ] && [ ! -s "$TMP/probe51.txt" ]; then
  ok "doc: #1313 — re-fetch of an existing NAME without --replace is refused (exit 4) before any download; bytes+row untouched"
else no "R51: rc=$_rc51 err='$(cat "$TMP/err51.txt")' probes=$(wc -l < "$TMP/probe51.txt")"; fi

# R52 — --replace with DIFFERENT bytes: old bytes kept under <stem>.<sha12>.<ext>, the OLD row now names that file
#       (its sha still true), a NEW row registers NAME with the new sha — every row's sha matches its file.
d52="$TMP/rr-52/target"; mkdir -p "$d52"; seed51 "$d52" r52.pdf "http://s52.example/old"
f52="$d52/sources/datasheets/r52.pdf"; old12_52="$(sha12 "$f52")"; oldsha52="$(sum_of "$f52")"
_rc52=0; STUB_ROUTES="" sut --replace doc "http://s52.example/new" "$d52" datasheets r52.pdf >/dev/null 2>"$TMP/err52.txt" || _rc52=$?
v52="$d52/sources/datasheets/r52.$old12_52.pdf"; md52="$d52/sources/SOURCES.md"
if [ "$_rc52" = "0" ] && grep -qF 'stub body for http://s52.example/old' "$v52" 2>/dev/null \
   && grep -qF 'stub body for http://s52.example/new' "$f52" \
   && [ "$(row_cell "$md52" "datasheets/r52.$old12_52.pdf" 5)" = "$oldsha52" ] \
   && [ "$(row_cell "$md52" "datasheets/r52.pdf" 5)" = "$(sum_of "$f52")" ] \
   && [ "$(grep -c 'r52' "$md52")" = "2" ]; then
  ok "doc: #1313 — --replace keeps the old bytes under a versioned name, retargets the old row, registers the new bytes"
else no "R52: rc=$_rc52 versioned=$([ -e "$v52" ] && echo y || echo n) rows='$(grep 'r52' "$md52" | tr '\n' '/')' err='$(cat "$TMP/err52.txt")'"; fi

# R53 — --replace with IDENTICAL bytes archives nothing (the old row is still right).
d53="$TMP/rr-53/target"; mkdir -p "$d53"; seed51 "$d53" r53.pdf "http://s53.example/same"
_rc53=0; STUB_ROUTES="" sut --replace doc "http://s53.example/same" "$d53" datasheets r53.pdf >/dev/null 2>"$TMP/err53.txt" || _rc53=$?
if [ "$_rc53" = "0" ] && [ "$(find "$d53/sources/datasheets" -type f | wc -l | tr -d ' ')" = "1" ] && [ "$(grep -c r53 "$d53/sources/SOURCES.md")" = "1" ] && grep -qi identical "$TMP/err53.txt"; then
  ok "doc: #1313 — --replace with identical bytes keeps a single file (no versioned copy)"
else no "R53: rc=$_rc53 files=$(find "$d53/sources/datasheets" -type f | tr '\n' ' ')"; fi

# R54 — a SYMLINKED destination is refused (exit 5, typed), with or without --replace; the link target is untouched.
d54="$TMP/rr-54/target"; mkdir -p "$d54/sources/datasheets"; printf 'LINK-TARGET\n' > "$TMP/link54.txt"
ln -s "$TMP/link54.txt" "$d54/sources/datasheets/r54.pdf"
_rc54=0; STUB_ROUTES="" sut doc "http://s54.example/a" "$d54" datasheets r54.pdf >/dev/null 2>"$TMP/err54.txt" || _rc54=$?
_rc54r=0; STUB_ROUTES="" sut --replace doc "http://s54.example/a" "$d54" datasheets r54.pdf >/dev/null 2>"$TMP/err54r.txt" || _rc54r=$?
if [ "$_rc54" = "5" ] && [ "$_rc54r" = "5" ] && grep -qi 'symlink' "$TMP/err54.txt" && [ -L "$d54/sources/datasheets/r54.pdf" ] \
   && [ "$(cat "$TMP/link54.txt")" = "LINK-TARGET" ]; then
  ok "doc: #1313 — a symlinked DEST is refused with a typed error (exit 5), link and target untouched"
else no "R54: rc=$_rc54/$_rc54r err='$(cat "$TMP/err54.txt")'"; fi

# R55 — stale part files of DEAD pids are swept (with a notice); a part file of a LIVE pid is left alone.
d55="$TMP/rr-55/target"; mkdir -p "$d55/sources/datasheets"
_dead55=2999999; while kill -0 "$_dead55" 2>/dev/null; do _dead55=$((_dead55 + 1)); done
: > "$d55/sources/datasheets/old.pdf.fetchdoc-part.$_dead55"; : > "$d55/sources/datasheets/live.pdf.fetchdoc-part.$$"
_rc55=0; STUB_ROUTES="" sut doc "http://s55.example/a" "$d55" datasheets r55.pdf >/dev/null 2>"$TMP/err55.txt" || _rc55=$?
if [ "$_rc55" = "0" ] && [ ! -e "$d55/sources/datasheets/old.pdf.fetchdoc-part.$_dead55" ] && [ -e "$d55/sources/datasheets/live.pdf.fetchdoc-part.$$" ] \
   && grep -q "stale part file from dead pid $_dead55" "$TMP/err55.txt"; then
  ok "doc: #1313 — a dead pid's stale .part file is swept with a notice; a live pid's is kept"
else no "R55: rc=$_rc55 dead-left=$([ -e "$d55/sources/datasheets/old.pdf.fetchdoc-part.$_dead55" ] && echo y || echo n) live-left=$([ -e "$d55/sources/datasheets/live.pdf.fetchdoc-part.$$" ] && echo y || echo n)"; fi
rm -f "$d55/sources/datasheets/live.pdf.fetchdoc-part.$$"

# R56 — web mode follows the same policy: refuse without --replace (exit 4), keep old bytes with it.
d56="$TMP/rr-56/target"; mkdir -p "$d56"
STUB_ROUTES="" sut web "http://s56.example/page" "$d56" >/dev/null 2>&1
slug56="s56.example_page"
f56="$d56/sources/web-snapshots/$slug56.md"; old12_56="$(sha12 "$f56")"
_rc56=0; STUB_ROUTES="" sut web "http://s56.example/page" "$d56" >/dev/null 2>&1 || _rc56=$?
_rc56s=0; STUB_ROUTES="" STUB_DOWNLOAD_FAIL=1 STUB_WGET_FAIL=1 sut --replace web "http://s56.example/page" "$d56" >/dev/null 2>&1 || _rc56s=$?
if [ "$_rc56" = "4" ] && [ "$_rc56s" != "0" ] && [ "$(sha12 "$f56")" = "$old12_56" ]; then
  ok "web: #1313 — an existing snapshot is refused without --replace (exit 4) and survives a failed --replace"
else no "R56: rc=$_rc56 / failed-replace rc=$_rc56s sum-changed=$([ "$(sha12 "$f56")" = "$old12_56" ] && echo n || echo y)"; fi

# ─── #1313 fix-first round (Opus review): B1 sweep safety, B2 sha-scoped row retarget, N1/N2/N4/N7/N8 ───
# R57 — B1: a REGISTERED doc whose name happens to look like a part file (spec.part.<digits>, or the marker form)
#       must survive the sweep; its SOURCES.md row must not dangle.
d57="$TMP/rr-57/target"; mkdir -p "$d57"
seed51 "$d57" "spec.part.2999998" "http://s57.example/a"; seed51 "$d57" "spec.fetchdoc-part.2999998" "http://s57.example/b"
_rc57=0; STUB_ROUTES="" sut doc "http://s57.example/c" "$d57" datasheets r57.pdf >/dev/null 2>"$TMP/err57.txt" || _rc57=$?
if [ "$_rc57" = "0" ] && [ -e "$d57/sources/datasheets/spec.part.2999998" ] && [ -e "$d57/sources/datasheets/spec.fetchdoc-part.2999998" ]; then
  ok "doc: #1313 B1 — registered files named like part files survive the stale sweep"
else no "R57: rc=$_rc57 plain=$([ -e "$d57/sources/datasheets/spec.part.2999998" ] && echo y || echo n) marker=$([ -e "$d57/sources/datasheets/spec.fetchdoc-part.2999998" ] && echo y || echo n)"; fi

# R58 — B1: a pid we may not signal (pid 1, EPERM for non-root) is ALIVE, never "dead"; an old-style .part.<digits> name is not ours.
d58="$TMP/rr-58/target"; mkdir -p "$d58/sources/datasheets"
: > "$d58/sources/datasheets/x.pdf.part.1"; : > "$d58/sources/datasheets/y.pdf.fetchdoc-part.1"
_rc58=0; STUB_ROUTES="" sut doc "http://s58.example/a" "$d58" datasheets r58.pdf >/dev/null 2>&1 || _rc58=$?
if [ "$_rc58" = "0" ] && [ -e "$d58/sources/datasheets/x.pdf.part.1" ] && [ -e "$d58/sources/datasheets/y.pdf.fetchdoc-part.1" ]; then
  ok "doc: #1313 B1 — a part file of pid 1 (EPERM) and a non-marker .part.N name are never swept"
else no "R58: rc=$_rc58 old-style=$([ -e "$d58/sources/datasheets/x.pdf.part.1" ] && echo y || echo n) pid1=$([ -e "$d58/sources/datasheets/y.pdf.fetchdoc-part.1" ] && echo y || echo n)"; fi

# R59 — B2: legacy multi-row corpus (rows A and B both name r59.pdf; the file holds B). --replace C retargets ONLY the
#       row whose sha matches the archived bytes (B); the A row stays untouched and a warning names it.
d59="$TMP/rr-59/target"; mkdir -p "$d59/sources/datasheets"
printf 'B-BYTES\n' > "$d59/sources/datasheets/r59.pdf"; shaB59="$(sum_of "$d59/sources/datasheets/r59.pdf")"; shaA59="$(printf 'A-BYTES\n' | sha256sum | cut -d' ' -f1)"
printf '# External sources preserved\n\n| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |\n|---|---|---|---|---|---|\n| datasheets/r59.pdf | datasheets | http://s59.example/A | 2026-01-01T00:00:00Z | %s | |\n| datasheets/r59.pdf | datasheets | http://s59.example/B | 2026-02-01T00:00:00Z | %s | |\n' "$shaA59" "$shaB59" > "$d59/sources/SOURCES.md"
_rc59=0; STUB_ROUTES="" sut --replace doc "http://s59.example/C" "$d59" datasheets r59.pdf >/dev/null 2>"$TMP/err59.txt" || _rc59=$?
md59="$d59/sources/SOURCES.md"
if [ "$_rc59" = "0" ] && <<<"$(grep -F 'http://s59.example/B' "$md59")" grep -qF "datasheets/r59.${shaB59:0:12}.pdf" \
   && <<<"$(grep -F 'http://s59.example/A' "$md59")" grep -qF '| datasheets/r59.pdf |' && grep -qi 'different sha' "$TMP/err59.txt"; then
  ok "doc: #1313 B2 — --replace retargets only the row whose sha matches the archived bytes and warns about the other"
else no "R59: rc=$_rc59 rows='$(grep 'r59' "$md59" | cut -d'|' -f2,4 | tr '\n' '/')' err='$(cat "$TMP/err59.txt")'"; fi

# R61 — N4: the download child runs in its own process group and the whole GROUP is killed, so the grandchild
#       (the stub's sleep, standing in for a curl/wget helper) dies too — pkill -P of the direct child is not enough.
# run_grandchild <script> <dir> — TERM to the script pid mid-download; echoes the stub's grandchild sleep pid (killed
# afterwards if it is still alive, so a failing run leaves nothing behind) and "alive"/"dead" on the next line.
run_grandchild(){
  local script="$1" dir="$2" pid sp; rm -f "$TMP/sleep61.pid"
  STUB_ROUTES="" STUB_DOWNLOAD_HANG=1 STUB_HANG_SECS=30 STUB_HANG_MARKER="$TMP/start61.marker" STUB_HANG_PIDFILE="$TMP/sleep61.pid" \
    PATH="$stubbin:$PATH" bash "$script" doc "http://s61.example/a" "$dir" datasheets r61.pdf >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -s "$TMP/sleep61.pid" ] && break; sleep 0.1; done
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; sleep 0.3
  sp="$(cat "$TMP/sleep61.pid" 2>/dev/null)"
  # An empty pidfile means the stub never started: that is "unknown", never a pass.
  if [ -z "$sp" ]; then echo unknown; elif [ -d "/proc/$sp" ]; then echo alive; kill "$sp" 2>/dev/null; else echo dead; fi
}
d61="$TMP/rr-61/target"; mkdir -p "$d61"; _sp61="$(run_grandchild "$SUT" "$d61")"
if [ "$_sp61" = "dead" ]; then ok "doc: #1313 N4 — TERM to the script kills the download's whole process group (grandchild gone)"
else no "R61: grandchild state '$_sp61' (want dead; 'unknown' = the stub never wrote its pidfile)"; fi

# R64 — W1: web mode: a TERM during the pandoc conversion must NOT be ignored (ignored signals are inherited by the
#       child). The cancel takes effect before anything is installed: exit 143, no snapshot, no row, no part file.
slowpandoc="$TMP/slowpandoc-bin"; mkdir -p "$slowpandoc"
printf '#!/usr/bin/env bash\n[ -n "${PANDOC_MARK:-}" ] && : > "$PANDOC_MARK"\nsleep 3\nout=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done\n[ -n "$out" ] && echo converted > "$out"\nexit 0\n' > "$slowpandoc/pandoc"; chmod +x "$slowpandoc/pandoc"
# run_pandoc_term <script> <dir> — echoes the exit code after TERM-to-pid during a slow pandoc.
run_pandoc_term(){
  local script="$1" dir="$2" pid rc=0; rm -f "$TMP/pandoc64.mark"
  STUB_ROUTES="" PANDOC_MARK="$TMP/pandoc64.mark" PATH="$slowpandoc:$stubbin:$PATH" bash "$script" web "http://s64.example/page" "$dir" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$TMP/pandoc64.mark" ] && break; sleep 0.1; done
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || rc=$?
  echo "$rc"
}
d64="$TMP/rr-64/target"; mkdir -p "$d64"; _rc64="$(run_pandoc_term "$SUT" "$d64")"
_snap64="$(find "$d64/sources/web-snapshots" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ -e "$TMP/pandoc64.mark" ] && [ "$_rc64" = "143" ] && [ "$_snap64" = "0" ] && [ ! -e "$d64/sources/SOURCES.md" ]; then
  ok "web: #1313 W1 — TERM during the pandoc conversion cancels the run (exit 143, no snapshot, no row, no part file)"
else no "R64: rc=$_rc64 files=$_snap64 sources-md=$([ -e "$d64/sources/SOURCES.md" ] && echo y || echo n)"; fi

# R62 — N7: the versioned name is already taken by DIFFERENT bytes (or a dangling symlink): refuse, current bytes intact.
d62="$TMP/rr-62/target"; mkdir -p "$d62"; seed51 "$d62" r62.pdf "http://s62.example/old"
f62="$d62/sources/datasheets/r62.pdf"; o12_62="$(sha12 "$f62")"; sum62="$(sum_of "$f62")"
printf 'SOMETHING-ELSE\n' > "$d62/sources/datasheets/r62.$o12_62.pdf"
_rc62=0; STUB_ROUTES="" sut --replace doc "http://s62.example/new" "$d62" datasheets r62.pdf >/dev/null 2>"$TMP/err62.txt" || _rc62=$?
d62l="$TMP/rr-62l/target"; mkdir -p "$d62l"; seed51 "$d62l" r62.pdf "http://s62.example/old"; ln -s /nonexistent-target "$d62l/sources/datasheets/r62.$o12_62.pdf"
_rc62l=0; STUB_ROUTES="" sut --replace doc "http://s62.example/new" "$d62l" datasheets r62.pdf >/dev/null 2>&1 || _rc62l=$?
if [ "$_rc62" != "0" ] && [ "$_rc62l" != "0" ] && [ "$(sum_of "$f62")" = "$sum62" ] && [ "$(sum_of "$d62l/sources/datasheets/r62.pdf")" = "$sum62" ] && grep -qi 'refus' "$TMP/err62.txt"; then
  ok "doc: #1313 N7 — a taken versioned name (different bytes / dangling symlink) is refused, current bytes intact"
else no "R62: rc=$_rc62/$_rc62l err='$(cat "$TMP/err62.txt")'"; fi

# R63 — N8: web --replace SUCCEEDS: old snapshot kept under a versioned name, new content registered, rows consistent.
d63="$TMP/rr-63/target"; mkdir -p "$d63"
STUB_ROUTES="" sut web "http://s63.example/page" "$d63" >/dev/null 2>&1
slug63="s63.example_page"
f63="$d63/sources/web-snapshots/$slug63.md"; o12_63="$(sha12 "$f63")"; osum63="$(sum_of "$f63")"
_rc63=0; STUB_ROUTES="" STUB_BODY='<p>changed upstream</p>' sut --replace web "http://s63.example/page" "$d63" >/dev/null 2>"$TMP/err63.txt" || _rc63=$?
md63="$d63/sources/SOURCES.md"
if [ "$_rc63" = "0" ] && [ -e "$d63/sources/web-snapshots/$slug63.$o12_63.md" ] && [ "$(sum_of "$f63")" != "$osum63" ] \
   && [ "$(row_cell "$md63" "web-snapshots/$slug63.$o12_63.md" 5)" = "$osum63" ] && [ "$(row_cell "$md63" "web-snapshots/$slug63.md" 5)" = "$(sum_of "$f63")" ]; then
  ok "web: #1313 N8 — --replace keeps the old snapshot under a versioned name and registers the new one"
else no "R63: rc=$_rc63 err='$(cat "$TMP/err63.txt")' files=$(ls "$d63/sources/web-snapshots" | tr '\n' ' ')"; fi

# ─── #1354: signal windows, concurrent same-NAME, pandoc kill ───
# The SUT exposes a test seam: FETCHDOC_TEST_AT=<point> runs FETCHDOC_TEST_CMD in the MAIN shell at that exact spot
# (points: after-fork = between `&` and DL_PID=$!, install = start of install_file), so races are injected
# deterministically instead of with sleeps.

# R65 — N5a: TERM delivered exactly between the fork of the download child and DL_PID=$!. The child must still be
#       cancelled (pre-fix it was orphaned and ran to completion): exit 143, download never finishes, no debris.
# run_hook_term <script> <dir> <done-marker> — echoes the script's exit code.
run_hook_term(){
  local script="$1" dir="$2" done_m="$3" rc=0
  rm -f "$done_m"
  STUB_ROUTES="" STUB_DOWNLOAD_HANG=1 STUB_HANG_SECS=2 STUB_HANG_DONE_MARKER="$done_m" \
    FETCHDOC_TEST_SEAM=1 FETCHDOC_TEST_AT=after-fork FETCHDOC_TEST_CMD='kill -TERM $$' \
    PATH="$stubbin:$PATH" bash "$script" --replace doc "http://s65.example/a" "$dir" datasheets r65.pdf >/dev/null 2>&1 || rc=$?
  sleep 2.5   # past the stub's 2 s: an orphaned download has finished by now
  echo "$rc"
}
d65="$TMP/rr-65/target"; f65="$(mkexisting "$d65" r65.pdf)"
rc65="$(run_hook_term "$SUT" "$d65" "$TMP/done65.marker")"
_part65="$(find "$d65/sources" -name '*.fetchdoc-part.*' | wc -l | tr -d ' ')"
if [ "$rc65" = "143" ] && [ ! -e "$TMP/done65.marker" ] && [ "$_part65" = "0" ] && [ "$(sum_of "$f65")" = "$EVID_SUM" ] && [ ! -e "$d65/sources/SOURCES.md" ]; then
  ok "doc: #1354 N5 — TERM between the fork and DL_PID=\$! still cancels the download (exit 143, no orphan, no debris)"
else no "R65: rc=$rc65 orphan-finished=$([ -e "$TMP/done65.marker" ] && echo y || echo n) parts=$_part65"; fi

# R67 — N6: a concurrent run on the same NAME lands its file AFTER this run's preflight_dest but BEFORE its install.
#       Without --replace the second run must REFUSE (exit 4): the other run's bytes stay, nothing is archived,
#       no row is written (pre-fix it archived the other run's file and installed over it).
d67="$TMP/rr-67/target"; mkdir -p "$d67/sources/datasheets"
_rc67=0
STUB_ROUTES="" FETCHDOC_TEST_SEAM=1 FETCHDOC_TEST_AT=install FETCHDOC_TEST_CMD='printf "OTHER-RUN\n" > "$DEST"' \
  PATH="$stubbin:$PATH" bash "$SUT" doc "http://s67.example/a" "$d67" datasheets r67.pdf >/dev/null 2>"$TMP/err67.txt" || _rc67=$?
if [ "$_rc67" = "4" ] && [ "$(cat "$d67/sources/datasheets/r67.pdf")" = "OTHER-RUN" ] \
   && [ "$(find "$d67/sources" -type f | wc -l | tr -d ' ')" = "1" ] && grep -qi 'REFUSED' "$TMP/err67.txt"; then
  ok "doc: #1354 N6 — a file that appears after preflight is refused (exit 4) without --replace: not archived, not overwritten, no row"
else no "R67: rc=$_rc67 files=$(find "$d67/sources" -type f | tr '\n' ' ') err='$(cat "$TMP/err67.txt")'"; fi

# R67b — same race WITH --replace is still honoured: the other run's bytes are archived, the new bytes win.
d67b="$TMP/rr-67b/target"; mkdir -p "$d67b/sources/datasheets"
_rc67b=0; _o12_67b="$(printf 'OTHER-RUN\n' | sha256sum | cut -c1-12)"
STUB_ROUTES="" FETCHDOC_TEST_SEAM=1 FETCHDOC_TEST_AT=install FETCHDOC_TEST_CMD='printf "OTHER-RUN\n" > "$DEST"' \
  PATH="$stubbin:$PATH" bash "$SUT" --replace doc "http://s67.example/b" "$d67b" datasheets r67.pdf >/dev/null 2>&1 || _rc67b=$?
if [ "$_rc67b" = "0" ] && [ "$(cat "$d67b/sources/datasheets/r67.$_o12_67b.pdf" 2>/dev/null)" = "OTHER-RUN" ] \
   && grep -qF 'stub body for http://s67.example/b' "$d67b/sources/datasheets/r67.pdf"; then
  ok "doc: #1354 N6 — with --replace the late-appearing file is archived under a versioned name and the new bytes win"
else no "R67b: rc=$_rc67b files=$(ls "$d67b/sources/datasheets" | tr '\n' ' ')"; fi

# R67d — the concurrent run installed IDENTICAL bytes: still refused (exit 4) without --replace, and still no row.
src67d="$TMP/rr-67d-src/target"; mkdir -p "$src67d"; seed51 "$src67d" r67.pdf "http://s67d.example/a"
d67d="$TMP/rr-67d/target"; mkdir -p "$d67d/sources/datasheets"; _rc67d=0
STUB_ROUTES="" SRC67D="$src67d/sources/datasheets/r67.pdf" FETCHDOC_TEST_SEAM=1 FETCHDOC_TEST_AT=install FETCHDOC_TEST_CMD='cp "$SRC67D" "$DEST"' \
  PATH="$stubbin:$PATH" bash "$SUT" doc "http://s67d.example/a" "$d67d" datasheets r67.pdf >/dev/null 2>&1 || _rc67d=$?
if [ "$_rc67d" = "4" ] && [ "$(sum_of "$d67d/sources/datasheets/r67.pdf")" = "$(sum_of "$src67d/sources/datasheets/r67.pdf")" ] && [ ! -e "$d67d/sources/SOURCES.md" ]; then
  ok "doc: #1354 N6 — a concurrent run that installed identical bytes is still refused (exit 4) without --replace"
else no "R67d: rc=$_rc67d files=$(find "$d67d/sources" -type f | tr '\n' ' ')"; fi

# R67c — web mode shares the contract.
d67c="$TMP/rr-67c/target"; mkdir -p "$d67c/sources/web-snapshots"
slug67c="s67c.example_page"
_rc67c=0
STUB_ROUTES="" FETCHDOC_TEST_SEAM=1 FETCHDOC_TEST_AT=install FETCHDOC_TEST_CMD='printf "OTHER-RUN\n" > "$DEST"' \
  PATH="$stubbin:$PATH" bash "$SUT" web "http://s67c.example/page" "$d67c" >/dev/null 2>&1 || _rc67c=$?
if [ "$_rc67c" = "4" ] && [ "$(cat "$d67c/sources/web-snapshots/$slug67c.md")" = "OTHER-RUN" ] \
   && [ "$(find "$d67c/sources" -type f | wc -l | tr -d ' ')" = "1" ]; then
  ok "web: #1354 N6 — a snapshot that appears after preflight is refused (exit 4) without --replace"
else no "R67c: rc=$_rc67c files=$(find "$d67c/sources" -type f | tr '\n' ' ')"; fi

# R68 — item 5: a TERM during the pandoc conversion KILLS pandoc (pre-fix the run waited for pandoc to finish).
#       The stub writes a done marker only when it runs to completion; it must be absent after the run exits.
killpandoc="$TMP/killpandoc-bin"; mkdir -p "$killpandoc"
printf '#!/usr/bin/env bash\n: > "$PANDOC_MARK"\nsleep 3\n: > "$PANDOC_DONE"\nout=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done\n[ -n "$out" ] && echo converted > "$out"\nexit 0\n' > "$killpandoc/pandoc"; chmod +x "$killpandoc/pandoc"
# run_pandoc_kill <script> <dir> — echoes the exit code; leaves the done marker state for the caller.
run_pandoc_kill(){
  local script="$1" dir="$2" pid rc=0; rm -f "$TMP/pandoc68.mark" "$TMP/pandoc68.done"
  STUB_ROUTES="" PANDOC_MARK="$TMP/pandoc68.mark" PANDOC_DONE="$TMP/pandoc68.done" PATH="$killpandoc:$stubbin:$PATH" bash "$script" web "http://s68.example/page" "$dir" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$TMP/pandoc68.mark" ] && break; sleep 0.1; done
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || rc=$?
  sleep 3.5   # past the stub's 3 s: a pandoc that was NOT killed has finished by now
  echo "$rc"
}
d68="$TMP/rr-68/target"; mkdir -p "$d68"; rc68="$(run_pandoc_kill "$SUT" "$d68")"
if [ -e "$TMP/pandoc68.mark" ] && [ "$rc68" = "143" ] && [ ! -e "$TMP/pandoc68.done" ] && [ ! -e "$d68/sources/SOURCES.md" ] \
   && [ "$(find "$d68/sources/web-snapshots" -type f | wc -l | tr -d ' ')" = "0" ]; then
  ok "web: #1354 — TERM during the pandoc conversion kills pandoc itself (exit 143, conversion never completes, no debris)"
else no "R68: rc=$rc68 pandoc-completed=$([ -e "$TMP/pandoc68.done" ] && echo y || echo n)"; fi

# R69 — the test seam is TEST-ONLY: with FETCHDOC_TEST_AT and FETCHDOC_TEST_CMD set but WITHOUT the explicit opt-in
#       FETCHDOC_TEST_SEAM=1, the hook must be a no-op (CMD never runs). The positive control (SEAM=1) proves the
#       marker really is written when the seam is live, so "absent" is not vacuous.
d69="$TMP/rr-69/target"; mkdir -p "$d69"; d69p="$TMP/rr-69p/target"; mkdir -p "$d69p"
rm -f "$TMP/seam69.marker" "$TMP/seam69p.marker"
_rc69=0; STUB_ROUTES="" FETCHDOC_TEST_AT=install FETCHDOC_TEST_CMD=': > "$TMP_MARKER"' TMP_MARKER="$TMP/seam69.marker" \
  PATH="$stubbin:$PATH" bash "$SUT" doc "http://s69.example/a" "$d69" datasheets r69.pdf >/dev/null 2>&1 || _rc69=$?
_rc69p=0; STUB_ROUTES="" FETCHDOC_TEST_SEAM=1 FETCHDOC_TEST_AT=install FETCHDOC_TEST_CMD=': > "$TMP_MARKER"' TMP_MARKER="$TMP/seam69p.marker" \
  PATH="$stubbin:$PATH" bash "$SUT" doc "http://s69.example/a" "$d69p" datasheets r69.pdf >/dev/null 2>&1 || _rc69p=$?
if [ "$_rc69" = "0" ] && [ ! -e "$TMP/seam69.marker" ] && [ "$_rc69p" = "0" ] && [ -e "$TMP/seam69p.marker" ]; then
  ok "doc: #1354 — the test seam is a no-op without FETCHDOC_TEST_SEAM=1 (and live with it)"
else no "R69: no-optin rc=$_rc69 marker=$([ -e "$TMP/seam69.marker" ] && echo RAN || echo absent) / optin rc=$_rc69p marker=$([ -e "$TMP/seam69p.marker" ] && echo ran || echo ABSENT)"; fi

# R70 — the install-time symlink re-check: DEST becomes a symlink AFTER preflight (during the download). Both with and
#       without --replace the run must REFUSE (exit 5) and leave the link and its target untouched.
# run_late_symlink <script> <dir> <replace-flag-or-empty> — echoes the exit code; the link target is $TMP/link70.txt.
run_late_symlink(){
  local script="$1" dir="$2" rflag="$3" rc=0
  printf 'LINK-TARGET\n' > "$TMP/link70.txt"; mkdir -p "$dir/sources/datasheets"; rm -f "$dir/sources/datasheets/r70.pdf"
  STUB_ROUTES="" LINK70="$TMP/link70.txt" FETCHDOC_TEST_SEAM=1 FETCHDOC_TEST_AT=install FETCHDOC_TEST_CMD='ln -s "$LINK70" "$DEST"' \
    PATH="$stubbin:$PATH" bash "$script" ${rflag:+"$rflag"} doc "http://s70.example/a" "$dir" datasheets r70.pdf >/dev/null 2>&1 || rc=$?
  echo "$rc"
}
d70="$TMP/rr-70/target"; d70r="$TMP/rr-70r/target"
_rc70="$(run_late_symlink "$SUT" "$d70" "")"; _lk70a="$(cat "$TMP/link70.txt")"; _isl70=n; [ -L "$d70/sources/datasheets/r70.pdf" ] && _isl70=y
_rc70r="$(run_late_symlink "$SUT" "$d70r" "--replace")"; _lk70b="$(cat "$TMP/link70.txt")"; _isl70r=n; [ -L "$d70r/sources/datasheets/r70.pdf" ] && _isl70r=y
if [ "$_rc70" = "5" ] && [ "$_rc70r" = "5" ] && [ "$_lk70a" = "LINK-TARGET" ] && [ "$_lk70b" = "LINK-TARGET" ] && [ "$_isl70" = "y" ] && [ "$_isl70r" = "y" ] \
   && [ ! -e "$d70/sources/SOURCES.md" ] && [ ! -e "$d70r/sources/SOURCES.md" ]; then
  ok "doc: #1354 — a DEST that becomes a symlink during the download is refused (exit 5), link and target untouched, no row"
else no "R70: rc=$_rc70/$_rc70r target='$_lk70a'/'$_lk70b' link=$_isl70/$_isl70r"; fi


# ---- Teeth for the shim itself ----------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ] && [ "$SUT_IS_SHIM" = 1 ]; then
  echo "-- teeth: mutation controls for fetch-doc.sh (shim) --"
  # The retired controls sed the old script body, which is gone: each is a typed SKIP naming the Go tests that replace it.
  skip "teeth (old reg() mutants) end-of-table insert, ENVIRON vs awk -v: srcregistry TestInsertRow*, TestParseRows*, differential doc-registry-with-trailing-prose and doc-backslash-url"
  skip "teeth (old redirect resolver mutants) hop cap, probe method, permanent-only, scheme guard, loc guard, connect-class retry: internal/sources/redirect tests"
  skip "teeth (old fetch_and_register mutants) part file, empty guard, wget fallback, notices, -L, keep-part: internal/sources/download tests and differential doc-curl-*, doc-wget-*"
  skip "teeth (old install_file, --replace and sweep mutants) versioned names, sha-scoped retarget, exclusive link, symlink refusal, stale parts: internal/sources/place tests and differential doc-replace-*, doc-symlink-*, doc-stale-part-sweep"
  skip "teeth (old cancellation and test-seam mutants) group kill, signal windows, TERM during pandoc, seam opt-in: fetchdoc TestSignal*, TestSeam*, TestConcurrentWriterAtInstall"
  skip "teeth (old web_slug and sha256-probe mutants) 80-char boundary, constant hash, scheme in the hash, no sha256 tool: internal/sources/slug tests and TestIntendedDivergences/no-sha256-tool-is-not-a-dependency"
  # mkshim NAME [SEDEXPR] -> a (mutant) shim with the lib beside it, in a kit layout: $MUT/NAME/toolbelt
  mkshim() {
    local d="$MUT/$1/toolbelt"
    mkdir -p "$d/lib" && cp "$HERE/../lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh
    if [ -z "${2:-}" ]; then cp "$SUT" "$d/fetch-doc.sh"; return 0; fi
    mutant_sed "$SUT" "$d/fetch-doc.sh" "$2" >/dev/null 2>&1 || { no "teeth $1: could not build the mutant (refused by lib/mutant.sh)"; return 1; }
  }
  # the stub curl/wget answer every probe and download; --replace keeps the repeated run of a tooth idempotent
  export PATH="$stubbin:$PATH" STUB_ROUTES=""
  SHIM_LINE='^rsdd_exec sources fetch-doc "\$@"'
  GOODSHIM="$MUT/good/toolbelt/fetch-doc.sh"
  mkshim good "" || exit 2
  dT="$TMP/teeth-shim/target"; mkdir -p "$dT"
  if mkshim A 's#'"$SHIM_LINE"'#rsdd_exec sources fetch-doc#'; then
    tooth "teeth(shim-args): arguments no longer forwarded → no mode, a usage error instead of a download" 0 2 "$MUT/A/toolbelt/fetch-doc.sh" \
      --orig "$GOODSHIM" --good-has '^OK: ' -- bash @SUT@ --replace doc "http://shim.example/a.pdf" "$dT"
  fi
  if mkshim B 's#^rsdd_exec sources fetch-doc #rsdd_exec sources fetch-docs #'; then
    tooth "teeth(shim-command): wrong subcommand name → an unknown command, not a download" 0 2 "$MUT/B/toolbelt/fetch-doc.sh" \
      --orig "$GOODSHIM" --good-has '^OK: ' -- bash @SUT@ --replace doc "http://shim.example/a.pdf" "$dT"
  fi
  if mkshim F 's#^rsdd_exec sources #rsdd_exec source #'; then
    tooth "teeth(shim-group): wrong group name → an unknown group, not a download" 0 2 "$MUT/F/toolbelt/fetch-doc.sh" \
      --orig "$GOODSHIM" --good-has '^OK: ' -- bash @SUT@ --replace doc "http://shim.example/a.pdf" "$dT"
  fi
  mkdir -p "$TMP/teeth-shim-refuse/target/sources/datasheets"; printf 'REGISTERED\n' > "$TMP/teeth-shim-refuse/target/sources/datasheets/kept.pdf"
  if mkshim D 's#'"$SHIM_LINE"'#( rsdd_exec sources fetch-doc "$@" ); exit 0#'; then
    tooth "teeth(shim-exit): exit code laundered to 0 → a refused overwrite no longer fails the caller" 4 0 "$MUT/D/toolbelt/fetch-doc.sh" \
      --orig "$GOODSHIM" --good-has 'REFUSED' -- bash @SUT@ doc "http://shim.example/kept.pdf" "$TMP/teeth-shim-refuse/target"
  fi
  # the library guard: a shim with no lib beside it says so and exits 2; a mutant that exits 0 there hides a missing binary
  mkdir -p "$MUT/Cgood" "$MUT/C"
  cp "$SUT" "$MUT/Cgood/fetch-doc.sh"
  if mutant_sed "$SUT" "$MUT/C/fetch-doc.sh" 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#' >/dev/null 2>&1; then
    tooth "teeth(shim-guard): missing-library guard exits 0 → a missing rsdd reads as a successful fetch" 2 0 "$MUT/C/fetch-doc.sh" \
      --orig "$MUT/Cgood/fetch-doc.sh" --good-has 'rsdd-exec.sh missing' -- bash @SUT@ doc "http://shim.example/a.pdf" "$dT"
  else no "teeth(shim-guard): could not build the mutant (refused by lib/mutant.sh)"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
