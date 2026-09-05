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

# mkiter_h <dir> <header-row> <data-row>... — iteration-history table with an ARBITRARY header line and
# RAW data rows (caller writes full `| … |` rows). Lets a case exercise header-name column selection,
# non-last New-gaps columns, and leading-integer / none / gap-id cell forms (#420).
mkiter_h() {
  local dir="$1" hdr="$2"; shift 2; mkdir -p "$dir"
  local ncol sep i; ncol=$(awk -F'|' '{print NF-2}' <<<"$hdr"); sep="|"
  for ((i=0;i<ncol;i++)); do sep="$sep---|"; done
  { echo "# T"; echo; echo "## Gap-backlog"; echo
    echo "| P | G | t | S |"; echo "|-|-|-|-|"; echo "| high | g1 | web | pending |"; echo
    echo "## Iteration history"; echo
    echo "$hdr"; echo "$sep"
    for r in "$@"; do echo "$r"; done
    echo; echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"
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

# --- #420: saturation parser reads New-gaps BY HEADER NAME + lenient cell forms + 3-state honesty ---
# 29a — New-gaps chosen by header name even when it is NOT the last column (last col is prose)
d="$TMP/sat-byname"; mkiter_h "$d" "| # | New gaps | Result |" "| 1 | 0 | did |" "| 2 | 0 | did |" "| 3 | 0 | did |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : SATURATED (review) — last 3 iterations netted 0 new gaps' <<<"$rep" && ok "#420 saturation: New-gaps selected by header name, not position" || no "#420 by-name ($(grep -i saturation <<<"$rep"))"

# 29b — leading-integer cell forms (`2 new`, `+1`) are recognised as their integer
d="$TMP/sat-leadint"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 2 new |" "| 2 | 0 |" "| 3 | +1 |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : active (3 new gaps in last 3 iter)' <<<"$rep" && ok "#420 saturation: leading-integer cells (2 new / +1) parsed" || no "#420 leadint ($(grep -i saturation <<<"$rep"))"

# 29c — the `none…` family (incl. Spanish `ninguno`) counts as 0 → an all-none window is SATURATED
d="$TMP/sat-none"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | none net-new · yes · sonnet |" "| 2 | ninguno para este focus |" "| 3 | none |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : SATURATED (review) — last 3 iterations netted 0 new gaps' <<<"$rep" && ok "#420 saturation: none/ninguno family cells count as 0" || no "#420 none ($(grep -i saturation <<<"$rep"))"

# 29d — a table with NO New-gaps column is reported honestly, NOT as blind 'insufficient history (0)'
d="$TMP/sat-nocol"; mkiter_h "$d" "| Iter | Block | Gap | Result |" "| 1 | B1 | g | did |" "| 2 | B2 | g | did |" "| 3 | B3 | g | did |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : no New-gaps column (header:' <<<"$rep" && ok "#420 saturation: no New-gaps column reported (not blind 'insufficient history')" || no "#420 no-col ($(grep -i saturation <<<"$rep"))"

# 29e — an unreadable row in the last-3 window → 'unreadable window' (never computed on the readable subset)
d="$TMP/sat-unread"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | 0 |" "| 3 | 0 |" "| 4 | B754-G1/G2 |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : unreadable window — 1 of last 3 rows unrecognised (forms: B754-G1/G2)' <<<"$rep" && ok "#420 saturation: unreadable tail row → unreadable window, not computed on readable subset" || no "#420 unread-window ($(grep -i saturation <<<"$rep"))"

# 29g — a readable last-3 window with an OLDER unreadable row → SATURATED/active + a named partial WARN
d="$TMP/sat-partial"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | IC1–IC4 seeded |" "| 2 | 0 |" "| 3 | 0 |" "| 4 | 0 |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
if grep -q 'saturation      : SATURATED' <<<"$rep" && grep -qF '[WARN: 1 of 4 rows unreadable (forms: IC1–IC4 seeded)]' <<<"$rep"; then ok "#420 saturation: readable window + older unreadable row → SATURATED with named partial WARN"
else no "#420 partial-warn ($(grep -i saturation <<<"$rep"))"; fi

# 29h — an EMPTY New-gaps cell is reported as (empty), never silently skipped (explorador #442 review)
d="$TMP/sat-empty"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | 0 |" "| 3 |  |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : unreadable window — 1 of last 3 rows unrecognised (forms: (empty))' <<<"$rep" && ok "#420 saturation: empty New-gaps cell reported as (empty), not silently skipped" || no "#420 empty-cell ($(grep -i saturation <<<"$rep"))"

# 29f — index forms `it.N` parse for ordering; out-of-order rows still take the correct last-3 window
d="$TMP/sat-itidx"; mkiter_h "$d" "| # | New gaps uncovered |" "| it.4 | 9 |" "| it.1 | 0 |" "| it.2 | 0 |" "| it.3 | 0 |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -q 'saturation      : active (9 new gaps in last 3 iter)' <<<"$rep" && ok "#420 saturation: it.N index parsed and rows ordered by it" || no "#420 it-index ($(grep -i saturation <<<"$rep"))"


# 29i — #449: a `—`-indexed bootstrap row in the TAIL is STRUCTURAL, not a window row; last 3 NUMERIC
#       iterations are all 0 → SATURATED with the excluded-rows note (never plain SATURATED without it)
d="$TMP/sat-struct-tail"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | 0 |" "| 3 | 0 |" "| — | MA1-7 seeded |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
if grep -q 'saturation      : SATURATED' <<<"$rep" && grep -qF '[1 unnumbered row(s) (bootstrap/reopen/synthesis) excluded from the window]' <<<"$rep"; then
  ok "#449 saturation: bootstrap tail row excluded from window → SATURATED with excluded-rows note"
else no "#449 struct-tail ($(grep -i saturation <<<"$rep"))"; fi

# 29j — #449: last data row is a reopen that seeded gaps → appends 'latest unnumbered row seeded N gaps'
#       so a fresh reopen never reads plain SATURATED
d="$TMP/sat-reopen-seed"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | 0 |" "| 3 | 0 |" "| — | 5 seeded |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
if grep -q 'saturation      : SATURATED' <<<"$rep" && grep -qF '· latest unnumbered row seeded 5 gaps — not yet an iteration' <<<"$rep"; then
  ok "#449 saturation: reopen-tail row seeded note appended — fresh reopen not plain SATURATED"
else no "#449 reopen-seed ($(grep -i saturation <<<"$rep"))"; fi

# 29k — #476: a `—` reopen row whose position sorts it into the last-w of all_sorted must NOT contribute
#       its form to wforms. wforms is numbered-only (iter_window). Two-part assertion:
#       (a) REOPEN-form is ABSENT from wforms (iter-only fix);
#       (b) verdict count is unchanged (badwin uses iter_window — already correct post-#449).
#       Fixture: iter1(ok,0), iter2(bad,BAD-ITER-form), iter3(ok,0), —(bad,REOPEN-form).
#       all_sorted last-3: iter2(bad),iter3(ok),struct(bad) — old code would show REOPEN-form in wforms.
#       iter_window last-3: iter1(ok),iter2(bad),iter3(ok) — badwin=1, wforms=BAD-ITER-form only.
d="$TMP/sat-reopen-wforms"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | BAD-ITER-form |" "| 3 | 0 |" "| — | REOPEN-form |"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
sat476="$(grep 'saturation' <<<"$rep")"
if ! grep -qF 'REOPEN-form' <<<"$sat476" && grep -qF 'unreadable window — 1 of last 3 rows unrecognised' <<<"$sat476"; then
  ok "#476 reopen-tail: REOPEN-form absent from wforms; verdict count (badwin=1) unchanged"
else no "#476 reopen-tail: sat=[${sat476}] — expected REOPEN-form absent and 'unreadable window — 1 of last 3 rows unrecognised'"; fi

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
bash "$SUT" "$d" --sync-state --focus alpha >/dev/null 2>&1
bash "$SUT" "$d" --sync-state --focus beta  >/dev/null 2>&1
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
#      (like verify-state.sh:101), NOT once at the corpus root. Teeth: root has 2 blocks, subdir focus has 1.
#      Each file is seeded in single-focus mode: root first (only 1 file in $d), then legacy separately by
#      targeting its own subdirectory (only 1 file there). This avoids the scope-guard refusal (FIX 2).
d="$TMP/subdir-cb"; mkdir -p "$d"
printf '# root\n> x\n## Gap-backlog\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n' > "$d/RESEARCH-STATE.md"
printf 'x\n' > "$d/proj-block1.md"; printf 'x\n' > "$d/proj-block2.md"
bash "$SUT" "$d" --sync-state >/dev/null 2>&1    # single-focus: only RESEARCH-STATE.md exists here yet
mkdir -p "$d/legacy"
printf '# legacy\n> x\n## Gap-backlog\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n' > "$d/legacy/RESEARCH-STATE-legacy.md"
printf 'x\n' > "$d/legacy/legacy-block1.md"   # §16: block prefix mirrors state suffix (legacy- from RESEARCH-STATE-legacy.md)
bash "$SUT" "$d/legacy" --sync-state >/dev/null 2>&1    # single-focus: only legacy file in this subdir
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
bash "$SUT" "$d" --sync-state --focus alpha >/dev/null 2>&1
bash "$SUT" "$d" --sync-state --focus beta  >/dev/null 2>&1
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

# 48b-indented-nospace — issue #126 item 2: `  undocumented_findings:7` (indented + no space after colon).
# env_get: $1="undocumented_findings:7" (no trailing colon) → no match → empty.
# Fallback probe (buggy): index($0,"undocumented_findings:")==1 → position 3 (leading spaces), not 1 → missed.
# After fix (/^[[:space:]]*undocumented_findings:/ regex): matches → extracts "7" → preserved.
d="$TMP/sync-uf-indented-nospace"; mkdir -p "$d"
{ echo '# T'; echo '> intro'; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n  undocumented_findings:7\n<!-- /research-state.v1 -->\n'; echo
  echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
  echo '## Blocked gaps'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'; } > "$d/RESEARCH-STATE.md"
bash "$SUT" "$d" --sync-state 2>/dev/null
_uf_inp="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^undocumented_findings:/{print $2; exit}' "$d/RESEARCH-STATE.md")"
[ "$_uf_inp" = "7" ] \
  && ok "sync-uf-indented-nospace: '  undocumented_findings:7' (indented+nospace) → preserved as 7 by whitespace-tolerant probe" \
  || no "sync-uf-indented-nospace: uf=$_uf_inp (want 7) — indented+nospace value silently zeroed (probe whitespace-intolerant)"

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

# 51 — split-layout --sync-state seeds BOTH sibling focuses by targeting each subdir separately.
#      Each subdir contains a single RESEARCH-STATE.md (no slug) so the scope guard does not fire.
#      The prior behavior (seeding both via a single target-wide sweep) is replaced by explicit
#      per-subdir invocations that satisfy FIX 2 (scope guard) while still seeding every focus.
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
bash "$SUT" "$d51/alpha" --sync-state >/dev/null 2>&1
bash "$SUT" "$d51/beta"  --sync-state >/dev/null 2>&1
_a_seeded=$(grep -c '<!-- research-state.v1 -->' "$d51/alpha/RESEARCH-STATE.md")
_b_seeded=$(grep -c '<!-- research-state.v1 -->' "$d51/beta/RESEARCH-STATE.md")
if [ "$_a_seeded" = 1 ] && [ "$_b_seeded" = 1 ]; then
  ok "split-layout --sync-state: seeds BOTH sibling focuses (via per-subdir targeting)"
else
  no "split-layout --sync-state: alpha_seeded=$_a_seeded(want 1) beta_seeded=$_b_seeded(want 1)"
fi

# 52 — BLOCKING: block_scope: shared-global must survive --sync-state; covered_blocks must be seeded
# from the GLOBAL (focus-blind) count, not the focus-filtered 0. Corpus: RESEARCH-STATE-chihuahua.md
# declares block_scope: shared-global + covered_blocks: 3; 3 niagara-bloque* files on disk.
# chihuahua- prefix finds 0 blocks → broken sync seeds 0 and destroys block_scope → verify-state fails.
d52="$TMP/sync-bs"; mkdir -p "$d52"
printf 'x\n' > "$d52/niagara-bloque1.md"; printf 'x\n' > "$d52/niagara-bloque2.md"; printf 'x\n' > "$d52/niagara-bloque3.md"
printf '# C\n> i\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 3\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope: shared-global\n<!-- /research-state.v1 -->\n\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n' \
  > "$d52/RESEARCH-STATE-chihuahua.md"
bash "$SUT" "$d52" --sync-state >/dev/null 2>&1
_bs52="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^block_scope:/{print $2; exit}' "$d52/RESEARCH-STATE-chihuahua.md")"
_cb52="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^covered_blocks:/{print $2; exit}' "$d52/RESEARCH-STATE-chihuahua.md")"
[ "$_bs52" = "shared-global" ] && [ "$_cb52" = "3" ] \
  && ok "sync-bs: block_scope: shared-global preserved; covered_blocks=3 (global, not 0)" \
  || no "sync-bs: bs=$_bs52(want shared-global) cb=$_cb52(want 3) — sync destroyed block_scope or used wrong count"
# 53 — sync-bs-e2e: declare → sync → verify-state must exit 0 AND report covered_blocks=3/3 (global)
# Checks the OUTPUT, not just the exit code: before the fix, sync seeds cb=0 (0/0 is a false-pass);
# after the fix, cb=3 (global) so verify-state reports 3/3 — distinguishing correct from silent zero.
_vs53out="$(bash "$HERE/../verify-state.sh" "$d52" 2>/dev/null)"; _vs53rc=$?
if [ "$_vs53rc" = "0" ] && grep -qE 'covered_blocks=3/3' <<<"$_vs53out"; then
  ok "sync-bs-e2e: verify-state exits 0 with covered_blocks=3/3 (global count) after shared-global sync"
else no "sync-bs-e2e: rc=$_vs53rc :: $(grep 'envelope' <<<"$_vs53out" | head -1) (want rc=0 + cb=3/3)"; fi

# 53b — sync-bs-indented-nospace: issue #126 item 2 — `  block_scope:shared-global` (indented + no space).
# env_get: $1="block_scope:shared-global" (no trailing colon) → no match → empty.
# Fallback probe (buggy): index($0,"block_scope:")==1 → position 3 (leading spaces), not 1 → missed.
# After fix (/^[[:space:]]*block_scope:/ regex): matches → extracts "shared-global" → carried through sync.
d53b="$TMP/sync-bs-indented-nospace"; mkdir -p "$d53b"
printf 'x\n' > "$d53b/niagara-bloque1.md"
printf '# C\n> i\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 1\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n  block_scope:shared-global\n<!-- /research-state.v1 -->\n\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n' \
  > "$d53b/RESEARCH-STATE-chihuahua.md"
bash "$SUT" "$d53b" --sync-state 2>/dev/null
_bs53b="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^block_scope:/{print $2; exit}' "$d53b/RESEARCH-STATE-chihuahua.md")"
[ "$_bs53b" = "shared-global" ] \
  && ok "sync-bs-indented-nospace: '  block_scope:shared-global' (indented+nospace) → carried through sync (whitespace-tolerant probe)" \
  || no "sync-bs-indented-nospace: bs=$_bs53b (want shared-global) — indented+nospace probe missed (whitespace-intolerant)"

# ---- ISSUE #143 — unknown priority concealment chain -----------------------------------------------
# Unknown priorities (e.g. 'critical', 'urgent', typos) were silently dropped by backlog_rows().
# The gap was concealed: scheduler returned STOP and --sync-state laundered a false-ok envelope.
# mkbadprio <dir> <priority-value> [io=1|0]  io=0 = laundered (what --sync-state wrote under the bug)
mkbadprio() {
  local dir="$1" pval="$2" io="${3:-1}"; mkdir -p "$dir"
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 1\ninvestigable_open: %s\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n' "$io"; echo
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    echo "| $pval | firmware parsing | web | pending |"; echo
    echo "## Blocked gaps"; echo "- none"; echo
    echo "## Stop control"
    echo "- **Open gaps — read-only investigable**: $io"
  } > "$dir/RESEARCH-STATE.md"
}

# T54 — 'critical' (laundered io=0) → --next STALE (not STOP). Pre-fix: verify-state passed, gap concealed.
d="$TMP/bp-laundered"; mkbadprio "$d" "critical" 0
got54="$(next "$d")"
case "$got54" in
  STALE\ *) ok "T54: unknown priority 'critical' (laundered io=0) → --next STALE (not STOP)";;
  STOP\ *)  no "T54: --next returned STOP — concealment chain still active (got [$got54])";;
  NEXT\ *)  no "T54: --next returned NEXT on unparseable backlog (got [$got54])";;
  *)        no "T54: unexpected output: [$got54]";;
