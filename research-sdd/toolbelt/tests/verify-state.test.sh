#!/usr/bin/env bash
# verify-state.test.sh — RED-FIRST harness for verify-state.sh's living-mirror consistency lint.
#
# WHY THIS SHAPE (anti-"test theater"): the load-bearing behaviour is CHECK 1 — the stale-mirror
# FAIL that fires ONLY when the coverage metric reads "X / X" (all gaps claimed closed) AND the
# backlog still lists `pending` gaps. That exact desync (summary said 23/23 closed while gaps were
# still pending) is what let the pruebas-dashboards run-A emit a PREMATURE STOP. The discriminating
# cases feed a KNOWN-STALE state file and assert the linter CATCHES it (exit 1); the boundary cases
# (X != Y, or no metric) assert CHECK 1 stays SILENT so the check is provably gated on X==Y, not on
# "pending exists". verify-state.sh is now a shim to `rsdd verify state` (kit issue #2457): the cases below run the
# SHIM end to end against the real Go binary (RSDD_BIN, else built once from research-sdd/rsdd), and the report is
# also pinned byte for byte against the frozen bash script by the Go differential tests (internal/verify,
# `make test`). The cases that needed a doctored PATH (no jq, no realpath, a failing awk or grep) or a source seam
# into the old script (an exported `cd`, an extracted function) are gone with those tools: the Go port parses the
# settings and resolves paths in process. --prove-teeth mutates the SHIM (each mutant must lose its case); the Go
# source has its own mutation gate (`make teeth` in research-sdd/rsdd).
#
# Usage: verify-state.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-state.sh"
FPLIB="$HERE/../lib/focus-prefix.sh"
[ -f "$SUT" ]   || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$FPLIB" ] || { echo "FATAL: helper not found: $FPLIB" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The Go binary the shim execs: the caller's RSDD_BIN, else one build into the temp dir.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$TMP/rsdd"
fi
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a fixture toolbelt
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
if [ "$(code "$d")" = 0 ] && ! <<<"$(grep -E '^   (FAIL|WARN)' <<<"$out")" grep -q 'requires_execution_open'; then
  ok "marked-open row + declared 1 → exit 0, CHECK E silent (backlog-anchored agreement)"
else no "req-agree: exit $(code "$d") :: $(grep -iE 'requires_execution_open' <<<"$out" | head -1)"; fi

# 31 — PROSE-TRACKED corpus (the logosoft shape): NO backlog marker at all, envelope carries a nonzero
#      declared count → exit 0 with CHECK E silent. Pins the calibration: a strict equality gate would
#      false-FAIL every prose-tracked corpus (declared N vs derived 0), which is exactly what CHECK E
#      must NOT do — derived 0 proves nothing.
d="$TMP/req-prose-only"; ewrite "$d" 0 4 7 1 1 1 "high|open read-only gap|pending"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! <<<"$(grep -E '^   (FAIL|WARN)' <<<"$out")" grep -q 'requires_execution_open'; then
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
if [ "$(code "$d")" = 0 ] && ! <<<"$(grep -E '^   (FAIL|WARN)' <<<"$out")" grep -q 'requires_execution_open'; then
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
if [ "$(code "$d")" = 0 ] && ! <<<"$(grep -E '^   (FAIL|WARN)' <<<"$out")" grep -q 'requires_execution_open'; then
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
if [ "$(code "$d")" = 0 ] && <<<"$(grep -c 'ok.*envelope validated' <<<"$out")" grep -q '^2$'; then
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
if [ "$(code "$d")" = 0 ] && ! grep -qE 'FAIL.*undocumented_findings|WARN.*undocumented_findings' <<<"$out"; then
  ok "G-absent: no undocumented_findings field → silent (no FAIL/WARN), exit 0 (legacy corpora not penalized)"
else no "G-absent: exit $(code "$d") :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-zero — undocumented_findings: 0 → exit 0, no FAIL or WARN about the field.
# SUGGESTION 8: the summary line now shows the field value; 'silent' means no FAIL/WARN, not no mention.
d="$TMP/uf-zero"; _uf_fixture "$d" 0
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'FAIL.*undocumented_findings|WARN.*undocumented_findings' <<<"$out"; then
  ok "G-zero: undocumented_findings=0 → exit 0, no FAIL or WARN"
else no "G-zero: exit $(code "$d") :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-ok-max — undocumented_findings: 3 → exit 0, no WARN (WARN fires only above 3, not at 3).
d="$TMP/uf-ok-max"; _uf_fixture "$d" 3
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'WARN.*undocumented_findings' <<<"$out"; then
  ok "G-ok-max: undocumented_findings=3 → exit 0, no WARN (boundary; WARN fires only >3)"
else no "G-ok-max: exit $(code "$d") :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-warn — undocumented_findings: 4 → WARN printed, exit still 0 (advisory, not a STOP hazard yet).
d="$TMP/uf-warn"; _uf_fixture "$d" 4
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'WARN.*undocumented_findings=4' <<<"$out"; then
  ok "G-warn: undocumented_findings=4 → WARN emitted, exit 0"
else no "G-warn: exit $(code "$d") (want 0) :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-warn-max — undocumented_findings: 6 → WARN still (FAIL fires only above 6, not at 6).
d="$TMP/uf-warn-max"; _uf_fixture "$d" 6
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'WARN.*undocumented_findings=6' <<<"$out"; then
  ok "G-warn-max: undocumented_findings=6 → WARN still, exit 0 (FAIL threshold is >6)"
else no "G-warn-max: exit $(code "$d") (want 0) :: $(echo "$out" | grep -iE 'undocumented' | head -1)"; fi

