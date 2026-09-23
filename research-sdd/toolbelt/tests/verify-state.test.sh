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
d="$TMP/req-agree"; ewrite "$d" 0 4 7 1 1 1 "high|open read-only gap|pending" \
  "high|G41 equipment LOD|requires-execution → §19 (not read-only; needs a build + re-measure)"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -E '^   (FAIL|WARN)' <<<"$out" | grep -q 'requires_execution_open'; then
  ok "marked-open row + declared 1 → exit 0, CHECK E silent (backlog-anchored agreement)"
else no "req-agree: exit $(code "$d") :: $(grep -iE 'requires_execution_open' <<<"$out" | head -1)"; fi

# 31 — PROSE-TRACKED corpus (the logosoft shape): NO backlog marker at all, envelope carries a nonzero
#      declared count → exit 0 with CHECK E silent. Pins the calibration: a strict equality gate would
#      false-FAIL every prose-tracked corpus (declared N vs derived 0), which is exactly what CHECK E
#      must NOT do — derived 0 proves nothing.
d="$TMP/req-prose-only"; ewrite "$d" 0 4 7 1 1 1 "high|open read-only gap|pending"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -E '^   (FAIL|WARN)' <<<"$out" | grep -q 'requires_execution_open'; then
  ok "prose-tracked (no marker) + declared 1 → exit 0, silent (no false FAIL on logosoft-shape corpora)"
else no "req-prose-only: exit $(code "$d") :: $(grep -iE 'requires_execution_open' <<<"$out" | head -1)"; fi

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
d="$TMP/req-closed"; ewrite "$d" 0 4 5 0 0 1 \
  "high|~~G50 old build gap~~|requires-execution → §19" \
  "high|G51 landed PoC|requires-execution ✅ cubierto — B72"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -E '^   (FAIL|WARN)' <<<"$out" | grep -q 'requires_execution_open'; then
  ok "struck-through / cubierto requires-execution rows excluded → derived 0, exit 0"
else no "req-closed: exit $(code "$d") :: $(grep -iE 'requires_execution_open' <<<"$out" | head -1)"; fi

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
d="$TMP/req-freetext-mention"; ewrite "$d" 0 4 6 1 0 1 "medium|future scope note|pending (requires-execution)"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -E '^   (FAIL|WARN)' <<<"$out" | grep -q 'requires_execution_open'; then
  ok "free-text 'pending (requires-execution)' mention NOT counted → exit 0, CHECK E silent (no false FAIL)"
else no "req-freetext-mention: exit $(code "$d") :: $(grep -iE 'requires_execution_open' <<<"$out" | head -1)"; fi

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

# B3c — ## Blocked / <qualifier> gaps is treated identically to ## Blocked gaps for blocked_open
# derivation (e.g. "## Blocked / non-read-only gaps" used in niagara-research spyder focus, confirmed
# fleet-wide 2026-09-22). Entries still must carry a needs: token — no double-counting with
# derive_requires_execution() because that function reads the backlog TABLE, not these sections.
d="$TMP/blocked-slash"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 3 0 0 1 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 3 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked / non-read-only gaps (tagged with what they need)'
  echo '- G5b — needs: the tasowizSupport module JAR added to corpus. blocked-on-artifact.'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "B3c: ## Blocked / non-read-only gaps counted for blocked_open (1 needs: entry → blocked_open=1 → PASS)"
else no "B3c: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# B3c-FAIL — same fixture but envelope declares blocked_open=0 while 1 entry exists → FAIL.
d="$TMP/blocked-slash-fail"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 3 0 0 0 0; echo   # blocked_open=0 (wrong)
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 3 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked / non-read-only gaps (tagged with what they need)'
  echo '- G5b — needs: the tasowizSupport module JAR added to corpus. blocked-on-artifact.'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*blocked_open=0 != 1' <<<"$out"; then
  ok "B3c-FAIL: blocked_open=0 vs 1 Blocked/ entry → FAIL (slash-heading recognized)"
else no "B3c-FAIL: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# B911a — ## Child gaps surfaced at close: multi-line bullet with `needs:` on a continuation line.
# A blocked gap whose `needs:` token is NOT on the bullet line itself (e.g. niagara-research
# RESEARCH-STATE-database.md DB-G1: bullet carries `blocked-on-source-missing`; `needs:` is on a
# subsequent indent line) must still be counted. Confirmed fleet-wide 2026-09-22: only
# RESEARCH-STATE-database.md carries this section heading; the fix scans it with awk rather than
# extending the existing grep (which is anchored to bullet lines only).
# SINGLE: one open entry in ## Child gaps surfaced at close, `needs:` on continuation → PASS.
d="$TMP/child-gaps-single"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 3 0 0 1 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 3 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Child gaps surfaced at close'
  echo '- **CG1 missing jar** — `blocked-on-source-missing`.'
  echo '  `tried:` fd on corpus = 0.'
  echo '  `needs:` decompilar el jar before reinvestigating.'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "B911a-SINGLE: ## Child gaps surfaced at close: 1 multi-line entry (needs: on continuation) → blocked_open=1 → PASS"
else no "B911a-SINGLE: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# B911a-FAIL: declared blocked_open=0 while 1 child-gaps entry has needs: on continuation → FAIL.
d="$TMP/child-gaps-single-fail"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 3 0 0 0 0; echo   # blocked_open=0 (wrong — 1 child-gaps entry exists)
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 3 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Child gaps surfaced at close'
  echo '- **CG1 missing jar** — `blocked-on-source-missing`.'
  echo '  `tried:` fd on corpus = 0.'
  echo '  `needs:` decompilar el jar before reinvestigating.'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*blocked_open=0 != 1' <<<"$out"; then
  ok "B911a-FAIL: child-gaps 1 entry, blocked_open=0 (wrong) → FAIL (mismatch detected)"
else no "B911a-FAIL: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# B911a-FIRST: open entry is FIRST in section (2 closed after it); blocked_open=1 → PASS.
d="$TMP/child-gaps-first"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 3 0 0 1 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 3 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Child gaps surfaced at close'
  echo '- **CG1 open** — `blocked-on-source-missing`.'
  echo '  `tried:` fd = 0. `needs:` retrieve the jar before reinvestigating.'
  echo '- **CG2 closed** — **CERRADO [CERT-live] (B610, §12)**: evidence in block.'
  echo '- **CG3 closed** — **CERRADO [CERT-live] (B611)**: analysed in block.'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "B911a-FIRST: open entry FIRST in ## Child gaps surfaced at close → blocked_open=1 → PASS"
else no "B911a-FIRST: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# B911a-MIDDLE: open entry is in MIDDLE (closed before and after); blocked_open=1 → PASS.
d="$TMP/child-gaps-middle"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 3 0 0 1 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 3 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Child gaps surfaced at close'
  echo '- **CG1 closed** — **CERRADO [CERT-live] (B610, §12)**: analysed in block.'
  echo '- **CG2 open** — `blocked-on-source-missing`.'
  echo '  `tried:` fd = 0. `needs:` retrieve the jar before reinvestigating.'
  echo '- **CG3 closed** — **CERRADO [CERT-live] (B611)**: analysed in block.'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "B911a-MIDDLE: open entry MIDDLE in ## Child gaps surfaced at close → blocked_open=1 → PASS"
else no "B911a-MIDDLE: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# B911a-LAST: open entry is LAST in section (2 closed before it); blocked_open=1 → PASS.
d="$TMP/child-gaps-last"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 3 0 0 1 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 3 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Child gaps surfaced at close'
  echo '- **CG1 closed** — **CERRADO [CERT-live] (B610, §12)**: analysed in block.'
  echo '- **CG2 closed** — **CERRADO [CERT-live] (B611)**: analysed in block.'
  echo '- **CG3 open** — `blocked-on-source-missing`.'
  echo '  `tried:` fd = 0. `needs:` retrieve the jar before reinvestigating.'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "B911a-LAST: open entry LAST in ## Child gaps surfaced at close → blocked_open=1 → PASS"
else no "B911a-LAST: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# B911a-FP-GUARD: ## Child gaps surfaced at close with only closed entries — blocked_open=0 → PASS.
# Also guards against a false positive when closed entries have instructional prose on continuation
# lines that does NOT carry `needs:` (like DB-G2/G3 in database.md).
d="$TMP/child-gaps-fp-guard"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 3 0 0 0 0; echo   # blocked_open=0 (correct — all entries are CERRADO)
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 3 closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Child gaps surfaced at close'
  echo '- **CG1 closed** — **CERRADO [CERT-live] (B610, GATED-BY-DEPLOYMENT)**: already in block.'
  echo '  `tried:` remittance to B403/B407 covers static model.'
  echo '- **CG2 closed** — **CERRADO [CERT-live] (B611, §12)**: thread-safe confirmed in live.'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "B911a-FP-GUARD: all child-gap entries closed (CERRADO, no needs:) → blocked_open=0 → PASS (no false positive)"
else no "B911a-FP-GUARD: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

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

# ---- Prose-paragraph form of blocked gaps (§7 false negative — RSDD-PROSE-BLOCKED-ANCHOR) ----
# Real corpora (e.g. blender-llm) write blocked gaps as multi-line prose paragraphs:
#   G54 — description. **needs:** something.
# and NOT as bullet items.  derive_blocked must count them, and derive_missing_tried must recognise
# them paragraph-wise (tried: and needs: may be on different lines within one paragraph).
# The "- none" placeholder form must NOT be counted in either derivation.

# T-PROSE-BLOCKED-MATCH: one prose-paragraph gap with **needs:** → blocked_open=1 must match.  # RSDD-PROSE-BLOCKED-ANCHOR
d="$TMP/prose-blocked-match"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 5 1 0 1 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 5 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | active gap | web | pending |'; echo
  echo '## Blocked gaps (each tagged with what it needs)'
  echo ''
  echo 'G54 — the undecoded blob in the file. **needs:** a documented reader for the format;'
  echo 'the open-source tool converts everything else but leaves this blob opaque. Recorded'
  echo '`blocked-on-tool`, named and bounded, not dismissed.'
  echo ''
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "T-PROSE-BLOCKED-MATCH: prose **needs:** paragraph counted → blocked_open=1 matches → exit 0"
else no "T-PROSE-BLOCKED-MATCH: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# T-PROSE-BLOCKED-FAIL: same prose paragraph but blocked_open=0 declared → must FAIL.
d="$TMP/prose-blocked-fail"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 5 1 0 0 0; echo   # blocked_open=0 (wrong — there is 1 prose entry)
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 5 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | active gap | web | pending |'; echo
  echo '## Blocked gaps (each tagged with what it needs)'
  echo ''
  echo 'G54 — the undecoded blob in the file. **needs:** a documented reader for the format.'
  echo ''
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*blocked_open=0 != 1' <<<"$out"; then
  ok "T-PROSE-BLOCKED-FAIL: declared blocked_open=0 vs 1 prose entry → FAIL exit 1"
else no "T-PROSE-BLOCKED-FAIL: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# T-PROSE-BLOCKED-PARENTHETICAL: "(none other at this time ... `needs:` ...)" paragraph must NOT count.
# This is the blender-llm trailing paragraph that mentions needs: in backtick/historical context.
d="$TMP/prose-blocked-paren"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 5 1 0 0 0; echo   # blocked_open=0 (correct — the parenthetical must not inflate)
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 5 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | active gap | web | pending |'; echo
  echo '## Blocked gaps (each tagged with what it needs)'
  echo ''
  echo '(none other at this time — G1 is requires-execution but not blocked; they need a live session.'
  echo 'G2'\''s original `needs:` was a special tool; **tried:** shell probe → blocked by permissions.'
  echo 'Closed at [CERT-hw], no extra tooling needed.)'
  echo ''
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "T-PROSE-BLOCKED-PAREN: parenthetical backtick \`needs:\` not counted → blocked_open=0 matches → exit 0"
else no "T-PROSE-BLOCKED-PAREN: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

# T-PROSE-TRIED-WARN: prose paragraph with **needs:** but no **tried:** → P23 WARN must fire.
d="$TMP/prose-tried-warn"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 5 1 0 1 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 5 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | active gap | web | pending |'; echo
  echo '## Blocked gaps (each tagged with what it needs)'
  echo ''
  echo 'G54 — the undecoded blob in the file. **needs:** a documented reader for the format;'
  echo 'the open-source tool converts everything else but leaves this blob opaque.'
  echo ''
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qiE 'WARN.*tried:' <<<"$out"; then
  ok "T-PROSE-TRIED-WARN: prose **needs:** without **tried:** → P23 WARN fires, exit 0"
else no "T-PROSE-TRIED-WARN: exit $(code "$d") :: $(grep -iE 'WARN.*tried\|tried' <<<"$out" | head -1)"; fi

# T-PROSE-TRIED-OK: prose paragraph with both **needs:** and **tried:** (on different lines) → P23 must NOT fire.
d="$TMP/prose-tried-ok"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 5 1 0 1 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 5 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | active gap | web | pending |'; echo
  echo '## Blocked gaps (each tagged with what it needs)'
  echo ''
  echo 'G77 — device tags on the sheet frame. **needs:** stroke-level reconstruction, a different'
  echo 'instrument rather than a looser threshold. **tried:** nearest closed body → returns an edge;'
  echo 'transitive clustering → one huge cluster; leader-line following → 71 resolved, 85 framed.'
  echo ''
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qiE 'WARN.*tried:' <<<"$out"; then
  ok "T-PROSE-TRIED-OK: prose **needs:** + **tried:** on different lines → P23 WARN suppressed, exit 0"
else no "T-PROSE-TRIED-OK: exit $(code "$d") :: $(grep -iE 'WARN.*tried\|tried' <<<"$out" | head -1)"; fi

# T-PROSE-BULLET-REGRESSION: existing bullet form must still work alongside prose form.
d="$TMP/prose-bullet-regression"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env9 0 3 6 1 0 2 0; echo   # blocked_open=2: one bullet + one prose entry
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 6 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '| high | active gap | web | pending |'; echo
  echo '## Blocked gaps (each tagged with what it needs)'
  echo '- gpu profiling — needs: hardware; tried: ssh probe (rejected: device offline)'; echo
  echo 'G54 — the undecoded blob in the file. **needs:** a documented reader for the format.'
  echo 'The tool converts everything else but leaves this blob opaque.'; echo
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 1'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "T-PROSE-BULLET-REGRESSION: bullet + prose entry both counted → blocked_open=2 matches → exit 0"
else no "T-PROSE-BULLET-REGRESSION: exit $(code "$d") :: $(grep -iE 'fail|blocked_open' <<<"$out" | head -1)"; fi

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

# BS-global-ok — block_scope: shared-global, covered_blocks == attributed count → PASSES.
# Corpus has 5 blocks on disk (corpus total) but focus only attributes B1,B2,B3 (from Iteration history).
# covered_blocks=3 matches attributed=3; corpus total 5 is informational. SUT must exit 0.
d="$TMP/bs-global-ok"; mkdir -p "$d"
for _bgi in 1 2 3 4 5; do printf 'x\n' > "$d/niagara-mental-model-bloque${_bgi}.md"; done
{ echo '# Chihuahua — Research State'; echo
  env_bs 3 0 0 0 0 0 0 0 "shared-global"; echo   # covered_blocks=3, attributed=3 → PASS
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
  echo '## Iteration history'; echo
  echo '| # | Date | Gap closed | Block | Delegated? · model | New gaps |'
  echo '|---|---|---|---|---|---|'
  echo '| 1 | 2026-01-01 | gap-A | B1 | no · inline | none |'
  echo '| 2 | 2026-01-02 | gap-B | B2 | no · inline | none |'
  echo '| 3 | 2026-01-03 | gap-C | B3 | no · inline | none |'
} > "$d/RESEARCH-STATE-chihuahua.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "BS-global-ok: block_scope: shared-global, covered_blocks=3 == attributed 3 (corpus 5) → exit 0"
else no "BS-global-ok: exit $(code "$d") :: $(grep -iE 'fail|covered_blocks|ok ' <<<"$out" | head -1)"; fi

