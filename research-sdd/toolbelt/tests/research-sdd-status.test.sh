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
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-status.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a fixture kit
# HERMETICITY (kit issue #1140 round-2 review, Blocking 4): lib/hook-wiring.sh's git-root walk-up
# climbs from a target to `/` unless RSDD_HOOK_WIRING_CEILING is set. Case 32f below git-inits a
# fixture under $TMP; without this, a $TMPDIR that happens to sit inside a real repo would let an
# ENCLOSING repo's .git bleed into every fixture here.
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"
export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0; skips=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# skip: a SKIP is not a pass — name it and count it separately (kit issue #1005 round 2, W4). Used
# when a check's precondition (e.g. GNU date) is unmet on this host, not when the check itself fails.
skip(){ printf '  SKIP  %s\n' "$1"; skips=$((skips+1)); }

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
  rsdd_stage_libs "$kdir"
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
  rsdd_stage_libs "$kdir"
  cp "$SUT" "$kdir/research-sdd-status.sh"
  cp "$HERE/../verify-state.sh" "$kdir/verify-state.sh"
  cp "$HERE/../reconcile-issues.sh" "$kdir/reconcile-issues.sh"
  # kit issue #1287 item 3: reconcile treats an absent/zero-row TARGETS.md as an OPERATIONAL failure
  # (exit 1), so the fixture kit needs a registry. Callers pass a kdir of the form
  # <root>/research-sdd/toolbelt, making <root> the KIT_ROOT reconcile derives. One dummy row (a path
  # that does not exist) keeps every fixture retro "unregistered" → the legacy WARN + basename path.
  printf '# fixture targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | fixture-dummy | `/nonexistent-kit-fixture-target` |\n' \
    > "$kdir/../TARGETS.md"
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

# 32d — settings.json unreadable (chmod 000) → unreadable. Skipped when running as root.
if [ "$(id -u)" != "0" ]; then
  d="$TMP/hook-unreadable"; mkstate "$d" 1 "high|g1|pending"
  mkdir -p "$d/.claude"
  printf '{"hooks":{"Stop":[]}}' > "$d/.claude/settings.json"
  chmod 000 "$d/.claude/settings.json"
  rep="$(bash "$SUT" "$d" 2>/dev/null)"
  chmod 644 "$d/.claude/settings.json"   # restore so cleanup works
  grep -qF 'Stop hook       : unreadable' <<<"$rep" \
    && ok "32d Stop hook line: unreadable (permission error)" \
    || no "32d Stop hook line: unreadable" "$(grep -i 'Stop hook' <<<"$rep")"
else
  skip "32d Stop hook line: unreadable (running as root; permission bits bypassed)"
fi

# NOTE (kit issue #1140 round-2 review, Blocking 5): the '(checked: ...)' path suffix (formerly
# 32e here) and the missing/broken-lib coverage (formerly 32g/32h here) were split OUT of this PR
# into their own follow-up work, now tracked as kit issue #1150 — the suffix changes ALL 15
# reachable status reports, not only three.js, breaking this PR's own "byte-identical except
# three.js" acceptance claim (kit §6: a calibration change is its own work unit). 32f below (the
# wired-off-root STATE itself) is the only research-sdd-status.sh behavior kit issue #1135 actually
# needs, and it changes nothing for any target whose state is not wired-off-root, preserving the
# byte-identical claim.

# 32f — kit issue #1135: a registered target nested inside a git repo whose OWN root is a DIFFERENT,
# higher directory, with settings.json syntactically wired at the nested path → wired-off-root, not
# wired. This is the three.js shape: a real session launches from the git root, never the nested
# path, so the wired settings.json never loads in practice.
d_root="$TMP/hook-offroot-gitroot"; d="$d_root/nested"; mkstate "$d" 1 "high|g1|pending"
git init -q "$d_root" >/dev/null 2>&1
mkdir -p "$d/.claude"
printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}' > "$d/.claude/settings.json"
rep="$(bash "$SUT" "$d" 2>/dev/null)"
grep -qF 'Stop hook       : wired-off-root' <<<"$rep" \
  && ok "32f Stop hook line: wired-off-root (three.js shape — nested off git root)" \
  || no "32f Stop hook line: wired-off-root" "$(grep -i 'Stop hook' <<<"$rep")"


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


# T-IDG-CONTRACT: parser↔producer contract — real reconcile-issues.sh prints ^untracked: that gate counts.
# R3-STUB-ONLY: runs REAL reconcile (not a stub); gh is stubbed (auth→exit 0, issue list→empty).
# Empty issue list → delta has no matching open issue → reconcile classifies it as untracked.
# Gate's awk '/^untracked:/' must match reconcile's real output format → ISSUES-DUE.
_kit_ctr="$TMP/kit-idg-contract/research-sdd/toolbelt"
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

# T-IDG-NOTARGETS (kit issue #1304 item 5): a kit with NO TARGETS.md (absent) or a TARGETS.md with
# no registered rows (empty) must read as UNVERIFIED coverage, never as a bare verified-clean STOP.
# Real reconcile-issues.sh exits 1 on both (operational failure, kit issue #1287 item 3) and the
# status gate's F5b branch (IDG-OPFAIL-SENTINEL) turns that exit into the unverified marker.
# Runs the REAL reconcile (R3-STUB-ONLY convention); gh is stubbed. A pending retro with a delta
# guarantees reconcile is actually probed.
for _nt_case in absent empty; do
  _nt_kit="$TMP/kit-idg-notargets-$_nt_case/research-sdd/toolbelt"
  _nt_gh="$TMP/gh-stub-notargets-$_nt_case"
  mk_kit_real_reconcile "$_nt_kit" "$_nt_gh"
  case "$_nt_case" in
    absent) rm -f "$_nt_kit/../TARGETS.md" ;;
    empty)  printf '# fixture targets\n\n| # | Target | Path |\n|---|---|---|\n' > "$_nt_kit/../TARGETS.md" ;;
  esac
  _nt_t="$TMP/target-idg-notargets-$_nt_case"; mkstate "$_nt_t" 0 "high|done gap|covered"
  mkdir -p "$_nt_t/retros"
  cat > "$_nt_t/retros/notargets-retro.md" <<'NT_EOF'
