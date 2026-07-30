#!/usr/bin/env bash
# retro-status.sh — shared helper: read a §18 retro's review-status marker from its LEADING
# HTML-comment block (METHODOLOGY §18). Sourced by sweep-retros.sh and stage-retro.sh so both gate
# on IDENTICAL logic — the two scripts used to carry hand-copied awk pipelines that drifted
# (R1-003 / R3-004); this file is the single source of truth.
#
#   retro_review_status <file>
#     Echoes the lowercased status word (applied/dismissed/pending/…) found in the retro's leading
#     comment block, or nothing when there is no marker there. Always returns 0 (a non-matching
#     grep must yield empty output, never abort a caller running under `set -o pipefail`).
#
# Algorithm — scan ONLY the leading HTML-comment block:
#   * print consecutive lines that (after optional leading spaces) OPEN an HTML comment ('<!--'),
#   * SKIP blank lines (a leading blank is not the block terminator — R1-002),
#   * STOP at the first line that is neither a comment nor blank (so a body marker never gates,
#     and a plain-prose or '# heading' first line ends the scan immediately — R3-001).
# Then pull the FIRST '<!--'-ANCHORED 'review-status: <word>' marker out of that region and
# lowercase it. Anchoring on '<!--' means a bare 'review-status:' substring living in a heading's
# or a comment's PROSE (not directly after the comment opener) is ignored (R1-001).

# Idempotent: safe to source more than once (both SUTs may pull it in the same shell in tests).
if ! declare -F retro_review_status >/dev/null 2>&1; then
  retro_review_status() {
    local f="${1:-}"
    [ -n "$f" ] && [ -f "$f" ] || return 0
    awk '
      /^[[:space:]]*<!--/ { print; next }   # a comment line: keep scanning the block
      /^[[:space:]]*$/     { next }          # blank line: skip, do not terminate (R1-002)
      { exit }                               # first non-comment, non-blank line: stop (R3-001)
    ' "$f" 2>/dev/null \
      | grep -oiE '<!--[[:space:]]*review-status:[[:space:]]*[a-z]+' \
      | head -1 \
      | sed -E 's/.*:[[:space:]]*//' \
      | tr 'A-Z' 'a-z'
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
fi
