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
# and leading-block-only marker scanning), the delta count, multi-target aggregation, the empty-summary
# and empty-retros-dir paths, and the truncated-'...'-path filter — WITHOUT any external tool. It never
# edits the SUT; it exercises a throwaway COPY placed inside a sandbox kit so KIT=dirname/.. resolves
# hermetically. The marker is only honored in the retro's LEADING BLOCK (line 1 until the first blank
# line or first '# ' heading); a marker sitting in the body is ignored — cases 14/16 pin that.
#
# Usage: sweep-retros.test.sh                (run the suite)
#        sweep-retros.test.sh --prove-teeth  (run suite + the mutation teeth proof)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-retros.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
LIB="$HERE/../lib/retro-status.sh"           # shared marker reader the SUT now sources
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }
TP_LIB="$HERE/../lib/target-paths.sh"        # shared path derivation the SUT now sources
[ -f "$TP_LIB" ] || { echo "FATAL: target-paths helper not found: $TP_LIB" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok()   { printf '  PASS  %-56s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()   { printf '  FAIL  %-56s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> : lay down a runnable COPY of the SUT at <ROOT>/<name>/toolbelt/ so the script's
# KIT=dirname/.. resolves inside the sandbox; echoes the kit dir. TARGETS.md goes at its top.
mkkit() {
  local kit="$ROOT/$1"
  mkdir -p "$kit/toolbelt/lib"
  cp "$SUT" "$kit/toolbelt/sweep-retros.sh"
  cp "$LIB" "$kit/toolbelt/lib/retro-status.sh"   # SUT sources this at $(dirname $0)/lib/
  cp "$TP_LIB" "$kit/toolbelt/lib/target-paths.sh" # SUT sources this at $(dirname $0)/lib/
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

# mkretro_git <target> <filename> <marker-line|-> <ndeltas> <git-date> <mtime> : like mkretro, but the
# target becomes a hermetic git repo and the retro's git FIRST-COMMIT date is set INDEPENDENTLY of its
# file mtime via GIT_AUTHOR_DATE/GIT_COMMITTER_DATE (deterministic — no wall-clock flakiness; the sibling
# stage-retro.test.sh already relies on this idiom via its `mkrepo` helper) so a case can prove the AGING
# feature reads the git-added date, not mtime. Lazily inits the target repo (idempotent across calls).
mkretro_git() {
  local tgt="$1" fname="$2" marker="$3" nd="$4" gdate="$5" mtime="$6"
  mkretro "$tgt" "$fname" "$marker" "$nd"
  if [ ! -d "$tgt/.git" ]; then
    git -C "$tgt" init -q -b main
    git -C "$tgt" config user.email t@example.com
    git -C "$tgt" config user.name tester
  fi
  git -C "$tgt" add -A
  GIT_AUTHOR_DATE="$gdate" GIT_COMMITTER_DATE="$gdate" git -C "$tgt" commit -q -m "add $fname"
  touch -d "$mtime" "$tgt/retros/$fname"
}

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

# 14 — BODY-POSITION marker is IGNORED — only the top block counts. The review-status marker is
#      honored solely in the retro's LEADING BLOCK (line 1 until the first blank line or first '# '
#      heading). So an 'applied' marker sitting only in the retro BODY (no top marker) must NOT
#      exclude the retro: it stays PENDING with 'status: none'. This guards against a body string
#      shaped like a marker silently dropping an un-reviewed retro out of the §18 queue.
kit="$(mkkit c14-bodymarker)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "-" 2   # no top marker
printf '\nnote: <!-- review-status: applied 2026-01-01 -->\n' >> "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'status: none' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "14 body-position marker → IGNORED, retro surfaced as pending" "(exit $RC)"
else
  no "14 body-position marker → IGNORED, retro surfaced as pending" "exit=$RC out=[$OUT]"
fi

# 15 — RECONSTRUCTED layout (false-positive guard). One real retro's line 1 is a non-marker
#      '<!-- RECONSTRUCTED ... -->' comment with the true 'review-status' marker on LINE 2, the
#      '# retro' heading on line 3, and the first blank line on line 4. The whole LEADING BLOCK
#      (line 1 through the first blank/'# ' heading) must be scanned, so the line-2 'applied'
#      marker is honored and the retro is EXCLUDED. A naive 'first line only' fix would miss the
#      line-2 marker and WRONGLY surface this reviewed retro as pending — this case fails that.
kit="$(mkkit c15-recon)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "-" 2   # marker-less retro: line 1 is the '# retro' heading
{ printf '<!-- RECONSTRUCTED note -->\n<!-- review-status: applied 2026-07-07 -->\n'
  cat "$tgt/retros/r1.md"; } > "$tgt/retros/r1.md.new"
mv "$tgt/retros/r1.md.new" "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'Summary: 0 pending / 1 retros' <<<"$OUT"; then
  ok "15 recon layout (marker on line 2) → excluded (whole leading block scanned)" "(exit $RC)"
else
  no "15 recon layout (marker on line 2) → excluded (whole leading block scanned)" "exit=$RC out=[$OUT]"
fi

# 16 — POSITIONAL guard. A body 'review-status: applied' marker printed on its OWN line at column 0
#      (no comment prefix), BELOW the heading and the first blank line, must STILL leave the retro
#      PENDING. This proves the fix is positional (leading-block-only), not merely prefix-based:
#      it is the marker's POSITION past the leading block — not its lack of an HTML-comment wrapper —
#      that makes it ignored. Currently RED: the whole-file scan finds this marker and excludes it.
kit="$(mkkit c16-positional)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "-" 2   # no top marker; leading block is just the '# retro' heading
printf '\nreview-status: applied 2026-01-01\n' >> "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'status: none' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "16 body marker at column 0 → still pending (leading-block-only, not prefix)" "(exit $RC)"
else
  no "16 body marker at column 0 → still pending (leading-block-only, not prefix)" "exit=$RC out=[$OUT]"
fi

# 17 — FAIL-CLOSED on a broken helper. The SUT sources lib/retro-status.sh, but existence of the
#      file is not enough: the source must have DEFINED retro_review_status. Neither script runs under
#      `set -e`, so a helper that EXISTS and sources cleanly but defines NO function would leave the
#      reader as a 'command not found' — every retro would read as 'none' and silently surface as
#      PENDING (fail-OPEN). The post-source `declare -F` guard must instead ABORT non-zero with a
#      helper-error message BEFORE the summary. Fixture: replace the sandbox helper with a comment-only
#      file (exists, exit 0, no function) and feed an APPLIED retro that MUST NOT false-surface.
kit="$(mkkit c17-broken-helper)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: applied 2026-01-01 -->" 3
write_targets "$kit" "$tgt"
printf '#!/usr/bin/env bash\n# broken helper: sources cleanly but defines no retro_review_status\n' \
  > "$kit/toolbelt/lib/retro-status.sh"
run "$kit"
if [ "$RC" != 0 ] \
   && grep -q 'failed to define retro_review_status' <<<"$OUT" \
   && ! grep -q 'PENDING' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "17 broken helper (no function) → fail-closed abort, no summary" "(exit $RC)"
else
  no "17 broken helper (no function) → fail-closed abort, no summary" "exit=$RC out=[$OUT]"
fi

# 18 — AGING / ESCALATION + oldest-first ordering (Feature #26). Two pending retros: one far-aged (mtime in
#      the deep past), one fresh (now). The sandbox is not a git repo, so the SUT's git-first-commit lookup
#      returns empty and it FALLS BACK to file mtime — this case drives that mtime-fallback path specifically
#      (case 21 below drives the git-added-date path directly; git-first-commit IS hermetically fakeable via
#      GIT_AUTHOR_DATE/GIT_COMMITTER_DATE, contra a stale claim once here — see the sibling stage-retro.test.sh's
#      `mkrepo`, which already builds hermetic git repos this way). With RSDD_RETRO_AGE_DAYS=1 the aged one must
#      be TAGGED 'ESCALATED (aged Nd)' and — because the queue is reordered oldest-first — print BEFORE the fresh one.
kit="$(mkkit c18-aging)"; tgt="$kit/targetA"
mkretro "$tgt" "fresh.md" "<!-- review-status: pending -->" 1
mkretro "$tgt" "old.md"   "<!-- review-status: pending -->" 1
touch -d '2000-01-01' "$tgt/retros/old.md"   # deep past → aged well past any small threshold
touch "$tgt/retros/fresh.md"                  # ~now → age 0d
write_targets "$kit" "$tgt"
OUT="$(RSDD_RETRO_AGE_DAYS=1 "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?
old_ln=$(grep -n 'old.md'   <<<"$OUT" | head -1 | cut -d: -f1)
fresh_ln=$(grep -n 'fresh.md' <<<"$OUT" | head -1 | cut -d: -f1)
if [ "$RC" = 0 ] \
   && [ "$(grep -c 'ESCALATED (aged' <<<"$OUT")" = 1 ] \
   && grep -A1 'old.md' <<<"$OUT" | grep -q 'ESCALATED (aged' \
   && [ -n "$old_ln" ] && [ -n "$fresh_ln" ] && [ "$old_ln" -lt "$fresh_ln" ]; then
  ok "18 aged pending → ESCALATED tag + sorted oldest-first (fresh not tagged)" "(exit $RC)"
else
  no "18 aged pending → ESCALATED tag + sorted oldest-first (fresh not tagged)" "old_ln=$old_ln fresh_ln=$fresh_ln out=[$OUT]"
fi

# 18a — AGING via the GIT-ADDED-DATE path directly (Feature #26, not just the mtime fallback exercised by
#       case 18). A git-tracked target with ONE pending retro whose GIT first-commit date is deep in the
#       past but whose file MTIME is FRESH (~now) — a detector that (bug or fallback) read mtime instead of
#       the git date would see the fresh mtime and NOT escalate. Reading the git date correctly escalates it
#       despite the misleading fresh mtime.
kit="$(mkkit c18a-git-aging)"; tgt="$kit/targetA"
mkretro_git "$tgt" "old.md" "<!-- review-status: pending -->" 1 "2000-01-01T00:00:00" "$(date -u +%Y-%m-%d)"
write_targets "$kit" "$tgt"
OUT="$(RSDD_RETRO_AGE_DAYS=1 "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q 'ESCALATED (aged' <<<"$OUT"; then
  ok "18a git-added-date deep-past → ESCALATED despite a FRESH mtime (git date wins, not mtime)" "(exit $RC)"
else
  no "18a git-added-date deep-past → ESCALATED despite a FRESH mtime (git date wins, not mtime)" "exit=$RC out=[$OUT]"
fi

# 19 — MISSING-RETRO fleet pass (Feature #25b). A target whose corpus ADVANCED past its newest retro (here: a
#      block file NEWER than the newest retro) surfaces a 'MISSING-RETRO: <target> advanced ...' line. The
#      block uses gen-catalog's discriminator ('*-block<N>.md'). Not-git sandbox → mtime drives advancement.
#      The block must be OLD enough (> grace window from now) for the alert to fire under the corrected
#      C2 semantics: MISSING-RETRO fires when now > nb + grace_secs (block has been idle past the window).
kit="$(mkkit c19-missing)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 1
touch -d '2000-01-01' "$tgt/retros/r1.md"              # retro is OLD (year 2000)
printf '# b\n' > "$tgt/t-block1.md"
touch -d '2 days ago' "$tgt/t-block1.md"               # block is 2 days old → beyond 24h default grace
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && grep -q "MISSING-RETRO: $tgt advanced with no retro" <<<"$OUT"; then
  ok "19 corpus advanced past newest retro → MISSING-RETRO line" "(exit $RC)"
else
  no "19 corpus advanced past newest retro → MISSING-RETRO line" "exit=$RC out=[$OUT]"
fi

# 20 — MISSING-RETRO negative control. A target whose newest retro is NEWER than every block (up to date) must
#      NOT surface a MISSING-RETRO line — the detector fires only on genuine advancement past the retro.
kit="$(mkkit c20-uptodate)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 1   # creates $tgt/retros (hence $tgt)
touch "$tgt/retros/r1.md"                      # retro is NEW → up to date
printf '# b\n' > "$tgt/t-block1.md"; touch -d '2000-01-01' "$tgt/t-block1.md"   # block is OLD
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'MISSING-RETRO' <<<"$OUT"; then
  ok "20 retro newer than blocks → no MISSING-RETRO line (negative control)" "(exit $RC)"
else
  no "20 retro newer than blocks → no MISSING-RETRO line (negative control)" "exit=$RC out=[$OUT]"
fi

# 21 — NESTED-CORPUS layout: retros kept DEEPER than <target>/retros/. A nested-corpus target registers its
#      ROOT path in TARGETS.md but keeps its retros at <target>/research/retros/*.md (three.js does exactly
#      this — its 5 real retros live under research/retros/). The PENDING loop must resolve retros RECURSIVELY
#      (the SAME find predicate as this file's MISSING-RETRO pass), so a pending retro under research/retros/ is
#      LISTED, counted, and AGED. Against the OLD flat "$p/retros/*.md" glob (d="$p/retros"; [ -d "$d" ] ||
#      continue) this retro was NEVER surfaced — the target's flat retros/ dir does not exist, so the loop
#      'continue'd and the retro was invisible: never listed, never aged, never escalated. This case is RED on
#      that code (it would print '0 pending / 0 retros'), proving the teeth of the recursive fix.
kit="$(mkkit c21-nested)"; tgt="$kit/targetA"
mkretro "$tgt/research" "n1.md" "<!-- review-status: pending -->" 2   # → $tgt/research/retros/n1.md (NOT $tgt/retros/)
touch -d '2000-01-01' "$tgt/research/retros/n1.md"                     # deep past → must AGE + ESCALATE
write_targets "$kit" "$tgt"                                            # registers the ROOT, not research/
OUT="$(RSDD_RETRO_AGE_DAYS=1 "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && [ ! -d "$tgt/retros" ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'research/retros/n1.md' <<<"$OUT" \
   && grep -q '~2 proposed deltas' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT" \
   && grep -q 'ESCALATED (aged' <<<"$OUT"; then
  ok "21 nested research/retros/ layout → LISTED + AGED (recursive resolution)" "(exit $RC)"
else
  no "21 nested research/retros/ layout → LISTED + AGED (recursive resolution)" "exit=$RC out=[$OUT]"
fi

# 22 — INDEX/manifest files are EXCLUDED from the retro walk (Fix #38). A generated 'RETROS-INDEX.md' sitting
#      in retros/ is a table of contents, not a §18 proposal — it must NOT be counted or surfaced as a pending
#      retro (it wrongly surfaced as '~0 proposed deltas · status none' for three.js). A real pending retro
#      alongside it still surfaces. The find now carries '-not -iname "*index*.md"'. RED on the old find (the
#      index would count as a 2nd retro → 'Summary: 1 pending / 2 retros' and print RETROS-INDEX.md).
kit="$(mkkit c22-index)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 2            # a real pending retro
printf '# Retros index\n\n| # | file |\n|---|---|\n| 1 | r1.md |\n' > "$tgt/retros/RETROS-INDEX.md"  # generated index
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'r1.md' <<<"$OUT" \
   && ! grep -q 'RETROS-INDEX.md' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "22 INDEX file in retros/ → excluded; real retro still listed" "(exit $RC)"
else
  no "22 INDEX file in retros/ → excluded; real retro still listed" "exit=$RC out=[$OUT]"
fi

# 23 — EXCLUDED marker → not counted pending or total. A file carrying '<!-- kit-retro: exclude -->'
#      in its leading block is not a §18 kit retro at all. The sweeper must skip it completely (not
#      counted in the total, not surfaced as PENDING) and report the empty-queue path.
#      RED on an implementation that does not recognise the marker: the file surfaces as pending.
kit="$(mkkit c23-excluded)"; tgt="$kit/targetA"
mkretro "$tgt" "client.md" "<!-- kit-retro: exclude -->" 3
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'Summary: 0 pending / 0 retros' <<<"$OUT" \
   && grep -q 'Nothing to review.' <<<"$OUT"; then
  ok "23 excluded marker → not counted pending or total (0/0)" "(exit $RC)"
else
  no "23 excluded marker → not counted pending or total (0/0)" "exit=$RC out=[$OUT]"
fi

# 24 — OPT-OUT DEFAULT: an UNMARKED file IS counted pending. This proves the design is opt-out
#      (INCLUDE by default), not opt-in. A target with one excluded client retro AND one normal
#      unmarked retro: only the unmarked one must surface (1 pending / 1 retros), proving the
#      exclusion is not a blanket silencer.
kit="$(mkkit c24-optout-default)"; tgt="$kit/targetA"
mkretro "$tgt" "client.md" "<!-- kit-retro: exclude -->" 2
mkretro "$tgt" "normal.md" "-" 1
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'normal.md' <<<"$OUT" \
   && ! grep -q 'client.md' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "24 opt-out default → excluded not listed, unmarked surfaces (1 pending / 1 retros)" "(exit $RC)"
else
  no "24 opt-out default → excluded not listed, unmarked surfaces (1 pending / 1 retros)" "exit=$RC out=[$OUT]"
fi

# 25 — TWO-SCAN-SITE: target with only excluded retros + an old block → MISSING-RETRO fires.
#      The MISSING-RETRO fleet pass also walks retros/ to find the newest retro date (nr). When the
#      only retro is excluded, nr must stay 0; any block file with nb > 0 fires the warning. RED on a
#      partial implementation (pending pass excluded, MISSING-RETRO pass not excluded): the excluded
#      retro's FRESH mtime sets nr to ~now, which is newer than the old block (nb < nr), so
#      MISSING-RETRO is SUPPRESSED — the two-scan-site hole. An opt-out that silently drops a
#      MISSING-RETRO warning is as bad as missing the file from the sweep altogether.
kit="$(mkkit c25-both-scan-sites)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
printf '<!-- kit-retro: exclude -->\n# client retro - not §18\n' > "$tgt/retros/client.md"
touch "$tgt/retros/client.md"             # FRESH mtime — would suppress MISSING-RETRO if counted
printf '# b\n' > "$tgt/t-block1.md"
touch -d '2000-01-01' "$tgt/t-block1.md" # OLD block (nb < current-time; still > 0)
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q "MISSING-RETRO: $tgt advanced" <<<"$OUT" \
   && grep -q 'Summary: 0 pending / 0 retros' <<<"$OUT"; then
  ok "25 only-excluded retro + old block → MISSING-RETRO fires (both scan sites wired)" "(exit $RC)"
else
  no "25 only-excluded retro + old block → MISSING-RETRO fires (both scan sites wired)" "exit=$RC out=[$OUT]"
fi

# 26 — GARBLED MARKER falls through to INCLUDE (fail-open). A typo'd value ('excluded' instead of
#      'exclude') must NOT match the opt-out marker, so the file surfaces as PENDING. This proves the
#      exclusion is exact-match on the value, not a substring catch-all.
kit="$(mkkit c26-garbled)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- kit-retro: excluded -->" 2   # typo: 'excluded' not 'exclude'
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'r1.md' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "26 garbled marker (excluded vs exclude) → fail-open, file surfaces as PENDING" "(exit $RC)"
else
  no "26 garbled marker (excluded vs exclude) → fail-open, file surfaces as PENDING" "exit=$RC out=[$OUT]"
fi

# 27 — BODY-POSITION OPT-OUT (M5 invariant). A file whose '<!-- kit-retro: exclude -->' marker
#      appears BELOW its leading block (after the '# retro' heading — not in the leading HTML-comment
#      block) must still surface as PENDING. Mirrors case 14 (body-position review-status marker is
#      ignored) for the exclusion marker. This pins the '{ exit }' guard in retro_is_excluded's awk:
#      removing it (M5 mutation) enables a whole-file scan that finds the body marker and falsely
#      excludes the retro. The M5 tooth (--prove-teeth) asserts that this case goes RED on M5.
kit="$(mkkit c27-body-excluded)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "-" 2   # no leading marker; '# retro' heading on the first content line
printf '\n<!-- kit-retro: exclude -->\n' >> "$tgt/retros/r1.md"   # body-position marker
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'status: none' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "27 body-position exclude marker → still PENDING (M5 invariant, marker ignored outside leading block)" "(exit $RC)"
else
  no "27 body-position exclude marker → still PENDING (M5 invariant, marker ignored outside leading block)" "exit=$RC out=[$OUT]"
fi

# 28 — WARN on unrecognized review-status. A retro with a marker word that is neither
#      'pending', 'applied', 'dismissed', nor empty must surface as PENDING and also print a
#      visible WARN so the ambiguous status is not silently swallowed.
#      RED before G1 implementation: no WARN is printed for the word 'accepted'.
kit="$(mkkit c28-unrecognized)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: accepted -->" 1
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -qi "WARN.*unrecognized.*review-status.*accepted" <<<"$OUT"; then
  ok "28 unrecognized status 'accepted' → PENDING + WARN printed" "(exit $RC)"
else
  no "28 unrecognized status 'accepted' → PENDING + WARN printed" "exit=$RC out=[$OUT]"
fi

# 29 — Delta count for heading-style deltas ('## D<n>'). A retro that lists its deltas
#      as '## D1 — ...' / '## D2 — ...' section headings (not a markdown table) must report
#      the correct delta count. The old counter only matched '| <digits> |' table rows and
#      would report ~0 for a heading-only retro.
#      RED before G2 fix: the count stays at 0 for a heading-only retro.
kit="$(mkkit c29-headingdeltas)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## D1 — first delta\n\nRationale.\n\n'
  printf '## D2 — second delta\n\nRationale.\n\n'
  printf '## D3 — third delta\n\nRationale.\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~3 proposed deltas' <<<"$OUT"; then
  ok "29 heading-style deltas (## D<n>) → counted correctly (~3)" "(exit $RC)"
else
  no "29 heading-style deltas (## D<n>) → counted correctly (~3)" "exit=$RC out=[$OUT]"
fi

# 30 — Grace window: block committed VERY RECENTLY (within grace from now) → no alert.
#      The corrected semantics suppress based on how recently the block was committed relative
#      to NOW (in-flight tolerance), not how close the block is to the retro epoch. A block
#      committed just now (nb ≈ now) with a grace of 4h must NOT fire MISSING-RETRO even
#      though the retro is 2h older.
#      Uses relative mtimes so the test remains valid regardless of when it runs.
kit="$(mkkit c30-grace-window)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 1
touch -d '2 hours ago' "$tgt/retros/r1.md"   # retro 2h ago = nr
printf '# b\n' > "$tgt/t-block1.md"
touch "$tgt/t-block1.md"                       # block just committed (nb ≈ now)
write_targets "$kit" "$tgt"
OUT="$(RSDD_MISSING_RETRO_GRACE_HOURS=4 "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! grep -q 'MISSING-RETRO' <<<"$OUT"; then
  ok "30 grace window: block just committed (nb≈now, 4h grace) → no MISSING-RETRO (in-flight)" "(exit $RC)"
else
  no "30 grace window: block just committed (nb≈now, 4h grace) → no MISSING-RETRO (in-flight)" "exit=$RC out=[$OUT]"
fi

# 31 — Grace window EXPIRY: block committed 1.5h ago, retro 2h ago, grace 1h → ALERT fires.
#      DECISIVE test for corrected C2 semantics:
#        new condition: now > nb + grace_secs → (now - nb = 90min) > 3600s → TRUE → fires ✓
#        old condition: nb > nr + grace_secs → (nb - nr = 30min) > 3600s → FALSE → silent bug
#      This test FAILS under the old nb > nr + grace_secs form (no MISSING-RETRO emitted)
#      and PASSES under the corrected now > nb + grace_secs form.
kit="$(mkkit c31-grace-expiry)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 1
touch -d '2 hours ago' "$tgt/retros/r1.md"    # retro 2h ago = nr
printf '# b\n' > "$tgt/t-block1.md"
touch -d '90 minutes ago' "$tgt/t-block1.md"  # block 1.5h ago = nb; nb - nr = 30min < 1h grace
write_targets "$kit" "$tgt"
OUT="$(RSDD_MISSING_RETRO_GRACE_HOURS=1 "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q "MISSING-RETRO: $tgt advanced" <<<"$OUT"; then
  ok "31 grace expiry: block 1.5h ago, retro 2h ago, grace 1h → MISSING-RETRO fires" "(exit $RC)"
else
  no "31 grace expiry: block 1.5h ago, retro 2h ago, grace 1h → MISSING-RETRO fires" "exit=$RC out=[$OUT]"
fi

# 32 — Retro-waived target → MISSING-RETRO suppressed + count + target path in summary.
#      Block is aged past the 24h grace window so MISSING-RETRO WOULD fire without the waiver.
#      The waiver marker is the SOLE cause of suppression; test 32b proves this differentially.
#      RED: retro_is_waived is not defined; no waiver check in fleet pass.
kit="$(mkkit c32-waived)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
printf '<!-- kit-retro: exclude -->\n<!-- retro-waived: 2026-07-27 · dormant -->\n# waiver\n' \
  > "$tgt/retros/retro-waived.md"
touch -d '2000-01-01' "$tgt/retros/retro-waived.md"        # old retro mtime (not suppressed by fresh date)
printf '# b\n' > "$tgt/t-block1.md"
touch -d '2 days ago' "$tgt/t-block1.md"                   # block aged past 24h grace — MISSING-RETRO would fire without waiver
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -qF "MISSING-RETRO: $tgt" <<<"$OUT" \
   && grep -qi 'waived.*1' <<<"$OUT" \
   && grep -qF "$tgt" <<<"$OUT"; then
  ok "32 waived target → MISSING-RETRO suppressed + count + target path in summary" "(exit $RC)"
else
  no "32 waived target → MISSING-RETRO suppressed + count + target path in summary" "exit=$RC out=[$OUT]"
fi

# 32b — Differential control: identical aged fixture WITHOUT the waiver marker must fire MISSING-RETRO.
#       Proves the waiver marker is the sole cause of suppression in test 32.
kit="$(mkkit c32b-nowaiver)"; tgt="$kit/targetA"
mkdir -p "$tgt"
printf '# b\n' > "$tgt/t-block1.md"
touch -d '2 days ago' "$tgt/t-block1.md"                   # same age as test 32, no waiver present
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && grep -qF "MISSING-RETRO: $tgt" <<<"$OUT"; then
  ok "32b aged block without waiver → MISSING-RETRO fires (differential control for test 32)" "(exit $RC)"
else
  no "32b aged block without waiver → MISSING-RETRO fires (differential control for test 32)" "exit=$RC out=[$OUT]"
fi

# 33 — Delta dedup coverage: table rows 1-3 + heading-style D4-D5 (no overlap) → 5 total.
#      When a retro uses BOTH table rows (numbers 1-3) AND heading-style deltas (D4, D5),
#      the combined count must be 5: no overlap, all five distinct delta numbers counted once.
#      Covers the dedup path (sort -un) when the two forms produce NON-OVERLAPPING numbers.
kit="$(mkkit c33-dedup-nooverlap)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n## Proposed kit deltas\n\n'
  printf '| # | delta | rationale |\n|---|---|-|\n'
  printf '| 1 | d1 | r |\n| 2 | d2 | r |\n| 3 | d3 | r |\n\n'
  printf '## D4 — heading four\n\n## D5 — heading five\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~5 proposed deltas' <<<"$OUT"; then
  ok "33 mixed table+heading (no overlap): rows 1-3 + D4-D5 → 5 deltas" "(exit $RC)"
else
  no "33 mixed table+heading (no overlap): rows 1-3 + D4-D5 → 5 deltas" "exit=$RC out=[$OUT]"
fi

# 34 — Delta dedup coverage: table rows 1-3 + heading-style D1-D3 (full overlap) → 3 unique.
#      When table rows and headings use the SAME delta numbers, sort -un deduplicates them.
#      Covers the dedup path when both forms produce OVERLAPPING numbers.
kit="$(mkkit c34-dedup-overlap)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n## Proposed kit deltas\n\n'
  printf '| # | delta | rationale |\n|---|---|-|\n'
  printf '| 1 | d1 | r |\n| 2 | d2 | r |\n| 3 | d3 | r |\n\n'
  printf '## D1 — heading (same as row 1)\n\n## D2 — heading (same as row 2)\n\n## D3 — heading (same as row 3)\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~3 proposed deltas' <<<"$OUT"; then
  ok "34 mixed table+heading (full overlap): rows 1-3 + D1-D3 → 3 unique deltas (dedup)" "(exit $RC)"
else
  no "34 mixed table+heading (full overlap): rows 1-3 + D1-D3 → 3 unique deltas (dedup)" "exit=$RC out=[$OUT]"
fi

# 35 — Invalid RSDD_MISSING_RETRO_GRACE_HOURS → WARN printed + default 24h window used.
#      A non-numeric value must print a WARN naming the bad value and fall back to 24h,
#      never silently coerce to 0. With grace=0 a just-committed block fires immediately;
#      with grace=24h (the default) a just-committed block is suppressed. The MISSING-RETRO
#      absence proves the default is in effect, not the silent 0.
#      RED before C4 fix: bash arithmetic coerces 'foo' to 0, no WARN, alert fires.
kit="$(mkkit c35-bad-grace)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 1
touch -d '2 hours ago' "$tgt/retros/r1.md"
printf '# b\n' > "$tgt/t-block1.md"
touch "$tgt/t-block1.md"                        # block just committed — within 24h default grace
write_targets "$kit" "$tgt"
OUT="$(RSDD_MISSING_RETRO_GRACE_HOURS=foo "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && grep -qi 'WARN.*RSDD_MISSING_RETRO_GRACE_HOURS' <<<"$OUT" \
   && ! grep -q 'MISSING-RETRO' <<<"$OUT"; then
  ok "35 invalid grace env: WARN printed + default 24h suppresses MISSING-RETRO" "(exit $RC)"
else
  no "35 invalid grace env: WARN printed + default 24h suppresses MISSING-RETRO" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 36 — P-prefix heading style (synthetic). A retro that lists deltas as '## P<n> — title'
#      headings must count them correctly. P is a Proposal prefix found in the real corpus;
#      the old counter only recognised D-prefix, so P-prefix retros rendered as ~0 deltas.
#      RED before this fix.
kit="$(mkkit c36-pprefix)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## P1 — first proposal\n\nRationale.\n\n'
  printf '## P2 — second proposal\n\nRationale.\n\n'
  printf '## P3 — third proposal\n\nRationale.\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~3 proposed deltas' <<<"$OUT"; then
  ok "36 P-prefix heading style (## P<n>) → counted correctly (~3)" "(exit $RC)"
else
  no "36 P-prefix heading style (## P<n>) → counted correctly (~3)" "exit=$RC out=[$OUT]"
fi

# 37 — Bare-number heading style (synthetic). A retro whose proposal headings are plain
#      numbered sections ('## 1. title', '## 2. title' …) must count them correctly.
#      This shape appears in the real corpus; the old counter did not recognise bare
#      numbers, so such retros rendered as ~0 deltas. RED before this fix.
kit="$(mkkit c37-barenum)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## 1. First proposal\n\nSomething.\n\n'
  printf '## 2. Second proposal\n\nSomething.\n\n'
  printf '## 3. Third proposal\n\nSomething.\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~3 proposed deltas' <<<"$OUT"; then
  ok "37 bare-number heading style (## N. title) → counted correctly (~3)" "(exit $RC)"
else
  no "37 bare-number heading style (## N. title) → counted correctly (~3)" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 38–45 — CORPUS-ANCHORED frozen-fixture regression tests.
# These tests run the counter against frozen fixtures copied from the real retro corpus.
# The fixtures live in tests/fixtures/ and run on any machine without external dependencies.
#
# PURPOSE: the two previous counter implementations were written against retro.template.md
# and both missed shapes that appear in the real corpus. A fix that passes only synthetic
# fixtures can silently mis-count the actual corpus that maintainers read. Frozen fixtures
# prevent that: they preserve the real heading shapes verbatim, which is where the
# regression lives — NOT in any invented approximation of them.
#
# FIXTURE INTEGRITY: each fixture contains the leading marker block and all count-bearing
# headings/table-rows verbatim in their original order. Engagement identifiers (focus
# names, target identifiers) were replaced with neutral placeholders (target-01, target-02,
# focus-a … focus-d); no structural prefix was changed and no count was affected. Each
# fixture is named after the heading shape it exercises, not the engagement. See
# tests/fixtures/README.md for the full rationale.
#
# COUNTS: verified by running the counter pipeline against both the real files and the
# frozen fixtures before writing assertions. Two counts differ from the original
# specification: p-prefix-headings-6.md reports ~6 (not ~5) because ## P6 "What worked
# well" is a P-prefix heading and the accepted over-counting rule applies;
# bare-number-headings-5.md reports ~5 (not ~4) because ## 5. "Lo que el kit hizo bien"
# is a bare-numbered heading. Both are accepted.

FIXTURES="$HERE/fixtures"

# 38 — P-prefix headings, 6 items: P1–P5 real proposals plus P6 "what worked well"
#      (accepted over-count: the P-prefix rule counts all P-headed sections).
kit="$(mkkit c38-pprefix6)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/p-prefix-headings-6.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q '~6 proposed deltas' <<<"$OUT"; then
  ok "38 corpus: p-prefix-headings-6.md → P-prefix (6 items), ~6 deltas" "(exit $RC)"
else
  no "38 corpus: p-prefix-headings-6.md → P-prefix (6 items), ~6 deltas" "exit=$RC out=[$OUT]"
fi

# 39 — P-prefix headings, 23 items (P1–P23): the large P-prefix retro that was
#      the clearest victim of the P-blind counter (the richest content rendered as ~0).
kit="$(mkkit c39-pprefix23)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/p-prefix-headings-23.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q '~23 proposed deltas' <<<"$OUT"; then
  ok "39 corpus: p-prefix-headings-23.md → P-prefix (23 items), ~23 deltas" "(exit $RC)"
else
  no "39 corpus: p-prefix-headings-23.md → P-prefix (23 items), ~23 deltas" "exit=$RC out=[$OUT]"
fi

# 40 — D-prefix headings, 12 items (D1–D12, non-contiguous order): already counted
#      correctly before the P-prefix fix; anchored here to catch any regression.
kit="$(mkkit c40-dprefix12)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/d-prefix-headings-12.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q '~12 proposed deltas' <<<"$OUT"; then
  ok "40 corpus: d-prefix-headings-12.md → D-prefix (12 items), ~12 deltas" "(exit $RC)"
else
  no "40 corpus: d-prefix-headings-12.md → D-prefix (12 items), ~12 deltas" "exit=$RC out=[$OUT]"
fi

# 41 — D-prefix headings, 7 items (D13–D19): second of three D-prefix fixtures.
kit="$(mkkit c41-dprefix7)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/d-prefix-headings-7.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q '~7 proposed deltas' <<<"$OUT"; then
  ok "41 corpus: d-prefix-headings-7.md → D-prefix (7 items), ~7 deltas" "(exit $RC)"
else
  no "41 corpus: d-prefix-headings-7.md → D-prefix (7 items), ~7 deltas" "exit=$RC out=[$OUT]"
fi

# 42 — D-prefix headings, 4 items (D20–D23): third of three D-prefix fixtures.
kit="$(mkkit c42-dprefix4)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/d-prefix-headings-4.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q '~4 proposed deltas' <<<"$OUT"; then
  ok "42 corpus: d-prefix-headings-4.md → D-prefix (4 items), ~4 deltas" "(exit $RC)"
else
  no "42 corpus: d-prefix-headings-4.md → D-prefix (4 items), ~4 deltas" "exit=$RC out=[$OUT]"
fi

# 43 — Delta table with letter-suffix rows: '| 1b |' and '| 1c |' do NOT match the
#      '| <digits> |' pattern, so only rows '| 1 |' and '| 2 |' count → 2.
#      Anchors the letter-suffix exclusion so it is not accidentally widened.
kit="$(mkkit c43-lettersuffix2)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/delta-table-letter-suffix-2.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q '~2 proposed deltas' <<<"$OUT"; then
  ok "43 corpus: delta-table-letter-suffix-2.md → letter-suffix rows uncounted, ~2 deltas" "(exit $RC)"
else
  no "43 corpus: delta-table-letter-suffix-2.md → letter-suffix rows uncounted, ~2 deltas" "exit=$RC out=[$OUT]"
fi

# 44 — Bare-number headings, 5 items (## 1. through ## 5., including the "what worked
#      well" section — accepted over-count per the bare-number rule).
kit="$(mkkit c44-barenum5)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/bare-number-headings-5.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q '~5 proposed deltas' <<<"$OUT"; then
  ok "44 corpus: bare-number-headings-5.md → bare-number headings (5 items), ~5 deltas" "(exit $RC)"
else
  no "44 corpus: bare-number-headings-5.md → bare-number headings (5 items), ~5 deltas" "exit=$RC out=[$OUT]"
fi

# 45 — Plain delta table, 5 items: simple '| 1 |' … '| 5 |' table format; already
#      counted correctly before the heading fixes; anchored as a regression guard.
kit="$(mkkit c45-plaindelta5)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/delta-table-plain-5.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q '~5 proposed deltas' <<<"$OUT"; then
  ok "45 corpus: delta-table-plain-5.md → plain delta table (5 items), ~5 deltas" "(exit $RC)"
else
  no "45 corpus: delta-table-plain-5.md → plain delta table (5 items), ~5 deltas" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 46 — SPACELESS SEPARATORS: em dash (—, U+2014) and en dash (–, U+2013) directly
#      after the delta number, with no space before them.
#
# The heading regex at sweep-retros.sh:119 includes '—' and '–' in its separator class
# [[:space:].—–-] so that '## P1—title' and '## D1–title' (spaceless) are recognised.
# Every fixture from the real corpus puts a SPACE before the separator, so the whitespace
# member is what matches in practice; the em/en dash members have never been exercised
# and could be silently deleted as noise without failing any existing test.
#
# SYNTHETIC fixture — this shape does NOT yet exist in the real corpus. It is added here
# to pin the branch so its members are not mistaken for dead code. When a real retro does
# use a spaceless em/en dash separator, add a frozen corpus fixture and note it in
# tests/fixtures/README.md; do NOT replace this synthetic case, which serves a different
# purpose (branch coverage for a form the corpus has not yet produced).
kit="$(mkkit c46-spaceless-dash)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## P1\xe2\x80\x94spaceless em-dash separator\n\n'
  printf '## D2\xe2\x80\x93spaceless en-dash separator\n\n'
  printf '## 3\xe2\x80\x94bare number with em-dash\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~3 proposed deltas' <<<"$OUT"; then
  ok "46 spaceless separators (P1— em-dash, D2– en-dash, 3— bare) → ~3 counted" "(exit $RC)"
else
  no "46 spaceless separators (P1— em-dash, D2– en-dash, 3— bare) → ~3 counted" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 47 — FAIL-CLOSED on a broken target-paths helper. The SUT sources lib/target-paths.sh and
#      must DEFINE target_paths_all before doing any path work. A helper that exists and sources
#      cleanly but defines NO function must cause an immediate abort (non-zero exit, no summary).
#      RED before the retrofit: the SUT ignores lib/target-paths.sh entirely and runs normally.
kit="$(mkkit c47-broken-tp)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 2
write_targets "$kit" "$tgt"
printf '#!/usr/bin/env bash\n# broken: sources cleanly but defines no target_paths_all\n' \
  > "$kit/toolbelt/lib/target-paths.sh"
run "$kit"
if [ "$RC" != 0 ] \
   && grep -q 'failed to define target_paths_all' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "47 broken target-paths helper → fail-closed abort, no summary" "(exit $RC)"
else
  no "47 broken target-paths helper → fail-closed abort, no summary" "exit=$RC out=[$OUT]"
fi

# 48 — \$RESEARCH_HOME path form resolves (the whole point of the retrofit). A TARGETS.md row
#      written as \`\$RESEARCH_HOME/sub/dir\` was INVISIBLE to the old backtick+slash grep.
#      After the retrofit, target_paths_all expands the placeholder → the target resolves, its
#      pending retro surfaces. RED before retrofit: old grep sees nothing, summary is 0/0.
kit="$(mkkit c48-rh-path)"
_rh_base="$ROOT/rh_base_$$"
mkdir -p "$_rh_base"
tgt="$_rh_base/rh_target"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 3
{ printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
  printf '| 1 | t1 | `$RESEARCH_HOME/rh_target` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base" "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?
unset _rh_base
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "48 \$RESEARCH_HOME path → expanded and resolved, retro surfaced" "(exit $RC)"
else
  no "48 \$RESEARCH_HOME path → expanded and resolved, retro surfaced" "exit=$RC out=[$OUT]"
fi

# 49 — ANTI-SILENT-ZERO: TARGETS.md with no backtick-wrapped paths → zero usable paths →
#      exit 1 with a visible ERROR message, never a clean empty sweep.
#      RED before retrofit: inline grep returns empty, sweep runs with no targets, exits 0.
kit="$(mkkit c49-zeropaths)"
printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | /no/backticks |\n' \
  > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 1 ] \
   && grep -qi 'ERROR.*no usable target paths' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "49 no usable paths → exit 1, ERROR message, no summary" "(exit $RC)"
else
  no "49 no usable paths → exit 1, ERROR message, no summary" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 50 — MARKER-HONESTY NOTE printed when pending > 0. The summary alone says "N pending" which
#      a reader takes as "N units of work waiting." The note beneath the instructions must
#      clarify that "pending" tracks the review-status MARKER, not whether each delta is still
#      open work — a commit may have applied a delta without flipping the marker.
#      RED before the note is added: no Note: line appears in the output.
kit="$(mkkit c50-marker-note)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 1
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -qi 'Note:.*MARKER\|without flipping the marker' <<<"$OUT"; then
  ok "50 pending retros exist → marker-honesty note printed" "(exit $RC)"
else
  no "50 pending retros exist → marker-honesty note printed" "exit=$RC out=[$OUT]"
fi

# 51 — MARKER-HONESTY NOTE absent when queue is empty. When nothing is pending the
#      instruction block (and its note) must not appear — the note is proportionate,
#      appearing only where it changes a decision (the reviewer's next action).
#      Negative control for case 50.
kit="$(mkkit c51-no-note-when-clean)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: applied 2026-01-01 -->" 1
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'Nothing to review.' <<<"$OUT" \
   && ! grep -qi 'Note:.*MARKER\|without flipping the marker' <<<"$OUT"; then
  ok "51 no pending retros → marker-honesty note absent (clean run uncluttered)" "(exit $RC)"
else
  no "51 no pending retros → marker-honesty note absent (clean run uncluttered)" "exit=$RC out=[$OUT]"
fi

# 52 — RENAME TRADEOFF (accepted, --follow removed for performance). A retro is CREATED in an early
#      commit under one name, then RENAMED in a later commit. Without --follow, git-log's
#      diff-filter=A/added-date lookup dates the file from the RENAME commit, not its original
#      creation — this is the documented, ACCEPTED tradeoff (see sweep-retros.sh comments above the
#      git-log call): --follow costs 15x more per invocation and the fleet-wide sweep makes hundreds
#      of these calls, so it was removed to make the sweep complete inside the session-start hook's
#      30s timeout. This case is RED against a --follow'd SUT (the deep-past creation date would win
#      and the retro would ESCALATE) and GREEN after --follow's removal (the recent rename date wins,
#      under the age threshold, so the retro stays un-escalated).
kit="$(mkkit c52-rename-tradeoff)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n' \
  > "$tgt/retros/orig.md"
git -C "$tgt" init -q -b main
git -C "$tgt" config user.email t@example.com
git -C "$tgt" config user.name tester
git -C "$tgt" add -A
GIT_AUTHOR_DATE="2000-01-01T00:00:00" GIT_COMMITTER_DATE="2000-01-01T00:00:00" \
  git -C "$tgt" commit -q -m "add orig.md"
git -C "$tgt" mv retros/orig.md retros/renamed.md
GIT_AUTHOR_DATE="$(date -u +%Y-%m-%d)T00:00:00" GIT_COMMITTER_DATE="$(date -u +%Y-%m-%d)T00:00:00" \
  git -C "$tgt" commit -q -m "rename orig.md to renamed.md"
write_targets "$kit" "$tgt"
OUT="$(RSDD_RETRO_AGE_DAYS=7 "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && ! grep -q 'ESCALATED (aged' <<<"$OUT"; then
  ok "52 renamed-after-creation retro dated from rename commit, not original add (accepted --follow tradeoff)" "(exit $RC)"
else
  no "52 renamed-after-creation retro dated from rename commit, not original add (accepted --follow tradeoff)" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# Sentinel cases (RSDD-STATE declared state)
# S1 — clean: all retros applied, no blocks, no skipped → RSDD-STATE: clean (last stdout line)
kit="$(mkkit s1-sentinel-clean)"; tgt="$kit/targetA"
mkretro "$tgt" "applied.md" "<!-- review-status: applied 2026-01-01 · kit abc -->" 0
write_targets "$kit" "$tgt"
run "$kit"
last_line="$(printf '%s\n' "$OUT" | tail -1)"
if [ "$RC" = 0 ] && [ "$last_line" = "RSDD-STATE: clean" ]; then
  ok "S1 all-clean + no-skipped → RSDD-STATE: clean (last stdout line)" "(exit $RC)"
else
  no "S1 all-clean + no-skipped → expected RSDD-STATE: clean as last stdout" "exit=$RC last=[$last_line] out=[$OUT]"
fi

# S2 — attention via missing_retro: block 2 days old, no retros → missing_retro=1 → RSDD-STATE: attention
kit="$(mkkit s2-sentinel-attention)"; tgt="$kit/targetA"
mkdir -p "$tgt"
printf '# block content\n' > "$tgt/t-block1.md"
touch -d '2 days ago' "$tgt/t-block1.md"
write_targets "$kit" "$tgt"
run "$kit"
last_line="$(printf '%s\n' "$OUT" | tail -1)"
if [ "$RC" = 0 ] && [ "$last_line" = "RSDD-STATE: attention" ]; then
  ok "S2 missing_retro=1 → RSDD-STATE: attention (last stdout line)" "(exit $RC)"
else
  no "S2 missing_retro=1 → expected RSDD-STATE: attention as last stdout" "exit=$RC last=[$last_line] out=[$OUT]"
fi

# S3 — partial: skipped>0 + all findings zero → RSDD-STATE: partial
kit="$(mkkit s3-sentinel-partial)"; tgt="$kit/targetA"
mkretro "$tgt" "applied.md" "<!-- review-status: applied 2026-01-01 · kit abc -->" 0
{ printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
  printf '| 1 | t1 | `%s` |\n' "$tgt"
  printf '| 2 | t2 | `$RESEARCH_HOME/no/path/...` |\n'
} > "$kit/TARGETS.md"
run "$kit"
last_line="$(printf '%s\n' "$OUT" | tail -1)"
if [ "$RC" = 0 ] && [ "$last_line" = "RSDD-STATE: partial" ]; then
  ok "S3 skipped>0 + findings=0 → RSDD-STATE: partial (last stdout line)" "(exit $RC)"
else
  no "S3 skipped>0 + findings=0 → expected RSDD-STATE: partial as last stdout" "exit=$RC last=[$last_line] out=[$OUT]"
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
  # real tally of the '| <digits> |' rows. Break the table-row grep on a throwaway copy so it can
  # never match a numbered row, then re-run a 5-delta pending fixture: the mutant MUST report '~0'.
  # The anchor targets the first grep in the G2 dedup pipeline (grep -oE form; the old -cE form was
  # refactored when dedup was added). Breaking it silences ALL table-row matches; case 4 has teeth
  # only if the count drops to 0.
  echo "-- teeth: break the delta-count regex, expect a 5-delta retro to miscount as ~0 --"
  anchor2="grep -oE '^\| *[0-9]+ \|'"
  if [[ "$content" != *"$anchor2"* ]]; then
    no "teeth: locate delta-count regex" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-count)"; tgt="$kit/targetA"
    mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 5
    write_targets "$kit" "$tgt"
    mutant="$kit/toolbelt/sweep-retros.sh"          # replace the sandbox copy with the mutant
    broken="grep -oE '^__never_a_delta_row__'"
    printf '%s\n' "${content/"$anchor2"/$broken}" > "$mutant"
    outm="$("$BASH_BIN" "$mutant" 2>&1)"
    if grep -q '~0 proposed deltas' <<<"$outm" && ! grep -q '~5 proposed deltas' <<<"$outm"; then
      ok "teeth: count-regex-broken mutant miscounts deltas (~0 not ~5)" "(case 4 has teeth)"
    else
      no "teeth: count-regex-broken mutant miscounts deltas (~0 not ~5)" "mutant kept counting — case 4 is THEATER: [$outm]"
    fi
  fi

  # Third teeth (negative control for the fail-closed guard). Case 17 claims the post-source
  # `declare -F` guards are what turn a broken helper into a non-zero abort. Neuter BOTH guards on a
  # throwaway copy so neither check can fail (force both always-true), pair it with the same broken
  # (comment-only) helper + an APPLIED retro, and re-run: with both guards dead the SUT falls back to
  # the OLD fail-OPEN — the applied retro false-surfaces as PENDING and the run exits 0.
  echo "-- teeth: neuter the fail-closed guards, expect the broken helper to fail-OPEN again --"
  anchor3='declare -F retro_review_status >/dev/null 2>&1 || { echo "sweep-retros: helper $LIB failed to define retro_review_status" >&2; exit 1; }'
  anchor3_wv='declare -F retro_is_waived >/dev/null 2>&1 || { echo "sweep-retros: helper $LIB failed to define retro_is_waived" >&2; exit 1; }'
  if [[ "$content" != *"$anchor3"* ]]; then
    no "teeth: locate fail-closed guard" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-guard)"; tgt="$kit/targetA"
    mkretro "$tgt" "r1.md" "<!-- review-status: applied 2026-01-01 -->" 3
    write_targets "$kit" "$tgt"
    printf '#!/usr/bin/env bash\n# broken helper: no retro_review_status\n' \
      > "$kit/toolbelt/lib/retro-status.sh"
    mutant="$kit/toolbelt/sweep-retros.sh"          # replace the sandbox copy with the mutant
    # Neuter BOTH guards to no-op ':' — a literal replacement with NO '&' (bash 5.1+ expands an
    # unescaped '&' in the replacement to the matched text, which would corrupt the mutant).
    neutered=':'
    _tmp_neu="${content/"$anchor3"/$neutered}"
    printf '%s\n' "${_tmp_neu/"$anchor3_wv"/$neutered}" > "$mutant"
    outm="$("$BASH_BIN" "$mutant" 2>&1)"; rcm=$?
    if [ "$rcm" = 0 ] && grep -q 'PENDING' <<<"$outm" && ! grep -q 'failed to define' <<<"$outm"; then
      ok "teeth: guard-neutered mutant fails OPEN (applied retro surfaces as PENDING)" "(case 17 has teeth)"
    else
      no "teeth: guard-neutered mutant fails OPEN (applied retro surfaces as PENDING)" "mutant stayed closed — case 17 is THEATER: rc=$rcm [$outm]"
    fi
  fi

  # ---- Exclusion-marker teeth (cases 23-26) ----

  # Tooth E1: neuter the exclusion check in the PENDING pass → excluded file surfaces as PENDING.
  # The pending-pass check uses '$f' so the anchor is specific to that call site.
  echo "-- teeth: neuter exclusion check (pending pass), expect excluded file to false-surface as PENDING --"
  anchor_e1='retro_is_excluded "$f" && continue'
  if [[ "$content" != *"$anchor_e1"* ]]; then
    no "teeth E1: locate exclusion check in pending pass" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-excl-1)"; tgt="$kit/targetA"
    mkretro "$tgt" "client.md" "<!-- kit-retro: exclude -->" 2
    write_targets "$kit" "$tgt"
    mutant="$kit/toolbelt/sweep-retros.sh"
    printf '%s\n' "${content/"$anchor_e1"/: # __teeth_never_excludes__}" > "$mutant"
    outm="$("$BASH_BIN" "$mutant" 2>&1)"
    if grep -q 'PENDING' <<<"$outm"; then
      ok "teeth E1: excl-neutered mutant false-surfaces excluded as PENDING (case 23 has teeth)" "()"
    else
      no "teeth E1: excl-neutered mutant false-surfaces excluded as PENDING" "mutant stayed quiet — case 23 is THEATER: [$outm]"
    fi
  fi

  # Tooth E2: blanket exclusion (always-true) → an UNMARKED file also disappears (opt-out default broken).
  # Replace the sandbox lib so retro_is_excluded always returns 0 (true). With retro_review_status
  # also stubbed to return empty (no echo), every file is 'not applied/dismissed' but immediately
  # 'excluded' → 0 pending / 0 retros. Case 24 asserts 1 pending / 1 retros, which now fails → teeth proved.
  echo "-- teeth: blanket exclusion (always-exclude), expect unmarked file to disappear (opt-out default) --"
  kit="$(mkkit teeth-excl-2)"; tgt="$kit/targetA"
  mkretro "$tgt" "client.md" "<!-- kit-retro: exclude -->" 2
  mkretro "$tgt" "normal.md" "-" 1
  write_targets "$kit" "$tgt"
  printf '#!/usr/bin/env bash\nif ! declare -F retro_review_status >/dev/null 2>&1; then\n  retro_review_status() { return 0; }\nfi\nif ! declare -F retro_is_excluded >/dev/null 2>&1; then\n  retro_is_excluded() { return 0; }  # always-exclude blanket\nfi\n' \
    > "$kit/toolbelt/lib/retro-status.sh"
  outm="$("$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"
  if ! grep -q 'Summary: 1 pending' <<<"$outm"; then
    ok "teeth E2: blanket-exclude drops unmarked file (case 24 opt-out default has teeth)" "()"
  else
    no "teeth E2: blanket-exclude drops unmarked file" "mutant kept the unmarked pending — case 24 is THEATER: [$outm]"
  fi

  # Tooth E3: exclusion in PENDING pass only, not in MISSING-RETRO pass → MISSING-RETRO silent hole.
  # Fixture: excluded retro with FRESH mtime + OLD block. Correct impl: nr=0, nb=old_epoch > 0 → fires.
  # Single-scan mutant: nr=fresh_epoch (excluded retro counted), nb=old_epoch < nr → MISSING-RETRO
  # suppressed (silent hole). If it suppresses, case 25 has teeth.
  echo "-- teeth: exclusion in pending pass only → MISSING-RETRO silent hole (case 25 has teeth) --"
  anchor_e3='retro_is_excluded "$rf" && continue'
  if [[ "$content" != *"$anchor_e3"* ]]; then
    no "teeth E3: locate exclusion check in MISSING-RETRO pass" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-excl-3)"; tgt="$kit/targetA"
    mkdir -p "$tgt/retros"
    printf '<!-- kit-retro: exclude -->\n# client retro\n' > "$tgt/retros/client.md"
    touch "$tgt/retros/client.md"              # FRESH — suppresses MISSING-RETRO when counted
    printf '# b\n' > "$tgt/t-block1.md"
    touch -d '2000-01-01' "$tgt/t-block1.md"  # OLD block
    write_targets "$kit" "$tgt"
    mutant="$kit/toolbelt/sweep-retros.sh"
    printf '%s\n' "${content/"$anchor_e3"/: # __teeth_no_missing_excl__}" > "$mutant"
    outm="$("$BASH_BIN" "$mutant" 2>&1)"
    if ! grep -q "MISSING-RETRO: $tgt advanced" <<<"$outm"; then
      ok "teeth E3: single-scan-site mutant silently suppresses MISSING-RETRO (case 25 has teeth)" "()"
    else
      no "teeth E3: single-scan-site mutant keeps MISSING-RETRO (case 25 is THEATER)" "mutant still printed MISSING-RETRO: [$outm]"
    fi
  fi

  # Tooth E4: anti-vacuity — without the exclude marker the fixture file surfaces as PENDING.
  # Proves case 23 is non-trivial: the fixture itself (not the test structure) is what drives the pass.
  echo "-- teeth E4: fixture without exclude marker surfaces as PENDING (anti-vacuity) --"
  kit="$(mkkit teeth-excl-vacuity)"; tgt="$kit/targetA"
  mkretro "$tgt" "client.md" "-" 2   # NO exclude marker: an ordinary pending retro
  write_targets "$kit" "$tgt"
  outv="$("$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"
  if grep -q 'PENDING' <<<"$outv"; then
    ok "teeth E4: fixture without exclude marker surfaces as PENDING (case 23 non-trivial)" "()"
  else
    no "teeth E4: fixture without exclude marker surfaces as PENDING (anti-vacuity)" "retro did not surface — test structure is trivially passing: [$outv]"
  fi

  # Tooth G3 — narrow the heading regex back to D-only: P-prefix and bare-number fixtures must
  # then both miscount as ~0. Proves that the widened alternation ([A-Za-z][0-9]+|[0-9]+|Delta)
  # — not some other mechanism — is what makes cases 36/37/38/39/44 pass.
  # Uses sed BRE literal substitution (not bash ${var/pat} which interprets '[' as a glob class).
  # Anchor: the unique alternation string that differs old from new; grep -F for literal presence.
  echo "-- teeth G3: narrow heading regex to D-only; P-prefix and bare-number must miscount as ~0 --"
  if ! grep -qF '[A-Za-z][0-9]+|[0-9]+|Delta' "$SUT"; then
    no "teeth G3: locate widened heading regex in SUT" "anchor not found — SUT drifted?"
  else
    # Build P-prefix fixture (same as case 36)
    kit_gp="$(mkkit teeth-g3-pprefix)"; tgt_gp="$kit_gp/targetA"
    mkdir -p "$tgt_gp/retros"
    { printf '<!-- review-status: pending -->\n# Retro\n\n'
      printf '## P1 — first\n\n## P2 — second\n\n## P3 — third\n'
    } > "$tgt_gp/retros/r1.md"
    write_targets "$kit_gp" "$tgt_gp"
    # Build bare-number fixture (same as case 37)
    kit_gb="$(mkkit teeth-g3-barenum)"; tgt_gb="$kit_gb/targetA"
    mkdir -p "$tgt_gb/retros"
    { printf '<!-- review-status: pending -->\n# Retro\n\n'
      printf '## 1. First\n\n## 2. Second\n\n## 3. Third\n'
    } > "$tgt_gb/retros/r1.md"
    write_targets "$kit_gb" "$tgt_gb"
    # Write the D-only mutant via sed BRE: \[ matches literal [, + and | are literal in BRE.
    # Replaces '[A-Za-z][0-9]+|[0-9]+|Delta' with 'D[0-9]+|Delta' so the group becomes
    # (D[0-9]+|Delta[[:space:]]+[0-9]+), which matches only D-prefix and Delta-word headings.
    sed 's/\[A-Za-z\]\[0-9\]+|\[0-9\]+|Delta/D\[0-9\]+|Delta/' \
      "$SUT" > "$kit_gp/toolbelt/sweep-retros.sh"
    cp "$kit_gp/toolbelt/sweep-retros.sh" "$kit_gb/toolbelt/sweep-retros.sh"
    outm_p="$("$BASH_BIN" "$kit_gp/toolbelt/sweep-retros.sh" 2>&1)"
    outm_b="$("$BASH_BIN" "$kit_gb/toolbelt/sweep-retros.sh" 2>&1)"
    if grep -q '~0 proposed deltas' <<<"$outm_p" \
       && ! grep -q '~3 proposed deltas' <<<"$outm_p" \
       && grep -q '~0 proposed deltas' <<<"$outm_b" \
       && ! grep -q '~3 proposed deltas' <<<"$outm_b"; then
      ok "teeth G3: D-only mutant miscounts P-prefix and bare-number as ~0 (cases 36/37 have teeth)" "()"
    else
      no "teeth G3: D-only mutant miscounts P-prefix and bare-number as ~0" "p=[$outm_p] b=[$outm_b]"
    fi
  fi

  # Tooth M5: drop the bare '{ exit }' from retro_is_excluded's awk → whole-file scan in the lib.
  # A body-position exclude marker (case 27 fixture) must then FALSELY exclude the retro — the
  # mutant lib scans the whole file, finds the body marker, the retro disappears: 0 pending / 0 retros.
  # If the mutant stays PENDING, the '{ exit }' guard was never the deciding factor and case 27 is theater.
  # Uses sed to delete the ONE bare '{ exit }' line (no trailing comment) in retro_is_excluded's awk;
  # retro_review_status's matching line has a trailing '# ...' comment and is NOT deleted.
  echo "-- teeth M5: drop { exit } from retro_is_excluded awk; body-position marker must false-exclude (case 27 has teeth) --"
  kit="$(mkkit teeth-m5-body)"; tgt="$kit/targetA"
  mkretro "$tgt" "r1.md" "-" 2   # no leading marker
  printf '\n<!-- kit-retro: exclude -->\n' >> "$tgt/retros/r1.md"   # body-position marker
  write_targets "$kit" "$tgt"
  sed '/^      { exit }$/ d' "$LIB" > "$kit/toolbelt/lib/retro-status.sh"
  outm="$("$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"
  if grep -q 'Summary: 0 pending / 0 retros' <<<"$outm"; then
    ok "teeth M5: { exit }-dropped mutant false-excludes body-position retro → 0/0 (case 27 has teeth)" "()"
  else
    no "teeth M5: { exit }-dropped mutant kept retro PENDING — case 27 is THEATER" "out=[$outm]"
  fi

  # Tooth T1: neuter the declare-F guard for target_paths_all → broken helper fails OPEN.
  # Without the guard the SUT calls an undefined target_paths_all; bash reports "command not found",
  # all_paths is empty, zero-paths guard fires (exit 1) but WITHOUT the "failed to define" message.
  # Case 47 requires BOTH non-zero exit AND "failed to define" message → test goes RED. Teeth proven.
  echo "-- teeth T1: neuter declare-F for target_paths_all; broken helper must fail OPEN without the right message --"
  # The guard is a single-liner; replacing the whole line with ':' drops the || echo exit block entirely.
  _tp_guard_anchor='declare -F target_paths_all >/dev/null 2>&1 || { echo "sweep-retros:'
  if ! grep -qF "$_tp_guard_anchor" "$SUT"; then
    no "teeth T1: locate declare-F target_paths_all guard in SUT" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-t1-no-tp-guard)"; tgt="$kit/targetA"
    mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 2
    write_targets "$kit" "$tgt"
    printf '#!/usr/bin/env bash\n# broken: no target_paths_all\n' > "$kit/toolbelt/lib/target-paths.sh"
    mut="$kit/toolbelt/sweep-retros.sh"
    # Entire single-line guard is replaced with no-op; the 'failed to define' echo is gone.
    sed 's/declare -F target_paths_all .*/: # __T1_NEUTERED__/' "$SUT" > "$mut"
    outm="$("$BASH_BIN" "$mut" 2>&1)"; rcm=$?
    if [ "$rcm" != 0 ] && ! grep -q 'failed to define target_paths_all' <<<"$outm"; then
      ok "teeth T1: guard-neutered mutant exits non-zero without 'failed to define' msg (case 47 has teeth)" "()"
    else
      no "teeth T1: mutant still said 'failed to define' or exited 0 — case 47 has no teeth" "rc=$rcm out=[$outm]"
    fi
  fi

  # Tooth T2: strip RESEARCH_HOME expansion from target-paths.sh sandbox copy → case 48 goes RED.
  # Without the $RESEARCH_HOME form, all_paths is empty, zero-paths guard fires (exit 1),
  # no PENDING retro surfaces — test expects exit 0 + PENDING → RED.
  echo "-- teeth T2: remove RESEARCH_HOME expansion; case 48 must go RED (no PENDING surfaced) --"
  kit="$(mkkit teeth-t2-no-rh)"
  _rh_base_t2="$ROOT/rh_base_t2_$$"
  mkdir -p "$_rh_base_t2"
  tgt="$_rh_base_t2/rh_target"
  mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 3
  { printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
    printf '| 1 | t1 | `$RESEARCH_HOME/rh_target` |\n'
  } > "$kit/TARGETS.md"
  # Write a stripped target-paths.sh that handles only /abs form (no RESEARCH_HOME expansion).
  cat > "$kit/toolbelt/lib/target-paths.sh" <<'STRIPPED'