<!-- review-status: pending -->
# No-targets retro

## Proposed kit deltas

| # | Proposed change | Target | Evidence | Priority |
|---|---|---|---|---|
| 1 | test delta | file.sh | evidence | high |
NT_EOF
  _nt_err="$TMP/idg-notargets-$_nt_case-stderr.txt"
  _nt_got="$(PATH="$_nt_gh:$PATH" bash "$_nt_kit/research-sdd-status.sh" "$_nt_t" --next 2>"$_nt_err")"
  _nt_rc=$?
  _nt_stderr="$(cat "$_nt_err")"
  if [ "$_nt_got" = "STOP | read-only-investigable exhausted (0) [issue-coverage: unverified]" ] \
     && grep -q 'reconcile-issues.sh failed' <<<"$_nt_stderr" \
     && [ "$_nt_rc" -eq 0 ]; then
    ok "T-IDG-NOTARGETS-$_nt_case: TARGETS.md $_nt_case → [issue-coverage: unverified] + reconcile-failed WARN + exit 0"
  else
    no "T-IDG-NOTARGETS-$_nt_case: stdout=[$_nt_got] stderr=[$_nt_stderr] rc=$_nt_rc — expected the unverified marker"
  fi
done

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
if grep -qF "$_SC_CROSS_CHECK_FAIL" <<<"$_sccc_out"; then
  ok "T-SC-CROSS-CHECK: verify-state SC-CROSS-CHECK fires (FAIL + stop-control prose) when prose (0) contradicts derived count (1)"
else
  no "T-SC-CROSS-CHECK: verify-state passed silently — SC-CROSS-CHECK did not fire on prose mismatch (prose absent or check skipped)"
fi

# T-BACKLOG-ROWS-MIRROR: awk body in backlog_rows() (status.sh) and _backlog_rows() (verify-state.sh)
# must be logically identical — they are kept as copies (not a lib) to preserve sentinel-based teeth.
# File-specific sentinel prefixes (SS- and VS-) are normalised to BP- before comparison so the test
# catches logic drift while allowing the file-scoped sentinel names the teeth require.
# Extract the awk interior (from BACKLOG-ROWS-AWK-START through OOB-WARN-EOF) from both files and diff.
# Normalize the extracted awk body for comparison:
# 1. Unify file-specific sentinel prefixes (SS- → BP-, VS- → BP-)
_normalize_awk_body() {
  sed 's/# SS-/# BP-/g; s/# VS-/# BP-/g'
}
_mirror_status="$(awk '/# BACKLOG-ROWS-AWK-START/{p=1} p{print} /OOB-WARN-EOF/{p=0}' "$SUT" | _normalize_awk_body)"
_mirror_vs="$(awk '/# BACKLOG-ROWS-AWK-START/{p=1} p{print} /OOB-WARN-EOF/{p=0}' "$HERE/../../rsdd/internal/verify/testdata/state-legacy/verify-state.sh" | _normalize_awk_body)"   # the frozen oracle of the Go port (kit issue #2457)
if [ -z "$_mirror_status" ]; then
  no "T-BACKLOG-ROWS-MIRROR: could not extract awk body from $SUT (BACKLOG-ROWS-AWK-START marker missing)"
elif [ -z "$_mirror_vs" ]; then
  no "T-BACKLOG-ROWS-MIRROR: could not extract awk body from the frozen verify-state.sh oracle (BACKLOG-ROWS-AWK-START marker missing)"
elif [ "$_mirror_status" = "$_mirror_vs" ]; then
  ok "T-BACKLOG-ROWS-MIRROR: awk logic identical in backlog_rows (status.sh) and _backlog_rows (verify-state.sh) after sentinel-prefix normalisation"
else
  no "T-BACKLOG-ROWS-MIRROR: awk body differs (logic drift, not just sentinel prefix); diff: $(diff <(echo "$_mirror_status") <(echo "$_mirror_vs") | head -10)"
fi

# T-M1-DENOM-UNSPACED: CHECK 3 must detect contradictory denominators even when fractions are
# unspaced (e.g. "7/8" vs "7/7"). The new awk match allows [[:space:]]* around the slash.
d_m1="$TMP/m1-unspaced"; mkdir -p "$d_m1"
{ echo "# T"; echo; env_lines 0 0 0 0 0; echo
  echo "## Gap-backlog"; echo
  echo "| Priority | Gap | type | Status |"; echo "|---|---|---|---|"
  echo "| high | g | t | covered |"
  echo
  echo "## Coverage"; echo "Coverage metric: 7/8"
  echo "Declared gaps closed: 7/7"
  echo
  echo "## Stop control"; echo "- **Open gaps — read-only investigable**: 0"; } > "$d_m1/RESEARCH-STATE.md"
_m1_out="$(bash "$HERE/../verify-state.sh" "$d_m1" 2>&1)"
if grep -qi 'contradictory' <<<"$_m1_out"; then
  ok "T-M1-DENOM-UNSPACED: unspaced fractions (7/8 vs 7/7) detected as contradictory denominators"
