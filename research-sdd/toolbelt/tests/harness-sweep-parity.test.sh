#!/usr/bin/env bash
# harness-sweep-parity.test.sh — locks the canonical sweep-script set across the supported agent
# harnesses (Claude, Pi, gentle-shell) so a future edit to one harness that forgets the others is
# caught immediately.
#
# OpenCode support was dropped on 2026-09-23 (#954); its surface (toolbelt/opencode/
# research-sdd-sweep.ts) has been removed. Codex and Reasonix were dropped on 2026-10-03 (#1471).
# Pi (and its isolated-home wrapper gentle-shell) is the manual-sweep harness: its golden plan
# lists the canonical sweep scripts explicitly.
#
# WHY THIS TEST EXISTS (anti-theater):
#   Parity drifted silently once (README said 2 scripts; .claude/settings.json had grown to 4;
#   the manual-harness golden listed all 4 by hand; nothing bound both surfaces to one canonical list).
#   This test does that binding: it parses each authoritative source file directly (no hardcoded
#   list that would rot) and fails if any harness adds, drops, or renames a sweep script relative
#   to the canonical set.
#
# Surfaces parsed (all must agree on the same canonical names):
#   Claude       : .claude/settings.json                    — SessionStart hook command paths
#   Pi           : install/tests/golden/plan-pi.txt          — backtick-quoted toolbelt/ entries
#   gentle-shell : install/tests/golden/plan-gentle-shell.txt — same shape as Pi
#
# Canonical name normalisation:
#   Claude wires -hook.sh wrapper scripts; strip "-hook" suffix to recover the base name that
#   the manual-sweep harnesses reference directly. Result: sweep-retros, sweep-audits,
#   sweep-breakthroughs, verify-registry, verify-kit-clean, sweep-tools, verify-tool-catalog.
#
# Usage: harness-sweep-parity.test.sh [--prove-teeth]
# Exit : 0 all held · 1 regression · 2 harness error (source file missing / jq absent)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
REPO="$(cd "$TOOLBELT/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# ---- Source file paths -----------------------------------------------------
SETTINGS="$REPO/.claude/settings.json"
PI_GOLDEN="$REPO/research-sdd/install/tests/golden/plan-pi.txt"

# --list-inputs: print harness input files as repo-relative paths, one per line.
# ci-path-filter-coverage.test.sh calls this to derive its checked set at runtime
# rather than maintaining a hardcoded duplicate list that can drift.
if [ "${1:-}" = "--list-inputs" ]; then
  printf '%s\n' "${SETTINGS#"$REPO/"}"
  printf '%s\n' "${PI_GOLDEN#"$REPO/"}"
  exit 0
fi

