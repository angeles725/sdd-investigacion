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
pmk "$d" aa 4 '# Block 4\n\n> Corrects [Block 1] of the `ghost` focus.\n'; pblank "$d" aa 1; pblank "$d" zz 1   # explicit `focus` word (a bare leading `ghost` is a code identifier since #1874)
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

# ---- Opus PR gate round (#1868): qualifier vs self-skip, soft slugs, list inheritance, narrow object, bare lists, refine shapes ----

# 12 — SELF-SKIP ON THE RESOLVED FILE: `Corrects `zz` [Block 3]` inside aa-block3 targets zz-block3, not itself.
d="$TMP/self-q"; pmk "$d" aa 3 '# Block 3\n\n> Corrects `zz` [Block 3] §3.1.\n'; pblank "$d" zz 3
out="$(run "$d")"
if grep -qE 'FAIL +B3 corrects \[Block 3\] but zz-block3\.md ' <<<"$out"; then ok "qualified ref to the SAME number in another focus is checked (not skipped as self-correction)"
else no "self-q :: $(tr '\n' '|' <<<"$out")"; fi
# 12b — the same through FOCUSES.md (the real HotelHilton shape: pi5-decoding-block5 → `integration` [Block 5]).
d="$TMP/self-focuses"; pmk "$d" pi5 5 '# Block 5\n\n> Corrects `integration` [Block 5].\n'; pblank "$d" hb 5
printf '| Focus | S | State | Block prefix | Q |\n|---|---|---|---|---|\n| `integration` | x | y | `hb-block5.md` | q |\n' > "$d/FOCUSES.md"
if grep -qE 'FAIL +B5 corrects \[Block 5\] but hb-block5\.md ' <<<"$(run "$d")"; then ok "FOCUSES.md row with a real <prefix>-block<N>.md file name resolves the slug; same-number cross-focus ref is checked"
else no "self-focuses :: $(run "$d" | tr '\n' '|')"; fi
# 12c — CONTROLS: a genuine self-correction (unqualified) stays skipped, even when another prefix owns the same number.
d="$TMP/self-ctl"; pmk "$d" aa 3 '# Block 3\n\n> Corrects [Block 3] §3.1 (my own earlier paragraph).\n'; pblank "$d" zz 3
if [ "$(code "$d")" = 0 ] && ! grep -qE 'FAIL|AMBIG' <<<"$(run "$d")"; then ok "unqualified same-number ref is still a self-correction (skipped) even with a colliding prefix"
else no "self-ctl :: $(run "$d" | tr '\n' '|')"; fi
# 12d — tabs inside the FOCUSES.md slug cell are stripped.
d="$TMP/self-tab"; pmk "$d" pi5 8 '# Block 8\n\n> Corrects `integration` [Block 5].\n'; pblank "$d" hb 5 ; pblank "$d" pi5 5   # pi5-block5 collides: an unresolved slug would check IT
printf '| Focus | S | State | Block prefix | Q |\n|---|---|---|---|---|\n|\t`integration`\t| x | y | `hb-blockN.md` | q |\n' > "$d/FOCUSES.md"
if grep -qE 'FAIL +B8 corrects \[Block 5\] but hb-block5\.md ' <<<"$(run "$d")"; then ok "a tab-padded slug cell in FOCUSES.md still resolves"
else no "self-tab :: $(run "$d" | tr '\n' '|')"; fi

# 13 — SOFT SLUGS: a backticked token after in/of/en/de with no `focus` word that names no focus is just a file name.
sl_ok=1; sl_bad=""
for _s in 'Corrects [Block 8] in `parser.c`.' 'Corrige [Block 8] en `parser.c`.' 'Corrects [Block 8] of `verify.sh` §2.' 'Corrige [Block 8] del `loader`.'; do
  d="$TMP/soft"; rm -rf "$d"; pblank "$d" t 8; pmk "$d" t 90 '# Block 90\n\n> %s\n' "$_s"
  out="$(run "$d")"
  { grep -qE 'FAIL +B90 corrects \[Block 8\] ' <<<"$out" && ! grep -qE 'AMBIG' <<<"$out"; } || { sl_ok=0; sl_bad="$sl_bad [$_s]"; }
done
if [ "$sl_ok" = 1 ]; then ok "'] in/en/of/del \`file\`' (EN + ES) falls back to the strict own-prefix lookup (FAIL, never AMBIG)"
else no "soft-slug :: $sl_bad"; fi
# 13b — a soft token that DOES name a focus qualifies; a HARD one (`focus` word) that names none is AMBIG.
d="$TMP/soft-res"; pmk "$d" aa 4 '# Block 4\n\n> Corrects [Block 1] in `zz`.\n'; pmk "$d" aa 1 '# Block 1\n\nOwn, annotated.\n\n> corrected in B4.\n'; pmk "$d" zz 1 '# Block 1\n\nOther, never annotated.\n'
if grep -qE 'FAIL +B4 corrects \[Block 1\] but zz-block1\.md ' <<<"$(run "$d")"; then ok "soft token that names a prefix still qualifies (zz-block1 is the target)"
else no "soft-res :: $(run "$d" | tr '\n' '|')"; fi
d="$TMP/hard-ghost"; pmk "$d" aa 4 '# Block 4\n\n> Corrects [Block 1] of the `ghost` focus.\n'; pblank "$d" aa 1; pblank "$d" zz 1
if grep -qE '^ *AMBIG +B4 corrects \[Block 1\] .*cross-focus' <<<"$(run "$d")"; then ok "'of the \`ghost\` focus' (explicit focus word) that resolves to nothing stays a typed AMBIG"
else no "hard-ghost :: $(run "$d" | tr '\n' '|')"; fi