else
  no "T-M1-DENOM-UNSPACED: expected contradictory-denominators WARN for 7/8 vs 7/7 — got: [$(echo "$_m1_out" | grep -i denom | head -1)]"
fi

sx_env() { awk -v k="$2" '/<!-- research-state.v1 -->/{b=1;next}/<!-- \/research-state.v1 -->/{b=0}b&&$1==k":"{print $2;exit}' "$1"; }

if ! grep -q '\$(remote_visibility_block)' "$SUT"; then ok "RC-WIRE-1: remote_visibility_block is not run inside a command substitution"
else no "RC-WIRE-1: remote_visibility_block still runs inside \$(...) (loses its variables and trailing newlines)"; fi

# RC-WIRE-2/3: every degraded echo of the block sets the flag (structural, covers paths a fixture cannot
# reach: git absent, timeout absent, empty url), and the wire region buffers nothing.
_n_echo="$(grep -c 'echo "degraded: remote-visibility:' "$SUT")"
_n_flag="$(grep -c '_RC_DEGRADED_PRINTED=1; echo "degraded: remote-visibility:' "$SUT")"
if [ "$_n_echo" -gt 0 ] && [ "$_n_echo" = "$_n_flag" ]; then ok "RC-WIRE-2: all $_n_echo degraded echoes of the block set the flag on the same line"
else no "RC-WIRE-2: $_n_echo degraded echoes but $_n_flag set the flag"; fi
_wire_region="$(sed -n '/^# RC-WIRE-BEGIN$/,/^# RC-WIRE-END$/p' "$SUT")"
if [ -n "$_wire_region" ] && ! grep -qE 'mktemp|\$\(|tee |>"' <<<"$_wire_region"; then ok "RC-WIRE-3: the wire region has no temp file, subshell or redirect"
else no "RC-WIRE-3: the wire region buffers or forks"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # The mutant status scripts resolve $here to $TMP, so they need verify-state.sh at $TMP/verify-state.sh.
  # verify-state.sh and every toolbelt lib (staged by rsdd_stage_libs, tests/lib/stage-libs.sh) sit beside them, so
  # the PERF pre-filter (lib/retro-status.sh) runs inside mutants (safe: no markers in teeth fixtures, so the
  # pre-filter is transparent for existing mutant scenarios).
  rsdd_stage_libs "$TMP"
  # kit #1637: DECLARED-KEEP (a declared counter above the derivation is carried forward) shadows every control
  # whose mutant bites by clobbering such a counter or by changing the derivation that the keep now masks. Those
  # mechanisms are still load-bearing for fixtures with declared <= derived and for --only, so their mutants are
  # built from the SUT with DECLARED-KEEP removed (SUT_NK for cp-built mutants; an extra `-e '/# DECLARED-KEEP$/d'`
  # stage for mutant_sed ones — mutant_sed refuses an ORIG that lives in the temp tree): the mutation is then measured
  # against the mechanism it targets, not against the keep that masks it. The T1637-* teeth use the real SUT.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  SUT_NK="$TMP/status.NOKEEP.MUTANT.sh"
  mutant_sed "$SUT" "$SUT_NK" -e '/# DECLARED-KEEP$/d' || { echo "  FAIL  teeth-T1637-NOKEEP: could not build the keep-less base"; fail=$((fail+1)); }
  # nk_mutant_sed OUT SED_ARGS... — a mutant of the KEEP-LESS base. mutant_sed alone cannot catch a dead mutation
  # expression here (the always-applied keep deletion already makes OUT differ from the SUT), so the mutation must
  # additionally change the keep-less base itself: cmp SUT_NK vs OUT must differ. Prints the refusal, never counts.
  nk_mutant_sed() {
    local out="$1"; shift
    mutant_sed "$SUT" "$out" -e '/# DECLARED-KEEP$/d' "$@" || return 1
    if cmp -s "$SUT_NK" "$out"; then rm -f "$out"; echo "  FAIL  nk_mutant_sed: the mutation does not change the keep-less base (dead sed expression) — $out"; return 1; fi
  }













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











  # ---- ISSUE #143 teeth -----------------------------------------------------------------------
  # T54 targets copy-2 (verify-state.sh) via --next; T59-T62 target copy-1 (SUT::backlog_rows) via --sync-state.
  # (kit issue #2457) teeth-T54 mutated verify-state.sh's source; that script is a shim to the Go `rsdd verify state` now and its checks
  # are pinned by the Go differential tests and `make teeth` (internal/verify).


  # ---- Corpus vocabulary teeth: T59–T62 (skip forms in SUT::backlog_rows; oracle: --sync-state) ----
  # Copy-1 (SUT) skip guards: neutering makes --sync-state refuse (exit 1). T62 uses exit 0.
  cnt_occ() { awk -v n="$1" 'BEGIN{c=0}{s=$0;while((p=index(s,n))>0){c++;s=substr(s,p+length(n))}}END{print c}' "$2"; }
  printf 'no match\n'                         > "$TMP/cnt-proof.txt"; _cp0="$(cnt_occ "BPSKIP-X" "$TMP/cnt-proof.txt")"
  printf 'BPSKIP-X once\n'                    > "$TMP/cnt-proof.txt"; _cp1="$(cnt_occ "BPSKIP-X" "$TMP/cnt-proof.txt")"
  printf 'BPSKIP-X and BPSKIP-X same line\n' > "$TMP/cnt-proof.txt"; _cp2="$(cnt_occ "BPSKIP-X" "$TMP/cnt-proof.txt")"
  [ "$_cp0" = 0 ] && [ "$_cp1" = 1 ] && [ "$_cp2" = 2 ] && ok "cnt_occ: 0/1/2 same-line → 0/1/2 (self-proof)" || no "cnt_occ: proof failed (0=$_cp0 1=$_cp1 2=$_cp2)"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"  # restore real verify-state.sh














  # (kit issue #2457) teeth-907-T53 and teeth-907-T905 mutated verify-state.sh's source; that script is a shim to the Go `rsdd verify state` now and its checks
  # are pinned by the Go differential tests and `make teeth` (internal/verify).









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
      _ctr_mut_kit="$TMP/kit-teeth-ctr/research-sdd/toolbelt"   # <root>/research-sdd/toolbelt: root = KIT_ROOT (#1287)
      _ctr_mut_gh="$TMP/gh-stub-teeth-ctr"
      mkdir -p "$_ctr_mut_kit/lib" "$_ctr_mut_gh"
      cp "$idg_ctr_mutant" "$_ctr_mut_kit/research-sdd-status.sh"
      cp "$HERE/../verify-state.sh" "$_ctr_mut_kit/verify-state.sh"
      cp "$HERE/../reconcile-issues.sh" "$_ctr_mut_kit/reconcile-issues.sh"
      rsdd_stage_libs "$_ctr_mut_kit"
      # Registry (kit issue #1287 item 3): without it real reconcile exits 1 and the mutant's STOP
      # would be for the WRONG reason (an operational failure, not the corrupted awk pattern).
      printf '# fixture targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | fixture-dummy | `/nonexistent-kit-fixture-target` |\n' \
        > "$_ctr_mut_kit/../TARGETS.md"
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


  # ---- teeth-IDG-notargets (kit issue #1304 item 5): neuter IDG-OPFAIL-SENTINEL with the REAL
  # reconcile and NO TARGETS.md; the T-IDG-NOTARGETS cases must go RED (bare STOP).
  echo "-- teeth-IDG-notargets: sentinel-neutered mutant + real reconcile + absent TARGETS.md --"
  _ntm_kit="$TMP/kit-teeth-notargets/research-sdd/toolbelt"
  _ntm_gh="$TMP/gh-stub-teeth-notargets"
  mk_kit_real_reconcile "$_ntm_kit" "$_ntm_gh"
  rm -f "$_ntm_kit/../TARGETS.md"
  . "$HERE/lib/mutant.sh"
  if mutant_sed "$SUT" "$TMP/status.NOTARGETS.MUTANT.sh" -e 's/_idg_had_unverified=1  # IDG-OPFAIL-SENTINEL/: # MUTANT-NOTARGETS/'; then
    cp "$TMP/status.NOTARGETS.MUTANT.sh" "$_ntm_kit/research-sdd-status.sh"
    _ntm_t="$TMP/target-teeth-notargets"; mkstate "$_ntm_t" 0 "high|done gap|covered"
    mkdir -p "$_ntm_t/retros"
    printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n| # | Proposed change | Target | Evidence | Priority |\n|---|---|---|---|---|\n| 1 | d | f.sh | e | high |\n' \
      > "$_ntm_t/retros/r.md"
    _ntm_got="$(PATH="$_ntm_gh:$PATH" bash "$_ntm_kit/research-sdd-status.sh" "$_ntm_t" --next 2>/dev/null)"
    case "$_ntm_got" in
      "STOP | read-only-investigable exhausted (0)")
        ok "teeth-IDG-notargets: sentinel-neutered mutant → bare STOP → T-IDG-NOTARGETS goes RED" ;;
      *) no "teeth-IDG-notargets: mutant returned unexpected [$_ntm_got]" ;;
    esac
  else
    no "teeth-IDG-notargets: mutant refused by mutant.sh"
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
    elif grep -qF "$_SC_CROSS_CHECK_FAIL" <<<"$_sccc_tooth_out"; then
      no "teeth-SC-CROSS-CHECK: verify-state fired SC-CROSS-CHECK even without prose line — tooth invalid (SC-CROSS-CHECK should be silent when prose is absent)"
    else
      ok "teeth-SC-CROSS-CHECK: SC-CROSS-CHECK silent without prose → T-SC-CROSS-CHECK not theater (would be RED if prose absent)"
    fi








  # (kit issue #2457) teeth-T-M1-DENOM-UNSPACED mutated verify-state.sh's source; that script is a shim to the Go `rsdd verify state` now and its checks
  # are pinned by the Go differential tests and `make teeth` (internal/verify).

