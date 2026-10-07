#!/usr/bin/env bash
# retro-status.test.sh — red-first unit harness for lib/retro-status.sh, the SHARED helper that
# both sweep-retros.sh and stage-retro.sh use to read a §18 retro's review-status marker
# (METHODOLOGY §18). Extracting the logic once kills the drift risk of two hand-copied awk
# pipelines (R1-003 / R3-004).
#
# WHY THIS SHAPE. retro_review_status <file> is pure text logic: it echoes the lowercased status
# word (applied/dismissed/pending/…) found in the retro's LEADING HTML-comment block, or nothing.
# The contract it must honor:
#   * marker on line 1                             → that word
#   * non-marker comment on line 1 + marker line 2 → that word   (RECONSTRUCTED layout)
#   * blank line 1 + marker line 2                 → that word   (R1-002: blanks are skipped)
#   * '# heading' whose PROSE says review-status:  → nothing     (R1-001: no '<!--' anchor)
#   * NO blank + NO heading, marker-shaped line 3  → nothing     (R3-001: stop at 1st non-comment)
#   * marker (comment) BELOW the heading + blank   → nothing     (body markers never gate)
#   * dismissed marker                             → dismissed
# It sources the helper directly and asserts the function's output per fixture — no external tool,
# no subprocess of the SUTs. It never edits the helper; teeth mutate a throwaway COPY.
#
# Usage: retro-status.test.sh                (run the suite)
#        retro-status.test.sh --prove-teeth  (run suite + the mutation teeth proof)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="$HERE/../lib/retro-status.sh"
[ -f "$HELPER" ] || { echo "FATAL: helper under test not found: $HELPER" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

# shellcheck source=../lib/retro-status.sh
. "$HELPER"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkretro <name> <<'EOF' … EOF : write a fixture from stdin, echo its path.
n=0
mkretro() {
  n=$((n+1)); local p="$ROOT/retro-$n-$1.md"; cat > "$p"; printf '%s' "$p"
}

echo "== retro-status.test.sh (SUT: lib/$(basename "$HELPER")) =="

# ---------------------------------------------------------------------------
# 1 — MARKER ON LINE 1. The plain, common case: the first line IS the status comment, so the
#     helper must return its lowercased word.
f="$(mkretro line1-applied <<'EOF'
<!-- review-status: applied 2026-01-01 · kit deadbeef -->
# retro

body
EOF
)"
got="$(retro_review_status "$f")"
[ "$got" = "applied" ] && ok "1 marker on line 1 → applied" "(got '$got')" \
                       || no "1 marker on line 1 → applied" "got '$got'"

# 2 — RECON LAYOUT: non-marker comment on line 1, real marker on line 2. Both are comments, so the
#     leading-comment scan reaches line 2 and honors it. A 'first line only' reading would miss it.
f="$(mkretro recon-applied <<'EOF'
<!-- RECONSTRUCTED note -->
<!-- review-status: applied 2026-07-07 -->
# retro

body
EOF
)"
got="$(retro_review_status "$f")"
[ "$got" = "applied" ] && ok "2 recon comment L1 + marker L2 → applied" "(got '$got')" \
                       || no "2 recon comment L1 + marker L2 → applied" "got '$got'"

# 3 — BLANK LINE 1 + marker line 2 (R1-002). A leading blank must be SKIPPED, not treated as the
#     block terminator, so the line-2 marker is still honored.
f="$(mkretro blank-then-marker <<'EOF'

<!-- review-status: applied 2026-01-01 -->
# retro
EOF
)"
got="$(retro_review_status "$f")"
[ "$got" = "applied" ] && ok "3 blank L1 + marker L2 → applied (R1-002)" "(got '$got')" \
                       || no "3 blank L1 + marker L2 → applied (R1-002)" "got '$got'"

# 4 — HEADING PROSE (R1-001). Line 1 is a real '# heading' whose PROSE happens to contain the
#     substring 'review-status: applied' — NOT an HTML comment. Anchoring on '<!--' and stopping at
#     the first non-comment line must make this resolve to NOTHING. (RED against the old inline awk,
#     which scans line 1 and misreads the prose as an applied marker → drops a pending retro.)
f="$(mkretro heading-prose <<'EOF'
# retro — earlier draft had review-status: applied noted informally

body
EOF
)"
got="$(retro_review_status "$f")"
[ -z "$got" ] && ok "4 heading prose 'review-status: applied' → none (R1-001)" "(got '$got')" \
             || no "4 heading prose 'review-status: applied' → none (R1-001)" "got '$got'"

# 5 — NO BLANK, NO HEADING (R3-001). A retro whose first line is ordinary prose (no '<!--', no
#     blank, no '# ' heading) with a marker-shaped string on line 3. The scan must STOP at the
#     first non-comment line and return nothing — NOT fall through to a whole-file scan.
#     (RED against the old inline awk: both its exit rules are dead here → whole file scanned →
#     the deep marker is misread and a pending retro is dropped.)
f="$(mkretro no-blank-no-heading <<'EOF'
intro prose line one
second prose line
review-status: applied 2026-01-01
EOF
)"
got="$(retro_review_status "$f")"
[ -z "$got" ] && ok "5 no blank/no heading, deep marker → none (R3-001)" "(got '$got')" \
             || no "5 no blank/no heading, deep marker → none (R3-001)" "got '$got'"

# 6 — BODY MARKER (after heading + blank) → NONE for retro_review_status. A status comment that
#     sits BELOW the H1 heading is outside the leading HTML-comment block. retro_review_status uses
#     a leading-block-only scan (stops at the first non-comment, non-blank line) so it does NOT see
#     this marker — it returns nothing.  sweep-retros.sh relies on this: body-position markers are
#     intentionally invisible to it.  (stage-retro-issues.sh uses retro_marker_line instead, which
#     DOES find this marker — tested via cases 19-21 below.)
f="$(mkretro body-marker <<'EOF'
# retro

<!-- review-status: applied 2026-01-01 -->
EOF
)"
got="$(retro_review_status "$f")"
[ -z "$got" ] && ok "6 body marker below heading+blank → none (leading-block-only)" "(got '$got')" \
             || no "6 body marker below heading+blank → none (leading-block-only)" "got '$got'"

# 7 — DISMISSED marker → dismissed (the other resolution word, proves it is not hard-coded to
#     'applied').
f="$(mkretro line1-dismissed <<'EOF'
<!-- review-status: dismissed 2026-01-01 -->
# retro
EOF
)"
got="$(retro_review_status "$f")"
[ "$got" = "dismissed" ] && ok "7 dismissed marker → dismissed" "(got '$got')" \
                         || no "7 dismissed marker → dismissed" "got '$got'"

# 8 — COMMENT PROSE, non-anchored (the '<!--' anchor's own guard). Line 1 IS a comment (so the
#     block scan prints it), but 'review-status: applied' sits in its PROSE, not directly after the
#     '<!--' opener. The '<!--'-anchored marker regex must NOT match it → nothing. This is the exact
#     fixture the teeth block inverts: drop the anchor and it wrongly resolves to 'applied'.
f="$(mkretro comment-prose <<'EOF'
<!-- RECONSTRUCTED from a backup that had review-status: applied -->
# retro
EOF
)"
got="$(retro_review_status "$f")"
[ -z "$got" ] && ok "8 comment-prose (non-anchored) → none ('<!--' guard)" "(got '$got')" \
             || no "8 comment-prose (non-anchored) → none ('<!--' guard)" "got '$got'"

# 9 — PENDING marker → pending. An explicit 'pending' word is echoed verbatim (only applied/dismissed
#     are resolutions; every other word is surfaced for the caller's gate to decide).
f="$(mkretro line1-pending <<'EOF'
<!-- review-status: pending -->
# retro
EOF
)"
got="$(retro_review_status "$f")"
[ "$got" = "pending" ] && ok "9 pending marker → pending" "(got '$got')" \
                       || no "9 pending marker → pending" "got '$got'"

# ---------------------------------------------------------------------------
# retro_is_excluded unit tests — the shared opt-out scope marker helper.

# 10 — CORRECT MARKER → excluded. A file whose leading HTML-comment block carries the exact
#      '<!-- kit-retro: exclude -->' marker must be identified as excluded (return 0).
f="$(mkretro rexcl-correct <<'EOF'
<!-- kit-retro: exclude -->
# client retro — not §18
body text
EOF
)"
retro_is_excluded "$f" \
  && ok "10 retro_is_excluded: correct leading-block marker → excluded (return 0)" "()" \
  || no "10 retro_is_excluded: correct leading-block marker → excluded (return 0)" "(returned 1)"

# 11 — QUOTED-IN-LONGER-COMMENT → NOT excluded (B3 full-line anchor). A comment line whose
#      PROSE mentions '<!-- kit-retro: exclude -->' but adds surrounding text (a longer comment)
#      must NOT trigger the opt-out. Without a full-line anchor the unanchored grep matches the
#      embedded pattern inside the longer line — a false exclusion. RED until B3 is fixed.
f="$(mkretro rexcl-b3-quoted <<'EOF'
<!-- note: a file opts out with '<!-- kit-retro: exclude -->' in its leading block -->
# retro
body text
EOF
)"
retro_is_excluded "$f" \
  && no "11 retro_is_excluded: marker quoted in longer comment → NOT excluded (B3 anchor)" "(returned 0 — false exclusion)" \
  || ok "11 retro_is_excluded: marker quoted in longer comment → NOT excluded (B3 anchor)" "()"

# 12 — BODY-POSITION MARKER → NOT excluded (M5 invariant). The exclude marker positioned BELOW
#      the leading block (after a '# heading') must be ignored by retro_is_excluded. This pins
#      the '{ exit }' guard in retro_is_excluded's awk: without it the whole-file scan finds the
#      body marker and falsely excludes the file. The M5 tooth (--prove-teeth) removes that guard
#      and asserts this case then goes RED, proving the guard is load-bearing.
f="$(mkretro rexcl-body-pos <<'EOF'
# retro

<!-- kit-retro: exclude -->
body text
EOF
)"
retro_is_excluded "$f" \
  && no "12 retro_is_excluded: body-position marker → NOT excluded (M5 invariant)" "(returned 0 — false exclusion)" \
  || ok "12 retro_is_excluded: body-position marker → NOT excluded (M5 invariant)" "()"

# ---------------------------------------------------------------------------
# TEETH (negative control). The '<!--' anchor in retro_status_from_marker_line is what stops a
# 'review-status:' substring from a prose line (no '<!--' prefix) from being misread as a real
# status.  Mutate a throwaway COPY of the helper: DROP the '<!--' anchor from the grep so any
# 'review-status: <word>' anywhere in the input matches.  Call retro_status_from_marker_line
# DIRECTLY with a prose string (no '<!--') in a FRESH bash.  Against the mutant the prose MUST
# wrongly resolve to 'applied'.  If it stayed empty the anchor was never load-bearing and the
# function has no teeth.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: drop the '<!--' anchor in retro_status_from_marker_line; prose line must false-resolve --"
  anchor="grep -oiE '<!--[[:space:]]*review-status:[[:space:]]*[a-z]+'"
  content="$(cat "$HELPER")"
  if [[ "$content" != *"$anchor"* ]]; then
    no "teeth: locate '<!--'-anchored marker regex in retro_status_from_marker_line" "anchor not found — helper drifted?"
  else
    mutant="$ROOT/retro-status.mutant.sh"
    broken="grep -oiE 'review-status:[[:space:]]*[a-z]+'"
    printf '%s\n' "${content/"$anchor"/"$broken"}" > "$mutant"
    # Call the extraction helper directly with a prose line that has NO '<!--' prefix.
    # Without the anchor the anchorless grep matches 'review-status: applied' in the prose.
    prose="RECONSTRUCTED from a backup that had review-status: applied"
    outm="$("$BASH_BIN" -c '. "$1"; retro_status_from_marker_line "$2"' _ "$mutant" "$prose" 2>&1)"
    if [ "$outm" = "applied" ]; then
      ok "teeth: anchor-dropped mutant false-resolves prose line (retro_status_from_marker_line has teeth)" "()"
    else
      no "teeth: anchor-dropped mutant false-resolves prose line" "mutant returned '$outm' — anchor is THEATER"
    fi
  fi

  # Tooth M5: remove the bare '{ exit }' from retro_is_excluded's awk, enabling a whole-file scan.
  # A body-position marker (case 12 fixture) must then FALSELY exclude — return 0 (excluded).
  # Uses sed to delete the ONE bare '{ exit }' line (the one in retro_is_excluded's awk, which has
  # no trailing comment); the matching line in retro_review_status has a trailing '# ...' comment
  # and is NOT deleted, keeping retro_review_status intact. If the mutant returns 1 (not excluded),
  # case 12's '{ exit }' guard was never the deciding factor and case 12 is theater.
  echo "-- teeth M5: drop { exit } from retro_is_excluded awk; body marker must false-exclude (case 12 has teeth) --"
  m5_mutant="$ROOT/retro-status.m5.sh"
  sed '/^      { exit }$/ d' "$HELPER" > "$m5_mutant"
  fix12="$(mkretro m5-body-check <<'EOF'
# retro

