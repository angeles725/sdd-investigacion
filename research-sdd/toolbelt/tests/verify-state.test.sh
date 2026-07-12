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
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
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
if [ "$(code "$d")" = 0 ] && printf '%s\n' "$out" | grep -qE 'ok +envelope validated'; then
  ok "consistent 5/5 · zero pending → exit 0 + ok line"
else no "consistent: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'ok|fail' | head -1)"; fi

# 4 — STALE MIRROR (the core FAIL): metric 23 / 23 WITH pending gap rows → exit 1 + PREMATURE STOP line.
#     Mirrors the real pruebas-dashboards run-A desync (summary 23/23 closed while gaps pending).
d="$TMP/stale"
state "$d" '# Research State' 'coverage metric: 23 / 23 declared gaps closed' \
  '## Backlog' '- gap A pending' '- gap B pending' '- gap C pending'
addenv "$d" 0 23 23 0 0 0   # envelope derived-consistent (bullets, not table rows → investigable=0); CHECK 1 prose fires
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && printf '%s\n' "$out" | grep -qE 'FAIL' && printf '%s\n' "$out" | grep -q 'PREMATURE STOP'; then
  ok "STALE 23/23 + pending → exit 1 + FAIL/PREMATURE STOP"
else no "stale: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'fail|premature' | head -1)"; fi

# 5 — NON-EQUAL metric guard: metric 3 / 5 WITH pending gaps → exit 0 (CHECK 1 must NOT fire when X != Y).
#     Key boundary: proves the FAIL is gated on X==Y, not merely on "pending exists".
d="$TMP/unequal"
state "$d" '# Research State' 'coverage metric: 3 / 5 gaps closed' '## Backlog' '- gap A pending' '- gap B pending'
addenv "$d" 0 3 5 0 0 0
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
if [ "$(code "$d")" = 0 ] && printf '%s\n' "$out" | grep -qE 'WARN.*disagrees with 2 block file'; then
  ok "CHECK 2: claim 21 vs 2 on-disk → WARN printed, exit still 0"
else no "warn: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'warn' | head -1)"; fi

# 8 — NESTED state: RESEARCH-STATE.md under a corpus/ subdir (within maxdepth 3) is found and linted.
#     Reuse the stale desync so we can assert the nested file is genuinely parsed (exit 1, not skipped).
d="$TMP/nested"; mkdir -p "$d/corpus"
state "$d/corpus" '# Research State' 'coverage metric: 23 / 23 gaps closed' '## Backlog' '- gap A pending'
addenv "$d/corpus" 0 23 23 0 0 0
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && printf '%s\n' "$out" | grep -q 'PREMATURE STOP'; then
  ok "nested corpus/RESEARCH-STATE.md found + linted (stale caught, exit 1)"
else no "nested: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'no research-state|premature' | head -1)"; fi

# 9 — CHECK 2 quiet: covered-blocks claim MATCHES the on-disk count → NO warn (and exit 0).
d="$TMP/nowarn"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 2' '## Backlog' '- gap done'
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"
addenv "$d" 2 5 5 0 0 0
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! printf '%s\n' "$out" | grep -qE 'WARN'; then
  ok "CHECK 2: claim 2 == 2 on-disk → no WARN, exit 0"
else no "no-warn: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'warn' | head -1)"; fi

# 10 — CHECK 2 on-disk guard: 'Covered blocks: 5' claim but ZERO *block*.md on disk → NO warn (exit 0).
#      Pins the `[ "${ondisk:-0}" -gt 0 ]` guard at verify-state.sh:49 — CHECK 2 is SUPPRESSED when nothing
#      is on disk (you cannot 'disagree' with an empty glob). Load-bearing: flip the guard to `-ge 0` in a
#      mutant and the WARN WOULD fire (5 != 0), so this "no WARN" assertion pins that guard. See --prove-teeth.
d="$TMP/warn-zero-ondisk"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 5' '## Backlog' '- gap done'
# NOTE: no *block*.md files created → ondisk == 0.
addenv "$d" 0 5 5 0 0 0   # envelope covered_blocks=0 matches ondisk=0; prose 'Covered blocks: 5' is CHECK 2's -gt 0 guard case
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! printf '%s\n' "$out" | grep -qE 'WARN'; then
  ok "CHECK 2: claim 5 vs 0 on-disk → guard -gt 0 suppresses WARN, exit 0"