esac

# T55 — unknown priority → --sync-state REFUSES (non-zero exit); envelope io=1 stays unchanged.
d="$TMP/bp-syncrefuse"; mkbadprio "$d" "urgent" 1
bash "$SUT" "$d" --sync-state >/dev/null 2>&1; t55_rc=$?
t55_io="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^investigable_open:/{print $2; exit}' "$d/RESEARCH-STATE.md")"
[ "$t55_rc" -ne 0 ] && ok "T55: --sync-state exits non-zero on 'urgent' (refuses to rewrite)" \
  || no "T55: --sync-state exited 0 — should have refused (exit non-zero)"
[ "$t55_io" = "1" ] && ok "T55: envelope investigable_open unchanged at 1 — sync refused to launder" \
  || no "T55: envelope changed to '$t55_io' (was 1) — sync should have refused"

# T56 — concealment chain: sync refused (io=1 stays) → verify-state must still FAIL.
d="$TMP/bp-chain"; mkbadprio "$d" "critical" 1
bash "$SUT" "$d" --sync-state >/dev/null 2>&1   # expected to REFUSE with the fix
t56_vs="$(bash "$HERE/../verify-state.sh" "$d" >/dev/null 2>&1 && echo "ok" || echo "FAIL")"
[ "$t56_vs" = "FAIL" ] && ok "T56: after refused sync, verify-state still FAILs — chain not disarmed" \
  || no "T56: verify-state reports '$t56_vs' (want FAIL) — chain was disarmed"

# T57 — REGRESSION: valid priorities (high, medium, low) unchanged by the fix.
d="$TMP/bp-valid"; mkstate "$d" 2 "high|shader gap|pending" "medium|loader gap|pending" "low|trivia|covered"
expect_next "$d" "NEXT | high | shader gap" "T57: valid priorities (high/medium/low) unchanged by unknown-priority fix"

# T58 — MIXED: valid 'high' + 'critical', laundered io=1 → STALE (fails closed, valid row not routed).
d="$TMP/bp-mixed"; mkdir -p "$d"
{ echo "# T — Research State"; echo
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 2\ninvestigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n'; echo
  echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
  echo "| high | valid gap | web | pending |"
  echo "| critical | firmware parsing | web | pending |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"
  echo "- **Open gaps — read-only investigable**: 1"
} > "$d/RESEARCH-STATE.md"
got58="$(next "$d")"
case "$got58" in
  STALE\ *) ok "T58: mixed backlog (valid high + critical) → --next STALE (fails closed, valid row not routed)";;
  NEXT\ *"valid gap"*) no "T58: --next routed the valid high gap despite unparseable backlog (got [$got58])";;
  STOP\ *)  no "T58: --next returned STOP — concealment still active (got [$got58])";;
  *)        no "T58: unexpected output: [$got58]";;
esac

# ---- Issue #143 corpus vocabulary: strikethrough / qualifier / em-dash skip forms ----
# These forms must be silently skipped (not cause STALE). Invalid qualifier base still fails closed.

# Suite-local helper: skip-form row + valid medium pending; io=1 (only medium counted after fix).
mk_vocab_skip_fixture() {
  local d="$1" pval="$2" gdesc="$3" gtype="$4" gstatus="$5"; mkdir -p "$d"
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 2\ninvestigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n<!-- /research-state.v1 -->\n'; echo
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    echo "| $pval | $gdesc | $gtype | $gstatus |"
    echo "| medium | active gap | web | pending |"; echo
    echo "## Blocked gaps"; echo "- none"; echo
    echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"
  } > "$d/RESEARCH-STATE.md"
}

# T59 — '~~high~~' silently skipped; --next routes valid medium gap.
d="$TMP/bp-strikethrough-status"
mkstate "$d" 1 "~~high~~|resolved gap|~~covered~~" "medium|active gap|pending"
expect_next "$d" "NEXT | medium | active gap" "T59: ~~high~~ (strikethrough) silently skipped — --next routes valid medium gap"

# T60 — 'high (cross-vibra)' (valid-base qualifier) emits WARN to stderr, still excluded; --next routes medium gap.
# Cannot use mkstate: it counts all pending rows for io; with fix high(x) skipped → io=1 only.
mk_vocab_skip_fixture "$TMP/bp-qualifier-status" 'high (cross-vibra)' 'vibra gap' 'web' 'pending (cross-vibra)'
expect_next "$TMP/bp-qualifier-status" "NEXT | medium | active gap" "T60: 'high (cross-vibra)' (valid-base qualifier) excluded — --next routes medium gap"
# T60-warn — same fixture: qualifier row must emit a provisional WARN to stderr naming the stripped base 'high'.
warn60="$(bash "$SUT" "$TMP/bp-qualifier-status" --next 2>&1 >/dev/null)"
grep -qE 'WARN.*non-conforming qualifier.*high' <<<"$warn60" \
  && ok "T60-warn: qualifier row emits WARN to stderr naming base 'high'" \
  || no "T60-warn: no WARN emitted — got [$warn60]"

