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
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SWEEP_RETROS_SUT:-$HERE/../sweep-retros.sh}"   # override = run the suite against another build (RED check)
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
LIB="$HERE/../lib/retro-status.sh"           # shared marker reader the SUT now sources
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }
TP_LIB="$HERE/../lib/target-paths.sh"        # shared path derivation the SUT now sources
[ -f "$TP_LIB" ] || { echo "FATAL: target-paths helper not found: $TP_LIB" >&2; exit 2; }
RG_LIB="$HERE/../lib/retro-grammar.sh"       # shared delta-heading grammar the SUT now sources
[ -f "$RG_LIB" ] || { echo "FATAL: retro-grammar helper not found: $RG_LIB" >&2; exit 2; }
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a sandbox kit toolbelt
[ -f "$HERE/../lib/hook-wiring.sh" ] || { echo "FATAL: hook-wiring helper not found: $HERE/../lib/hook-wiring.sh" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# HERMETICITY (kit issue #1140 round-2 review, Blocking 4): lib/hook-wiring.sh's git-root walk-up
# climbs from a target to `/` unless RSDD_HOOK_WIRING_CEILING is set. Several fixtures below
# `git init` a target under $ROOT; without this, a $TMPDIR that happens to sit inside a real repo
# (this kit checkout, for instance) would let an ENCLOSING repo's .git bleed into every fixture.
RSDD_HOOK_WIRING_CEILING="$(dirname "$ROOT")"
export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok()   { printf '  PASS  %-56s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()   { printf '  FAIL  %-56s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> : lay down a runnable COPY of the SUT at <ROOT>/<name>/toolbelt/ so the script's
# KIT=dirname/.. resolves inside the sandbox; echoes the kit dir. TARGETS.md goes at its top.
mkkit() {
  local kit="$ROOT/$1"
  rsdd_stage_libs "$kit/toolbelt"   # every lib the SUT sources (retro-status, target-paths, block-files, retro-grammar, hook-wiring)
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

# wire_target <target> : create a minimal .claude/settings.json that wires retro-gate under the
# "Stop" event block so the wiring-status pass stays quiet (no absent-settings or unwired WARN)
# for tests focused on other behaviour. Writes real JSON so the awk Stop-scoped check passes.
# Call after the target dir already exists (mkretro/mkdir ensures that).
wire_target() {
  local t="$1"
  mkdir -p "$t/.claude"
  printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate-stop.sh"}]}]}}\n' \
    > "$t/.claude/settings.json"
}

# run <kit> : invoke the sandbox copy of the SUT, capture stdout+stderr into OUT, exit into RC.
run() { OUT="$("$BASH_BIN" "$1/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?; }

# run_profile <kit> : invoke with RSDD_PROFILE=1; capture STDOUT_P/STDERR_P/RC separately.
run_profile() {
  local _ef; _ef="$(mktemp "$ROOT/prof.XXXXXX")"
  STDOUT_P="$(RSDD_PROFILE=1 "$BASH_BIN" "$1/toolbelt/sweep-retros.sh" 2>"$_ef")"; RC=$?
  STDERR_P="$(cat "$_ef")"; rm -f "$_ef"
}

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

# 5 — ZERO numeric rows in canonical section → WARN, never silent ~0.
#     A pending retro whose '## Proposed kit deltas' section has a table header/separator
#     row but NO data rows (nd=0) cannot distinguish "genuinely 0 deltas" from "deltas
#     written in non-numeric form that the counter cannot see" — so the counter must
#     WARN and show ~? instead of silently reporting ~0. The human counts by hand.
#     RED on the old digit-extraction counter: it reported ~0 (silent).
#     RED on the old behaviour (STATE 2): removing the 0-row WARN (tooth D1) must cause
#     this case to silently report ~0 again.
kit="$(mkkit c5-zero)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 0
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" \
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*delta section present.*not in countable form' <<<"$OUT"; then
  ok "5 canonical section, 0 numeric rows → WARN 'not in countable form' + ~?" "(exit $RC)"
else
  no "5 canonical section, 0 numeric rows → WARN 'not in countable form' + ~?" "exit=$RC out=[$OUT]"
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

# 16b — kit issue #945 real-corpus shape: H1 line 1, blank line 2, marker line 3 (the exact
# niagara-research *-closure.md layout). Before #945, sweep-retros.sh's retro_review_status had
# NO H1 tolerance — the H1 heading itself terminated the leading-block scan before ever reaching
# the marker on line 3, so a fully APPLIED retro written in this shape stayed reported as PENDING
# forever. RED against origin/main: 'Summary: 1 pending / 1 retros' (wrongly pending).
kit="$(mkkit c16b-h1-scope)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '# §18 Retro — focus: apis — 2026-08-25\n\n'
  printf '<!-- review-status: applied 2026-09-24 · kit c10f9d9 -->\n\n'
  printf '## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n'
  printf '| 1 | delta 1 | because |\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'Summary: 0 pending / 1 retros' <<<"$OUT"; then
  ok "16b H1 + blank + applied marker → excluded (#945 real-corpus shape)" "(exit $RC)"
else
  no "16b H1 + blank + applied marker → excluded (#945 real-corpus shape)" "exit=$RC out=[$OUT]"
fi

# 16c — OUT-OF-SCOPE MARKER (kit issue #1099): a marker positioned after a SECOND heading is
# outside the shared #945 scope. Before #1099 this was silently conflated with "no marker at
# all" — same WARN wording ('add a marker'), which is misleading when a marker already exists,
# just misplaced. #1099 keeps the retro pending (sweep-retros is WARN-only, never fails the
# run) but reports it under its own distinct, typed 'out-of-scope-marker' WARN wording instead.
kit="$(mkkit c16c-oos)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '# §18 Retro — focus: apis\n\n## Notes\n\n'
  printf '<!-- review-status: applied 2026-09-24 · kit c10f9d9 -->\n\n'
  printf '## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n'
  printf '| 1 | delta 1 | because |\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'out-of-scope-marker' <<<"$OUT" \
   && ! grep -q 'add .<!-- review-status: pending' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 retros' <<<"$OUT"; then
  ok "16c out-of-scope marker (after a SECOND heading) → pending, typed WARN (#1099)" "(exit $RC)"
else
  no "16c out-of-scope marker (after a SECOND heading) → pending, typed WARN (#1099)" "exit=$RC out=[$OUT]"
fi

# 16d — REGRESSION GUARD (§7 list edges: LAST position, no trailing newline): the out-of-scope
# marker sits as the FINAL line of the file with no trailing newline — the exact shape of
# verify-registry.sh's last-field bug — and must still be detected and reported with the typed
# WARN, not silently fall back to the generic "no marker" wording.
kit="$(mkkit c16d-oos-last)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
printf '# §18 Retro — focus: apis\n\n## Notes\n\n<!-- review-status: applied 2026-09-24 -->' \
  > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'out-of-scope-marker' <<<"$OUT"; then
  ok "16d out-of-scope marker, LAST line no trailing newline → still detected (#1099, §7)" "(exit $RC)"
else
  no "16d out-of-scope marker, LAST line no trailing newline → still detected (#1099, §7)" "exit=$RC out=[$OUT]"
fi

# 16e — REGRESSION GUARD: genuinely absent marker (case 6's shape) must keep the ORIGINAL 'add a
# marker' WARN wording, never the new out-of-scope-marker wording.
kit="$(mkkit c16e-genuinely-absent)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "-" 1
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'no review-status marker' <<<"$OUT" \
   && ! grep -q 'out-of-scope-marker' <<<"$OUT"; then
  ok "16e genuinely absent marker → original 'no review-status marker' wording, unchanged" "(exit $RC)"
else
  no "16e genuinely absent marker → original 'no review-status marker' wording, unchanged" "exit=$RC out=[$OUT]"
fi

# 16f — PREFIX CONSISTENCY (kit issue #1130 finding 4/item 5): the out-of-scope-marker WARN must
# lead with the literal token 'out-of-scope-marker:' (colon immediately after, no other word
# in between) right after this tool's own 'WARN: ' wrapper — the SAME shape
# stage-retro-issues.sh and reconcile-issues.sh already use, so the finding is greppable the
# same way across all four consumers. Before this fix the wording was 'out-of-scope-marker in
# <file>' (no colon, "in" instead).
kit="$(mkkit c16f-oos-prefix)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '# §18 Retro — focus: apis\n\n## Notes\n\n'
  printf '<!-- review-status: applied 2026-09-24 · kit c10f9d9 -->\n\n'
  printf '## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n'
  printf '| 1 | delta 1 | because |\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'WARN: out-of-scope-marker: ' <<<"$OUT"; then
  ok "16f prefix consistency: WARN leads with the literal 'out-of-scope-marker:' token" "(exit $RC)"
else
  no "16f prefix consistency: expected 'WARN: out-of-scope-marker: ' in output" "exit=$RC out=[$OUT]"
fi

# 17 — FAIL-CLOSED on a broken helper. The SUT sources lib/retro-status.sh, but existence of the
#      file is not enough: the source must have DEFINED retro_marker_scope_line (kit issue #945 —
#      the shared scope function replacing retro_review_status as sweep-retros.sh's primary
#      reader). Neither script runs under `set -e`, so a helper that EXISTS and sources cleanly
#      but defines NO function would leave the reader as a 'command not found' — every retro
#      would read as 'none' and silently surface as PENDING (fail-OPEN). The post-source
#      `declare -F` guard must instead ABORT non-zero with a helper-error message BEFORE the
#      summary. Fixture: replace the sandbox helper with a comment-only file (exists, exit 0, no
#      function) and feed an APPLIED retro that MUST NOT false-surface.
kit="$(mkkit c17-broken-helper)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: applied 2026-01-01 -->" 3
write_targets "$kit" "$tgt"
printf '#!/usr/bin/env bash\n# broken helper: sources cleanly but defines no retro_marker_scope_line\n' \
  > "$kit/toolbelt/lib/retro-status.sh"
run "$kit"
if [ "$RC" != 0 ] \
   && grep -q 'failed to define retro_marker_scope_line' <<<"$OUT" \
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
   && grep -q 'ESCALATED (aged' <<<"$(grep -A1 'old.md' <<<"$OUT")" \
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

# 29 — Heading-style deltas ('## D<n>') without canonical section → WARN, never silent ~0.
#      A retro that lists deltas as '## D1 — ...' per-delta headings (no '## Proposed kit
#      deltas' section) cannot be machine-counted; the section-scoped counter detects the
#      D-prefix letter+digit headings as non-canonical delta indicators and WARNs the reviewer
#      to count by hand. The invariant: a retro with any delta indicator never reports ~0.
#      RED on the old counter: it reported ~3 from the heading forms but the digit-extraction
#      approach was fragile and prone to false negatives on section-heading variants.
#      Doctrine says: WARN loudly when non-canonical, never a confident count from headings.
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
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*non-conforming delta declaration' <<<"$OUT"; then
  ok "29 heading-style D<n> (no canonical section) → WARN 'non-conforming' + ~?" "(exit $RC)"
else
  no "29 heading-style D<n> (no canonical section) → WARN 'non-conforming' + ~?" "exit=$RC out=[$OUT]"
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

# 33 — Section-scoped count: canonical section 3 rows; D4-D5 headings outside are ignored.
#      When the canonical '## Proposed kit deltas' section has 3 numeric rows and the retro
#      ALSO has D4/D5 heading-style deltas OUTSIDE that section, the counter counts ONLY the
#      3 rows inside the canonical section — it does not count headings outside it.
#      No WARN: canonical section was found and had countable rows (STATE 1).
#      Before the section-scoped fix, the old dedup pipeline counted 5 (rows 1-3 + D4, D5).
#      After: strict section scope → 3.  The D4/D5 headings are informational outside the
#      canonical section and do not affect the count.
kit="$(mkkit c33-dedup-nooverlap)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n## Proposed kit deltas\n\n'
  printf '| # | delta | rationale |\n|---|---|-|\n'
  printf '| 1 | d1 | r |\n| 2 | d2 | r |\n| 3 | d3 | r |\n\n'
  printf '## D4 — heading four\n\n## D5 — heading five\n'
} > "$tgt/retros/r1.md"
wire_target "$tgt"
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~3 proposed deltas' <<<"$OUT" \
   && ! grep -qi 'WARN' <<<"$OUT"; then
  ok "33 section-scoped: canonical 3 rows + D4-D5 outside → ~3 (headings outside not counted)" "(exit $RC)"
else
  no "33 section-scoped: canonical 3 rows + D4-D5 outside → ~3 (headings outside not counted)" "exit=$RC out=[$OUT]"
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
# 36 — P-prefix heading style (## P<n>) without canonical section → WARN (non-conforming).
#      Doctrine-first: the counter binds to the canonical '## Proposed kit deltas' section.
#      A retro with only P-prefix headings has no canonical section; the counter detects
#      '## P1 — ...' as a non-canonical letter+digit heading indicator and WARNs.
#      The value is the loud WARN over the fragile heading-count (which could under-count
#      or over-count on section-heading variants invisible to the old heuristic).
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
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*non-conforming delta declaration' <<<"$OUT"; then
  ok "36 P-prefix (## P<n>, no canonical section) → WARN 'non-conforming' + ~?" "(exit $RC)"
else
  no "36 P-prefix (## P<n>, no canonical section) → WARN 'non-conforming' + ~?" "exit=$RC out=[$OUT]"
fi

# 37 — Bare-number heading style (## N.) without canonical section → WARN (non-conforming).
#      Doctrine: the counter binds to the canonical '## Proposed kit deltas' section.
#      A retro with only bare-number headings ('## 1. title') has no canonical section;
#      the counter detects the bare-number heading as a non-canonical indicator and WARNs.
#      WARN is the honest signal: the reviewer must count by hand, not trust a fragile
#      heuristic that was prone to false negatives on section-heading variants.
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
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*non-conforming delta declaration' <<<"$OUT"; then
  ok "37 bare-number (## N., no canonical section) → WARN 'non-conforming' + ~?" "(exit $RC)"
else
  no "37 bare-number (## N., no canonical section) → WARN 'non-conforming' + ~?" "exit=$RC out=[$OUT]"
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

# 38 — Corpus fixture: P-prefix headings, no canonical section → WARN (non-conforming).
#      The real retro uses ## P1 … ## P6 headings with no '## Proposed kit deltas' section.
#      Under doctrine-first counting, any P-prefix heading is a non-canonical delta indicator
#      → STATE 3: WARN "non-conforming declaration — count by hand". Never a confident count.
#      Before the section-scoped fix, this fixture counted ~6 via heading extraction.
kit="$(mkkit c38-pprefix6)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/p-prefix-headings-6.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" \
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*non-conforming delta declaration' <<<"$OUT"; then
  ok "38 corpus: p-prefix-headings-6.md → WARN 'non-conforming' + ~? (no canonical section)" "(exit $RC)"
else
  no "38 corpus: p-prefix-headings-6.md → WARN 'non-conforming' + ~? (no canonical section)" "exit=$RC out=[$OUT]"
fi

# 39 — Corpus fixture: P-prefix headings, 23 items, no canonical section → WARN.
#      The largest P-prefix retro — the one that rendered as ~0 before the heading-counter
#      fix and now, under doctrine-first, renders as WARN (non-conforming).
kit="$(mkkit c39-pprefix23)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/p-prefix-headings-23.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" \
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*non-conforming delta declaration' <<<"$OUT"; then
  ok "39 corpus: p-prefix-headings-23.md → WARN 'non-conforming' + ~? (no canonical section)" "(exit $RC)"
else
  no "39 corpus: p-prefix-headings-23.md → WARN 'non-conforming' + ~? (no canonical section)" "exit=$RC out=[$OUT]"
fi

# 40 — Corpus fixture: D-prefix headings, 12 items, no canonical section → WARN.
#      Regression anchor: these D-prefix headings were counted correctly by the old heading
#      counter; under section-scoped doctrine they are non-conforming and WARN instead.
kit="$(mkkit c40-dprefix12)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/d-prefix-headings-12.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" \
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*non-conforming delta declaration' <<<"$OUT"; then
  ok "40 corpus: d-prefix-headings-12.md → WARN 'non-conforming' + ~? (no canonical section)" "(exit $RC)"
else
  no "40 corpus: d-prefix-headings-12.md → WARN 'non-conforming' + ~? (no canonical section)" "exit=$RC out=[$OUT]"
fi

# 41 — Corpus fixture: D-prefix headings, 7 items (D13–D19) → WARN.
kit="$(mkkit c41-dprefix7)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/d-prefix-headings-7.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" \
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*non-conforming delta declaration' <<<"$OUT"; then
  ok "41 corpus: d-prefix-headings-7.md → WARN 'non-conforming' + ~? (no canonical section)" "(exit $RC)"
else
  no "41 corpus: d-prefix-headings-7.md → WARN 'non-conforming' + ~? (no canonical section)" "exit=$RC out=[$OUT]"
fi

# 42 — Corpus fixture: D-prefix headings, 4 items (D20–D23) → WARN.
kit="$(mkkit c42-dprefix4)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/d-prefix-headings-4.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" \
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*non-conforming delta declaration' <<<"$OUT"; then
  ok "42 corpus: d-prefix-headings-4.md → WARN 'non-conforming' + ~? (no canonical section)" "(exit $RC)"
else
  no "42 corpus: d-prefix-headings-4.md → WARN 'non-conforming' + ~? (no canonical section)" "exit=$RC out=[$OUT]"
fi

# 43 — Delta table with letter-suffix rows: '| 1b |' and '| 1c |' count as data rows
#      under ID-agnostic counting. The fixture has 4 data rows (| 1 |, | 1b |, | 1c |, | 2 |)
#      → ~4 deltas. Previously the strict '| <digits> |' pattern counted only ~2; under
#      doctrine-first ID-agnostic counting, the first-column content is irrelevant — every
#      non-separator table row under the canonical section is one delta.
kit="$(mkkit c43-lettersuffix4)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/delta-table-letter-suffix-2.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q '~4 proposed deltas' <<<"$OUT"; then
  ok "43 corpus: delta-table-letter-suffix-2.md → ID-agnostic: all 4 data rows counted (~4)" "(exit $RC)"
else
  no "43 corpus: delta-table-letter-suffix-2.md → ID-agnostic: all 4 data rows counted (~4)" "exit=$RC out=[$OUT]"
fi

# 44 — Corpus fixture: bare-number headings (## 1., ## 2. … ## 5.), no canonical section.
#      Under doctrine-first counting, bare-number headings (`## N.`) are a non-canonical
#      delta indicator (matching pattern [0-9]+[.—–-]) with no canonical `## Proposed kit
#      deltas` section → STATE 3: WARN "non-conforming declaration — count by hand". The
#      old heading-extraction counter counted ~5; under section-scoped doctrine it WARNs.
kit="$(mkkit c44-barenum5)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"; cp "$FIXTURES/bare-number-headings-5.md" "$tgt/retros/"
write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" \
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*non-conforming delta declaration' <<<"$OUT"; then
  ok "44 corpus: bare-number-headings-5.md → WARN 'non-conforming' + ~? (no canonical section)" "(exit $RC)"
else
  no "44 corpus: bare-number-headings-5.md → WARN 'non-conforming' + ~? (no canonical section)" "exit=$RC out=[$OUT]"
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
#      after the delta number, with no space before them — NO canonical section.
#
# The non-canonical indicator check in sweep-retros.sh includes '—' and '–' in its
# separator class [[:space:].—–-] so that '## P1—title' and '## D2–title' (spaceless)
# are recognised as non-canonical delta indicators → STATE 3: WARN "non-conforming
# declaration — count by hand". Under doctrine-first counting, only the canonical
# `## Proposed kit deltas` table form produces a numeric count.
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
   && grep -qF '~? proposed deltas' <<<"$OUT" \
   && grep -qi 'WARN.*non-conforming delta declaration' <<<"$OUT"; then
  ok "46 spaceless separators (P1— D2– 3—, no canonical section) → WARN 'non-conforming' + ~?" "(exit $RC)"
else
  no "46 spaceless separators (P1— D2– 3—, no canonical section) → WARN 'non-conforming' + ~?" "exit=$RC out=[$OUT]"
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

# 47b — kit issue #1108 round 2: lib/hook-wiring.sh FILE absent → exit 1, 'cannot find helper',
#       no summary. The sourcing block now lives at the TOP with the other libs (moved out of
#       the mid-script WIRING-STATUS pass, kit issue #1108 round 2 RSDD_PROFILE fix), so this
#       must fail BEFORE any retro-scanning work runs.
kit="$(mkkit c47b-absent-hw)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 2
write_targets "$kit" "$tgt"
rm "$kit/toolbelt/lib/hook-wiring.sh"
run "$kit"
if [ "$RC" != 0 ] && grep -q 'cannot find helper' <<<"$OUT" && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "47b hook-wiring helper file absent → fail-closed abort, no summary" "(exit $RC)"
else
  no "47b hook-wiring helper file absent → fail-closed abort, no summary" "exit=$RC out=[$OUT]"
fi

# 47c — kit issue #1108 round 2: lib/hook-wiring.sh exists but defines no
#       hook_stop_wiring_state_var → exit 1, 'failed to define', no summary.
kit="$(mkkit c47c-broken-hw)"; tgt="$kit/targetA"
mkretro "$tgt" "r1.md" "<!-- review-status: pending -->" 2
write_targets "$kit" "$tgt"
printf '#!/usr/bin/env bash\n# broken: sources cleanly but defines no hook_stop_wiring_state_var\n' \
  > "$kit/toolbelt/lib/hook-wiring.sh"
run "$kit"
if [ "$RC" != 0 ] \
   && grep -q 'failed to define hook_stop_wiring_state_var' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "47c broken hook-wiring helper → fail-closed abort, no summary" "(exit $RC)"
else
  no "47c broken hook-wiring helper → fail-closed abort, no summary" "exit=$RC out=[$OUT]"
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

# 53 — CLEAN SENTINEL must NOT fire before the MISSING-RETRO pass is complete (sentinel
#      relocation, PR #2). A fleet with pending==0 but ≥1 MISSING-RETRO target printed
#      "Nothing to review." AND THEN "MISSING-RETRO: ..." — a §7 false-clean (clean claimed
#      before the instrument finished looking). After the fix the sentinel is relocated to
#      AFTER the MISSING-RETRO pass and gated on missing==0 in addition to pending==0.
#
#      FIXTURE ISOLATION (learned from PR #1 contamination): one target carries an applied retro
#      (pending=0 contribution, no blocks → no MISSING-RETRO from it), one target carries an old
#      block + NO retros (missing=1, pending=0 from it). No skipped targets. Each signal is
#      exclusive: only missing>0 is what must suppress the sentinel — not pending, not skipped.
#
#      RED on pre-fix SUT: sentinel fires at pending==0 before MISSING-RETRO is computed →
#      "Nothing to review." prints despite the fleet not having been fully inspected.
kit="$(mkkit c53-missing-clean)"; tgt_clean="$kit/targetA"; tgt_miss="$kit/targetB"
mkretro "$tgt_clean" "r1.md" "<!-- review-status: applied 2026-01-01 -->" 1
mkdir -p "$tgt_miss"
printf '# b\n' > "$tgt_miss/t-block1.md"
touch -d '2 days ago' "$tgt_miss/t-block1.md"   # old block (past 24h grace) → MISSING-RETRO fires; nr=0 (no retros)
write_targets "$kit" "$tgt_clean" "$tgt_miss"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'Nothing to review.' <<<"$OUT" \
   && grep -q "MISSING-RETRO: $tgt_miss advanced" <<<"$OUT"; then
  ok "53 pending=0 + MISSING-RETRO target → clean sentinel ABSENT; MISSING-RETRO printed" "(exit $RC)"
else
  no "53 pending=0 + MISSING-RETRO target → clean sentinel ABSENT; MISSING-RETRO printed" "exit=$RC out=[$OUT]"
fi

# 54 — PARTIAL SWEEP must NOT print "Nothing to review." (skipped_count gate, PR #2 correction).
#      A fleet with skipped_count>0 (truncated '...' path in TARGETS.md) but pending==0 and
#      missing==0 must be reported as PARTIAL, NOT clean. Before the PR #2 fix the sentinel was
#      gated on pending==0 only, so a PARTIAL sweep with pending=0 silently claimed "Nothing to
#      review." despite the sweep being incomplete.
#
#      FIXTURE ISOLATION: one clean target (applied retro, no block files → pending=0, missing=0);
#      one TARGETS.md entry whose path contains '...' → skipped_count=1, excluded before [ -d ].
#      The ONLY not-clean signal is skipped_count; pending and missing stay 0.
#
#      RED on pre-fix SUT (7170e21): gate was pending==0 only → "Nothing to review." fires despite
#      skipped_count>0 (PARTIAL sweep). GREEN on fixed SUT: gate requires skipped_count==0 too.
kit="$(mkkit c54-partial-clean)"; tgt_clean="$kit/targetA"
tgt_skip="$kit/truncated...path"   # '...' → filtered into skipped_count before [ -d ] check
mkretro "$tgt_clean" "r1.md" "<!-- review-status: applied 2026-01-01 -->" 1
# tgt_skip intentionally absent on disk — the '...' grep filters it before any [ -d ] walk
write_targets "$kit" "$tgt_clean" "$tgt_skip"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'Nothing to review.' <<<"$OUT" \
   && grep -q 'PARTIAL' <<<"$OUT"; then
  ok "54 skipped_count>0 (PARTIAL sweep) → clean sentinel ABSENT; PARTIAL WARN printed" "(exit $RC)"
else
  no "54 skipped_count>0 (PARTIAL sweep) → clean sentinel ABSENT; PARTIAL WARN printed" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 55 — STATE 4: No delta indicators at all → distinct 'no delta section found (empty-input)', no WARN.
#      A retro with no recognisable delta heading (no canonical, no deprecated, no non-canonical
#      indicators) must print 'no delta section found (empty-input)' instead of a confident '~0'.
#      STATE 4 is still the only path that produces no indicator WARN — it just never claims a
#      confident zero for a retro whose canonical section might simply be absent.
kit="$(mkkit c55-nodelta)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro — target · focus · 2026-08-01\n\n'
  printf '## Already covered\n\n- lesson A → already in kit\n\n'
  printf '## Notes\n\nNothing notable this session.\n'
} > "$tgt/retros/r1.md"
wire_target "$tgt"; write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'no delta section found (empty-input)' <<<"$OUT" \
   && ! grep -qi 'WARN' <<<"$OUT"; then
  ok "55 no delta indicators → no delta section found (empty-input), no WARN" "(exit $RC)"
else
  no "55 no delta indicators → no delta section found (empty-input), no WARN" "exit=$RC out=[$OUT]"
fi

# 56 — '## Proposed deltas' is a CANONICAL section heading → table rows COUNT (STATE 1).
#      Under the tolerant heading recogniser, '## Proposed deltas' matches the fleet corpus
#      form and is treated as canonical. A table with 1 data row under it counts as ~1.
#      No WARN: canonical section found, table present.
kit="$(mkkit c56-proposed-deltas)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## Proposed deltas\n\n'
  printf '| # | Change |\n|---|---|\n| 1 | delta W1 |\n'
} > "$tgt/retros/r1.md"
wire_target "$tgt"; write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~1 proposed deltas' <<<"$OUT" \
   && ! grep -qi 'WARN' <<<"$OUT"; then
  ok "56 '## Proposed deltas' (canonical form) → table rows counted, ~1, no WARN" "(exit $RC)"
