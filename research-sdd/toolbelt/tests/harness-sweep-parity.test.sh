#!/usr/bin/env bash
# harness-sweep-parity.test.sh — locks the canonical sweep-script set across all three agent
# harnesses (Claude, OpenCode, Codex) so a future edit to one harness that forgets the others
# is caught immediately.
#
# WHY THIS TEST EXISTS (anti-theater):
#   Parity drifted silently once (README said 2 scripts; .claude/settings.json had grown to 4;
#   Codex golden listed all 4 manually; nothing bound all three surfaces to one canonical list).
#   This test does that binding: it parses each authoritative source file directly (no hardcoded
#   list that would rot) and fails if any harness adds, drops, or renames a sweep script relative
#   to the canonical set.
#
# Surfaces parsed (all three must agree on the same 4 canonical names):
#   Claude   : .claude/settings.json                  — SessionStart hook command paths
#   OpenCode : toolbelt/opencode/research-sdd-sweep.ts — path.join(TOOLBELT, "*.sh") constants
#   Codex    : install/tests/golden/plan-codex.txt     — backtick-quoted toolbelt/ entries
#
# Canonical name normalisation:
#   Claude wires -hook.sh wrapper scripts; strip "-hook" suffix to recover the base name that
#   the other two harnesses reference directly. Result: sweep-retros, sweep-audits,
#   verify-registry, verify-kit-clean.
#
# Usage: harness-sweep-parity.test.sh [--prove-teeth]
# Exit : 0 all held · 1 regression · 2 harness error (source file missing / jq absent)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$TOOLBELT/../.." && pwd)"

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# ---- Source file paths -----------------------------------------------------
SETTINGS="$REPO/.claude/settings.json"
SWEEP_TS="$TOOLBELT/opencode/research-sdd-sweep.ts"
CODEX_GOLDEN="$REPO/research-sdd/install/tests/golden/plan-codex.txt"

