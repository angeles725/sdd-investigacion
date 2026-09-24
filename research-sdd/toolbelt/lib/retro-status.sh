#!/usr/bin/env bash
# retro-status.sh — shared helper: read a §18 retro's review-status marker (METHODOLOGY §18).
# Sourced by sweep-retros.sh and stage-retro-issues.sh so both gate on IDENTICAL logic — the two
# scripts used to carry hand-copied awk pipelines that drifted (R1-003 / R3-004); this file is the
# single source of truth for the marker grammar.
#
#   retro_review_status <file>
#     Echoes the lowercased status word (applied/dismissed/pending/…) found in the retro's LEADING
#     HTML-comment block (the run of '<!--…' lines and blank lines before the first heading or prose
#     line).  Returns nothing when no such marker is present in the leading block.  Always returns 0.
#     Used by sweep-retros.sh; it intentionally skips markers placed after the H1 heading so that
#     only a properly-positioned leading-block marker gates the sweep.
#
#   retro_marker_line <file>
#     Echoes the raw first '<!-- review-status: ... -->' line from ANYWHERE in the file (unmodified).
#     Callers that need to inspect the full marker text (e.g. to extract PARTIAL / shipped IDs, or
#     to handle retros whose marker was placed after the H1 heading) use this function.
#     Returns nothing when no canonical marker is present. Always returns 0.
#     Retained for callers outside the kit issue #945 unification (none in this kit as of #945);
#     stage-retro-issues.sh now uses retro_marker_scope_line instead (see below).
#
#   retro_marker_scope_line <file>
#     Kit issue #945 — the ONE marker scope shared by reconcile-issues.sh, stage-retro-issues.sh
#     (the seeder), retro-gate.sh's _retro_is_seedable, and sweep-retros.sh. Echoes the raw first
#     '<!-- review-status: ... -->' line found in the retro's LEADING BLOCK, where the leading
#     block may optionally start with ONE H1 heading line ('# ...', never '##' or deeper) before
#     the run of comment/blank lines — the real-corpus layout in *-closure.md retros (H1 line 1,
#     blank line 2, marker line 3). A marker positioned deeper in the body — after a second
#     heading, inside a fenced code block, or quoted in prose — is out of scope and this function
#     returns nothing for it. Returns nothing (exit 0) when no marker is found within scope.
#
# Scanning algorithms:
#   retro_review_status — LEADING-BLOCK-ONLY, NO H1 tolerance: awk stops at the first
#     non-comment, non-blank line (an '# heading' line included). Anchors on '<!--' so a bare
#     'review-status:' in heading prose is ignored (R1-001). Pre-#945 callers only; kept for any
#     consumer outside the four instruments #945 unified (verify-retro.sh's own inline copy,
#     research-sdd-archive.sh's format lint, stage-retro.sh, sweep-audits.sh).
#
#   retro_marker_line — WHOLE-FILE: grep the entire file for '<!--[space]*review-status:'.
#     The '<!--' anchor prevents false matches from heading prose (R1-001 preserved). This is
#     MORE permissive than the #945 shared scope (any position, not just the leading block) —
#     no longer used by any of the four #945-unified instruments.
#
#   retro_marker_scope_line — LEADING-BLOCK-WITH-OPTIONAL-H1 (kit issue #945): like
#     retro_review_status, but the very first line is allowed to be a single '#' H1 heading
#     (skipped, not counted as the block terminator) before the leading comment/blank run is
#     scanned. A second heading, or any non-blank/non-comment prose, still terminates the scan.
#     This is the ONE scope reconcile-issues.sh, stage-retro-issues.sh, retro-gate.sh, and
#     sweep-retros.sh now share — narrower than retro_marker_line's whole-file scan, wider than
#     retro_review_status's no-H1-tolerance scan.
#
# retro_is_excluded, retro_is_waived, retro_has_bare_marker keep LEADING-BLOCK-ONLY algorithms
# because their semantics require a definite leading-block position (opt-out scope, waiver, format
# lint).