else no "warn-zero-ondisk: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'warn' | head -1)"; fi

# 11 — CHECK 2 empty-claim guard IN ISOLATION: NO 'Covered blocks' line, but block files DO exist on disk
#      (ondisk > 0). CHECK 2 stays silent specifically because `covered_claim` is empty (the
#      `-n "${covered_claim:-}"` guard), independent of the on-disk count. Earlier cases always had
#      ondisk==0 too, so only this fixture (ondisk>0) isolates the empty-claim guard.
d="$TMP/nocovered-ondisk"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' '## Backlog' '- gap done'
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"   # ondisk == 2, but no covered-blocks claim
addenv "$d" 2 5 5 0 0 0
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! printf '%s\n' "$out" | grep -qE 'WARN'; then
  ok "CHECK 2: no covered-blocks line + 2 on-disk → empty-claim guard keeps it silent, exit 0"
else no "nocovered-ondisk: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'warn' | head -1)"; fi

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
if printf '%s\n' "$out" | grep -qE '4 block file\(s\) on disk'; then
  ok "STRICT: prefixed -block/-bloque counted (4), bare/decoy 'blocked-notes.md' excluded → '4 block file(s)'"
else no "bloque-glob: on-disk count :: $(printf '%s\n' "$out" | grep -iE 'block file' | head -1)"; fi

# 13 — BUG 2 (only the FIRST state file is linted): a corpus with several RESEARCH-STATE-*.md (niagara
#      keeps ~12, one per focus) must lint EVERY one, not just `head -1`. Fixture: two consistent
#      focuses + one STALE focus (23/23 while gaps pending). The old `head -1` linted a single file,
#      printing ONE header and silently skipping the other focuses. Assert ALL THREE basenames appear
#      (every file linted) AND exit 1 (the stale focus is caught). The all-headers check is
#      order-independent, so this stays deterministic regardless of find's traversal order.
d="$TMP/multistate"; mkdir -p "$d"
printf '%s\n' '# Research State' 'coverage metric: 5 / 5 gaps closed' '## Backlog' '- gap done' > "$d/RESEARCH-STATE-alpha.md"
printf '%s\n' '# Research State' 'coverage metric: 7 / 7 gaps closed' '## Backlog' '- gap done' > "$d/RESEARCH-STATE-beta.md"
printf '%s\n' '# Research State' 'coverage metric: 23 / 23 declared gaps closed' '## Backlog' '- gap A pending' '- gap B pending' > "$d/RESEARCH-STATE-gamma.md"
env_lines 0 5 5 0 0 0 >> "$d/RESEARCH-STATE-alpha.md"
env_lines 0 7 7 0 0 0 >> "$d/RESEARCH-STATE-beta.md"
env_lines 0 23 23 0 0 0 >> "$d/RESEARCH-STATE-gamma.md"   # derived-consistent; CHECK 1 prose fires on 23/23 + pending
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] \
   && printf '%s\n' "$out" | grep -q 'RESEARCH-STATE-alpha.md' \
   && printf '%s\n' "$out" | grep -q 'RESEARCH-STATE-beta.md' \
   && printf '%s\n' "$out" | grep -q 'RESEARCH-STATE-gamma.md'; then
  ok "BUG2: every RESEARCH-STATE-*.md linted (3 headers) + stale focus caught → exit 1"
else no "multistate: exit $(code "$d") · headers seen: $(printf '%s\n' "$out" | grep -c 'verify-state:')"; fi

# 14 — BUG 3 (zero-pending corpus crashes CHECK 1): a corpus with a metric like '3 / 3 closed' and NO
#      `pending` rows. `grep -c` already prints 0 on no match, so the old `|| echo 0` APPENDED a second
#      line → `pending` became the two-line string "0\n0" → `[ "0\n0" -gt 0 ]` threw
#      "integer expression expected" on stderr (seen live on the three.js corpus). Assert a CLEAN run:
#      exit 0 AND no integer-expression error on stderr.
d="$TMP/zero-pending"
state "$d" '# Research State' 'coverage metric: 3 / 3 gaps closed' '## Backlog' '- gap 1 closed' '- gap 2 closed' '- gap 3 closed'
addenv "$d" 0 3 3 0 0 0
err="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
if [ "$(code "$d")" = 0 ] && ! printf '%s\n' "$err" | grep -qiE 'integer expression'; then
  ok "BUG3: zero-pending metric 3/3 → exit 0, no 'integer expression expected' on stderr"
