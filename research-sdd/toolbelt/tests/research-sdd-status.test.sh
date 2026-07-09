#!/usr/bin/env bash
# research-sdd-status.test.sh — RED-FIRST harness for research-sdd-status.sh --next resolution.
#
# The discriminating behaviour is DETERMINISTIC gap selection: highest-priority PENDING gap that is
# NOT blocked. Fixtures assert the ORDER (high beats medium beats low), the blocked-exclusion, and the
# clean STOP. --prove-teeth reverses the priority order in a mutant and asserts the "high over low"
# fixture then picks the WRONG gap — proving the test depends on the ordering logic.
#
# Usage: research-sdd-status.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-status.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# state <dir> <investigable> <backlog-rows...> ; blocked/stop appended. Rows: "priority|gap|status"
mkstate() {
  local dir="$1" inv="$2"; shift 2; mkdir -p "$dir"
  { echo "# T — Research State"; echo; echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    for r in "$@"; do IFS='|' read -r p g s <<<"$r"; echo "| $p | $g | web | $s |"; done
    echo; echo "## Blocked gaps (each tagged with what it needs)"; echo
    echo "- gpu profiling — needs: hardware"
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: $inv"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 1"
  } > "$dir/RESEARCH-STATE.md"
}
next() { bash "$SUT" "$1" --next 2>/dev/null; }
expect_next() { local got; got="$(next "$1")"; [ "$got" = "$2" ] && ok "$3" || no "$3 — got [$got] want [$2]"; }

echo "== research-sdd-status.test.sh =="

# 1 — high beats medium beats low
d="$TMP/order"; mkstate "$d" 3 "high|reconstruct the shader pipeline|pending" "medium|map the loaders|pending" "low|trivia|pending"
expect_next "$d" "NEXT | high | reconstruct the shader pipeline" "high beats medium+low"

# 2 — no high → medium is next
d="$TMP/nomed"; mkstate "$d" 2 "medium|map the loaders|pending" "low|trivia|pending"
expect_next "$d" "NEXT | medium | map the loaders" "medium chosen when no high pending"

# 3 — a high row that is ALSO blocked is skipped → medium next
d="$TMP/blocked"; mkstate "$d" 2 "high|gpu profiling|pending" "medium|map the loaders|pending"
expect_next "$d" "NEXT | medium | map the loaders" "blocked high gap is skipped"

# 4 — nothing pending + investigable 0 → clean STOP
d="$TMP/stop"; mkstate "$d" 0 "high|done thing|covered" "low|also done|covered"
expect_next "$d" "STOP | read-only-investigable exhausted (0)" "clean STOP when investigable=0"

# 5 — no RESEARCH-STATE → BOOTSTRAP
d="$TMP/empty"; mkdir -p "$d"
got="$(next "$d")"; case "$got" in BOOTSTRAP\ *) ok "BOOTSTRAP when no state";; *) no "BOOTSTRAP when no state — got [$got]";; esac

# 6 — NESTED corpus (state under corpus/) resolves
d="$TMP/nested"; mkstate "$d/corpus" 1 "high|nested gap|pending"; : > "$d/app.html"
expect_next "$d" "NEXT | high | nested gap" "resolves a nested corpus/ state"

# 7 — default status report reflects the backlog counts
d="$TMP/report"; mkstate "$d" 4 "high|g1|pending" "high|g2|pending" "medium|g3|pending" "low|g4|covered"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -q 'high=2 medium=1 low=0' && ok "status: pending counts by priority" || no "status: pending counts ($(printf '%s' "$rep" | grep pending))"

# 8 — a NEGATED status ("not pending") must NOT be treated as pending (was: *pending* substring match)
d="$TMP/negstatus"; mkstate "$d" 1 "high|resolved item|not pending anymore" "medium|real gap|pending"
expect_next "$d" "NEXT | medium | real gap" "negated status not treated as pending"

# 9 — a pending gap named like a blocked "needs:" clause must NOT be false-skipped (was: substring exclusion)
#     (mkstate's blocked line is "- gpu profiling — needs: hardware"; the gap 'hardware' must survive)
d="$TMP/subblock"; mkstate "$d" 1 "high|hardware|pending"
expect_next "$d" "NEXT | high | hardware" "gap 'hardware' not killed by 'needs: hardware' blocked line"

