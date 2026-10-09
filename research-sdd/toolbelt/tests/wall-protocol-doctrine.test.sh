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
KIT_ROOT="$(cd "$HERE/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)

METHODOLOGY="$KIT_ROOT/METHODOLOGY.md"
PROMPT_LOOP="$KIT_ROOT/PROMPT-LOOP.md"

# Verify source files exist — absent-input must not read as PASS (§7 anti-silent-zero).
[ -f "$METHODOLOGY" ] || { echo "FATAL: METHODOLOGY.md not found: $METHODOLOGY" >&2; exit 2; }
[ -f "$PROMPT_LOOP" ] || { echo "FATAL: PROMPT-LOOP.md not found: $PROMPT_LOOP" >&2; exit 2; }

pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

# ── shared predicates ─────────────────────────────────────────────────────────
# The ONLY place each check's logic lives: the --prove-teeth mutants below call these same functions on a
# mutated COPY, so a mutant is judged by the REAL check, never by a re-implemented grep (kit issue #1299).

# order_state FILE — prints 'absent', 'ok <l21>><l20>' or 'wrong <l21><=<l20>'.
order_state() {
  local l20 l21
  l20="$(grep -n '^## 20[.]' "$1" | head -1 | cut -d: -f1)"
  l21="$(grep -n '^## 21[.]' "$1" | head -1 | cut -d: -f1)"
  if [ -z "$l20" ] || [ -z "$l21" ]; then echo absent
  elif [ "$l21" -gt "$l20" ]; then echo "ok $l21>$l20"
  else echo "wrong $l21<=$l20"; fi
}

# Extract §21 body: print from heading until the next ## N. section, exclusive.
# Cannot use awk range /start/,/end/ because the start line also matches /^## [0-9]/
# (the '21' digit), which collapses the range to a single line.
section21_of() {
  awk '
    /^## 21[.] Wall protocol/ { found=1; print; next }
    found && /^## [0-9]/ { exit }
    found { print }
  ' "$1"
}

# s21_has FILE TOKEN — true when TOKEN occurs inside FILE's §21 body (scoped, never whole-file).
s21_has() { grep -qF -- "$2" <<<"$(section21_of "$1")"; }

# ── §21 heading presence ──────────────────────────────────────────────────────

if grep -qF '## 21. Wall protocol' "$METHODOLOGY"; then
  ok "METHODOLOGY.md has '## 21. Wall protocol' heading"
else
  no "METHODOLOGY.md missing '## 21. Wall protocol' heading"
fi

# ── §20 / §21 ORDER — §21 must appear AFTER §20 ─────────────────────────────
# Compare line numbers: §21 heading must be on a higher line than §20 heading.
order="$(order_state "$METHODOLOGY")"
case "$order" in
  absent) no "order check: could not locate both ## 20. and ## 21. headings (absent-input)" ;;
  ok*)    ok "§21 appears after §20 (lines ${order#ok })" ;;
  *)      no "§21 appears BEFORE §20 (lines ${order#wrong }) — wrong order" ;;
esac

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

section21="$(section21_of "$METHODOLOGY")"

if [ -z "$section21" ]; then
  no "§21 section body could not be extracted (heading absent or no following section)"
