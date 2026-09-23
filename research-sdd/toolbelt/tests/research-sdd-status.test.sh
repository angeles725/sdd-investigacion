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
    echo "- **Open gaps — read-only investigable**: $io"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 1"
  } > "$dir/RESEARCH-STATE.md"
}
next() { bash "$SUT" "$1" --next 2>/dev/null; }
expect_next() { local got; got="$(next "$1")"; [ "$got" = "$2" ] && ok "$3" || no "$3 — got [$got] want [$2]"; }
# env_lines <covered> <gc> <kg> <io> <req> <bo> — the research-state.v1 envelope, for raw-printf fixtures
# that don't use mkstate (which seeds its own). A valid envelope is required or --next returns STALE on the gate.
env_lines(){ printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: %s\ngaps_closed: %s\nknown_gaps: %s\ninvestigable_open: %s\nrequires_execution_open: %s\nblocked_open: %s\n<!-- /research-state.v1 -->\n' "$@"; }

# mk_kit <kit_dir> <stub_mode> — create a hermetic SUT copy with a stub reconcile-issues.sh.
# Modes: untracked (returns one ^untracked: line), tracked (returns ^tracked:), degraded (exit 1).
# The kit resolves $here to <kit_dir>, so the stub is picked up instead of the real script.
# lib/retro-status.sh is included so the PERF pre-filter runs in all kit-based tests; retros
# without an applied/dismissed marker pass through normally, so existing tests are unaffected.
#
# Wrapper design: research-sdd-status.sh is a thin wrapper that prepends $kdir/bin to PATH and
# execs the real SUT (_sut.sh). This injects a hermetic stub gh so the batch prefetch in
# issues_due_gate() does not hit the real GitHub or fail when gh is absent from the system PATH.
# Stub gh: auth→exit 0, issue list→exit 0 (empty bodies). All reconcile stubs ignore --issues-cache
# args and return their fixed output, so existing hermetic kit tests are unaffected.
mk_kit() {
  local kdir="$1" mode="$2"
  mkdir -p "$kdir/lib" "$kdir/bin"
  # Stub gh for the batch prefetch in issues_due_gate (never hits real GitHub)
  printf '#!/usr/bin/env bash\ncase "$1" in auth) exit 0 ;; issue) exit 0 ;; *) exit 1 ;; esac\n' \
    > "$kdir/bin/gh"
  chmod +x "$kdir/bin/gh"
  # Wrapper: injects $kdir/bin into PATH, then execs the real SUT as _sut.sh
  cat > "$kdir/research-sdd-status.sh" <<MKKIT_WRAPPER_EOF
#!/usr/bin/env bash
export PATH="$kdir/bin:\$PATH"
exec bash "$kdir/_sut.sh" "\$@"
MKKIT_WRAPPER_EOF
  chmod +x "$kdir/research-sdd-status.sh"
  cp "$SUT" "$kdir/_sut.sh"
  cp "$HERE/../verify-state.sh" "$kdir/verify-state.sh"
  cp "$HERE/../lib/focus-prefix.sh" "$kdir/lib/focus-prefix.sh"
  cp "$HERE/../lib/state-files.sh" "$kdir/lib/state-files.sh"
  cp "$HERE/../lib/block-files.sh" "$kdir/lib/block-files.sh"
  cp "$HERE/../lib/retro-status.sh" "$kdir/lib/retro-status.sh"
  case "$mode" in
    untracked)
      printf '#!/usr/bin/env bash\nprintf "untracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$kdir/reconcile-issues.sh" ;;
    tracked)
      printf '#!/usr/bin/env bash\nprintf "tracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$kdir/reconcile-issues.sh" ;;
    degraded)
      printf '#!/usr/bin/env bash\nprintf "degraded: gh not authenticated\\n" >&2\nexit 1\n' \
        > "$kdir/reconcile-issues.sh" ;;
    timeout_sleep_3)
      # Stub sleeps 3s — longer than any _IDG_RECONCILE_TIMEOUT_SECS=1 test timeout; used for R4-SERIAL.
      printf '#!/usr/bin/env bash\nsleep 3\nprintf "untracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$kdir/reconcile-issues.sh" ;;
    exit_1_empty)
      # Stub exits 1 with no stderr output — operational failure, not timeout (124) or degraded gh.
      # Used for T-IDG-E / teeth-IDG-opfail to verify any non-zero exit marks coverage unverified.
      printf '#!/usr/bin/env bash\nexit 1\n' \
        > "$kdir/reconcile-issues.sh" ;;
    exit_137)
      # Stub exits 137 (SIGKILL class) — used for T-IDG-F to verify signal-kill exit is also unverified.
      printf '#!/usr/bin/env bash\nexit 137\n' \
        > "$kdir/reconcile-issues.sh" ;;
    recording_untracked)
      # Stub logs the retro path (last positional arg) to $_IDG_RECORD_LOG; returns one untracked line.
      # Used for T-IDG-PAYLOAD: count stub calls to verify early-exit stops probing after first retro.
      # Uses ${@: -1} (last arg) because the gate now passes --issues-cache <file> before the retro path.
      printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' "${@: -1}" >> "${_IDG_RECORD_LOG:-/dev/null}"\nprintf "untracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$kdir/reconcile-issues.sh" ;;
    cache_untracked_reverify_tracked)
      # Returns "untracked" when called WITH --issues-cache (simulates batch cache saying untracked),
      # returns "tracked" when called WITHOUT --issues-cache (per-retro re-verify finds it tracked).
      # Used for T-IDG-BATCH-FALSE-NEG: batch false-negative (exit-0 truncated/empty body); the
      # re-verify via narrowed per-retro gh probe finds the issue → gate must NOT emit false ISSUES-DUE.
      printf '#!/usr/bin/env bash\n_has_cache=0\nfor _a in "$@"; do [ "$_a" = "--issues-cache" ] && _has_cache=1; done\nif [ "$_has_cache" = "1" ]; then\n  printf "untracked: row 1 delta-foo\\n"\nelse\n  printf "tracked: row 1 delta-foo\\n"\nfi\n' \
        > "$kdir/reconcile-issues.sh" ;;
  esac
  chmod +x "$kdir/reconcile-issues.sh"
}

# mk_kit_real_reconcile <kit_dir> <gh_stub_dir> — kit with REAL reconcile-issues.sh and all its libs.
# A stub gh is placed in gh_stub_dir: auth status→exit 0, issue list→empty result (untracked).
# Used for R3-STUB-ONLY parser↔producer contract test.
mk_kit_real_reconcile() {
  local kdir="$1" ghdir="$2"
  mkdir -p "$kdir/lib"
  cp "$SUT" "$kdir/research-sdd-status.sh"
  cp "$HERE/../verify-state.sh" "$kdir/verify-state.sh"
  cp "$HERE/../reconcile-issues.sh" "$kdir/reconcile-issues.sh"
  cp "$HERE/../lib/focus-prefix.sh" "$kdir/lib/focus-prefix.sh"
  cp "$HERE/../lib/state-files.sh" "$kdir/lib/state-files.sh"
  cp "$HERE/../lib/block-files.sh" "$kdir/lib/block-files.sh"
  cp "$HERE/../lib/retro-status.sh" "$kdir/lib/retro-status.sh"
  cp "$HERE/../lib/retro-grammar.sh" "$kdir/lib/retro-grammar.sh"
  cp "$HERE/../lib/target-paths.sh" "$kdir/lib/target-paths.sh"
  # Stub gh: auth status→ exit 0; issue list → empty (no issues → delta is untracked)
  mkdir -p "$ghdir"
  printf '#!/usr/bin/env bash\ncase "$1" in auth) exit 0 ;; issue) printf "" ; exit 0 ;; *) exit 1 ;; esac\n' \
    > "$ghdir/gh"
  chmod +x "$ghdir/gh"
}

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
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d/RESEARCH-STATE.md"
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
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
expect_next "$d" "NEXT | medium | free thing" "plain-hyphen blocked entry excludes its gap"

# 15 — en-dash blocked entry also excludes its gap
d="$TMP/endashblock"; mkdir -p "$d"
{ echo "# T"; echo; env_lines 0 0 0 1 0 1; echo; echo "## Gap-backlog"; echo
  echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | blocked thing | web | pending |"; echo "| medium | free thing | web | pending |"; echo
  echo "## Blocked gaps"; echo "- blocked thing – needs: hardware"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 1"; } > "$d/RESEARCH-STATE.md"
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
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d/RESEARCH-STATE.md"
expect_next "$d" "STOP | read-only-investigable exhausted (0)" "empty eligible backlog → STOP (derived=0, not stale prose)"

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
  printf '%s\n' '- **Open gaps — read-only investigable**: 0'
} > "$d/RESEARCH-STATE-apple.md"
{ printf '# Mango — Research State\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n'
  printf '| high | open mango gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
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
  printf '%s\n' '- **Open gaps — read-only investigable**: 0'
} > "$d/alpha/RESEARCH-STATE.md"
{ printf '# Beta — Research State\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n'
  printf '| high | open beta gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
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
  printf '%s\n' '- **Open gaps — read-only investigable**: 0'
} > "$d51/alpha/RESEARCH-STATE.md"
{ printf '# Beta — Research State\n> intro\n'
  printf '## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n'
  printf '| high | open beta gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
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
# as 0 (unverifiable) when the focus has no attributed B<n> ids — NOT the corpus-wide file count.
# Corpus: RESEARCH-STATE-chihuahua.md declares block_scope: shared-global; 3 niagara-bloque* files
# on disk; no ## Covered blocks or ## Iteration history with B<n> ids → count_attributed_sg returns 0.
# Bug (pre-fix): falls back to corpus-wide count (3 files) → seeds cb=3 — wrong; not attributed.
# Fix (SG-ZERO-UNVERIFIABLE): seed cb=0 + loud stderr WARN; verify-state reports INFO unverifiable.
d52="$TMP/sync-bs"; mkdir -p "$d52"
printf 'x\n' > "$d52/niagara-bloque1.md"; printf 'x\n' > "$d52/niagara-bloque2.md"; printf 'x\n' > "$d52/niagara-bloque3.md"
printf '# C\n> i\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 3\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope: shared-global\n<!-- /research-state.v1 -->\n\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n' \
  > "$d52/RESEARCH-STATE-chihuahua.md"
_sync52_stderr="$(bash "$SUT" "$d52" --sync-state 2>&1 >/dev/null)"
_bs52="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^block_scope:/{print $2; exit}' "$d52/RESEARCH-STATE-chihuahua.md")"
_cb52="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^covered_blocks:/{print $2; exit}' "$d52/RESEARCH-STATE-chihuahua.md")"
[ "$_bs52" = "shared-global" ] && [ "$_cb52" = "0" ] \
  && ok "sync-bs: block_scope: shared-global preserved; covered_blocks=0 (unverifiable, no attributed ids)" \
  || no "sync-bs: bs=$_bs52(want shared-global) cb=$_cb52(want 0) — corpus-wide fallback still running or block_scope lost"
# 52b — sync-bs must emit a loud stderr WARN when seeding 0 (anti-silent-zero §7)
echo "$_sync52_stderr" | grep -qE 'WARN.*no attributed block ids|no attributed block ids.*WARN' \
  && ok "sync-bs-warn: --sync-state emits WARN on stderr when seeding covered_blocks=0 (no attributed ids)" \
  || no "sync-bs-warn: no WARN emitted on stderr — silent zero (want: WARN about no attributed block ids)"
# 53 — sync-bs-e2e: declare → sync → verify-state must exit 0 AND report INFO unverifiable + cb=0
# covered_blocks=0 is unverifiable (no attributed ids), not a false-pass. verify-state must exit 0
# with INFO (not FAIL) and the envelope line must show covered_blocks=0/<ondisk>.
_vs53out="$(bash "$HERE/../verify-state.sh" "$d52" 2>/dev/null)"; _vs53rc=$?
if [ "$_vs53rc" = "0" ] \
    && grep -qE 'covered_blocks=0/' <<<"$_vs53out" \
    && grep -qF 'INFO' <<<"$_vs53out"; then
  ok "sync-bs-e2e: verify-state exits 0 + INFO unverifiable + covered_blocks=0/<ondisk> after sync"
else no "sync-bs-e2e: rc=$_vs53rc :: $(grep 'envelope' <<<"$_vs53out" | head -1) (want rc=0, cb=0/<N>, INFO)"; fi

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

# T-905-SG-ATTR: shared-global focus with attributed ids (B1, B2 in ## Covered blocks) over a corpus
# with more on-disk files (5). --sync-state must seed cb=2 (attributed), not 5 (corpus-wide).
# verify-state CHECK A must pass: e_covered=2 == _sg_attributed=2.
d_905="$TMP/t905-sg-attr"; mkdir -p "$d_905"
printf 'x\n' > "$d_905/focus-bloque1.md"
printf 'x\n' > "$d_905/focus-bloque2.md"
printf 'x\n' > "$d_905/focus-bloque3.md"
printf 'x\n' > "$d_905/focus-bloque4.md"
printf 'x\n' > "$d_905/focus-bloque5.md"
{ printf '# T905\n> intro\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 99\n'
  printf 'gaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\n'
  printf 'blocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope: shared-global\n'
  printf '<!-- /research-state.v1 -->\n'
  printf '\n## Covered blocks\nB1, B2\n'
  printf '\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n'
  printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d_905/RESEARCH-STATE-focus.md"
bash "$SUT" "$d_905" --sync-state >/dev/null 2>&1
_t905_cb="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^covered_blocks:/{print $2; exit}' "$d_905/RESEARCH-STATE-focus.md")"
[ "$_t905_cb" = "2" ] \
  && ok "T-905-SG-ATTR: --sync-state seeds cb=2 (B1,B2 attributed; 5 corpus files)" \
  || no "T-905-SG-ATTR: cb=$_t905_cb (want 2) — attributed count not used or wrong count"
_t905_vs_out="$(bash "$HERE/../verify-state.sh" "$d_905" 2>&1)"
if echo "$_t905_vs_out" | grep -qF 'FAIL'; then
  no "T-905-SG-ATTR: verify-state FAILs with attributed covered_blocks=2 (want CHECK A pass)"
else
  ok "T-905-SG-ATTR: verify-state passes CHECK A (covered_blocks=2 == 2 attributed)"
fi

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

# ==================== T-SS2 — FOCUSES.md declared stopped/paused skip ====================
# A focus declared paused in FOCUSES.md with d_inv>0 must be SKIPPED by --next even though
# it still has open investigable gaps; --next must return NEXT from an active sibling.
# RED before fix: the paused focus slug sorts before the active one (aaa < zzz), so the
# current loop hands it out first — wrong. After fix: FOCUSES.md check skips it.
d_ss2="$TMP/ss2-paused"; mkdir -p "$d_ss2"
# Focus "aaa-paused": d_inv=1 (one pending gap), correct envelope (investigable_open=1)
{ printf '# Paused Focus\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | paused-open-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
} > "$d_ss2/RESEARCH-STATE-aaa-paused.md"
# Focus "zzz-active": d_inv=1 (one pending gap), correct envelope
{ printf '# Active Focus\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | active-pending-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
} > "$d_ss2/RESEARCH-STATE-zzz-active.md"
# FOCUSES.md: aaa-paused is paused (d_inv>0 — the key test), zzz-active is active
{ printf '# Focus Registry\n\n'
  printf '| Focus | Status | State file | Block prefix |\n'
  printf '|---|---|---|---|\n'
  printf '| aaa-paused | paused (14 open gaps) | RESEARCH-STATE-aaa-paused.md | ap- |\n'
  printf '| zzz-active | active | RESEARCH-STATE-zzz-active.md | za- |\n'
} > "$d_ss2/FOCUSES.md"
# T-SS2a: paused focus is skipped; active sibling is returned
expect_next "$d_ss2" "NEXT | high | active-pending-gap" \
  "T-SS2a: paused focus with d_inv>0 in FOCUSES.md is skipped — active sibling returned"

# T-SS2b: when ALL focuses are paused/stopped (none active) → STOP
d_ss2b="$TMP/ss2-all-paused"; mkdir -p "$d_ss2b"
{ printf '# Alpha\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | alpha-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
} > "$d_ss2b/RESEARCH-STATE-alpha.md"
{ printf '# Beta\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | beta-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
} > "$d_ss2b/RESEARCH-STATE-beta.md"
{ printf '# Focus Registry\n\n| Focus | Status | State file | Block prefix |\n|---|---|---|---|\n'
  printf '| alpha | stopped (gaps post-stop) | RESEARCH-STATE-alpha.md | a- |\n'
  printf '| beta  | paused (budget cap) | RESEARCH-STATE-beta.md | b- |\n'
} > "$d_ss2b/FOCUSES.md"
expect_next "$d_ss2b" "STOP | no active focus (2 declared stopped/paused in FOCUSES.md with open gaps)" \
  "T-SS2b: all focuses declared stopped/paused in FOCUSES.md with open gaps → descriptive STOP"

# T-SS2c: FOCUSES.md absent → fall back to existing behavior (no skip)
d_ss2c="$TMP/ss2-no-focuses"; mkdir -p "$d_ss2c"
{ printf '# Active\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | fallback-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
} > "$d_ss2c/RESEARCH-STATE.md"
# No FOCUSES.md — must NOT skip anything
expect_next "$d_ss2c" "NEXT | high | fallback-gap" \
  "T-SS2c: FOCUSES.md absent → no skip, existing behavior preserved"

# T-SS2d: frozen multi-corpus fixture — niagara format (Estado, bold focus, backtick state-file) AND
# HotelHilton format (half-bold status **token** (...), link-wrapped state-file [f.md](f.md)).
# RED-before-fix: paused focus (aaa) sorts BEFORE active (zzz) so the base SUT returns niafoo-gap;
# new SUT skips paused + hilton-stopped + base, returning niabar-gap.  D9 fix.
d_ss2d="$TMP/ss2-niagara-fmt"; mkdir -p "$d_ss2d"
# Focus aaa-niafoo-paused (sorts FIRST): bold focus, bold+parens status, backtick state-file (niagara form)
{ printf '# Focus aaa-niafoo-paused (niagara: bold focus, bold+parens status, backtick state-file)\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | niafoo-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
} > "$d_ss2d/RESEARCH-STATE-aaa-niafoo-paused.md"
# Focus zzz-hilton-stopped (sorts SECOND): half-bold status, link-wrapped state-file (HotelHilton form)
{ printf '# Focus zzz-hilton-stopped (hilton: half-bold **stopped** (...), link state-file)\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | hilton-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
} > "$d_ss2d/RESEARCH-STATE-zzz-hilton-stopped.md"
# Focus zzz-niabar-active (sorts THIRD): bare focus, bare status, backtick state-file — the NEXT source
{ printf '# Focus zzz-niabar-active (bare tokens, active)\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | niabar-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
} > "$d_ss2d/RESEARCH-STATE-zzz-niabar-active.md"
# Base focus: RESEARCH-STATE.md (no slug suffix — stopped, 0 open gaps, sfcol match)
{ printf '# Base focus: sfcol match only\n> intro\n'
  env_lines 0 0 0 0 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 0'
} > "$d_ss2d/RESEARCH-STATE.md"
# FOCUSES.md: niagara-format header (Estado), mixes niagara + HotelHilton cell forms
{ printf '# Corpus Index\n\n'
  printf '| Focus | Estado | RESEARCH-STATE | Ambito |\n'
  printf '|---|---|---|---|\n'
  # niagara form: bold focus, bold+parens status, backtick state-file
  printf '| **aaa-niafoo-paused** | **paused (3 open; budget cap)** | `RESEARCH-STATE-aaa-niafoo-paused.md` | paused focus |\n'
  # HotelHilton form: bare focus, half-bold status **token** (...), link-wrapped state-file — D8 fix
  printf '| zzz-hilton-stopped | **stopped** (complete 3/3) | [RESEARCH-STATE-zzz-hilton-stopped.md](RESEARCH-STATE-zzz-hilton-stopped.md) | hilton stopped |\n'
  # bare tokens, backtick state-file
  printf '| zzz-niabar-active | active | `RESEARCH-STATE-zzz-niabar-active.md` | active focus |\n'
  # (base) row: state-file RESEARCH-STATE.md — matches via sfcol only
  printf '| (base) | stopped | `RESEARCH-STATE.md` | base framework |\n'
} > "$d_ss2d/FOCUSES.md"
# T-SS2d: skips aaa-niafoo-paused (niagara bold), zzz-hilton-stopped (hilton half-bold+link), base (sfcol)
# RED-before-fix: paused aaa sorts first → base returns niafoo-gap; new returns niabar-gap
expect_next "$d_ss2d" "NEXT | high | niabar-gap" \
  "T-SS2d: niagara+HotelHilton FOCUSES.md forms — bold/half-bold/link/sfcol skip; active returned"

# T-SS2d-sfcol: state-file-column match path — (base) RESEARCH-STATE.md, stopped, single focus with open gap.
# base SUT → NEXT | high | base-gap; new SUT → STOP (sfcol match detected stopped).
d_ss2d_sfcol="$TMP/ss2-sfcol-match"; mkdir -p "$d_ss2d_sfcol"
{ printf '# Base focus (sfcol match only)\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | base-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
} > "$d_ss2d_sfcol/RESEARCH-STATE.md"
{ printf '| Focus | Estado | RESEARCH-STATE |\n|---|---|---|\n'
  printf '| (base) | stopped | `RESEARCH-STATE.md` |\n'
} > "$d_ss2d_sfcol/FOCUSES.md"
expect_next "$d_ss2d_sfcol" \
  "STOP | no active focus (1 declared stopped/paused in FOCUSES.md with open gaps)" \
  "T-SS2d-sfcol: (base) row matched via state-file column — stopped, single focus → STOP reason"

# T-SS2e: STALE-bypass respects FOCUSES.md (D5 path: STALE gate + FOCUSES.md skip interact correctly).
# Scenario: verify-state fails because a paused focus has a mismatched envelope; but FOCUSES.md
# declares that focus as paused, so the STALE bypass treats it as bypassed → _any_real_stale=0 →
# fall through → NEXT from the active sibling.
d_ss2e="$TMP/ss2-stale-bypass"; mkdir -p "$d_ss2e"
# Focus "ss2e-paused": envelope says investigable_open=0 but backlog has 1 pending gap → verify-state FAIL.
# Also declared paused in FOCUSES.md → STALE bypass should skip it.
{ printf '# Paused (stale envelope)\n> intro\n'
  env_lines 0 0 0 0 0 0   # envelope: investigable_open=0 (mismatches backlog → verify-state FAIL)
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | paused-stale-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'  # contradicts envelope
} > "$d_ss2e/RESEARCH-STATE-ss2e-paused.md"
# Focus "ss2e-active": valid envelope, 1 pending gap → NEXT source
{ printf '# Active\n> intro\n'
  env_lines 0 0 0 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | active-stale-sibling-gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 1'
} > "$d_ss2e/RESEARCH-STATE-ss2e-active.md"
{ printf '# Focus Registry\n\n| Focus | Status | State file | Block prefix |\n|---|---|---|---|\n'
  printf '| ss2e-paused | paused (stale envelope test) | RESEARCH-STATE-ss2e-paused.md | p- |\n'
  printf '| ss2e-active | active | RESEARCH-STATE-ss2e-active.md | a- |\n'
} > "$d_ss2e/FOCUSES.md"
# T-SS2e: FOCUSES.md-declared paused focus with stale envelope → STALE bypass treats it as bypassed
# → active sibling's NEXT is returned (not STALE)
expect_next "$d_ss2e" "NEXT | high | active-stale-sibling-gap" \
  "T-SS2e: STALE-bypass respects FOCUSES.md — paused focus with stale envelope is bypassed; active NEXT"

# T-SS2f: default-status subshell skips declared stopped/paused focuses and emits the correct STOP reason.
# Uses the d_ss2b fixture (both focuses stopped/paused with open gaps).
# Assert on the "next step" line in the default status output.
_ns_got="$(bash "$SUT" "$d_ss2b" 2>/dev/null | grep 'next step')"
[ "$_ns_got" = "  next step       : STOP | no active focus (2 declared stopped/paused in FOCUSES.md with open gaps)" ] \
  && ok "T-SS2f: default-status subshell emits accurate STOP reason when all focuses are paused/stopped with open gaps" \
  || no "T-SS2f: default-status next-step got [$_ns_got]"

# T-641: stopped focus with malformed priority (MED) must NOT brick --next for the healthy active focus.
# Bug #641: the INVALID_PRIORITY check fires before the FOCUSES.md stopped-check in the bypass loop,
# so a stopped focus with MED priority locks _any_real_stale=1 and returns STALE instead of NEXT.
# Fix: FOCUSES.md stopped-check runs first; stopped focuses are skipped before INVALID_PRIORITY fires.
d_641="$TMP/t641-stopped-malformed"; mkdir -p "$d_641"
{ printf '# Stopped Focus (malformed priority MED)\n> intro\n'
  env_lines 0 0 0 0 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| MED | legacy malformed gap | web | pending |\n'
  printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d_641/RESEARCH-STATE-641-stopped.md"
{ printf '# Active Focus (healthy, high priority)\n> intro\n'
  env_lines 0 0 1 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | healthy gap | web | pending |\n'
  printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 1\n'
} > "$d_641/RESEARCH-STATE-641-active.md"
{ printf '| Focus | Status | State-file |\n|---|---|---|\n'
  printf '| 641-stopped | stopped | RESEARCH-STATE-641-stopped.md |\n'
  printf '| 641-active | active | RESEARCH-STATE-641-active.md |\n'
} > "$d_641/FOCUSES.md"
expect_next "$d_641" "NEXT | high | healthy gap" \
  "T-641: stopped focus with malformed priority (MED) does not brick --next for the active sibling"

# T-641b: positive control — an ACTIVE focus with malformed priority must still STALE the corpus.
# A stopped malformed focus is forgiven (T-641); an active one is a real failure.
d_641b="$TMP/t641b-active-malformed"; mkdir -p "$d_641b"
{ printf '# Active Focus (malformed priority MED)\n> intro\n'
  env_lines 0 0 0 0 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| MED | active malformed gap | web | pending |\n'
  printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d_641b/RESEARCH-STATE-641b-bad.md"
{ printf '# Active Focus (healthy, high priority)\n> intro\n'
  env_lines 0 0 1 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | healthy gap b | web | pending |\n'
  printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 1\n'
} > "$d_641b/RESEARCH-STATE-641b-good.md"
{ printf '| Focus | Status | State-file |\n|---|---|---|\n'
  printf '| 641b-bad | active | RESEARCH-STATE-641b-bad.md |\n'
  printf '| 641b-good | active | RESEARCH-STATE-641b-good.md |\n'
} > "$d_641b/FOCUSES.md"
_t641b_got="$(next "$d_641b")"
case "$_t641b_got" in
  STALE\ *) ok "T-641b: active focus with malformed priority (MED) → STALE (positive control)" ;;
  *) no "T-641b: expected STALE, got [$_t641b_got]" ;;
esac

# T-568: --sync-state derives known_gaps from backlog total when it exceeds the coverage metric Y.
# Bug #568: stale coverage metric (4/9) prevented known_gaps from updating when a new gap was added,
# resulting in kg=9 even though the backlog now has 10 rows.
# Fix (KG-BACKLOG-EXCEEDS): when backlog_total > metric_Y, use the backlog count.
d_568="$TMP/t568-kg-derive"; mkdir -p "$d_568"
{ printf '# T568\n> intro\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\n'
  printf 'gaps_closed: 4\nknown_gaps: 9\ninvestigable_open: 6\nrequires_execution_open: 0\n'
  printf 'blocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
  printf '\n## Coverage\n- **Coverage metric**: 4 / 9 closed\n'
  printf '\n## Gap-backlog (prioritized)\n| P | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | g1 | web | covered |\n'
  printf '| high | g2 | web | covered |\n'
  printf '| medium | g3 | web | covered |\n'
  printf '| low | g4 | web | covered |\n'
  printf '| high | g5 | web | pending |\n'
  printf '| high | g6 | web | pending |\n'
  printf '| medium | g7 | web | pending |\n'
  printf '| low | g8 | web | pending |\n'
  printf '| medium | g9 | web | pending |\n'
  printf '| high | g10-new | web | pending |\n'
  printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 6\n'
} > "$d_568/RESEARCH-STATE.md"
bash "$SUT" "$d_568" --sync-state >/dev/null 2>&1
_t568_kg="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^known_gaps:/{print $2; exit}' "$d_568/RESEARCH-STATE.md")"
[ "$_t568_kg" = "10" ] \
  && ok "T-568: --sync-state derives known_gaps=10 (backlog 10 rows > stale metric Y=9)" \
  || no "T-568: kg=$_t568_kg (want 10) — stale coverage metric Y prevailed over backlog row count"

# T-530: --sync-state under block_scope: shared-global uses attributed B<n> count, not corpus-wide.
# Bug #530: 5 .md files on disk but only 3 are attributed (B1-B3 in ## Covered blocks).
# --sync-state wrote covered_blocks=5 (corpus-wide); verify-state CHECK A expects covered_blocks=3 (attributed).
# Fix (SG-ATTR-SYNC): use count_attributed_sg() when attributed count > 0.
d_530="$TMP/t530-sg-attributed"; mkdir -p "$d_530"
printf 'x\n' > "$d_530/focus-bloque1.md"
printf 'x\n' > "$d_530/focus-bloque2.md"
printf 'x\n' > "$d_530/focus-bloque3.md"
printf 'x\n' > "$d_530/focus-bloque4.md"
printf 'x\n' > "$d_530/focus-bloque5.md"
{ printf '# T530\n> intro\n'
  printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 3\n'
  printf 'gaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\n'
  printf 'blocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope: shared-global\n'
  printf '<!-- /research-state.v1 -->\n'
  printf '\n## Covered blocks\nB1, B2, B3\n'
  printf '\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n'
  printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d_530/RESEARCH-STATE-sg.md"
bash "$SUT" "$d_530" --sync-state >/dev/null 2>&1
_t530_cb="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^covered_blocks:/{print $2; exit}' "$d_530/RESEARCH-STATE-sg.md")"
if [ "$_t530_cb" = "3" ]; then
  ok "T-530: shared-global --sync-state uses attributed count (3 B<n> ids, not 5 corpus-wide files)"
else
  no "T-530: cb=$_t530_cb (want 3) — --sync-state wrote corpus-wide file count instead of attributed"
fi
_t530_vs_out="$(bash "$HERE/../verify-state.sh" "$d_530" 2>&1)"
if echo "$_t530_vs_out" | grep -q 'FAIL'; then
  no "T-530: verify-state FAILs with attributed covered_blocks (expected CHECK A to pass)"
else
  ok "T-530: shared-global envelope with attributed covered_blocks passes verify-state CHECK A"
fi

# ========================= ISSUE CLUSTER #557 FIXES =========================

# T-634-SS — trailing ** stripped in backlog_rows so resolve_next/count_investigable see clean status.
# Pre-fix: backlog_rows emits `pending**` → resolve_next's `lead` strip handles it but count_investigable
# would double-strip harmlessly; the real risk is `count_investigable` counting wrong. Test the correct count.
d_634="$TMP/t634-status-bold"
mkdir -p "$d_634"
{ printf '# Research State\n\n'
  printf '<!-- research-state.v1 -->\n'
  printf 'schema: research-state.v1\ncovered_blocks: 0\n'
  printf 'gaps_closed: 0\nknown_gaps: 1\n'
  printf 'investigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n'
  printf '<!-- /research-state.v1 -->\n\n'
  printf '## Coverage\n- **Coverage metric**: 0 / 1 closed\n\n'
  printf '## Gap-backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | bold-gap | web | pending** |\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 1\n'
} > "$d_634/RESEARCH-STATE.md"
# Use --sync-state on a copy to check that count_investigable sees 1 investigable gap for pending** row.
# Note: status.sh already stripped ** in its callers (§8b); this fix moves stripping to backlog_rows source.
# The backlog_rows fix ensures consistency: callers no longer need to strip.
# Verify the invariant holds: investigable_open=1 is correctly computed for a pending** row.
_t634_copy="$TMP/t634-ss-copy"; mkdir -p "$_t634_copy"
cp "$d_634/RESEARCH-STATE.md" "$_t634_copy/RESEARCH-STATE.md"
_t634_sync="$(bash "$SUT" "$_t634_copy" --sync-state 2>/dev/null)"
_t634_io="$(printf '%s\n' "$_t634_sync" | grep -oE 'investigable_open=[0-9]+' | grep -oE '[0-9]+')"
if [ "${_t634_io:-0}" = "1" ]; then
  ok "T-634-SS: Status 'pending**' → --sync-state computes investigable_open=1 (** stripped correctly in backlog_rows)"
else
  no "T-634-SS: Status 'pending**' → --sync-state investigable_open=${_t634_io:-<missing>} (expected 1); backlog_rows ** stripping may be misaligned"
fi

# T-567-SS — COVERED row with pipe notation in status must not emit malformed-row WARN in status.sh.
d_567="$TMP/t567-status-covered-pipe"
mkdir -p "$d_567"
{ printf '# Research State\n\n'
  printf '<!-- research-state.v1 -->\n'
  printf 'schema: research-state.v1\ncovered_blocks: 0\n'
  printf 'gaps_closed: 0\nknown_gaps: 1\n'
  printf 'investigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\n'
  printf '<!-- /research-state.v1 -->\n\n'
  printf '## Coverage\n- **Coverage metric**: 0 / 1 closed\n\n'
  printf '## Gap-backlog (prioritized)\n\n'
  printf '| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | MM12-G1 | protocol | COVERED devType|address|command|status |\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 0\n'
} > "$d_567/RESEARCH-STATE.md"
_t567_err="$(bash "$SUT" "$d_567" 2>&1 >/dev/null)"
if ! grep -q 'malformed backlog row' <<<"$_t567_err"; then
  ok "T-567-SS: COVERED row with pipe notation → no malformed-row WARN in status.sh stderr"
else
  no "T-567-SS: spurious malformed-row WARN for COVERED pipe row in status.sh; warn=$(grep -m1 'malformed backlog row' <<<"$_t567_err")"
fi

# ==================== T-627 — RETRO-DUE state in --next (issue #627) ====================
# retro_due_state <dir> <bsr>: valid state file with blocks_since_retro: <bsr> and one pending gap.
retro_due_state() {
  local d="$1" bsr="$2"; mkdir -p "$d"
  { printf '# T-627 Research State\n\n'
    printf '<!-- research-state.v1 -->\n'
    printf 'schema: research-state.v1\ncovered_blocks: 0\n'
    printf 'gaps_closed: 0\nknown_gaps: 1\n'
    printf 'investigable_open: 1\nrequires_execution_open: 0\nblocked_open: 0\n'
    printf 'undocumented_findings: 0\nblocks_since_retro: %s\n' "$bsr"
    printf '<!-- /research-state.v1 -->\n\n'
    printf '## Gap-backlog\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
    printf '| high | retro-due-test-gap | web | pending |\n\n'
    printf '## Blocked gaps\n- none\n\n'
    printf '## Stop control\n- **Open gaps — read-only investigable**: 1\n'
  } > "$d/RESEARCH-STATE.md"
}

# T-627a: blocks_since_retro=11 (exceeds threshold 10) → RETRO-DUE from --next  # RD-PRIORITY-STALE-CASE
d="$TMP/t627-retro-due"; retro_due_state "$d" 11
got="$(next "$d")"
case "$got" in
  RETRO-DUE\ *) ok "T-627a: blocks_since_retro=11 > 10 → RETRO-DUE | ... from --next";;
  *) no "T-627a: expected RETRO-DUE, got [$got]";;
esac

# T-627b: blocks_since_retro=10 (AT threshold; gate fires at >10) → NEXT (not RETRO-DUE)
d="$TMP/t627-bsr-at"; retro_due_state "$d" 10
got="$(next "$d")"
case "$got" in
  NEXT\ *) ok "T-627b: blocks_since_retro=10 (at threshold, >10 fires) → NEXT (not RETRO-DUE)";;
  *) no "T-627b: expected NEXT for bsr=10, got [$got]";;