# 10 — a gap description mentioning the §8 phrase must NOT mask a real STOP (was: whole-file grep)
d="$TMP/phrasemask"; mkdir -p "$d"
{ echo "# T"; echo; echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | audit the read-only investigable subsystems | web | covered |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d/RESEARCH-STATE.md"
expect_next "$d" "STOP | read-only-investigable exhausted (0)" "gap text mentioning the phrase does not mask STOP"

# 11 — a pipe inside a Gap cell is WARNed to stderr, never silently dropped (was: awk -F'|' misfield)
d="$TMP/pipe"; mkdir -p "$d"
{ echo "# T"; echo; echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | compare A | B render paths | web | pending |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
warn="$(bash "$SUT" "$d" --next 2>&1 >/dev/null)"
printf '%s' "$warn" | grep -qi 'malformed backlog row' && ok "pipe-in-gap emits a WARN (not a silent drop)" || no "pipe-in-gap: no WARN emitted"

# 12 — STALE: state claims all gaps closed but backlog still lists pending (verify-state FAIL) → refuse NEXT
d="$TMP/stale"; mkdir -p "$d"
{ echo "# T"; echo; echo "## Coverage"; echo "- **Coverage metric**: 3 / 3 closed"; echo
  echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | still open gap | web | pending |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
got="$(next "$d")"; case "$got" in STALE\ *) ok "STALE when summary claims done but backlog pending";; *) no "STALE case — got [$got]";; esac

# 13 — outer-pipe-less GFM row (valid GFM) parses correctly, not silently dropped
d="$TMP/unbounded"; mkdir -p "$d"
{ echo "# T"; echo; echo "## Gap-backlog"; echo
  echo "Priority | Gap | type | Status"; echo "---|---|---|---"
  echo "high | no outer pipes gap | web | pending"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
expect_next "$d" "NEXT | high | no outer pipes gap" "outer-pipe-less GFM row parses"

# 14 — plain-hyphen blocked entry still excludes its gap (was: only em-dash handled)
d="$TMP/hyphenblock"; mkdir -p "$d"
{ echo "# T"; echo; echo "## Gap-backlog"; echo
  echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | blocked thing | web | pending |"; echo "| medium | free thing | web | pending |"; echo
  echo "## Blocked gaps"; echo "- blocked thing - needs: hardware"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 2"; } > "$d/RESEARCH-STATE.md"
expect_next "$d" "NEXT | medium | free thing" "plain-hyphen blocked entry excludes its gap"

# 15 — en-dash blocked entry also excludes its gap
d="$TMP/endashblock"; mkdir -p "$d"
{ echo "# T"; echo; echo "## Gap-backlog"; echo
  echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | blocked thing | web | pending |"; echo "| medium | free thing | web | pending |"; echo
  echo "## Blocked gaps"; echo "- blocked thing – needs: hardware"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 2"; } > "$d/RESEARCH-STATE.md"
expect_next "$d" "NEXT | medium | free thing" "en-dash blocked entry excludes its gap"

# 16 — default `status` exits 0 even on a stale (verify-state FAIL) corpus (contract: 0 ok / 2 bad args)
d="$TMP/exitcode"; mkdir -p "$d"
{ echo "# T"; echo; echo "## Coverage"; echo "- **Coverage metric**: 2 / 2 closed"; echo
  echo "## Gap-backlog"; echo "| P | G | t | S |"; echo "|-|-|-|-|"; echo "| high | still open | web | pending |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "default status exits 0 even on a stale corpus" || no "default status exit=$rc (want 0)"

# mkledger <dir> — writes a CONTRADICTIONS.md with 2 open + 1 resolved row (id|A|B|status|note).
mkledger() {
  { echo "# T — Contradictions ledger"; echo
    echo "| id | claim A (block) | claim B (block) | status | note |"
    echo "|---|---|---|---|---|"
    echo "| C1 | A says X (B1) | B says Y (B2) | open | cannot adjudicate yet |"
    echo "| C2 | foo=1 (B3) | foo=2 (B4) | open | |"
    echo "| C3 | baz (B5) | qux (B6) | resolved | B5 won per §14 |"
  } > "$1/CONTRADICTIONS.md"
}

# 17 — default status surfaces the count of OPEN contradictions (2 open, 1 resolved → "2 open")
d="$TMP/contra"; mkstate "$d" 3 "high|g1|pending"; mkledger "$d"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -q 'contradictions  : 2 open' && ok "status: surfaces 2 open contradictions" || no "status: open-contradiction count ($(printf '%s' "$rep" | grep -i contradic))"

# 18 — NO ledger → quiet no-ledger line, still exits 0 (never errors)
d="$TMP/noledger"; mkstate "$d" 1 "high|g1|pending"
rep="$(bash "$SUT" "$d" 2>/dev/null)"; bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
if printf '%s' "$rep" | grep -q 'contradictions  : (no ledger)' && [ "$rc" = 0 ]; then ok "status: quiet no-ledger line, exit 0"
else no "status: no-ledger line/exit ($(printf '%s' "$rep" | grep -i contradic), rc=$rc)"; fi

# 19 — REGRESSION guard: --next output must be UNCHANGED by a CONTRADICTIONS.md (machine contract untouched)
d="$TMP/contraregress"; mkstate "$d" 2 "high|the gap|pending"
before="$(next "$d")"; mkledger "$d"; after="$(next "$d")"
if [ "$before" = "$after" ] && ! printf '%s' "$after" | grep -qi contradic; then ok "--next contract unchanged by a ledger"
else no "--next leaked: before[$before] after[$after]"; fi

# mkledger1 <dir> <status> <note> — one-row ledger to probe column-scoping (status vs note cell).
mkledger1() {
  { echo "# T — Contradictions ledger"; echo
    echo "| id | claim A (block) | claim B (block) | status | note |"
    echo "|---|---|---|---|---|"
    echo "| C1 | X (B1) | Y (B2) | $2 | $3 |"
  } > "$1/CONTRADICTIONS.md"
}

# 20 — column-scope: a note cell literally "open" on a RESOLVED row must NOT count (STATUS cell only)
d="$TMP/notecol"; mkstate "$d" 1 "high|g1|pending"; mkledger1 "$d" "resolved" "open"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -q 'contradictions  : (none)' && ok "note-cell 'open' on resolved row not counted (column-scoped)" || no "column-scope over-count ($(printf '%s' "$rep" | grep -i contradic))"

# 21 — column-scope mixed: 1 real open (status cell) + 1 resolved-with-note-open → exactly 1 open
d="$TMP/mixedcol"; mkstate "$d" 1 "high|g1|pending"
{ echo "# T"; echo; echo "| id | claim A (block) | claim B (block) | status | note |"; echo "|---|---|---|---|---|"
  echo "| C1 | X (B1) | Y (B2) | open | note |"
  echo "| C2 | A (B3) | B (B4) | resolved | open |"; } > "$d/CONTRADICTIONS.md"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -q 'contradictions  : 1 open' && ok "status-cell open counts, note-cell open does not (mixed)" || no "mixed column-scope ($(printf '%s' "$rep" | grep -i contradic))"

# 22 — multiple ledger files → counted across ALL (never silently dropped) + a WARN to stderr
d="$TMP/multi"; mkstate "$d" 1 "high|g1|pending"; mkledger "$d"        # CONTRADICTIONS.md: 2 open
{ echo "# T"; echo; echo "| id | claim A | claim B | status | note |"; echo "|---|---|---|---|---|"
  echo "| Z1 | P (B7) | Q (B8) | open | archived-open |"; } > "$d/CONTRADICTIONS-archive.md"   # +1 open
rep="$(bash "$SUT" "$d" 2>/dev/null)"; warn="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
if printf '%s' "$rep" | grep -q 'contradictions  : 3 open' && printf '%s' "$warn" | grep -qi 'multiple CONTRADICTIONS'; then ok "multiple ledgers counted across all + WARN"
else no "multi-ledger ($(printf '%s' "$rep" | grep -i contradic) | warn=$(printf '%s' "$warn" | grep -i CONTRADICTIONS))"; fi

# 23 — header/separator-only ledger (no data rows) → (none), never a spurious count, exit unchanged
d="$TMP/headeronly"; mkstate "$d" 1 "high|g1|pending"
{ echo "# T"; echo; echo "| id | claim A | claim B | status | note |"; echo "|---|---|---|---|---|"; } > "$d/CONTRADICTIONS.md"
rep="$(bash "$SUT" "$d" 2>/dev/null)"; bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
if printf '%s' "$rep" | grep -q 'contradictions  : (none)' && [ "$rc" = 0 ]; then ok "header-only ledger → (none), exit 0"
else no "header-only ($(printf '%s' "$rep" | grep -i contradic), rc=$rc)"; fi

# mkiter <dir> <inv> <"num|newgaps"...> — a minimal state WITH an ## Iteration history table.
# Each arg becomes one data row; col 6 ("New gaps uncovered") = <newgaps>. A backlog pending gap is
# included so verify-state stays consistent (NEXT), keeping the --next regression guards meaningful.
mkiter() {
  local dir="$1" inv="$2"; shift 2; mkdir -p "$dir"
  { echo "# T"; echo; echo "## Gap-backlog"; echo
    echo "| P | G | t | S |"; echo "|-|-|-|-|"; echo "| high | g1 | web | pending |"; echo
    echo "## Iteration history"; echo
    echo "| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |"
    echo "|---|---|---|---|---|---|"
    for r in "$@"; do IFS='|' read -r num ng <<<"$r"; echo "| $num | 2026-01-01 | gap$num | B$num | no · inline | $ng |"; done
    echo; echo "## Stop control"; echo "- **Open gaps — read-only investigable**: $inv"
  } > "$dir/RESEARCH-STATE.md"
}

# 24 — last 3 iterations net 0 new gaps → SATURATED (review) signal in the DEFAULT status report
d="$TMP/sat"; mkiter "$d" 1 "1|0" "2|0" "3|0"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -q 'saturation      : SATURATED (review) — last 3 iterations netted 0 new gaps' && ok "saturation: 0 over last 3 numeric iterations → SATURATED (review)" || no "saturation: SATURATED not surfaced ($(printf '%s' "$rep" | grep -i saturation))"

# 25 — last 3 sum > 0 (2,0,1 → 3) → active, NOT saturated
d="$TMP/active"; mkiter "$d" 1 "1|2" "2|0" "3|1"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -q 'saturation      : active (3 new gaps in last 3 iter)' && ok "saturation: nonzero sum over last 3 → active" || no "saturation: active line ($(printf '%s' "$rep" | grep -i saturation))"

# 25b — WINDOW is the last 3 ONLY: an older iteration with new gaps does NOT rescue a saturated tail
d="$TMP/window"; mkiter "$d" 1 "1|9" "2|0" "3|0" "4|0"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -q 'saturation      : SATURATED (review)' && ok "saturation: only the last 3 iterations count (older gaps excluded)" || no "saturation: window not last-3 ($(printf '%s' "$rep" | grep -i saturation))"

# 26 — fewer than 3 numeric rows → insufficient history, NOT flagged
d="$TMP/insuff"; mkiter "$d" 1 "1|2" "2|1"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -q 'saturation      : insufficient history (2 iterations)' && ok "saturation: <3 numeric rows → insufficient history" || no "saturation: insufficient line ($(printf '%s' "$rep" | grep -i saturation))"

# 26b — a template `<n>` placeholder in col 6 (with pipes in the Delegated cell) is NOT counted numeric
d="$TMP/placeholder"; mkdir -p "$d"
{ echo "# T"; echo; echo "## Iteration history"; echo
  echo "| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |"
  echo "|---|---|---|---|---|---|"
  echo "| 1 | 2026-01-01 | g | B1 | no · inline | 0 |"
  echo "| 2 | 2026-01-02 | g | B2 | no · inline | 0 |"
  echo "| 3 | <date> | <gap> | B<k> | <no · inline / yes · haiku|sonnet|opus> | <n> |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -q 'saturation      : insufficient history (2 iterations)' && ok "saturation: <n> placeholder row not counted as a numeric iteration" || no "saturation: placeholder counted ($(printf '%s' "$rep" | grep -i saturation))"

# 27 — rows OUT OF # ORDER are sorted numerically before the last-3 window is taken
d="$TMP/order"; mkiter "$d" 1 "4|9" "1|0" "2|0" "3|0"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -q 'saturation      : active (9 new gaps in last 3 iter)' && ok "saturation: rows sorted by # before taking the last 3" || no "saturation: not sorted by # ($(printf '%s' "$rep" | grep -i saturation))"

# 28 — no ## Iteration history section → (no iteration history), no error, exit unchanged (mkstate emits none)
d="$TMP/nohist"; mkstate "$d" 1 "high|g1|pending"
rep="$(bash "$SUT" "$d" 2>/dev/null)"; bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
if printf '%s' "$rep" | grep -q 'saturation      : (no iteration history)' && [ "$rc" = 0 ]; then ok "saturation: no history section → (no iteration history), exit 0"
else no "saturation: no-history line/exit ($(printf '%s' "$rep" | grep -i saturation), rc=$rc)"; fi

# 29 — REGRESSION guard: --next output BYTE-IDENTICAL with/without an ## Iteration history table
d="$TMP/satregress"; mkstate "$d" 2 "high|the gap|pending"
before="$(next "$d")"
{ echo; echo "## Iteration history"; echo
  echo "| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |"
  echo "|---|---|---|---|---|---|"
  echo "| 1 | 2026-01-01 | g | B1 | no · inline | 0 |"
  echo "| 2 | 2026-01-02 | g | B2 | no · inline | 0 |"
  echo "| 3 | 2026-01-03 | g | B3 | no · inline | 0 |"; } >> "$d/RESEARCH-STATE.md"
after="$(next "$d")"
if [ "$before" = "$after" ] && ! printf '%s' "$after" | grep -qi saturation; then ok "--next contract unchanged by an iteration-history table"
else no "--next leaked: before[$before] after[$after]"; fi

# 30 — TEMPLATE is not real state: a dir holding ONLY the kit `RESEARCH-STATE.template.md` (placeholders,
#      no real corpus state) must resolve to BOOTSTRAP, not parse the template as work. The find must
#      exclude `*.template.md`. RED before the fix: the template was picked as the state file and its
#      placeholder backlog row was handed out as NEXT.
d="$TMP/tmplonly"; mkdir -p "$d"
{ echo "# <SUBJECT> — Research State"; echo; echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
  echo "| high | <research question> | web | pending |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.template.md"
got="$(next "$d")"; case "$got" in BOOTSTRAP\ *) ok "template-only → BOOTSTRAP (*.template.md is not real state)";; *) no "template-only --next — got [$got] want BOOTSTRAP";; esac

# 31 — POSITIVE CONTROL: a REAL RESEARCH-STATE.md coexisting with a RESEARCH-STATE.template.md → the
#      REAL state is resolved and its gap handed out, the template ignored. Pins that the exclusion does
#      not drop real state.
d="$TMP/real-plus-template"; mkstate "$d" 1 "high|real pending gap|pending"
{ echo "# <SUBJECT> — Research State"; echo; echo "## Gap-backlog"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | <placeholder gap> | web | pending |"; } > "$d/RESEARCH-STATE.template.md"
expect_next "$d" "NEXT | high | real pending gap" "real state used, template ignored"

# 32 — TEMPLATE not counted on disk: the status report's on-disk *block*.md count must EXCLUDE a stray
#      block.template.md in the corpus dir. Two real blocks + one template → "2 on disk", not 3. RED
#      before the fix: the loose `-name '*block*.md'` glob counted the template too.
d="$TMP/tmpl-block-count"; mkstate "$d" 1 "high|g1|pending"
printf 'x\n' > "$d/a-block1.md"; printf 'x\n' > "$d/b-block2.md"; printf 'x\n' > "$d/block.template.md"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
printf '%s' "$rep" | grep -qE 'covered blocks  : .*· 2 on disk' && ok "on-disk block count excludes block.template.md (2, not 3)" || no "on-disk count ($(printf '%s' "$rep" | grep -i 'covered blocks'))"

# NEGATIVE CONTROL — reverse the priority order; the "high beats low" fixture must then pick LOW.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: reverse priority order in a mutant, expect the order fixture to pick the WRONG gap --"
  mutant="$TMP/status.MUTANT.sh"
  sed 's/for prio in high medium low/for prio in low medium high/' "$SUT" > "$mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"   # the mutant resolves $here to $TMP; it needs verify-state there
  d="$TMP/teeth"; mkstate "$d" 2 "high|the high one|pending" "low|the low one|pending"
  mgot="$(bash "$mutant" "$d" --next 2>/dev/null)"
  if [ "$mgot" = "NEXT | low | the low one" ]; then ok "teeth: reversed mutant picks low → ordering test has teeth"
  else no "teeth: mutant picked [$mgot] — ordering not exercised (THEATER)"; fi

  # saturation teeth: widen the threshold (-eq 0 → -ge 0) so EVERY window "saturates"; the active
  # fixture (2,0,1 → sum 3) must then WRONGLY report SATURATED, proving the threshold is exercised.
  smutant="$TMP/status.SAT-MUTANT.sh"
  sed 's/-eq 0/-ge 0/' "$SUT" > "$smutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"   # the mutant resolves $here to $TMP
  d="$TMP/satteeth"; mkiter "$d" 1 "1|2" "2|0" "3|1"
  srep="$(bash "$smutant" "$d" 2>/dev/null)"
  if printf '%s' "$srep" | grep -q 'saturation      : SATURATED'; then ok "teeth: widened-threshold mutant over-flags an active window → saturation test has teeth"
  else no "teeth: sat mutant did not over-flag [$(printf '%s' "$srep" | grep -i saturation)] — threshold not exercised (THEATER)"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
