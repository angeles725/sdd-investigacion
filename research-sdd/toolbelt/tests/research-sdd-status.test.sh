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
# NOTE: mkstate now SEEDS a derived-consistent research-state.v1 envelope (near the top, after the H1) so
# every fixture passes verify-state.sh's new envelope gate — otherwise --next would return STALE on the
# missing envelope instead of exercising resolve_next. The envelope's derived triplet is computed HERE from
# the same rules the SUT uses: covered_blocks=0 (mkstate writes no block files), blocked_open=1 (the fixed
# 'gpu profiling' entry), investigable_open = pending (leading-token) non-'gpu profiling' rows.
mkstate() {
  local dir="$1" inv="$2"; shift 2; mkdir -p "$dir"
  local io=0 r p g s
  for r in "$@"; do IFS='|' read -r p g s <<<"$r"
    [ "${s%% *}" = "pending" ] || continue
    [ "$g" = "gpu profiling" ] && continue       # the fixed blocked entry mkstate writes below
    io=$((io+1))
  done
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: %s\nrequires_execution_open: 0\nblocked_open: 1\n<!-- /research-state.v1 -->\n' "$io"; echo
    echo "## Gap-backlog (prioritized)"; echo
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
# env_lines <covered> <gc> <kg> <io> <req> <bo> — the research-state.v1 envelope, for raw-printf fixtures
# that don't use mkstate (which seeds its own). A valid envelope is required or --next returns STALE on the gate.
env_lines(){ printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: %s\ngaps_closed: %s\nknown_gaps: %s\ninvestigable_open: %s\nrequires_execution_open: %s\nblocked_open: %s\n<!-- /research-state.v1 -->\n' "$@"; }

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
grep -q 'high=2 medium=1 low=0' <<<"$rep" && ok "status: pending counts by priority" || no "status: pending counts ($(grep pending <<<"$rep"))"

# 8 — a NEGATED status ("not pending") must NOT be treated as pending (was: *pending* substring match)
d="$TMP/negstatus"; mkstate "$d" 1 "high|resolved item|not pending anymore" "medium|real gap|pending"
expect_next "$d" "NEXT | medium | real gap" "negated status not treated as pending"

# 9 — a pending gap named like a blocked "needs:" clause must NOT be false-skipped (was: substring exclusion)
#     (mkstate's blocked line is "- gpu profiling — needs: hardware"; the gap 'hardware' must survive)
d="$TMP/subblock"; mkstate "$d" 1 "high|hardware|pending"
expect_next "$d" "NEXT | high | hardware" "gap 'hardware' not killed by 'needs: hardware' blocked line"

# 10 — a gap description mentioning the §8 phrase must NOT mask a real STOP (was: whole-file grep)
d="$TMP/phrasemask"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 0 0 0; echo; echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | audit the read-only investigable subsystems | web | covered |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d/RESEARCH-STATE.md"
expect_next "$d" "STOP | read-only-investigable exhausted (0)" "gap text mentioning the phrase does not mask STOP"

# 11 — a pipe inside a Gap cell is WARNed to stderr, never silently dropped (was: awk -F'|' misfield)
d="$TMP/pipe"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 0 0 0; echo; echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | compare A | B render paths | web | pending |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
warn="$(bash "$SUT" "$d" --next 2>&1 >/dev/null)"
grep -qi 'malformed backlog row' <<<"$warn" && ok "pipe-in-gap emits a WARN (not a silent drop)" || no "pipe-in-gap: no WARN emitted"

# 12 — STALE: state claims all gaps closed but backlog still lists pending (verify-state FAIL) → refuse NEXT
d="$TMP/stale"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 3 3 1 0 0; echo; echo "## Coverage"; echo "- **Coverage metric**: 3 / 3 closed"; echo
  echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | still open gap | web | pending |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
# envelope CHECK D fires: declared full coverage (gaps_closed==known_gaps==3) while 1 investigable gap remains.
got="$(next "$d")"; case "$got" in STALE\ *) ok "STALE when summary claims done but backlog pending";; *) no "STALE case — got [$got]";; esac

# 13 — outer-pipe-less GFM row (valid GFM) parses correctly, not silently dropped
d="$TMP/unbounded"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 1 0 0; echo; echo "## Gap-backlog"; echo
  echo "Priority | Gap | type | Status"; echo "---|---|---|---"
  echo "high | no outer pipes gap | web | pending"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
expect_next "$d" "NEXT | high | no outer pipes gap" "outer-pipe-less GFM row parses"

# 14 — plain-hyphen blocked entry still excludes its gap (was: only em-dash handled)
d="$TMP/hyphenblock"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 1 0 1; echo; echo "## Gap-backlog"; echo
  echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | blocked thing | web | pending |"; echo "| medium | free thing | web | pending |"; echo
  echo "## Blocked gaps"; echo "- blocked thing - needs: hardware"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 2"; } > "$d/RESEARCH-STATE.md"
expect_next "$d" "NEXT | medium | free thing" "plain-hyphen blocked entry excludes its gap"

# 15 — en-dash blocked entry also excludes its gap
d="$TMP/endashblock"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 1 0 1; echo; echo "## Gap-backlog"; echo
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
grep -q 'contradictions  : 2 open' <<<"$rep" && ok "status: surfaces 2 open contradictions" || no "status: open-contradiction count ($(grep -i contradic <<<"$rep"))"

# 18 — NO ledger → quiet no-ledger line, still exits 0 (never errors)
d="$TMP/noledger"; mkstate "$d" 1 "high|g1|pending"
rep="$(bash "$SUT" "$d" 2>/dev/null)"; bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
if grep -q 'contradictions  : (no ledger)' <<<"$rep" && [ "$rc" = 0 ]; then ok "status: quiet no-ledger line, exit 0"
else no "status: no-ledger line/exit ($(grep -i contradic <<<"$rep"), rc=$rc)"; fi

