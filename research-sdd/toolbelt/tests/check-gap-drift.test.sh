#!/usr/bin/env bash
# check-gap-drift.test.sh — harness for check-gap-drift.sh and lib/gap-rows.sh (kit issues #1291, #1294).
#
# The tool compares each `B<n>-G<m>` backlog row against the bullet that defines it in block <n> and
# reports DRIFT? / NO-BULLET / NO-BLOCK / NO-WORDS / UNPARSED, exiting 1 on drift or unparsed rows.
# Cases pin: the drift verdict, every bullet form seen on the real corpus (bracketed ids, parenthesised
# state, colon), the id-prefix hazard (G1 vs G10), the §7 absent / empty / no-match distinction, list
# edges (first / middle / last / single row), CRLF, continuation lines, threshold handling, worktree
# exclusion, and the verify-state.sh WARN integration. --prove-teeth builds mutants of the lib and the
# tool and requires each to flip a specific assertion.
#
# Usage: check-gap-drift.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/check-gap-drift.sh"
VS="$TOOLBELT/verify-state.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# run <args...> : run the SUT, capture stdout+stderr in OUT and the exit code in RC.
run(){ OUT="$(timeout 20 bash "$SUT" "$@" 2>&1)"; RC=$?; }
has(){ grep -qF -- "$1" <<<"$OUT"; }
# expect <label> <rc> <needle>...: exit code and every needle present.
expect(){ local label="$1" want="$2"; shift 2; local miss=""
  [ "$RC" = "$want" ] || miss="rc=$RC(want $want) "
  for n in "$@"; do has "$n" || miss="${miss}[missing: $n] "; done
  if [ -z "$miss" ]; then ok "$label"; else no "$label — $miss| out: $(printf '%s' "$OUT" | tr '\n' '~' | cut -c1-300)"; fi; }
lacks(){ local label="$1"; shift; local hit=""
  for n in "$@"; do has "$n" && hit="${hit}[unexpected: $n] "; done
  if [ -z "$hit" ]; then ok "$label"; else no "$label — $hit"; fi; }

# st <dir> <line...> : RESEARCH-STATE.md fixture ; blk <dir> <name> <line...> : a block file.
st(){ local d="$1"; shift; mkdir -p "$d"; printf '%s\n' "$@" > "$d/RESEARCH-STATE.md"; }
blk(){ local d="$1" f="$2"; shift 2; mkdir -p "$d"; printf '%s\n' "$@" > "$d/$f"; }
row(){ printf '| %s | %s | %s | %s |' "$1" "$2" "evidence/" "$3"; }
HDR1='## Gap-backlog'
HDR2='| Priority | Gap | Artifact | Status |'
HDR3='|---|---|---|---|'

echo "-- check-gap-drift.sh --"

# 1. CLEAN: row text copied from the bullet.
d="$TMP/clean"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B1-G1 Whether the keyring write path validates the signature' pending)"
blk "$d" proj-block1.md '## Child gaps' '- **B1-G1** Whether the keyring write path validates the signature before store.'
run "$d"; expect "1  clean row exits 0 with checked=1 suspects=0" 0 "checked=1 suspects=0"

# 2. DRIFT: row describes a different finding than the bullet.
d="$TMP/drift"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B1-G1 Greenfield module wizard templates' pending)"
blk "$d" proj-block1.md '- **B1-G1** Whether the keyring write path validates the signature before store.'
run "$d"; expect "2  unrelated row text is DRIFT? and exits 1" 1 "DRIFT? B1-G1" "suspects=1"

# 3. Bullet forms: bracketed id, parenthesised state, colon.
d="$TMP/forms"
st "$d" "$HDR1" "$HDR2" "$HDR3" \
  "$(row high 'B2-G1 Read community migration doc pages' pending)" \
  "$(row high 'B2-G2 Build license portal client harness' pending)" \
  "$(row low 'B2-G3 Monitor release notes for the migration guide' pending)"
blk "$d" proj-block2.md '- **[B2-G1]** Read community migration doc pages in full.' \
  '- **B2-G2 (requires-execution, license)** Build license portal client harness for the flow.' \
  '- **B2-G3**: Monitor release notes for the migration guide statement.'
run "$d"; expect "3  bracketed / parenthesised / colon bullets are all FOUND (no NO-BULLET)" 0 "checked=3 suspects=0 no_bullet=0"

