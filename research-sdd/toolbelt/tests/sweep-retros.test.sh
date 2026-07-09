#!/usr/bin/env bash
# sweep-retros.test.sh — red-first regression harness for sweep-retros.sh (surfaces
# un-reviewed §18 self-retrospective proposals across research-sdd targets, METHODOLOGY §18).
#
# WHY THIS SHAPE. sweep-retros.sh is READ-ONLY pure text logic: it reads the backtick-wrapped
# absolute target paths out of the kit's TARGETS.md, walks each <target>/retros/*.md, and a retro
# is PENDING unless its top carries a 'review-status: applied' or 'review-status: dismissed'
# marker; for each pending retro it prints a 'PENDING <file>' line plus a '~N proposed deltas'
# count (rows shaped like '| <digits> |') and a 'status: <word|none>' tag, closing with a
# 'Summary: <pending> pending / <total> retros' line. This suite pins that contract — marker
# detection (pending vs applied vs dismissed vs unknown-word, plus case-insensitive normalization
# and body-position markers), the delta count, multi-target aggregation, the empty-summary and
# empty-retros-dir paths, and the truncated-'...'-path filter — WITHOUT any external tool. It never
# edits the SUT; it exercises a throwaway COPY placed inside a sandbox kit so KIT=dirname/.. resolves
# hermetically. (Note: sweep-retros.sh's own header says the marker sits 'at the top', but the impl
# scans the whole file — case 14 characterizes that ACTUAL behavior; see the review summary.)
#
# Usage: sweep-retros.test.sh                (run the suite)
#        sweep-retros.test.sh --prove-teeth  (run suite + the mutation teeth proof)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-retros.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-56s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-56s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> : lay down a runnable COPY of the SUT at <ROOT>/<name>/toolbelt/ so the script's
# KIT=dirname/.. resolves inside the sandbox; echoes the kit dir. TARGETS.md goes at its top.
mkkit() {
  local kit="$ROOT/$1"
  mkdir -p "$kit/toolbelt"
  cp "$SUT" "$kit/toolbelt/sweep-retros.sh"
  printf '%s' "$kit"
}

# write_targets <kit> <targetpath...> : build a minimal TARGETS.md whose table carries each
# target as a backtick-wrapped absolute path — the only thing the SUT reads out of it.
write_targets() {
  local kit="$1"; shift
  { printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
    local i=0 t
    for t in "$@"; do i=$((i+1)); printf '| %d | t%d | `%s` |\n' "$i" "$i" "$t"; done
  } > "$kit/TARGETS.md"
}

# mkretro <target> <filename> <marker-line|-> <ndeltas> : write a retro with an optional top
# marker line and <ndeltas> table rows shaped like '| <n> | ... |' (what the SUT counts).
mkretro() {
  local tgt="$1" fname="$2" marker="$3" nd="$4" i=0
  mkdir -p "$tgt/retros"
  {
    [ "$marker" = "-" ] || printf '%s\n' "$marker"
    printf '# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n'
    while [ "$i" -lt "$nd" ]; do i=$((i+1)); printf '| %d | delta %d | because |\n' "$i" "$i"; done
  } > "$tgt/retros/$fname"
}

# run <kit> : invoke the sandbox copy of the SUT, capture stdout+stderr into OUT, exit into RC.
run() { OUT="$("$BASH_BIN" "$1/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?; }

echo "== sweep-retros.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# 1 — PENDING marker → detected as pending. A retro whose top says 'review-status: pending'
#     is NOT applied/dismissed, so it must surface as PENDING with its literal status word,
#     its delta count, and a '1 pending / 1 retros' summary.
kit="$(mkkit c1-pending)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 3
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'r1.md'   <<<"$OUT" \
   && grep -q 'status: pending' <<<"$OUT" \
   && grep -q '~3 proposed deltas' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "1 pending marker → surfaced as PENDING (~3 deltas)" "(exit $RC)"
else
  no "1 pending marker → surfaced as PENDING (~3 deltas)" "exit=$RC out=[$OUT]"
fi

