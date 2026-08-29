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
# runf <dir> [extra-args...]: run the SUT with additional flags (e.g. --focus <slug>), drop stderr.
runf(){ bash "$SUT" "$@" 2>/dev/null; }
# codef <dir> [extra-args...]: same but capture only the exit code.
codef(){ bash "$SUT" "$@" >/dev/null 2>&1; echo $?; }
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

# UF-indented-nonint — issue #126 item 2: `  undocumented_findings: seven` (indented, non-integer).
# env_field uses awk default FS (ignores leading whitespace) → e_uf="seven".  But the _uf_present probe
# anchored /^undocumented_findings:/ misses the indented form → _uf_present="" → CHECK-G at the not-int
# branch (guarded by _uf_present) never fires on unmodified SUT.  After fix (probe widened to
# /^[[:space:]]*undocumented_findings:/) the probe catches the indented form → FAIL exit 1.
d="$TMP/uf-indented-nonint"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n  undocumented_findings: seven\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && echo "$out" | grep -qE 'FAIL.*undocumented_findings'; then
  ok "UF-indented-nonint: '  undocumented_findings: seven' (indented non-int) → FAIL exit 1"
else no "UF-indented-nonint: exit $(code "$d") (want 1) :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# UF-pos-first — same but undocumented_findings is FIRST in the envelope (list-edges §7: FIRST position).
d="$TMP/uf-pos-first"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\n  undocumented_findings: seven\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
[ "$(code "$d")" = 1 ] && echo "$out" | grep -qE 'FAIL.*undocumented_findings' \
  && ok "UF-pos-first: '  undocumented_findings: seven' FIRST in envelope → FAIL (probe is position-independent)" \
  || no "UF-pos-first: exit $(code "$d") :: $(echo "$out" | grep -iE 'undocumented' | head -1)"

# UF-pos-middle — field in the MIDDLE of the envelope (list-edges §7: MIDDLE position).
d="$TMP/uf-pos-middle"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\n  undocumented_findings: seven\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
[ "$(code "$d")" = 1 ] && echo "$out" | grep -qE 'FAIL.*undocumented_findings' \
  && ok "UF-pos-middle: '  undocumented_findings: seven' MIDDLE in envelope → FAIL" \
  || no "UF-pos-middle: exit $(code "$d") :: $(echo "$out" | grep -iE 'undocumented' | head -1)"

# ---- P23: blocked/absent gaps missing a tried: clause (pi5 P23) --------------------------------
# When a gap under ## Blocked gaps or ## Non-investigable gaps has a `needs:` clause but no
# `tried:` clause, a WARN fires — absent-input gaps must document what alternatives were tried
# before they can be closed. This distinguishes absent-input (genuinely blocked) from untried.

# P23-warn — blocked entry with needs: but no tried: → WARN must fire, WARN-only (exit 0).
d="$TMP/p23-warn"
ewrite "$d" 0 3 5 1 0 1 "high|active gap|pending"   # ewrite always puts '- gpu profiling — needs: hardware'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qiE 'WARN.*tried:' <<<"$out"; then
  ok "P23: blocked gap with needs: but no tried: → WARN emitted, exit 0"
else no "P23-warn: exit $(code "$d") :: $(grep -iE 'WARN.*tried\|tried' <<<"$out" | head -1)"; fi

# P23-ok — blocked entry carries tried: → WARN must NOT fire.
d="$TMP/p23-ok"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 5 1 0 1 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 5 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | active gap | web | pending |'; echo
  echo '## Blocked gaps'
  echo '- gpu profiling — needs: hardware; tried: ssh probe (rejected: device offline)'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qiE 'WARN.*tried:' <<<"$out"; then
  ok "P23: blocked gap with tried: present → no WARN, exit 0"
else no "P23-ok: exit $(code "$d") :: $(grep -iE 'WARN.*tried\|tried' <<<"$out" | head -1)"; fi

# ---- P7: INDEX.md template placeholders while covered_blocks > 0 (pi5 P7) --------------------
# When INDEX.md in the corpus dir contains <UPPER-CASE> template placeholders while at least
# one block file is on disk (ondisk > 0), a WARN fires to prompt updating the corpus index.

# P7-warn — INDEX.md with <SUBJECT> placeholder, 1 block file on disk → WARN must fire (exit 0).
d="$TMP/p7-warn"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 1 0 3 1 0 0 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 0 / 3 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | gap A | web | pending |'; echo
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
printf '# <SUBJECT> — Corpus Index\n\nDate: <YYYY-MM-DD>\n' > "$d/INDEX.md"
printf '# Block 1\n' > "$d/t-block1.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qiE 'WARN.*INDEX\.md.*placeholder' <<<"$out"; then
  ok "P7: INDEX.md with <SUBJECT> placeholder + 1 block file → WARN emitted, exit 0"
else no "P7-warn: exit $(code "$d") :: $(grep -iE 'WARN.*INDEX\|INDEX.*WARN\|placeholder' <<<"$out" | head -1)"; fi

# P7-ok — INDEX.md without placeholders → WARN must NOT fire.
d="$TMP/p7-ok"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 1 0 3 1 0 0 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 0 / 3 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | gap A | web | pending |'; echo
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
printf '# Project Alpha — Corpus Index\n\nDate: 2026-07-28\n' > "$d/INDEX.md"
printf '# Block 1\n' > "$d/t-block1.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qiE 'WARN.*INDEX\.md.*placeholder' <<<"$out"; then
  ok "P7: INDEX.md without placeholders → no WARN, exit 0"
else no "P7-ok: exit $(code "$d") :: $(grep -iE 'WARN.*INDEX\|INDEX.*WARN\|placeholder' <<<"$out" | head -1)"; fi

# P7-fp — FALSE-POSITIVE GUARD: INDEX.md with legitimate <Uppercase-but-not-placeholder content
#   (<I and <Instruction> — no real all-caps template token) + 1 block file on disk → WARN must NOT fire.
#   RED before the fix: `<[A-Z]` matched `<I` (no closing >) and fired a spurious WARN.
#   The anchored fix requires a closing > and an all-caps/digits/underscores/hyphens body, so
#   `<Instruction text>` (mixed case) and `<I` (no >) are both silently passed over.
d="$TMP/p7-fp"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 1 0 3 1 0 0 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 0 / 3 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | gap A | web | pending |'; echo
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
printf '# Project Beta — Corpus Index\n\nThe grammar accepts <Instruction text>. Variable types include <I and <B markers.\n' > "$d/INDEX.md"
printf '# Block 1\n' > "$d/t-block1.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qiE 'WARN.*INDEX\.md.*placeholder' <<<"$out"; then
  ok "P7-fp: INDEX.md with <I/<Instruction (no all-caps placeholder) → no WARN, exit 0"
else no "P7-fp: exit $(code "$d") :: $(grep -iE 'WARN.*INDEX\|INDEX.*WARN\|placeholder' <<<"$out" | head -1)"; fi

