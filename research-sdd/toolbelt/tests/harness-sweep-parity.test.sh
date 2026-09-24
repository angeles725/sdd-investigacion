#!/usr/bin/env bash
# harness-sweep-parity.test.sh — locks the canonical sweep-script set across the two active agent
# harnesses (Claude, Codex) so a future edit to one harness that forgets the other is caught
# immediately.
#
# OpenCode support was dropped on 2026-09-23 (#954); its surface (toolbelt/opencode/
# research-sdd-sweep.ts) has been removed.  Codex remains a manual harness whose golden plan
# lists the canonical sweep scripts explicitly.
#
# WHY THIS TEST EXISTS (anti-theater):
#   Parity drifted silently once (README said 2 scripts; .claude/settings.json had grown to 4;
#   Codex golden listed all 4 manually; nothing bound both surfaces to one canonical list).
#   This test does that binding: it parses each authoritative source file directly (no hardcoded
#   list that would rot) and fails if any harness adds, drops, or renames a sweep script relative
#   to the canonical set.
#
# Surfaces parsed (both must agree on the same canonical names):
#   Claude : .claude/settings.json              — SessionStart hook command paths
#   Codex  : install/tests/golden/plan-codex.txt — backtick-quoted toolbelt/ entries
#
# Canonical name normalisation:
#   Claude wires -hook.sh wrapper scripts; strip "-hook" suffix to recover the base name that
#   the Codex harness references directly. Result: sweep-retros, sweep-audits,
#   sweep-breakthroughs, verify-registry, verify-kit-clean, sweep-tools, verify-tool-catalog.
#
# Usage: harness-sweep-parity.test.sh [--prove-teeth]
# Exit : 0 all held · 1 regression · 2 harness error (source file missing / jq absent)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: test-driver SUT-locating derivation, never reached through a render (kit issue #1024 round 4)
REPO="$(cd "$TOOLBELT/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test-driver SUT-locating derivation, never reached through a render (kit issue #1024 round 4)

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# ---- Source file paths -----------------------------------------------------
SETTINGS="$REPO/.claude/settings.json"
CODEX_GOLDEN="$REPO/research-sdd/install/tests/golden/plan-codex.txt"

# --list-inputs: print harness input files as repo-relative paths, one per line.
# ci-path-filter-coverage.test.sh calls this to derive its checked set at runtime
# rather than maintaining a hardcoded duplicate list that can drift.
if [ "${1:-}" = "--list-inputs" ]; then
  printf '%s\n' "${SETTINGS#"$REPO/"}"
  printf '%s\n' "${CODEX_GOLDEN#"$REPO/"}"
  exit 0
fi

for f in "$SETTINGS" "$CODEX_GOLDEN"; do
  [ -f "$f" ] || { printf 'FATAL: source not found: %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 \
  || { echo 'FATAL: jq required to parse .claude/settings.json' >&2; exit 2; }

# ---- Extraction helpers ----------------------------------------------------
# Each helper emits sorted canonical names (one per line) from its authoritative source.
#
# Claude: .hooks.SessionStart[0].hooks[].command → basename → strip "-hook.sh" suffix
# Codex:  `toolbelt/*.sh` backtick entries        → strip prefix + ".sh"

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

extract_codex() {
  local f="${1:-$CODEX_GOLDEN}"
  grep -oE '`toolbelt/[^`]+\.sh`' "$f" \
    | tr -d '`' \
    | sed 's|^toolbelt/||' \
    | sed 's/\.sh$//' \
    | grep -v '^sweep-all$' \
    | sort
  # NOTE: sweep-all.sh is deliberately excluded from the canonical set extracted here.
  # It is the aggregator shim (U-A20) that CALLS the four canonical scripts; it is not
  # a canonical member of the sweep set itself. A separate assertion (see below) verifies
  # that it IS referenced in the codex golden as the single recommended command.
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
CODEX_SET="$(extract_codex)"

# ---- 1–2: Non-empty parse sanity -------------------------------------------
[ -n "$CLAUDE_SET" ] \
  && ok "claude: parsed non-empty script set from settings.json" \
  || no "claude: empty parse (jq path or settings.json format changed?)"

[ -n "$CODEX_SET" ] \
  && ok "codex: parsed non-empty script set from plan-codex.txt" \
  || no "codex: empty parse (backtick format in golden changed?)"

# ---- 3–4: Cardinality (exactly CANONICAL_COUNT per surface) ----------------
claude_c=$(count_lines "$CLAUDE_SET")
codex_c=$(count_lines "$CODEX_SET")

[ "$claude_c" = "$CANONICAL_COUNT" ] \
  && ok "claude: exactly $CANONICAL_COUNT scripts referenced" \
  || no "claude: expected $CANONICAL_COUNT scripts, got $claude_c (set: $(echo "$CLAUDE_SET" | tr '\n' ' '))"

[ "$codex_c" = "$CANONICAL_COUNT" ] \
  && ok "codex: exactly $CANONICAL_COUNT scripts referenced" \
  || no "codex: expected $CANONICAL_COUNT scripts, got $codex_c (set: $(echo "$CODEX_SET" | tr '\n' ' '))"

# ---- 5: Cross-surface equality ---------------------------------------------
if [ "$CLAUDE_SET" = "$CODEX_SET" ]; then
  ok "claude == codex (identical canonical set)"
else
  no "claude != codex  PARITY DRIFT"
  printf '    claude: %s\n' "$(echo "$CLAUDE_SET" | tr '\n' ' ')"
  printf '    codex : %s\n' "$(echo "$CODEX_SET"  | tr '\n' ' ')"
fi

# ---- 6–N: Canonical member presence (by exact name) ------------------------
for script in $CANONICAL_MEMBERS; do
  grep -qx "$script" <<<"$CLAUDE_SET" \
    && ok "canonical member present: $script" \
    || no "canonical member MISSING: $script  (claude set: $(echo "$CLAUDE_SET" | tr '\n' ' '))"
done

# ---- Codex golden references the sweep-all.sh aggregator -------------------
# sweep-all.sh is NOT a canonical sweep member (excluded from extract_codex above); it is
# the U-A20 aggregator shim that runs the four canonical scripts in one command. The codex
# section should reference it as the single recommended manual command.
grep -q '`toolbelt/sweep-all.sh`' "$CODEX_GOLDEN" \
  && ok "codex: sweep-all.sh aggregator referenced in plan-codex.txt (single recommended command)" \
  || no "codex: sweep-all.sh NOT referenced in plan-codex.txt (expected as single recommended command)"

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
  echo "-- teeth: inject drift into each surface; parity checks must catch it --"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  # Teeth A: drop sweep-audits-hook from a temp copy of settings.json
  jq 'del(.hooks.SessionStart[0].hooks[] | select(.command | test("sweep-audits")))' \
      "$SETTINGS" > "$TMP/settings-drop.json"
  mutant_cl="$(extract_claude "$TMP/settings-drop.json")"
  if [ "$mutant_cl" != "$CODEX_SET" ]; then
    ok "teeth A: dropping sweep-audits from Claude settings caught as drift vs Codex"
  else
    no "teeth A: dropped hook NOT caught — cross-surface comparison is theater"
  fi

  # Teeth B: rename sweep-retros.sh → sweep-MUTANT.sh in a temp copy of the codex golden
  sed 's|`toolbelt/sweep-retros\.sh`|`toolbelt/sweep-MUTANT.sh`|' "$CODEX_GOLDEN" > "$TMP/plan-codex-mutant.txt"
  mutant_cx="$(extract_codex "$TMP/plan-codex-mutant.txt")"
  if [ "$CLAUDE_SET" != "$mutant_cx" ]; then
    ok "teeth B: renaming sweep-retros in Codex golden detected as drift vs Claude"
  else
    no "teeth B: mutant Codex NOT caught — cross-surface comparison is theater"
  fi

  # Teeth C: prove the quote-stripping test has teeth.
  # Simulate the pre-fix parser (no sed quote strip) against the quoted fixture;
  # it must produce output DIFFERENT from the correct canonical set.
  # If it produces the correct set, the fixture is not catching the bug and
  # the assertion would pass vacuously even with a broken parser.
  mutant_cl_quoted="$(jq -r '.hooks.SessionStart[0].hooks[].command' "$FIXTURE_QUOTED" \
      | while IFS= read -r cmd; do
          base="$(basename "$cmd")"
          echo "${base%-hook.sh}"   # intentionally no quote stripping — simulates the old bug
        done | sort)"
  if [ "$mutant_cl_quoted" != "$EXPECTED_QUOTED" ]; then
    ok "teeth C: un-stripped parser yields wrong names from quoted fixture (quote-strip fix has teeth)"
  else
    no "teeth C: un-stripped parser passed — the fixture does not catch the bug (quoted-commands assertion is theater)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