# BS-global-stale — block_scope: shared-global, covered_blocks != attributed count → FAILS (mismatch check has teeth).
# Iteration history attributes B1,B2,B3 (attributed=3). declared covered_blocks=10 → mismatch → FAIL.
d="$TMP/bs-global-stale"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-mental-model-bloque1.md"
printf 'x\n' > "$d/niagara-mental-model-bloque2.md"
printf 'x\n' > "$d/niagara-mental-model-bloque3.md"
{ echo '# Chihuahua — Research State'; echo
  env_bs 10 0 0 0 0 0 0 0 "shared-global"; echo   # covered_blocks=10, attributed=3 → MISMATCH
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
  echo '## Iteration history'; echo
  echo '| # | Date | Gap closed | Block | Delegated? · model | New gaps |'
  echo '|---|---|---|---|---|---|'
  echo '| 1 | 2026-01-01 | gap-A | B1 | no · inline | none |'
  echo '| 2 | 2026-01-02 | gap-B | B2 | no · inline | none |'
  echo '| 3 | 2026-01-03 | gap-C | B3 | no · inline | none |'
} > "$d/RESEARCH-STATE-chihuahua.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*covered_blocks=10 != 3' <<<"$out"; then
  ok "BS-global-stale: block_scope: shared-global, covered_blocks=10 != attributed 3 → FAIL exit 1"
else no "BS-global-stale: exit $(code "$d") :: $(grep -iE 'fail|covered_blocks' <<<"$out" | head -1)"; fi

# SG-check2-no-false-warn — CHECK 2 must NOT fire for shared-global when prose 'Covered blocks: N'
# matches the attributed count but differs from corpus total.
# Bug: for block_scope: shared-global, ondisk = corpus total (here 5), but covered_claim = 3 (from
# prose '**Covered blocks:** 3 of 5'). CHECK 2 compared covered_claim (3) against ondisk (5) → false WARN.
# Fix: skip CHECK 2 when _sg_check_a_done = 1 (shared-global path taken).
# Fixture: corpus=5 blocks, focus attributes B1+B2+B3 (attributed=3, covered_blocks=3 = correct).
# After fix: CHECK 2 skipped → exit 0, no WARN. Before fix: exit 0 + WARN 'disagrees with 5'.
d="$TMP/sg-check2-no-false-warn"; mkdir -p "$d"
for _bgi in 1 2 3 4 5; do printf 'x\n' > "$d/niagara-mental-model-bloque${_bgi}.md"; done
{ echo '# Chihuahua — Research State'; echo
  env_bs 3 0 0 0 0 0 0 0 "shared-global"; echo   # covered_blocks=3, attributed=3 → SG CHECK A passes
  echo '## Summary'; echo
  echo '**Covered blocks:** 3 of 5 (B1, B2, B3 attributed to this focus)'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
  echo '## Iteration history'; echo
  echo '| # | Date | Gap closed | Block | Delegated? · model | New gaps |'
  echo '|---|---|---|---|---|---|'
  echo '| 1 | 2026-01-01 | gap-A | B1 | no · inline | none |'
  echo '| 2 | 2026-01-02 | gap-B | B2 | no · inline | none |'
  echo '| 3 | 2026-01-03 | gap-C | B3 | no · inline | none |'
} > "$d/RESEARCH-STATE-chihuahua.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -q 'disagrees with' <<<"$out"; then
  ok "SG-check2-no-false-warn: shared-global prose 'Covered blocks: 3 of 5', attributed=3, corpus=5 → no CHECK 2 WARN, exit 0"
else no "SG-check2-no-false-warn: exit $(code "$d") :: $(grep -E 'disagrees|WARN.*Covered|FAIL' <<<"$out" | head -2 | tr '\n' '|') (want exit 0 + no false WARN)"; fi

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

# ====================== ISSUE #423 — shared-global attributed-count CHECK A ========================