# 19 — REGRESSION guard: --next output must be UNCHANGED by a CONTRADICTIONS.md (machine contract untouched)
d="$TMP/contraregress"; mkstate "$d" 2 "high|the gap|pending"
before="$(next "$d")"; mkledger "$d"; after="$(next "$d")"
if [ "$before" = "$after" ] && ! grep -qi contradic <<<"$after"; then ok "--next contract unchanged by a ledger"
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
grep -q 'contradictions  : (none)' <<<"$rep" && ok "note-cell 'open' on resolved row not counted (column-scoped)" || no "column-scope over-count ($(grep -i contradic <<<"$rep"))"

# 21 — column-scope mixed: 1 real open (status cell) + 1 resolved-with-note-open → exactly 1 open
d="$TMP/mixedcol"; mkstate "$d" 1 "high|g1|pending"
{ echo "# T"; echo; echo "| id | claim A (block) | claim B (block) | status | note |"; echo "|---|---|---|---|---|"
  echo "| C1 | X (B1) | Y (B2) | open | note |"
  echo "| C2 | A (B3) | B (B4) | resolved | open |"; } > "$d/CONTRADICTIONS.md"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'contradictions  : 1 open' <<<"$rep" && ok "status-cell open counts, note-cell open does not (mixed)" || no "mixed column-scope ($(grep -i contradic <<<"$rep"))"

# 22 — multiple ledger files → counted across ALL (never silently dropped) + a WARN to stderr
d="$TMP/multi"; mkstate "$d" 1 "high|g1|pending"; mkledger "$d"        # CONTRADICTIONS.md: 2 open
{ echo "# T"; echo; echo "| id | claim A | claim B | status | note |"; echo "|---|---|---|---|---|"
  echo "| Z1 | P (B7) | Q (B8) | open | archived-open |"; } > "$d/CONTRADICTIONS-archive.md"   # +1 open
rep="$(bash "$SUT" "$d" 2>/dev/null)"; warn="$(bash "$SUT" "$d" 2>&1 >/dev/null)"
if grep -q 'contradictions  : 3 open' <<<"$rep" && grep -qi 'multiple CONTRADICTIONS' <<<"$warn"; then ok "multiple ledgers counted across all + WARN"
else no "multi-ledger ($(grep -i contradic <<<"$rep") | warn=$(grep -i CONTRADICTIONS <<<"$warn"))"; fi

# 23 — header/separator-only ledger (no data rows) → (none), never a spurious count, exit unchanged
d="$TMP/headeronly"; mkstate "$d" 1 "high|g1|pending"
{ echo "# T"; echo; echo "| id | claim A | claim B | status | note |"; echo "|---|---|---|---|---|"; } > "$d/CONTRADICTIONS.md"
rep="$(bash "$SUT" "$d" 2>/dev/null)"; bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
if grep -q 'contradictions  : (none)' <<<"$rep" && [ "$rc" = 0 ]; then ok "header-only ledger → (none), exit 0"
else no "header-only ($(grep -i contradic <<<"$rep"), rc=$rc)"; fi

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
grep -q 'saturation      : SATURATED (review) — last 3 iterations netted 0 new gaps' <<<"$rep" && ok "saturation: 0 over last 3 numeric iterations → SATURATED (review)" || no "saturation: SATURATED not surfaced ($(grep -i saturation <<<"$rep"))"

# 25 — last 3 sum > 0 (2,0,1 → 3) → active, NOT saturated
d="$TMP/active"; mkiter "$d" 1 "1|2" "2|0" "3|1"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : active (3 new gaps in last 3 iter)' <<<"$rep" && ok "saturation: nonzero sum over last 3 → active" || no "saturation: active line ($(grep -i saturation <<<"$rep"))"

# 25b — WINDOW is the last 3 ONLY: an older iteration with new gaps does NOT rescue a saturated tail
d="$TMP/window"; mkiter "$d" 1 "1|9" "2|0" "3|0" "4|0"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : SATURATED (review)' <<<"$rep" && ok "saturation: only the last 3 iterations count (older gaps excluded)" || no "saturation: window not last-3 ($(grep -i saturation <<<"$rep"))"

# 26 — fewer than 3 numeric rows → insufficient history, NOT flagged
d="$TMP/insuff"; mkiter "$d" 1 "1|2" "2|1"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : insufficient history (2 iterations)' <<<"$rep" && ok "saturation: <3 numeric rows → insufficient history" || no "saturation: insufficient line ($(grep -i saturation <<<"$rep"))"

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
grep -q 'saturation      : insufficient history (2 iterations)' <<<"$rep" && ok "saturation: <n> placeholder row not counted as a numeric iteration" || no "saturation: placeholder counted ($(grep -i saturation <<<"$rep"))"

# 27 — rows OUT OF # ORDER are sorted numerically before the last-3 window is taken
d="$TMP/order"; mkiter "$d" 1 "4|9" "1|0" "2|0" "3|0"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : active (9 new gaps in last 3 iter)' <<<"$rep" && ok "saturation: rows sorted by # before taking the last 3" || no "saturation: not sorted by # ($(grep -i saturation <<<"$rep"))"

# 28 — no ## Iteration history section → (no iteration history), no error, exit unchanged (mkstate emits none)
d="$TMP/nohist"; mkstate "$d" 1 "high|g1|pending"
rep="$(bash "$SUT" "$d" 2>/dev/null)"; bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
if grep -q 'saturation      : (no iteration history)' <<<"$rep" && [ "$rc" = 0 ]; then ok "saturation: no history section → (no iteration history), exit 0"
else no "saturation: no-history line/exit ($(grep -i saturation <<<"$rep"), rc=$rc)"; fi

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
if [ "$before" = "$after" ] && ! grep -qi saturation <<<"$after"; then ok "--next contract unchanged by an iteration-history table"
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
grep -qE 'covered blocks  : .*· 2 on disk' <<<"$rep" && ok "on-disk block count excludes block.template.md (2, not 3)" || no "on-disk count ($(grep -i 'covered blocks' <<<"$rep"))"

# 33 — bare `pending` cell is still selected by --next (leading-token regression guard)
d="$TMP/bare-pending"; mkstate "$d" 1 "high|bare gap|pending"
expect_next "$d" "NEXT | high | bare gap" "bare 'pending' status is selected"

