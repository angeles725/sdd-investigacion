#!/usr/bin/env bash
# sweep-audits.test.sh — smoke harness for sweep-audits.sh (surfaces un-reviewed §13 audit reports
# across research-sdd targets, METHODOLOGY §13). Mirror of sweep-retros.test.sh, scoped to the
# audit-specific contract: it walks <target>/audits/*.md (not retros/), prints '~N audited claims',
# closes with a 'Summary: <pending> pending / <total> audits' line, and — the new surface from
# Discovery #1 — emits a 'WARN: … PARTIAL' line naming any target dropped for a truncated '...' path.
# The review-status marker logic is shared (lib/retro-status.sh) and already pinned exhaustively by
# retro-status.test.sh + sweep-retros.test.sh, so this suite only spot-checks it (pending/applied/none).
#
# READ-ONLY on the SUT: it runs a throwaway COPY inside a sandbox kit so KIT=dirname/.. resolves
# hermetically, with no external tool.
#
# Usage: sweep-audits.test.sh
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-audits.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
LIB="$HERE/../lib/retro-status.sh"           # shared marker reader the SUT sources
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> : lay down a runnable COPY of the SUT at <ROOT>/<name>/toolbelt/ so KIT=dirname/..
# resolves inside the sandbox; echoes the kit dir. TARGETS.md goes at its top.
mkkit() {
  local kit="$ROOT/$1"
  mkdir -p "$kit/toolbelt/lib"
  cp "$SUT" "$kit/toolbelt/sweep-audits.sh"
  cp "$LIB" "$kit/toolbelt/lib/retro-status.sh"
  printf '%s' "$kit"
}

# write_targets <kit> <targetpath...> : minimal TARGETS.md carrying each target as a backtick-wrapped
# absolute path — the only thing the SUT reads out of it.
write_targets() {
  local kit="$1"; shift
  { printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
    local i=0 t
    for t in "$@"; do i=$((i+1)); printf '| %d | t%d | `%s` |\n' "$i" "$i" "$t"; done
  } > "$kit/TARGETS.md"
}

# mkaudit <target> <filename> <marker-line|-> <nclaims> : write an audit with an optional top marker
# and <nclaims> table rows shaped like '| <n> | ... |' (what the SUT counts as audited claims).
mkaudit() {
  local tgt="$1" fname="$2" marker="$3" nc="$4" i=0
  mkdir -p "$tgt/audits"
  {
    [ "$marker" = "-" ] || printf '%s\n' "$marker"
    printf '# audit\n\n## Audited claims\n\n| # | claim | verdict |\n|---|---|---|\n'
    while [ "$i" -lt "$nc" ]; do i=$((i+1)); printf '| %d | claim %d | CONFIRMED |\n' "$i" "$i"; done
  } > "$tgt/audits/$fname"
}

run() { OUT="$("$BASH_BIN" "$1/toolbelt/sweep-audits.sh" 2>&1)"; RC=$?; }

echo "== sweep-audits.test.sh (SUT: $(basename "$SUT")) =="

# 1 — PENDING marker → surfaced with claim count + audit-specific summary wording.
kit="$(mkkit c1-pending)"; tgt="$kit/targetA"
mkaudit "$tgt" "a1.md" "<!-- review-status: pending -->" 3
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'a1.md' <<<"$OUT" \
   && grep -q 'status: pending' <<<"$OUT" \
   && grep -q '~3 audited claims' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 audits' <<<"$OUT"; then
  ok "1 pending audit → surfaced as PENDING (~3 claims)" "(exit $RC)"
else
  no "1 pending audit → surfaced as PENDING (~3 claims)" "exit=$RC out=[$OUT]"
fi

# 2 — APPLIED marker → excluded (counted in total, never printed PENDING, empty-queue path).
kit="$(mkkit c2-applied)"; tgt="$kit/targetA"
mkaudit "$tgt" "a1.md" "<!-- review-status: applied 2026-01-01 · kit deadbeef -->" 4
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'Summary: 0 pending / 1 audits' <<<"$OUT" \
   && grep -q 'Nothing to review.' <<<"$OUT"; then
  ok "2 applied audit → excluded, empty queue" "(exit $RC)"
