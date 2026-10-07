#!/usr/bin/env bash
# fetch-doc.sh — downloads and PRESERVES external sources (datasheets, manuals,
# forums, links) inside TARGET/sources/ with a traceable record in SOURCES.md.
# fetch-doc downloads and registers; page-anchored extraction is extract-pdf.sh's job.
# Research-SDD rule: URLs die; evidence does not.
#
# Usage:
#   fetch-doc.sh doc <url> <target-dir> [datasheets|manuals] [name]
#   fetch-doc.sh web <url> <target-dir>          # page/forum -> markdown (pandoc); long URLs get a hash-suffixed name (web_slug)
#   fetch-doc.sh ocr <pdf>                        # OCR of a scanned PDF (tesseract); --replace is ignored
#   fetch-doc.sh --replace doc|web ...            # --replace may appear anywhere in the argument list
#
# Overwrite policy (kit issue #1313 item 2 — "evidence does not die"): doc and web mode REFUSE (exit 4,
# before any download) when the destination file already exists. Re-fetching the same NAME would replace
# the registered bytes and leave the OLD SOURCES.md row with a stale sha256 (verify-sources LEVEL 6 would
# then fail on evidence that was fine). With --replace the old bytes are KEPT: the existing file is renamed
# to a versioned name (<stem>.<first 12 hex of its sha256>.<ext>, or <name>.<12 hex> without an extension),
# its row's File cell is rewritten to that name (its sha stays correct), and the new bytes are registered
# under NAME with a new row. Re-fetching IDENTICAL bytes archives nothing (the old row is still right).
# A symlinked destination is REFUSED (exit 5, typed): the old behaviour wrote THROUGH the link, the
# current one would silently replace the link with a regular file; neither is evidence-safe.
# Part files are named "<dest>.fetchdoc-part.<pid>" (an unambiguous marker: a registered document may
# legitimately be called "spec.part.123"). Part files left by SIGKILL are swept at start, but ONLY that
# marker pattern, never a file that is a File cell in SOURCES.md, and only when the pid is positively dead
# (/proc/<pid> absent, or `ps -p` finds nothing): a pid we may not signal (EPERM) is ALIVE.
# Cancellation (#1313 item 1): the download runs as a tracked background child in its OWN process group
# (`set -m`) and the script waits on it; INT/TERM delivered to the script pid alone kill that whole group
# (curl/wget included; a stderr notice is printed if the group cannot be signalled and only the child pid is
# killed) and exit 130/143. The downloaded part file is moved into place by the MAIN shell only after the
# download succeeded, and INT/TERM are ignored from that point on until the row is written, so a cancelled
# run can never replace a registered file nor leave a row that disagrees with it (a signal that arrives in
# that last window is deliberately dropped: the window is only the install + sha256 + row write, never a
# download or a pandoc conversion, so the run completes consistently; in web mode the pandoc conversion is
# itself a tracked child in its own process group, so a signal during it kills pandoc, before anything is
# installed). INT/TERM in the unavoidable pre-tracking windows (mktemp, fork -> DL_PID) are recorded, not acted
# on, and honoured the moment the child is tracked (#1354), so no child is orphaned and no temp file leaks.
# Concurrent runs on the same NAME (#1354): install_file re-checks the destination right before installing; without
# --replace the install is exclusive (hard link: atomic, fails if the file appeared) and refuses with exit 4.
# A SIGKILL of the script's own process group (e.g. `timeout -k`) no longer reaches the download child, which
# runs in its own process group: the orphan can install nothing (only the main shell moves the part file) and
# its "<dest>.fetchdoc-part.<pid>" file is swept by a later run once its pid is dead.
# --replace row retargeting is sha-scoped: only a row whose File cell AND sha256 match the archived bytes is
# rewritten; other rows for the same File (legacy corpora) are left untouched with a stderr warning. If the
# versioned name is already taken by different bytes, or is a symlink, the run REFUSES (exit 1) and keeps
# the current bytes. --replace with byte-identical content registered already adds no duplicate row.
# `ocr` takes no --replace (the flag is accepted anywhere and ignored for ocr).
# TEST-ONLY: FETCHDOC_TEST_SEAM=1 + FETCHDOC_TEST_AT/FETCHDOC_TEST_CMD inject code at fixed points (_test_hook); the
# test suite uses them to reproduce races deterministically. They are inert without FETCHDOC_TEST_SEAM=1.
# Exit codes: 1 failure, 2 usage, 3 missing dependency, 4 destination exists (no --replace),
# 5 symlinked destination.
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