esac

# T-627c: blocks_since_retro absent → NEXT (silent when field absent)
d="$TMP/t627-bsr-absent"; mkstate "$d" 1 "high|retro-absent-gap|pending"
got="$(next "$d")"
case "$got" in
  NEXT\ *) ok "T-627c: blocks_since_retro absent → NEXT (silent when field absent)";;
  *) no "T-627c: expected NEXT when bsr absent, got [$got]";;
esac

# T-627d: STALE beats RETRO-DUE — inconsistent envelope + bsr=11 → STALE (not RETRO-DUE)
d="$TMP/t627-stale-beats-rd"; mkdir -p "$d"
{ printf '# T-627d stale+bsr state\n\n'
  printf '<!-- research-state.v1 -->\n'
  printf 'schema: research-state.v1\ncovered_blocks: 0\n'
  printf 'gaps_closed: 0\nknown_gaps: 1\n'
  printf 'investigable_open: 5\n'
  printf 'requires_execution_open: 0\nblocked_open: 0\n'
  printf 'undocumented_findings: 0\nblocks_since_retro: 11\n'
  printf '<!-- /research-state.v1 -->\n\n'
  printf '## Gap-backlog\n\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | stale-gap | web | pending |\n\n'
  printf '## Blocked gaps\n- none\n\n'
  printf '## Stop control\n- **Open gaps — read-only investigable**: 1\n'
} > "$d/RESEARCH-STATE.md"
got="$(next "$d")"
case "$got" in
  STALE\ *) ok "T-627d: STALE beats RETRO-DUE — inconsistent envelope (e_inv=5 vs d_inv=1) + bsr=11 → STALE";;
  *) no "T-627d: expected STALE, got [$got]";;
esac

# T-IDG-A: gaps exhausted + retros with untracked deltas → ISSUES-DUE
_kita="$TMP/kita"; mk_kit "$_kita" "untracked"
_ta="$TMP/target-idg-a"; mkstate "$_ta" 0 "high|done gap|covered"
mkdir -p "$_ta/retros"
touch "$_ta/retros/2026-09-01-retro-idg.md"
_idg_a_got="$(bash "$_kita/research-sdd-status.sh" "$_ta" --next 2>/dev/null)"
case "$_idg_a_got" in
  ISSUES-DUE\ *) ok "T-IDG-A: gaps exhausted + untracked deltas → ISSUES-DUE";;
  *) no "T-IDG-A: expected ISSUES-DUE, got [$_idg_a_got]";;
esac

# T-IDG-B: gaps exhausted + all deltas tracked → STOP (gate transparent)
_kitb="$TMP/kitb"; mk_kit "$_kitb" "tracked"
_tb="$TMP/target-idg-b"; mkstate "$_tb" 0 "high|done gap|covered"
mkdir -p "$_tb/retros"
touch "$_tb/retros/2026-09-01-retro-idg.md"
_idg_b_got="$(bash "$_kitb/research-sdd-status.sh" "$_tb" --next 2>/dev/null)"
[ "$_idg_b_got" = "STOP | read-only-investigable exhausted (0)" ] \
  && ok "T-IDG-B: all deltas tracked → STOP (gate transparent)" \
  || no "T-IDG-B: expected STOP, got [$_idg_b_got]"

# T-IDG-C: reconcile degraded → DISTINCT STOP marker on stdout + WARN on stderr, exit 0 (no deadlock)
# R4-DEGRADED: stdout must carry generic [issue-coverage: unverified] (cause-neutral), NOT the old
# cause-specific label and NOT a bare STOP.  Specific cause (gh degraded) must appear on stderr.
_kitc="$TMP/kitc"; mk_kit "$_kitc" "degraded"
_tc="$TMP/target-idg-c"; mkstate "$_tc" 0 "high|done gap|covered"
mkdir -p "$_tc/retros"
touch "$_tc/retros/2026-09-01-retro-idg.md"
_idg_c_err="$TMP/idg-c-stderr.txt"
_idg_c_got="$(bash "$_kitc/research-sdd-status.sh" "$_tc" --next 2>"$_idg_c_err")"
_idg_c_rc=$?
_idg_c_stderr="$(cat "$_idg_c_err")"
if printf '%s\n' "$_idg_c_got" | grep -qF '[issue-coverage: unverified]' \
   && printf '%s\n' "$_idg_c_stderr" | grep -q 'gh degraded' \
   && [ "$_idg_c_rc" -eq 0 ]; then
  ok "T-IDG-C: reconcile degraded → generic unverified marker on stdout + cause-specific WARN (gh degraded) on stderr + exit 0"
else
  no "T-IDG-C: degraded case — stdout=[$_idg_c_got] stderr=[$_idg_c_stderr] rc=$_idg_c_rc"
fi

# T-IDG-D: active investigable gap present → NEXT (gate never reached; hermetic kit)
# Fixture: active pending gap AND a retro with an untracked delta (via stub). The gate must
# NOT fire — resolve_next's NEXT result preempts issues_due_gate. This is the M2 precedence
# check: a precedence-inversion mutant that moves the gate before resolve_next would return
# ISSUES-DUE, making this test go RED. See teeth-IDG-precedence in --prove-teeth.
_kit_d="$TMP/kit-idg-d"; mk_kit "$_kit_d" "untracked"
_td="$TMP/target-idg-d"; mkstate "$_td" 1 "high|active-idg-gap|pending"
mkdir -p "$_td/retros"
touch "$_td/retros/2026-09-01-retro-idg.md"
_idg_d_got="$(bash "$_kit_d/research-sdd-status.sh" "$_td" --next 2>/dev/null)"
case "$_idg_d_got" in
  "NEXT | high | active-idg-gap") ok "T-IDG-D: active gap → NEXT (gate preempted by NEXT resolution; hermetic)" ;;
  *) no "T-IDG-D: expected NEXT | high | active-idg-gap, got [$_idg_d_got]" ;;
esac

# T-IDG-FOCUS: --focus with exhausted gaps + untracked retro → ISSUES-DUE
# Covers the single-focus --focus arm of issues_due_gate (F2 coverage gap).
_kit_foc="$TMP/kit-idg-foc"; mk_kit "$_kit_foc" "untracked"
_tf="$TMP/target-idg-focus"; mkdir -p "$_tf"
{ echo "# Alpha — Research State"; echo
  env_lines 0 0 0 0 0 0; echo
  echo "## Gap-backlog"; echo "| P | G | t | S |"; echo "|-|-|-|-|"
  echo "| high | done gap | web | covered |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"
} > "$_tf/RESEARCH-STATE-alpha.md"
mkdir -p "$_tf/retros"
touch "$_tf/retros/2026-09-01-focus-retro.md"
_idg_foc_got="$(bash "$_kit_foc/research-sdd-status.sh" "$_tf" --next --focus alpha 2>/dev/null)"
case "$_idg_foc_got" in
  ISSUES-DUE\ *) ok "T-IDG-FOCUS: --focus + exhausted gaps + untracked retro → ISSUES-DUE" ;;
  *) no "T-IDG-FOCUS: expected ISSUES-DUE, got [$_idg_foc_got]" ;;
esac

# T-IDG-PERF: applied-marked retro is skipped (no reconcile/gh call for it)
# Fixture: two retros — one with applied marker (must be skipped), one open (reconcile called).
# Recording stub uses ${@: -1} (last arg = retro path) because gate now passes
# --issues-cache <file> <retro> — $1 would be "--issues-cache", not the retro path.
# Wrapper design: research-sdd-status.sh is a wrapper that injects $kdir/bin (stub gh) into PATH;
# real SUT lives as _sut.sh; stub gh handles the batch prefetch (auth→0, issue list→0, empty bodies).
_perf_log="$TMP/perf-invocations.log"
_kit_perf="$TMP/kit-idg-perf"
mkdir -p "$_kit_perf/lib" "$_kit_perf/bin"
# Stub gh: hermetic batch prefetch (never hits real GitHub)
printf '#!/usr/bin/env bash\ncase "$1" in auth) exit 0 ;; issue) exit 0 ;; *) exit 1 ;; esac\n' \
  > "$_kit_perf/bin/gh"
chmod +x "$_kit_perf/bin/gh"
# Wrapper: injects $kdir/bin into PATH before executing the real SUT as _sut.sh
cat > "$_kit_perf/research-sdd-status.sh" <<PERF_WRAPPER_EOF
#!/usr/bin/env bash
export PATH="$_kit_perf/bin:\$PATH"
exec bash "$_kit_perf/_sut.sh" "\$@"
PERF_WRAPPER_EOF
chmod +x "$_kit_perf/research-sdd-status.sh"
cp "$SUT" "$_kit_perf/_sut.sh"
cp "$HERE/../verify-state.sh" "$_kit_perf/verify-state.sh"
cp "$HERE/../lib/retro-status.sh" "$_kit_perf/lib/retro-status.sh"
cp "$HERE/../lib/focus-prefix.sh" "$_kit_perf/lib/focus-prefix.sh"
cp "$HERE/../lib/state-files.sh" "$_kit_perf/lib/state-files.sh"
cp "$HERE/../lib/block-files.sh" "$_kit_perf/lib/block-files.sh"
# Recording stub: logs LAST argument (retro path) to the invocations file, returns one untracked line.
# Uses ${@: -1} because gate calls reconcile as: reconcile.sh --issues-cache <file> <retro>
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${@: -1}" >> "%s"\nprintf "untracked: row 1\\n"\nexit 0\n' \
  "$_perf_log" > "$_kit_perf/reconcile-issues.sh"
chmod +x "$_kit_perf/reconcile-issues.sh"
_ta_perf="$TMP/target-perf"; mkstate "$_ta_perf" 0 "high|done gap|covered"
mkdir -p "$_ta_perf/retros"
printf '<!-- review-status: applied · kit 073cef5 -->\n# Applied retro\n' \
  > "$_ta_perf/retros/applied-retro.md"
touch "$_ta_perf/retros/open-retro.md"
_perf_got="$(bash "$_kit_perf/research-sdd-status.sh" "$_ta_perf" --next 2>/dev/null)"
_perf_invocations="$(cat "$_perf_log" 2>/dev/null || true)"
if ! printf '%s\n' "$_perf_invocations" | grep -q 'applied-retro.md' \
   && printf '%s\n' "$_perf_invocations" | grep -q 'open-retro.md'; then
  ok "T-IDG-PERF: applied retro not passed to reconcile; open retro was"
else
  no "T-IDG-PERF: invocations=[${_perf_invocations}] — expected applied-retro absent, open-retro present"
fi
case "$_perf_got" in
  ISSUES-DUE\ *) ok "T-IDG-PERF: still emits ISSUES-DUE (open retro has untracked delta)" ;;
  *) no "T-IDG-PERF: expected ISSUES-DUE, got [$_perf_got]" ;;
esac

# T-IDG-TIMEOUT: per-retro reconcile call is wrapped in timeout; a slow stub times out → unverified marker
# R4-SERIAL: override timeout to 1s via _IDG_RECONCILE_TIMEOUT_SECS; stub sleeps 3s (longer).
# Assert: gate returns the generic unverified marker promptly (not plain STOP, not ISSUES-DUE);
# and stderr names the timeout cause (not "gh degraded" — a distinct per-branch WARN).
_kit_tmt="$TMP/kit-idg-timeout"; mk_kit "$_kit_tmt" "timeout_sleep_3"
_t_tmt="$TMP/target-idg-timeout"; mkstate "$_t_tmt" 0 "high|done gap|covered"
mkdir -p "$_t_tmt/retros"
touch "$_t_tmt/retros/2026-09-01-timeout-retro.md"
_tmt_stderr_file="$TMP/idg-timeout-stderr.txt"
_tmt_got="$(env _IDG_RECONCILE_TIMEOUT_SECS=1 bash "$_kit_tmt/research-sdd-status.sh" "$_t_tmt" --next 2>"$_tmt_stderr_file")"
_tmt_err_got="$(cat "$_tmt_stderr_file")"
if printf '%s\n' "$_tmt_got" | grep -qF '[issue-coverage: unverified]' \
   && printf '%s\n' "$_tmt_err_got" | grep -q 'timed out'; then
  ok "T-IDG-TIMEOUT: slow reconcile stub (3s) times out at 1s → generic unverified marker on stdout + timed-out WARN on stderr"