# 34 — a DECORATED `pending (uncovered by B7)` cell IS selected (leading-token tolerance). RED before
#      the fix: `[ "$st" = "pending" ]` is EXACT, so the decorated cell fails the match and the gap is
#      silently skipped → a false STOP/NONE. First whitespace token is `pending` → must be treated pending.
d="$TMP/decorated-pending"; mkstate "$d" 1 "high|decorated gap|pending (uncovered by B7)"
expect_next "$d" "NEXT | high | decorated gap" "decorated 'pending (uncovered by B7)' is selected"

# 35 — a `blocked (pending review)` cell must NOT be treated as pending (first token is `blocked`, not
#      `pending`) — the `pending` word appears only elsewhere in the cell. The real medium pending wins.
d="$TMP/pending-elsewhere"; mkstate "$d" 1 "high|not-a-gap|blocked (pending review)" "medium|real gap|pending"
expect_next "$d" "NEXT | medium | real gap" "'blocked (pending review)' not treated as pending"

# 36 — different-vocabulary statuses (`partial`, `covered`) must NOT match; only the low `pending` wins.
d="$TMP/other-vocab"; mkstate "$d" 1 "high|partial gap|partial" "medium|covered gap|covered" "low|real gap|pending"
expect_next "$d" "NEXT | low | real gap" "'partial'/'covered' statuses are not treated as pending"

# ==================== research-state.v1 ENVELOPE GATE + --sync-state SEEDER ====================

# 37 — CORE REGRESSION (premature-STOP class): the envelope UNDER-declares investigable_open (0) while the
#      backlog still lists 2 pending non-blocked gaps. verify-state FAILs on the mismatch → --next MUST
#      return STALE (reconcile first), never a premature STOP nor a blind NEXT on stale ints.
d="$TMP/env-understated"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 5 5 0 0 0; echo; echo "## Gap-backlog"; echo
  echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | first open gap | web | pending |"; echo "| medium | second open gap | web | pending |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d/RESEARCH-STATE.md"
got="$(next "$d")"; case "$got" in STALE\ *) ok "envelope investigable_open=0 vs 2 pending → --next STALE (not STOP)";; *) no "core regression — got [$got] want STALE";; esac

# 38 — --sync-state SEEDS a contract-valid envelope into a corpus that has none, and is IDEMPOTENT (a
#      second run is byte-identical — gentle-ai's content-compare no-op re-render). Blocked gap excluded.
d="$TMP/sync"; mkdir -p "$d"
{ echo "# T — Research State"; echo; echo "> intro blockquote"; echo
  echo "## Coverage"; echo "- **Coverage metric**: 4 / 9 closed"; echo
  echo "## Gap-backlog"; echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | open one | web | pending |"; echo "| medium | blocked one | web | pending |"; echo
  echo "## Blocked gaps"; echo "- blocked one — needs: hardware"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; echo "- **Open gaps — requires-execution**: 2"; } > "$d/RESEARCH-STATE.md"
bash "$SUT" "$d" --sync-state >/dev/null 2>&1
if bash "$HERE/../verify-state.sh" "$d" >/dev/null 2>&1; then ok "--sync-state seeds a contract-valid envelope (verify-state passes)"
else no "--sync-state: verify-state still fails after seeding"; fi
env_io="$(grep '^investigable_open:' "$d/RESEARCH-STATE.md" | awk '{print $2}')"
[ "$env_io" = "1" ] && ok "--sync-state derives investigable_open=1 (blocked gap excluded)" || no "sync io=$env_io want 1"
env_re="$(grep '^requires_execution_open:' "$d/RESEARCH-STATE.md" | awk '{print $2}')"
[ "$env_re" = "2" ] && ok "--sync-state reads requires_execution_open=2 from prose" || no "sync req=$env_re want 2"
cp "$d/RESEARCH-STATE.md" "$TMP/sync-snap"
bash "$SUT" "$d" --sync-state >/dev/null 2>&1
if diff -q "$TMP/sync-snap" "$d/RESEARCH-STATE.md" >/dev/null; then ok "--sync-state is idempotent (second run byte-identical)"
else no "--sync-state not idempotent"; fi
expect_next "$d" "NEXT | high | open one" "--next resolves after --sync-state seeding"

# 39 — --sync-state UPDATES an existing fence IN PLACE (replaces only between markers; prose untouched) and
#      RECONCILES a stale envelope. Seed a WRONG envelope, edit nothing else, re-sync → the ints are fixed.
d="$TMP/resync"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 9 9 9 9 9 9; echo; echo "## SENTINEL prose line kept verbatim"; echo
  echo "## Gap-backlog"; echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | the only gap | web | pending |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
bash "$SUT" "$d" --sync-state >/dev/null 2>&1
env_io="$(grep '^investigable_open:' "$d/RESEARCH-STATE.md" | awk '{print $2}')"
if [ "$env_io" = "1" ] && grep -q '## SENTINEL prose line kept verbatim' "$d/RESEARCH-STATE.md" \
   && [ "$(grep -c '<!-- research-state.v1 -->' "$d/RESEARCH-STATE.md")" = 1 ]; then
  ok "--sync-state reconciles a stale fence in place (io 9→1, single fence, prose kept)"
else no "resync: io=$env_io / fence-count=$(grep -c '<!-- research-state.v1 -->' "$d/RESEARCH-STATE.md")"; fi

