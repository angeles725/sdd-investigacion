#!/usr/bin/env bash
# checkout-freshness.test.sh — suite for lib/checkout-freshness.sh and the stale-first line of
# sweep-retros-hook.sh (kit issue #2215).
# Covers: lib states (ok / stale / within-threshold / three degraded shapes), hook ordering (stale line FIRST in
# additionalContext), silence when fresh, degraded silent unless verbose, opt-out, missing-lib announcement,
# line width, and mutation controls (--prove-teeth).
# Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/checkout-freshness.sh"
HOOK="$HERE/../sweep-retros-hook.sh"
# shellcheck disable=SC2034  # read by lib/mutant.sh (mutant_chain / mutant_tooth default original)
SUT="$LIB"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== checkout-freshness.test.sh =="

MUT=""; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" ${MUT:+"$MUT"}' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
G() { git -C "$1" -c user.name=t -c user.email=t@example.invalid "${@:2}"; }

# mk_pair NAME BEHIND — bare origin + clone; origin gets BEHIND extra commits that the clone has FETCHED but not merged.
mk_pair() {
  local name="$1" behind="$2" i
  git init -q --bare -b main "$TMP/$name.git"
  git clone -q "$TMP/$name.git" "$TMP/$name" 2>/dev/null
  echo base > "$TMP/$name/f"; G "$TMP/$name" add f; G "$TMP/$name" commit -q -m base; G "$TMP/$name" push -q origin HEAD:main
  G "$TMP/$name" branch -q --set-upstream-to=origin/main 2>/dev/null || G "$TMP/$name" fetch -q origin
  git clone -q "$TMP/$name.git" "$TMP/$name-peer" 2>/dev/null
  for i in $(seq 1 "$behind"); do
    echo "c$i" >> "$TMP/$name-peer/f"; G "$TMP/$name-peer" commit -q -am "c$i"
  done
  G "$TMP/$name-peer" push -q origin HEAD:main 2>/dev/null
  G "$TMP/$name" fetch -q origin
  G "$TMP/$name" branch -q --set-upstream-to=origin/main main 2>/dev/null
}

if [ ! -f "$LIB" ]; then
  no "1 lib exists at $LIB"; echo "== $pass passed · $fail failed =="; exit 1
fi
# shellcheck source=../lib/checkout-freshness.sh
. "$LIB"

# ---- lib states -----------------------------------------------------------------------------------------------
mk_pair fresh 0; mk_pair behind3 3
R="$(rsdd_checkout_freshness "$TMP/fresh" 2)"
[[ "$R" == "state=ok behind=0 ref=origin/main age="* ]] && ok "1 up to date -> state=ok behind=0" || no "1 up to date: [$R]"
R="$(rsdd_checkout_freshness "$TMP/behind3" 2)"
[[ "$R" == "state=stale behind=3 ref=origin/main age="* ]] && ok "2 behind 3 > max 2 -> state=stale behind=3" || no "2 stale: [$R]"
R="$(rsdd_checkout_freshness "$TMP/behind3" 20)"
[[ "$R" == "state=ok behind=3 "* ]] && ok "3 behind 3 <= max 20 -> state=ok (threshold, not 'fresh')" || no "3 within threshold: [$R]"
R="$(rsdd_checkout_freshness "$TMP/behind3" abc)"
[[ "$R" == "state=ok behind=3 "* ]] && ok "4 invalid max falls back to 20" || no "4 invalid max: [$R]"
# no origin ref
git init -q "$TMP/noref"; echo x > "$TMP/noref/f"; G "$TMP/noref" add f; G "$TMP/noref" commit -q -m x
R="$(rsdd_checkout_freshness "$TMP/noref" 2)"
[[ "$R" == "state=degraded reason=no upstream ref"* ]] && ok "5 no origin ref -> typed degraded, not fresh" || no "5 no ref: [$R]"
# not a git checkout
mkdir -p "$TMP/plain"
R="$(rsdd_checkout_freshness "$TMP/plain" 2)"
[[ "$R" == "state=degraded reason=not a git checkout"* ]] && ok "6 not a git checkout -> typed degraded" || no "6 not git: [$R]"
R="$(rsdd_checkout_freshness "$TMP/absent-dir" 2)"
[[ "$R" == "state=degraded reason=kit dir absent" ]] && ok "7 absent dir -> typed degraded" || no "7 absent: [$R]"
R="$(RESEARCH_SDD_NO_TIMEOUT_BIN=1 rsdd_checkout_freshness "$TMP/behind3" 2)"
[[ "$R" == "state=degraded reason=no timeout binary"* ]] && ok "8 no timeout binary -> typed degraded" || no "8 no timeout: [$R]"
mkdir -p "$TMP/behind3/sub/deeper"
R="$(rsdd_checkout_freshness "$TMP/behind3/sub/deeper" 2)"
[[ "$R" == "state=degraded reason=kit dir sits inside an unrelated repo" ]] && ok "9 kit dir deep inside another repo -> typed degraded" || no "9 unrelated: [$R]"
NL="$(rsdd_checkout_freshness "$TMP/behind3" 2 | wc -l | tr -d ' ')"
[ "$NL" = 1 ] && ok "10 exactly one record line" || no "10 record lines: $NL"

