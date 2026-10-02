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
  TT="$(mktemp -d)"
  trap 'rm -rf "$TT"' EXIT
  # Every mutant is a COPY of the doc under $TT built by lib/mutant.sh (MUTANT_SYNTAX=none: markdown),
  # which REFUSES an empty, byte-identical or live-tree mutant — a dead sed is a FAIL, not a silent no-op
  # (kit issues #943, #1299). Each tooth asserts the GOOD verdict (the REAL predicate holds on the
  # original) AND the BAD verdict (it fails on the mutant).
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  typeset -f mutant_sed >/dev/null 2>&1 && typeset -f mutant_verify >/dev/null 2>&1 \
    || { echo "FATAL: lib/mutant.sh did not define mutant_sed/mutant_verify ($HERE/lib/mutant.sh)" >&2; exit 2; }
  export MUTANT_SYNTAX=none
  # TODO(#1299): replace with shared lib/mutant.sh helpers once promoted
  # tooth LABEL PREDICATE SED_EXPR  delete every doc line matching SED_EXPR into a mutant; PREDICATE must
  # hold on the original and must NOT hold on the mutant.
  tooth() {
    local label="$1" pred="$2" expr="$3" out="$TT/$1.md" rc err
    err="$(mutant_sed "$DOC" "$out" -e "$expr" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then no "$label: mutant refused by lib/mutant.sh (rc=$rc) :: $err"; return 1; fi
    if ! "$pred" "$DOC"; then
      no "$label: $pred does NOT hold on the original — the tooth has no GOOD verdict to flip"
    elif "$pred" "$out"; then
      no "$label: $pred still holds on the mutant — no teeth"
    else
      ok "$label: $pred holds on the original and goes RED on the mutant"
    fi
  }

  echo "-- teeth 2: 'Claude profile' removed → assertion 2 must go RED --"
  tooth "teeth 2" _has_claude_profile '/Claude profile/d'
  echo "-- teeth 3: 'Opus 5.5' removed → assertion 3 must go RED --"
  tooth "teeth 3" _has_opus_55 '/Opus 5\.5/d'
  echo "-- teeth 4: 'Sonnet 5' removed → assertion 4 must go RED --"
  tooth "teeth 4" _has_sonnet_5 '/Sonnet 5/d'
  echo "-- teeth 5: 'Haiku 4.5' removed → assertion 5 must go RED --"
  tooth "teeth 5" _has_haiku_45_200k '/Haiku 4\.5/d'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