# 4. Id-prefix hazard: B4-G1 must not be compared against the B4-G10 bullet.
d="$TMP/prefix"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B4-G1 Alpha handshake timing analysis' pending)"
blk "$d" proj-block4.md '- **B4-G10** Zulu unrelated storage question entirely.' '- **B4-G1** Alpha handshake timing analysis for fox.'
run "$d"; expect "4  G1 matches the G1 bullet, not the earlier G10 bullet" 0 "checked=1 suspects=0"
d="$TMP/prefix2"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B4-G1 Alpha handshake timing analysis' pending)"
blk "$d" proj-block4.md '- **B4-G10** Alpha handshake timing analysis for fox.'
run "$d"; expect "4b G1 with ONLY a G10 bullet is NO-BULLET, never matched to G10" 0 "NO-BULLET B4-G1" "no_bullet=1"

# 5. NO-BULLET / NO-BLOCK are separate typed states, exit 0 when something else was compared.
d="$TMP/nob"
st "$d" "$HDR1" "$HDR2" "$HDR3" \
  "$(row high 'B5-G1 Present clean gap text here' pending)" \
  "$(row high 'B5-G2 Defined only in prose elsewhere' pending)" \
  "$(row high 'B9-G1 Parent block missing entirely' pending)"
blk "$d" proj-block5.md '- **B5-G1** Present clean gap text here for sure.' 'B5-G2 is mentioned only in running prose.'
run "$d"; expect "5  NO-BULLET and NO-BLOCK reported separately, exit 0" 0 "NO-BULLET B5-G2" "NO-BLOCK B9-G1" "checked=1 suspects=0 no_bullet=1 no_block=1"

# 6. UNPARSED: a gap-id row the grammar cannot parse is loud and exits 1.
d="$TMP/unp"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B1-G1 Alpha clean row text' pending)" '| med | B1-G5 invalid priority row | x | pending |'
blk "$d" proj-block1.md '- **B1-G1** Alpha clean row text.'
run "$d"; expect "6  invalid-priority gap row is UNPARSED, exit 1" 1 "UNPARSED" "unparsed=1"

# 7. Absent input: bad target / missing state => exit 2 (never a silent 0).
run "$TMP/does-not-exist"; expect "7a absent target dir exits 2" 2
mkdir -p "$TMP/nostate"; run "$TMP/nostate"; expect "7b target without RESEARCH-STATE.md exits 2" 2 "RESEARCH-STATE"
run; expect "7c no args exits 2 with usage" 2 "usage"
run "$TMP/clean" --threshold abc; expect "7d non-integer threshold exits 2" 2 "threshold"
run "$TMP/clean" --bogus; expect "7e unknown flag exits 2" 2 "usage"
run "$TMP/clean" --state "$TMP/nope.md"; expect "7f --state naming an absent file exits 2" 2 "cannot read"

# 8. Empty vs no-match: no gap-id rows at all is typed n/a; all-covered rows are a different message.
d="$TMP/norows"
st "$d" "$HDR1" "$HDR2" "$HDR3" "| high | plain gap without an id | x | pending |"
run "$d"; expect "8a state with no B<n>-G<m> rows is typed n/a, exit 0" 0 "no B<n>-G<m> backlog rows" "checked=0"
d="$TMP/allclosed"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B1-G1 Greenfield wizard templates' '✅ covered — B7')"
blk "$d" proj-block1.md '- **B1-G1** Whether the keyring write path validates the signature.'
run "$d"; expect "8b only non-pending rows: 'no pending' message, skipped counted, exit 0" 0 "no pending B<n>-G<m> rows" "skipped_nonpending=1" "checked=0"
run "$d" --all; expect "8c --all includes the non-pending drifted row" 1 "DRIFT? B1-G1" "checked=1"

# 9. DEGRADED: pending rows exist but not one could be compared.
d="$TMP/degraded"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B9-G1 Block absent one' pending)" "$(row high 'B9-G2 Block absent two' pending)"
run "$d"; expect "9  every pending row NO-BLOCK => DEGRADED line (a zero that could not look), exit 0" 0 "DEGRADED" "checked=0" "no_block=2"
d="$TMP/notdegraded"
run "$TMP/clean"; lacks "9b a clean compared run carries no DEGRADED line" "DEGRADED"

# 10. List edges: drift FIRST / MIDDLE / LAST / SINGLE.
mkedge(){ local d="$1" p1="$2" p2="$3" p3="$4"
  st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high "B6-G1 $p1" pending)" "$(row high "B6-G2 $p2" pending)" "$(row high "B6-G3 $p3" pending)"
  blk "$d" proj-block6.md '- **B6-G1** Alpha handshake timing analysis.' '- **B6-G2** Bravo certificate chain depth census.' '- **B6-G3** Charlie websocket frame fragmentation audit.'; }
