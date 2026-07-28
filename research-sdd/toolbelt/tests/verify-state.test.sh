#!/usr/bin/env bash
# verify-state.test.sh — RED-FIRST harness for verify-state.sh's living-mirror consistency lint.
#
# WHY THIS SHAPE (anti-"test theater"): the load-bearing behaviour is CHECK 1 — the stale-mirror
# FAIL that fires ONLY when the coverage metric reads "X / X" (all gaps claimed closed) AND the
# backlog still lists `pending` gaps. That exact desync (summary said 23/23 closed while gaps were
# still pending) is what let the pruebas-dashboards run-A emit a PREMATURE STOP. The discriminating
# cases feed a KNOWN-STALE state file and assert the linter CATCHES it (exit 1); the boundary cases
# (X != Y, or no metric) assert CHECK 1 stays SILENT so the check is provably gated on X==Y, not on
# "pending exists". --prove-teeth neuters CHECK 1 and asserts the stale fixture stops exiting 1,
# proving case STALE is genuinely load-bearing and not theater.
#
# Usage: verify-state.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-state.sh"
FPLIB="$HERE/../lib/focus-prefix.sh"
[ -f "$SUT" ]   || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$FPLIB" ] || { echo "FATAL: helper not found: $FPLIB" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# run <dir> : run the SUT on a target dir, capture stdout (SUT emits a benign
# "integer expression expected" stderr line on the zero-pending grep -c quirk — drop stderr).
run(){ bash "$SUT" "$1" 2>/dev/null; }
# code <dir> : run the SUT and echo only its exit code.
code(){ bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }
# state <dir> <line...> : create <dir> and drop a RESEARCH-STATE.md with the given lines.
state(){ local d="$1"; shift; mkdir -p "$d"; printf '%s\n' "$@" > "$d/RESEARCH-STATE.md"; }
# addenv <dir> <covered> <gaps_closed> <known_gaps> <investigable_open> <requires_exec_open> <blocked_open>
#   Append a research-state.v1 envelope to the fixture's RESEARCH-STATE.md. Since the missing-envelope gate
#   is now a hard FAIL, a fixture that exercises CHECK 1/2/3 (prose) must carry a DERIVED-CONSISTENT
#   envelope, else it fails on the gate instead of the check under test. The values passed here are the
#   fixture's ground truth (0 block files / 0 table rows / 0 blocked entries unless the fixture adds them).
addenv(){ local d="$1"; shift
  { printf '<!-- research-state.v1 -->\n'; printf 'schema: research-state.v1\n'
    printf 'covered_blocks: %s\n' "$1"; printf 'gaps_closed: %s\n' "$2"; printf 'known_gaps: %s\n' "$3"
    printf 'investigable_open: %s\n' "$4"; printf 'requires_execution_open: %s\n' "$5"; printf 'blocked_open: %s\n' "$6"
    printf '<!-- /research-state.v1 -->\n'; } >> "$d/RESEARCH-STATE.md"; }