<!-- kit-retro: exclude -->
body text
EOF
)"
  m5_rc="$("$BASH_BIN" -c '. "$1"; retro_is_excluded "$2"; echo $?' _ "$m5_mutant" "$fix12" 2>&1)"
  if [ "$m5_rc" = "0" ]; then
    ok "teeth M5: { exit }-dropped mutant false-excludes body-position marker" "(case 12 has teeth)"
  else
    no "teeth M5: { exit }-dropped mutant should false-exclude body-position marker" "exit was '$m5_rc' (expected 0) — case 12 is THEATER"
  fi

  # Tooth M7: convert retro_marker_line's awk from a whole-file conditional-exit scan to an
  # unconditional leading-block-only exit.  Replaces the conditional `if (tolower($0) ~ …) { print;
  # exit }` rule with a bare `{ exit }` so the awk exits at the first non-comment, non-blank line.
  # An after-H1 marker (cases 19-20 fixtures) must return empty, proving the conditional exit is
  # load-bearing.  Uses the RETRO_MARKER_LINE_AWK anchor tag to locate the tolower line precisely.
  echo "-- teeth M7: make retro_marker_line leading-block-only; after-H1 marker must return empty (cases 19-20 have teeth) --"
  if ! grep -qF "RETRO_MARKER_LINE_AWK" "$HELPER"; then
    no "teeth M7: locate RETRO_MARKER_LINE_AWK anchor" "anchor not found — helper drifted?"
  else
    m7_linenum="$(awk '/RETRO_MARKER_LINE_AWK/{found=1} found && /tolower/{print NR; exit}' "$HELPER")"
    if [ -z "$m7_linenum" ]; then
      no "teeth M7: find tolower line after RETRO_MARKER_LINE_AWK" "not found — helper drifted?"
    else
      m7_mutant="$ROOT/retro-status.m7.sh"
      # Replace the entire conditional-match line with a bare '{ exit }' on the specific line number.
      sed "${m7_linenum}s/.*/      { exit }/" "$HELPER" > "$m7_mutant"
      if diff -q "$HELPER" "$m7_mutant" >/dev/null 2>&1; then
        no "teeth M7: build leading-block-only mutant" "mutant identical — sed substitution failed"
      elif ! "$BASH_BIN" -n "$m7_mutant" 2>/dev/null; then
        no "teeth M7: build leading-block-only mutant" "mutant syntax error"
      else
        fix_m7="$(mkretro m7-after-h1 <<'EOF'
# §18 Retro — some focus

<!-- review-status: applied 2026-09-20 · kit ad87c33 -->

body text
EOF
)"
        outm7="$("$BASH_BIN" -c '. "$1"; retro_marker_line "$2"' _ "$m7_mutant" "$fix_m7" 2>&1)"
        if [ -z "$outm7" ]; then
          ok "teeth M7: leading-block-only mutant returns empty for after-H1 marker (cases 19-20 have teeth)" "()"
        else
          no "teeth M7: leading-block-only mutant should return empty for after-H1 marker" \
            "got '$outm7' — cases 19-20 are THEATER"
        fi
      fi
    fi
  fi

  # Tooth M8: remove the '^[[:space:]]*' line-start anchor from retro_marker_line's awk match.
  # Without the anchor a marker pattern appearing mid-line (e.g. backtick-quoted in a table cell)
  # falsely matches.  The anchor forces '<!--' to appear at line start (optional whitespace only).
  # Uses RETRO_MARKER_LINE_AWK + the same tolower line to build the mutant.
  echo "-- teeth M8: remove line-start anchor from retro_marker_line; mid-line quoted marker must false-match (cases 22-23 have teeth) --"
  if ! grep -qF "RETRO_MARKER_LINE_AWK" "$HELPER"; then
    no "teeth M8: locate RETRO_MARKER_LINE_AWK anchor" "anchor not found — helper drifted?"
  else
    m8_linenum="$(awk '/RETRO_MARKER_LINE_AWK/{found=1} found && /ismark = /{print NR; exit}' "$HELPER")"
    if [ -z "$m8_linenum" ]; then
      no "teeth M8: find tolower line after RETRO_MARKER_LINE_AWK" "not found — helper drifted?"
    else
      m8_mutant="$ROOT/retro-status.m8.sh"
      # Remove '^ ? ? ?' before '<!--' in the awk match regex so it becomes a substring search.
      # (kit issue #1125 item 1 narrowed the anchor from '^[[:space:]]*' to '^ {0,3}', and kit
      # issue #1130 finding 2 rewrote that as the mawk-portable '^ ? ? ?'; the mutant target
      # moves with it — same load-bearing claim, current pattern.)
      sed "${m8_linenum}s|\^ ? ? ?<!--|<!--|" "$HELPER" > "$m8_mutant"
      if diff -q "$HELPER" "$m8_mutant" >/dev/null 2>&1; then
        no "teeth M8: build anchor-removed mutant" "mutant identical — sed substitution failed"
      elif ! "$BASH_BIN" -n "$m8_mutant" 2>/dev/null; then
        no "teeth M8: build anchor-removed mutant" "mutant syntax error"
      else
        # A table-cell backtick-quoted marker must falsely match when the anchor is absent.
        fix_m8="$(mkretro m8-table-quoted <<'EOF'
# §18 Retro — table example

| col A | col B |
|-------|-------|
| info  | `<!-- review-status: applied -->` |
EOF
)"
        outm8="$("$BASH_BIN" -c '. "$1"; retro_marker_line "$2"' _ "$m8_mutant" "$fix_m8" 2>&1)"
        if [ -n "$outm8" ]; then
          ok "teeth M8: anchor-removed mutant false-matches mid-line quoted marker (cases 22-23 have teeth)" "(got '$outm8')"
        else
          no "teeth M8: anchor-removed mutant should false-match mid-line quoted marker" \
            "got empty — line-start anchor is THEATER"
        fi
      fi
    fi
  fi

  # Tooth M6: drop the bare '{ exit }' from retro_is_waived's awk, enabling a whole-file scan.
  # A body-position waiver marker (case 15 fixture) must then FALSELY return 0 (waived).
  # Uses awk to skip the FOURTH bare '{ exit }' occurrence (the one in retro_is_waived); the
  # first (retro_review_status), second (retro_marker_scope_line, kit issue #945), and third
  # (retro_is_excluded) are kept intact. If the mutant returns 1 (not waived), the '{ exit }'
  # guard was not the deciding factor and case 15 is theater.
  echo "-- teeth M6: drop { exit } from retro_is_waived awk; body-position waiver must false-fire (case 15 has teeth) --"
  m6_mutant="$ROOT/retro-status.m6.sh"
  # Four '{ exit }' occurrences: retro_review_status (n=1), retro_marker_scope_line (n=2),
  # retro_is_excluded (n=3), retro_is_waived (n=4). Skip the FOURTH to mutate only
  # retro_is_waived's guard.
  awk 'BEGIN{n=0} /^      \{ exit \}$/ { n++; if(n==4) next } { print }' "$HELPER" > "$m6_mutant"
  fix15="$(mkretro m6-body-waiver <<'EOF'
# retro — body-position waiver below

<!-- retro-waived: 2026-07-27 · should not match -->
body text
EOF
)"
  m6_rc="$("$BASH_BIN" -c '. "$1"; retro_is_waived "$2"; echo $?' _ "$m6_mutant" "$fix15" 2>&1)"
  if [ "$m6_rc" = "0" ]; then
    ok "teeth M6: { exit }-dropped mutant false-waivers body-position marker" "(case 15 has teeth)"
  else
    no "teeth M6: { exit }-dropped mutant should false-waiver body-position marker" "exit was '$m6_rc' (expected 0) — case 15 is THEATER"
  fi
fi

# ---------------------------------------------------------------------------
# retro_is_waived unit tests — the shared waiver-marker helper.

# 13 — CORRECT WAIVER MARKER → waived. A file whose leading HTML-comment block carries
#      '<!-- retro-waived: ... -->' must be identified as waived (return 0).
f="$(mkretro rwaived-correct <<'EOF'
<!-- kit-retro: exclude -->
<!-- retro-waived: 2026-07-27 · dormant target; reconstruction not warranted -->
# waiver marker file
EOF
)"
retro_is_waived "$f" \
  && ok "13 retro_is_waived: correct waiver marker → waived (return 0)" "()" \
  || no "13 retro_is_waived: correct waiver marker → waived (return 0)" "(returned 1)"

# 14 — NO WAIVER MARKER → not waived. A plain retro without the waiver marker must
#      return 1 (not waived).
f="$(mkretro rwaived-absent <<'EOF'
<!-- review-status: pending -->
# retro — no waiver
body text
EOF
)"
retro_is_waived "$f" \
  && no "14 retro_is_waived: no waiver marker → NOT waived (return 1)" "(returned 0)" \
  || ok "14 retro_is_waived: no waiver marker → NOT waived (return 1)" "()"

# 15 — BODY-POSITION WAIVER → NOT waived (leading-block-only invariant). A waiver marker
#      appearing AFTER the heading (outside the leading HTML-comment block) must be ignored.
#      The '{ exit }' guard in the awk scan terminates at the first non-comment, non-blank
#      line — the heading — so a body-position waiver must never fire.
f="$(mkretro rwaived-body-pos <<'EOF'
# retro — body-position waiver below

<!-- retro-waived: 2026-07-27 · should not match -->
body text
EOF
)"
retro_is_waived "$f" \
  && no "15 retro_is_waived: body-position waiver → NOT waived (leading-block-only)" "(returned 0)" \
  || ok "15 retro_is_waived: body-position waiver → NOT waived (leading-block-only)" "()"

# 16 — PROSE-MENTION → NOT waived (full-line anchor required). A leading-block comment that
#      MENTIONS the waiver marker inside longer prose (e.g., a template instruction) must NOT
#      be treated as waived. The unanchored grep matches an INNER '<!-- retro-waived: '
#      substring found in the longer comment line — a false positive. The full-line anchor
#      prevents this by requiring the entire line to be a proper closing '<!-- retro-waived:
#      ... -->' comment with no extra content before the marker (after '<!--').
#      RED against the unanchored form: the inner '<!-- retro-waived: ' substring matches.
f="$(mkretro rwaived-prose <<'EOF'
<!-- NOTE: to waive, add '<!-- retro-waived: <date> · <reason> -->' in the leading block -->
# retro — this is documentation, not a waiver
body text
EOF
)"
retro_is_waived "$f" \
  && no "16 retro_is_waived: prose-mention → NOT waived (full-line anchor)" "(returned 0 — false waiver)" \
  || ok "16 retro_is_waived: prose-mention → NOT waived (full-line anchor)" "()"

# 17 — EMPTY-PAYLOAD WAIVER → NOT waived. '<!-- retro-waived: -->' with nothing between the
#      colon and '-->' must NOT be treated as a waiver — a waiver with zero recorded justification
#      silently suppresses a target. Require at least one non-space character in the payload.
f="$(mkretro rwaived-empty-payload <<'EOF'
<!-- kit-retro: exclude -->
<!-- retro-waived: -->
# empty waiver — no justification
body text
EOF
)"
retro_is_waived "$f" \
  && no "17 retro_is_waived: empty payload '<!-- retro-waived: -->' → NOT waived (require non-empty justification)" "(returned 0 — false waiver)" \
  || ok "17 retro_is_waived: empty payload '<!-- retro-waived: -->' → NOT waived (require non-empty justification)" "()"

# 18 — NO-SPACE-AFTER-COLON WAIVER → waived. '<!-- retro-waived:2026-07-27 · reason -->' must
#      match even without a space after the colon, consistent with retro_is_excluded's [[:space:]]*
#      (not [[:space:]]+). RED before fix: the current [[:space:]]+ requires at least one space,
#      so a no-space payload is silently rejected and the waiver goes unrecognized.
f="$(mkretro rwaived-nospace <<'EOF'
<!-- kit-retro: exclude -->
<!-- retro-waived:2026-07-27 · dormant target; reconstruction not warranted -->
# waiver without space after colon
body text
EOF
)"
retro_is_waived "$f" \
  && ok "18 retro_is_waived: no space after colon (retro-waived:date) → waived (space optional)" "()" \
  || no "18 retro_is_waived: no space after colon (retro-waived:date) → waived (space optional)" "(returned 1)"

# ---------------------------------------------------------------------------
# 19-21 — retro_marker_line WHOLE-FILE SCAN tests.
#   retro_marker_line finds '<!-- review-status: ...' anywhere in the file (not just the leading
#   block), so after-H1 markers are detected.  These cases directly test retro_marker_line to pin
#   its contract; they complement case 6 which confirms retro_review_status still ignores these.
#   stage-retro-issues.sh uses retro_marker_line for status extraction; sweep-retros.sh uses
#   retro_review_status (leading-block-only) — the two functions have intentionally different scopes.
#
# 19 — MARKER DIRECTLY AFTER H1 (no blank). retro_marker_line must return the raw marker line.
f19="$(mkretro ml-after-h1-no-blank <<'EOF'
# §18 Retro — some focus
<!-- review-status: applied 2026-09-20 · kit abc1234 -->

body text
EOF
)"
ml19="$(retro_marker_line "$f19")"
[ -n "$ml19" ] && ok "19 retro_marker_line: marker directly after H1 (no blank) → found" "(got '$ml19')" \
              || no "19 retro_marker_line: marker directly after H1 (no blank) → found" "got empty"

# 20 — MARKER AFTER H1 AND BLANK (real-corpus layout: H1 line 1, blank line 2, marker line 3).
#      This is the layout of the niagara-research retros that were missed by the leading-block scan.
f20="$(mkretro ml-after-h1-blank <<'EOF'
# §18 Retro — focus: signing-pki

<!-- review-status: applied 2026-09-20 · kit ad87c33 -->

body text
EOF
)"
ml20="$(retro_marker_line "$f20")"
<<<"$ml20" grep -qiE '<!--[[:space:]]*review-status:' \
  && ok "20 retro_marker_line: marker after H1+blank → found (real corpus layout)" "(got '$ml20')" \
  || no "20 retro_marker_line: marker after H1+blank → found (real corpus layout)" "got '$ml20'"

# 21 — PARTIAL MARKER AFTER H1: retro_marker_line returns the raw line including 'PARTIAL' token,
#      which stage-retro-issues.sh uses for is_partial detection (case-sensitive grep).
f21="$(mkretro ml-after-h1-partial <<'EOF'
# §18 Retro — partial applied

<!-- review-status: applied 2026-06-01 · kit deadbeef · PARTIAL — shipped: 1; deferred: 2 -->

body
EOF
)"
ml21="$(retro_marker_line "$f21")"
<<<"$ml21" grep -qF 'PARTIAL' \
  && ok "21 retro_marker_line: partial applied marker after H1 → raw line has PARTIAL" "(got '$ml21')" \
  || no "21 retro_marker_line: partial applied marker after H1 → raw line has PARTIAL" "got '$ml21'"

# ---------------------------------------------------------------------------
# 22-25 — retro_marker_line edge cases: anchoring, fence tracking, and list edges.

# 22 — QUOTED IN TABLE CELL → no match. The only marker-like text is backtick-quoted inside a
#      table row cell (not at line start). The line-start anchor must prevent it from matching.
f="$(mkretro ml-table-quoted <<'EOF'
# §18 Retro — table example