# SG-unverifiable — block_scope: shared-global, no attributed blocks (no ## Covered blocks, no Iteration history)
# → INFO 'unverifiable under shared-global', never FAIL against corpus total, exit 0.
d="$TMP/sg-unverifiable"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-mental-model-bloque1.md"
{ echo '# Chihuahua — Research State'; echo
  env_bs 0 0 0 0 0 0 0 0 "shared-global"; echo   # covered_blocks=0, no attributed ids → unverifiable
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-chihuahua.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'INFO.*unverifiable' <<<"$out" && grep -qE 'INFO.*corpus total' <<<"$out"; then
  ok "SG-unverifiable: shared-global + no attributed ids → INFO (not FAIL) + corpus total INFO, exit 0"
else no "SG-unverifiable: exit $(code "$d") :: $(grep -iE 'info|fail' <<<"$out" | head -2 | tr '\n' '|')"; fi

# SG-true-mismatch — block_scope: shared-global, covered_blocks=19 while Iteration history shows B1..B17.
# A focus whose envelope disagrees with its OWN attributed ids stays a TRUE FAIL (not suppressed).
# This is the tooth-2 base fixture: declared 19, attributed 17 → FAIL exit 1.
d="$TMP/sg-true-mismatch"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-mental-model-bloque1.md"
printf 'x\n' > "$d/niagara-mental-model-bloque2.md"
printf 'x\n' > "$d/niagara-mental-model-bloque3.md"
{ echo '# KitControl — Research State'; echo
  env_bs 19 0 0 0 0 0 0 0 "shared-global"; echo   # covered_blocks=19, attributed=17 → MISMATCH
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
  echo '## Iteration history'; echo
  echo '| # | Date | Gap closed | Block | Delegated? · model | New gaps |'
  echo '|---|---|---|---|---|---|'
  for _sgk in $(seq 1 17); do echo "| ${_sgk} | 2026-01-01 | gap-${_sgk} | B${_sgk} | no · inline | none |"; done
} > "$d/RESEARCH-STATE-kitControl.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*covered_blocks=19 != 17' <<<"$out"; then
  ok "SG-true-mismatch: covered_blocks=19 vs attributed 17 → FAIL exit 1 (true mismatch stays a FAIL)"
else no "SG-true-mismatch: exit $(code "$d") :: $(grep -iE 'fail|covered_blocks' <<<"$out" | head -1)"; fi

# SG-scope — two focuses sharing shared-global corpus.
# focus-a: covered_blocks=3, attributed=3 (B1,B2,B3) → CLEAN.
# focus-b: covered_blocks=10, attributed=3 (B1,B2,B3) → MISMATCH.
# --focus focus-a must exit 0: scoped to focus-a only; focus-b mismatch must NOT propagate.
_sg_iter3() {   # emit 3-row Iteration history (B1,B2,B3) for shared-global fixtures
  echo '## Iteration history'; echo
  echo '| # | Date | Gap closed | Block | Delegated? · model | New gaps |'
  echo '|---|---|---|---|---|---|'
  for _sgj in 1 2 3; do echo "| ${_sgj} | 2026-01-01 | gap-${_sgj} | B${_sgj} | no · inline | none |"; done
}
d="$TMP/sg-scope"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-mental-model-bloque1.md"
printf 'x\n' > "$d/niagara-mental-model-bloque2.md"
printf 'x\n' > "$d/niagara-mental-model-bloque3.md"
{ echo '# FocusA — Research State'; echo
  env_bs 3 0 0 0 0 0 0 0 "shared-global"; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
  _sg_iter3
} > "$d/RESEARCH-STATE-focus-a.md"
{ echo '# FocusB — Research State'; echo
  env_bs 10 0 0 0 0 0 0 0 "shared-global"; echo   # mismatch: covered_blocks=10, attributed=3
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
  _sg_iter3
} > "$d/RESEARCH-STATE-focus-b.md"
rc_scope="$(codef "$d" --focus focus-a)"
out_scope="$(runf "$d" --focus focus-a)"
if [ "$rc_scope" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out_scope"; then
  ok "SG-scope: --focus focus-a scoped → exit 0 (focus-b mismatch must not propagate)"
else no "SG-scope: exit $rc_scope :: $(grep -iE 'fail|ok ' <<<"$out_scope" | head -1)"; fi

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

# F2c — §7 three-state: EMPTY focus file (0-byte) ≠ absent (exit 2) ≠ thin-nonempty (F2b).
#        A 0-byte RESEARCH-STATE-<slug>.md satisfies `-f` (file exists) but NOT `-s` (non-empty).
#        The focus guard `[ ! -f "$_focused" ]` treats it as PRESENT → reaches the lint path, NOT
#        the absent-guard exit 2. has_env fails on 0 bytes → exit 1; focus-scoping still restricts
#        output to exactly 1 file header (only the focused file is linted).
#        F2b's nonempty-but-thin fixture passes under both -f and a -s mutation (the file has content
#        so -s is also true → the boundary is invisible). This 0-byte fixture exposes the -f vs -s
#        distinction that F2b left untested, closing the §7 EMPTY-state gap.
#        RED before fix: pre-fix ignores --focus → lints all → header count != 1 → F2c red.
d="$TMP/focus-empty-file"; mkdir -p "$d"
: > "$d/RESEARCH-STATE-database.md"   # 0-byte — satisfies -f (exists), NOT -s (non-empty)
# Consistent sibling to isolate: the ONLY not-clean signal is the empty focus file; no other check fires.
{ echo '# Email — Research State'; echo
  env_lines 0 3 3 0 0 0; echo
  echo 'coverage metric: 3 / 3 gaps closed'
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
} > "$d/RESEARCH-STATE-email.md"
# Sanity: confirm fixture is genuinely 0-byte (prevents a stale fixture from masking the -f/-s boundary).
[ ! -s "$d/RESEARCH-STATE-database.md" ] || { echo "FATAL: F2c fixture RESEARCH-STATE-database.md is not 0-byte" >&2; exit 2; }
f2c_rc="$(codef "$d" --focus database)"
f2c_out="$(runf "$d" --focus database)"
if [ "$f2c_rc" != 2 ] \
   && grep -c '== verify-state:' <<<"$f2c_out" | grep -q '^1$'; then
  ok "F2c --focus empty-file: 0-byte file EXISTS (-f true) → NOT exit 2 (exit $f2c_rc), 1 header (§7 empty ≠ absent)"
else no "F2c: exit=$f2c_rc headers=$(grep -c '== verify-state:' <<<"$f2c_out" || true) (want exit!=2, 1 header)"; fi

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

# ============================ PART A: coverage-metric anchor (MA) ============================
# Verifies that the metric grep anchors to 'Coverage metric:' (with optional bold **) and does NOT
# pick up table headers whose row contains 'Gap closed' / 'gaps closed'.
# Smoking-gun shape: an '## Iteration history' table header '| Gap closed |' appears BEFORE the
# real '**Coverage metric**: **13 / 15**' line. The old head-1 picked the table header and
# reported <none>; the fix anchors to 'coverage metric:' to skip table headers.

# MA-1 (RED before fix): table-header shadow. '| Iteration | Date | Gap closed | Coverage |'
#   comes BEFORE '**Coverage metric**: **13 / 15**'. The old grep matches 'Gap closed' via
#   'gaps? closed', head-1 picks it, no ratio found → summary 'coverage metric : <none>'.
#   After fix: anchored grep skips the table header, picks the real metric line → 13/15.
d="$TMP/metric-anchor-table-header"; mkdir -p "$d"
{ echo '# OEM Tail — Research State'; echo
  env_lines 0 13 15 0 0 0; echo
  echo '## Iteration history'
  echo '| Iteration | Date | Gap closed | Coverage (after) |'
  echo '|---|---|---|---|'
  echo '| B1 | 2024-01 | gap-alpha | 1/15 |'
  echo '| B12 | 2024-12 | gap-omega | 12/15 |'
  echo ''
  echo '## Coverage'
  echo '- **Coverage metric**: **13 / 15** declared gaps closed'
  echo ''
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if grep -qE 'coverage metric\s*:\s*13/15' <<<"$out"; then
  ok "MA-1: table-header 'Gap closed' does NOT shadow real **Coverage metric**: line → 13/15 detected"
else no "MA-1: expected 13/15 got: $(grep -iE 'coverage metric' <<<"$out" | head -1)"; fi

# MA-2 (negative control, must PASS both before and after fix): unbolded 'Coverage metric: 7 / 7'
#   with NO table header above. Pins that the fix does not break the simple unbolded form.
d="$TMP/metric-anchor-unbolded"; mkdir -p "$d"
{ echo '# Platform — Research State'; echo
  env_lines 0 7 7 0 0 0; echo
  echo '## Coverage'
  echo 'Coverage metric: 7 / 7 declared gaps closed'
  echo ''
  echo '## Gap-backlog (prioritized)'
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if grep -qE 'coverage metric\s*:\s*7/7' <<<"$out"; then
  ok "MA-2 neg-control: unbolded 'Coverage metric: 7 / 7' still detected as 7/7 (no regression)"
else no "MA-2: expected 7/7 got: $(grep -iE 'coverage metric' <<<"$out" | head -1)"; fi

# ============================ PART B: duplicate-WARN dedupe (DW) ============================
# _backlog_rows() is called 4× per state (bparse_out, derive_pending_rows, derive_investigable,
# derive_requires_execution). Each call re-runs awk and re-emits structural WARNs to stderr,
# producing 4× the same WARN. The cache (BR-CACHE-HIT) deduplicates to 1× per state.

# DW-1 (RED before fix): near-miss heading emits the WARN exactly ONCE per state.
#   Before fix: NM-WARN fires on every _backlog_rows call → 4 identical WARNs on stderr.
#   After fix: cache returns cached rows on calls 2-4 → awk re-run skipped → 1 WARN total.
d="$TMP/dup-warn-once"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  env_lines 0 0 0 0 0 0; echo
  echo '## Gap backlog'      # near-miss (space not hyphen) → NM-WARN from _backlog_rows
  echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
nm_stderr_dw="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
nm_count_dw="$(grep -c 'near-miss' <<<"$nm_stderr_dw")"
if [ "$nm_count_dw" = 1 ]; then
  ok "DW-1: near-miss WARN emitted exactly ONCE per state (not ${nm_count_dw}×) — BR cache deduplicates"
else no "DW-1: near-miss WARN appeared ${nm_count_dw}× (want exactly 1) — deduplication missing or broken"; fi

# ============================ ENVELOPE CHECK H — known_gaps declared identity (IDENT) ============================
# CHECK H fires WARN when declared known_gaps ≠ sum of its five DECLARED envelope counters:
#   gaps_closed + investigable_open + blocked_open + deferred_open + requires_execution_open == known_gaps
# All counters must be declared integers — skip silently if any is missing/malformed.
# This is an internal-consistency check on the envelope; disk-vs-declared staleness is CHECK B/C/E/F's job.
# WHY declared-only: prose-tracked corpora declare e_req>0 but d_req=0 (no backlog marker) — a
# derived-counter check false-fires on them. Using declared counters matches §8 doctrine field names exactly.
# WARN-ONLY: premature-STOP is owned by CHECK B/D; this is advisory mirror hygiene.

# e9write <dir> <covered> <gc> <kg> <io> <req> <bo> <def> <backlog-row...> — like ewrite but includes
# deferred_open in the envelope (env9). Used for IDENT fixtures that need an explicit deferred_open value
# (e.g. def=0 for IDENT-A/B/C). Note: absent deferred_open is now treated as 0 (IDENTITY-DEF-ABSENT-AS-ZERO),
# so ewrite fixtures also participate in CHECK H — see IDENT-D for the absent-def path.
e9write() {
  local dir="$1" cb="$2" gc="$3" kg="$4" io="$5" req="$6" bo="$7" def="$8"; shift 8; mkdir -p "$dir"
  { echo '# T — Research State'; echo
    env9 "$cb" "$gc" "$kg" "$io" "$req" "$bo" "$def"; echo
    echo '## Coverage'; echo "- **Coverage metric**: $gc / $kg closed"; echo
    echo '## Gap-backlog (prioritized)'; echo
    echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
    local r p g s; for r in "$@"; do IFS='|' read -r p g s <<<"$r"; echo "| $p | $g | web | $s |"; done; echo
    echo '## Blocked gaps'; echo '- gpu profiling — needs: hardware'; echo
    echo '## Stop control'; echo "- **Open gaps — read-only investigable**: $io"
  } > "$dir/RESEARCH-STATE.md"
}

# IDENT-A (teeth/RED case): declared identity fails — declared sum ≠ kg → WARN fires.
# e_gc=4, e_kg=10, e_inv=2, e_blocked=1, e_def=0, e_req=0 → declared sum=7 ≠ kg=10.
# Per-term checks all pass: d_inv=2=e_inv, d_blocked=1=e_blocked, d_def=0=e_def, d_req=0 and e_req=0.
# RED before fix (derived-counter code): old code emitted different WARN text → new grep does not match
# → case fails. After fix: new WARN text matches → PASS.
d="$TMP/ident-mismatch"
e9write "$d" 0 4 10 2 0 1 0 "high|gap A|pending" "high|gap B|pending"
out="$(run "$d")"
if grep -qE 'WARN.*sum of declared counters.*stale denominator' <<<"$out"; then
  ok "IDENT-A: declared sum (gc=4+inv=2+blocked=1+def=0+req=0=7) ≠ kg=10 → stale-denominator WARN emitted"
else no "IDENT-A: declared sum=7 ≠ kg=10 → WARN expected; got: $(grep -iE 'warn.*known_gaps' <<<"$out" | head -1)"; fi

# IDENT-B (negative control): declared identity holds → no stale-denominator WARN.
# e_gc=4, e_kg=7, e_inv=2, e_blocked=1, e_def=0, e_req=0 → declared sum=7 = kg=7 → silent.
d="$TMP/ident-match"
e9write "$d" 0 4 7 2 0 1 0 "high|gap A|pending" "high|gap B|pending"
out="$(run "$d")"
if ! grep -qE 'WARN.*stale denominator' <<<"$out"; then
  ok "IDENT-B: declared identity (gc=4+inv=2+blocked=1+def=0+req=0=7) = kg=7 → no stale-denominator WARN"
else no "IDENT-B: false-alarm WARN on matching declared denominator: $(grep -iE 'warn.*known_gaps' <<<"$out" | head -1)"; fi

# IDENT-C (prose-tracked negative control): declared identity holds; d_req=0 (req gap prose-tracked only).
# e_gc=4, e_kg=7, e_inv=1, e_blocked=1, e_def=0, e_req=1 → declared sum=4+1+1+0+1=7 = kg=7 → no WARN.
# d_req=0: the single pending backlog row has no requires-execution marker; req is prose-tracked (logosoft shape).
# RED on the FABLE-#1 derived-counter draft; pinned by teeth-IDENT-C.
# Old _identity_sum = e_gc+d_inv+d_blocked+d_def+d_req = 4+1+1+0+0 = 6 ≠ kg=7 → false WARN → assertion fails → RED.
# GREEN on new declared-counter code: _identity_sum = e_gc+e_inv+e_blocked+e_def+e_req = 4+1+1+0+1=7=kg → no WARN.
d="$TMP/ident-prose-req"
e9write "$d" 0 4 7 1 1 1 0 "high|gap A|pending"
out="$(run "$d")"
if ! grep -qE 'WARN.*stale denominator' <<<"$out"; then
  ok "IDENT-C: prose-tracked req (e_req=1, d_req=0, declared sum=7=kg) → no false stale-denominator WARN"
else no "IDENT-C: false-alarm on prose-tracked req (declared sum=4+1+1+0+1=7=kg but WARN fires): $(grep -iE 'warn.*known_gaps' <<<"$out" | head -1)"; fi

# IDENT-D (absent-deferred_open, stale): ewrite fixture (no deferred_open field) with kg ≠ gc+inv+blocked+req.
# gc=4, kg=10, e_inv=2, e_blocked=1, _h_def=0 (absent-as-0), e_req=0 → sum=7 ≠ kg=10 → WARN MUST FIRE.
# Proves the absent-as-0 fix is active: if the guard still required is_int(e_def), this would be silent.
d="$TMP/ident-absent-def"
ewrite "$d" 0 4 10 2 0 1 "high|gap A|pending" "high|gap B|pending"
out="$(run "$d")"
if grep -qE 'WARN.*sum of declared counters.*stale denominator' <<<"$out"; then
  ok "IDENT-D: absent deferred_open (ewrite), kg=10 ≠ sum=7 → stale-denominator WARN fires (absent def counted as 0)"
else no "IDENT-D: absent deferred_open, kg=10 ≠ sum=7 → WARN expected (absent def must not skip); got: $(grep -iE 'warn.*known_gaps' <<<"$out" | head -1)"; fi

# IDENT-D-malformed: deferred_open set to non-integer "none" — must not crash; def treated as 0 (is_int split).
# (a) kg consistent (gc=4, kg=7, inv=2, blocked=1, req=0 → sum=7 with _h_def=0) → no stale WARN, no crash.
d="$TMP/ident-mal-def-ok"
mkdir -p "$d"
{ printf '# T — Research State\n\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 4\nknown_gaps: 7\n'
  printf 'investigable_open: 2\nrequires_execution_open: 0\nblocked_open: 1\ndeferred_open: none\n<!-- /research-state.v1 -->\n\n'
  printf '## Coverage\n- **Coverage metric**: 4 / 7 closed\n\n'
  printf '## Gap-backlog (prioritized)\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | gap A | web | pending |\n| high | gap B | web | pending |\n\n'
  printf '## Blocked gaps\n- gpu profiling — needs: hardware\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 2\n'
} > "$d/RESEARCH-STATE.md"
out="$(bash "$SUT" "$d" 2>&1)"
if ! grep -qE 'WARN.*stale denominator' <<<"$out" && ! grep -qiE 'unbound variable|arithmetic expression' <<<"$out"; then
  ok "IDENT-D-malformed(a): deferred_open=none, kg=7=sum → no stale-denominator WARN, no arithmetic crash"
else no "IDENT-D-malformed(a): unexpected WARN or crash; $(grep -E 'unbound|arithmetic|stale denominator' <<<"$out" | head -2 | tr '\n' ' ')"; fi

# (b) kg inconsistent (gc=4, kg=10, inv=2, blocked=1, req=0 → sum=7 ≠ kg=10) → stale WARN fires (def=0), no crash.
d="$TMP/ident-mal-def-stale"
mkdir -p "$d"
{ printf '# T — Research State\n\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 4\nknown_gaps: 10\n'
  printf 'investigable_open: 2\nrequires_execution_open: 0\nblocked_open: 1\ndeferred_open: none\n<!-- /research-state.v1 -->\n\n'
  printf '## Coverage\n- **Coverage metric**: 4 / 10 closed\n\n'
  printf '## Gap-backlog (prioritized)\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | gap A | web | pending |\n| high | gap B | web | pending |\n\n'
  printf '## Blocked gaps\n- gpu profiling — needs: hardware\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 2\n'
} > "$d/RESEARCH-STATE.md"
out="$(bash "$SUT" "$d" 2>&1)"
if grep -qE 'WARN.*sum of declared counters.*stale denominator' <<<"$out" && ! grep -qiE 'unbound variable|arithmetic expression' <<<"$out"; then
  ok "IDENT-D-malformed(b): deferred_open=none, kg=10≠sum=7 → stale-denominator WARN fires (def=0), no crash"
else no "IDENT-D-malformed(b): WARN expected or crash detected; warn=$(grep -iE 'warn.*known_gaps|stale denominator' <<<"$out" | head -1); err=$(grep -iE 'unbound|arithmetic' <<<"$out" | head -1)"; fi

# ========================= ISSUE CLUSTER #557 FIXES =========================

# T-634a — trailing ** stripped from status in derive_investigable / derive_pending_rows (§8b).
# A row with Status `pending**` (markdown bold artifact from rich editing) must be counted as pending.
# Pre-fix: ${st%% *} sees `pending**` ≠ `pending` → derive_investigable returns 0 → CHECK B: 0≠1 → FAIL.
# Post-fix: ** stripped at _backlog_rows output → st=`pending`, derives 1 = env 1 → exit 0.
d="$TMP/t634-trailing-bold"; mkdir -p "$d"
{ printf '# Research State\n\n'
  env_lines 0 1 2 1 0 0; printf '\n'
  printf '## Coverage\n- **Coverage metric**: 1 / 2 closed\n\n'
  printf '## Gap-backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | open-gap | web | pending** |\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 1\n'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "T-634a: Status 'pending**' (trailing bold) → counted as pending, investigable_open=1 matches derived, exit 0"
else
  no "T-634a: Status 'pending**' not counted as pending; exit=$(code "$d"); msg=$(grep -iE 'investigable_open|FAIL' <<<"$out" | head -1)"
fi

# T-634b — status **pending** (both leading and trailing bold) → also counted correctly.
d="$TMP/t634-double-bold"; mkdir -p "$d"
{ printf '# Research State\n\n'
  env_lines 0 1 2 1 0 0; printf '\n'
  printf '## Coverage\n- **Coverage metric**: 1 / 2 closed\n\n'
  printf '## Gap-backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | open-gap | web | **pending** |\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 1\n'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "T-634b: Status '**pending**' (double bold) → counted as pending, investigable_open=1 matches derived, exit 0"
else
  no "T-634b: Status '**pending**' not counted; exit=$(code "$d"); msg=$(grep -iE 'investigable_open|FAIL' <<<"$out" | head -1)"
fi

# T-567 — COVERED row with pipe notation in Status must not emit a malformed-row WARN.
# COVERED rows legitimately carry protocol-field summaries (`devType|address|...`) that make the row
# appear to have > 4 cells. These are COVERED, not malformed; the WARN is spurious noise.
# Pre-fix: WARN emitted to stderr.  Post-fix: WARN suppressed (COVERED rows silently skip).
d="$TMP/t567-covered-pipe"; mkdir -p "$d"
{ printf '# Research State\n\n'
  env_lines 0 0 0 0 0 0; printf '\n'
  printf '## Coverage\n- **Coverage metric**: 0 / 1 closed\n\n'
  printf '## Gap-backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | MM12-G1 | protocol | COVERED devType|address|command|status |\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d/RESEARCH-STATE.md"
t567_err="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
if [ "$(code "$d")" = 0 ] && ! grep -q 'malformed backlog row' <<<"$t567_err"; then
  ok "T-567: COVERED row with pipe notation → no malformed-row WARN, exit 0"
else
  no "T-567: spurious malformed-row WARN for COVERED pipe row; warn=$(grep -m1 'malformed backlog row' <<<"$t567_err")"
fi

# T-567b — positive control: a non-COVERED row with pipe notation (real malformed case) STILL warns.
d="$TMP/t567-noncovered-pipe"; mkdir -p "$d"
{ printf '# Research State\n\n'
  env_lines 0 0 0 0 0 0; printf '\n'
  printf '## Coverage\n- **Coverage metric**: 0 / 1 closed\n\n'
  printf '## Gap-backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | pipe-gap | protocol | pending | extra-cell |\n\n'  # NOT covered → still a WARN
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d/RESEARCH-STATE.md"
t567b_err="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
if grep -q 'malformed backlog row' <<<"$t567b_err"; then
  ok "T-567b: non-COVERED row with pipe notation → malformed-row WARN still fires (positive control)"
else
  no "T-567b: non-COVERED malformed row WARN missing (positive control broken)"
fi

# T-599a — missing ## Gap-backlog section → FAIL (absent ≠ empty, §7 anti-silent-zero).
# Pre-fix: derive_investigable=0 silently matches envelope=0 → exit 0 (false ok).
# Post-fix: absent heading detected → FAIL, exit 1.
d="$TMP/t599-no-backlog"; mkdir -p "$d"
{ printf '# Research State\n\n'
  env_lines 0 2 5 0 0 0; printf '\n'
  printf '## Coverage\n- **Coverage metric**: 2 / 5 closed\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 3\n'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qiE 'FAIL.*Gap-backlog.*absent|FAIL.*absent.*Gap-backlog' <<<"$out"; then
  ok "T-599a: missing ## Gap-backlog section → FAIL (absent section detected), exit 1"
else
  no "T-599a: missing Gap-backlog silently passed; exit=$(code "$d"); msg=$(grep -iE 'fail|gap.backlog|ok ' <<<"$out" | head -1)"
fi

# T-599b — present but EMPTY ## Gap-backlog section → no absent-section FAIL (empty ≠ absent).
d="$TMP/t599-empty-backlog"; mkdir -p "$d"
{ printf '# Research State\n\n'
  env_lines 0 2 2 0 0 0; printf '\n'
  printf '## Coverage\n- **Coverage metric**: 2 / 2 closed\n\n'
  printf '## Gap-backlog\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "T-599b: present but empty ## Gap-backlog → no absent-section FAIL (empty ≠ absent), exit 0"
else
  no "T-599b: empty Gap-backlog wrongly triggered absent-section FAIL; exit=$(code "$d"); msg=$(grep -iE 'fail|gap.backlog|ok ' <<<"$out" | head -1)"
fi

# T-599c — stop-control prose count matches derived investigable_open → no cross-check FAIL.
d="$TMP/t599-stopctl-match"; mkdir -p "$d"
{ printf '# Research State\n\n'
  env_lines 0 1 3 2 0 0; printf '\n'
  printf '## Coverage\n- **Coverage metric**: 1 / 3 closed\n\n'
  printf '## Gap-backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | gap-A | web | pending |\n'
  printf '| medium | gap-B | web | pending |\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 2\n'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "T-599c: stop-control prose=2 matches derived=2 → no cross-check FAIL, exit 0"
else
  no "T-599c: false mismatch FAIL; exit=$(code "$d"); msg=$(grep -iE 'stop.control|investigable|fail' <<<"$out" | head -1)"
fi

# T-599d — stop-control prose says 3 but backlog-derived is 1 → FAIL (cross-check mismatch).
# Pre-fix: no cross-check → exit 0 (false ok).
# Post-fix: mismatch detected → FAIL, exit 1.
d="$TMP/t599-stopctl-mismatch"; mkdir -p "$d"
{ printf '# Research State\n\n'
  env_lines 0 1 3 1 0 0; printf '\n'  # investigable_open=1 matches derived=1 (CHECK B passes)
  printf '## Coverage\n- **Coverage metric**: 1 / 3 closed\n\n'
  printf '## Gap-backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | gap-A | web | pending |\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 3\n'  # stale: prose says 3 but derived=1
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qiE 'FAIL.*[Ss]top.control.*prose.*[0-9]|FAIL.*read-only-investigable.*but backlog' <<<"$out"; then
  ok "T-599d: stop-control prose=3 vs derived=1 → FAIL (cross-check mismatch), exit 1"
else
  no "T-599d: stop-control mismatch not detected; exit=$(code "$d"); msg=$(grep -iE 'stop.control|investigable|fail' <<<"$out" | head -2 | tr '\n' ' ')"
fi

# T-SCEX-A (false-positive guard — arrow-annotation form, issue #SC-EXTRACT):
# Stop-control line: "- **Open gaps - read-only investigable**: 3  <- static loop stops when this hits 0"
# The buggy extractor grep -oE '[0-9]+' | tail -1 returns 0 (last number in the annotation), not 3.
# Derived investigable_open=3 (3 pending rows). Pre-fix: FAIL fired since 0≠3 — false positive.
# Post-fix: extracts 3 (value immediately after the colon), no FAIL.
d="$TMP/t-scex-arrow"; mkdir -p "$d"
{ printf '# Research State\n\n'
  env_lines 0 0 3 3 0 0; printf '\n'
  printf '## Gap-backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | gap-1 | web | pending |\n'
  printf '| medium | gap-2 | web | pending |\n'
  printf '| low | gap-3 | web | pending |\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n'
  printf '%s\n' '- **Open gaps - read-only investigable**: 3  <- static loop stops when this hits 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "T-SCEX-A: stop-control arrow-annotation (3 <- ...hits 0) matches derived=3 → no false FAIL"
else
  no "T-SCEX-A: false FAIL on arrow-annotation form; exit=$(code "$d"); msg=$(grep -iE '  FAIL  .*investigable|  FAIL  .*stop.control' <<<"$out" | head -1)"
fi

# T-SCEX-B (false-positive guard — parenthesized gap-ID list form, issue #SC-EXTRACT):
# Stop-control line: "- **Open gaps - read-only investigable**: 6 (G74 bridge-timeout, G77 other)"
# The buggy extractor returns 77 (last number in G77), not 6.
# Derived investigable_open=6 (6 pending rows). Pre-fix: FAIL fired since 77≠6 — false positive.
# Post-fix: extracts 6 (value immediately after the colon), no FAIL.
d="$TMP/t-scex-gaplist"; mkdir -p "$d"
{ printf '# Research State\n\n'
  env_lines 0 0 6 6 0 0; printf '\n'
  printf '## Gap-backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | G74 bridge-timeout | web | pending |\n'
  printf '| high | G77 round diffusers | web | pending |\n'
  printf '| high | G78 adjudication | web | pending |\n'
  printf '| medium | G37 viewer base | web | pending |\n'
  printf '| medium | G38 repo-triage | web | pending |\n'
  printf '| low | G73 merge-batch | web | pending |\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n'
  printf '%s\n' '- **Open gaps - read-only investigable**: 6 (G74 bridge-timeout, G77 other)'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'ok +envelope validated' <<<"$out"; then
  ok "T-SCEX-B: stop-control gap-list form (6 (G74..G77)) matches derived=6 → no false FAIL"
else
  no "T-SCEX-B: false FAIL on gap-list form; exit=$(code "$d"); msg=$(grep -iE '  FAIL  .*investigable|  FAIL  .*stop.control' <<<"$out" | head -1)"
fi

# T-566a — known_stale_warns: p7-index-placeholder suppresses the P7 INDEX placeholder WARN.
# Pre-fix: known_stale_warns field is unknown → WARN emitted normally.
# Post-fix: field recognised → INFO emitted ("suppressed (known_stale_warns)"); no WARN.
d="$TMP/t566-p7-suppress"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-block1.md"   # ondisk=1 so P7 check runs
printf '<SUBJECT>\n<YYYY-MM-DD>\n' > "$d/INDEX.md"   # placeholder triggers P7
{ printf '# Research State\n\n'
  printf '<!-- research-state.v1 -->\n'
  printf 'schema: research-state.v1\n'
  printf 'covered_blocks: 1\n'
  printf 'gaps_closed: 2\nknown_gaps: 2\n'
  printf 'investigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\n'
  printf 'known_stale_warns: p7-index-placeholder\n'
  printf '<!-- /research-state.v1 -->\n\n'
  printf '## Coverage\n- **Coverage metric**: 2 / 2 closed\n\n'
  printf '## Gap-backlog\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] \
   && grep -qiE 'INFO.*p7-index-placeholder' <<<"$out" \
   && ! grep -qE '^\s*WARN.*placeholder' <<<"$out"; then
  ok "T-566a: known_stale_warns=p7-index-placeholder → P7 WARN suppressed to INFO, exit 0"
else
  no "T-566a: P7 WARN not suppressed; exit=$(code "$d"); msgs=$(grep -iE '^\s*WARN.*placeholder|INFO.*p7' <<<"$out" | head -2 | tr '\n' '|')"
fi

# T-566b — known_stale_warns: check-2-covered-blocks suppresses CHECK 2 (covered_blocks mismatch WARN).
# Pre-fix: WARN emitted normally.  Post-fix: INFO emitted instead; no WARN.
d="$TMP/t566-check2-suppress"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-block1.md"   # ondisk=1; claim=5 → mismatch triggers CHECK 2 WARN
{ printf '# Research State\n\n'
  printf '<!-- research-state.v1 -->\n'
  printf 'schema: research-state.v1\n'
  printf 'covered_blocks: 1\n'
  printf 'gaps_closed: 2\nknown_gaps: 2\n'
  printf 'investigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\n'
  printf 'known_stale_warns: check-2-covered-blocks\n'
  printf '<!-- /research-state.v1 -->\n\n'
  printf '## Coverage\n- **Coverage metric**: 2 / 2 closed\nCovered blocks: 5\n\n'
  printf '## Gap-backlog\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] \
   && grep -qiE 'INFO.*check-2-covered-blocks.*suppressed|INFO.*suppressed.*check-2-covered-blocks' <<<"$out" \
   && ! grep -qE 'WARN.*disagrees with' <<<"$out"; then
  ok "T-566b: known_stale_warns=check-2-covered-blocks → CHECK 2 WARN suppressed to INFO, exit 0"
else
  no "T-566b: CHECK 2 WARN not suppressed; exit=$(code "$d"); msgs=$(grep -iE 'WARN.*disagrees|INFO.*suppressed' <<<"$out" | head -2 | tr '\n' '|')"
fi

# T-566c — unknown suppression id in known_stale_warns → no false suppression (WARNs still fire).
d="$TMP/t566-unknown-id"; mkdir -p "$d"
printf 'x\n' > "$d/niagara-block1.md"
printf '<SUBJECT>\n' > "$d/INDEX.md"
{ printf '# Research State\n\n'
  printf '<!-- research-state.v1 -->\n'
  printf 'schema: research-state.v1\n'
  printf 'covered_blocks: 1\n'
  printf 'gaps_closed: 2\nknown_gaps: 2\n'
  printf 'investigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\n'
  printf 'known_stale_warns: unknown-warn-id\n'
  printf '<!-- /research-state.v1 -->\n\n'
  printf '## Coverage\n- **Coverage metric**: 2 / 2 closed\nCovered blocks: 5\n\n'
  printf '## Gap-backlog\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if grep -qE '^\s*WARN.*disagrees with' <<<"$out" && grep -qE '^\s*WARN.*placeholder' <<<"$out"; then
  ok "T-566c: unknown suppression id → no false suppression (both P7 and CHECK 2 WARNs fire)"
else
  no "T-566c: unknown id falsely suppressed a WARN; msgs=$(grep -iE '^\s*WARN' <<<"$out" | head -3 | tr '\n' '|')"
fi

# ==================== CHECK P18 — blocks_since_retro §18 cadence threshold ====================
# Helper: build a minimal valid state with the given envelope + gap-backlog, no block files on disk.
# bsr_state <dir> <bsr-value>: creates RESEARCH-STATE.md with blocks_since_retro: <bsr-value> in the envelope.
bsr_state() {
  local d="$1" bsr="$2"; mkdir -p "$d"
  { printf '# T-P18 Research State\n\n'
    printf '<!-- research-state.v1 -->\n'
    printf 'schema: research-state.v1\n'
    printf 'covered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\n'
    printf 'requires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n'
    printf 'undocumented_findings: 0\nblocks_since_retro: %s\n' "$bsr"
    printf '<!-- /research-state.v1 -->\n\n'
    printf '## Gap-backlog\n\n| P | G | t | S |\n|---|---|---|---|\n\n'
    printf '## Blocked gaps\n- none\n\n'
    printf '## Stop control\n- **Open gaps — read-only investigable**: 0\n'
  } > "$d/RESEARCH-STATE.md"
}

# T-P18a — blocks_since_retro ABSENT from envelope → silent (no WARN, exit 0)
d="$TMP/p18-absent"
tablestate "$d" 3 5 2   # metric 3/5, 2 pending, envelope has no bsr field
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qiE 'blocks_since_retro' <<<"$out"; then
  ok "T-P18a: blocks_since_retro absent from envelope → silent (no WARN)"
else no "T-P18a: expected silent, got rc=$(code "$d") :: $(grep -iE 'blocks_since_retro' <<<"$out" | head -1)"; fi

# T-P18b — blocks_since_retro=9 (below threshold 10) → no WARN
d="$TMP/p18-below"; bsr_state "$d" 9
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qiE 'WARN.*blocks_since_retro' <<<"$out"; then
  ok "T-P18b: blocks_since_retro=9 (below threshold) → no WARN"
else no "T-P18b: expected no WARN for bsr=9, got rc=$(code "$d") :: $(grep -iE 'blocks_since_retro' <<<"$out" | head -1)"; fi

# T-P18c — blocks_since_retro=10 (AT threshold, not exceeded; gate fires at >10) → no WARN
d="$TMP/p18-at"; bsr_state "$d" 10
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qiE 'WARN.*blocks_since_retro' <<<"$out"; then
  ok "T-P18c: blocks_since_retro=10 (at threshold, >10 fires) → no WARN"
else no "T-P18c: expected no WARN for bsr=10, got rc=$(code "$d") :: $(grep -iE 'blocks_since_retro' <<<"$out" | head -1)"; fi

# T-P18d — blocks_since_retro=11 (EXCEEDS threshold) → WARN (not FAIL; cadence is advisory)  # P18-THRESHOLD-WARN-CASE
d="$TMP/p18-exceeded"; bsr_state "$d" 11
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qiE 'WARN.*blocks_since_retro.*11.*>.*10' <<<"$out"; then
  ok "T-P18d: blocks_since_retro=11 > 10 → WARN (not FAIL; cadence advisory)"
else no "T-P18d: expected WARN for bsr=11, got rc=$(code "$d") :: $(grep -iE 'blocks_since_retro|WARN' <<<"$out" | head -2 | tr '\n' '|')"; fi

# T-P18e — blocks_since_retro=xyz (non-integer) → FAIL (gate cannot do its job)  # P18-NONINT-FAIL-CASE
d="$TMP/p18-nonint"; bsr_state "$d" "xyz"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qiE 'FAIL.*blocks_since_retro' <<<"$out"; then
  ok "T-P18e: blocks_since_retro=xyz (non-integer) → FAIL (gate cannot check cadence)"
else no "T-P18e: expected FAIL for non-integer bsr, got rc=$(code "$d") :: $(grep -iE 'blocks_since_retro|FAIL' <<<"$out" | head -2 | tr '\n' '|')"; fi

# T-P18f — blocks_since_retro=20 (well above threshold) → WARN surfaced
d="$TMP/p18-high"; bsr_state "$d" 20
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qiE 'WARN.*blocks_since_retro.*20' <<<"$out"; then
  ok "T-P18f: blocks_since_retro=20 → WARN (cadence enforcement)"
else no "T-P18f: expected WARN for bsr=20, got rc=$(code "$d") :: $(grep -iE 'blocks_since_retro' <<<"$out" | head -1)"; fi

# ---- #911 A2 mirror coverage: 5-col tables and U+2011 headings -----------------------------------
# VS-5COL-PASS: verify-state must exit 0 when a 5-col backlog table declares matching counts.
d="$TMP/vs-5col-pass"; mkdir -p "$d"
{ echo '# T'; echo
  env9 0 2 2 0 0 0 0; echo
  echo '## Gap-backlog (prioritized)'; echo
  printf '| Pr. | ID | Gap | Artifact | Status |\n|---|---|---|---|---|\n'
  echo '| high | G1 | five-col gap 1 | bin.dll | covered |'
  echo '| low  | G2 | five-col gap 2 | bin2.dll | covered |'; echo
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps — read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
if [ "$(code "$d")" = 0 ]; then
  ok "VS-5COL-PASS: 5-col Gap-backlog with matching known_gaps=2 → exit 0"
else no "VS-5COL-PASS: exit $(code "$d") — 5-col rows may not be read (BP-EXPECTED-COLS missing in verify-state mirror)"; fi

# VS-5COL-FAIL: a pending 5-col row must cause verify-state to exit 1 when the envelope declares
# investigable_open=0. Pre-fix: 5-col rows rejected (n=5 ≠ sc=4) → derived investigable=0 →
# false match with declared=0 → exit 0 (false pass). Post-fix: 5-col row counted → derived=1 ≠ 0.
d="$TMP/vs-5col-fail"; mkdir -p "$d"
{ echo '# T'; echo
  env9 0 0 1 0 0 0 0; echo   # known_gaps=1, investigable_open=0 — stale (open gap not counted)
  echo '## Gap-backlog (prioritized)'; echo
  printf '| Pr. | ID | Gap | Artifact | Status |\n|---|---|---|---|---|\n'
  echo '| high | G1 | five-col pending gap | bin.dll | pending |'; echo
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps — read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
if [ "$(code "$d")" != 0 ]; then
  ok "VS-5COL-FAIL: 5-col pending row → derived investigable_open=1 ≠ declared=0 → FAIL exit 1 (5-col rows counted)"
else no "VS-5COL-FAIL: exit 0 — 5-col pending row not counted (BP-EXPECTED-COLS may be broken in verify-state mirror)"; fi

# VS-OOB-WARN: _backlog_rows() counts OOB rows (emitting OOB-WARN to stderr) so verify-state must
# not brick when a row appears outside ## Gap-backlog. The fixture has:
#   - an empty (but present) ## Gap-backlog section — satisfies the presence check
#   - one covered OOB row under ## Non-canonical heading
# The envelope declares known_gaps=1, gaps_closed=1 to match the single OOB counted row → exit 0.
d="$TMP/vs-oob-warn"; mkdir -p "$d"
{ echo '# T'; echo
  env9 0 1 1 0 0 0 0; echo   # gaps_closed=1, known_gaps=1 — matches the one OOB row
  echo '## Gap-backlog (prioritized)'; echo   # present-but-empty satisfies §T-599a presence check
  echo '## Non-canonical heading'; echo
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  echo '| high | NG1 | web | covered |'; echo
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps -- read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
if [ "$(code "$d")" = 0 ]; then
  ok "VS-OOB-WARN: OOB row counted with matching envelope → exit 0 (OOB does not brick verify-state)"
else no "VS-OOB-WARN: exit 1 — OOB row with matching envelope still fails verify-state"; fi

# VS-U2011-HEADING: a Gap-backlog heading with U+2011 non-breaking hyphen. U+2011-NORM was dropped
# (M2 — corpus no longer uses U+2011 after niagara 571652bec). Without normalisation the heading
# does not match the canonical ASCII pattern → NM-WARN fires (near-miss warning).
d="$TMP/vs-u2011"; mkdir -p "$d"
{ echo '# T'; echo
  env9 0 1 1 0 0 0 0; echo
  # U+2011 non-breaking hyphen in heading (UTF-8: E2 80 91)
  printf '## Gap\xe2\x80\x91backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | u2011 gap | web | covered |\n\n'
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps -- read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
_vs_u2011_warn="$(bash "$SUT" "$d" 2>&1)"
if echo "$_vs_u2011_warn" | grep -qi 'near-miss'; then
  ok "VS-U2011-HEADING: U+2011 heading → NM-WARN fires (U+2011-NORM dropped; heading not recognised as valid)"
else no "VS-U2011-HEADING: NM-WARN should fire for U+2011 heading after U+2011-NORM removal — got: [$(echo "$_vs_u2011_warn" | head -3)]"; fi

# VS-WIDTH-3: a 3-column Gap-backlog table must emit BP-WIDTH-WARN; verify-state skips the rows
# (all rows skipped → derived open=0 = declared 0 → exit 0, but WARN fires on stderr).
d="$TMP/vs-width-3"; mkdir -p "$d"
{ echo '# T'; echo
  env9 0 0 0 0 0 0 0; echo
  echo '## Gap-backlog (prioritized)'; echo
  printf '| Priority | Gap | Status |\n|---|---|---|\n'
  echo '| high | three-col row | pending |'; echo
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps -- read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
_vs_w3_warn="$(bash "$SUT" "$d" 2>&1)"
if echo "$_vs_w3_warn" | grep -qi 'only 4- or 5-column\|backlog table has.*3 columns'; then
  ok "VS-WIDTH-3: 3-col separator → BP-WIDTH-WARN emitted by _backlog_rows mirror"
else
  no "VS-WIDTH-3: no BP-WIDTH-WARN for 3-col separator — unsupported width accepted silently in verify-state mirror"
fi

# VS-WIDTH-6: a 6-column Gap-backlog table must emit BP-WIDTH-WARN.
d="$TMP/vs-width-6"; mkdir -p "$d"
{ echo '# T'; echo
  env9 0 0 0 0 0 0 0; echo
  echo '## Gap-backlog (prioritized)'; echo
  printf '| Priority | ID | Gap | Artifact | Extra | Status |\n|---|---|---|---|---|---|\n'
  echo '| high | G1 | six-col row | art.dll | extra | pending |'; echo
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps -- read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
_vs_w6_warn="$(bash "$SUT" "$d" 2>&1)"
if echo "$_vs_w6_warn" | grep -qi 'only 4- or 5-column\|backlog table has.*6 columns'; then
  ok "VS-WIDTH-6: 6-col separator → BP-WIDTH-WARN emitted by _backlog_rows mirror"
else
  no "VS-WIDTH-6: no BP-WIDTH-WARN for 6-col separator — unsupported width accepted silently in verify-state mirror"
fi

# VS-LIST-ITEM: a markdown prose list item with embedded | in a Gap-backlog section must NOT be
# treated as a backlog row in _backlog_rows() (verify-state.sh mirror of backlog_rows).
d_vsli="$TMP/vs-list-item"; mkdir -p "$d_vsli"
{ echo '# T'; echo
  env9 0 0 1 1 0 0 0; echo
  echo '## Gap-backlog (prioritized)'; echo
  printf '| Pr. | ID | Gap | Artifact | Status |\n|---|---|---|---|---|\n'
  echo '| high | G1 | real gap | art.dll | pending |'; echo
  echo '- **B843-G1/G2/G3 — CLOSED by B855**: slot facets (Flags.OPERATOR/READONLY|TRANSIENT, extra|pipe)'; echo
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps — read-only investigable**: 1'; } > "$d_vsli/RESEARCH-STATE.md"
_vsli_out="$(bash "$SUT" "$d_vsli" 2>&1)"
if ! echo "$_vsli_out" | grep -qi 'unknown priority\|INVALID_PRIORITY\|backlog.*columns'; then
  ok "VS-LIST-ITEM: prose list item with | in Gap-backlog silently ignored in verify-state mirror"
else
  no "VS-LIST-ITEM: list item with | produced unexpected output in verify-state: $(echo "$_vsli_out" | grep -i 'unknown\|invalid\|columns' | head -1)"
fi

# VS-SEP-OUTSIDE: a 6-col separator outside a Gap-backlog section must NOT produce BP-WIDTH-WARN
# in _backlog_rows() (verify-state.sh mirror).
d_vsso="$TMP/vs-sep-outside"; mkdir -p "$d_vsso"
{ echo '# T'; echo
  env9 0 0 0 0 0 0 0; echo
  echo '## Iteration history'; echo
  echo '| # | Date | Scope | New gaps | Status | Notes |'; printf '|---|---|---|---|---|---|\n'
  echo '| 1 | 2026-01-01 | full | 3 | active | n/a |'; echo
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps — read-only investigable**: 0'; } > "$d_vsso/RESEARCH-STATE.md"
_vsso_out="$(bash "$SUT" "$d_vsso" 2>&1)"
if ! echo "$_vsso_out" | grep -qi 'only 4- or 5-column\|backlog table has'; then
  ok "VS-SEP-OUTSIDE: 6-col separator outside Gap-backlog silently ignored in verify-state mirror"
else
  no "VS-SEP-OUTSIDE: BP-WIDTH-WARN fired for 6-col separator outside Gap-backlog in verify-state mirror"
fi

# VS-DENOM-PORT: port numbers in prose (e.g. 3011/5011 framing note) must NOT trigger the
# contradictory-denominators WARN. The denominator grep now requires spaces on both sides of /.
d_vsdp="$TMP/vs-denom-port"; mkdir -p "$d_vsdp"
{ echo '# T'; echo
  env9 0 7 7 0 0 0 0; echo
  echo '## Coverage'
  echo 'Coverage metric: 7 / 7 at 2026-01-01 (3011/5011 framing applies — port numbers not fractions)'; echo
  echo '## Gap-backlog (prioritized)'; echo
  printf '| Pr. | ID | Gap | Artifact | Status |\n|---|---|---|---|---|\n'
  echo '| high | G1 | gap covered | art.dll | covered -> B1 |'; echo
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps — read-only investigable**: 0'; } > "$d_vsdp/RESEARCH-STATE.md"
_vsdp_out="$(bash "$SUT" "$d_vsdp" 2>&1)"
if ! echo "$_vsdp_out" | grep -qi 'contradictory.*denominators\|denominators.*3011\|denominators.*5011'; then
  ok "VS-DENOM-PORT: port numbers 3011/5011 in Coverage prose do not trigger contradictory-denominators WARN"
else
  no "VS-DENOM-PORT: port numbers 3011/5011 incorrectly parsed as coverage fraction → false WARN: $(echo "$_vsdp_out" | grep -i denominat | head -1)"
fi

# VS-M1-DENOM-UNSPACED: CHECK 3 must detect contradictory denominators for unspaced fractions
# (e.g. "7/8" vs "7/7") after the grep-to-awk migration (M1 fix).
d_vsm1="$TMP/vs-m1-unspaced"; mkdir -p "$d_vsm1"
{ echo '# T'; echo
  env9 0 7 8 0 0 0 0; echo
  echo '## Coverage'
  echo 'Coverage metric: 7/8'; echo "Declared gaps closed: 7/7"; echo
  echo '## Gap-backlog'; echo
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | g | t | covered |\n\n'
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps — read-only investigable**: 0'; } > "$d_vsm1/RESEARCH-STATE.md"
_vsm1_out="$(bash "$SUT" "$d_vsm1" 2>&1)"
if echo "$_vsm1_out" | grep -qi 'contradictory'; then
  ok "VS-M1-DENOM-UNSPACED: unspaced fractions 7/8 vs 7/7 detected as contradictory denominators (M1 awk fix)"
else
  no "VS-M1-DENOM-UNSPACED: expected contradictory-denominators WARN for 7/8 vs 7/7 — got: [$(echo "$_vsm1_out" | grep -i denom | head -1)]"
fi

# VS-N1-OOB-PER-SECTION: OOB-WARN fires once per section with count, not per row.
d_vsn1="$TMP/vs-n1-oob"; mkdir -p "$d_vsn1"
{ echo '# T'; echo
  env9 0 0 0 0 0 0 0; echo
  echo '## Other section'; echo
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | oob1 | t | pending |\n'
  printf '| medium | oob2 | t | pending |\n'
  echo
  echo '## Gap-backlog'; echo
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps — read-only investigable**: 0'; } > "$d_vsn1/RESEARCH-STATE.md"
_vsn1_warn="$(bash "$SUT" "$d_vsn1" 2>&1)"
_vsn1_count="$(echo "$_vsn1_warn" | grep -ic 'outside.*gap-backlog')"
_vsn1_has2="$(echo "$_vsn1_warn" | grep -i 'outside.*gap-backlog' | grep -c '2')"
if [ "$_vsn1_count" -eq 1 ] && [ "$_vsn1_has2" -ge 1 ]; then
  ok "VS-N1-OOB-PER-SECTION: 2 OOB rows → 1 WARN with count '2'"
elif [ "$_vsn1_count" -eq 0 ]; then
  no "VS-N1-OOB-PER-SECTION: no OOB-WARN — expected 1 per-section WARN"
elif [ "$_vsn1_count" -gt 1 ]; then
  no "VS-N1-OOB-PER-SECTION: $_vsn1_count WARNs — expected exactly 1 (got per-row)"
else
  no "VS-N1-OOB-PER-SECTION: WARN fired but no count '2' — got: [$(echo "$_vsn1_warn" | grep -i outside | head -1)]"
fi

# VS-N3-COVERED-PIPE-WARN: 5-col COVERED row with extra cell → WARN in verify-state mirror.
d_vsn3="$TMP/vs-n3-cov-pipe"; mkdir -p "$d_vsn3"
{ echo '# T'; echo
  env9 0 1 1 0 0 0 0; echo
  echo '## Gap-backlog'; echo
  printf '| Priority | Gap | Scope | Where | Status |\n|---|---|---|---|---|\n'
  printf '| high | g | web | src | covered | extra |\n\n'
  echo '## Coverage'; echo 'Coverage metric: 1/1'
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps — read-only investigable**: 0'; } > "$d_vsn3/RESEARCH-STATE.md"
_vsn3_warn="$(bash "$SUT" "$d_vsn3" 2>&1)"
if echo "$_vsn3_warn" | grep -qi 'COVERED row'; then
  ok "VS-N3-COVERED-PIPE-WARN: 5-col COVERED row with extra cell → VS-COVERED-PIPE-WARN emitted"
else
  no "VS-N3-COVERED-PIPE-WARN: expected COVERED-pipe WARN — got: [$(echo "$_vsn3_warn" | head -2)]"
fi

# VS-N3-MALFORMED-SCOPE: malformed WARN scoped to in_backlog && in_data in the mirror too.
d_vsn3m="$TMP/vs-n3-malf-scope"; mkdir -p "$d_vsn3m"
{ echo '# T'; echo
  env9 0 0 0 0 0 0 0; echo
  echo '## Other section'; echo
  printf '| P | G | t | S |\n|---|---|---|---|\n'
  printf '| high | g | t | pending | extra |\n\n'
  echo '## Gap-backlog'; echo
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps — read-only investigable**: 0'; } > "$d_vsn3m/RESEARCH-STATE.md"
_vsn3m_warn="$(bash "$SUT" "$d_vsn3m" 2>&1)"
if ! echo "$_vsn3m_warn" | grep -qi 'malformed'; then
  ok "VS-N3-MALFORMED-SCOPE: malformed row outside Gap-backlog → no malformed WARN in verify-state"
else
  no "VS-N3-MALFORMED-SCOPE: malformed WARN fired outside Gap-backlog — scope fix missing: [$(echo "$_vsn3m_warn" | grep -i malformed | head -1)]"
fi

# NEGATIVE CONTROL — prove CHECK 1 (the STALE detection) has TEETH via mutation.
if [ "${1:-}" = "--prove-teeth" ]; then
  # Seed the shared lib into $TMP/lib/ so every mutant SUT placed in $TMP can source it.
  # verify-state.sh resolves its lib as $(dirname $0)/lib/focus-prefix.sh; a mutant in $TMP
  # needs the lib at $TMP/lib/focus-prefix.sh (same pattern: research-sdd-status.test.sh copies
  # verify-state.sh to $TMP so the mutant status.sh can call it as $here/verify-state.sh).
  mkdir -p "$TMP/lib"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  cp "$HERE/../lib/block-files.sh" "$TMP/lib/block-files.sh"  # SUT sources at $(dirname $0)/lib/

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
  # NOTE: SC-CROSS-CHECK (#599) also fires when stop-control prose diverges from derived.  To isolate CHECK B,
  # we use a fresh fixture where prose=derived (2) so SC-CROSS-CHECK stays silent, and only the envelope
  # mismatch (declared=0 vs derived=2) can trigger a failure.  Without CHECK B, the mutant exits 0.
  echo "-- teeth: neuter ENVELOPE CHECK B (investigable_open); expect the under-declared fixture to pass --"
  mutantE="$TMP/verify-state.ENVB.MUTANT.sh"
  sed 's/^\( *\)if ! is_int "\$e_inv" .*then$/\1if false; then  # MUTANT: envelope investigable check neutered/' "$SUT" > "$mutantE"
  if ! grep -q 'MUTANT: envelope investigable check neutered' "$mutantE"; then
    no "teeth(envB): could not build mutant (CHECK B guard line not found — did the SUT change?)"
  else
    # Isolation fixture: envelope investigable_open=0 (under-declared) but prose=2 (matches derived).
    # SC-CROSS-CHECK: prose=2 == derived=2 → silent.  CHECK B (neutered): silent.  → exit 0.
    d_envb_iso="$TMP/env-inv-under-envb-iso"; mkdir -p "$d_envb_iso"
    { printf '# T — Research State\n\n'
      printf '<!-- research-state.v1 -->\n'
      printf 'schema: research-state.v1\ncovered_blocks: 0\n'
      printf 'gaps_closed: 4\nknown_gaps: 10\n'
      printf 'investigable_open: 0\nrequires_execution_open: 0\nblocked_open: 1\n'
      printf '<!-- /research-state.v1 -->\n\n'
      printf '## Coverage\n- **Coverage metric**: 4 / 10 closed\n\n'
      printf '## Gap-backlog (prioritized)\n\n'
      printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
      printf '| high | reconstruct pipeline | web | pending |\n'
      printf '| medium | map loaders | web | pending |\n\n'
      printf '## Blocked gaps\n- gpu profiling — needs: hardware\n\n'
      printf '## Stop control\n- **Open gaps — read-only investigable**: 2\n'
    } > "$d_envb_iso/RESEARCH-STATE.md"
    bash "$mutantE" "$d_envb_iso" >/dev/null 2>&1; egot=$?
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

  # ---- B3c mutation: restrict blocked section to omit ## Blocked / prefix (remove Blocked-slash branch) ----
  # Use the B3c-FAIL fixture: 1 Blocked-slash entry, envelope blocked_open=0 (wrong).
  # Real SUT: derive_blocked finds the entry → d_blocked=1 ≠ e_blocked=0 → FAIL (exit 1).
  # Mutant (without ## Blocked /): derive_blocked=0, e_blocked=0 → match → exit 0 (FALSE-PASS).
  echo "-- teeth: B3c — remove Blocked-slash section from derive_blocked; B3c-FAIL fixture must false-pass --"
  mutantBS="$TMP/verify-state.B3BS.MUTANT.sh"
  sed "s|; _section \"\\\$1\" '## Blocked /'||g" "$SUT" > "$mutantBS"
  if grep -q "section.*'## Blocked /'" "$mutantBS"; then
    no "teeth(B3c): could not build Blocked-slash mutant (pattern still present — did the SUT change?)"
  else
    d="$TMP/blocked-slash-fail"   # reuse B3c-FAIL: 1 Blocked-slash entry, envelope blocked_open=0 (wrong)
    bash "$mutantBS" "$d" >/dev/null 2>&1; mbsgot=$?
    if [ "$mbsgot" = 0 ]; then
      ok "teeth(B3c): mutant ignores Blocked-slash → false-passes (mismatch undetected) → triple-section fix is load-bearing"
    else no "teeth(B3c): mutant exit $mbsgot (want 0) — Blocked-slash detection may not depend on the fix (THEATER)"; fi
  fi

  # ---- B911a mutation: remove RSDD-CHILD-GAPS-ANCHOR awk block → multi-line child-gap entry undetected ----
  # Use the B911a-FAIL fixture: 1 child-gaps entry with `needs:` on continuation, envelope blocked_open=0 (wrong).
  # Real SUT: derive_blocked finds the entry via awk → d_blocked=1 ≠ e_blocked=0 → FAIL (exit 1).
  # Mutant (child-gaps awk removed): _d2=0, d_blocked=0 == e_blocked=0 → no mismatch → exit 0 (FALSE-PASS).
  # Build via python3: the awk heredoc contains single quotes that confuse sed.
  echo "-- teeth: B911a — remove RSDD-CHILD-GAPS-ANCHOR awk from derive_blocked; B911a-FAIL fixture must false-pass --"
  mutant911a="$TMP/verify-state.B911A.MUTANT.sh"
  if grep -q '# RSDD-CHILD-GAPS-ANCHOR' "$SUT"; then
    python3 - "$SUT" "$mutant911a" <<'PYEOF'
import sys, re
src = open(sys.argv[1]).read()
# Remove the _d2 assignment (the RSDD-CHILD-GAPS-ANCHOR awk block) and change the echo to use only _d1.
# Strategy: replace the multi-line derive_blocked body with the old one-liner equivalent.
# Remove _d2 line and the echo $(( ... )) line; replace with a one-liner that only counts _d1.
mutant = re.sub(
    r'  # RSDD-CHILD-GAPS-ANCHOR.*?  echo \$\(\( \$\{_d1:-0\} \+ \$\{_d2:-0\} \)\)',
    '  echo "${_d1:-0}"',
    src,
    count=1,
    flags=re.DOTALL
)
open(sys.argv[2], 'w').write(mutant)
PYEOF
    if [ ! -f "$mutant911a" ]; then
      no "teeth(B911a): python3 did not write mutant file"
    elif grep -q 'RSDD-CHILD-GAPS-ANCHOR' "$mutant911a"; then
      no "teeth(B911a): could not build mutant (RSDD-CHILD-GAPS-ANCHOR still present after substitution)"
    else
      cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
      d="$TMP/child-gaps-single-fail"   # reuse B911a-FAIL: 1 child-gaps entry, blocked_open=0 (wrong)
      bash "$mutant911a" "$d" >/dev/null 2>&1; m911got=$?
      if [ "$m911got" = 0 ]; then
        ok "teeth(B911a): awk-removed mutant misses continuation entry (d=0 vs e=0 → false-pass) → RSDD-CHILD-GAPS-ANCHOR awk is load-bearing"
      else no "teeth(B911a): mutant exit $m911got (want 0) — child-gaps detection may not depend on the awk block (THEATER)"; fi
    fi
  else
    no "teeth(B911a): RSDD-CHILD-GAPS-ANCHOR sentinel not found in SUT (child-gaps awk block not implemented)"
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

  # ---- RSDD-PROSE-BLOCKED: revert derive_blocked to bullet-only; prose fixture must FAIL (not match) ----
  # Mutation: strip the |\*\*needs:\*\* branch from the grep in derive_blocked so prose paragraphs
  # are no longer counted. The T-PROSE-BLOCKED-MATCH fixture (blocked_open=1, prose entry) must then
  # FAIL because derived=0 != declared=1.  Proves the RSDD-PROSE-BLOCKED-ANCHOR branch is load-bearing.
  # python3 is used for the substitution because the target string contains backslash-asterisks that
  # are unreliable to escape through multiple layers of shell+sed quoting.
  echo "-- teeth-RSDD-PROSE: revert derive_blocked to bullet-only; prose fixture must FAIL (d=0 vs e=1) --"
  mutantPROSE="$TMP/verify-state.PROSE.MUTANT.sh"
  if grep -q '# RSDD-PROSE-BLOCKED-ANCHOR' "$SUT"; then
    python3 - "$SUT" "$mutantPROSE" <<'PYEOF'
import sys
src = open(sys.argv[1]).read()
# Remove the prose branch (the ERE alternative) from derive_blocked's grep pattern.
# The literal text in the source file is: |\*\*needs:\*\*
mutant = src.replace(r'|\*\*needs:\*\*', '', 1)
open(sys.argv[2], 'w').write(mutant)
PYEOF
    if ! grep -q 'RSDD-PROSE-BLOCKED-ANCHOR' "$mutantPROSE"; then
      no "teeth-RSDD-PROSE: python3 strip removed sentinel line unexpectedly — mutant broken"
    elif grep -qF '|\*\*needs:\*\*' "$mutantPROSE"; then
      no "teeth-RSDD-PROSE: could not build mutant (prose branch still present after substitution)"
    else
      cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
      d="$TMP/prose-blocked-match"   # reuse T-PROSE-BLOCKED-MATCH fixture: blocked_open=1, 1 prose entry
      bash "$mutantPROSE" "$d" >/dev/null 2>&1; mprosegot=$?
      if [ "$mprosegot" = 1 ]; then
        ok "teeth-RSDD-PROSE: bullet-only mutant misses prose entry (d=0 vs e=1 → FAIL) → prose branch is load-bearing"
      else no "teeth-RSDD-PROSE: mutant exit $mprosegot (want 1) — prose detection may not depend on the added branch (THEATER)"; fi
    fi
  else
    no "teeth-RSDD-PROSE: RSDD-PROSE-BLOCKED-ANCHOR sentinel not found in SUT"
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

  # BS-global-ok mutation: revert _derive_attributed_sg to corpus total → attributed-match fixture FAILs.
  # fixture: covered_blocks=3, attributed=3, corpus=5 → PASS; mutant: attributed=corpus=5 → 3≠5 → FAIL.
  echo "-- teeth-BS-global-ok: revert _derive_attributed_sg to corpus total; attributed-match fixture must FAIL --"
  mutantBSGO="$TMP/verify-state.BSGLOBALOK.MUTANT.sh"
  sed 's/^_derive_attributed_sg() {$/_derive_attributed_sg() { echo "$_ondisk_global"; return  # MUTANT-SGOK/' "$SUT" > "$mutantBSGO"
  if ! grep -q 'MUTANT-SGOK' "$mutantBSGO"; then
    no "teeth-BS-global-ok: could not build mutant (_derive_attributed_sg header not found — did SUT change?)"
  else
    cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
    d="$TMP/bs-global-ok"
    bash "$mutantBSGO" "$d" >/dev/null 2>&1; mbsgogot=$?
    if [ "$mbsgogot" = 1 ]; then
      ok "teeth-BS-global-ok: corpus-total mutant → covered_blocks=3 ≠ corpus 5 → FAIL → attributed check has teeth"
    else no "teeth-BS-global-ok: mutant exit $mbsgogot (want 1) — attributed check not load-bearing (THEATER)"; fi
  fi

  # BS-global-stale mutation: neuter SG-ATTR-CHECK → attributed mismatch (10 vs 3) undetected → exit 0.
  echo "-- teeth-BS-global-stale: neuter SG-ATTR-CHECK; covered_blocks=10 vs attributed 3 must stop FAILing --"
  mutantBSGS="$TMP/verify-state.BSGLOBALSTALE.MUTANT.sh"
  sed 's/^\( *\)elif ! is_int "\$e_covered" || \[ "\$e_covered" != "\$_sg_attributed" \]; then  # SG-ATTR-CHECK$/\1elif false; then  # MUTANT-BSGS/' "$SUT" > "$mutantBSGS"
  if ! grep -q 'MUTANT-BSGS' "$mutantBSGS"; then
    no "teeth-BS-global-stale: could not build mutant (SG-ATTR-CHECK sentinel not found — did SUT change?)"
  else
    cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
    d="$TMP/bs-global-stale"
    bash "$mutantBSGS" "$d" >/dev/null 2>&1; mbsgsgot=$?
    if [ "$mbsgsgot" = 0 ]; then
      ok "teeth-BS-global-stale: SG-ATTR-CHECK neutered → 10 vs 3 undetected (exit 0) → mismatch check has teeth"
    else no "teeth-BS-global-stale: mutant exit $mbsgsgot (want 0) → mismatch check not load-bearing (THEATER)"; fi
  fi

  # SG-skip-attribution tooth (tooth-2): set _sg_attributed=0 → unverifiable INFO → true mismatch undetected.
  echo "-- teeth-SG-skip-attribution: set _sg_attributed=0; covered_blocks=19/attributed=17 must false-pass --"
  mutantSGSA="$TMP/verify-state.SGSKIPATRIB.MUTANT.sh"
  sed 's/^\( *\)_sg_attributed=.*# SG-DERIVE-ATTRIBUTED$/\1_sg_attributed="0"  # MUTANT-SGSA/' "$SUT" > "$mutantSGSA"
  if ! grep -q 'MUTANT-SGSA' "$mutantSGSA"; then
    no "teeth-SG-skip-attribution: could not build mutant (SG-DERIVE-ATTRIBUTED sentinel not found — did SUT change?)"
  else
    cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
    d="$TMP/sg-true-mismatch"
    bash "$mutantSGSA" "$d" >/dev/null 2>&1; msgsagot=$?
    if [ "$msgsagot" = 0 ]; then
      ok "teeth-SG-skip-attribution: attribution skipped → 19≠17 undetected (exit 0) — true-mismatch has teeth"
    else no "teeth-SG-skip-attribution: mutant exit $msgsagot (want 0) — skip has no effect (THEATER)"; fi
  fi

  # SG-scope tooth (tooth-3): neutered FOCUS-FILTER lints both focuses; focus-b mismatch propagates → exit 1.
  echo "-- teeth-SG-scope: neutered FOCUS-FILTER; focus-b mismatch propagates to --focus focus-a call → exit 1 --"
  if grep -q '# FOCUS-FILTER' "$SUT"; then
    mutantSGSCOPE="$TMP/verify-state.SGSCOPE.MUTANT.sh"
    cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
    sed '/# FOCUS-FILTER$/s/if \[ -n "\$focus_slug" \]; then/if false; then  # MUTANT-SGSCOPE/' "$SUT" > "$mutantSGSCOPE"
    d="$TMP/sg-scope"
    bash "$mutantSGSCOPE" "$d" --focus focus-a >/dev/null 2>&1; msgsgot=$?
    if [ "$msgsgot" = 1 ]; then
      ok "teeth-SG-scope: neutered filter → focus-b mismatch propagates (exit 1) — focus scoping has teeth"
    else no "teeth-SG-scope: mutant exit $msgsgot (want 1) — SG-scope isolation not load-bearing (THEATER)"; fi
  else
    no "teeth-SG-scope: FOCUS-FILTER sentinel not found in SUT"
  fi

  # SG-check2-skip tooth: remove _sg_check_a_done guard from CHECK 2 (SG-CHECK2-COND) → false WARN fires.
  # Mutation: strip [ "$_sg_check_a_done" = 0 ] && from the SG-CHECK2-COND if-line → CHECK 2 runs for
  # shared-global → prose 'Covered blocks: 3 of 5' vs corpus 5 triggers WARN on the no-false-warn fixture.
  echo "-- teeth-sg-check2-skip: remove _sg_check_a_done guard from SG-CHECK2-COND; false WARN must fire --"
  mu_sgck2="$TMP/verify-state.SGCK2.MUTANT.sh"
  if grep -q '# SG-CHECK2-COND' "$SUT"; then
    sed '/# SG-CHECK2-COND/ { s/ && \[ "\$_sg_check_a_done" = 0 \]//; s/# SG-CHECK2-COND/# MUTANT-SGCK2/ }' "$SUT" > "$mu_sgck2"
    if ! grep -q 'MUTANT-SGCK2' "$mu_sgck2"; then
      no "teeth-sg-check2-skip: could not build mutant (SG-CHECK2-COND substitution failed — did SUT change?)"
    else
      cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
      d="$TMP/sg-check2-no-false-warn"
      sgck2_out="$(bash "$mu_sgck2" "$d" 2>/dev/null)"
      if grep -q 'disagrees with' <<<"$sgck2_out"; then
        ok "teeth-sg-check2-skip: guard removed → false WARN fires on SG fixture → CHECK 2 SG guard is load-bearing"
      else no "teeth-sg-check2-skip: guard removed but no false WARN on SG fixture (THEATER)"; fi
    fi
  else
    no "teeth-sg-check2-skip: SG-CHECK2-COND sentinel not found in SUT"
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
  # teeth-n4-warn: silence the malformed-row WARN (VS-MALFORMED-WARN) → n!=4-warn fixture must
  # go red (no malformed-row WARN emitted by the silenced mutant).
  echo "-- teeth-n4-warn: silence VS-MALFORMED-WARN line; n4 fixture must emit no WARN --"
  n4w_mutant="$TMP/verify-state.n4w.MUTANT.sh"
  sed '/# VS-MALFORMED-WARN/s/.*/      if (in_backlog \&\& in_data) { next }  # MUTANT-N4-WARN/' "$SUT" > "$n4w_mutant"; cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  warn_n4m="$(bash "$n4w_mutant" "$TMP/n4-warn" 2>&1 >/dev/null)"
  if ! grep -qiE 'WARN.*malformed backlog row' <<<"$warn_n4m"; then
    ok "teeth-n4-warn: VS-MALFORMED-WARN-silenced mutant emits no WARN — malformed-WARN assertion has teeth"
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
      # F2c teeth: neutered mutant lints BOTH (empty + consistent) → 2 headers (pre-fix RED path)
      echo "-- teeth-FOCUS-F2c: neutered → must show 2 headers, not 1 --"
      foc2c_out="$(bash "$mutantFOC" "$TMP/focus-empty-file" --focus database 2>/dev/null)"
      if ! grep -c '== verify-state:' <<<"$foc2c_out" | grep -q '^1$'; then
        ok "teeth-FOCUS-F2c: neutered → multiple headers (not 1) — empty-file isolation has teeth (pre-fix RED)"
      else
        no "teeth-FOCUS-F2c: neutered mutant still shows only 1 header — THEATER"
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

  # teeth-F2C-empty (-f→-s): the anti-collapse tooth F2b lacked. F2b's nonempty-but-thin fixture
  # is non-empty, so both -f and -s would be true → `! -s` false → the guard would NOT exit 2 even
  # under -f→-s mutation; the -f/-s boundary is invisible to F2b. The 0-byte F2c fixture is where
  # the two operators diverge: `-f` → file exists (don't exit 2); `-s` → file is empty (exit 2).
  # Mutating the guard to `[ ! -s "$_focused" ]` collapses the §7 EMPTY state into ABSENT.
  # F2c expects exit ≠ 2; mutant exits 2 → F2c goes RED. This is the tooth that closes the gap.
  echo "-- teeth-F2C-empty: -f→-s in focus-absent guard; 0-byte focus file must exit 2 (anti-collapse) --"
  mutantF2C="$TMP/verify-state.F2C.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if ! grep -q '! -f "$_focused"' "$SUT"; then
    no "teeth-F2C-empty: anchor '! -f \"\$_focused\"' not found in SUT — guard drifted; update anchor"
  else
    sed 's/\[ ! -f "\$_focused" \]/[ ! -s "$_focused" ]/' "$SUT" > "$mutantF2C"
    _sut_f2c_h="$(md5sum "$SUT" | cut -d' ' -f1)"; _mut_f2c_h="$(md5sum "$mutantF2C" | cut -d' ' -f1)"
    if [ "$_sut_f2c_h" = "$_mut_f2c_h" ]; then
      no "teeth-F2C-empty: sed no-op — mutant == SUT — -f→-s recipe not applied (guard may have drifted)"
    else
      bash "$mutantF2C" "$TMP/focus-empty-file" --focus database >/dev/null 2>&1; mf2c_rc=$?
      if [ "$mf2c_rc" = 2 ]; then
        ok "teeth-F2C-empty: -f→-s mutant exits 2 on 0-byte file — anti-collapse tooth bites (§7 empty ≠ absent)"
      else
        no "teeth-F2C-empty: -f→-s mutant exit $mf2c_rc (want 2) — THEATER"
      fi
    fi
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

  # ---- MA-1 teeth: revert metric grep to old pattern; table-header fixture must report <none> ----
  # The fix anchors to 'coverage metric:'; the old pattern matched 'gaps? closed' → head-1 picked
  # the table header → <none>. Mutation: replace the anchored grep (tagged CM-ANCHOR-GREP) with the
  # old broad pattern. MA-1 expects 13/15; mutant reports <none> → MA-1 goes RED.
  echo "-- teeth-MA-1: revert metric grep to old 'gaps? closed' pattern; table-header fixture must report <none> --"
  mutantMA="$TMP/verify-state.MA.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# CM-ANCHOR-GREP' "$SUT"; then
    sed '/# CM-ANCHOR-GREP/s/.*/  metric="$(grep -iE '"'"'coverage metric|declared gaps closed|gaps? closed'"'"' "$state" 2>\/dev\/null | head -1)"/' \
      "$SUT" > "$mutantMA"
    if ! grep -q "gaps? closed" "$mutantMA"; then
      no "teeth-MA-1: could not build mutant (CM-ANCHOR-GREP sentinel not found or replacement failed)"
    else
      ma_mut_out="$(bash "$mutantMA" "$TMP/metric-anchor-table-header" 2>/dev/null)"
      if grep -qE 'coverage metric\s*:\s*<none>' <<<"$ma_mut_out"; then
        ok "teeth-MA-1: old broad pattern → table-header shadows real metric → <none> reported → MA-1 anchor is load-bearing"
      else
        no "teeth-MA-1: old pattern did NOT report <none> — got: $(grep -iE 'coverage metric' <<<"$ma_mut_out" | head -1)"
      fi
    fi
  else
    no "teeth-MA-1: CM-ANCHOR-GREP sentinel not found in SUT (metric grep not tagged — did SUT change?)"
  fi

  # ---- DW-1 teeth: neuter the BR cache → near-miss WARN must fire multiple times ----
  # With the cache, awk runs once → 1 NM-WARN. Without it (BR-CACHE-HIT bypassed), awk runs
  # 4× → 4 NM-WARNs. Mutation: replace the cache-hit return with a no-op (cache always misses).
  echo "-- teeth-DW-1: neuter BR-CACHE-HIT; near-miss WARN must fire >1 time (deduplication is load-bearing) --"
  mutantDW="$TMP/verify-state.DW.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# BR-CACHE-HIT' "$SUT"; then
    sed '/# BR-CACHE-HIT/s/.*/  if false; then  # MUTANT-DW: cache neutered/' "$SUT" > "$mutantDW"
    if ! grep -q 'MUTANT-DW: cache neutered' "$mutantDW"; then
      no "teeth-DW-1: could not build mutant (BR-CACHE-HIT sentinel substitution failed)"
    else
      dw_mut_stderr="$(bash "$mutantDW" "$TMP/dup-warn-once" 2>&1 >/dev/null)"
      dw_mut_count="$(grep -c 'near-miss' <<<"$dw_mut_stderr")"
      if [ "$dw_mut_count" -gt 1 ]; then
        ok "teeth-DW-1: neutered cache → ${dw_mut_count}× near-miss WARNs (>1) → DW-1 deduplication is load-bearing"
      else
        no "teeth-DW-1: neutered mutant emitted ${dw_mut_count}× WARN (want >1) — DW-1 may not depend on cache (THEATER)"
      fi
    fi
  else
    no "teeth-DW-1: BR-CACHE-HIT sentinel not found in SUT (cache not implemented or not tagged)"
  fi

  # ---- teeth-IDENT: neuter IDENTITY-SUM-CHECK → stale-denominator WARN must disappear ----
  # Mutation: replace the comparison `[ "$_identity_sum" -ne "$e_kg" ]` with `false`.
  # The stale-denominator fixture (ident-mismatch, kg=10, declared sum=7) must no longer emit the WARN →
  # IDENT-A's 'WARN expected' assertion would go RED, proving the check is load-bearing.
  echo "-- teeth-IDENT: neuter IDENTITY-SUM-CHECK; stale-denominator WARN must be absent --"
  mutantIDENT="$TMP/verify-state.IDENT.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# IDENTITY-SUM-CHECK' "$SUT"; then
    sed '/# IDENTITY-SUM-CHECK/s/\[ "\$_identity_sum" -ne "\$e_kg" \]/false/' "$SUT" > "$mutantIDENT"
    if ! grep -q 'false.*# IDENTITY-SUM-CHECK' "$mutantIDENT"; then
      no "teeth-IDENT: could not build mutant (IDENTITY-SUM-CHECK sentinel substitution failed — did SUT change?)"
    else
      ident_mut_out="$(bash "$mutantIDENT" "$TMP/ident-mismatch" 2>/dev/null)"
      if ! grep -qE 'WARN.*sum of declared counters.*stale denominator' <<<"$ident_mut_out"; then
        ok "teeth-IDENT: neutered IDENTITY-SUM-CHECK → stale-denominator WARN absent → IDENT-A is load-bearing"
      else
        no "teeth-IDENT: neutered mutant still emitted stale-denominator WARN — THEATER"
      fi
    fi
  else
    no "teeth-IDENT: IDENTITY-SUM-CHECK sentinel not found in SUT (check not implemented or not tagged)"
  fi

  # ---- teeth-IDENT-C: replace IDENTITY-REQ-VAR (e_req) → d_req in sum; prose-tracked fixture must WARN ----
  # Mutation: replace e_req with d_req in the _identity_sum line (anchored by IDENTITY-REQ-VAR sentinel).
  # For the prose-tracked fixture (ident-prose-req: e_req=1, d_req=0, declared sum=7=kg):
  #   mutant uses d_req=0 → sum = e_gc+e_inv+e_blocked+_h_def+d_req = 4+1+1+0+0 = 6 ≠ kg=7
  #   → stale-denominator WARN fires → IDENT-C's "no WARN" assertion goes RED → teeth proved.
  # This proves the declared-vs-derived distinction in the sum is load-bearing.
  echo "-- teeth-IDENT-C: replace e_req→d_req (IDENTITY-REQ-VAR); prose-tracked fixture must fire WARN --"
  mutantIDENT_C="$TMP/verify-state.IDENT_C.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# IDENTITY-REQ-VAR' "$SUT"; then
    sed '/# IDENTITY-REQ-VAR/s/e_req/d_req/' "$SUT" > "$mutantIDENT_C"
    if ! grep -q 'd_req.*# IDENTITY-REQ-VAR' "$mutantIDENT_C"; then
      no "teeth-IDENT-C: could not build mutant (IDENTITY-REQ-VAR sentinel substitution failed — did SUT change?)"
    else
      ident_c_mut_out="$(bash "$mutantIDENT_C" "$TMP/ident-prose-req" 2>/dev/null)"
      if grep -qE 'WARN.*sum of declared counters.*stale denominator' <<<"$ident_c_mut_out"; then
        ok "teeth-IDENT-C: e_req→d_req mutant fires stale-denominator WARN on prose-tracked fixture → IDENT-C declared-vs-derived distinction is load-bearing"
      else
        no "teeth-IDENT-C: e_req→d_req mutant did NOT fire stale-denominator WARN — IDENT-C may have no teeth against the declared/derived distinction"
      fi
    fi
  else
    no "teeth-IDENT-C: IDENTITY-REQ-VAR sentinel not found in SUT (check not implemented or not tagged)"
  fi

  # ---- teeth-IDENT-D: restore is_int(e_def) in IDENTITY-INT-GUARD → absent-def fixture must go silent ----
  # Mutation: prepend `is_int "$e_def" &&` before `is_int "$e_req"; then` on the IDENTITY-INT-GUARD line.
  # IDENT-D's ewrite fixture has no deferred_open → e_def="" → is_int("") = false → guard short-circuits →
  # CHECK H skips → stale-denominator WARN absent.
  # IDENT-D's 'WARN expected' assertion goes RED, proving the absent-def-as-0 path is load-bearing.
  echo "-- teeth-IDENT-D: restore is_int(e_def) in IDENTITY-INT-GUARD; absent-def fixture must go silent --"
  mutantIDENT_D="$TMP/verify-state.IDENT_D.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# IDENTITY-INT-GUARD' "$SUT"; then
    sed '/# IDENTITY-INT-GUARD/s/is_int "\$e_req"; then/is_int "$e_def" \&\& is_int "$e_req"; then/' "$SUT" > "$mutantIDENT_D"
    if ! grep -q 'is_int.*e_def.*# IDENTITY-INT-GUARD' "$mutantIDENT_D"; then
      no "teeth-IDENT-D: could not build mutant (IDENTITY-INT-GUARD substitution failed — did SUT change?)"
    else
      ident_d_mut_out="$(bash "$mutantIDENT_D" "$TMP/ident-absent-def" 2>/dev/null)"
      if ! grep -qE 'WARN.*sum of declared counters.*stale denominator' <<<"$ident_d_mut_out"; then
        ok "teeth-IDENT-D: restored is_int(e_def) → absent-def fixture silent → IDENT-D absent-as-0 fix is load-bearing"
      else
        no "teeth-IDENT-D: restored is_int(e_def) mutant still WARNed on absent-def fixture — THEATER"
      fi
    fi
  else
    no "teeth-IDENT-D: IDENTITY-INT-GUARD sentinel not found in SUT"
  fi

  # ---- teeth-634-BOLD: remove ** stripping from _backlog_rows; pending** row must NOT be counted ----
  # Mutation: replace the VS-634-BOLD-STRIP tagged awk line with one that omits gsub calls.
  # T-634a fixture (t634-trailing-bold) has Status 'pending**'; without stripping, st='pending**'
  # does not match 'pending' → derive_investigable=0 ≠ envelope=1 → CHECK B FAIL → exit 1.
  # T-634a expects exit 0 → assertion goes RED → VS-634-BOLD-STRIP is load-bearing.
  echo "-- teeth-634-BOLD: remove ** stripping (VS-634-BOLD-STRIP); pending** row must NOT count as investigable --"
  mutant634="$TMP/verify-state.634-BOLD.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# VS-634-BOLD-STRIP' "$SUT"; then
    sed '/# VS-634-BOLD-STRIP/s/.*/      { st=tolower(a[4]) }  # VS-634-BOLD-STRIP-MUTANT: stripping removed/' "$SUT" > "$mutant634"
    if ! grep -q '# VS-634-BOLD-STRIP-MUTANT' "$mutant634"; then
      no "teeth-634-BOLD: could not build mutant (VS-634-BOLD-STRIP replacement failed — did SUT change?)"
    else
      m634_out="$(bash "$mutant634" "$TMP/t634-trailing-bold" 2>/dev/null)"
      m634_rc=$?
      if [ "$m634_rc" != 0 ] || ! grep -qE 'ok +envelope validated' <<<"$m634_out"; then
        ok "teeth-634-BOLD: mutant without ** stripping fails T-634a (pending** unrecognised) → VS-634-BOLD-STRIP is load-bearing"
      else
        no "teeth-634-BOLD: mutant without ** stripping still passed T-634a — THEATER"
      fi
    fi
  else
    no "teeth-634-BOLD: VS-634-BOLD-STRIP sentinel not found in SUT"
  fi

  # ---- teeth-567-COVERED-PIPE-WARN: delete VS-567-COVERED-PIPE-WARN handler; 4-col COVERED pipe
  # row falls through to malformed WARN → T-567 (checks no 'malformed backlog row') goes RED.
  echo "-- teeth-567-COVERED-PIPE: delete COVERED-pipe handler (VS-567-COVERED-PIPE-WARN); row must emit malformed WARN --"
  mutant567="$TMP/verify-state.567-COVERED.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# VS-567-COVERED-PIPE-WARN' "$SUT"; then
    sed '/# VS-567-COVERED-PIPE-WARN/d' "$SUT" > "$mutant567"
    if grep -q '# VS-567-COVERED-PIPE-WARN' "$mutant567"; then
      no "teeth-567-COVERED-PIPE: could not build mutant (deletion failed — sentinel still present)"
    else
      t567m_err="$(bash "$mutant567" "$TMP/t567-covered-pipe" 2>&1 >/dev/null)"
      if grep -q 'malformed backlog row' <<<"$t567m_err"; then
        ok "teeth-567-COVERED-PIPE: removed COVERED-pipe handler → COVERED pipe row emits malformed WARN → T-567 goes RED → VS-567-COVERED-PIPE-WARN is load-bearing"
      else
        no "teeth-567-COVERED-PIPE: mutant did NOT emit malformed-row WARN for COVERED pipe row — THEATER"
      fi
    fi
  else
    no "teeth-567-COVERED-PIPE: VS-567-COVERED-PIPE-WARN sentinel not found in SUT"
  fi

  # ---- teeth-599-GB-PRESENT: negate GB-PRESENT-CHECK condition; absent backlog must pass silently ----
  # Mutation: change 'if ! grep' → 'if grep' so the FAIL fires when backlog IS present, not absent.
  # T-599a fixture (t599-no-backlog) has no ## Gap-backlog heading; with inverted condition,
  # grep finds nothing → 'if grep' is false → FAIL block not entered → exits 0 (false ok).
  # T-599a expects exit 1 + FAIL message → assertion goes RED → GB-PRESENT-CHECK is load-bearing.
  echo "-- teeth-599-GB-PRESENT: negate GB-PRESENT-CHECK condition; absent backlog must exit 0 (FAIL suppressed) --"
  mutantGB="$TMP/verify-state.599-GB.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# GB-PRESENT-CHECK' "$SUT"; then
    sed '/# GB-PRESENT-CHECK$/s/if ! grep/if grep/' "$SUT" > "$mutantGB"
    if ! grep -q 'if grep.*# GB-PRESENT-CHECK' "$mutantGB"; then
      no "teeth-599-GB-PRESENT: could not build mutant (negation failed — GB-PRESENT-CHECK line not found or changed?)"
    else
      gb_mut_out="$(bash "$mutantGB" "$TMP/t599-no-backlog" 2>/dev/null)"
      if ! grep -qiE 'FAIL.*Gap-backlog.*absent|FAIL.*absent.*Gap-backlog' <<<"$gb_mut_out"; then
        ok "teeth-599-GB-PRESENT: negated condition → absent backlog undetected → T-599a absent-FAIL assertion goes RED → GB-PRESENT-CHECK is load-bearing"
      else
        no "teeth-599-GB-PRESENT: negated mutant still produced absent-Gap-backlog FAIL — THEATER"
      fi
    fi
  else
    no "teeth-599-GB-PRESENT: GB-PRESENT-CHECK sentinel not found in SUT"
  fi

  # ---- teeth-599-SC-CROSS: neuter SC-CROSS-CHECK; stop-control mismatch must go undetected ----
  # Mutation: replace [ "$_sc_n" != "$d_inv" ] with false so the mismatch condition never fires.
  # T-599d fixture (t599-stopctl-mismatch) has prose=3 but derived=1; with neutered check,
  # the mismatch is not caught → exits 0 (false ok).
  # T-599d expects exit 1 + FAIL message → assertion goes RED → SC-CROSS-CHECK is load-bearing.
  echo "-- teeth-599-SC-CROSS: neuter SC-CROSS-CHECK; stop-control prose mismatch must be undetected --"
  mutantSC="$TMP/verify-state.599-SC.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# SC-CROSS-CHECK$' "$SUT"; then
    sed '/# SC-CROSS-CHECK$/s/\[ "\$_sc_n" != "\$d_inv" \]/false/' "$SUT" > "$mutantSC"
    if ! grep -q 'false.*# SC-CROSS-CHECK' "$mutantSC"; then
      no "teeth-599-SC-CROSS: could not build mutant (SC-CROSS-CHECK substitution failed — did SUT change?)"
    else
      bash "$mutantSC" "$TMP/t599-stopctl-mismatch" >/dev/null 2>&1; sc_mut_rc=$?
      if [ "$sc_mut_rc" = 0 ]; then
        ok "teeth-599-SC-CROSS: neutered SC-CROSS-CHECK → stop-control mismatch undetected → mutant exits 0 → T-599d assertion goes RED → SC-CROSS-CHECK is load-bearing"
      else
        no "teeth-599-SC-CROSS: neutered mutant still exits $sc_mut_rc for mismatch fixture — THEATER (another check may fire; review fixture)"
      fi
    fi
  else
    no "teeth-599-SC-CROSS: SC-CROSS-CHECK sentinel not found in SUT"
  fi

  # ---- teeth-SCEX-EXTRACT: revert extraction to buggy grep -oE '[0-9]+' | tail -1; T-SCEX-A must false-FAIL ----
  # Mutation: replace the anchored SCEX-EXTRACT-ANCHOR line with the old extraction that takes the LAST
  # number anywhere on the line. T-SCEX-A has value=3 but the annotation contains 0 ("hits 0"); the
  # buggy extraction returns 0, firing a false FAIL → T-SCEX-A's "no false FAIL" assertion goes RED.
  # T-SCEX-A expects exit 0 + ok line → assertion goes RED → SCEX-EXTRACT-ANCHOR extraction is load-bearing.
  echo "-- teeth-SCEX-EXTRACT: revert to buggy tail -1 extraction; T-SCEX-A must emit false FAIL --"
  mutantSCEX="$TMP/verify-state.SCEX.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# SCEX-EXTRACT-ANCHOR$' "$SUT"; then
    sed '/# SCEX-EXTRACT-ANCHOR$/s/.*/    _sc_n="$(printf '"'"'%s'"'"' "$_sc_prose" | grep -oE '"'"'[0-9]+'"'"' | tail -1)"  # MUTANT-SCEX/' "$SUT" > "$mutantSCEX"
    if ! grep -q '# MUTANT-SCEX' "$mutantSCEX"; then
      no "teeth-SCEX-EXTRACT: could not build mutant (SCEX-EXTRACT-ANCHOR substitution failed — did SUT change?)"
    else
      scex_out="$(bash "$mutantSCEX" "$TMP/t-scex-arrow" 2>/dev/null)"
      scex_rc=$?
      if [ "$scex_rc" = 1 ] && grep -qiE '  FAIL  .*investigable|  FAIL  .*stop.control' <<<"$scex_out"; then
        ok "teeth-SCEX-EXTRACT: reverted extraction returns 0 → false FAIL fires → T-SCEX-A exit-0 assertion goes RED → SCEX-EXTRACT-ANCHOR is load-bearing"
      else
        no "teeth-SCEX-EXTRACT: mutant exit $scex_rc, expected 1 with FAIL — T-SCEX-A does NOT depend on SCEX-EXTRACT-ANCHOR (THEATER)"
      fi
    fi
  else
    no "teeth-SCEX-EXTRACT: SCEX-EXTRACT-ANCHOR sentinel not found in SUT"
  fi

  # ---- teeth-566-KSW-P7: replace _ksw_has with false; P7 suppress must be skipped → WARN fires ----
  # Mutation: replace _ksw_has "p7-index-placeholder" with false so the suppress branch is never taken.
  # T-566a fixture (t566-p7-suppress) has known_stale_warns=p7-index-placeholder and INDEX.md placeholders;
  # with false, suppress block skipped → WARN fires instead of INFO.
  # T-566a expects no WARN + INFO line → assertion goes RED → KSW-P7-SUPPRESS is load-bearing.
  echo "-- teeth-566-KSW-P7: replace _ksw_has with false (KSW-P7-SUPPRESS); P7 WARN must fire despite known_stale_warns --"
  mutantP7="$TMP/verify-state.566-P7.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# KSW-P7-SUPPRESS' "$SUT"; then
    sed '/# KSW-P7-SUPPRESS/s/_ksw_has "p7-index-placeholder"/false/' "$SUT" > "$mutantP7"
    if ! grep -q 'if false.*# KSW-P7-SUPPRESS' "$mutantP7"; then
      no "teeth-566-KSW-P7: could not build mutant (KSW-P7-SUPPRESS substitution failed — did SUT change?)"
    else
      p7_mut_out="$(bash "$mutantP7" "$TMP/t566-p7-suppress" 2>/dev/null)"
      if grep -qE '^\s*WARN.*placeholder' <<<"$p7_mut_out"; then
        ok "teeth-566-KSW-P7: _ksw_has→false → suppress skipped → P7 WARN fires → T-566a no-WARN assertion goes RED → KSW-P7-SUPPRESS is load-bearing"
      else
        no "teeth-566-KSW-P7: mutant did NOT emit P7 placeholder WARN when suppress was disabled — THEATER"
      fi
    fi
  else
    no "teeth-566-KSW-P7: KSW-P7-SUPPRESS sentinel not found in SUT"
  fi

  # ---- teeth-566-KSW-CHECK2: replace _ksw_has with false; CHECK 2 suppress skipped → WARN fires ----
  # Mutation: replace _ksw_has "check-2-covered-blocks" with false.
  # T-566b fixture (t566-check2-suppress) has known_stale_warns=check-2-covered-blocks and
  # covered_blocks mismatch (claim=5, ondisk=1); with false, WARN fires instead of INFO.
  # T-566b expects no WARN + INFO → assertion goes RED → KSW-CHECK2-SUPPRESS is load-bearing.
  echo "-- teeth-566-KSW-CHECK2: replace _ksw_has with false (KSW-CHECK2-SUPPRESS); CHECK 2 WARN must fire --"
  mutantCK2="$TMP/verify-state.566-CK2.MUTANT.sh"
  cp "$FPLIB" "$TMP/lib/focus-prefix.sh"
  if grep -q '# KSW-CHECK2-SUPPRESS' "$SUT"; then
    sed '/# KSW-CHECK2-SUPPRESS/s/_ksw_has "check-2-covered-blocks"/false/' "$SUT" > "$mutantCK2"
    if ! grep -q 'if false.*# KSW-CHECK2-SUPPRESS' "$mutantCK2"; then
      no "teeth-566-KSW-CHECK2: could not build mutant (KSW-CHECK2-SUPPRESS substitution failed — did SUT change?)"
    else
      ck2_mut_out="$(bash "$mutantCK2" "$TMP/t566-check2-suppress" 2>/dev/null)"
      if grep -qE 'WARN.*disagrees with' <<<"$ck2_mut_out"; then
        ok "teeth-566-KSW-CHECK2: _ksw_has→false → CHECK 2 suppress skipped → mismatch WARN fires → T-566b no-WARN assertion goes RED → KSW-CHECK2-SUPPRESS is load-bearing"
      else
        no "teeth-566-KSW-CHECK2: mutant did NOT emit CHECK 2 disagrees WARN when suppress was disabled — THEATER"
      fi
    fi
  else
    no "teeth-566-KSW-CHECK2: KSW-CHECK2-SUPPRESS sentinel not found in SUT"
  fi

  # ---- CHECK P18 teeth (issue #630): neuter threshold guard → T-P18d (bsr=11 WARN) must go RED.
  echo "-- teeth-P18: neuter P18-THRESHOLD-WARN-CASE (replace condition with false); T-P18d WARN must vanish --"
  if grep -q '# P18-THRESHOLD-WARN-CASE' "$HERE/../verify-state.sh"; then
    mutantP18="$TMP/verify-state.P18.MUTANT.sh"
    sed '/# P18-THRESHOLD-WARN-CASE$/s/elif is_int.*/elif false; then  # MUTANT-P18/' \
      "$HERE/../verify-state.sh" > "$mutantP18"
    if grep -q '# P18-THRESHOLD-WARN-CASE' "$mutantP18"; then
      no "teeth-P18: could not build mutant (sed did not replace P18-THRESHOLD-WARN-CASE — check sed pattern)"
    else
      p18_mut_out="$(bash "$mutantP18" "$TMP/p18-exceeded" 2>/dev/null)"
      if ! grep -qiE 'WARN.*blocks_since_retro' <<<"$p18_mut_out"; then
        ok "teeth-P18: neutered threshold → bsr=11 no WARN emitted → T-P18d assertion goes RED → P18-THRESHOLD-WARN-CASE is load-bearing"
      else
        no "teeth-P18: mutant still emitted blocks_since_retro WARN — P18-THRESHOLD-WARN-CASE is THEATER or mutant broken"
      fi
    fi
  else
    no "teeth-P18: P18-THRESHOLD-WARN-CASE sentinel not found in SUT"
  fi

  # ---- teeth-VS-5COL: change (n==4||n==5)?n: to (n==4||n==5)?0: in BP-EXPECTED-COLS ternary
  # → 5-col tables get expected_cols=0 → sc falls back to 4 → 5-col rows fail n!=sc → VS-5COL-FAIL
  # sees derived investigable_open=0 = declared=0 → exits 0 (false pass) → guard is load-bearing.
  echo "-- teeth-VS-5COL: change ?n: to ?0: in BP-EXPECTED-COLS; 5-col pending row must be MISSED → VS-5COL-FAIL goes RED --"
  if grep -q '# BP-EXPECTED-COLS' "$HERE/../verify-state.sh"; then
    mutantBP="$TMP/verify-state.BP.MUTANT.sh"
    cp "$HERE/../verify-state.sh" "$mutantBP"
    sed -i 's/n==4||n==5)?n:-1/n==4||n==5)?0:-1/' "$mutantBP"
    if cmp -s "$mutantBP" "$HERE/../verify-state.sh"; then
      no "teeth-VS-5COL: mutant identical to SUT — sed did not apply mutation"
    elif ! bash -n "$mutantBP" 2>/dev/null; then
      no "teeth-VS-5COL: mutant has syntax error (bash -n) — mutation broke shell syntax"
    elif grep -q 'n==4||n==5)?n:-1' "$mutantBP"; then
      no "teeth-VS-5COL: sabotage check failed — ?n: still present in mutant"
    else
      bp_mut_exit="$(bash "$mutantBP" "$TMP/vs-5col-fail" >/dev/null 2>&1; echo $?)"
      if [ "$bp_mut_exit" = 0 ]; then
        ok "teeth-VS-5COL: mutant (?0: for 5-col) → 5-col pending row missed → VS-5COL-FAIL exits 0 (false pass) → BP-EXPECTED-COLS is load-bearing"
      else
        no "teeth-VS-5COL: mutant exit $bp_mut_exit (want 0) — VS-5COL-FAIL does not depend on BP-EXPECTED-COLS (THEATER)"
      fi
    fi
  else
    no "teeth-VS-5COL: BP-EXPECTED-COLS sentinel not found in verify-state.sh"
  fi

  # ---- teeth-VS-BP-LIST-ITEM-GUARD: delete the BP-LIST-ITEM-GUARD line from verify-state.sh;
  # the prose list item with | in d_vsli must then produce unknown-priority WARN → VS-LIST-ITEM goes RED.
  echo "-- teeth-VS-BP-LIST-ITEM-GUARD: delete guard → list item fires INVALID_PRIORITY → VS-LIST-ITEM RED --"
  if grep -q '# BP-LIST-ITEM-GUARD' "$HERE/../verify-state.sh"; then
    mutantLIG="$TMP/verify-state.LIG.MUTANT.sh"
    cp "$HERE/../verify-state.sh" "$mutantLIG"
    sed -i '/# BP-LIST-ITEM-GUARD/d' "$mutantLIG"
    if cmp -s "$mutantLIG" "$HERE/../verify-state.sh"; then
      no "teeth-VS-BP-LIST-ITEM-GUARD: mutant identical to SUT — sed did not delete the guard line"
    elif ! bash -n "$mutantLIG" 2>/dev/null; then
      no "teeth-VS-BP-LIST-ITEM-GUARD: mutant has syntax error (bash -n) — mutation broke shell syntax"
    elif grep -q '# BP-LIST-ITEM-GUARD' "$mutantLIG"; then
      no "teeth-VS-BP-LIST-ITEM-GUARD: sabotage check failed — BP-LIST-ITEM-GUARD sentinel still in mutant"
    else
      _vslig_out="$(bash "$mutantLIG" "$d_vsli" 2>&1)"
      if echo "$_vslig_out" | grep -qi 'unknown priority\|INVALID_PRIORITY\|backlog.*columns'; then
        ok "teeth-VS-BP-LIST-ITEM-GUARD: mutant (no guard) → list item fires WARN → VS-LIST-ITEM goes RED → BP-LIST-ITEM-GUARD is load-bearing"
      else
        no "teeth-VS-BP-LIST-ITEM-GUARD: mutant did not produce WARN for list item — guard not load-bearing (THEATER)"
      fi
    fi
  else
    no "teeth-VS-BP-LIST-ITEM-GUARD: BP-LIST-ITEM-GUARD sentinel not found in verify-state.sh"
  fi

  # ---- teeth-VS-BP-SEP-IN-BACKLOG: remove the "if (!in_backlog) next" guard from the separator
  # branch in verify-state.sh; all separators (including 6-col outside Gap-backlog) then go through
  # the expected_cols check → 6-col → expected_cols=-1 → BP-WIDTH-WARN fires → VS-SEP-OUTSIDE RED.
  echo "-- teeth-VS-BP-SEP-IN-BACKLOG: remove in_backlog guard → iteration-history separator fires BP-WIDTH-WARN → VS-SEP-OUTSIDE RED --"
  if grep -q 'BP-SEP-IN-BACKLOG' "$HERE/../verify-state.sh"; then
    mutantSIB="$TMP/verify-state.SIB.MUTANT.sh"
    cp "$HERE/../verify-state.sh" "$mutantSIB"
    sed -i 's/in_data=1; if (!in_backlog) next; expected_cols/in_data=1; expected_cols/' "$mutantSIB"
    if cmp -s "$mutantSIB" "$HERE/../verify-state.sh"; then
      no "teeth-VS-BP-SEP-IN-BACKLOG: mutant identical to SUT — sed did not remove the guard"
    elif ! bash -n "$mutantSIB" 2>/dev/null; then
      no "teeth-VS-BP-SEP-IN-BACKLOG: mutant has syntax error (bash -n) — mutation broke shell syntax"
    else
      _vssib_out="$(bash "$mutantSIB" "$d_vsso" 2>&1)"
      if echo "$_vssib_out" | grep -qi 'only 4- or 5-column\|backlog table has'; then
        ok "teeth-VS-BP-SEP-IN-BACKLOG: mutant (no guard) → iteration-history 6-col separator fires BP-WIDTH-WARN → VS-SEP-OUTSIDE goes RED → BP-SEP-IN-BACKLOG is load-bearing"
      else
        no "teeth-VS-BP-SEP-IN-BACKLOG: mutant did not fire BP-WIDTH-WARN for iteration-history separator — guard not load-bearing (THEATER)"
      fi
    fi
  else
    no "teeth-VS-BP-SEP-IN-BACKLOG: BP-SEP-IN-BACKLOG sentinel not found in verify-state.sh"
  fi

  # ---- teeth-VS-DENOM-PORT: change the denominator grep to the old form (no spaces required)
  # so 3011/5011 is parsed as a coverage fraction → contradictory-denominators WARN fires →
  # VS-DENOM-PORT goes RED. The port-number fix works by only extracting the FIRST fraction per
  # line (awk match, not global). Mutation: replace 'print substr ... RLENGTH' with a global
  # extractor (grep) to extract ALL fractions per line → 3011/5011 extracted too → false WARN.
  echo "-- teeth-VS-DENOM-PORT: extract all fractions (not just first) → 3011/5011 parsed as fraction → VS-DENOM-PORT RED --"
  if grep -q 'RSTART.*RLENGTH\|match.*RSTART' "$HERE/../verify-state.sh"; then
    mutantDP="$TMP/verify-state.DP.MUTANT.sh"
    # Replace the single-match awk with a global grep (extracts every fraction per line)
    python3 -c "
import sys
txt = open(sys.argv[1]).read()
old = \"    | LC_ALL=C awk 'match(\$0, /[0-9]+[[:space:]]*\\/[[:space:]]*[0-9]+/) { print substr(\$0, RSTART, RLENGTH) }' \\\\\"
new = \"    | grep -oE '[0-9]+[[:space:]]*\\/[[:space:]]*[0-9]+' \\\\\"
open(sys.argv[2], 'w').write(txt.replace(old, new))
" "$HERE/../verify-state.sh" "$mutantDP" 2>/dev/null
    if cmp -s "$mutantDP" "$HERE/../verify-state.sh" 2>/dev/null; then
      no "teeth-VS-DENOM-PORT: mutant identical to SUT — python3 replacement did not apply"
    elif ! bash -n "$mutantDP" 2>/dev/null; then
      no "teeth-VS-DENOM-PORT: mutant has syntax error (bash -n) — mutation broke shell syntax"
    else
      _vsdp_mut_out="$(bash "$mutantDP" "$d_vsdp" 2>&1)"
      if echo "$_vsdp_mut_out" | grep -qi 'contradictory.*denominators\|denominators.*3011\|denominators.*5011'; then
        ok "teeth-VS-DENOM-PORT: mutant (all-fractions grep) → 3011/5011 extracted → contradictory-denominators WARN → VS-DENOM-PORT goes RED → first-fraction-only awk is load-bearing"
      else
        no "teeth-VS-DENOM-PORT: mutant did not produce contradictory-denominators WARN — port-number fix not load-bearing (THEATER)"
      fi
    fi
  else
    no "teeth-VS-DENOM-PORT: awk-match sentinel (RSTART/RLENGTH) not found in verify-state.sh"
  fi

fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