else
  ok "§21 section body extracted successfully"

  if grep -qE '§10|install-tool\.sh' <<<"$section21"; then
    ok "§21 references §10 / install-tool.sh for provision step"
  else
    no "§21 missing reference to §10 / install-tool.sh"
  fi

  if grep -qF 'ghidra' <<<"$section21"; then
    ok "§21 mentions 'ghidra' in fallback chain"
  else
    no "§21 missing 'ghidra' in fallback chain"
  fi

  if grep -q 'r2' <<<"$section21"; then
    ok "§21 mentions 'r2' in fallback chain"
  else
    no "§21 missing 'r2' in fallback chain"
  fi

  if grep -qF 'quick' <<<"$section21"; then
    ok "§21 mentions 'quick' in fallback chain"
  else
    no "§21 missing 'quick' in fallback chain"
  fi

  if grep -qF 'unavailable' <<<"$section21"; then
    ok "§21 mentions typed state 'unavailable' (scoped to §21 body)"
  else
    no "§21 missing typed state 'unavailable'"
  fi

  if grep -qF 'refused' <<<"$section21"; then
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

  # --- mutation helpers (kit issues #943, #1299) ----------------------------------------------------
  # Every mutant is a COPY of METHODOLOGY.md under $TMPDIR_PT built by lib/mutant.sh (MUTANT_SYNTAX=none:
  # markdown), which REFUSES an empty, byte-identical or live-tree mutant — a dead sed is a FAIL, not a
  # silent no-op. Each tooth asserts the GOOD verdict on the ORIGINAL and the BAD verdict on the mutant
  # through the SAME predicates the main checks use.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
  # The predicates are shell functions: export them so the bash the shared mutant_tooth spawns sees them.
  export -f order_state section21_of s21_has
  # tt LABEL GOOD_RC BAD_RC MUTANT [mutant_tooth opts] -- ARGV  count the shared mutant_tooth verdict.
  tt() { local line; if line="$(mutant_tooth "$@")"; then pass=$((pass+1)); else fail=$((fail+1)); fi; printf '%s\n' "$line"; }
  # mk LABEL OUT EXPR...  build OUT from $METHODOLOGY (mutant_chain: every stage must apply on its own).
  mk() { local label="$1" out="$2"; shift 2; MUTANT_SYNTAX=none mutant_chain_or_count fail "$label" "$METHODOLOGY" "$out" "$@" || return 1; }

  # teeth-M1: delete EVERY line mentioning 'blocked-on-tool' (§21 has two occurrences; removing only the
  # first leaves the whole-file check GREEN). GOOD: original has the token (rc 0); BAD: mutant lacks it (rc 1).
  MUT_FILE="$TMPDIR_PT/METHODOLOGY-mutant.md"
  if mk "teeth-M1" "$MUT_FILE" '/blocked-on-tool/d'; then
    tt "teeth-M1: 'blocked-on-tool' present in the original, absent from the mutant (whole-file check)" 0 1 "$MUT_FILE" \
      --orig "$METHODOLOGY" -- grep -qF 'blocked-on-tool' @SUT@
  fi

  # teeth-M2: swap the §20 and §21 headings; the REAL order_state must flip ok → wrong. One sed pass,
  # each stage touches a different line, so no sentinel is needed.
  MUT_ORDER="$TMPDIR_PT/METHODOLOGY-order-mutant.md"
  if mk "teeth-M2" "$MUT_ORDER" \
       's/^## 20\. Document mode/## 21. Document mode/' \
       's/^## 21\. Wall protocol/## 20. Wall protocol/'; then
    tt "teeth-M2: order_state 'ok' on the original → 'wrong' on the swapped mutant" 0 0 "$MUT_ORDER" \
      --orig "$METHODOLOGY" --good-has '^ok ' --bad-has '^wrong ' -- bash -c 'order_state "$1"' _ @SUT@
  fi

  # teeth-M3/M4: delete the lines mentioning TOKEN INSIDE §21 only (sed range from the §21 heading to the
  # next numbered heading). GOOD: s21_has holds on the original; BAD: it fails on the mutant while the
  # token may still occur OUTSIDE §21 — which is what makes the scoped check, not a whole-file grep, the
  # real guard.
  for _tok in unavailable refused; do
    _lab="teeth-M$([ "$_tok" = unavailable ] && echo 3 || echo 4)"
    _mf="$TMPDIR_PT/METHODOLOGY-$_tok.md"
    if mk "$_lab" "$_mf" "/^## 21[.] Wall protocol/,/^## [0-9][0-9]*[.] /{/^## 21[.]/!{/$_tok/d}}"; then
      tt "$_lab: '$_tok' in §21 of the original, gone from §21 of the mutant (scoped check)" 0 1 "$_mf" \
        --orig "$METHODOLOGY" -- bash -c 's21_has "$1" "$2"' _ @SUT@ "$_tok"
    fi
  done
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