| col A | col B |
|-------|-------|
| info  | `<!-- review-status: applied -->` |
EOF
)"
ml22="$(retro_marker_line "$f")"
[ -z "$ml22" ] \
  && ok "22 retro_marker_line: marker quoted in table cell → no match (line-start anchor)" "()" \
  || no "22 retro_marker_line: marker quoted in table cell → no match (line-start anchor)" "got '$ml22'"

# 23 — FENCED CODE BLOCK → no match. A marker-like line inside a ``` fenced block must be skipped
#      by the fence-tracking logic; only a real marker outside the fence matches.
f="$(mkretro ml-fenced <<'EOF'
# §18 Retro — fenced example

```
<!-- review-status: pending -->
```

body text
EOF
)"
ml23="$(retro_marker_line "$f")"
[ -z "$ml23" ] \
  && ok "23 retro_marker_line: marker inside fenced block → no match (fence tracking)" "()" \
  || no "23 retro_marker_line: marker inside fenced block → no match (fence tracking)" "got '$ml23'"

# 24 — REAL MARKER AFTER H1 + QUOTED IN TABLE LATER → finds real one first. A genuine marker on
#      line 3 (after H1 + blank) must be returned; a backtick-quoted one later in a table cell
#      must be ignored (because retro_marker_line exits after the first real match).
f="$(mkretro ml-real-plus-quoted <<'EOF'
# §18 Retro — real marker first

<!-- review-status: applied 2026-09-20 · kit abc1234 -->

| note | `<!-- review-status: pending -->` |
|------|-----------------------------------|
EOF
)"
ml24="$(retro_marker_line "$f")"
<<<"$ml24" grep -qF 'applied' \
  && ok "24 retro_marker_line: real after-H1 marker returned; quoted-in-table ignored" "(got '$ml24')" \
  || no "24 retro_marker_line: real after-H1 marker should be returned first" "got '$ml24'"

# 25 — MARKER AS LAST LINE (list edge). A marker on the very last line of the file (no trailing
#      blank after it) must still be returned.
f="$(mkretro ml-last-line <<'EOF'
# §18 Retro — marker at end

body text
<!-- review-status: applied 2026-09-20 · kit deadbeef -->
EOF
)"
ml25="$(retro_marker_line "$f")"
[ -n "$ml25" ] \
  && ok "25 retro_marker_line: marker as last line → found" "(got '$ml25')" \
  || no "25 retro_marker_line: marker as last line → found" "got empty"

# ---------------------------------------------------------------------------
# retro_marker_is_partial <marker_line> — kit issue #1090.

# 26 — STRUCTURED PARTIAL TOKEN → true. The canonical format: PARTIAL sits before the em dash.
m26='<!-- review-status: applied 2026-06-01 · kit deadbeef · PARTIAL — shipped: 1; deferred: 2 -->'
retro_marker_is_partial "$m26" \
  && ok "26 retro_marker_is_partial: structured PARTIAL token → true" "()" \
  || no "26 retro_marker_is_partial: structured PARTIAL token → true" "returned false"

# 27 — REAL #1090 REPRO: dismissed marker, lowercase 'partial' in free-text prose → false.
m27='<!-- review-status: dismissed 2026-09-20 · scoped to build-n4-module kit — deltas owned + implemented there (D1-D5 orient-guard, P3/P4/P5; P1 partial) -->'
retro_marker_is_partial "$m27" \
  && no "27 retro_marker_is_partial: #1090 repro (dismissed + prose 'partial') → false" "returned true" \
  || ok "27 retro_marker_is_partial: #1090 repro (dismissed + prose 'partial') → false" "()"

# 28 — PROSE POSITION: 'partial' at the very START of the free-text segment → false.
m28='<!-- review-status: dismissed 2026-09-20 · kit deadbeef — partial rollback only, see ticket -->'
retro_marker_is_partial "$m28" \
  && no "28 retro_marker_is_partial: 'partial' at prose START → false" "returned true" \
  || ok "28 retro_marker_is_partial: 'partial' at prose START → false" "()"

# 29 — PROSE POSITION: 'partial' at the very END of the free-text segment → false.
m29='<!-- review-status: dismissed 2026-09-20 · kit deadbeef — deltas owned elsewhere (partial) -->'
retro_marker_is_partial "$m29" \
  && no "29 retro_marker_is_partial: 'partial' at prose END → false" "returned true" \
  || ok "29 retro_marker_is_partial: 'partial' at prose END → false" "()"

# 30 — FREE-TEXT UPPERCASE 'PARTIAL' (no shipped:, after the dash) → false. Proves the cut
# point, not just case, is what protects an applied marker whose free text happens to use the
# exact uppercase word.
m30='<!-- review-status: applied 2026-01-01 · kit abc1234 — historical note: this used to be PARTIAL but is now fully resolved -->'
retro_marker_is_partial "$m30" \
  && no "30 retro_marker_is_partial: free-text uppercase PARTIAL (no shipped:) → false" "returned true" \
  || ok "30 retro_marker_is_partial: free-text uppercase PARTIAL (no shipped:) → false" "()"

# 31 — 'shipped:' WITHOUT a literal PARTIAL token → still true (real-corpus format; kit
# issue #949 fixtures use exactly this shape).
m31='<!-- review-status: applied 2026-09-05 · kit e0b701a · shipped: #1, #2 -->'
retro_marker_is_partial "$m31" \
  && ok "31 retro_marker_is_partial: bare 'shipped:' (no PARTIAL token) → true" "()" \
  || no "31 retro_marker_is_partial: bare 'shipped:' (no PARTIAL token) → true" "returned false"

# 32 — EMPTY LINE → false.
retro_marker_is_partial "" \
  && no "32 retro_marker_is_partial: empty line → false" "returned true" \
  || ok "32 retro_marker_is_partial: empty line → false" "()"

# ---------------------------------------------------------------------------
# retro_marker_shipped_ids <shipped_raw> — kit issue #949 item 1.

# 33 — HASH STRIP: '#1, #2' → '1' and '2' (leading '#' stripped from each token).
ids33="$(retro_marker_shipped_ids '#1, #2')"
if [ "$ids33" = "$(printf '1\n2')" ]; then
  ok "33 retro_marker_shipped_ids: '#1, #2' → '1','2' (hash stripped)" "()"
else
  no "33 retro_marker_shipped_ids: '#1, #2' → '1','2' (hash stripped)" "got [$ids33]"
fi

# 34 — TRAILING ANNOTATION: 'Δ1 (#549), D1 (§20)' → 'Δ1' and 'D1' (parenthetical dropped).
ids34="$(retro_marker_shipped_ids 'Δ1 (#549), D1 (§20)')"
if [ "$ids34" = "$(printf 'Δ1\nD1')" ]; then
  ok "34 retro_marker_shipped_ids: 'Δ1 (#549), D1 (§20)' → 'Δ1','D1'" "()"
else
  no "34 retro_marker_shipped_ids: 'Δ1 (#549), D1 (§20)' → 'Δ1','D1'" "got [$ids34]"
fi

# 35 — RANGE EXPANSION (list edges: FIRST, MIDDLE, LAST of a 3-element range) still works
# alongside the hash strip — '#P1-P3' expands to P1, P2, P3.
ids35="$(retro_marker_shipped_ids '#P1-P3')"
if [ "$ids35" = "$(printf 'P1\nP2\nP3')" ]; then
  ok "35 retro_marker_shipped_ids: '#P1-P3' range expands with hash stripped" "()"
else
  no "35 retro_marker_shipped_ids: '#P1-P3' range expands with hash stripped" "got [$ids35]"
fi

# 36 — EMPTY INPUT → empty output, no error.
ids36="$(retro_marker_shipped_ids '')"
[ -z "$ids36" ] \
  && ok "36 retro_marker_shipped_ids: empty input → empty output" "()" \
  || no "36 retro_marker_shipped_ids: empty input → empty output" "got [$ids36]"

# ---------------------------------------------------------------------------
# retro_marker_scope_line <file> — kit issue #945: the ONE marker scope shared by
# reconcile-issues.sh, stage-retro-issues.sh, retro-gate.sh, and sweep-retros.sh. Leading block,
# tolerating exactly one H1 line at the very top.

# 37 — REAL-CORPUS LAYOUT: H1 line 1, blank line 2, marker line 3 → found. This is the exact
# niagara-research *-closure.md shape kit issue #945 was filed over.
f="$(mkretro scope-h1-blank <<'EOF'
# §18 Retro — focus: apis — 2026-08-25

<!-- review-status: applied 2026-09-24 · kit c10f9d9 -->

body
EOF
)"
f37path="$f"
sl37="$(retro_marker_scope_line "$f")"
[ "$sl37" = "<!-- review-status: applied 2026-09-24 · kit c10f9d9 -->" ] \
  && ok "37 retro_marker_scope_line: H1 + blank + marker → found (#945 real-corpus shape)" "()" \
  || no "37 retro_marker_scope_line: H1 + blank + marker → found (#945 real-corpus shape)" "got [$sl37]"

# 38 — H1 directly followed by marker, NO blank line → still found (blanks after H1 are optional,
# not required).
f="$(mkretro scope-h1-noblank <<'EOF'
# retro
<!-- review-status: dismissed 2026-01-01 -->
body
EOF
)"
sl38="$(retro_marker_scope_line "$f")"
[ "$sl38" = "<!-- review-status: dismissed 2026-01-01 -->" ] \
  && ok "38 retro_marker_scope_line: H1 immediately followed by marker (no blank) → found" "()" \
  || no "38 retro_marker_scope_line: H1 immediately followed by marker (no blank) → found" "got [$sl38]"

# 39 — NO H1 at all, marker on line 1 → still found (pre-#945 behavior preserved — this scope is a
# superset of retro_review_status's, not a replacement with different no-H1 semantics).
f="$(mkretro scope-no-h1 <<'EOF'
<!-- review-status: applied 2026-01-01 -->
# retro

body
EOF
)"
sl39="$(retro_marker_scope_line "$f")"
[ "$sl39" = "<!-- review-status: applied 2026-01-01 -->" ] \
  && ok "39 retro_marker_scope_line: no H1, marker on line 1 → found (pre-#945 case preserved)" "()" \
  || no "39 retro_marker_scope_line: no H1, marker on line 1 → found (pre-#945 case preserved)" "got [$sl39]"

# 40 — TWO HEADINGS: H1, blank, H2, blank, marker → NOT found. Only ONE H1 is skippable; a second
# heading is ordinary non-blank/non-comment content and terminates the leading-block scan.
f="$(mkretro scope-two-headings <<'EOF'
# H1

## H2

<!-- review-status: applied 2026-01-01 -->
EOF
)"
sl40="$(retro_marker_scope_line "$f")"
[ -z "$sl40" ] \
  && ok "40 retro_marker_scope_line: H1 + H2 + marker → NOT found (only one heading skippable)" "()" \
  || no "40 retro_marker_scope_line: H1 + H2 + marker → NOT found (only one heading skippable)" "got [$sl40]"

# 41 — FENCED CODE BLOCK after H1: a documented example marker inside a ``` fence must not count.
# The leading-block scan exits at the fence-opener line (non-blank, non-comment) before ever
# reaching the marker-shaped text inside the fence.
f="$(mkretro scope-fenced <<'EOF'
# retro

```
<!-- review-status: applied 2026-01-01 -->
```
EOF
)"
sl41="$(retro_marker_scope_line "$f")"
[ -z "$sl41" ] \
  && ok "41 retro_marker_scope_line: marker inside fenced block after H1 → NOT found" "()" \
  || no "41 retro_marker_scope_line: marker inside fenced block after H1 → NOT found" "got [$sl41]"

# 42 — QUOTED IN PROSE after H1: a paragraph explaining the convention, that happens to mention
# the marker text on its own following line, must not count — the prose line itself (not blank,
# not a comment) terminates the scan before the quoted line is ever reached.
f="$(mkretro scope-quoted-prose <<'EOF'
# retro

Example marker:
<!-- review-status: applied 2026-01-01 -->
EOF
)"
sl42="$(retro_marker_scope_line "$f")"
[ -z "$sl42" ] \
  && ok "42 retro_marker_scope_line: marker quoted in prose after H1 → NOT found" "()" \
  || no "42 retro_marker_scope_line: marker quoted in prose after H1 → NOT found" "got [$sl42]"

# 43 — NO MARKER AT ALL → empty output, no error (absent-input inside the function itself).
f="$(mkretro scope-none <<'EOF'
# retro

body, no marker here
EOF
)"
sl43="$(retro_marker_scope_line "$f")"
[ -z "$sl43" ] \
  && ok "43 retro_marker_scope_line: no marker present → empty, no error" "()" \
  || no "43 retro_marker_scope_line: no marker present → empty, no error" "got [$sl43]"

# ---------------------------------------------------------------------------
# retro_marker_is_partial 'shipped:' scoping — kit issue #1093 item 2.

# 44 — PROSE 'shipped:' AFTER THE FREE-TEXT DASH → false. Real #1093 repro: an applied marker
# whose free-text explanation (after the em dash) happens to use the word 'shipped:' must not
# retroactively mark the retro PARTIAL.
m44='<!-- review-status: applied 2026-01-01 · kit abc1234 — all done; nothing shipped: later than #600 -->'
retro_marker_is_partial "$m44" \
  && no "44 retro_marker_is_partial: prose 'shipped:' after free-text dash → false (#1093 item 2)" "returned true" \
  || ok "44 retro_marker_is_partial: prose 'shipped:' after free-text dash → false (#1093 item 2)" "()"

# 45 — REAL-CORPUS 'shipped:' AFTER AN OPENING PAREN (no PARTIAL token) → false. The opening
# paren is a free-text boundary exactly like the em dash; 'shipped:' appearing only after it is
# descriptive prose, not the structured field.
m45='<!-- review-status: applied 2026-01-01 · kit abc1234 (see rationale) shipped: 1, 2 -->'
retro_marker_is_partial "$m45" \
  && no "45 retro_marker_is_partial: 'shipped:' only after an opening paren → false" "returned true" \
  || ok "45 retro_marker_is_partial: 'shipped:' only after an opening paren → false" "()"