else
  no "T-IDG-TIMEOUT: expected unverified marker + timed-out stderr, got stdout=[$_tmt_got] stderr=[$_tmt_err_got]"
fi

# T-IDG-TIMEOUT-ABSENT: _IDG_TIMEOUT_BIN="" → fail-closed for liveness:
# unverified marker returned, 0 reconcile calls made (probe is skipped entirely).
# R4-unbounded-when-timeout-absent: previously the gate ran each probe unbounded.
_kit_ta="$TMP/kit-idg-timeout-absent"
_ta_log="$TMP/timeout-absent-invocations.log"
mkdir -p "$_kit_ta/lib"
cp "$SUT" "$_kit_ta/research-sdd-status.sh"
cp "$HERE/../verify-state.sh" "$_kit_ta/verify-state.sh"
cp "$HERE/../lib/retro-status.sh" "$_kit_ta/lib/retro-status.sh"
cp "$HERE/../lib/focus-prefix.sh" "$_kit_ta/lib/focus-prefix.sh"
cp "$HERE/../lib/state-files.sh" "$_kit_ta/lib/state-files.sh"
cp "$HERE/../lib/block-files.sh" "$_kit_ta/lib/block-files.sh"
# Recording stub: logs its argument (assert 0 calls); returns "tracked" so clean STOP if probe runs.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s"\nprintf "tracked: row 1\\n"\nexit 0\n' \
  "$_ta_log" > "$_kit_ta/reconcile-issues.sh"
chmod +x "$_kit_ta/reconcile-issues.sh"
_t_ta="$TMP/target-idg-timeout-absent"; mkstate "$_t_ta" 0 "high|done gap|covered"
mkdir -p "$_t_ta/retros"
touch "$_t_ta/retros/2026-09-01-timeout-absent-retro.md"
_ta_got="$(_IDG_TIMEOUT_BIN="" bash "$_kit_ta/research-sdd-status.sh" "$_t_ta" --next 2>/dev/null)"
_ta_calls="$(cat "$_ta_log" 2>/dev/null || true)"
if printf '%s\n' "$_ta_got" | grep -qF '[issue-coverage: unverified'; then
  ok "T-IDG-TIMEOUT-ABSENT: _IDG_TIMEOUT_BIN=\"\" → unverified marker returned"
else
  no "T-IDG-TIMEOUT-ABSENT: expected unverified marker, got [$_ta_got]"
fi
if [ -z "$_ta_calls" ]; then
  ok "T-IDG-TIMEOUT-ABSENT: reconcile not called (0 invocations) — fail-closed for liveness"
else
  no "T-IDG-TIMEOUT-ABSENT: reconcile was called [$_ta_calls] — probe not skipped"
fi

# T-IDG-CONTRACT: parser↔producer contract — real reconcile-issues.sh prints ^untracked: that gate counts.
# R3-STUB-ONLY: runs REAL reconcile (not a stub); gh is stubbed (auth→exit 0, issue list→empty).
# Empty issue list → delta has no matching open issue → reconcile classifies it as untracked.
# Gate's awk '/^untracked:/' must match reconcile's real output format → ISSUES-DUE.
_kit_ctr="$TMP/kit-idg-contract"
_gh_stub_ctr="$TMP/gh-stub-contract"
mk_kit_real_reconcile "$_kit_ctr" "$_gh_stub_ctr"
_tc_ctr="$TMP/target-idg-contract"; mkstate "$_tc_ctr" 0 "high|done gap|covered"
mkdir -p "$_tc_ctr/retros"
cat > "$_tc_ctr/retros/contract-test-retro.md" <<'CONTRACT_EOF'
<!-- review-status: pending -->
# Contract test retro

## Proposed kit deltas

| # | Proposed change | Target | Evidence | Priority |
|---|---|---|---|---|
| 1 | test delta | file.sh | evidence | high |
CONTRACT_EOF
_ctr_got="$(PATH="$_gh_stub_ctr:$PATH" bash "$_kit_ctr/research-sdd-status.sh" "$_tc_ctr" --next 2>/dev/null)"
case "$_ctr_got" in
  ISSUES-DUE\ *) ok "T-IDG-CONTRACT: real reconcile + stubbed-gh (no issues) → ISSUES-DUE (^untracked: line counted by gate)" ;;
  *) no "T-IDG-CONTRACT: expected ISSUES-DUE, got [$_ctr_got]" ;;
esac

# T-IDG-E: operational failure (exit 1, empty stderr) → distinct unverified marker on stdout + WARN on stderr, exit 0
# R4-OPFAIL: a reconcile failure that is NOT a timeout (124) or a degraded gh response must also mark
# coverage unverified.  The stub exits 1 with no output — no 'degraded:' line, no SIGKILL code.
# Before the fix the F5b else-branch was missing _idg_had_unverified=1, so it silently returned STOP.
_kite="$TMP/kite"; mk_kit "$_kite" "exit_1_empty"
_te="$TMP/target-idg-e"; mkstate "$_te" 0 "high|done gap|covered"
mkdir -p "$_te/retros"
touch "$_te/retros/2026-09-01-retro-idg.md"
_idg_e_err="$TMP/idg-e-stderr.txt"
_idg_e_got="$(bash "$_kite/research-sdd-status.sh" "$_te" --next 2>"$_idg_e_err")"
_idg_e_rc=$?
_idg_e_stderr="$(cat "$_idg_e_err")"
if printf '%s\n' "$_idg_e_got" | grep -qF '[issue-coverage: unverified' \
   && printf '%s\n' "$_idg_e_stderr" | grep -q 'WARN' \
   && [ "$_idg_e_rc" -eq 0 ]; then
  ok "T-IDG-E: operational failure (exit 1, empty stderr) → distinct unverified marker + WARN stderr + exit 0"
else
  no "T-IDG-E: stdout=[$_idg_e_got] stderr=[$_idg_e_stderr] rc=$_idg_e_rc — expected unverified marker + WARN + exit 0"
fi

# T-IDG-F: signal-kill class (exit 137) → distinct unverified marker, not bare STOP
# Verifies that the F5b fix covers the full else-branch, not just exit 1.
_kitf="$TMP/kitf"; mk_kit "$_kitf" "exit_137"
_tf2="$TMP/target-idg-f"; mkstate "$_tf2" 0 "high|done gap|covered"
mkdir -p "$_tf2/retros"
touch "$_tf2/retros/2026-09-01-retro-idg.md"
_idg_f_got="$(bash "$_kitf/research-sdd-status.sh" "$_tf2" --next 2>/dev/null)"
if printf '%s\n' "$_idg_f_got" | grep -qF '[issue-coverage: unverified'; then
  ok "T-IDG-F: signal-kill (exit 137) → distinct unverified marker (not bare STOP)"
else
  no "T-IDG-F: expected unverified marker, got [$_idg_f_got]"
fi

# ---- Enumeration hardening: find exit-status + mktemp (§7 invariant) --------------------------
# Bare verified-clean STOP only when ALL of: (a) enumeration SUCCEEDED AND COMPLETE, (b) every
# probed retro's reconcile exited 0, (c) 0 untracked. All other outcomes → unverified marker.
#
# Stub infrastructure (shared by T-IDG-ENUM-*):
#   stub-find: for the retro-enumeration call (*/retros/*.md), outputs IDG_RETRO_PATHS_FILE if set,
#              writes IDG_FIND_STDERR to stderr if set, exits IDG_FIND_EXIT (default 0).
#              All other find calls delegate to /usr/bin/find.
#   stub-mktemp: fails the FIRST mktemp call; passes subsequent calls to /usr/bin/mktemp.
#                Uses IDG_MKTEMP_STUB_DIR for the per-run call counter file.
_stub_find_dir="$TMP/stub-find"
mkdir -p "$_stub_find_dir"
cat > "$_stub_find_dir/find" <<'STUB_FIND_EOF'
#!/usr/bin/env bash
for _a in "$@"; do
    if [ "$_a" = '*/retros/*.md' ]; then
        [ -f "${IDG_RETRO_PATHS_FILE:-}" ] && cat "$IDG_RETRO_PATHS_FILE"
        [ -n "${IDG_FIND_STDERR:-}" ] && printf '%s\n' "$IDG_FIND_STDERR" >&2
        exit "${IDG_FIND_EXIT:-0}"
    fi
done
exec /usr/bin/find "$@"
STUB_FIND_EOF
chmod +x "$_stub_find_dir/find"

_stub_mktemp_dir="$TMP/stub-mktemp"
mkdir -p "$_stub_mktemp_dir"
cat > "$_stub_mktemp_dir/mktemp" <<'STUB_MKTEMP_EOF'
#!/usr/bin/env bash
_dir="${IDG_MKTEMP_STUB_DIR:?IDG_MKTEMP_STUB_DIR not set}"
_count_file="$_dir/.count"
_count=0
[ -f "$_count_file" ] && _count="$(cat "$_count_file" 2>/dev/null)"
_count=$((_count + 1))
printf '%s\n' "$_count" > "$_count_file"
if [ "$_count" -eq 1 ]; then exit 1; fi
exec /usr/bin/mktemp "$@"
STUB_MKTEMP_EOF
chmod +x "$_stub_mktemp_dir/mktemp"

_stub_sort_dir="$TMP/stub-sort"
mkdir -p "$_stub_sort_dir"
cat > "$_stub_sort_dir/sort" <<'STUB_SORT_EOF'
#!/usr/bin/env bash
# Stub sort: when IDG_SORT_EXIT is set AND called with -o (in-place), exit that code.
# Regular sort calls (pipelines, etc.) pass through to the real binary so the rest
# of the SUT flow (verify-state.sh state-file lookup, etc.) is not disrupted.
if [ -n "${IDG_SORT_EXIT:-}" ]; then
    for _sa in "$@"; do
        [ "$_sa" = "-o" ] && exit "${IDG_SORT_EXIT}"
    done
fi
exec /usr/bin/sort "$@"
STUB_SORT_EOF
chmod +x "$_stub_sort_dir/sort"

# T-IDG-ENUM-PARTIAL: find exits non-zero + some retros listed + one has untracked → ISSUES-DUE.
# Verifies retros listed before the error are NOT discarded — coverage cannot be claimed complete
# but untracked deltas found in the partial set still win.
_kit_ep="$TMP/kit-idg-enum-partial"; mk_kit "$_kit_ep" "untracked"
_t_ep="$TMP/target-idg-enum-partial"; mkstate "$_t_ep" 0 "high|done gap|covered"
mkdir -p "$_t_ep/retros"
touch "$_t_ep/retros/2026-09-enum-partial-retro.md"
_ep_retro_paths="$TMP/enum-partial-retro-paths.txt"
printf '%s\n' "$_t_ep/retros/2026-09-enum-partial-retro.md" > "$_ep_retro_paths"
_ep_got="$(IDG_RETRO_PATHS_FILE="$_ep_retro_paths" IDG_FIND_EXIT=1 IDG_FIND_STDERR="find: /sub: Permission denied" \
  PATH="$_stub_find_dir:$PATH" bash "$_kit_ep/research-sdd-status.sh" "$_t_ep" --next 2>/dev/null)"
case "$_ep_got" in
  ISSUES-DUE\ *) ok "T-IDG-ENUM-PARTIAL: find exits non-zero + retros listed + untracked → ISSUES-DUE (retros not discarded)" ;;
  *) no "T-IDG-ENUM-PARTIAL: expected ISSUES-DUE, got [$_ep_got]" ;;
esac

# T-IDG-ENUM-PARTIAL-NOUNTRACKED: find exits non-zero + retros listed + all tracked → unverified marker.
# "Partial but no untracked": probing succeeded but coverage cannot be claimed complete.
_kit_epn="$TMP/kit-idg-enum-partial-noissues"; mk_kit "$_kit_epn" "tracked"
_t_epn="$TMP/target-idg-enum-partial-noissues"; mkstate "$_t_epn" 0 "high|done gap|covered"
mkdir -p "$_t_epn/retros"
touch "$_t_epn/retros/2026-09-enum-partial-noissues-retro.md"
_epn_retro_paths="$TMP/enum-partial-noissues-retro-paths.txt"
printf '%s\n' "$_t_epn/retros/2026-09-enum-partial-noissues-retro.md" > "$_epn_retro_paths"
_epn_got="$(IDG_RETRO_PATHS_FILE="$_epn_retro_paths" IDG_FIND_EXIT=1 IDG_FIND_STDERR="find: /sub: Permission denied" \
  PATH="$_stub_find_dir:$PATH" bash "$_kit_epn/research-sdd-status.sh" "$_t_epn" --next 2>/dev/null)"
if printf '%s\n' "$_epn_got" | grep -qF '[issue-coverage: unverified'; then
  ok "T-IDG-ENUM-PARTIAL-NOUNTRACKED: find exits non-zero + retros listed + all tracked → unverified marker (not bare STOP)"
else
  no "T-IDG-ENUM-PARTIAL-NOUNTRACKED: expected unverified marker, got [$_epn_got]"
fi

# T-IDG-ENUM-EMPTY: find exits non-zero + no retros found → unverified marker (not bare STOP).
# Absent-input (find failed) is distinct from empty-input (found zero retros cleanly).
_kit_ee="$TMP/kit-idg-enum-empty"; mk_kit "$_kit_ee" "tracked"
_t_ee="$TMP/target-idg-enum-empty"; mkstate "$_t_ee" 0 "high|done gap|covered"
_ee_got="$(IDG_FIND_EXIT=1 IDG_FIND_STDERR="find: /sub: Permission denied" \
  PATH="$_stub_find_dir:$PATH" bash "$_kit_ee/research-sdd-status.sh" "$_t_ee" --next 2>/dev/null)"
if printf '%s\n' "$_ee_got" | grep -qF '[issue-coverage: unverified'; then
  ok "T-IDG-ENUM-EMPTY: find exits non-zero + no retros → unverified marker (not bare STOP)"
else
  no "T-IDG-ENUM-EMPTY: expected unverified marker, got [$_ee_got]"
fi

# T-IDG-ENUM-MKTEMP: enumeration mktemp failure → unverified marker, no crash.
# Stub mktemp fails the first call (_find_out_tmp creation); subsequent calls succeed.
_kit_em="$TMP/kit-idg-enum-mktemp"; mk_kit "$_kit_em" "tracked"
_t_em="$TMP/target-idg-enum-mktemp"; mkstate "$_t_em" 0 "high|done gap|covered"
_em_stub_dir="$TMP/mstub-run"; mkdir -p "$_em_stub_dir"
_em_got="$(IDG_MKTEMP_STUB_DIR="$_em_stub_dir" \
  PATH="$_stub_mktemp_dir:$PATH" bash "$_kit_em/research-sdd-status.sh" "$_t_em" --next 2>/dev/null)"
if printf '%s\n' "$_em_got" | grep -qF '[issue-coverage: unverified'; then
  ok "T-IDG-ENUM-MKTEMP: enumeration mktemp failure → unverified marker, no crash"
else
  no "T-IDG-ENUM-MKTEMP: expected unverified marker, got [$_em_got]"
fi

# T-IDG-ENUM-SORT-FAIL: sort stage of enumeration fails → unverified marker (not bare clean STOP).
# R4-sort-silent-zero: sort's exit status was previously discarded.
_kit_sf="$TMP/kit-idg-sort-fail"; mk_kit "$_kit_sf" "tracked"
_t_sf="$TMP/target-idg-sort-fail"; mkstate "$_t_sf" 0 "high|done gap|covered"
mkdir -p "$_t_sf/retros"
touch "$_t_sf/retros/2026-09-01-sort-fail-retro.md"
_sf_got="$(IDG_SORT_EXIT=1 PATH="$_stub_sort_dir:$PATH" \
  bash "$_kit_sf/research-sdd-status.sh" "$_t_sf" --next 2>/dev/null)"
if printf '%s\n' "$_sf_got" | grep -qF '[issue-coverage: unverified'; then
  ok "T-IDG-ENUM-SORT-FAIL: enumeration sort exits 1 → unverified marker (not bare clean STOP)"
else
  no "T-IDG-ENUM-SORT-FAIL: expected unverified marker, got [$_sf_got]"
fi

# T-IDG-PAYLOAD: ISSUES-DUE emitted for the first retro; retro-beta.md is NOT probed (early-exit).
# Verifies: (1) ISSUES-DUE present, (2) triggering retro named in output, (3) only 1 stub call.
_kit_pl="$TMP/kit-idg-payload"; mk_kit "$_kit_pl" "recording_untracked"
_t_pl="$TMP/target-idg-payload"; mkstate "$_t_pl" 0 "high|done gap|covered"
mkdir -p "$_t_pl/retros"
touch "$_t_pl/retros/retro-alpha.md"   # sorts first → first probe; 1 untracked → early-exit
touch "$_t_pl/retros/retro-beta.md"    # must NOT be probed after alpha's early-exit
_pl_log="$TMP/idg-payload-rec.log"; : > "$_pl_log"
_pl_got="$(_IDG_RECORD_LOG="$_pl_log" bash "$_kit_pl/research-sdd-status.sh" "$_t_pl" --next 2>/dev/null)"
_pl_calls="$(grep -c '' "$_pl_log" 2>/dev/null || echo 999)"
if printf '%s\n' "$_pl_got" | grep -qF 'ISSUES-DUE'; then
  ok "T-IDG-PAYLOAD: ISSUES-DUE present in output"
else
  no "T-IDG-PAYLOAD: ISSUES-DUE absent — got [$_pl_got]"
fi
if printf '%s\n' "$_pl_got" | grep -qF 'retro-alpha.md'; then
  ok "T-IDG-PAYLOAD: output names the triggering retro (retro-alpha.md)"
else
  no "T-IDG-PAYLOAD: output missing retro path — got [$_pl_got]"
fi
if [ "${_pl_calls}" -le 2 ] 2>/dev/null; then
  ok "T-IDG-PAYLOAD: early-exit — reconcile called ${_pl_calls} time(s) (retro-beta NOT probed; ≤2 for alpha: batch call + optional re-verify)"
else
  no "T-IDG-PAYLOAD: early-exit failed — reconcile called ${_pl_calls} time(s) (expected ≤2; retro-beta must NOT be probed)"
fi

# T-IDG-EMPTY-CORPUS: find succeeds with 0 retros (no .md files) → bare clean STOP.
# Distinct from T-IDG-ENUM-EMPTY where find exits non-zero (absent-input vs empty-input).
_kit_ec="$TMP/kit-idg-empty-corpus"; mk_kit "$_kit_ec" "tracked"
_t_ec="$TMP/target-idg-empty-corpus"; mkstate "$_t_ec" 0 "high|done gap|covered"
mkdir -p "$_t_ec/retros"  # retros dir exists but has no .md files
_ec_got="$(bash "$_kit_ec/research-sdd-status.sh" "$_t_ec" --next 2>/dev/null)"
if [ "$_ec_got" = "STOP | read-only-investigable exhausted (0)" ]; then
  ok "T-IDG-EMPTY-CORPUS: 0 retros (clean find) → bare clean STOP (no ISSUES-DUE, no unverified)"
else
  no "T-IDG-EMPTY-CORPUS: expected bare clean STOP, got [$_ec_got]"
fi

# T-IDG-AGGR-BUDGET: aggregate budget=0 → exceeded before first retro verified → unverified marker.
# Uses tracked stub (no untracked → early-exit does not fire); budget fires instead.
_kit_ab="$TMP/kit-idg-aggr-budget"; mk_kit "$_kit_ab" "tracked"
_t_ab="$TMP/target-idg-aggr-budget"; mkstate "$_t_ab" 0 "high|done gap|covered"
mkdir -p "$_t_ab/retros"
touch "$_t_ab/retros/2026-09-01-ab-retro.md"
_ab_got="$(_IDG_AGGREGATE_BUDGET_SECS=0 bash "$_kit_ab/research-sdd-status.sh" "$_t_ab" --next 2>/dev/null)"
if printf '%s\n' "$_ab_got" | grep -qF '[issue-coverage: unverified]'; then
  ok "T-IDG-AGGR-BUDGET: aggregate budget 0 → exceeded → unverified marker"
else
  no "T-IDG-AGGR-BUDGET: expected unverified marker, got [$_ab_got]"
fi

# T-IDG-BATCH-A: batch prefetch path — untracked delta found via cache → ISSUES-DUE.
# Uses mk_kit (stub reconcile returns untracked regardless of --issues-cache), wrapper injects gh stub.
# This test verifies the end-to-end ISSUES-DUE path is preserved after the batch change.
_kit_ba="$TMP/kit-idg-batch-a"; mk_kit "$_kit_ba" "untracked"
_t_ba="$TMP/target-idg-batch-a"; mkstate "$_t_ba" 0 "high|done gap|covered"
mkdir -p "$_t_ba/retros"
touch "$_t_ba/retros/batch-a-retro.md"
_ba_got="$(bash "$_kit_ba/research-sdd-status.sh" "$_t_ba" --next 2>/dev/null)"
case "$_ba_got" in
  ISSUES-DUE\ *) ok "T-IDG-BATCH-A: batch path — untracked delta → ISSUES-DUE" ;;
  *) no "T-IDG-BATCH-A: expected ISSUES-DUE, got [$_ba_got]" ;;
esac

# T-IDG-BATCH-B: batch prefetch path — all deltas tracked via cache → STOP.
# Uses mk_kit (stub reconcile returns tracked); wrapper injects gh stub.
# This test verifies the STOP path is preserved after the batch change.
_kit_bb="$TMP/kit-idg-batch-b"; mk_kit "$_kit_bb" "tracked"
_t_bb="$TMP/target-idg-batch-b"; mkstate "$_t_bb" 0 "high|done gap|covered"
mkdir -p "$_t_bb/retros"
touch "$_t_bb/retros/batch-b-retro.md"
_bb_got="$(bash "$_kit_bb/research-sdd-status.sh" "$_t_bb" --next 2>/dev/null)"
if [ "$_bb_got" = "STOP | read-only-investigable exhausted (0)" ]; then
  ok "T-IDG-BATCH-B: batch path — all deltas tracked → bare clean STOP"
else
  no "T-IDG-BATCH-B: expected bare clean STOP, got [$_bb_got]"
fi

# T-IDG-BATCH-ONE-GH: batch prefetch results in exactly ONE gh call for N retros (not one per retro).
# Uses REAL reconcile (mk_kit_real_reconcile) + recording gh stub that logs every issue list call.
# With batch (after implementation): 1 gh call (batch prefetch) + 0 per-retro (reconcile uses cache).
# Without batch (current SUT): 0 batch call + 2 per-retro calls = 2 gh calls → RED before implementation.
# Fixture: 2 retros, each with 1 row; gh stub returns tracked bodies for both → no early-exit → all probed.
# The gh stub returns a body for each retro so real reconcile classifies them as tracked (no ISSUES-DUE).
_kit_b1gh="$TMP/kit-idg-batch1gh"
_gh_b1gh_dir="$TMP/gh-batch1gh-dir"
mk_kit_real_reconcile "$_kit_b1gh" "$_gh_b1gh_dir"
_gh_b1gh_log="$TMP/gh-batch1gh.log"; : > "$_gh_b1gh_log"
# Override: recording gh that logs issue calls and returns tracked bodies for both retros.
# The target dir is $TMP/target-idg-batch1gh; basename = target-idg-batch1gh.
cat > "$_gh_b1gh_dir/gh" <<GHBATCH1EOF
#!/usr/bin/env bash
case "\$1" in
  auth) exit 0 ;;
  issue)
    printf 'call\n' >> "$_gh_b1gh_log"
    printf 'Source retro: target-idg-batch1gh/retros/retro-1.md \xc2\xb7 1\n'
    printf 'Source retro: target-idg-batch1gh/retros/retro-2.md \xc2\xb7 1\n'
    exit 0
    ;;
  *) exit 1 ;;