# 40 — MULTI-FOCUS (§16): --sync-state seeds EVERY RESEARCH-STATE-*.md, deriving each focus's
#      investigable_open from ITS OWN backlog (not the head-1 file). Seeding only head-1 left siblings
#      envelope-less, and verify-state.sh (lints ALL) then FAILs → the corpus BRICKS under the --next
#      STALE-gate. Teeth: alpha has 2 pending, beta 0 — head-1-only seeding leaves beta unseeded (or, if it
#      copied alpha's numbers, beta.io=2), so pinning beta seeded WITH io=0 catches both regressions.
d="$TMP/multifocus"; mkdir -p "$d"
cat > "$d/RESEARCH-STATE-alpha.md" <<'EOF'
# Alpha — Research State
> intro
## Gap-backlog (prioritized)
| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | a1 | web | pending |
| high | a2 | web | pending |
## Blocked gaps
## Stop control
- **Open gaps — read-only investigable**: 2
EOF
cat > "$d/RESEARCH-STATE-beta.md" <<'EOF'
# Beta — Research State
> intro
## Gap-backlog (prioritized)
| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | b1 | doc | done |
## Blocked gaps
## Stop control
- **Open gaps — read-only investigable**: 0
EOF
bash "$SUT" "$d" --sync-state >/dev/null 2>&1
_envf() { awk -v k="$2" '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && $1==k":"{print $2; exit}' "$1"; }
a_seed=$(grep -c '<!-- research-state.v1 -->' "$d/RESEARCH-STATE-alpha.md")
b_seed=$(grep -c '<!-- research-state.v1 -->' "$d/RESEARCH-STATE-beta.md")
a_io=$(_envf "$d/RESEARCH-STATE-alpha.md" investigable_open); b_io=$(_envf "$d/RESEARCH-STATE-beta.md" investigable_open)
if [ "$a_seed" = 1 ] && [ "$b_seed" = 1 ] && [ "$a_io" = 2 ] && [ "$b_io" = 0 ] && bash "$HERE/../verify-state.sh" "$d" >/dev/null 2>&1; then
  ok "multi-focus: both foci seeded, per-focus investigable_open (alpha=2, beta=0), verify-state passes"
else no "multi-focus: a_seed=$a_seed b_seed=$b_seed a_io=$a_io(want 2) b_io=$b_io(want 0) verify=$(bash "$HERE/../verify-state.sh" "$d" >/dev/null 2>&1 && echo ok || echo FAIL)"; fi

# 41 — SYMLINKED state file: --sync-state must write THROUGH to the real target and PRESERVE the symlink
#      (a bare `mv $tmp $state` would replace the symlink inode with a regular file, breaking a shared/
#      canonical state). Also pins the same-directory atomic-write path (temp lives beside the real file).
d="$TMP/symlink"; mkdir -p "$d/real"
cat > "$d/real/state.md" <<'EOF'
# T
> intro
## Gap-backlog (prioritized)
| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | g1 | web | pending |
## Blocked gaps
## Stop control
- **Open gaps — read-only investigable**: 1
EOF
ln -s real/state.md "$d/RESEARCH-STATE.md"
bash "$SUT" "$d" --sync-state >/dev/null 2>&1
if [ -L "$d/RESEARCH-STATE.md" ] && grep -q '<!-- research-state.v1 -->' "$d/real/state.md"; then
  ok "symlinked state: --sync-state writes through to the real target, symlink preserved"
else no "symlink: still-link=$([ -L "$d/RESEARCH-STATE.md" ] && echo yes || echo NO) seeded-real=$(grep -qc '<!-- research-state.v1 -->' "$d/real/state.md" 2>/dev/null && echo yes || echo no)"; fi

# 42 — MULTI-FOCUS with a focus in a SUBDIRECTORY: covered_blocks must be derived PER STATE FILE's own dir
#      (like verify-state.sh:101), NOT once at the corpus root. A shared root-cb would be seeded into the
#      subdir focus's envelope and verify-state (per-dir ondisk) would FAIL the envelope --sync-state just
#      wrote. Teeth: root has 2 blocks, the subdir focus has 1 — a shared cb would wrongly seed 2 into both.
d="$TMP/subdir-cb"; mkdir -p "$d/legacy"
printf '# root\n> x\n## Gap-backlog\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n' > "$d/RESEARCH-STATE.md"
printf 'x\n' > "$d/proj-block1.md"; printf 'x\n' > "$d/proj-block2.md"
printf '# legacy\n> x\n## Gap-backlog\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n' > "$d/legacy/RESEARCH-STATE-legacy.md"
printf 'x\n' > "$d/legacy/legacy-block1.md"   # §16: block prefix mirrors state suffix (legacy- from RESEARCH-STATE-legacy.md)
bash "$SUT" "$d" --sync-state >/dev/null 2>&1
root_cb=$(_envf "$d/RESEARCH-STATE.md" covered_blocks); leg_cb=$(_envf "$d/legacy/RESEARCH-STATE-legacy.md" covered_blocks)
if [ "$root_cb" = 2 ] && [ "$leg_cb" = 1 ] && bash "$HERE/../verify-state.sh" "$d" >/dev/null 2>&1; then
  ok "per-dir covered_blocks (root=2, subdir focus=1), verify-state agrees"
else no "subdir-cb: root_cb=$root_cb(want 2) leg_cb=$leg_cb(want 1) verify=$(bash "$HERE/../verify-state.sh" "$d" >/dev/null 2>&1 && echo ok || echo FAIL)"; fi

# 43 — STOP BY CONSTRUCTION: resolve_next must ignore the hand-authored `## Stop control` prose. An empty
#      eligible backlog ⇒ derived investigable = 0 ⇒ STOP, even when the prose still claims a non-zero count
#      (which --sync-state never rewrites and verify-state never gates). Teeth: the prose says 5; before the
#      fix resolve_next read inv_count() → wrong `NONE`. Envelope investigable_open=0 matches the empty backlog
#      so the --next STALE-gate passes and we reach resolve_next.
d="$TMP/stop-construct"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 0 0 0; echo; echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | done gap | web | covered |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 5"; } > "$d/RESEARCH-STATE.md"
expect_next "$d" "STOP | read-only-investigable exhausted (0)" "empty eligible backlog → STOP (ignores stale prose count of 5)"

# 44 — BACKLOG-ANCHORED requires_execution_open (the three.js shape): --sync-state must PREFER the count
#      derived from backlog rows whose Status column carries `requires-execution` over a STALE prose
#      stop-control number (0 here) — the marked backlog is authoritative, the envelope lands at 1, and
#      verify-state's CHECK E (the deliberate mirror) certifies the envelope --sync-state just wrote.
d="$TMP/sync-req-backlog"; mkdir -p "$d"
{ echo "# T — Research State"; echo; echo "> intro"; echo
  echo "## Coverage"; echo "- **Coverage metric**: 40 / 40 closed"; echo
  echo "## Gap-backlog (prioritized)"; echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | G41 — equipment LOD | prototype build | requires-execution → §19 (not read-only; needs a build + re-measure) |"; echo
  echo "## Blocked gaps"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"
  echo "- **Open gaps — requires-execution**: 0"; } > "$d/RESEARCH-STATE.md"