fi

CQ_FIX="$HERE/fixtures/campaign-queue"
d_cq_mf="$CQ_FIX/multi-focus-mixed"
d_w3="$CQ_FIX/multi-focus-stop-with-idle-sibling"
_gnu_date_ok=0
if grep -qi 'GNU coreutils' <<<"$(/usr/bin/date --version 2>/dev/null)"; then _gnu_date_ok=1; fi

# ro_dir_is_readonly <dir>: chmod 500 is only a read-only directory for a non-root caller. Probe it instead of
# assuming: when a write still succeeds (root, or a filesystem ignoring mode bits) the read-only test cannot
# run, and it must say so loudly (SKIP) instead of passing or failing for a reason that is not the SUT's.
ro_dir_is_readonly() {
  if ( : > "$1/.rsdd-ro-probe" ) 2>/dev/null; then rm -f "$1/.rsdd-ro-probe"; return 1; fi
  return 0
}

echo "-- Round 4 nit: _read_focuses_tok_into must not shadow a caller variable named like one of its OLD locals --"
# Before this fix, the function's own locals were _rft_var/ffile/sbase/_cache_key/_tok. printf -v
# resolves the target name against the NEAREST scope, so a caller whose own variable happened to be
# named e.g. "_tok" would have `printf -v "$_rft_var"` (with _rft_var="_tok") silently write into the
# FUNCTION's own local _tok instead of the caller's — the caller's real variable would stay whatever
# it was before, unset or stale, with no error. Every local is now __rft_-prefixed specifically to
# close this. Exercise it directly: source just the two functions this needs (declare -A line +
# _read_focuses_tok_into + _read_focuses_tok_uncached) into an isolated harness — sourcing the whole
# SUT would run its own argv-dependent top-level logic and `exit` the harness — then call it with a
# caller-side variable named "_tok" and confirm THAT variable receives the real token.
_shadow_harness="$TMP/shadow-harness.sh"
# Marker-based extraction (kit issue #1023): the SUT brackets the two functions this needs with
# SENTINEL-RFT-HARNESS-BEGIN / -END comments, so the slice survives any line shift above or below it and
# a missing or duplicated marker is a DISTINCT failure below, never misreported as the shadowing regression.
awk '/# SENTINEL-RFT-HARNESS-BEGIN/{p=1;next} /# SENTINEL-RFT-HARNESS-END/{p=0} p{print}' "$SUT" > "$_shadow_harness"
_shadow_nb="$(grep -cF 'SENTINEL-RFT-HARNESS-BEGIN' "$SUT")"; _shadow_ne="$(grep -cF 'SENTINEL-RFT-HARNESS-END' "$SUT")"
_shadow_dir="$TMP/shadow-fixture"; mkdir -p "$_shadow_dir"
{
  printf '# Focus Registry\n\n'
  printf '| Focus | Status | State file |\n'
  printf '|---|---|---|\n'
  printf '| alpha | active | RESEARCH-STATE-alpha.md |\n'
} > "$_shadow_dir/FOCUSES.md"
_shadow_err="$TMP/shadow-harness.err"
_shadow_out="$(bash -c '
  # shellcheck disable=SC1090
  source "$1"
  _tok="UNCHANGED"
  _read_focuses_tok_into _tok "$2" "RESEARCH-STATE-alpha.md"
  printf "%s" "$_tok"