# 46 — REGRESSION GUARD: real-corpus 'shipped: #1, #2' with no em dash/paren before it (kit issue
# #949 shape) still returns true after the #1093 item 2 scoping fix.
m46='<!-- review-status: applied 2026-09-05 · kit e0b701a · shipped: #1, #2 -->'
retro_marker_is_partial "$m46" \
  && ok "46 retro_marker_is_partial: real-corpus bare 'shipped:' still true (#949 regression guard)" "()" \
  || no "46 retro_marker_is_partial: real-corpus bare 'shipped:' still true (#949 regression guard)" "returned false"

# 47 — REGRESSION GUARD: canonical 'PARTIAL — shipped: …' form (em dash BEFORE shipped:, but
# PARTIAL sits before the dash too) still returns true — condition (a) catches it regardless of
# condition (b)'s narrower scope.
m47='<!-- review-status: applied 2026-07-29 · kit cc5e13a · PARTIAL — shipped: D2,D3,D4,D5; DEFERRED: D1 -->'
retro_marker_is_partial "$m47" \
  && ok "47 retro_marker_is_partial: canonical 'PARTIAL — shipped:' form still true" "()" \
  || no "47 retro_marker_is_partial: canonical 'PARTIAL — shipped:' form still true" "returned false"

# 48 — MIXED-CASE 'Partial' (kit issue #1093 item 4, documented behavior): the structured segment
# carries 'Partial' (not the exact uppercase token) and no 'shipped:' field — condition (a) is
# case-SENSITIVE by design (#1090) and does not match, condition (b) has nothing to find, so the
# marker is read as NOT partial. This is intentional, documented behavior (see the function's doc
# comment), not a silent gap.
m48='<!-- review-status: applied 2026-01-01 · kit abc1234 · Partial -->'
retro_marker_is_partial "$m48" \
  && no "48 retro_marker_is_partial: mixed-case 'Partial', no shipped: → false (documented #1093 item 4)" "returned true" \
  || ok "48 retro_marker_is_partial: mixed-case 'Partial', no shipped: → false (documented #1093 item 4)" "()"

# ---------------------------------------------------------------------------
# retro_marker_shipped_ids portability — kit issue #1093 item 5: no gawk-only 3-arg match().

# 49 — FORCED NON-GAWK PATH: with a stub 'awk' on PATH that errors on any invocation, range
# expansion must still work — proving retro_marker_shipped_ids no longer depends on awk at all
# (gawk or otherwise) for the range-parsing path that used to require gawk's 3-arg match().
_p49dir="$(mktemp -d)"
cat > "$_p49dir/awk" <<'FAKEAWK'
#!/bin/sh
echo "FAKE AWK INVOKED" >&2
exit 97
FAKEAWK
chmod +x "$_p49dir/awk"
ids49="$(PATH="$_p49dir:$PATH" "$BASH_BIN" -c '. "$1"; retro_marker_shipped_ids "$2"' _ "$HELPER" '#P1-P3' 2>"$_p49dir/stderr")"
if [ "$ids49" = "$(printf 'P1\nP2\nP3')" ] && [ ! -s "$_p49dir/stderr" ]; then
  ok "49 retro_marker_shipped_ids: range expansion works with a broken/non-gawk 'awk' on PATH (#1093 item 5)" "()"
else
  no "49 retro_marker_shipped_ids: range expansion works with a broken/non-gawk 'awk' on PATH (#1093 item 5)" \
    "got ids=[$ids49] stderr=[$(cat "$_p49dir/stderr" 2>/dev/null)]"
fi
rm -rf "$_p49dir"

MAWK_BIN="$(command -v mawk || true)"
if [ -n "$MAWK_BIN" ]; then
  _p49bdir="$(mktemp -d)"
  ln -s "$MAWK_BIN" "$_p49bdir/awk"
  ids49b="$(PATH="$_p49bdir:$PATH" "$BASH_BIN" -c '. "$1"; retro_marker_shipped_ids "$2"' _ "$HELPER" '#P1-P3' 2>"$_p49bdir/stderr")"
  rm -rf "$_p49bdir"
  [ "$ids49b" = "$(printf 'P1\nP2\nP3')" ] \
    && ok "49b retro_marker_shipped_ids: range expansion works with real mawk aliased as awk" "()" \
    || no "49b retro_marker_shipped_ids: range expansion works with real mawk aliased as awk" "got [$ids49b]"
else
  printf '  SKIP  49b retro_marker_shipped_ids: mawk not installed — skipping real-mawk path\n'
fi

# ---------------------------------------------------------------------------
# retro_marker_out_of_scope <file> — kit issue #1099: THIRD state distinct from "in-scope marker"
# and "genuinely absent". §7 "test the list edges": the whole-file scan this function depends on
# (retro_marker_line) reads the file line by line, so prove it is not blind at any structural
# position — EARLY, MIDDLE, LATE (no trailing newline) — plus the smallest single-extra-line shape.

# 50 — EARLY: YAML frontmatter precedes an otherwise leading-block-shaped marker.
f="$(mkretro oos-early <<'EOF'
---
title: x
---

<!-- review-status: applied 2026-01-01 -->
body
EOF
)"
retro_marker_out_of_scope "$f" \
  && ok "50 retro_marker_out_of_scope: EARLY (YAML frontmatter) → true" "()" \
  || no "50 retro_marker_out_of_scope: EARLY (YAML frontmatter) → true" "returned false"

# 51 — MIDDLE: substantial content both before AND after the out-of-scope marker.
f="$(mkretro oos-middle <<'EOF'
# retro

## Background

Some long narrative paragraph explaining
what happened, several lines of prose,
so the marker sits well past line 1.

<!-- review-status: applied 2026-01-01 -->

## More notes

Even more narrative content follows the marker,
so it is not the last line of the file either.
EOF
)"
retro_marker_out_of_scope "$f" \
  && ok "51 retro_marker_out_of_scope: MIDDLE (narrative before+after) → true" "()" \
  || no "51 retro_marker_out_of_scope: MIDDLE (narrative before+after) → true" "returned false"

# 52 — LAST: the marker is the FINAL line of the file, NO trailing newline — the exact shape of
# verify-registry.sh's list-edge bug (a `read` loop silently skipping the last element).
f="$ROOT/retro-oos-last.md"
printf '# retro\n\n## Notes\n\n<!-- review-status: applied 2026-01-01 -->' > "$f"
retro_marker_out_of_scope "$f" \
  && ok "52 retro_marker_out_of_scope: LAST line, no trailing newline → true" "()" \
  || no "52 retro_marker_out_of_scope: LAST line, no trailing newline → true" "returned false"

# 53 — SINGLE-ROW: the smallest possible out-of-scope shape — exactly one non-blank, non-comment
# line (a lone '## Notes' heading) between the leading block and the marker.
f="$ROOT/retro-oos-single.md"
printf '## Notes\n<!-- review-status: applied 2026-01-01 -->\n' > "$f"
retro_marker_out_of_scope "$f" \
  && ok "53 retro_marker_out_of_scope: single-row minimal shape → true" "()" \
  || no "53 retro_marker_out_of_scope: single-row minimal shape → true" "returned false"

# 54 — REGRESSION GUARD: genuinely absent (no marker anywhere) → false, not out-of-scope.
f="$(mkretro oos-absent <<'EOF'
# retro

body, no marker here at all
EOF
)"
retro_marker_out_of_scope "$f" \
  && no "54 retro_marker_out_of_scope: genuinely absent → false" "returned true (false positive)" \
  || ok "54 retro_marker_out_of_scope: genuinely absent → false" "()"

# 55 — REGRESSION GUARD: an IN-SCOPE marker (case 37's real-corpus shape) → false, not out-of-scope.
retro_marker_out_of_scope "$f37path" \
  && no "55 retro_marker_out_of_scope: in-scope marker (case 37 fixture) → false" "returned true (false positive)" \
  || ok "55 retro_marker_out_of_scope: in-scope marker (case 37 fixture) → false" "()"

# 56 — MISSING FILE → false (absent-input), no error, never a crash.
retro_marker_out_of_scope "$ROOT/does-not-exist-$$.md" \
  && no "56 retro_marker_out_of_scope: missing file → false" "returned true" \
  || ok "56 retro_marker_out_of_scope: missing file → false" "()"

# ---------------------------------------------------------------------------
# UTF-8 BOM stripping (kit issue #1099) — retro_marker_scope_line and retro_marker_line must
# strip a leading BOM so a marker whose position is otherwise in scope is still found.

# 57 — BOM + H1 + blank + marker (real-corpus shape with a BOM prepended) → found IN SCOPE.
f="$ROOT/retro-bom-inscope.md"
printf '\xef\xbb\xbf# retro\n\n<!-- review-status: applied 2026-01-01 -->\nbody\n' > "$f"
sl57="$(retro_marker_scope_line "$f")"
[ "$sl57" = "<!-- review-status: applied 2026-01-01 -->" ] \
  && ok "57 retro_marker_scope_line: BOM + H1 + blank + marker → found in scope" "()" \
  || no "57 retro_marker_scope_line: BOM + H1 + blank + marker → found in scope" "got [$sl57]"

# 58 — BOM directly before the marker (no H1) → still found via retro_marker_line's whole-file
# scan (used by retro_marker_out_of_scope's second half).
f="$ROOT/retro-bom-direct.md"
printf '\xef\xbb\xbf<!-- review-status: applied 2026-01-01 -->\nbody\n' > "$f"
wl58="$(retro_marker_line "$f")"
[ "$wl58" = "<!-- review-status: applied 2026-01-01 -->" ] \
  && ok "58 retro_marker_line: BOM directly before marker → found" "()" \
  || no "58 retro_marker_line: BOM directly before marker → found" "got [$wl58]"

# ---------------------------------------------------------------------------
# Indented-code-block false refusal (kit issue #1125 item 1) — retro_marker_line's whole-file
# scan must not mistake a markdown INDENTED CODE BLOCK (4+ leading spaces / a tab) showing the
# marker syntax as documentation for a REAL marker. Before the fix, a retro with NO real marker
# that merely SHOWS the marker format as an indented example was refused by the seeder and gate,
# counted degraded by reconcile, and WARNed by sweep — all four read it as "marker exists but
# is out of scope", and the "move the marker into the leading block" advice made no sense because
# there was never a real marker to move.

# 59 — 4-space indented example marker, no real marker anywhere → retro_marker_line must NOT
#      find it (empty), so retro_marker_out_of_scope correctly reports "not out of scope" (the
#      retro is genuinely markerless, not misplaced).
f="$(mkretro indented-example-4sp <<'EOF'
# retro

Example marker format for reference:

    <!-- review-status: applied 2026-01-01 -->

body, no real marker anywhere in this file
EOF
)"
wl59="$(retro_marker_line "$f")"
oos59_rc=1; retro_marker_out_of_scope "$f" && oos59_rc=0
if [ -z "$wl59" ] && [ "$oos59_rc" = 1 ]; then
  ok "59 4-space indented example marker → retro_marker_line blind, not out-of-scope" "()"
else
  no "59 4-space indented example marker → expected blind + not out-of-scope" "wl=[$wl59] oos_rc=$oos59_rc"
fi

# 60 — TAB-indented example marker (same family as 59, different indent character) → also blind.
f="$(mkretro indented-example-tab <<'EOF'
# retro

Example marker format for reference:

	<!-- review-status: applied 2026-01-01 -->

body, no real marker anywhere in this file
EOF
)"
wl60="$(retro_marker_line "$f")"
[ -z "$wl60" ] && ok "60 tab-indented example marker → retro_marker_line blind" "()" \
              || no "60 tab-indented example marker → expected blind" "got [$wl60]"

# 61 — LIST-EDGE boundary: EXACTLY 3 leading spaces (not a code block per markdown's 4-space
#      rule) must still be FOUND — the fix narrows to '^ ? ? ?<!--', not '^<!--' outright.
f="$ROOT/retro-3sp-boundary.md"
printf '# retro\n\nbody\n\n   <!-- review-status: applied 2026-01-01 -->\n' > "$f"
wl61="$(retro_marker_line "$f")"
[ "$wl61" = "   <!-- review-status: applied 2026-01-01 -->" ] \
  && ok "61 LIST-EDGE: 3-space-indented marker (boundary) → still found" "()" \
  || no "61 LIST-EDGE: 3-space-indented marker (boundary) → expected found" "got [$wl61]"

# 62 — LIST-EDGE boundary: EXACTLY 4 leading spaces (the other side of the boundary) → NOT found.
f="$ROOT/retro-4sp-boundary.md"
printf '# retro\n\nbody\n\n    <!-- review-status: applied 2026-01-01 -->\n' > "$f"
wl62="$(retro_marker_line "$f")"
[ -z "$wl62" ] && ok "62 LIST-EDGE: 4-space-indented marker (boundary) → NOT found" "()" \
              || no "62 LIST-EDGE: 4-space-indented marker (boundary) → expected blind" "got [$wl62]"

# ---------------------------------------------------------------------------
# Shared first-line BOM reader (kit issue #1125 item 2) — every marker/exclude/waive/format
# reader in this file must strip a leading UTF-8 BOM the same way retro_marker_line and
# retro_marker_scope_line already do. Before the fix, retro_review_status, retro_is_excluded,
# retro_is_waived, and retro_has_bare_marker each read the file directly and silently missed a
# BOM'd marker.

# 63 — retro_review_status: BOM directly before the marker (line 1, no H1) → status found.
f="$ROOT/retro-bom-review-status.md"
printf '\xef\xbb\xbf<!-- review-status: applied 2026-01-01 -->\nbody\n' > "$f"
got63="$(retro_review_status "$f")"
[ "$got63" = "applied" ] && ok "63 retro_review_status: BOM directly before marker → applied" "()" \
                         || no "63 retro_review_status: BOM directly before marker → expected applied" "got [$got63]"

# 64 — retro_is_excluded: BOM directly before the exclude marker (line 1) → excluded (true).
f="$ROOT/retro-bom-excluded.md"
printf '\xef\xbb\xbf<!-- kit-retro: exclude -->\nbody\n' > "$f"
if retro_is_excluded "$f"; then
  ok "64 retro_is_excluded: BOM directly before exclude marker → excluded" "()"
else
  no "64 retro_is_excluded: BOM directly before exclude marker → expected excluded" ""
fi

# 65 — retro_is_waived: BOM directly before the waived marker (line 1) → waived (true).
f="$ROOT/retro-bom-waived.md"
printf '\xef\xbb\xbf<!-- retro-waived: 2026-01-01 · dormant target -->\nbody\n' > "$f"
if retro_is_waived "$f"; then
  ok "65 retro_is_waived: BOM directly before waived marker → waived" "()"
