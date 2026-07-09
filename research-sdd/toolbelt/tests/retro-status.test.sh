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
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
