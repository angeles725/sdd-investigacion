#!/usr/bin/env bash
# verify-parity.test.sh — RED-FIRST harness for verify-parity.sh's corpus↔deliverable PARITY gate.
#
# WHY THIS SHAPE (anti-"test theater"): the load-bearing behaviour is the SUBSET check — every
# load-bearing value (hex color token) in the shipped DELIVERABLE must EXIST somewhere in the
# certified BLOCK set it claims to derive from. A hex in the deliverable that appears in NO block
# value is DRIFT and must FAIL (exit 1) with the offending hex NAMED. This is exactly the
# pruebas-dashboards miss: realign commits 6a9bc78/c27ec63 shipped a tokens.css whose palette had
# silently diverged from the certified block while verify-block/sources/state all exited 0.
# The discriminating cases feed a KNOWN-DRIFTED deliverable and assert the gate CATCHES it; the
# boundary cases (clean parity, #RGB shorthand equality, multi-block union, empty deliverable) pin
# that the gate stays SILENT so the FAIL is provably gated on real drift, not noise. --prove-teeth
# neuters the drift branch and asserts the drift fixture stops exiting 1 — proving the DRIFT
# assertion is genuinely load-bearing and not theater.
#
# Usage: verify-parity.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-parity.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# run <deliverable> <block> : run the SUT, capture stdout (drop stderr).
run(){ bash "$SUT" "$1" "$2" 2>/dev/null; }
# code <deliverable> <block> : run the SUT and echo only its exit code.
code(){ bash "$SUT" "$1" "$2" >/dev/null 2>&1; echo $?; }

echo "== verify-parity.test.sh (SUT: $(basename "$SUT")) =="

# 1 — bad args: no args at all → exit 2.
if [ "$(bash "$SUT" >/dev/null 2>&1; echo $?)" = 2 ]; then ok "no args → exit 2"; else no "no args: got $(bash "$SUT" >/dev/null 2>&1; echo $?) (want 2)"; fi

# 2 — bad args: deliverable file missing on disk → exit 2.
blk="$TMP/block-a.md"; printf '%s\n' '> legend' 'color: #112233;' > "$blk"
if [ "$(code "$TMP/no-such-deliverable.css" "$blk")" = 2 ]; then ok "missing deliverable file → exit 2"
else no "missing-deliverable: got $(code "$TMP/no-such-deliverable.css" "$blk") (want 2)"; fi

# 3 — bad args: block path missing on disk → exit 2.
del="$TMP/tokens.css"; printf '%s\n' ':root { --c: #112233; }' > "$del"
if [ "$(code "$del" "$TMP/no-such-block-dir")" = 2 ]; then ok "missing block path → exit 2"
else no "missing-block: got $(code "$del" "$TMP/no-such-block-dir") (want 2)"; fi

# 4 — CLEAN PARITY: every deliverable hex present in the block (file mode) → exit 0.
d="$TMP/clean"; mkdir -p "$d"
printf '%s\n' '# Block' 'palette: #112233 #445566 #778899' > "$d/block-1.md"
printf '%s\n' ':root {' '  --bg: #112233;' '  --fg: #445566;' '}' > "$d/tokens.css"
if [ "$(code "$d/tokens.css" "$d/block-1.md")" = 0 ]; then ok "clean parity (all hexes in block) → exit 0"
else no "clean: exit $(code "$d/tokens.css" "$d/block-1.md") (want 0)"; fi

# 5 — DRIFT (the core FAIL): deliverable carries a hex absent from the block → exit 1, hex NAMED.
#     Mirrors the pruebas-dashboards tokens.css that diverged from the certified block palette.
d="$TMP/drift"; mkdir -p "$d"
printf '%s\n' '# Block' 'palette: #112233 #445566' > "$d/block-1.md"
printf '%s\n' ':root {' '  --bg: #112233;' '  --accent: #ff00ab;' '}' > "$d/tokens.css"   # #ff00ab NOT in block
out="$(run "$d/tokens.css" "$d/block-1.md")"
if [ "$(code "$d/tokens.css" "$d/block-1.md")" = 1 ] && printf '%s\n' "$out" | grep -qiF '#ff00ab'; then
  ok "DRIFT: deliverable #ff00ab absent from block → exit 1 + hex named"
else no "drift: exit $(code "$d/tokens.css" "$d/block-1.md") :: $(printf '%s\n' "$out" | grep -iE 'drift|ff00ab' | head -1)"; fi

# 6 — #RGB SHORTHAND equality: block has #ffffff, deliverable writes #FFF → treated as EQUAL → exit 0.
#     Pins the #RGB→#RRGGBB expansion AND case-insensitive normalization.
d="$TMP/shorthand"; mkdir -p "$d"
printf '%s\n' '# Block' 'white token: #ffffff' > "$d/block-1.md"
printf '%s\n' ':root { --paper: #FFF; }' > "$d/tokens.css"
if [ "$(code "$d/tokens.css" "$d/block-1.md")" = 0 ]; then ok "#FFF (deliverable) == #ffffff (block) → exit 0"
else no "shorthand: exit $(code "$d/tokens.css" "$d/block-1.md") (want 0 — #RGB not expanded/normalized)"; fi