GOOD1='Alpha handshake timing analysis'; GOOD2='Bravo certificate chain depth census'; GOOD3='Charlie websocket frame fragmentation audit'
mkedge "$TMP/e-first" 'Zulu quantum unrelated nonsense' "$GOOD2" "$GOOD3"; run "$TMP/e-first"; expect "10a drift in FIRST row only" 1 "DRIFT? B6-G1" "suspects=1"
mkedge "$TMP/e-mid" "$GOOD1" 'Zulu quantum unrelated nonsense' "$GOOD3"; run "$TMP/e-mid"; expect "10b drift in MIDDLE row only" 1 "DRIFT? B6-G2" "suspects=1"
mkedge "$TMP/e-last" "$GOOD1" "$GOOD2" 'Zulu quantum unrelated nonsense'; run "$TMP/e-last"; expect "10c drift in LAST row only" 1 "DRIFT? B6-G3" "suspects=1"
mkedge "$TMP/e-none" "$GOOD1" "$GOOD2" "$GOOD3"; run "$TMP/e-none"; expect "10d no drift in a 3-row list" 0 "checked=3 suspects=0"
d="$TMP/e-single"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B6-G1 Zulu quantum unrelated nonsense' pending)"
blk "$d" proj-block6.md '- **B6-G1** Alpha handshake timing analysis.'
run "$d"; expect "10e single-row list with drift" 1 "DRIFT? B6-G1" "checked=1 suspects=1"
# last line without a trailing newline must still be read.
d="$TMP/e-nonl"; mkdir -p "$d"
printf '%s\n%s\n%s\n%s' "$HDR1" "$HDR2" "$HDR3" "$(row high 'B6-G1 Zulu quantum unrelated nonsense' pending)" > "$d/RESEARCH-STATE.md"
blk "$d" proj-block6.md '- **B6-G1** Alpha handshake timing analysis.'
run "$d"; expect "10f final row without trailing newline is still checked" 1 "DRIFT? B6-G1"

# 11. CRLF state and block files.
d="$TMP/crlf"; mkdir -p "$d"
printf '%s\r\n%s\r\n%s\r\n%s\r\n' "$HDR1" "$HDR2" "$HDR3" "$(row high 'B6-G1 Alpha handshake timing analysis' pending)" > "$d/RESEARCH-STATE.md"
printf '%s\r\n' '- **B6-G1** Alpha handshake timing analysis.' > "$d/proj-block6.md"
run "$d"; expect "11 CRLF state + block: pending status and bullet still recognised" 0 "checked=1 suspects=0"

# 12. Continuation lines: words found only on a wrapped line count; the 7-line cap bounds the read.
d="$TMP/cont"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B7-G1 Delta keyring rotation semantics' pending)"
blk "$d" proj-block7.md '- **B7-G1** First line has nothing relevant' '  continuation mentions delta keyring rotation semantics here.'
run "$d"; expect "12a words on a continuation line are compared" 0 "checked=1 suspects=0"
d="$TMP/cap"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B7-G1 Delta keyring rotation semantics' pending)"
blk "$d" proj-block7.md '- **B7-G1** First line nothing' '  l1 x' '  l2 x' '  l3 x' '  l4 x' '  l5 x' '  l6 x' '  l7 x' '  l8 delta keyring rotation semantics beyond the cap.'
run "$d"; expect "12b a bullet read stops at 7 continuation lines (word beyond the cap is not seen)" 1 "DRIFT? B7-G1"
d="$TMP/stopnext"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B7-G1 Delta keyring rotation semantics' pending)"
blk "$d" proj-block7.md '- **B7-G1** First line nothing relevant.' '- **B7-G2** delta keyring rotation semantics belongs to the NEXT bullet.'
run "$d"; expect "12c the read stops at the next gap bullet" 1 "DRIFT? B7-G1"
d="$TMP/stopblank"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B7-G1 Delta keyring rotation semantics' pending)"
blk "$d" proj-block7.md '- **B7-G1** First line nothing relevant.' '' 'delta keyring rotation semantics in later prose.'
run "$d"; expect "12d the read stops at a blank line" 1 "DRIFT? B7-G1"
d="$TMP/stophead"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B7-G1 Delta keyring rotation semantics' pending)"
blk "$d" proj-block7.md '- **B7-G1** First line nothing relevant.' '## Next section' 'delta keyring rotation semantics in a heading section.'
run "$d"; expect "12e the read stops at a heading" 1 "DRIFT? B7-G1"

# 13. Threshold: a ~33% overlap row is clean at the default (20) and flagged at 40.
d="$TMP/thr"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B8-G1 alpha bravo charlie' pending)"
blk "$d" proj-block8.md '- **B8-G1** alpha only appears here.'
run "$d"; expect "13a 33% overlap is clean at the default threshold" 0 "suspects=0"
run "$d" --threshold 40; expect "13b the same row is DRIFT? at --threshold 40" 1 "DRIFT? B8-G1" "overlap=33%"
d="$TMP/thr-edge"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B8-G1 alpha bravo charlie delta echo' pending)"
blk "$d" proj-block8.md '- **B8-G1** alpha only appears here.'
run "$d"; expect "13c exactly 20% overlap is NOT below the threshold (boundary)" 0 "suspects=0"
run "$d" --threshold 21; expect "13d 20% overlap IS below 21" 1 "DRIFT? B8-G1"

