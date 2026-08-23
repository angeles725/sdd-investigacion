#!/usr/bin/env bash
# wall-protocol-doctrine.test.sh — anti-drift guard for METHODOLOGY §21 (wall protocol).
#
# WHAT THIS GUARDS. §21 introduces typed wall states, a fallback chain, and a
# HARD RULE in PROMPT-LOOP.md. If any of those drift or get accidentally
# removed, this suite goes RED.  It is NOT a logic test — it is a presence +
# coherence guard over two kit documents.
#
# Mutation self-test (--prove-teeth):
#   Works on a COPY of METHODOLOGY.md — never touches the live file.
#   Removes the first occurrence of 'blocked-on-tool' and confirms the
#   corresponding assertion goes RED, proving the check has teeth.
#
# Portability note: grep on this host is ugrep (BSD-3, via shell snapshot).
#   Patterns starting with '-' require '--' to avoid being parsed as options.
#
# Usage:
#   bash wall-protocol-doctrine.test.sh               # run suite
#   bash wall-protocol-doctrine.test.sh --prove-teeth # suite + mutation proof
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$HERE/../.." && pwd)"

METHODOLOGY="$KIT_ROOT/METHODOLOGY.md"
PROMPT_LOOP="$KIT_ROOT/PROMPT-LOOP.md"

# Verify source files exist — absent-input must not read as PASS (§7 anti-silent-zero).
[ -f "$METHODOLOGY" ] || { echo "FATAL: METHODOLOGY.md not found: $METHODOLOGY" >&2; exit 2; }
[ -f "$PROMPT_LOOP" ] || { echo "FATAL: PROMPT-LOOP.md not found: $PROMPT_LOOP" >&2; exit 2; }

pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

# ── §21 heading presence ──────────────────────────────────────────────────────

if grep -qF '## 21. Wall protocol' "$METHODOLOGY"; then
  ok "METHODOLOGY.md has '## 21. Wall protocol' heading"
else
  no "METHODOLOGY.md missing '## 21. Wall protocol' heading"
fi

# ── §20 / §21 ORDER — §21 must appear AFTER §20 ─────────────────────────────
# Compare line numbers: §21 heading must be on a higher line than §20 heading.
line20="$(grep -n '^## 20[.]' "$METHODOLOGY" | head -1 | cut -d: -f1)"
line21="$(grep -n '^## 21[.]' "$METHODOLOGY" | head -1 | cut -d: -f1)"

if [ -z "$line20" ] || [ -z "$line21" ]; then
  no "order check: could not locate both ## 20. and ## 21. headings (absent-input)"
elif [ "$line21" -gt "$line20" ]; then
  ok "§21 appears after §20 (line $line21 > line $line20)"
else
  no "§21 appears BEFORE §20 (line $line21 <= line $line20) — wrong order"
fi

# ── typed wall states ──────────────────────────────────────────────────────────
# 'blocked-on-tool' is checked whole-file (prove-teeth tooth M1 confirms it has teeth).
# 'unavailable' and 'refused' are checked §21-scoped: 'unavailable' appears elsewhere in
# METHODOLOGY.md (model-tier context), so a whole-file grep is theater on a cleared §21.
# Both scoped checks are covered by teeth M3/M4 in the --prove-teeth block below.

if grep -qF 'blocked-on-tool' "$METHODOLOGY"; then
  ok "METHODOLOGY.md mentions typed state 'blocked-on-tool'"
else
  no "METHODOLOGY.md missing typed state 'blocked-on-tool'"
fi

# ── §21 section body checks (extract lines from § heading to next §) ──────────

# Extract §21 body: print from heading until the next ## N. section, exclusive.
# Cannot use awk range /start/,/end/ because the start line also matches /^## [0-9]/
# (the '21' digit), which collapses the range to a single line.
section21="$(awk '
  /^## 21[.] Wall protocol/ { found=1; print; next }
  found && /^## [0-9]/ { exit }
  found { print }
' "$METHODOLOGY")"

if [ -z "$section21" ]; then
  no "§21 section body could not be extracted (heading absent or no following section)"
else
  ok "§21 section body extracted successfully"

  if echo "$section21" | grep -qE '§10|install-tool\.sh'; then
    ok "§21 references §10 / install-tool.sh for provision step"
  else
    no "§21 missing reference to §10 / install-tool.sh"
  fi

  if echo "$section21" | grep -qF 'ghidra'; then
    ok "§21 mentions 'ghidra' in fallback chain"
  else
    no "§21 missing 'ghidra' in fallback chain"
  fi

  if echo "$section21" | grep -q 'r2'; then
    ok "§21 mentions 'r2' in fallback chain"
  else
    no "§21 missing 'r2' in fallback chain"
  fi

  if echo "$section21" | grep -qF 'quick'; then
    ok "§21 mentions 'quick' in fallback chain"
  else
    no "§21 missing 'quick' in fallback chain"
  fi

  if echo "$section21" | grep -qF 'unavailable'; then
    ok "§21 mentions typed state 'unavailable' (scoped to §21 body)"
  else
    no "§21 missing typed state 'unavailable'"
  fi

  if echo "$section21" | grep -qF 'refused'; then
    ok "§21 mentions typed state 'refused' (scoped to §21 body)"
  else
    no "§21 missing typed state 'refused'"
  fi