esac
GHBATCH1EOF
chmod +x "$_gh_b1gh_dir/gh"
_t_b1gh="$TMP/target-idg-batch1gh"; mkstate "$_t_b1gh" 0 "high|done gap|covered"
mkdir -p "$_t_b1gh/retros"
printf '<!-- review-status: pending -->\n# Batch retro 1\n\n## Proposed kit deltas\n\n| # | Proposed change | Target | Evidence | Priority |\n|---|---|---|---|---|\n| 1 | delta 1 | file.sh | ev | high |\n' \
  > "$_t_b1gh/retros/retro-1.md"
printf '<!-- review-status: pending -->\n# Batch retro 2\n\n## Proposed kit deltas\n\n| # | Proposed change | Target | Evidence | Priority |\n|---|---|---|---|---|\n| 1 | delta 2 | file.sh | ev | high |\n' \
  > "$_t_b1gh/retros/retro-2.md"
_b1gh_got="$(PATH="$_gh_b1gh_dir:$PATH" bash "$_kit_b1gh/research-sdd-status.sh" "$_t_b1gh" --next 2>/dev/null)"
_b1gh_calls="$(grep -c '' "$_gh_b1gh_log" 2>/dev/null || echo 999)"
if [ "$_b1gh_got" = "STOP | read-only-investigable exhausted (0)" ]; then
  ok "T-IDG-BATCH-ONE-GH: 2 tracked retros → bare clean STOP (gh stub returns tracked bodies)"
else
  no "T-IDG-BATCH-ONE-GH: expected bare clean STOP, got [$_b1gh_got]"
fi
if [ "${_b1gh_calls}" -eq 1 ] 2>/dev/null; then
  ok "T-IDG-BATCH-ONE-GH: exactly 1 gh issue list call for 2 retros (batch semantics — not per-retro)"
else
  no "T-IDG-BATCH-ONE-GH: expected 1 gh call for 2 retros, got ${_b1gh_calls} — batch prefetch not implemented"
fi

# T-IDG-BATCH-TIMEOUT-WRAP: batch gh call passes through the timeout wrapper (IDG-BATCH-GH-TIMEOUT-WRAP).
# Uses a recording fake-timeout that logs its args and execs the real command (skip first arg = duration).
# The batch call must appear in the fake-timeout log as a "gh issue list" entry.
_kit_btwrap="$TMP/kit-idg-batch-twrap"; mk_kit "$_kit_btwrap" "tracked"
_btwrap_log="$TMP/btwrap.log"; : > "$_btwrap_log"
_btwrap_bin="$TMP/btwrap-bin"; mkdir -p "$_btwrap_bin"
cat > "$_btwrap_bin/fake-timeout" <<BTWRAPEOF
#!/usr/bin/env bash
printf 'timeout-call: %s\n' "\$*" >> "$_btwrap_log"
shift  # skip duration
exec "\$@"
BTWRAPEOF
chmod +x "$_btwrap_bin/fake-timeout"
_t_btwrap="$TMP/target-idg-btwrap"; mkstate "$_t_btwrap" 0 "high|done gap|covered"
mkdir -p "$_t_btwrap/retros"
touch "$_t_btwrap/retros/btwrap-retro.md"
_IDG_TIMEOUT_BIN="$_btwrap_bin/fake-timeout" \
  bash "$_kit_btwrap/research-sdd-status.sh" "$_t_btwrap" --next 2>/dev/null || true
if grep -q 'gh issue list' "$_btwrap_log" 2>/dev/null; then
  ok "T-IDG-BATCH-TIMEOUT-WRAP: batch gh call passes through timeout wrapper (log has 'gh issue list')"
else
  no "T-IDG-BATCH-TIMEOUT-WRAP: 'gh issue list' not in timeout log — batch not timeout-wrapped"
fi

# T-IDG-BATCH-LIMIT: batch gh call includes --limit flag to bound the page size.
# A recording gh stub replaces the kit's own gh (into $kdir/bin, which the wrapper prepends first).
_kit_blim="$TMP/kit-idg-batch-lim"; mk_kit "$_kit_blim" "tracked"
_blim_ghlog="$TMP/gh-blim.log"; : > "$_blim_ghlog"
# Override the kit gh stub with a recording one (kit/bin is prepended by wrapper, so this wins).
cat > "$_kit_blim/bin/gh" <<BLIMGHEOF
#!/usr/bin/env bash
printf 'args: %s\n' "\$*" >> "$_blim_ghlog"
case "\$1" in
  auth) exit 0 ;;
  issue) exit 0 ;;
  *) exit 1 ;;
esac
BLIMGHEOF
chmod +x "$_kit_blim/bin/gh"
_t_blim="$TMP/target-idg-batch-lim"; mkstate "$_t_blim" 0 "high|done gap|covered"
mkdir -p "$_t_blim/retros"
touch "$_t_blim/retros/blim-retro.md"
bash "$_kit_blim/research-sdd-status.sh" "$_t_blim" --next 2>/dev/null || true
if grep -q -- '--limit' "$_blim_ghlog" 2>/dev/null; then
  ok "T-IDG-BATCH-LIMIT: batch gh call includes --limit flag (page size is bounded)"
else
  no "T-IDG-BATCH-LIMIT: '--limit' not found in batch gh invocation — page size unbounded"
fi

# T-IDG-BATCH-FALLBACK: batch gh failure triggers per-retro reconcile (no blanket-unverified SPOF).
# gh stub exits 1 (simulates rate-limit / transient failure); reconcile stub is recording_untracked.
# Expected: per-retro reconcile IS invoked (log non-empty) AND gate returns ISSUES-DUE (untracked found).
# Tooth: mutant removes the fallback else-branch → reconcile NOT invoked → log empty → RED.
_kit_bfb="$TMP/kit-idg-batch-fb"; mk_kit "$_kit_bfb" "recording_untracked"
# Override kit gh stub to exit 1 (batch gh call fails; triggers fallback to per-retro)
printf '#!/usr/bin/env bash\nexit 1\n' > "$_kit_bfb/bin/gh"
chmod +x "$_kit_bfb/bin/gh"
_bfb_log="$TMP/bfb-reconcile.log"; : > "$_bfb_log"
_t_bfb="$TMP/target-idg-batch-fb"; mkstate "$_t_bfb" 0 "high|done gap|covered"
mkdir -p "$_t_bfb/retros"
printf '<!-- review-status: pending -->\n# Fallback retro\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | delta 1 | file.sh | ev | new | high |\n' \
  > "$_t_bfb/retros/fallback-retro.md"
_bfb_got="$(_IDG_RECORD_LOG="$_bfb_log" \
  bash "$_kit_bfb/research-sdd-status.sh" "$_t_bfb" --next 2>/dev/null)"
_bfb_log_lines="$(grep -c '' "$_bfb_log" 2>/dev/null || echo 0)"
case "$_bfb_got" in
  ISSUES-DUE\ *)
    ok "T-IDG-BATCH-FALLBACK: batch fail → per-retro fallback → ISSUES-DUE (untracked found)" ;;
  *)
    no "T-IDG-BATCH-FALLBACK: expected ISSUES-DUE, got [$_bfb_got]" ;;
esac
if [ "${_bfb_log_lines:-0}" -gt 0 ] 2>/dev/null; then
  ok "T-IDG-BATCH-FALLBACK: per-retro reconcile WAS invoked (log has ${_bfb_log_lines} entr(ies))"
else
  no "T-IDG-BATCH-FALLBACK: reconcile log empty — per-retro fallback not invoked (SPOF regression)"
fi

# T-IDG-BATCH-FALSE-NEG: batch cache reports UNTRACKED for a retro, but per-retro re-verify returns
# TRACKED → batch was a false negative (exit-0 truncated/empty/rate-limited gh response).
# Gate must NOT emit ISSUES-DUE; re-verify trusts the narrowed probe and treats the retro as tracked.
# Stub: "cache_untracked_reverify_tracked" — returns "untracked" WITH --issues-cache (batch path),
# "tracked" WITHOUT --issues-cache (re-verify path) → simulates batch false-negative.
# Expected BEFORE fix (RED): ISSUES-DUE (gate trusts batch untracked without re-verifying).
# Expected AFTER fix (GREEN): STOP | read-only-investigable exhausted (0).
_kit_bfn="$TMP/kit-idg-batch-false-neg"; mk_kit "$_kit_bfn" "cache_untracked_reverify_tracked"
_t_bfn="$TMP/target-idg-batch-false-neg"; mkstate "$_t_bfn" 0 "high|done gap|covered"
mkdir -p "$_t_bfn/retros"
printf '<!-- review-status: pending -->\n# False-neg retro\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | delta 1 | file.sh | ev | new | high |\n' \
  > "$_t_bfn/retros/false-neg-retro.md"
_bfn_got="$(bash "$_kit_bfn/research-sdd-status.sh" "$_t_bfn" --next 2>/dev/null)"
if [ "$_bfn_got" = "STOP | read-only-investigable exhausted (0)" ]; then
  ok "T-IDG-BATCH-FALSE-NEG: batch untracked + per-retro tracked → re-verify clears false-neg → clean STOP"
else
  no "T-IDG-BATCH-FALSE-NEG: expected clean STOP (false-neg cleared by re-verify), got [$_bfn_got]"
fi

# T-IDG-BATCH-FALSE-NEG-CONFIRMED: batch cache AND per-retro re-verify both say UNTRACKED →
# genuinely untracked → ISSUES-DUE. Assert re-verify was actually invoked via recording stub.
# Stub: "recording_untracked" (returns "untracked" regardless; logs each call to _IDG_RECORD_LOG).
# For 1 retro with batch mode: batch reconcile call logs 1 entry; re-verify call logs 2nd entry →
# ≥2 log lines prove the re-verify call happened (not just the initial batch classification).
# Expected BEFORE fix (RED on confirm assertion): 1 log line (no re-verify called).
# Expected AFTER fix (GREEN): ≥2 log lines AND ISSUES-DUE.
_kit_bfnc="$TMP/kit-idg-batch-false-neg-conf"; mk_kit "$_kit_bfnc" "recording_untracked"
_bfnc_log="$TMP/bfnc-reconcile.log"; : > "$_bfnc_log"
_t_bfnc="$TMP/target-idg-batch-false-neg-conf"; mkstate "$_t_bfnc" 0 "high|done gap|covered"
mkdir -p "$_t_bfnc/retros"
printf '<!-- review-status: pending -->\n# Confirmed-untracked retro\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | delta 1 | file.sh | ev | new | high |\n' \
  > "$_t_bfnc/retros/confirmed-retro.md"
_bfnc_got="$(_IDG_RECORD_LOG="$_bfnc_log" \
  bash "$_kit_bfnc/research-sdd-status.sh" "$_t_bfnc" --next 2>/dev/null)"
_bfnc_log_lines="$(grep -c '' "$_bfnc_log" 2>/dev/null || echo 0)"
case "$_bfnc_got" in
  ISSUES-DUE\ *) ok "T-IDG-BATCH-FALSE-NEG-CONFIRMED: batch+re-verify both untracked → ISSUES-DUE" ;;
  *) no "T-IDG-BATCH-FALSE-NEG-CONFIRMED: expected ISSUES-DUE, got [$_bfnc_got]" ;;
esac
if [ "${_bfnc_log_lines:-0}" -ge 2 ] 2>/dev/null; then
  ok "T-IDG-BATCH-FALSE-NEG-CONFIRMED: re-verify invoked — reconcile called ${_bfnc_log_lines} time(s) for 1 retro (batch call + re-verify call)"
else
  no "T-IDG-BATCH-FALSE-NEG-CONFIRMED: expected ≥2 reconcile calls (batch+re-verify), got ${_bfnc_log_lines} — re-verify not yet implemented"
fi

# T-SC-CROSS-CHECK: verify-state.sh SC-CROSS-CHECK must FIRE when stop-control prose contradicts the
# backlog-derived investigable count. This test was RED before the printf '- ' fix (#883) because
# printf '- **Open gaps ...\n' treats the leading dash as a printf option on bash 5.2+, writes nothing
# to the fixture, and SC-CROSS-CHECK silently skips the absent prose line — the exact blind spot the
# fix closes. With the fixed idiom (printf '%s\n' '- ...'), the prose line reaches the fixture and
# the check fires as designed.
#
# Fixture: 1 pending investigable gap (d_inv=1), envelope investigable_open=1 (CHECK A passes),
# prose says 0 → mismatch → SC-CROSS-CHECK must emit a FAIL line.
_SC_CROSS_CHECK_FAIL='   FAIL   stop-control prose'  # stable grep anchor for SC-CROSS-CHECK FAIL output
d_sccc="$TMP/sc-cross-check-mismatch"; mkdir -p "$d_sccc"
{ printf '# SC-CROSS-CHECK Test\n> intro\n'
  env_lines 0 0 1 1 0 0
  printf '\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
  printf '| high | open investigable gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
  printf '%s\n' '- **Open gaps — read-only investigable**: 0'  # SC-CROSS-CHECK-FIRES-SENTINEL: prose=0, derived=1
} > "$d_sccc/RESEARCH-STATE.md"
_sccc_out="$(bash "$HERE/../verify-state.sh" "$d_sccc" 2>&1)"
if echo "$_sccc_out" | grep -qF "$_SC_CROSS_CHECK_FAIL"; then
  ok "T-SC-CROSS-CHECK: verify-state SC-CROSS-CHECK fires (FAIL + stop-control prose) when prose (0) contradicts derived count (1)"
else
  no "T-SC-CROSS-CHECK: verify-state passed silently — SC-CROSS-CHECK did not fire on prose mismatch (prose absent or check skipped)"
fi