# 2 — APPLIED marker → NOT pending. A retro tagged 'review-status: applied ...' is reviewed
#     work; it must be counted in the total but never printed as PENDING, and the run must end
#     on the empty-queue path ('Nothing to review.', '0 pending / 1 retros').
kit="$(mkkit c2-applied)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: applied 2026-01-01 · kit deadbeef -->" 4
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'Summary: 0 pending / 1 retros' <<<"$OUT" \
   && grep -q 'Nothing to review.' <<<"$OUT"; then
  ok "2 applied marker → not pending, empty queue" "(exit $RC)"
else
  no "2 applied marker → not pending, empty queue" "exit=$RC out=[$OUT]"
fi

# 3 — DISMISSED marker → NOT pending. Same exclusion path as applied: dismissed deltas are a
#     resolved decision, so the retro is counted but not surfaced.
kit="$(mkkit c3-dismissed)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: dismissed 2026-01-01 -->" 2
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'Summary: 0 pending / 1 retros' <<<"$OUT"; then
  ok "3 dismissed marker → not pending" "(exit $RC)"
else
  no "3 dismissed marker → not pending" "exit=$RC out=[$OUT]"
fi

# 4 — DELTA COUNT is exact. A pending retro with N delta rows must report '~N proposed deltas'
#     (only lines shaped '| <digits> |' count — the '| # |' header and '|---|' separator do not).
kit="$(mkkit c4-count)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 7
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && grep -q '~7 proposed deltas' <<<"$OUT"; then
  ok "4 delta count → exactly N reported" "(~7)"
else
  no "4 delta count → exactly N reported" "exit=$RC out=[$OUT]"
fi

# 5 — ZERO deltas. A pending retro with no numbered delta rows still surfaces, reporting '~0'.
kit="$(mkkit c5-zero)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 0
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q '~0 proposed deltas' <<<"$OUT"; then
  ok "5 zero deltas → pending, ~0 reported" "(exit $RC)"
else
  no "5 zero deltas → pending, ~0 reported" "exit=$RC out=[$OUT]"
fi

# 6 — ABSENT marker → pending with 'status: none'. No review-status line at all means the retro
#     was never triaged, so it is pending and its status tag renders as the literal 'none'.
kit="$(mkkit c6-nomarker)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "-" 1
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q 'status: none' <<<"$OUT"; then
  ok "6 absent marker → pending, status: none" "(exit $RC)"
else
  no "6 absent marker → pending, status: none" "exit=$RC out=[$OUT]"
fi

# 7 — UNKNOWN marker word → pending. Only 'applied'/'dismissed' exclude a retro; any other word
#     (here 'wip') is not a resolution, so the retro stays pending and echoes that word as status.
kit="$(mkkit c7-unknown)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: wip -->" 1
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q 'status: wip' <<<"$OUT"; then
  ok "7 unknown marker word → pending (status: wip)" "(exit $RC)"
else
  no "7 unknown marker word → pending (status: wip)" "exit=$RC out=[$OUT]"
fi

# 8 — MULTI-TARGET aggregation. Two targets: A has one pending + one applied, B has one pending.
#     The summary must aggregate across BOTH targets → 2 pending / 3 retros total.
kit="$(mkkit c8-multi)"; tgtA="$kit/targetA"; tgtB="$kit/targetB"
mkretro "$tgtA" "p.md"       "<!-- review-status: pending -->" 2
mkretro "$tgtA" "done.md"    "<!-- review-status: applied 2026-01-01 -->" 5
mkretro "$tgtB" "p.md"       "<!-- review-status: pending -->" 1
write_targets "$kit" "$tgtA" "$tgtB"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'Summary: 2 pending / 3 retros' <<<"$OUT"; then
  ok "8 multi-target → 2 pending / 3 retros aggregated" "(exit $RC)"
else
  no "8 multi-target → 2 pending / 3 retros aggregated" "exit=$RC out=[$OUT]"
fi