# 14 — LIST INHERITS THE QUALIFIER: every later ref of a joined list resolves in the qualifier's focus.
d="$TMP/qlist"; pmk "$d" aa 4 '# Block 4\n\n> Corrects `zz` [Block 1] and [Block 2] and [Block 3].\n'
pmk "$d" aa 1 '# Block 1\n\n> corrected in B4.\n'; pmk "$d" aa 2 '# Block 2\n\n> corrected in B4.\n'; pmk "$d" aa 3 '# Block 3\n\n> corrected in B4.\n'
pblank "$d" zz 1 2 3
out="$(run "$d")"; q_ok=1
for _n in 1 2 3; do grep -qE "FAIL +B4 corrects \[Block $_n\] but zz-block$_n\.md " <<<"$out" || q_ok=0; done
if [ "$q_ok" = 1 ]; then ok "'\`zz\` [Block 1] and [Block 2] and [Block 3]': first, middle and last all resolve in zz"
else no "qlist :: $(grep -E 'FAIL|WARN|AMBIG' <<<"$out" | tr '\n' '|')"; fi

# 15 — NARROW OBJECT: a possessive of a CODE artifact is a claim of the cited block, not a non-block object.
d="$TMP/poss"; pblank "$d" t 8; pmk "$d" t 91 "# Block 91\\n\\n> Corrects the decompiler's reading in [Block 8].\\n"
out="$(run "$d")"
if grep -qE 'FAIL +B91 corrects \[Block 8\] ' <<<"$out" && ! grep -qE 'AMBIG' <<<"$out"; then ok "\"the decompiler's reading in [Block 8]\" is a plain declaration (FAIL), not AMBIG object"
else no "poss :: $(tr '\n' '|' <<<"$out")"; fi

# 16 — EVERY LEADING BARE REF is checked (first, middle, last), joined by and / y / e / & / '/'.
d="$TMP/bare-list"; pblank "$d" t 6 12 15 20
pmk "$d" t 100 '# Block 100\n\n> Corrects B6/B12 and B15.\n'; pmk "$d" t 101 '# Block 101\n\n> Corrige B20 y B6.\n'
out="$(run "$d")"; b_ok=1
for _n in 6 12 15; do grep -qE "AMBIG +B100 corrects \[Block $_n\] .*bare" <<<"$out" || b_ok=0; done
for _n in 20 6; do grep -qE "AMBIG +B101 corrects \[Block $_n\] .*bare" <<<"$out" || b_ok=0; done
if [ "$b_ok" = 1 ] && [ "$(code "$d")" = 0 ]; then ok "bare lists 'B6/B12 and B15' / 'B20 y B6': every ref is checked (AMBIG bare each), exit 0"
else no "bare-list :: $(grep -E 'AMBIG|FAIL' <<<"$out" | cut -c1-70 | tr '\n' '|')"; fi
d="$TMP/bare-stop"; pblank "$d" t 6 7; pmk "$d" t 102 '# Block 102\n\n> Corrects B6 (see also B7) here.\n'
if ! grep -qE 'AMBIG +B102 corrects \[Block 7\]' <<<"$(run "$d")"; then ok "prose between bare refs ('(see also B7)') ends the list (B7 is not a target)"
else no "bare-stop"; fi

# 17 — REFINE words count only in a backlink SHAPE.
d="$TMP/refine-neg"; pmk "$d" t 4 '# Block 4\n\n> Corrects [Block 1].\n'; pmk "$d" t 1 '# Block 1\n\nRefinement planned, see B4.\n'
if [ "$(code "$d")" = 1 ]; then ok "'Refinement planned, see B4' is not a backlink (still FAILs)"
else no "refine-neg"; fi
d="$TMP/refine-pos"; pmk "$d" t 4 '# Block 4\n\n> Corrects [Block 1].\n'; pmk "$d" t 1 '# Block 1\n\n> **§14 refinement (2026-09-27, [Block 4]):** narrower.\n'
if [ "$(code "$d")" = 0 ]; then ok "'§14 refinement ([Block 4])' is a backlink shape"
else no "refine-pos"; fi

# ---- Opus round 2 (#1868): trailing list qualifier, no silent n==c drop for the AMBIG classes ----