# ---- hook: stale line first ---------------------------------------------------------------------------------------
[ -f "$HOOK" ] || { no "11 hook missing"; echo "== $pass passed · $fail failed =="; exit 1; }
mk_hook_dir() {   # mk_hook_dir DIR [withlib]
  mkdir -p "$1/lib"
  cp "$HOOK" "$1/sweep-retros-hook.sh"; cp "$HERE/../lib/hook-emit.sh" "$1/lib/"
  [ "${2:-withlib}" = withlib ] && cp "$LIB" "$1/lib/"
  printf '#!/usr/bin/env bash\necho "Summary: 0 pending"\n' > "$1/sweep-retros.sh"; chmod +x "$1/sweep-retros.sh" "$1/sweep-retros-hook.sh"
}
mk_hook_dir "$TMP/h"
ctx() { jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null; }
run_hook() { env -u RESEARCH_SDD_KIT_STALE_CHECK -u RESEARCH_SDD_KIT_STALE_VERBOSE -u RESEARCH_SDD_KIT_STALE_MAX_COMMITS "$@" bash "$TMP/h/sweep-retros-hook.sh" 2>&1 | ctx; }
C="$(run_hook RESEARCH_SDD_KIT_DIR="$TMP/behind3" RESEARCH_SDD_KIT_STALE_MAX_COMMITS=2)"
L1="$(printf '%s\n' "$C" | sed -n 1p)"; L2="$(printf '%s\n' "$C" | sed -n 2p)"
[[ "$L1" == "STALE KIT CHECKOUT: behind origin/main by 3 commits"* ]] && ok "11 stale -> FIRST line of additionalContext is the stale line" || no "11 first line: [$L1]"
[[ "$L2" == "Research-SDD retro sweep (supervisor project):" ]] && ok "12 the normal header follows the stale line" || no "12 second line: [$L2]"
grep -q 'may be artifacts' <<<"$L1" && grep -q 'ff-only origin/main' <<<"$L1" && ok "13 stale line qualifies downstream warnings and names the fix command" || no "13 content: [$L1]"
[ "${#L1}" -le 300 ] && [[ "$L1" == *"ff-only origin/main" ]] && ok "14 stale line <= 300 chars and not cut short (${#L1})" || no "14 width/cut ${#L1}: [$L1]"
C="$(run_hook RESEARCH_SDD_KIT_DIR="$TMP/fresh" RESEARCH_SDD_KIT_STALE_MAX_COMMITS=2)"
[[ "$(printf '%s\n' "$C" | sed -n 1p)" == "Research-SDD retro sweep (supervisor project):" ]] && ! grep -q STALE <<<"$C" && ok "15 fresh -> no stale line, output unchanged" || no "15 fresh: [$C]"
C="$(run_hook RESEARCH_SDD_KIT_DIR="$TMP/behind3" RESEARCH_SDD_KIT_STALE_MAX_COMMITS=20)"
! grep -q STALE <<<"$C" && ok "16 within threshold -> silent" || no "16 threshold: [$C]"
C="$(run_hook RESEARCH_SDD_KIT_DIR="$TMP/noref")"
! grep -q -i 'freshness\|STALE' <<<"$C" && ok "17 degraded (no origin ref) -> silent by default" || no "17 degraded default: [$C]"
C="$(run_hook RESEARCH_SDD_KIT_DIR="$TMP/noref" RESEARCH_SDD_KIT_STALE_VERBOSE=1)"
[[ "$(printf '%s\n' "$C" | sed -n 1p)" == "KIT CHECKOUT FRESHNESS unknown (no upstream ref"* ]] && ok "18 degraded + VERBOSE=1 -> typed unknown line, never 'fresh'" || no "18 degraded verbose: [$C]"
C="$(run_hook RESEARCH_SDD_KIT_DIR="$TMP/plain" RESEARCH_SDD_KIT_STALE_VERBOSE=1)"
grep -q 'not a git checkout' <<<"$C" && ok "19 not a git checkout + VERBOSE=1 -> typed unknown line" || no "19 plain verbose: [$C]"
C="$(run_hook RESEARCH_SDD_KIT_DIR="$TMP/behind3" RESEARCH_SDD_KIT_STALE_MAX_COMMITS=2 RESEARCH_SDD_KIT_STALE_CHECK=off)"
! grep -q STALE <<<"$C" && ok "20 RESEARCH_SDD_KIT_STALE_CHECK=off opts out" || no "20 opt-out: [$C]"
mk_hook_dir "$TMP/h2" nolib
C="$(env RESEARCH_SDD_KIT_DIR="$TMP/behind3" bash "$TMP/h2/sweep-retros-hook.sh" 2>&1 | ctx)"
grep -q 'lib/checkout-freshness.sh missing' <<<"$C" && ok "21 missing lib announces itself (no confident silence)" || no "21 missing lib: [$C]"
cat > "$TMP/h/sweep-retros.sh" <<'EOS'
#!/usr/bin/env bash
echo "boom"; exit 1
EOS
C="$(run_hook RESEARCH_SDD_KIT_DIR="$TMP/behind3" RESEARCH_SDD_KIT_STALE_MAX_COMMITS=2)"
[[ "$(printf '%s\n' "$C" | sed -n 1p)" == "STALE KIT CHECKOUT"* ]] && grep -q 'could not run' <<<"$C" && ok "22 stale line also leads the sweep-failure banner" || no "22 failure path: [$C]"
printf '#!/usr/bin/env bash\necho "Summary: 0 pending"\n' > "$TMP/h/sweep-retros.sh"