# 9 — TARGET WITHOUT retros/ is skipped silently. A listed target that has no retros directory
#     contributes nothing to the totals (it must not crash or inflate the count).
kit="$(mkkit c9-noretros)"; tgtA="$kit/targetA"; tgtB="$kit/targetB"
mkretro "$tgtA" "r1.md" "<!-- review-status: pending -->" 1
mkdir -p "$tgtB"   # exists, but no retros/ subdir
write_targets "$kit" "$tgtA" "$tgtB"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "9 target without retros/ → skipped silently" "(exit $RC)"
else
  no "9 target without retros/ → skipped silently" "exit=$RC out=[$OUT]"
fi

# 10 — A '...'-bearing path is filtered even when it EXISTS on disk. The SUT drops any backtick
#      path containing '...' at sweep-retros.sh:22 (grep -v '\.\.\.') BEFORE the [ -d ] walk check —
#      so a REAL, walkable target dir whose absolute path literally contains '...' is EXCLUDED
#      despite being on disk. Both targets carry a pending retro; only the non-'...' one may count.
#      (This genuinely exercises the '...' filter — the truncated fixture is not skipped merely for
#      being absent. The [ -d ] assertion below proves the '...' target really exists.)
kit="$(mkkit c10-dots-exist)"; tgtA="$kit/targetA"; tgtDots="$kit/real...dots"
mkretro "$tgtA"    "r1.md" "<!-- review-status: pending -->" 1
mkretro "$tgtDots" "r1.md" "<!-- review-status: pending -->" 1
write_targets "$kit" "$tgtA" "$tgtDots"
run "$kit"
if [ "$RC" = 0 ] \
   && [ -d "$tgtDots/retros" ] \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "10 existing '...' path → filtered despite being on disk" "(exit $RC)"
else
  no "10 existing '...' path → filtered despite being on disk" "exit=$RC out=[$OUT]"
fi

# 11 — MISSING TARGETS.md → harness-style abort (exit 1, no summary). The SUT cannot proceed
#      without the registry it reads target paths from.
kit="$(mkkit c11-notargets)"   # note: no write_targets → TARGETS.md absent
run "$kit"
if [ "$RC" = 1 ] && grep -qi 'cannot find' <<<"$OUT" && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "11 missing TARGETS.md → exit 1, no summary" "(exit $RC)"
else
  no "11 missing TARGETS.md → exit 1, no summary" "exit=$RC out=[$OUT]"
fi

# 12 — CASE-INSENSITIVE marker normalization. The SUT lowercases the status word (grep -oiE +
#      tr 'A-Z' 'a-z' at sweep-retros.sh:31-32), so a MixedCase 'Applied' marker must resolve to
#      'applied' and be EXCLUDED. This is load-bearing: without the -i/tr the 'review-status:[a-z]+'
#      pattern would never match capital-A 'Applied', status would fall to 'none', and the retro
#      would WRONGLY surface as pending. Assert it is treated as reviewed (empty queue).
kit="$(mkkit c12-mixedcase)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: Applied 2026-01-01 -->" 3
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'Summary: 0 pending / 1 retros' <<<"$OUT" \
   && grep -q 'Nothing to review.' <<<"$OUT"; then
  ok "12 MixedCase 'Applied' marker → normalized, excluded" "(exit $RC)"
else
  no "12 MixedCase 'Applied' marker → normalized, excluded" "exit=$RC out=[$OUT]"
fi

# 13 — EMPTY retros/ dir (exists, no *.md) → contributes nothing. Distinct from case 9 (no retros/
#      dir at all): here the dir passes the [ -d "$d" ] check but the *.md glob finds no file, so the
#      [ -e "$f" ] guard skips the empty-glob token and the target adds zero to BOTH counts.
kit="$(mkkit c13-emptyretros)"; tgtA="$kit/targetA"; tgtB="$kit/targetB"
mkretro "$tgtA" "r1.md" "<!-- review-status: pending -->" 1
mkdir -p "$tgtB/retros"   # retros/ exists but holds no *.md
write_targets "$kit" "$tgtA" "$tgtB"
run "$kit"
if [ "$RC" = 0 ] \
   && [ -d "$tgtB/retros" ] \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "13 empty retros/ dir → contributes nothing" "(exit $RC)"