else
  no "65 retro_is_waived: BOM directly before waived marker → expected waived" ""
fi

# 66 — retro_has_bare_marker: BOM directly before a bare (non-HTML-comment) review-status: line
#      → detected as a bare marker (true).
f="$ROOT/retro-bom-bare-marker.md"
printf '\xef\xbb\xbfreview-status: applied\nbody\n' > "$f"
if retro_has_bare_marker "$f"; then
  ok "66 retro_has_bare_marker: BOM directly before bare marker → detected" "()"
else
  no "66 retro_has_bare_marker: BOM directly before bare marker → expected detected" ""
fi

# ---------------------------------------------------------------------------
# retro_marker_scope_line indent alignment (kit issue #1130 finding 3) — the ACTUAL status
# reader must apply the SAME indented-code-block anchor as retro_marker_line (item 1's own
# reasoning — "renders as a literal example, never an active HTML comment" — applies here too).
# Before this fix, a 4-space-indented marker in the leading block was still honoured as the
# real status, even though retro_marker_line (the whole-file scan) correctly refused it.

# 67 — LIST-EDGE boundary: EXACTLY 3 leading spaces in the leading block (not a code block per
#      markdown's 4-space rule) must still be FOUND in scope.
f="$(mkretro scope-3sp-boundary <<EOF
# retro

   <!-- review-status: applied 2026-01-01 -->
body
EOF
)"
sl67="$(retro_marker_scope_line "$f")"
[ "$sl67" = "   <!-- review-status: applied 2026-01-01 -->" ] \
  && ok "67 LIST-EDGE: retro_marker_scope_line, 3-space-indented marker (boundary) → still found in scope" "()" \
  || no "67 LIST-EDGE: retro_marker_scope_line, 3-space-indented marker (boundary) → expected found" "got [$sl67]"

# 68 — LIST-EDGE boundary: EXACTLY 4 leading spaces in the leading block (the other side of the
#      boundary, a markdown indented code block) must NOT be honoured as the real status.
f="$(mkretro scope-4sp-boundary <<EOF
# retro

    <!-- review-status: applied 2026-01-01 -->
body
EOF
)"
sl68="$(retro_marker_scope_line "$f")"
[ -z "$sl68" ] \
  && ok "68 LIST-EDGE: retro_marker_scope_line, 4-space-indented marker (boundary) → NOT honoured in scope" "()" \
  || no "68 LIST-EDGE: retro_marker_scope_line, 4-space-indented marker (boundary) → expected not found" "got [$sl68]"

# ---------------------------------------------------------------------------
# CommonMark-style fence tracking in retro_marker_line (kit issues #949 item 3 / #1304 item 6).
# A fence opens with 3+ backticks or tildes (info string allowed), closes ONLY on a line of the
# SAME character, at least as long as the opener, with nothing but whitespace after it. A fence
# that never closes fails CLOSED: a marker-shaped line inside it is returned (so
# retro_marker_out_of_scope refuses) instead of vanishing and letting an applied retro read as
# genuinely markerless (the #1048-#1089 flood direction).
M69="<!-- review-status: applied 2026-01-01 · kit abc1234 -->"

# 69 — a '~~~' fence containing a ``` line: the ``` is CONTENT, the fence closes at the second
#      '~~~', so the marker after it is a real (out-of-scope) marker and must be found.
f="$(mkretro fence-tilde-with-backtick <<EOF
# retro

~~~
\`\`\`
~~~

$M69
EOF
)"
got="$(retro_marker_line "$f")"
[ "$got" = "$M69" ] && ok "69 ~~~ fence containing a \`\`\` line → marker after it found" "()" \
                    || no "69 ~~~ fence containing a \`\`\` line → marker after it found" "got [$got]"

# 70 — a four-backtick fence wrapping a three-backtick example: the inner ``` is content.
f="$(mkretro fence-4tick-wrapping-3tick <<EOF
# retro

\`\`\`\`
\`\`\`
example
\`\`\`
\`\`\`\`

$M69
EOF
)"
got="$(retro_marker_line "$f")"
[ "$got" = "$M69" ] && ok "70 4-backtick fence wrapping a 3-backtick example → marker after found" "()" \
                    || no "70 4-backtick fence wrapping a 3-backtick example → marker after found" "got [$got]"

# 71 — UNCLOSED fence with a marker-shaped line inside: fail closed — the line is returned, so
#      the out-of-scope check refuses the retro rather than reading it as markerless.
f="$(mkretro fence-unclosed-with-marker <<EOF
# retro

\`\`\`
stray opener never closed

$M69
EOF
)"
got="$(retro_marker_line "$f")"
oos=1; retro_marker_out_of_scope "$f" && oos=0
[ "$got" = "$M69" ] && [ "$oos" = 0 ] \
  && ok "71 unclosed fence before the marker → fails closed (returned, out-of-scope)" "()" \
  || no "71 unclosed fence before the marker → fails closed" "got [$got] oos_rc=$oos"

# 72 — LIST-EDGE: unclosed fence with NO marker-shaped line inside → empty, NOT out-of-scope (no
#      false refusal of a genuinely markerless retro).
f="$(mkretro fence-unclosed-no-marker <<'EOF'
# retro

```
stray opener never closed, nothing marker-shaped in it
EOF
)"
got="$(retro_marker_line "$f")"
oos=1; retro_marker_out_of_scope "$f" && oos=0
[ -z "$got" ] && [ "$oos" = 1 ] \
  && ok "72 unclosed fence with no marker inside → empty, not out-of-scope" "()" \
  || no "72 unclosed fence with no marker inside → empty, not out-of-scope" "got [$got] oos_rc=$oos"

# 73 — a marker inside a CLOSED fence is documentation; the real one after the fence wins.
f="$(mkretro fence-closed-then-real <<EOF
# retro

\`\`\`
<!-- review-status: pending -->
\`\`\`

$M69
EOF
)"
got="$(retro_marker_line "$f")"
[ "$got" = "$M69" ] && ok "73 marker inside a closed fence skipped; real marker after it returned" "()" \
                    || no "73 marker inside a closed fence skipped; real marker after it returned" "got [$got]"

# 74 — a closer LONGER than the opener is a valid close (info string on the opener too).
f="$(mkretro fence-longer-closer <<EOF
# retro

\`\`\`bash
echo hi
\`\`\`\`\`

$M69
EOF
)"
got="$(retro_marker_line "$f")"
[ "$got" = "$M69" ] && ok "74 info-string opener + longer closer closes the fence → marker after found" "()" \
                    || no "74 info-string opener + longer closer closes the fence → marker after found" "got [$got]"

# 75 — a closer with trailing text is NOT a closer (CommonMark): the fence stays open to EOF and
#      the marker-shaped line inside it fails closed.
f="$(mkretro fence-closer-trailing-text <<EOF
# retro

\`\`\`
content
\`\`\` not a closer

$M69
EOF
)"
got="$(retro_marker_line "$f")"
[ "$got" = "$M69" ] && ok "75 closer with trailing text does not close; unclosed → fails closed" "()" \
                    || no "75 closer with trailing text does not close; unclosed → fails closed" "got [$got]"

# 76 — inline triple-backtick code on one line is NOT a fence opener (backtick info strings may
#      not contain backticks): the marker after it must still be found.
f="$(mkretro fence-inline-code <<EOF
# retro

use \`\`\`code\`\`\` inline
\`\`\`code\`\`\`

$M69
EOF
)"
got="$(retro_marker_line "$f")"
[ "$got" = "$M69" ] && ok "76 inline \`\`\`code\`\`\` line is not a fence → marker after found" "()" \
                    || no "76 inline \`\`\`code\`\`\` line is not a fence → marker after found" "got [$got]"

# 77 — LIST-EDGE: opener as the very last line (nothing inside) → empty, not out-of-scope.
f="$ROOT/retro-fence-last-line.md"
printf '# retro\n\nbody\n\n```' > "$f"
got="$(retro_marker_line "$f")"
oos=1; retro_marker_out_of_scope "$f" && oos=0
[ -z "$got" ] && [ "$oos" = 1 ] \
  && ok "77 fence opener as the last line (no trailing newline) → empty, not out-of-scope" "()" \
  || no "77 fence opener as the last line → empty, not out-of-scope" "got [$got] oos_rc=$oos"

# 78 — LIST-EDGE: a closed fence FIRST, an unclosed one LAST; only the unclosed one holds a marker.
f="$(mkretro fence-closed-first-unclosed-last <<EOF
# retro

~~~
closed
~~~

~~~
$M69
EOF
)"
got="$(retro_marker_line "$f")"
[ "$got" = "$M69" ] && ok "78 closed fence first, unclosed fence last holding a marker → fails closed" "()" \
                    || no "78 closed fence first, unclosed fence last holding a marker → fails closed" "got [$got]"

# 79 — a marker-shaped line inside a 4-backtick fence AFTER an inner ``` line is still inside the
#      fence (the shorter ``` cannot close it) → skipped; nothing outside → empty.
f="$(mkretro fence-4tick-decoy <<EOF
# retro

\`\`\`\`
\`\`\`
$M69
\`\`\`\`
EOF
)"
got="$(retro_marker_line "$f")"
[ -z "$got" ] && ok "79 decoy inside a 4-backtick fence after an inner \`\`\` line → skipped" "()" \
              || no "79 decoy inside a 4-backtick fence after an inner \`\`\` line → skipped" "got [$got]"

# 80 — a decoy after a would-be closer with trailing text, then the real closer → still inside.
f="$(mkretro fence-trailing-text-decoy <<EOF
# retro

\`\`\`
\`\`\` not a closer
$M69
\`\`\`
EOF
)"
got="$(retro_marker_line "$f")"
[ -z "$got" ] && ok "80 decoy after a trailing-text pseudo-closer, real closer later → skipped" "()" \
              || no "80 decoy after a trailing-text pseudo-closer, real closer later → skipped" "got [$got]"

# 81 — a decoy inside a '~~~' fence after a ``` line (different character, not a closer).
f="$(mkretro fence-tilde-decoy <<EOF
# retro

~~~
\`\`\`
$M69
~~~
EOF
)"
got="$(retro_marker_line "$f")"
[ -z "$got" ] && ok "81 decoy inside a ~~~ fence after a \`\`\` line → skipped" "()" \
              || no "81 decoy inside a ~~~ fence after a \`\`\` line → skipped" "got [$got]"

# 82 — an inline \`\`\`code\`\`\` line must not open a fence: the later closed fence holds a decoy
#      ('pending'), the real marker ('applied') follows it; the real one must be returned.
f="$(mkretro fence-inline-then-decoy <<EOF
# retro

\`\`\`code\`\`\`

\`\`\`
<!-- review-status: pending -->
\`\`\`

$M69
EOF
)"
got="$(retro_marker_line "$f")"
[ "$got" = "$M69" ] && ok "82 inline \`\`\`code\`\`\` does not open a fence; decoy skipped, real marker returned" "()" \
                    || no "82 inline \`\`\`code\`\`\` does not open a fence; decoy skipped, real marker returned" "got [$got]"

# 83 — case-insensitive match (kit issue #949 item 4): an UPPERCASE '<!-- REVIEW-STATUS:' marker
#      outside any fence is still a marker.
f="$(mkretro upper-case-marker <<'EOF'
# retro

body

<!-- REVIEW-STATUS: applied 2026-01-01 · kit abc1234 -->
EOF
)"
got="$(retro_marker_line "$f")"
[ "$got" = "<!-- REVIEW-STATUS: applied 2026-01-01 · kit abc1234 -->" ] \
  && ok "83 uppercase REVIEW-STATUS marker → found (case-insensitive)" "()" \
  || no "83 uppercase REVIEW-STATUS marker → found (case-insensitive)" "got [$got]"

# 84 — CRLF line endings (kit issue #1304, Opus review of #1315 note a): a closer line is
#      '```\r', so the closer test must tolerate the CR. A CRLF fence that holds a documented
#      example marker must CLOSE, so the real marker after it wins (before the fix the fence never
#      closed: the decoy inside was returned by the fail-closed END rule instead).
f="$ROOT/retro-crlf-fence.md"
printf '# retro\r\n\r\n```\r\n<!-- review-status: pending -->\r\n```\r\n\r\n<!-- review-status: applied 2026-01-01 -->\r\n' > "$f"
got="$(retro_marker_line "$f" | tr -d '\r')"
[ "$got" = "<!-- review-status: applied 2026-01-01 -->" ] \
  && ok "84 CRLF closed fence holding a decoy marker → real marker after it returned" "()" \
  || no "84 CRLF closed fence holding a decoy marker → real marker after it returned" "got [$got]"

# 85 — LIST-EDGE: CRLF fence holding a decoy and NOTHING after it → empty, not out-of-scope.
f="$ROOT/retro-crlf-fence-only.md"
printf '# retro\r\n\r\n~~~\r\n<!-- review-status: pending -->\r\n~~~\r\n' > "$f"
got="$(retro_marker_line "$f")"
oos=1; retro_marker_out_of_scope "$f" && oos=0
[ -z "$got" ] && [ "$oos" = 1 ] \
  && ok "85 CRLF closed fence holding only a decoy marker → empty, not out-of-scope" "()" \
  || no "85 CRLF closed fence holding only a decoy marker → empty, not out-of-scope" "got [$got] oos_rc=$oos"

# ---------------------------------------------------------------------------
# 86-110 — DISMISSED ids in a PARTIAL marker (kit issue #1944). A row listed after 'DISMISSED:' is
#     resolved (neither shipped nor open): retro_marker_row_state must say 'dismissed' so a consumer
#     can skip it as "no-match: dismissed" instead of seeding it. List edges: first / middle / last
#     / single position, plus the fleet marker shape (DISMISSED between shipped: and DEFERRED:).
#     retro_marker_row_state answers exactly one of shipped | dismissed | open | not-partial | malformed.
dm='<!-- review-status: applied 2026-09-05 · kit abc1234 · PARTIAL — shipped: 3; DISMISSED: #1, #4, #9, #12; DEFERRED: 7 -->'
got="$(retro_marker_dismissed_ids "$dm" | paste -sd, -)"
[ "$got" = "1,4,9,12" ] && ok "86 DISMISSED list → normalized ids (# stripped, order kept)" "(got '$got')" \
                       || no "86 DISMISSED list → normalized ids" "got '$got'"