# head_never_reached_host <head_rc> <time_connect> — true when a failed HEAD probe demonstrably never reached a live
# host, so the GET retry cannot do better: curl exit 6 (cannot resolve) or 7 (cannot connect) always; exit 28 (timed
# out) ONLY when %{time_connect} is zero, i.e. the connect phase never completed (round-5 N2'/N3'). Exit 28 with a
# nonzero time_connect means the host accepted the connection and the RESPONSE then hung: the retry is worth it.
head_never_reached_host() {
  local skip_fallback=0
  case "$1" in
    6|7) skip_fallback=1 ;;  # SENTINEL-CONNECT-SKIP: DNS/connect failure — never reached the host
    28)
      case "$2" in
        0|0.000000|0.000000000|"") skip_fallback=1 ;;  # never connected — skip the retry
      esac
      ;;
  esac
  [ "$skip_fallback" -eq 1 ]
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
  local cur="$1" hop=0 probe code loc head_rc head_time_connect rest
  local max_hops=10  # SENTINEL-MAXHOPS-VALUE (bounded hop loop — kit review PR #1155 round 2/3)
  local max_time=20  # SENTINEL-MAX-TIME (curl --max-time per hop, round 3 RS1 — bound a hanging probe)
  local connect_timeout=10  # SENTINEL-CONNECT-TIMEOUT (round-4 N3 — bounds the connect/TLS phase
  # separately from --max-time, so a connect-level failure can be told apart from a slow response)
  # SENTINEL-HOP-BOUND: the loop below must stop once `hop` reaches this bound — a chain of
  # permanent redirects longer than max_hops is followed only up to the cap, never indefinitely
  # (round-3 RS3: a genuine A<->B redirect LOOP never satisfies any other break condition, so
  # this bound is the ONLY thing that terminates it).
  while [ "$hop" -lt "$max_hops" ]; do
    # SENTINEL-PROBE-METHOD (round-3 RS1, round-4 N2/N3, round-5 N2'/N3'): HEAD first, not GET —
    # a GET probe downloads and discards the full response body on every hop, doubling transfer
    # cost for a large manual or PDF. HEAD is treated as a DEFINITIVE answer only for a redirect
    # code (301/302/303/307/308) or a real 2xx; anything else — 4xx, 5xx, 000/malformed, or empty
    # — is retried via a GET probe capped to a zero-byte range (`-r 0-0`), since some CDN/S3
    # fronts answer HEAD with e.g. 403 while GET on the SAME url is a genuine redirect (N2). The
    # retry is skipped only when the HEAD probe demonstrably never reached a live host: curl exit
    # 6 (could not resolve host) or 7 (could not connect) are unambiguous; exit 28 ("Operation
    # timed out") is NOT — it also fires when the connect succeeded and the RESPONSE then hung
    # past --max-time, where the host IS reachable and the retry is worth it. `%{time_connect}`
    # disambiguates the two: a connect phase that never completed reports 0 (round-5 N2'/N3' —
    # round-4 treated ALL of 6/7/28 as connect-stage, which wrongly skipped the retry for a slow
    # but reachable server).
    # SENTINEL-HEAD-GUARD: `&&`/`||` on the assignment (not an if/then/else) so that whatever
    # curl DID manage to write to stdout before failing (e.g. %{time_connect} on a mid-response
    # timeout) is PRESERVED rather than discarded — this is also exempt from `set -e` regardless
    # of whether the caller's errexit propagates into this function's call context (see
    # fetch_and_register's own doc comment on inherit_errexit), so a HEAD probe that fails
    # outright can never abort the script.
    probe="$(curl -sS -I -o /dev/null --connect-timeout "$connect_timeout" --max-time "$max_time" -w '%{http_code} %{time_connect} %{redirect_url}' "$cur")" && head_rc=0 || head_rc=$?
    head_time_connect="0"
    if [ -n "$probe" ]; then
      code="${probe%% *}"; rest="${probe#* }"
      head_time_connect="${rest%% *}"
      loc="${rest#* }"
      probe="$code $loc"
    fi
    code="${probe%% *}"
    case "$code" in
      301|302|303|307|308|2??) : ;;  # HEAD gave a definitive answer — use it as-is
      *)
        if head_never_reached_host "$head_rc" "$head_time_connect"; then
          probe=""
        else
          # SENTINEL-PROBE-FALLBACK-GET
          probe="$(curl -sS -o /dev/null --connect-timeout "$connect_timeout" --max-time "$max_time" -r 0-0 -w '%{http_code} %{redirect_url}' "$cur")" || probe=""
        fi
        ;;
    esac
    code="${probe%% *}"; loc="${probe#* }"
    if [ -z "$code" ]; then
      # SENTINEL-PROBE-FAIL-NOTICE: the redirect probe produced no usable HTTP response — either
      # BOTH the HEAD probe and its GET fallback failed outright (network error, timeout,
      # malformed URL), OR (round-5 N3') the HEAD probe failed at the CONNECT stage (exit 6/7, or
      # 28 with a zero `%{time_connect}`) and the GET fallback was skipped entirely — ONLY the
      # HEAD probe was actually attempted in that case. Either way, `cur` (the last successfully
      # resolved PERMANENT url — the ORIGINAL typed url on the very first hop) is kept; this is a
      # probe-level failure, distinct from a non-redirect terminal response (200/404/...), which
      # needs no notice at all — it is simply "done".
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
  local url="$1" final="$2" keep_part="${3:-}" effective
  # SENTINEL-PART-FILE (kit issue #1285 item 1): NEVER download straight into <dest-file> — a
  # failed or partial transfer (curl mid-transfer error, wget -O truncation, an empty 200) would
  # destroy an ALREADY-REGISTERED file whose SOURCES.md row then points at evidence that is gone
  # ("URLs die; evidence does not"). Every download lands in a SIBLING part file ($dest below) and
  # is moved over <dest-file> only once it is confirmed non-empty. `$$` is the SCRIPT's pid even
  # inside this command-substitution subshell, so the main dispatch's trap removes the same name.
  local dest="$final.fetchdoc-part.$$"
  # Only curl can resolve permanent redirects (the HEAD/GET probe is curl-only); without it the
  # typed url is used as-is and wget is the sole downloader.
  if have_cmd curl; then effective="$(resolve_permanent_redirect "$url")"; else effective="$url"; fi
  # SENTINEL-DOWNLOAD: the single shared download call — `-L` is load-bearing (round-3 RS2): the
  # PERMANENT-resolved url may still sit behind one more (temporary) hop to reach the bytes, and
  # without `-L` curl saves the REDIRECT RESPONSE itself as the "document", not the real content.
  if have_cmd curl && curl -fsS -L "$effective" -o "$dest"; then
    # SENTINEL-EMPTY-GUARD (round-4 N4, moved here by #1285): a 200 response can still carry an
    # EMPTY body. Reject it BEFORE the move, so it can never replace an existing registered file
    # and the success notice below is never printed for a fetch that registers nothing — the
    # false-success shape round-2 N1 fixed on the wget path, reappearing on the success path.
    if [ ! -s "$dest" ]; then
      rm -f "$dest"
      echo "fetch-doc: empty body: $url" >&2
      exit 1
    fi
    # SENTINEL-KEEP-PART (#1313 item 1): with --keep-part the MAIN shell moves the part file into place
    # (so a cancelled run never does it from a detached subshell); direct callers still get the move.
    if [ "$keep_part" != "--keep-part" ]; then
      mv -f "$dest" "$final" || { rm -f "$dest"; echo "fetch-doc: could not move download into place: $final" >&2; exit 1; }
    fi
    if [ "$effective" != "$url" ]; then
      printf 'fetch-doc: registered %s (permanent redirect from %s)\n' "$effective" "$url" >&2
    fi
    printf '%s' "$effective"
  else
    rm -f "$dest"  # a curl failure may have left a partial part file; wget starts from scratch
    # SENTINEL-WGET-GUARD (round-4 RDD): wget's own exit status is checked EXPLICITLY (see the
    # errexit note above) — a failing wget must never be treated as a successful fallback. On
    # failure, NOTHING is registered: no "registered ..." line of any kind, a typed failure
    # notice instead, and a non-zero exit from THIS subshell — which the caller's own
    # `EFFECTIVE_URL="$(fetch_and_register ...)"` assignment (running under REAL `set -e`, since
    # that call site is not itself inside another command substitution) turns into an immediate
    # script abort, exactly like any other failed command substitution assignment.
    local wget_rc=-1  # -1 = wget was not run (not installed)
    if have_cmd wget; then wget -q "$url" -O "$dest" && wget_rc=0 || wget_rc=$?; fi
    # SENTINEL-WGET-EMPTY-GUARD (#1285 review B1): wget can exit 0 with an EMPTY body; that must
    # never replace a registered file (the part file is moved only when non-empty).
    if [ "$wget_rc" -eq 0 ] && [ -s "$dest" ]; then
      if [ "$keep_part" != "--keep-part" ]; then
        mv -f "$dest" "$final" || { rm -f "$dest"; echo "fetch-doc: could not move download into place: $final" >&2; exit 1; }
      fi
      echo "fetch-doc: registered requested URL (wget fallback; effective URL unknown)" >&2
      printf '%s' "$url"
    else
      # SENTINEL-WGET-CLEANUP (round-5 R1, reworked by #1285): real `wget -O` CREATES or TRUNCATES
      # its target even when the request itself fails. That target is now the PART file, so the
      # registered <dest-file> is never touched; this removes the part file so no debris is left
      # in the target's evidence tree (this `exit 1` also skips every caller-side cleanup).
      rm -f "$dest"
      # Say what actually happened (#1285 review): not installed / empty 200 / wget itself failed.
      if [ "$wget_rc" -eq -1 ]; then
        echo "fetch-doc: curl failed and wget is not installed for $url; nothing registered" >&2
      elif [ "$wget_rc" -eq 0 ]; then
        echo "fetch-doc: empty body: $url (wget fallback); nothing registered" >&2
      else
        echo "fetch-doc: wget fallback ALSO failed for $url; nothing registered" >&2
      fi
      exit 1
    fi
  fi
}