# env_lines <covered> <gaps_closed> <known_gaps> <investigable_open> <requires_exec_open> <blocked_open>
#   Emit the 8 envelope lines to stdout (for fixtures built with raw printf blocks, not state()).
env_lines(){ printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: %s\ngaps_closed: %s\nknown_gaps: %s\ninvestigable_open: %s\nrequires_execution_open: %s\nblocked_open: %s\n<!-- /research-state.v1 -->\n' "$@"; }
# tablestate <dir> <cx> <cy> <n-pending> — a TABLE-backed state (the REAL backlog shape): prose coverage
#   metric "cx / cy" + <n-pending> leading-token `pending` rows in a 4-col Gap-backlog table. Now that
#   CHECK 1 counts backlog ROWS (not every prose occurrence of the word "pending"), the stale-mirror
#   fixtures must carry real backlog rows, not bullets. The envelope is built so ONLY CHECK 1 can fire
#   (investigable_open == the pending rows; gaps_closed=0 != known_gaps so CHECK D stays silent;
#   covered/blocked = 0), isolating the stale-mirror check for the STALE fixtures and the teeth mutant.
tablestate(){
  local dir="$1" cx="$2" cy="$3" n="$4" i; mkdir -p "$dir"
  { echo '# Research State'; echo
    env_lines 0 0 "$cy" "$n" 0 0; echo
    echo "coverage metric: $cx / $cy declared gaps closed"; echo
    echo '## Gap-backlog (prioritized)'; echo
    echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
    for ((i=1;i<=n;i++)); do echo "| high | gap $i | web | pending |"; done; echo
    echo '## Blocked gaps'; echo '- none'; echo
    echo '## Stop control'; echo "- **Open gaps — read-only investigable**: $n"
  } > "$dir/RESEARCH-STATE.md"
}

echo "== verify-state.test.sh (SUT: $(basename "$SUT")) =="

# 1 — no arg / arg is not a directory → exit 2 (bad args).
if [ "$(code "")" = 2 ]; then ok "no/empty arg → exit 2"; else no "empty arg: got $(code '') (want 2)"; fi
if [ "$(code "$TMP/does-not-exist")" = 2 ]; then ok "non-directory arg → exit 2"; else no "non-dir arg: got $(code "$TMP/does-not-exist") (want 2)"; fi

# 2 — target dir with NO RESEARCH-STATE*.md → exit 2 (no state file).
d="$TMP/nostate"; mkdir -p "$d"
if [ "$(code "$d")" = 2 ]; then ok "dir with no RESEARCH-STATE*.md → exit 2"; else no "no-state: got $(code "$d") (want 2)"; fi

# 3 — CONSISTENT: metric 5 / 5, zero pending gaps → exit 0, prints the ok line.
d="$TMP/consistent"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' '## Backlog' '- gap 1 closed' '- gap 2 closed'
addenv "$d" 0 5 5 0 0 0
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "consistent 5/5 · zero pending → exit 0 + ok line"
else no "consistent: exit $(code "$d") :: $(grep -iE 'ok|fail' <<<"$out" | head -1)"; fi

# 4 — STALE MIRROR (the core FAIL): metric 23 / 23 WITH pending gap rows → exit 1 + PREMATURE STOP line.
#     Mirrors the real pruebas-dashboards run-A desync (summary 23/23 closed while gaps pending).
d="$TMP/stale"
tablestate "$d" 23 23 3   # metric 23/23 (all closed) WITH 3 leading-token `pending` backlog ROWS → CHECK 1 fires
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL' <<<"$out" && grep -q 'PREMATURE STOP' <<<"$out"; then
  ok "STALE 23/23 + pending → exit 1 + FAIL/PREMATURE STOP"
else no "stale: exit $(code "$d") :: $(grep -iE 'fail|premature' <<<"$out" | head -1)"; fi

# 4b — FALSE-POSITIVE GUARD (retro delta): the ordinary word "pending" in PROSE (iteration-history
#      narratives, coverage notes) must NOT count as a backlog gap. Metric 5 / 5 (all closed) + ZERO
#      leading-token `pending` backlog rows, yet three prose occurrences of "pending" → CHECK 1 must stay
#      SILENT (exit 0). RED before the fix: CHECK 1's whole-file `grep -icE '\bpending\b'` counted the prose
#      words, fired the stale-mirror FAIL, and forced editing HISTORY to please the linter — exactly backwards.
d="$TMP/pending-prose-fp"; mkdir -p "$d"
{ echo '# Research State'; echo
  env_lines 0 5 5 0 0 0; echo
  echo 'coverage metric: 5 / 5 declared gaps closed'; echo
  echo 'Note: build+validation was pending in an earlier run; [INFER] pending re-test until the in-skill check.'; echo
  echo '## Gap-backlog (prioritized)'; echo
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | the one gap | web | ✅ closed |'; echo
  echo '## Iteration history'; echo
  echo '| # | Date | Gap | Note |'; echo '|---|---|---|---|'
  echo '| 1 | d1 | g1 | build+validation pending at the time; later closed |'; echo
  echo '## Blocked gaps'; echo '- none'; echo
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -q 'PREMATURE STOP' <<<"$out"; then
  ok "prose 'pending' (not a backlog status) → CHECK 1 silent, exit 0 (no false stale-mirror FAIL)"
else no "pending-prose-fp: exit $(code "$d") :: $(grep -iE 'premature|fail' <<<"$out" | head -1)"; fi

# 5 — NON-EQUAL metric guard: metric 3 / 5 WITH pending gaps → exit 0 (CHECK 1 must NOT fire when X != Y).
#     Key boundary: proves the FAIL is gated on X==Y, not merely on "pending exists".
d="$TMP/unequal"
tablestate "$d" 3 5 2   # 2 real leading-token `pending` backlog rows, but metric 3/5 (X != Y) → CHECK 1 silent
if [ "$(code "$d")" = 0 ]; then ok "3/5 + pending → exit 0 (CHECK 1 gated on X==Y, stays silent)"
else no "unequal-metric: exit $(code "$d") (want 0 — CHECK 1 wrongly fired on X!=Y)"; fi

# 6 — NO parseable metric line at all → exit 0 (cx/cy empty → CHECK 1 cannot fire even with pending).
d="$TMP/nometric"
state "$d" '# Research State' 'No coverage line here at all.' '## Backlog' '- gap A pending'
addenv "$d" 0 0 0 0 0 0
if [ "$(code "$d")" = 0 ]; then ok "no metric line + pending → exit 0 (empty cx/cy → CHECK 1 inert)"
else no "no-metric: exit $(code "$d") (want 0)"; fi

# 7 — CHECK 2 WARN: 'Covered blocks: 21' claim vs a different on-disk *block*.md count → WARN printed,
#     but exit code UNAFFECTED (still 0 because CHECK 1 does not fire — metric equal, zero pending).
d="$TMP/warn"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 21' '## Backlog' '- gap done'
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"
addenv "$d" 2 5 5 0 0 0   # envelope covered_blocks=2 matches on-disk; the prose 'Covered blocks: 21' still trips CHECK 2 WARN
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'WARN.*disagrees with 2 block file' <<<"$out"; then
  ok "CHECK 2: claim 21 vs 2 on-disk → WARN printed, exit still 0"
else no "warn: exit $(code "$d") :: $(grep -iE 'warn' <<<"$out" | head -1)"; fi

# 8 — NESTED state: RESEARCH-STATE.md under a corpus/ subdir (within maxdepth 3) is found and linted.
#     Reuse the stale desync so we can assert the nested file is genuinely parsed (exit 1, not skipped).
d="$TMP/nested"; mkdir -p "$d/corpus"
tablestate "$d/corpus" 23 23 1   # nested table-backed stale focus (metric 23/23 + 1 pending row)
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -q 'PREMATURE STOP' <<<"$out"; then
  ok "nested corpus/RESEARCH-STATE.md found + linted (stale caught, exit 1)"
else no "nested: exit $(code "$d") :: $(grep -iE 'no research-state|premature' <<<"$out" | head -1)"; fi

# 9 — CHECK 2 quiet: covered-blocks claim MATCHES the on-disk count → NO warn (and exit 0).
d="$TMP/nowarn"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 2' '## Backlog' '- gap done'
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"
addenv "$d" 2 5 5 0 0 0
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'WARN' <<<"$out"; then
  ok "CHECK 2: claim 2 == 2 on-disk → no WARN, exit 0"
else no "no-warn: exit $(code "$d") :: $(grep -iE 'warn' <<<"$out" | head -1)"; fi

# 10 — CHECK 2 on-disk guard: 'Covered blocks: 5' claim but ZERO *block*.md on disk → NO warn (exit 0).
#      Pins the `[ "${ondisk:-0}" -gt 0 ]` guard at verify-state.sh:49 — CHECK 2 is SUPPRESSED when nothing
#      is on disk (you cannot 'disagree' with an empty glob). Load-bearing: flip the guard to `-ge 0` in a
#      mutant and the WARN WOULD fire (5 != 0), so this "no WARN" assertion pins that guard. See --prove-teeth.
d="$TMP/warn-zero-ondisk"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 5' '## Backlog' '- gap done'
# NOTE: no *block*.md files created → ondisk == 0.
addenv "$d" 0 5 5 0 0 0   # envelope covered_blocks=0 matches ondisk=0; prose 'Covered blocks: 5' is CHECK 2's -gt 0 guard case
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'WARN' <<<"$out"; then
  ok "CHECK 2: claim 5 vs 0 on-disk → guard -gt 0 suppresses WARN, exit 0"
else no "warn-zero-ondisk: exit $(code "$d") :: $(grep -iE 'warn' <<<"$out" | head -1)"; fi

# 11 — CHECK 2 empty-claim guard IN ISOLATION: NO 'Covered blocks' line, but block files DO exist on disk
#      (ondisk > 0). CHECK 2 stays silent specifically because `covered_claim` is empty (the
#      `-n "${covered_claim:-}"` guard), independent of the on-disk count. Earlier cases always had
#      ondisk==0 too, so only this fixture (ondisk>0) isolates the empty-claim guard.
d="$TMP/nocovered-ondisk"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' '## Backlog' '- gap done'
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"   # ondisk == 2, but no covered-blocks claim
addenv "$d" 2 5 5 0 0 0
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'WARN' <<<"$out"; then
  ok "CHECK 2: no covered-blocks line + 2 on-disk → empty-claim guard keeps it silent, exit 0"
else no "nocovered-ondisk: exit $(code "$d") :: $(grep -iE 'warn' <<<"$out" | head -1)"; fi

# 12 — STRICT block discriminator (gen-catalog.py BLOCK_RE): a block file is `<prefix>-(block|bloque)<N>[-suffix].md`,
#      matched case-INSENSITIVELY. This is the SINGLE definition shared by verify-state / --sync-state / archive /
#      catalog — a loose `*block*` glob is what let decoys like `blocked-notes.md` inflate the count and fork the
#      authority. Fixture pins: Spanish `-bloque`, mixed case, English `-block`, and a both-tokens name — each
#      PREFIXED (the real corpus names blocks `sdd-mental-model-bloque1.md`), 4 DISTINCT files → "4 block file(s)".
#      Bare `bloqueNN.md` (no prefix) is deliberately NOT a block here: gen-catalog does not catalog it either.
d="$TMP/bloque-glob"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 21' '## Backlog' '- gap done'
printf 'x\n' > "$d/niagara-bloque125.md"       # Spanish, lowercase, prefixed
printf 'x\n' > "$d/niagara-bloque126.md"       # Spanish — keyword is lowercase (discriminator is case-sensitive)
printf 'x\n' > "$d/niagara-block99.md"         # English — `-block<N>` (no dash before the number)
printf 'x\n' > "$d/niagara-block-bloque1.md"   # both tokens present — the single grep counts it exactly ONCE
printf 'x\n' > "$d/blocked-notes.md"           # DECOY — old loose glob wrongly counted it; strict must NOT
addenv "$d" 4 5 5 0 0 0
out="$(run "$d")"
if grep -qE '4 block file\(s\) on disk' <<<"$out"; then
  ok "STRICT: prefixed -block/-bloque counted (4), bare/decoy 'blocked-notes.md' excluded → '4 block file(s)'"
else no "bloque-glob: on-disk count :: $(grep -iE 'block file' <<<"$out" | head -1)"; fi

# 13 — BUG 2 (only the FIRST state file is linted): a corpus with several RESEARCH-STATE-*.md (niagara
#      keeps ~12, one per focus) must lint EVERY one, not just `head -1`. Fixture: two consistent
#      focuses + one STALE focus (23/23 while gaps pending). The old `head -1` linted a single file,
#      printing ONE header and silently skipping the other focuses. Assert ALL THREE basenames appear
#      (every file linted) AND exit 1 (the stale focus is caught). The all-headers check is
#      order-independent, so this stays deterministic regardless of find's traversal order.
d="$TMP/multistate"; mkdir -p "$d"
printf '%s\n' '# Research State' 'coverage metric: 5 / 5 gaps closed' '## Backlog' '- gap done' > "$d/RESEARCH-STATE-alpha.md"
printf '%s\n' '# Research State' 'coverage metric: 7 / 7 gaps closed' '## Backlog' '- gap done' > "$d/RESEARCH-STATE-beta.md"
env_lines 0 5 5 0 0 0 >> "$d/RESEARCH-STATE-alpha.md"
env_lines 0 7 7 0 0 0 >> "$d/RESEARCH-STATE-beta.md"
# gamma: table-backed STALE focus (metric 23/23 + 2 leading-token `pending` backlog rows → CHECK 1 fires)
{ echo '# Research State'; echo
  env_lines 0 0 23 2 0 0; echo
  echo 'coverage metric: 23 / 23 declared gaps closed'; echo
  echo '## Gap-backlog (prioritized)'; echo
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | gap A | web | pending |'; echo '| high | gap B | web | pending |'; echo
  echo '## Blocked gaps'; echo '- none'; echo
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 2'
} > "$d/RESEARCH-STATE-gamma.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] \
   && grep -q 'RESEARCH-STATE-alpha.md' <<<"$out" \
   && grep -q 'RESEARCH-STATE-beta.md' <<<"$out" \
   && grep -q 'RESEARCH-STATE-gamma.md' <<<"$out"; then
  ok "BUG2: every RESEARCH-STATE-*.md linted (3 headers) + stale focus caught → exit 1"
else no "multistate: exit $(code "$d") · headers seen: $(grep -c 'verify-state:' <<<"$out")"; fi

# 14 — BUG 3 (zero-pending corpus crashes CHECK 1): a corpus with a metric like '3 / 3 closed' and NO
#      `pending` rows. `grep -c` already prints 0 on no match, so the old `|| echo 0` APPENDED a second
#      line → `pending` became the two-line string "0\n0" → `[ "0\n0" -gt 0 ]` threw
#      "integer expression expected" on stderr (seen live on the three.js corpus). Assert a CLEAN run:
#      exit 0 AND no integer-expression error on stderr.
d="$TMP/zero-pending"
state "$d" '# Research State' 'coverage metric: 3 / 3 gaps closed' '## Backlog' '- gap 1 closed' '- gap 2 closed' '- gap 3 closed'
addenv "$d" 0 3 3 0 0 0
err="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
if [ "$(code "$d")" = 0 ] && ! grep -qiE 'integer expression' <<<"$err"; then
  ok "BUG3: zero-pending metric 3/3 → exit 0, no 'integer expression expected' on stderr"
else no "zero-pending: exit $(code "$d") · stderr: $(grep -iE 'integer expression' <<<"$err" | head -1)"; fi

# 15 — CHECK 3 WARN (contradictory CANONICAL coverage): TWO coverage-metric assertions with DIFFERENT
#      denominators, both OUTSIDE any '## Iteration history' table → WARN. Mirrors the real
#      pruebas-dashboards corpus that ACCRETES 16/16 then 26/26 (the denominator drifted 16→26 with no
#      reconciliation), so a reader cannot get one true coverage number. Zero pending → CHECK 1 stays
#      silent, so exit is 0 and this isolates CHECK 3 (a WARN, not an rc change — like CHECK 2).
d="$TMP/coverage-contradiction"
state "$d" '# Research State' 'coverage metric: 16 / 16 gaps closed' \
  'Coverage metric: 26 / 26 declared gaps closed' '## Backlog' '- gap done'
addenv "$d" 0 16 16 0 0 0
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'contradictory coverage denominators \(16 vs 26\)' <<<"$out"; then
  ok "CHECK 3: 16/16 + 26/26 canonical → WARN (16 vs 26), exit still 0"
else no "coverage-contradiction: exit $(code "$d") :: $(grep -iE 'contradictory|warn' <<<"$out" | head -1)"; fi

# 16 — CHECK 3 NEGATIVE CONTROL (load-bearing): a SINGLE canonical coverage metric PLUS a normal
#      '## Iteration history' table whose rows each carry a DIFFERENT cumulative coverage snapshot
#      (1/12, 5/16, 8/26 — the denominator legitimately GROWS as the gap universe is discovered). Those
#      per-row snapshots are NOT a contradiction; CHECK 3 MUST exclude the iteration-history section
#      before gathering canonical figures, so only the single 5/12 metric counts → NO WARN. Without the
#      section-strip this fixture would false-alarm (12 vs 16 vs 26) — that false alarm is exactly what
#      this pins. This is the load-bearing test: without it the check is dangerous.
d="$TMP/coverage-history-ok"
state "$d" '# Research State' 'coverage metric: 5 / 12 gaps closed' '## Backlog' '- gap done' \
  '## Iteration history' \
  '| # | Date | Gap closed | Coverage (after) |' \
  '| 1 | d1 | g1 | Coverage (after B1): 1/12 |' \
  '| 2 | d2 | g2 | Coverage (after B2): 5/16 |' \
  '| 3 | d3 | g3 | Coverage (after B3): 8/26 |' \
  '## Blocked gaps' '- none'
addenv "$d" 0 5 12 0 0 0
out="$(run "$d")"
if ! grep -qE 'contradictory coverage denominators' <<<"$out"; then
  ok "CHECK 3 neg-control: 1 canonical metric + iteration-history snapshots → NO WARN (history excluded)"
else no "coverage-history-ok: FALSE ALARM :: $(grep -iE 'contradictory' <<<"$out" | head -1)"; fi

# 17 — CHECK 3 quiet on the happy path: exactly ONE canonical coverage metric, no iteration history →
#      a single denominator → NO 'contradictory coverage denominators' WARN, exit 0.
d="$TMP/coverage-single"
state "$d" '# Research State' 'coverage metric: 12 / 12 gaps closed' '## Backlog' '- gap done'
addenv "$d" 0 12 12 0 0 0
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'contradictory coverage denominators' <<<"$out"; then
  ok "CHECK 3: single canonical 12/12 → no contradiction WARN, exit 0"
else no "coverage-single: exit $(code "$d") :: $(grep -iE 'contradictory|warn' <<<"$out" | head -1)"; fi

# 18 — CHECK 3 NEGATIVE CONTROL, TITLE-CASE fence: same shape as case 16 but the heading is the ordinary
#      '## Iteration History' (Title Case). The history-fence must match CASE-INSENSITIVELY, else the
#      per-row cumulative snapshots (1/12, 5/16, 8/26) leak through and false-alarm. Case 16 only pins
#      the exact lowercase spelling, so this regression is invisible without this fixture.
d="$TMP/coverage-history-titlecase"
state "$d" '# Research State' 'coverage metric: 5 / 12 gaps closed' '## Backlog' '- gap done' \
  '## Iteration History' \
  '| # | Date | Gap closed | Coverage (after) |' \
  '| 1 | d1 | g1 | Coverage (after B1): 1/12 |' \
  '| 2 | d2 | g2 | Coverage (after B2): 5/16 |' \
  '| 3 | d3 | g3 | Coverage (after B3): 8/26 |' \
  '## Blocked gaps' '- none'
addenv "$d" 0 5 12 0 0 0
out="$(run "$d")"
if ! grep -qE 'contradictory coverage denominators' <<<"$out"; then
  ok "CHECK 3 neg-control: Title-Case '## Iteration History' → NO WARN (fence is case-insensitive)"
else no "coverage-history-titlecase: FALSE ALARM :: $(grep -iE 'contradictory' <<<"$out" | head -1)"; fi

# 19 — CHECK 3 NEGATIVE CONTROL, bare '## History' alias: a state file that heads its snapshot table
#      '## History' (no 'Iteration') must also be exempted. Over-recognizing the history fence is cheap
#      (a miss there is low-cost); a false alarm is the whole risk. Same cumulative-snapshot rows → NO WARN.
d="$TMP/coverage-history-alias"
state "$d" '# Research State' 'coverage metric: 5 / 12 gaps closed' '## Backlog' '- gap done' \
  '## History' \
  '| # | Date | Gap closed | Coverage (after) |' \
  '| 1 | d1 | g1 | Coverage (after B1): 1/12 |' \
  '| 2 | d2 | g2 | Coverage (after B2): 5/16 |' \
  '| 3 | d3 | g3 | Coverage (after B3): 8/26 |' \
  '## Blocked gaps' '- none'
addenv "$d" 0 5 12 0 0 0
out="$(run "$d")"
if ! grep -qE 'contradictory coverage denominators' <<<"$out"; then
  ok "CHECK 3 neg-control: bare '## History' alias → NO WARN (fence accepts the alias)"
else no "coverage-history-alias: FALSE ALARM :: $(grep -iE 'contradictory' <<<"$out" | head -1)"; fi

# 20 — TEMPLATE is not real state: a dir holding ONLY the kit template `RESEARCH-STATE.template.md`
#      (placeholders + the CHECK-3 doc example `16/16 then 26/26`, plus pending backlog rows) must be
#      treated as NO state → exit 2. The find must exclude `*.template.md`; a *.template.md is NEVER a
#      real corpus state file. RED before the fix: the template was linted and its documentation example
#      fired CHECK 1 (16/16 + pending) and CHECK 3 (16 vs 26) — a pure false positive on the kit tree.
d="$TMP/template-only"; mkdir -p "$d"
printf '%s\n' '# <SUBJECT> — Research State' 'coverage metric: 16 / 16 gaps closed' \
  'e.g. 16/16 then 26/26 (do NOT accrete contradictory denominators)' \
  '## Backlog' '- <gap> pending' '- <gap2> pending' '- <gap3> pending' > "$d/RESEARCH-STATE.template.md"
out="$(run "$d")"
if [ "$(code "$d")" = 2 ] && ! grep -qE 'FAIL|contradictory coverage denominators|RESEARCH-STATE.template.md' <<<"$out"; then
  ok "template-only: *.template.md excluded → exit 2 (no state), template never linted"
else no "template-only: exit $(code "$d") (want 2) :: $(grep -iE 'fail|contradictory|verify-state:' <<<"$out" | head -1)"; fi

# 21 — POSITIVE CONTROL: a REAL RESEARCH-STATE.md (consistent 5/5) coexisting with a contradictory
#      RESEARCH-STATE.template.md in the SAME dir → the linter uses the REAL one and IGNORES the template
#      (exit 0 + ok line, and the template basename never appears in a header). Pins that the exclusion
#      does not accidentally drop real state. RED before the fix: mapfile linted BOTH, so the template's
#      16/16 + pending desync flipped the aggregate to exit 1.
d="$TMP/real-plus-template"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' '## Backlog' '- gap done'
addenv "$d" 0 5 5 0 0 0   # real state carries the envelope; the template (excluded) does not
printf '%s\n' '# <SUBJECT> — Research State' 'coverage metric: 16 / 16 gaps closed' \
  'e.g. 16/16 then 26/26' '## Backlog' '- <gap> pending' > "$d/RESEARCH-STATE.template.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out" \
   && ! grep -q 'RESEARCH-STATE.template.md' <<<"$out"; then
  ok "real state + template coexist → uses REAL, ignores template (exit 0, template not linted)"
else no "real-plus-template: exit $(code "$d") :: $(grep -iE 'fail|template|ok ' <<<"$out" | head -1)"; fi

# 22 — TEMPLATE not counted as a block: CHECK 2's on-disk *block*.md count must EXCLUDE a stray
#      block.template.md sitting in the corpus dir (a kit template must not inflate the count). Two real
#      blocks + one block.template.md → the summary must read "2 block file(s)", not 3. RED before the
#      fix: the loose `-iname '*block*.md'` glob counted the template too.
d="$TMP/template-block-count"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 2' '## Backlog' '- gap done'
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"; printf 'x\n' > "$d/block.template.md"
addenv "$d" 2 5 5 0 0 0
out="$(run "$d")"
if grep -qE '2 block file\(s\) on disk' <<<"$out"; then
  ok "CHECK 2: block.template.md excluded from on-disk count (2, not 3)"
else no "template-block-count: on-disk count :: $(grep -iE 'block file' <<<"$out" | head -1)"; fi

# ============================ research-state.v1 ENVELOPE CONTRACT ============================
# The new authority: verify-state RECOMPUTES the disk-anchored envelope fields and FAILs on drift.

# 23 — MISSING ENVELOPE (the STALE-gate): a prose-only state with NO research-state.v1 fence → FAIL exit 1
#      with the actionable seed message. Un-migrated corpora must not silently trust prose. (The companion
#      --next→STALE assertion lives in research-sdd-status.test.sh.)
d="$TMP/no-envelope"
state "$d" '# Research State' 'coverage metric: 3 / 3 gaps closed' '## Backlog' '- gap done'
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL +no research-state.v1 envelope' <<<"$out" \
   && grep -q -- '--sync-state' <<<"$out"; then
  ok "missing envelope → FAIL exit 1 + actionable --sync-state message"
else no "no-envelope: exit $(code "$d") :: $(grep -iE 'fail|envelope' <<<"$out" | head -1)"; fi

# ewrite <dir> <covered> <gc> <kg> <io> <req> <bo> <backlog-row...> — a TABLE-backed state (rows are
# "priority|gap|status") + a fixed blocked entry 'gpu profiling — needs: hardware' + the given envelope.
ewrite() {
  local dir="$1" cb="$2" gc="$3" kg="$4" io="$5" req="$6" bo="$7"; shift 7; mkdir -p "$dir"
  { echo '# T — Research State'; echo
    env_lines "$cb" "$gc" "$kg" "$io" "$req" "$bo"; echo
    echo '## Coverage'; echo "- **Coverage metric**: $gc / $kg closed"; echo
    echo '## Gap-backlog (prioritized)'; echo
    echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
    local r p g s; for r in "$@"; do IFS='|' read -r p g s <<<"$r"; echo "| $p | $g | web | $s |"; done; echo
    echo '## Blocked gaps'; echo '- gpu profiling — needs: hardware'; echo
    echo '## Stop control'; echo "- **Open gaps — read-only investigable**: $io"
  } > "$dir/RESEARCH-STATE.md"
}

# 24 — ENVELOPE ALL-MATCH: 2 pending non-blocked rows, envelope investigable_open=2 → exit 0 + ok line.
d="$TMP/env-ok"; ewrite "$d" 0 4 10 2 0 1 "high|reconstruct pipeline|pending" "medium|map loaders|pending"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "envelope all fields match ground truth → exit 0 + ok"
else no "env-ok: exit $(code "$d") :: $(grep -iE 'fail|ok ' <<<"$out" | head -1)"; fi

# 25 — CORE REGRESSION: envelope investigable_open=0 while 2 pending non-blocked rows remain → FAIL exit 1.
#      The premature-STOP class closed by construction. (status.test.sh asserts --next then returns STALE.)
d="$TMP/env-inv-under"; ewrite "$d" 0 4 10 0 0 1 "high|reconstruct pipeline|pending" "medium|map loaders|pending"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL +envelope investigable_open=0 != 2' <<<"$out"; then
  ok "declared investigable_open=0 vs derived 2 → FAIL exit 1 (premature-STOP guard)"
else no "env-inv-under: exit $(code "$d") :: $(grep -iE 'investigable_open' <<<"$out" | head -1)"; fi

# 26 — BLOCKED gap EXCLUDED from investigable_open: 'gpu profiling' (a blocked entry) is pending in the
#      backlog but must NOT count; envelope investigable_open=1 (only the free gap) → exit 0.
d="$TMP/env-blocked-excl"; ewrite "$d" 0 4 10 1 0 1 "high|gpu profiling|pending" "medium|free gap|pending"
if [ "$(code "$d")" = 0 ]; then ok "blocked pending gap excluded from investigable_open (declared 1 == derived 1)"
else no "env-blocked-excl: exit $(code "$d") :: $(run "$d" | grep -iE 'investigable_open' | head -1)"; fi

# 27 — covered_blocks mismatch: envelope covered_blocks=5 but only 2 *block*.md on disk → FAIL exit 1.
d="$TMP/env-covered"; ewrite "$d" 5 4 10 1 0 1 "high|the gap|pending"
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL +envelope covered_blocks=5 != 2' <<<"$out"; then
  ok "declared covered_blocks=5 vs 2 on-disk → FAIL exit 1"
else no "env-covered: exit $(code "$d") :: $(grep -iE 'covered_blocks' <<<"$out" | head -1)"; fi

# 28 — blocked_open mismatch: envelope blocked_open=3 but only 1 '- ... needs:' entry → FAIL exit 1.
d="$TMP/env-blocked"; ewrite "$d" 0 4 10 1 0 3 "high|the gap|pending"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL +envelope blocked_open=3 != 1' <<<"$out"; then
  ok "declared blocked_open=3 vs 1 actual → FAIL exit 1"
else no "env-blocked: exit $(code "$d") :: $(grep -iE 'blocked_open' <<<"$out" | head -1)"; fi

# ================= requires_execution_open (§19 build counter) — CALIBRATED CHECK E =================
# There is NO uniform on-disk marker for open build gaps (logosoft tracked its counter in PROSE only, all
# its backlog build rows closed), so CHECK E is deliberately NOT a strict-equality gate: it FAILs only the
# premature build-STOP direction (declared 0 while marked-open rows remain), WARNs on other divergence.

# 29 — THE TEETH CASE (premature build-STOP): an OPEN requires-execution backlog row (Status marked exactly
#      like three.js's G41) while the envelope declares the build loop DONE (requires_execution_open=0)
#      → FAIL exit 1. This is the §19 analog of case 25's investigable premature-STOP guard.
d="$TMP/req-premature"; ewrite "$d" 0 4 10 1 0 1 "high|open read-only gap|pending" \
  "high|G41 equipment LOD|requires-execution → §19 (not read-only; needs a build + re-measure)"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL +envelope requires_execution_open=0 .*premature build-STOP' <<<"$out"; then
  ok "marked-open requires-execution row + declared 0 → FAIL exit 1 (premature build-STOP caught)"
else no "req-premature: exit $(code "$d") :: $(grep -iE 'requires_execution' <<<"$out" | head -1)"; fi

# 30 — same fixture, envelope AGREES (requires_execution_open=1) → exit 0 and CHECK E fully silent.
d="$TMP/req-agree"; ewrite "$d" 0 4 10 1 1 1 "high|open read-only gap|pending" \
  "high|G41 equipment LOD|requires-execution → §19 (not read-only; needs a build + re-measure)"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -E '^   (FAIL|WARN)' <<<"$out" | grep -q 'requires_execution'; then
  ok "marked-open row + declared 1 → exit 0, CHECK E silent (backlog-anchored agreement)"
else no "req-agree: exit $(code "$d") :: $(grep -iE 'requires_execution' <<<"$out" | head -1)"; fi

# 31 — PROSE-TRACKED corpus (the logosoft shape): NO backlog marker at all, envelope carries a nonzero
#      declared count → exit 0 with CHECK E silent. Pins the calibration: a strict equality gate would
#      false-FAIL every prose-tracked corpus (declared N vs derived 0), which is exactly what CHECK E
#      must NOT do — derived 0 proves nothing.
d="$TMP/req-prose-only"; ewrite "$d" 0 4 10 1 1 1 "high|open read-only gap|pending"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -E '^   (FAIL|WARN)' <<<"$out" | grep -q 'requires_execution'; then
  ok "prose-tracked (no marker) + declared 1 → exit 0, silent (no false FAIL on logosoft-shape corpora)"
else no "req-prose-only: exit $(code "$d") :: $(grep -iE 'requires_execution' <<<"$out" | head -1)"; fi

# 32 — MIRROR HYGIENE: 1 marked-open row but the envelope declares 3 → WARN printed, exit UNCHANGED (0).
#      Divergence with marked rows on disk is drift worth surfacing, but only the 0-direction is a hazard.
d="$TMP/req-hygiene"; ewrite "$d" 0 4 10 1 3 1 "high|open read-only gap|pending" \
  "high|G41 equipment LOD|requires-execution → §19 (not read-only; needs a build + re-measure)"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'WARN +envelope requires_execution_open=3 != 1' <<<"$out"; then
  ok "declared 3 vs 1 marked-open row → WARN (mirror hygiene), exit still 0"
else no "req-hygiene: exit $(code "$d") :: $(grep -iE 'requires_execution' <<<"$out" | head -1)"; fi

# 33 — CLOSED markers EXCLUDED from the derivation: a struck-through gap (~~) and a '✅ cubierto — B7x'
#      status both carry the requires-execution token but are CLOSED rows (the logosoft closed-backlog
#      shape) → derived 0, declared 0 → exit 0, CHECK E silent (closed rows never re-arm the build loop).
d="$TMP/req-closed"; ewrite "$d" 0 4 10 0 0 1 \
  "high|~~G50 old build gap~~|requires-execution → §19" \
  "high|G51 landed PoC|requires-execution ✅ cubierto — B72"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -E '^   (FAIL|WARN)' <<<"$out" | grep -q 'requires_execution'; then
  ok "struck-through / cubierto requires-execution rows excluded → derived 0, exit 0"
else no "req-closed: exit $(code "$d") :: $(grep -iE 'requires_execution' <<<"$out" | head -1)"; fi

# 33a — REGRESSION (false-NEGATIVE, both judges): two OPEN requires-execution rows whose status carries a
#      NEGATED closure word ("not yet covered", "not yet done") — the OLD unanchored substring closed-test
#      (*covered*/*done*) wrongly matched these and excluded the row, so CHECK E stayed silent on a
#      genuinely open build gap. Envelope declares the build loop DONE (requires_execution_open=0) →
#      MUST FAIL exit 1 (premature build-STOP caught).
d="$TMP/req-negated-open"; ewrite "$d" 0 4 10 1 0 1 "high|open read-only gap|pending" \
  "high|G60 rt PoC|requires-execution → §19 (not yet covered by any PoC; needs a build)" \
  "high|G61 decode PoC|requires-execution — round-trip not yet done, awaiting slot"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL +envelope requires_execution_open=0 .*premature build-STOP' <<<"$out"; then
  ok "negated-closure open requires-execution rows + declared 0 → FAIL exit 1 (premature build-STOP caught)"
else no "req-negated-open: exit $(code "$d") :: $(grep -iE 'requires_execution' <<<"$out" | head -1)"; fi

# 33b — REGRESSION (false-POSITIVE, judge A): the ONLY requires-execution mention is a free-text aside on
#      an ordinary pending gap ("pending (requires-execution)") — the OLD unanchored open-test (*requires-
#      execution*) wrongly counted this as an open build gap. Envelope declares 0 and there is NO real
#      marked-open build row → CHECK E must stay SILENT (exit 0, no false FAIL).
d="$TMP/req-freetext-mention"; ewrite "$d" 0 4 10 1 0 1 "medium|future scope note|pending (requires-execution)"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -E '^   (FAIL|WARN)' <<<"$out" | grep -q 'requires_execution'; then
  ok "free-text 'pending (requires-execution)' mention NOT counted → exit 0, CHECK E silent (no false FAIL)"
else no "req-freetext-mention: exit $(code "$d") :: $(grep -iE 'requires_execution' <<<"$out" | head -1)"; fi

# CRLF — a RESEARCH-STATE.md saved with Windows line endings must still verify OK. Before env_field's
# trailing-CR strip, awk left '\r' on each value and is_int('0\r') was FALSE, so EVERY envelope check
# falsely FAILed — a deterministic false FAIL that bricked --next/archive on any CRLF-saved corpus.
d="$TMP/crlf"; mkdir -p "$d"
printf '# T\r\n> intro\r\n<!-- research-state.v1 -->\r\nschema: research-state.v1\r\ncovered_blocks: 0\r\ngaps_closed: 0\r\nknown_gaps: 0\r\ninvestigable_open: 0\r\nrequires_execution_open: 0\r\nblocked_open: 0\r\n<!-- /research-state.v1 -->\r\n## Gap-backlog (prioritized)\r\n## Blocked gaps\r\n## Stop control\r\n- **Open gaps — read-only investigable**: 0\r\n' > "$d/RESEARCH-STATE.md"
if [ "$(code "$d")" = 0 ]; then ok "CRLF-saved envelope verifies OK (env_field strips the trailing CR)"
else no "CRLF: exit $(code "$d") :: $(run "$d" 2>&1 | grep -iE 'FAIL' | head -1)"; fi

# ============================ B3 — MULTI-FOCUS + FOCUSED BLOCK COUNTS ============================
# These cases verify the B3 fix: focus-prefix derivation from state filename so ondisk counts
# only the blocks belonging to each focus, not all blocks across the corpus.

# env9 <covered> <gc> <kg> <io> <req> <bo> <def> — envelope lines including deferred_open
env9(){ printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: %s\ngaps_closed: %s\nknown_gaps: %s\ninvestigable_open: %s\nrequires_execution_open: %s\nblocked_open: %s\ndeferred_open: %s\n<!-- /research-state.v1 -->\n' "$@"; }

# B3-MF1 — RESEARCH-STATE-focus-a.md claims covered_blocks=2; only focus-a-block*.md are counted.
# Without the fix: ondisk=7 (all 7 blocks in the corpus dir) → FAIL.
# With the fix:    ondisk=2 (only focus-a's 2 blocks) → PASS.
d="$TMP/multi-focus-a"; mkdir -p "$d"
for i in 1 2; do printf 'x\n' > "$d/focus-a-block${i}.md"; done
for i in 1 2 3 4 5; do printf 'x\n' > "$d/focus-b-block${i}.md"; done
{ echo '# Focus A — Research State'; echo
  env9 2 5 5 0 0 0 0; echo
  echo '## Coverage'; echo '- **Covered blocks**: 2'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-focus-a.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "B3-MF1: RESEARCH-STATE-focus-a.md counts only focus-a's 2 blocks (not all 7) → exit 0"
else no "B3-MF1: exit $(code "$d") :: $(grep -iE 'fail|covered_blocks' <<<"$out" | head -1)"; fi

# B3-MF2 — RESEARCH-STATE-focus-b.md claims covered_blocks=5; only focus-b-block*.md are counted.
# Without the fix: ondisk=7 → FAIL. With the fix: ondisk=5 → PASS.
{ echo '# Focus B — Research State'; echo
  env9 5 3 3 0 0 0 0; echo
  echo '## Coverage'; echo '- **Covered blocks**: 5'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-focus-b.md"
out="$(run "$d")"   # lints BOTH state files; both must pass
if [ "$(code "$d")" = 0 ] && grep -c 'ok.*envelope validated' <<<"$out" | grep -q '^2$'; then
  ok "B3-MF2: both focuses PASS with per-focus block counts (2 + 5, never the combined 7)"
else no "B3-MF2: exit $(code "$d") · ok-lines=$(grep -c 'ok.*envelope validated' <<<"$out") :: $(grep -iE 'FAIL|covered_blocks' <<<"$out" | head -2 | tr '\n' '|')"; fi

# B3-MF3 — RESEARCH-STATE.md with a sibling FOCUSES.md maps to a different block prefix (legacy case).
d="$TMP/multi-focus-focuses"; mkdir -p "$d"
# Two focuses: "integration" uses hilton-bms-blockN.md; "dash" uses dash-blockN.md
for i in 1 2 3; do printf 'x\n' > "$d/hilton-bms-block${i}.md"; done
printf 'x\n' > "$d/dash-block1.md"
# FOCUSES.md with the Block prefix column
{ printf '# Focuses\n\n'
  printf '| Focus | Status | State file | Block prefix | Angle |\n'
  printf '|---|---|---|---|---|\n'
  printf '| `integration` | stopped | [RESEARCH-STATE.md](RESEARCH-STATE.md) | `hilton-bms-blockN.md` | test |\n'
  printf '| `dash` | active | [RESEARCH-STATE-dash.md](RESEARCH-STATE-dash.md) | `dash-blockN.md` | test |\n'
} > "$d/FOCUSES.md"
{ echo '# Integration — Research State'; echo
  env9 3 5 5 0 0 0 0; echo
  echo '## Coverage'; echo '- **Covered blocks**: 3'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "B3-MF3: RESEARCH-STATE.md with FOCUSES.md maps hilton-bms- prefix → 3 blocks → PASS"
else no "B3-MF3: exit $(code "$d") :: $(grep -iE 'fail|covered_blocks' <<<"$out" | head -1)"; fi

# B3a — ## Non-investigable gaps is treated identically to ## Blocked gaps for blocked_open derivation.
# A state with one entry under ## Non-investigable gaps and envelope blocked_open=1 must exit 0.
d="$TMP/non-investigable"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 3 0 0 1 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 3 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Non-investigable gaps (without lab / hardware / NDA)'
  echo '- live-system correlation — needs: live hardware (read-only probe phase §12)'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "B3a: ## Non-investigable gaps counted for blocked_open (1 needs: entry → blocked_open=1 → PASS)"
else no "B3a: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# B3a-FAIL — same fixture but envelope declares blocked_open=0 while 1 entry exists → FAIL.
d="$TMP/non-investigable-fail"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 3 0 0 0 0; echo   # blocked_open=0 (wrong)
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 3 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Non-investigable gaps (without lab / hardware / NDA)'
  echo '- live-system correlation — needs: live hardware'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*blocked_open=0 != 1' <<<"$out"; then
  ok "B3a-FAIL: blocked_open=0 vs 1 Non-investigable entry → FAIL (heading recognized)"
else no "B3a-FAIL: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# B3b — deferred_open envelope field: a backlog row with priority 'deferred' is counted.
d="$TMP/deferred-open"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 4 10 1 0 0 1; echo   # deferred_open=1
  echo '## Coverage'; echo '- **Coverage metric**: 4 / 10 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | active gap | web | pending |'
  echo '| deferred | G4 parked | analysis | ⏸ deferred — operator decision |'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "B3b: deferred_open=1 matches 1 open deferred backlog row → PASS"
else no "B3b: exit $(code "$d") :: $(grep -iE 'fail|deferred' <<<"$out" | head -1)"; fi

# B3b-FAIL — declared deferred_open=0 while 1 deferred row exists → FAIL.
d="$TMP/deferred-open-fail"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 4 10 1 0 0 0; echo   # deferred_open=0 (wrong — 1 deferred row exists)
  echo '## Coverage'; echo '- **Coverage metric**: 4 / 10 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | active gap | web | pending |'
  echo '| deferred | G4 parked | analysis | ⏸ deferred — operator decision |'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*deferred_open=0 != 1' <<<"$out"; then
  ok "B3b-FAIL: declared deferred_open=0 vs 1 deferred row → FAIL (CHECK F fires)"
else no "B3b-FAIL: exit $(code "$d") :: $(grep -iE 'fail|deferred' <<<"$out" | head -1)"; fi

# ======================== CHECK G — undocumented_findings (C2 §18 retro delta) ====================
# env10 <covered> <gc> <kg> <io> <req> <bo> <def> <uf> — envelope including undocumented_findings
env10(){ printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: %s\ngaps_closed: %s\nknown_gaps: %s\ninvestigable_open: %s\nrequires_execution_open: %s\nblocked_open: %s\ndeferred_open: %s\nundocumented_findings: %s\n<!-- /research-state.v1 -->\n' "$@"; }

# Minimal state file for G tests: no block files, no pending/blocked/deferred/req-execution rows.
# Each case differs only in the undocumented_findings value so no other check can fire.
_uf_fixture() {
  local dir="$1" uf="$2"; mkdir -p "$dir"
  { echo '# T — Research State'; echo
    env10 0 0 0 0 0 0 0 "$uf"; echo
    echo '## Gap-backlog (prioritized)'
    echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
    echo '## Blocked gaps'; echo '- none'
    echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
  } > "$dir/RESEARCH-STATE.md"
}

# G-absent — legacy envelope (env9, no undocumented_findings field) → silent, exit 0.
d="$TMP/uf-absent"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 0 0 0 0 0 0; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! echo "$out" | grep -qE 'FAIL.*undocumented_findings|WARN.*undocumented_findings'; then
  ok "G-absent: no undocumented_findings field → silent (no FAIL/WARN), exit 0 (legacy corpora not penalized)"
else no "G-absent: exit $(code "$d") :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-zero — undocumented_findings: 0 → exit 0, no FAIL or WARN about the field.
# SUGGESTION 8: the summary line now shows the field value; 'silent' means no FAIL/WARN, not no mention.
d="$TMP/uf-zero"; _uf_fixture "$d" 0
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! echo "$out" | grep -qE 'FAIL.*undocumented_findings|WARN.*undocumented_findings'; then
  ok "G-zero: undocumented_findings=0 → exit 0, no FAIL or WARN"
else no "G-zero: exit $(code "$d") :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-ok-max — undocumented_findings: 3 → exit 0, no WARN (WARN fires only above 3, not at 3).
d="$TMP/uf-ok-max"; _uf_fixture "$d" 3
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! echo "$out" | grep -qE 'WARN.*undocumented_findings'; then
  ok "G-ok-max: undocumented_findings=3 → exit 0, no WARN (boundary; WARN fires only >3)"
else no "G-ok-max: exit $(code "$d") :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-warn — undocumented_findings: 4 → WARN printed, exit still 0 (advisory, not a STOP hazard yet).
d="$TMP/uf-warn"; _uf_fixture "$d" 4
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && echo "$out" | grep -qE 'WARN.*undocumented_findings=4'; then
  ok "G-warn: undocumented_findings=4 → WARN emitted, exit 0"
else no "G-warn: exit $(code "$d") (want 0) :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-warn-max — undocumented_findings: 6 → WARN still (FAIL fires only above 6, not at 6).
d="$TMP/uf-warn-max"; _uf_fixture "$d" 6
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && echo "$out" | grep -qE 'WARN.*undocumented_findings=6'; then
  ok "G-warn-max: undocumented_findings=6 → WARN still, exit 0 (FAIL threshold is >6)"
else no "G-warn-max: exit $(code "$d") (want 0) :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-fail — undocumented_findings: 7 → FAIL exit 1.
d="$TMP/uf-fail"; _uf_fixture "$d" 7
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && echo "$out" | grep -qE 'FAIL.*undocumented_findings=7'; then
  ok "G-fail: undocumented_findings=7 → FAIL exit 1"
else no "G-fail: exit $(code "$d") (want 1) :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-nospace — undocumented_findings:7 (no space between key and value) must NOT report a clean envelope.
# The awk parser uses whitespace to split fields; a no-space format means $1 = "undocumented_findings:7"
# and env_field returns empty — BUT the LINE IS PRESENT. The gate must detect "line present but value
# not a valid non-negative integer" and FAIL rather than treating it the same as the absent (silent) case.
# Real regression: a researcher types `undocumented_findings:7` (no space) → old code silently exits 0
# and --sync-state then rewrites to 0, erasing a real debt of 7 with no warning.
d="$TMP/uf-nospace"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings:7\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && echo "$out" | grep -qE 'FAIL.*undocumented_findings'; then
  ok "G-nospace: undocumented_findings:7 (no space) → FAIL exit 1 (line present, value unparseable)"
else no "G-nospace: exit $(code "$d") (want 1) :: $(echo "$out" | grep -iE 'undocumented|ok ' | head -1)"; fi

# G-not-int — undocumented_findings: seven (word, not a digit) → FAIL.
# env_field returns 'seven'; is_int('seven') is false. The gate cannot check debt and must FAIL,
# not WARN, because the whole purpose of this counter is blocking the archive above threshold.
d="$TMP/uf-not-int"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: seven\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && echo "$out" | grep -qE 'FAIL.*undocumented_findings'; then
  ok "G-not-int: undocumented_findings: seven → FAIL exit 1 (non-integer value present)"
else no "G-not-int: exit $(code "$d") (want 1) :: $(echo "$out" | grep -iE 'undocumented|ok ' | head -1)"; fi

# G-negative — undocumented_findings: -2 (negative) → FAIL.
# Negative values are not valid for a non-negative integer counter; is_int('-2') is false.
d="$TMP/uf-negative"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: -2\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && echo "$out" | grep -qE 'FAIL.*undocumented_findings'; then
  ok "G-negative: undocumented_findings: -2 → FAIL exit 1 (negative is not a valid count)"
else no "G-negative: exit $(code "$d") (want 1) :: $(echo "$out" | grep -iE 'undocumented|ok ' | head -1)"; fi

# G-nospace-nonint — undocumented_findings:seven (NO SPACE + non-integer) → FAIL.
# Root class: no-space format makes env_field's awk see $1="undocumented_findings:seven" which never
# matches $1==key":", so env_field returns "" — indistinguishable from absent WITHOUT a separate
# presence probe. The _uf_present prefix probe (added in BLOCKER 1A fix) detects the line and then
# "" from env_field fails is_int, triggering FAIL. This is the sibling of G-nospace (which tests
# a valid int in no-space format) but stresses the non-integer value path.
d="$TMP/uf-nospace-nonint"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings:seven\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && echo "$out" | grep -qE 'FAIL.*undocumented_findings'; then
  ok "G-nospace-nonint: undocumented_findings:seven (no space) → FAIL exit 1 (prefix probe detects line, env_field sees empty → not-int)"
else no "G-nospace-nonint: exit $(code "$d") (want 1) :: $(echo "$out" | grep -iE 'undocumented|ok ' | head -1)"; fi

# NEGATIVE CONTROL — prove CHECK 1 (the STALE detection) has TEETH via mutation.
if [ "${1:-}" = "--prove-teeth" ]; then
  # Seed the shared lib into $TMP/lib/ so every mutant SUT placed in $TMP can source it.
  # verify-state.sh resolves its lib as $(dirname $0)/lib/focus-prefix.sh; a mutant in $TMP
  # needs the lib at $TMP/lib/focus-prefix.sh (same pattern: research-sdd-status.test.sh copies
  # verify-state.sh to $TMP so the mutant status.sh can call it as $here/verify-state.sh).
  mkdir -p "$TMP/lib"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"

  echo "-- teeth: neuter CHECK 1's condition; expect the STALE fixture to stop exiting 1 --"
  mutant="$TMP/verify-state.MUTANT.sh"
  # Force CHECK 1's guard false so the stale-mirror FAIL can never fire.
  sed 's/^\( *\)if \[ -n "${cx:-}".*then$/\1if false; then  # MUTANT: CHECK 1 neutered/' "$SUT" > "$mutant"
  if ! grep -q 'MUTANT: CHECK 1 neutered' "$mutant"; then
    no "teeth: could not build mutant (CHECK 1 guard line not found — did the SUT change?)"
  else
    d="$TMP/stale"   # reuse the flagship stale fixture (case 4)
    bash "$mutant" "$d" >/dev/null 2>&1; mgot=$?
    if [ "$mgot" = 0 ]; then
      ok "teeth: neutered mutant false-passes (exit 0) → STALE assertion has teeth"
    else no "teeth: mutant exit $mgot (want 0) — STALE case does NOT depend on CHECK 1 (THEATER)"; fi
  fi

  # Teeth for case 10 — flip CHECK 2's on-disk guard `-gt 0` → `-ge 0`; the zero-on-disk fixture must
  # then EMIT a WARN (5 != 0), proving case 10's "no WARN" assertion genuinely pins that guard.
  echo "-- teeth: flip CHECK 2 guard -gt 0 → -ge 0; expect the zero-on-disk fixture to now WARN --"
  mutant2="$TMP/verify-state.CHECK2.MUTANT.sh"
  sed 's/\[ "${ondisk:-0}" -gt 0 \]/[ "${ondisk:-0}" -ge 0 ]/' "$SUT" > "$mutant2"
  if ! grep -q '"${ondisk:-0}" -ge 0' "$mutant2"; then
    no "teeth(check2): could not build mutant (guard line not found — did the SUT change?)"
  else
    d="$TMP/warn-zero-ondisk"   # reuse case 10 fixture: claim 5, zero *block*.md on disk
    m2out="$(bash "$mutant2" "$d" 2>/dev/null)"
    if grep -qE 'WARN.*disagrees with 0 block file' <<<"$m2out"; then
      ok "teeth: -ge 0 mutant WARNs on zero on-disk → case 10 'no WARN' pins the -gt 0 guard"
    else no "teeth(check2): mutant did NOT warn — case 10 does NOT depend on the guard (THEATER)"; fi
  fi

  # Teeth for case 15 — raise CHECK 3's distinct-denominator guard `-ge 2` → `-ge 99`; the contradiction
  # fixture must then STOP emitting the WARN, proving case 15 genuinely depends on CHECK 3 (not theater).
  echo "-- teeth: raise CHECK 3 guard -ge 2 → -ge 99; expect the contradiction fixture to stop WARNing --"
  mutant3="$TMP/verify-state.CHECK3.MUTANT.sh"
  sed 's/\[ "${#denoms\[@\]}" -ge 2 \]/[ "${#denoms[@]}" -ge 99 ]/' "$SUT" > "$mutant3"
  if ! grep -q '"${#denoms\[@\]}" -ge 99' "$mutant3"; then
    no "teeth(check3): could not build mutant (guard line not found — did the SUT change?)"
  else
    d="$TMP/coverage-contradiction"   # reuse case 15 fixture: 16/16 + 26/26 canonical
    m3out="$(bash "$mutant3" "$d" 2>/dev/null)"
    if ! grep -qE 'contradictory coverage denominators' <<<"$m3out"; then
      ok "teeth: -ge 99 mutant stops WARNing → case 15 pins the CHECK 3 contradiction guard"
    else no "teeth(check3): mutant STILL warned — case 15 does NOT depend on CHECK 3 (THEATER)"; fi
  fi

  # Teeth for case 25 (the CORE regression) — neuter ENVELOPE CHECK B (investigable_open); the under-declared
  # fixture must then STOP exiting 1, proving the premature-STOP guard is genuinely load-bearing (not theater).
  echo "-- teeth: neuter ENVELOPE CHECK B (investigable_open); expect the under-declared fixture to pass --"
  mutantE="$TMP/verify-state.ENVB.MUTANT.sh"
  sed 's/^\( *\)if ! is_int "\$e_inv" .*then$/\1if false; then  # MUTANT: envelope investigable check neutered/' "$SUT" > "$mutantE"
  if ! grep -q 'MUTANT: envelope investigable check neutered' "$mutantE"; then
    no "teeth(envB): could not build mutant (CHECK B guard line not found — did the SUT change?)"
  else
    d="$TMP/env-inv-under"   # reuse case 25 fixture: declared investigable_open=0 while 2 pending remain
    bash "$mutantE" "$d" >/dev/null 2>&1; egot=$?
    if [ "$egot" = 0 ]; then
      ok "teeth: neutered envelope-investigable mutant false-passes (exit 0) → case 25 has teeth"
    else no "teeth(envB): mutant exit $egot (want 0) — case 25 does NOT depend on CHECK B (THEATER)"; fi
  fi

  # Teeth for case 29 (the §19 premature-build-STOP guard) — neuter CHECK E's FAIL branch; the marked-open
  # fixture with declared 0 must then STOP exiting 1 (the elif demotes it to a WARN at most), proving the
  # calibrated gate is genuinely load-bearing and not theater.
  echo "-- teeth: neuter ENVELOPE CHECK E (requires_execution_open); expect the marked-open fixture to pass --"
  mutantR="$TMP/verify-state.ENVE.MUTANT.sh"
  sed 's/^\( *\)if is_int "\$e_req" .*then$/\1if false; then  # MUTANT: envelope requires-execution check neutered/' "$SUT" > "$mutantR"
  if ! grep -q 'MUTANT: envelope requires-execution check neutered' "$mutantR"; then
    no "teeth(envE): could not build mutant (CHECK E guard line not found — did the SUT change?)"
  else
    d="$TMP/req-premature"   # reuse case 29 fixture: marked-open requires-execution row + declared 0
    bash "$mutantR" "$d" >/dev/null 2>&1; rgot=$?
    if [ "$rgot" = 0 ]; then
      ok "teeth: neutered envelope-requires-execution mutant false-passes (exit 0) → case 29 has teeth"
    else no "teeth(envE): mutant exit $rgot (want 0) — case 29 does NOT depend on CHECK E (THEATER)"; fi
  fi

  # ---- B3 mutation: neuter derive_focus_prefix in lib/focus-prefix.sh → ondisk counts ALL blocks ----
  # derive_focus_prefix now lives in lib/focus-prefix.sh (single source of truth for verify-state.sh and
  # research-sdd-status.sh). The mutant puts a neutered lib in $TMP/lib/ and copies the real SUT alongside
  # it; verify-state.sh resolves its lib path as $(dirname $0)/lib/focus-prefix.sh, so the copy in $TMP
  # sources the mutant lib — same pattern as research-sdd-status.test.sh copies verify-state.sh to $TMP.
  echo "-- teeth: B3 — neuter derive_focus_prefix in lib; multi-focus alpha fixture must then false-fail on ondisk count --"
  mkdir -p "$TMP/lib"
  # Mutant lib: derive_focus_prefix always returns 0 without printing → empty prefix → no filter → all blocks
  sed 's/^  derive_focus_prefix() {$/  derive_focus_prefix() { return 0  # MUTANT-B3: always empty prefix/' "$FPLIB" > "$TMP/lib/focus-prefix.sh"
  mutantFP="$TMP/verify-state.B3FP.MUTANT.sh"
  cp "$SUT" "$mutantFP"
  if ! grep -q 'MUTANT-B3: always empty prefix' "$TMP/lib/focus-prefix.sh"; then
    no "teeth(B3): could not build derive_focus_prefix mutant (function header not found — did the lib change?)"
  else
    d="$TMP/multi-focus-a"   # reuse B3-MF1 fixture: alpha state (covered_blocks=2), 7 total blocks in dir
    bash "$mutantFP" "$d" >/dev/null 2>&1; mfpgot=$?
    if [ "$mfpgot" = 1 ]; then
      ok "teeth(B3): neutered derive_focus_prefix mutant sees 7 on-disk vs envelope 2 → false-fails → B3 fix is load-bearing"
    else no "teeth(B3): mutant exit $mfpgot (want 1) — multi-focus fix may not be exercised (THEATER)"; fi
  fi

  # ---- B3a mutation: restrict blocked section to ## Blocked gaps only (remove Non-investigable branch) ----
  # Use the B3a-FAIL fixture: 1 Non-investigable entry, envelope blocked_open=0 (wrong).
  # Real SUT: derive_blocked finds the entry → d_blocked=1 ≠ e_blocked=0 → FAIL (exit 1).
  # Mutant (only ## Blocked gaps): derive_blocked=0, e_blocked=0 → match → exit 0 (FALSE-PASS).
  echo "-- teeth: B3a — remove Non-investigable section from derive_blocked; B3a-FAIL fixture must false-pass --"
  mutantNI="$TMP/verify-state.B3NI.MUTANT.sh"
  # Remove "; _section "$1" '## Non-investigable gaps'" from every line where it appears.
  sed "s/; _section \"\\\$1\" '## Non-investigable gaps'//g" "$SUT" > "$mutantNI"
  if grep -qF "'## Non-investigable gaps'" "$mutantNI"; then
    no "teeth(B3a): could not build Non-investigable mutant (pattern still present — did the SUT change?)"
  else
    d="$TMP/non-investigable-fail"   # reuse B3a-FAIL: 1 Non-investigable entry, envelope blocked_open=0 (wrong)
    bash "$mutantNI" "$d" >/dev/null 2>&1; mnigot=$?
    if [ "$mnigot" = 0 ]; then
      ok "teeth(B3a): mutant ignores Non-investigable → false-passes (mismatch undetected) → dual-section fix is load-bearing"
    else no "teeth(B3a): mutant exit $mnigot (want 0) — Non-investigable detection may not depend on the dual-section fix (THEATER)"; fi
  fi

  # ---- B3b mutation: neuter derive_deferred → always return 0 → deferred_open mismatch undetected ----
  echo "-- teeth: B3b — neuter derive_deferred; fixture declaring deferred_open=0 vs 1 row must then false-pass --"
  mutantDD="$TMP/verify-state.B3DD.MUTANT.sh"
  sed 's/^derive_deferred() {$/derive_deferred() { echo 0; return  # MUTANT-B3b: always 0/' "$SUT" > "$mutantDD"
  if ! grep -q 'MUTANT-B3b: always 0' "$mutantDD"; then
    no "teeth(B3b): could not build derive_deferred mutant (function header not found — did the SUT change?)"
  else
    d="$TMP/deferred-open-fail"   # reuse B3b-FAIL fixture: declared deferred_open=0 vs 1 deferred row
    bash "$mutantDD" "$d" >/dev/null 2>&1; mddgot=$?
    if [ "$mddgot" = 0 ]; then
      ok "teeth(B3b): neutered derive_deferred always returns 0 → false-passes → CHECK F is load-bearing"
    else no "teeth(B3b): mutant exit $mddgot (want 0) — deferred check may not depend on derive_deferred (THEATER)"; fi
  fi

  # ---- CHECK G mutation: raise threshold from 6 to 9999 → uf=7 stops FAILing (FAIL guard is load-bearing) ----
  echo "-- teeth: CHECK G — raise -gt 6 threshold to 9999; expect uf=7 fixture to exit 0 (WARN only, not FAIL) --"
  mutantG="$TMP/verify-state.CHECKG.MUTANT.sh"
  sed 's/"\$e_uf" -gt 6/"\$e_uf" -gt 9999/' "$SUT" > "$mutantG"
  if ! grep -q '"$e_uf" -gt 9999' "$mutantG"; then
    no "teeth(G): could not build CHECK G mutant (\"\$e_uf\" -gt 6 not found — did the SUT change?)"
  else
    d="$TMP/uf-fail"   # reuse G-fail fixture: undocumented_findings=7
    bash "$mutantG" "$d" >/dev/null 2>&1; mgot=$?
    if [ "$mgot" = 0 ]; then
      ok "teeth(G): threshold raised to 9999 → uf=7 false-passes (exit 0) — CHECK G FAIL guard is load-bearing"
    else no "teeth(G): mutant exit $mgot (want 0) — uf=7 fixture does NOT depend on CHECK G FAIL (THEATER)"; fi
  fi

  # ---- CHECK G non-integer teeth: neuter the present-but-non-integer branch → G-not-int must false-pass ----
  # Mutation: replace the opening condition of the new "present but not is_int" FAIL branch with `false`
  # so that malformed values (seven, -2, no-space) are never caught. The G-not-int fixture must then
  # exit 0 (false-pass), proving the guard is load-bearing and not theater.
  echo "-- teeth: CHECK G non-int — neuter the non-integer FAIL branch; G-not-int fixture must false-pass --"
  mutantGNI="$TMP/verify-state.GNOTINT.MUTANT.sh"
  sed 's/if \[ -n "\$_uf_present" \] && ! is_int "\$e_uf"; then/if false; then  # MUTANT-GNI: non-integer check neutered/' "$SUT" > "$mutantGNI"
  if ! grep -q 'MUTANT-GNI: non-integer check neutered' "$mutantGNI"; then
    no "teeth(GNI): could not build mutant (non-integer guard line not found — did the SUT change?)"
  else
    d="$TMP/uf-not-int"   # reuse G-not-int fixture: undocumented_findings: seven
    bash "$mutantGNI" "$d" >/dev/null 2>&1; mgnigot=$?
    if [ "$mgnigot" = 0 ]; then
      ok "teeth(GNI): neutered non-integer mutant exits 0 → G-not-int has teeth (non-integer FAIL branch is load-bearing)"
    else no "teeth(GNI): mutant exit $mgnigot (want 0) — G-not-int may not depend on the non-integer branch (THEATER)"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