# G-fail — undocumented_findings: 7 → FAIL exit 1.
d="$TMP/uf-fail"; _uf_fixture "$d" 7
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*undocumented_findings=7' <<<"$out"; then
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
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*undocumented_findings' <<<"$out"; then
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
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*undocumented_findings' <<<"$out"; then
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
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*undocumented_findings' <<<"$out"; then
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
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*undocumented_findings' <<<"$out"; then
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
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*undocumented_findings' <<<"$out"; then
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
[ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*undocumented_findings' <<<"$out" \
  && ok "UF-pos-first: '  undocumented_findings: seven' FIRST in envelope → FAIL (probe is position-independent)" \
  || no "UF-pos-first: exit $(code "$d") :: $(grep -iE 'undocumented' <<<"$out" | head -1)"

# UF-pos-middle — field in the MIDDLE of the envelope (list-edges §7: MIDDLE position).
d="$TMP/uf-pos-middle"; mkdir -p "$d"
{ echo '# T — Research State'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\n  undocumented_findings: seven\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
[ "$(code "$d")" = 1 ] && grep -qE 'FAIL.*undocumented_findings' <<<"$out" \
  && ok "UF-pos-middle: '  undocumented_findings: seven' MIDDLE in envelope → FAIL" \
  || no "UF-pos-middle: exit $(code "$d") :: $(grep -iE 'undocumented' <<<"$out" | head -1)"

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

# ---- kit #1361 item 2: `unblock:` line on walls + `## Stretch goal` shape (METHODOLOGY §21.1 / §8c) ----
# Doctrine: every recorded wall ends with `unblock: <route> · owner: <who> · cost: <estimate>`; the
# `## Stretch goal` section (PROMPT-LOOP BOOTSTRAP, kit #1268) carries `realistic:` and `stretch:` lines.
# Both are WARN-only findings (exit stays 0). An ABSENT `## Stretch goal` is silent: the section is
# per-new-focus doctrine, older corpora legitimately lack it (the possibility audit records `stretch: not declared`).
# ub_state <dir> <n-blocked-bullets> <n-inplace-rows> <body-line...>
#   body lines are appended verbatim after the backlog; the envelope is ground-truth for the given counts.
ub_state(){
  local d="$1" nb="$2" nr="$3"; shift 3; mkdir -p "$d"
  { echo '# T — Research State'; echo
    env9 0 3 $((4+nb+nr-${UB_DEDUCT:-0})) 1 0 "$nb" 0; echo
    echo '## Coverage'; echo "- **Coverage metric**: 3 / $((4+nb+nr-${UB_DEDUCT:-0})) closed"
    echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
    echo '| high | active gap | web | pending |'
    # UB_ROWS (newline-separated full table rows) overrides the generated in-place rows; UB_DEDUCT lowers known_gaps
    # for a row that a Blocked-gaps bullet already counts once. Other envelope identity WARNs are tolerated.
    if [ -n "${UB_ROWS:-}" ]; then printf '%s\n' "$UB_ROWS"
    else local i=0; while [ "$i" -lt "$nr" ]; do i=$((i+1)); echo "| low | R$i wall gap | web | ${UB_ROWSTATUS:-blocked-on-operator} |"; done; fi; echo
    printf '%s\n' "$@"
  } > "$d/RESEARCH-STATE.md"
}
ub_warn_n(){ grep -E 'WARN.*missing an unblock:' <<<"$1" | grep -oE '[0-9]+ blocked' | head -1 | grep -oE '[0-9]+'; }
UBOK='unblock: add a ssh route · owner: operator · cost: 1h'
# list edges: the unblock-less bullet in FIRST / MIDDLE / LAST position, and the SINGLE-element list.
d="$TMP/ub-first"; ub_state "$d" 3 0 '## Blocked gaps' "- a — needs: x; tried: y" "- b — needs: x; tried: y; $UBOK" "- c — needs: x; tried: y; $UBOK"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && [ "$(ub_warn_n "$out")" = 1 ]; then ok "1361-first: unblock-less FIRST bullet → exactly 1 WARN, exit 0"
else no "1361-first: exit $(code "$d") n=$(ub_warn_n "$out") :: $out"; fi
d="$TMP/ub-middle"; ub_state "$d" 3 0 '## Blocked gaps' "- a — needs: x; tried: y; $UBOK" "- b — needs: x; tried: y" "- c — needs: x; tried: y; $UBOK"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && [ "$(ub_warn_n "$out")" = 1 ]; then ok "1361-middle: unblock-less MIDDLE bullet → exactly 1 WARN, exit 0"
else no "1361-middle: exit $(code "$d") n=$(ub_warn_n "$out") :: $out"; fi
d="$TMP/ub-last"; ub_state "$d" 3 0 '## Blocked gaps' "- a — needs: x; tried: y; $UBOK" "- b — needs: x; tried: y; $UBOK" "- c — needs: x; tried: y"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && [ "$(ub_warn_n "$out")" = 1 ]; then ok "1361-last: unblock-less LAST bullet → exactly 1 WARN, exit 0"
else no "1361-last: exit $(code "$d") n=$(ub_warn_n "$out") :: $out"; fi
# LAST bullet is also the last line of the FILE with no trailing newline (the §7 list-edge read() trap).
d="$TMP/ub-last-nonl"; ub_state "$d" 2 0 '## Blocked gaps' "- a — needs: x; tried: y; $UBOK" "- c — needs: x; tried: y"
printf '%s' "$(cat "$d/RESEARCH-STATE.md")" > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && [ "$(ub_warn_n "$out")" = 1 ]; then ok "1361-last-nonl: unblock-less final line without trailing newline → 1 WARN"
else no "1361-last-nonl: exit $(code "$d") n=$(ub_warn_n "$out") :: $out"; fi
d="$TMP/ub-single"; ub_state "$d" 1 0 '## Blocked gaps' "- a — needs: x; tried: y"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && [ "$(ub_warn_n "$out")" = 1 ]; then ok "1361-single: single unblock-less bullet → 1 WARN, exit 0"
else no "1361-single: exit $(code "$d") n=$(ub_warn_n "$out") :: $out"; fi
d="$TMP/ub-single-ok"; ub_state "$d" 1 0 '## Blocked gaps' "- a — needs: x; tried: y; $UBOK"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'WARN.*unblock:' <<<"$out"; then ok "1361-single-ok: single bullet with unblock: → no WARN"
else no "1361-single-ok: exit $(code "$d") :: $(grep -E 'unblock' <<<"$out")"; fi
d="$TMP/ub-two"; ub_state "$d" 3 0 '## Blocked gaps' "- a — needs: x; tried: y" "- b — needs: x; tried: y; $UBOK" "- c — needs: x; tried: y"
out="$(run "$d")"
if [ "$(ub_warn_n "$out")" = 2 ]; then ok "1361-two: two unblock-less bullets → counted as 2"
else no "1361-two: n=$(ub_warn_n "$out") :: $out"; fi
# continuation-line form: the unblock: plan sits on the line after the bullet → NOT missing.
d="$TMP/ub-cont"; ub_state "$d" 1 0 '## Blocked gaps' "- a — needs: x; tried: y" "  $UBOK"
out="$(run "$d")"
if ! grep -qE 'WARN.*unblock:' <<<"$out"; then ok "1361-cont: unblock: on a continuation line of the bullet → no WARN"
else no "1361-cont: $(grep -E 'unblock' <<<"$out")"; fi
# a plan on the NEXT bullet must not be credited to the previous one (entry boundary).
d="$TMP/ub-bound"; ub_state "$d" 2 0 '## Blocked gaps' "- a — needs: x; tried: y" "- b — needs: x; tried: y; $UBOK"
out="$(run "$d")"
if [ "$(ub_warn_n "$out")" = 1 ]; then ok "1361-boundary: the next bullet's unblock: is not credited to the previous entry"
else no "1361-boundary: n=$(ub_warn_n "$out")"; fi
# backlog ROWS (rows come from the mirrored _backlog_rows parser): a wall-typed Status without unblock: WARNs.
d="$TMP/ub-row"; ub_state "$d" 0 1 '## Stop control'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'WARN.*1 wall backlog row\(s\) missing an unblock:' <<<"$out"; then ok "1361-row: blocked-on-* backlog row without unblock: → WARN, exit 0"
else no "1361-row: exit $(code "$d") :: $out"; fi
d="$TMP/ub-row-ok"; UB_ROWSTATUS="blocked-on-operator · $UBOK" ub_state "$d" 0 1 '## Stop control'
out="$(run "$d")"
if ! grep -qE 'WARN.*unblock:' <<<"$out"; then ok "1361-row-ok: backlog row ending in unblock: → no WARN"
else no "1361-row-ok: $(grep -E 'unblock' <<<"$out")"; fi
# ub_row_n <out> : the N of "N wall backlog row(s) missing" (empty when the WARN is absent)
ub_row_n(){ grep -E 'WARN.*wall backlog row' <<<"$1" | grep -oE '[0-9]+ wall' | head -1 | grep -oE '[0-9]+'; }
# W6: every wall-vocabulary state of METHODOLOGY §21.1 is recognised (one row each) ...
for _st in 'blocked (requires-tool)' 'not-buildable' 'refused' 'unavailable' 'not-extracted' 'blocked-on-tool' '**blocked-on-tool**' 'blocked: no key' '**blocked** (requires-tool)' 'refused: no' 'unavailable, later' 'not-buildable: x' 'not-extracted,' 'blocked, no'; do
  d="$TMP/ub-vocab"; UB_ROWS="| low | R1 wall gap | web | $_st |" ub_state "$d" 0 0 '## Stop control'
  out="$(run "$d")"
  if [ "$(ub_row_n "$out")" = 1 ]; then ok "1361-vocab: Status '$_st' is a wall → 1 row WARN"
  else no "1361-vocab: Status '$_st' n=$(ub_row_n "$out") :: $(grep -E 'WARN|degraded' <<<"$out")"; fi
done
# ... and transport-timeout-succeeded (records NO wall), pending and covered are not.
for _st in 'transport-timeout-succeeded' 'pending' 'covered (B3)'; do
  d="$TMP/ub-vocab-neg"; UB_ROWS="| low | R1 wall gap | web | $_st |" ub_state "$d" 0 0 '## Stop control'
  out="$(run "$d")"
  if [ -z "$(ub_row_n "$out")" ]; then ok "1361-vocab-neg: Status '$_st' is not a wall → no row WARN"
  else no "1361-vocab-neg: Status '$_st' n=$(ub_row_n "$out")"; fi
done
# closed-row convention (W2): struck gap, struck Status, or a check mark in Status → not an open wall.
for _row in '| low | ~~R1 wall gap~~ | web | blocked-on-operator |' '| low | R1 wall gap | web | ~~blocked-on-operator~~ |' '| low | R1 wall gap | web | blocked-on-operator ✅ closed by B9 |'; do
  d="$TMP/ub-closed"; UB_ROWS="$_row" ub_state "$d" 0 0 '## Stop control'
  out="$(run "$d")"
  if [ -z "$(ub_row_n "$out")" ]; then ok "1361-closed: closed wall row '${_row:0:44}…' → no row WARN"
  else no "1361-closed: '$_row' n=$(ub_row_n "$out")"; fi
done
# list edges over the ROW list: wall row in FIRST / MIDDLE / LAST position.
_rok="| low | R9 ok gap | web | blocked-on-operator · $UBOK |"; _rbad='| low | R1 wall gap | web | blocked-on-operator |'
d="$TMP/ub-row-first"; UB_ROWS="$_rbad"$'\n'"$_rok"$'\n'"$_rok" ub_state "$d" 0 0 '## Stop control'; out="$(run "$d")"
if [ "$(ub_row_n "$out")" = 1 ]; then ok "1361-row-first: wall row FIRST in the table → 1 row WARN"; else no "1361-row-first: n=$(ub_row_n "$out")"; fi
d="$TMP/ub-row-middle"; UB_ROWS="$_rok"$'\n'"$_rbad"$'\n'"$_rok" ub_state "$d" 0 0 '## Stop control'; out="$(run "$d")"
if [ "$(ub_row_n "$out")" = 1 ]; then ok "1361-row-middle: wall row MIDDLE in the table → 1 row WARN"; else no "1361-row-middle: n=$(ub_row_n "$out")"; fi
d="$TMP/ub-row-last"; UB_ROWS="$_rok"$'\n'"$_rok"$'\n'"$_rbad" ub_state "$d" 0 0 '## Stop control'; out="$(run "$d")"
if [ "$(ub_row_n "$out")" = 1 ]; then ok "1361-row-last: wall row LAST in the table → 1 row WARN"; else no "1361-row-last: n=$(ub_row_n "$out")"; fi
# 5-column table: Status is the 5th cell (a[5]) — the mirrored parser locates it by table shape.
d="$TMP/ub-row-5col"; mkdir -p "$d"
{ echo '# T — Research State'; echo; env9 0 3 5 1 0 0 0; echo
  echo '## Coverage'; echo '- **Coverage metric**: 3 / 5 closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | ID | Gap | Artifact | Status |'; echo '|---|---|---|---|---|'
  echo '| high | G1 | active gap | x | pending |'
  echo '| low | G2 | a wall | x | refused |'; echo; echo '## Stop control'
} > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if [ "$(ub_row_n "$out")" = 1 ]; then ok "1361-row-5col: wall Status read from the 5th cell of a 5-column table → 1 row WARN"
else no "1361-row-5col: n=$(ub_row_n "$out") :: $(grep -E 'WARN|degraded' <<<"$out")"; fi
# an ESCAPED pipe is a literal character of the cell (the mirrored parser's BP-ESCAPED-PIPE): the Status is still located
# in the right cell, so the wall is counted exactly once; an UNESCAPED extra pipe makes a malformed row (parser WARN) that
# is skipped, never mis-read as a wall.
d="$TMP/ub-row-pipe"; UB_ROWS='| low | R1 wall \| gap | web | blocked-on-operator |' ub_state "$d" 0 0 '## Stop control'
out="$(run "$d")"
if [ "$(ub_row_n "$out")" = 1 ]; then ok "1361-row-pipe: escaped pipe in the Gap cell → Status still located, 1 row WARN"
else no "1361-row-pipe: n=$(ub_row_n "$out")"; fi
d="$TMP/ub-row-rawpipe"; UB_ROWS='| low | R1 wall | gap | web | blocked-on-operator |' ub_state "$d" 0 0 '## Stop control'
_errs="$(bash "$SUT" "$d" 2>&1 >/dev/null)"; out="$(run "$d")"
if grep -q 'malformed backlog row' <<<"$_errs" && [ -z "$(ub_row_n "$out")" ]; then ok "1361-row-rawpipe: unescaped extra pipe → the parser's malformed-row WARN, row not mis-read as a wall"
else no "1361-row-rawpipe: errs=$(head -c 200 <<<"$_errs") n=$(ub_row_n "$out")"; fi
# W4: exemption is by NAME / gap-ID linkage to a Blocked-gaps bullet, never by pointer text.
d="$TMP/ub-link-name"; UB_DEDUCT=1 UB_ROWS='| low | plain wall name | web | blocked-on-operator |' ub_state "$d" 1 0 '## Blocked gaps' "- plain wall name — needs: x; tried: y; $UBOK"
out="$(run "$d")"
if [ -z "$(ub_row_n "$out")" ] && ! grep -qE 'WARN.*unblock:' <<<"$out"; then ok "1361-link-name: row whose Gap equals a Blocked-gaps bullet name → exempt (bullet holds the plan)"
else no "1361-link-name: $(grep -E 'unblock' <<<"$out")"; fi
d="$TMP/ub-link-id"; UB_DEDUCT=1 UB_ROWS='| low | G7 reworded gap text | web | blocked-on-operator |' ub_state "$d" 1 0 '## Blocked gaps' "- G7 the original wording — needs: x; tried: y; $UBOK"
out="$(run "$d")"
if [ -z "$(ub_row_n "$out")" ]; then ok "1361-link-id: row sharing the leading gap ID of a Blocked-gaps bullet → exempt"
else no "1361-link-id: n=$(ub_row_n "$out")"; fi
d="$TMP/ub-link-none"; UB_ROWS='| low | G8 unrelated wall | web | blocked-on-operator → see ## Blocked gaps |' ub_state "$d" 1 0 '## Blocked gaps' "- G7 other gap — needs: x; tried: y; $UBOK"
out="$(run "$d")"
if [ "$(ub_row_n "$out")" = 1 ]; then ok "1361-link-none: pointer text alone no longer exempts a row with no name/ID link → 1 row WARN"
else no "1361-link-none: n=$(ub_row_n "$out")"; fi
# W5: indented sub-bullets belong to the parent entry; a same-indent bullet starts a new one; blank-line handling.
d="$TMP/ub-sub"; ub_state "$d" 1 0 '## Blocked gaps' "- a — needs: x" "  - tried: y" "  - $UBOK"
out="$(run "$d")"
if [ -z "$(ub_warn_n "$out")" ]; then ok "1361-sub: unblock: in an indented sub-bullet belongs to the parent entry → no WARN"
else no "1361-sub: n=$(ub_warn_n "$out")"; fi
d="$TMP/ub-sub-none"; ub_state "$d" 2 0 '## Blocked gaps' "- a — needs: x" "  - tried: y" "- b — needs: x; $UBOK"
out="$(run "$d")"
if [ "$(ub_warn_n "$out")" = 1 ]; then ok "1361-sub-none: sub-bullets without unblock: + next bullet's plan not credited → 1 WARN"
else no "1361-sub-none: n=$(ub_warn_n "$out")"; fi
d="$TMP/ub-blank-in"; ub_state "$d" 1 0 '## Blocked gaps' "- a — needs: x" "" "  $UBOK"
out="$(run "$d")"
if [ -z "$(ub_warn_n "$out")" ]; then ok "1361-blank-in: loose-list gap then an INDENTED plan line stays inside the entry → no WARN"
else no "1361-blank-in: n=$(ub_warn_n "$out")"; fi
d="$TMP/ub-blank-out"; ub_state "$d" 1 0 '## Blocked gaps' "- a — needs: x" "" "$UBOK"
out="$(run "$d")"
if [ "$(ub_warn_n "$out")" = 1 ]; then ok "1361-blank-out: blank line then a column-0 paragraph is NOT part of the bullet → 1 WARN"
else no "1361-blank-out: n=$(ub_warn_n "$out")"; fi
# S8: presence-only wording + the ORDER finding (unblock: must come after needs:).
d="$TMP/ub-order"; ub_state "$d" 1 0 '## Blocked gaps' "- a — $UBOK; needs: x; tried: y"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'WARN.*1 blocked gap\(s\) with unblock: placed before needs:' <<<"$out" && [ -z "$(ub_warn_n "$out")" ]; then ok "1361-order: unblock: before needs: → ORDER WARN only (not 'missing'), exit 0"
else no "1361-order: exit $(code "$d") :: $(grep -E 'WARN' <<<"$out")"; fi
d="$TMP/ub-order-ok"; ub_state "$d" 1 0 '## Blocked gaps' "- a — needs: x; tried: y; $UBOK"
out="$(run "$d")"
if ! grep -qE 'placed before needs:' <<<"$out"; then ok "1361-order-ok: unblock: after needs: → no ORDER WARN"; else no "1361-order-ok"; fi
d="$TMP/ub-presence"; ub_state "$d" 1 0 '## Blocked gaps' "- a — needs: x"
out="$(run "$d")"
if grep -qE 'WARN.*missing an unblock:.*presence-only' <<<"$out"; then ok "1361-presence: WARN text states the check is presence-only"; else no "1361-presence: $(grep WARN <<<"$out")"; fi
# ## Stretch goal: present-and-complete is silent; each missing line WARNs; absent is silent.
d="$TMP/sg-ok"; ub_state "$d" 0 0 '## Stretch goal' 'realistic: map the API surface' 'stretch: full protocol reimplementation'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'WARN.*Stretch goal' <<<"$out"; then ok "1361-sg-ok: complete ## Stretch goal → no WARN"
else no "1361-sg-ok: exit $(code "$d") :: $(grep -E 'Stretch' <<<"$out")"; fi
d="$TMP/sg-nostretch"; ub_state "$d" 0 0 '## Stretch goal' 'realistic: map the API surface'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'WARN.*Stretch goal.*stretch:' <<<"$out" && ! grep -qE 'WARN.*Stretch goal.*realistic:' <<<"$out"; then ok "1361-sg-nostretch: section lacking stretch: → WARN naming stretch:, exit 0"
else no "1361-sg-nostretch: exit $(code "$d") :: $(grep -E 'Stretch' <<<"$out")"; fi
d="$TMP/sg-norealistic"; ub_state "$d" 0 0 '## Stretch goal' 'stretch: full protocol reimplementation'
out="$(run "$d")"
if grep -qE 'WARN.*Stretch goal.*realistic:' <<<"$out" && ! grep -qE 'WARN.*Stretch goal.*stretch:' <<<"$out"; then ok "1361-sg-norealistic: section lacking realistic: → WARN naming realistic:"
else no "1361-sg-norealistic: $(grep -E 'Stretch' <<<"$out")"; fi
d="$TMP/sg-empty"; ub_state "$d" 0 0 '## Stretch goal' '' '## Stop control'
out="$(run "$d")"
if grep -qE 'WARN.*Stretch goal.*realistic:.*stretch:' <<<"$out"; then ok "1361-sg-empty: empty ## Stretch goal → WARN naming both lines"
else no "1361-sg-empty: $(grep -E 'Stretch' <<<"$out")"; fi
d="$TMP/sg-absent"; ub_state "$d" 0 0 '## Stop control'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'WARN.*Stretch goal' <<<"$out"; then ok "1361-sg-absent: no ## Stretch goal section → silent (per-new-focus doctrine)"
else no "1361-sg-absent: exit $(code "$d") :: $(grep -E 'Stretch' <<<"$out")"; fi
# section is the LAST in the file and the stretch line is the LAST line without a trailing newline.
d="$TMP/sg-last-nonl"; ub_state "$d" 0 0 '## Stretch goal' 'realistic: map the API surface' 'stretch: full protocol reimplementation'
printf '%s' "$(cat "$d/RESEARCH-STATE.md")" > "$d/RESEARCH-STATE.md"
out="$(run "$d")"
if ! grep -qE 'WARN.*Stretch goal' <<<"$out"; then ok "1361-sg-last-nonl: stretch: as the final line without newline is recognised → no WARN"
else no "1361-sg-last-nonl: $(grep -E 'Stretch' <<<"$out")"; fi

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
   && <<<"$(grep -c '== verify-state:' <<<"$out")" grep -q '^1$'; then
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
   && <<<"$(grep -c '== verify-state:' <<<"$f2b_out")" grep -q '^1$'; then
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
   && <<<"$(grep -c '== verify-state:' <<<"$f2c_out")" grep -q '^1$'; then
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
if grep -qi 'near-miss' <<<"$_vs_u2011_warn"; then
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
if grep -qi 'only 4- or 5-column\|backlog table has.*3 columns' <<<"$_vs_w3_warn"; then
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
if grep -qi 'only 4- or 5-column\|backlog table has.*6 columns' <<<"$_vs_w6_warn"; then
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
if ! grep -qi 'unknown priority\|INVALID_PRIORITY\|backlog.*columns' <<<"$_vsli_out"; then
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
if ! grep -qi 'only 4- or 5-column\|backlog table has' <<<"$_vsso_out"; then
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
if ! grep -qi 'contradictory.*denominators\|denominators.*3011\|denominators.*5011' <<<"$_vsdp_out"; then
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
if grep -qi 'contradictory' <<<"$_vsm1_out"; then
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
if grep -qi 'COVERED row' <<<"$_vsn3_warn"; then
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
if ! grep -qi 'malformed' <<<"$_vsn3m_warn"; then
  ok "VS-N3-MALFORMED-SCOPE: malformed row outside Gap-backlog → no malformed WARN in verify-state"
else
  no "VS-N3-MALFORMED-SCOPE: malformed WARN fired outside Gap-backlog — scope fix missing: [$(echo "$_vsn3m_warn" | grep -i malformed | head -1)]"
fi

# VS-OOB-5COL (kit #983): a 5-col table OUTSIDE ## Gap-backlog is counted by the backlog exactly like a
# 4-col OOB table is (mirrors research-sdd-status.sh). Declared io=3 = 1 canonical + 2 OOB 5-col rows.
vs_oob5() {  # <dir> <investigable_open-declared>
  local dd="$1" io="$2"; mkdir -p "$dd"
  { echo '# T'; echo
    env9 0 0 3 "$io" 0 0 0; echo
    echo '## Gap-backlog (prioritized)'; echo
    printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
    echo '| high | g1 | web | pending |'; echo
    echo '## Extra gaps'; echo
    printf '| Priority | ID | Gap | Artifact | Status |\n|---|---|---|---|---|\n'
    echo '| high | X1 | one | art | pending |'
    echo '| medium | X2 | two | art | pending |'; echo
    echo '## Blocked gaps'; echo '## Stop control'
    echo '- **Open gaps — read-only investigable**: 3'; } > "$dd/RESEARCH-STATE.md"
}
vs_oob5 "$TMP/vs-oob5-ok" 3
if [ "$(code "$TMP/vs-oob5-ok")" = 0 ]; then
  ok "VS-OOB-5COL: 5-col OOB rows counted (declared io=3 = 1 canonical + 2 OOB) → exit 0"
else no "VS-OOB-5COL: exit non-zero — 5-col OOB rows dropped from derive_investigable (derived io=1 != declared 3)"; fi
vs_oob5 "$TMP/vs-oob5-bad" 1
_vso5_rev="$(run "$TMP/vs-oob5-bad")"
if [ "$(code "$TMP/vs-oob5-bad")" = 1 ] && grep -q 'envelope investigable_open=1 != 3 NEXT-eligible' <<<"$_vso5_rev"; then
  ok "VS-OOB-5COL-REV: declaring io=1 FAILs on investigable_open (derived 3: the OOB 5-col rows are load-bearing)"
else no "VS-OOB-5COL-REV: want exit 1 naming 'investigable_open=1 != 3' — got [$(grep -i 'FAIL' <<<"$_vso5_rev" | head -2)]"; fi

# VS-FINDINGS (kit #1307): a non-backlog table whose first column merely holds high/medium/low (a Severity
# column) is NOT a backlog — an out-of-backlog table needs a priority-shaped header. Declared io=1 (the one
# canonical row); the 3 Findings rows must not inflate the derived count.
vs_findings() {  # <dir>
  local dd="$1"; mkdir -p "$dd"
  { echo '# T'; echo
    env9 0 0 1 1 0 0 0; echo
    echo '## Gap-backlog (prioritized)'; echo
    printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
    echo '| high | g1 | web | pending |'; echo
    echo '## Findings'; echo
    printf '| Severity | ID | Finding | Evidence | Status |\n|---|---|---|---|---|\n'
    echo '| high | F1 | one | x.java:1 | pending |'
    echo '| medium | F2 | two | x.java:2 | pending |'
    echo '| low | F3 | three | x.java:3 | pending |'; echo
    echo '## Blocked gaps'; echo '## Stop control'
    echo '- **Open gaps — read-only investigable**: 1'; } > "$dd/RESEARCH-STATE.md"
}
vs_findings "$TMP/vs-findings"
if [ "$(code "$TMP/vs-findings")" = 0 ]; then
  ok "VS-FINDINGS: Severity-table rows are not backlog gaps (declared io=1 == derived 1) → exit 0"
else no "VS-FINDINGS: exit non-zero — a Findings table inflated derive_investigable: [$(run "$TMP/vs-findings" | grep -i 'FAIL' | head -2)]"; fi
# Header-less out-of-backlog pipe rows (no separator, no header) are not a table either.
_vsf2="$TMP/vs-findings-noheader"; mkdir -p "$_vsf2"
{ echo '# T'; echo; env9 0 0 1 1 0 0 0; echo
  echo '## Gap-backlog (prioritized)'; echo
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  echo '| high | g1 | web | pending |'; echo
  echo '## Notes'; echo
  echo '| high | stray | prose | pending |'; echo
  echo '## Blocked gaps'; echo '## Stop control'
  echo '- **Open gaps — read-only investigable**: 1'; } > "$_vsf2/RESEARCH-STATE.md"
if [ "$(code "$_vsf2")" = 0 ]; then
  ok "VS-FINDINGS-NOHDR: a header-less out-of-backlog pipe row is ignored (declared io=1 == derived 1) → exit 0"
else no "VS-FINDINGS-NOHDR: exit non-zero — stray pipe row counted: [$(run "$_vsf2" | grep -i 'FAIL' | head -2)]"; fi

# NEGATIVE CONTROL — prove CHECK 1 (the STALE detection) has TEETH via mutation.

# P8 — hook-placeholder check: WARN when installed hook scripts contain unreplaced <TOKEN> placeholders.
# §7 anti-silent-zero: absent-input / empty-input / no-match all produce distinct output.
echo "-- P8: hook-placeholder check --"
# Helper: build a minimal valid state file so verify-state reaches the P8 check
mk_state_p8() {
  local d="$1"; mkdir -p "$d"
  # Need a valid RESEARCH-STATE.md with envelope for verify-state to proceed past early exits
  { echo '# Research State'; echo
    env_lines 0 0 0 0 0 0; echo
    echo 'coverage metric: 0 / 0 declared gaps closed'; echo
    echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'; echo
    echo '## Blocked gaps'; echo '- none'; echo
    echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
  } > "$d/RESEARCH-STATE.md"
}

# P8-A: no .claude/hooks/ directory → INFO line for absent-input
d="$TMP/p8-absent"; mk_state_p8 "$d"
# ensure no .claude dir exists
rm -rf "$d/.claude" 2>/dev/null || true
_p8a="$(run "$d" 2>/dev/null)"
if grep -qiF "hook-placeholder" <<<"$_p8a" && grep -qiE "absent|not found|skip" <<<"$_p8a"; then
  ok "P8-A: no .claude/hooks/ → INFO absent-input line"
else
  no "P8-A: no .claude/hooks/ → expected INFO absent-input; got: $(echo "$_p8a" | grep -i hook | head -1)"
fi

# P8-B: .claude/hooks/ exists but empty (no .sh files) → INFO empty-input line
d="$TMP/p8-empty"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
_p8b="$(run "$d" 2>/dev/null)"
if grep -qiF "hook-placeholder" <<<"$_p8b" && grep -qiE "empty|no .sh|skip" <<<"$_p8b"; then
  ok "P8-B: empty .claude/hooks/ → INFO empty-input line"
else
  no "P8-B: empty .claude/hooks/ → expected INFO empty-input; got: $(echo "$_p8b" | grep -i hook | head -1)"
fi

# P8-C: hook with no placeholders → no WARN (silent, no-match)
d="$TMP/p8-clean"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\n# research-protocol.sh — adapted for myproject\necho "myproject"\n' \
  > "$d/.claude/hooks/research-protocol.sh"
_p8c="$(run "$d" 2>/dev/null)"
if grep -qE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8c"; then
  no "P8-C: clean hook → no WARN expected; got WARN"
else
  ok "P8-C: clean hook → no hook-placeholder WARN (no-match)"
fi

# P8-D: hook with <SUBJECT> placeholder on code line → WARN (FIRST file, single)
# Placeholder on non-comment code line (comment lines are skipped — F4 rule).
d="$TMP/p8-subject"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\n# adapted hook header\nSUBJECT="<SUBJECT>"\necho "$SUBJECT"\n' \
  > "$d/.claude/hooks/research-protocol.sh"
_p8d="$(run "$d" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8d"; then
  ok "P8-D: hook with <SUBJECT> on code line → hook-placeholder WARN emitted"
else
  no "P8-D: hook with <SUBJECT> on code line → expected hook-placeholder WARN; got: $(echo "$_p8d" | grep -i hook | head -1)"
fi
# The WARN line itself must name the placeholder
if <<<"$(grep -iE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8d")" grep -qiF "SUBJECT"; then
  ok "P8-D: WARN line names the placeholder <SUBJECT>"
else
  no "P8-D: WARN line does not name <SUBJECT>"
fi
# WARN must name the exact hook file (exact-file assertion)
if <<<"$(grep -iE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8d")" grep -qF "research-protocol.sh"; then
  ok "P8-D: WARN line names the hook file (research-protocol.sh)"
