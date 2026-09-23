#!/usr/bin/env bash
# model-tiers-doc.test.sh — invariants for research-sdd/toolbelt/model-tiers.v1.md
#
# Covers:
#   1   model-tiers.v1.md exists
#   2   contains a "Claude profile" section
#   3   opus alias maps to Opus 5.5
#   4   sonnet alias maps to Sonnet 5
#   5   haiku alias maps to Haiku 4.5 with 200K context limit
#
# --prove-teeth:
#   teeth 2: mutant with "Claude profile" heading removed → assertion 2 goes RED
#   teeth 3: mutant with "Opus 5.5" removed → assertion 3 goes RED
#   teeth 4: mutant with "Sonnet 5" removed → assertion 4 goes RED
#   teeth 5: mutant with "Haiku 4.5" + "200K" removed → assertion 5 goes RED
#
# Exit: 0 all held · 1 regression

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="$HERE/../model-tiers.v1.md"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== model-tiers-doc.test.sh =="

# --- 1. Document exists -------------------------------------------------------
[ -f "$DOC" ] \
  && ok "1 model-tiers.v1.md exists at $DOC" \
  || { no "1 model-tiers.v1.md NOT found at $DOC"; echo "== $pass passed · $fail failed =="; exit 1; }

DOC_CONTENT="$(cat "$DOC")"
# Empty-capture guard: a fork-fail yields empty content, not a content failure.
[ -n "$DOC_CONTENT" ] || { no "DOC_CONTENT: cat produced no output (capture fork-fail?)"; echo "== $pass passed · $fail failed =="; exit 1; }

# Predicate functions: return 0 (true) or 1 (false); never touch global counters.
_has_claude_profile() { grep -q 'Claude profile' "$1"; }
_has_opus_55()       { grep -qE 'opus.*Opus 5\.5|Opus 5\.5.*opus' "$1"; }
_has_sonnet_5()      { grep -qE 'sonnet.*Sonnet 5|Sonnet 5.*sonnet' "$1"; }
_has_haiku_45_200k() { grep -qE 'haiku.*Haiku 4\.5|Haiku 4\.5.*haiku' "$1" \
                         && grep -q '200K' "$1"; }

# --- 2. Contains "Claude profile" section ------------------------------------
_has_claude_profile "$DOC" \
  && ok "2 contains 'Claude profile' section" \
  || no "2 expected a 'Claude profile' section in model-tiers.v1.md"

# --- 3. opus alias → Opus 5.5 ------------------------------------------------
_has_opus_55 "$DOC" \
  && ok "3 opus alias → Opus 5.5" \
  || no "3 expected 'opus' alias mapped to 'Opus 5.5'"

# --- 4. sonnet alias → Sonnet 5 ----------------------------------------------
_has_sonnet_5 "$DOC" \
  && ok "4 sonnet alias → Sonnet 5" \
  || no "4 expected 'sonnet' alias mapped to 'Sonnet 5'"

# --- 5. haiku alias → Haiku 4.5 with 200K context ---------------------------
_has_haiku_45_200k "$DOC" \
  && ok "5 haiku alias → Haiku 4.5 with 200K context" \
  || no "5 expected 'haiku' alias mapped to 'Haiku 4.5' with '200K' context limit"

# =============================================================================
# Teeth — mutation proof (mutant COPY in temp dir, never the live doc)
# =============================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  m2="$(mktemp)"; m3="$(mktemp)"; m4="$(mktemp)"; m5="$(mktemp)"
  trap 'rm -f "$m2" "$m3" "$m4" "$m5"' EXIT

  # ---- teeth 2: remove "Claude profile" heading → assertion 2 must go RED --
  echo "-- teeth 2: 'Claude profile' removed → assertion 2 must go RED --"
  # Mutant: remove every line that contains "Claude profile"
  sed '/Claude profile/d' "$DOC" > "$m2"
  if _has_claude_profile "$m2"; then
    no "teeth 2: 'Claude profile' still present in mutant — could not build mutant"
  else
    ok "teeth 2: mutant lacks 'Claude profile' → assertion 2 would go RED"
  fi

  # ---- teeth 3: remove "Opus 5.5" → assertion 3 must go RED ----------------
  echo "-- teeth 3: 'Opus 5.5' removed → assertion 3 must go RED --"
  sed '/Opus 5\.5/d' "$DOC" > "$m3"
  if _has_opus_55 "$m3"; then
    no "teeth 3: 'Opus 5.5' still present in mutant — could not build mutant"
  else
    ok "teeth 3: mutant lacks 'Opus 5.5' → assertion 3 would go RED"
  fi

  # ---- teeth 4: remove "Sonnet 5" → assertion 4 must go RED ----------------
  echo "-- teeth 4: 'Sonnet 5' removed → assertion 4 must go RED --"
  # Remove only lines in the Claude-profile section that mention Sonnet 5;
  # existing "sonnet" tier table rows mention Sonnet 5 only in the new section.
  # For safety, remove any line containing "Sonnet 5".
  sed '/Sonnet 5/d' "$DOC" > "$m4"
  if _has_sonnet_5 "$m4"; then
    no "teeth 4: 'Sonnet 5' still present in mutant — could not build mutant"
  else
    ok "teeth 4: mutant lacks 'Sonnet 5' → assertion 4 would go RED"
  fi

  # ---- teeth 5: remove "Haiku 4.5" → assertion 5 must go RED ---------------
  echo "-- teeth 5: 'Haiku 4.5' removed → assertion 5 must go RED --"
  sed '/Haiku 4\.5/d' "$DOC" > "$m5"
  if _has_haiku_45_200k "$m5"; then
    no "teeth 5: 'Haiku 4.5' still present in mutant — could not build mutant"
  else
    ok "teeth 5: mutant lacks 'Haiku 4.5' → assertion 5 would go RED"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
