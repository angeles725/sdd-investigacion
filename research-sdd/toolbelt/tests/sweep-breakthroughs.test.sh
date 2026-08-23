#!/usr/bin/env bash
# sweep-breakthroughs.test.sh — red-first regression harness for sweep-breakthroughs.sh.
# Verifies the WARN-only Breakthrough Ledger checker (METHODOLOGY §22): cross-checks
# tagged blocks against BREAKTHROUGHS.md, WARNs on unindexed breakthroughs and drift,
# and distinguishes absent-input / empty-input / no-match (§7 anti-silent-zero).
#
# Usage: sweep-breakthroughs.test.sh
#        sweep-breakthroughs.test.sh --prove-teeth  (run suite + mutation teeth proof)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../sweep-breakthroughs.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
TP_LIB="$HERE/../lib/target-paths.sh"
[ -f "$TP_LIB" ] || { echo "FATAL: target-paths helper not found: $TP_LIB" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok()   { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()   { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# mkkit <name> : lay down a runnable COPY of the SUT at <ROOT>/<name>/toolbelt/
# so the script's KIT=dirname/.. resolves inside the sandbox; echoes the kit dir.
mkkit() {
  local kit="$ROOT/$1"
  mkdir -p "$kit/toolbelt/lib"
  cp "$SUT" "$kit/toolbelt/sweep-breakthroughs.sh"
  cp "$TP_LIB" "$kit/toolbelt/lib/target-paths.sh"
  printf '%s' "$kit"
}

# write_targets <kit> <targetpath...> : build a minimal TARGETS.md table.
write_targets() {
  local kit="$1"; shift
  { printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
    local i=0 t
    for t in "$@"; do i=$((i+1)); printf '| %d | t%d | `%s` |\n' "$i" "$i" "$t"; done
  } > "$kit/TARGETS.md"
}

# write_breakthroughs <kit> [<row>...]: build BREAKTHROUGHS.md with the standard header
# and any given rows; each row is a string '| N | target | what | how | memory |'.
write_breakthroughs() {
  local kit="$1"; shift
  { printf '# Research-SDD — Breakthrough Ledger\n\n'
    printf '| # | target | what (cracked) | how — block `path:line` | memory — engram topic-key |\n'
    printf '|---|--------|----------------|-------------------------|---------------------------|\n'
    printf '| — | _(no entries yet)_ | | | |\n'
    for row in "$@"; do printf '%s\n' "$row"; done
  } > "$kit/BREAKTHROUGHS.md"
}

# mkblock <dir> <filename> : write a minimal block file (NO breakthrough marker).
mkblock() {
  local dir="$1" fname="$2"
  mkdir -p "$dir"
  { printf '# Block 1\n\n'
    printf '> Research of **module**: scope.\n>\n'
    printf '> Sources: file. Method: reading.\n'
    printf '\n---\n\n## 1.1 — Section\n\nContent.\n'
  } > "$dir/$fname"
}

# mkblock_tagged <dir> <filename> : write a block file WITH the Breakthrough marker.
mkblock_tagged() {
  local dir="$1" fname="$2"
  mkdir -p "$dir"
  { printf '# Block 1\n\n'
    printf '> Research of **module**: scope.\n>\n'
    printf '> Sources: file. Method: reading.\n>\n'
    printf '> **Breakthrough:** the technique that cracked it — details here.\n'
    printf '\n---\n\n## 1.1 — Section\n\nContent.\n'
  } > "$dir/$fname"
}

# run <kit> : invoke the sandbox copy of the SUT, capture stdout+stderr into OUT, exit into RC.
run() { OUT="$("$BASH_BIN" "$1/toolbelt/sweep-breakthroughs.sh" 2>&1)"; RC=$?; }

# tagged_lineno <dir>/<file> : print the line number of the Breakthrough marker.
tagged_lineno() { grep -nE '^>[[:space:]]*\*\*Breakthrough:\*\*' "$1" | head -1 | cut -d: -f1; }

echo "== sweep-breakthroughs.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# 1 — CLEAN: tagged block + indexed row → no WARN, exit 0.
# A block carrying the marker AND an entry in the ledger is healthy; the summary
# must show 1 tagged and 0 unindexed, 0 drifted.
kit="$(mkkit c1-clean)"; tgt="$kit/targetA"
mkblock_tagged "$tgt" "pfx-block1.md"
ln=$(tagged_lineno "$tgt/pfx-block1.md")
write_targets "$kit" "$tgt"
write_breakthroughs "$kit" "| 1 | targetA | what | \`$tgt/pfx-block1.md:$ln\` | key |"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'WARN' <<<"$OUT" \
   && grep -q '1 tagged' <<<"$OUT" \
   && grep -q '0 unindexed' <<<"$OUT" \
   && grep -q '0 drifted' <<<"$OUT"; then
  ok "1 tagged+indexed block → clean, no WARN, 1 tagged 0 unindexed 0 drifted" "(exit $RC)"
else
  no "1 tagged+indexed block → clean, no WARN, 1 tagged 0 unindexed 0 drifted" "exit=$RC out=[$OUT]"
fi

# 2 — UNINDEXED: tagged block with NO row in BREAKTHROUGHS.md → WARN.
# The ledger is empty (only skeleton placeholder). The block carries the marker.
kit="$(mkkit c2-unindexed)"; tgt="$kit/targetA"
mkblock_tagged "$tgt" "pfx-block1.md"
write_targets "$kit" "$tgt"
write_breakthroughs "$kit"   # no rows — only placeholder
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qi 'WARN.*unindexed' <<<"$OUT" \
   && grep -q '1 unindexed' <<<"$OUT"; then
  ok "2 tagged+unindexed → WARN unindexed breakthrough" "(exit $RC)"
else
  no "2 tagged+unindexed → WARN unindexed breakthrough" "exit=$RC out=[$OUT]"
fi

# 3 — DRIFT: ledger row whose block file no longer carries the marker → WARN drift.
# The block file exists but does NOT have the marker; the ledger still points at it.
kit="$(mkkit c3-drift)"; tgt="$kit/targetA"
mkblock "$tgt" "pfx-block1.md"   # no marker
write_targets "$kit" "$tgt"
write_breakthroughs "$kit" "| 1 | targetA | what | \`$tgt/pfx-block1.md:5\` | key |"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qi 'WARN.*drift' <<<"$OUT" \
   && grep -q '1 drifted' <<<"$OUT"; then
  ok "3 indexed block missing marker → WARN drift" "(exit $RC)"
else
  no "3 indexed block missing marker → WARN drift" "exit=$RC out=[$OUT]"
fi

# 4 — DRIFT: ledger row whose block FILE no longer exists → WARN drift.
kit="$(mkkit c4-drift-missing-file)"; tgt="$kit/targetA"
mkblock "$tgt" "pfx-block1.md"   # create the dir/target
write_targets "$kit" "$tgt"
write_breakthroughs "$kit" "| 1 | targetA | what | \`$tgt/pfx-block99.md:5\` | key |"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qi 'WARN.*drift' <<<"$OUT" \
   && grep -q '1 drifted' <<<"$OUT"; then
  ok "4 indexed block file gone → WARN drift" "(exit $RC)"
else
  no "4 indexed block file gone → WARN drift" "exit=$RC out=[$OUT]"
fi

# 5 — NO-MATCH: corpus has block files but 0 tagged → INFO no-match (distinct from absent/empty).
# Must NOT exit 1; must print an INFO line; summary shows 0 tagged.
kit="$(mkkit c5-nomatch)"; tgt="$kit/targetA"
mkblock "$tgt" "pfx-block1.md"
mkblock "$tgt" "pfx-block2.md"
write_targets "$kit" "$tgt"
write_breakthroughs "$kit"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qi 'INFO.*no tagged' <<<"$OUT" \
   && grep -q '0 tagged' <<<"$OUT" \
   && ! grep -q 'absent' <<<"$OUT" \
   && ! grep -q 'empty' <<<"$OUT"; then
  ok "5 blocks exist but 0 tagged → INFO no-match (not absent/empty)" "(exit $RC)"
else
  no "5 blocks exist but 0 tagged → INFO no-match (not absent/empty)" "exit=$RC out=[$OUT]"
fi

# 6 — ABSENT-INPUT: target corpus dir does not exist → INFO absent (distinct from empty/no-match).
# Must NOT exit 1; must print INFO absent.
kit="$(mkkit c6-absent)"; tgt="$kit/targetA"
# tgt is NOT created on disk
write_targets "$kit" "$tgt"
write_breakthroughs "$kit"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qi 'INFO.*absent' <<<"$OUT" \
   && ! grep -q 'empty' <<<"$OUT" \
   && ! grep -qi 'no tagged' <<<"$OUT"; then
  ok "6 corpus dir absent → INFO absent (not empty/no-match)" "(exit $RC)"
else
  no "6 corpus dir absent → INFO absent (not empty/no-match)" "exit=$RC out=[$OUT]"
fi

# 7 — EMPTY-INPUT: corpus dir exists but has 0 block files → INFO empty (distinct from absent/no-match).
kit="$(mkkit c7-empty)"; tgt="$kit/targetA"
mkdir -p "$tgt"   # dir exists, but no *-block*.md files
write_targets "$kit" "$tgt"
write_breakthroughs "$kit"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qi 'INFO.*empty' <<<"$OUT" \
   && ! grep -q 'absent' <<<"$OUT" \
   && ! grep -qi 'no tagged' <<<"$OUT"; then
  ok "7 corpus exists, 0 block files → INFO empty (not absent/no-match)" "(exit $RC)"
else
  no "7 corpus exists, 0 block files → INFO empty (not absent/no-match)" "exit=$RC out=[$OUT]"
fi

# 8 — MISSING TARGETS.md → exit 1, no summary (operational failure).
kit="$(mkkit c8-notargets)"   # no write_targets → TARGETS.md absent
mkdir -p "$kit"
write_breakthroughs "$kit"
run "$kit"
if [ "$RC" = 1 ] \
   && grep -qi 'cannot find' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "8 missing TARGETS.md → exit 1, no summary" "(exit $RC)"
else
  no "8 missing TARGETS.md → exit 1, no summary" "exit=$RC out=[$OUT]"
fi

# 9 — MISSING BREAKTHROUGHS.md → exit 1, no summary (operational failure).
kit="$(mkkit c9-nobreakthroughs)"
tgt="$kit/targetA"
mkblock "$tgt" "pfx-block1.md"
write_targets "$kit" "$tgt"
# BREAKTHROUGHS.md NOT written
run "$kit"
if [ "$RC" = 1 ] \
   && grep -qi 'cannot find' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "9 missing BREAKTHROUGHS.md → exit 1, no summary" "(exit $RC)"
else
  no "9 missing BREAKTHROUGHS.md → exit 1, no summary" "exit=$RC out=[$OUT]"
fi

# 10 — BROKEN HELPER: target-paths.sh present but defines no function → fail-closed abort.
kit="$(mkkit c10-broken-helper)"; tgt="$kit/targetA"
mkblock_tagged "$tgt" "pfx-block1.md"
write_targets "$kit" "$tgt"
write_breakthroughs "$kit"
printf '#!/usr/bin/env bash\n# broken helper: sources cleanly but defines no function\n' \
  > "$kit/toolbelt/lib/target-paths.sh"
run "$kit"
if [ "$RC" != 0 ] \
   && grep -qi 'failed to define target_paths_all' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "10 broken helper → fail-closed abort, no summary" "(exit $RC)"
else
  no "10 broken helper → fail-closed abort, no summary" "exit=$RC out=[$OUT]"
fi

# 11 — MULTI-TARGET: two targets, A has a tagged+indexed block, B has a block but 0 tagged.
# Summary must aggregate across both: 1 tagged, 0 unindexed, 0 drifted; B gets an INFO no-match.
kit="$(mkkit c11-multi)"; tgtA="$kit/targetA"; tgtB="$kit/targetB"
mkblock_tagged "$tgtA" "pfx-block1.md"
mkblock "$tgtB" "pfx-block1.md"
ln=$(tagged_lineno "$tgtA/pfx-block1.md")
write_targets "$kit" "$tgtA" "$tgtB"
write_breakthroughs "$kit" "| 1 | targetA | what | \`$tgtA/pfx-block1.md:$ln\` | key |"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q '1 tagged' <<<"$OUT" \
   && grep -q '0 unindexed' <<<"$OUT" \
   && grep -qi 'INFO.*no tagged' <<<"$OUT"; then
  ok "11 multi-target: A clean, B no-match → 1 tagged 0 unindexed + INFO for B" "(exit $RC)"
else
  no "11 multi-target: A clean, B no-match → 1 tagged 0 unindexed + INFO for B" "exit=$RC out=[$OUT]"
fi

# 12 — LIST EDGE: single-element (one block file, tagged) → correctly detected and reported.
kit="$(mkkit c12-single)"; tgt="$kit/targetA"
mkblock_tagged "$tgt" "pfx-block1.md"
ln=$(tagged_lineno "$tgt/pfx-block1.md")
write_targets "$kit" "$tgt"
write_breakthroughs "$kit" "| 1 | tgt | w | \`$tgt/pfx-block1.md:$ln\` | k |"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q '1 tagged' <<<"$OUT" \
   && grep -q '0 unindexed' <<<"$OUT"; then
  ok "12 single-element list → correctly handled" "(exit $RC)"
else
  no "12 single-element list → correctly handled" "exit=$RC out=[$OUT]"
fi

# 13 — LIST EDGE FIRST: tagged block is first among three; remaining are untagged. The FIRST
# element in the block list must be detected. A trailing-newline issue (verify-registry lesson)
# that skips the last element in a loop would NOT affect this case, but a first-element skip
# would. Proves: the first element is not swallowed by the iteration.
kit="$(mkkit c13-first)"; tgt="$kit/targetA"
mkblock_tagged "$tgt" "pfx-block1.md"   # FIRST
mkblock "$tgt" "pfx-block2.md"
mkblock "$tgt" "pfx-block3.md"
ln=$(tagged_lineno "$tgt/pfx-block1.md")
write_targets "$kit" "$tgt"
write_breakthroughs "$kit" "| 1 | tgt | w | \`$tgt/pfx-block1.md:$ln\` | k |"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q '1 tagged' <<<"$OUT" \
   && grep -q '0 unindexed' <<<"$OUT" \
   && ! grep -qi 'WARN' <<<"$OUT"; then
  ok "13 tagged block FIRST in list → detected (no WARN)" "(exit $RC)"
else
  no "13 tagged block FIRST in list → detected (no WARN)" "exit=$RC out=[$OUT]"
fi

# 14 — LIST EDGE LAST: tagged block is last among three. A trailing-newline issue that skips
# the last element of the block list would leave the tagged block undetected and report
# 'unindexed' even though the ledger row is present. Proves: no last-element skip.
kit="$(mkkit c14-last)"; tgt="$kit/targetA"
mkblock "$tgt" "pfx-block1.md"
mkblock "$tgt" "pfx-block2.md"
mkblock_tagged "$tgt" "pfx-block3.md"   # LAST (lexicographically largest name)
ln=$(tagged_lineno "$tgt/pfx-block3.md")
write_targets "$kit" "$tgt"
write_breakthroughs "$kit" "| 1 | tgt | w | \`$tgt/pfx-block3.md:$ln\` | k |"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q '1 tagged' <<<"$OUT" \
   && grep -q '0 unindexed' <<<"$OUT" \
   && ! grep -qi 'WARN' <<<"$OUT"; then
  ok "14 tagged block LAST in list → detected (no WARN, no last-element skip)" "(exit $RC)"
else
  no "14 tagged block LAST in list → detected (no WARN, no last-element skip)" "exit=$RC out=[$OUT]"
fi

# 15 — LIST EDGE MIDDLE: tagged block is middle among three.
kit="$(mkkit c15-middle)"; tgt="$kit/targetA"
mkblock "$tgt" "pfx-block1.md"
mkblock_tagged "$tgt" "pfx-block2.md"   # MIDDLE
mkblock "$tgt" "pfx-block3.md"
ln=$(tagged_lineno "$tgt/pfx-block2.md")
write_targets "$kit" "$tgt"
write_breakthroughs "$kit" "| 1 | tgt | w | \`$tgt/pfx-block2.md:$ln\` | k |"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q '1 tagged' <<<"$OUT" \
   && grep -q '0 unindexed' <<<"$OUT" \
   && ! grep -qi 'WARN' <<<"$OUT"; then
  ok "15 tagged block MIDDLE in list → detected (no WARN)" "(exit $RC)"
else
  no "15 tagged block MIDDLE in list → detected (no WARN)" "exit=$RC out=[$OUT]"
fi

# 16 — PROSE SIGNAL NOT RECOGNIZED: a block containing "BREAKTHROUGH" (bare caps) but NOT the
# structured "> **Breakthrough:**" field must NOT be detected as tagged.
# Proves the recognized-form comment is enforced: informal prose is excluded.
kit="$(mkkit c16-prose)"; tgt="$kit/targetA"
mkdir -p "$tgt"
{ printf '# Block 1\n\n'
  printf '> Research of **module**: scope.\n>\n'
  printf '> Sources: file.\n'
  printf '\n---\n\n## 1.1 — Section\n\nThis was a BREAKTHROUGH finding.\n'
  printf 'The pivot came when we realized the key.\n'
} > "$tgt/pfx-block1.md"
write_targets "$kit" "$tgt"
write_breakthroughs "$kit"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q '0 tagged' <<<"$OUT" \
   && ! grep -qi 'WARN.*unindexed' <<<"$OUT"; then
  ok "16 prose 'BREAKTHROUGH' → NOT recognized (only structured field counts)" "(exit $RC)"
else
  no "16 prose 'BREAKTHROUGH' → NOT recognized (only structured field counts)" "exit=$RC out=[$OUT]"
fi

# 17 — BLOQUE naming: block file named with 'bloque' (Spanish form) is recognized.
# The gen-catalog discriminator matches both 'block' and 'bloque'.
kit="$(mkkit c17-bloque)"; tgt="$kit/targetA"
mkblock_tagged "$tgt" "pfx-bloque1.md"
ln=$(tagged_lineno "$tgt/pfx-bloque1.md")
write_targets "$kit" "$tgt"
write_breakthroughs "$kit" "| 1 | tgt | w | \`$tgt/pfx-bloque1.md:$ln\` | k |"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q '1 tagged' <<<"$OUT" \
   && grep -q '0 unindexed' <<<"$OUT"; then
  ok "17 bloque naming convention → recognized block, tagged detected" "(exit $RC)"
else
  no "17 bloque naming convention → recognized block, tagged detected" "exit=$RC out=[$OUT]"
fi

# 18 — MULTIPLE TAGGED in ONE corpus: two tagged blocks, one indexed and one not.
# Summary must show 2 tagged, 1 unindexed, 0 drifted; one WARN for the unindexed.
kit="$(mkkit c18-two-tagged)"; tgt="$kit/targetA"
mkblock_tagged "$tgt" "pfx-block1.md"
mkblock_tagged "$tgt" "pfx-block2.md"
ln1=$(tagged_lineno "$tgt/pfx-block1.md")
write_targets "$kit" "$tgt"
write_breakthroughs "$kit" "| 1 | tgt | w | \`$tgt/pfx-block1.md:$ln1\` | k |"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q '2 tagged' <<<"$OUT" \
   && grep -q '1 unindexed' <<<"$OUT" \
   && grep -qi 'WARN.*unindexed' <<<"$OUT"; then
  ok "18 two tagged, one unindexed → 2 tagged 1 unindexed 1 WARN" "(exit $RC)"
else
  no "18 two tagged, one unindexed → 2 tagged 1 unindexed 1 WARN" "exit=$RC out=[$OUT]"
fi

# 19 — FINDING NEVER FAILS: unindexed and drift WARNs still exit 0.
# Findings are WARN-only — a finding must not flip exit code to non-zero.
kit="$(mkkit c19-exit0)"; tgt="$kit/targetA"
mkblock_tagged "$tgt" "pfx-block1.md"
mkblock "$tgt" "pfx-block2.md"
write_targets "$kit" "$tgt"
write_breakthroughs "$kit" "| 1 | tgt | w | \`$tgt/pfx-block99.md:5\` | k |"   # drift
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qi 'WARN' <<<"$OUT" \
   && grep -q 'Summary:' <<<"$OUT"; then
  ok "19 findings (unindexed + drift) never fail the run → exit 0" "(exit $RC)"
else
  no "19 findings (unindexed + drift) never fail the run → exit 0" "exit=$RC out=[$OUT]"
fi

# 20 — SKELETON PLACEHOLDER ROW: the '| — | ...' skeleton is skipped, not treated as an entry.
# A ledger with only the skeleton row + no real entries must not produce drift WARNs.
kit="$(mkkit c20-skeleton)"; tgt="$kit/targetA"
mkblock "$tgt" "pfx-block1.md"
write_targets "$kit" "$tgt"
# write_breakthroughs always writes the skeleton row; no real rows added
write_breakthroughs "$kit"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -qi 'WARN.*drift' <<<"$OUT" \
   && ! grep -qi 'WARN.*unindexed' <<<"$OUT"; then
  ok "20 skeleton placeholder row → not treated as a ledger entry, no drift/unindexed WARN" "(exit $RC)"
else
  no "20 skeleton placeholder row → not treated as a ledger entry, no drift/unindexed WARN" "exit=$RC out=[$OUT]"
fi

# 21 — TRUNCATED PATH in TARGETS.md: a '...' path is filtered, sweep is PARTIAL.
# Does not crash; prints WARN about partial sweep.
kit="$(mkkit c21-dots)"; tgtA="$kit/targetA"
mkblock "$tgtA" "pfx-block1.md"
{ printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
  printf '| 1 | t1 | `%s` |\n' "$tgtA"
  printf '| 2 | t2 | `$RESEARCH_HOME/some/path/...` |\n'
} > "$kit/TARGETS.md"
write_breakthroughs "$kit"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qi 'PARTIAL\|skipped' <<<"$OUT"; then
  ok "21 truncated '...' path → filtered, WARN PARTIAL" "(exit $RC)"
else
  no "21 truncated '...' path → filtered, WARN PARTIAL" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "== $pass passed · $fail failed =="

# ---------------------------------------------------------------------------
# --prove-teeth mutation section
# ---------------------------------------------------------------------------
if [[ "${1:-}" != "--prove-teeth" ]]; then
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi

echo ""
echo "== --prove-teeth: mutation controls =="

# MUTATION controls verify that each assertion in the test suite will actually go RED
# when the SUT is mutated in the relevant way. Each mutation creates a temporary copy
# of the SUT, injects a defect, and proves the corresponding case detects it.

mut_pass=0; mut_fail=0
mut_ok() { printf '  PASS  [teeth] %-56s %s\n' "$1" "${2:-}"; mut_pass=$((mut_pass+1)); }
mut_no() { printf '  FAIL  [teeth] %-56s %s\n' "$1" "${2:-}"; mut_fail=$((mut_fail+1)); }

MUTANT_DIR="$(mktemp -d)"; trap 'rm -rf "$MUTANT_DIR"' EXIT

mutate_sut() {
  # $1=mutation_description (documentation only — not stored) $2=sed_script
  local sscript="$2"
  local mutant="$MUTANT_DIR/sweep-breakthroughs-mutant.sh"
  sed "$sscript" "$SUT" > "$mutant"
  chmod +x "$mutant"
  printf '%s' "$mutant"
}

run_mutant() {
  # Run a mutant SUT with its own kit copy.
  local kit="$1" mutant="$2"
  cp "$mutant" "$kit/toolbelt/sweep-breakthroughs.sh"
  OUT="$("$BASH_BIN" "$kit/toolbelt/sweep-breakthroughs.sh" 2>&1)"; RC=$?
}

# M1: Remove the unindexed-WARN emission → case 2 must go RED (no WARN printed).
mut_kit="$(mkkit m1-unindexed)"; tgt="$mut_kit/targetA"
mkblock_tagged "$tgt" "pfx-block1.md"
write_targets "$mut_kit" "$tgt"
write_breakthroughs "$mut_kit"
# Mutation: comment out the unindexed WARN line
mutant="$(mutate_sut "remove-unindexed-warn" 's/echo "WARN: unindexed/# DISABLED: echo "WARN: unindexed/')"
run_mutant "$mut_kit" "$mutant"
if ! grep -qi 'WARN.*unindexed' <<<"$OUT"; then
  mut_ok "M1 no-unindexed-warn → case 2 (unindexed block) goes RED" "(WARN absent on mutant)"
else
  mut_no "M1 no-unindexed-warn → mutation not detected by case 2" "out=[$OUT]"
fi

# M2: Remove the drift-WARN emission → case 3 must go RED (no drift WARN).
mut_kit="$(mkkit m2-drift)"; tgt="$mut_kit/targetA"
mkblock "$tgt" "pfx-block1.md"
write_targets "$mut_kit" "$tgt"
write_breakthroughs "$mut_kit" "| 1 | tgt | w | \`$tgt/pfx-block1.md:5\` | k |"
mutant="$(mutate_sut "remove-drift-warn" 's/echo "WARN: drift/# DISABLED: echo "WARN: drift/')"
run_mutant "$mut_kit" "$mutant"
if ! grep -qi 'WARN.*drift' <<<"$OUT"; then
  mut_ok "M2 no-drift-warn → case 3 (drift) goes RED" "(WARN absent on mutant)"
else
  mut_no "M2 no-drift-warn → mutation not detected by case 3" "out=[$OUT]"
fi

# M3: Remove the absent-input label → absent corpus output no longer contains 'absent'.
# Mutation: replace "(absent-input)" with "(DISABLED)" so the INFO line loses the 'absent' keyword.
# Case 6 checks grep -qi 'INFO.*absent'; without "absent" in the output it goes RED.
mut_kit="$(mkkit m3-nodist)"; tgt="$mut_kit/targetX"
# tgt not created on disk → triggers absent-input path
write_targets "$mut_kit" "$tgt"
write_breakthroughs "$mut_kit"
mutant="$(mutate_sut "absent-label-removed" 's/(absent-input)/(DISABLED)/')"
run_mutant "$mut_kit" "$mutant"
# Kit name and path contain no 'absent' — only the mutated INFO label carries it.
if ! grep -qi 'INFO.*absent' <<<"$OUT"; then
  mut_ok "M3 absent-label removed → case 6 (absent-input) goes RED" "(absent keyword absent on mutant)"
else
  mut_no "M3 absent-label removed → mutation not detected by case 6" "out=[$OUT]"
fi

# M4: Skip marker check (never grep for Breakthrough) → tagged block reported as untagged.
# A mutant that replaces the marker grep with a false test means no block is ever tagged.
mut_kit="$(mkkit m4-no-marker)"; tgt="$mut_kit/targetA"
mkblock_tagged "$tgt" "pfx-block1.md"
ln=$(tagged_lineno "$tgt/pfx-block1.md")
write_targets "$mut_kit" "$tgt"
write_breakthroughs "$mut_kit" "| 1 | tgt | w | \`$tgt/pfx-block1.md:$ln\` | k |"
# Mutation: replace grep Breakthrough check with 'false' (never matches)
mutant="$(mutate_sut "no-marker-grep" 's/grep -qE.*Breakthrough.*/false/')"
run_mutant "$mut_kit" "$mutant"
# With the mutation, the tagged block is never detected, so: 0 tagged, drift WARN or no-match INFO
if ! grep -q '1 tagged' <<<"$OUT"; then
  mut_ok "M4 no-marker-grep → case 1 (clean) goes RED (0 tagged instead of 1)" "(1 tagged absent on mutant)"
else
  mut_no "M4 no-marker-grep → mutation not detected by case 1" "out=[$OUT]"
fi

# M5: mute the "cannot find TARGETS_MD" echo → case 8 goes RED (no 'cannot find' in output).
# The exit 1 guard remains, so exit code is still 1. But case 8 also asserts that 'cannot find'
# appears in output — without the echo that assertion fails, proving the tooth.
# Note: defense in depth keeps exit 1 via the empty-paths guard even if the explicit check
# were removed — so the tooth must target the message, not just the exit code.
mut_kit="$(mkkit m5-no-targets-echo)"
write_breakthroughs "$mut_kit"
# TARGETS.md absent
mutant="$(mutate_sut "mute-targets-echo" '/sweep-breakthroughs: cannot find.*TARGETS_MD/d')"
run_mutant "$mut_kit" "$mutant"
if ! grep -qi 'cannot find' <<<"$OUT"; then
  mut_ok "M5 muted-TARGETS-echo → case 8 goes RED (no 'cannot find' in output)" "(cannot find absent on mutant)"
else
  mut_no "M5 muted-TARGETS-echo → mutation not detected by case 8" "out=[$OUT]"
fi

total_fail=$(( fail + mut_fail ))
total_pass=$(( pass + mut_pass ))
echo ""
echo "== $total_pass passed · $total_fail failed =="
[ "$total_fail" -eq 0 ] && exit 0 || exit 1