for pair in "1:FIRST" "4:MIDDLE" "9:MIDDLE2" "12:LAST"; do
  rid="${pair%%:*}"; pos="${pair##*:}"
  got="$(retro_marker_row_state "$dm" "$rid")"
  [ "$got" = "dismissed" ] && ok "87 row $rid ($pos in DISMISSED list) → dismissed" "()" \
                           || no "87 row $rid ($pos in DISMISSED list) → dismissed" "got '$got'"
done
got="$(retro_marker_row_state "$dm" 3)"
[ "$got" = "shipped" ] && ok "88 row in shipped: → shipped" "()" || no "88 row in shipped: → shipped" "got '$got'"
got="$(retro_marker_row_state "$dm" 7)"
[ "$got" = "open" ] && ok "89 DEFERRED row stays open (not dismissed)" "()" || no "89 DEFERRED row stays open" "got '$got'"
got="$(retro_marker_row_state "$dm" 2)"
[ "$got" = "open" ] && ok "90 unlisted row stays open" "()" || no "90 unlisted row stays open" "got '$got'"
got="$(retro_marker_row_state "$dm" 1x)"
[ "$got" = "open" ] && ok "91 id prefix is not a match (1x vs 1) → open" "()" || no "91 id prefix is not a match" "got '$got'"

sm='<!-- review-status: applied 2026-09-05 · kit abc1234 · PARTIAL — shipped: 1, 3; DISMISSED: #2 -->'
got="$(retro_marker_dismissed_ids "$sm" | paste -sd, -)"
[ "$got" = "2" ] && ok "92 SINGLE-element DISMISSED list" "(got '$got')" || no "92 single-element DISMISSED list" "got '$got'"
got="$(retro_marker_row_state "$sm" 2)"
[ "$got" = "dismissed" ] && ok "93 single dismissed row → dismissed" "()" || no "93 single dismissed row" "got '$got'"

# 94 — the fleet shape: parenthetical annotations (with em dash and commas inside) after each id
#      must not leak ids or swallow the DISMISSED segment.
f="$HERE/fixtures/retro-status/partial-dismissed-fleet-shape.md"
fm="$(retro_marker_scope_line "$f")"
got="$(for r in 1 2 3 4 5 6 7; do printf '%s=%s ' "$r" "$(retro_marker_row_state "$fm" "$r")"; done)"
want='1=shipped 2=dismissed 3=shipped 4=shipped 5=shipped 6=shipped 7=open '
[ "$got" = "$want" ] && ok "94 fleet-shape retro: #2 dismissed, #7 DEFERRED stays open" "()" \
                     || no "94 fleet-shape retro marker row states" "got [$got] want [$want]"

# 95 — a ';' INSIDE a parenthetical annotation must not truncate the DISMISSED list.
pm='<!-- review-status: applied 2026-07-29 · kit cc5e13a · shipped: 1; DISMISSED: #4 (already enforced; mechanization deferred), #5 -->'
got="$(retro_marker_dismissed_ids "$pm" | paste -sd, -)"
[ "$got" = "4,5" ] && ok "95 ';' inside a parenthetical does not truncate the list" "(got '$got')" \
                   || no "95 ';' inside a parenthetical" "got '$got'"

# 96 — no DISMISSED keyword (lowercase 'dismissed:' inside prose or a parenthetical is not one) → no ids, rc 0.
for np in '<!-- review-status: applied 2026-09-05 · kit abc · PARTIAL — shipped: 1 -->' \
          '<!-- review-status: applied 2026-09-05 · kit abc · PARTIAL — shipped: 1 (dismissed: 2 was dropped) -->' \
          '<!-- review-status: applied 2026-09-05 · kit abc · shipped: 1 — dismissed: 2 -->' \
          ''; do
  got="$(retro_marker_dismissed_ids "$np")"; rc=$?
  [ -z "$got" ] && [ "$rc" = 0 ] && ok "96 no DISMISSED keyword → no ids, rc 0" "($(printf '%.40s' "$np"))" \
                || no "96 no DISMISSED keyword → no ids, rc 0" "got '$got' rc=$rc for '$np'"
done

# 97 — an empty row id or an empty marker line is MALFORMED input (§7: a typed answer, never a false open/dismissed).
got="$(retro_marker_row_state "$sm" "")"
[ "$got" = "malformed" ] && ok "97 empty row id → malformed (never open, never dismissed)" "()" || no "97 empty row id → malformed" "got '$got'"
got="$(retro_marker_row_state "" 2)"
[ "$got" = "malformed" ] && ok "97b empty marker line → malformed" "()" || no "97b empty marker line → malformed" "got '$got'"

# 98 — precondition: row_state describes a PARTIAL marker. A plain applied/dismissed status marker is not-partial
#      (typed), even when it carries a DISMISSED: list: the consumers close such a retro by its status instead.
for np in '<!-- review-status: applied 2026-09-05 · kit abc · DISMISSED: #2 -->' \
          '<!-- review-status: dismissed 2026-09-05 · all absorbed; DISMISSED: #2 -->'; do
  got="$(retro_marker_row_state "$np" 2)"
  [ "$got" = "not-partial" ] && ok "98 non-PARTIAL marker → not-partial" "($(printf '%.45s' "$np"))" \
                             || no "98 non-PARTIAL marker → not-partial" "got '$got' for '$np'"
done

# 99 — EVERY DISMISSED segment is read, joined before normalising (a second segment after DEFERRED).
mm='<!-- review-status: applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: #2; DEFERRED: #7; DISMISSED: #9 -->'
got="$(retro_marker_dismissed_ids "$mm" | paste -sd, -)"
[ "$got" = "2,9" ] && ok "99 two DISMISSED segments → 2 and 9" "(got '$got')" || no "99 two DISMISSED segments" "got '$got'"
got="$(for r in 2 7 9; do printf '%s=%s ' "$r" "$(retro_marker_row_state "$mm" "$r")"; done)"
[ "$got" = "2=dismissed 7=open 9=dismissed " ] && ok "99b second segment's id is dismissed, DEFERRED stays open" "()" || no "99b second segment" "got [$got]"

# 100 — nested parentheses are stripped innermost-first; a ';' inside them cannot truncate the list.
nm='<!-- review-status: applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: #2 (x (y); z), #5; DEFERRED: #7 -->'
got="$(retro_marker_dismissed_ids "$nm" | paste -sd, -)"
[ "$got" = "2,5" ] && ok "100 nested parentheses → 2 and 5" "(got '$got')" || no "100 nested parentheses" "got '$got'"