# 18 — A qualifier AFTER THE LAST ref of a joined list applies to the whole list (both prefix orders; 2- and 3-element lists),
#      and one right after the FIRST ref of a longer list still applies to all of it.
for _own in aa zz; do
  _oth=zz; [ "$_own" = zz ] && _oth=aa
  d="$TMP/tq-$_own"
  pmk "$d" "$_own" 4 '# Block 4\n\n> Corrects [Block 1] and [Block 2] of the `%s` focus.\n' "$_oth"
  pmk "$d" "$_own" 1 '# Block 1\n\n> corrected in B4.\n'; pmk "$d" "$_own" 2 '# Block 2\n\n> corrected in B4.\n'; pblank "$d" "$_oth" 1 2
  out="$(run "$d")"
  if grep -qE "FAIL +B4 corrects \[Block 1\] but $_oth-block1\.md " <<<"$out" && grep -qE "FAIL +B4 corrects \[Block 2\] but $_oth-block2\.md " <<<"$out"; then
    ok "trailing qualifier after the last ref of a 2-list ($_own → $_oth): both refs resolve in $_oth"
  else no "tq-$_own :: $(grep -E 'FAIL|WARN|AMBIG|ok' <<<"$out" | cut -c1-90 | tr '\n' '|')"; fi
done
d="$TMP/tq-3"; pmk "$d" aa 4 '# Block 4\n\n> Corrects [Block 1]/[Block 2]/[Block 3] of the `zz` focus.\n'
for _n in 1 2 3; do pmk "$d" aa $_n '# Block %s\n\n> corrected in B4.\n' "$_n"; done; pblank "$d" zz 1 2 3
out="$(run "$d")"; t3=1
for _n in 1 2 3; do grep -qE "FAIL +B4 corrects \[Block $_n\] but zz-block$_n\.md " <<<"$out" || t3=0; done
if [ "$t3" = 1 ]; then ok "trailing qualifier after a 3-element slash list: first, middle and last all resolve in zz"
else no "tq-3 :: $(grep -E 'FAIL|WARN|AMBIG' <<<"$out" | cut -c1-90 | tr '\n' '|')"; fi
d="$TMP/tq-mid"; pmk "$d" aa 4 '# Block 4\n\n> Corrects [Block 1] of the `zz` focus and [Block 2].\n'
pmk "$d" aa 1 '# Block 1\n\n> corrected in B4.\n'; pmk "$d" aa 2 '# Block 2\n\n> corrected in B4.\n'; pblank "$d" zz 1 2
out="$(run "$d")"
if grep -qE 'FAIL +B4 corrects \[Block 1\] but zz-block1\.md ' <<<"$out" && ! grep -qE 'B4 corrects \[Block 2\]' <<<"$out"; then ok "qualifier after the FIRST ref: it binds that ref in zz; the prose after it ends the list (no [Block 2] target)"
else no "tq-mid :: $(grep -E 'FAIL|WARN|AMBIG' <<<"$out" | cut -c1-90 | tr '\n' '|')"; fi

# 19 — the AMBIG classes never vanish when the declared number is the correcting block's own: AMBIG line, counted in ok-partial.
sn_ok=1; sn_bad=""
i=0
for _s in "Corrects this focus's remittance in [Block 5] of the \`zz\` focus." "Corrige la implementación junto a [Block 5]." "This corrects the assumption behind [Block 5]'s packaging."; do
  i=$((i+1)); d="$TMP/selfamb$i"; rm -rf "$d"; pblank "$d" zz 5; pmk "$d" aa 5 '# Block 5\n\n> %s\n' "$_s"
  out="$(run "$d")"
  { [ "$(code "$d")" = 0 ] && grep -qE '^ *AMBIG +B5 corrects \[Block 5\] ' <<<"$out" && grep -qE 'ok-partial +1 declared correction' <<<"$out"; } || { sn_ok=0; sn_bad="$sn_bad [$i]"; }
done
if [ "$sn_ok" = 1 ]; then ok "object / locator / assumption with the correcting block's own number → AMBIG line + ok-partial (never a silent drop)"
else no "self-amb :: $sn_bad"; fi

# ---- T12 (#1847 review items, #1835 follow-ups from the PR #1848 reviews): corrigendum `of`, tag bound, backlink word boundary ----

# 20 — POSSESSIVE `of` (Opus PASS review of #1848): `See the corrigendum of [Block 33].` in a CORRECTED file is a possessive reference
#      to block 33's corrigendum, not a declaration. A bare `of` is a typed AMBIG (possessive) counted toward ok-partial, never an unqualified
#      ok; `of` with a tag before OR after it (`[CERT] of [Block N]`, `of [CERT] [Block N]`) and the directional `al`/`a`/`to`/`for` still declare.
d="$TMP/cg-of"; pmk "$d" t 8 '# Block 8\n\nSee the corrigendum of [Block 33].\n'; pmk "$d" t 33 '# Block 33\n\nCorrects [Block 8].\n'
out="$(run "$d")"
if ! grep -qE 'FAIL +B8 corrects' <<<"$out" && grep -qE 'AMBIG +B8 corrects \[Block 33\] — possessive' <<<"$out" && grep -qE 'ok-partial +1 declared' <<<"$out" && ! grep -qE 'ok +every declared' <<<"$out"; then ok "bare 'corrigendum of [Block 33]' is a possessive reference: typed AMBIG + ok-partial (never an unqualified ok), no false FAIL"
else no "cg-of :: $(tr '\n' '|' <<<"$out")"; fi
d="$TMP/cg-oftag"; pblank "$d" t 32; pmk "$d" t 107 '# Block 107\n\nCORRIGENDUM `[CERT]` of [Block 32].\n'   # stable fixture for the teeth below
cof_ok=1
for _s in 'CORRIGENDUM `[CERT]` of [Block 32].' 'CORRIGENDUM of [CERT] [Block 32].' 'CORRIGENDUM al [Block 32].' 'Corrigenda for [Block 32].'; do
  d="$TMP/cg-of2"; rm -rf "$d"; pblank "$d" t 32; pmk "$d" t 107 '# Block 107\n\n%s\n' "$_s"
  grep -qE 'FAIL +B107 corrects \[Block 32\] ' <<<"$(run "$d")" || cof_ok=0