fi

# ── PROMPT-LOOP.md WALL hard rule ─────────────────────────────────────────────
# Use '--' before the pattern because ugrep (the grep on this host) interprets
# a pattern starting with '-' as an option flag without the -- separator.

if grep -qF -- '- WALL' "$PROMPT_LOOP"; then
  ok "PROMPT-LOOP.md contains the WALL hard rule entry"
else
  no "PROMPT-LOOP.md missing WALL hard rule entry"
fi

if grep -qF 'METHODOLOGY' "$PROMPT_LOOP" && grep -q '§21' "$PROMPT_LOOP"; then
  ok "PROMPT-LOOP.md WALL rule references METHODOLOGY §21"
else
  no "PROMPT-LOOP.md WALL rule missing reference to METHODOLOGY §21"
fi

# ── MUTATION SELF-TEST (--prove-teeth) ───────────────────────────────────────

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "── mutation self-test ──"
  TMPDIR_PT="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_PT"' EXIT

  MUT_FILE="$TMPDIR_PT/METHODOLOGY-mutant.md"

  # Remove ALL lines containing 'blocked-on-tool' from a COPY.
  # §21 introduces two occurrences; removing only the first still leaves one,
  # so the whole-file check stays GREEN — remove all to drive it RED.
  # Never touches the live file.
  grep -v 'blocked-on-tool' "$METHODOLOGY" > "$MUT_FILE"

  # Confirm the token was actually removed from the mutant.
  if grep -qF 'blocked-on-tool' "$MUT_FILE"; then
    no "teeth-M1: mutant still contains 'blocked-on-tool' — grep -v did not remove it"
  else
    # The check in the main suite would go RED on this mutant (token absent).
    if ! grep -qF 'blocked-on-tool' "$MUT_FILE"; then
      ok "teeth-M1: 'blocked-on-tool' absent from mutant — assertion goes RED (teeth proven)"
    else
      no "teeth-M1: mutant check returned green despite missing token (no teeth)"
    fi
  fi

  # teeth-M2: swap §20 and §21 in a copy — order assertion must go RED.
  MUT_ORDER="$TMPDIR_PT/METHODOLOGY-order-mutant.md"
  # Extract the two section blocks and swap their positions.
  # Strategy: replace the §20 heading with a unique sentinel, §21 heading with §20,
  # then sentinel with §21.  Content is unchanged; only heading numbers swap.
  sed \
    -e 's/^## 20\. Document mode/## SWAP_SENTINEL Document mode/' \
    -e 's/^## 21\. Wall protocol/## 20. Wall protocol/' \
    -e 's/^## SWAP_SENTINEL Document mode/## 21. Document mode/' \
    "$METHODOLOGY" > "$MUT_ORDER"

  m_line20="$(grep -n '^## 20[.]' "$MUT_ORDER" | head -1 | cut -d: -f1)"
  m_line21="$(grep -n '^## 21[.]' "$MUT_ORDER" | head -1 | cut -d: -f1)"

  if [ -n "$m_line20" ] && [ -n "$m_line21" ] && [ "$m_line21" -le "$m_line20" ]; then
    ok "teeth-M2: swapped-order mutant has §21 before §20 — order assertion goes RED (teeth proven)"
  else
    no "teeth-M2: swapped-order mutant did not invert the order (line20=$m_line20 line21=$m_line21)"
  fi

  # teeth-M3: remove 'unavailable' from §21 body only; the §21-scoped check must go RED.
  # Whole-file 'unavailable' would survive (line 709 outside §21) — confirming the old
  # whole-file check was theater. The scoped check is the real guard.
  MUT_M3="$TMPDIR_PT/METHODOLOGY-m3.md"
  awk '/^## 21[.] Wall protocol/{in21=1} in21 && /^## [0-9]+[.]/ && !/^## 21[.]/{in21=0} in21 && /unavailable/{next} {print}' \
    "$METHODOLOGY" > "$MUT_M3"
  section21_m3="$(awk '/^## 21[.] Wall protocol/{found=1; print; next} found && /^## [0-9]/{exit} found{print}' "$MUT_M3")"
  if echo "$section21_m3" | grep -qF 'unavailable'; then
    no "teeth-M3: 'unavailable' still present in §21 body after mutation — sed did not take"
  else
    ok "teeth-M3: 'unavailable' absent from §21 body — scoped assertion goes RED (teeth proven)"
  fi

  # teeth-M4: remove 'refused' from §21 body; the §21-scoped check must go RED.
  MUT_M4="$TMPDIR_PT/METHODOLOGY-m4.md"
  awk '/^## 21[.] Wall protocol/{in21=1} in21 && /^## [0-9]+[.]/ && !/^## 21[.]/{in21=0} in21 && /refused/{next} {print}' \
    "$METHODOLOGY" > "$MUT_M4"
  section21_m4="$(awk '/^## 21[.] Wall protocol/{found=1; print; next} found && /^## [0-9]/{exit} found{print}' "$MUT_M4")"
  if echo "$section21_m4" | grep -qF 'refused'; then
    no "teeth-M4: 'refused' still present in §21 body after mutation — sed did not take"
  else
    ok "teeth-M4: 'refused' absent from §21 body — scoped assertion goes RED (teeth proven)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