else
  no "P8-D: WARN line does not name the hook file"
fi
# WARN must include a line number (F4 requirement)
if <<<"$(grep -iE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8d")" grep -qE 'line\(s\) [0-9]'; then
  ok "P8-D: WARN line includes line number"
else
  no "P8-D: WARN line missing line number"
fi

# P8-D2: comment-only lines with <SUBJECT> must NOT trigger WARN (F4: skip # lines)
d="$TMP/p8-comment-skip"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\n# Research-SDD — <SUBJECT>\n# Kit: <KIT>/toolbelt/\necho "adapted"\n' \
  > "$d/.claude/hooks/research-protocol.sh"
_p8d2="$(run "$d" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8d2"; then
  no "P8-D2: comment-only <SUBJECT>/<KIT> → should NOT WARN (F4 skip rule); got WARN"
else
  ok "P8-D2: comment-only <SUBJECT>/<KIT> → no WARN (F4 skip rule)"
fi

# P8-E: hook with <KIT> placeholder on code line → WARN
d="$TMP/p8-kit"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\nKIT_PATH="<KIT>/toolbelt/"\necho "$KIT_PATH"\n' \
  > "$d/.claude/hooks/retro-gate-stop.sh"
_p8e="$(run "$d" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8e"; then
  ok "P8-E: hook with <KIT> on code line → hook-placeholder WARN"