# T61 — '—' (em-dash) silently skipped; --next routes valid medium gap.
mk_vocab_skip_fixture "$TMP/bp-em-dash-status" '—' 'placeholder' '—' '—'
expect_next "$TMP/bp-em-dash-status" "NEXT | medium | active gap" "T61: '—' (em-dash placeholder) silently skipped — --next routes valid medium gap"

# T62 — 'hight (cross-vibra)' (invalid base 'hight') → STALE. Qualifier form is not an escape hatch.
d="$TMP/bp-qualifier-invalid-status"; mkbadprio "$d" "hight (cross-vibra)" 0
got62="$(next "$d")"
case "$got62" in
  STALE\ *) ok "T62: 'hight (cross-vibra)' (invalid qualifier base 'hight') → --next STALE (fails closed)";;
  NEXT\ *)  no "T62: --next returned NEXT on unparseable backlog (got [$got62])";;
  STOP\ *)  no "T62: --next returned STOP — verify-state passed with invalid base (parse check not firing)";;
  *)        no "T62: unexpected output: [$got62]";;
esac

# 63 — ISSUE #194: multi-focus --next MUST skip a STOPPED focus with a STALE envelope and return
#      NEXT from the active sibling. Scenario: RESEARCH-STATE-stopped.md has all gaps covered but a
#      stale envelope (investigable_open: 1 while the derived value is 0); RESEARCH-STATE-active.md
#      has 1 pending gap and a correct envelope (investigable_open: 1). verify-state.sh fails on the
#      stopped focus's stale envelope → old code returned STALE; after fix, the stopped focus is
#      bypassed and NEXT is returned from the active sibling.
d="$TMP/stopped-focus"; mkdir -p "$d"
{ echo "# Stopped Focus"
  echo
  env_lines 0 0 0 1 0 0     # investigable_open: 1 (STALE — actual is 0; the only gap is covered)
  echo
  echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | legacy done gap | web | covered |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"
} > "$d/RESEARCH-STATE-stopped.md"
{ echo "# Active Focus"
  echo
  env_lines 0 0 0 1 0 0     # investigable_open: 1 (correct — 1 pending gap)
  echo
  echo "## Gap-backlog (prioritized)"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | active pending gap | web | pending |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"
} > "$d/RESEARCH-STATE-active.md"
expect_next "$d" "NEXT | high | active pending gap" "#194: stopped focus with stale envelope skipped — active sibling NEXT returned"

# 64 — near-miss: '## Gap backlog' (space instead of hyphen) → WARN on stderr from backlog_rows.
# Envelope investigable_open=1 because the awk final print has no in_backlog guard: the row inside
# the near-miss section IS returned, making derive_investigable=1; the envelope must match so
# verify-state passes and status.sh reaches resolve_next → backlog_rows → WARN fires.
d="$TMP/nm-space"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 1 0 0; echo; echo "## Gap backlog"; echo
  echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | g1 | web | pending |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
nm_warn_space="$(bash "$SUT" "$d" --next 2>&1 >/dev/null)"
grep -qi 'near-miss' <<<"$nm_warn_space" && ok "64: near-miss '## Gap backlog' → WARN on stderr" || no "64: near-miss '## Gap backlog' — no WARN (got: $nm_warn_space)"

# 64b — near-miss: '## Backlog de gaps' (Spanish heading) → WARN on stderr
d="$TMP/nm-spanish"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 1 0 0; echo; echo "## Backlog de gaps"; echo
  echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | g1 | web | pending |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
nm_warn_es="$(bash "$SUT" "$d" --next 2>&1 >/dev/null)"
grep -qi 'near-miss' <<<"$nm_warn_es" && ok "64b: near-miss '## Backlog de gaps' → WARN on stderr" || no "64b: near-miss '## Backlog de gaps' — no WARN"

# 64c — near-miss: '## Gap-backlog prioritized' (text outside parens) → WARN on stderr
d="$TMP/nm-noparens"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 1 0 0; echo; echo "## Gap-backlog prioritized"; echo
  echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | g1 | web | pending |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
nm_warn_np="$(bash "$SUT" "$d" --next 2>&1 >/dev/null)"
grep -qi 'near-miss' <<<"$nm_warn_np" && ok "64c: near-miss '## Gap-backlog prioritized' → WARN on stderr" || no "64c: near-miss '## Gap-backlog prioritized' — no WARN"

# 64d — near-miss: U+2011 non-breaking hyphen 'Gap‑backlog' → WARN on stderr
d="$TMP/nm-nbhyphen"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 1 0 0; echo; printf '## Gap\xe2\x80\x91backlog\n'; echo
  echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | g1 | web | pending |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
nm_warn_nb="$(bash "$SUT" "$d" --next 2>&1 >/dev/null)"
grep -qi 'near-miss' <<<"$nm_warn_nb" && ok "64d: near-miss U+2011 'Gap‑backlog' → WARN on stderr" || no "64d: U+2011 near-miss — no WARN"

# 64e — canonical '## Gap-backlog (prioritized)' must NOT warn (happy-path regression guard)
d="$TMP/nm-canonical"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 1 0 0; echo; echo "## Gap-backlog (prioritized)"; echo
  echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | real gap | web | pending |"; echo
  echo "## Blocked gaps"; echo "- none"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
nm_warn_can="$(bash "$SUT" "$d" --next 2>&1 >/dev/null)"
! grep -qi 'near-miss' <<<"$nm_warn_can" && ok "64e: canonical '## Gap-backlog (prioritized)' → no near-miss WARN" || no "64e: canonical form falsely warned: [$nm_warn_can]"

# 64f — '## Blocked gaps' heading must NOT trigger near-miss WARN (false-positive guard)
d="$TMP/nm-blocked-fp"; mkstate "$d" 1 "high|real gap|pending"
nm_warn_blk="$(bash "$SUT" "$d" --next 2>&1 >/dev/null)"
! grep -qi 'near-miss' <<<"$nm_warn_blk" && ok "64f: '## Blocked gaps' → no near-miss WARN (false-positive guard)" || no "64f: '## Blocked gaps' falsely triggered near-miss: [$nm_warn_blk]"

# ==================== FIX 1 — GENERALIZED PREAMBLE CARRY-FORWARD ====================

# T-PREAMBLE-ROUNDTRIP: a RESEARCH-STATE carrying method:, block_scope:, and an unknown field
# foo: bar (the generalization sentinel), plus stale count fields → after --sync-state all three
# preamble fields survive verbatim AND the count is reconciled to the on-disk truth.
# Before the fix: method: (and any unknown field) were silently dropped; only block_scope: had
# an explicit carry-forward. The foo: bar case is ESSENTIAL — it proves the generalization, not
# just a method:-special-case.
d="$TMP/preamble-rt"; mkdir -p "$d"
{ echo "# T"
  echo "> intro"
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 99\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nmethod: document-cycle-external\nblock_scope: per-focus\nfoo: bar\n<!-- /research-state.v1 -->\n'
  echo; echo "## Gap-backlog"; echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | the gap | web | pending |"
  echo; echo "## Blocked gaps"; echo; echo "## Stop control"
  echo "- **Open gaps — read-only investigable**: 1"
} > "$d/RESEARCH-STATE.md"
bash "$SUT" "$d" --sync-state >/dev/null 2>&1
_pr_method="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^method:/{$1=""; sub(/^[[:space:]]*/,""); print; exit}' "$d/RESEARCH-STATE.md")"
_pr_bscope="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^block_scope:/{print $2; exit}' "$d/RESEARCH-STATE.md")"
_pr_foo="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^foo:/{$1=""; sub(/^[[:space:]]*/,""); print; exit}' "$d/RESEARCH-STATE.md")"
_pr_io="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^investigable_open:/{print $2; exit}' "$d/RESEARCH-STATE.md")"
if [ "$_pr_method" = "document-cycle-external" ] && [ "$_pr_bscope" = "per-focus" ] && [ "$_pr_foo" = "bar" ]; then
  ok "preamble-roundtrip: method:, block_scope:, and unknown foo: bar all survive --sync-state (generalized carry-forward)"
else
  no "preamble-roundtrip: method=$_pr_method(want document-cycle-external) bscope=$_pr_bscope(want per-focus) foo=$_pr_foo(want bar)"
fi
[ "$_pr_io" = "1" ] \
  && ok "preamble-roundtrip: investigable_open reconciled to 1 (counts still reconcile after carry-forward)" \
  || no "preamble-roundtrip: investigable_open=$_pr_io(want 1) — reconciliation broken by carry-forward"

# ==================== FIX 2 — SCOPE GUARD (DON'T CLOBBER SIBLINGS) ====================