# ── #911 A2: multi-table backlog reader ─────────────────────────────────────────────────────────
# T-5COL-NOMALFORMED: a 5-column Gap-backlog table must NOT emit "malformed backlog row" WARN;
# before the fix the n!=4 check fires on every row → WARN logged and rows dropped.
d_5c="$TMP/fivecol-warn"; mkdir -p "$d_5c"
{ echo "# T"; echo; env_lines 0 0 0 0 0 0; echo
  echo "## Gap-backlog (prioritized)"; echo
  echo "| Pr. | ID | Gap | Artifact | Status |"; echo "|---|---|---|---|---|"
  echo "| high | G1 | five-col gap | bin.dll | pending |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d_5c/RESEARCH-STATE.md"
_5c_warn="$(bash "$SUT" "$d_5c" --next 2>&1 >/dev/null)"
if echo "$_5c_warn" | grep -qi 'malformed backlog row'; then
  no "T-5COL-NOMALFORMED: 5-col Gap-backlog row emits malformed-WARN (should parse correctly after fix)"
else
  ok "T-5COL-NOMALFORMED: 5-col Gap-backlog row parsed without malformed-WARN"
fi

# T-5COL-SYNC: --sync-state must derive known_gaps≥1 from a 5-col Gap-backlog table;
# before the fix n!=4 drops all rows → count_all_known_gaps=0 → known_gaps falls back to
# the coverage metric (0 here) → the envelope is left with known_gaps: 0.
d_5cs="$TMP/fivecol-sync"; mkdir -p "$d_5cs"
{ echo "# T"; echo; env_lines 0 0 0 0 0 0; echo
  echo "## Gap-backlog (prioritized)"; echo
  echo "| Pr. | ID | Gap | Artifact | Status |"; echo "|---|---|---|---|---|"
  echo "| high | G1 | five-col pending gap | bin.dll | pending |"
  echo "| low  | G2 | five-col covered gap | bin.dll | covered |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d_5cs/RESEARCH-STATE.md"
bash "$SUT" "$d_5cs" --sync-state >/dev/null 2>&1
_5cs_kg="$(awk '/<!-- research-state.v1 -->/{b=1;next}/<!-- \/research-state.v1 -->/{b=0}b&&/^[[:space:]]*known_gaps:/{print $2;exit}' "$d_5cs/RESEARCH-STATE.md")"
if [ "${_5cs_kg:-0}" -ge 2 ]; then
  ok "T-5COL-SYNC: --sync-state derived known_gaps=${_5cs_kg} ≥ 2 from 5-col Gap-backlog"
else
  no "T-5COL-SYNC: --sync-state derived known_gaps=${_5cs_kg:-0}, want ≥2 (5-col rows not counted)"
fi

# T-TWO-TABLE-SYNC: --sync-state must derive known_gaps that reflects BOTH tables — NG* rows in
# a non-Gap-backlog section AND N* rows in the canonical ## Gap-backlog section.
# Before the fix: NG* rows silently skipped (in_backlog=0 + n=5); N* rows WARNed and dropped
# (in_backlog=1 + n=5 ≠ 4) → total=0 → known_gaps falls back to coverage metric (0 here).
d_tt="$TMP/two-table"; mkdir -p "$d_tt"
{ echo "# T"; echo; env_lines 0 0 0 0 0 0; echo
  echo "## Sub-pass (non-Gap-backlog heading)"; echo
  echo "| Pr. | ID | Gap | Artifact | Status |"; echo "|---|---|---|---|---|"
  echo "| high | NG1 | first-table covered gap | bin.dll | covered -> B1 |"; echo
  echo "## Gap-backlog (prioritized)"; echo
  echo "| Pr. | ID | Gap | Artifact | Status |"; echo "|---|---|---|---|---|"
  echo "| low | N1 | second-table covered gap | bin2.dll | covered -> B2 |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d_tt/RESEARCH-STATE.md"
bash "$SUT" "$d_tt" --sync-state >/dev/null 2>&1
_tt_kg="$(awk '/<!-- research-state.v1 -->/{b=1;next}/<!-- \/research-state.v1 -->/{b=0}b&&/^[[:space:]]*known_gaps:/{print $2;exit}' "$d_tt/RESEARCH-STATE.md")"
if [ "${_tt_kg:-0}" -ge 2 ]; then
  ok "T-TWO-TABLE-SYNC: --sync-state derived known_gaps=${_tt_kg} ≥ 2 (both tables counted)"
else
  no "T-TWO-TABLE-SYNC: --sync-state derived known_gaps=${_tt_kg:-0}, want ≥2 (second table not counted)"
fi

# T-OOB-WARN: a backlog-format row outside ## Gap-backlog must emit OOB-WARN to stderr so the
# author knows to migrate it per METHODOLOGY §8b. Use --sync-state so backlog_rows runs directly
# (--next silences verify-state stderr via its stale gate, swallowing the WARN).
d_oob="$TMP/oob-warn"; mkdir -p "$d_oob"
{ echo "# T"; echo; env_lines 0 0 0 0 0 0; echo
  echo "## Non-canonical heading"; echo
  echo "| Pr. | ID | Gap | Artifact | Status |"; echo "|---|---|---|---|---|"
  echo "| high | NG1 | oob covered gap | bin.dll | covered -> B1 |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d_oob/RESEARCH-STATE.md"
_oob_warn="$(bash "$SUT" "$d_oob" --sync-state 2>&1 >/dev/null)"
if echo "$_oob_warn" | grep -qi 'Gap-backlog\|gap.backlog'; then
  ok "T-OOB-WARN: OOB-WARN emitted for backlog-format row outside ## Gap-backlog section"
else
  no "T-OOB-WARN: no WARN mentioning Gap-backlog for row outside ## Gap-backlog section"
fi

# T-MED-ABBREV-WARN: 'med' priority must emit a normalization WARN, not INVALID_PRIORITY.
# Before the fix: 'med' hits the unknown-priority branch → INVALID_PRIORITY sentinel on stdout
# and a generic "unknown priority" message on stderr; --sync-state refuses with error exit 1.
d_med="$TMP/med-abbrev"; mkdir -p "$d_med"
{ echo "# T"; echo; env_lines 0 0 0 0 0 0; echo
  echo "## Gap-backlog"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| med | medium-tier gap | web | covered |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d_med/RESEARCH-STATE.md"
_med_warn="$(bash "$SUT" "$d_med" --next 2>&1 >/dev/null)"
if echo "$_med_warn" | grep -qi 'tier.abbrev\|non-conforming.*tier\|med.*medium\|MED-ABBREV'; then
  ok "T-MED-ABBREV-WARN: 'med' priority emits a tier-normalization WARN"
else
  no "T-MED-ABBREV-WARN: 'med' priority did not emit a tier-normalization WARN"
fi

# T-MED-ABBREV-SYNC: 'med' row must be counted by --sync-state (not INVALID_PRIORITY-rejected).
# Before the fix: INVALID_PRIORITY sentinel → BP-SYNC-INVALID-REFUSE → exit 1.
d_meds="$TMP/med-sync"; mkdir -p "$d_meds"
{ echo "# T"; echo; env_lines 0 0 0 0 0 0; echo
  echo "## Gap-backlog"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| med | med-abbrev gap | web | covered |"; echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d_meds/RESEARCH-STATE.md"
bash "$SUT" "$d_meds" --sync-state >/dev/null 2>&1; _med_sync_rc=$?
_meds_kg="$(awk '/<!-- research-state.v1 -->/{b=1;next}/<!-- \/research-state.v1 -->/{b=0}b&&/^[[:space:]]*known_gaps:/{print $2;exit}' "$d_meds/RESEARCH-STATE.md")"
if [ "$_med_sync_rc" -eq 0 ] && [ "${_meds_kg:-0}" -ge 1 ]; then
  ok "T-MED-ABBREV-SYNC: 'med' row counted (known_gaps=${_meds_kg}) and --sync-state exits 0"
else
  no "T-MED-ABBREV-SYNC: 'med' row not counted (known_gaps=${_meds_kg:-0}, rc=$_med_sync_rc) — INVALID_PRIORITY not normalized"
fi

# NEGATIVE CONTROL — reverse the priority order; the "high beats low" fixture must then pick LOW.
if [ "${1:-}" = "--prove-teeth" ]; then
  # The mutant status scripts resolve $here to $TMP, so they need verify-state.sh at $TMP/verify-state.sh.
  # verify-state.sh sources lib/focus-prefix.sh; status.sh also sources lib/state-files.sh after the fix.
  # lib/retro-status.sh is also included so the PERF pre-filter runs inside mutants (safe: no markers
  # in teeth fixtures, so the pre-filter is transparent for existing mutant scenarios).
  mkdir -p "$TMP/lib"
  cp "$HERE/../lib/focus-prefix.sh" "$TMP/lib/focus-prefix.sh"
  cp "$HERE/../lib/state-files.sh" "$TMP/lib/state-files.sh"
  cp "$HERE/../lib/block-files.sh" "$TMP/lib/block-files.sh"  # SUT sources at $(dirname $0)/lib/
  cp "$HERE/../lib/retro-status.sh" "$TMP/lib/retro-status.sh"

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
  echo "-- teeth-#449e: wforms reverted to \$all_sorted → reopen form re-appears → guard has teeth (NG-WFORMS-ITER-ONLY) --"
  e449e_mut="$TMP/status.449E.MUTANT.sh"
  if grep -q 'NG-WFORMS-ITER-ONLY' "$SUT"; then
    # mutant: on the NG-WFORMS-ITER-ONLY line, swap "$iter_window" to "$all_sorted" (includes struct rows)
    sed '/NG-WFORMS-ITER-ONLY/ s/"\$iter_window"/"$all_sorted"/' "$SUT" > "$e449e_mut"
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
  echo "-- teeth-#476: reopen-tail wforms reverted to \$all_sorted → REOPEN-form appears + verdict unchanged --"
  t476_mut="$TMP/status.476.MUTANT.sh"
  if grep -q 'NG-WFORMS-ITER-ONLY' "$SUT"; then
    sed '/NG-WFORMS-ITER-ONLY/ s/"\$iter_window"/"$all_sorted"/' "$SUT" > "$t476_mut"
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
        ok "teeth-#476: wforms reverted to \$all_sorted → REOPEN-form re-appears; verdict count unchanged (guard has teeth)"
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
  # teeth-sync-bs-cb: neuter shared-global cb branch; attributed corpus must revert to per-focus count.
  # Use an attributed fixture (B1,B2 → cb=2 on real SUT) so SYNCCB mutant (per-focus = 5 files) differs.
  # After #905 fix, the 0-attributed d52 fixture is not suitable: both real SUT and mutant give cb=0.
  d_cbm="$TMP/sync-bs-cb-tooth"; mkdir -p "$d_cbm"
  for _i in 1 2 3 4 5; do printf 'x\n' > "$d_cbm/cb-bloque${_i}.md"; done
  { printf '# T\n> intro\n'
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 2\n'
    printf 'gaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\n'
    printf 'blocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope: shared-global\n'
    printf '<!-- /research-state.v1 -->\n'
    printf '\n## Covered blocks\nB1, B2\n'
    printf '\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n'
    printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n'
  } > "$d_cbm/RESEARCH-STATE-cb.md"
  echo "-- teeth-sync-bs-cb: neuter shared-global cb branch; attributed corpus (cb=2) must revert to per-focus (cb=5) --"
  mu_cb="$TMP/status.SYNCCB.MUTANT.sh"
  sed 's/if \[ "\$_e_bs" = "shared-global" \]; then$/if false; then  # MUTANT-SYNCCB/' "$SUT" > "$mu_cb"
  if ! grep -q 'MUTANT-SYNCCB' "$mu_cb"; then
    no "teeth-sync-bs-cb: could not build mutant (_e_bs=shared-global branch not found — did SUT change?)"
  else
    bash "$SUT" "$d_cbm" --sync-state >/dev/null 2>&1
    _cbm_real="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^covered_blocks:/{print $2; exit}' "$d_cbm/RESEARCH-STATE-cb.md")"
    bash "$mu_cb" "$d_cbm" --sync-state >/dev/null 2>&1
    _cbm="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^covered_blocks:/{print $2; exit}' "$d_cbm/RESEARCH-STATE-cb.md")"
    [ "$_cbm_real" = "2" ] && [ "$_cbm" != "2" ] \
      && ok "teeth-sync-bs-cb: real SUT cb=${_cbm_real}(want 2); SYNCCB mutant cb=${_cbm}(want ≠2) → T-905-SG-ATTR is load-bearing" \
      || no "teeth-sync-bs-cb: real=${_cbm_real}(want 2) mutant=${_cbm}(want ≠2) — THEATER"; fi
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

  # T-SS2 teeth: neuter _read_focuses_tok at the function body entry point (N194-FOCUSES-SKIP-FN)
  # so that ALL three skip paths (--next aggregation, STALE bypass, default-status subshell) are
  # disabled simultaneously.  Bites T-SS2a (--next), T-SS2e (STALE bypass), T-SS2f (default-status).
  echo "-- teeth-SS2: neuter _read_focuses_tok via N194-FOCUSES-SKIP-FN; all three skip paths must re-surface --"
  ss2_mutant="$TMP/status.SS2.MUTANT.sh"
  if grep -q '# N194-FOCUSES-SKIP-FN' "$SUT"; then
    # Replace the file-existence guard (the first statement in the function body) with a bare
    # return so _read_focuses_tok always returns empty regardless of input.
    sed '/# N194-FOCUSES-SKIP-FN/s/\[ -f "\$ffile" \] || return.*/return  # MUTANT-SS2: _read_focuses_tok disabled/' "$SUT" > "$ss2_mutant"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    # Direction A: --next aggregation (T-SS2a fixture: paused aaa sorts before active zzz)
    ss2a_mgot="$(bash "$ss2_mutant" "$TMP/ss2-paused" --next 2>/dev/null)"
    if [ "$ss2a_mgot" = "NEXT | high | paused-open-gap" ]; then
      ok "teeth-SS2-A: neutered _read_focuses_tok → NEXT | high | paused-open-gap — --next skip is load-bearing"
    else
      no "teeth-SS2-A: mutant returned [$ss2a_mgot] (want NEXT | high | paused-open-gap) — --next skip is THEATER or fixture broken"
    fi
    # Direction B: STALE bypass (T-SS2e fixture: paused focus has stale envelope)
    ss2e_mgot="$(bash "$ss2_mutant" "$TMP/ss2-stale-bypass" --next 2>/dev/null)"
    case "$ss2e_mgot" in
      STALE\ *) ok "teeth-SS2-B: neutered _read_focuses_tok → paused stale focus not bypassed → STALE — STALE-bypass skip is load-bearing";;
      *)        no "teeth-SS2-B: mutant returned [$ss2e_mgot] — STALE-bypass skip is THEATER or fixture broken";;
    esac
    # Direction C: default-status subshell (T-SS2b fixture: both focuses paused/stopped with open gaps)
    ss2f_mgot="$(bash "$ss2_mutant" "$TMP/ss2-all-paused" 2>/dev/null | grep 'next step')"
    if echo "$ss2f_mgot" | grep -q 'NEXT'; then
      ok "teeth-SS2-C: neutered _read_focuses_tok → default-status next-step returns NEXT (skip removed) — default-status skip is load-bearing"
    else
      no "teeth-SS2-C: mutant default-status next-step [$ss2f_mgot] — expected NEXT, skip not biting"
    fi
    # Direction D: niagara+HotelHilton fixture (T-SS2d) — D8+D9 regression fixture must bite.
    # With mutant: paused aaa sorts first → niafoo-gap returned (skip disabled).
    # Proves bold/half-bold/link stripping AND sort-first positioning are load-bearing.
    ss2d_mgot="$(bash "$ss2_mutant" "$TMP/ss2-niagara-fmt" --next 2>/dev/null)"
    if [ "$ss2d_mgot" = "NEXT | high | niafoo-gap" ]; then
      ok "teeth-SS2-D: neutered _read_focuses_tok on niagara+hilton fixture → NEXT | high | niafoo-gap — D1/D8 fix is load-bearing"
    else
      no "teeth-SS2-D: mutant returned [$ss2d_mgot] (want NEXT | high | niafoo-gap) — fixture not biting"
    fi
    # Direction D-sfcol: sfcol-match fixture (T-SS2d-sfcol) — (base) RESEARCH-STATE.md stopped, single focus.
    # With mutant: (base) row undetected → NEXT | high | base-gap; new SUT → STOP (sfcol match fires).
    ss2d_sfcol_mgot="$(bash "$ss2_mutant" "$TMP/ss2-sfcol-match" --next 2>/dev/null)"
    if [ "$ss2d_sfcol_mgot" = "NEXT | high | base-gap" ]; then
      ok "teeth-SS2-D-sfcol: neutered on sfcol fixture → NEXT | high | base-gap — sfcol skip path is load-bearing"
    else
      no "teeth-SS2-D-sfcol: mutant returned [$ss2d_sfcol_mgot] (want NEXT | high | base-gap) — sfcol path THEATER or fixture broken"
    fi
  else
    no "teeth-SS2: N194-FOCUSES-SKIP-FN sentinel not found in SUT"
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

  # issue #424 teeth-BOLD-STRIP: neuter ** strip in BOTH layers (defense-in-depth); **pending** must stay dropped.
  # BOLD-STRIP (count_investigable) and SS-634-BOLD-STRIP (backlog_rows) form a two-layer defense:
  # removing only one still leaves the other operative → both must be neutered to prove the mechanism bites.
  echo "-- teeth-#424-bold-strip: neuter BOLD-STRIP + SS-634-BOLD-STRIP (both layers); **pending** must not count investigable --"
  bold_mutant="$TMP/status.BOLD-MUTANT.sh"
  sed '/# BOLD-STRIP$/s/.*/    lead="$st"  # MUTANT-BOLD: strip neutered/' "$SUT" \
    | sed '/# SS-634-BOLD-STRIP/s/.*/      { st=tolower(a[4]) }  # SS-634-BOLD-STRIP-MUTANT: backlog strip also removed/' \
    > "$bold_mutant"
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

  # T-641 teeth: inject an early INVALID_PRIORITY check BEFORE the FOCUSES.md stopped-check so that a
  # stopped focus with a malformed priority bricks the bypass loop (reverting the pre-fix bug order).
  # The T-641 fixture (stopped MED + active high) must return STALE instead of NEXT.
  echo "-- teeth-#641: early INVALID_PRIORITY before FOCUSES check; stopped-MED corpus must return STALE --"
  n641_mutant="$TMP/status.N641.MUTANT.sh"
  if grep -q '# N641-FOCUSES-BEFORE-INVALID-PRIORITY' "$SUT"; then
    awk '/# N641-FOCUSES-BEFORE-INVALID-PRIORITY/{
      print "        # MUTANT-641: INVALID_PRIORITY check moved before FOCUSES skip (reverts bug order)"
      print "        if backlog_rows 2>/dev/null | grep -q '"'"'^INVALID_PRIORITY'"'"'; then"
      print "          _any_real_stale=1; break  # MUTANT-641-EARLY"
      print "        fi"
    } { print }' "$SUT" > "$n641_mutant"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    n641_mgot="$(bash "$n641_mutant" "$d_641" --next 2>/dev/null)"
    case "$n641_mgot" in
      STALE\ *) ok "teeth-#641: early INVALID_PRIORITY mutant → STALE on stopped-MED corpus — fix is load-bearing" ;;
      NEXT\ *)  no "teeth-#641: mutant returned NEXT — fix is THEATER (INVALID_PRIORITY guard is not the stopper)" ;;
      *)        no "teeth-#641: mutant returned [$n641_mgot] (want STALE)" ;;
    esac
  else
    no "teeth-#641: N641-FOCUSES-BEFORE-INVALID-PRIORITY sentinel not found in SUT"
  fi

  # T-568 teeth: disable KG-BACKLOG-EXCEEDS branch so known_gaps always falls back to the coverage
  # metric Y even when the backlog total exceeds it. The T-568 fixture must then keep kg=9 (stale).
  echo "-- teeth-#568: disable KG-BACKLOG-EXCEEDS; stale-metric corpus must keep known_gaps=9 --"
  n568_mutant="$TMP/status.N568.MUTANT.sh"
  if grep -q '# KG-BACKLOG-EXCEEDS' "$SUT"; then
    sed 's/kg="${_dkg_total}"  # KG-BACKLOG-EXCEEDS/kg=""  # MUTANT-568: backlog-derived kg disabled/' "$SUT" > "$n568_mutant"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    n568_fixture="$TMP/t568-teeth-fix"; mkdir -p "$n568_fixture"
    { printf '# T568-teeth\n> intro\n'
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\n'
      printf 'gaps_closed: 4\nknown_gaps: 9\ninvestigable_open: 6\nrequires_execution_open: 0\n'
      printf 'blocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\n<!-- /research-state.v1 -->\n'
      printf '\n## Coverage\n- **Coverage metric**: 4 / 9 closed\n'
      printf '\n## Gap-backlog (prioritized)\n| P | Gap | type | Status |\n|---|---|---|---|\n'
      printf '| high | g1 | web | covered |\n'
      printf '| high | g2 | web | covered |\n'
      printf '| medium | g3 | web | covered |\n'
      printf '| low | g4 | web | covered |\n'
      printf '| high | g5 | web | pending |\n'
      printf '| high | g6 | web | pending |\n'
      printf '| medium | g7 | web | pending |\n'
      printf '| low | g8 | web | pending |\n'
      printf '| medium | g9 | web | pending |\n'
      printf '| high | g10-new | web | pending |\n'
      printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 6\n'
    } > "$n568_fixture/RESEARCH-STATE.md"
    bash "$n568_mutant" "$n568_fixture" --sync-state >/dev/null 2>&1
    _n568_kg="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^known_gaps:/{print $2; exit}' "$n568_fixture/RESEARCH-STATE.md")"
    if [ "$_n568_kg" != "10" ]; then
      ok "teeth-#568: KG-BACKLOG-EXCEEDS disabled → known_gaps=${_n568_kg} ≠ 10 — backlog-derived kg is load-bearing"
    else
      no "teeth-#568: mutant still wrote known_gaps=10 — KG-BACKLOG-EXCEEDS is not the active path (THEATER)"
    fi
  else
    no "teeth-#568: KG-BACKLOG-EXCEEDS sentinel not found in SUT"
  fi

  # T-530 teeth: disable SG-ATTR-SYNC by forcing _attr_sg=0.
  # After #905 fix (SG-ZERO-UNVERIFIABLE), the else branch seeds cb=0 (not corpus-wide).
  # So the T-530 fixture (5 disk files, 3 attributed) gets cb=0 with the mutant (not 3 attributed).
  # The assertion `_n530_cb != 3` still holds: forcing _attr_sg=0 proves the attributed count is load-bearing.
  echo "-- teeth-#530: disable SG-ATTR-SYNC; attributed corpus must not get cb=attributed count --"
  n530_mutant="$TMP/status.N530.MUTANT.sh"
  if grep -q '# SG-ATTR-SYNC' "$SUT"; then
    sed 's/_attr_sg="$(count_attributed_sg)"  # SG-ATTR-SYNC/_attr_sg=0  # MUTANT-530: attributed count disabled/' "$SUT" > "$n530_mutant"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    n530_fixture="$TMP/t530-teeth-fix"; mkdir -p "$n530_fixture"
    printf 'x\n' > "$n530_fixture/focus-bloque1.md"
    printf 'x\n' > "$n530_fixture/focus-bloque2.md"
    printf 'x\n' > "$n530_fixture/focus-bloque3.md"
    printf 'x\n' > "$n530_fixture/focus-bloque4.md"
    printf 'x\n' > "$n530_fixture/focus-bloque5.md"
    { printf '# T530-teeth\n> intro\n'
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 3\n'
      printf 'gaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\n'
      printf 'blocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope: shared-global\n'
      printf '<!-- /research-state.v1 -->\n'
      printf '\n## Covered blocks\nB1, B2, B3\n'
      printf '\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n'
      printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n'
    } > "$n530_fixture/RESEARCH-STATE-sg.md"
    bash "$n530_mutant" "$n530_fixture" --sync-state >/dev/null 2>&1
    _n530_cb="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^covered_blocks:/{print $2; exit}' "$n530_fixture/RESEARCH-STATE-sg.md")"
    if [ "$_n530_cb" != "3" ]; then
      ok "teeth-#530: SG-ATTR-SYNC disabled → covered_blocks=${_n530_cb} ≠ 3 — attributed count is load-bearing"
    else
      no "teeth-#530: mutant still wrote covered_blocks=3 — SG-ATTR-SYNC is not the active path (THEATER)"
    fi
  else
    no "teeth-#530: SG-ATTR-SYNC sentinel not found in SUT"
  fi

  # teeth-905-SG-ZERO: restore corpus-wide else-branch in 0-attributed path; must seed cb != 0.
  # Real SUT (fixed): 0-attributed focus → cb=0 (SG-ZERO-UNVERIFIABLE). Mutation: replace cb=0 with
  # a non-zero constant (99) — proving the sentinel guards the "seed 0" path, not just assigns
  # any value. Two separate mutations confirm both the cb value and the WARN are load-bearing.
  echo "-- teeth-905-SG-ZERO: cb=0 sentinel; 0-attributed focus must NOT silently get corpus count --"
  mu_905_cb="$TMP/status.905CB.MUTANT.sh"
  if grep -qF '# SG-ZERO-UNVERIFIABLE' "$SUT"; then
    sed 's/  cb=0  # SG-ZERO-UNVERIFIABLE/  cb=99  # MUTANT-905-CB: restored non-zero/' "$SUT" > "$mu_905_cb"
    if ! grep -qF 'MUTANT-905-CB' "$mu_905_cb"; then
      no "teeth-905-SG-ZERO: sed did not build MUTANT-905-CB (sentinel not found — did SUT change?)"
    else
      d_905z="$TMP/t905-sg-zero-tooth"; mkdir -p "$d_905z"
      printf 'x\n' > "$d_905z/niagara-bloque1.md"
      printf 'x\n' > "$d_905z/niagara-bloque2.md"
      printf 'x\n' > "$d_905z/niagara-bloque3.md"
      { printf '# T905Z\n> intro\n'
        printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\n'
        printf 'gaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\n'
        printf 'blocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope: shared-global\n'
        printf '<!-- /research-state.v1 -->\n'
        printf '\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n'
        printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n'
      } > "$d_905z/RESEARCH-STATE-nz.md"
      bash "$mu_905_cb" "$d_905z" --sync-state >/dev/null 2>&1
      _905z_cb="$(awk '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && /^covered_blocks:/{print $2; exit}' "$d_905z/RESEARCH-STATE-nz.md")"
      if [ "$_905z_cb" != "0" ]; then
        ok "teeth-905-SG-ZERO-CB: MUTANT-905-CB writes cb=${_905z_cb} ≠ 0 → test 52 cb=0 assertion is load-bearing"
      else
        no "teeth-905-SG-ZERO-CB: mutant still wrote cb=0 — THEATER (sentinel not the only path?)"
      fi
    fi
  else
    no "teeth-905-SG-ZERO: SG-ZERO-UNVERIFIABLE sentinel not found in SUT"
  fi

  echo "-- teeth-905-SG-ZERO-WARN: neuter SG-ZERO-WARN printf; test 52b WARN check must go RED --"
  mu_905_warn="$TMP/status.905WARN.MUTANT.sh"
  if grep -qF '# SG-ZERO-WARN' "$SUT"; then
    sed '/# SG-ZERO-WARN$/s/printf .*/: # MUTANT-905-WARN: warn disabled/' "$SUT" > "$mu_905_warn"
    if ! grep -qF 'MUTANT-905-WARN' "$mu_905_warn"; then
      no "teeth-905-SG-ZERO-WARN: sed did not build MUTANT-905-WARN (sentinel not found — did SUT change?)"
    else
      d_905w="$TMP/t905-sg-warn-tooth"; mkdir -p "$d_905w"
      printf 'x\n' > "$d_905w/niagara-bloque1.md"
      { printf '# T905W\n> intro\n'
        printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\n'
        printf 'gaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\n'
        printf 'blocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope: shared-global\n'
        printf '<!-- /research-state.v1 -->\n'
        printf '\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n'
        printf '\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n'
      } > "$d_905w/RESEARCH-STATE-warn.md"
      _905w_stderr="$(bash "$mu_905_warn" "$d_905w" --sync-state 2>&1 >/dev/null)"
      if echo "$_905w_stderr" | grep -qE 'WARN.*no attributed block ids|no attributed block ids.*WARN'; then
        no "teeth-905-SG-ZERO-WARN: MUTANT-905-WARN still emits WARN — THEATER (warn is not from this printf)"
      else
        ok "teeth-905-SG-ZERO-WARN: MUTANT-905-WARN silences WARN → test 52b WARN assertion is load-bearing"
      fi
    fi
  else
    no "teeth-905-SG-ZERO-WARN: SG-ZERO-WARN sentinel not found in SUT"
  fi

  # ---- teeth-SS-634-BOLD: remove ** stripping from BOTH layers; pending** must NOT count as investigable ----
  # SS-634-BOLD-STRIP (backlog_rows) and BOLD-STRIP (count_investigable) form a two-layer defense.
  # Removing only SS-634-BOLD-STRIP leaves BOLD-STRIP operative → io=1 (theater).
  # The combined mutant removes BOTH so neither strips → pending** is unrecognised → io=0.
  # T-634-SS expects investigable_open=1 → with combined mutant it sees 0 → assertion goes RED.
  echo "-- teeth-SS-634-BOLD: remove ** stripping from BOTH layers (SS-634-BOLD-STRIP + BOLD-STRIP); pending** must not count --"
  ss634_mutant="$TMP/status.SS634.MUTANT.sh"
  if grep -q '# SS-634-BOLD-STRIP' "$SUT"; then
    sed '/# SS-634-BOLD-STRIP/s/.*/      { st=tolower(a[4]) }  # SS-634-BOLD-STRIP-MUTANT: stripping removed/' "$SUT" \
      | sed '/# BOLD-STRIP$/s/.*/    lead="$st"  # MUTANT-BOLD-ALSO: count_investigable strip also removed/' \
      > "$ss634_mutant"
    if ! grep -q '# SS-634-BOLD-STRIP-MUTANT' "$ss634_mutant"; then
      no "teeth-SS-634-BOLD: could not build mutant (SS-634-BOLD-STRIP replacement failed — did SUT change?)"
    else
      cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
      _ss634_teeth_dir="$TMP/t634-ss-teeth-copy"; mkdir -p "$_ss634_teeth_dir"
      cp "$d_634/RESEARCH-STATE.md" "$_ss634_teeth_dir/RESEARCH-STATE.md"
      _ss634_out="$(bash "$ss634_mutant" "$_ss634_teeth_dir" --sync-state 2>/dev/null)"
      _ss634_io="$(printf '%s\n' "$_ss634_out" | grep -oE 'investigable_open=[0-9]+' | grep -oE '[0-9]+')"
      if [ "${_ss634_io:-0}" != "1" ]; then
        ok "teeth-SS-634-BOLD: without ** stripping, pending** → investigable_open=${_ss634_io:-0} ≠ 1 → T-634-SS assertion goes RED → SS-634-BOLD-STRIP is load-bearing"
      else
        no "teeth-SS-634-BOLD: mutant still computes investigable_open=1 — stripping removed but count unchanged — THEATER"
      fi
    fi
  else
    no "teeth-SS-634-BOLD: SS-634-BOLD-STRIP sentinel not found in SUT"
  fi

  # ---- teeth-SS-567-COVERED-PIPE: remove COVERED skip; COVERED pipe row must emit malformed WARN ----
  # Mutation: delete the SS-567-COVERED-PIPE-SKIP tagged line entirely.
  # T-567-SS fixture (t567-status-covered-pipe) has 'COVERED devType|address|...';
  # without the skip, n≠4 fires the malformed-row WARN → appears in stderr.
  # T-567-SS expects no WARN → assertion goes RED → SS-567-COVERED-PIPE-SKIP is load-bearing.
  echo "-- teeth-SS-567-COVERED-PIPE: delete COVERED skip (SS-567-COVERED-PIPE-SKIP); pipe row must emit WARN --"
  ss567_mutant="$TMP/status.SS567.MUTANT.sh"
  if grep -q '# SS-567-COVERED-PIPE-SKIP' "$SUT"; then
    sed '/# SS-567-COVERED-PIPE-SKIP/d' "$SUT" > "$ss567_mutant"
    if grep -q '# SS-567-COVERED-PIPE-SKIP' "$ss567_mutant"; then
      no "teeth-SS-567-COVERED-PIPE: could not build mutant (deletion failed — sentinel still present)"
    else
      cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
      _ss567_mut_err="$(bash "$ss567_mutant" "$d_567" 2>&1 >/dev/null)"
      if grep -q 'malformed backlog row' <<<"$_ss567_mut_err"; then
        ok "teeth-SS-567-COVERED-PIPE: removed COVERED skip → COVERED pipe row emits malformed WARN → T-567-SS goes RED → SS-567-COVERED-PIPE-SKIP is load-bearing"
      else
        no "teeth-SS-567-COVERED-PIPE: mutant did NOT emit malformed-row WARN for COVERED pipe row — THEATER"
      fi
    fi
  else
    no "teeth-SS-567-COVERED-PIPE: SS-567-COVERED-PIPE-SKIP sentinel not found in SUT"
  fi

  # ---- teeth-627: neuter RD-BLOCKS-SINCE-RETRO-CHECK; T-627a (bsr=11 RETRO-DUE) must return NEXT.
  # Mutation: replace the echo+exit in the RETRO-DUE block with a no-op comment.
  # T-627a expects RETRO-DUE → with the check neutered, the SUT falls through to NEXT | high | ...
  # → T-627a's `RETRO-DUE *` case never matches → assertion goes RED → RD-BLOCKS-SINCE-RETRO-CHECK is load-bearing.
  echo "-- teeth-627: neuter RD-THRESHOLD-CHECK; bsr=11 fixture must fall through to NEXT --"
  rd_mutant="$TMP/status.RD627.MUTANT.sh"
  if grep -q '# RD-THRESHOLD-CHECK' "$SUT"; then
    sed '/# RD-THRESHOLD-CHECK$/s/if printf.*/if false; then  # MUTANT-RD627/' "$SUT" > "$rd_mutant"
    if grep -q '# RD-THRESHOLD-CHECK' "$rd_mutant"; then
      no "teeth-627: could not build mutant (sed did not replace RD-THRESHOLD-CHECK — check sed pattern)"
    else
      cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
      rd_got="$(bash "$rd_mutant" "$TMP/t627-retro-due" --next 2>/dev/null)"
      case "$rd_got" in
        NEXT\ *) ok "teeth-627: neutered RD-BLOCKS-SINCE-RETRO-CHECK → bsr=11 returns NEXT → T-627a goes RED → check is load-bearing";;
        RETRO-DUE\ *) no "teeth-627: mutant still returned RETRO-DUE — RD-BLOCKS-SINCE-RETRO-CHECK is THEATER or mutant broken";;
        *) no "teeth-627: mutant returned unexpected [$rd_got] — fixture or mutant broken";;
      esac
    fi
  else
    no "teeth-627: RD-BLOCKS-SINCE-RETRO-CHECK sentinel not found in SUT"
  fi

  # ---- teeth-IDG: neuter ISSUES-DUE-GATE-COND; T-IDG-A (untracked fixture) must fall through to STOP.
  # Mutation: replace the untracked-count if-condition with `if false`, so the ISSUES-DUE block
  # is never entered and the function falls through to `STOP | read-only-investigable exhausted (0)`.
  # T-IDG-A expects ISSUES-DUE | ... → with the condition neutered, the output is STOP →
  # T-IDG-A's `ISSUES-DUE *` case never matches → assertion goes RED →
  # the ISSUES-DUE-GATE-COND condition is load-bearing.
  echo "-- teeth-IDG: neuter ISSUES-DUE-GATE-COND; untracked fixture must fall through to STOP --"
  idg_mutant="$TMP/status.IDG.MUTANT.sh"
  if grep -q '# ISSUES-DUE-GATE-COND' "$SUT"; then
    sed '/# ISSUES-DUE-GATE-COND$/s/if \[ .*/if false; then  # MUTANT-IDG/' "$SUT" > "$idg_mutant"
    if grep -q '# ISSUES-DUE-GATE-COND' "$idg_mutant"; then
      no "teeth-IDG: could not build mutant (sed did not replace ISSUES-DUE-GATE-COND — check sed pattern)"
    else
      # The mutant resolves $here to $TMP; provide stub reconcile-issues.sh + libs there.
      cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
      printf '#!/usr/bin/env bash\nprintf "untracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$TMP/reconcile-issues.sh"
      chmod +x "$TMP/reconcile-issues.sh"
      _idg_teeth_dir="$TMP/t-idg-teeth"
      mkstate "$_idg_teeth_dir" 0 "high|done gap|covered"
      mkdir -p "$_idg_teeth_dir/retros"
      touch "$_idg_teeth_dir/retros/2026-09-01-retro-teeth.md"
      _idg_teeth_got="$(bash "$idg_mutant" "$_idg_teeth_dir" --next 2>/dev/null)"
      case "$_idg_teeth_got" in
        ISSUES-DUE\ *) no "teeth-IDG: mutant still printed ISSUES-DUE → ISSUES-DUE-GATE-COND is THEATER";;
        STOP\ *) ok "teeth-IDG: condition neutered → falls through to STOP → T-IDG-A goes RED → ISSUES-DUE-GATE-COND is load-bearing";;
        *) no "teeth-IDG: mutant returned unexpected [$_idg_teeth_got] — fixture or mutant broken";;
      esac
    fi
  else
    no "teeth-IDG: ISSUES-DUE-GATE-COND sentinel not found in SUT"
  fi

  # ---- teeth-IDG-precedence: inject issues_due_gate BEFORE resolve_next via IDG-PREC-SENTINEL.
  # The IDG-PREC-SENTINEL no-op in the SUT guards the point where the gate must NOT fire early.
  # Mutant: replace the no-op with 'issues_due_gate; exit 0', so the gate fires before any
  # resolve_next call. T-IDG-D fixture has an active pending gap + a retro with untracked delta:
  # - Normal SUT: resolve_next returns NEXT → T-IDG-D passes.
  # - Mutant: issues_due_gate fires first → finds untracked → ISSUES-DUE → T-IDG-D expected
  #   NEXT → gets ISSUES-DUE → assertion goes RED → IDG-PREC-SENTINEL is load-bearing.
  echo "-- teeth-IDG-precedence: inject gate before resolve_next; T-IDG-D must go RED --"
  idg_prec_mutant="$TMP/status.IDG-PREC.MUTANT.sh"
  if grep -q '# IDG-PREC-SENTINEL' "$SUT"; then
    sed 's/: # IDG-PREC-SENTINEL.*/issues_due_gate; exit 0  # MUTANT-IDG-PREC/' "$SUT" > "$idg_prec_mutant"
    if grep -q '# IDG-PREC-SENTINEL' "$idg_prec_mutant"; then
      no "teeth-IDG-precedence: could not build mutant (sed did not replace IDG-PREC-SENTINEL — check sed pattern)"
    else
      cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
      printf '#!/usr/bin/env bash\nprintf "untracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$TMP/reconcile-issues.sh"
      chmod +x "$TMP/reconcile-issues.sh"
      _idg_prec_dir="$TMP/t-idg-prec-teeth"
      mkstate "$_idg_prec_dir" 1 "high|active-idg-gap|pending"
      mkdir -p "$_idg_prec_dir/retros"
      touch "$_idg_prec_dir/retros/2026-09-01-retro-prec.md"
      _idg_prec_got="$(bash "$idg_prec_mutant" "$_idg_prec_dir" --next 2>/dev/null)"
      case "$_idg_prec_got" in
        ISSUES-DUE\ *) ok "teeth-IDG-precedence: gate-first mutant → ISSUES-DUE → T-IDG-D goes RED → IDG-PREC-SENTINEL is load-bearing";;
        NEXT\ *)        no "teeth-IDG-precedence: mutant still returned NEXT — IDG-PREC-SENTINEL is THEATER or mutant broken";;
        *)              no "teeth-IDG-precedence: mutant returned unexpected [$_idg_prec_got] — fixture or mutant broken";;
      esac
    fi
  else
    no "teeth-IDG-precedence: IDG-PREC-SENTINEL not found in SUT"
  fi

  # ---- teeth-IDG-focus: replace IDG-FOCUS-GATE arm with passthrough; T-IDG-FOCUS must go RED.
  # The IDG-FOCUS-GATE sentinel marks the --focus STOP-arm call to issues_due_gate.
  # Mutant: replace issues_due_gate with a pass-through of the raw resolve_next output.
  # T-IDG-FOCUS expects ISSUES-DUE → mutant returns STOP → assertion goes RED →
  # IDG-FOCUS-GATE is load-bearing.
  echo "-- teeth-IDG-focus: passthrough mutant on --focus STOP arm; T-IDG-FOCUS must go RED --"
  idg_focus_mutant="$TMP/status.IDG-FOCUS.MUTANT.sh"
  if grep -q '# IDG-FOCUS-GATE' "$SUT"; then
    sed "s/issues_due_gate ;;  # IDG-FOCUS-GATE/printf '%s\\\\n' \"\$_rn_out\" ;;  # MUTANT-IDG-FOCUS/" \
      "$SUT" > "$idg_focus_mutant"
    if grep -q '# IDG-FOCUS-GATE' "$idg_focus_mutant"; then
      no "teeth-IDG-focus: could not build mutant (sed did not replace IDG-FOCUS-GATE — check sed pattern)"
    else
      cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
      printf '#!/usr/bin/env bash\nprintf "untracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$TMP/reconcile-issues.sh"
      chmod +x "$TMP/reconcile-issues.sh"
      _idg_focus_teeth_dir="$TMP/t-idg-focus-teeth"
      mkdir -p "$_idg_focus_teeth_dir"
      { echo "# Alpha — Research State"; echo
        env_lines 0 0 0 0 0 0; echo
        echo "## Gap-backlog"; echo "| P | G | t | S |"; echo "|-|-|-|-|"
        echo "| high | done gap | web | covered |"; echo
        echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"
      } > "$_idg_focus_teeth_dir/RESEARCH-STATE-alpha.md"
      mkdir -p "$_idg_focus_teeth_dir/retros"
      touch "$_idg_focus_teeth_dir/retros/2026-09-01-focus-teeth-retro.md"
      _idg_focus_teeth_got="$(bash "$idg_focus_mutant" "$_idg_focus_teeth_dir" --next --focus alpha 2>/dev/null)"
      case "$_idg_focus_teeth_got" in
        ISSUES-DUE\ *) no "teeth-IDG-focus: mutant still printed ISSUES-DUE → IDG-FOCUS-GATE is THEATER";;
        STOP\ *)        ok "teeth-IDG-focus: passthrough mutant → STOP → T-IDG-FOCUS goes RED → IDG-FOCUS-GATE is load-bearing";;
        *)              no "teeth-IDG-focus: mutant returned unexpected [$_idg_focus_teeth_got] — fixture or mutant broken";;
      esac
    fi
  else
    no "teeth-IDG-focus: IDG-FOCUS-GATE sentinel not found in SUT"
  fi

  # ---- teeth-IDG-unverified-marker: replace distinct STOP with _stop_exhausted; T-IDG-C must go RED.
  # The IDG-UNVERIFIED-MARKER sentinel guards the printf that emits the generic
  # '[issue-coverage: unverified]' suffix.  A mutant that silently falls back to the bare STOP
  # would make any unverified condition indistinguishable from verified-clean, violating R4-DEGRADED.
  # This tooth ensures that behaviour is load-bearing.
  echo "-- teeth-IDG-unverified-marker: bare-STOP mutant; T-IDG-C must go RED --"
  idg_unver_mutant="$TMP/status.IDG-UNVERIFIED-MARKER.MUTANT.sh"
  if grep -q '# IDG-UNVERIFIED-MARKER' "$SUT"; then
    sed '/# IDG-UNVERIFIED-MARKER/s/.*/_stop_exhausted  # MUTANT-IDG-UNVERIFIED-MARKER/' \
      "$SUT" > "$idg_unver_mutant"
    if grep -q '# IDG-UNVERIFIED-MARKER' "$idg_unver_mutant"; then
      no "teeth-IDG-unverified-marker: could not build mutant (sed did not replace IDG-UNVERIFIED-MARKER)"
    else
      _unver_kit="$TMP/kit-teeth-unver"
      mkdir -p "$_unver_kit/lib"
      cp "$idg_unver_mutant" "$_unver_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_unver_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_unver_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_unver_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_unver_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_unver_kit/lib/retro-status.sh"
      printf '#!/usr/bin/env bash\nprintf "degraded: gh not authenticated\\n" >&2\nexit 1\n' \
        > "$_unver_kit/reconcile-issues.sh"
      chmod +x "$_unver_kit/reconcile-issues.sh"
      _unver_target="$TMP/target-teeth-unver"
      mkstate "$_unver_target" 0 "high|done gap|covered"
      mkdir -p "$_unver_target/retros"
      touch "$_unver_target/retros/2026-09-01-teeth-unver-retro.md"
      _unver_got="$(bash "$_unver_kit/research-sdd-status.sh" "$_unver_target" --next 2>/dev/null)"
      if printf '%s\n' "$_unver_got" | grep -qF '[issue-coverage: unverified]'; then
        no "teeth-IDG-unverified-marker: mutant still printed distinct marker → IDG-UNVERIFIED-MARKER is THEATER"
      else
        ok "teeth-IDG-unverified-marker: bare-STOP mutant → distinct marker absent → T-IDG-C goes RED → IDG-UNVERIFIED-MARKER is load-bearing"
      fi
    fi
  else
    no "teeth-IDG-unverified-marker: IDG-UNVERIFIED-MARKER sentinel not found in SUT"
  fi

  # ---- teeth-IDG-timeout: neuter IDG-TIMEOUT-WRAP + IDG-REVERIFY-TIMEOUT-WRAP; T-IDG-TIMEOUT must go RED.
  # IDG-TIMEOUT-WRAP guards the per-retro reconcile call; IDG-REVERIFY-TIMEOUT-WRAP guards the
  # re-verify call triggered when the batch cache was used and the retro looks untracked.
  # Both wrappers are neutralized: when the batch call succeeds the reverify path is exercised,
  # so the re-verify wrapper must also be removed for the stub to complete unbounded.
  # With _IDG_RECONCILE_TIMEOUT_SECS=1 and a 3s-sleep stub, the original times out on either
  # wrapper (→ unverified marker) while the mutant completes normally (→ ISSUES-DUE), so
  # T-IDG-TIMEOUT (which expects the unverified marker) goes RED.
  echo "-- teeth-IDG-timeout: neuter IDG-TIMEOUT-WRAP; T-IDG-TIMEOUT must go RED --"
  idg_tmt_mutant="$TMP/status.IDG-TIMEOUT-WRAP.MUTANT.sh"
  if grep -q '# IDG-TIMEOUT-WRAP' "$SUT"; then
    sed '/# IDG.*TIMEOUT-WRAP/s/"$_idg_timeout_bin" "$_idg_timeout_secs" //' \
      "$SUT" > "$idg_tmt_mutant"
    if grep -F '# IDG-TIMEOUT-WRAP' "$idg_tmt_mutant" | grep -qF '"$_idg_timeout_bin"' || \
       grep -F '# IDG-REVERIFY-TIMEOUT-WRAP' "$idg_tmt_mutant" | grep -qF '"$_idg_timeout_bin"'; then
      no "teeth-IDG-timeout: could not build mutant (sed did not remove _idg_timeout_bin from IDG-TIMEOUT-WRAP or IDG-REVERIFY-TIMEOUT-WRAP)"
    else
      _tmt_mut_kit="$TMP/kit-teeth-tmt"
      mkdir -p "$_tmt_mut_kit/lib"
      cp "$idg_tmt_mutant" "$_tmt_mut_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_tmt_mut_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_tmt_mut_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_tmt_mut_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_tmt_mut_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_tmt_mut_kit/lib/retro-status.sh"
      # Same 3s-sleep stub as T-IDG-TIMEOUT; mutant removes timeout wrapper → stub completes normally.
      printf '#!/usr/bin/env bash\nsleep 3\nprintf "untracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$_tmt_mut_kit/reconcile-issues.sh"
      chmod +x "$_tmt_mut_kit/reconcile-issues.sh"
      _tmt_mut_target="$TMP/target-teeth-tmt"
      mkstate "$_tmt_mut_target" 0 "high|done gap|covered"
      mkdir -p "$_tmt_mut_target/retros"
      touch "$_tmt_mut_target/retros/2026-09-01-teeth-tmt-retro.md"
      _tmt_mut_got="$(env _IDG_RECONCILE_TIMEOUT_SECS=1 bash "$_tmt_mut_kit/research-sdd-status.sh" \
        "$_tmt_mut_target" --next 2>/dev/null)"
      if printf '%s\n' "$_tmt_mut_got" | grep -qF '[issue-coverage: unverified'; then
        no "teeth-IDG-timeout: mutant still returned unverified marker → IDG-TIMEOUT-WRAP is THEATER"
      else
        case "$_tmt_mut_got" in
          ISSUES-DUE\ *) ok "teeth-IDG-timeout: remove-wrapper mutant → ISSUES-DUE (stub completed unbounded) → T-IDG-TIMEOUT goes RED → IDG-TIMEOUT-WRAP is load-bearing" ;;
          *) no "teeth-IDG-timeout: mutant returned unexpected [$_tmt_mut_got] — fixture or mutant broken" ;;
        esac
      fi
    fi
  else
    no "teeth-IDG-timeout: IDG-TIMEOUT-WRAP sentinel not found in SUT"
  fi

  # ---- teeth-IDG-contract: corrupt awk pattern; T-IDG-CONTRACT must go RED.
  # The IDG-UNTRACKED-PATTERN sentinel guards the awk '/^untracked:/' line that
  # counts reconcile-issues.sh output lines.  A mutant that changes the pattern
  # to /^UNTRACKED:/ (wrong case) silently counts 0 even when real reconcile output
  # is present, hiding the ISSUES-DUE signal.  This tooth ensures the parser↔producer
  # contract is enforced.
  echo "-- teeth-IDG-contract: corrupt-awk-pattern mutant; T-IDG-CONTRACT must go RED --"
  idg_ctr_mutant="$TMP/status.IDG-UNTRACKED-PATTERN.MUTANT.sh"
  if grep -q '# IDG-UNTRACKED-PATTERN' "$SUT"; then
    sed 's|/\^untracked:/|/^UNTRACKED:/|' \
      "$SUT" > "$idg_ctr_mutant"
    if grep -q '/\^untracked:/' "$idg_ctr_mutant"; then
      no "teeth-IDG-contract: could not build mutant (sed did not corrupt awk pattern)"
    else
      _ctr_mut_kit="$TMP/kit-teeth-ctr"
      _ctr_mut_gh="$TMP/gh-stub-teeth-ctr"
      mkdir -p "$_ctr_mut_kit/lib" "$_ctr_mut_gh"
      cp "$idg_ctr_mutant" "$_ctr_mut_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_ctr_mut_kit/verify-state.sh"
      cp "$HERE/../reconcile-issues.sh" "$_ctr_mut_kit/reconcile-issues.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_ctr_mut_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_ctr_mut_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_ctr_mut_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_ctr_mut_kit/lib/retro-status.sh"
      cp "$HERE/../lib/retro-grammar.sh" "$_ctr_mut_kit/lib/retro-grammar.sh"
      cp "$HERE/../lib/target-paths.sh" "$_ctr_mut_kit/lib/target-paths.sh"
      printf '#!/usr/bin/env bash\ncase "$1" in auth) exit 0 ;; issue) printf "" ; exit 0 ;; *) exit 1 ;; esac\n' \
        > "$_ctr_mut_gh/gh"
      chmod +x "$_ctr_mut_gh/gh"
      _ctr_mut_target="$TMP/target-teeth-ctr"
      mkstate "$_ctr_mut_target" 0 "high|done gap|covered"
      mkdir -p "$_ctr_mut_target/retros"
      cat > "$_ctr_mut_target/retros/contract-teeth-retro.md" <<'CTR_TEETH_EOF'