# have_cmd <name> — true when <name> resolves on PATH.
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# probe_downloaders — runtime-dependency probe (kit CLAUDE.md §7, issue #1285 item 3). With NEITHER
# curl nor wget the run can only fail, and "wget fallback ALSO failed" would hide the real cause:
# emit a typed DEGRADED error naming the missing tools instead. Exit 3 matches the tesseract probe.
probe_downloaders() {
  if ! have_cmd curl && ! have_cmd wget; then
    echo "fetch-doc: DEGRADED: neither curl nor wget is installed — cannot download; nothing registered" >&2
    exit 3
  fi
}

# pid_alive <pid> — positive liveness: /proc/<pid> exists (Linux) or `ps -p` finds it. NEVER `kill -0`: that
# fails with EPERM for another user's pid, which would read as "dead". With neither /proc nor ps, assume alive.
pid_alive() {
  if [ -d /proc/self ]; then [ -d "/proc/$1" ]
  elif have_cmd ps; then ps -p "$1" >/dev/null 2>&1
  else return 0; fi
}

# has_row <file-cell> [<sha256>] — true when SOURCES.md has a row whose File cell equals <file-cell> (and, when
# given, whose sha256 cell equals <sha256>). ENVIRON, not `awk -v`, so a backslash survives (see reg()).
has_row() {
  local md="$SDIR/SOURCES.md"
  [ -f "$md" ] || return 1
  F="$1" S="${2:-}" awk -F'|' '
    /^[[:space:]]*\|/ { c=$2; s=$6; gsub(/^[ \t]+|[ \t]+$/,"",c); gsub(/^[ \t]+|[ \t]+$/,"",s)
      if (c==ENVIRON["F"] && (ENVIRON["S"]=="" || s==ENVIRON["S"])) found=1 }
    END { exit !found }' "$md"
}

