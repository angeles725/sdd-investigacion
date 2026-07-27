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

# 6 — BODY MARKER below heading + blank. A real status comment sitting AFTER the heading and the
#     first blank line is in the body, not the leading comment block, so it must NOT gate the retro.
f="$(mkretro body-marker <<'EOF'
# retro

<!-- review-status: applied 2026-01-01 -->
EOF
)"
got="$(retro_review_status "$f")"
[ -z "$got" ] && ok "6 body marker below heading+blank → none" "(got '$got')" \
             || no "6 body marker below heading+blank → none" "got '$got'"

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
# TEETH (negative control). Case 8 claims the '<!--' anchor in the marker regex is what stops a
# review-status substring buried in a comment's PROSE from being misread as a real status. Mutate a
# throwaway COPY of the helper: DROP the '<!--' anchor from the grep so any 'review-status: <word>'
# anywhere in a scanned line matches. Re-run the comment-prose fixture (case 8) through the mutant in
# a FRESH bash (so the mutant's function definition wins, unshadowed by the one already sourced here).
# Against the mutant the buried prose MUST wrongly resolve to 'applied'. If it stayed empty, the
# anchor was never load-bearing and case 8 is theater.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: drop the '<!--' anchor, expect comment-prose to false-resolve to applied --"
  anchor="grep -oiE '<!--[[:space:]]*review-status:[[:space:]]*[a-z]+'"
  content="$(cat "$HELPER")"
  if [[ "$content" != *"$anchor"* ]]; then
    no "teeth: locate '<!--'-anchored marker regex" "anchor not found — helper drifted?"
  else
    mutant="$ROOT/retro-status.mutant.sh"
    broken="grep -oiE 'review-status:[[:space:]]*[a-z]+'"
    printf '%s\n' "${content/"$anchor"/$broken}" > "$mutant"
    fix="$(mkretro teeth-comment-prose <<'EOF'
<!-- RECONSTRUCTED from a backup that had review-status: applied -->
# retro
EOF
)"
    outm="$("$BASH_BIN" -c '. "$1"; retro_review_status "$2"' _ "$mutant" "$fix" 2>&1)"
    if [ "$outm" = "applied" ]; then
      ok "teeth: anchor-dropped mutant false-resolves comment prose" "(case 8 has teeth)"
    else
      no "teeth: anchor-dropped mutant false-resolves comment prose" "mutant returned '$outm' — case 8 is THEATER"
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

  # Tooth M6: drop the bare '{ exit }' from retro_is_waived's awk, enabling a whole-file scan.
  # A body-position waiver marker (case 15 fixture) must then FALSELY return 0 (waived).
  # Uses awk to skip ONLY the SECOND bare '{ exit }' occurrence (the one in retro_is_waived);
  # the first (in retro_is_excluded) is kept so retro_is_excluded remains intact.
  # If the mutant returns 1 (not waived), the '{ exit }' guard was not the deciding factor
  # and case 15 is theater.
  echo "-- teeth M6: drop { exit } from retro_is_waived awk; body-position waiver must false-fire (case 15 has teeth) --"
  m6_mutant="$ROOT/retro-status.m6.sh"
  awk 'BEGIN{n=0} /^      \{ exit \}$/ { n++; if(n==2) next } { print }' "$HELPER" > "$m6_mutant"
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

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