else
  no "56 '## Proposed deltas' (canonical form) → table rows counted, ~1, no WARN" "exit=$RC out=[$OUT]"
fi

# 57 — FORM 3: '## Delta W1 —' separator-shaped headings outside canonical section → COUNT.
#      Each '## Delta <id> — <title>' line is a form-3 delta-entry heading. Two such headings
#      must count as ~2 proposed deltas with no WARN. The '## Delta ' prefix + em-dash separator
#      is what makes these machine-countable (vs '## D1 —' which is not ## Delta-prefixed).
#      RED on the old code (would WARN 'non-conforming'); proves form-3 counting works.
kit="$(mkkit c57-delta-word)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## Delta W1 — some fix\n\n## Delta W2 — another fix\n'
} > "$tgt/retros/r1.md"
wire_target "$tgt"; write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~2 proposed deltas' <<<"$OUT" \
   && ! grep -qi 'WARN' <<<"$OUT"; then
  ok "57 '## Delta W1/W2 — …' form-3 headings → ~2 counted, no WARN" "(exit $RC)"
else
  no "57 '## Delta W1/W2 — …' form-3 headings → ~2 counted, no WARN" "exit=$RC out=[$OUT]"
fi

# 58 — INVARIANT: any delta indicator (canonical or non-canonical) must never produce
#      '~0 proposed deltas' in the output. This catches silent-zero regressions that slip
#      past individual state tests. Verified against three fixtures:
#        (a) canonical section + numeric rows → STATE 1: ~N (never 0)
#        (b) canonical section + 0 numeric rows → STATE 2: ~? (never 0)
#        (c) non-canonical indicators only → STATE 3: ~? (never 0)
#      STATE 4 (no indicators at all) outputs 'no delta section found (empty-input)' (case 55).
_inv_pass=0; _inv_fail=0
# (a) STATE 1 fixture
kit="$(mkkit c58a-inv-state1)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## Proposed kit deltas\n\n'
  printf '| # | Change |\n|---|---|\n| 1 | delta one |\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"; run "$kit"