' _ "$_shadow_harness" "$_shadow_dir/FOCUSES.md" 2>"$_shadow_err")"
if [ "$_shadow_nb" != 1 ] || [ "$_shadow_ne" != 1 ] || [ ! -s "$_shadow_harness" ]; then
  no "T-RFT-NO-SHADOW: harness extraction is broken (BEGIN markers=$_shadow_nb, END markers=$_shadow_ne, harness bytes=$(wc -c < "$_shadow_harness")) — this is NOT the shadowing regression"
elif [ -s "$_shadow_err" ]; then
  no "T-RFT-NO-SHADOW: the extracted harness wrote to stderr — a broken extraction, NOT the shadowing regression: [$(head -c 300 "$_shadow_err")]"
elif [ "$_shadow_out" = "active" ]; then
  ok "T-RFT-NO-SHADOW: a caller variable named '_tok' (collides with an old internal local name) still receives the correct token, not left unchanged"
else
  no "T-RFT-NO-SHADOW: expected the caller's _tok to become 'active', got [$_shadow_out] — printf -v wrote into the function's own local instead of the caller's variable"
fi

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "== TEETH BANNER: campaign-queue mutation controls =="










  # teeth-T-CQ-MF-STOP / teeth-T-CQ-MF-STALL (R3-teeth-mf-or-logic, round 3): truncate the
  # active-focus list back down to just the first one (reproducing the original "only $state" bug).
  # Round 2 OR'd the false-STOP and stall-WARN-drop signals into one combined verdict, so EITHER half
  # of the multi-focus fix alone could carry the whole mutant to "ok" while the other half had gone
  # untested that run — split into two independent teeth, each with its own bite and its own verdict.
  echo "-- teeth-T-CQ-MF-STOP / teeth-T-CQ-MF-STALL: truncate active focuses to first-only → each half goes RED independently --"
  _cq_mf_mutant="$TMP/status.CQ-MF.MUTANT.sh"
  if grep -q 'CQB-MULTIFOCUS-ANCHOR' "$SUT"; then
    cp "$SUT" "$_cq_mf_mutant"
    sed -i '/CQB-MULTIFOCUS-ANCHOR/a\  _cqb_active=("${_cqb_active[0]}")' "$_cq_mf_mutant"
    if cmp -s "$_cq_mf_mutant" "$SUT"; then
      no "teeth-T-CQ-MF-STOP: mutant identical to SUT — sed did not apply"
      no "teeth-T-CQ-MF-STALL: mutant identical to SUT — sed did not apply"
    elif ! bash -n "$_cq_mf_mutant" 2>/dev/null; then
      no "teeth-T-CQ-MF-STOP: mutant has syntax error"
      no "teeth-T-CQ-MF-STALL: mutant has syntax error"
    else
      # Half 1: false-STOP regression (T-CQ-MF-NO-FALSE-STOP) — independent of GNU date.
      _cq_mf_mut_out="$(bash "$_cq_mf_mutant" "$d_cq_mf" 2>&1)"
      if grep -qE '^\s*campaign_stop\s*:\s*STOP reached' <<<"$_cq_mf_mut_out"; then
        ok "teeth-T-CQ-MF-STOP: mutant false-STOPs on first-focus-only again → T-CQ-MF-NO-FALSE-STOP goes RED → the multi-focus scan (STOP half) is load-bearing"
      else
        no "teeth-T-CQ-MF-STOP: mutant did not reproduce the false-STOP — THEATER"
      fi

      # Half 2: dropped stall-WARN regression (T-CQ-MF-STALL) — needs GNU date for the reference
      # epoch; SKIP loudly (never silently) when unavailable, exactly like the functional test does.
      if [ "$_gnu_date_ok" -ne 1 ]; then
        skip "teeth-T-CQ-MF-STALL: GNU date not found on this host — cannot compute beta's reference epoch for this mutant test"
      else
        _cq_mf_beta_epoch2="$(/usr/bin/date -u -d "2026-09-24T00:00:00Z" +%s 2>/dev/null)"
        if [ -z "$_cq_mf_beta_epoch2" ]; then
          no "teeth-T-CQ-MF-STALL: cannot compute beta's reference epoch"
        else
          _cq_mf_stall_mut_out="$(_RSDD_NOW_EPOCH=$(( _cq_mf_beta_epoch2 + 960 )) bash "$_cq_mf_mutant" "$d_cq_mf" 2>&1)"
          if ! grep -qi 'WARN.*stall' <<<"$_cq_mf_stall_mut_out"; then
            ok "teeth-T-CQ-MF-STALL: mutant drops beta's stall WARN on first-focus-only again → T-CQ-MF-STALL goes RED → the multi-focus scan (stall half) is load-bearing"
          else
            no "teeth-T-CQ-MF-STALL: mutant still emits beta's stall WARN — THEATER"
          fi
        fi
      fi
    fi
  else
    no "teeth-T-CQ-MF-STOP: CQB-MULTIFOCUS-ANCHOR sentinel not found in SUT"
    no "teeth-T-CQ-MF-STALL: CQB-MULTIFOCUS-ANCHOR sentinel not found in SUT"
  fi





  # teeth-T-W3-WORDING: revert the aggregate STOP count from the queue-bearing count back to the
  # total active-focus count → the wording overclaims again on a mixed fixture (idle no-queue sibling
  # counted as "terminal") → T-W3-STOP-POSITIVE must go RED.
  echo "-- teeth-T-W3-WORDING: revert aggregate STOP count to total-active (overclaim) → T-W3-STOP-POSITIVE goes RED --"
  _w3_mutant="$TMP/status.W3-WORDING.MUTANT.sh"
  if grep -q 'W3-WORDING-ANCHOR' "$SUT"; then
    cp "$SUT" "$_w3_mutant"
    sed -i '/W3-WORDING-ANCHOR/s/"\$_cqb_n_queue"/"${#_cqb_active[@]}"/' "$_w3_mutant"
    if cmp -s "$_w3_mutant" "$SUT"; then
      no "teeth-T-W3-WORDING: mutant identical to SUT — sed did not apply"
    elif ! bash -n "$_w3_mutant" 2>/dev/null; then
      no "teeth-T-W3-WORDING: mutant has syntax error"
    else
      _w3_mut_out="$(bash "$_w3_mutant" "$d_w3" 2>/dev/null)"
      if grep -qE '^\s*campaign_stop\s*:\s*STOP reached — all 3 queue-bearing focuses terminal' <<<"$_w3_mut_out"; then
        ok "teeth-T-W3-WORDING: mutant overclaims 'all 3 ... terminal' (gamma has no queue) → T-W3-STOP-POSITIVE goes RED → the queue-bearing count is load-bearing"
      else
        no "teeth-T-W3-WORDING: mutant did not reproduce the overclaimed count [$(echo "$_w3_mut_out" | grep -E '^\s*campaign_stop\s*:')] — THEATER"
      fi
    fi
  else
    no "teeth-T-W3-WORDING: W3-WORDING-ANCHOR sentinel not found in SUT"
  fi

  # --- kit issue #1109 teeth: 'Stop hook: ...' self-report line -----------------------------------
  echo "-- teeth-STOP-HOOK-LINE: remove the Stop-hook self-report line; test 32b must go RED --"
  d="$TMP/hook-wired-teeth"; mkstate "$d" 1 "high|g1|pending"
  mkdir -p "$d/.claude"
  printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}' > "$d/.claude/settings.json"
  _sh_mutant="$TMP/status.STOP-HOOK.MUTANT.sh"
  if grep -qF 'echo "  Stop hook       : $(hook_stop_wiring_state "$target")' "$SUT"; then
    grep -vF 'echo "  Stop hook       : $(hook_stop_wiring_state "$target")' "$SUT" > "$_sh_mutant"
    _sh_mut_out="$(bash "$_sh_mutant" "$d" 2>/dev/null)"
    # The mutant must still print the report HEADER: an absent Stop hook line proves nothing if a crash
    # (empty output) is what removed it (kit issue #1150 item 3).
    if ! grep -qF '== research-sdd-status:' <<<"$_sh_mut_out"; then
      no "teeth-STOP-HOOK-LINE: mutant printed no report header — a crash, not a line removal — THEATER" "out=[$_sh_mut_out]"
    elif ! grep -q 'Stop hook' <<<"$_sh_mut_out"; then
      ok "teeth-STOP-HOOK-LINE: line removed, report header intact → test 32b/32a/32c/32d go RED (line absent) — has teeth"
    else
      no "teeth-STOP-HOOK-LINE: mutant must drop the Stop hook line — THEATER" "out=[$_sh_mut_out]"
    fi
  else
    no "teeth-STOP-HOOK-LINE: 'Stop hook' echo line not found in SUT (drifted?)"
  fi

  echo "-- teeth-STOP-HOOK-STATE: force hook_stop_wiring_state's own logic to always report 'wired' (via lib/hook-wiring.sh mutation); test 32a/32c/32d must go RED --"
  _sh_lib_mutant="$TMP/hook-wiring.STOP-HOOK-STATE.MUTANT.sh"
  printf 'hook_stop_wiring_state() { echo "wired"; return 0; }\n' > "$_sh_lib_mutant"
  _sh2_mutant_dir="$TMP/status-libmut/toolbelt"
  rsdd_stage_libs "$_sh2_mutant_dir"
  cp "$SUT" "$_sh2_mutant_dir/research-sdd-status.sh"
  cp "$_sh_lib_mutant" "$_sh2_mutant_dir/lib/hook-wiring.sh"
  d="$TMP/hook-absent-teeth"; mkstate "$d" 1 "high|g1|pending"
  _sh2_out="$(bash "$_sh2_mutant_dir/research-sdd-status.sh" "$d" 2>/dev/null)"
  if grep -qF 'Stop hook       : wired' <<<"$_sh2_out"; then
    ok "teeth-STOP-HOOK-STATE: always-wired lib mutant false-reports wired for absent-settings target — has teeth"
  else
    no "teeth-STOP-HOOK-STATE: always-wired lib mutant must false-report wired — THEATER" "out=[$_sh2_out]"
  fi