for f in "$SETTINGS" "$SWEEP_TS" "$CODEX_GOLDEN"; do
  [ -f "$f" ] || { printf 'FATAL: source not found: %s\n' "$f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 \
  || { echo 'FATAL: jq required to parse .claude/settings.json' >&2; exit 2; }

# ---- Extraction helpers ----------------------------------------------------
# Each helper emits sorted canonical names (one per line) from its authoritative source.
#
# Claude:   .hooks.SessionStart[0].hooks[].command → basename → strip "-hook.sh" suffix
# OpenCode: path.join(TOOLBELT, "*.sh") const calls → quoted arg → strip ".sh"
# Codex:    `toolbelt/*.sh` backtick entries        → strip prefix + ".sh"

extract_claude() {
  local f="${1:-$SETTINGS}"
  jq -r '.hooks.SessionStart[0].hooks[].command' "$f" \
    | while IFS= read -r cmd; do
        base="$(basename "$cmd")"
        echo "${base%-hook.sh}"   # sweep-retros-hook.sh → sweep-retros
      done | sort
}

extract_opencode() {
  local f="${1:-$SWEEP_TS}"
  grep -F 'path.join(TOOLBELT' "$f" \
    | grep -oE '"[^"]+\.sh"' \
    | tr -d '"' \
    | sed 's/\.sh$//' \
    | sort
}

extract_codex() {
  local f="${1:-$CODEX_GOLDEN}"
  grep -oE '`toolbelt/[^`]+\.sh`' "$f" \
    | tr -d '`' \
    | sed 's|^toolbelt/||' \
    | sed 's/\.sh$//' \
    | sort
}

# count non-blank lines in $1
count_lines() {
  printf '%s\n' "${1:-}" | grep -c '[^[:space:]]' 2>/dev/null || echo 0
}

echo "== harness-sweep-parity.test.sh =="

CLAUDE_SET="$(extract_claude)"
OPENCODE_SET="$(extract_opencode)"
CODEX_SET="$(extract_codex)"

# ---- 1–3: Non-empty parse sanity -------------------------------------------
[ -n "$CLAUDE_SET" ] \
  && ok "claude: parsed non-empty script set from settings.json" \
  || no "claude: empty parse (jq path or settings.json format changed?)"

[ -n "$OPENCODE_SET" ] \
  && ok "opencode: parsed non-empty script set from research-sdd-sweep.ts" \
  || no "opencode: empty parse (TOOLBELT path.join pattern changed?)"

[ -n "$CODEX_SET" ] \
  && ok "codex: parsed non-empty script set from plan-codex.txt" \
  || no "codex: empty parse (backtick format in golden changed?)"

# ---- 4–6: Cardinality (exactly 4 per surface) ------------------------------
claude_c=$(count_lines "$CLAUDE_SET")
opencode_c=$(count_lines "$OPENCODE_SET")
codex_c=$(count_lines "$CODEX_SET")

[ "$claude_c" = 4 ] \
  && ok "claude: exactly 4 scripts referenced" \
  || no "claude: expected 4 scripts, got $claude_c (set: $(echo "$CLAUDE_SET" | tr '\n' ' '))"

[ "$opencode_c" = 4 ] \
  && ok "opencode: exactly 4 scripts referenced" \
  || no "opencode: expected 4 scripts, got $opencode_c (set: $(echo "$OPENCODE_SET" | tr '\n' ' '))"

[ "$codex_c" = 4 ] \
  && ok "codex: exactly 4 scripts referenced" \
  || no "codex: expected 4 scripts, got $codex_c (set: $(echo "$CODEX_SET" | tr '\n' ' '))"

# ---- 7–9: Cross-surface equality -------------------------------------------
if [ "$CLAUDE_SET" = "$OPENCODE_SET" ]; then
  ok "claude == opencode (identical canonical set)"
else
  no "claude != opencode  PARITY DRIFT"
  printf '    claude  : %s\n' "$(echo "$CLAUDE_SET"   | tr '\n' ' ')"
  printf '    opencode: %s\n' "$(echo "$OPENCODE_SET" | tr '\n' ' ')"
fi

if [ "$CLAUDE_SET" = "$CODEX_SET" ]; then
  ok "claude == codex (identical canonical set)"
else
  no "claude != codex  PARITY DRIFT"
  printf '    claude: %s\n' "$(echo "$CLAUDE_SET" | tr '\n' ' ')"
  printf '    codex : %s\n' "$(echo "$CODEX_SET"  | tr '\n' ' ')"
fi

if [ "$OPENCODE_SET" = "$CODEX_SET" ]; then
  ok "opencode == codex (identical canonical set)"
else
  no "opencode != codex  PARITY DRIFT"
  printf '    opencode: %s\n' "$(echo "$OPENCODE_SET" | tr '\n' ' ')"
  printf '    codex   : %s\n' "$(echo "$CODEX_SET"    | tr '\n' ' ')"
fi

# ---- 10–13: Canonical member presence (by exact name) ----------------------
for script in sweep-retros sweep-audits verify-registry verify-kit-clean; do
  grep -qx "$script" <<<"$CLAUDE_SET" \
    && ok "canonical member present: $script" \
    || no "canonical member MISSING: $script  (claude set: $(echo "$CLAUDE_SET" | tr '\n' ' '))"
done

# ---- NEGATIVE CONTROL: prove drift detection has teeth ---------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: inject drift into each surface; parity checks must catch it --"
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  # Teeth A: rename sweep-retros.sh → sweep-MUTANT.sh in a temp copy of research-sdd-sweep.ts
  sed 's/"sweep-retros\.sh"/"sweep-MUTANT.sh"/' "$SWEEP_TS" > "$TMP/sweep-mutant.ts"
  mutant_oc="$(extract_opencode "$TMP/sweep-mutant.ts")"
  if [ "$CLAUDE_SET" != "$mutant_oc" ]; then
    ok "teeth A: renaming sweep-retros in OpenCode detected as drift vs Claude"
  else
    no "teeth A: mutant OpenCode NOT caught — cross-surface comparison is theater"
  fi

  # Teeth B: drop sweep-audits-hook from a temp copy of settings.json
  jq 'del(.hooks.SessionStart[0].hooks[] | select(.command | test("sweep-audits")))' \
      "$SETTINGS" > "$TMP/settings-drop.json"
  mutant_cl="$(extract_claude "$TMP/settings-drop.json")"
  if [ "$mutant_cl" != "$CODEX_SET" ]; then
    ok "teeth B: dropping sweep-audits from Claude settings caught as drift vs Codex"
  else
    no "teeth B: dropped hook NOT caught — cross-surface comparison is theater"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