else
  no "P8-E: hook with <KIT> on code line → expected WARN; got: $(echo "$_p8e" | grep -i hook | head -1)"
fi

# P8-E2: lowercase <prefix> placeholder → WARN (F1: allowlist includes lowercase forms)
d="$TMP/p8-prefix"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\n# Research protocol\nBLOCK_GLOB="<prefix>-block*.md"\necho "$BLOCK_GLOB"\n' \
  > "$d/.claude/hooks/research-protocol.sh"
_p8e2="$(run "$d" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8e2"; then
  ok "P8-E2: hook with lowercase <prefix> on code line → WARN (F1 allowlist)"
else
  no "P8-E2: hook with <prefix> on code line → expected WARN; got: $(echo "$_p8e2" | grep -i hook | head -1)"
fi
if <<<"$(grep -iE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8e2")" grep -qF "prefix"; then
  ok "P8-E2: WARN line names <prefix>"
else
  no "P8-E2: WARN line does not name <prefix>"
fi

# P8-E3: long lowercase <path to ...> placeholder → WARN (F1: allowlist includes this form)
d="$TMP/p8-path"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\n# primary source\nSOURCE="<path to binaries/decompiled output/source code of the system under study>"\necho "$SOURCE"\n' \
  > "$d/.claude/hooks/research-protocol.sh"
_p8e3="$(run "$d" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8e3"; then
  ok "P8-E3: hook with <path to binaries...> on code line → WARN (F1 allowlist)"
else
  no "P8-E3: hook with <path to binaries...> → expected WARN; got: $(echo "$_p8e3" | grep -i hook | head -1)"
fi

# P8-F: multiple hooks — FIRST (alphabetically) has placeholder, LAST is clean → WARN for first
d="$TMP/p8-multi"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\nSUBJECT="<SUBJECT>"\necho first\n' > "$d/.claude/hooks/a-first.sh"
printf '#!/bin/bash\necho "clean"\n'                     > "$d/.claude/hooks/b-middle.sh"
printf '#!/bin/bash\necho "clean"\n'                     > "$d/.claude/hooks/c-last.sh"
_p8f="$(run "$d" 2>/dev/null)"
_p8f_warns=$(echo "$_p8f" | grep -cE 'WARN.*hook-placeholder|hook-placeholder.*WARN' 2>/dev/null || true)
[ "${_p8f_warns:-0}" -ge 1 ] && ok "P8-F: multi-hook first-placeholder → at least 1 WARN" \
                             || no "P8-F: multi-hook first-placeholder → expected WARN, got $_p8f_warns"
# Exact-file: the WARN must name the file that has the placeholder
if <<<"$(grep -iE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8f")" grep -qF "a-first.sh"; then
  ok "P8-F: WARN names the specific file (a-first.sh)"
else
  no "P8-F: WARN does not name the specific placeholder file (a-first.sh)"
fi

# P8-G: LAST hook has placeholder, middle and first are clean → WARN (edge: last position)
d="$TMP/p8-last"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\necho "clean"\n'                       > "$d/.claude/hooks/a-clean.sh"
printf '#!/bin/bash\necho "mid"\n'                         > "$d/.claude/hooks/m-mid.sh"
printf '#!/bin/bash\nKIT_PATH="<KIT>/toolbelt/"\necho z\n' > "$d/.claude/hooks/z-last.sh"
_p8g="$(run "$d" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8g"; then
  ok "P8-G: last hook with placeholder → WARN (last-position edge)"
else
  no "P8-G: last hook with placeholder → expected WARN (last-position edge)"
fi
# Exact-file: WARN must name z-last.sh
if <<<"$(grep -iE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8g")" grep -qF "z-last.sh"; then
  ok "P8-G: WARN names the last hook file (z-last.sh)"
else
  no "P8-G: WARN does not name z-last.sh"
fi

# P8-H: single-element: one hook with <TARGET> → WARN (single-element edge)
d="$TMP/p8-single"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\nTARGET="<TARGET>"\necho "$TARGET"\n' \
  > "$d/.claude/hooks/retro-gate-stop.sh"
_p8h="$(run "$d" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8h"; then
  ok "P8-H: single hook with <TARGET> → hook-placeholder WARN (single-element edge)"
else
  no "P8-H: single hook with <TARGET> → expected WARN (single-element edge)"
fi

# P8-I: unreadable hook file → typed 'unreadable' signal (B4 requirement)
# Only run when we have permission to chmod (may not work as root)
d="$TMP/p8-unreadable-file"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\nSUBJECT="<SUBJECT>"\necho "$SUBJECT"\n' > "$d/.claude/hooks/research-protocol.sh"
chmod 000 "$d/.claude/hooks/research-protocol.sh" 2>/dev/null
_p8i="$(run "$d" 2>/dev/null)"
if grep -qiE 'unreadable.*hook-placeholder|hook-placeholder.*unreadable' <<<"$_p8i"; then
  ok "P8-I: unreadable hook file → typed 'unreadable' signal"
else
  # Tolerate if running as root (chmod 000 has no effect)
  _uid="$(id -u 2>/dev/null || echo 1)"
  if [ "$_uid" = "0" ]; then
    echo "  SKIP  P8-I: unreadable hook file (running as root, chmod 000 ignored)"
  else
    no "P8-I: unreadable hook file → expected 'unreadable' signal; got: $(echo "$_p8i" | grep -i hook | head -1)"
  fi
fi
chmod 644 "$d/.claude/hooks/research-protocol.sh" 2>/dev/null || true

# P8-J: unreadable hooks dir → typed 'unreadable' signal (B4 requirement)
d="$TMP/p8-unreadable-dir"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\necho "hook"\n' > "$d/.claude/hooks/research-protocol.sh"
chmod 000 "$d/.claude/hooks" 2>/dev/null
_p8j="$(run "$d" 2>/dev/null)"
if grep -qiE 'unreadable.*hook-placeholder|hook-placeholder.*unreadable' <<<"$_p8j"; then
  ok "P8-J: unreadable hooks dir → typed 'unreadable' signal"
else
  _uid="$(id -u 2>/dev/null || echo 1)"
  if [ "$_uid" = "0" ]; then
    echo "  SKIP  P8-J: unreadable hooks dir (running as root, chmod 000 ignored)"
  else
    no "P8-J: unreadable hooks dir → expected 'unreadable' signal; got: $(echo "$_p8j" | grep -i hook | head -1)"
  fi
fi
chmod 755 "$d/.claude/hooks" 2>/dev/null || true

# P8-K: multi-state no-duplication — when a target has 3 RESEARCH-STATE*.md files,
# P8 must appear exactly ONCE in the output (runs once per target, not per state).
d="$TMP/p8-multi-state"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\nSUBJECT="<SUBJECT>"\necho "$SUBJECT"\n' > "$d/.claude/hooks/research-protocol.sh"
# Create 3 state files so the per-state loop iterates 3×
{ echo '# Research State'; env_lines 0 0 0 0 0 0
  echo 'coverage metric: 0 / 0 declared gaps closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
cp "$d/RESEARCH-STATE.md" "$d/RESEARCH-STATE-focus-a.md"
cp "$d/RESEARCH-STATE.md" "$d/RESEARCH-STATE-focus-b.md"
_p8k="$(run "$d" 2>/dev/null)"
_p8k_warns=$(echo "$_p8k" | grep -cE 'WARN.*hook-placeholder|hook-placeholder.*WARN' 2>/dev/null || true)
[ "${_p8k_warns:-0}" -eq 1 ] && ok "P8-K: 3-state target → exactly 1 hook-placeholder WARN (no duplication)" \
                              || no "P8-K: 3-state target → expected 1 WARN, got $_p8k_warns (duplication?)"

# P8-L: nested corpus — verify-state called with $target/corpus, hooks at $target/.claude/hooks
d_root="$TMP/p8-nested-root"
d_corpus="$d_root/corpus"
mkdir -p "$d_corpus" "$d_root/.claude/hooks"
# State file lives in the corpus dir (nested); hooks live at target root
{ echo '# Research State'; env_lines 0 0 0 0 0 0
  echo 'coverage metric: 0 / 0 declared gaps closed'
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '- none'
  echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'; } > "$d_corpus/RESEARCH-STATE.md"
printf '#!/bin/bash\nSUBJECT="<SUBJECT>"\necho "$SUBJECT"\n' > "$d_root/.claude/hooks/research-protocol.sh"
_p8l="$(run "$d_corpus" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8l"; then
  ok "P8-L: nested corpus — hooks found at target root, WARN emitted"
else
  no "P8-L: nested corpus — expected WARN for hook at target root; got: $(echo "$_p8l" | grep -i hook | head -2)"
fi

# P8-M: hook adapted from fixed template — uses $RESEARCH_SDD_KIT (no <KIT>) → no false WARN
# (Regression guard: blender-llm line 50 was the fixed template's kit-info line, not an unadapted hook.)
d="$TMP/p8-template-clean"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
cat > "$d/.claude/hooks/research-protocol.sh" <<'HOOKEOF'
#!/bin/bash
read -r -d '' CTX <<'EOF' || true
Toolbelt: $RESEARCH_SDD_KIT/toolbelt/ — set RESEARCH_SDD_KIT to your Research-SDD kit root.
EOF
printf '%s\n' "$CTX"
HOOKEOF
_p8m="$(run "$d" 2>/dev/null)"
if ! grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8m"; then
  ok "P8-M: adapted hook with fixed template kit-line (\$RESEARCH_SDD_KIT) → no false P8 WARN"
else
  no "P8-M: adapted hook with fixed template kit-line → unexpected WARN: $(echo "$_p8m" | grep -i hook | head -1)"
fi


# ============================================================================
# P8-S: hook SET DERIVATION — settings.json UNION settings.local.json UNION .claude/hooks/*.
# A target's real hooks are whatever settings.json (and its untracked settings.local.json override)
# actually runs, PLUS whatever sits directly in .claude/hooks/ — as a plain file OR a symlink. The
# INSPECTED SET is the union of all three, deduplicated, never a mutually-exclusive choice: no
# single source may hide another. Every candidate path — settings-derived or from the .claude/hooks/
# listing — passes through the SAME containment check before it is ever opened: with `realpath`
# available this is an exact canonicalized check against the target root; without it, a conservative
# component-walk refuses anything containing a ".." segment or crossing a symlink, since a purely
# textual prefix match cannot see either kind of escape. §7 keeps FOUR final states distinct: a
# source that does not exist at all (absent), one that exists and is genuinely empty, one whose
# files are all clean (no-match, silent), and one whose declared candidates were all refused
# (found-but-none-inspectable) — the last of these must never read the same as plain emptiness.
# ============================================================================
echo "-- P8-S: settings.json ∪ settings.local.json ∪ .claude/hooks/* --"

# mk_settings_file <dir> <filename> <cmd...> — .claude/<filename> with one SessionStart hook object
# per <cmd> (real Claude Code hooks shape). Built with jq (a fixture-construction tool, independent
# of whether the SUT run under test has jq on PATH — see the jq-degraded case below).
mk_settings_file() {
  local d="$1" fname="$2"; shift 2
  mkdir -p "$d/.claude"
  local hooks_json='[]' c
  for c in "$@"; do
    hooks_json="$(jq -n --argjson acc "$hooks_json" --arg cmd "$c" '$acc + [{"type":"command","command":$cmd}]')"
  done
  jq -n --argjson hooks "$hooks_json" '{hooks:{SessionStart:[{matcher:"",hooks:$hooks}]}}' > "$d/.claude/$fname"
}
# mk_settings_cmds <dir> <cmd...> — convenience wrapper: settings.json (used by most P8S-* cases).
mk_settings_cmds() { local d="$1"; shift; mk_settings_file "$d" "settings.json" "$@"; }
# mk_local_cmds <dir> <cmd...> — convenience wrapper: settings.local.json.
mk_local_cmds() { local d="$1"; shift; mk_settings_file "$d" "settings.local.json" "$@"; }

# build_hermetic_bin_excluding <src_path> <out_dir> <excluded_name> — populate <out_dir> with
# symlinks to every executable reachable from <src_path> except <excluded_name> (ported from
# retro-gate.test.sh's build_hermetic_nojq_bin, generalized to take the excluded name as a
# parameter instead of duplicating the whole function per excluded tool). First-wins across dirs
# keeps a duplicate-dir copy, e.g. /bin -> /usr/bin, from leaking the excluded tool back in through
# a second PATH entry.
#
# #1161 — cost: on WSL the ambient PATH carries the Windows PATH (63 /mnt/c/... entries, and
# /mnt/c/WINDOWS/system32 alone has ~5,300 entries on a 9P mount), and the old body forked
# `basename` plus `ln` once per executable. Now (a) source dirs matching HERMETIC_BIN_SKIP_GLOB
# (default '/mnt/*' = WSL Windows drive mounts; nothing the SUT or this suite runs lives there)
# are never walked, (b) the name comes from ${_exe##*/} (no fork), (c) links are created with ONE
# `ln -s -t` per source dir. First-wins semantics are unchanged.
build_hermetic_bin_excluding() {
  local src_path="$1" out_dir="$2" excluded="$3" _oifs _pd _exe _n _batch _skip="${HERMETIC_BIN_SKIP_GLOB:-/mnt/*}"
  _oifs="$IFS"; IFS=':'
  for _pd in $src_path; do
    IFS="$_oifs"
    [ -d "$_pd" ] || continue
    # SENTINEL-HB-SKIP-START
    # shellcheck disable=SC2254
    case "$_pd" in $_skip) continue ;; esac
    # SENTINEL-HB-SKIP-END
    _batch=()
    while IFS= read -r -d '' _exe; do
      _n="${_exe##*/}"
      [ "$_n" = "$excluded" ] && continue
      [ -e "$out_dir/$_n" ] && continue   # SENTINEL-HB-FIRSTWINS
      _batch+=("$_exe")
    done < <(find "$_pd" -maxdepth 1 \( -type f -o -type l \) -executable -print0 2>/dev/null)
    if [ "${#_batch[@]}" -gt 0 ]; then ln -s -t "$out_dir" -- "${_batch[@]}"; fi
  done
  IFS="$_oifs"
}

# #1161 builder checks (same fixture shape as retro-gate.test.sh's HB cases, but this builder takes
# the excluded name as a parameter). hb_checks <function-source>: eval it in a subshell and print one
# "FAIL:<name>" per broken assertion, so the same function checks the real builder and each mutant.
hb_checks() {
  (
    eval "$1"
    declare -F build_hermetic_bin_excluding >/dev/null 2>&1 || { echo "FAIL:function-not-defined"; exit 0; }
    h="$(mktemp -d)"; trap 'rm -rf "$h"' EXIT
    mkdir -p "$h/a" "$h/skipme" "$h/b" "$h/out"
    for t in a/alpha a/realpath skipme/beta b/alpha b/gamma; do
      printf '#!/bin/sh\necho %s\n' "$t" > "$h/$t"; chmod +x "$h/$t"
    done
    HERMETIC_BIN_SKIP_GLOB="$h/skipme*" build_hermetic_bin_excluding "$h/a:$h/skipme:$h/b:$h/nonexistent" "$h/out" "realpath" 2>"$h/builder.err"
    [ -s "$h/builder.err" ] && echo "FAIL:builder-stderr-must-be-empty"
    [ -x "$h/out/alpha" ] || echo "FAIL:alpha-reachable"
    [ -x "$h/out/gamma" ] || echo "FAIL:gamma-reachable-from-later-dir"
    [ -e "$h/out/realpath" ] && echo "FAIL:excluded-name-must-be-hidden"
    [ -e "$h/out/beta" ] && echo "FAIL:skipped-dir-must-not-be-mirrored"
    [ "$(readlink "$h/out/alpha" 2>/dev/null)" = "$h/a/alpha" ] || echo "FAIL:first-wins(alpha→a/)"
    rm -rf "$h/out2"; mkdir -p "$h/out2"
    HERMETIC_BIN_SKIP_GLOB="/nonexistent-prefix/*" build_hermetic_bin_excluding "$h/skipme" "$h/out2" "realpath"
    [ -x "$h/out2/beta" ] || echo "FAIL:non-matching-glob-still-mirrors"
    rm -rf "$h/out3"; mkdir -p "$h/out3" "$h/empty"
    build_hermetic_bin_excluding "$h/empty" "$h/out3" "realpath" 2>/dev/null || echo "FAIL:empty-dir-rc"
    build_hermetic_bin_excluding "" "$h/out3" "realpath" 2>/dev/null || echo "FAIL:empty-path-rc"
    [ -z "$(ls -A "$h/out3")" ] || echo "FAIL:empty-dir-no-links"
  )
}
HB_SRC="$(sed -n '/^build_hermetic_bin_excluding() {/,/^}/p' "${BASH_SOURCE[0]}")"
[ -n "$HB_SRC" ] || no "#1161 HB0: could not extract build_hermetic_bin_excluding from this file"
hb_out="$(hb_checks "$HB_SRC")"
[ -z "$hb_out" ] \
  && ok "#1161 HB1: builder — skip glob, first-wins, excluded name hidden, edge dirs (empty / absent / later-dir-only)" \
  || no "#1161 HB1: builder — $(printf '%s' "$hb_out" | tr '\n' ' ')"
case "$HB_SRC" in
  *'HERMETIC_BIN_SKIP_GLOB:-/mnt/*'*) ok "#1161 HB2: default skip glob is /mnt/* (WSL Windows mounts)" ;;
  *) no "#1161 HB2: default skip glob is not /mnt/*" ;;