fi

if [ "${1:-}" = "--prove-teeth" ]; then
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"   # mutants resolve $here to $TMP
  # sx_mutant <name> <sed-script>: build a non-empty, syntactically valid mutant; prints its path.
  sx_mutant() {
    local m="$TMP/status.$1.MUTANT.sh"
    cp "${SX_ORIG:-$SUT}" "$m"; sed -i "$2" "$m"
    if cmp -s "$m" "${SX_ORIG:-$SUT}"; then no "teeth-$1: mutant identical to its base — sed did not apply" >&2; return 1; fi
    bash -n "$m" 2>/dev/null || { no "teeth-$1: mutant has a syntax error" >&2; return 1; }
    printf '%s' "$m"
  }
fi

# ==================== kit #1307 — sync-state derivations: closed-class rows / near-miss headings / non-backlog tables ====================
# Closed-class = deferred / em-dash / struck priority rows: COUNTED in known_gaps (and gaps_closed when closed), never routable.
# b13_fix <dir> <heading> <header-row> <rows...>: stale 0-counter fence + ONE backlog table under <heading>.
b13_fix() {
  local dir="$1" heading="$2" hdr="$3" r cols; shift 3; mkdir -p "$dir"
  cols="$(awk -F'|' '{print NF-2}' <<<"$hdr")"
  { echo "# T"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n<!-- /research-state.v1 -->\n'
    echo; echo "$heading"; echo; echo "$hdr"
    printf '|'; for _ in $(seq "$cols"); do printf -- '---|'; done; echo
    for r in "$@"; do echo "$r"; done
    echo; echo "## Blocked gaps"
  } > "$dir/RESEARCH-STATE.md"
}
# b13_run <dir>: run --sync-state (stderr kept in <dir>/.b13err, read with b13_err) and echo "kg gc io def".
b13_run() {
  bash "${B13_SUT:-$SUT}" "$1" --sync-state >"$1/.b13out" 2>"$1/.b13err"
  local f="$1/RESEARCH-STATE.md"
  echo "$(sx_env "$f" known_gaps) $(sx_env "$f" gaps_closed) $(sx_env "$f" investigable_open) $(sx_env "$f" deferred_open)"
}
B13H4='| Priority | Gap | type | Status |'
b13_err() { cat "$1/.b13err"; }
b13_expect() { # <label> <got "kg gc io def"> <want>
  [ "$2" = "$3" ] && ok "$1: kg/gc/io/def = [$2]" || no "$1: got [$2] want [$3]"
}

