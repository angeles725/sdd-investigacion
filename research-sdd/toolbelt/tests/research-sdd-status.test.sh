#!/usr/bin/env bash
# research-sdd-status.test.sh — RED-FIRST harness for research-sdd-status.sh --next resolution.
#
# The discriminating behaviour is DETERMINISTIC gap selection: highest-priority PENDING gap that is
# NOT blocked. Fixtures assert the ORDER (high beats medium beats low), the blocked-exclusion, and the
# clean STOP. The script-mutation teeth were retired: their faults are killed by Go tests (S8c, #2549),
# research-sdd/rsdd/internal/status/show. --prove-teeth now runs only the SC-CROSS-CHECK guard.
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
_mirror_status="$(awk '/# BACKLOG-ROWS-AWK-START/{p=1} p{print} /OOB-WARN-EOF/{p=0}' "$HERE/../../rsdd/internal/status/show/testdata/legacy/status-scan.sh" | _normalize_awk_body)"   # the frozen oracle of the status port (kit issue #2549): the script is a shim now
_mirror_vs="$(awk '/# BACKLOG-ROWS-AWK-START/{p=1} p{print} /OOB-WARN-EOF/{p=0}' "$HERE/../../rsdd/internal/verify/testdata/state-legacy/verify-state.sh" | _normalize_awk_body)"   # the frozen oracle of the Go port (kit issue #2457)
if [ -z "$_mirror_status" ]; then
  no "T-BACKLOG-ROWS-MIRROR: could not extract awk body from the frozen status oracle (BACKLOG-ROWS-AWK-START marker missing)"
elif [ -z "$_mirror_vs" ]; then
  no "T-BACKLOG-ROWS-MIRROR: could not extract awk body from the frozen verify-state.sh oracle (BACKLOG-ROWS-AWK-START marker missing)"
elif [ "$_mirror_status" = "$_mirror_vs" ]; then
  ok "T-BACKLOG-ROWS-MIRROR: awk logic identical in the frozen backlog_rows (status.sh) and _backlog_rows (verify-state.sh) oracles of the two Go ports after sentinel-prefix normalisation"
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

# RC-WIRE-1..3 (structural greps over the script body: no command substitution around the block, every degraded echo sets
# the flag, no buffering in the wire region) were retired with the body (kit issue #2549). Their behaviour is pinned in Go:
# s6_scen_vis_test.go v-degraded-line-sets-the-footer (a typed remote-visibility line sets the reason-codes footer) and
# s8a_blocked_test.go (the blocked-rows step prints the footer exactly once, after the step), both replayed against goldens.

# The script-mutation teeth of this suite (sed/awk on a copy of research-sdd-status.sh) were retired:
# every fault they injected is killed by a Go test or scenario in
# research-sdd/rsdd/internal/status/show (S8c, #2549). What stays below mutates nothing.
if [ "${1:-}" = "--prove-teeth" ]; then
  # SC-CROSS-CHECK guard (not a script mutation): verify-state must NOT fire SC-CROSS-CHECK when prose is absent.
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
fi

# ro_dir_is_readonly <dir>: chmod 500 is only a read-only directory for a non-root caller. Probe it instead of
# assuming: when a write still succeeds (root, or a filesystem ignoring mode bits) the read-only test cannot
# run, and it must say so loudly (SKIP) instead of passing or failing for a reason that is not the SUT's.
ro_dir_is_readonly() {
  if ( : > "$1/.rsdd-ro-probe" ) 2>/dev/null; then rm -f "$1/.rsdd-ro-probe"; return 1; fi
  return 0
}

# T-RFT-NO-SHADOW (a bash `printf -v` into a caller variable named like an old local of _read_focuses_tok_into) was retired
# with the body: the shadowing class does not exist in Go (kit issue #2549). The FOCUSES token itself, including the
# per-(file, state) cache of _read_focuses_tok_into, stays pinned by the S2 differential (s2_diff_test.go __into_twice).





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