# sweep_stale_parts <dir> — removes "*.fetchdoc-part.<pid>" files in <dir> whose pid is positively dead (#1313
# item 4: a SIGKILLed run cannot run its EXIT trap, and verify-sources would keep reporting the debris as
# "unregistered on disk"). Never touches a file registered in SOURCES.md, nor a part file of a live pid.
sweep_stale_parts() {
  local f pid
  for f in "$1"/*.fetchdoc-part.*; do
    [ -e "$f" ] || continue
    pid="${f##*.fetchdoc-part.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    has_row "${f#"$SDIR"/}" && continue  # SENTINEL-SWEEP-REGISTERED-GUARD: registered evidence is never debris
    if ! pid_alive "$pid"; then
      rm -f "$f"
      echo "fetch-doc: removed stale part file from dead pid $pid: ${f##*/}" >&2
    fi
  done
}

# preflight_dest <dest> — refuse a symlinked destination (exit 5) and, unless --replace was given, an
# existing one (exit 4); both BEFORE any download, so a refusal costs no network and changes nothing.
preflight_dest() {
  local dest="$1"
  if [ -L "$dest" ]; then
    echo "fetch-doc: REFUSED: destination is a symlink: $dest — remove it or choose another name; nothing fetched" >&2
    exit 5
  fi
  if [ -e "$dest" ] && [ "$REPLACE" -eq 0 ]; then
    echo "fetch-doc: REFUSED: destination already exists: $dest — re-run with --replace to keep the old bytes under a versioned name; nothing fetched" >&2
    exit 4
  fi
}