# Idempotent: safe to source more than once (both SUTs may pull it in the same shell in tests).
if ! declare -F retro_review_status >/dev/null 2>&1; then
  # retro_status_from_marker_line <line>
  #   R2-001 — SINGLE extraction point: extracts the lowercased status word from a raw
  #   '<!-- review-status: <word> …' marker line.  Returns nothing when no marker pattern
  #   is found.  Always returns 0.
  #
  #   Used by retro_review_status (below) and by stage-retro-issues.sh to avoid duplicating
  #   the grep/sed/tr pipeline.  Never hand-copy this pipeline; call this function instead.
  retro_status_from_marker_line() {
    local line="${1:-}"
    [ -n "$line" ] || return 0
    printf '%s' "$line" \
      | grep -oiE '<!--[[:space:]]*review-status:[[:space:]]*[a-z]+' \
      | head -1 \
      | sed -E 's/.*:[[:space:]]*//' \
      | tr 'A-Z' 'a-z'
    return 0
  }

  retro_review_status() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 0
    # Leading-block-only awk scan: stops at first non-comment, non-blank line.
    # Anchored on '<!--' so a bare 'review-status:' in heading prose is not matched (R1-001).
    # sweep-retros.sh relies on this leading-block contract; do not change to whole-file here.
    # pipefail-audit: external `awk` over the leading block of a single retro file. SAFE.
    local _leading_marker
    _leading_marker="$(awk '
      /^[[:space:]]*<!--/ { print; next }
      /^[[:space:]]*$/     { next }
      { exit }
    ' "$f" 2>/dev/null \
      | grep -iE '<!--[[:space:]]*review-status:' \
      | head -1)"
    retro_status_from_marker_line "$_leading_marker"
    return 0
  }

  # retro_marker_line <file>
  #   WHOLE-FILE scan (fenced-block-aware): returns the raw first '<!-- review-status: … -->'
  #   line from anywhere in the file, provided it appears at line start (optional leading
  #   whitespace before '<!--').  Markers quoted mid-line (e.g. inside a table cell or inline
  #   code) are NOT matched.  Lines inside fenced code blocks (``` or ~~~) are skipped so that
  #   documented examples of marker syntax are not mistaken for real markers.
  #
  #   Unlike retro_review_status (leading-block-only), this function finds markers placed after
  #   the H1 heading — the real-corpus layout in *-closure.md retros.
  #   Returns nothing when no canonical marker is present. Always returns 0.
  #
  # STAGE_RETRO_ISSUES_MARKER_LINE: stage-retro-issues.sh uses retro_marker_line as the single
  # definition of "what the marker line looks like and where to find it". Both the status word
  # (applied/dismissed/pending) and the PARTIAL/shipped inspection are derived from this one call.
  # pipefail-audit: external `awk` over a single retro file (fleet max ~50 KB). SAFE.
  retro_marker_line() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 0
    # awk state: fence=1 inside a fenced code block (``` or ~~~); tolower for case-insensitive
    # match; anchored to line start so mid-line quoted markers are skipped (R2-002).
    # RETRO_MARKER_LINE_AWK: anchor tag for Tooth M7 and M8.
    awk '
      /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
      fence { next }
      { if (tolower($0) ~ /^[[:space:]]*<!--[[:space:]]*review-status:/) { print; exit } }
    ' "$f" 2>/dev/null
    return 0
  }

  # retro_marker_scope_line <file>
  #   Kit issue #945 — the ONE marker scope shared by reconcile-issues.sh, stage-retro-issues.sh
  #   (the seeder), retro-gate.sh's _retro_is_seedable, and sweep-retros.sh. See the file header
  #   for the full rationale of why this scope replaces the two that used to disagree.
  #
  #   Algorithm: an awk state machine over the LEADING BLOCK, tolerating exactly one H1 line at
  #   the very start (NR==1 only — a heading on any later line is NOT skipped, so 'H1, blank, H2,
  #   blank, marker' correctly falls OUT of scope: the H2 on line 3 is ordinary non-blank,
  #   non-comment content and terminates the scan). After the optional H1, blank lines and
  #   '<!--...' comment lines are collected exactly like retro_review_status; the first genuinely
  #   non-blank, non-comment line (prose, a second heading, a fenced-block opener, …) ends the
  #   scan. Because the scan always stops there, content further down the file — a quoted example
  #   marker in prose, or one sitting inside a ``` fenced block — is structurally unreachable and
  #   needs no separate fence-awareness pass (unlike retro_marker_line's whole-file scan).
  #
  #   RETRO_MARKER_SCOPE_H1_SKIP: anchor for the kit issue #945 teeth proof.
  #   pipefail-audit: external `awk` over the leading few lines of a single retro file. SAFE.
  retro_marker_scope_line() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 0
    awk '
      NR==1 && /^[[:space:]]*#[^#]/ { next }
      NR==1 && /^[[:space:]]*#[[:space:]]*$/ { next }
      /^[[:space:]]*<!--/ { print; next }
      /^[[:space:]]*$/     { next }
      { exit }
    ' "$f" 2>/dev/null \
      | grep -iE '^[[:space:]]*<!--[[:space:]]*review-status:' \
      | head -1
    return 0
  }

  # retro_is_excluded <file>
  #   Returns 0 (true) when the file's leading HTML-comment block carries the OPT-OUT scope marker
  #   '<!-- kit-retro: exclude -->' (exact value, case-insensitive).  Returns 1 otherwise.
  #
  # Consumers: sweep-retros.sh (pending pass + MISSING-RETRO fleet pass), stage-retro.sh (refuses
  # with exit 2), and research-sdd-archive.sh (retros mirror-fact count + MISSING-RETRO check).
  #
  # Design: OPT-OUT means INCLUDE by default. A genuine §18 retro with NO marker is correctly
  # supervised. Only a file that is explicitly NOT a §18 kit retro (e.g. a client-feedback retro
  # living in corpus/retros/) carries the marker to opt out. This fails NOISILY when the marker is
  # absent (the file surfaces as a false-positive PENDING item, visible and self-correcting) rather
  # than SILENTLY (an unmarked genuine retro would become invisible — the exact failure mode the §18
  # supervision loop exists to eliminate). Scans the same leading-block region as retro_review_status
  # so the two share a consistent definition of "leading block".
  #
  # The grep is FULL-LINE ANCHORED ('^...$') so a comment that merely QUOTES or MENTIONS the marker
  # in its prose (a longer line) does NOT trigger the opt-out. Do NOT apply this same anchoring to
  # retro_review_status (review-status markers intentionally carry trailing content like the date and
  # kit sha — they are never a full line by themselves).
  retro_is_excluded() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 1
    awk '
      /^[[:space:]]*<!--/ { print; next }
      /^[[:space:]]*$/     { next }
      { exit }
    ' "$f" 2>/dev/null \
      | grep -qiE '^[[:space:]]*<!--[[:space:]]*kit-retro:[[:space:]]*exclude[[:space:]]*-->[[:space:]]*$'
      # pipefail-audit: external `awk` producer (leading HTML-comment block of a retro file).
      # Fleet max 414 B (2026-07-06-kit-audit.md). Race onset: ~64 KB. Fleet max << onset; SAFE.
  }

  # retro_is_waived <file>
  #   Returns 0 (true) when the file's leading HTML-comment block carries a
  #   '<!-- retro-waived: <date> · <reason> -->' marker, signalling a DELIBERATE decision
  #   not to reconstruct a retro for that target.  Returns 1 otherwise.
  #
  # Convention: create a file under <target>/retros/ (e.g. 'retro-waived.md') that carries
  # BOTH '<!-- kit-retro: exclude -->' (so sweep-retros.sh does not count it as a pending §18
  # retro) AND '<!-- retro-waived: <date> · <reason> -->'.  sweep-retros.sh detects a waived
  # target in the MISSING-RETRO fleet pass by scanning its retros/ files for this marker.
  # A waived target is suppressed from MISSING-RETRO and counted separately in the sweep
  # summary (e.g. 'waived: 1') so the suppression is never invisible.
  #
  # Design: OPT-OUT (same reasoning as retro_is_excluded). A missing waiver means the target
  # is monitored by default. Deleting the waiver file makes the MISSING-RETRO line reappear —
  # self-correcting, never silent. Scans the same leading-block region as retro_review_status
  # and retro_is_excluded so all three share a consistent definition of "leading block".
  retro_is_waived() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 1
    awk '
      /^[[:space:]]*<!--/ { print; next }
      /^[[:space:]]*$/     { next }
      { exit }
    ' "$f" 2>/dev/null \
      | grep -qiE '^[[:space:]]*<!--[[:space:]]*retro-waived:[[:space:]]*[^[:space:]>][^>]*-->[[:space:]]*$'
      # pipefail-audit: same awk producer as retro_is_excluded. Fleet max 414 B. SAFE.
  }

  # retro_has_bare_marker <file>
  #   Returns 0 (true) when the file's first 10 lines carry a bare (non-HTML-comment) line
  #   matching `^[[:space:]]*review-status:` — a malformed marker that should be wrapped in
  #   `<!-- review-status: ... -->`. Returns 1 otherwise.
  #
  # Consumers: research-sdd-archive.sh format lint — distinguishes "malformed" from "absent".
  # Algorithm: identical to the inline `head -10 | grep` the archive previously carried; routing
  # it here makes lib/retro-status.sh the SINGLE definition of "review-status presence" logic
  # (U11 centralisation). Uses head -10 (not the awk leading-block scan) to preserve byte-identical
  # fleet output — the two scanning strategies can differ on edge cases (see design.md D-3 note).
  retro_has_bare_marker() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 1
    head -10 "$f" 2>/dev/null | grep -qiE '^[[:space:]]*review-status:'
    # pipefail-audit: external `head -10` producer. Fleet max 1,170 B across all retro files.
    # Race onset for external producers: ~64 KB. Fleet max << onset; SAFE.
  }

  # retro_marker_is_partial <marker_line>
  #   Returns 0 (true) when EITHER:
  #     (a) the marker's STRUCTURED metadata segment — the portion BEFORE the first free-text
  #         separator (a spaced em dash '—', the 'shipped:' keyword, or an opening parenthesis)
  #         — carries the case-SENSITIVE whole-word token PARTIAL, or
  #     (b) the literal, case-sensitive keyword 'shipped:' (canonical lowercase form) appears
  #         anywhere in the line.
  #   Returns 1 (false) given an empty line, or when neither condition holds.
  #
  #   Kit issue #1090: PARTIAL is a STATUS TOKEN, never free text. The previous check
  #   (`grep -qiE 'PARTIAL|shipped:'`, case-INSENSITIVE, over the WHOLE line) let lowercase
  #   prose like "(P1 partial)" inside a dismissed marker's free-text segment falsely trip
  #   PARTIAL handling — a dismissed retro whose explanation happens to mention "partial" then
  #   reopened every row. Cutting the line at the first free-text separator BEFORE the
  #   case-sensitive PARTIAL check (condition a) means prose after that point (any case,
  #   anywhere) can never be mistaken for the status token — even without the caller's own
  #   'dismissed always wins' guard (both stage-retro-issues.sh and reconcile-issues.sh add that
  #   guard independently; this function is the shared first line of defense).
  #
  #   Condition (b) is intentionally UNSCOPED (whole line, not just the structured segment): the
  #   real corpus carries applied markers that write "shipped: 1, 2" WITHOUT the literal PARTIAL
  #   token at all (e.g. "applied · sha · shipped: #1, #2") — 'shipped:' is itself already a
  #   specific, lowercase, structurally-meaningful keyword (never a word that shows up by
  #   accident in free-text prose the way "partial" can), so it was never the source of the
  #   #1090 false-positive and narrowing it would silently stop treating those retros as
  #   PARTIAL, wrongly leaving every one of their shipped rows open forever.
  #
  #   RETRO_MARKER_PARTIAL_STRUCTURED_CUT: anchor for the kit issue #1090 teeth proof.
  retro_marker_is_partial() {
    local line="${1:-}"
    [ -n "$line" ] || return 1
    if printf '%s' "$line" | grep -q 'shipped:'; then
      return 0
    fi
    local body="$line"
    body="${body#*review-status:}"
    body="${body%%-->*}"
    local structured
    structured="$(printf '%s' "$body" | sed -E 's/(—|shipped:|\().*$//')"
    printf '%s' "$structured" | grep -qE '(^|[^A-Za-z])PARTIAL($|[^A-Za-z])'
  }

  # retro_marker_shipped_ids <shipped_raw>
  #   Given the raw text captured after a marker's 'shipped:' keyword (e.g. "#1, #2" or
  #   "Δ1 (#549), D1 (§20)" or "P1-P5"), echoes the normalized, expanded set of shipped
  #   row-ids, one per line:
  #     - a trailing parenthetical annotation (" (#549)", " (§20)") is dropped first — it is
  #       descriptive text, never part of the id (kit issue #949 item 1)
  #     - a leading '#' is stripped from each remaining token (kit issue #949 item 1 — markers
  #       write "shipped: #1, #2" the way reconcile-issues.sh's row markers do elsewhere)
  #     - an "<prefix><n>-<prefix><n>" range (e.g. "P1-P5") is expanded to one id per line
  #   Returns nothing (exit 0) when given an empty string. Single source of truth for both
  #   stage-retro-issues.sh and reconcile-issues.sh — the two used to carry hand-copied awk
  #   pipelines that drifted (stage-retro-issues.sh never got the '#'-strip fix reconcile-issues.sh
  #   already had).
  #
  #   RETRO_MARKER_SHIPPED_IDS_HASH_STRIP / RETRO_MARKER_SHIPPED_IDS_PAREN_STRIP: anchors for the
  #   kit issue #949 teeth proofs.
  retro_marker_shipped_ids() {
    local raw="${1:-}"
    [ -n "$raw" ] || return 0
    printf '%s' "$raw" \
      | sed -E 's/[[:space:]]*\([^)]*\)//g' \
      | awk '{
          n = split($0, tokens, /[,[:space:]]+/)
          for (i=1; i<=n; i++) {
            t = tokens[i]
            if (t == "") continue
            sub(/^#/, "", t)
            if (t == "") continue
            if (match(t, /^([A-Za-z]*)([0-9]+)-([A-Za-z]*)([0-9]+)$/, m)) {
              pfx1=m[1]; n1=int(m[2]); pfx2=m[3]; n2=int(m[4])
              if (pfx1 == pfx2) {
                for (j=n1; j<=n2; j++) printf "%s%d\n", pfx1, j
              } else { printf "%s\n", t }
            } else { printf "%s\n", t }
          }
        }'
    return 0
  }
fi