<!-- review-status: pending -->
# Contract teeth retro

## Proposed kit deltas

| # | Proposed change | Target | Evidence | Priority |
|---|---|---|---|---|
| 1 | teeth delta | file.sh | evidence | high |
CTR_TEETH_EOF
      _ctr_mut_got="$(PATH="$_ctr_mut_gh:$PATH" bash "$_ctr_mut_kit/research-sdd-status.sh" \
        "$_ctr_mut_target" --next 2>/dev/null)"
      case "$_ctr_mut_got" in
        ISSUES-DUE\ *) no "teeth-IDG-contract: mutant still returned ISSUES-DUE → IDG-UNTRACKED-PATTERN is THEATER" ;;
        STOP\ *)       ok "teeth-IDG-contract: corrupt-awk mutant → STOP (0 counted) → T-IDG-CONTRACT goes RED → IDG-UNTRACKED-PATTERN is load-bearing" ;;
        *)             no "teeth-IDG-contract: mutant returned unexpected [$_ctr_mut_got] — fixture or mutant broken" ;;
      esac
    fi
  else
    no "teeth-IDG-contract: IDG-UNTRACKED-PATTERN sentinel not found in SUT"
  fi

  # ---- teeth-IDG-opfail: neuter F5b _idg_had_unverified flag; T-IDG-E must return bare STOP.
  # Mutation: replace `_idg_had_unverified=1  # IDG-OPFAIL-SENTINEL` with a no-op, restoring the
  # old bug where an operational failure (non-124, non-degraded) did NOT mark coverage unverified.
  # T-IDG-E (exit 1 empty stderr) must then return bare STOP instead of the unverified marker →
  # T-IDG-E assertion goes RED → IDG-OPFAIL-SENTINEL is load-bearing.
  echo "-- teeth-IDG-opfail: neuter F5b unverified flag; exit_1_empty fixture must return bare STOP --"
  idg_opfail_mutant="$TMP/status.IDG-OPFAIL.MUTANT.sh"
  if grep -q '# IDG-OPFAIL-SENTINEL' "$SUT"; then
    sed 's/_idg_had_unverified=1  # IDG-OPFAIL-SENTINEL/: # MUTANT-IDG-OPFAIL: flag removed/' \
      "$SUT" > "$idg_opfail_mutant"
    if grep -q '# IDG-OPFAIL-SENTINEL' "$idg_opfail_mutant"; then
      no "teeth-IDG-opfail: could not build mutant (sed did not replace IDG-OPFAIL-SENTINEL — check sed pattern)"
    else
      _opfail_kit="$TMP/kit-teeth-opfail"
      mkdir -p "$_opfail_kit/lib"
      cp "$idg_opfail_mutant" "$_opfail_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_opfail_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_opfail_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_opfail_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_opfail_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_opfail_kit/lib/retro-status.sh"
      # exit_1_empty stub: exits 1 with no output — same scenario as T-IDG-E.
      printf '#!/usr/bin/env bash\nexit 1\n' > "$_opfail_kit/reconcile-issues.sh"
      chmod +x "$_opfail_kit/reconcile-issues.sh"
      _opfail_target="$TMP/target-teeth-opfail"
      mkstate "$_opfail_target" 0 "high|done gap|covered"
      mkdir -p "$_opfail_target/retros"
      touch "$_opfail_target/retros/2026-09-01-teeth-opfail-retro.md"
      _opfail_got="$(bash "$_opfail_kit/research-sdd-status.sh" "$_opfail_target" --next 2>/dev/null)"
      if printf '%s\n' "$_opfail_got" | grep -qF '[issue-coverage: unverified'; then
        no "teeth-IDG-opfail: mutant still returned unverified marker → IDG-OPFAIL-SENTINEL is THEATER"
      else
        case "$_opfail_got" in
          "STOP | read-only-investigable exhausted (0)")
            ok "teeth-IDG-opfail: old-bug mutant → bare STOP → T-IDG-E goes RED → IDG-OPFAIL-SENTINEL is load-bearing" ;;
          *)
            no "teeth-IDG-opfail: mutant returned unexpected [$_opfail_got] — fixture or mutant broken" ;;
        esac
      fi
    fi
  else
    no "teeth-IDG-opfail: IDG-OPFAIL-SENTINEL not found in SUT"
  fi

  # ---- teeth-IDG-find-exit-unverified: neuter IDG-FIND-EXIT-UNVERIFIED; T-IDG-ENUM-EMPTY must go RED.
  # The IDG-FIND-EXIT-UNVERIFIED sentinel guards the _idg_had_unverified=1 line inside the
  # "find exit non-zero" block.  A mutant that replaces it with _idg_can_probe=0 (discarding
  # listed retros and clearing the unverified flag) restores the old discard-on-error behavior:
  # with no retros listed and find exit non-zero, the unified decision emits bare STOP instead
  # of the unverified marker.  T-IDG-ENUM-EMPTY goes RED.
  echo "-- teeth-IDG-find-exit-unverified: IDG-FIND-EXIT-UNVERIFIED neutered; T-IDG-ENUM-EMPTY must go RED --"
  idg_find_exit_mutant="$TMP/status.IDG-FIND-EXIT-UNVERIFIED.MUTANT.sh"
  if grep -q '# IDG-FIND-EXIT-UNVERIFIED' "$SUT"; then
    sed 's/_idg_had_unverified=1  # IDG-FIND-EXIT-UNVERIFIED/_idg_can_probe=0  # MUTANT-IDG-FIND-EXIT-UNVERIFIED/' \
      "$SUT" > "$idg_find_exit_mutant"
    if grep -q '# IDG-FIND-EXIT-UNVERIFIED' "$idg_find_exit_mutant"; then
      no "teeth-IDG-find-exit-unverified: could not build mutant (sed did not replace IDG-FIND-EXIT-UNVERIFIED)"
    else
      _fex_kit="$TMP/kit-teeth-fex"
      mkdir -p "$_fex_kit/lib"
      cp "$idg_find_exit_mutant" "$_fex_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_fex_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_fex_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_fex_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_fex_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_fex_kit/lib/retro-status.sh"
      # No reconcile stub needed: no retros are listed (stub find outputs nothing, exits 1).
      printf '#!/usr/bin/env bash\nexit 0\n' > "$_fex_kit/reconcile-issues.sh"
      chmod +x "$_fex_kit/reconcile-issues.sh"
      _fex_target="$TMP/target-teeth-fex"
      mkstate "$_fex_target" 0 "high|done gap|covered"
      # Stub find: no retros (no IDG_RETRO_PATHS_FILE), exits 1 (no stderr → avoids old-code path)
      _fex_got="$(IDG_FIND_EXIT=1 PATH="$_stub_find_dir:$PATH" \
        bash "$_fex_kit/research-sdd-status.sh" "$_fex_target" --next 2>/dev/null)"
      if printf '%s\n' "$_fex_got" | grep -qF '[issue-coverage: unverified'; then
        no "teeth-IDG-find-exit-unverified: mutant still emitted unverified marker → IDG-FIND-EXIT-UNVERIFIED is THEATER"
      else
        case "$_fex_got" in
          "STOP | read-only-investigable exhausted (0)")
            ok "teeth-IDG-find-exit-unverified: neutered mutant → bare STOP → T-IDG-ENUM-EMPTY goes RED → IDG-FIND-EXIT-UNVERIFIED is load-bearing" ;;
          *)
            no "teeth-IDG-find-exit-unverified: mutant returned unexpected [$_fex_got] — fixture or mutant broken" ;;
        esac
      fi
    fi
  else
    no "teeth-IDG-find-exit-unverified: IDG-FIND-EXIT-UNVERIFIED sentinel not found in SUT"
  fi

  # ---- teeth-IDG-enum-mktemp-guard: neuter IDG-ENUM-MKTEMP-GUARD; T-IDG-ENUM-MKTEMP must go RED.
  # The IDG-ENUM-MKTEMP-GUARD sentinel is on the _idg_had_unverified=1; _idg_can_probe=0 line inside
  # the _find_out_tmp mktemp failure block.  A mutant that replaces it with _find_out_tmp=/dev/null
  # silently absorbs the mktemp failure: find runs (output to /dev/null → empty retros), exits 0, and
  # no unverified flag is set → unified decision emits bare STOP.  T-IDG-ENUM-MKTEMP goes RED.
  echo "-- teeth-IDG-enum-mktemp-guard: IDG-ENUM-MKTEMP-GUARD neutered; T-IDG-ENUM-MKTEMP must go RED --"
  idg_mktemp_guard_mutant="$TMP/status.IDG-ENUM-MKTEMP-GUARD.MUTANT.sh"
  if grep -q '# IDG-ENUM-MKTEMP-GUARD' "$SUT"; then
    sed 's|_idg_had_unverified=1; _idg_can_probe=0  # IDG-ENUM-MKTEMP-GUARD|_find_out_tmp=/dev/null  # MUTANT-IDG-ENUM-MKTEMP-GUARD|' \
      "$SUT" > "$idg_mktemp_guard_mutant"
    if grep -q '# IDG-ENUM-MKTEMP-GUARD' "$idg_mktemp_guard_mutant"; then
      no "teeth-IDG-enum-mktemp-guard: could not build mutant (sed did not replace IDG-ENUM-MKTEMP-GUARD)"
    else
      _mtg_kit="$TMP/kit-teeth-mtg"
      mkdir -p "$_mtg_kit/lib"
      cp "$idg_mktemp_guard_mutant" "$_mtg_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_mtg_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_mtg_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_mtg_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_mtg_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_mtg_kit/lib/retro-status.sh"
      # tracked stub: if somehow retros are found (they won't be), all tracked → no ISSUES-DUE.
      printf '#!/usr/bin/env bash\nprintf "tracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$_mtg_kit/reconcile-issues.sh"
      chmod +x "$_mtg_kit/reconcile-issues.sh"
      _mtg_target="$TMP/target-teeth-mtg"
      mkstate "$_mtg_target" 0 "high|done gap|covered"
      # No retros in target — find on target returns nothing (find runs to /dev/null in mutant).
      # Use a fresh stub-dir so the call counter starts at 0 for the mutant run.
      _mtg_stub_dir="$TMP/mstub-mut"; mkdir -p "$_mtg_stub_dir"
      _mtg_got="$(IDG_MKTEMP_STUB_DIR="$_mtg_stub_dir" \
        PATH="$_stub_mktemp_dir:$PATH" bash "$_mtg_kit/research-sdd-status.sh" "$_mtg_target" --next 2>/dev/null)"
      if printf '%s\n' "$_mtg_got" | grep -qF '[issue-coverage: unverified'; then
        no "teeth-IDG-enum-mktemp-guard: mutant still emitted unverified marker → IDG-ENUM-MKTEMP-GUARD is THEATER"
      else
        case "$_mtg_got" in
          "STOP | read-only-investigable exhausted (0)")
            ok "teeth-IDG-enum-mktemp-guard: neutered mutant → bare STOP → T-IDG-ENUM-MKTEMP goes RED → IDG-ENUM-MKTEMP-GUARD is load-bearing" ;;
          *)
            no "teeth-IDG-enum-mktemp-guard: mutant returned unexpected [$_mtg_got] — fixture or mutant broken" ;;
        esac
      fi
    fi
  else
    no "teeth-IDG-enum-mktemp-guard: IDG-ENUM-MKTEMP-GUARD sentinel not found in SUT"
  fi

  # ---- teeth-IDG-sort-exit-unverified: neuter IDG-SORT-EXIT-UNVERIFIED; T-IDG-ENUM-SORT-FAIL must go RED.
  # A mutant that replaces the _idg_had_unverified=1 flag with a no-op restores the old bug where
  # sort failure was silently swallowed.  The stub find output is present (stub sort received it
  # before failing) but the sort-exit guard never fires.  With all-tracked reconcile and no unverified
  # flag set, unified decision emits bare STOP instead of the unverified marker.
  echo "-- teeth-IDG-sort-exit-unverified: neuter IDG-SORT-EXIT-UNVERIFIED; T-IDG-ENUM-SORT-FAIL must go RED --"
  idg_sort_mutant="$TMP/status.IDG-SORT-EXIT-UNVERIFIED.MUTANT.sh"
  if grep -q '# IDG-SORT-EXIT-UNVERIFIED' "$SUT"; then
    sed 's/_idg_had_unverified=1  # IDG-SORT-EXIT-UNVERIFIED/: # MUTANT-IDG-SORT-EXIT-UNVERIFIED/' \
      "$SUT" > "$idg_sort_mutant"
    if grep -q '# IDG-SORT-EXIT-UNVERIFIED' "$idg_sort_mutant"; then
      no "teeth-IDG-sort-exit-unverified: could not build mutant (sed did not replace IDG-SORT-EXIT-UNVERIFIED)"
    else
      _sort_mut_kit="$TMP/kit-teeth-sort"
      mkdir -p "$_sort_mut_kit/lib"
      cp "$idg_sort_mutant" "$_sort_mut_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_sort_mut_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_sort_mut_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_sort_mut_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_sort_mut_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_sort_mut_kit/lib/retro-status.sh"
      # tracked stub: all retros tracked → no ISSUES-DUE; bare STOP if unverified flag is neutered.
      printf '#!/usr/bin/env bash\nprintf "tracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$_sort_mut_kit/reconcile-issues.sh"
      chmod +x "$_sort_mut_kit/reconcile-issues.sh"
      _sort_mut_target="$TMP/target-teeth-sort"
      mkstate "$_sort_mut_target" 0 "high|done gap|covered"
      mkdir -p "$_sort_mut_target/retros"
      touch "$_sort_mut_target/retros/2026-09-01-teeth-sort-retro.md"
      _sort_mut_got="$(IDG_SORT_EXIT=1 PATH="$_stub_sort_dir:$PATH" \
        bash "$_sort_mut_kit/research-sdd-status.sh" "$_sort_mut_target" --next 2>/dev/null)"
      if printf '%s\n' "$_sort_mut_got" | grep -qF '[issue-coverage: unverified'; then
        no "teeth-IDG-sort-exit-unverified: mutant still returned unverified marker → IDG-SORT-EXIT-UNVERIFIED is THEATER"
      else
        case "$_sort_mut_got" in
          "STOP | read-only-investigable exhausted (0)")
            ok "teeth-IDG-sort-exit-unverified: neutered mutant → bare STOP → T-IDG-ENUM-SORT-FAIL goes RED → IDG-SORT-EXIT-UNVERIFIED is load-bearing" ;;
          *)
            no "teeth-IDG-sort-exit-unverified: mutant returned unexpected [$_sort_mut_got] — fixture or mutant broken" ;;
        esac
      fi
    fi
  else
    no "teeth-IDG-sort-exit-unverified: IDG-SORT-EXIT-UNVERIFIED sentinel not found in SUT"
  fi

  # ---- teeth-IDG-timeout-absent: neuter IDG-TIMEOUT-ABSENT-FAIL-CLOSED; T-IDG-TIMEOUT-ABSENT must go RED.
  # A mutant that replaces the _idg_had_unverified=1 flag with a no-op means the gate never marks
  # coverage unverified when no timeout binary is present.  The IDG-TIMEOUT-ABSENT-SKIP guard still
  # fires (all probes are still skipped), so no reconcile calls happen and no ISSUES-DUE fires either.
  # The unified decision then emits bare STOP → T-IDG-TIMEOUT-ABSENT (expects unverified marker) goes RED.
  echo "-- teeth-IDG-timeout-absent: neuter IDG-TIMEOUT-ABSENT-FAIL-CLOSED; T-IDG-TIMEOUT-ABSENT must go RED --"
  idg_ta_mutant="$TMP/status.IDG-TIMEOUT-ABSENT-FAIL-CLOSED.MUTANT.sh"
  if grep -q '# IDG-TIMEOUT-ABSENT-FAIL-CLOSED' "$SUT"; then
    sed 's/_idg_had_unverified=1  # IDG-TIMEOUT-ABSENT-FAIL-CLOSED/: # MUTANT-IDG-TIMEOUT-ABSENT-FAIL-CLOSED/' \
      "$SUT" > "$idg_ta_mutant"
    if grep -q '# IDG-TIMEOUT-ABSENT-FAIL-CLOSED' "$idg_ta_mutant"; then
      no "teeth-IDG-timeout-absent: could not build mutant (sed did not replace IDG-TIMEOUT-ABSENT-FAIL-CLOSED)"
    else
      _ta_mut_kit="$TMP/kit-teeth-ta"
      mkdir -p "$_ta_mut_kit/lib"
      cp "$idg_ta_mutant" "$_ta_mut_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_ta_mut_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_ta_mut_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_ta_mut_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_ta_mut_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_ta_mut_kit/lib/retro-status.sh"
      # tracked stub: probes skipped (ABSENT-SKIP fires), so reconcile is never called; just needs to exist.
      printf '#!/usr/bin/env bash\nprintf "tracked: row 1\\n"\nexit 0\n' \
        > "$_ta_mut_kit/reconcile-issues.sh"
      chmod +x "$_ta_mut_kit/reconcile-issues.sh"
      _ta_mut_target="$TMP/target-teeth-ta"
      mkstate "$_ta_mut_target" 0 "high|done gap|covered"
      mkdir -p "$_ta_mut_target/retros"
      touch "$_ta_mut_target/retros/2026-09-01-teeth-ta-retro.md"
      # Mutant: FAIL-CLOSED flag neutered; IDG-TIMEOUT-ABSENT-SKIP still fires → all probes skipped.
      # No unverified flag + no probes → bare STOP; T-IDG-TIMEOUT-ABSENT expects unverified → RED.
      _ta_mut_got="$(_IDG_TIMEOUT_BIN="" bash "$_ta_mut_kit/research-sdd-status.sh" "$_ta_mut_target" --next 2>/dev/null)"
      if printf '%s\n' "$_ta_mut_got" | grep -qF '[issue-coverage: unverified'; then
        no "teeth-IDG-timeout-absent: mutant still returned unverified marker → IDG-TIMEOUT-ABSENT-FAIL-CLOSED is THEATER"
      else
        case "$_ta_mut_got" in
          "STOP | read-only-investigable exhausted (0)")
            ok "teeth-IDG-timeout-absent: FAIL-CLOSED neutered → bare STOP → T-IDG-TIMEOUT-ABSENT goes RED → IDG-TIMEOUT-ABSENT-FAIL-CLOSED is load-bearing" ;;
          *)
            no "teeth-IDG-timeout-absent: mutant returned unexpected [$_ta_mut_got] — fixture or mutant broken" ;;
        esac
      fi
    fi
  else
    no "teeth-IDG-timeout-absent: IDG-TIMEOUT-ABSENT-FAIL-CLOSED sentinel not found in SUT"
  fi

  # ---- teeth-IDG-early-exit: neuter IDG-EARLY-EXIT (remove return); T-IDG-PAYLOAD must go RED.
  # Mutant: remove the 'return  # IDG-EARLY-EXIT' so the loop continues after emitting ISSUES-DUE.
  # With recording_untracked stub and two retros, the mutant probes both retros (call count = 2 > 1).
  # T-IDG-PAYLOAD's early-exit check expects call count ≤1 → assertion goes RED →
  # the IDG-EARLY-EXIT return is load-bearing.
  echo "-- teeth-IDG-early-exit: neuter IDG-EARLY-EXIT return; T-IDG-PAYLOAD early-exit check must go RED --"
  _idg_ee_mutant="$TMP/status.IDG-EARLY-EXIT.MUTANT.sh"
  if grep -q 'return  # IDG-EARLY-EXIT' "$SUT"; then
    sed 's/return  # IDG-EARLY-EXIT/:  # MUTANT-NOWAIT/' "$SUT" > "$_idg_ee_mutant"
    if grep -q 'return  # IDG-EARLY-EXIT' "$_idg_ee_mutant"; then
      no "teeth-IDG-early-exit: could not build mutant (sed did not replace IDG-EARLY-EXIT)"
    else
      _ee_mut_kit="$TMP/kit-teeth-ee"; mkdir -p "$_ee_mut_kit/lib"
      cp "$_idg_ee_mutant" "$_ee_mut_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_ee_mut_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_ee_mut_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_ee_mut_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_ee_mut_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_ee_mut_kit/lib/retro-status.sh"
      # recording_untracked stub: logs each invocation to _IDG_RECORD_LOG; returns untracked.
      printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' "$1" >> "${_IDG_RECORD_LOG:-/dev/null}"\nprintf "untracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$_ee_mut_kit/reconcile-issues.sh"
      chmod +x "$_ee_mut_kit/reconcile-issues.sh"
      _ee_mut_target="$TMP/target-teeth-ee"; mkstate "$_ee_mut_target" 0 "high|done gap|covered"
      mkdir -p "$_ee_mut_target/retros"
      touch "$_ee_mut_target/retros/retro-alpha.md"
      touch "$_ee_mut_target/retros/retro-beta.md"
      _ee_mut_log="$TMP/teeth-ee-rec.log"; : > "$_ee_mut_log"
      _ee_mut_got="$(_IDG_RECORD_LOG="$_ee_mut_log" bash "$_ee_mut_kit/research-sdd-status.sh" \
        "$_ee_mut_target" --next 2>/dev/null)"
      _ee_mut_calls="$(grep -c '' "$_ee_mut_log" 2>/dev/null || echo 0)"
      if [ "${_ee_mut_calls}" -gt 1 ] 2>/dev/null; then
        ok "teeth-IDG-early-exit: return neutered → both retros probed (${_ee_mut_calls} calls) → T-IDG-PAYLOAD goes RED → IDG-EARLY-EXIT is load-bearing"
      else
        no "teeth-IDG-early-exit: mutant still stopped early (${_ee_mut_calls} calls, got [$_ee_mut_got]) — IDG-EARLY-EXIT is THEATER or mutant broken"
      fi
    fi
  else
    no "teeth-IDG-early-exit: 'return  # IDG-EARLY-EXIT' sentinel not found in SUT"
  fi

  # ---- teeth-IDG-aggregate-budget: neuter IDG-AGGREGATE-EXCEEDED; T-IDG-AGGR-BUDGET must go RED.
  # Mutant: replace the aggregate budget if-condition with 'if false', so the budget never fires.
  # With _IDG_AGGREGATE_BUDGET_SECS=0 and tracked stub (no untracked → no early-exit),
  # the mutant probes all retros and reaches _stop_exhausted → bare STOP instead of unverified.
  # T-IDG-AGGR-BUDGET expects unverified marker → gets STOP → assertion goes RED →
  # the IDG-AGGREGATE-EXCEEDED guard is load-bearing.
  echo "-- teeth-IDG-aggregate-budget: neuter IDG-AGGREGATE-EXCEEDED; T-IDG-AGGR-BUDGET must go RED --"
  _idg_ab_mutant="$TMP/status.IDG-AGGREGATE-EXCEEDED.MUTANT.sh"
  if grep -q '# IDG-AGGREGATE-EXCEEDED' "$SUT"; then
    sed '/# IDG-AGGREGATE-EXCEEDED$/s/if ((.*/if false; then  # MUTANT-IDG-AGGR/' "$SUT" > "$_idg_ab_mutant"
    if grep -q '# IDG-AGGREGATE-EXCEEDED' "$_idg_ab_mutant"; then
      no "teeth-IDG-aggregate-budget: could not build mutant (sed did not replace IDG-AGGREGATE-EXCEEDED)"
    else
      _ab_mut_kit="$TMP/kit-teeth-ab"; mkdir -p "$_ab_mut_kit/lib"
      cp "$_idg_ab_mutant" "$_ab_mut_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_ab_mut_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_ab_mut_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_ab_mut_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_ab_mut_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_ab_mut_kit/lib/retro-status.sh"
      # tracked stub: returns no untracked lines; budget must be the only trigger.
      printf '#!/usr/bin/env bash\nprintf "tracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$_ab_mut_kit/reconcile-issues.sh"
      chmod +x "$_ab_mut_kit/reconcile-issues.sh"
      _ab_mut_target="$TMP/target-teeth-ab"; mkstate "$_ab_mut_target" 0 "high|done gap|covered"
      mkdir -p "$_ab_mut_target/retros"
      touch "$_ab_mut_target/retros/2026-09-01-ab-teeth-retro.md"
      # Mutant: budget guard neutered; tracked stub → no untracked; all retros probed → bare STOP.
      # T-IDG-AGGR-BUDGET expects unverified marker → bare STOP → assertion goes RED.
      _ab_mut_got="$(_IDG_AGGREGATE_BUDGET_SECS=0 bash "$_ab_mut_kit/research-sdd-status.sh" \
        "$_ab_mut_target" --next 2>/dev/null)"
      if printf '%s\n' "$_ab_mut_got" | grep -qF '[issue-coverage: unverified]'; then
        no "teeth-IDG-aggregate-budget: mutant still returned unverified marker → IDG-AGGREGATE-EXCEEDED is THEATER"
      else
        case "$_ab_mut_got" in
          "STOP | read-only-investigable exhausted (0)")
            ok "teeth-IDG-aggregate-budget: budget neutered → bare STOP → T-IDG-AGGR-BUDGET goes RED → IDG-AGGREGATE-EXCEEDED is load-bearing" ;;
          *)
            no "teeth-IDG-aggregate-budget: mutant returned unexpected [$_ab_mut_got] — fixture or mutant broken" ;;
        esac
      fi
    fi
  else
    no "teeth-IDG-aggregate-budget: IDG-AGGREGATE-EXCEEDED sentinel not found in SUT"
  fi

  # ---- teeth-T-IDG-BATCH-ONE-GH: remove IDG-BATCH-PASS-CACHE; T-IDG-BATCH-ONE-GH must go RED. --------
  # Mutant: removes `--issues-cache "$_idg_cache_file"` from the reconcile call inside issues_due_gate.
  # Without cache pass-through, reconcile.sh calls gh issue list per retro → call count > 1.
  # T-IDG-BATCH-ONE-GH asserts exactly 1 gh call → gets >1 calls → assertion goes RED →
  # IDG-BATCH-PASS-CACHE is load-bearing.
  echo "-- teeth-T-IDG-BATCH-ONE-GH: remove IDG-BATCH-PASS-CACHE; per-retro gh calls > 1 must go RED --"
  _b1t_anchor='IDG-BATCH-PASS-CACHE:'
  if grep -q "$_b1t_anchor" "$SUT"; then
    _b1t_mut="$TMP/status.BATCH1-TOOTH.MUTANT.sh"
    sed "/IDG-BATCH-PASS-CACHE:/{ n; s/ --issues-cache \"\\\$_idg_cache_file\"// }" \
      "$SUT" > "$_b1t_mut"
    if grep -q 'IDG-BATCH-PASS-CACHE' "$_b1t_mut" && \
       ! grep -q -- '--issues-cache "\$_idg_cache_file"' "$_b1t_mut"; then
      # Tooth kit: real reconcile + all its libs + recording gh stub
      _b1t_kdir="$TMP/kit-b1tooth"
      mkdir -p "$_b1t_kdir/lib"
      cp "$_b1t_mut" "$_b1t_kdir/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_b1t_kdir/verify-state.sh"
      cp "$HERE/../reconcile-issues.sh" "$_b1t_kdir/reconcile-issues.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_b1t_kdir/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_b1t_kdir/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_b1t_kdir/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_b1t_kdir/lib/retro-status.sh"
      cp "$HERE/../lib/retro-grammar.sh" "$_b1t_kdir/lib/retro-grammar.sh"
      cp "$HERE/../lib/target-paths.sh" "$_b1t_kdir/lib/target-paths.sh"
      _b1t_ghdir="$TMP/gh-batch1-tooth"
      mkdir -p "$_b1t_ghdir"
      _b1t_ghlog="$TMP/gh-batch1-tooth.log"; : > "$_b1t_ghlog"
      # Recording gh: logs every issue list call; returns tracked bodies for both tooth retros.
      # Bodies match the tooth fixture's target dir basename: target-idg-b1tooth.
      cat > "$_b1t_ghdir/gh" <<GHTOOTHEOF