# 7 — CASE-INSENSITIVE 6-digit: block #aabbcc, deliverable #AABBCC → equal → exit 0.
d="$TMP/case"; mkdir -p "$d"
printf '%s\n' '# Block' 'tone: #aabbcc' > "$d/block-1.md"
printf '%s\n' ':root { --t: #AABBCC; }' > "$d/tokens.css"
if [ "$(code "$d/tokens.css" "$d/block-1.md")" = 0 ]; then ok "#AABBCC == #aabbcc (case-insensitive) → exit 0"
else no "case: exit $(code "$d/tokens.css" "$d/block-1.md") (want 0)"; fi

# 8 — MULTI-BLOCK DIR (union): deliverable value lives in a SIBLING block file, not the first → exit 0.
#     The block arg is a DIR; the gate must union hexes ACROSS all block files before checking.
d="$TMP/multiblock"; mkdir -p "$d/corpus"
printf '%s\n' '# Block 1' 'base: #112233' > "$d/corpus/block-1.md"
printf '%s\n' '# Block 2' 'accent: #99aabb' > "$d/corpus/block-2.md"
printf '%s\n' ':root {' '  --a: #112233;' '  --b: #99aabb;' '}' > "$d/tokens.css"   # #99aabb only in block-2
if [ "$(code "$d/tokens.css" "$d/corpus")" = 0 ]; then ok "multi-block dir union (value in sibling block) → exit 0"
else no "multiblock: exit $(code "$d/tokens.css" "$d/corpus") (want 0 — dir union not applied)"; fi

# 9 — MULTI-BLOCK DIR still catches drift: a hex in NO block file of the dir → exit 1, hex named.
#     Negative control for case 8: proves the dir mode is a real subset check, not an always-pass.
d="$TMP/multiblock-drift"; mkdir -p "$d/corpus"
printf '%s\n' '# Block 1' 'base: #112233' > "$d/corpus/block-1.md"
printf '%s\n' '# Block 2' 'accent: #99aabb' > "$d/corpus/block-2.md"
printf '%s\n' ':root { --x: #deadbe; }' > "$d/tokens.css"   # in neither block
out="$(run "$d/tokens.css" "$d/corpus")"
if [ "$(code "$d/tokens.css" "$d/corpus")" = 1 ] && printf '%s\n' "$out" | grep -qiF '#deadbe'; then
  ok "multi-block dir catches drift (#deadbe in no block) → exit 1 + named"
else no "multiblock-drift: exit $(code "$d/tokens.css" "$d/corpus") :: $(printf '%s\n' "$out" | grep -iE 'drift|deadbe' | head -1)"; fi

# 10 — EMPTY DELIVERABLE (no extractable hexes) → exit 0 with a note, NO false-fail.
d="$TMP/empty"; mkdir -p "$d"
printf '%s\n' '# Block' 'palette: #112233' > "$d/block-1.md"
printf '%s\n' '/* no color tokens here, just layout */' '.box { margin: 0 auto; }' > "$d/tokens.css"
out="$(run "$d/tokens.css" "$d/block-1.md")"
if [ "$(code "$d/tokens.css" "$d/block-1.md")" = 0 ] && printf '%s\n' "$out" | grep -qiE 'no|nothing|note|zero'; then
  ok "empty deliverable (0 hexes) → exit 0 + note (no false-fail)"
else no "empty: exit $(code "$d/tokens.css" "$d/block-1.md") :: $(printf '%s\n' "$out" | grep -iE 'no|note' | head -1)"; fi

# 11 — MULTIPLE DRIFTS all reported: two absent hexes → exit 1 and BOTH named (not just the first).
d="$TMP/multidrift"; mkdir -p "$d"
printf '%s\n' '# Block' 'palette: #112233' > "$d/block-1.md"
printf '%s\n' ':root {' '  --a: #112233;' '  --b: #aabbcc;' '  --c: #ddeeff;' '}' > "$d/tokens.css"
out="$(run "$d/tokens.css" "$d/block-1.md")"
if [ "$(code "$d/tokens.css" "$d/block-1.md")" = 1 ] \
   && printf '%s\n' "$out" | grep -qiF '#aabbcc' && printf '%s\n' "$out" | grep -qiF '#ddeeff'; then
  ok "two drifts → exit 1 + BOTH named (#aabbcc, #ddeeff)"
else no "multidrift: exit $(code "$d/tokens.css" "$d/block-1.md") :: $(printf '%s\n' "$out" | grep -iE 'drift' | head -1)"; fi

# NEGATIVE CONTROL — prove the DRIFT detection has TEETH via mutation.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the per-hex membership guard; expect the DRIFT fixture to stop exiting 1 --"
  mutant="$TMP/verify-parity.MUTANT.sh"
  # Force the drift branch's guard false so a missing hex can never be flagged.
  sed 's/^\( *\)if ! printf .*grep -qxF.*then$/\1if false; then  # MUTANT: drift check neutered/' "$SUT" > "$mutant"
  if ! grep -q 'MUTANT: drift check neutered' "$mutant"; then
    no "teeth: could not build mutant (drift guard line not found — did the SUT change?)"
  else
    d="$TMP/drift"   # reuse the flagship drift fixture (case 5)
    bash "$mutant" "$d/tokens.css" "$d/block-1.md" >/dev/null 2>&1; mgot=$?
    if [ "$mgot" = 0 ]; then
      ok "teeth: neutered mutant false-passes (exit 0) → DRIFT assertion has teeth"
    else no "teeth: mutant exit $mgot (want 0) — DRIFT case does NOT depend on the guard (THEATER)"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