else no "zero-pending: exit $(code "$d") · stderr: $(printf '%s\n' "$err" | grep -iE 'integer expression' | head -1)"; fi

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
if [ "$(code "$d")" = 0 ] && printf '%s\n' "$out" | grep -qE 'contradictory coverage denominators \(16 vs 26\)'; then
  ok "CHECK 3: 16/16 + 26/26 canonical → WARN (16 vs 26), exit still 0"
else no "coverage-contradiction: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'contradictory|warn' | head -1)"; fi

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
if ! printf '%s\n' "$out" | grep -qE 'contradictory coverage denominators'; then
  ok "CHECK 3 neg-control: 1 canonical metric + iteration-history snapshots → NO WARN (history excluded)"
else no "coverage-history-ok: FALSE ALARM :: $(printf '%s\n' "$out" | grep -iE 'contradictory' | head -1)"; fi

# 17 — CHECK 3 quiet on the happy path: exactly ONE canonical coverage metric, no iteration history →
#      a single denominator → NO 'contradictory coverage denominators' WARN, exit 0.
d="$TMP/coverage-single"
state "$d" '# Research State' 'coverage metric: 12 / 12 gaps closed' '## Backlog' '- gap done'
addenv "$d" 0 12 12 0 0 0
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! printf '%s\n' "$out" | grep -qE 'contradictory coverage denominators'; then
  ok "CHECK 3: single canonical 12/12 → no contradiction WARN, exit 0"
else no "coverage-single: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'contradictory|warn' | head -1)"; fi

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
if ! printf '%s\n' "$out" | grep -qE 'contradictory coverage denominators'; then
  ok "CHECK 3 neg-control: Title-Case '## Iteration History' → NO WARN (fence is case-insensitive)"
else no "coverage-history-titlecase: FALSE ALARM :: $(printf '%s\n' "$out" | grep -iE 'contradictory' | head -1)"; fi

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
if ! printf '%s\n' "$out" | grep -qE 'contradictory coverage denominators'; then
  ok "CHECK 3 neg-control: bare '## History' alias → NO WARN (fence accepts the alias)"
else no "coverage-history-alias: FALSE ALARM :: $(printf '%s\n' "$out" | grep -iE 'contradictory' | head -1)"; fi

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
if [ "$(code "$d")" = 2 ] && ! printf '%s\n' "$out" | grep -qE 'FAIL|contradictory coverage denominators|RESEARCH-STATE.template.md'; then
  ok "template-only: *.template.md excluded → exit 2 (no state), template never linted"
else no "template-only: exit $(code "$d") (want 2) :: $(printf '%s\n' "$out" | grep -iE 'fail|contradictory|verify-state:' | head -1)"; fi

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
if [ "$(code "$d")" = 0 ] && printf '%s\n' "$out" | grep -qE 'ok +envelope validated' \
   && ! printf '%s\n' "$out" | grep -q 'RESEARCH-STATE.template.md'; then
  ok "real state + template coexist → uses REAL, ignores template (exit 0, template not linted)"
else no "real-plus-template: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'fail|template|ok ' | head -1)"; fi

# 22 — TEMPLATE not counted as a block: CHECK 2's on-disk *block*.md count must EXCLUDE a stray
#      block.template.md sitting in the corpus dir (a kit template must not inflate the count). Two real
#      blocks + one block.template.md → the summary must read "2 block file(s)", not 3. RED before the
#      fix: the loose `-iname '*block*.md'` glob counted the template too.
d="$TMP/template-block-count"
state "$d" '# Research State' 'coverage metric: 5 / 5 gaps closed' 'Covered blocks: 2' '## Backlog' '- gap done'
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"; printf 'x\n' > "$d/block.template.md"
addenv "$d" 2 5 5 0 0 0
out="$(run "$d")"
if printf '%s\n' "$out" | grep -qE '2 block file\(s\) on disk'; then
  ok "CHECK 2: block.template.md excluded from on-disk count (2, not 3)"