# rename_row <sources-md> <old-file-cell> <new-file-cell> <old-sha> — rewrites the File cell of the row whose
# File cell equals <old-file-cell> AND whose sha256 cell equals <old-sha>. Other rows for the same File (legacy
# corpora) are left untouched and counted in a stderr warning. ENVIRON, not `awk -v` (see reg()).
rename_row() {
  local md="$1" tmp
  [ -f "$md" ] || return 0
  tmp="$(mktemp)"
  OLD="$2" NEW="$3" SHA="$4" awk 'BEGIN{FS=OFS="|"}
    { if ($0 ~ /^[[:space:]]*\|/) { c=$2; s=$6; gsub(/^[ \t]+|[ \t]+$/,"",c); gsub(/^[ \t]+|[ \t]+$/,"",s)
        if (c==ENVIRON["OLD"]) { if (s==ENVIRON["SHA"]) $2=" " ENVIRON["NEW"] " "; else other++ } } print }
    END { if (other>0) printf "fetch-doc: WARNING: %d other row(s) for %s carry a different sha256 than the archived bytes and were left untouched\n", other, ENVIRON["OLD"] > "/dev/stderr" }
  ' "$md" > "$tmp" && mv "$tmp" "$md"  # SENTINEL-RENAME-ROW-WRITE
}

# install_file <part> <dest> — moves <part> over <dest>. When <dest> exists (only reachable with --replace)
# and its bytes differ, the old bytes are first kept under a versioned name and their row retargeted.
# Sets INSTALL_SAME=1 (and drops <part>) when the bytes are identical AND already registered: no new row.
INSTALL_SAME=0
# _test_hook <point> — TEST-ONLY seam (#1354). A no-op unless FETCHDOC_TEST_SEAM=1 is set explicitly; then, when
# FETCHDOC_TEST_AT names <point>, FETCHDOC_TEST_CMD is eval'd in the MAIN shell at that exact spot, so a signal or a
# concurrent writer can be injected deterministically (no sleeps). Never set these variables in production.
_test_hook() { [ "${FETCHDOC_TEST_SEAM:-}" = "1" ] || return 0; [ "${FETCHDOC_TEST_AT:-}" = "$1" ] || return 0; eval "${FETCHDOC_TEST_CMD:-:}"; }
install_file() {
  local part="$1" dest="$2" oldsha newsha base stem ext vname vpath rel
  INSTALL_SAME=0
  _test_hook install
  rel="${dest#"$SDIR"/}"
  # N6 (#1354): preflight_dest ran BEFORE the download, so a concurrent run on the same NAME may have landed a file
  # (or a symlink) since. Re-check here: a symlink is always refused, and an existing file is archived ONLY with --replace.
  if [ -L "$dest" ]; then
    echo "fetch-doc: REFUSED: destination became a symlink during the download: $dest; nothing installed" >&2
    exit 5
  fi
  if [ "$REPLACE" -eq 1 ] && [ -e "$dest" ]; then  # SENTINEL-INSTALL-REPLACE-GUARD
    oldsha="$(sha256sum "$dest" | cut -d' ' -f1)"; newsha="$(sha256sum "$part" | cut -d' ' -f1)"
    if [ "$oldsha" = "$newsha" ]; then
      if has_row "$rel" "$newsha"; then
        rm -f "$part"; INSTALL_SAME=1
        echo "fetch-doc: identical bytes already registered for $rel; nothing replaced, no new row" >&2
        return 0
      fi
    else
      base="${dest##*/}"
      case "$base" in
        *.*) stem="${base%.*}"; ext=".${base##*.}" ;;
        *)   stem="$base"; ext="" ;;
      esac
      vname="$stem.${oldsha:0:12}$ext"; vpath="${dest%/*}/$vname"
      if [ -L "$vpath" ]; then
        echo "fetch-doc: REFUSED: versioned name is a symlink: $vpath — the current bytes are kept; remove it and re-run" >&2
        exit 1
      fi
      if [ -e "$vpath" ]; then
        # A->B->A->B: the same bytes may already be archived there; anything else must NOT be destroyed or merged.
        if [ "$(sha256sum "$vpath" | cut -d' ' -f1)" != "$oldsha" ]; then  # SENTINEL-VNAME-COMPARE
          echo "fetch-doc: REFUSED: versioned name already holds DIFFERENT bytes: $vpath — the current bytes are kept" >&2
          exit 1
        fi
        rm -f "$dest"
      else
        mv -f "$dest" "$vpath"
      fi
      rename_row "$SDIR/SOURCES.md" "$rel" "${rel%/*}/$vname" "$oldsha"
      echo "fetch-doc: replaced $dest; old bytes kept as $vname" >&2
    fi
  fi
  if [ "$REPLACE" -eq 0 ]; then
    # SENTINEL-INSTALL-EXCL: without --replace the install must be EXCLUSIVE. A hard link fails atomically when
    # <dest> exists (a file that appears between the re-check above and here still cannot be overwritten).
    if ln "$part" "$dest" 2>/dev/null; then rm -f "$part"; return 0; fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      echo "fetch-doc: REFUSED: destination appeared during the download: $dest — re-run with --replace to keep the old bytes under a versioned name; nothing installed" >&2
      exit 4
    fi
    # ln failed for another reason (e.g. a filesystem without hard links): fall back to the plain move below.
  fi
  mv -f "$part" "$dest" || { rm -f "$part"; echo "fetch-doc: could not move download into place: $dest" >&2; exit 1; }
}

