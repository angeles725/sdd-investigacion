#!/usr/bin/env bash
# hook-emit.test.sh — red-first harness for lib/hook-emit.sh (rsdd_hook_emit, kit issue #1877).
# Covers: the lib defines rsdd_hook_emit; jq path emits the hookSpecificOutput envelope with
# "HDR\nBODY" (headered) or BODY alone (headerless); the no-jq fallback prints the same text as a
# plain `printf '%s\n%s\n'` / `printf '%s\n'`; sourcing twice is harmless; awkward bodies survive.
# --prove-teeth: sed mutants of a COPY of the lib (lib/mutant.sh) must each lose one of the cases.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/hook-emit.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== hook-emit.test.sh =="

if [ -f "$LIB" ]; then ok "1 lib exists at $LIB"; else
  no "1 lib NOT found at $LIB"; echo "== $pass passed · $fail failed =="; exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
EMPTY_BIN="$TMP/empty-bin"; mkdir -p "$EMPTY_BIN"   # PATH with no jq (builtins only)

# emit LIBFILE MODE ARGS... — run rsdd_hook_emit from LIBFILE in a fresh bash; MODE jq|nojq picks PATH.
emit() {
  local lib="$1" mode="$2"; shift 2
  local p="$PATH"; [ "$mode" = nojq ] && p="$EMPTY_BIN"
  PATH="$p" /bin/bash -c '. "$1"; shift; rsdd_hook_emit "$@"' _ "$lib" "$@"
}

if ! command -v jq >/dev/null 2>&1; then
  no "2 jq missing from the test environment — the jq-path cases cannot run (degraded, not a pass)"
  echo "== $pass passed · $fail failed =="; exit 2
fi