# ========================= block_scope field (NR-A) =========================
# env_bs: emit envelope lines including block_scope as the 9th param (all 9 fields).
env_bs(){ printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: %s\ngaps_closed: %s\nknown_gaps: %s\ninvestigable_open: %s\nrequires_execution_open: %s\nblocked_open: %s\ndeferred_open: %s\nundocumented_findings: %s\nblock_scope: %s\n<!-- /research-state.v1 -->\n' "$@"; }

# BS-absent — REGRESSION GUARD: block_scope absent → per-focus behavior unchanged.
# Two focuses share a dir; focus-a has 2 blocks, focus-b has 2 blocks. State for focus-a declares
# covered_blocks=2 with NO block_scope field. Must pass BOTH before and after the NR-A change.
d="$TMP/bs-absent"; mkdir -p "$d"
printf 'x\n' > "$d/focus-a-block1.md"; printf 'x\n' > "$d/focus-a-block2.md"
printf 'x\n' > "$d/focus-b-block1.md"; printf 'x\n' > "$d/focus-b-block2.md"
{ echo '# Focus-A — Research State'; echo
  env10 2 0 0 0 0 0 0 0; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-focus-a.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "BS-absent: block_scope absent → per-focus (2 focus-a blocks counted not 4 total), exit 0"
else no "BS-absent: exit $(code "$d") :: $(grep -iE 'fail|ok ' <<<"$out" | head -1)"; fi

# BS-per-focus — block_scope: per-focus explicit → identical to absent.
d="$TMP/bs-perfocus"; mkdir -p "$d"
printf 'x\n' > "$d/focus-a-block1.md"; printf 'x\n' > "$d/focus-a-block2.md"
printf 'x\n' > "$d/focus-b-block1.md"; printf 'x\n' > "$d/focus-b-block2.md"
{ echo '# Focus-A — Research State'; echo
  env_bs 2 0 0 0 0 0 0 0 "per-focus"; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-focus-a.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "BS-per-focus: block_scope: per-focus → per-focus count (2 of 4 blocks), exit 0"
else no "BS-per-focus: exit $(code "$d") :: $(grep -iE 'fail|ok ' <<<"$out" | head -1)"; fi

# BS-global-ok — block_scope: shared-global, declared total == global on-disk count → PASSES.
# Corpus shares a single prefix (niagara-mental-model-bloque). RESEARCH-STATE-chihuahua.md claims
# covered_blocks=3 and declares block_scope: shared-global. CHECK A must compare against the global
# count (3), not the chihuahua-prefix count (0) → passes.
d="$TMP/bs-global-ok"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-mental-model-bloque1.md"
printf 'x\n' > "$d/niagara-mental-model-bloque2.md"
printf 'x\n' > "$d/niagara-mental-model-bloque3.md"
{ echo '# Chihuahua — Research State'; echo
  env_bs 3 0 0 0 0 0 0 0 "shared-global"; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-chihuahua.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "BS-global-ok: block_scope: shared-global, covered_blocks=3 == 3 global blocks → exit 0"
else no "BS-global-ok: exit $(code "$d") :: $(grep -iE 'fail|covered_blocks|ok ' <<<"$out" | head -1)"; fi

# BS-global-stale — block_scope: shared-global, declared != global count → FAILS (staleness check has teeth).
d="$TMP/bs-global-stale"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-mental-model-bloque1.md"
printf 'x\n' > "$d/niagara-mental-model-bloque2.md"
printf 'x\n' > "$d/niagara-mental-model-bloque3.md"
{ echo '# Chihuahua — Research State'; echo
  env_bs 10 0 0 0 0 0 0 0 "shared-global"; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-chihuahua.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*covered_blocks=10 != 3' <<<"$out"; then
  ok "BS-global-stale: block_scope: shared-global, covered_blocks=10 != 3 global → FAIL exit 1"
else no "BS-global-stale: exit $(code "$d") :: $(grep -iE 'fail|covered_blocks' <<<"$out" | head -1)"; fi

# BS-bogus — block_scope: bogus-value → FAILS with message naming both legal values.
# covered_blocks=0 and 0 blocks on disk → CHECK A is silent; only block_scope validation fires.
d="$TMP/bs-bogus"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env_bs 0 0 0 0 0 0 0 0 "bogus-value"; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-t.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*block_scope' <<<"$out" \
   && grep -q 'per-focus' <<<"$out" && grep -q 'shared-global' <<<"$out"; then
  ok "BS-bogus: block_scope: bogus-value → FAIL exit 1, message names both legal values"
else no "BS-bogus: exit $(code "$d") :: $(grep -iE 'block_scope' <<<"$out" | head -1)"; fi

# BS-empty — block_scope: (present but empty) → FAILS as malformed, NOT silently treated as absent.
# §7 three-state rule: absent (no line) ≠ empty (line exists, value missing).
d="$TMP/bs-empty"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope: \n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-t.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*block_scope' <<<"$out"; then
  ok "BS-empty: block_scope: (empty) → FAIL exit 1 (present+empty is malformed, not absent)"
else no "BS-empty: exit $(code "$d") :: $(grep -iE 'block_scope' <<<"$out" | head -1)"; fi

# BS-cannot-see — focus-filtered=0 while global > 0, block_scope absent → FAIL with distinguishing
# message naming block_scope: shared-global. NOT a bare '!= N block file(s)' message.
# Models the niagara defect: all focuses share niagara-mental-model-bloque; chihuahua- prefix=0.
d="$TMP/bs-cannot-see"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-mental-model-bloque1.md"
printf 'x\n' > "$d/niagara-mental-model-bloque2.md"
printf 'x\n' > "$d/niagara-mental-model-bloque3.md"
{ echo '# Chihuahua — Research State'; echo
  env10 3 0 0 0 0 0 0 0; echo   # covered_blocks=3, block_scope absent (→ per-focus, chihuahua- prefix)
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-chihuahua.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -q 'shared-global' <<<"$out" && ! grep -qE '!= [0-9]+ block file' <<<"$out"; then
  ok "BS-cannot-see: focus-prefix=0 while global=3 → FAIL with shared-global hint, not bare '!= N'"
else no "BS-cannot-see: exit $(code "$d") :: $(grep -iE 'shared-global\|!= ' <<<"$out" | head -1)"; fi

# BS-no-blocks — no block files at all (global=0 too) → standard FAIL, NO shared-global hint.
# Pair-control for BS-cannot-see: the two messages must be distinguishable.
d="$TMP/bs-no-blocks"; mkdir -p "$d"
{ echo '# Focus-X — Research State'; echo
  env10 5 0 0 0 0 0 0 0; echo   # covered_blocks=5, no block_scope, zero block files
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-x.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*covered_blocks=5' <<<"$out" && ! grep -q 'shared-global' <<<"$out"; then
  ok "BS-no-blocks: no block files at all (global=0) → standard FAIL, no shared-global hint"
else no "BS-no-blocks: exit $(code "$d") :: $(grep -iE 'fail.*covered_blocks\|shared-global' <<<"$out" | head -1)"; fi

# FOLLOW-UP 3: BS-indented — `  block_scope: shared-global` (leading spaces) must be detected as present.
# env_field uses whitespace split so it correctly reads the value; but the _bs_present probe anchored
# to /^block_scope:/ misses the indented form → treated as absent → per-focus path → ondisk=0 vs
# e_covered=3 → FAIL. After fixing the probe to /^[[:space:]]*block_scope:/, the presence is detected,
# shared-global path is taken, ondisk=3 → PASS.
d="$TMP/bs-indented"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-bloque1.md"; printf 'x\n' > "$d/niagara-bloque2.md"; printf 'x\n' > "$d/niagara-bloque3.md"
{ echo '# Chihuahua — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 3\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n  block_scope: shared-global\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-chihuahua.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "BS-indented: '  block_scope: shared-global' (indented) detected present → shared-global path, exit 0"
else no "BS-indented: exit $(code "$d") :: $(grep -iE 'fail|ok ' <<<"$out" | head -1)"; fi

# FOLLOW-UP 4: BS-nospace-msg — block_scope:shared-global (no space after colon) must FAIL and the
# message must name the no-space form (not just print '<empty>'). The exit-1 is already correct; the
# fix is message quality so the operator knows exactly what to fix.
d="$TMP/bs-nospace-msg"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope:shared-global\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-t.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qiE 'block_scope.*missing.space|missing.space.*block_scope|no.space.*block_scope|block_scope.*no.space|unparseable' <<<"$out"; then
  ok "BS-nospace-msg: block_scope:shared-global (no space) → FAIL exit 1 with message naming the no-space form"
else no "BS-nospace-msg: exit $(code "$d") :: $(grep -iE 'block_scope' <<<"$out" | head -1) (want FAIL + no-space message)"; fi

# BS-cannot-see-pass — issue #126 item 1: PASS-path WARN for the cannot-see conflation.
# covered_blocks=0 and focus-filtered ondisk=0 (CHECK A passes: 0==0) while _ondisk_global > 0.
# On unmodified SUT: CHECK A passes silently, exit 0 — no WARN fired.
# After fix: WARN names the global count and suggests block_scope: shared-global.
d="$TMP/bs-cannot-see-pass"; mkdir -p "$d"
printf 'x\n' > "$d/other-bloque1.md"   # _ondisk_global=1; focus 'x-' prefix yields 0 focus-filtered
{ echo '# X — Research State'; echo
  env10 0 0 0 0 0 0 0 0; echo   # covered_blocks=0, block_scope absent → per-focus, x- prefix
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-x.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'WARN.*covered_blocks=0' <<<"$out" && grep -q 'shared-global' <<<"$out"; then
  ok "BS-cannot-see-pass: covered_blocks=0=focus-filtered but 1 global block → WARN with shared-global hint, exit 0"
else no "BS-cannot-see-pass: exit $(code "$d") :: $(grep -iE 'warn\|covered_blocks' <<<"$out" | head -1) (want exit 0 + WARN)"; fi

# ====================== ISSUE #143 — unknown priority backlog parse check ========================
# Unknown priorities silently dropped; fix detects INVALID_PRIORITY sentinels and FAILs before
# any derivation runs. Suite-local helpers: build single-row bp fixtures and assert outcomes.
mk_vocab_fixture() {
  local d="$1" pval="$2" gdesc="$3" gtype="$4" gstatus="$5"; mkdir -p "$d"
  { echo '# T — Research State'; echo
    env10 0 0 1 0 0 0 0 0; echo
    echo '## Gap-backlog (prioritized)'
    echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
    echo "| $pval | $gdesc | $gtype | $gstatus |"; echo
    echo '## Blocked gaps'; echo '- none'
    echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
  } > "$d/RESEARCH-STATE.md"
}
chk_skip_ok() {  # expect exit 0 and no INVALID_PRIORITY/NOT FULLY PARSEABLE output
  local d="$1" msg="$2"; local out; out="$(run "$d")"
  if [ "$(code "$d")" = 0 ] && ! grep -qiE 'NOT FULLY PARSEABLE|INVALID_PRIORITY' <<<"$out"; then ok "$msg"
  else no "$msg — exit $(code "$d") :: $(grep -iE 'fail|parseable|invalid' <<<"$out" | head -1)"; fi
}
chk_skip_fail() {  # expect exit 1 and NOT FULLY PARSEABLE (invalid-base tests)
  local d="$1" msg="$2"; local out; out="$(run "$d")"
  if [ "$(code "$d")" = 1 ] && grep -qiE 'NOT FULLY PARSEABLE' <<<"$out"; then ok "$msg"
  else no "$msg — exit $(code "$d") (want 1) :: $(grep -iE 'fail|parseable|invalid' <<<"$out" | head -1)"; fi
}

# BP-fail — unknown priority 'critical', laundered io=0 → FAIL exit 1 with diagnostic.
# Core regression: WITHOUT the fix, verify-state PASSED (0==0) — laundred envelope silently accepted.
mk_vocab_fixture "$TMP/bp-fail" 'critical' 'firmware parsing' 'web' 'pending'
out="$(run "$TMP/bp-fail")"
if [ "$(code "$TMP/bp-fail")" = 1 ] && grep -qE 'FAIL' <<<"$out" && grep -qiE 'critical|unknown|unparse|backlog' <<<"$out"; then
  ok "BP-fail: unknown priority 'critical' (laundered io=0) → FAIL exit 1 with diagnostic"
else no "BP-fail: exit $(code "$TMP/bp-fail") (want 1) :: $(grep -iE 'fail|critical|ok ' <<<"$out" | head -2 | tr '\n' '|')"; fi

# BP-typo — typo 'hight' FAILs with diagnostic (not silently dropped).
mk_vocab_fixture "$TMP/bp-typo" 'hight' 'typo gap' 'web' 'pending'
out="$(run "$TMP/bp-typo")"
if [ "$(code "$TMP/bp-typo")" = 1 ] && grep -qE 'FAIL' <<<"$out" && grep -qiE 'hight|unknown|unparse|backlog' <<<"$out"; then
  ok "BP-typo: priority typo 'hight' → FAIL exit 1 (not silently dropped)"
else no "BP-typo: exit $(code "$TMP/bp-typo") (want 1) :: $(grep -iE 'fail|hight|ok ' <<<"$out" | head -2 | tr '\n' '|')"; fi

# BP-regression — valid priorities (high, medium, low) still pass after the fix (io=2).
d="$TMP/bp-regression"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env10 0 0 3 2 0 0 0 0; echo
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | gap-1 | web | pending |'
  echo '| medium | gap-2 | web | pending |'
  echo '| low | gap-3 | web | covered |'; echo
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 2'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "BP-regression: valid priorities (high, medium, low) still pass with the fix"
else no "BP-regression: exit $(code "$d") (want 0) :: $(grep -iE 'fail|ok ' <<<"$out" | head -1)"; fi

# BP-mixed — valid 'high' + 'critical' row → FAILS; laundered io=1 does NOT mask the unknown row.
d="$TMP/bp-mixed-vs"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env10 0 0 2 1 0 0 0 0; echo
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | valid gap | web | pending |'
  echo '| critical | firmware parsing | web | pending |'; echo
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL' <<<"$out" && grep -qiE 'critical|unknown|unparse|backlog' <<<"$out"; then
  ok "BP-mixed: 1 valid high + 1 critical → FAIL exit 1 (not silently routed around the invalid row)"
else no "BP-mixed: exit $(code "$d") (want 1) :: $(grep -iE 'fail|critical|ok ' <<<"$out" | head -2 | tr '\n' '|')"; fi

# BP-deferred — 'deferred' is NOT flagged (known non-investigable). Regression: fix must not false-alarm.
d="$TMP/bp-deferred"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env10 0 0 2 1 0 0 1 0; echo
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | active gap | web | pending |'
  echo '| deferred | parked gap | analysis | ⏸ deferred — operator decision |'; echo
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "BP-deferred: 'deferred' priority is NOT flagged as unknown (known non-investigable state)"
else no "BP-deferred: exit $(code "$d") (want 0) :: $(grep -iE 'fail|deferred|ok ' <<<"$out" | head -1)"; fi

# ---- Issue #143 corpus vocabulary: strikethrough / qualifier / em-dash skip forms ----
# Real-corpus forms excluded; qualifier forms emit a provisional WARN to stderr naming the stripped base.
# Invalid qualifier base still fails closed (not an escape hatch).

# BP-strikethrough — '~~high~~' silently skipped (nave-panccadia 24 rows, computadoras 8 rows).
mk_vocab_fixture "$TMP/bp-strikethrough" '~~high~~' 'resolved gap' 'web' '~~covered~~'
chk_skip_ok "$TMP/bp-strikethrough" "BP-strikethrough: '~~high~~' (strikethrough) silently skipped — NOT flagged"

# BP-qualifier — 'high (cross-vibra)' (valid-base qualifier) excluded (pruebas-dashboards 21, three.js 1).
mk_vocab_fixture "$TMP/bp-qualifier" 'high (cross-vibra)' 'vibra gap' 'web' 'pending (cross-vibra)'
chk_skip_ok "$TMP/bp-qualifier" "BP-qualifier: 'high (cross-vibra)' (valid-base qualifier) excluded — exit 0, no INVALID_PRIORITY"
# BP-qualifier-warn — same fixture: qualifier row must emit a provisional WARN to stderr naming stripped base 'high'.
warn_bpq="$(bash "$SUT" "$TMP/bp-qualifier" 2>&1 >/dev/null)"
grep -qE 'WARN.*non-conforming qualifier.*high' <<<"$warn_bpq" \
  && ok "BP-qualifier-warn: qualifier row emits WARN to stderr naming base 'high'" \
  || no "BP-qualifier-warn: no WARN emitted — got [$warn_bpq]"

# n!=4-warn — a backlog row with an in-cell pipe (n=5) must emit WARN to stderr, parity with status.sh:211.
d="$TMP/n4-warn"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env10 0 0 0 0 0 0 0 0; echo
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | compare A | B render paths | web | pending |'; echo
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
warn_n4="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
grep -qiE 'WARN.*malformed backlog row' <<<"$warn_n4" \
  && ok "n!=4-warn: in-cell-pipe row emits WARN to stderr (parity with status.sh)" \
  || no "n!=4-warn: no WARN on n!=4 row — got [$warn_n4]"

# BP-em-dash — '—' (em-dash placeholder) silently skipped (hifref 2 rows).
mk_vocab_fixture "$TMP/bp-em-dash" '—' 'placeholder' '—' '—'
chk_skip_ok "$TMP/bp-em-dash" "BP-em-dash: '—' (em-dash placeholder) silently skipped — NOT flagged"

# BP-qualifier-invalid — 'hight (cross-vibra)' invalid base → fails closed. Not an escape hatch.
mk_vocab_fixture "$TMP/bp-qualifier-invalid" 'hight (cross-vibra)' 'typo gap' 'web' 'pending'
chk_skip_fail "$TMP/bp-qualifier-invalid" "BP-qualifier-invalid: 'hight (cross-vibra)' (invalid base) fails closed — qualifier is not an escape hatch"

# NM-space — near-miss '## Gap backlog' (space instead of hyphen) → WARN on stderr from _backlog_rows.
d="$TMP/nm-space"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env_lines 0 0 0 0 0 0; echo
  echo '## Gap backlog'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | g1 | web | pending |'; echo
  echo '## Blocked gaps'; echo '- none'; echo
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
nm_warn_vs="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
grep -qi 'near-miss' <<<"$nm_warn_vs" \
  && ok "NM-space: '## Gap backlog' → near-miss WARN on stderr from _backlog_rows" \
  || no "NM-space: '## Gap backlog' — no WARN (got: $nm_warn_vs)"

# NM-noparens — near-miss '## Gap-backlog prioritized' (text outside parens) → WARN on stderr
d="$TMP/nm-noparens"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env_lines 0 0 0 0 0 0; echo
  echo '## Gap-backlog prioritized'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | g1 | web | pending |'; echo
  echo '## Blocked gaps'; echo '- none'; echo
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
nm_warn_np="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
grep -qi 'near-miss' <<<"$nm_warn_np" \
  && ok "NM-noparens: '## Gap-backlog prioritized' → near-miss WARN on stderr" \
  || no "NM-noparens: '## Gap-backlog prioritized' — no WARN (got: $nm_warn_np)"

# NM-canonical — '## Gap-backlog (prioritized)' canonical form → NO near-miss WARN (happy-path regression guard)
d="$TMP/nm-canonical"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env_lines 0 0 0 1 0 0; echo
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | real gap | web | pending |'; echo
  echo '## Blocked gaps'; echo '- none'; echo
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
nm_warn_can="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
! grep -qi 'near-miss' <<<"$nm_warn_can" \
  && ok "NM-canonical: '## Gap-backlog (prioritized)' → no near-miss WARN" \
  || no "NM-canonical: canonical form falsely warned: [$nm_warn_can]"

# NM-blocked-fp — '## Blocked gaps' must NOT trigger near-miss WARN (false-positive guard)
d="$TMP/nm-blocked-fp"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env_lines 0 0 0 1 0 0; echo
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | real gap | web | pending |'; echo
  echo '## Blocked gaps'; echo '- none'; echo
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
nm_warn_blk="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
! grep -qi 'near-miss' <<<"$nm_warn_blk" \
  && ok "NM-blocked-fp: '## Blocked gaps' → no near-miss WARN (false-positive guard)" \
  || no "NM-blocked-fp: '## Blocked gaps' falsely triggered near-miss: [$nm_warn_blk]"

# ============================ FOCUS SCOPING (--focus <slug>) ============================
# Cases F1–F4 verify the --focus <slug> interface added to verify-state.sh.
# Without --focus the script lints every RESEARCH-STATE*.md; with --focus it lints ONLY the one
# file matching RESEARCH-STATE-<slug>.md, suppressing noise from unrelated focuses.
# §7 three-state rule: absent-focus (no such file, exit 2) ≠ exists-but-thin (linted, exit 1/0)
# ≠ no-state-files-at-all (already covered by case 2 in this suite).
#
# PRE-FIX RED check (MANDATORY per strict-TDD): each new test is run against the pre-fix SUT
# (a64b316:verify-state.sh) in the prove-teeth section below to confirm it goes RED for the right
# reason. The right reason is always: pre-fix ignores --focus, lints all files.

# F1 — --focus slug on a two-file consistent corpus → lints ONLY the selected file.
#      Exactly 1 "== verify-state:" header in output; exit 0 when selected focus is consistent.
#      RED before fix: pre-fix ignores --focus, lints both → 2 headers → assertion fails.
d="$TMP/focus-single-hit"; mkdir -p "$d"
{ echo '# Database — Research State'; echo
  env_lines 0 5 5 0 0 0; echo
  echo 'coverage metric: 5 / 5 gaps closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
} > "$d/RESEARCH-STATE-database.md"
{ echo '# Email — Research State'; echo
  env_lines 0 3 3 0 0 0; echo
  echo 'coverage metric: 3 / 3 gaps closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
} > "$d/RESEARCH-STATE-email.md"
out="$(runf "$d" --focus database)"
if [ "$(codef "$d" --focus database)" = 0 ] \
   && grep -c '== verify-state:' <<<"$out" | grep -q '^1$'; then
  ok "F1 --focus database: lints ONLY RESEARCH-STATE-database.md (1 header, exit 0)"
else no "F1 --focus: exit=$(codef "$d" --focus database) headers=$(grep -c '== verify-state:' <<<"$out" || true) (want exit 0, 1 header)"; fi

# F2 — --focus slug with NO matching file → exit 2 (absent-focus), actionable message.
#      §7: DISTINCT from "no RESEARCH-STATE*.md at all" — the dir HAS email, just not the slug.
#      RED before fix: pre-fix ignores --focus, lints email (consistent) → exit 0 → test expects exit 2.
d="$TMP/focus-absent"; mkdir -p "$d"
{ echo '# Email — Research State'; echo
  env_lines 0 3 3 0 0 0; echo
  echo 'coverage metric: 3 / 3 gaps closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
} > "$d/RESEARCH-STATE-email.md"
f2_msg="$(bash "$SUT" "$d" --focus database 2>&1 >/dev/null)"
if [ "$(codef "$d" --focus database)" = 2 ] \
   && grep -q 'RESEARCH-STATE-database\.md' <<<"$f2_msg"; then
  ok "F2 --focus database (no matching file) → exit 2 + actionable absent-focus message"
else no "F2: exit=$(codef "$d" --focus database) msg=$(printf '%s' "$f2_msg" | head -1) (want exit 2 + filename)"; fi

# F2b — §7 three-state: absent-focus (exit 2) ≠ exists-but-thin (reaches lint, NOT exit 2).
#       Dir has RESEARCH-STATE-database.md (thin, no envelope → lint FAIL → exit 1) + email (consistent).
#       Assertions: (a) exit is NOT 2, (b) exactly 1 header (focused on database only).
#       RED before fix: pre-fix lints BOTH → 2 headers → assertion (b) fails for the right reason.
d="$TMP/focus-thin-match"; mkdir -p "$d"
{ echo '# Database — Research State'
  echo 'coverage metric: 5 / 5 gaps closed'
  echo '## Gap-backlog'; echo '- gap done'
} > "$d/RESEARCH-STATE-database.md"   # no envelope → lint FAIL, but the FILE EXISTS
{ echo '# Email — Research State'; echo
  env_lines 0 3 3 0 0 0; echo
  echo 'coverage metric: 3 / 3 gaps closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
} > "$d/RESEARCH-STATE-email.md"
f2b_rc="$(codef "$d" --focus database)"
f2b_out="$(runf "$d" --focus database)"
if [ "$f2b_rc" != 2 ] \
   && grep -c '== verify-state:' <<<"$f2b_out" | grep -q '^1$'; then
  ok "F2b --focus thin-match: file EXISTS → NOT exit 2 (exit $f2b_rc), 1 header (absent-focus ≠ thin-exists)"
else no "F2b: exit=$f2b_rc headers=$(grep -c '== verify-state:' <<<"$f2b_out" || true) (want exit!=2, 1 header)"; fi

# F3 — Noise suppression: multi-focus corpus; ONLY email stale; --focus database → exit 0, no FAIL noise.
#      This is the load-bearing case: proves the stale sibling is fully suppressed.
#      RED before fix: pre-fix lints both → email STALE fires exit 1 with FAIL/PREMATURE STOP.
d="$TMP/focus-noise-suppress"; mkdir -p "$d"
{ echo '# Database — Research State'; echo
  env_lines 0 5 5 0 0 0; echo
  echo 'coverage metric: 5 / 5 gaps closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
} > "$d/RESEARCH-STATE-database.md"
{ echo '# Email — Research State'; echo
  env_lines 0 0 23 2 0 0; echo
  echo 'coverage metric: 23 / 23 declared gaps closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | gap A | web | pending |'
  echo '| high | gap B | web | pending |'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 2'
} > "$d/RESEARCH-STATE-email.md"
out="$(runf "$d" --focus database)"
if [ "$(codef "$d" --focus database)" = 0 ] && ! grep -qE 'FAIL|PREMATURE STOP' <<<"$out"; then
  ok "F3 --focus database: stale email suppressed → exit 0, no FAIL/PREMATURE STOP in output"
else no "F3: exit=$(codef "$d" --focus database) FAIL=$(grep -cE 'FAIL|PREMATURE' <<<"$out" || true) (want exit 0, no FAIL noise)"; fi

# F4 — --focus with no slug arg → exit 2 (usage error), distinct from absent-focus.
#      Uses a dir with a consistent state file so pre-fix (ignoring --focus) exits 0.
#      RED before fix: pre-fix ignores --focus, lints consistent file → exit 0 → test expects exit 2.
d="$TMP/focus-no-slug"; mkdir -p "$d"
{ echo '# Database — Research State'; echo
  env_lines 0 5 5 0 0 0; echo
  echo 'coverage metric: 5 / 5 gaps closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
} > "$d/RESEARCH-STATE-database.md"
if [ "$(codef "$d" --focus)" = 2 ]; then
  ok "F4 --focus (no slug) → exit 2 (usage error)"
else no "F4: exit=$(codef "$d" --focus) (want 2 — usage error when slug missing)"; fi

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

  # ---- P23 mutation: neuter the tried: gate; the missing-tried fixture must stop WARNing ----
  echo "-- teeth-P23: neuter P23-MISSING-TRIED-WARN; needs:/no-tried: fixture must NOT WARN --"
  mutantP23="$TMP/verify-state.P23.MUTANT.sh"
  if grep -q '# P23-MISSING-TRIED-WARN' "$SUT"; then
    sed '/# P23-MISSING-TRIED-WARN/ s/.*/  if false; then  # P23-MISSING-TRIED-WARN [NEUTERED]/' "$SUT" > "$mutantP23"
    cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
    d="$TMP/p23-warn"   # reuse P23-warn fixture (ewrite: blocked entry with needs: but no tried:)
    mp23out="$(bash "$mutantP23" "$d" 2>/dev/null)"
    if ! grep -qiE 'WARN.*tried:' <<<"$mp23out"; then
      ok "teeth-P23: neutered gate → missing-tried fixture emits NO WARN (P23-warn has teeth)"
    else
      no "teeth-P23: neutered mutant STILL emits tried: WARN → P23 assertion is THEATER"
    fi
  else
    no "teeth-P23: P23-MISSING-TRIED-WARN sentinel not found in SUT (P23 not implemented or marker missing)"
  fi

  # ---- P7 mutation: neuter the INDEX.md placeholder check; placeholder fixture must stop WARNing ----
  echo "-- teeth-P7: neuter P7-INDEX-PLACEHOLDER-WARN; INDEX.md-placeholder fixture must NOT WARN --"
  mutantP7="$TMP/verify-state.P7.MUTANT.sh"
  if grep -q '# P7-INDEX-PLACEHOLDER-WARN' "$SUT"; then
    sed '/# P7-INDEX-PLACEHOLDER-WARN/ s/.*/    if false; then  # P7-INDEX-PLACEHOLDER-WARN [NEUTERED]/' "$SUT" > "$mutantP7"
    d="$TMP/p7-warn"   # reuse P7-warn fixture (INDEX.md with <SUBJECT> placeholder + 1 block file)
    mp7out="$(bash "$mutantP7" "$d" 2>/dev/null)"
    if ! grep -qiE 'WARN.*INDEX\.md.*placeholder' <<<"$mp7out"; then
      ok "teeth-P7: neutered gate → INDEX.md-placeholder fixture emits NO WARN (P7-warn has teeth)"
    else
      no "teeth-P7: neutered mutant STILL emits placeholder WARN → P7 assertion is THEATER"
    fi
  else
    no "teeth-P7: P7-INDEX-PLACEHOLDER-WARN sentinel not found in SUT (P7 not implemented or marker missing)"
  fi

  # ---- P7-fp mutation: revert P7 regex to <[A-Z]; the <I/<Instruction fixture must false-WARN ----
  # Proves the closing-'>' + all-caps anchor is load-bearing: dropping it makes the FP fixture trigger.
  echo "-- teeth-P7-fp: revert P7 regex to <[A-Z]; <I/<Instruction fixture must false-WARN (anchor load-bearing) --"
  mutantP7fp="$TMP/verify-state.P7fp.MUTANT.sh"
  sed 's/<\[A-Z\]\[A-Z0-9_-\]\*>/<[A-Z]/' "$SUT" > "$mutantP7fp"
  d="$TMP/p7-fp"   # reuse P7-fp fixture (INDEX.md with <I/<Instruction — no real placeholder)
  mp7fpout="$(bash "$mutantP7fp" "$d" 2>/dev/null)"
  if grep -qiE 'WARN.*INDEX\.md.*placeholder' <<<"$mp7fpout"; then
    ok "teeth-P7-fp: reverted regex → <I/<Instruction fixture false-WARNs (anchor is load-bearing)"
  else
    no "teeth-P7-fp: reverted regex does NOT false-WARN on <I/<Instruction content → anchor may be theater"
  fi

  # ---- block_scope (NR-A) mutation controls ----
  # Restore the real lib (P23 already did this, but be explicit for clarity).
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"

  # BS-absent + BS-per-focus mutation: neuter derive_focus_prefix → all blocks counted (4 vs declared 2).
  echo "-- teeth-BS-absent: neuter derive_focus_prefix; 4 total blocks vs declared 2 → FAIL (has teeth) --"
  sed 's/^  derive_focus_prefix() {$/  derive_focus_prefix() { return 0  # MUTANT-BSABSENT/' "$FPLIB" > "$TMP/lib/focus-prefix.sh"
  mutantBSA="$TMP/verify-state.BSABSENT.MUTANT.sh"; cp "$SUT" "$mutantBSA"
  d="$TMP/bs-absent"
  bash "$mutantBSA" "$d" >/dev/null 2>&1; mbsagot=$?
  if [ "$mbsagot" = 1 ]; then
    ok "teeth-BS-absent: neutered prefix mutant → 4 blocks vs declared 2 → FAIL → BS-absent has teeth"
  else no "teeth-BS-absent: mutant exit $mbsagot (want 1) → BS-absent may not depend on focus-prefix (THEATER)"; fi

  echo "-- teeth-BS-per-focus: same mutant on bs-perfocus fixture; explicit per-focus also depends on prefix --"
  d="$TMP/bs-perfocus"
  bash "$mutantBSA" "$d" >/dev/null 2>&1; mbspfgot=$?
  if [ "$mbspfgot" = 1 ]; then
    ok "teeth-BS-per-focus: neutered prefix mutant → 4 blocks vs declared 2 → FAIL → BS-per-focus has teeth"
  else no "teeth-BS-per-focus: mutant exit $mbspfgot (want 1) → BS-per-focus may not depend on focus-prefix (THEATER)"; fi
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"   # restore

  # BS-global-ok mutation: replace ondisk="$_ondisk_global" with ondisk="0" (sentinel BS-SHARED-GLOBAL-ONDISK).
  # shared-global fixture (covered_blocks=3, 3 global blocks) must then FAIL (3 ≠ 0).
  echo "-- teeth-BS-global-ok: force ondisk=0 for shared-global; covered_blocks=3 vs 0 must FAIL --"
  mutantBSGO="$TMP/verify-state.BSGLOBALOK.MUTANT.sh"
  sed 's/ondisk="\$_ondisk_global"  # BS-SHARED-GLOBAL-ONDISK/ondisk="0"  # MUTANT-BSGO/' "$SUT" > "$mutantBSGO"
  if ! grep -q 'MUTANT-BSGO' "$mutantBSGO"; then
    no "teeth-BS-global-ok: could not build mutant (BS-SHARED-GLOBAL-ONDISK sentinel not found — did SUT change?)"
  else
    d="$TMP/bs-global-ok"
    bash "$mutantBSGO" "$d" >/dev/null 2>&1; mbsgogot=$?
    if [ "$mbsgogot" = 1 ]; then
      ok "teeth-BS-global-ok: ondisk=0 mutant → covered_blocks=3 ≠ 0 → FAIL → BS-global-ok has teeth"
    else no "teeth-BS-global-ok: mutant exit $mbsgogot (want 1) → shared-global ondisk selection not load-bearing (THEATER)"; fi
  fi

  # BS-global-stale mutation: neuter CHECK A → declared 10 vs 3 global undetected → exit 0.
  echo "-- teeth-BS-global-stale: neuter CHECK A; covered_blocks=10 vs 3 must stop FAILing --"
  mutantBSGS="$TMP/verify-state.BSGLOBALSTALE.MUTANT.sh"
  sed 's/^\(  if ! is_int "\$e_covered" || \[ "\$e_covered" != "\$ondisk" \]; then\)$/  if false; then  # MUTANT-BSGS/' "$SUT" > "$mutantBSGS"
  if ! grep -q 'MUTANT-BSGS' "$mutantBSGS"; then
    no "teeth-BS-global-stale: could not build mutant (CHECK A guard line not found — did SUT change?)"
  else
    d="$TMP/bs-global-stale"
    bash "$mutantBSGS" "$d" >/dev/null 2>&1; mbsgsgot=$?
    if [ "$mbsgsgot" = 0 ]; then
      ok "teeth-BS-global-stale: CHECK A neutered → 10 vs 3 undetected (exit 0) → BS-global-stale has teeth"
    else no "teeth-BS-global-stale: mutant exit $mbsgsgot (want 0) → BS-global-stale does not depend on CHECK A (THEATER)"; fi
  fi

  # BS-bogus + BS-empty mutation: neuter block_scope validation (sentinel BS-BLOCK_SCOPE-VALIDATE).
  # bogus-value and empty value must then exit 0 instead of 1.
  echo "-- teeth-BS-bogus: neuter block_scope validation; bogus-value must stop FAILing --"
  mutantBSVAL="$TMP/verify-state.BSVALIDATE.MUTANT.sh"
  if grep -q '# BS-BLOCK_SCOPE-VALIDATE' "$SUT"; then
    sed '/# BS-BLOCK_SCOPE-VALIDATE/ s/.*if ! _validate_block_scope.*/  if false; then  # MUTANT-BSVAL/' "$SUT" > "$mutantBSVAL"
    d="$TMP/bs-bogus"
    bash "$mutantBSVAL" "$d" >/dev/null 2>&1; mbsbgot=$?
    if [ "$mbsbgot" = 0 ]; then
      ok "teeth-BS-bogus: neutered validation → bogus-value exits 0 → BS-bogus has teeth"
    else no "teeth-BS-bogus: mutant exit $mbsbgot (want 0) → BS-bogus does not depend on block_scope validation (THEATER)"; fi

    echo "-- teeth-BS-empty: same mutant on bs-empty fixture; empty value also depends on validation --"
    d="$TMP/bs-empty"
    bash "$mutantBSVAL" "$d" >/dev/null 2>&1; mbsegot=$?
    if [ "$mbsegot" = 0 ]; then
      ok "teeth-BS-empty: neutered validation → empty value exits 0 → BS-empty has teeth"
    else no "teeth-BS-empty: mutant exit $mbsegot (want 0) → BS-empty does not depend on block_scope validation (THEATER)"; fi
  else
    no "teeth-BS-bogus: BS-BLOCK_SCOPE-VALIDATE sentinel not found in SUT (block_scope validation not implemented)"
    no "teeth-BS-empty: BS-BLOCK_SCOPE-VALIDATE sentinel not found in SUT (block_scope validation not implemented)"
  fi

  # BS-cannot-see mutation: neuter the distinguishing condition (sentinel BS-CANNOT-SEE-COND).
  # The bs-cannot-see fixture must then emit the standard message (no shared-global hint) → test fails.
  echo "-- teeth-BS-cannot-see: neuter the cannot-see distinguishing condition; standard message must fire --"
  mutantBSCS="$TMP/verify-state.BSCANNOTSEE.MUTANT.sh"
  if grep -q '# BS-CANNOT-SEE-COND' "$SUT"; then
    sed 's/^    if \[ -n "\$_fpfx" \].*# BS-CANNOT-SEE-COND$/    if false; then  # MUTANT-BSCS/' "$SUT" > "$mutantBSCS"
    d="$TMP/bs-cannot-see"
    mbcsout="$(bash "$mutantBSCS" "$d" 2>/dev/null)"
    if ! grep -q 'shared-global' <<<"$mbcsout"; then
      ok "teeth-BS-cannot-see: neutered condition → standard message (no shared-global hint) → BS-cannot-see has teeth"
    else no "teeth-BS-cannot-see: mutant STILL emits shared-global hint → BS-cannot-see assertion is THEATER"; fi
  else
    no "teeth-BS-cannot-see: BS-CANNOT-SEE-COND sentinel not found in SUT (cannot-see logic not implemented)"
  fi

  # BS-no-blocks mutation: change _ondisk_global -gt 0 to -ge 0 → condition fires even when global=0.
  # bs-no-blocks fixture (global=0) must then emit the shared-global hint → test fails ('shared-global' appears).
  echo "-- teeth-BS-no-blocks: relax _ondisk_global guard to -ge 0; global=0 fixture must now emit shared-global hint --"
  mutantBSNB="$TMP/verify-state.BSNOBLOCKS.MUTANT.sh"
  sed 's/\[ "\${_ondisk_global:-0}" -gt 0 \]/[ "${_ondisk_global:-0}" -ge 0 ]/' "$SUT" > "$mutantBSNB"
  if ! grep -q '"\${_ondisk_global:-0}" -ge 0' "$mutantBSNB"; then
    no "teeth-BS-no-blocks: could not build mutant (_ondisk_global -gt 0 pattern not found — did SUT change?)"
  else
    d="$TMP/bs-no-blocks"
    mbnbout="$(bash "$mutantBSNB" "$d" 2>/dev/null)"
    if grep -q 'shared-global' <<<"$mbnbout"; then
      ok "teeth-BS-no-blocks: relaxed guard → global=0 emits shared-global hint → BS-no-blocks has teeth"
    else no "teeth-BS-no-blocks: mutant did NOT emit shared-global hint → BS-no-blocks may not depend on global guard (THEATER)"; fi
  fi

  # ---- FOLLOW-UP 3 mutation: neuter the whitespace-tolerant probe (sentinel BS-INDENTED-PROBE) ----
  # BS-indented fixture (  block_scope: shared-global) must then report _bs_present="" → per-focus path
  # → ondisk=0 vs e_covered=3 → FAIL (exit 1), proving the whitespace-tolerant probe is load-bearing.
  echo "-- teeth-BS-indented: neuter BS-INDENTED-PROBE; indented form must be missed → FAIL --"
  mutantBSI="$TMP/verify-state.BSINDENTED.MUTANT.sh"
  sed '/# BS-INDENTED-PROBE$/s/_bs_present=.*/_bs_present=""  # MUTANT-BSI: probe neutered/' "$SUT" > "$mutantBSI"
  if ! grep -q 'MUTANT-BSI' "$mutantBSI"; then
    no "teeth-BS-indented: could not build mutant (BS-INDENTED-PROBE sentinel not found — did SUT change?)"
  else
    d="$TMP/bs-indented"
    bash "$mutantBSI" "$d" >/dev/null 2>&1; mbsigot=$?
    if [ "$mbsigot" = 1 ]; then
      ok "teeth-BS-indented: neutered probe → indented form missed → FAIL (exit 1) → BS-indented has teeth"
    else no "teeth-BS-indented: mutant exit $mbsigot (want 1) — indented probe not exercised (THEATER)"; fi
  fi

  # ---- FOLLOW-UP 4 mutation: replace 'unparseable' message branch with the old '<empty>' text ----
  echo "-- teeth-BS-nospace-msg: old '<empty>' message; 'unparseable' check must miss --"
  mutantBSNS="$TMP/verify-state.BSNOSPACE.MUTANT.sh"
  sed 's/envelope block_scope is present but unparseable.*/envelope block_scope=<empty> is not a legal value — must be '"'"'per-focus'"'"' or '"'"'shared-global'"'"'/' "$SUT" > "$mutantBSNS"
  if ! grep -q 'block_scope=<empty>' "$mutantBSNS"; then
    no "teeth-BS-nospace-msg: could not build mutant (unparseable message line not found — did SUT change?)"
  else
    d="$TMP/bs-nospace-msg"
    mbnsout="$(bash "$mutantBSNS" "$d" 2>/dev/null)"
    if ! grep -qiE 'unparseable|missing.space|no.space' <<<"$mbnsout"; then
      ok "teeth-BS-nospace-msg: old message → 'unparseable' check fails → BS-nospace-msg wording is load-bearing"
    else no "teeth-BS-nospace-msg: reverted mutant STILL has the improved message — assertion is THEATER"; fi
  fi

  # ---- ISSUE #126 mutation controls ----------------------------------------------------------------

  # (i) teeth-BS-cannot-see-pass-global: override _ondisk_global to 0 → item-1 WARN must stop firing.
  # The bs-cannot-see-pass fixture (global=1 from other-bloque1.md) has the WARN fire on real SUT.
  # With _ondisk_global=0, condition (_ondisk_global > 0) is FALSE → WARN silent. CHECK A stays green
  # (exit 0): e_covered=0 == ondisk=0 → no FAIL. Proves the WARN reads the global count.
  echo "-- teeth-BS-cannot-see-pass-global: zero _ondisk_global via sentinel; WARN must stop --"
  mutantBGC="$TMP/verify-state.BGC.MUTANT.sh"
  if grep -q '# BS-ONDISK-GLOBAL-COMPUTED' "$SUT"; then
    sed 's/^  : # BS-ONDISK-GLOBAL-COMPUTED.*$/  _ondisk_global="0"  # MUTANT-BGC: override to 0/' "$SUT" > "$mutantBGC"
    cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
    d="$TMP/bs-cannot-see-pass"
    mbgcout="$(bash "$mutantBGC" "$d" 2>/dev/null)"; mbgcrc=$?
    if [ "$mbgcrc" = 0 ] && ! grep -qE 'WARN.*covered_blocks' <<<"$mbgcout"; then
      ok "teeth-BS-cannot-see-pass-global: zeroed _ondisk_global → WARN silent, exit 0 — item-1 WARN reads global count"
    else no "teeth-BS-cannot-see-pass-global: rc=$mbgcrc WARN=$(grep -E 'WARN' <<<"$mbgcout" | head -1) — THEATER or CHECK A broken"; fi
  else
    no "teeth-BS-cannot-see-pass-global: BS-ONDISK-GLOBAL-COMPUTED sentinel not found in SUT"
  fi

  # (ii) teeth-UF-indented-probe: neuter UF-INDENTED-PROBE sentinel → indented non-int must go silent.
  # UF-indented-nonint fixture uses '  undocumented_findings: seven'. On real SUT: _uf_present non-empty
  # → CHECK-G FAIL fires (exit 1). Mutant sets _uf_present="" → FAIL silenced, exit 0 → test goes red.
  echo "-- teeth-UF-indented-probe: neuter UF-INDENTED-PROBE; indented non-int must not FAIL --"
  mutantUFI="$TMP/verify-state.UFI.MUTANT.sh"
  if grep -q '# UF-INDENTED-PROBE' "$SUT"; then
    sed '/# UF-INDENTED-PROBE$/s/_uf_present=.*/_uf_present=""  # MUTANT-UFI: probe neutered/' "$SUT" > "$mutantUFI"
    cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
    d="$TMP/uf-indented-nonint"
    bash "$mutantUFI" "$d" >/dev/null 2>&1; mufigot=$?
    if [ "$mufigot" = 0 ]; then
      ok "teeth-UF-indented-probe: neutered probe → indented non-int exits 0 (FAIL silenced) — UF-indented-nonint has teeth"
    else no "teeth-UF-indented-probe: mutant exit $mufigot (want 0) — neutering did not silence FAIL (THEATER)"; fi
  else
    no "teeth-UF-indented-probe: UF-INDENTED-PROBE sentinel not found in SUT"
  fi

  # (iii) teeth-BS-cannot-see-pass-guard: replace PASS-path guard with if-false → WARN must stop firing.
  # BS-cannot-see-pass fixture: on real SUT WARN fires (exit 0 with WARN). Mutant: if-false → silent.
  echo "-- teeth-BS-cannot-see-pass-guard: if-false mutant; PASS-path WARN must go silent --"
  mutantBCSP="$TMP/verify-state.BCSP.MUTANT.sh"
  if grep -q '# BS-CANNOT-SEE-PASS' "$SUT"; then
    sed 's/^  if is_int.*# BS-CANNOT-SEE-PASS$/  if false; then  # MUTANT-BCSP/' "$SUT" > "$mutantBCSP"
    cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
    d="$TMP/bs-cannot-see-pass"
    mbcspout="$(bash "$mutantBCSP" "$d" 2>/dev/null)"; mbcsprc=$?
    if [ "$mbcsprc" = 0 ] && ! grep -qE 'WARN.*covered_blocks' <<<"$mbcspout"; then
      ok "teeth-BS-cannot-see-pass-guard: if-false → WARN silent, exit 0 — PASS-path guard is load-bearing"
    else no "teeth-BS-cannot-see-pass-guard: rc=$mbcsprc WARN=$(grep -E 'WARN' <<<"$mbcspout" | head -1) — THEATER"; fi
  else
    no "teeth-BS-cannot-see-pass-guard: BS-CANNOT-SEE-PASS sentinel not found in SUT"
  fi

  # Suite-local helper: build a SUT mutant via sed, copy FPLIB, run fixture, assert exit == EXPECT.
  cnt_occ() { awk -v n="$1" 'BEGIN{c=0}{s=$0;while((p=index(s,n))>0){c++;s=substr(s,p+length(n))}}END{print c}' "$2"; }
  printf 'no match\n'                         > "$TMP/cnt-proof.txt"; _cp0="$(cnt_occ "BPSKIP-X" "$TMP/cnt-proof.txt")"
  printf 'BPSKIP-X once\n'                    > "$TMP/cnt-proof.txt"; _cp1="$(cnt_occ "BPSKIP-X" "$TMP/cnt-proof.txt")"
  printf 'BPSKIP-X and BPSKIP-X same line\n' > "$TMP/cnt-proof.txt"; _cp2="$(cnt_occ "BPSKIP-X" "$TMP/cnt-proof.txt")"
  [ "$_cp0" = 0 ] && [ "$_cp1" = 1 ] && [ "$_cp2" = 2 ] && ok "cnt_occ: 0/1/2 same-line → 0/1/2 (self-proof)" || no "cnt_occ: proof failed (0=$_cp0 1=$_cp1 2=$_cp2)"
  chk_bpskip_tooth() {
    local label="$1" marker="$2" sedexpr="$3" fixdir="$4" expect="${5:-1}"
    local mutant="$TMP/verify-state.${label}.MUTANT.sh"
    echo "-- teeth-BP-${label}: neuter ${label} skip; fixture must exit ${expect} --"
    local mc; mc="$(cnt_occ "$marker" "$SUT")"
    [ "$mc" = 1 ] || { no "teeth-BP-${label}: anchor found $mc times in SUT (want exactly 1)"; return; }
    sed "$sedexpr" "$SUT" > "$mutant"; cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
    local sut_h mutant_h
    sut_h="$(md5sum "$SUT" | cut -d' ' -f1)"; mutant_h="$(md5sum "$mutant" | cut -d' ' -f1)"
    [ "$sut_h" != "$mutant_h" ] || { no "teeth-BP-${label}: sed no-op — mutant == SUT — recipe not applied"; return; }
    bash "$mutant" "$fixdir" >/dev/null 2>&1; local got=$?
    [ "$got" = "$expect" ] \
      && ok "teeth-BP-${label}: neutered guard exits ${expect} — ${label} skip is load-bearing" \
      || no "teeth-BP-${label}: mutant exit $got (want $expect) — THEATER"
  }

  # teeth-BP-parse-check: BP-fail fixture (laundered io=0) must false-pass — check is load-bearing.
  chk_bpskip_tooth "BP-parse-check" "# BP-INVALID-PRIORITY-FAIL" \
    's/if \[ -n "\$_bparse_invalid" \]; then  # BP-INVALID-PRIORITY-FAIL/if false; then  # MUTANT-BP/' \
    "$TMP/bp-fail" 0

  # Corpus vocabulary teeth: removing a skip makes fixture exit 1; invalid-base tested in reverse.
  chk_bpskip_tooth "strikethrough" "BPSKIP-STRIKETHROUGH" '/BPSKIP-STRIKETHROUGH/s/if (p~/if (0 ~/' "$TMP/bp-strikethrough" 1
  chk_bpskip_tooth "em-dash"       "BPSKIP-EMDASH"        '/BPSKIP-EMDASH/s/if (p~/if (0 ~/'        "$TMP/bp-em-dash"       1
  chk_bpskip_tooth "qualifier"     "BPSKIP-QUALIFIER"      '/BPSKIP-QUALIFIER/s/if (base != p)/if (0)/' "$TMP/bp-qualifier" 1
  # teeth-BP-qualifier-warn: remove BP-QUALIFIER-WARN line → BP-qualifier-warn must go red (no WARN emitted).
  echo "-- teeth-BP-qualifier-warn: remove WARN print; qualifier fixture must emit no WARN --"
  bpqw_mutant="$TMP/verify-state.bpqw.MUTANT.sh"
  sed '/# BP-QUALIFIER-WARN/d' "$SUT" > "$bpqw_mutant"; cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  warn_bpqm="$(bash "$bpqw_mutant" "$TMP/bp-qualifier" 2>&1 >/dev/null)"
  if ! grep -qE 'WARN.*non-conforming qualifier' <<<"$warn_bpqm"; then
    ok "teeth-BP-qualifier-warn: WARN-removed mutant emits no WARN — qualifier WARN assertion has teeth"
  else
    no "teeth-BP-qualifier-warn: mutant still emitted WARN — THEATER"
  fi
  # teeth-n4-warn: silence the n!=4 WARN → n!=4-warn must go red (no WARN emitted).
  echo "-- teeth-n4-warn: silence VS-N4-WARN line; n4 fixture must emit no WARN --"
  n4w_mutant="$TMP/verify-state.n4w.MUTANT.sh"
  sed '/# VS-N4-WARN/s/.*/      if (n!=4) { next }  # MUTANT-N4/' "$SUT" > "$n4w_mutant"; cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  warn_n4m="$(bash "$n4w_mutant" "$TMP/n4-warn" 2>&1 >/dev/null)"
  if ! grep -qiE 'WARN.*malformed backlog row' <<<"$warn_n4m"; then
    ok "teeth-n4-warn: n!=4-WARN-silenced mutant emits no WARN — n4 WARN assertion has teeth"
  else
    no "teeth-n4-warn: mutant still emitted WARN — THEATER"
  fi
  cp "$TMP/verify-state.strikethrough.MUTANT.sh" "$TMP/verify-state.sh"  # Propagation: copy-2 mutant → status --next must return STALE
  cp "$HERE/../research-sdd-status.sh" "$TMP/status.VS-PROP.sh"; cp "$HERE/../lib/state-files.sh" "$TMP/lib/state-files.sh"
  _pst="$(bash "$TMP/status.VS-PROP.sh" "$TMP/bp-strikethrough" --next 2>/dev/null)"
  [ "${_pst%%\ *}" = "STALE" ] && ok "teeth-BP-strikethrough-prop: neutered copy-2 → STALE in status" || no "teeth-BP-strikethrough-prop: [$_pst] (want STALE)"
  cp "$TMP/verify-state.em-dash.MUTANT.sh" "$TMP/verify-state.sh"
  _ped="$(bash "$TMP/status.VS-PROP.sh" "$TMP/bp-em-dash" --next 2>/dev/null)"
  [ "${_ped%%\ *}" = "STALE" ] && ok "teeth-BP-em-dash-prop: neutered copy-2 → STALE in status" || no "teeth-BP-em-dash-prop: [$_ped] (want STALE)"
  cp "$TMP/verify-state.qualifier.MUTANT.sh" "$TMP/verify-state.sh"
  _pq="$(bash "$TMP/status.VS-PROP.sh" "$TMP/bp-qualifier" --next 2>/dev/null)"
  [ "${_pq%%\ *}" = "STALE" ] && ok "teeth-BP-qualifier-prop: neutered copy-2 → STALE in status" || no "teeth-BP-qualifier-prop: [$_pq] (want STALE)"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"  # restore lib

  # teeth-BP-qualifier-invalid: explicit (needs MUTANT-QV build-check); accept-all-bases → hight(x) false-passes.
  echo "-- teeth-BP-qualifier-invalid: accept-all-bases mutant; hight(x) must false-pass (exit 0) --"
  if grep -q 'BPSKIP-QUALIFIER' "$SUT"; then
    sed '/# BP-QUALIFIER-WARN/s/if (base=="high" || base=="medium" || base=="low" || base=="deferred") {/if (1) {  # MUTANT-QV/' \
      "$SUT" > "$TMP/verify-state.QV.MUTANT.sh"
    if ! grep -q 'MUTANT-QV' "$TMP/verify-state.QV.MUTANT.sh"; then
      no "teeth-BP-qualifier-invalid: could not build accept-all-bases mutant (base-validity line not found)"
    else
      cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
      bash "$TMP/verify-state.QV.MUTANT.sh" "$TMP/bp-qualifier-invalid" >/dev/null 2>&1; mqvgot=$?
      [ "$mqvgot" = 0 ] \
        && ok "teeth-BP-qualifier-invalid: accept-all-bases mutant → hight(x) false-passes (exit 0) — base-validity is load-bearing" \
        || no "teeth-BP-qualifier-invalid: mutant exit $mqvgot (want 0) — base-validity may not be the stopper (THEATER)"
    fi
  else no "teeth-BP-qualifier-invalid: BPSKIP-QUALIFIER not found in SUT"; fi

  # near-miss WARN teeth: neuter the NM-WARN branch → near-miss fixture must stop WARNing.
  echo "-- teeth-NM: neuter near-miss WARN (NM-WARN tag); '## Gap backlog' fixture must stop WARNing --"
  nm_mutant="$TMP/verify-state.NM-MUTANT.sh"
  sed 's|> "/dev/stderr" }  # NM-WARN|> "/dev/null" }  # MUTANT-NM: near-miss WARN neutered|' "$SUT" > "$nm_mutant"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if ! grep -q 'MUTANT-NM: near-miss WARN neutered' "$nm_mutant"; then
    no "teeth-NM: could not build mutant (NM-WARN tag not found in SUT — did the SUT change?)"
  else
    nm_warn_orig="$(bash "$SUT" "$TMP/nm-space" 2>&1 >/dev/null)"
    nm_warn_mut="$(bash "$nm_mutant" "$TMP/nm-space" 2>&1 >/dev/null)"
    if grep -qi 'near-miss' <<<"$nm_warn_orig" && ! grep -qi 'near-miss' <<<"$nm_warn_mut"; then
      ok "teeth-NM: original WARNs on '## Gap backlog', mutant stays silent → near-miss WARN has teeth"
    else
      no "teeth-NM: orig warns=[$(grep -ci 'near-miss' <<<"$nm_warn_orig")] mut warns=[$(grep -ci 'near-miss' <<<"$nm_warn_mut")] — WARN not load-bearing"
    fi
  fi

  # ============================ FOCUS SCOPING mutation controls ============================
  # Mutation 1 (FOCUS-FILTER): neuter the focus-filter branch → --focus ignored; lints all files.
  # This makes F1/F2/F2b/F3 revert to pre-fix behavior and go RED.
  echo "-- teeth-FOCUS-FILTER: neuter FOCUS-FILTER; focus tests must revert to lint-all (pre-fix) --"
  mutantFOC="$TMP/verify-state.FOCUS.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# FOCUS-FILTER' "$SUT"; then
    sed '/# FOCUS-FILTER$/s/if \[ -n "\$focus_slug" \]; then/if false; then  # MUTANT-FOCUS/' "$SUT" > "$mutantFOC"
    if ! grep -q '# MUTANT-FOCUS' "$mutantFOC"; then
      no "teeth-FOCUS-FILTER: could not build mutant (FOCUS-FILTER sentinel not found — did SUT change?)"
    else
      # F1 teeth: neutered mutant lints BOTH consistent files → 2 headers (not 1)
      echo "-- teeth-FOCUS-F1: neutered → must show 2 headers, not 1 --"
      foc1_out="$(bash "$mutantFOC" "$TMP/focus-single-hit" --focus database 2>/dev/null)"
      if ! grep -c '== verify-state:' <<<"$foc1_out" | grep -q '^1$'; then
        ok "teeth-FOCUS-F1: neutered → multiple headers (not 1) — focus isolation has teeth"
      else
        no "teeth-FOCUS-F1: neutered mutant still shows only 1 header — THEATER"
      fi
      # F2 teeth: neutered mutant lints email (consistent) → exit 0, not 2
      echo "-- teeth-FOCUS-F2: neutered → must exit 0 (not 2) —"
      bash "$mutantFOC" "$TMP/focus-absent" --focus database >/dev/null 2>&1; mfoc2rc=$?
      if [ "$mfoc2rc" != 2 ]; then
        ok "teeth-FOCUS-F2: neutered → exit $mfoc2rc (not 2) — absent-focus guard has teeth"
      else
        no "teeth-FOCUS-F2: neutered mutant still exits 2 — THEATER"
      fi
      # F2b teeth: neutered mutant lints BOTH (thin + consistent) → 2 headers
      echo "-- teeth-FOCUS-F2b: neutered → must show 2 headers, not 1 --"
      foc2b_out="$(bash "$mutantFOC" "$TMP/focus-thin-match" --focus database 2>/dev/null)"
      if ! grep -c '== verify-state:' <<<"$foc2b_out" | grep -q '^1$'; then
        ok "teeth-FOCUS-F2b: neutered → multiple headers (not 1) — thin-match isolation has teeth"
      else
        no "teeth-FOCUS-F2b: neutered mutant still shows only 1 header — THEATER"
      fi
      # F3 teeth: neutered mutant lints both → stale email fires FAIL/PREMATURE STOP → exit 1
      echo "-- teeth-FOCUS-F3: neutered → stale sibling must fire FAIL/PREMATURE STOP --"
      foc3_out="$(bash "$mutantFOC" "$TMP/focus-noise-suppress" --focus database 2>/dev/null)"
      bash "$mutantFOC" "$TMP/focus-noise-suppress" --focus database >/dev/null 2>&1; mfoc3rc=$?
      if [ "$mfoc3rc" = 1 ] && grep -q 'PREMATURE STOP' <<<"$foc3_out"; then
        ok "teeth-FOCUS-F3: neutered → stale sibling FAIL fires (exit 1, PREMATURE STOP) — noise-suppression has teeth"
      else
        no "teeth-FOCUS-F3: neutered mutant: rc=$mfoc3rc PREMATURE=$(grep -c 'PREMATURE STOP' <<<"$foc3_out" || true) — THEATER"
      fi
    fi
  else
    no "teeth-FOCUS-FILTER: FOCUS-FILTER sentinel not found in SUT (focus branch not implemented)"
  fi

  # Mutation 2 (FOCUS-EMPTY-SLUG-GUARD): change exit 2 → exit 0 on the empty-slug guard.
  # F4 test expects exit 2; mutant exits 0 → F4 goes RED.
  echo "-- teeth-FOCUS-F4: FOCUS-EMPTY-SLUG-GUARD exit 2→0; --focus (no slug) must exit 0 (not 2) --"
  mutantF4="$TMP/verify-state.FOCUSF4.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# FOCUS-EMPTY-SLUG-GUARD' "$SUT"; then
    sed '/# FOCUS-EMPTY-SLUG-GUARD$/s/exit 2/exit 0/' "$SUT" > "$mutantF4"
    if ! grep -q 'exit 0.*# FOCUS-EMPTY-SLUG-GUARD' "$mutantF4"; then
      no "teeth-FOCUS-F4: could not build mutant (FOCUS-EMPTY-SLUG-GUARD sentinel not found — did SUT change?)"
    else
      bash "$mutantF4" "$TMP/focus-no-slug" --focus >/dev/null 2>&1; mf4rc=$?
      if [ "$mf4rc" = 0 ]; then
        ok "teeth-FOCUS-F4: exit 2→0 mutant exits 0 → F4 'exit 2' assertion goes red — empty-slug guard has teeth"
      else
        no "teeth-FOCUS-F4: mutant exit $mf4rc (want 0) — THEATER"
      fi
    fi
  else
    no "teeth-FOCUS-F4: FOCUS-EMPTY-SLUG-GUARD sentinel not found in SUT"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
