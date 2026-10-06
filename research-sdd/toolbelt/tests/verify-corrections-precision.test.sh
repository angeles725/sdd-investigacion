#!/usr/bin/env bash
# verify-corrections-precision.test.sh — precision classes for verify-corrections.sh (#1868, #1847, #1835 item 4).
#
# Companion to verify-corrections-binding.test.sh. The classes below were MEASURED on real corpora (the #1790 step-2
# archive sweep, 2026-10-06): findings that are not real unreciprocated corrections, or that bind the wrong block.
# The headline fixture `real-1868/` carries the cited real lines VERBATIM (copied read-only from HotelHilton,
# niagara5-research and fluke-177x-datos; the targets themselves are never edited):
#   1. cross-focus qualifier   `corrects `integration` [Block 5]`  -> bound to the wrong focus's block 5
#   2. non-block object        `[Block 50] (… — corrects the caller's B50-G6 mislabel)` -> typed ambiguous (object)
#   3. locator reference       `Corrige la … introducida junto a [Block 16]`            -> typed ambiguous (locator)
#   4. reader assumption       `corrects the assumption behind [Block 1]'s … for anyone …` -> typed ambiguous (assumption)
#   5. joined list             `usado en [Block 9]/[Block 10]`                          -> EVERY ref checked
#   6. backlink vocabulary     `§14 refinement ([Block 26])`                            -> accepted backlink
# plus #1847 (the passive/past-tense guard's word boundary is byte-based: a non-ASCII letter next to a verb is part of
# the word) and #1835 item 4 (bare `B<N>` targets are checked as advisory AMBIG lines, never as a refusal).
#
# Usage: verify-corrections-precision.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-corrections.sh"
FIX="$HERE/fixtures/verify-corrections"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -d "$FIX/real-1868" ] || { echo "FATAL: fixture dir missing: $FIX/real-1868" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
run(){ bash "$SUT" "$1" 2>&1; }
code(){ bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }
# pmk <dir> <prefix> <num> <printf-format> [args] — write <prefix>-block<num>.md (no trailing newline added).
pmk(){ mkdir -p "$1"; printf "$4" "${@:5}" > "$1/$2-block$3.md"; }
# pblank <dir> <prefix> <num>... — unannotated target blocks.
pblank(){ local d="$1" p="$2"; shift 2; local n; mkdir -p "$d"; for n in "$@"; do printf '# Block %s\n\nOriginal claim.\n' "$n" > "$d/$p-block$n.md"; done; }

echo "== verify-corrections-precision.test.sh (SUT: $(basename "$SUT")) =="
REAL="$TMP/real"; cp -r "$FIX/real-1868" "$REAL"
rout="$(run "$REAL")"

# 1 — CROSS-FOCUS QUALIFIER (real HotelHilton pi5-decoding-block8.md:19). `integration` resolves through FOCUSES.md to the
#     `hilton-bms` prefix, whose block 5 carries the backlink: the pair is reciprocated and the colliding
#     pi5-decoding-block5 is never checked.
if ! grep -qE 'B8 corrects \[Block 5\] but pi5-decoding-block5' <<<"$rout" && ! grep -qE 'FAIL +B8 ' <<<"$rout"; then
  ok "real B8 'corrects \`integration\` [Block 5]': checked in the integration focus (hilton-bms), not pi5-decoding-block5"
else no "real cross-focus :: $(grep -E 'B8 ' <<<"$rout" | tr '\n' '|')"; fi
# 1b — the qualifier names an existing PREFIX directly (no FOCUSES.md): zz-block1 is the target, aa-block1 is annotated.
d="$TMP/q-prefix"
pmk "$d" aa 4 '# Block 4\n\n> Corrects `zz` [Block 1] §1.2.\n'
pmk "$d" aa 1 '# Block 1\n\nOriginal.\n\n> corrected in B4.\n'; pmk "$d" zz 1 '# Block 1\n\nNo note.\n'
out="$(run "$d")"
if grep -qE 'FAIL +B4 corrects \[Block 1\] but zz-block1\.md ' <<<"$out"; then ok "qualifier = an existing prefix → that focus's block is the target (a real gap there FAILs)"
else no "q-prefix :: $(tr '\n' '|' <<<"$out")"; fi
# 1c — AFTER-ref form `[Block 1] of the `zz` focus`, with the colliding prefix sorting FIRST and LAST (list edges).
for _own in aa zz; do
  _oth=zz; [ "$_own" = zz ] && _oth=aa
  d="$TMP/q-after-$_own"
  pmk "$d" "$_own" 4 '# Block 4\n\n> Corrects [Block 1] of the `%s` focus.\n' "$_oth"
  pmk "$d" "$_own" 1 '# Block 1\n\nOwn block, never annotated.\n'; pmk "$d" "$_oth" 1 '# Block 1\n\nOther.\n\n> corrected in B4.\n'
  if [ "$(code "$d")" = 0 ]; then ok "after-ref qualifier ($_own → $_oth): the named focus is checked, not the own prefix (exit 0)"
  else no "q-after-$_own :: $(run "$d" | grep FAIL | tr '\n' '|')"; fi
done
# 1d — an UNRESOLVABLE qualifier is a typed ambiguous line, never a guess and never a refusal.
d="$TMP/q-ghost"
pmk "$d" aa 4 '# Block 4\n\n> Corrects `ghost` [Block 1].\n'; pblank "$d" aa 1; pblank "$d" zz 1
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE '^ *AMBIG +B4 corrects \[Block 1\] .*cross-focus' <<<"$out" && ! grep -qE '^ *FAIL' <<<"$out" \
   && grep -qE 'ok-partial +1 declared correction\(s\) NOT checked' <<<"$out"; then
  ok "unresolvable qualifier → 'AMBIG … cross-focus', exit 0, ok-partial (not a FAIL, not an unqualified ok)"
else no "q-ghost :: $(tr '\n' '|' <<<"$out")"; fi
# 1e — the qualifier NAMES the own prefix: behaves like an unqualified ref (own block is checked).
d="$TMP/q-own"
pmk "$d" aa 4 '# Block 4\n\n> Corrects `aa` [Block 1].\n'; pblank "$d" aa 1; pblank "$d" zz 1
if grep -qE 'FAIL +B4 corrects \[Block 1\] but aa-block1\.md ' <<<"$(run "$d")"; then ok "qualifier = own prefix → own block checked"
else no "q-own :: $(run "$d" | tr '\n' '|')"; fi

# 2 — NON-BLOCK OBJECT (real niagara5-block74.md:86): `[Block 50] (… — corrects the caller's B50-G6 mislabel)`.
if grep -qE '^ *AMBIG +B74 corrects \[Block 50\] .*object' <<<"$rout" && ! grep -qE 'FAIL +B74 ' <<<"$rout"; then
  ok "real B74: the verb's object is the caller's B50-G6 label → typed AMBIG (object), no FAIL"
else no "real object :: $(grep -E 'B74' <<<"$rout" | tr '\n' '|')"; fi
# 2b — the real bloque717 evidence-citation list: possessive object, three refs, all ambiguous (none refused).
d="$TMP/obj717"; pblank "$d" t 537 538 545
pmk "$d" t 83 "# Block 83\\n\\n> corrects this focus's bootstrap remittance — kitControl is DONE ([Block 537]/[Block 538]/[Block 545])\\n"
out="$(run "$d")"; o_ok=1
for _n in 537 538 545; do grep -qE "^ *AMBIG +B83 corrects \[Block $_n\] .*object" <<<"$out" || o_ok=0; done
if [ "$o_ok" = 1 ] && ! grep -qE '^ *FAIL' <<<"$out" && [ "$(code "$d")" = 0 ]; then ok "possessive object + '/' list: EVERY ref (first, middle, last) is AMBIG (object); exit 0"
else no "obj717 :: $(tr '\n' '|' <<<"$out")"; fi
# 2c — control: a postfix verb with NO object still binds (the real blender shape is also pinned in the binding suite).
d="$TMP/post-ctl"; pblank "$d" t 3
pmk "$d" t 30 '# Block 30\n\n> Connects [Block 3] (the premise this corrects).\n'
if grep -qE 'FAIL +B30 corrects \[Block 3\] ' <<<"$(run "$d")"; then ok "postfix verb without an object still binds (control)"
else no "post-ctl :: $(run "$d" | tr '\n' '|')"; fi

# 3 — LOCATOR REFERENCE (real fluke-block21.md:52): `introducida junto a [Block 16]`.
if grep -qE '^ *AMBIG +B21 corrects \[Block 16\] .*locator' <<<"$rout" && ! grep -qE 'FAIL +B21 ' <<<"$rout"; then
  ok "real B21: '… introducida junto a [Block 16]' → typed AMBIG (locator), no FAIL"
else no "real locator :: $(grep -E 'B21' <<<"$rout" | tr '\n' '|')"; fi
# 3b — control: a plain object ref (`introduced in [Block 16]`, no co-location word) still declares.
d="$TMP/loc-ctl"; pblank "$d" t 16
pmk "$d" t 21 '# Block 21\n\n- Corrects the calendar claim introduced in [Block 16] (dashboard).\n'
if grep -qE 'FAIL +B21 corrects \[Block 16\] ' <<<"$(run "$d")"; then ok "'introduced in [Block 16]' (no co-location word) still declares the correction"
else no "loc-ctl :: $(run "$d" | tr '\n' '|')"; fi

# 4 — READER ASSUMPTION (real niagara5-block139.md:26).
if grep -qE '^ *AMBIG +B139 corrects \[Block 1\] .*assumption' <<<"$rout" && ! grep -qE 'FAIL +B139 ' <<<"$rout"; then
  ok "real B139: 'corrects the assumption behind [Block 1]'s … for anyone …' → typed AMBIG (assumption), no FAIL"
else no "real assumption :: $(grep -E 'B139' <<<"$rout" | tr '\n' '|')"; fi
# 4b — control: an assumption STATED IN the cited block is a real correction.
d="$TMP/asm-ctl"; pblank "$d" t 1
pmk "$d" t 139 '# Block 139\n\n> This corrects the assumption made in [Block 1] about the module names.\n'
if grep -qE 'FAIL +B139 corrects \[Block 1\] ' <<<"$(run "$d")"; then ok "'the assumption made in [Block 1]' (no reader marker) still declares"
else no "asm-ctl :: $(run "$d" | tr '\n' '|')"; fi

# 5 — JOINED LIST (real fluke-block23.md:53): `usado en [Block 9]/[Block 10]` — BOTH refs are checked.
if grep -qE 'FAIL +B23 corrects \[Block 9\] ' <<<"$rout" && grep -qE 'FAIL +B23 corrects \[Block 10\] ' <<<"$rout"; then
  ok "real B23: '[Block 9]/[Block 10]' → both refs checked (the second was a false negative)"
else no "real joined :: $(grep -E 'B23' <<<"$rout" | tr '\n' '|')"; fi
# 5b — LIST EDGES: 3-element slash list (first/middle/last), spaced slash, and a Spanish list; `+` and comma still do not join.
d="$TMP/slash"; pblank "$d" t 1 2 3 4 5
pmk "$d" t 80 '# Block 80\n\n> Corrects [Block 1]/[Block 2]/[Block 3].\n'
pmk "$d" t 81 '# Block 81\n\n> Corrige [Block 4] / [Block 5].\n'
pmk "$d" t 82 '# Block 82\n\n> Corrects [Block 3] + [Block 2].\n'
out="$(run "$d")"; s_ok=1
for _n in 1 2 3; do grep -qE "B80 corrects \[Block $_n\] " <<<"$out" || s_ok=0; done
for _n in 4 5; do grep -qE "B81 corrects \[Block $_n\] " <<<"$out" || s_ok=0; done
if [ "$s_ok" = 1 ] && grep -qE 'B82 corrects \[Block 3\] ' <<<"$out" && ! grep -qE 'B82 corrects \[Block 2\]' <<<"$out"; then
  ok "slash lists: every position is a target (3-element, spaced '/'); '+' still does not join"
else no "slash :: $(grep -E 'FAIL' <<<"$out" | tr '\n' '|')"; fi

# 6 — BACKLINK VOCABULARY (real niagara5-block20.md:226 `§14 refinement (…, [Block 26])`): decided in METHODOLOGY §14.
if ! grep -qE 'FAIL +B26 ' <<<"$rout"; then ok "real B26→B20: the '§14 refinement … [Block 26]' note is an accepted backlink"
else no "real refinement :: $(grep -E 'B26' <<<"$rout" | tr '\n' '|')"; fi
v_ok=1; v_bad=""
for _s in 'Refined in B4 (scope only).' 'Refinamiento (B4): el alcance cambia.' 'Corrected in B4.'; do
  d="$TMP/vocab"; rm -rf "$d"; pmk "$d" t 4 '# Block 4\n\n> Corrects [Block 1].\n'; pmk "$d" t 1 '# Block 1\n\n%s\n' "$_s"
  [ "$(code "$d")" = 0 ] || { v_ok=0; v_bad="$v_bad [$_s]"; }
done
if [ "$v_ok" = 1 ]; then ok "'refined in' / 'refinamiento' / 'corrected in' naming the correcting block all satisfy the backlink"
else no "vocab :: rejected:$v_bad"; fi
d="$TMP/vocab-neg"; pmk "$d" t 4 '# Block 4\n\n> Corrects [Block 1].\n'; pmk "$d" t 1 '# Block 1\n\nRefinement of the heuristics, nothing else.\n'
if [ "$(code "$d")" = 1 ]; then ok "'refinement' without naming the correcting block is NOT a backlink (still FAILs)"
else no "vocab-neg"; fi

# 7 — BARE B<N> (#1835 item 4): checked as ADVISORY. An unreciprocated bare ref is an AMBIG line (never a FAIL); a
#     reciprocated one is silent. Gap labels (B50-G6) are never a block ref.
d="$TMP/bare"; pblank "$d" t 292; pmk "$d" t 5 '# Block 5\n\nOriginal.\n\n> corrected in B300.\n'
pmk "$d" t 300 '# Block 300\n\n> Corrects B292 §292.6 and B5 §5.1.\n'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE '^ *AMBIG +B300 corrects \[Block 292\] .*bare' <<<"$out" && ! grep -qE 'AMBIG +B300 corrects \[Block 5\]' <<<"$out" \
   && ! grep -qE '^ *FAIL' <<<"$out"; then
  ok "bare 'Corrects B292': unreciprocated → AMBIG (bare), no FAIL; the reciprocated bare ref is silent; exit 0"
else no "bare :: $(tr '\n' '|' <<<"$out")"; fi
d="$TMP/bare-self"; pblank "$d" t 8; pmk "$d" t 67 '# Block 67\n\n> CORRECTS my own B67 §67.7, which walked into a trap [Block 34] had described.\n'
if ! grep -qE 'AMBIG' <<<"$(run "$d")" && [ "$(code "$d")" = 0 ]; then ok "a bare ref to the correcting block itself is not a cross-block declaration"
else no "bare-self :: $(run "$d" | tr '\n' '|')"; fi

# 8 — #1847 NON-ASCII WORD BOUNDARY. A non-ASCII letter next to a verb is PART of the word. Run under a UTF-8 and a C
#     locale (the extractor pins LC_ALL=C internally; the surrounding shell must agree in both). FIRST / MIDDLE / LAST
#     positions (unit start, mid-clause, final unit of a file without trailing newline).
runl(){ LC_ALL="$1" LANG="$1" bash "$SUT" "$2" 2>&1; }
for _loc in C C.utf8; do
  # (a) `ñse corrige` is NOT the passive `se corrige`: it stays an assertive declaration.
  d="$TMP/nb-a"; rm -rf "$d"; pblank "$d" t 8; pmk "$d" t 70 '# Block 70\n\n> El pa\303\261se corrige [Block 8] \302\2672.\n'
  grep -qE 'FAIL +B70 corrects \[Block 8\] ' <<<"$(runl "$_loc" "$d")" && a=1 || a=0
  # (b) `ñcorrige` (preceding non-ASCII letter) is a different word: no verb at all, not even a note.
  d="$TMP/nb-b"; rm -rf "$d"; pblank "$d" t 8; pmk "$d" t 71 '# Block 71\n\n> Nombre\303\261corrige [Block 8].\n'
  out="$(runl "$_loc" "$d")"; { ! grep -qE 'FAIL|note +[0-9]+ correction verb' <<<"$out"; } && b=1 || b=0
  # (c) `corrigeñ` (following non-ASCII letter, LAST position, no trailing newline): not the verb `corrige`.
  d="$TMP/nb-c"; rm -rf "$d"; pblank "$d" t 8; pmk "$d" t 72 '# Block 72\n\n> corrige\303\261 [Block 8].'
  out="$(runl "$_loc" "$d")"; { ! grep -qE 'FAIL' <<<"$out"; } && c=1 || c=0
  # (d) `corrigióñ`: the word continues past the accented vowel → not the past-tense form either.
  d="$TMP/nb-d"; rm -rf "$d"; pblank "$d" t 8; pmk "$d" t 73 '# Block 73\n\n> corrigi\303\263\303\261 [Block 8].\n'
  out="$(runl "$_loc" "$d")"; { ! grep -qE 'non-assertive' <<<"$out"; } && dd=1 || dd=0
  # (e) control: the real past-tense `corrigió` and passive `se corrige` still skip.
  d="$TMP/nb-e"; rm -rf "$d"; pblank "$d" t 8; pmk "$d" t 74 '# Block 74\n\n> Aquel corrigi\303\263 [Block 8]. Si no se corrige [Block 8], falla.\n'
  out="$(runl "$_loc" "$d")"; { ! grep -qE 'FAIL' <<<"$out" && grep -qE 'note +2 correction verb\(s\) in a non-assertive form' <<<"$out"; } && e=1 || e=0
  if [ "$a$b$c$dd$e" = 11111 ]; then ok "non-ASCII boundary [$_loc]: ñse≠se, ñcorrige/corrigeñ/corrigióñ are other words; corrigió/se corrige still skipped"
  else no "non-ascii [$_loc] :: a=$a b=$b c=$c d=$dd e=$e"; fi
done

# 9 — R3-corrigendum-tag-accepts-block-ref (#1847): the optional tag before the preposition must not itself be a block ref.
d="$TMP/cg-tag"; pblank "$d" t 6; pmk "$d" t 90 '# Block 90\n\nCORRIGENDUM `[Block 5]` al [Block 6].\n'
out="$(run "$d")"
if ! grep -qE 'FAIL +B90 corrects \[Block 6\] ' <<<"$out" && grep -qE 'note +1 correction verb' <<<"$out"; then ok "a [Block N] tag before the preposition is not a corrigendum declaration (surfaced as unbound)"
else no "cg-tag :: $(tr '\n' '|' <<<"$out")"; fi

# 10 — R4-skipped-note-anonymous (#1847): the non-assertive note NAMES the blocks that carry the skipped verbs.
d="$TMP/na-name"; pblank "$d" t 8; pmk "$d" t 77 '# Block 77\n\n> Se corrige [Block 8] luego.\n'; pmk "$d" t 78 '# Block 78\n\n> Los autores corrigieron [Block 8].\n'
out="$(run "$d")"
if grep -qE 'non-assertive form .*: B77, B78' <<<"$out"; then ok "the non-assertive note names the blocks (B77, B78)"
else no "na-name :: $(grep note <<<"$out" | tr '\n' '|')"; fi

# 11 — #1857 contract: every FAIL line names the CORRECTING block's file so the archive gate can scope it exactly.
if grep -qE 'FAIL +B23 corrects \[Block 9\] but fluke-block9\.md .*\[correcting: fluke-block23\.md\]' <<<"$rout"; then ok "FAIL lines end with '[correcting: <file>]' (exact focus ownership for the archive gate)"
else no "correcting-file :: $(grep -E 'B23' <<<"$rout" | head -1)"; fi

# NEGATIVE CONTROLS — each mutant disables ONE rule and must flip exactly the case that owns it (a mutant that crashes, or
# that merely differs, is theater: lib/mutant.sh refuses it).
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  for _mf in mutant_chain mutant_tooth; do
    declare -F "$_mf" >/dev/null || { echo "FATAL: lib/mutant.sh did not define $_mf" >&2; exit 2; }
  done
  mk_mut(){ mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  CRASH='integer expression expected|syntax error|unbound variable|command not found|Traceback|awk: '
  mkdir -p "$TMP/lib"; cp "$HERE/../lib/block-files.sh" "$TMP/lib/block-files.sh"

  echo "-- teeth (#1868 item 1): cross-focus qualifier --"
  m="$TMP/vc.NOQUAL.sh"
  if mk_mut "teeth: qualifier ignored" "$SUT" "$m" 's/if (qual != "") emitq(r, qual); else emit(r)/emit(r)/'; then
    tt "teeth: qualifier-blind mutant binds B8 to the colliding pi5-decoding-block5 (the real false FAIL)" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'B8 corrects \[Block 5\] but pi5-decoding' --bad-has 'B8 corrects \[Block 5\] but pi5-decoding-block5' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
    tt "teeth: qualifier-blind mutant checks aa-block1 for 'Corrects \`zz\` [Block 1]' (loses the zz gap)" 1 0 "$m" --orig "$SUT" \
      --good-has 'but zz-block1\.md' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/q-prefix"
  fi
  m="$TMP/vc.NOFOCUSES.sh"
  if mk_mut "teeth: FOCUSES.md lookup" "$SUT" "$m" '/^  \[ -z "${focuspfx\[$s\]:-}" \] || /d'; then
    tt "teeth: FOCUSES-blind mutant cannot resolve 'integration' (AMBIG instead of a verdict)" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'AMBIG +B8 ' --bad-has 'AMBIG +B8 corrects \[Block 5\] .*cross-focus' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
  fi
  m="$TMP/vc.GUESS.sh"
  if mk_mut "teeth: unresolved qualifier" "$SUT" "$m" 's/if \[ -z "$_vc_qp" \]; then/if false; then/'; then
    tt "teeth: guessing mutant drops the typed AMBIG for an unresolvable qualifier" 0 0 "$m" --orig "$SUT" \
      --good-has 'AMBIG +B4 corrects \[Block 1\] .*cross-focus' --bad-lacks 'AMBIG +B4|awk: ' -- bash @SUT@ "$TMP/q-ghost"
  fi

  echo "-- teeth (#1868 items 2-4): the typed ambiguous classes --"
  m="$TMP/vc.NOOBJ.sh"
  if mk_mut "teeth: object class" "$SUT" "$m" '/return "object"$/d'; then
    tt "teeth: no-object mutant FAILs B74→B50 on the caller's mislabel (the real false FAIL)" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'FAIL +B74 ' --bad-has 'FAIL +B74 corrects \[Block 50\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
    tt "teeth: no-object mutant FAILs the bloque717 citation list" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B83 corrects \[Block 537\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/obj717"
  fi
  m="$TMP/vc.NOLOC.sh"
  if mk_mut "teeth: locator class" "$SUT" "$m" '/return "locator"$/d'; then
    tt "teeth: no-locator mutant FAILs B21→B16 on 'introducida junto a [Block 16]'" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'FAIL +B21 ' --bad-has 'FAIL +B21 corrects \[Block 16\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
  fi
  m="$TMP/vc.NOASM.sh"
  if mk_mut "teeth: assumption class" "$SUT" "$m" '/return "assumption"$/d'; then
    tt "teeth: no-assumption mutant FAILs B139→B1 on the reader-assumption" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'FAIL +B139 ' --bad-has 'FAIL +B139 corrects \[Block 1\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
  fi
  m="$TMP/vc.NOOBJPOST.sh"
  if mk_mut "teeth: postfix object" "$SUT" "$m" 's/cls = classify(cl); emit(refnum/cls = ""; emit(refnum/'; then
    tt "teeth: postfix-blind mutant FAILs B74→B50 (verb inside the parenthetical)" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'FAIL +B74 ' --bad-has 'FAIL +B74 corrects \[Block 50\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
  fi

  echo "-- teeth (#1868 items 5-6): joined lists and backlink vocabulary --"
  m="$TMP/vc.NOSLASH.sh"
  if mk_mut "teeth: slash joiner" "$SUT" "$m" 's#(and|y|e|&|.\{2\})#(and|y|e|\&)#'; then
    tt "teeth: no-slash mutant never checks [Block 10] of '[Block 9]/[Block 10]' (the real false negative)" 1 1 "$m" --orig "$SUT" \
      --good-has 'FAIL +B23 corrects \[Block 10\] ' --bad-has 'FAIL +B23 corrects \[Block 9\] ' --bad-lacks 'B23 corrects \[Block 10\]|awk: ' -- bash @SUT@ "$REAL"
    tt "teeth: no-slash mutant loses the LAST ref of '[Block 1]/[Block 2]/[Block 3]'" 1 1 "$m" --orig "$SUT" \
      --good-has 'B80 corrects \[Block 3\] ' --bad-has 'B80 corrects \[Block 1\] ' --bad-lacks 'B80 corrects \[Block 3\] |awk: ' -- bash @SUT@ "$TMP/slash"
  fi
  m="$TMP/vc.NOREFINE.sh"
  if mk_mut "teeth: refinement vocabulary" "$SUT" "$m" "s/^_vc_backlink_re=.*/_vc_backlink_re='corrected|corregid[oa]s?|corrigend(um|a)|errat(um|a)'/"; then
    tt "teeth: no-refinement mutant FAILs the real '§14 refinement ([Block 26])' backlink" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'FAIL +B26 ' --bad-has 'FAIL +B26 corrects \[Block 20\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
  fi

  echo "-- teeth (#1835 item 4): bare B<N> --"
  m="$TMP/vc.NOBARE.sh"
  if mk_mut "teeth: bare class" "$SUT" "$m" 's/{ cls = "bare"; emit(bn); done = 1 }/{ done = 0 }/'; then
    tt "teeth: bare-blind mutant drops the AMBIG line for 'Corrects B292'" 0 0 "$m" --orig "$SUT" \
      --good-has 'AMBIG +B300 corrects \[Block 292\] ' --bad-lacks 'AMBIG +B300|awk: ' -- bash @SUT@ "$TMP/bare"
  fi
  m="$TMP/vc.BAREREFUSE.sh"
  if mk_mut "teeth: bare advisory" "$SUT" "$m" 's/^    elif \[ "$cls" = bare \]; then$/    elif false; then/'; then
    tt "teeth: refusing mutant turns the advisory bare ref into a FAIL (exit 1)" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B300 corrects \[Block 292\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/bare"
  fi
  m="$TMP/vc.PARTIAL.sh"
  if mk_mut "teeth: ambiguous counts as partial" "$SUT" "$m" 's/_vc_partial=$((unchecked+ambiguous))/_vc_partial=$unchecked/'; then
    tt "teeth: ambiguous-blind verdict reads an unqualified ok over an AMBIG line" 0 0 "$m" --orig "$SUT" \
      --good-has 'ok-partial' --good-lacks 'ok +every declared' --bad-has 'ok +every declared' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/q-ghost"
  fi

  echo "-- teeth (#1847): byte-based word boundary --"
  m="$TMP/vc.NOHIGH.sh"
  if mk_mut "teeth: byte boundary (all classes)" "$SUT" "$m" 's/\\200-\\377//g'; then
    tt "teeth: byte-based mutant reads 'pañse corrige' as the passive (loses the FAIL)" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B70 corrects \[Block 8\] ' --bad-lacks 'B70 corrects|awk: ' -- bash @SUT@ "$TMP/nb-a"
  fi
  m="$TMP/vc.NOSE.sh"
  if mk_mut "teeth: se boundary" "$SUT" "$m" 's/pre ~ \/(^|\[^a-z0-9_\\200-\\377\])se/pre ~ \/(^|[^a-z0-9_])se/'; then
    tt "teeth: se-boundary mutant treats 'pañse corrige' as passive" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B70 corrects \[Block 8\] ' --bad-lacks 'B70 corrects|awk: ' -- bash @SUT@ "$TMP/nb-a"
  fi
  m="$TMP/vc.NOLEAD.sh"
  if mk_mut "teeth: leading boundary" "$SUT" "$m" 's/(^|\[^a-z0-9_\\200-\\377\])(corrects/(^|[^a-z0-9_])(corrects/'; then
    tt "teeth: lead-boundary mutant reads 'Nombreñcorrige' as a verb" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B71 corrects \[Block 8\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/nb-b"
  fi
  m="$TMP/vc.NOTRAIL.sh"
  if mk_mut "teeth: trailing boundary" "$SUT" "$m" 's/else if (nb ~ \/\[0-9_\\200-\\377\]\/) {/else if (0) {/'; then
    tt "teeth: trail-boundary mutant reads 'corrigeñ' as the verb (last position, no trailing newline)" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B72 corrects \[Block 8\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/nb-c"
  fi
  m="$TMP/vc.NOPASTEND.sh"
  if mk_mut "teeth: past-tense word end" "$SUT" "$m" 's/if (substr(l, ve + 2, 1) ~ \/\[a-z0-9_\\200-\\377\]\/) {/if (0) {/'; then
    tt "teeth: end-less mutant counts 'corrigióñ' as past tense" 0 0 "$m" --orig "$SUT" \
      --good-lacks 'non-assertive' --bad-has 'non-assertive form' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/nb-d"
  fi

  echo "-- teeth (#1847 suggestions): corrigendum tag, named skipped note, correcting file --"
  m="$TMP/vc.CGTAG.sh"
  if mk_mut "teeth: corrigendum leading tag" "$SUT" "$m" '/the LEADING tag is itself a block ref/d'; then
    tt "teeth: tag-blind mutant declares the tag block (B90→B5) from 'CORRIGENDUM \`[Block 5]\` al [Block 6]'" 0 0 "$m" --orig "$SUT" \
      --good-lacks 'B90 declares a correction of \[Block 5\]' --bad-has 'B90 declares a correction of \[Block 5\]' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/cg-tag"
  fi
  m="$TMP/vc.ANON.sh"
  if mk_mut "teeth: skipped names" "$SUT" "$m" 's/skipnames="${skipnames:+$skipnames, }B$c"; //'; then
    tt "teeth: anonymous mutant omits the block names from the non-assertive note" 0 0 "$m" --orig "$SUT" \
      --good-has ': B77, B78' --bad-lacks ': B77, B78|awk: ' -- bash @SUT@ "$TMP/na-name"
  fi
  m="$TMP/vc.NOCORR.sh"
  if mk_mut "teeth: correcting file" "$SUT" "$m" 's/ \[correcting: $(basename "$f")\]//'; then
    tt "teeth: file-less mutant drops '[correcting: <file>]' from the FAIL line" 1 1 "$m" --orig "$SUT" \
      --good-has '\[correcting: fluke-block23\.md\]' --bad-lacks '\[correcting: |awk: ' -- bash @SUT@ "$REAL"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