if ! grep -q '~0 proposed deltas' <<<"$OUT"; then _inv_pass=$((_inv_pass+1))
else _inv_fail=$((_inv_fail+1)); fi
# (b) STATE 2 fixture (canonical section, D-prefix rows only)
kit="$(mkkit c58b-inv-state2)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## Proposed kit deltas\n\n'
  printf '| D1 | not numeric | file | evidence | new | HIGH |\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"; run "$kit"
if ! grep -q '~0 proposed deltas' <<<"$OUT"; then _inv_pass=$((_inv_pass+1))
else _inv_fail=$((_inv_fail+1)); fi
# (c) STATE 3 fixture (P-prefix headings, no canonical section)
kit="$(mkkit c58c-inv-state3)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## P1 — some delta\n\n## P2 — another delta\n'
} > "$tgt/retros/r1.md"
write_targets "$kit" "$tgt"; run "$kit"
if ! grep -q '~0 proposed deltas' <<<"$OUT"; then _inv_pass=$((_inv_pass+1))
else _inv_fail=$((_inv_fail+1)); fi
if [ "$_inv_fail" = 0 ]; then
  ok "58 INVARIANT: any delta indicator → never ~0 (STATE 1/2/3 all non-zero)" "($_inv_pass/3 checks passed)"
else
  no "58 INVARIANT: any delta indicator → never ~0 (STATE 1/2/3 all non-zero)" "$_inv_fail/3 checks reported ~0 — silent zero regression"