done
if [ "$cof_ok" = 1 ]; then ok "'of' with a tag before or after it, and the directional al / for still declare the correction"
else no "cg-of2: a tagged/directional corrigendum declaration was lost"; fi

# 21 — TAG LENGTH BOUND (Opus PASS review of #1848): the 'short' tag before the preposition is at most 24 BYTES (the extractor runs under LC_ALL=C); a long bracketed
#      aside is prose, not a tag, so the clause is surfaced as unbound instead of declaring a correction.
d="$TMP/cg-longtag"; pblank "$d" t 32; pmk "$d" t 109 '# Block 109\n\nCORRIGENDUM [a long bracketed aside about something else entirely] to [Block 32].\n'
out="$(run "$d")"
if ! grep -qE 'FAIL +B109 corrects \[Block 32\] ' <<<"$out" && grep -qE 'note +1 correction verb' <<<"$out"; then ok "a tag longer than 24 bytes is prose: surfaced unbound, not a declaration"
else no "cg-longtag :: $(tr '\n' '|' <<<"$out")"; fi
d="$TMP/cg-shorttag"; pblank "$d" t 32; pmk "$d" t 110 '# Block 110\n\nCORRIGENDUM [CERT-2026-07-26] to [Block 32].\n'
if grep -qE 'FAIL +B110 corrects \[Block 32\] ' <<<"$(run "$d")"; then ok "a short tag (<= 24 bytes) still declares"
else no "cg-shorttag :: $(run "$d" | tr '\n' '|')"; fi

# 23 — UTF-8 PUNCTUATION IS A BOUNDARY (Opus gate on T12): a typographic mark directly before the note (`—corrected in B33`,
#      `“corrected in B33”`, `«corregido en B33»`, `¿corregido?`, `–`, `‘`, `¡`, `·`) is not word text, in the backlink rule AND the
#      noun rule. Single forms, plus ONE fixture holding them first/middle/last; C and UTF-8 locales. Letters stay word text (case 22).
pun_forms=('\342\200\224corrected in B33' '\342\200\234corrected in B33\342\200\235' '\302\253corregido en B33\302\273' '\302\277corregido en B33?' '\342\200\223corrected in B33' '\342\200\230corrected in B33' '\302\241corregido en B33' '\302\267corrected in B33')
for _loc in C C.utf8; do
  pu_ok=1; pu_bad=""
  for _s in "${pun_forms[@]}"; do
    d="$TMP/pun1"; rm -rf "$d"; pmk "$d" t 33 '# Block 33\n\n> Corrects [Block 8].\n'; pmk "$d" t 8 '# Block 8\n\n'"$_s"'\n'
    out="$(runl "$_loc" "$d")"; grep -qE 'FAIL' <<<"$out" && { pu_ok=0; pu_bad="$pu_bad [$_s]"; }
  done
  d="$TMP/pun-all"; rm -rf "$d"; pmk "$d" t 33 '# Block 33\n\n> Corrects [Block 8].\n'
  pmk "$d" t 8 '# Block 8\n\n\342\200\224corrected in B33 first\nmid \342\200\234corrected in B33\342\200\235 middle\nlast \302\253corregido en B33\302\273'
  grep -qE 'FAIL' <<<"$(runl "$_loc" "$d")" && { pu_ok=0; pu_bad="$pu_bad [all]"; }
  d="$TMP/pun-noun"; rm -rf "$d"; pmk "$d" t 33 '# Block 33\n\n> Corrects [Block 8].\n'; pmk "$d" t 8 '# Block 8\n\n\342\200\234CORRECCI\303\223N \342\200\224 [Block 33].\342\200\235\n'
  grep -qE 'FAIL' <<<"$(runl "$_loc" "$d")" && { pu_ok=0; pu_bad="$pu_bad [noun]"; }
  if [ "$pu_ok" = 1 ]; then ok "UTF-8 punctuation before the note is a boundary [$_loc]: dash / curly quotes / guillemets / inverted marks / middle dot still reciprocate (backlink + noun rule)"
  else no "punct-boundary [$_loc] :: $pu_bad"; fi
done