else
  no "13 empty retros/ dir → contributes nothing" "exit=$RC out=[$OUT]"
fi

# 14 — BODY-POSITION marker (characterization). sweep-retros.sh's own header says the marker sits
#      'at the top', but the impl greps the WHOLE file and takes head -1 (sweep-retros.sh:31-32).
#      So an 'applied' marker sitting only in the retro BODY (no top marker) is still detected and
#      EXCLUDES the retro. This case pins the ACTUAL behavior, not the documented 'top' contract —
#      the doc/impl mismatch is a potential SUT bug, left UNFIXED here (the SUT is never edited).
kit="$(mkkit c14-bodymarker)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "-" 2   # no top marker
printf '\nnote: <!-- review-status: applied 2026-01-01 -->\n' >> "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'Summary: 0 pending / 1 retros' <<<"$OUT"; then
  ok "14 body-position marker → still detected (whole-file scan)" "(exit $RC)"
else
  no "14 body-position marker → still detected (whole-file scan)" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# TEETH (negative control). Cases 2/3 claim the 'applied|dismissed) continue' skip is what
# keeps reviewed retros OUT of the pending queue. Mutate a throwaway copy so that arm can never
# match (rename its pattern to a token no status ever equals) and re-run the APPLIED fixture:
# against the mutant the skip is dead, so an applied retro MUST false-surface as PENDING. If the
# mutant stayed quiet, cases 2/3 would be theater.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the applied|dismissed skip, expect an APPLIED retro to false-surface as PENDING --"
  anchor='      applied|dismissed) continue ;;'
  content="$(cat "$SUT")"
  if [[ "$content" != *"$anchor"* ]]; then
    no "teeth: locate applied|dismissed skip arm" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-applied)"; tgt="$kit/targetA"
    mkretro "$tgt" "r1.md" "<!-- review-status: applied 2026-01-01 -->" 3
    write_targets "$kit" "$tgt"
    mutant="$kit/toolbelt/sweep-retros.sh"          # replace the sandbox copy with the mutant
    neutered='      __teeth_never_matches__) continue ;;'
    printf '%s\n' "${content/"$anchor"/$neutered}" > "$mutant"
    outm="$("$BASH_BIN" "$mutant" 2>&1)"
    if grep -q 'PENDING' <<<"$outm"; then
      ok "teeth: skip-neutered mutant false-surfaces applied retro" "(cases 2/3 have teeth)"
    else
      no "teeth: skip-neutered mutant false-surfaces applied retro" "mutant stayed quiet — cases 2/3 are THEATER"
    fi
  fi

  # Second teeth (negative control for the delta count). Case 4 claims '~N proposed deltas' is a
  # real tally of the '| <digits> |' rows. Break the count regex on a throwaway copy so it can never
  # match a numbered row, then re-run a 5-delta pending fixture: the mutant MUST report '~0', not
  # '~5'. If the mutant still counted 5, the count regex was never exercised and case 4 is theater.
  echo "-- teeth: break the delta-count regex, expect a 5-delta retro to miscount as ~0 --"
  anchor2="grep -cE '^\\| *[0-9]+ \\|'"
  if [[ "$content" != *"$anchor2"* ]]; then
    no "teeth: locate delta-count regex" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-count)"; tgt="$kit/targetA"
    mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 5
    write_targets "$kit" "$tgt"
    mutant="$kit/toolbelt/sweep-retros.sh"          # replace the sandbox copy with the mutant
    broken="grep -cE '^__never_a_delta_row__'"
    printf '%s\n' "${content/"$anchor2"/$broken}" > "$mutant"
    outm="$("$BASH_BIN" "$mutant" 2>&1)"
    if grep -q '~0 proposed deltas' <<<"$outm" && ! grep -q '~5 proposed deltas' <<<"$outm"; then
      ok "teeth: count-regex-broken mutant miscounts deltas (~0 not ~5)" "(case 4 has teeth)"
    else
      no "teeth: count-regex-broken mutant miscounts deltas (~0 not ~5)" "mutant kept counting — case 4 is THEATER: [$outm]"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