# download_into <url> <final> — runs fetch_and_register as a TRACKED background child in its own process group
# and waits, so INT/TERM to this script's pid alone can cancel it (cancel_download kills the GROUP). Leaves the
# verified part file at <final>.fetchdoc-part.$$ (NOT moved: the caller moves it from this shell) and sets
# EFFECTIVE_URL.
DL_PID=""; DL_OUT=""
cancel_download() {
  if [ -n "$DL_PID" ]; then
    if kill -0 "$DL_PID" 2>/dev/null; then
      # SENTINEL-KILL-GROUP: `set -m` made the child a process-group leader, so -PID is its whole group.
      if ! kill -TERM -- "-$DL_PID" 2>/dev/null; then
        echo "fetch-doc: could not signal the download's process group; falling back to the child pid only" >&2
        if have_cmd pkill; then pkill -TERM -P "$DL_PID" 2>/dev/null || true; fi
        kill -TERM "$DL_PID" 2>/dev/null || true
      fi
    fi
    wait "$DL_PID" 2>/dev/null || true
    DL_PID=""
  fi
  [ -z "$DL_OUT" ] || rm -f "$DL_OUT"
}
# Signal windows (#1354 N5): between the fork and `DL_PID=$!` (and around the mktemp) the child is not yet tracked,
# so an immediate cancel would orphan it. defer_cancel makes INT/TERM only RECORD themselves (CANCEL_PENDING);
# arm_cancel_traps restores the real handlers; run_cancellable then acts on a recorded signal once DL_PID is known.
# Handlers (unlike an ignore) are reset to default in the forked child, so the child stays killable.
CANCEL_PENDING=0
arm_cancel_traps() { trap 'cancel_download; exit 130' INT; trap 'cancel_download; exit 143' TERM; }
defer_cancel() { CANCEL_PENDING=0; trap 'CANCEL_PENDING=130' INT; trap 'CANCEL_PENDING=143' TERM; }
# run_cancellable <stdout-file> <cmd...> — runs <cmd> as the TRACKED background child (own process group, so the
# whole group is killed on cancel) and waits for it; returns its exit status. The caller must have called
# defer_cancel before any step it wants covered; this arms the real traps as soon as DL_PID is set.
run_cancellable() {
  local out="$1" rc=0; shift
  if [ "$CANCEL_PENDING" -ne 0 ]; then arm_cancel_traps; cancel_download; exit "$CANCEL_PENDING"; fi
  set -m
  "$@" >"$out" </dev/null &
  _test_hook after-fork
  DL_PID=$!
  set +m
  arm_cancel_traps
  if [ "$CANCEL_PENDING" -ne 0 ]; then cancel_download; exit "$CANCEL_PENDING"; fi
  wait "$DL_PID" || rc=$?
  DL_PID=""
  return "$rc"
}
download_into() {
  local rc=0
  defer_cancel
  DL_OUT="$(mktemp)"
  run_cancellable "$DL_OUT" fetch_and_register "$1" "$2" --keep-part || rc=$?
  if [ "$rc" -ne 0 ]; then rm -f "$DL_OUT"; exit "$rc"; fi
  EFFECTIVE_URL="$(cat "$DL_OUT")"; rm -f "$DL_OUT"; DL_OUT=""
}