esac
case "$HB_SRC" in
  *'basename'*) no "#1161 HB3: builder still forks basename per executable" ;;
  *) ok "#1161 HB3: no basename fork per executable (\${_exe##*/})" ;;
esac
# build_hermetic_nojq_bin <src_path> <out_dir> — convenience wrapper: excludes "jq".
build_hermetic_nojq_bin() { build_hermetic_bin_excluding "$1" "$2" "jq"; }
# build_hermetic_norealpath_bin <src_path> <out_dir> — convenience wrapper: excludes "realpath".
# jq stays reachable in this one: the degraded-mode fixtures below still need it to parse
# settings.json; only realpath's absence is under test.
build_hermetic_norealpath_bin() { build_hermetic_bin_excluding "$1" "$2" "realpath"; }

# _P8_REALPATH_GUARANTEED_DIR / run_rp <dir> — every test below that specifically exercises NORMAL
# (realpath-present) mode must not silently depend on the ambient host's PATH actually having
# realpath: running this whole suite under a PATH that lacks it (e.g. r3bin) would otherwise make
# these tests exercise DEGRADED mode instead and fail on their normal-mode wording. Locate the real
# `realpath` via `command -v` first; if the ambient PATH itself excludes it (exactly r3bin's shape
# — a PATH deliberately missing realpath while the binary still exists on disk), fall back to the
# well-known coreutils install locations directly, since those do not depend on PATH at all. Then
# symlink whichever was found into a dedicated dir and prepend that dir to PATH for every such run
# — the same technique the out-of-root bypass teeth mutant already uses.
_p8_rp_bin="$(command -v realpath 2>/dev/null || true)"
if [ -z "$_p8_rp_bin" ]; then
  for _p8_rp_candidate in /usr/bin/realpath /bin/realpath /usr/local/bin/realpath; do
    [ -x "$_p8_rp_candidate" ] && { _p8_rp_bin="$_p8_rp_candidate"; break; }
  done
fi
if [ -n "$_p8_rp_bin" ]; then
  _P8_REALPATH_GUARANTEED_DIR="$TMP/realpath-guaranteed-bin"; mkdir -p "$_P8_REALPATH_GUARANTEED_DIR"
  ln -sf "$_p8_rp_bin" "$_P8_REALPATH_GUARANTEED_DIR/realpath"
else
  _P8_REALPATH_GUARANTEED_DIR=""
fi
run_rp() {
  if [ -n "$_P8_REALPATH_GUARANTEED_DIR" ]; then
    PATH="$_P8_REALPATH_GUARANTEED_DIR:$PATH" bash "$SUT" "$1" 2>/dev/null
  else
    bash "$SUT" "$1" 2>/dev/null
  fi
}

# P8S-REPRO: settings.json wires tools/hooks/a.py (clean); settings.local.json wires
# .claude/hooks/orphan.sh (contains <TARGET>), which ALSO sits directly under .claude/hooks/ — named
# by two sources at once. It must be deduplicated to ONE inspected file and WARN exactly once, not
# be silently dropped by either source excluding the other.
d="$TMP/p8s-repro"; mk_state_p8 "$d"
mkdir -p "$d/tools/hooks" "$d/.claude/hooks"
printf '#!/usr/bin/env python3\nprint("clean")\n' > "$d/tools/hooks/a.py"
printf '#!/bin/bash\nT="<TARGET>"\necho "$T"\n' > "$d/.claude/hooks/orphan.sh"
mk_settings_cmds "$d" '$CLAUDE_PROJECT_DIR/tools/hooks/a.py'
mk_local_cmds "$d" '$CLAUDE_PROJECT_DIR/.claude/hooks/orphan.sh'
_p8sr="$(run "$d" 2>/dev/null)"
_p8sr_warns=$(echo "$_p8sr" | grep -cE 'WARN.*hook-placeholder.*orphan\.sh|hook-placeholder.*orphan\.sh.*WARN' 2>/dev/null || true)
[ "${_p8sr_warns:-0}" -eq 1 ] && ok "P8S-REPRO: a hook named by settings.local.json AND present in .claude/hooks/ is inspected exactly once" \
                              || no "P8S-REPRO: expected exactly 1 orphan.sh WARN, got $_p8sr_warns — got: $(echo "$_p8sr" | grep -i hook | head -5)"
if grep -qiE 'hook-set:.*settings\.json: 1 file' <<<"$_p8sr"; then
  ok "P8S-REPRO: summary names settings.json's contribution"
else
  no "P8S-REPRO: summary does not name settings.json's contribution: $(echo "$_p8sr" | grep -i 'hook-set:' | head -2)"
fi
if grep -qiE 'hook-set:.*settings\.local\.json: 1 file' <<<"$_p8sr"; then
  ok "P8S-REPRO: summary names settings.local.json's contribution"
else
  no "P8S-REPRO: summary does not name settings.local.json's contribution: $(echo "$_p8sr" | grep -i 'hook-set:' | head -2)"
fi
if grep -qiE 'hook-set:.*\.claude/hooks/\*: 1 file' <<<"$_p8sr"; then
  ok "P8S-REPRO: summary names .claude/hooks/*'s contribution"
else
  no "P8S-REPRO: summary does not name .claude/hooks/*'s contribution: $(echo "$_p8sr" | grep -i 'hook-set:' | head -2)"
fi
if grep -qiE 'hook-set:.*\(1 duplicate' <<<"$_p8sr"; then
  ok "P8S-REPRO: dedup count reports the 1 duplicate (orphan.sh named by two sources)"
else
  no "P8S-REPRO: dedup count missing/wrong: $(echo "$_p8sr" | grep -i 'hook-set:' | head -2)"
fi

# P8S-UNION: three files, one from EACH of the three distinct sources, no duplicates — proves the
# union genuinely combines all three rather than any one masking the others.
d="$TMP/p8s-union"; mk_state_p8 "$d"
mkdir -p "$d/tools/hooks" "$d/other" "$d/.claude/hooks"
printf '#!/bin/bash\nT="<TARGET>"\n'  > "$d/tools/hooks/from-settings.sh"
printf '#!/bin/bash\nS="<SUBJECT>"\n' > "$d/other/from-local.sh"
printf '#!/bin/bash\nK="<KIT>"\n'     > "$d/.claude/hooks/from-dir.sh"
mk_settings_cmds "$d" '$CLAUDE_PROJECT_DIR/tools/hooks/from-settings.sh'
mk_local_cmds    "$d" '$CLAUDE_PROJECT_DIR/other/from-local.sh'
_p8su="$(run "$d" 2>/dev/null)"
for _p8su_name in from-settings.sh from-local.sh from-dir.sh; do
  if grep -qiE "WARN.*hook-placeholder.*${_p8su_name}|hook-placeholder.*${_p8su_name}.*WARN" <<<"$_p8su"; then
    ok "P8S-UNION: $_p8su_name (its own source) is inspected and WARNs"
  else
    no "P8S-UNION: $_p8su_name did not WARN — got: $(echo "$_p8su" | grep -i hook | head -5)"
  fi
done
if grep -qiE 'hook-set:.*inspected 3 hook file.*\(0 duplicate' <<<"$_p8su"; then
  ok "P8S-UNION: union count is 3 with 0 duplicates (three genuinely distinct files)"
else
  no "P8S-UNION: union/dedup count wrong: $(echo "$_p8su" | grep -i 'hook-set:' | head -2)"
fi
unset _p8su_name

# P8S-LOCAL: settings.local.json ALONE (no settings.json) resolves and WARNs — settings.local.json
# is a first-class source, not just incidentally exercised by the repro/union fixtures above.
d="$TMP/p8s-local-only"; mk_state_p8 "$d"; mkdir -p "$d/tools/hooks"
printf '#!/bin/bash\nT="<TARGET>"\n' > "$d/tools/hooks/local-only.sh"
mk_local_cmds "$d" '$CLAUDE_PROJECT_DIR/tools/hooks/local-only.sh'
_p8sl="$(run "$d" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder.*local-only\.sh|hook-placeholder.*local-only\.sh.*WARN' <<<"$_p8sl"; then
  ok "P8S-LOCAL: settings.local.json alone (no settings.json) resolves and WARNs"
else
  no "P8S-LOCAL: expected WARN naming local-only.sh; got: $(echo "$_p8sl" | grep -i hook | head -3)"