# 14. A row with no comparable content word is typed NO-WORDS, never drift.
d="$TMP/nowords"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B8-G1 of the to' pending)"
blk "$d" proj-block8.md '- **B8-G1** alpha bravo charlie.'
run "$d"; expect "14 stop-word-only row => NO-WORDS, not DRIFT?, exit 0" 0 "NO-WORDS B8-G1" "no_words=1" "suspects=0"

# 15. Nested git worktrees are not corpus: a block only under .claude/worktrees is NO-BLOCK.
d="$TMP/wt"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B3-G1 Alpha handshake timing' pending)"
blk "$d/.claude/worktrees" proj-block3.md '- **B3-G1** Alpha handshake timing.'
run "$d"; expect "15 a block under .claude/worktrees/ is ignored (NO-BLOCK)" 0 "NO-BLOCK B3-G1"

# 16. --state compares an alternate state file against the target's blocks; 4-col rows work.
d="$TMP/alt"; mkdir -p "$d"
blk "$d" proj-block1.md '- **B1-G1** Alpha handshake timing analysis.'
printf '%s\n' '## Gap-backlog' '| Priority | Gap | Type | Status |' '|---|---|---|---|' '| high | B1-G1 Zulu quantum unrelated nonsense | recon | pending |' > "$d/RESEARCH-STATE-foo.md"
mkdir -p "$d/_x"; printf '%s\n' '# s' > "$d/RESEARCH-STATE.md"
run "$d" --state "$d/RESEARCH-STATE-foo.md"; expect "16 --state + 4-col row: drift found" 1 "DRIFT? B1-G1"

# 17. Text with backslashes / escaped pipes travels intact (ENVIRON, not awk -v).
d="$TMP/bs"
st "$d" "$HDR1" "$HDR2" "$HDR3" '| high | B1-G1 handle C:\temp\new path and a\|b pipe | x | pending |'
blk "$d" proj-block1.md '- **B1-G1** handle C:\temp\new path and a|b pipe cases.'
run "$d"; expect "17 backslashes and an escaped pipe in the row do not corrupt the comparison" 0 "checked=1 suspects=0"

# 18. Closed-class / history rows (em-dash, strikethrough, numeric first cell) carry a gap id but are NOT
#     backlog rows to compare: out of scope and counted, never UNPARSED (found by the fleet sweep:
#     niagara-research has ~50 such rows).
d="$TMP/closedclass"
st "$d" "$HDR1" "$HDR2" "$HDR3" \
  '| — | B1-G1 closed em-dash row | x | ✅ covered |' \
  '| ~~low~~ | B1-G2 struck-through row | x | ✅ covered |' \
  '| 17 | B1-G3 iteration history row | x | CER |' \
  "$(row high 'B1-G4 Alpha handshake timing analysis' pending)"
blk "$d" proj-block1.md '- **B1-G4** Alpha handshake timing analysis.'
run "$d"; expect "18 em-dash / strikethrough / numeric-first-cell gap rows are skipped_closed=3, unparsed=0" 0 "unparsed=0" "skipped_closed=3" "checked=1 suspects=0"
lacks "18b no UNPARSED line for closed-class rows" "UNPARSED"

# 19. Plural/singular inflection must not read as drift (found by the fleet sweep: B1009-G3 'months' vs 'month').
d="$TMP/stem"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B8-G1 months ordinals zulu yankee' pending)"
blk "$d" proj-block8.md '- **B8-G1** month ordinal mapping only.'
run "$d"; expect "19 'months ordinals' vs 'month ordinal' share words (trailing-s stemmed): 50%, clean" 0 "checked=1 suspects=0"
d="$TMP/stem-ss"
st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high 'B8-G1 class access zulu yankee' pending)"
blk "$d" proj-block8.md '- **B8-G1** clas acces mapping only.'
run "$d"; expect "19b a double-s ending is NOT stemmed ('class' != 'clas')" 1 "DRIFT? B8-G1"