# 22 — BACKLINK WORD BOUNDARY (#1835 comment, pre-existing): `uncorrected` / `miscorrected` / `ñcorrected` contain the word `corrected` but
#      are not the note `corrected in B33`. FIRST / MIDDLE / LAST position of the line, under a C and a UTF-8 locale.
for _loc in C C.utf8; do
  bl_ok=1; bl_bad=""
  for _s in 'uncorrected in B33 text' 'This was uncorrected in B33' 'Left as uncorrected, see B33' 'pa\0303\0261corrected in B33' 'stays miscorrected by B33'; do
    d="$TMP/bl-neg"; rm -rf "$d"; pmk "$d" t 33 '# Block 33\n\n> Corrects [Block 8].\n'; pmk "$d" t 8 '# Block 8\n\n%b' "$_s"
    grep -qE 'FAIL +B33 corrects \[Block 8\] ' <<<"$(runl "$_loc" "$d")" || { bl_ok=0; bl_bad="$bl_bad [$_s]"; }
  done
  for _s in 'corrected in B33' 'Note: corrected in B33' '> **Corrected** (B33)' 'was (corrected in B33)' '_corrected_ in B33'; do
    d="$TMP/bl-pos"; rm -rf "$d"; pmk "$d" t 33 '# Block 33\n\n> Corrects [Block 8].\n'; pmk "$d" t 8 '# Block 8\n\n%b' "$_s"
    grep -qE 'FAIL' <<<"$(runl "$_loc" "$d")" && { bl_ok=0; bl_bad="$bl_bad +[$_s]"; }
  done
  # stable fixtures for the teeth below: a non-ASCII letter right before the word (C locale: two bytes >= 0x80), and a plain prefix
  d="$TMP/bl-n"; rm -rf "$d"; pmk "$d" t 33 '# Block 33\n\n> Corrects [Block 8].\n'; pmk "$d" t 8 '# Block 8\n\npa\303\261corrected in B33'
  grep -qE 'FAIL +B33 corrects \[Block 8\] ' <<<"$(runl "$_loc" "$d")" || { bl_ok=0; bl_bad="$bl_bad [ñcorrected fixture]"; }
  d="$TMP/bl-u"; rm -rf "$d"; pmk "$d" t 33 '# Block 33\n\n> Corrects [Block 8].\n'; pmk "$d" t 8 '# Block 8\n\nuncorrected in B33'
  d="$TMP/bl-nn"; rm -rf "$d"; pmk "$d" t 33 '# Block 33\n\n> Corrects [Block 8].\n'; pmk "$d" t 8 '# Block 8\n\npa\303\261correcci\303\263n \342\200\224 [Block 33].\n'
  grep -qE 'FAIL +B33 corrects \[Block 8\] ' <<<"$(runl "$_loc" "$d")" || { bl_ok=0; bl_bad="$bl_bad [ñcorrección noun fixture]"; }
  if [ "$bl_ok" = 1 ]; then ok "backlink vocabulary has a left word boundary [$_loc]: un-/mis-/ñ-corrected is not the note; real forms still reciprocate"
  else no "backlink-boundary [$_loc] :: $bl_bad"; fi
done