fi

# P8S-A: single hook declared via settings.json, OUTSIDE .claude/hooks (niagara-research shape:
# $CLAUDE_PROJECT_DIR/tools/hooks/x.sh) — no .claude/hooks dir at all. A placeholder in that file
# must WARN.
d="$TMP/p8s-outside"; mk_state_p8 "$d"
mkdir -p "$d/tools/hooks"
printf '#!/bin/bash\nSUBJECT="<SUBJECT>"\necho "$SUBJECT"\n' > "$d/tools/hooks/protocol.sh"
mk_settings_cmds "$d" '$CLAUDE_PROJECT_DIR/tools/hooks/protocol.sh'
_p8sa="$(run "$d" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8sa"; then
  ok "P8S-A: settings-declared hook outside .claude/hooks/ (tools/hooks/) → placeholder WARN fires"
else
  no "P8S-A: settings-declared hook outside .claude/hooks/ → expected WARN; got: $(echo "$_p8sa" | grep -i hook | head -3)"
fi
if grep -qiE 'hook-set:.*settings\.json: 1 file' <<<"$_p8sa"; then
  ok "P8S-A: hook-set summary line names settings.json's contribution"
else
  no "P8S-A: hook-set summary line missing/wrong: $(echo "$_p8sa" | grep -i 'hook-set' | head -3)"
fi

# P8S-B: THREE settings-declared hooks (first/middle/last) — FIRST has the placeholder, middle and
# last are clean → WARN for the first only (edge: first position within the settings-derived set).
d="$TMP/p8s-first"; mk_state_p8 "$d"; mkdir -p "$d/tools/hooks"
printf '#!/bin/bash\nSUBJECT="<SUBJECT>"\necho first\n' > "$d/tools/hooks/a-first.sh"
printf '#!/bin/bash\necho middle\n'                     > "$d/tools/hooks/b-middle.sh"
printf '#!/bin/bash\necho last\n'                       > "$d/tools/hooks/c-last.sh"
mk_settings_cmds "$d" \
  '$CLAUDE_PROJECT_DIR/tools/hooks/a-first.sh' \
  '$CLAUDE_PROJECT_DIR/tools/hooks/b-middle.sh' \
  '$CLAUDE_PROJECT_DIR/tools/hooks/c-last.sh'
_p8sb="$(run "$d" 2>/dev/null)"
_p8sb_warns=$(echo "$_p8sb" | grep -cE 'WARN.*hook-placeholder|hook-placeholder.*WARN' 2>/dev/null || true)
[ "${_p8sb_warns:-0}" -eq 1 ] && ok "P8S-B: 3 settings hooks, FIRST placeholder → exactly 1 WARN" \
                              || no "P8S-B: expected exactly 1 WARN, got $_p8sb_warns"
if <<<"$(grep -iE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8sb")" grep -qF "a-first.sh"; then
  ok "P8S-B: WARN names the first settings-declared file (a-first.sh)"
else
  no "P8S-B: WARN does not name a-first.sh"
fi

# P8S-C: same 3-hook set, LAST has the placeholder, first/middle clean → WARN for the last only
# (edge: last position).
d="$TMP/p8s-last"; mk_state_p8 "$d"; mkdir -p "$d/tools/hooks"
printf '#!/bin/bash\necho first\n'                        > "$d/tools/hooks/a-first.sh"
printf '#!/bin/bash\necho middle\n'                       > "$d/tools/hooks/b-middle.sh"
printf '#!/bin/bash\nKIT_PATH="<KIT>/toolbelt/"\necho z\n' > "$d/tools/hooks/c-last.sh"
mk_settings_cmds "$d" \
  '$CLAUDE_PROJECT_DIR/tools/hooks/a-first.sh' \
  '$CLAUDE_PROJECT_DIR/tools/hooks/b-middle.sh' \
  '$CLAUDE_PROJECT_DIR/tools/hooks/c-last.sh'
_p8sc="$(run "$d" 2>/dev/null)"
if <<<"$(grep -iE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8sc")" grep -qF "c-last.sh"; then
  ok "P8S-C: 3 settings hooks, LAST placeholder → WARN names c-last.sh (last-position edge)"
else
  no "P8S-C: expected WARN naming c-last.sh; got: $(echo "$_p8sc" | grep -i hook | head -3)"
fi

# P8S-D: single-element settings-derived set (single-element edge), ABSOLUTE path form (no
# $CLAUDE_PROJECT_DIR prefix — the real api-paneles/blender-llm shape), clean → no WARN (sanity:
# absolute-path resolution works and does not false-positive).
d="$TMP/p8s-absolute"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\necho "clean"\n' > "$d/.claude/hooks/research-protocol.sh"
mk_settings_cmds "$d" "$d/.claude/hooks/research-protocol.sh"
_p8sd="$(run "$d" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8sd"; then
  no "P8S-D: absolute-path single settings hook, clean → unexpected WARN"
else
  ok "P8S-D: absolute-path single settings hook (single-element edge), clean → no WARN"
fi

# P8S-E: settings-declared hook command WITH ARGS resolving to a NON-.sh (.py) script that has a
# placeholder → WARN fires (proves interpreter/arg stripping AND non-.sh extensions both work).
d="$TMP/p8s-py-args"; mk_state_p8 "$d"; mkdir -p "$d/tools/hooks"
printf '#!/usr/bin/env python3\nSUBJECT = "<SUBJECT>"\nprint(SUBJECT)\n' > "$d/tools/hooks/lint.py"
mk_settings_cmds "$d" 'python3 $CLAUDE_PROJECT_DIR/tools/hooks/lint.py --strict --fix'
_p8se="$(run "$d" 2>/dev/null)"
if <<<"$(grep -iE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8se")" grep -qF "lint.py"; then
  ok "P8S-E: python3 ... lint.py --strict --fix (args + .py) → placeholder WARN names lint.py"
else
  no "P8S-E: expected WARN naming lint.py; got: $(echo "$_p8se" | grep -i hook | head -3)"
fi

# P8S-F: settings-declared command whose script does not exist on disk → reported loudly as
# unresolved (§7: unclassifiable, never silently skipped), no crash.
d="$TMP/p8s-unresolvable"; mk_state_p8 "$d"
mk_settings_cmds "$d" '$CLAUDE_PROJECT_DIR/tools/hooks/does-not-exist.sh'
_p8sf="$(run "$d" 2>/dev/null)"
if grep -qiE 'hook-set.*could not be resolved.*does-not-exist\.sh' <<<"$_p8sf"; then
  ok "P8S-F: unresolvable settings-declared command → loud 'could not be resolved' report"
else
  no "P8S-F: expected loud unresolved report; got: $(echo "$_p8sf" | grep -i 'hook-set' | head -3)"
fi
_p8sf_rc="$(code "$d")"
[ "$_p8sf_rc" -ne 2 ] && ok "P8S-F: unresolved settings command does not abort the whole run (rc=$_p8sf_rc)" \
                       || no "P8S-F: unresolved settings command aborted the run (rc=2)"
if grep -qiE 'hook-placeholder.*found-but-none-inspectable' <<<"$_p8sf"; then
  ok "P8S-F: summary reports found-but-none-inspectable, not plain empty"
else
  no "P8S-F: expected found-but-none-inspectable in the summary; got: $(echo "$_p8sf" | grep -i hook | head -3)"
fi

# P8S-G: settings.json present but declares NO hooks ({}), and no .claude/hooks/ dir either.
# settings.json EXISTS on disk, so this is empty-input (a source was found and looked empty), not
# absent-input (nothing existed), and — since nothing was ever DECLARED — not
# found-but-none-inspectable either (nothing to reject).
d="$TMP/p8s-empty-settings"; mk_state_p8 "$d"
mkdir -p "$d/.claude"; printf '{}\n' > "$d/.claude/settings.json"
_p8sg="$(run "$d" 2>/dev/null)"
if grep -qiE 'hook-placeholder.*\(empty\)' <<<"$_p8sg" && ! grep -qi 'found-but-none-inspectable' <<<"$_p8sg"; then
  ok "P8S-G: settings.json declares no hooks, no .claude/hooks/ → empty-input INFO"
else
  no "P8S-G: expected empty-input INFO; got: $(echo "$_p8sg" | grep -i hook | head -3)"
fi

# P8S-noneexist: NONE of settings.json / settings.local.json / .claude/hooks/ exist at all →
# absent-input INFO (distinct from P8S-G's empty-input above). Same fixture shape as P8-A.
d="$TMP/p8s-none"; mk_state_p8 "$d"; rm -rf "$d/.claude" 2>/dev/null || true
_p8sn="$(run "$d" 2>/dev/null)"
if grep -qiE 'hook-placeholder.*not found' <<<"$_p8sn"; then
  ok "P8S-noneexist: nothing exists at all → absent-input INFO, distinct wording from P8S-G's empty"
else
  no "P8S-noneexist: expected absent-input INFO; got: $(echo "$_p8sn" | grep -i hook | head -3)"
fi

# P8S-H: settings.json is present but NOT valid JSON → a DISTINCT 'malformed' status, never
# conflated with 'unreadable' (a permission failure). Falls back to .claude/hooks/*, which still
# gets scanned (a placeholder there still WARNs).
d="$TMP/p8s-invalid-json"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf 'not valid json {{{\n' > "$d/.claude/settings.json"
printf '#!/bin/bash\nSUBJECT="<SUBJECT>"\necho "$SUBJECT"\n' > "$d/.claude/hooks/research-protocol.sh"
_p8sh="$(run "$d" 2>/dev/null)"
if grep -qE '^ *malformed *hook-set:.*not valid JSON' <<<"$_p8sh"; then
  ok "P8S-H: invalid settings.json → typed 'malformed' report"
else
  no "P8S-H: expected 'malformed' report; got: $(echo "$_p8sh" | grep -i 'hook-set' | head -3)"
fi
if grep -qiE '^ *unreadable.*not valid JSON' <<<"$_p8sh"; then
  no "P8S-H: 'malformed' must never be reported as 'unreadable'"
else
  ok "P8S-H: invalid JSON is never labeled 'unreadable' — distinct status"
fi
if grep -qiE 'WARN.*hook-placeholder|hook-placeholder.*WARN' <<<"$_p8sh"; then
  ok "P8S-H: .claude/hooks/ still scanned after invalid settings.json (WARN fires)"
else
  no "P8S-H: fallback did not run after invalid settings.json; got: $(echo "$_p8sh" | grep -i hook | head -3)"
fi

# P8S-I: settings.json is present but NOT readable (chmod 000) → typed loud report, falls back.
d="$TMP/p8s-unreadable-settings"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
mk_settings_cmds "$d" '$CLAUDE_PROJECT_DIR/tools/hooks/x.sh'
chmod 000 "$d/.claude/settings.json" 2>/dev/null
_p8si="$(run "$d" 2>/dev/null)"
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP  P8S-I: unreadable settings.json (running as root, chmod 000 ignored)"
elif grep -qiE 'unreadable.*hook-set.*not readable|hook-set.*not readable' <<<"$_p8si"; then
  ok "P8S-I: unreadable settings.json → typed loud 'not readable' report"
else
  no "P8S-I: expected typed unreadable report; got: $(echo "$_p8si" | grep -i 'hook-set' | head -3)"
fi
chmod 644 "$d/.claude/settings.json" 2>/dev/null || true

# P8S-ECHOHI: a hook command with NO path token at all (`echo hi` — a plain word, no "/" and no
# recognized extension) must be reported loudly as unresolved, and must never abort the run. Run
# under the script's OWN real shell options (its shebang + its own `set -uo pipefail`, unmodified;
# see the errexit-hardening teeth proof below for what would happen WITHOUT the `|| true` guard
# under an injected `-e`).
d="$TMP/p8s-echohi"; mk_state_p8 "$d"
mk_settings_cmds "$d" 'echo hi'
_p8seh_out="$(bash "$SUT" "$d" 2>/dev/null)"; _p8seh_rc=$?
if grep -qiE "hook-set:.*could not be resolved.*: echo hi" <<<"$_p8seh_out"; then
  ok "P8S-ECHOHI: 'echo hi' (no path token) is reported loudly as unresolved"
else
  no "P8S-ECHOHI: expected loud unresolved report for 'echo hi'; got: $(echo "$_p8seh_out" | grep -i 'hook-set' | head -3)"
fi
[ "$_p8seh_rc" -le 1 ] && ok "P8S-ECHOHI: run completes normally (rc=$_p8seh_rc), no abort" \
                       || no "P8S-ECHOHI: run aborted unexpectedly (rc=$_p8seh_rc)"
unset _p8seh_out _p8seh_rc