# 20. A PENDING row is never silently skipped because of its first cell: numeric / em-dash / ~~struck~~
#     priority cells on a pending row are compared (drift flagged) at FIRST, LAST and SINGLE positions.
GOODP='Alpha handshake timing analysis'; BADP='Totally unrelated question about gizmos widgets'
for pc in '1' '—' '~~low~~'; do
  tag="$(printf '%s' "$pc" | tr -c 'A-Za-z0-9' 'x')"
  d="$TMP/pend1-$tag"
  st "$d" "$HDR1" "$HDR2" "$HDR3" "| $pc | B5-G1 $BADP | x | pending |" "$(row high "B5-G2 $GOODP" pending)"
  blk "$d" proj-block5.md "- **B5-G1** $GOODP." "- **B5-G2** $GOODP."
  run "$d"; expect "20a pending row with first cell '$pc' (FIRST position) is compared: DRIFT?" 1 "DRIFT? B5-G1" "skipped_closed=0"
  d="$TMP/pendL-$tag"
  st "$d" "$HDR1" "$HDR2" "$HDR3" "$(row high "B5-G2 $GOODP" pending)" "| $pc | B5-G1 $BADP | x | pending |"
  blk "$d" proj-block5.md "- **B5-G1** $GOODP." "- **B5-G2** $GOODP."
  run "$d"; expect "20b pending row with first cell '$pc' (LAST position) is compared: DRIFT?" 1 "DRIFT? B5-G1"
  d="$TMP/pendS-$tag"
  st "$d" "$HDR1" "$HDR2" "$HDR3" "| $pc | B5-G1 $BADP | x | pending |"
  blk "$d" proj-block5.md "- **B5-G1** $GOODP."
  run "$d"; expect "20c pending row with first cell '$pc' (SINGLE row) is compared: DRIFT?" 1 "DRIFT? B5-G1" "checked=1 suspects=1"
done
d="$TMP/pend-ok"
st "$d" "$HDR1" "$HDR2" "$HDR3" "| 1 | B5-G1 $GOODP | x | pending |"
blk "$d" proj-block5.md "- **B5-G1** $GOODP."
run "$d"; expect "20d a faithful pending row with a numeric first cell is checked and clean" 0 "checked=1 suspects=0" "skipped_closed=0"
d="$TMP/pend-short"
st "$d" "$HDR1" "$HDR2" "$HDR3" "| — | B5-G1 $BADP | pending |"
blk "$d" proj-block5.md "- **B5-G1** $GOODP."
run "$d"; expect "20e pending row with a marker first cell but too few cells is UNPARSED, not skipped" 1 "UNPARSED" "unparsed=1"

# 21. Operational failures exit 2 (1 is reserved for findings); a flag with a missing value cannot hang.
run "$TMP/clean" --threshold; expect "21a --threshold with no value exits 2 (no hang)" 2 "usage"
run "$TMP/clean" --state; expect "21b --state with no value exits 2 (no hang)" 2 "usage"
mkdir -p "$TMP/nolib/lib"; cp "$SUT" "$TMP/nolib/"; cp "$TOOLBELT/lib/block-files.sh" "$TMP/nolib/lib/"
OUT="$(timeout 20 bash "$TMP/nolib/check-gap-drift.sh" "$TMP/clean" 2>&1)"; RC=$?
expect "21c missing lib/gap-rows.sh exits 2 (never 1, which means findings)" 2 "gap-rows.sh"
mkdir -p "$TMP/nolib2/lib"; cp "$SUT" "$TMP/nolib2/"; cp "$TOOLBELT/lib/gap-rows.sh" "$TMP/nolib2/lib/"
OUT="$(timeout 20 bash "$TMP/nolib2/check-gap-drift.sh" "$TMP/clean" 2>&1)"; RC=$?
expect "21d missing lib/block-files.sh exits 2" 2 "block-files.sh"
mkdir -p "$TMP/badlib/lib"; cp "$SUT" "$TMP/badlib/"; cp "$TOOLBELT/lib/block-files.sh" "$TMP/badlib/lib/"; : > "$TMP/badlib/lib/gap-rows.sh"
OUT="$(timeout 20 bash "$TMP/badlib/check-gap-drift.sh" "$TMP/clean" 2>&1)"; RC=$?
expect "21e lib that fails to define its function exits 2" 2 "failed to define"

# --- lib unit checks ---
echo "-- lib/gap-rows.sh --"
# shellcheck source=lib/gap-rows.sh
. "$TOOLBELT/lib/gap-rows.sh"
declare -F gap_overlap >/dev/null 2>&1 || no "L0 lib did not define gap_overlap"
r="$(gap_overlap 'alpha bravo alpha' 'alpha charlie')"
[ "$r" = "1 2" ] && ok "L1 overlap de-duplicates row words (shared=1 total=2)" || no "L1 overlap got [$r] want [1 2]"
r="$(gap_overlap 'months ordinals' 'month ordinal')"
[ "$r" = "2 2" ] && ok "L3 trailing-s inflection is stemmed (shared=2 total=2)" || no "L3 got [$r] want [2 2]"
r="$(gap_overlap 'the of to' 'anything')"
[ "$r" = "0 0" ] && ok "L2 stop-word-only row has total 0" || no "L2 got [$r] want [0 0]"

