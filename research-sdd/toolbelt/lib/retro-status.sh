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
fi