#!/usr/bin/env bash
if ! declare -F target_paths_all >/dev/null 2>&1; then
  target_paths_all() {
    local f="${1:-}"
    [ -n "$f" ] || return 0
    [ -f "$f" ] || { echo "target-paths: cannot read ${f}" >&2; return 1; }
    grep -oE '`/[^`]+`' "$f" 2>/dev/null | tr -d '`' | sort -u
  }
fi
STRIPPED
  outm2="$(RESEARCH_HOME="$_rh_base_t2" "$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"; rcm2=$?
  unset _rh_base_t2
  if ! grep -q 'PENDING' <<<"$outm2" || ! grep -q 'Summary: 1 pending / 1 retros' <<<"$outm2"; then
    ok "teeth T2: RESEARCH_HOME-stripped mutant: no PENDING surfaced → case 48 has teeth" "()"
  else
    no "teeth T2: stripped mutant still surfaced PENDING — case 48 is THEATER" "rc=$rcm2 out=[$outm2]"
  fi

  # Tooth T3: remove zero-paths guard from SUT → case 49 goes RED (exits 0 with Summary).
  echo "-- teeth T3: remove zero-paths guard; empty-paths run must exit 0 with Summary (case 49 has teeth) --"
  _zp_anchor='if \[ -z "\$paths" \]; then'
  if ! grep -qE "$_zp_anchor" "$SUT"; then
    no "teeth T3: locate zero-paths guard in SUT" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-t3-no-zpguard)"
    printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | /no/backticks |\n' \
      > "$kit/TARGETS.md"
    # Delete lines matching the guard block (if [ -z "$paths" ]; then ... fi).
    # Use a temp file: copy SUT, remove the 4-line guard block with sed.
    sed '/if \[ -z "\$paths" \]/,/^fi$/d' "$SUT" > "$kit/toolbelt/sweep-retros.sh"
    outm3="$("$BASH_BIN" "$kit/toolbelt/sweep-retros.sh" 2>&1)"; rcm3=$?
    if [ "$rcm3" = 0 ] && grep -q 'Summary:' <<<"$outm3" && ! grep -qi 'ERROR.*no usable' <<<"$outm3"; then
      ok "teeth T3: guard-removed mutant exits 0 with Summary (case 49 has teeth)" "()"
    else
      no "teeth T3: guard-removed mutant did not exit 0 with Summary — case 49 has no teeth" "rc=$rcm3 out=[$outm3]"
    fi
  fi

  # Tooth R1: re-add --follow to a mutant copy → case 52's renamed-retro fixture must ESCALATE
  # (dated from its deep-past ORIGINAL creation, not the recent rename commit). Proves case 52 is not
  # vacuous: the --follow removal is the deciding factor, not some other detail of the fixture.
  echo "-- teeth R1: re-add --follow; renamed-retro fixture must ESCALATE again (case 52 has teeth) --"
  anchor_r1='added="$(git -C "$p" log --diff-filter=A --format=%aI -1 -- "$f" 2>/dev/null)"'
  if [[ "$content" != *"$anchor_r1"* ]]; then
    no "teeth R1: locate git-log added-date call in SUT" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-r1-follow)"; tgt="$kit/targetA"
    mkdir -p "$tgt/retros"
    printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n| 1 | d1 | because |\n' \
      > "$tgt/retros/orig.md"
    git -C "$tgt" init -q -b main
    git -C "$tgt" config user.email t@example.com
    git -C "$tgt" config user.name tester
    git -C "$tgt" add -A
    GIT_AUTHOR_DATE="2000-01-01T00:00:00" GIT_COMMITTER_DATE="2000-01-01T00:00:00" \
      git -C "$tgt" commit -q -m "add orig.md"
    git -C "$tgt" mv retros/orig.md retros/renamed.md
    GIT_AUTHOR_DATE="$(date -u +%Y-%m-%d)T00:00:00" GIT_COMMITTER_DATE="$(date -u +%Y-%m-%d)T00:00:00" \
      git -C "$tgt" commit -q -m "rename orig.md to renamed.md"
    write_targets "$kit" "$tgt"
    mutant="$kit/toolbelt/sweep-retros.sh"          # replace the sandbox copy with the mutant
    followed="${anchor_r1/log --diff-filter=A/log --follow --diff-filter=A}"
    printf '%s\n' "${content/"$anchor_r1"/$followed}" > "$mutant"
    outm="$(RSDD_RETRO_AGE_DAYS=7 "$BASH_BIN" "$mutant" 2>&1)"
    if grep -q 'ESCALATED (aged' <<<"$outm"; then
      ok "teeth R1: --follow-restored mutant escalates from original creation date (case 52 has teeth)" "()"
    else
      no "teeth R1: --follow-restored mutant did not escalate — case 52 is THEATER" "out=[$outm]"
    fi
  fi

  # Tooth N1: remove the marker-honesty note → pending run must NOT print it (case 50 has teeth).
  # Use sed range-delete to remove the opening 'Note:' echo line AND the two continuation lines
  # that follow it; a single-line replacement would leave the continuation lines in place and the
  # 'without flipping the marker' pattern in case 50's grep would still match — a false PASS.
  echo "-- teeth N1: remove marker-honesty note (all 3 lines); pending output must lack the note (case 50 has teeth) --"
  anchor_n1='echo "Note: the count above tracks the review-status MARKER'
  if ! grep -qF "$anchor_n1" "$SUT"; then
    no "teeth N1: locate marker-honesty note in SUT" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-n1-no-note)"; tgt="$kit/targetA"
    mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 1
    write_targets "$kit" "$tgt"
    mutant="$kit/toolbelt/sweep-retros.sh"
    sed '/Note: the count above tracks the review-status MARKER/,+2d' "$SUT" > "$mutant"
    outm="$("$BASH_BIN" "$mutant" 2>&1)"
    if ! grep -qi 'Note:.*MARKER\|without flipping the marker' <<<"$outm"; then
      ok "teeth N1: note-removed mutant omits marker note → case 50 would go RED (has teeth)" "()"
    else
      no "teeth N1: note-removed mutant still prints note — case 50 is THEATER" "out=[$outm]"
    fi
  fi

  # Tooth S1: drop missing_retro from FINDINGS expression → missing_retro-only attention fixture
  # becomes FINDINGS=0 → clean → S2 would go RED. Verifies missing_retro is counted.
  echo "-- teeth S1: drop missing_retro from FINDINGS; attention fixture must flip to clean (S2 RED) --"
  findings_anchor='FINDINGS=$((pending + missing_retro))'
  if ! grep -qF "$findings_anchor" "$SUT"; then
    no "teeth S1: FINDINGS expression not found in SUT" "anchor not found — SUT drifted?"
  else
    kit_s1t="$(mkkit teeth-s1-findings)"; tgt_s1t="$kit_s1t/targetA"
    mkdir -p "$tgt_s1t"
    printf '# block content\n' > "$tgt_s1t/t-block1.md"
    touch -d '2 days ago' "$tgt_s1t/t-block1.md"
    write_targets "$kit_s1t" "$tgt_s1t"
    sed "s/FINDINGS=\$((pending + missing_retro))/FINDINGS=\$((pending))/" \
      "$SUT" > "$kit_s1t/toolbelt/sweep-retros.sh"
    outm_s1t="$("$BASH_BIN" "$kit_s1t/toolbelt/sweep-retros.sh" 2>&1)"
    last_s1t="$(printf '%s\n' "$outm_s1t" | tail -1)"
    if [ "$last_s1t" = "RSDD-STATE: clean" ]; then
      ok "teeth S1: missing_retro-dropped mutant flips to clean → S2 would go RED (has teeth)" "()"
    else
      no "teeth S1: mutant still reports attention — sed may be a no-op or S2 has no teeth" "last=[$last_s1t]"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