# --- verify-state.sh integration (WARN only) ---
echo "-- verify-state.sh integration --"
vs(){ OUT="$(bash "$VS" "$@" 2>&1)"; RC=$?; }
mkvs(){ local d="$1" gap="$2"; mkdir -p "$d"
  { printf '%s\n' '# S' '<!-- research-state.v1 -->' 'schema: research-state.v1' 'covered_blocks: 1' 'gaps_closed: 0' 'known_gaps: 1' 'investigable_open: 1' 'requires_execution_open: 0' 'blocked_open: 0' 'deferred_open: 0' '<!-- /research-state.v1 -->'
    printf '%s\n' "$HDR1" "$HDR2" "$HDR3" "$(row high "B1-G1 $gap" pending)"; } > "$d/RESEARCH-STATE.md"
  printf '%s\n' '- **B1-G1** Alpha handshake timing analysis.' > "$d/proj-block1.md"; }
mkvs "$TMP/vs-clean" 'Alpha handshake timing analysis'
vs "$TMP/vs-clean"; lacks "V1 clean gap rows add no gap-drift output to verify-state" "gap-drift" "DRIFT?"
mkvs "$TMP/vs-drift" 'Zulu quantum unrelated nonsense'
vs "$TMP/vs-drift"
if has "WARN" && has "gap-drift" && has "B1-G1"; then ok "V2 drifted row => verify-state WARN naming the gap id"; else no "V2 no gap-drift WARN — $(printf '%s' "$OUT" | tr '\n' '~' | cut -c1-300)"; fi
vsrc_drift=$RC
vs "$TMP/vs-clean"; vsrc_clean=$RC
[ "$vsrc_drift" = "$vsrc_clean" ] && ok "V3 the drift WARN does not change verify-state's exit code (WARN-only)" || no "V3 exit code changed: drift=$vsrc_drift clean=$vsrc_clean"
# degraded: checker missing beside a copy of verify-state, state HAS gap rows => typed degraded WARN.
mkdir -p "$TMP/vscopy/lib"
cp "$VS" "$TMP/vscopy/verify-state.sh"
cp "$TOOLBELT/lib/focus-prefix.sh" "$TOOLBELT/lib/block-files.sh" "$TMP/vscopy/lib/"
OUT="$(bash "$TMP/vscopy/verify-state.sh" "$TMP/vs-drift" 2>&1)"; RC=$?
if grep -qF 'check-gap-drift.sh not found' <<<"$OUT"; then ok "V4 checker absent + gap rows present => typed degraded WARN (never silent)"; else no "V4 missing checker not reported"; fi
mkdir -p "$TMP/vscopy3/lib"; cp "$VS" "$TMP/vscopy3/verify-state.sh"; cp "$SUT" "$TMP/vscopy3/"
cp "$TOOLBELT/lib/focus-prefix.sh" "$TOOLBELT/lib/block-files.sh" "$TMP/vscopy3/lib/"
OUT="$(bash "$TMP/vscopy3/verify-state.sh" "$TMP/vs-drift" 2>&1)"
if grep -qF 'gap-drift: degraded' <<<"$OUT"; then ok "V7 checker present but its helper lib is missing => typed degraded WARN (not silence)"; else no "V7 broken checker produced no gap-drift line — $(printf '%s' "$OUT" | grep -a gap-drift | head -1)"; fi
mkdir -p "$TMP/vscopy4/lib"; cp "$VS" "$TMP/vscopy4/verify-state.sh"; cp "$TOOLBELT/lib/focus-prefix.sh" "$TOOLBELT/lib/block-files.sh" "$TMP/vscopy4/lib/"
printf '#!/usr/bin/env bash\necho oops >&2\nexit 1\n' > "$TMP/vscopy4/check-gap-drift.sh"
OUT="$(bash "$TMP/vscopy4/verify-state.sh" "$TMP/vs-drift" 2>&1)"
if grep -qF 'check-gap-drift.sh failed (exit 1)' <<<"$OUT"; then ok "V8 checker exit 1 with NO typed finding line => degraded WARN (1 is reserved for findings)"; else no "V8 untyped exit 1 not reported"; fi
mkdir -p "$TMP/vs-norows"; { printf '%s\n' '# S' '<!-- research-state.v1 -->' 'schema: research-state.v1' 'covered_blocks: 0' 'gaps_closed: 0' 'known_gaps: 1' 'investigable_open: 1' 'requires_execution_open: 0' 'blocked_open: 0' 'deferred_open: 0' '<!-- /research-state.v1 -->' "$HDR1" "$HDR2" "$HDR3" '| high | plain gap | x | pending |'; } > "$TMP/vs-norows/RESEARCH-STATE.md"
OUT="$(bash "$TMP/vscopy/verify-state.sh" "$TMP/vs-norows" 2>&1)"
lacks "V5 checker absent but NO gap rows => no degraded noise" "check-gap-drift.sh not found"
mkdir -p "$TMP/vscopy2/lib"; cp "$VS" "$TMP/vscopy2/verify-state.sh"; cp "$TOOLBELT/lib/focus-prefix.sh" "$TOOLBELT/lib/block-files.sh" "$TMP/vscopy2/lib/"
printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$TMP/vscopy2/check-gap-drift.sh"
OUT="$(bash "$TMP/vscopy2/verify-state.sh" "$TMP/vs-drift" 2>&1)"
if grep -qF 'check-gap-drift.sh failed (exit 2)' <<<"$OUT"; then ok "V6 checker exits 2 => typed degraded WARN naming the failure"; else no "V6 checker failure not reported"; fi