fi

# 59 — ID-AGNOSTIC TABLE COUNTING: D-prefix table rows in canonical section → COUNT (STATE 1).
#      The dominant corpus convention uses non-numeric IDs (| D1 |, | W1 |, | PN-A |) in the
#      delta table. Under the ID-agnostic row counter, these count exactly like | 1 |, | 2 |.
#      No WARN: the canonical section has a table with data rows.
#      RED on the old strict numeric counter (would report STATE 2 WARN + ~? for D-prefix rows).
kit="$(mkkit c59-dprefix-table)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## Proposed kit deltas\n\n'
  printf '| # | Change | Target | Evidence | Type | Priority |\n'
  printf '|---|---|---|---|---|---|\n'
  printf '| D1 | first delta | METHODOLOGY.md §5 | B01 | new | HIGH |\n'
  printf '| D2 | second delta | PROMPT-LOOP.md | B02 | refinement | MED |\n'
  printf '| D3 | third delta | METHODOLOGY.md §12 | B03 | new | LOW |\n'
} > "$tgt/retros/r1.md"
wire_target "$tgt"; write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~3 proposed deltas' <<<"$OUT" \
   && ! grep -qi 'WARN' <<<"$OUT"; then
  ok "59 D-prefix table rows in canonical section → ~3 counted, no WARN (ID-agnostic)" "(exit $RC)"