b13_decl() { sed -i -e "s/^known_gaps: .*/known_gaps: $2/" -e "s/^gaps_closed: .*/gaps_closed: $3/" "$1/RESEARCH-STATE.md"; }

b13_b2_fix() { # <dir> <declared kg> <declared gc>
  b13_fix "$1" "## Gap backlog" "$B13H4" '| 4 | X-G | closed | x |' '| — | e1 | web | closed |' '| — | e2 | web | closed |' '| — | e3 | web | closed |' '| — | e4 | web | closed |' '| high | g1 | web | pending |'
  printf '\n## Coverage\n\n- **Coverage metric**: 3 / 4 closed\n' >> "$1/RESEARCH-STATE.md"; b13_decl "$1" "$2" "$3"
}


b19_decl() { sed -i -e "s/^known_gaps: .*/known_gaps: $2/" -e "s/^gaps_closed: .*/gaps_closed: $3/" "$1/RESEARCH-STATE.md"; }
PROSE_C='— note: rows use the a | b convention'
PROSE_T='low | prose with | several | pipes | inside'
b50_fx_prose_closed() { b13_fix "$1" "## Gap-backlog" "$B13H4" '| — | e1 | web | ✅ B1 |' '| — | e2 | web | ✅ B2 |' '| high | g1 | web | pending |' '' "$PROSE_C"; b19_decl "$1" 4 3; }
b50_fx_prose_tier()   { b13_fix "$1" "## Gap-backlog" "$B13H4" '| high | g1 | web | pending |' '| low | g2 | web | ✅ B1 |' '' "$PROSE_T"; b19_decl "$1" 3 2; }
b50_fx_prose_first()  { b13_fix "$1" "## Gap-backlog" "$B13H4" '' "$PROSE_T" '| high | g1 | web | pending |' '| low | g2 | web | ✅ B1 |'; b19_decl "$1" 3 2; }

b50_fx_indented() { b13_fix "$1" "## Gap-backlog" "$B13H4" '| high | g1 | web | pending |' '| low | g2 | web | ✅ B1 |' '   | low | real | malformed | row | here |'; b19_decl "$1" 3 2; }