# The expected envelope is built by the test's own jq call, independent of the lib's.
want_json() { jq -cn --arg c "$1" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'; }
got_json()  { emit "$@" | jq -c .; }

# 2. declared function
# shellcheck source=../lib/hook-emit.sh
if ( . "$LIB"; declare -F rsdd_hook_emit >/dev/null ); then ok "2 sourcing defines rsdd_hook_emit"; else no "2 rsdd_hook_emit not defined"; fi

# 3. jq, headered: additionalContext is "HDR\nBODY"
if [ "$(got_json "$LIB" jq "HDR line:" "body one")" = "$(want_json $'HDR line:\nbody one')" ]; then
  ok "3 jq headered → additionalContext 'HDR\\nBODY'"; else no "3 jq headered envelope differs"; fi

# 4. jq, headerless: additionalContext is BODY alone
if [ "$(got_json "$LIB" jq "just the body")" = "$(want_json 'just the body')" ]; then
  ok "4 jq headerless → additionalContext BODY alone"; else no "4 jq headerless envelope differs"; fi

# 5. no jq, headered: plain 'HDR\nBODY\n'
if [ "$(emit "$LIB" nojq "HDR line:" "body one"; echo x)" = $'HDR line:\nbody one\nx' ]; then
  ok "5 no-jq headered → 'HDR\\nBODY\\n' plain print"; else no "5 no-jq headered output differs"; fi

# 6. no jq, headerless: plain 'BODY\n'
if [ "$(emit "$LIB" nojq "just the body"; echo x)" = $'just the body\nx' ]; then
  ok "6 no-jq headerless → 'BODY\\n' plain print"; else no "6 no-jq headerless output differs"; fi

# 7. a multi-line body with quotes, backslashes and a '%s' survives both paths byte-for-byte
BODY=$'line "one"\nback\\slash 100% %s\n\tTabbed'
if [ "$(got_json "$LIB" jq "H" "$BODY")" = "$(want_json "H"$'\n'"$BODY")" ]; then
  ok "7a jq path preserves quotes/backslashes/%s/newlines"; else no "7a jq path mangles an awkward body"; fi
if [ "$(emit "$LIB" nojq "H" "$BODY"; echo x)" = "H"$'\n'"$BODY"$'\nx' ]; then
  ok "7b no-jq path preserves quotes/backslashes/%s/newlines"; else no "7b no-jq path mangles an awkward body"; fi

# 8. exit status is 0 on both paths (a hook must never fail its session)
emit "$LIB" jq "H" "b" >/dev/null; r1=$?; emit "$LIB" nojq "H" "b" >/dev/null; r2=$?
if [ "$r1$r2" = "00" ]; then ok "8 rsdd_hook_emit returns 0 (jq and no-jq)"; else no "8 non-zero return (jq=$r1 nojq=$r2)"; fi

# 9. idempotent: sourcing twice keeps the function and prints nothing
# shellcheck source=../lib/hook-emit.sh
if ( . "$LIB"; . "$LIB"; declare -F rsdd_hook_emit >/dev/null ) 2>"$TMP/dbl.err" && [ ! -s "$TMP/dbl.err" ]; then
  ok "9 double source is silent and keeps the function"; else no "9 double source failed or printed: $(cat "$TMP/dbl.err")"; fi

# 8b. a failing write (closed stdout) must not make the helper fail: the explicit `return 0` is the contract
emit "$LIB" nojq "H" "b" >&- 2>/dev/null; r3=$?
if [ "$r3" = 0 ]; then ok "8b rsdd_hook_emit returns 0 even when the write fails (stdout closed)"; else no "8b write failure leaked as rc=$r3"; fi

# 10. every hook that sources the lib must ANNOUNCE a missing lib (plain text, rc 0), never go silent.
TB="$HERE/.."
for hk in sweep-audits sweep-breakthroughs sweep-retros sweep-tools verify-kit-clean verify-registry verify-skill-drift verify-tool-catalog; do
  d="$TMP/nolib-$hk"; mkdir -p "$d"; cp "$TB/$hk-hook.sh" "$d/$hk-hook.sh"   # no lib/ beside it
  got="$(bash "$d/$hk-hook.sh" 2>/dev/null)"; grc=$?
  if [ "$grc" = 0 ] && [ "$got" = "Research-SDD hook: lib/hook-emit.sh missing beside $d/$hk-hook.sh" ]; then
    ok "10 $hk-hook.sh with no lib/ → announces the missing lib (rc 0)"
  else
    no "10 $hk-hook.sh with no lib/ → rc=$grc out=[$got]"
  fi
done

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  # Each tooth builds a mutant COPY of the lib and requires the NAMED case's assertion to turn false.
  echo "-- teeth: each lib mutation must lose exactly its case --"

  # A: header and body no longer joined by a newline (jq path) → case 3.
  if mk_mut "teeth A: jq join without newline" "$LIB" "$TMP/mutA.sh" 's/\$.\\n.//'; then
    if [ "$(got_json "$TMP/mutA.sh" jq "HDR line:" "body one" 2>/dev/null)" != "$(want_json $'HDR line:\nbody one')" ]; then
      ok "teeth A: header/body joined without newline → case 3 would go RED"; else no "teeth A: mutant still passes case 3"; fi
  fi
  # B: jq path never taken (jq presence probe forced false) → the jq cases print plain text, not JSON.
  if mk_mut "teeth B: jq never used" "$LIB" "$TMP/mutB.sh" 's/command -v jq >\/dev\/null 2>&1/false/'; then
    if [ "$(got_json "$TMP/mutB.sh" jq "HDR line:" "body one" 2>/dev/null)" != "$(want_json $'HDR line:\nbody one')" ]; then
      ok "teeth B: jq probe forced false → case 3 would go RED"; else no "teeth B: mutant still passes case 3"; fi
  fi
  # C: no-jq fallback drops the header → case 5.
  if mk_mut "teeth C: fallback drops header" "$LIB" "$TMP/mutC.sh" 's/printf .%s\\n%s\\n. "\$1" "\$2"/printf "%s\\n" "$2"/'; then
    if [ "$(emit "$TMP/mutC.sh" nojq "HDR line:" "body one"; echo x)" != $'HDR line:\nbody one\nx' ]; then
      ok "teeth C: fallback without header → case 5 would go RED"; else no "teeth C: mutant still passes case 5"; fi
  fi
  # D: headerless fallback loses its trailing newline → case 6.
  if mk_mut "teeth D: headerless fallback no newline" "$LIB" "$TMP/mutD.sh" "s/printf '%s\\\\n' \"\\\$1\"/printf '%s' \"\\\$1\"/"; then
    if [ "$(emit "$TMP/mutD.sh" nojq "just the body"; echo x)" != $'just the body\nx' ]; then
      ok "teeth D: headerless fallback without newline → case 6 would go RED"; else no "teeth D: mutant still passes case 6"; fi
  fi
  # E: the two-argument branch test loosened to one argument → a headerless call joins an empty body → case 4.
  if mk_mut "teeth E: -ge 2 loosened to -ge 1" "$LIB" "$TMP/mutE.sh" 's/"\$#" -ge 2/"$#" -ge 1/g'; then
    if [ "$(got_json "$TMP/mutE.sh" jq "just the body" 2>/dev/null)" != "$(want_json 'just the body')" ]; then
      ok "teeth E: headerless call treated as headered → case 4 would go RED"; else no "teeth E: mutant still passes case 4"; fi
  fi
  # F: the forced `return 0` removed → a failed write leaks its status → case 8b.
  if mk_mut "teeth F: return 0 removed" "$LIB" "$TMP/mutF.sh" '/^    return 0$/d'; then
    emit "$TMP/mutF.sh" nojq "H" "b" >&- 2>/dev/null; mrc=$?
    if [ "$mrc" != 0 ]; then ok "teeth F: write failure leaks a non-zero rc (got $mrc) → case 8b would go RED"; else no "teeth F: mutant still returns 0"; fi
  fi
  # G: the missing-lib guard stripped from a hook copy → no announcement → case 10.
  mkdir -p "$TMP/mutG"
  if mk_mut "teeth G: guard removed" "$TB/verify-kit-clean-hook.sh" "$TMP/mutG/verify-kit-clean-hook.sh" 's/ 2>\/dev\/null || { printf .*exit 0; }//'; then
    gotg="$(bash "$TMP/mutG/verify-kit-clean-hook.sh" 2>/dev/null)"
    if [ "$gotg" != "Research-SDD hook: lib/hook-emit.sh missing beside $TMP/mutG/verify-kit-clean-hook.sh" ]; then
      ok "teeth G: unguarded hook no longer announces a missing lib → case 10 would go RED"; else no "teeth G: mutant still announces"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