# convert_html <html> <out> — pandoc html->gfm into <out>, falling back to a plain copy (also when pandoc is absent).
convert_html() {
  if have_cmd pandoc; then pandoc -f html -t gfm "$1" -o "$2" 2>/dev/null || cp "$1" "$2"
  else cp "$1" "$2"; fi
}

# web_slug <url> — snapshot file stem for web mode (#1904/#1897). The scheme-less URL with every character outside
# [A-Za-z0-9._-] turned into "_". Slugs of <= 80 chars are returned UNCHANGED (existing short-URL names stay
# stable). A longer slug used to be cut to its first 80 chars, so two URLs sharing that prefix collided on one
# name; now it becomes <first 46>_<last 20>-<first 12 hex of sha256(FULL URL)> (head AND tail stay readable, the
# hash makes the name distinct and deterministic per URL, 80 chars total). Two DIFFERENT short URLs that only
# differ in replaced characters ("a/b" vs "a_b") still share a name; preflight_dest then REFUSES (exit 4).
web_slug() {
  local slug h
  slug="$(printf '%s' "$1" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g')"
  if [ "${#slug}" -le 80 ]; then printf '%s' "$slug"; return 0; fi
  h="$(printf '%s' "$1" | sha256sum | cut -c1-12)"
  printf '%s_%s-%s' "${slug:0:46}" "${slug: -20}" "$h"
}

# Main dispatch is guarded so the file can be SOURCED to unit-test reg(), resolve_permanent_redirect()
# and fetch_and_register() in isolation (tests/fetch-doc.test.sh) without triggering a network
# fetch. When sourced, BASH_SOURCE[0] != $0, so nothing below runs.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
REPLACE=0; _args=()
for _a in "$@"; do if [ "$_a" = "--replace" ]; then REPLACE=1; else _args+=("$_a"); fi; done
set -- ${_args[@]+"${_args[@]}"}
MODE="${1:?usage: fetch-doc.sh [--replace] doc|web|ocr ...}"