if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_or_count mutant_chain_or_count mutant_crash_re || exit 2
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  rsdd_stage_libs "$TMP"
  # b13_tooth <name> <sed-script> <fixture-builder: heading> <hdr> <want-good> <rows...> — OR stderr mode when want-good is "ERR:<pattern>"

  # ---- teeth for the #1307 review round (B1, B2, GCMAX, NOTE, GRUPO, BOLDHDR) ----
  # b13_tooth2 <name> <want-good or ERR:pattern> <builder-fn> <mutant sed -e args...> : builder-fn <dir> builds the fixture.
  b13_tooth2() {
    local name="$1" want="$2" builder="$3" m dd got; shift 3
    m="$TMP/status.B13-$name.MUTANT.sh"
    if ! nk_mutant_sed "$m" "$@"; then no "teeth-B13-$name: mutant refused by mutant.sh (no-op / invalid bash)"; return; fi
    dd="$TMP/b13-teeth-$name"; "$builder" "$dd"; got="$(B13_SUT="$m" b13_run "$dd")"
    if [[ "$want" == HAS:* ]]; then  # the mutant must GAIN the line (a message the good run never prints)
      if grep -qiF -- "${want#HAS:}" <<<"$(b13_err "$dd")"; then ok "teeth-B13-$name: mutant gains [${want#HAS:}] → its test goes RED"; else no "teeth-B13-$name: mutant still lacks [${want#HAS:}] — THEATER"; fi
    elif [[ "$want" == ERR:* ]]; then
      if grep -qiF -- "${want#ERR:}" <<<"$(b13_err "$dd")"; then no "teeth-B13-$name: mutant still emits [${want#ERR:}] — THEATER"; else ok "teeth-B13-$name: mutant loses [${want#ERR:}] → its test goes RED"; fi
    elif [ "$got" = "$want" ]; then no "teeth-B13-$name: mutant still derives [$got] — THEATER"
    else ok "teeth-B13-$name: mutant derives [$got] instead of [$want] → its test goes RED"; fi
  }

  b13_tooth2 B50-PROSE-CLOSED "HAS:keeping the declared known_gaps" b50_fx_prose_closed -e 's/function unc(tier) { if (isrow) print/function unc(tier) { if (1) print/'
  b13_tooth2 B50-PROSE-TIER "HAS:keeping the declared known_gaps" b50_fx_prose_tier -e 's/function unc(tier) { if (isrow) print/function unc(tier) { if (1) print/'
  b13_tooth2 B50-PROSE-FIRST "HAS:keeping the declared known_gaps" b50_fx_prose_first -e 's/function unc(tier) { if (isrow) print/function unc(tier) { if (1) print/'
  b13_tooth2 B50-INDENTED-ROW "3 2 1 0" b50_fx_indented -e 's/isrow = (\$0 ~ \/\^\[ \\t\]\*\\|\/)/isrow = ($0 ~ \/^\\|\/)/'
  # ---- no-op guards (#1637 review): a deliberately stale sed expression is refused in each keep-less path ----
  if _g_out="$(nk_mutant_sed "$TMP/status.GUARD-NK.MUTANT.sh" -e 's/THIS_TEXT_IS_NOT_IN_THE_SUT/x/' 2>&1)"; then
    no "guard-nk_mutant_sed: stale expression was accepted"
  elif [ -e "$TMP/status.GUARD-NK.MUTANT.sh" ]; then no "guard-nk_mutant_sed: refused but left a mutant file behind"
  elif grep -q 'does not change the keep-less base' <<<"$_g_out"; then ok "guard-nk_mutant_sed: stale expression refused (keep-less base unchanged)"
  else no "guard-nk_mutant_sed: refused for the wrong reason — [$_g_out]"; fi
  if (SX_ORIG="$SUT_NK" sx_mutant GUARD-SX 's/THIS_TEXT_IS_NOT_IN_THE_SUT/x/' >/dev/null 2>"$TMP/guard-sx.err"); then
    no "guard-sx_mutant: stale expression was accepted against SX_ORIG"
  elif grep -q 'identical to its base' "$TMP/guard-sx.err"; then ok "guard-sx_mutant: stale expression refused against SX_ORIG"
  else no "guard-sx_mutant: refused for the wrong reason — [$(cat "$TMP/guard-sx.err")]"; fi
fi


# ==================== kit issue #1023: test follow-ups ====================
# (the marker-based RFT extraction and the root-safe read-only TMPDIR guards live where those tests do;
# this section checks the guard helper itself.)
# The read-only-directory probe must tell a writable directory from a read-only one.
_ro_w="$(mktemp -d)"
if ro_dir_is_readonly "$_ro_w"; then no "T-1023-probe: a plain writable directory was reported read-only (the SKIP guard would never fire)"
else ok "T-1023-probe: a writable directory is NOT read-only (a root run would SKIP, not pass or fail)"; fi
if [ "$(id -u)" != 0 ]; then
  chmod 500 "$_ro_w"
  if ro_dir_is_readonly "$_ro_w"; then ok "T-1023-probe: a chmod-500 directory IS read-only for a non-root caller"
  else no "T-1023-probe: a chmod-500 directory was reported writable for a non-root caller"; fi
  chmod 700 "$_ro_w"
fi
rm -rf "$_ro_w"

if [ "$skips" -gt 0 ]; then
  echo "== $pass passed · $fail failed · $skips skipped =="
else
  echo "== $pass passed · $fail failed =="
fi
[ "$fail" -eq 0 ] || exit 1