else
  no "59 D-prefix table rows in canonical section → ~3 counted, no WARN (ID-agnostic)" "exit=$RC out=[$OUT]"
fi

# 60 — FORM 2: canonical section + separator-shaped ### heading → COUNT.
#      '### D1 — title' under '## Proposed kit deltas' is a delta-entry heading (has '—').
#      The section exit uses /^##[^#]/ so the ### heading does NOT exit the section prematurely.
#      Must count ~1, no WARN. RED on the old /^##/ bug (which exited on the first ### line).
kit="$(mkkit c60-form2-h3)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## Proposed kit deltas\n\n'
  printf '### D1 — first fix of this run\n\nsome prose about it\n\n'
  printf '## Next section\n\nnot a delta.\n'
} > "$tgt/retros/r1.md"
wire_target "$tgt"; write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~1 proposed deltas' <<<"$OUT" \
   && ! grep -qi 'WARN' <<<"$OUT"; then
  ok "60 form 2: '### D1 — …' in canonical section → ~1 counted, no WARN" "(exit $RC)"
else
  no "60 form 2: '### D1 — …' in canonical section → ~1 counted, no WARN" "exit=$RC out=[$OUT]"
fi

# 61 — FORM 2 over-count guard: structural ### headings (no '—') are NOT counted.
#      Delta section has '### D1 — title' (delta, has '—') and '### Rationale' (structural,
#      no '—'). Must count ~1 (delta only), not ~2 (delta+structural).
#      Proves the separator-shape discriminator works: only ### with '—' count as delta entries.
kit="$(mkkit c61-form2-noover)"; tgt="$kit/targetA"
mkdir -p "$tgt/retros"
{
  printf '<!-- review-status: pending -->\n# Retro\n\n'
  printf '## Proposed kit deltas\n\n'
  printf '### D1 — first delta\n\n'
  printf '### Rationale\n\nsome reasoning without em-dash\n\n'
  printf '### D2 — second delta\n\n'
  printf '### Evidence\n\nno em-dash here either\n\n'
  printf '## Already covered\n\nnot a delta section.\n'
} > "$tgt/retros/r1.md"
wire_target "$tgt"; write_targets "$kit" "$tgt"; run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q '~2 proposed deltas' <<<"$OUT" \
   && ! grep -qi 'WARN' <<<"$OUT"; then
  ok "61 form 2 over-count guard: '### Rationale'/'### Evidence' (no —) not counted → ~2 not ~4" "(exit $RC)"
else
  no "61 form 2 over-count guard: structural ### without — excluded → ~2 not ~4" "exit=$RC out=[$OUT]"
fi


echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