# P8S-OUTOFROOT: a settings-declared command resolving to an ABSOLUTE path OUTSIDE the target root
# (e.g. `cat /etc/hostname`) must be reported 'out-of-root' and NEVER opened — §8/privacy. The
# outside file DOES contain a placeholder; if it were read for placeholders, it would WARN. It must
# not — this instrument reads only the target corpus.
d="$TMP/p8s-outofroot"; mk_state_p8 "$d"
outside="$TMP/p8s-outofroot-secret"; mkdir -p "$outside"
printf '#!/bin/bash\nT="<TARGET>"\n' > "$outside/secret.sh"
mk_settings_cmds "$d" "cat $outside/secret.sh"
_p8oor="$(run "$d" 2>/dev/null)"
if grep -qiE 'hook-set:.*out-of-root.*secret\.sh' <<<"$_p8oor"; then
  ok "P8S-OUTOFROOT: absolute path outside the target root is reported 'out-of-root'"
else
  no "P8S-OUTOFROOT: expected 'out-of-root' report; got: $(echo "$_p8oor" | grep -i 'hook-set' | head -3)"
fi
if grep -qiE 'hook-placeholder.*secret\.sh' <<<"$_p8oor"; then
  no "P8S-OUTOFROOT: secret.sh was READ for placeholders — privacy violation (§8)"
else
  ok "P8S-OUTOFROOT: secret.sh's placeholder content was never read (§8 respected)"
fi
if grep -qiE 'hook-placeholder.*found-but-none-inspectable' <<<"$_p8oor"; then
  ok "P8S-OUTOFROOT: summary reports found-but-none-inspectable, not plain empty"
else
  no "P8S-OUTOFROOT: expected found-but-none-inspectable in the summary; got: $(echo "$_p8oor" | grep -i hook | head -3)"
fi

# ----------------------------------------------------------------------------
# P8-S: symlinks in .claude/hooks/ — a hook is not always a plain file.
# ----------------------------------------------------------------------------

# P8S-SYM-INROOT: a .claude/hooks/ entry that is a SYMLINK whose target resolves IN-ROOT (a shared
# tools/hooks/ script linked into .claude/hooks/, exactly like niagara-research's layout but
# reached through a symlink instead of a settings.json command). It must be followed and inspected —
# excluding symlinks from the listing made this silently invisible.
d="$TMP/p8s-sym-inroot"; mk_state_p8 "$d"
mkdir -p "$d/tools/hooks" "$d/.claude/hooks"
printf '#!/bin/bash\nT="<TARGET>"\n' > "$d/tools/hooks/real.sh"
ln -s "../../tools/hooks/real.sh" "$d/.claude/hooks/real.sh"
_p8symin="$(run_rp "$d")"
if grep -qiE 'WARN.*hook-placeholder.*real\.sh|hook-placeholder.*real\.sh.*WARN' <<<"$_p8symin"; then
  ok "P8S-SYM-INROOT: an in-root symlink under .claude/hooks/ is followed and inspected"
else
  no "P8S-SYM-INROOT: expected WARN on the symlinked hook; got: $(echo "$_p8symin" | grep -i hook | head -3)"
fi

# P8S-SYM-OUTROOT: a .claude/hooks/ entry that is a SYMLINK whose target resolves OUTSIDE the target
# root. Must be reported out-of-root and never read — a symlink can escape exactly as an absolute
# command path can.
d="$TMP/p8s-sym-outroot"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
outside_sym="$TMP/p8s-sym-outroot-secret"; mkdir -p "$outside_sym"
printf '#!/bin/bash\nT="<TARGET>"\n' > "$outside_sym/secret.sh"
ln -s "$outside_sym/secret.sh" "$d/.claude/hooks/l.sh"
_p8symout="$(run_rp "$d")"
if grep -qiE 'hook-set:.*out-of-root.*secret\.sh' <<<"$_p8symout"; then
  ok "P8S-SYM-OUTROOT: a .claude/hooks/ symlink pointing outside the target root is reported out-of-root"
else
  no "P8S-SYM-OUTROOT: expected out-of-root report; got: $(echo "$_p8symout" | grep -i 'hook-set' | head -3)"
fi
if grep -qiE 'hook-placeholder.*secret\.sh' <<<"$_p8symout"; then
  no "P8S-SYM-OUTROOT: secret.sh was READ for placeholders — privacy violation (§8)"
else
  ok "P8S-SYM-OUTROOT: the outside symlink target's placeholder content was never read (§8 respected)"
fi

# P8S-DANGLING: a dangling symlink in .claude/hooks/ (points at a file that does not exist) is
# in-root by construction but not ultimately a regular file. It must be reported loudly — silently
# dropping it (as a plain subdirectory always was) hid a hook the old *.sh glob used to WARN on.
d="$TMP/p8s-dangling"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
ln -s nonexist.sh "$d/.claude/hooks/d.sh"
_p8dang="$(run_rp "$d")"
if grep -qiE 'hook-set:.*dangling or non-file symlink.*d\.sh' <<<"$_p8dang"; then
  ok "P8S-DANGLING: a dangling symlink alone is reported loudly, not silently dropped"
else
  no "P8S-DANGLING: expected a dangling-symlink report; got: $(echo "$_p8dang" | grep -i 'hook-set' | head -3)"
fi
if grep -qiE 'hook-placeholder.*found-but-none-inspectable' <<<"$_p8dang"; then
  ok "P8S-DANGLING: summary reports found-but-none-inspectable, not plain empty"
else
  no "P8S-DANGLING: expected found-but-none-inspectable in the summary; got: $(echo "$_p8dang" | grep -i hook | head -3)"
fi

# P8S-DANGLING-ALONGSIDE: the SAME dangling symlink sitting next to a genuinely valid hook — the
# dangling entry must still be reported, and the valid one must still be inspected normally (the
# union count reflects only the one real file).
d="$TMP/p8s-dangling-alongside"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
ln -s nonexist.sh "$d/.claude/hooks/d.sh"
printf '#!/bin/bash\nT="<TARGET>"\n' > "$d/.claude/hooks/valid.sh"
_p8danga="$(run_rp "$d")"
if grep -qiE 'hook-set:.*dangling or non-file symlink.*d\.sh' <<<"$_p8danga"; then
  ok "P8S-DANGLING-ALONGSIDE: the dangling symlink is still reported alongside a valid hook"
else
  no "P8S-DANGLING-ALONGSIDE: expected a dangling-symlink report; got: $(echo "$_p8danga" | grep -i 'hook-set' | head -3)"
fi
if grep -qiE 'WARN.*hook-placeholder.*valid\.sh|hook-placeholder.*valid\.sh.*WARN' <<<"$_p8danga"; then
  ok "P8S-DANGLING-ALONGSIDE: the valid hook is still inspected and WARNs normally"
else
  no "P8S-DANGLING-ALONGSIDE: expected valid.sh to WARN; got: $(echo "$_p8danga" | grep -i hook | head -3)"
fi
if grep -qiE 'hook-set:.*inspected 1 hook file' <<<"$_p8danga"; then
  ok "P8S-DANGLING-ALONGSIDE: union count is 1 (the dangling entry is excluded, not counted)"
else
  no "P8S-DANGLING-ALONGSIDE: expected a union count of 1; got: $(echo "$_p8danga" | grep -i 'hook-set:' | head -2)"
fi

# ----------------------------------------------------------------------------
# P8-S: root canonicalization — the target root itself needs canonicalizing (via the `cd + pwd -P`
# builtin combo, no external `realpath` required), not only the candidate hook paths checked
# against it.
# ----------------------------------------------------------------------------

# P8S-ROOT-DOT: invoking with "." while cwd == the target, in degraded mode. An ABSOLUTE
# settings-declared command naturally resolves to the target's real absolute location; without
# canonicalizing "." to that same absolute form first, the two never textually matched and a real,
# in-root file was reported out-of-root — a false positive, not a privacy leak.
d="$TMP/p8s-root-dot"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\nT="<TARGET>"\n' > "$d/.claude/hooks/x.sh"
mk_settings_cmds "$d" "$d/.claude/hooks/x.sh"   # the REAL absolute path, not $CLAUDE_PROJECT_DIR
if command -v realpath >/dev/null 2>&1; then
  _NOREAL_BIN2="$TMP/norealpath_bin2"; mkdir -p "$_NOREAL_BIN2"
  build_hermetic_norealpath_bin "$PATH" "$_NOREAL_BIN2"
  _p8rd="$(cd "$d" && PATH="$_NOREAL_BIN2" bash "$SUT" . 2>/dev/null)"
  if grep -qiE 'hook-set:.*out-of-root' <<<"$_p8rd"; then
    no "P8S-ROOT-DOT: an absolute in-root command was falsely reported out-of-root when target='.' (degraded)"
  else
    ok "P8S-ROOT-DOT: an absolute in-root command is NOT falsely out-of-root when target='.' (degraded)"
  fi
  if grep -qiE 'WARN.*hook-placeholder.*x\.sh|hook-placeholder.*x\.sh.*WARN' <<<"$_p8rd"; then
    ok "P8S-ROOT-DOT: the hook is still inspected and WARNs (target='.', degraded)"
  else
    no "P8S-ROOT-DOT: expected x.sh to WARN; got: $(echo "$_p8rd" | grep -i hook | head -3)"
  fi
else
  echo "  SKIP  P8S-ROOT-DOT: realpath already absent from PATH — cannot isolate the degraded probe"
fi
# Sanity: the same fixture, normal mode (realpath present) — must already have worked, and must
# still work after the canonicalization change (regression guard).
_p8rd_normal="$(cd "$d" && bash "$SUT" . 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder.*x\.sh|hook-placeholder.*x\.sh.*WARN' <<<"$_p8rd_normal" && ! grep -qiE 'hook-set:.*out-of-root' <<<"$_p8rd_normal"; then
  ok "P8S-ROOT-DOT: target='.' still WARNs correctly in normal mode (regression guard)"
else
  no "P8S-ROOT-DOT: target='.' regressed in normal mode; got: $(echo "$_p8rd_normal" | grep -i hook | head -3)"
fi

# P8S-ROOT-ANCESTOR-SYMLINK: the target argument's PATH is reached through a symlinked ANCESTOR
# directory (not the target directory itself) — `cd + pwd -P` must resolve the whole chain, not
# just a directly-symlinked final component.
d_real="$TMP/p8s-root-ancestor-real"; mkdir -p "$d_real/t"; mk_state_p8 "$d_real/t"
mkdir -p "$d_real/t/.claude/hooks"
printf '#!/bin/bash\nT="<TARGET>"\n' > "$d_real/t/.claude/hooks/x.sh"
ln -s "$d_real" "$TMP/p8s-root-ancestor-link"
_p8ras="$(run "$TMP/p8s-root-ancestor-link/t" 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder.*x\.sh|hook-placeholder.*x\.sh.*WARN' <<<"$_p8ras"; then
  ok "P8S-ROOT-ANCESTOR-SYMLINK: a target reached through a symlinked ancestor still resolves and WARNs"
else
  no "P8S-ROOT-ANCESTOR-SYMLINK: expected x.sh to WARN; got: $(echo "$_p8ras" | grep -i hook | head -3)"
fi

# P8S-CDPATH: an exported CDPATH pointing at a directory that itself contains a SAME-NAMED
# subdirectory (a decoy target) must never divert the root canonicalization there, and must never
# corrupt the canonicalized value into two lines — `cd`, when it resolves a bare relative argument
# via CDPATH, ALSO auto-prints the directory it found to stdout, which would otherwise land inside
# the captured value alongside pwd -P's own line. Invoked with a BARE relative target name (no
# leading "./") — that is what makes bash consult CDPATH for a `cd` in the first place.
d_cdp_base="$TMP/p8s-cdpath-base"
mkdir -p "$d_cdp_base/real/mytarget/.claude/hooks" "$d_cdp_base/decoy/mytarget/.claude/hooks"
mk_state_p8 "$d_cdp_base/real/mytarget"
printf '#!/bin/bash\nT="<TARGET>"\n' > "$d_cdp_base/real/mytarget/.claude/hooks/x.sh"
printf '#!/bin/bash\necho decoy\n' > "$d_cdp_base/decoy/mytarget/.claude/hooks/y.sh"
_p8cdp="$(cd "$d_cdp_base/real" && CDPATH="$d_cdp_base/decoy" bash "$SUT" mytarget 2>/dev/null)"
# kit issue #1034: the SUT prints the PHYSICAL root (pwd -P). Compare against the canonicalized
# expectation — a TMPDIR under a symlinked ancestor (macOS /var -> /private/var) must not break it.
_p8cdp_root="$(cd -P "$d_cdp_base/real/mytarget" && pwd -P)"
if grep -qiF "root: $_p8cdp_root)" <<<"$_p8cdp"; then
  ok "P8S-CDPATH: an exported CDPATH with a same-named decoy does not divert the canonicalized root"
else
  no "P8S-CDPATH: expected the real root in the summary line; got: $(echo "$_p8cdp" | grep -i 'hook-set:' | head -3)"
fi
if grep -qiE 'WARN.*hook-placeholder.*x\.sh|hook-placeholder.*x\.sh.*WARN' <<<"$_p8cdp"; then
  ok "P8S-CDPATH: the REAL target's hook (x.sh) is inspected, not the decoy's (y.sh)"
else
  no "P8S-CDPATH: expected x.sh to WARN (not the decoy); got: $(echo "$_p8cdp" | grep -i hook | head -3)"