# --- mutation controls ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: check-gap-drift / gap-rows / verify-state mutants --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mk_tree(){ local d="$TMP/mut-$1"; mkdir -p "$d/lib"
    cp "$TOOLBELT/check-gap-drift.sh" "$TOOLBELT/verify-state.sh" "$d/"
    cp "$TOOLBELT/lib/gap-rows.sh" "$TOOLBELT/lib/block-files.sh" "$TOOLBELT/lib/focus-prefix.sh" "$d/lib/"; printf '%s' "$d"; }
  # tooth <name> <file> <sed-expr> <fixture> <rc GOOD gives> <needle GOOD prints> [tool args...]
  # The mutant must change the exit code or lose the needle; either proves the assertion bites.
  tooth(){ local name="$1" file="$2" expr="$3" fx="$4" grc="$5" needle="$6"; shift 6
    local d mo mrc kept=lost; d="$(mk_tree "$name")"
    if ! mutant_sed "$TOOLBELT/$file" "$d/$file" "$expr" 2>/dev/null; then
      no "teeth $name: could not build mutant (pattern absent / refused by lib/mutant.sh)"; return; fi
    mo="$(timeout 10 bash "$d/check-gap-drift.sh" "$fx" "$@" 2>&1)"; mrc=$?
    grep -qF -- "$needle" <<<"$mo" && kept=kept
    if [ "$mrc" != "$grc" ] || [ "$kept" = lost ]; then ok "teeth $name: mutant flips the assertion (rc=$mrc, needle $kept)"
    else no "teeth $name: mutant still satisfies the assertion — THEATER"; fi; }
  # vtooth <name> <sed-expr> <fixture> <verify-state dir kind: full|nochk> <needle> <present|absent>
  # present = GOOD prints the needle, the mutant must lose it; absent = GOOD lacks it, the mutant must print it.
  vtooth(){ local name="$1" expr="$2" fx="$3" kind="$4" needle="$5" mode="$6" d mo
    d="$(mk_tree "$name")"
    if ! mutant_sed "$TOOLBELT/verify-state.sh" "$d/verify-state.sh" "$expr" 2>/dev/null; then
      no "teeth $name: could not build verify-state mutant"; return; fi
    [ "$kind" = nochk ] && rm -f "$d/check-gap-drift.sh"
    if [ "$kind" = stub ]; then printf '#!/usr/bin/env bash\necho boom >&2\nexit 2\n' > "$d/check-gap-drift.sh"; fi
    if [ "$kind" = stub1 ]; then printf '#!/usr/bin/env bash\necho oops >&2\nexit 1\n' > "$d/check-gap-drift.sh"; fi
    if [ "$kind" = nolib ]; then rm -f "$d/lib/gap-rows.sh"; fi
    mo="$(bash "$d/verify-state.sh" "$fx" 2>&1)"
    if [ "$mode" = present ]; then
      grep -qF -- "$needle" <<<"$mo" && no "teeth $name: mutant still prints [$needle] — THEATER" || ok "teeth $name: mutant loses [$needle]"
    else
      grep -qF -- "$needle" <<<"$mo" && ok "teeth $name: mutant now prints [$needle]" || no "teeth $name: mutant still silent — THEATER"
    fi; }

  tooth bracket-form    lib/gap-rows.sh 's#\\\[?/,"",s)#/,"",s)#' "$TMP/forms" 0 "no_bullet=0"
  tooth id-digit-guard  lib/gap-rows.sh 's#substr(s,length(gid)+1,1) !~ /[[]0-9[]]/#1#' "$TMP/prefix" 0 "checked=1 suspects=0"
  tooth unparsed-grammar lib/gap-rows.sh '/printf "UNPARSED/s/if (n<4 .*) { printf "UNPARSED/if (0) { printf "UNPARSED/' "$TMP/unp" 1 "unparsed=1"
  tooth continuation-cap lib/gap-rows.sh 's/if (cont>=7) exit/if (0) exit/' "$TMP/cap" 1 "DRIFT? B7-G1"
  tooth stop-next-bullet lib/gap-rows.sh 's@if (line ~ [^|]* || line ~ /^#/@if (0 || line ~ /^#/@' "$TMP/stopnext" 1 "DRIFT? B7-G1"
  tooth stop-blank-line lib/gap-rows.sh 's# || line !~ /\[^ \\t]/##' "$TMP/stopblank" 1 "DRIFT? B7-G1"
  tooth stop-heading    lib/gap-rows.sh 's@ || line ~ /^#/@@' "$TMP/stophead" 1 "DRIFT? B7-G1"
  tooth stemming        lib/gap-rows.sh 's/if (length(w)>3 \&\& w ~ \/\[^s\]s$\/) w=substr(w,1,length(w)-1)/ /' "$TMP/stem" 0 "checked=1 suspects=0"
  tooth closed-class-skip lib/gap-rows.sh '/printf "SKIPPED/s/if (pr ~ [^{]*{/if (0) {/' "$TMP/closedclass" 0 "skipped_closed=3"
  tooth threshold-boundary check-gap-drift.sh 's/\[ \$((shared\*100)) -lt/[ $((shared*100)) -le/' "$TMP/thr-edge" 0 "suspects=0"
  tooth exit-on-drift   check-gap-drift.sh 's/^\[ "\$suspects" -eq 0 \] && \[ "\$unparsed" -eq 0 \]$/true/' "$TMP/drift" 1 "DRIFT? B1-G1"
  tooth no-words-state  check-gap-drift.sh 's/if \[ "\${total:-0}" -eq 0 \]/if [ "${total:-0}" -eq 99999 ]/' "$TMP/nowords" 0 "NO-WORDS B8-G1"
  tooth degraded-line   check-gap-drift.sh 's/^elif \[ "\$checked" -eq 0 \] && \[ \$((rows-skipped)) -gt 0 \]; then/elif false; then/' "$TMP/degraded" 0 "DEGRADED"
  tooth pending-filter  check-gap-drift.sh 's/if \[ "\$all" -eq 0 \] && \[ "\$pend" != "pending" \]/if false/' "$TMP/allclosed" 0 "no pending B<n>-G<m> rows"
  tooth worktree-prune  check-gap-drift.sh 's# \\( -path "$target/.claude/worktrees" -o -name .git \\) -prune -o##' "$TMP/wt" 0 "NO-BLOCK B3-G1"
  tooth threshold-range check-gap-drift.sh 's/\[ "\$threshold" -le 100 \]/true/' "$TMP/clean" 2 "threshold" --threshold 101
  vtooth vs-warn-lines  's@DRIFT\\?\*|UNPARSED\*) _gd_typed@DRIFT_NEVER*) _gd_typed@' "$TMP/vs-drift" full "gap-drift: DRIFT?" present
  vtooth vs-missing-checker 's/if \[ ! -f "\$_gd" \]; then/if false; then/' "$TMP/vs-drift" nochk "check-gap-drift.sh not found" present
  vtooth vs-failed-checker '/GAP-DRIFT-BROKEN/s/\[ "\$_gd_rc" -ge 2 \] || //' "$TMP/vs-drift" stub "check-gap-drift.sh failed (exit 2)" present
  vtooth vs-untyped-exit1 '/GAP-DRIFT-BROKEN/s/ || { \[ "\$_gd_rc" -eq 1 \] && \[ "\$_gd_typed" -eq 0 \]; }//' "$TMP/vs-drift" stub1 "check-gap-drift.sh failed (exit 1)" present
  vtooth vs-missing-helper '/GAP-DRIFT-BROKEN/s/\[ "\$_gd_rc" -ge 2 \] || //' "$TMP/vs-drift" nolib "gap-drift: degraded" present
  tooth pending-marker-row lib/gap-rows.sh 's/if (pr ~ \/^(—|~~|\[0-9\]+\$)\/ \&\& tolower(a\[n\]) !~ \/^pending\/)/if (pr ~ \/^(—|~~|[0-9]+$)\/)/' "$TMP/pendS-1" 1 "DRIFT? B5-G1"
  tooth helper-exit-code check-gap-drift.sh 's/failed to define gap_rows_parse" >&2; exit 2/failed to define gap_rows_parse" >\&2; exit 1/' "$TMP/badlib" 2 "failed to define"
  tooth flag-missing-value check-gap-drift.sh 's/\[ "\$#" -ge 2 \] || { _usage; exit 2; }/true/' "$TMP/clean" 2 "usage" --state
  vtooth vs-rows-guard  '/GAP-DRIFT-ROWS-PRESENT/s/if grep -qE .* 2>\/dev\/null; then/if true; then/' "$TMP/vs-norows" nochk "check-gap-drift.sh not found" absent
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