else no "template-block-count: on-disk count :: $(printf '%s\n' "$out" | grep -iE 'block file' | head -1)"; fi

# ============================ research-state.v1 ENVELOPE CONTRACT ============================
# The new authority: verify-state RECOMPUTES the disk-anchored envelope fields and FAILs on drift.

# 23 — MISSING ENVELOPE (the STALE-gate): a prose-only state with NO research-state.v1 fence → FAIL exit 1
#      with the actionable seed message. Un-migrated corpora must not silently trust prose. (The companion
#      --next→STALE assertion lives in research-sdd-status.test.sh.)
d="$TMP/no-envelope"
state "$d" '# Research State' 'coverage metric: 3 / 3 gaps closed' '## Backlog' '- gap done'
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && printf '%s\n' "$out" | grep -qE 'FAIL +no research-state.v1 envelope' \
   && printf '%s\n' "$out" | grep -q -- '--sync-state'; then
  ok "missing envelope → FAIL exit 1 + actionable --sync-state message"
else no "no-envelope: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'fail|envelope' | head -1)"; fi

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
if [ "$(code "$d")" = 0 ] && printf '%s\n' "$out" | grep -qE 'ok +envelope validated'; then
  ok "envelope all fields match ground truth → exit 0 + ok"
else no "env-ok: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'fail|ok ' | head -1)"; fi

# 25 — CORE REGRESSION: envelope investigable_open=0 while 2 pending non-blocked rows remain → FAIL exit 1.
#      The premature-STOP class closed by construction. (status.test.sh asserts --next then returns STALE.)
d="$TMP/env-inv-under"; ewrite "$d" 0 4 10 0 0 1 "high|reconstruct pipeline|pending" "medium|map loaders|pending"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && printf '%s\n' "$out" | grep -qE 'FAIL +envelope investigable_open=0 != 2'; then
  ok "declared investigable_open=0 vs derived 2 → FAIL exit 1 (premature-STOP guard)"
else no "env-inv-under: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'investigable_open' | head -1)"; fi

# 26 — BLOCKED gap EXCLUDED from investigable_open: 'gpu profiling' (a blocked entry) is pending in the
#      backlog but must NOT count; envelope investigable_open=1 (only the free gap) → exit 0.
d="$TMP/env-blocked-excl"; ewrite "$d" 0 4 10 1 0 1 "high|gpu profiling|pending" "medium|free gap|pending"
if [ "$(code "$d")" = 0 ]; then ok "blocked pending gap excluded from investigable_open (declared 1 == derived 1)"
else no "env-blocked-excl: exit $(code "$d") :: $(run "$d" | grep -iE 'investigable_open' | head -1)"; fi

# 27 — covered_blocks mismatch: envelope covered_blocks=5 but only 2 *block*.md on disk → FAIL exit 1.
d="$TMP/env-covered"; ewrite "$d" 5 4 10 1 0 1 "high|the gap|pending"
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && printf '%s\n' "$out" | grep -qE 'FAIL +envelope covered_blocks=5 != 2'; then
  ok "declared covered_blocks=5 vs 2 on-disk → FAIL exit 1"
else no "env-covered: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'covered_blocks' | head -1)"; fi

# 28 — blocked_open mismatch: envelope blocked_open=3 but only 1 '- ... needs:' entry → FAIL exit 1.
d="$TMP/env-blocked"; ewrite "$d" 0 4 10 1 0 3 "high|the gap|pending"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && printf '%s\n' "$out" | grep -qE 'FAIL +envelope blocked_open=3 != 1'; then
  ok "declared blocked_open=3 vs 1 actual → FAIL exit 1"
else no "env-blocked: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'blocked_open' | head -1)"; fi

# NEGATIVE CONTROL — prove CHECK 1 (the STALE detection) has TEETH via mutation.
if [ "${1:-}" = "--prove-teeth" ]; then
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
    if printf '%s\n' "$m2out" | grep -qE 'WARN.*disagrees with 0 block file'; then
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
    if ! printf '%s\n' "$m3out" | grep -qE 'contradictory coverage denominators'; then
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
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