bash "$SUT" "$d" --sync-state >/dev/null 2>&1
env_re="$(grep '^requires_execution_open:' "$d/RESEARCH-STATE.md" | awk '{print $2}')"
[ "$env_re" = "1" ] && ok "--sync-state anchors requires_execution_open=1 from the marked backlog row (stale prose 0 overridden)" \
  || no "sync-req-backlog: req=$env_re want 1"
if bash "$HERE/../verify-state.sh" "$d" >/dev/null 2>&1; then ok "backlog-anchored envelope passes verify-state (derivations in lockstep)"
else no "sync-req-backlog: verify-state FAILs the envelope --sync-state just wrote (mirror drift)"; fi

# 45 — PROSE-TRACKED corpus with paren noise (the REAL logosoft stop-control line): no marked backlog rows,
#      and the prose reads `— requires-execution (…, METHODOLOGY §8)**: **0 — AGOTADO.**`. The old bare
#      first-integer grep grabbed the 8 out of `§8` (that stale 8 was LIVE in logosoft's envelope); the
#      token-anchored + paren-stripped parse must read the declared 0.
d="$TMP/sync-req-prose"; mkdir -p "$d"
{ echo "# T"; echo; echo "> intro"; echo
  echo "## Gap-backlog (prioritized)"; echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | done build gap | poc | ✅ cubierto — B75 |"; echo
  echo "## Blocked gaps"; echo
  echo "## Stop control"
  echo "- **Gaps abiertos — requires-execution (NO read-only; fase build/PoC, METHODOLOGY §8)**: **0 — AGOTADO.** (Era 4 → B72 cerró el round-trip)"; } > "$d/RESEARCH-STATE.md"
bash "$SUT" "$d" --sync-state >/dev/null 2>&1
env_re="$(grep '^requires_execution_open:' "$d/RESEARCH-STATE.md" | awk '{print $2}')"
[ "$env_re" = "0" ] && ok "--sync-state reads prose 0 through the paren noise (never the 8 from '§8')" \
  || no "sync-req-prose: req=$env_re want 0 (the §8-grab bug)"

# =============================== B5 — MULTI-FOCUS COVERED_BLOCKS IN --sync-state ===============================
# B5 root cause: research-sdd-status.sh find in --sync-state used no focus-prefix filter → all blocks in the
# corpus dir were counted for every focus, so each focus's covered_blocks was the TOTAL across all focuses.
# Fix: derive_focus_prefix() + per-prefix count means each RESEARCH-STATE-<focus>.md counts only its own blocks.

# _envf is defined in test 40 but as a local awk function. Redefine it here for B5.
envf_b5() { awk -v k="$2" '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && $1==k":"{print $2; exit}' "$1"; }

# B5-MF1 — same-directory multi-focus: alpha has 2 blocks, beta has 3 blocks.
# --sync-state must seed covered_blocks=2 for alpha and covered_blocks=3 for beta (NOT the combined 5).
d="$TMP/b5-multifocus"; mkdir -p "$d"
printf 'x\n' > "$d/alpha-block1.md"; printf 'x\n' > "$d/alpha-block2.md"
printf 'x\n' > "$d/beta-block1.md";  printf 'x\n' > "$d/beta-block2.md"; printf 'x\n' > "$d/beta-block3.md"
printf '# Alpha\n> intro\n## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n' > "$d/RESEARCH-STATE-alpha.md"
printf '# Beta\n> intro\n## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n' > "$d/RESEARCH-STATE-beta.md"
bash "$SUT" "$d" --sync-state >/dev/null 2>&1
a_cb="$(envf_b5 "$d/RESEARCH-STATE-alpha.md" covered_blocks)"
b_cb="$(envf_b5 "$d/RESEARCH-STATE-beta.md" covered_blocks)"
if [ "$a_cb" = 2 ] && [ "$b_cb" = 3 ]; then
  ok "B5-MF1: --sync-state seeds per-focus covered_blocks (alpha=2, beta=3; NOT combined 5)"
else
  no "B5-MF1: a_cb=$a_cb(want 2) b_cb=$b_cb(want 3) — focus-blind would seed both=5"
fi
if bash "$HERE/../verify-state.sh" "$d" >/dev/null 2>&1; then
  ok "B5-MF1: verify-state passes the per-focus envelopes --sync-state just wrote"
else
  no "B5-MF1: verify-state FAILs the envelope --sync-state just wrote (ondisk mismatch if cb wrong)"
fi

# B5-DEFAULT-STATUS — the DEFAULT status report's "on disk" count must be per-focus.
# After --sync-state (which also tests B5 --sync-state path), run the default report.
# The default report picks the lexicographically-first state file (alpha < beta); only
# alpha's 2 blocks should be counted. Without the fix, ondisk would be 5 (all blocks).
rep_a="$(bash "$SUT" "$d" 2>/dev/null)"
if grep -qE 'covered blocks.*·.*2 on disk' <<<"$rep_a"; then
  ok "B5-DEFAULT: default status shows alpha's 2 on-disk blocks (not combined 5)"
else
  no "B5-DEFAULT: covered blocks line: $(grep -E 'covered blocks' <<<"$rep_a")"
fi

# ==================== MULTI-FOCUS FALSE-STOP (chihuahua/px-chart-classic regression) ====================

# 46 — MULTI-FOCUS FALSE-STOP: a STOPPED focus that sorts alphabetically before an ACTIVE focus must NOT
#      cause --next to return STOP while the active focus still has open gaps. Focus "apple" (stopped)
#      sorts before "mango" (active, 1 pending gap). RED before the fix: state=head-1(apple) → STOP.
#      After fix: scan all focuses, mango has NEXT → return NEXT. This is the exact shape of the real
#      failure (chihuahua stopped, sorted first; px-chart-classic had 8 pending gaps → false STOP).
d="$TMP/mf-false-stop"; mkdir -p "$d"
{ printf '# Apple — Research State\n> intro\n'
  env_lines 0 0 0 0 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n'
  printf '| high | done gap | web | covered |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '- **Open gaps — read-only investigable**: 0\n'
} > "$d/RESEARCH-STATE-apple.md"
{ printf '# Mango — Research State\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n'
  printf '| high | open mango gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '- **Open gaps — read-only investigable**: 1\n'
} > "$d/RESEARCH-STATE-mango.md"
expect_next "$d" "NEXT | high | open mango gap" "multi-focus: STOPPED apple does not mask NEXT in mango (false-STOP regression)"

