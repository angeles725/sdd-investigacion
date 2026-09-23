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
#     Used by stage-retro-issues.sh for both status detection and PARTIAL extraction.
#
# Scanning algorithms:
#   retro_review_status — LEADING-BLOCK-ONLY: awk stops at the first non-comment, non-blank line.
#     Anchors on '<!--' so a bare 'review-status:' in heading prose is ignored (R1-001).
#     sweep-retros.sh uses this function and expects body-position markers to be invisible.
#
#   retro_marker_line — WHOLE-FILE: grep the entire file for '<!--[space]*review-status:'.
#     The '<!--' anchor prevents false matches from heading prose (R1-001 preserved).
#     stage-retro-issues.sh uses this to detect markers placed after the H1 heading (real-corpus
#     layout: H1 on line 1, blank on line 2, marker on line 3 in *-closure.md retros).
#
# retro_is_excluded, retro_is_waived, retro_has_bare_marker keep LEADING-BLOCK-ONLY algorithms
# because their semantics require a definite leading-block position (opt-out scope, waiver, format
# lint).

# Idempotent: safe to source more than once (both SUTs may pull it in the same shell in tests).
if ! declare -F retro_review_status >/dev/null 2>&1; then
  retro_review_status() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 0
    # Leading-block-only awk scan: stops at first non-comment, non-blank line.
    # Anchored on '<!--' so a bare 'review-status:' in heading prose is not matched (R1-001).
    # sweep-retros.sh relies on this leading-block contract; do not change to whole-file here.
    # pipefail-audit: external `awk` over the leading block of a single retro file. SAFE.
    awk '
      /^[[:space:]]*<!--/ { print; next }
      /^[[:space:]]*$/     { next }
      { exit }
    ' "$f" 2>/dev/null \
      | grep -oiE '<!--[[:space:]]*review-status:[[:space:]]*[a-z]+' \
      | head -1 \
      | sed -E 's/.*:[[:space:]]*//' \
      | tr 'A-Z' 'a-z'
    return 0
  }

  # retro_marker_line <file>
  #   WHOLE-FILE scan: returns the raw first '<!-- review-status: … -->' line from anywhere in the
  #   file.  Unlike retro_review_status (leading-block-only), this function finds markers placed
  #   after the H1 heading — the real-corpus layout in *-closure.md retros.
  #   Callers use this to inspect the full marker text (status word, PARTIAL token, shipped IDs).
  #   Returns nothing when no canonical marker is present. Always returns 0.
  #
  # STAGE_RETRO_ISSUES_MARKER_LINE: stage-retro-issues.sh uses retro_marker_line as the single
  # definition of "what the marker line looks like and where to find it". Both the status word
  # (applied/dismissed/pending) and the PARTIAL/shipped inspection are derived from this one call,
  # so after-H1 markers and body markers are handled uniformly and correctly.
  # pipefail-audit: external `grep` over a single retro file (fleet max ~50 KB). SAFE.
  retro_marker_line() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 0
    grep -iE '<!--[[:space:]]*review-status:' "$f" 2>/dev/null | head -1
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
fi