# 101 — malformed list (§7): the keyword with an empty list or only a parenthetical is TYPED, not "no dismissed ids".
for bm in '<!-- review-status: applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: ; DEFERRED: #7 -->' \
          '<!-- review-status: applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: (only a reason) -->' \
          '<!-- review-status: applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: -->'; do
  got="$(retro_marker_dismissed_ids "$bm")"; rc=$?
  [ -z "$got" ] && [ "$rc" = 3 ] && ok "101 DISMISSED with no usable id → rc 3, no ids" "($(printf '%.50s' "${bm#*PARTIAL}"))" \
                                 || no "101 DISMISSED with no usable id → rc 3" "got '$got' rc=$rc for '$bm'"
  got="$(retro_marker_row_state "$bm" 2)"
  [ "$got" = "malformed" ] && ok "101b row not shipped under a malformed list → malformed" "()" || no "101b malformed list row state" "got '$got'"
done
got="$(retro_marker_row_state "$bm" 1)"
[ "$got" = "shipped" ] && ok "101c a shipped row still reads shipped under a malformed DISMISSED list" "()" || no "101c shipped under malformed list" "got '$got'"

# 102 — an id in BOTH sets reads shipped (it did ship); DISMISSED written BEFORE shipped: is still read.
bs='<!-- review-status: applied 2026-09-05 · PARTIAL — DISMISSED: #2, #3; shipped: 2, 5 -->'
got="$(for r in 2 3 5; do printf '%s=%s ' "$r" "$(retro_marker_row_state "$bs" "$r")"; done)"
[ "$got" = "2=shipped 3=dismissed 5=shipped " ] && ok "102 id in both sets → shipped; DISMISSED before shipped: read" "()" || no "102 both sets / order" "got [$got]"

# 103 — letter ids, hyphenated ids and numeric ranges (the normaliser is the shipped-id one).
lm='<!-- review-status: applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: D3, SPKI-A, R1 -->'
got="$(for r in D3 SPKI-A R1 D4; do printf '%s=%s ' "$r" "$(retro_marker_row_state "$lm" "$r")"; done)"
[ "$got" = "D3=dismissed SPKI-A=dismissed R1=dismissed D4=open " ] && ok "103 letter/hyphen ids are dismissed" "()" || no "103 letter ids" "got [$got]"
rm_='<!-- review-status: applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: D1-D3 -->'
got="$(for r in D1 D2 D3 D4; do printf '%s=%s ' "$r" "$(retro_marker_row_state "$rm_" "$r")"; done)"
[ "$got" = "D1=dismissed D2=dismissed D3=dismissed D4=open " ] && ok "103b range D1-D3 → D1,D2,D3 dismissed" "()" || no "103b numeric range" "got [$got]"

# 104 — no spaces after the colon / commas; a '-->' inside a parenthetical reason does not close the marker early.
ns='<!-- review-status: applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED:#2,#3 -->'
got="$(retro_marker_dismissed_ids "$ns" | paste -sd, -)"
[ "$got" = "2,3" ] && ok "104 DISMISSED:#2,#3 without spaces → 2,3" "(got '$got')" || no "104 no-space list" "got '$got'"
am='<!-- review-status: applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: #2 (a --> b), #3 -->'
got="$(retro_marker_dismissed_ids "$am" | paste -sd, -)"
[ "$got" = "2,3" ] && ok "104b '-->' inside a reason does not truncate the list" "(got '$got')" || no "104b arrow in reason" "got '$got'"

# 105 — retro_marker_shipped_raw: ONE extraction of the shipped: list for row_state and both consumers.
#       First match only, parentheticals KEPT (consumer parity), cut at ';' or '>'; nothing for a line without it.
got="$(retro_marker_shipped_raw '<!-- review-status: applied · PARTIAL — shipped: #1 (a), #3; DISMISSED: #2 -->')"
[ "$got" = "#1 (a), #3" ] && ok "105 shipped_raw keeps parentheticals, cuts at ';'" "(got '$got')" || no "105 shipped_raw" "got '$got'"
got="$(retro_marker_shipped_raw '<!-- review-status: pending -->')"; rc=$?
[ -z "$got" ] && [ "$rc" = 0 ] && ok "105b shipped_raw without a shipped: list → nothing, rc 0" "()" || no "105b shipped_raw none" "got '$got' rc=$rc"

# ---------------------------------------------------------------------------
# TEETH (negative controls) for the two shared marker-parsing helpers.
if [ "${1:-}" = "--prove-teeth" ]; then
  # Tooth P1: drop the free-text CUT (the sed that trims at '—'/'shipped:'/'(') from
  # retro_marker_is_partial, so the whole-line PARTIAL check runs unscoped. The #1090 repro
  # marker (case 27) has no literal uppercase PARTIAL anywhere, so this tooth alone would not
  # flip it — instead prove the cut is load-bearing with a marker that DOES carry an uppercase
  # PARTIAL only in its free text (case 30's fixture): without the cut, the whole-line
  # case-sensitive check finds it and false-positives.
  echo "-- teeth P1: drop the structured-segment cut in retro_marker_is_partial; free-text PARTIAL (case 30) must false-positive --"
  if ! grep -qF "RETRO_MARKER_PARTIAL_STRUCTURED_CUT" "$HELPER"; then
    no "teeth P1: locate RETRO_MARKER_PARTIAL_STRUCTURED_CUT anchor" "anchor not found — helper drifted?"
  else
    p1_mutant="$ROOT/retro-status.p1.sh"
    sed "s/structured=\"\$(printf '%s' \"\$body\" | sed -E 's\/(—|shipped:|\\\\().*\$\/\/')\"/structured=\"\$body\"/" "$HELPER" > "$p1_mutant"
    if diff -q "$HELPER" "$p1_mutant" >/dev/null 2>&1; then
      no "teeth P1: build cut-removed mutant" "mutant identical — sed substitution failed"
    elif ! "$BASH_BIN" -n "$p1_mutant" 2>/dev/null; then
      no "teeth P1: build cut-removed mutant" "mutant syntax error"
    else
      outp1="$("$BASH_BIN" -c '. "$1"; retro_marker_is_partial "$2"; echo $?' _ "$p1_mutant" "$m30" 2>&1)"
      if [ "$outp1" = "0" ]; then
        ok "teeth P1: cut-removed mutant false-positives on free-text PARTIAL (case 30 has teeth)" "()"
      else
        no "teeth P1: cut-removed mutant should false-positive on free-text PARTIAL" \
          "returned '$outp1' (expected 0) — case 30 is THEATER"
      fi
    fi
  fi

  # Tooth P2: relax the case-sensitive PARTIAL grep to case-insensitive. The #1090 repro
  # marker's structured segment has no 'PARTIAL' at all (only free-text lowercase 'partial'
  # AFTER the cut), so this tooth alone does not flip case 27 — use a fixture with lowercase
  # 'partial' INSIDE the structured segment instead, to isolate case-sensitivity from the cut.
  echo "-- teeth P2: relax PARTIAL grep to case-insensitive; lowercase token in structured segment must false-positive --"
  p2_linenum="$(grep -n "grep -qE '(\^|\[\^A-Za-z\])PARTIAL" "$HELPER" | head -1 | cut -d: -f1)"
  if [ -z "$p2_linenum" ]; then
    no "teeth P2: locate the case-sensitive PARTIAL grep" "anchor not found — helper drifted?"
  else
    p2_mutant="$ROOT/retro-status.p2.sh"
    # Replace ONLY the '-qE' flag with '-qiE' on that exact line (line-number targeted, no
    # pattern-escaping fragility): the rest of the line is left untouched.
    awk -v ln="$p2_linenum" '{ if (NR==ln) { sub(/grep -qE/, "grep -qiE") } print }' "$HELPER" > "$p2_mutant"
    if diff -q "$HELPER" "$p2_mutant" >/dev/null 2>&1; then
      no "teeth P2: build case-insensitive mutant" "mutant identical — substitution failed"
    else
      m_p2='<!-- review-status: applied 2026-01-01 · kit abc1234 · partial -->'
      outp2="$("$BASH_BIN" -c '. "$1"; retro_marker_is_partial "$2"; echo $?' _ "$p2_mutant" "$m_p2" 2>&1)"
      if [ "$outp2" = "0" ]; then
        ok "teeth P2: case-insensitive mutant false-positives on lowercase structured token (case 26/30 have teeth)" "()"
      else
        no "teeth P2: case-insensitive mutant should false-positive" "returned '$outp2' (expected 0) — THEATER"
      fi
    fi
  fi

  # Tooth S1: drop the '#' strip from retro_marker_shipped_ids's bash loop (kit issue #1093 item 5
  # rewrite — pure bash now, no awk). '#1, #2' must then be returned WITH the hash still attached
  # ('#1'/'#2'), proving case 33 has teeth.
  echo "-- teeth S1: drop the leading '#' strip in retro_marker_shipped_ids; hash must survive (case 33 has teeth) --"
  if ! grep -qF 'RETRO_MARKER_SHIPPED_IDS_HASH_STRIP' "$HELPER"; then
    no "teeth S1: locate the RETRO_MARKER_SHIPPED_IDS_HASH_STRIP anchor" "anchor not found — helper drifted?"
  else
    s1_mutant="$ROOT/retro-status.s1.sh"
    sed '/t="\${t#\\#}"/d' "$HELPER" > "$s1_mutant"
    if diff -q "$HELPER" "$s1_mutant" >/dev/null 2>&1; then
      no "teeth S1: build hash-strip-removed mutant" "mutant identical — sed substitution failed"
    elif ! "$BASH_BIN" -n "$s1_mutant" 2>/dev/null; then
      no "teeth S1: build hash-strip-removed mutant" "mutant syntax error"
    else
      outs1="$("$BASH_BIN" -c '. "$1"; retro_marker_shipped_ids "$2"' _ "$s1_mutant" '#1, #2' 2>&1)"
      if <<<"$outs1" grep -q '^#1$'; then
        ok "teeth S1: hash-strip-removed mutant leaves '#1' attached (case 33 has teeth)" "(got [$outs1])"
      else
        no "teeth S1: hash-strip-removed mutant should leave '#1' attached" "got [$outs1] — case 33 is THEATER"
      fi
    fi
  fi

  # Tooth S2: drop the parenthetical-strip sed stage from retro_marker_shipped_ids's `stripped=`
  # pipeline (kit issue #1093 item 5 rewrite). 'Δ1 (#549)' must then leak the annotation as
  # spurious extra tokens, proving case 34 has teeth.
  echo "-- teeth S2: drop the parenthetical-annotation strip in retro_marker_shipped_ids; annotation must leak (case 34 has teeth) --"
  if ! grep -qF 'RETRO_MARKER_SHIPPED_IDS_PAREN_STRIP' "$HELPER"; then
    no "teeth S2: locate the RETRO_MARKER_SHIPPED_IDS_PAREN_STRIP anchor" "anchor not found — helper drifted?"
  else
    s2_mutant="$ROOT/retro-status.s2.sh"
    # Replace the paren-strip sed stage with a no-op passthrough (cat) — the pipeline shape stays
    # intact (still syntactically valid), only the strip itself is removed.
    sed "s/sed -E 's\/\[\[:space:\]\]\*\\\\(\[^)\]\*\\\\)\/\/g'/cat/" "$HELPER" > "$s2_mutant"
    if diff -q "$HELPER" "$s2_mutant" >/dev/null 2>&1; then
      no "teeth S2: build paren-strip-removed mutant" "mutant identical — substitution failed"
    elif ! "$BASH_BIN" -n "$s2_mutant" 2>/dev/null; then
      no "teeth S2: build paren-strip-removed mutant" "mutant syntax error"
    else
      outs2="$("$BASH_BIN" -c '. "$1"; retro_marker_shipped_ids "$2"' _ "$s2_mutant" 'Δ1 (#549)' 2>&1)"
      if <<<"$outs2" grep -qF '#549'; then
        ok "teeth S2: paren-strip-removed mutant leaks the annotation (case 34 has teeth)" "(got [$outs2])"
      else
        no "teeth S2: paren-strip-removed mutant should leak the annotation" "got [$outs2] — case 34 is THEATER"
      fi
    fi
  fi

  # Tooth SC1 (kit issue #945): drop the two NR==1 H1-skip rules from retro_marker_scope_line.
  # Case 37's H1+blank+marker fixture must then find NOTHING — the H1 line becomes the block
  # terminator again, exactly the pre-#945 bug.
  echo "-- teeth SC1: drop the H1-skip rules in retro_marker_scope_line; case 37 must go blind --"
  if ! grep -qF 'RETRO_MARKER_SCOPE_H1_SKIP' "$HELPER"; then
    no "teeth SC1: locate the RETRO_MARKER_SCOPE_H1_SKIP anchor" "anchor not found — helper drifted?"
  else
    sc1_mutant="$ROOT/retro-status.sc1.sh"
    sed '/NR==1 && \/\^\[\[:space:\]\]\*#/d' "$HELPER" > "$sc1_mutant"
    if diff -q "$HELPER" "$sc1_mutant" >/dev/null 2>&1; then
      no "teeth SC1: build H1-skip-removed mutant" "mutant identical — sed substitution failed"
    elif ! "$BASH_BIN" -n "$sc1_mutant" 2>/dev/null; then
      no "teeth SC1: build H1-skip-removed mutant" "mutant syntax error"
    else
      outsc1="$("$BASH_BIN" -c '. "$1"; retro_marker_scope_line "$2"' _ "$sc1_mutant" "$f37path" 2>&1)"
      if [ -z "$outsc1" ]; then
        ok "teeth SC1: H1-skip-removed mutant goes blind on case 37's fixture (has teeth)" "()"
      else
        no "teeth SC1: H1-skip-removed mutant should go blind on case 37's fixture" "got [$outsc1] — case 37 is THEATER"
      fi
    fi
  fi

  # Tooth SH1 (kit issue #1093 item 2): revert the 'shipped:' scoping to the pre-fix UNSCOPED
  # whole-body check. Case 44's prose-'shipped:'-after-dash fixture must then false-positive.
  echo "-- teeth SH1: revert 'shipped:' scoping to unscoped whole-body check; case 44 must false-positive --"
  if ! grep -qF 'RETRO_MARKER_SHIPPED_STRUCTURED_CUT' "$HELPER"; then
    no "teeth SH1: locate the RETRO_MARKER_SHIPPED_STRUCTURED_CUT anchor" "anchor not found — helper drifted?"
  else
    sh1_mutant="$ROOT/retro-status.sh1.sh"
    sed "s/structured_for_shipped=\"\$(printf '%s' \"\$body\" | sed -E 's\/(—|\\\\().\*\$\/\/')\"/structured_for_shipped=\"\$body\"/" \
      "$HELPER" > "$sh1_mutant"
    if diff -q "$HELPER" "$sh1_mutant" >/dev/null 2>&1; then
      no "teeth SH1: build unscoped-shipped mutant" "mutant identical — sed substitution failed"
    elif ! "$BASH_BIN" -n "$sh1_mutant" 2>/dev/null; then
      no "teeth SH1: build unscoped-shipped mutant" "mutant syntax error"
    else
      outsh1="$("$BASH_BIN" -c '. "$1"; retro_marker_is_partial "$2"; echo $?' _ "$sh1_mutant" "$m44" 2>&1)"
      if [ "$outsh1" = "0" ]; then
        ok "teeth SH1: unscoped-shipped mutant false-positives on case 44's prose 'shipped:' (has teeth)" "()"
      else
        no "teeth SH1: unscoped-shipped mutant should false-positive on case 44" "returned '$outsh1' (expected 0) — THEATER"
      fi
    fi
  fi

  # Tooth OOS1 (kit issue #1099): neuter retro_marker_out_of_scope's whole-file-scan check (the
  # 'retro_marker_line' call) so it always reports "not out of scope" — case 51's out-of-scope
  # fixture must then go blind (return false), reproducing the pre-#1099 silent-absent conflation.
  echo "-- teeth OOS1: neuter retro_marker_out_of_scope's whole-file-scan check; case 51 must go blind --"
  anchor_oos1='[ -n "$(retro_marker_line "$f")" ]'
  if grep -qF "$anchor_oos1" "$HELPER"; then
    oos1_mutant="$ROOT/retro-status.oos1.sh"
    sed "s/\[ -n \"\$(retro_marker_line \"\$f\")\" \]/false/" "$HELPER" > "$oos1_mutant"
    if diff -q "$HELPER" "$oos1_mutant" >/dev/null 2>&1; then
      no "teeth OOS1: build whole-file-check-removed mutant" "mutant identical — sed substitution failed"
    elif ! "$BASH_BIN" -n "$oos1_mutant" 2>/dev/null; then
      no "teeth OOS1: build whole-file-check-removed mutant" "mutant syntax error"
    else
      f_oos1_middle="$(mkretro oos1-middle <<'EOF'
# retro

## Background

Narrative paragraph before the marker.

<!-- review-status: applied 2026-01-01 -->

## More notes

Narrative content after the marker.
EOF
      )"
      outoos1="$("$BASH_BIN" -c '. "$1"; retro_marker_out_of_scope "$2"; echo $?' _ "$oos1_mutant" "$f_oos1_middle" 2>&1)"
      if [ "$outoos1" = "1" ]; then
        ok "teeth OOS1: whole-file-check-removed mutant goes blind (case 51 has teeth)" "()"
      else
        no "teeth OOS1: whole-file-check-removed mutant should go blind (return false)" \
          "returned '$outoos1' (expected 1) — case 51 is THEATER"
      fi
    fi
  else
    no "teeth OOS1: locate the retro_marker_line call inside retro_marker_out_of_scope" "anchor not found — helper drifted?"
  fi

  # Tooth BOM1 (kit issue #1099; extended by #1125 item 5): drop the leading-BOM strip from the
  # shared _retro_status_strip_bom reader (kit issue #1125 item 2 — every one of the six readers
  # in this file now goes through it, so neutering it once blinds all six). Case 57's
  # BOM-prefixed real-corpus fixture (retro_marker_scope_line) must then go blind, AND case 58's
  # fixture (retro_marker_line, used by retro_marker_out_of_scope's whole-file half) must ALSO go
  # blind — before #1125 item 5, case 58 had no mutation control of its own.
  echo "-- teeth BOM1: drop the BOM strip in the shared reader; cases 57 and 58 must go blind --"
  if ! grep -qF 'RETRO_MARKER_BOM_STRIP' "$HELPER"; then
    no "teeth BOM1: locate the RETRO_MARKER_BOM_STRIP anchor" "anchor not found — helper drifted?"
  else
    bom1_mutant="$ROOT/retro-status.bom1.sh"
    # Replace the ONE BOM-stripping sed stage (inside _retro_status_strip_bom) with a no-op cat.
    sed "s/sed \$'1s\/\^\\\\xef\\\\xbb\\\\xbf\/\/' \"\$f\" 2>\/dev\/null/cat \"\$f\" 2>\/dev\/null/g" \
      "$HELPER" > "$bom1_mutant"
    if diff -q "$HELPER" "$bom1_mutant" >/dev/null 2>&1; then
      no "teeth BOM1: build BOM-strip-removed mutant" "mutant identical — substitution failed"
    elif ! "$BASH_BIN" -n "$bom1_mutant" 2>/dev/null; then
      no "teeth BOM1: build BOM-strip-removed mutant" "mutant syntax error"
    else
      f_bom1="$ROOT/retro-status.bom1-fixture.md"
      printf '\xef\xbb\xbf# retro\n\n<!-- review-status: applied 2026-01-01 -->\nbody\n' > "$f_bom1"
      outbom1="$("$BASH_BIN" -c '. "$1"; retro_marker_scope_line "$2"' _ "$bom1_mutant" "$f_bom1" 2>&1)"
      if [ -z "$outbom1" ]; then
        ok "teeth BOM1: BOM-strip-removed mutant goes blind on case 57's fixture (has teeth)" "()"
      else
        no "teeth BOM1: BOM-strip-removed mutant should go blind" "got [$outbom1] — case 57 is THEATER"
      fi
      f_bom1_58="$ROOT/retro-status.bom1-58-fixture.md"
      printf '\xef\xbb\xbf<!-- review-status: applied 2026-01-01 -->\nbody\n' > "$f_bom1_58"
      outbom1_58="$("$BASH_BIN" -c '. "$1"; retro_marker_line "$2"' _ "$bom1_mutant" "$f_bom1_58" 2>&1)"
      if [ -z "$outbom1_58" ]; then
        ok "teeth BOM1: BOM-strip-removed mutant also goes blind on case 58's fixture (kit issue #1125 item 5)" "()"
      else
        no "teeth BOM1: BOM-strip-removed mutant should also go blind on case 58's fixture" \
          "got [$outbom1_58] — case 58 was THEATER (kit issue #1125 item 5)"
      fi
    fi
  fi

  # Tooth IND1 (kit issue #1125 item 1, updated for #1130 finding 2's mawk-portable rewrite):
  # widen retro_marker_line's indent anchor back to '^[[:space:]]*<!--' (any whitespace, the
  # pre-fix regex). Case 59's 4-space-indented example marker must then FALSE-MATCH — proving
  # the '^ ? ? ?<!--' narrowing is load-bearing.
  echo "-- teeth IND1: widen retro_marker_line's indent anchor back to any-whitespace; case 59 must false-match --"
  anchor_ind1='^ ? ? ?<!--[[:space:]]*review-status:'
  if ! grep -qF "$anchor_ind1" "$HELPER"; then
    no "teeth IND1: locate the RETRO_MARKER_LINE_INDENT_ANCHOR pattern" "anchor not found — helper drifted?"
  else
    ind1_mutant="$ROOT/retro-status.ind1.sh"
    sed "s/\^ ? ? ?<!--\[\[:space:\]\]\*review-status:/^[[:space:]]*<!--[[:space:]]*review-status:/" \
      "$HELPER" > "$ind1_mutant"
    if diff -q "$HELPER" "$ind1_mutant" >/dev/null 2>&1; then
      no "teeth IND1: build widened-anchor mutant" "mutant identical — substitution failed"
    elif ! "$BASH_BIN" -n "$ind1_mutant" 2>/dev/null; then
      no "teeth IND1: build widened-anchor mutant" "mutant syntax error"
    else
      f_ind1="$ROOT/retro-status.ind1-fixture.md"
      printf '# retro\n\nExample marker format for reference:\n\n    <!-- review-status: applied 2026-01-01 -->\n\nbody, no real marker anywhere in this file\n' > "$f_ind1"
      outind1="$("$BASH_BIN" -c '. "$1"; retro_marker_line "$2"' _ "$ind1_mutant" "$f_ind1" 2>&1)"
      if [ -n "$outind1" ]; then
        ok "teeth IND1: widened-anchor mutant false-matches the indented example (case 59 has teeth)" "(got '$outind1')"
      else
        no "teeth IND1: widened-anchor mutant should false-match the indented example" \
          "got empty — case 59 is THEATER"
      fi
    fi
  fi

  # Tooth IND2 (kit issue #1130 finding 3): widen retro_marker_scope_line's indent anchor back
  # to '^[[:space:]]*<!--' (any whitespace, the pre-fix regex). Case 68's 4-space-indented marker
  # in the leading block must then be honoured again — proving the '^ ? ? ?<!--' narrowing on
  # THIS function is load-bearing too, not just on retro_marker_line.
  echo "-- teeth IND2: widen retro_marker_scope_line's indent anchor back to any-whitespace; case 68 must flip to found --"
  anchor_ind2='/^ ? ? ?<!--/ { print; next }'
  if ! grep -qF "$anchor_ind2" "$HELPER"; then
    no "teeth IND2: locate the RETRO_MARKER_SCOPE_INDENT_ANCHOR pattern" "anchor not found — helper drifted?"
  else
    ind2_mutant="$ROOT/retro-status.ind2.sh"
    sed "s|/\^ ? ? ?<!--/ { print; next }|/^[[:space:]]*<!--/ { print; next }|" \
      "$HELPER" > "$ind2_mutant"
    if diff -q "$HELPER" "$ind2_mutant" >/dev/null 2>&1; then
      no "teeth IND2: build widened-anchor mutant" "mutant identical — substitution failed"
    elif ! "$BASH_BIN" -n "$ind2_mutant" 2>/dev/null; then
      no "teeth IND2: build widened-anchor mutant" "mutant syntax error"
    else
      f_ind2="$ROOT/retro-status.ind2-fixture.md"
      printf '# retro\n\n    <!-- review-status: applied 2026-01-01 -->\nbody\n' > "$f_ind2"
      outind2="$("$BASH_BIN" -c '. "$1"; retro_marker_scope_line "$2"' _ "$ind2_mutant" "$f_ind2" 2>&1)"
      if [ -n "$outind2" ]; then
        ok "teeth IND2: widened-anchor mutant honours the 4-space-indented marker again (case 68 has teeth)" "(got '$outind2')"
      else
        no "teeth IND2: widened-anchor mutant should honour the 4-space-indented marker" \
          "got empty — case 68 is THEATER"
      fi
    fi
  fi

  # ── Fence-tracking teeth (kit issues #949 item 3 / #1304 item 6). One mutant per clause of the
  # CommonMark fence rule in retro_marker_line, each built with the shared tests/lib/mutant.sh
  # (a mutant that never applied, is empty or does not parse is refused, never run). Each mutant
  # is run against a fixture whose EXPECTED output differs from what the mutant produces, so a
  # mutant that merely differs from the good run for the wrong reason cannot pass.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  FM="$(printf '<!-- review-status: applied 2026-01-01 · kit abc1234 -->')"
  FX="$ROOT/fence-teeth"; mkdir -p "$FX"
  printf '# r\n\n````\n```\n%s\n````\n' "$FM" > "$FX/len.md"            # F1 expect: empty
  printf '# r\n\n```\n``` not a closer\n%s\n```\n' "$FM" > "$FX/trail.md" # F2 expect: empty
  printf '# r\n\n~~~\n```\n%s\n~~~\n' "$FM" > "$FX/char.md"             # F3/F6 expect: empty
  printf '# r\n\n```\nopen forever\n%s\n' "$FM" > "$FX/unclosed.md"       # F4 expect: marker
  printf '# r\n\n```code```\n\n```\n<!-- review-status: pending -->\n```\n\n%s\n' "$FM" > "$FX/inline.md"  # F5 expect: marker
  # fence_tooth <id> <label> <fixture> <expected> <sed-expr>
  fence_tooth() {
    local id="$1" label="$2" fx="$3" want="$4" expr="$5" mut="$ROOT/retro-status.fence-$1.sh" got good
    echo "-- teeth $id: $label --"
    good="$(retro_marker_line "$fx")"
    if [ "$good" != "$want" ]; then
      no "teeth $id: real helper returns the expected output on the fixture" "got [$good] want [$want]"
      return
    fi
    local mrc=0
    mutant_sed "$HELPER" "$mut" "$expr" || mrc=$?
    if [ "$mrc" -ne 0 ]; then
      no "teeth $id: build mutant" "mutant_sed refused (rc $mrc) — sed expression drifted?"
      return
    fi
    got="$("$BASH_BIN" -c '. "$1"; retro_marker_line "$2"' _ "$mut" "$fx" 2>&1)"
    if [ "$got" != "$want" ]; then
      ok "teeth $id: $label → mutant output differs (cases have teeth)" "(got [$got])"
    else
      no "teeth $id: mutant should differ from the good output" "got [$got] — fence cases are THEATER"
    fi
  }
  fence_tooth F1 "closer-length check dropped (shorter run closes the fence)" "$FX/len.md" "" \
    's/n >= flen && //'
  fence_tooth F2 "closer trailing-text check dropped (closer with text closes)" "$FX/trail.md" "" \
    's/n >= flen && rest ~ [^)]*)/n >= flen)/'
  fence_tooth F3 "closer same-char check dropped (any fence char closes)" "$FX/char.md" "" \
    's/if (c == fch) {/if (1) {/'
  fence_tooth F4 "END fail-closed dropped (unclosed fence reads as markerless)" "$FX/unclosed.md" "$FM" \
    's/END { if (!found && infence && held != "") print held }/END { }/'
  fence_tooth F5 "inline-backtick guard dropped (inline code opens a fence)" "$FX/inline.md" "$FM" \
    's/ && !(c == "`" && index(rest, "`") > 0)//'
  fence_tooth F6 "tilde opener dropped (~~~ never opens a fence)" "$FX/char.md" "" \
    's/if (c == "`" || c == "~") {/if (c == "`") {/'
  printf '# r\n\nbody\n\n<!-- REVIEW-STATUS: applied 2026-01-01 -->\n' > "$FX/upper.md"   # F7 expect: marker
  fence_tooth F7 "tolower dropped (uppercase REVIEW-STATUS no longer matches)" "$FX/upper.md" \
    "<!-- REVIEW-STATUS: applied 2026-01-01 -->" 's/lc = tolower(\$0)/lc = \$0/'

  printf '# r\r\n\r\n```\r\n<!-- review-status: pending -->\r\n```\r\n\r\n<!-- review-status: applied 2026-01-01 -->\r\n' > "$FX/crlf.md"
  # F8 expect: the REAL marker (CR kept in the raw line). Mutant: closer CR tolerance dropped.
  fence_tooth F8 "closer CR tolerance dropped (CRLF fence never closes)" "$FX/crlf.md" \
    "$(printf '<!-- review-status: applied 2026-01-01 -->\r')" 's#rest ~ /^\[ \\t\\r\]\*\$/#rest ~ /^[ \\t]*$/#'

  # ── DISMISSED-id teeth (kit issue #1944). One mutant per clause of retro_marker_shipped_raw /
  # retro_marker_dismissed_ids / retro_marker_row_state, built with the shared mutant_sed. Each tooth
  # runs the SAME probe its case asserts and requires the SPECIFIC WRONG ANSWER the mutated clause
  # produces (a mutant that differs for another reason cannot pass): `want` is an exact answer, or
  # `~text` for "the output contains text".
  export dm pm mm nm bs sm
  export bm_empty='<!-- review-status: applied 2026-09-05 · PARTIAL — shipped: 1; DISMISSED: ; DEFERRED: #7 -->'
  export np_marker='<!-- review-status: applied 2026-09-05 · kit abc · DISMISSED: #2 -->'
  export lc_marker='<!-- review-status: applied 2026-09-05 · kit abc · shipped: 1 — dismissed: 2 -->'
  export sh_marker='<!-- review-status: applied · PARTIAL — shipped: #1, #3 -->'
  dtooth() {
    local id="$1" label="$2" want="$3" expr="$4" snippet="$5" mut="$ROOT/retro-status.dism-$1.sh" got mrc=0
    echo "-- teeth $id: $label --"
    mutant_sed "$HELPER" "$mut" "$expr" || mrc=$?
    if [ "$mrc" -ne 0 ]; then
      no "teeth $id: build mutant" "mutant_sed refused (rc $mrc) — sed expression drifted?"
      return
    fi
    got="$("$BASH_BIN" -c '. "$1"; eval "$2"' _ "$mut" "$snippet" 2>&1)"
    if { [ "${want:0:1}" = "~" ] && grep -qF -- "${want:1}" <<<"$got"; } || [ "$got" = "$want" ]; then
      ok "teeth $id: $label → the specific wrong answer [$want]" "(got [$got])"
    else
      no "teeth $id: expected the wrong answer [$want]" "got [$got] — the case is THEATER or the mutant bit elsewhere"
    fi
  }
  dtooth D1 "parenthetical strip dropped (';' inside parens truncates the list)" '~(already' \
    '/RETRO_MARKER_DISMISSED_PAREN_STRIP$/{n;s/| sed -E .*/| cat)"/;}' \
    'retro_marker_dismissed_ids "$pm" | paste -sd, -'
  dtooth D2 "row-state dismissed branch removed (dismissed row reads open)" 'open' \
    '/RETRO_MARKER_ROW_STATE_DISMISSED$/{n;s/\[ -n "\$dids" \]/false/;}' \
    'retro_marker_row_state "$dm" 4'
  dtooth D3 "keyword match made case-insensitive (prose 'dismissed:' becomes a keyword)" '~2' \
    's/grep -oE '"'"'(^|\[^A-Za-z\])DISMISSED/grep -oiE '"'"'(^|[^A-Za-z])DISMISSED/' \
    'retro_marker_dismissed_ids "$lc_marker"'
  dtooth D4 "segment no longer cut at ';' (DEFERRED ids leak into the dismissed set)" 'dismissed' \
    's/DISMISSED:\[^;\]\*/DISMISSED:[^>]*/' \
    'retro_marker_row_state "$dm" 7'
  dtooth D5 "only the LAST DISMISSED segment kept (second segment replaces the first)" '9' \
    '/RETRO_MARKER_DISMISSED_JOIN$/s/joined=.*# RETRO/joined="$seg"   # RETRO/' \
    'retro_marker_dismissed_ids "$mm" | paste -sd, -'
  dtooth D6 "parentheses stripped once only (nested parentheses survive)" '~(x' \
    '/RETRO_MARKER_DISMISSED_PAREN_STRIP$/{n;s/ -e .ta.)/)/;}' \
    'retro_marker_dismissed_ids "$nm" | paste -sd, -'
  dtooth D7 "PARTIAL gate removed (a non-PARTIAL marker reads its DISMISSED list)" 'dismissed' \
    '/RETRO_MARKER_ROW_STATE_PARTIAL_GATE$/s/.*/    :/' \
    'retro_marker_row_state "$np_marker" 2'
  dtooth D8 "malformed list not typed (an empty DISMISSED list reads as open)" 'open' \
    '/RETRO_MARKER_DISMISSED_MALFORMED$/s/.*/    :/' \
    'retro_marker_row_state "$bm_empty" 2'
  dtooth D9 "empty row id not typed" 'open' \
    '/RETRO_MARKER_ROW_STATE_EMPTY$/s/\[ -z "\$line" \] || \[ -z "\$rid" \]/false/' \
    'retro_marker_row_state "$sm" ""'
  dtooth D10 "shipped branch removed (a shipped row reads open)" 'open' \
    '/RETRO_MARKER_ROW_STATE_SHIPPED$/{n;s/\[ -n "\$sids" \]/false/;}' \
    'retro_marker_row_state "$dm" 3'
  dtooth D11 "shipped_raw no longer cut at '>' (the marker closer leaks into the list)" '~-->' \
    "s/shipped:\\[^;>\\]\\*/shipped:[^;]*/" \
    'retro_marker_shipped_raw "$sh_marker"'

  # ── Structural guard (kit issue #1130 finding 2): no POSIX interval expression ({m,n}) may
  # reappear inside retro_marker_line's or retro_marker_scope_line's awk match regex — that is
  # exactly the mawk-incompatible shape this finding replaced with '^ ? ? ?'. Scoped to the two
  # function bodies (not the whole file) so an unrelated future '{n}' elsewhere in the lib
  # doesn't false-positive this guard.
  echo "-- structural guard: no {m,n} interval expression in retro_marker_line/scope_line's awk match --"
  # Strip full-line comments first (grep -v '^\s*#') — this guard checks LIVE regex code, not
  # documentation prose that may legitimately quote the old '{0,3}' shape for explanatory value.
  _ml_body="$(sed -n '/^  retro_marker_line() {/,/^  }/p' "$HELPER" | grep -vE '^[[:space:]]*#')"
  _sl_body="$(sed -n '/^  retro_marker_scope_line() {/,/^  }/p' "$HELPER" | grep -vE '^[[:space:]]*#')"
  if <<<"$_ml_body$_sl_body" grep -qE '\{[0-9]+,[0-9]*\}'; then
    no "structural guard: retro_marker_line/scope_line still carry a {m,n} interval expression" \
      "mawk-incompatible shape reintroduced"
  else
    ok "structural guard: retro_marker_line/scope_line carry no {m,n} interval expression" "()"
  fi
  unset _ml_body _sl_body
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