# ---- teeth ----------------------------------------------------------------------------------------------------------
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
tooth() { if MUTANT_TOOTH_ICASE=1 mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

if [ "${1:-}" = "--prove-teeth" ]; then
  MUT="$(mktemp -d)"
  echo "-- teeth: lib and hook mutants must go red --"
  # A: threshold comparison inverted -> a stale checkout reads as ok.
  mkdir -p "$MUT/A" "$MUT/B" "$MUT/C" "$MUT/D"
  mutant_chain_or_count fail "teeth A" "$LIB" "$MUT/A/checkout-freshness.sh" 's/\[ "\$n" -gt "\$kmax" \]/[ "$n" -lt "$kmax" ]/' \
    && tooth "teeth A: inverted threshold mutant reads stale as ok -> tests 2/3 catch it" 0 0 "$MUT/A/checkout-freshness.sh" \
         --good-has '^state=stale behind=3' --bad-lacks '^state=stale' --bad-has '^state=ok' -- \
         bash -c '. "$1"; rsdd_checkout_freshness "$2" 2' _ @SUT@ "$TMP/behind3"
  # B: no-upstream degraded record replaced by a confident ok -> test 5 catches it.
  mutant_chain_or_count fail "teeth B" "$LIB" "$MUT/B/checkout-freshness.sh" 's/echo "state=degraded reason=no upstream ref (no @{upstream}, no origin\/main)"/echo "state=ok behind=0 ref=none age=?d"/' \
    && tooth "teeth B: missing ref reported as fresh -> test 5 would catch it (RED)" 0 0 "$MUT/B/checkout-freshness.sh" \
         --good-has '^state=degraded reason=no upstream ref' --bad-lacks 'state=degraded' --bad-has '^state=ok' -- \
         bash -c '. "$1"; rsdd_checkout_freshness "$2" 2' _ @SUT@ "$TMP/noref"
  # C: stale line appended AFTER the header instead of first -> test 11 catches it.
  mkdir -p "$MUT/C/lib"; cp "$HERE/../lib/hook-emit.sh" "$LIB" "$MUT/C/lib/"; cp "$TMP/h/sweep-retros.sh" "$MUT/C/"
  mutant_chain_or_count fail "teeth C" "$HOOK" "$MUT/C/sweep-retros-hook.sh" \
    's/^rsdd_hook_emit .*$/rsdd_hook_emit "Research-SDD retro sweep (supervisor project):" "${stale_line:+$stale_line$'"'"'\\n'"'"'}$out"/' \
    && tooth "teeth C: stale line demoted below the header -> test 11 would catch it (RED)" 0 0 "$MUT/C/sweep-retros-hook.sh" --orig "$TMP/h/sweep-retros-hook.sh" \
         --good-has '^STALE KIT CHECKOUT' --bad-lacks '^STALE KIT CHECKOUT' --bad-has 'retro sweep \(supervisor' -- \
         bash -c 'RESEARCH_SDD_KIT_DIR="$2" RESEARCH_SDD_KIT_STALE_MAX_COMMITS=2 bash "$1" 2>&1 | jq -r .hookSpecificOutput.additionalContext | sed -n 1p; true' _ @SUT@ "$TMP/behind3"
  # D: degraded gating removed -> degraded noise shown by default (test 17 catches it).
  mkdir -p "$MUT/D/lib"; cp "$HERE/../lib/hook-emit.sh" "$LIB" "$MUT/D/lib/"; cp "$TMP/h/sweep-retros.sh" "$MUT/D/"
  mutant_chain_or_count fail "teeth D" "$HOOK" "$MUT/D/sweep-retros-hook.sh" 's/\[ "\${RESEARCH_SDD_KIT_STALE_VERBOSE:-}" != "1" \] ||/false ||/' \
    && tooth "teeth D: degraded no longer gated by VERBOSE -> test 17 would catch it (RED)" 0 0 "$MUT/D/sweep-retros-hook.sh" --orig "$TMP/h/sweep-retros-hook.sh" \
         --good-lacks 'FRESHNESS' --bad-has 'FRESHNESS unknown' -- \
         bash -c 'RESEARCH_SDD_KIT_DIR="$2" bash "$1" 2>&1 | jq -r .hookSpecificOutput.additionalContext' _ @SUT@ "$TMP/noref"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