#!/usr/bin/env bash
case "\$1" in
  auth) exit 0 ;;
  issue)
    printf 'call\n' >> "$_b1t_ghlog"
    printf 'Source retro: target-idg-b1tooth/retros/retro-1.md \xc2\xb7 1\n'
    printf 'Source retro: target-idg-b1tooth/retros/retro-2.md \xc2\xb7 1\n'
    exit 0
    ;;
  *) exit 1 ;;
esac
GHTOOTHEOF
      chmod +x "$_b1t_ghdir/gh"
      # Tooth fixture: 2 retros, each with 1 tracked delta (gh stub returns matching bodies)
      _t_b1tooth="$TMP/target-idg-b1tooth"
      mkstate "$_t_b1tooth" 0 "high|done gap|covered"
      mkdir -p "$_t_b1tooth/retros"
      printf '<!-- review-status: pending -->\n# Tooth retro 1\n\n## Proposed kit deltas\n\n| # | Proposed change | Target | Evidence | Priority |\n|---|---|---|---|---|\n| 1 | delta 1 | file.sh | ev | high |\n' \
        > "$_t_b1tooth/retros/retro-1.md"
      printf '<!-- review-status: pending -->\n# Tooth retro 2\n\n## Proposed kit deltas\n\n| # | Proposed change | Target | Evidence | Priority |\n|---|---|---|---|---|\n| 1 | delta 2 | file.sh | ev | high |\n' \
        > "$_t_b1tooth/retros/retro-2.md"
      # Run mutant: --issues-cache removed → reconcile calls gh per retro → >1 gh calls logged.
      PATH="$_b1t_ghdir:$PATH" bash "$_b1t_kdir/research-sdd-status.sh" \
        "$_t_b1tooth" --next 2>/dev/null || true
      _b1t_calls="$(grep -c '' "$_b1t_ghlog" 2>/dev/null || echo 0)"
      if [ "${_b1t_calls}" -gt 1 ] 2>/dev/null; then
        ok "teeth-T-IDG-BATCH-ONE-GH: mutant (no --issues-cache) → ${_b1t_calls} gh calls > 1 → IDG-BATCH-PASS-CACHE is load-bearing"
      else
        no "teeth-T-IDG-BATCH-ONE-GH: mutant produced ${_b1t_calls} gh calls, expected >1 — IDG-BATCH-PASS-CACHE THEATER"
      fi
    else
      no "teeth-T-IDG-BATCH-ONE-GH: sed mutant did not remove --issues-cache from IDG-BATCH-PASS-CACHE line — tooth invalid"
    fi
  else
    no "teeth-T-IDG-BATCH-ONE-GH: anchor '$_b1t_anchor' not found in SUT"
  fi

  # ---- teeth-T-IDG-BATCH-TIMEOUT-WRAP: remove IDG-BATCH-GH-TIMEOUT-WRAP; batch gh not wrapped. ----
  # Mutant: replaces "$_idg_timeout_bin" "$_idg_timeout_secs" gh with just gh on the command line.
  # With the mutant the batch gh call bypasses fake-timeout → no 'gh issue list' in timeout log → RED.
  echo "-- teeth-T-IDG-BATCH-TIMEOUT-WRAP: remove timeout wrapper from batch gh call --"
  _btwt_anchor='IDG-BATCH-GH-TIMEOUT-WRAP:'
  if grep -q "$_btwt_anchor" "$SUT"; then
    _btwt_mut="$TMP/status.BTWRAP-TOOTH.MUTANT.sh"
    sed '/IDG-BATCH-GH-TIMEOUT-WRAP:/{ n; s/"\$_idg_timeout_bin" "\$_idg_timeout_secs" gh/gh/ }' \
      "$SUT" > "$_btwt_mut"
    if grep -q 'IDG-BATCH-GH-TIMEOUT-WRAP' "$_btwt_mut" && \
       ! grep -q '"$_idg_timeout_bin" "$_idg_timeout_secs" gh' "$_btwt_mut" 2>/dev/null; then
      _btwt_kit="$TMP/kit-btwt"
      mkdir -p "$_btwt_kit/lib" "$_btwt_kit/bin"
      cp "$_btwt_mut" "$_btwt_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_btwt_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_btwt_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_btwt_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_btwt_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_btwt_kit/lib/retro-status.sh"
      printf '#!/usr/bin/env bash\nprintf "tracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$_btwt_kit/reconcile-issues.sh"
      chmod +x "$_btwt_kit/reconcile-issues.sh"
      # gh stub in kit bin: exits 0 (so mutant can complete); needed for direct (non-wrapped) batch call.
      printf '#!/usr/bin/env bash\ncase "$1" in auth) exit 0 ;; issue) exit 0 ;; *) exit 1 ;; esac\n' \
        > "$_btwt_kit/bin/gh"
      chmod +x "$_btwt_kit/bin/gh"
      _btwt_tlog="$TMP/btwrap-tooth.log"; : > "$_btwt_tlog"
      _btwt_tbin="$TMP/btwt-bin"; mkdir -p "$_btwt_tbin"
      cat > "$_btwt_tbin/fake-timeout" <<BTWTTEOF