else
  no "2 applied audit → excluded, empty queue" "exit=$RC out=[$OUT]"
fi

# 3 — ABSENT marker → pending with 'status: none' (a missing marker reads as pending, like retros).
kit="$(mkkit c3-nomarker)"; tgt="$kit/targetA"
mkaudit "$tgt" "a1.md" "-" 2
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'PENDING' <<<"$OUT" && grep -q 'status: none' <<<"$OUT"; then
  ok "3 absent marker → pending, status: none" "(exit $RC)"
else
  no "3 absent marker → pending, status: none" "exit=$RC out=[$OUT]"
fi

# 4 — MULTI-TARGET aggregation across two targets (one pending + one applied, plus one pending).
kit="$(mkkit c4-multi)"; tgtA="$kit/targetA"; tgtB="$kit/targetB"
mkaudit "$tgtA" "p.md"    "<!-- review-status: pending -->" 2
mkaudit "$tgtA" "done.md" "<!-- review-status: applied 2026-01-01 -->" 5
mkaudit "$tgtB" "p.md"    "<!-- review-status: pending -->" 1
write_targets "$kit" "$tgtA" "$tgtB"
run "$kit"
if [ "$RC" = 0 ] && grep -q 'Summary: 2 pending / 3 audits' <<<"$OUT"; then
  ok "4 multi-target → 2 pending / 3 audits aggregated" "(exit $RC)"
else
  no "4 multi-target → 2 pending / 3 audits aggregated" "exit=$RC out=[$OUT]"
fi

# 5 — WARN on a truncated '...' path (Discovery #1). A target whose backtick path contains '...'
#     is dropped from the walk, but the summary must WARN that the sweep is PARTIAL and NAME the
#     skipped target (its basename). The real target still sweeps normally.
kit="$(mkkit c5-warn)"; tgtA="$kit/targetA"; tgtDots="$kit/Honeywell...niagara-help"
mkaudit "$tgtA" "a1.md" "<!-- review-status: pending -->" 1
mkaudit "$tgtDots" "a1.md" "<!-- review-status: pending -->" 1   # exists on disk, still dropped
write_targets "$kit" "$tgtA" "$tgtDots"
run "$kit"
if [ "$RC" = 0 ] \
   && [ -d "$tgtDots/audits" ] \
   && grep -q 'Summary: 1 pending / 1 audits' <<<"$OUT" \
   && grep -qE 'WARN: 1 target\(s\) skipped .* PARTIAL' <<<"$OUT" \
   && grep -q 'Honeywell...niagara-help' <<<"$OUT"; then
  ok "5 truncated '...' path → dropped, WARN names it, sweep PARTIAL" "(exit $RC)"
else
  no "5 truncated '...' path → dropped, WARN names it, sweep PARTIAL" "exit=$RC out=[$OUT]"
fi

# 6 — NO truncated paths → NO WARN (negative control: the WARN must not fire spuriously).
kit="$(mkkit c6-nowarn)"; tgt="$kit/targetA"
mkaudit "$tgt" "a1.md" "<!-- review-status: pending -->" 1
write_targets "$kit" "$tgt"
run "$kit"
if [ "$RC" = 0 ] && ! grep -q 'WARN' <<<"$OUT" && ! grep -q 'PARTIAL' <<<"$OUT"; then
  ok "6 no '...' paths → no WARN (negative control)" "(exit $RC)"
else
  no "6 no '...' paths → no WARN (negative control)" "exit=$RC out=[$OUT]"
fi

# 7 — MISSING TARGETS.md → abort exit 1, no summary.
kit="$(mkkit c7-notargets)"   # no write_targets → TARGETS.md absent
run "$kit"
if [ "$RC" = 1 ] && grep -qi 'cannot find' <<<"$OUT" && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "7 missing TARGETS.md → exit 1, no summary" "(exit $RC)"
else
  no "7 missing TARGETS.md → exit 1, no summary" "exit=$RC out=[$OUT]"
fi