# NEGATIVE CONTROLS — each mutant disables ONE rule and must flip exactly the case that owns it (a mutant that crashes, or
# that merely differs, is theater: lib/mutant.sh refuses it).
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_tooth mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ mutant_chain_or_count fail "$@" || return 1; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  CRASH="$(mutant_crash_re bash cmd tb awk)" || exit 2
  mkdir -p "$TMP/lib"; cp "$HERE/../lib/block-files.sh" "$TMP/lib/block-files.sh"

  echo "-- teeth (#1868 item 1): cross-focus qualifier --"
  m="$TMP/vc.NOQUAL.sh"
  if mk_mut "teeth: qualifier ignored" "$SUT" "$m" 's/else if (qcur != "") print "Q " n " " qcur " " qkind/else if (0) print "Q " n " " qcur " " qkind/'; then
    tt "teeth: qualifier-blind mutant binds B8 to the colliding pi5-decoding-block5 (the real false FAIL)" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'B8 corrects \[Block 5\] but pi5-decoding' --bad-has 'B8 corrects \[Block 5\] but pi5-decoding-block5' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
    tt "teeth: qualifier-blind mutant checks aa-block1 for 'Corrects \`zz\` [Block 1]' (loses the zz gap)" 1 0 "$m" --orig "$SUT" \
      --good-has 'but zz-block1\.md' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/q-prefix"
  fi
  m="$TMP/vc.NOFOCUSES.sh"
  if mk_mut "teeth: FOCUSES.md lookup" "$SUT" "$m" '/^  \[ -z "${focuspfx\[$s\]:-}" \] || /d'; then
    tt "teeth: FOCUSES-blind mutant cannot resolve 'integration' (AMBIG instead of a verdict)" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'AMBIG +B8 ' --bad-has 'FAIL +B8 corrects \[Block 5\] but pi5-decoding-block5' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
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
  if mk_mut "teeth: postfix object" "$SUT" "$m" 's/cls = classify(cl); postlist(pre)/cls = ""; postlist(pre)/'; then
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
  if mk_mut "teeth: bare class" "$SUT" "$m" 's/{ cls = "bare"; emit(bn); moreb(cl); done = 1 }/{ done = 0 }/'; then
    tt "teeth: bare-blind mutant drops the AMBIG line for 'Corrects B292'" 0 0 "$m" --orig "$SUT" \
      --good-has 'AMBIG +B300 corrects \[Block 292\] ' --bad-lacks 'AMBIG +B300|awk: ' -- bash @SUT@ "$TMP/bare"
  fi
  m="$TMP/vc.BAREREFUSE.sh"
  if mk_mut "teeth: bare advisory" "$SUT" "$m" 's/^    elif \[ "$cls" = bare \] || \[ "$cls" = mixed \]; then$/    elif false; then/'; then
    tt "teeth: refusing mutant turns the advisory bare ref into a FAIL (exit 1)" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B300 corrects \[Block 292\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/bare"
  fi
  m="$TMP/vc.PARTIAL.sh"
  if mk_mut "teeth: ambiguous counts as partial" "$SUT" "$m" 's/_vc_partial=$((unchecked+ambiguous+negated))/_vc_partial=$unchecked/'; then
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
  if mk_mut "teeth: corrigendum leading tag" "$SUT" "$m" 's/ \&\& inner !~ \/(block|bloque)\[ \\t\]\*\[0-9\]\///'; then
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

  echo "-- teeth (PR gate round): self-skip on the resolved file, soft slugs, list inheritance, narrow object, bare lists, refine shapes --"
  m="$TMP/vc.SELFNUM.sh"
  if mk_mut "teeth: self-skip by number" "$SUT" "$m" 's/\[ "$tgt" = "$f" \] \&\& continue/[ "$n" = "$c" ] \&\& continue/'; then
    tt "teeth: number-based self-skip silently drops 'Corrects \`zz\` [Block 3]' inside aa-block3 (ok instead of FAIL)" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B3 corrects \[Block 3\] but zz-block3' --bad-lacks 'FAIL|awk: ' -- bash @SUT@ "$TMP/self-q"
    tt "teeth: number-based self-skip drops the FOCUSES.md same-number ref too" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B5 corrects \[Block 5\] but hb-block5' --bad-lacks 'FAIL|awk: ' -- bash @SUT@ "$TMP/self-focuses"
  fi
  m="$TMP/vc.NOSELF.sh"
  if mk_mut "teeth: no self-skip" "$SUT" "$m" 's/\[ "$tgt" = "$f" \] \&\& continue/:/'; then
    tt "teeth: no-self-skip mutant FAILs a genuine self-correction" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B3 corrects \[Block 3\] but aa-block3' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/self-ctl"
  fi
  m="$TMP/vc.NOSOFT.sh"
  if mk_mut "teeth: soft slug fallback" "$SUT" "$m" 's/if \[ -z "$_vc_qp" \] \&\& { \[ "$qkind" = soft \] || \[ "$qkind" = lead \]; }; then _vc_soft="$qual"; qual=""; fi/:/'; then
    tt "teeth: no-fallback mutant turns \"[Block 8] del \`loader\`\" into AMBIG cross-focus (was FAIL)" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B90 corrects \[Block 8\] ' --bad-has 'AMBIG +B90 .*cross-focus' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/soft"
  fi
  m="$TMP/vc.ALLSOFT.sh"
  if mk_mut "teeth: hard kind" "$SUT" "$m" 's/qkind = (qt ~ \/focus\/) ? "hard" : "soft"/qkind = "soft"/'; then
    tt "teeth: all-soft mutant loses the AMBIG for an explicit 'of the \`ghost\` focus'" 0 1 "$m" --orig "$SUT" \
      --good-has 'AMBIG +B4 .*cross-focus' --bad-has 'FAIL +B4 corrects \[Block 1\] but aa-block1' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/hard-ghost"
  fi
  m="$TMP/vc.QLIST.sh"
  if mk_mut "teeth: list inherits qualifier" "$SUT" "$m" 's/more(cl); done = 1; qcur = ""; qkind = ""/qcur = ""; qkind = ""; more(cl); done = 1/'; then
    tt "teeth: non-inheriting mutant resolves the LATER refs of '\`zz\` [Block 1] and [Block 2]' in the own prefix" 1 1 "$m" --orig "$SUT" \
      --good-has 'but zz-block3\.md' --bad-lacks 'but zz-block3\.md|awk: ' -- bash @SUT@ "$TMP/qlist"
  fi
  m="$TMP/vc.BROADPOSS.sh"
  if mk_mut "teeth: broad possessive" "$SUT" "$m" 's/\^\[ \\t\]\*(this|that|the|our|my)\[ \\t\]+(focus|caller|backlog|queue|session|run)(\\047/[a-z](\\047/'; then
    tt "teeth: any-possessive mutant makes \"the decompiler's reading in [Block 8]\" AMBIG" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B91 corrects \[Block 8\] ' --bad-has 'AMBIG +B91 .*object' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/poss"
  fi
  m="$TMP/vc.NARROWPOSS.sh"
  if mk_mut "teeth: process-noun possessive" "$SUT" "$m" 's/(focus|caller|backlog|queue|session|run)/(zzz)/'; then
    tt "teeth: over-narrow mutant FAILs the bloque717 citation list again" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B83 corrects \[Block 537\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/obj717"
  fi
  m="$TMP/vc.NOBARELIST.sh"
  if mk_mut "teeth: bare list" "$SUT" "$m" 's/ moreb(cl); done = 1 }/ done = 1 }/'; then
    tt "teeth: first-bare-only mutant drops B12 and B15 of 'Corrects B6/B12 and B15'" 0 0 "$m" --orig "$SUT" \
      --good-has 'AMBIG +B100 corrects \[Block 15\] ' --bad-lacks 'AMBIG +B100 corrects \[Block 15\] |awk: ' -- bash @SUT@ "$TMP/bare-list"
  fi
  m="$TMP/vc.BARESLASH.sh"
  if mk_mut "teeth: bare list slash" "$SUT" "$m" 's/(and|y|e|&|.\{2\})\[ \\t\]\*b\[0-9\]/(and|y|e|\&)[ \\t]*b[0-9]/'; then
    tt "teeth: slash-less bare list loses B12 of 'B6/B12'" 0 0 "$m" --orig "$SUT" \
      --good-has 'AMBIG +B100 corrects \[Block 12\] ' --bad-lacks 'AMBIG +B100 corrects \[Block 12\] |awk: ' -- bash @SUT@ "$TMP/bare-list"
  fi
  m="$TMP/vc.BARESTOP.sh"
  if mk_mut "teeth: bare list gap" "$SUT" "$m" 's/\^\[ \\t0-9.,-\]\*(and|y|e|&|.\{2\})\[ \\t\]\*b\[0-9\]+/[^b]*b[0-9]+/'; then
    tt "teeth: gap-less bare list binds B7 behind '(see also'" 0 0 "$m" --orig "$SUT" \
      --good-lacks 'AMBIG +B102 corrects \[Block 7\]' --bad-has 'AMBIG +B102 corrects \[Block 7\]' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/bare-stop"
  fi
  m="$TMP/vc.BAREREFINE.sh"
  if mk_mut "teeth: refine shapes" "$SUT" "$m" "s/^_vc_backlink_re=.*/_vc_backlink_re='corrected|corregid[oa]s?|corrigend(um|a)|errat(um|a)|refined|refinement|refinad[oa]s?|refinamiento'/"; then
    tt "teeth: bare-word refine vocabulary accepts 'Refinement planned, see B4' as a backlink" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B4 corrects \[Block 1\] ' --bad-lacks 'FAIL|awk: ' -- bash @SUT@ "$TMP/refine-neg"
  fi
  m="$TMP/vc.TABSLUG.sh"
  if mk_mut "teeth: tab slug" "$SUT" "$m" 's/\*\[:space:\]\]/* ]/'; then
    tt "teeth: tab-blind mutant cannot resolve a tab-padded FOCUSES.md slug (falls back to the colliding own prefix)" 1 1 "$m" --orig "$SUT" \
      --good-has 'FAIL +B8 corrects \[Block 5\] but hb-block5' --bad-has 'FAIL +B8 corrects \[Block 5\] but pi5-block5' --bad-lacks 'but hb-block5|awk: ' -- bash @SUT@ "$TMP/self-tab"
  fi
  m="$TMP/vc.REALFILE.sh"
  if mk_mut "teeth: real file names in FOCUSES" "$SUT" "$m" 's/(block|bloque)(N|\[0-9\]+)/(block|bloque)N/'; then
    tt "teeth: placeholder-only mutant cannot read a real <prefix>-block<N>.md cell" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B5 corrects \[Block 5\] but hb-block5' --bad-has 'ok +every declared' --bad-lacks 'but hb-block5|awk: ' -- bash @SUT@ "$TMP/self-focuses"
  fi

  echo "-- teeth (round 2): trailing list qualifier, no silent n==c drop --"
  m="$TMP/vc.NOTRAILQ.sh"
  if mk_mut "teeth: trailing qualifier" "$SUT" "$m" 's/if (!trailq(post)) trailq(substr(cl, listend(cl)))/trailq(post)/'; then
    tt "teeth: first-ref-only qualifier lookup resolves the 2-list '[Block 1] and [Block 2] of the \`zz\` focus' in the own prefix" 1 0 "$m" --orig "$SUT" \
      --good-has 'but zz-block2\.md' --bad-lacks 'FAIL|awk: ' -- bash @SUT@ "$TMP/tq-aa"
    tt "teeth: first-ref-only qualifier lookup, other prefix order (zz → aa)" 1 0 "$m" --orig "$SUT" \
      --good-has 'but aa-block2\.md' --bad-lacks 'FAIL|awk: ' -- bash @SUT@ "$TMP/tq-zz"
  fi
  m="$TMP/vc.NOLISTEND.sh"
  if mk_mut "teeth: listend walk" "$SUT" "$m" 's/pos += st + ln - 1; rest = substr(rest, st + ln)/break/'; then
    tt "teeth: list-end walk stops at the first ref, so a 3-element list loses its trailing qualifier" 1 0 "$m" --orig "$SUT" \
      --good-has 'but zz-block3\.md' --bad-lacks 'FAIL|awk: ' -- bash @SUT@ "$TMP/tq-3"
  fi
  m="$TMP/vc.SILENTSELF.sh"
  if mk_mut "teeth: own-number AMBIG" "$SUT" "$m" 's/^amb() { echo/amb() { [ "$n" = "$c" ] \&\& return 0; echo/'; then
    tt "teeth: number-based drop makes the own-number AMBIG object vanish (ok instead of ok-partial)" 0 0 "$m" --orig "$SUT" \
      --good-has 'ok-partial +1 declared correction' --bad-has 'ok +every declared' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/selfamb1"
  fi

  echo "-- teeth (T12): corrigendum possessive of, tag bound, backlink word boundary --"
  m="$TMP/vc.OFPOSS.sh"
  if mk_mut "teeth: bare of" "$SUT" "$m" 's/if (!hasl \&\& lead ~/if (0 \&\& lead ~/'; then
    tt "teeth: possessive-blind mutant declares B8→B33 from 'the corrigendum of [Block 33]'" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B8 corrects \[Block 33\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/cg-of"
  fi
  m="$TMP/vc.POSSTYPED.sh"
  if mk_mut "teeth: possessive typed" "$SUT" "$m" 's/print "A possessive " NDN; p = ve; continue/print "U"; p = ve; continue/'; then
    tt "teeth: untyped mutant reads the possessive as bare unbound: ok-partial becomes an unqualified ok" 0 0 "$m" --orig "$SUT" \
      --good-has 'ok-partial +1 declared' --good-lacks 'ok +every declared' --bad-has 'ok +every declared' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/cg-of"
  fi
  m="$TMP/vc.PUNALT.sh"
  if mk_mut "teeth: punctuation alternatives" "$SUT" "$m" 's/^_vc_pun="$(printf .*$/_vc_pun="NOPUNCT"/'; then
    tt "teeth: punctuation-blind mutant FAILs '—corrected in B33' (and the typographic forms)" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B33 corrects \[Block 8\] ' --bad-lacks "$CRASH" -- env LC_ALL=C bash @SUT@ "$TMP/pun-all"
  fi
  m="$TMP/vc.PUNNOUN.sh"
  if mk_mut "teeth: punctuation noun" "$SUT" "$m" 's/^_vc_noun_re="(^|\[^\[:alnum:\]_${_vc_hi}\]|${_vc_pun})"/_vc_noun_re="(^|[^[:alnum:]_${_vc_hi}])"/'; then
    tt "teeth: punctuation-blind noun rule FAILs a quoted 'CORRECCION - [Block 33].'" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B33 corrects \[Block 8\] ' --bad-lacks "$CRASH" -- env LC_ALL=C bash @SUT@ "$TMP/pun-noun"
  fi
  m="$TMP/vc.OFTAG.sh"
  if mk_mut "teeth: tagged of dropped" "$SUT" "$m" 's/PREP = "(al|a|to|of|for)"/PREP = "(al|a|to|for)"/'; then
    tt "teeth: a preposition list without 'of' loses the tagged 'CORRIGENDUM [CERT] of [Block 32]'" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B107 corrects \[Block 32\] ' --bad-lacks 'B107 corrects|awk: ' -- bash @SUT@ "$TMP/cg-oftag"
  fi
  m="$TMP/vc.TAGMAX.sh"
  if mk_mut "teeth: tag bound" "$SUT" "$m" 's/length(inner) <= TAGMAX/1/'; then
    tt "teeth: unbounded-tag mutant declares B109→B32 from a long bracketed aside" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B109 corrects \[Block 32\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/cg-longtag"
  fi
  m="$TMP/vc.BLLEFT.sh"
  if mk_mut "teeth: backlink left boundary" "$SUT" "$m" 's/^_vc_backlink_pre=.*$/_vc_backlink_pre="("/'; then
    tt "teeth: boundary-less mutant reads 'uncorrected in B33' as the note (loses the FAIL)" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B33 corrects \[Block 8\] ' --bad-lacks 'B33 corrects|awk: ' -- bash @SUT@ "$TMP/bl-u"
  fi
  m="$TMP/vc.BLHI.sh"
  if mk_mut "teeth: backlink non-ASCII byte" "$SUT" "$m" 's/^_vc_backlink_pre=.*$/_vc_backlink_pre="(^|[^[:alnum:]])("/'; then
    tt "teeth: byte-blind mutant reads 'pañcorrected in B33' as the note under LC_ALL=C (loses the FAIL)" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B33 corrects \[Block 8\] ' --bad-lacks 'B33 corrects|awk: ' -- env LC_ALL=C bash @SUT@ "$TMP/bl-n"
  fi
  m="$TMP/vc.NOUNHI.sh"
  if mk_mut "teeth: noun non-ASCII byte" "$SUT" "$m" 's/_vc_noun_re="(^|\[^\[:alnum:\]_${_vc_hi}\]/_vc_noun_re="(^|[^[:alnum:]_]/'; then
    tt "teeth: byte-blind noun mutant reads 'pañcorrección — [Block 33]' as the backlink under LC_ALL=C" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B33 corrects \[Block 8\] ' --bad-lacks 'B33 corrects|awk: ' -- env LC_ALL=C bash @SUT@ "$TMP/bl-nn"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