# T-SIBLING-GUARD: --sync-state WITHOUT --focus on a multi-focus corpus (2 RESEARCH-STATE-*.md)
# must refuse with WARN on stderr, exit non-zero, and leave BOTH files byte-for-byte unchanged.
# Before the fix: the sweep ran on all files, clobbering preamble fields (issue #368 root cause).
d="$TMP/sibling-guard"; mkdir -p "$d"
_sg_env() { printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 99\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nmethod: some-method\n<!-- /research-state.v1 -->\n'; }
{ echo "# A"; echo "> intro"; _sg_env
  echo; echo "## Gap-backlog"; echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "## Blocked gaps"; echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"
} > "$d/RESEARCH-STATE-alpha.md"
{ echo "# B"; echo "> intro"; _sg_env
  echo; echo "## Gap-backlog"; echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "## Blocked gaps"; echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"
} > "$d/RESEARCH-STATE-beta.md"
_sg_hash_a_before="$(md5sum "$d/RESEARCH-STATE-alpha.md" | cut -d' ' -f1)"
_sg_hash_b_before="$(md5sum "$d/RESEARCH-STATE-beta.md" | cut -d' ' -f1)"
_sg_warn="$(bash "$SUT" "$d" --sync-state 2>&1 >/dev/null)"; _sg_rc=$?
_sg_hash_a_after="$(md5sum "$d/RESEARCH-STATE-alpha.md" | cut -d' ' -f1)"
_sg_hash_b_after="$(md5sum "$d/RESEARCH-STATE-beta.md" | cut -d' ' -f1)"
if [ "$_sg_rc" -ne 0 ] && grep -qi 'WARN' <<<"$_sg_warn" \
   && [ "$_sg_hash_a_before" = "$_sg_hash_a_after" ] && [ "$_sg_hash_b_before" = "$_sg_hash_b_after" ]; then
  ok "sibling-guard: multi-focus without --focus refuses (WARN stderr, exit non-zero, files unchanged)"
else
  no "sibling-guard: rc=$_sg_rc warn=$(grep -qi WARN <<<"$_sg_warn" && echo yes || echo no) a_changed=$([ "$_sg_hash_a_before" != "$_sg_hash_a_after" ] && echo YES || echo no) b_changed=$([ "$_sg_hash_b_before" != "$_sg_hash_b_after" ] && echo YES || echo no)"
fi

# T-SIBLING-GUARD-FOCUS: with --focus, only the targeted file is seeded; the other is unchanged.
_sg_hash_b_snap="$(md5sum "$d/RESEARCH-STATE-beta.md" | cut -d' ' -f1)"
bash "$SUT" "$d" --sync-state --focus alpha >/dev/null 2>&1
_sg_hash_b_after_focus="$(md5sum "$d/RESEARCH-STATE-beta.md" | cut -d' ' -f1)"
_pr_alpha_io="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^investigable_open:/{print $2; exit}' "$d/RESEARCH-STATE-alpha.md")"
if [ "$_sg_hash_b_snap" = "$_sg_hash_b_after_focus" ] && [ "$_pr_alpha_io" = "0" ]; then
  ok "sibling-guard-focus: --focus alpha touches only alpha (beta unchanged, alpha.io reconciled to 0)"
else
  no "sibling-guard-focus: beta_changed=$([ "$_sg_hash_b_snap" != "$_sg_hash_b_after_focus" ] && echo YES || echo no) alpha.io=$_pr_alpha_io(want 0)"
fi

# T-BOLD-PENDING-REPORT (#424): **pending** Status cell is counted in the default pending-backlog line.
d_bp424="$TMP/bold-pending-report"; mkdir -p "$d_bp424"
{ printf '# T\n> intro\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
  echo; echo "## Gap-backlog (prioritized)"; echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | bold-gap | web | **pending** |"
  echo "| medium | bare-gap | web | pending |"
  echo; echo "## Blocked gaps"; echo; echo "## Stop control"
  echo "- **Open gaps — read-only investigable**: 0"
} > "$d_bp424/RESEARCH-STATE.md"
_bp424_rep="$(bash "$SUT" "$d_bp424" 2>/dev/null)"
_bp424_ph="$(grep 'pending backlog' <<<"$_bp424_rep" | head -1)"
if grep -q 'high=1' <<<"$_bp424_ph" && grep -q 'medium=1' <<<"$_bp424_ph"; then
  ok "bold-pending-report: **pending** and bare pending both counted in pending backlog line (#424)"
else
  no "bold-pending-report: pending backlog [$_bp424_ph] — want high=1 medium=1 (**pending** may be dropped)"
fi

# T-BOLD-PENDING-SYNC (#424): --sync-state counts **pending** as investigable_open.
d_bs424="$TMP/bold-pending-sync"; mkdir -p "$d_bs424"
{ printf '# T\n> intro\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
  echo; echo "## Gap-backlog (prioritized)"; echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | bold-gap | web | **pending** |"
  echo; echo "## Blocked gaps"; echo; echo "## Stop control"
  echo "- **Open gaps — read-only investigable**: 0"
} > "$d_bs424/RESEARCH-STATE.md"
bash "$SUT" "$d_bs424" --sync-state >/dev/null 2>&1
_bs424_io="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^investigable_open:/{print $2; exit}' "$d_bs424/RESEARCH-STATE.md")"
[ "$_bs424_io" = "1" ] \
  && ok "bold-pending-sync: --sync-state counts **pending** as investigable_open=1 (#424)" \
  || no "bold-pending-sync: investigable_open=$_bs424_io (want 1) — **pending** still dropped (#424)"

# T-UNRECOG-WARN (#424): unrecognised Status token emits a WARN to stderr.
d_uw424="$TMP/unrecog-warn"; mkdir -p "$d_uw424"
{ printf '# T\n> intro\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
  echo; echo "## Gap-backlog (prioritized)"; echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | open-gap | web | open |"
  echo; echo "## Blocked gaps"; echo; echo "## Stop control"
  echo "- **Open gaps — read-only investigable**: 0"
} > "$d_uw424/RESEARCH-STATE.md"
_uw424_warn="$(bash "$SUT" "$d_uw424" --sync-state 2>&1 >/dev/null)"
grep -qi 'unrecognised' <<<"$_uw424_warn" \
  && ok "unrecog-warn: 'open' token emits WARN: unrecognised Status token to stderr (#424)" \
  || no "unrecog-warn: no 'unrecognised' WARN on stderr for 'open' status token — silent drop persists (#424)"

# T-DONE-SILENT (#424b): recognised done-marker tokens are silent — no false-positive WARN flood.
d_ds424="$TMP/done-silent"; mkdir -p "$d_ds424"
{ printf '# T\n> intro\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
  echo; echo "## Gap-backlog (prioritized)"; echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | g-closed | web | closed |"
  echo "| high | g-covered | web | [covered] |"
  echo "| medium | g-done | web | done |"
  echo "| low | g-blocked | web | blocked |"
  echo; echo "## Blocked gaps"; echo; echo "## Stop control"
  echo "- **Open gaps — read-only investigable**: 0"
} > "$d_ds424/RESEARCH-STATE.md"
_ds424_warn="$(bash "$SUT" "$d_ds424" --sync-state 2>&1 >/dev/null)"
! grep -qi 'unrecognised' <<<"$_ds424_warn" \
  && ok "done-silent: closed/[covered]/done/blocked emit no WARN — done-marker set is recognised (#424b)" \
  || no "done-silent: got WARN on done-marker token — false-positive flood persists: [$_ds424_warn]"

# T-NOVEL-WARN (#424b): novel token (frobnicate) still emits a named WARN after done-set expansion.
d_nw424="$TMP/novel-warn"; mkdir -p "$d_nw424"
{ printf '# T\n> intro\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
  echo; echo "## Gap-backlog (prioritized)"; echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | frob-gap | web | frobnicate |"
  echo; echo "## Blocked gaps"; echo; echo "## Stop control"
  echo "- **Open gaps — read-only investigable**: 0"
} > "$d_nw424/RESEARCH-STATE.md"
_nw424_warn="$(bash "$SUT" "$d_nw424" --sync-state 2>&1 >/dev/null)"
grep -qi 'unrecognised' <<<"$_nw424_warn" \
  && ok "novel-warn: frobnicate token still emits WARN — novel tokens not blanket-silenced (#424b)" \
  || no "novel-warn: frobnicate was silently dropped — enumerated set may have become a catch-all (#424b)"

# T-STRICKEN-GAP (#424b): struck-through gap name is skipped silently (no WARN despite unrecognised status).
d_sg424="$TMP/stricken-gap"; mkdir -p "$d_sg424"
{ printf '# T\n> intro\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
  echo; echo "## Gap-backlog (prioritized)"; echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | ~~resolved-gap~~ | web | [covered] |"
  echo; echo "## Blocked gaps"; echo; echo "## Stop control"
  echo "- **Open gaps — read-only investigable**: 0"
} > "$d_sg424/RESEARCH-STATE.md"
_sg424_warn="$(bash "$SUT" "$d_sg424" --sync-state 2>&1 >/dev/null)"
! grep -qi 'unrecognised' <<<"$_sg424_warn" \
  && ok "stricken-gap: struck-through gap name is skipped silently — no WARN for resolved row (#424b)" \
  || no "stricken-gap: got WARN on struck-through gap — stricken-gap skip not applied: [$_sg424_warn]"

# T-BOLDFIX (#424b): **pending** (note) counts as investigable (closing ** not at end of lead).
d_bf424="$TMP/boldfix-pending"; mkdir -p "$d_bf424"
{ printf '# T\n> intro\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
  echo; echo "## Gap-backlog (prioritized)"; echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | decorated-gap | web | **pending** (uncovered by B7) |"
  echo; echo "## Blocked gaps"; echo; echo "## Stop control"
  echo "- **Open gaps — read-only investigable**: 0"
} > "$d_bf424/RESEARCH-STATE.md"
bash "$SUT" "$d_bf424" --sync-state >/dev/null 2>&1
_bf424_io="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^investigable_open:/{print $2; exit}' "$d_bf424/RESEARCH-STATE.md")"
[ "$_bf424_io" = "1" ] \
  && ok "boldfix: **pending** (note) counts as investigable_open=1 — closing ** in mid-string stripped (#424b)" \
  || no "boldfix: investigable_open=$_bf424_io (want 1) — **pending** (note) still dropped (#424b)"

# NEGATIVE CONTROL — reverse the priority order; the "high beats low" fixture must then pick LOW.
if [ "${1:-}" = "--prove-teeth" ]; then
  # The mutant status scripts resolve $here to $TMP, so they need verify-state.sh at $TMP/verify-state.sh.
  # verify-state.sh sources lib/focus-prefix.sh; status.sh also sources lib/state-files.sh after the fix.
  mkdir -p "$TMP/lib"
  cp "$HERE/../lib/focus-prefix.sh" "$TMP/lib/focus-prefix.sh"
  cp "$HERE/../lib/state-files.sh" "$TMP/lib/state-files.sh"
  cp "$HERE/../lib/block-files.sh" "$TMP/lib/block-files.sh"  # SUT sources at $(dirname $0)/lib/

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

  # #420 teeth (a): revert New-gaps column selection to the LAST column; a fixture whose New-gaps column
  # is NOT last (last col is prose 'Result') must then misread and lose SATURATED.
  echo "-- teeth-#420a: last-column-fallback mutant misreads a non-last New-gaps column --"
  a420_mut="$TMP/status.420A.MUTANT.sh"
  if grep -q '# NG-COL-BYNAME' "$SUT"; then
    sed 's/cell=a\[ngcol\]  # NG-COL-BYNAME/cell=a[n]  # MUTANT-420A/' "$SUT" > "$a420_mut"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    d="$TMP/sat420a"; mkiter_h "$d" "| # | New gaps | Result |" "| 1 | 0 | did |" "| 2 | 0 | did |" "| 3 | 0 | did |"
    a420_rep="$(bash "$a420_mut" "$d" 2>/dev/null)"
    if ! grep -q 'saturation      : SATURATED' <<<"$a420_rep"; then
      ok "teeth-#420a: last-column mutant loses SATURATED → header-name selection has teeth"
    else no "teeth-#420a: mutant still SATURATED [$(grep -i saturation <<<"$a420_rep")] — column-by-name not exercised (THEATER)"; fi
  else no "teeth-#420a: NG-COL-BYNAME sentinel not found in SUT"; fi

  # #420 teeth (b): drop none/ninguno recognition; an all-`none…` window must flip off SATURATED.
  echo "-- teeth-#420b: none/ninguno-blind mutant flips an all-none window off SATURATED --"
  b420_mut="$TMP/status.420B.MUTANT.sh"
  if grep -q '# NG-NONE' "$SUT"; then
    sed '/# NG-NONE/s/isnone = .*/isnone = 0  # MUTANT-420B/' "$SUT" > "$b420_mut"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    d="$TMP/sat420b"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | none net-new · yes · sonnet |" "| 2 | ninguno para este focus |" "| 3 | none |"
    b420_rep="$(bash "$b420_mut" "$d" 2>/dev/null)"
    if ! grep -q 'saturation      : SATURATED' <<<"$b420_rep" && grep -q 'unreadable window' <<<"$b420_rep"; then
      ok "teeth-#420b: none/ninguno-blind mutant flips all-none window to unreadable → none-recognition has teeth"
    else no "teeth-#420b: mutant [$(grep -i saturation <<<"$b420_rep")] — none-recognition not exercised (THEATER)"; fi
  else no "teeth-#420b: NG-NONE sentinel not found in SUT"; fi

  # #420 teeth (c): neuter window honesty; a mutant that computes on the readable subset must turn an
  # unreadable-window fixture into SATURATED (readable-but-older rows wrongly rescue an unreadable tail).
  echo "-- teeth-#420c: window-honesty neutered → an unreadable-window fixture wrongly computes SATURATED --"
  c420_mut="$TMP/status.420C.MUTANT.sh"
  if grep -q '# NG-WINDOW' "$SUT"; then
    sed 's/if \[ "\$badwin" -gt 0 \]; then  # NG-WINDOW/if false; then  # MUTANT-420C/' "$SUT" > "$c420_mut"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    d="$TMP/sat420c"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | 0 |" "| 3 | 0 |" "| 4 | 0 |" "| 5 | B754-G1/G2 |"
    c420_orig="$(bash "$SUT" "$d" 2>/dev/null)"
    c420_mrep="$(bash "$c420_mut" "$d" 2>/dev/null)"
    if grep -q 'saturation      : unreadable window' <<<"$c420_orig" && grep -q 'saturation      : SATURATED' <<<"$c420_mrep"; then
      ok "teeth-#420c: window-honesty neutered → mutant computes SATURATED on an unreadable window → guard has teeth"
    else no "teeth-#420c: orig=[$(grep -i saturation <<<"$c420_orig")] mut=[$(grep -i saturation <<<"$c420_mrep")] — window honesty not load-bearing (THEATER)"; fi
  else no "teeth-#420c: NG-WINDOW sentinel not found in SUT"; fi


  # #449 teeth (a): drop NG-STRUCT-SPLIT — revert to the old "all rows are window rows" behaviour by
  # making struct rows appear as "row" records. A fixture with a `—`-indexed bootstrap row in the tail
  # currently reports SATURATED+excluded-note; the mutant must flip to unreadable-window (the old bug).
  echo "-- teeth-#449a: NG-STRUCT-SPLIT neutered → bootstrap tail row counts as window row → unreadable-window --"
  a449_mut="$TMP/status.449A.MUTANT.sh"
  if grep -q '# NG-STRUCT-SPLIT' "$SUT"; then
    # mutant: collapse struct type back to row so structural rows enter the window
    sed 's/{ sk=substr(idx,RSTART,RLENGTH); type="row" } else { sk=seq; type="struct" }  # NG-STRUCT/{ sk=substr(idx,RSTART,RLENGTH); type="row" } else { sk=seq; type="row" }  # MUTANT-449A/' "$SUT" > "$a449_mut"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    d="$TMP/sat449a"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | 0 |" "| 3 | 0 |" "| — | MA1-7 seeded |"
    a449_orig="$(bash "$SUT" "$d" 2>/dev/null)"
    a449_mrep="$(bash "$a449_mut" "$d" 2>/dev/null)"
    if grep -q 'saturation      : SATURATED' <<<"$a449_orig" && grep -q 'unreadable window' <<<"$a449_mrep"; then
      ok "teeth-#449a: NG-STRUCT-SPLIT neutered → bootstrap row enters window → unreadable-window (guard has teeth)"
    else no "teeth-#449a: orig=[$(grep -i saturation <<<"$a449_orig")] mut=[$(grep -i saturation <<<"$a449_mrep")] — struct-split not load-bearing (THEATER)"; fi
  else no "teeth-#449a: NG-STRUCT-SPLIT sentinel not found in SUT"; fi

  # #449 teeth (b): drop the seed note; a reopen-tail fixture must read plain SATURATED without it.
  echo "-- teeth-#449b: seed note dropped → reopen-tail fixture reads plain SATURATED (no seed note) --"
  b449_mut="$TMP/status.449B.MUTANT.sh"
  if grep -q 'note_seed=' "$SUT"; then
    sed 's/note_seed="\s*· latest unnumbered.*/note_seed=""  # MUTANT-449B: seed note disabled/' "$SUT" > "$b449_mut"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    d="$TMP/sat449b"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | 0 |" "| 3 | 0 |" "| — | 5 seeded |"
    b449_orig="$(bash "$SUT" "$d" 2>/dev/null)"
    b449_mrep="$(bash "$b449_mut" "$d" 2>/dev/null)"
    if grep -qF '· latest unnumbered row seeded 5 gaps' <<<"$b449_orig" && ! grep -qF '· latest unnumbered row seeded' <<<"$b449_mrep"; then
      ok "teeth-#449b: seed note dropped → reopen-tail reads plain SATURATED without note (guard has teeth)"
    else no "teeth-#449b: orig=[$(grep -i saturation <<<"$b449_orig")] mut=[$(grep -i saturation <<<"$b449_mrep")] — seed note not load-bearing (THEATER)"; fi
  else no "teeth-#449b: note_seed assignment not found in SUT"; fi

  # #449 teeth (c): drop excluded-rows note → silently excludes structural rows with no announcement.
  echo "-- teeth-#449c: excluded-rows note dropped → struct-tail fixture reads SATURATED silently (no note) --"
  c449_mut="$TMP/status.449C.MUTANT.sh"
  if grep -q 'note_struct=' "$SUT"; then
    sed 's/note_struct="\s*\[${nstruct}.*/note_struct=""  # MUTANT-449C: excluded note disabled/' "$SUT" > "$c449_mut"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    d="$TMP/sat449c"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | 0 |" "| 3 | 0 |" "| — | MA1-7 seeded |"
    c449_orig="$(bash "$SUT" "$d" 2>/dev/null)"
    c449_mrep="$(bash "$c449_mut" "$d" 2>/dev/null)"
    if grep -qF '[1 unnumbered row(s)' <<<"$c449_orig" && ! grep -qF '[1 unnumbered row(s)' <<<"$c449_mrep"; then
      ok "teeth-#449c: excluded-rows note dropped → struct-tail reads SATURATED silently (guard has teeth)"
    else no "teeth-#449c: orig=[$(grep -i saturation <<<"$c449_orig")] mut=[$(grep -i saturation <<<"$c449_mrep")] — excluded note not load-bearing (THEATER)"; fi
  else no "teeth-#449c: note_struct assignment not found in SUT"; fi

  # #449 teeth (d): unstable sort reorders tied-sk forms in the partial-WARN sample → stable sort is load-bearing.
  # Fixture: iter1(ok,3), struct(bad,STRUCT-bad-form) at seq=2 tying sk=2 with iter2(bad,ITER-bad-2), iter3(ok,5), iter4(ok,3), iter5(ok,2).
  # Window (last-3 iter): iter3,iter4,iter5 — all ok → no badwin, no NG-WINDOW path.
  # partial-WARN: 3 bad rows (iter1,struct,iter2). Stable sort all_sorted at sk=2: struct before iter2 (file-pos).
  # First 2 distinct bad forms: ITER-bad-1,STRUCT-bad-form. Unstable sort flips sk=2 tie → forms: ITER-bad-1,ITER-bad-2.
  echo "-- teeth-#449d: unstable-sort mutant reorders partial-WARN forms at tied sk → stable tie-break guard has teeth --"
  d449d_mut="$TMP/status.449D.MUTANT.sh"
  if grep -q 'NG-FORMS-STABLE-SORT' "$SUT"; then
    sed 's/sort -s -t/sort -t/' "$SUT" > "$d449d_mut"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    d="$TMP/sat449d"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | ITER-bad-1 |" "| — | STRUCT-bad-form |" "| 2 | ITER-bad-2 |" "| 3 | 5 |" "| 4 | 3 |" "| 5 | 2 |"
    d449d_orig="$(bash "$SUT" "$d" 2>/dev/null)"
    d449d_mrep="$(bash "$d449d_mut" "$d" 2>/dev/null)"
    if grep -qF 'forms: ITER-bad-1,STRUCT-bad-form' <<<"$d449d_orig" && grep -qF 'forms: ITER-bad-1,ITER-bad-2' <<<"$d449d_mrep"; then
      ok "teeth-#449d: unstable-sort mutant reorders partial-WARN forms at tied sk → stable tie-break guard has teeth"
    else no "teeth-#449d: orig=[$(grep -i 'WARN\|saturation' <<<"$d449d_orig")] mut=[$(grep -i 'WARN\|saturation' <<<"$d449d_mrep")] — stable tie-break not load-bearing (THEATER)"; fi
  else no "teeth-#449d: NG-FORMS-STABLE-SORT sentinel not found in SUT"; fi

  # #449 teeth (e): #476 — wforms must source iter_window only; a structural row that sorts into the
  # last-w of all_sorted must NOT appear in wforms. Under the old code (wforms from $window), a reopen
  # tail row at sk=4 enters the all_sorted window and contributes REOPEN-form.
  # Fixture: iter1(ok,0), iter2(bad,BAD-ITER-form), iter3(ok,0), —(bad,REOPEN-form) (sk=4).
  # all_sorted last-3: iter2(bad),iter3(ok),struct(bad) — REOPEN-form would appear in old wforms.
  # After fix (wforms from iter_window): iter1,iter2,iter3 → only BAD-ITER-form.
  # Mutant: revert wforms to use $window → REOPEN-form re-appears → red.
  echo "-- teeth-#449e: wforms reverted to \$window → reopen form re-appears → guard has teeth (NG-WFORMS-ITER-ONLY) --"
  e449e_mut="$TMP/status.449E.MUTANT.sh"
  if grep -q 'NG-WFORMS-ITER-ONLY' "$SUT"; then
    # mutant: on the NG-WFORMS-ITER-ONLY line, swap "$iter_window" back to "$window"
    sed '/NG-WFORMS-ITER-ONLY/ s/"\$iter_window"/"$window"/' "$SUT" > "$e449e_mut"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    d="$TMP/sat449e"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | BAD-ITER-form |" "| 3 | 0 |" "| — | REOPEN-form |"
    e449e_orig="$(bash "$SUT" "$d" 2>/dev/null)"
    e449e_mrep="$(bash "$e449e_mut" "$d" 2>/dev/null)"
    if ! grep -qF 'REOPEN-form' <<<"$e449e_orig" && grep -qF 'REOPEN-form' <<<"$e449e_mrep"; then
      ok "teeth-#449e: wforms reverted to all_sorted → reopen-form re-appears → iter-only guard has teeth"
    else no "teeth-#449e: orig=[$(grep -i 'unreadable' <<<"$e449e_orig")] mut=[$(grep -i 'unreadable' <<<"$e449e_mrep")] — wforms iter-only guard not load-bearing (THEATER)"; fi
  else no "teeth-#449e: NG-WFORMS-ITER-ONLY sentinel not found in SUT"; fi

  # #476 reopen-tail two-part tooth: (a) REOPEN-form absent from wforms (iter-only fix),
  # (b) verdict count unchanged (badwin=iter_window, already correct post-#449).
  echo "-- teeth-#476: reopen-tail wforms reverted to \$window → REOPEN-form appears + verdict unchanged --"
  t476_mut="$TMP/status.476.MUTANT.sh"
  if grep -q 'NG-WFORMS-ITER-ONLY' "$SUT"; then
    sed '/NG-WFORMS-ITER-ONLY/ s/"\$iter_window"/"$window"/' "$SUT" > "$t476_mut"
    wforms476_line=""  # use sed-based mutant directly (no line split needed)
    if [ -s "$t476_mut" ]; then
      cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
      d="$TMP/sat476"; mkiter_h "$d" "| # | New gaps uncovered |" "| 1 | 0 |" "| 2 | BAD-ITER-form |" "| 3 | 0 |" "| — | REOPEN-form |"
      t476_orig="$(bash "$SUT" "$d" 2>/dev/null)"
      t476_mrep="$(bash "$t476_mut" "$d" 2>/dev/null)"
      # (a) orig: REOPEN-form absent; mutant: REOPEN-form present
      # (b) verdict count: both must show "1 of last 3 rows unrecognised" (badwin unchanged)
      t476_orig_sat="$(grep 'saturation' <<<"$t476_orig")"
      t476_mrep_sat="$(grep 'saturation' <<<"$t476_mrep")"
      if ! grep -qF 'REOPEN-form' <<<"$t476_orig_sat" && grep -qF 'REOPEN-form' <<<"$t476_mrep_sat" \
         && grep -qF 'unreadable window — 1 of last 3 rows unrecognised' <<<"$t476_orig_sat" \
         && grep -qF 'unreadable window — 1 of last 3 rows unrecognised' <<<"$t476_mrep_sat"; then
        ok "teeth-#476: wforms reverted to \$window → REOPEN-form re-appears; verdict count unchanged (guard has teeth)"
      else no "teeth-#476: orig=[${t476_orig_sat}] mut=[${t476_mrep_sat}] — reopen-tail iter-only not load-bearing (THEATER)"; fi
    else no "teeth-#476: NG-WFORMS-ITER-ONLY line not found by grep -n"; fi
  else no "teeth-#476: NG-WFORMS-ITER-ONLY sentinel not found in SUT"; fi


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

  # sync-bs teeth: re-sync d52 to verify cb branch.
  # After FIX 1 (generalized preamble carry-forward), block_scope is always carried via _extra_env_lines.
  # teeth-sync-bs-cb: neuter shared-global cb branch → cb drops.
  # teeth-sync-bs: neuter PREAMBLE-CARRY-FORWARD printf → unknown field (foo:bar) lost.
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  echo "-- teeth-sync-bs-cb: neuter shared-global cb branch; must reseed cb=0 while bs remains --"
  mu_cb="$TMP/status.SYNCCB.MUTANT.sh"
  sed 's/if \[ "\$_e_bs" = "shared-global" \]; then$/if false; then  # MUTANT-SYNCCB/' "$SUT" > "$mu_cb"
  if ! grep -q 'MUTANT-SYNCCB' "$mu_cb"; then
    no "teeth-sync-bs-cb: could not build mutant (_e_bs=shared-global branch not found — did SUT change?)"
  else
    bash "$mu_cb" "$d52" --sync-state >/dev/null 2>&1
    _cbm="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^covered_blocks:/{print $2; exit}' "$d52/RESEARCH-STATE-chihuahua.md")"
    [ "$_cbm" = "0" ] && ok "teeth-sync-bs-cb: neutered cb branch → cb=0 (focus-filtered) → test 52 cb is load-bearing" \
      || no "teeth-sync-bs-cb: mutant cb=$_cbm (want 0) — THEATER"; fi
  echo "-- teeth-sync-bs: neuter PREAMBLE-CARRY-FORWARD printf; unknown field foo:bar must vanish after re-sync --"
  mu_sbs="$TMP/status.SYNCBS.MUTANT.sh"
  sed 's/\[ -n "\$_extra_env_lines" \] && printf/: # MUTANT-PCF/' "$SUT" > "$mu_sbs"
  if ! grep -q 'MUTANT-PCF' "$mu_sbs"; then
    no "teeth-sync-bs: could not build mutant (PREAMBLE-CARRY-FORWARD printf pattern not found — did SUT change?)"
  else
    d_pcf="$TMP/pcf-tooth"; mkdir -p "$d_pcf"
    { printf '# T\n> intro\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nfoo: bar\n<!-- /research-state.v1 -->\n\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n'
    } > "$d_pcf/RESEARCH-STATE.md"
    bash "$mu_sbs" "$d_pcf" --sync-state >/dev/null 2>&1
    _pcfm="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^foo:/{$1=""; sub(/^[[:space:]]*/,""); print; exit}' "$d_pcf/RESEARCH-STATE.md")"
    [ -z "$_pcfm" ] && ok "teeth-sync-bs: neutered PREAMBLE-CARRY-FORWARD → foo:bar lost — carry-forward is load-bearing" \
      || no "teeth-sync-bs: mutant foo=$_pcfm (want empty) — THEATER"; fi

  # ---- ISSUE #126 teeth: whitespace-tolerant probe controls (sites 3 and 4) ----------------------
  # Site 3 (BS-SYNC-PROBE): neuter the block_scope fallback probe → indented+nospace form missed by _e_bs.
  # After FIX 1 (generalized carry-forward), block_scope: is always carried via _extra_env_lines regardless
  # of whether the probe fires. The probe's role is now ONLY setting _e_bs for the covered_blocks branch:
  # probe neutered → _e_bs="" → _sfpfx="chihuahua-" filter → niagara-bloque1.md not matched → cb=0.
  echo "-- teeth-sync-bs-probe: neuter BS-SYNC-PROBE; indented+nospace _e_bs missed → cb must drop to 0 --"
  mu_bsp="$TMP/status.BSPROBE.MUTANT.sh"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  if grep -q '# BS-SYNC-PROBE' "$SUT"; then
    sed '/# BS-SYNC-PROBE$/s/_raw_bs=.*/_raw_bs=""  # MUTANT-BSP: probe neutered/' "$SUT" > "$mu_bsp"
    # Fresh fixture to avoid reading the already-synced d53b state:
    d_bs_tooth="$TMP/bs-probe-tooth"; mkdir -p "$d_bs_tooth"
    printf 'x\n' > "$d_bs_tooth/niagara-bloque1.md"
    printf '# C\n> i\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 1\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n  block_scope:shared-global\n<!-- /research-state.v1 -->\n\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n' > "$d_bs_tooth/RESEARCH-STATE-chihuahua.md"
    bash "$mu_bsp" "$d_bs_tooth" --sync-state >/dev/null 2>&1
    # Probe neutered → _e_bs="" → _sfpfx="chihuahua-" branch → niagara-bloque1 not matched → cb=0.
    # Real SUT: probe fires → _e_bs=shared-global → global count = 1.
    _cbm_tooth="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^covered_blocks:/{print $2; exit}' "$d_bs_tooth/RESEARCH-STATE-chihuahua.md")"
    [ "$_cbm_tooth" = "0" ] \
      && ok "teeth-sync-bs-probe: neutered probe → cb=0 (focus-filtered, indented+nospace _e_bs missed) — BS-SYNC-PROBE is load-bearing" \
      || no "teeth-sync-bs-probe: mutant cb=$_cbm_tooth (want 0) — probe guard may not be the stopper (THEATER)"
  else no "teeth-sync-bs-probe: BS-SYNC-PROBE sentinel not found in SUT"; fi

  # Site 4 (UF-SYNC-PROBE): neuter the UF fallback probe → indented+nospace value must be zeroed.
  echo "-- teeth-sync-uf-probe: neuter UF-SYNC-PROBE; indented+nospace undocumented_findings must be zeroed --"
  mu_ufp="$TMP/status.UFPROBE.MUTANT.sh"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  if grep -q '# UF-SYNC-PROBE' "$SUT"; then
    sed '/# UF-SYNC-PROBE$/s/_raw_uf=.*/_raw_uf=""  # MUTANT-UFP: probe neutered/' "$SUT" > "$mu_ufp"
    # Fresh fixture to avoid reading the already-synced sync-uf-indented-nospace state:
    d_uf_tooth="$TMP/uf-probe-tooth"; mkdir -p "$d_uf_tooth"
    { echo '# T'; echo '> intro'; echo
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n  undocumented_findings:7\n<!-- /research-state.v1 -->\n'; echo
      echo '## Gap-backlog (prioritized)'; echo '| Priority | Gap | type | Status |'; echo '|---|---|---|---|'
      echo '## Blocked gaps'; echo '## Stop control'; echo '- **Open gaps — read-only investigable**: 0'
    } > "$d_uf_tooth/RESEARCH-STATE.md"
    bash "$mu_ufp" "$d_uf_tooth" --sync-state >/dev/null 2>&1
    _ufm_tooth="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^undocumented_findings:/{print $2; exit}' "$d_uf_tooth/RESEARCH-STATE.md")"
    [ "$_ufm_tooth" = "0" ] \
      && ok "teeth-sync-uf-probe: neutered probe → uf=0 for indented+nospace value — UF-SYNC-PROBE is load-bearing" \
      || no "teeth-sync-uf-probe: mutant uf=$_ufm_tooth (want 0) — probe guard may not be the stopper (THEATER)"
  else no "teeth-sync-uf-probe: UF-SYNC-PROBE sentinel not found in SUT"; fi

  # ---- ISSUE #143 teeth -----------------------------------------------------------------------
  # T54 targets copy-2 (verify-state.sh) via --next; T59-T62 target copy-1 (SUT::backlog_rows) via --sync-state.
  # teeth-T54: neuter BP-INVALID-PRIORITY-FAIL in verify-state.sh; laundered io=0 fixture must return STOP.
  echo "-- teeth-T54: neuter BP-INVALID-PRIORITY-FAIL in verify-state.sh; laundered fixture must return STOP --"
  if grep -q '# BP-INVALID-PRIORITY-FAIL' "$HERE/../verify-state.sh"; then
    sed 's/if \[ -n "\$_bparse_invalid" \]; then  # BP-INVALID-PRIORITY-FAIL/if false; then  # MUTANT-T54/' \
      "$HERE/../verify-state.sh" > "$TMP/verify-state.sh"; cp "$SUT" "$TMP/status.T54.MUTANT.sh"
    t54m="$(bash "$TMP/status.T54.MUTANT.sh" "$TMP/bp-laundered" --next 2>/dev/null)"
    [ "${t54m%%\ *}" = "STOP" ] && ok "teeth-T54: neutered BP-INVALID-PRIORITY-FAIL → STOP — guard is load-bearing" \
      || no "teeth-T54: mutant returned [$t54m] (want STOP)"
  else no "teeth-T54: BP-INVALID-PRIORITY-FAIL not found in verify-state.sh"; fi

  # T55: neuter BP-SYNC-INVALID-REFUSE; sync must exit 0 (proceeds) — refusal is load-bearing.
  echo "-- teeth-T55: neuter sync-state refusal; unknown-priority fixture must exit 0 (no longer refused) --"
  if grep -q '# BP-SYNC-INVALID-REFUSE' "$SUT"; then
    sed 's/if \[ -n "\$_brows_invalid" \]; then  # BP-SYNC-INVALID-REFUSE/if false; then  # MUTANT-T55/' \
      "$SUT" > "$TMP/status.T55.MUTANT.sh"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    d_t55m="$TMP/bp-syncrefuse-mutant"; mkbadprio "$d_t55m" "urgent" 1
    bash "$TMP/status.T55.MUTANT.sh" "$d_t55m" --sync-state >/dev/null 2>&1; t55m_rc=$?
    [ "$t55m_rc" = 0 ] \
      && ok "teeth-T55: neutered refusal → sync exits 0 (proceeds) — T55 refusal assertion has teeth" \
      || no "teeth-T55: mutant exits non-zero ($t55m_rc) — T55 not dependent on refusal check (THEATER)"
  else no "teeth-T55: BP-SYNC-INVALID-REFUSE not found in SUT"; fi

  # ---- Corpus vocabulary teeth: T59–T62 (skip forms in SUT::backlog_rows; oracle: --sync-state) ----
  # Copy-1 (SUT) skip guards: neutering makes --sync-state refuse (exit 1). T62 uses exit 0.
  cnt_occ() { awk -v n="$1" 'BEGIN{c=0}{s=$0;while((p=index(s,n))>0){c++;s=substr(s,p+length(n))}}END{print c}' "$2"; }
  printf 'no match\n'                         > "$TMP/cnt-proof.txt"; _cp0="$(cnt_occ "BPSKIP-X" "$TMP/cnt-proof.txt")"
  printf 'BPSKIP-X once\n'                    > "$TMP/cnt-proof.txt"; _cp1="$(cnt_occ "BPSKIP-X" "$TMP/cnt-proof.txt")"
  printf 'BPSKIP-X and BPSKIP-X same line\n' > "$TMP/cnt-proof.txt"; _cp2="$(cnt_occ "BPSKIP-X" "$TMP/cnt-proof.txt")"
  [ "$_cp0" = 0 ] && [ "$_cp1" = 1 ] && [ "$_cp2" = 2 ] && ok "cnt_occ: 0/1/2 same-line → 0/1/2 (self-proof)" || no "cnt_occ: proof failed (0=$_cp0 1=$_cp1 2=$_cp2)"
  chk_sut_bpskip_tooth() {
    local label="$1" marker="$2" sedexpr="$3" fixdir="$4" expect_rc="${5:-1}"
    local mutant="$TMP/status.${label}.MUTANT.sh"
    echo "-- ${label}: GREEN exit $((1 - expect_rc)) / RED exit ${expect_rc} (SUT::backlog_rows) --"
    local mc; mc="$(cnt_occ "$marker" "$SUT")"
    [ "$mc" = 1 ] || { no "${label}: anchor found $mc times in SUT (want exactly 1)"; return; }
    sed "$sedexpr" "$SUT" > "$mutant"
    local sut_h mutant_h
    sut_h="$(md5sum "$SUT" | cut -d' ' -f1)"; mutant_h="$(md5sum "$mutant" | cut -d' ' -f1)"
    [ "$sut_h" != "$mutant_h" ] || { no "${label}: sed no-op — mutant == SUT — recipe not applied"; return; }
    local green_rc; green_rc=$(( 1 - expect_rc ))
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    bash "$SUT" "$fixdir" --sync-state >/dev/null 2>&1; local got_g=$?
    [ "$got_g" = "$green_rc" ] && ok "${label}-green: real SUT exits ${green_rc} — baseline healthy" \
      || no "${label}-green: real SUT exits $got_g (want ${green_rc}) — SUT already broken"
    bash "$mutant" "$fixdir" --sync-state >/dev/null 2>&1; local got_r=$?
    [ "$got_r" = "$expect_rc" ] && ok "${label}-red: neutered exits ${expect_rc} — guard load-bearing" \
      || no "${label}-red: mutant exits $got_r (want ${expect_rc}) — THEATER"
  }
  chk_sut_bpskip_tooth "teeth-T59" "BPSKIP-STRIKETHROUGH" '/BPSKIP-STRIKETHROUGH/s/if (p~/if (0 ~/'    "$TMP/bp-strikethrough-status" 1
  chk_sut_bpskip_tooth "teeth-T60" "BPSKIP-QUALIFIER"     '/BPSKIP-QUALIFIER/s/if (base != p)/if (0)/' "$TMP/bp-qualifier-status"     1
  # teeth-T60-warn: remove BP-QUALIFIER-WARN line → T60-warn must go red (no WARN emitted).
  echo "-- teeth-T60-warn: remove WARN print; qualifier fixture must emit no WARN --"
  warn_mutant_t60w="$TMP/status.T60W.MUTANT.sh"
  sed '/# BP-QUALIFIER-WARN/d' "$SUT" > "$warn_mutant_t60w"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  warn60w="$(bash "$warn_mutant_t60w" "$TMP/bp-qualifier-status" --next 2>&1 >/dev/null)"
  if ! grep -qE 'WARN.*non-conforming qualifier' <<<"$warn60w"; then
    ok "teeth-T60-warn: WARN-removed mutant emits no WARN — qualifier WARN assertion has teeth"
  else
    no "teeth-T60-warn: mutant still emitted WARN — THEATER"
  fi
  chk_sut_bpskip_tooth "teeth-T61" "BPSKIP-EMDASH"        '/BPSKIP-EMDASH/s/if (p~/if (0 ~/'           "$TMP/bp-em-dash-status"       1
  # teeth-T62: accept-all-bases in SUT::backlog_rows; hight(x) fixture must allow --sync-state (exit 0).
  chk_sut_bpskip_tooth "teeth-T62" "BPSKIP-QUALIFIER" \
    '/# BP-QUALIFIER-WARN/s/if (base=="high" || base=="medium" || base=="low" || base=="deferred") {/if (1) {/' \
    "$TMP/bp-qualifier-invalid-status" 0
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"  # restore real verify-state.sh

  # issue #194 teeth: neuter the stopped-focus bypass (_any_real_stale=0 → =1) so that ANY
  # verify-state failure triggers STALE immediately — the stopped-stale-envelope fixture must
  # then return STALE, proving the bypass skip is load-bearing (not theater).
  echo "-- teeth-#194: neuter stopped-bypass; stopped-stale-envelope corpus must return STALE --"
  n194_mutant="$TMP/status.N194.MUTANT.sh"
  if grep -q '# N194-STOPPED-BYPASS' "$SUT"; then
    sed 's/_any_real_stale=0  # N194-STOPPED-BYPASS/_any_real_stale=1  # MUTANT-N194/' "$SUT" > "$n194_mutant"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    n194_got="$(bash "$n194_mutant" "$TMP/stopped-focus" --next 2>/dev/null)"
    case "$n194_got" in
      STALE\ *) ok "teeth-#194: neutered bypass → STALE on stopped-stale fixture — skip is load-bearing";;
      NEXT\ *)  no "teeth-#194: mutant returned NEXT — bypass skip not exercised (THEATER)";;
      *)        no "teeth-#194: mutant returned [$n194_got] (want STALE)";;
    esac
  else
    no "teeth-#194: N194-STOPPED-BYPASS sentinel not found in SUT"
  fi

  # issue #424b teeth-DONE-TOKENS: replace enumerated set with catch-all; frobnicate must stay silent (→ red).
  # Also proves closed/covered are ENUMERATED (direction a) and frobnicate still WARNs (direction b).
  echo "-- teeth-#424b-done-tokens: catch-all replaces enum; frobnicate must go silent → enum is load-bearing --"
  donetok_mutant="$TMP/status.DONETOK-MUTANT.sh"
  sed '/# DONE-TOKENS$/s/.*/        *) ;;  # MUTANT-DONETOK: catch-all (enumerated done-set removed)/' "$SUT" > "$donetok_mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  if ! grep -q 'MUTANT-DONETOK' "$donetok_mutant"; then
    no "teeth-#424b-done-tokens: could not build mutant (DONE-TOKENS sentinel not found in SUT — did SUT change?)"
  else
    d_dtfrob="$TMP/done-tok-frob"; mkdir -p "$d_dtfrob"
    { printf '# T\n> intro\n'
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
      printf '\n## Gap-backlog (prioritized)\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
      printf '| high | frob-gap | web | frobnicate |\n\n'
      printf '## Blocked gaps\n\n## Stop control\n\n- **Open gaps — read-only investigable**: 0\n'
    } > "$d_dtfrob/RESEARCH-STATE.md"
    # direction (a): original on closed-status fixture → silent (done-set recognised)
    d_dtclosed="$TMP/done-tok-closed"; mkdir -p "$d_dtclosed"
    { printf '# T\n> intro\n'
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
      printf '\n## Gap-backlog (prioritized)\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
      printf '| high | g-closed | web | closed |\n\n'
      printf '## Blocked gaps\n\n## Stop control\n\n- **Open gaps — read-only investigable**: 0\n'
    } > "$d_dtclosed/RESEARCH-STATE.md"
    orig_warn_closed="$(bash "$SUT" "$d_dtclosed" --sync-state 2>&1 >/dev/null)"
    # direction (b): original on frobnicate → WARN; mutant (catch-all) on frobnicate → silent
    orig_warn_frob="$(bash "$SUT" "$d_dtfrob" --sync-state 2>&1 >/dev/null)"
    mut_warn_frob="$(bash "$donetok_mutant" "$d_dtfrob" --sync-state 2>&1 >/dev/null)"
    ok_a=0; ok_b=0; ok_c=0
    ! grep -qi 'unrecognised' <<<"$orig_warn_closed" && ok_a=1
    grep -qi 'unrecognised' <<<"$orig_warn_frob" && ok_b=1
    ! grep -qi 'unrecognised' <<<"$mut_warn_frob" && ok_c=1
    if [ "$ok_a$ok_b$ok_c" = "111" ]; then
      ok "teeth-#424b-done-tokens: closed is silent (a), frobnicate WARNs (b), catch-all silences frobnicate (c) — enum is load-bearing"
    else
      no "teeth-#424b-done-tokens: closed_silent=$ok_a frob_warns=$ok_b catchall_silent=$ok_c (want 1 1 1)"
    fi
  fi

  # issue #424b teeth-STRICKEN-GAP-SKIP: neuter the ~~ gap-name skip; unrecognised-status stricken gap must WARN.
  echo "-- teeth-#424b-stricken-gap: neuter STRICKEN-GAP-SKIP; stricken-gap+novel-status must WARN --"
  stricken_mutant="$TMP/status.STRICKEN-MUTANT.sh"
  sed '/# STRICKEN-GAP-SKIP$/s/.*/    : # MUTANT-STRICKEN: struck-through skip neutered/' "$SUT" > "$stricken_mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  if ! grep -q 'MUTANT-STRICKEN' "$stricken_mutant"; then
    no "teeth-#424b-stricken-gap: could not build mutant (STRICKEN-GAP-SKIP sentinel not found in SUT — did SUT change?)"
  else
    d_stricken="$TMP/stricken-gap-tooth"; mkdir -p "$d_stricken"
    { printf '# T\n> intro\n'
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
      printf '\n## Gap-backlog (prioritized)\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
      printf '| high | ~~resolved-gap~~ | web | frobnicate |\n\n'
      printf '## Blocked gaps\n\n## Stop control\n\n- **Open gaps — read-only investigable**: 0\n'
    } > "$d_stricken/RESEARCH-STATE.md"
    orig_warn_stricken="$(bash "$SUT" "$d_stricken" --sync-state 2>&1 >/dev/null)"
    mut_warn_stricken="$(bash "$stricken_mutant" "$d_stricken" --sync-state 2>&1 >/dev/null)"
    if ! grep -qi 'unrecognised' <<<"$orig_warn_stricken" && grep -qi 'unrecognised' <<<"$mut_warn_stricken"; then
      ok "teeth-#424b-stricken-gap: original silent on stricken gap, mutant WARNs — STRICKEN-GAP-SKIP is load-bearing"
    else
      no "teeth-#424b-stricken-gap: orig_warns=$(grep -c 'unrecognised' <<<"$orig_warn_stricken") mut_warns=$(grep -c 'unrecognised' <<<"$mut_warn_stricken") — skip may not be stopper"
    fi
  fi

  # issue #424b teeth-BOLDFIX: revert closing-** strip to suffix-only; **pending** (note) must drop.
  echo "-- teeth-#424b-boldfix: revert closing-** strip (suffix-only); **pending** (note) must not count investigable --"
  boldfix_mutant="$TMP/status.BOLDFIX-MUTANT.sh"
  # Revert: change lead="${lead/\*\*/}" to lead="${lead%\*\*}" on the BOLD-STRIP line
  sed '/# BOLD-STRIP$/s/.*/    lead="${st#\\*\\*}"; lead="${lead%\\*\\*}"  # MUTANT-BOLDFIX: suffix-only strip (reverted)/' "$SUT" > "$boldfix_mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  if ! grep -q 'MUTANT-BOLDFIX' "$boldfix_mutant"; then
    no "teeth-#424b-boldfix: could not build mutant (BOLD-STRIP sentinel not found in SUT — did SUT change?)"
  else
    d_boldfix="$TMP/boldfix-tooth"; mkdir -p "$d_boldfix"
    { printf '# T\n> intro\n'
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
      printf '\n## Gap-backlog (prioritized)\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
      printf '| high | decorated-gap | web | **pending** (uncovered by B7) |\n\n'
      printf '## Blocked gaps\n\n## Stop control\n\n- **Open gaps — read-only investigable**: 0\n'
    } > "$d_boldfix/RESEARCH-STATE.md"
    bash "$boldfix_mutant" "$d_boldfix" --sync-state >/dev/null 2>&1
    _io_boldfix="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^investigable_open:/{print $2; exit}' "$d_boldfix/RESEARCH-STATE.md")"
    [ "$_io_boldfix" = "0" ] \
      && ok "teeth-#424b-boldfix: suffix-only mutant → io=0 for **pending** (note) — closing-** fix is load-bearing" \
      || no "teeth-#424b-boldfix: mutant io=$_io_boldfix (want 0) — closing-** fix may not be stopper (THEATER)"
  fi

  # issue #424 teeth-BOLD-STRIP: neuter ** strip in count_investigable; **pending** must stay dropped.
  echo "-- teeth-#424-bold-strip: neuter BOLD-STRIP sentinel; **pending** must not count investigable --"
  bold_mutant="$TMP/status.BOLD-MUTANT.sh"
  sed '/# BOLD-STRIP$/s/.*/    lead="$st"  # MUTANT-BOLD: strip neutered/' "$SUT" > "$bold_mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  if ! grep -q 'MUTANT-BOLD' "$bold_mutant"; then
    no "teeth-#424-bold-strip: could not build mutant (BOLD-STRIP sentinel not found in SUT — did SUT change?)"
  else
    d_boldtooth="$TMP/bold-strip-tooth"; mkdir -p "$d_boldtooth"
    { printf '# T\n> intro\n'
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
      printf '\n## Gap-backlog (prioritized)\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
      printf '| high | bold-gap | web | **pending** |\n\n'
      printf '## Blocked gaps\n\n## Stop control\n\n- **Open gaps — read-only investigable**: 0\n'
    } > "$d_boldtooth/RESEARCH-STATE.md"
    bash "$bold_mutant" "$d_boldtooth" --sync-state >/dev/null 2>&1
    _io_boldtooth="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^investigable_open:/{print $2; exit}' "$d_boldtooth/RESEARCH-STATE.md")"
    [ "$_io_boldtooth" = "0" ] \
      && ok "teeth-#424-bold-strip: neutered strip → io=0 for **pending** row — BOLD-STRIP is load-bearing" \
      || no "teeth-#424-bold-strip: mutant io=$_io_boldtooth (want 0) — strip may not be stopper (THEATER)"
  fi

  # issue #424 teeth-UNRECOG-WARN: neutering the WARN silences 'open'-token stderr output.
  echo "-- teeth-#424-unrecog-warn: neuter UNRECOG-STATUS-WARN; 'open'-token must stop WARNing --"
  unrecog_mutant="$TMP/status.UNRECOG-MUTANT.sh"
  sed 's|>&2 ;;  # UNRECOG-STATUS-WARN|>/dev/null ;;  # MUTANT-UNRECOG: WARN silenced|' "$SUT" > "$unrecog_mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  if ! grep -q 'MUTANT-UNRECOG' "$unrecog_mutant"; then
    no "teeth-#424-unrecog-warn: could not build mutant (UNRECOG-STATUS-WARN sentinel not found in SUT — did SUT change?)"
  else
    d_urecogtooth="$TMP/unrecog-warn-tooth"; mkdir -p "$d_urecogtooth"
    { printf '# T\n> intro\n'
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
      printf '\n## Gap-backlog (prioritized)\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
      printf '| high | open-gap | web | open |\n\n'
      printf '## Blocked gaps\n\n## Stop control\n\n- **Open gaps — read-only investigable**: 0\n'
    } > "$d_urecogtooth/RESEARCH-STATE.md"
    orig_warn_ur="$(bash "$SUT" "$d_urecogtooth" --sync-state 2>&1 >/dev/null)"
    mut_warn_ur="$(bash "$unrecog_mutant" "$d_urecogtooth" --sync-state 2>&1 >/dev/null)"
    if grep -qi 'unrecognised' <<<"$orig_warn_ur" && ! grep -qi 'unrecognised' <<<"$mut_warn_ur"; then
      ok "teeth-#424-unrecog-warn: original WARNs on 'open' token, mutant stays silent — WARN is load-bearing"
    else
      no "teeth-#424-unrecog-warn: orig warns=$(grep -c 'unrecognised' <<<"$orig_warn_ur") mut=$(grep -c 'unrecognised' <<<"$mut_warn_ur") — WARN not load-bearing"
    fi
  fi

  # near-miss WARN teeth: neuter the NM-WARN branch → near-miss fixture must stop WARNing.
  echo "-- teeth-NM: neuter near-miss WARN (NM-WARN tag); '## Gap backlog' fixture must stop WARNing --"
  nm_mutant="$TMP/status.NM-MUTANT.sh"
  sed 's|> "/dev/stderr" }  # NM-WARN|> "/dev/null" }  # MUTANT-NM: near-miss WARN neutered|' "$SUT" > "$nm_mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  if ! grep -q 'MUTANT-NM: near-miss WARN neutered' "$nm_mutant"; then
    no "teeth-NM: could not build mutant (NM-WARN tag not found in SUT — did the SUT change?)"
  else
    nm_warn_orig="$(bash "$SUT" "$TMP/nm-space" --next 2>&1 >/dev/null)"
    nm_warn_mut="$(bash "$nm_mutant" "$TMP/nm-space" --next 2>&1 >/dev/null)"
    if grep -qi 'near-miss' <<<"$nm_warn_orig" && ! grep -qi 'near-miss' <<<"$nm_warn_mut"; then
      ok "teeth-NM: original WARNs on '## Gap backlog', mutant stays silent → near-miss WARN has teeth"
    else
      no "teeth-NM: orig warns=[$(grep -ci 'near-miss' <<<"$nm_warn_orig")] mut warns=[$(grep -ci 'near-miss' <<<"$nm_warn_mut")] — WARN not load-bearing"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