case "$MODE" in
  ocr)
    PDF="${2:?pdf required}"
    command -v tesseract >/dev/null || { echo "tesseract not installed" >&2; exit 3; }
    OCR_DIR="$(mktemp -d)"; trap 'rm -rf "$OCR_DIR"' EXIT
    pdftoppm -r 300 -png "$PDF" "$OCR_DIR/ocr" >/dev/null 2>&1 || { echo "pdftoppm failed" >&2; exit 3; }
    for img in "$OCR_DIR"/ocr-*.png; do tesseract "$img" stdout 2>/dev/null; done
    ;;
  doc)
    URL="${2:?url}"; TDIR="${3:?target-dir}"; SUB="${4:-datasheets}"
    probe_downloaders
    SDIR="$TDIR/sources"; mkdir -p "$SDIR/$SUB"
    NAME="${5:-$(basename "${URL%%\?*}")}"; DEST="$SDIR/$SUB/$NAME"
    # SENTINEL-TRAP (#1285 item 2): Ctrl-C/TERM mid-download must not leave a partial file. Only
    # the PART file is removed — $DEST may be an already-registered file and is never touched.
    # #1313: INT/TERM also cancel the tracked download child (cancel_download) before exiting.
    trap 'cancel_download; rm -f "$DEST.fetchdoc-part.$$"' EXIT; trap 'cancel_download; exit 130' INT; trap 'cancel_download; exit 143' TERM
    preflight_dest "$DEST"; sweep_stale_parts "$SDIR/$SUB"
    # SENTINEL-DOC-RESOLVE (round-3 RR1): doc mode's own call into the shared resolve+download+
    # register-value pipeline — this is the specific wiring a doc-mode-only mutant must prove
    # matters, mirroring SENTINEL-WEB-RESOLVE below.
    download_into "$URL" "$DEST"   # sets EFFECTIVE_URL
    # SENTINEL-SIGNAL-BLOCK (#1313 N2): from here to the written row a signal must not leave new bytes without a row.
    trap '' INT TERM
    install_file "$DEST.fetchdoc-part.$$" "$DEST"
    SHA="$(sha256sum "$DEST" | cut -d' ' -f1)"
    # When the saved file is a PDF, recommend the canonical page-anchored extraction tool.
    # pdftotext -layout produces a FLAT .txt with NO page anchors — blocks cannot cite
    # page/section from it (§5). Page-anchored extraction belongs to extract-pdf.sh, which
    # produces sources/extracted/<name>.md with YAML front-matter (METHODOLOGY.md §5/§15).
    # fixed under #1444: process substitution, no producer | grep -q pipe, so no SIGPIPE race is possible.
    if grep -qi pdf < <(file -b "$DEST"); then
      printf 'hint: PDF saved. For page-anchored citations (§5), run: extract-pdf.sh "%s"  (a flat pdftotext dump has no page anchors and must not be cited).\n' "$DEST" >&2
    fi
    if [ "$INSTALL_SAME" -eq 1 ]; then
      echo "OK: $URL -> $DEST  (identical bytes already registered; no new row)"
    else
      reg "$SDIR" "$DEST" "$SUB" "$EFFECTIVE_URL" "$SHA"
      echo "OK: $URL -> $DEST  (sha256 ${SHA:0:16}…, registered in SOURCES.md)"
    fi
    ;;
  web)
    URL="${2:?url}"; TDIR="${3:?target-dir}"
    probe_downloaders
    SDIR="$TDIR/sources"; mkdir -p "$SDIR/web-snapshots"
    SLUG="$(web_slug "$URL")"
    DEST="$SDIR/web-snapshots/$SLUG.md"
    # Refuse BEFORE mktemp so a refusal leaves nothing behind (#1313 items 2-3).
    preflight_dest "$DEST"; sweep_stale_parts "$SDIR/web-snapshots"
    HTML="$(mktemp)"
    # SENTINEL-TRAP (#1285 item 2): the mktemp HTML (and its part file) must not leak when a later
    # cp/pandoc/sha256sum/reg step fails or the run is interrupted. #1313: INT/TERM also cancel the download.
    trap 'cancel_download; rm -f "$HTML" "$HTML.fetchdoc-part.$$" "$DEST.fetchdoc-part.$$"' EXIT; trap 'cancel_download; exit 130' INT; trap 'cancel_download; exit 143' TERM
    # SENTINEL-WEB-RESOLVE (round-1 R1): web mode registers URLs exactly the same way doc mode
    # does — the D4 evidence (cloudflare/retros/2026-08-28-ztna-focus-close.md) is 4 redirected
    # Cloudflare DOC URLs, and every one of those rows is type web-snapshot (fetched via THIS
    # mode, not doc). Round 3: now the SAME shared call as doc mode, not a parallel copy.
    download_into "$URL" "$HTML"   # sets EFFECTIVE_URL
    mv -f "$HTML.fetchdoc-part.$$" "$HTML"
    # SENTINEL-WEB-ATOMIC (#1285 review): write the snapshot to a part file and move it into place,
    # so a pandoc/cp that dies mid-write cannot truncate an already-registered snapshot.
    WPART="$DEST.fetchdoc-part.$$"
    # #1354: the conversion is a tracked child in its own process group, so a TERM kills pandoc itself (the old
    # foreground call only acted on the signal once pandoc returned); the EXIT trap removes $WPART.
    defer_cancel
    run_cancellable /dev/null convert_html "$HTML" "$WPART"
    # Block signals only NOW, after the conversion (#1313 W1): ignored signals are inherited across exec, so
    # blocking before pandoc would make it uncancellable.
    trap '' INT TERM  # SENTINEL-SIGNAL-BLOCK (#1313 N2): see doc mode
    install_file "$WPART" "$DEST"
    rm -f "$HTML"
    SHA="$(sha256sum "$DEST" | cut -d' ' -f1)"
    if [ "$INSTALL_SAME" -eq 1 ]; then
      echo "OK: $URL -> $DEST  (identical snapshot already registered; no new row)"
    else
      reg "$SDIR" "$DEST" "web-snapshot" "$EFFECTIVE_URL" "$SHA"
      echo "OK: $URL -> $DEST  (snapshot markdown, registered)"
    fi
    ;;
  *) echo "unknown mode: $MODE (doc|web|ocr)" >&2; exit 2 ;;
esac
fi
