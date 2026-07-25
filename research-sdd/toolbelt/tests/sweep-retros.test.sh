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

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-56s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-56s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> : lay down a runnable COPY of the SUT at <ROOT>/<name>/toolbelt/ so the script's
# KIT=dirname/.. resolves inside the sandbox; echoes the kit dir. TARGETS.md goes at its top.
mkkit() {
  local kit="$ROOT/$1"
  mkdir -p "$kit/toolbelt/lib"
  cp "$SUT" "$kit/toolbelt/sweep-retros.sh"
  cp "$LIB" "$kit/toolbelt/lib/retro-status.sh"   # SUT sources this at $(dirname $0)/lib/
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
kit="$(mkkit c19-missing)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 1
touch -d '2000-01-01' "$tgt/retros/r1.md"     # retro is OLD
printf '# b\n' > "$tgt/t-block1.md"; touch "$tgt/t-block1.md"   # block is NEW → corpus advanced past retro
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

  # Third teeth (negative control for the fail-closed guard). Case 17 claims the post-source
  # `declare -F` guard is what turns a broken helper into a non-zero abort. Neuter the guard on a
  # throwaway copy so its check can never fail (force it always-true), pair it with the same broken
  # (comment-only) helper + an APPLIED retro, and re-run: with the guard dead the SUT falls back to
  # the OLD fail-OPEN — the applied retro false-surfaces as PENDING and the run exits 0. If the
  # mutant stayed closed (non-zero, no PENDING), case 17 would be theater.
  echo "-- teeth: neuter the fail-closed guard, expect the broken helper to fail-OPEN again --"
  anchor3='declare -F retro_review_status >/dev/null 2>&1 || { echo "sweep-retros: helper $LIB failed to define retro_review_status" >&2; exit 1; }'
  if [[ "$content" != *"$anchor3"* ]]; then
    no "teeth: locate fail-closed guard" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-guard)"; tgt="$kit/targetA"
    mkretro "$tgt" "r1.md" "<!-- review-status: applied 2026-01-01 -->" 3
    write_targets "$kit" "$tgt"
    printf '#!/usr/bin/env bash\n# broken helper: no retro_review_status\n' \
      > "$kit/toolbelt/lib/retro-status.sh"
    mutant="$kit/toolbelt/sweep-retros.sh"          # replace the sandbox copy with the mutant
    # Neuter the guard to a no-op ':' — a literal replacement with NO '&' (bash 5.1+ expands an
    # unescaped '&' in the replacement to the matched text, which would corrupt the mutant).
    neutered=':'
    printf '%s\n' "${content/"$anchor3"/$neutered}" > "$mutant"
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
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