# 46a — --focus apple returns STOP (selects only the stopped focus)
got="$(bash "$SUT" "$d" --next --focus apple 2>/dev/null)"
[ "$got" = "STOP | read-only-investigable exhausted (0)" ] && ok "--focus apple: returns STOP for the stopped focus" || no "--focus apple: got [$got] want STOP"

# 46b — --focus mango returns NEXT (selects only the active focus)
got="$(bash "$SUT" "$d" --next --focus mango 2>/dev/null)"
[ "$got" = "NEXT | high | open mango gap" ] && ok "--focus mango: returns NEXT for the active focus" || no "--focus mango: got [$got] want NEXT"

# 46c — SINGLE-FOCUS corpus: behavior unchanged after the multi-focus fix (regression guard).
#       The only state file is RESEARCH-STATE.md — no multi-focus loop overhead, same output.
d="$TMP/mf-single"; mkstate "$d" 1 "high|single focus gap|pending"
expect_next "$d" "NEXT | high | single focus gap" "single-focus: --next unchanged after multi-focus fix"

# ==================== BLOCKER 1B — --sync-state undocumented_findings carry-forward ====================

# 47 — --sync-state absent-uf POSITIVE CONTROL: no undocumented_findings in the envelope → seeds 0
#      silently (METHODOLOGY §7 seeding contract). No stderr warning must be emitted for an absent field.
d="$TMP/sync-uf-absent"; mkdir -p "$d"
{ echo '# T'; echo '> intro'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
warn47="$(bash "$SUT" "$d" --sync-state 2>&1 >/dev/null)"
uf47="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^undocumented_findings:/{print $2; exit}' "$d/RESEARCH-STATE.md")"
if [ "$uf47" = "0" ] && ! grep -qiE 'warn.*undocumented|undocumented.*warn' <<<"$warn47"; then
  ok "sync-uf-absent: absent undocumented_findings → seeds 0 silently (seeding contract preserved, no stderr)"
else no "sync-uf-absent: uf=$uf47 (want 0) · warn='$(echo "$warn47" | grep -iE 'undocumented' | head -1)'"; fi

# 48 — --sync-state with UNPARSEABLE undocumented_findings: a non-integer value ('seven') must emit a
#      loud warning AND must NOT silently replace the value with 0. This is the noisy-beats-silent fix:
#      pick("", "seven") currently returns 0 (second arg fails is_int → falls through to 0). The three
#      cases that pick() collapses into one must be loud vs. silent: absent→seed 0 (case 47), valid→carry
#      (pass), UNPARSEABLE→warn and carry raw (this case). Assert on the resulting file content.
d="$TMP/sync-uf-bad"; mkdir -p "$d"
{ echo '# T'; echo '> intro'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: seven\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
warn48="$(bash "$SUT" "$d" --sync-state 2>&1 >/dev/null)"
uf48="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^undocumented_findings:/{print $2; exit}' "$d/RESEARCH-STATE.md")"
if grep -qiE 'undocumented_findings' <<<"$warn48" && [ "$uf48" != "0" ]; then
  ok "sync-uf-bad: unparseable 'seven' → loud stderr warning AND value not silently zeroed (noisy-beats-silent)"
else no "sync-uf-bad: uf48='$uf48' (want !0) · warn='$(echo "$warn48" | grep -iE 'undocumented' | head -1)' (want non-empty)"; fi

# 48b — NO-SPACE valid integer: undocumented_findings:7 (colon immediately followed by digit, no space).
#       env_get's awk uses $1==key":" which makes $1="undocumented_findings:7" — no match — so env_get
#       returns "". Without a prefix-probe fallback, the case ''→uf=0 branch fires silently, erasing the
#       real debt of 7. After the fix: prefix probe detects the line, extracts "7", integer branch →
#       carry 7, no zeroing, no warning (value is valid — just malformed format).
#       Assertion: value after --sync-state must be 7 (not 0).
d="$TMP/sync-uf-nospace-int"; mkdir -p "$d"
{ echo '# T'; echo '> intro'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings:7\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
bash "$SUT" "$d" --sync-state 2>/dev/null
uf48b="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^undocumented_findings:/{print $2; exit}' "$d/RESEARCH-STATE.md")"
if [ "$uf48b" = "7" ]; then
  ok "sync-uf-nospace-int: undocumented_findings:7 (no space) → --sync-state preserves 7, does not zero (no-space prefix probe fires)"
else no "sync-uf-nospace-int: uf=$uf48b (want 7) — no-space valid-integer was silently zeroed (BLOCKER 1B nospace regression)"; fi

# 48c — NO-SPACE non-integer: undocumented_findings:seven (no space + word value).
#       Same blind spot as 48b but the extracted value is non-integer. After the fix: prefix probe
#       detects the line, extracts "seven", non-integer branch → WARN on stderr AND carry forward
#       (NOT 0). Before the fix: env_get returns "" → absent → seeds 0 silently.
#       Assertions: (a) stderr contains 'undocumented_findings', (b) value in file is NOT 0.
d="$TMP/sync-uf-nospace-nonint"; mkdir -p "$d"
{ echo '# T'; echo '> intro'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings:seven\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
warn48c="$(bash "$SUT" "$d" --sync-state 2>&1 >/dev/null)"
uf48c="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^undocumented_findings:/{print $2; exit}' "$d/RESEARCH-STATE.md")"
if grep -qiE 'undocumented_findings' <<<"$warn48c" && [ "$uf48c" != "0" ]; then
  ok "sync-uf-nospace-nonint: undocumented_findings:seven (no space) → warn on stderr AND value not zeroed"
else no "sync-uf-nospace-nonint: uf=$uf48c (want !0) · warn='$(echo "$warn48c" | grep -iE 'undocumented' | head -1)' (want non-empty)"; fi

# 48d — END-TO-END: after verify-state FAILs on a malformed no-space value, running --sync-state
#       must NOT change the value to 0. This pins the invariant that the FAIL message's advice
#       ("fix manually then re-seed") is safe to follow: running --sync-state on an unfixed file
#       must not destroy debt. Uses the no-space non-integer shape (most dangerous: non-int PLUS
#       no-space → both blind spots at once, previously resulted in silent zero).
#       Assert: verify-state exit=1, then after --sync-state value is still not 0.
d="$TMP/sync-uf-e2e"; mkdir -p "$d"
{ echo '# T'; echo '> intro'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings:seven\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
bash "$HERE/../verify-state.sh" "$d" >/dev/null 2>&1; vs_exit=$?
bash "$SUT" "$d" --sync-state 2>/dev/null
uf48d="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^undocumented_findings:/{print $2; exit}' "$d/RESEARCH-STATE.md")"
if [ "$vs_exit" = "1" ] && [ "$uf48d" != "0" ]; then
  ok "sync-uf-e2e: verify-state FAILs (exit=1) then --sync-state does NOT zero the no-space non-int value (invariant: FAIL+sync=safe)"
else no "sync-uf-e2e: vs_exit=$vs_exit uf=$uf48d (want vs_exit=1 and uf!=0) — sync after verify-fail zeroed the value (doc/code trap)"; fi

# ==================== BLOCKER 2 — SPLIT-LAYOUT: focuses in sibling subdirectories ====================

# 49 — SPLIT-LAYOUT: one focus per SIBLING SUBDIRECTORY; the stopped alpha sorts alphabetically before
#      the active beta. --next on the target MUST NOT return STOP while beta has open gaps.
#      This is the identical C3 false-STOP as test 46, one level up: corpus=dirname(first)=$d/alpha,
#      and the old aggregation only scanned $corpus, missing $d/beta entirely.
d="$TMP/split-layout"; mkdir -p "$d/alpha" "$d/beta"
{ printf '# Alpha — Research State\n> intro\n'
  env_lines 0 0 0 0 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n'
  printf '| high | done gap | web | covered |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '- **Open gaps — read-only investigable**: 0\n'
} > "$d/alpha/RESEARCH-STATE.md"
{ printf '# Beta — Research State\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n'
  printf '| high | open beta gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '- **Open gaps — read-only investigable**: 1\n'
} > "$d/beta/RESEARCH-STATE.md"
got49="$(bash "$SUT" "$d" --next 2>/dev/null)"
case "$got49" in
  NEXT\ *) ok "split-layout --next: stopped alpha does not mask NEXT in sibling beta (BLOCKER 2 fix)";;
  STOP\ *) no "split-layout --next: false STOP (BLOCKER 2 regression) — expected NEXT from beta";;
  *)       no "split-layout --next: got [$got49] — expected NEXT from beta";;
esac

# 50 — same split-layout: DEFAULT REPORT next step must not claim STOP (WARNING 3).
#      The supervisor reads the default report; a false STOP there is the same misinformation C3 kills.
rep50="$(bash "$SUT" "$d" 2>/dev/null)"
if ! grep -qE 'next step[[:space:]]*:.*STOP' <<<"$rep50"; then
  ok "split-layout default report: next step does not say STOP while beta has open gaps (WARNING 3 fix)"
else
  no "split-layout default-report: next step says STOP — got: $(grep 'next step' <<<"$rep50" | head -1)"
fi

# 51 — split-layout --sync-state seeds BOTH sibling focuses (alpha AND beta), not just alpha.
#      Uses a FRESH fixture WITHOUT envelopes so that the seeded count reflects --sync-state's work.
#      Before the fix, --sync-state used find on $corpus=dirname(first)=$d/alpha, seeding only alpha;
#      beta would remain unseedeed (grep-c returns 0) → the test fails → proves the scope fix is needed.
d51="$TMP/split-seed"; mkdir -p "$d51/alpha" "$d51/beta"
{ printf '# Alpha — Research State\n> intro\n'
  printf '## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n'
  printf '| high | done gap | web | covered |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '- **Open gaps — read-only investigable**: 0\n'
} > "$d51/alpha/RESEARCH-STATE.md"
{ printf '# Beta — Research State\n> intro\n'
  printf '## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n'
  printf '| high | open beta gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '- **Open gaps — read-only investigable**: 1\n'
} > "$d51/beta/RESEARCH-STATE.md"
bash "$SUT" "$d51" --sync-state >/dev/null 2>&1
_a_seeded=$(grep -c '<!-- research-state.v1 -->' "$d51/alpha/RESEARCH-STATE.md")
_b_seeded=$(grep -c '<!-- research-state.v1 -->' "$d51/beta/RESEARCH-STATE.md")
if [ "$_a_seeded" = 1 ] && [ "$_b_seeded" = 1 ]; then
  ok "split-layout --sync-state: seeds BOTH sibling focuses (alpha and beta, not just alpha)"
else
  no "split-layout --sync-state: alpha_seeded=$_a_seeded(want 1) beta_seeded=$_b_seeded(want 1)"
fi

# NEGATIVE CONTROL — reverse the priority order; the "high beats low" fixture must then pick LOW.
if [ "${1:-}" = "--prove-teeth" ]; then
  # The mutant status scripts resolve $here to $TMP, so they need verify-state.sh at $TMP/verify-state.sh.
  # verify-state.sh sources lib/focus-prefix.sh; status.sh also sources lib/state-files.sh after the fix.
  mkdir -p "$TMP/lib"
  cp "$HERE/../lib/focus-prefix.sh" "$TMP/lib/focus-prefix.sh"
  cp "$HERE/../lib/state-files.sh" "$TMP/lib/state-files.sh"

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
  if grep -q 'saturation      : SATURATED' <<<"$srep"; then ok "teeth: widened-threshold mutant over-flags an active window → saturation test has teeth"
  else no "teeth: sat mutant did not over-flag [$(grep -i saturation <<<"$srep")] — threshold not exercised (THEATER)"; fi

  # multi-focus teeth: break the loop after the FIRST state only (apple, which is stopped) — the
  # fixture must then return STOP instead of NEXT, proving the multi-state scan is the fix.
  # sed mutation: add '; break' after _r="$(resolve_next)" so only apple is ever checked.
  echo "-- teeth: break-after-first mutant returns STOP on mf-false-stop fixture; multi-focus scan has real teeth --"
  mf_mutant="$TMP/status.MF-MUTANT.sh"
  sed 's/_r="\$(resolve_next)"/_r="$(resolve_next)"; break/' "$SUT" > "$mf_mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  mgot_mf="$(bash "$mf_mutant" "$TMP/mf-false-stop" --next 2>/dev/null)"
  if [ "$mgot_mf" = "STOP | read-only-investigable exhausted (0)" ]; then
    ok "mf-teeth: break-after-first mutant returns STOP on false-stop fixture → multi-focus scan has teeth"
  else
    no "mf-teeth: mutant returned [$mgot_mf] — scan not exercised (THEATER)"
  fi

  # BLOCKER 2 teeth: reuse break-after-first mutant on the SPLIT-LAYOUT fixture ($TMP/split-layout).
  # In the split-layout, corpus=dirname(first)=$TMP/split-layout/alpha. The break-after-first mutant
  # checks only alpha (stopped) and returns STOP, proving the scope fix (target vs. corpus) is needed.
  echo "-- teeth: split-layout — break-after-first mutant on split fixture; must return STOP (proves scope fix) --"
  mgot_sl="$(bash "$mf_mutant" "$TMP/split-layout" --next 2>/dev/null)"
  if [ "$mgot_sl" = "STOP | read-only-investigable exhausted (0)" ]; then
    ok "sl-teeth: break-after-first mutant returns STOP on split-layout → BLOCKER 2 scan scope fix has teeth"
  else
    no "sl-teeth: mutant returned [$mgot_sl] (want STOP) — split-layout scan scope not exercised (THEATER)"
  fi

  # BLOCKER 1B / nospace teeth: neuter the prefix probe's if-guard so the absent branch always runs for
  # the no-space shape, producing silent uf=0 — the exact pre-fix regression. Proves test 48b is load-bearing.
  echo "-- teeth: sync-uf-nospace — neuter prefix probe if-guard; no-space int fixture must silently zero --"
  ns_mutant="$TMP/status.NS-MUTANT.sh"
  # Mutation: replace `if [ -z "$_raw_uf" ]; then` with `if false; then` so the prefix probe never runs.
  # The no-space case then takes the absent branch ('' → uf=0) silently.
  sed 's/if \[ -z "\$_raw_uf" \]; then/if false; then  # MUTANT-NS: no-space probe neutered/' "$SUT" > "$ns_mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  if ! grep -q 'MUTANT-NS: no-space probe neutered' "$ns_mutant"; then
    no "teeth(NS): could not build mutant (if [ -z \$_raw_uf ] guard not found — did the SUT change?)"
  else
    d_ns="$TMP/sync-uf-nospace-teeth"; mkdir -p "$d_ns"
    { echo '# T'; echo '> intro'; echo
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings:7\n<!-- /research-state.v1 -->\n'; echo
      echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
      echo '## Blocked gaps'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'; } > "$d_ns/RESEARCH-STATE.md"
    bash "$ns_mutant" "$d_ns" --sync-state 2>/dev/null
    uf_ns="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^undocumented_findings:/{print $2; exit}' "$d_ns/RESEARCH-STATE.md")"
    if [ "$uf_ns" = "0" ]; then
      ok "teeth(NS): neutered prefix probe silently zeros no-space int 7 → test 48b assertion is load-bearing"
    else no "teeth(NS): mutant uf=$uf_ns (want 0) — probe guard is not the only defense (mutation did not restore the bug)"; fi
  fi

  # BLOCKER 1B teeth: make the always-absent mutant (seed 0 no matter what) → test 48 warning and
  # file assertions both fail. This proves the new three-branch uf logic is load-bearing, not theater.
  echo "-- teeth: sync-uf — always-absent mutant silently zeros unparseable uf; test 48 must detect it --"
  ufb_mutant="$TMP/status.UFB-MUTANT.sh"
  # Mutation: replace `case "$_raw_uf" in` with `case "" in` so the empty (absent) branch always runs,
  # silently setting uf=0 for ALL values — the old pick("","seven")=0 silent-loss behavior.
  sed 's/case "\$_raw_uf" in/case "" in  # MUTANT-UFB: always-absent/' "$SUT" > "$ufb_mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  if ! grep -q 'MUTANT-UFB: always-absent' "$ufb_mutant"; then
    no "teeth(UFB): could not build mutant (if [ -z _raw_uf ] guard not found — did the SUT change?)"
  else
    warn_ufb="$(bash "$ufb_mutant" "$TMP/sync-uf-bad" --sync-state 2>&1 >/dev/null)"
    uf_ufb="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^undocumented_findings:/{print $2; exit}' "$TMP/sync-uf-bad/RESEARCH-STATE.md")"
    # Re-seed the fixture to the known-bad state before running the mutant
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: seven\n<!-- /research-state.v1 -->\n' >> "$TMP/sync-uf-bad2/RESEARCH-STATE.md" 2>/dev/null || true
    # Simpler: re-create the fixture in a fresh dir
    d_ufb="$TMP/sync-uf-bad-teeth"; mkdir -p "$d_ufb"
    { echo '# T'; echo '> intro'; echo
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: seven\n<!-- /research-state.v1 -->\n'; echo
      echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
      echo '## Blocked gaps'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'; } > "$d_ufb/RESEARCH-STATE.md"
    warn_ufb="$(bash "$ufb_mutant" "$d_ufb" --sync-state 2>&1 >/dev/null)"
    uf_ufb="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^undocumented_findings:/{print $2; exit}' "$d_ufb/RESEARCH-STATE.md")"
    if ! grep -qiE 'undocumented_findings' <<<"$warn_ufb" && [ "$uf_ufb" = "0" ]; then
      ok "teeth(UFB): always-absent mutant silently zeros 'seven' (no warn, uf=0) → test 48 assertions are load-bearing"
    else no "teeth(UFB): mutant warn='$(echo "$warn_ufb" | grep -iE 'undocumented' | head -1)' uf=$uf_ufb (want no-warn and 0)"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