# 8 — AGING / ESCALATION + oldest-first ordering (Feature #26). Two pending audits: one deep-past mtime, one
#      fresh. Sandbox is not git → the SUT's git-first-commit lookup returns empty and FALLS BACK to file
#      mtime — this case drives that fallback path specifically (git-first-commit itself IS hermetically
#      fakeable via GIT_AUTHOR_DATE/GIT_COMMITTER_DATE — see the sibling stage-retro.test.sh's `mkrepo` and
#      research-sdd-archive.test.sh's `mkgood_git`, which already build hermetic git repos this way — a
#      dedicated git-added-date case for audits is left as a follow-up, not driven here). With
#      RSDD_RETRO_AGE_DAYS=1 the aged one is TAGGED 'ESCALATED (aged Nd)' and prints BEFORE the fresh one.
kit="$(mkkit c8-aging)"; tgt="$kit/targetA"
mkaudit "$tgt" "fresh.md" "<!-- review-status: pending -->" 1
mkaudit "$tgt" "old.md"   "<!-- review-status: pending -->" 1
touch -d '2000-01-01' "$tgt/audits/old.md"
touch "$tgt/audits/fresh.md"
write_targets "$kit" "$tgt"
OUT="$(RSDD_RETRO_AGE_DAYS=1 "$BASH_BIN" "$kit/toolbelt/sweep-audits.sh" 2>&1)"; RC=$?
old_ln=$(grep -n 'old.md'   <<<"$OUT" | head -1 | cut -d: -f1)
fresh_ln=$(grep -n 'fresh.md' <<<"$OUT" | head -1 | cut -d: -f1)
if [ "$RC" = 0 ] \
   && [ "$(grep -c 'ESCALATED (aged' <<<"$OUT")" = 1 ] \
   && grep -A1 'old.md' <<<"$OUT" | grep -q 'ESCALATED (aged' \
   && [ -n "$old_ln" ] && [ -n "$fresh_ln" ] && [ "$old_ln" -lt "$fresh_ln" ]; then
  ok "8 aged pending audit → ESCALATED tag + sorted oldest-first (fresh not tagged)" "(exit $RC)"
else
  no "8 aged pending audit → ESCALATED tag + sorted oldest-first (fresh not tagged)" "old_ln=$old_ln fresh_ln=$fresh_ln out=[$OUT]"
fi

# 9 — NESTED-CORPUS layout: audits kept DEEPER than <target>/audits/. A nested-corpus target registers its
#      ROOT in TARGETS.md but keeps its audits at <target>/research/audits/*.md. The PENDING loop must resolve
#      audits RECURSIVELY (find "$p" -path '*/audits/*.md'), so a pending audit under research/audits/ is LISTED,
#      counted, and AGED. Against the OLD flat "$p/audits/*.md" glob (d="$p/audits"; [ -d "$d" ] || continue)
#      the target's flat audits/ dir does not exist → the loop 'continue'd and the audit was invisible. This
#      case is RED on that code ('0 pending / 0 audits'), proving the teeth of the recursive fix.
kit="$(mkkit c9-nested)"; tgt="$kit/targetA"
mkaudit "$tgt/research" "n1.md" "<!-- review-status: pending -->" 3   # → $tgt/research/audits/n1.md (NOT $tgt/audits/)
touch -d '2000-01-01' "$tgt/research/audits/n1.md"                    # deep past → must AGE + ESCALATE
write_targets "$kit" "$tgt"                                           # registers the ROOT, not research/
OUT="$(RSDD_RETRO_AGE_DAYS=1 "$BASH_BIN" "$kit/toolbelt/sweep-audits.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && [ ! -d "$tgt/audits" ] \
   && grep -q 'PENDING' <<<"$OUT" \
   && grep -q 'research/audits/n1.md' <<<"$OUT" \
   && grep -q '~3 audited claims' <<<"$OUT" \
   && grep -q 'Summary: 1 pending / 1 audits' <<<"$OUT" \
   && grep -q 'ESCALATED (aged' <<<"$OUT"; then
  ok "9 nested research/audits/ layout → LISTED + AGED (recursive resolution)" "(exit $RC)"
else
  no "9 nested research/audits/ layout → LISTED + AGED (recursive resolution)" "exit=$RC out=[$OUT]"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