for f in "$SETTINGS" "$PI_GOLDEN"; do
  [ -f "$f" ] || { printf 'FATAL: source not found: %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 \
  || { echo 'FATAL: jq required to parse .claude/settings.json' >&2; exit 2; }

# ---- Extraction helpers ----------------------------------------------------
# Each helper emits sorted canonical names (one per line) from its authoritative source.
#
# Claude: .hooks.SessionStart[0].hooks[].command → basename → strip "-hook.sh" suffix
# Manual harnesses (Pi, gentle-shell): `toolbelt/*.sh` backtick entries → strip prefix + ".sh"

extract_claude() {
  local f="${1:-$SETTINGS}"
  jq -r '.hooks.SessionStart[0].hooks[].command' "$f" \
    | sed 's/^"//; s/"$//' \
    | while IFS= read -r cmd; do
        base="$(basename "$cmd")"
        echo "${base%-hook.sh}"   # sweep-retros-hook.sh → sweep-retros
      done | sort
  # sed strips surrounding literal double-quotes that wrap the command for
  # space-safe expansion (e.g. "\"$CLAUDE_PROJECT_DIR/.../foo-hook.sh\"").
  # Unquoted paths pass through unchanged — both forms must parse correctly.
}

extract_manual() {
  local f="${1:-$PI_GOLDEN}"
  grep -oE '`toolbelt/[^`]+\.sh`' "$f" \
    | tr -d '`' \
    | sed 's|^toolbelt/||' \
    | sed 's/\.sh$//' \
    | grep -v '^sweep-all$' \
    | sort
  # NOTE: sweep-all.sh is deliberately excluded from the canonical set extracted here.
  # It is the aggregator shim (U-A20) that CALLS the four canonical scripts; it is not
  # a canonical member of the sweep set itself. A separate assertion (see below) verifies
  # that it IS referenced in the manual-harness goldens as the single recommended command.
}

# count non-blank lines in $1
count_lines() {
  printf '%s\n' "${1:-}" | grep -c '[^[:space:]]' 2>/dev/null || echo 0
}

echo "== harness-sweep-parity.test.sh =="

# Canonical member names — single declaration; CANONICAL_COUNT is derived so cardinality
# assertions and the member-presence loop stay in sync automatically when the set grows.
# Add new sweep scripts here and nowhere else in this test.
CANONICAL_MEMBERS="sweep-retros sweep-audits sweep-breakthroughs verify-registry verify-kit-clean sweep-tools verify-tool-catalog verify-skill-drift"
CANONICAL_COUNT=0
for _m in $CANONICAL_MEMBERS; do CANONICAL_COUNT=$((CANONICAL_COUNT + 1)); done

CLAUDE_SET="$(extract_claude)"
PI_SET="$(extract_manual)"

# ---- 1–2: Non-empty parse sanity -------------------------------------------
[ -n "$CLAUDE_SET" ] \
  && ok "claude: parsed non-empty script set from settings.json" \
  || no "claude: empty parse (jq path or settings.json format changed?)"

[ -n "$PI_SET" ] \
  && ok "pi: parsed non-empty script set from plan-pi.txt" \
  || no "pi: empty parse (backtick format in golden changed?)"

# ---- 3–4: Cardinality (exactly CANONICAL_COUNT per surface) ----------------
claude_c=$(count_lines "$CLAUDE_SET")
pi_c=$(count_lines "$PI_SET")

[ "$claude_c" = "$CANONICAL_COUNT" ] \
  && ok "claude: exactly $CANONICAL_COUNT scripts referenced" \
  || no "claude: expected $CANONICAL_COUNT scripts, got $claude_c (set: $(echo "$CLAUDE_SET" | tr '\n' ' '))"

[ "$pi_c" = "$CANONICAL_COUNT" ] \
  && ok "pi: exactly $CANONICAL_COUNT scripts referenced" \
  || no "pi: expected $CANONICAL_COUNT scripts, got $pi_c (set: $(echo "$PI_SET" | tr '\n' ' '))"

# ---- 5: Cross-surface equality ---------------------------------------------
if [ "$CLAUDE_SET" = "$PI_SET" ]; then
  ok "claude == pi (identical canonical set)"
else
  no "claude != pi  PARITY DRIFT"
  printf '    claude: %s\n' "$(echo "$CLAUDE_SET" | tr '\n' ' ')"
  printf '    pi    : %s\n' "$(echo "$PI_SET"  | tr '\n' ' ')"
fi

# ---- 6–N: Canonical member presence (by exact name) ------------------------
for script in $CANONICAL_MEMBERS; do
  grep -qx "$script" <<<"$CLAUDE_SET" \
    && ok "canonical member present: $script" \
    || no "canonical member MISSING: $script  (claude set: $(echo "$CLAUDE_SET" | tr '\n' ' '))"
done

# ---- Pi golden references the sweep-all.sh aggregator ----------------------
# sweep-all.sh is NOT a canonical sweep member (excluded from extract_manual above); it is
# the U-A20 aggregator shim that runs the canonical scripts in one command. The Pi
# section should reference it as the single recommended manual command.
grep -q '`toolbelt/sweep-all.sh`' "$PI_GOLDEN" \
  && ok "pi: sweep-all.sh aggregator referenced in plan-pi.txt (single recommended command)" \
  || no "pi: sweep-all.sh NOT referenced in plan-pi.txt (expected as single recommended command)"

# ---- Quoted-command form (regression guard for PR #108) --------------------
# extract_claude must tolerate commands wrapped in literal double-quotes, i.e.
#   "command": "\"$CLAUDE_PROJECT_DIR/.../sweep-retros-hook.sh\""
# The inner quotes are intentional (space-safe expansion); the parser must strip
# them before basename so the "-hook.sh" suffix removal fires correctly.
FIXTURE_QUOTED="$HERE/fixtures/settings-quoted.json"
EXPECTED_QUOTED="$(printf 'sweep-audits\nsweep-retros\nverify-kit-clean\nverify-registry')"
if [ -f "$FIXTURE_QUOTED" ]; then
  QUOTED_SET="$(extract_claude "$FIXTURE_QUOTED")"
  [ "$QUOTED_SET" = "$EXPECTED_QUOTED" ] \
    && ok "quoted-commands: extract_claude strips surrounding quotes correctly" \
    || no "quoted-commands: extract_claude did not strip surrounding quotes (got: $(printf '%s' "$QUOTED_SET" | tr '\n' ' '))"
else
  no "quoted-commands: fixture file missing — cannot test quote stripping: $FIXTURE_QUOTED"
fi

# ---- gentle-shell golden: the isolated-home Pi wrapper held to the same canonical set ----------
# Pi has no SessionStart hook, so both Pi harnesses document the manual sweep block. The gentle-shell
# golden must reference the same canonical set + the sweep-all.sh aggregator.
# (Not added to --list-inputs: it lives beside plan-pi.txt under the same golden/ directory.)
_pig_list="gentle-shell"
for _pig in $_pig_list; do
  _pif="$REPO/research-sdd/install/tests/golden/plan-$_pig.txt"
  if [ ! -f "$_pif" ]; then no "$_pig: golden missing: $_pif"; continue; fi
  _pis="$(extract_manual "$_pif")"
  if [ "$_pis" = "$CLAUDE_SET" ]; then ok "$_pig == claude (identical canonical sweep set, $CANONICAL_COUNT scripts)"
  else
    no "$_pig != claude  PARITY DRIFT"
    printf '    claude: %s\n' "$(echo "$CLAUDE_SET" | tr '\n' ' ')"
    printf '    %s : %s\n' "$_pig" "$(echo "$_pis" | tr '\n' ' ')"
  fi
  grep -q '`toolbelt/sweep-all.sh`' "$_pif" \
    && ok "$_pig: sweep-all.sh aggregator referenced in plan-$_pig.txt" \
    || no "$_pig: sweep-all.sh NOT referenced in plan-$_pig.txt"
done


# ---- --list-inputs contract ------------------------------------------------
# The mode must emit exactly the two harness input files as repo-relative paths,
# one per line. ci-path-filter-coverage.test.sh consumes this at runtime so the
# coverage check never drifts from the actual sources this test reads.
LIST_OUT="$(bash "$HERE/harness-sweep-parity.test.sh" --list-inputs)"
list_count=0
while IFS= read -r _line; do
  if [ -n "$_line" ]; then list_count=$((list_count + 1)); fi
done <<< "$LIST_OUT"
[ "$list_count" -eq 2 ] \
  && ok "--list-inputs: emits exactly 2 repo-relative paths" \
  || no "--list-inputs: expected 2 paths, got $list_count (output: $(printf '%s' "$LIST_OUT" | tr '\n' '|' | cut -c1-120))"

list_bad=0
while IFS= read -r _path; do
  case "$_path" in
    /*|*' '*) list_bad=$((list_bad + 1)) ;;
  esac
done <<< "$LIST_OUT"
[ "$list_bad" -eq 0 ] \
  && ok "--list-inputs: all paths are repo-relative single-word strings (no / prefix, no spaces)" \
  || no "--list-inputs: $list_bad path(s) have a leading / or contain spaces — not valid repo-relative paths"

# ---- NEGATIVE CONTROL: prove drift detection has teeth ---------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # Sourced only here: a plain run never depends on the mutation helper.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_chain >/dev/null 2>&1 || { echo "FATAL: lib/mutant.sh did not define mutant_chain" >&2; exit 2; }
  echo "-- teeth: inject drift into each surface; parity checks must catch it --"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  # Teeth A: drop sweep-audits-hook from a temp copy of settings.json
  jq 'del(.hooks.SessionStart[0].hooks[] | select(.command | test("sweep-audits")))' \
      "$SETTINGS" > "$TMP/settings-drop.json"
  # lib/mutant.sh vets every mutant file (JSON/text: MUTANT_SYNTAX=none skips only its `bash -n`).
  mutant_cl=""
  if ! MUTANT_SYNTAX=none mutant_built "teeth A: settings mutant build" "$SETTINGS" "$TMP/settings-drop.json"; then
    no "teeth A: could not build settings mutant (refused by lib/mutant.sh)"
  elif mutant_cl="$(extract_claude "$TMP/settings-drop.json")"; \
       expect_a="$(printf '%s\n' "$PI_SET" | grep -vx 'sweep-audits')"; \
       [ "$mutant_cl" != "$PI_SET" ] && [ "$mutant_cl" = "$expect_a" ]; then
    # Exact BAD verdict (kit issue #1576): the set differs from Pi by exactly the dropped script, not by
    # any other parse accident.
    ok "teeth A: dropping sweep-audits from Claude settings caught as drift vs Pi (set differs by exactly sweep-audits)"
  else
    no "teeth A: dropped hook NOT caught, or the divergence is not exactly sweep-audits — cross-surface comparison is theater (got: $(printf '%s' "$mutant_cl" | tr '\n' ' '))"
  fi

  # Teeth B: rename sweep-retros.sh → sweep-MUTANT.sh in a temp copy of the Pi golden
  mutant_pi=""
  if ! MUTANT_SYNTAX=none mutant_chain "teeth B: Pi golden mutant build" "$PI_GOLDEN" "$TMP/plan-pi-mutant.txt" \
      's|`toolbelt/sweep-retros\.sh`|`toolbelt/sweep-MUTANT.sh`|'; then
    no "teeth B: could not build Pi golden mutant (anchor drifted or refused by lib/mutant.sh)"
  elif mutant_pi="$(extract_manual "$TMP/plan-pi-mutant.txt")"; \
       expect_b="$(printf '%s\n' "$PI_SET" | sed 's/^sweep-retros$/sweep-MUTANT/' | sort)"; \
       [ "$CLAUDE_SET" != "$mutant_pi" ] && [ "$mutant_pi" = "$expect_b" ]; then
    ok "teeth B: renaming sweep-retros in the Pi golden detected as drift vs Claude (set differs by exactly the rename)"
  else
    no "teeth B: mutant Pi NOT caught, or the divergence is not exactly the rename — cross-surface comparison is theater (got: $(printf '%s' "$mutant_pi" | tr '\n' ' '))"
  fi

  # Teeth C: prove the quote-stripping test has teeth. The mutant is a REAL file mutant of this suite
  # (kit issue #1576): lib/mutant.sh builds a copy with extract_claude's quote-strip stage deleted, the
  # mutant's own extract_claude definition is loaded from that file, and run against the quoted fixture.
  # GOOD verdict (original): EXPECTED_QUOTED, asserted by the quoted-commands check above. BAD verdict
  # (mutant): every name keeps the quote glued to a never-stripped "-hook.sh" suffix, exactly
  # EXPECTED_BAD_QUOTED below; any other output (a crash, an empty parse) is not the bite.
  EXPECTED_BAD_QUOTED="$(printf 'sweep-audits-hook.sh"\nsweep-retros-hook.sh"\nverify-kit-clean-hook.sh"\nverify-registry-hook.sh"')"
  if ! MUTANT_SYNTAX=none mutant_chain "teeth C: quote-strip mutant build" "$HERE/harness-sweep-parity.test.sh" \
      "$TMP/hsp-mutant-c.sh" "/sed 's\\/\\^\"\\/\\/; s\\/\"\\\$\\/\\/'/d"; then
    no "teeth C: could not build quote-strip mutant (anchor drifted or refused by lib/mutant.sh)"
  else
    sed -n '/^extract_claude() {/,/^}/p' "$TMP/hsp-mutant-c.sh" > "$TMP/hsp-mutant-c-fn.sh"
    mutant_cl_quoted="$(bash -c '. "$1"; extract_claude "$2"' _ "$TMP/hsp-mutant-c-fn.sh" "$FIXTURE_QUOTED" 2>/dev/null)"
    if [ "$mutant_cl_quoted" = "$EXPECTED_BAD_QUOTED" ]; then
      ok "teeth C: file mutant without quote-stripping yields exactly the wrong quoted names (quote-strip fix has teeth)"
    elif [ "$mutant_cl_quoted" = "$EXPECTED_QUOTED" ]; then
      no "teeth C: un-stripped parser passed — the fixture does not catch the bug (quoted-commands assertion is theater)"
    else
      no "teeth C: quote-strip mutant gave neither the correct nor the exact wrong set (crash or parse accident): $(printf '%s' "$mutant_cl_quoted" | tr '\n' ' ')"
    fi
  fi

  # Teeth D: rename sweep-retros.sh in a temp copy of the gentle-shell golden — the gentle-shell
  # parity check (same extractor, same canonical set) must see it as drift vs Claude.
  mutant_gs=""
  if ! MUTANT_SYNTAX=none mutant_chain "teeth D: gentle-shell golden mutant build" \
      "$REPO/research-sdd/install/tests/golden/plan-gentle-shell.txt" "$TMP/plan-gs-mutant.txt" \
      's|`toolbelt/sweep-retros\.sh`|`toolbelt/sweep-MUTANT.sh`|'; then
    no "teeth D: could not build gentle-shell golden mutant (anchor drifted or refused by lib/mutant.sh)"
  elif mutant_gs="$(extract_manual "$TMP/plan-gs-mutant.txt")"; \
       expect_d="$(printf '%s\n' "$CLAUDE_SET" | sed 's/^sweep-retros$/sweep-MUTANT/' | sort)"; \
       [ -n "$mutant_gs" ] && [ "$CLAUDE_SET" != "$mutant_gs" ] && [ "$mutant_gs" = "$expect_d" ]; then
    ok "teeth D: renaming sweep-retros in the gentle-shell golden detected as drift vs Claude (set differs by exactly the rename)"
  else
    no "teeth D: mutant gentle-shell golden NOT caught, or the divergence is not exactly the rename — gentle-shell parity check is theater (got: $(printf '%s' "$mutant_gs" | tr '\n' ' '))"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