#!/usr/bin/env bash
printf 'timeout-call: %s\n' "\$*" >> "$_btwt_tlog"
shift
exec "\$@"
BTWTTEOF
      chmod +x "$_btwt_tbin/fake-timeout"
      _t_btwt="$TMP/target-idg-btwt"
      mkstate "$_t_btwt" 0 "high|done gap|covered"
      mkdir -p "$_t_btwt/retros"
      touch "$_t_btwt/retros/btwt-retro.md"
      # Run mutant with fake-timeout: without wrapper, batch gh is called directly → not in log.
      PATH="$_btwt_kit/bin:$PATH" \
        _IDG_TIMEOUT_BIN="$_btwt_tbin/fake-timeout" \
        bash "$_btwt_kit/research-sdd-status.sh" "$_t_btwt" --next 2>/dev/null || true
      if grep -q 'gh issue list' "$_btwt_tlog" 2>/dev/null; then
        no "teeth-T-IDG-BATCH-TIMEOUT-WRAP: mutant still logs 'gh issue list' in timeout — wrapper may not be load-bearing"
      else
        ok "teeth-T-IDG-BATCH-TIMEOUT-WRAP: mutant (no wrapper) → 'gh issue list' absent from timeout log → IDG-BATCH-GH-TIMEOUT-WRAP is load-bearing"
      fi
    else
      no "teeth-T-IDG-BATCH-TIMEOUT-WRAP: sed mutant did not remove timeout wrapper from batch gh line — tooth invalid"
    fi
  else
    no "teeth-T-IDG-BATCH-TIMEOUT-WRAP: anchor '$_btwt_anchor' not found in SUT"
  fi

  # ---- teeth-T-IDG-BATCH-LIMIT: remove --limit from batch call → gh log lacks --limit → RED. ------
  # Mutant: deletes the --limit flag line from the batch gh issue list call.
  echo "-- teeth-T-IDG-BATCH-LIMIT: remove --limit flag from batch gh call --"
  _blt_anchor='IDG-BATCH-LIMIT-PRESENT'
  if grep -q "$_blt_anchor" "$SUT"; then
    _blt_mut="$TMP/status.BATCHLIM-TOOTH.MUTANT.sh"
    sed '/--limit.*IDG_BATCH_LIMIT/d' "$SUT" > "$_blt_mut"
    if ! grep -qF '"${_IDG_BATCH_LIMIT' "$_blt_mut" 2>/dev/null; then
      _blt_kit="$TMP/kit-blt"
      mkdir -p "$_blt_kit/lib" "$_blt_kit/bin"
      cp "$_blt_mut" "$_blt_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_blt_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_blt_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_blt_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_blt_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_blt_kit/lib/retro-status.sh"
      printf '#!/usr/bin/env bash\nprintf "tracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$_blt_kit/reconcile-issues.sh"
      chmod +x "$_blt_kit/reconcile-issues.sh"
      _blt_ghdir="$TMP/gh-blt-dir"; mkdir -p "$_blt_ghdir"
      _blt_ghlog="$TMP/gh-blt.log"; : > "$_blt_ghlog"
      cat > "$_blt_ghdir/gh" <<BLTGHEOF
#!/usr/bin/env bash
printf 'args: %s\n' "\$*" >> "$_blt_ghlog"
case "\$1" in
  auth) exit 0 ;;
  issue) exit 0 ;;
  *) exit 1 ;;
esac
BLTGHEOF
      chmod +x "$_blt_ghdir/gh"
      _t_blt="$TMP/target-idg-blt"
      mkstate "$_t_blt" 0 "high|done gap|covered"
      mkdir -p "$_t_blt/retros"
      touch "$_t_blt/retros/blt-retro.md"
      PATH="$_blt_ghdir:$PATH" \
        bash "$_blt_kit/research-sdd-status.sh" "$_t_blt" --next 2>/dev/null || true
      if grep -q -- '--limit' "$_blt_ghlog" 2>/dev/null; then
        no "teeth-T-IDG-BATCH-LIMIT: mutant still has --limit in gh call — limit not load-bearing"
      else
        ok "teeth-T-IDG-BATCH-LIMIT: mutant (no --limit line) → '--limit' absent from gh call → IDG-BATCH-LIMIT-PRESENT is load-bearing"
      fi
    else
      no "teeth-T-IDG-BATCH-LIMIT: sed did not remove --limit from mutant — tooth invalid"
    fi
  else
    no "teeth-T-IDG-BATCH-LIMIT: anchor '$_blt_anchor' not found in SUT"
  fi

  # ---- teeth-T-IDG-BATCH-FALLBACK: remove fallback else-branch → blanket no-op, log empty → RED. --
  # Mutant: replaces the IDG-BATCH-FALLBACK-PER-RETRO command with a no-op (: # MUTANT).
  # Without the fallback, batch failure leaves per-retro uncalled → reconcile log empty → RED.
  echo "-- teeth-T-IDG-BATCH-FALLBACK: remove IDG-BATCH-FALLBACK-PER-RETRO; reconcile not invoked --"
  _bfbt_anchor='IDG-BATCH-FALLBACK-PER-RETRO:'
  if grep -q "$_bfbt_anchor" "$SUT"; then
    _bfbt_mut="$TMP/status.BATCHFB-TOOTH.MUTANT.sh"
    sed "/${_bfbt_anchor}/{ n; s/.*/        : # MUTANT-FALLBACK-REMOVED/ }" \
      "$SUT" > "$_bfbt_mut"
    if grep -q "$_bfbt_anchor" "$_bfbt_mut" && \
       grep -q 'MUTANT-FALLBACK-REMOVED' "$_bfbt_mut" 2>/dev/null; then
      _bfbt_kit="$TMP/kit-bfbt"
      mkdir -p "$_bfbt_kit/lib" "$_bfbt_kit/bin"
      cp "$_bfbt_mut" "$_bfbt_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_bfbt_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_bfbt_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_bfbt_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_bfbt_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_bfbt_kit/lib/retro-status.sh"
      # recording_untracked stub: logs the retro path to _IDG_RECORD_LOG; returns "untracked".
      printf '#!/usr/bin/env bash\nprintf '"'"'%%s\n'"'"' "${@: -1}" >> "${_IDG_RECORD_LOG:-/dev/null}"\nprintf "untracked: row 1 delta-foo\\n"\nexit 0\n' \
        > "$_bfbt_kit/reconcile-issues.sh"
      chmod +x "$_bfbt_kit/reconcile-issues.sh"
      # gh stub: exits 1 → batch fails → should trigger fallback (but mutant has no fallback).
      printf '#!/usr/bin/env bash\nexit 1\n' > "$_bfbt_kit/bin/gh"
      chmod +x "$_bfbt_kit/bin/gh"
      _bfbt_log="$TMP/bfbt-reconcile.log"; : > "$_bfbt_log"
      _t_bfbt="$TMP/target-idg-batch-fbte"
      mkstate "$_t_bfbt" 0 "high|done gap|covered"
      mkdir -p "$_t_bfbt/retros"
      printf '<!-- review-status: pending -->\n# Fallback tooth retro\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | delta 1 | file.sh | ev | new | high |\n' \
        > "$_t_bfbt/retros/fbte-retro.md"
      # PATH must include $_bfbt_kit/bin so the gh stub (exit 1) intercepts the batch prefetch.
      # Without it, the real gh may succeed → pass-cache path calls reconcile → fallback THEATER.
      _bfbt_got="$(_IDG_RECORD_LOG="$_bfbt_log" \
        PATH="$_bfbt_kit/bin:$PATH" \
        bash "$_bfbt_kit/research-sdd-status.sh" "$_t_bfbt" --next 2>/dev/null)"
      _bfbt_log_lines="$(grep -c '' "$_bfbt_log" 2>/dev/null || echo 0)"
      # Mutant: no fallback → reconcile not called → log empty → T-IDG-BATCH-FALLBACK assertion goes RED.
      if [ "${_bfbt_log_lines:-0}" -gt 0 ] 2>/dev/null; then
        no "teeth-T-IDG-BATCH-FALLBACK: mutant still invoked reconcile (${_bfbt_log_lines} log lines) — fallback THEATER"
      else
        ok "teeth-T-IDG-BATCH-FALLBACK: mutant (no fallback) → reconcile not invoked → T-IDG-BATCH-FALLBACK goes RED → IDG-BATCH-FALLBACK-PER-RETRO is load-bearing"
      fi
    else
      no "teeth-T-IDG-BATCH-FALLBACK: sed mutant did not neutralize IDG-BATCH-FALLBACK-PER-RETRO — tooth invalid"
    fi
  else
    no "teeth-T-IDG-BATCH-FALLBACK: anchor '$_bfbt_anchor' not found in SUT"
  fi

  # teeth-IDG-batch-reverify: mutant skips the IDG-BATCH-UNTRACKED-REVERIFY re-verify block →
  # batch false-negative is trusted → T-IDG-BATCH-FALSE-NEG gets false ISSUES-DUE → RED.
  # Anchor: "# IDG-BATCH-UNTRACKED-REVERIFY" on the outer if-condition line.
  # Mutant: replace the condition with "if false" so the re-verify block body never runs.
  _brev_anchor='# IDG-BATCH-UNTRACKED-REVERIFY'
  if grep -qF "$_brev_anchor" "$HERE/../research-sdd-status.sh" 2>/dev/null; then
    _brev_mut="$TMP/brev-mutant.sh"
    sed "/$_brev_anchor/s/if .*/if false; then  # IDG-BATCH-UNTRACKED-REVERIFY MUTANT/" \
      "$HERE/../research-sdd-status.sh" > "$_brev_mut"
    if ! grep -qF 'if false' "$_brev_mut" 2>/dev/null; then
      no "teeth-IDG-batch-reverify: sed mutant did not neutralize IDG-BATCH-UNTRACKED-REVERIFY — tooth invalid"
    else
      _brev_kit="$TMP/kit-idg-brev-tooth"
      mkdir -p "$_brev_kit/bin" "$_brev_kit/lib"
      cp "$_brev_mut" "$_brev_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_brev_kit/verify-state.sh"
      cp "$HERE/../lib/focus-prefix.sh" "$_brev_kit/lib/focus-prefix.sh"
      cp "$HERE/../lib/state-files.sh" "$_brev_kit/lib/state-files.sh"
      cp "$HERE/../lib/block-files.sh" "$_brev_kit/lib/block-files.sh"
      cp "$HERE/../lib/retro-status.sh" "$_brev_kit/lib/retro-status.sh"
      # cache_untracked_reverify_tracked stub: batch says untracked; per-retro says tracked (false-neg).
      printf '#!/usr/bin/env bash\n_has_cache=0\nfor _a in "$@"; do [ "$_a" = "--issues-cache" ] && _has_cache=1; done\nif [ "$_has_cache" = "1" ]; then\n  printf "untracked: row 1 delta-foo\\n"\nelse\n  printf "tracked: row 1 delta-foo\\n"\nfi\n' \
        > "$_brev_kit/reconcile-issues.sh"
      chmod +x "$_brev_kit/reconcile-issues.sh"
      # gh stub: exits 0 (batch succeeds with empty output → cache file empty → reconcile sees UNTRACKED).
      printf '#!/usr/bin/env bash\ncase "$1" in\n  auth) exit 0 ;;\n  issue) exit 0 ;;\n  *) exit 1 ;;\nesac\n' \
        > "$_brev_kit/bin/gh"
      chmod +x "$_brev_kit/bin/gh"
      _t_brev="$TMP/target-idg-brev-tooth"
      mkstate "$_t_brev" 0 "high|done gap|covered"
      mkdir -p "$_t_brev/retros"
      printf '<!-- review-status: pending -->\n# Rev tooth retro\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | delta 1 | file.sh | ev | new | high |\n' \
        > "$_t_brev/retros/rev-retro.md"
      _brev_got="$(PATH="$_brev_kit/bin:$PATH" bash "$_brev_kit/research-sdd-status.sh" "$_t_brev" --next 2>/dev/null)"
      # Mutant: no re-verify → batch untracked trusted → false ISSUES-DUE emitted.
      # T-IDG-BATCH-FALSE-NEG expects STOP; mutant returns ISSUES-DUE → T-IDG-BATCH-FALSE-NEG goes RED.
      case "$_brev_got" in
        ISSUES-DUE\ *)
          ok "teeth-IDG-batch-reverify: mutant (no re-verify) → false ISSUES-DUE → T-IDG-BATCH-FALSE-NEG goes RED → IDG-BATCH-UNTRACKED-REVERIFY is load-bearing" ;;
        *)
          no "teeth-IDG-batch-reverify: mutant did not produce false ISSUES-DUE, got [$_brev_got] — tooth theater" ;;
      esac
    fi
  else
    no "teeth-IDG-batch-reverify: anchor '$_brev_anchor' not found in SUT"
  fi

  # teeth-SC-CROSS-CHECK: verify-state must NOT fire SC-CROSS-CHECK when prose is absent.
  # Guard deleted: prior sentinel searched $0 for a token defined in $0 — vacuous, cannot fail.
    # Build a matching fixture but intentionally omit the prose line (simulates broken printf '- ').
    d_sccc_tooth="$TMP/sc-cross-check-tooth"; mkdir -p "$d_sccc_tooth"
    { printf '# SC-CROSS-CHECK Tooth\n> intro\n'
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\n'
      printf 'gaps_closed: 0\nknown_gaps: 1\ninvestigable_open: 1\nrequires_execution_open: 0\n'
      printf 'blocked_open: 0\n<!-- /research-state.v1 -->\n\n'
      printf '## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n'
      printf '| high | open investigable gap | web | pending |\n\n## Blocked gaps\n\n## Stop control\n'
      # Intentionally NO prose line — simulates what broken printf '- **Open gaps...\n' produced.
    } > "$d_sccc_tooth/RESEARCH-STATE.md"
    _sccc_tooth_out="$(bash "$HERE/../verify-state.sh" "$d_sccc_tooth" 2>&1)"
    _sccc_tooth_ec=$?
    if [ "$_sccc_tooth_ec" -eq 127 ]; then
      no "teeth-SC-CROSS-CHECK: verify-state.sh absent (exit 127) — tooth cannot distinguish SC-CROSS-CHECK silent from helper absent"
    elif echo "$_sccc_tooth_out" | grep -qF "$_SC_CROSS_CHECK_FAIL"; then
      no "teeth-SC-CROSS-CHECK: verify-state fired SC-CROSS-CHECK even without prose line — tooth invalid (SC-CROSS-CHECK should be silent when prose is absent)"
    else
      ok "teeth-SC-CROSS-CHECK: SC-CROSS-CHECK silent without prose → T-SC-CROSS-CHECK not theater (would be RED if prose absent)"
    fi

  # ── #911 A2 teeth ────────────────────────────────────────────────────────────────────────────────
  # teeth-BP-EXPECTED-COLS: revert expected_cols=n to expected_cols=0; T-5COL-SYNC must go RED
  # (5-col rows not counted → known_gaps falls back to env 0 → T-5COL-SYNC fails ≥2 assertion).
  # Uses a fresh fixture (known_gaps: 0) so pick() doesn't salvage the previous envelope value.
  echo "-- teeth-BP-EXPECTED-COLS: replace expected_cols=n with expected_cols=0 → 5-col rows not counted --"
  _bpec_mutant="$TMP/status.BPEC.MUTANT.sh"
  _bpec_d="$TMP/bpec-tooth"; mkdir -p "$_bpec_d"
  { echo "# T"; echo; env_lines 0 0 0 0 0 0; echo
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Pr. | ID | Gap | Artifact | Status |"; echo "|---|---|---|---|---|"
    echo "| high | G1 | five-col covered gap | bin.dll | covered |"
    echo "| low  | G2 | five-col covered gap | bin2.dll | covered |"; echo
    echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$_bpec_d/RESEARCH-STATE.md"
  if grep -q '# BP-EXPECTED-COLS' "$SUT"; then
    sed 's/expected_cols=n; next/expected_cols=0; next/' "$SUT" > "$_bpec_mutant"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    bash "$_bpec_mutant" "$_bpec_d" --sync-state >/dev/null 2>&1
    _bpec_kg="$(awk '/<!-- research-state.v1 -->/{b=1;next}/<!-- \/research-state.v1 -->/{b=0}b&&/^[[:space:]]*known_gaps:/{print $2;exit}' "$_bpec_d/RESEARCH-STATE.md")"
    if [ "${_bpec_kg:-0}" -lt 2 ]; then
      ok "teeth-BP-EXPECTED-COLS: mutant (expected_cols=0) → known_gaps=${_bpec_kg} < 2 → T-5COL-SYNC goes RED → BP-EXPECTED-COLS is load-bearing"
    else
      no "teeth-BP-EXPECTED-COLS: mutant still derived known_gaps=${_bpec_kg} ≥ 2 — THEATER"
    fi
  else
    no "teeth-BP-EXPECTED-COLS: BP-EXPECTED-COLS sentinel not found in SUT"
  fi

  # teeth-MED-ABBREV-NORM: delete MED-ABBREV-NORM line; T-MED-ABBREV-SYNC must go RED
  # (med rows → INVALID_PRIORITY → sync-state refuses with exit 1).
  # Uses a fresh fixture (known_gaps: 0) to avoid env fallback masking the refusal.
  echo "-- teeth-MED-ABBREV-NORM: delete MED-ABBREV-NORM; med row must fall to INVALID_PRIORITY --"
  _medabn_mutant="$TMP/status.MEDABN.MUTANT.sh"
  _medabn_d="$TMP/medabn-tooth"; mkdir -p "$_medabn_d"
  { echo "# T"; echo; env_lines 0 0 0 0 0 0; echo
    echo "## Gap-backlog"; echo
    echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
    echo "| med | med-abbrev gap | web | covered |"; echo
    echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$_medabn_d/RESEARCH-STATE.md"
  if grep -q '# MED-ABBREV-NORM' "$SUT"; then
    sed '/# MED-ABBREV-NORM/d' "$SUT" > "$_medabn_mutant"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    bash "$_medabn_mutant" "$_medabn_d" --sync-state >/dev/null 2>&1; _medabn_rc=$?
    if [ "$_medabn_rc" -ne 0 ]; then
      ok "teeth-MED-ABBREV-NORM: mutant → med row INVALID_PRIORITY (rc=$_medabn_rc) → T-MED-ABBREV-SYNC goes RED → MED-ABBREV-NORM is load-bearing"
    else
      no "teeth-MED-ABBREV-NORM: mutant sync-state exited 0 — THEATER (expected exit 1 from INVALID_PRIORITY refusal)"
    fi
  else
    no "teeth-MED-ABBREV-NORM: MED-ABBREV-NORM sentinel not found in SUT"
  fi

  # teeth-OOB-WARN: delete OOB-WARN line; T-OOB-WARN must go RED (no WARN mentioning Gap-backlog).
  echo "-- teeth-OOB-WARN: delete OOB-WARN line → no warning for out-of-section row --"
  _oobw_mutant="$TMP/status.OOBWARN.MUTANT.sh"
  if grep -q '# OOB-WARN' "$SUT"; then
    sed '/# OOB-WARN/d' "$SUT" > "$_oobw_mutant"
    cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
    _oobw_warn="$(bash "$_oobw_mutant" "$d_oob" --sync-state 2>&1 >/dev/null)"
    if ! echo "$_oobw_warn" | grep -qi 'Gap-backlog\|gap.backlog'; then
      ok "teeth-OOB-WARN: mutant suppresses OOB-WARN → T-OOB-WARN goes RED → OOB-WARN is load-bearing"
    else
      no "teeth-OOB-WARN: mutant still emitted Gap-backlog WARN — THEATER"
    fi
  else
    no "teeth-OOB-WARN: OOB-WARN sentinel not found in SUT"
  fi

fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