fi
if grep -qi 'y\.sh' <<<"$_p8cdp"; then
  no "P8S-CDPATH: the decoy target's y.sh leaked into the output — CDPATH diverted the root"
else
  ok "P8S-CDPATH: the decoy target's y.sh never appears — CDPATH did not divert the root"
fi

# P8S-ROOT-DOTDOT-SYMLINK (kit issue #1034): the root is canonicalized PHYSICALLY (cd -P), matching the
# comment and the candidate-directory canonicalization. A target spelled <symlink>/.. is the physical
# parent of the link's real directory (that is also what the kernel resolves for the `-d` probes), NOT
# the logical parent of the link's own path.
d_dd="$TMP/p8s-dotdot"; mkdir -p "$d_dd/real/sub" "$d_dd/logical"
mk_state_p8 "$d_dd/real"; mkdir -p "$d_dd/real/.claude/hooks"
printf '#!/bin/bash\nT="<TARGET>"\n' > "$d_dd/real/.claude/hooks/x.sh"
ln -s "$d_dd/real/sub" "$d_dd/logical/link"
_p8dd="$(bash "$SUT" "$d_dd/logical/link/.." 2>/dev/null)"
if grep -qiE 'WARN.*hook-placeholder.*x\.sh|hook-placeholder.*x\.sh.*WARN' <<<"$_p8dd"; then
  ok "P8S-ROOT-DOTDOT-SYMLINK: <symlink>/.. canonicalizes physically (cd -P) and finds the real root's hook"
else
  no "P8S-ROOT-DOTDOT-SYMLINK: expected x.sh to WARN via the physical root; got: $(echo "$_p8dd" | grep -i 'hook' | head -3)"
fi

# P8S-SYMLINK-TARGET (kit issue #1034): the target passed as a SYMLINK without a trailing slash is
# found like the same path with one (find does not descend into a symlinked start path without -H).
d_stl="$TMP/p8s-symtarget-real"; mk_state_p8 "$d_stl"
ln -s "$d_stl" "$TMP/p8s-symtarget-link"
bash "$SUT" "$TMP/p8s-symtarget-link" >/dev/null 2>&1; _p8stl_rc=$?
if [ "$_p8stl_rc" != 2 ]; then
  ok "P8S-SYMLINK-TARGET: a symlinked target without a trailing slash is searched (exit $_p8stl_rc, not 'no RESEARCH-STATE' 2)"
else
  no "P8S-SYMLINK-TARGET: symlinked target without trailing slash exits 2 (no RESEARCH-STATE found)"
fi

# ----------------------------------------------------------------------------
# P8-S: distinct final states (§7 extended) — "found-but-none-inspectable" must fire whenever
# something was FOUND but every candidate was refused, and must never read the same as "empty"
# (nothing was ever declared) or "absent" (nothing exists at all). Each fixture below is minimal and
# isolated — no .claude/hooks/ at all — so the .claude/hooks/ source can never quietly supply a file
# that would flip the outcome to the union branch instead.
# ----------------------------------------------------------------------------

# unreadable settings.json, isolated
d="$TMP/p8s-state-unreadable"; mk_state_p8 "$d"
mk_settings_cmds "$d" '$CLAUDE_PROJECT_DIR/tools/hooks/x.sh'
chmod 000 "$d/.claude/settings.json" 2>/dev/null
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP  P8S-STATE-UNREADABLE: chmod 000 ignored when running as root"
else
  _p8str="$(run "$d" 2>/dev/null)"
  if grep -qiE 'hook-placeholder.*found-but-none-inspectable' <<<"$_p8str"; then
    ok "P8S-STATE-UNREADABLE: unreadable settings.json alone → found-but-none-inspectable, not 'empty'"
  else
    no "P8S-STATE-UNREADABLE: expected found-but-none-inspectable; got: $(echo "$_p8str" | grep -i hook | head -3)"
  fi
fi
chmod 644 "$d/.claude/settings.json" 2>/dev/null || true

# malformed JSON, isolated
d="$TMP/p8s-state-malformed"; mk_state_p8 "$d"; mkdir -p "$d/.claude"
printf 'not valid json {{{\n' > "$d/.claude/settings.json"
_p8stm="$(run "$d" 2>/dev/null)"
if grep -qiE 'hook-placeholder.*found-but-none-inspectable' <<<"$_p8stm"; then
  ok "P8S-STATE-MALFORMED: malformed settings.json alone → found-but-none-inspectable, not 'empty'"
else
  no "P8S-STATE-MALFORMED: expected found-but-none-inspectable; got: $(echo "$_p8stm" | grep -i hook | head -3)"
fi

# jq-degraded, isolated
if command -v jq >/dev/null 2>&1; then
  d="$TMP/p8s-state-nojq"; mk_state_p8 "$d"
  mk_settings_cmds "$d" '$CLAUDE_PROJECT_DIR/tools/hooks/x.sh'
  _NOJQ_BIN3="$TMP/nojq_bin3"; mkdir -p "$_NOJQ_BIN3"
  build_hermetic_nojq_bin "$PATH" "$_NOJQ_BIN3"
  _p8stj="$(PATH="$_NOJQ_BIN3" bash "$SUT" "$d" 2>/dev/null)"
  if grep -qiE 'hook-placeholder.*found-but-none-inspectable' <<<"$_p8stj"; then
    ok "P8S-STATE-NOJQ: jq-degraded settings.json alone → found-but-none-inspectable, not 'empty'"
  else
    no "P8S-STATE-NOJQ: expected found-but-none-inspectable; got: $(echo "$_p8stj" | grep -i hook | head -3)"
  fi
else
  echo "  SKIP  P8S-STATE-NOJQ: jq already absent from PATH"
fi

# unreadable .claude/hooks/ directory, isolated (no settings.json at all)
d="$TMP/p8s-state-unreadable-hooksdir"; mk_state_p8 "$d"; mkdir -p "$d/.claude/hooks"
printf '#!/bin/bash\necho hi\n' > "$d/.claude/hooks/x.sh"
chmod 000 "$d/.claude/hooks" 2>/dev/null
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP  P8S-STATE-UNREADABLE-HOOKSDIR: chmod 000 ignored when running as root"
else
  _p8sthd="$(run "$d" 2>/dev/null)"
  if grep -qiE 'hook-placeholder.*found-but-none-inspectable' <<<"$_p8sthd"; then
    ok "P8S-STATE-UNREADABLE-HOOKSDIR: unreadable .claude/hooks/ alone → found-but-none-inspectable, not 'empty'"
  else
    no "P8S-STATE-UNREADABLE-HOOKSDIR: expected found-but-none-inspectable; got: $(echo "$_p8sthd" | grep -i hook | head -3)"
  fi
fi
chmod 755 "$d/.claude/hooks" 2>/dev/null || true

# Regression guard: genuinely empty (nothing ever declared, nothing to reject) must keep saying
# 'empty' — the two states must stay visibly different from each other.
d="$TMP/p8s-state-empty-control"; mk_state_p8 "$d"
mkdir -p "$d/.claude"; printf '{}\n' > "$d/.claude/settings.json"
_p8ste="$(run "$d" 2>/dev/null)"
if grep -qiE 'hook-placeholder.*\(empty\)' <<<"$_p8ste" && ! grep -qi 'found-but-none-inspectable' <<<"$_p8ste"; then
  ok "P8S-STATE-EMPTY-CONTROL: nothing declared, nothing to reject → 'empty', never 'found-but-none-inspectable'"
else
  no "P8S-STATE-EMPTY-CONTROL: regression; got: $(echo "$_p8ste" | grep -i hook | head -3)"
fi

# P8-S teeth: mutate the union/dedup, containment, and extraction/detection primitives and confirm
# the fixtures above genuinely depend on each of them. Each mutant gets its OWN subdir with lib/
# copied in (matching the original P8 teeth block below) — a bare mutant in $TMP aborts at startup
# on "cannot find helper .../lib/focus-prefix.sh" before ever reaching P8, which is a startup
# failure, not a mutation result.

# P8-S teeth: errexit hardening. `_p8_tok="$(_p8_first_path_token "$cmd")"` is a plain assignment —
# NOT exempt from `errexit` the way an if/while condition is — so a bare-word command like `echo hi`
# (this function's ordinary, ungated `return 1`) would abort the WHOLE run under `set -e` before
# ever reaching the loud "could not be resolved" branch, UNLESS the call site is guarded with
# `|| true`. This script does not itself set `-e`; the mutants below inject it to isolate exactly
# what the guard buys.


# P8 teeth: neuter the placeholder grep → no WARN on <SUBJECT> hook → P8-D goes RED
# B3: syntax-valid mutant + lib/ included + assert startup succeeded.

# #1161 HB mutants: the builder lives in THIS file, so mutate its extracted text. Each mutant must
# differ from the builder (a no-op sed is theater) and trip the named assertion.

# teeth for kit #983: the OOB-separator width record in the verify-state mirror of the backlog awk.

# teeth for kit #1307: the out-of-backlog Priority-header guard in the verify-state mirror of the backlog awk.

# teeth for kit #1034 (built with the shared mutant helper, kit issue #943).

# teeth for kit #1361 item 2 (unblock: line on walls + ## Stretch goal shape), built with the shared mutant helper (kit issue #943).

# ---- SHIM CONTRACT (kit issue #2457) ----
# The report itself is pinned byte for byte against the frozen script by the Go differential tests
# (internal/verify, `make test`); the cases above run it end to end through this shim. These pin the shim only.
# stage_vs <dir> [shim]: a fixture toolbelt holding only the shim and its lib/rsdd-exec.sh (no check-gap-drift.sh:
# the gap-drift check runs in process since kit issue #2645).
stage_vs() { mkdir -p "$1"; rsdd_stage_libs "$1"; cp "${2:-$SUT}" "$1/verify-state.sh"; }
d="$TMP/shim-ok"; state "$d" "# s" "" "## Gap-backlog (prioritized)" "" "| Priority | Gap | Type | Status |" "|---|---|---|---|" "" "## Blocked gaps" "- none" "" "## Notes" "| note | B1-G1 a row that makes the gap-drift check run |" ""; addenv "$d" 0 0 0 0 0 0
stage_vs "$TMP/vs1"
out="$(bash "$TMP/vs1/verify-state.sh" "$d" 2>&1)"
if [ ! -e "$TMP/vs1/check-gap-drift.sh" ] && grep -q "verify-state" <<<"$out" && ! grep -q "gap-drift: degraded" <<<"$out"; then ok "SHIM-1 gap-drift runs in process: no checker beside the shim and no degraded WARN"
else no "SHIM-1 gap-drift degraded or no report :: $(grep -E "gap-drift|verify-state" <<<"$out" | head -3)"; fi
mkdir -p "$TMP/vs3"; cp "$SUT" "$TMP/vs3/verify-state.sh"
out3="$(bash "$TMP/vs3/verify-state.sh" "$d" 2>"$TMP/errvs3")"; rc3=$?
if [ "$rc3" = 2 ] && [ -z "$out3" ] && grep -q '^degraded: rsdd-unavailable — rsdd-exec.sh missing beside ' "$TMP/errvs3"; then ok "SHIM-3 missing rsdd-exec.sh → typed degraded line, rc 2"
else no "SHIM-3 missing lib: rc=$rc3 out=[$out3] err=[$(cat "$TMP/errvs3")]"; fi
out4="$(RSDD_BIN="$TMP/does-not-exist" bash "$SUT" "$d" 2>"$TMP/errvs4")"; rc4=$?
if [ "$rc4" = 2 ] && [ -z "$out4" ] && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/errvs4"; then ok "SHIM-4 unusable RSDD_BIN → typed degraded line, rc 2"
else no "SHIM-4 unusable binary: rc=$rc4 out=[$out4] err=[$(cat "$TMP/errvs4")]"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"
  # B: the wrong subcommand → the report disappears (case 1 family).
  if mk_mut "teeth B: wrong subcommand" "$SUT" "$TMP/vmutB.sh" 's/verify state/verify kit-clean/'; then
    stage_vs "$TMP/vmB" "$TMP/vmutB.sh"
    mo="$(bash "$TMP/vmB/verify-state.sh" "$d" 2>&1)"
    if ! grep -q 'verify-state' <<<"$mo"; then ok "teeth B: wrong subcommand → no verify-state report, the cases above would go RED"; else no "teeth B: mutant still prints the report"; fi
  fi
  # C: the missing-lib guard stripped → no typed degraded line (SHIM-3).
  if mk_mut "teeth C: guard removed" "$SUT" "$TMP/vmutC.sh" 's/ 2>\/dev\/null || { printf .*exit 2; }//'; then
    mkdir -p "$TMP/vmC"; cp "$TMP/vmutC.sh" "$TMP/vmC/verify-state.sh"
    bash "$TMP/vmC/verify-state.sh" "$d" >/dev/null 2>"$TMP/errvmC"
    if ! grep -q 'rsdd-exec.sh missing beside' "$TMP/errvmC"; then ok "teeth C: unguarded shim no longer announces a missing lib → SHIM-3 would go RED"; else no "teeth C: mutant still announces"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
