#!/usr/bin/env bash
# verify-corrections-binding.test.sh — clause-scoped verb→reference binding for verify-corrections.sh (#1790).
#
# Companion to verify-corrections.test.sh (which keeps the original reciprocal-backlink / first-ref / adjective
# cases). This suite pins the #1790 fix: the `corrects` verb governs ONLY a [Block N] inside its own clause, not
# any bracket that happens to share the (wrapped) line. The headline fixture is the REAL blender-llm-block17.md
# header — `[Block 1] (the claim §17.7 corrects) · [Block 11] (the recommendation §17.7 reframes).` — which the
# per-line linter reported as "B17 corrects Block 11". Every binding rule has a case where it is the ONLY thing
# separating a correct verdict from a wrong one, so each mutant in --prove-teeth turns exactly one case red.
#
# Usage: verify-corrections-binding.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-corrections.sh"
FIX="$HERE/fixtures/verify-corrections"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -d "$FIX/blender-wrapped" ] || { echo "FATAL: fixture dir missing: $FIX/blender-wrapped" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
run(){ bash "$SUT" "$1" 2>&1; }
code(){ bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }
# mk <dir> <num> <printf-format> — write t-block<num>.md (format is a printf format; no trailing newline added).
mk(){ mkdir -p "$1"; printf "$3" "${@:4}" > "$1/t-block$2.md"; }
# blank <dir> <num>... — create unannotated target blocks (no backlink anywhere).
blank(){ local d="$1"; shift; local n; mkdir -p "$d"; for n in "$@"; do printf '# Block %s\n\nOriginal claim.\n' "$n" > "$d/t-block$n.md"; done; }

echo "== verify-corrections-binding.test.sh (SUT: $(basename "$SUT")) =="

# 1 — REAL SHAPE (blender-llm-block17.md:18 and block19.md:15, copied verbatim into a fixture): a wrapped
#     blockquote list whose verb sits in a parenthetical AFTER its own ref. B17 must correct Block 1 (not the
#     unrelated trailing Block 11); B19's verb wraps onto the line AFTER its ref → Block 13 (not Block 9).
d="$TMP/real"; cp -r "$FIX/blender-wrapped" "$d"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] \
   && grep -qE 'FAIL +B17 corrects \[Block 1\] ' <<<"$out" && ! grep -qE 'B17 corrects \[Block 11\]' <<<"$out" \
   && grep -qE 'FAIL +B19 corrects \[Block 13\] ' <<<"$out" && ! grep -qE 'B19 corrects \[Block 9\]' <<<"$out"; then
  ok "real blender B17/B19 wrapped lists: binds Block 1 / Block 13, NOT the trailing Block 11 / Block 9"
else no "real shape :: $(grep -E 'FAIL|WARN' <<<"$out" | tr '\n' '|')"; fi

# 2 — `)` closes the clause: `[Block 3] (premise this corrects), see [Block 9].` → Block 3 only.
d="$TMP/paren"; blank "$d" 3 9
mk "$d" 30 '# Block 30\n\n> Connects [Block 3] (the premise this corrects), see [Block 9].\n'
out="$(run "$d")"
if grep -qE 'B30 corrects \[Block 3\] ' <<<"$out" && ! grep -qE 'B30 corrects \[Block 9\]' <<<"$out"; then
  ok "parenthetical postfix verb: governs the ref before '(' and stops at ')'"
else no "paren :: $(grep -E 'FAIL|WARN' <<<"$out" | tr '\n' '|')"; fi

# 3 — wrapped FORWARD: the verb ends one physical line and its ref starts the next.
d="$TMP/wrapfwd"; blank "$d" 8
mk "$d" 31 '# Block 31\n\n> This block Corrects\n> [Block 8] §2 on Docker.\n'
if grep -qE 'B31 corrects \[Block 8\] ' <<<"$(run "$d")"; then ok "verb at end of line, ref on the next line (same paragraph) → still bound"
else no "wrapfwd :: $(run "$d" | grep -E 'FAIL|WARN' | tr '\n' '|')"; fi

# 4 — a bracket wrapped INSIDE the reference: `[Block\n50]`.
d="$TMP/wrapbr"; blank "$d" 50
mk "$d" 32 '# Block 32\n\n> and, in doing so, corrects [Block\n> 50] §50.4 framing.\n'
if grep -qE 'B32 corrects \[Block 50\] ' <<<"$(run "$d")"; then ok "ref wrapped inside the bracket ('[Block' / '50]') → bound"
else no "wrapbr :: $(run "$d" | grep -E 'FAIL|WARN' | tr '\n' '|')"; fi

# 5 — LIST EDGES: bullet isolation + verb in the LAST bullet of a file with no trailing newline. Bullet 1's verb
#     has no ref of its own; the next bullet's [Block 12] is NOT its target. The last bullet (no final newline)
#     must still be scanned.
d="$TMP/edges"; blank "$d" 12 14
mk "$d" 33 '# Block 33\n\n- Corrects the earlier claim\n- [Block 12] cross-reference only\n- also corrects [Block 14]'
out="$(run "$d")"
if grep -qE 'B33 corrects \[Block 14\] ' <<<"$out" && ! grep -qE 'B33 corrects \[Block 12\]' <<<"$out"; then
  ok "list edges: bullets are separate units; last bullet without trailing newline is scanned"
else no "edges :: $(grep -E 'FAIL|WARN' <<<"$out" | tr '\n' '|')"; fi

# 5b — SINGLE-ELEMENT file, FIRST == LAST, no trailing newline.
d="$TMP/single"; blank "$d" 8
mk "$d" 34 '> Corrects [Block 8].'
if grep -qE 'B34 corrects \[Block 8\] ' <<<"$(run "$d")"; then ok "single-line file with no trailing newline → bound"
else no "single :: $(run "$d" | tr '\n' '|')"; fi

# 5c — a blank line ends the unit: a verb paragraph never binds a ref in the NEXT paragraph.
d="$TMP/para"; blank "$d" 8
mk "$d" 35 '# Block 35\n\nCorrects the earlier claim\n\n[Block 8] is only cross-referenced here\n'
if [ "$(code "$d")" = 0 ]; then ok "blank line ends the unit: next paragraph's [Block 8] is not a target → exit 0"
else no "para :: $(run "$d" | grep -E 'FAIL' | tr '\n' '|')"; fi

# 6 — conjunction ends the clause: `CORRECTS the backlog's statement, and independently corroborates [Block 5].`
d="$TMP/conj"; blank "$d" 5
mk "$d" 36 "# Block 36\n\n> **Block type: EVIDENCE.** CORRECTS the backlog statement of G4, and\n> independently corroborates [Block 5].\n"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'note +1 correction verb' <<<"$out"; then
  ok "', and <other verb> [Block 5]' → Block 5 is not a target; the unbound verb is surfaced as a note"
else no "conj :: $(tr '\n' '|' <<<"$out")"; fi

# 7 — sentence boundary: the ref after the verb's own sentence is not its target.
d="$TMP/sent"; blank "$d" 52
mk "$d" 37 '# Block 37\n\n- **[Block 53]** — both bounded it; this block\n  corrects that — it is in the jar we hold. The property read ([Block 52]) may also live here.\n'
if [ "$(code "$d")" = 0 ]; then ok "ref in the NEXT sentence is not a target → exit 0"
else no "sent :: $(run "$d" | grep -E 'FAIL' | tr '\n' '|')"; fi

# 8 — bare B<N> leads the clause: the later bracket is not the target (nor is it guessed); since #1868 (#1835 item 4) the
#     bare ref itself is a typed AMBIG (bare) line — here B67 has no block file, so it is named, not dropped.
d="$TMP/bare"; blank "$d" 34
mk "$d" 38 '# Block 38\n\n# x — and §14 CORRECTS my own B67 §67.7, which walked into a trap [Block 34] had described\n'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'AMBIG +B38 corrects \[Block 67\] .*bare' <<<"$out" && ! grep -qE 'B38 corrects \[Block 34\]' <<<"$out"; then
  ok "bare 'B67' leads the clause → later [Block 34] not a target; the bare ref is surfaced as an AMBIG line, not dropped silently"
else no "bare :: $(tr '\n' '|' <<<"$out")"; fi

# 9 — OPERATIONAL FAILURE is never "ok" (§7): a stub awk that exits 2 → typed degraded line, exit 1, no ok line.
d="$TMP/stubdir"; mkdir -p "$d/bin"; printf '#!/bin/sh\nexit 2\n' > "$d/bin/awk"; chmod +x "$d/bin/awk"
dd="$TMP/degr"; blank "$dd" 8
mk "$dd" 39 '# Block 39\n\n> Corrects [Block 8].\n'
out="$(PATH="$d/bin:$PATH" bash "$SUT" "$dd" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q 'degraded: extractor (awk) failed on t-block39.md' <<<"$out" && ! grep -qE 'ok +every declared' <<<"$out"; then
  ok "failing awk → 'degraded:' line naming the file, exit 1, never the ok line"
else no "degraded :: rc=$rc $(tr '\n' '|' <<<"$out")"; fi

# 10 — `·` boundary is byte-deterministic: same binding under C and UTF-8 locales, and under gawk when present.
d="$TMP/dot"; blank "$d" 8
mk "$d" 40 '# Block 40\n\n> Corrects the earlier claim · [Block 8] is only cross-referenced here\n'
GD=""; if command -v gawk >/dev/null 2>&1; then GD="$TMP/gawkbin"; mkdir -p "$GD"; ln -sf "$(command -v gawk)" "$GD/awk"; fi
UTF=""; for _l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do if grep -qix "$_l" <<<"$(locale -a 2>/dev/null)"; then UTF="$_l"; break; fi; done
dotok=1
for _env in "LC_ALL=C" ${UTF:+"LC_ALL=$UTF"}; do
  [ "$(env "$_env" bash "$SUT" "$d" >/dev/null 2>&1; echo $?)" = 0 ] || dotok=0
  if [ -n "$GD" ]; then [ "$(env "$_env" PATH="$GD:$PATH" bash "$SUT" "$d" >/dev/null 2>&1; echo $?)" = 0 ] || dotok=0; fi
done
if [ "$dotok" = 1 ]; then ok "'·' ends the clause under LC_ALL=C${UTF:+, $UTF}${GD:+ and gawk} (no cross-dot binding)"
else no "dot :: binding differs across locale/awk"; fi
[ -n "$UTF" ] || echo "  SKIP  no UTF-8 locale installed: '·' checked under LC_ALL=C only"
[ -n "$GD" ] || echo "  SKIP  gawk not installed: '·' checked with the default awk only"

# 11 — ABBREVIATIONS do not end the clause: "corrects the <abbr> framing in [Block 8]" still binds Block 8.
d="$TMP/abbr"; blank "$d" 8
abbr_ok=1; abbr_bad=""
for _a in 'cf.' 'e.g.' 'i.e.' 'vs.' 'Fig.' 'p.' 'pp.' 'approx.' 'aprox.' 'pág.' 'núm.' 'Sec.' 'x.'; do
  printf '# Block 41\n\n> This corrects the %s framing in [Block 8].\n' "$_a" > "$d/t-block41.md"
  if ! grep -qE 'B41 corrects \[Block 8\] ' <<<"$(run "$d")"; then abbr_ok=0; abbr_bad="$abbr_bad $_a"; fi
done
if [ "$abbr_ok" = 1 ]; then ok "abbreviations (cf. e.g. i.e. vs. Fig. p. pp. approx. aprox. pág. núm. Sec.) and a single initial do not end the clause"
else no "abbrev :: unbound after:$abbr_bad"; fi
# 11b — a REAL sentence end (multi-letter word, not on the list) still splits.
printf '# Block 41\n\n> This corrects the framing. [Block 8] is only cross-referenced.\n' > "$d/t-block41.md"
if [ "$(code "$d")" = 0 ]; then ok "a real sentence end ('framing. [Block 8]') still ends the clause → exit 0"
else no "sentend :: $(run "$d" | grep FAIL | tr '\n' '|')"; fi

# ---- #1835 precision follow-ups: prefix scope (12), backlink vocabulary (13), multi-target (14), non-assertive (15) ----
# pmk <dir> <prefix> <num> <printf-format> — write <prefix>-block<num>.md.
pmk(){ mkdir -p "$1"; printf "$4" "${@:5}" > "$1/$2-block$3.md"; }

# 12 — PREFIX SCOPE (#1835 item 1): two focus prefixes share block numbers. The target is resolved in the correcting
#      block's OWN prefix, whichever prefix sorts first/last (list edges): `aa` and `zz` both play "own" and "other".
for _own in aa zz; do
  _oth=zz; [ "$_own" = zz ] && _oth=aa
  d="$TMP/pfx-$_own"
  pmk "$d" "$_own" 4 '# Block 4\n\n> Corrects [Block 1] §1.2.\n'
  pmk "$d" "$_own" 1 '# Block 1\n\nOriginal.\n\n> corrected in B4.\n'
  pmk "$d" "$_oth" 1 '# Block 1\n\nOther focus, never annotated.\n'
  if [ "$(code "$d")" = 0 ]; then ok "prefix scope: '$_own' B4→B1 checks $_own-block1, not the colliding $_oth-block1 (exit 0)"
  else no "pfx-$_own :: $(run "$d" | grep FAIL | tr '\n' '|')"; fi
done
# 12b — the same scoping still FAILs a real gap, naming the OWN-prefix file.
d="$TMP/pfx-gap"
pmk "$d" aa 4 '# Block 4\n\n> Corrects [Block 1].\n'; pmk "$d" aa 1 '# Block 1\n\nNo note.\n'; pmk "$d" zz 1 '# Block 1\n\nnote: corrected in B4.\n'
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL +B4 corrects \[Block 1\] but aa-block1\.md ' <<<"$out"; then ok "prefix scope: a real gap in the own-prefix file still FAILs (and names aa-block1.md)"
else no "pfx-gap :: $(tr '\n' '|' <<<"$out")"; fi
# 12c — own prefix lacks the target and exactly ONE other prefix has it → that one is used.
d="$TMP/pfx-uniq"
pmk "$d" aa 4 '# Block 4\n\n> Corrects [Block 9].\n'; pmk "$d" zz 9 '# Block 9\n\nNo note.\n'
if [ "$(code "$d")" = 1 ] && grep -qE 'FAIL +B4 corrects \[Block 9\] but zz-block9\.md ' <<<"$(run "$d")"; then ok "own prefix lacks the target, one other prefix has it → unique fallback is checked (exit 1 asserted, #1847)"
else no "pfx-uniq :: $(run "$d" | tr '\n' '|')"; fi
# 12d — own prefix lacks it and SEVERAL others have it → ambiguous: WARN, not guessed, not a FAIL.
d="$TMP/pfx-amb"
pmk "$d" cc 4 '# Block 4\n\n> Corrects [Block 1].\n'; pmk "$d" aa 1 '# Block 1\n\nNo note.\n'; pmk "$d" zz 1 '# Block 1\n\nNo note.\n'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'WARN +B4 .*ambiguous across 2 other prefixes' <<<"$out" \
   && ! grep -qE 'ok +every declared' <<<"$out" && grep -qE 'ok-partial +1 declared correction\(s\) NOT checked' <<<"$out"; then
  ok "ambiguous across prefixes → typed WARN, nothing guessed, NO unqualified ok line, 'ok-partial' instead (exit 0)"
else no "pfx-amb :: $(tr '\n' '|' <<<"$out")"; fi
# 12e — a MISSING target file is the same unchecked state: qualified line, not the plain ok (§7).
d="$TMP/missing"; mk "$d" 33 '# Block 33\n\n> Corrects [Block 99].\n'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'WARN +B33 .*no block-99 file' <<<"$out" && ! grep -qE 'ok +every declared' <<<"$out" \
   && grep -qE 'ok-partial +1 declared correction\(s\) NOT checked' <<<"$out"; then ok "missing target file → WARN + 'ok-partial', never the unqualified ok"
else no "missing :: $(tr '\n' '|' <<<"$out")"; fi

# 13 — BACKLINK VOCABULARY (#1835 item 2): every accepted marker satisfies the reciprocal check.
vocab_ok=1; vocab_bad=""
for _w in 'CORRIGENDUM [Bloque 82]' 'Corrigenda: see B82' 'Erratum (B82)' 'Errata — Block 82' 'Corregida en B82' 'corregidos por Bloque 82' 'corrected in B82' 'corregido en B82'; do
  d="$TMP/vocab"; rm -rf "$d"; pmk "$d" t 82 '# Block 82\n\n> Corrects [Block 21].\n'; pmk "$d" t 21 '# Block 21\n\nOriginal.\n\n> %s\n' "$_w"
  [ "$(code "$d")" = 0 ] || { vocab_ok=0; vocab_bad="$vocab_bad [$_w]"; }
done
if [ "$vocab_ok" = 1 ]; then ok "backlink vocabulary: corrigendum/corrigenda/erratum/errata/corregida/corregidos/corrected/corregido all reciprocate"
else no "vocab :: rejected:$vocab_bad"; fi
# 13b — vocabulary without the correcting block's number is still no backlink.
d="$TMP/vocab-none"; pmk "$d" t 82 '# Block 82\n\n> Corrects [Block 21].\n'; pmk "$d" t 21 '# Block 21\n\nCORRIGENDUM [Bloque 90]\n'
if [ "$(code "$d")" = 1 ]; then ok "a corrigendum naming a DIFFERENT block is not a backlink to B82 → FAIL"
else no "vocab-none: exit $(code "$d")"; fi
# 13c — `corrigendum` is a noun, not a correction verb: the backlink line in block 21 must not declare B21→B90.
d="$TMP/vocab-noun"; pmk "$d" t 21 '# Block 21\n\nCORRIGENDUM [Bloque 90] — see there.\n'; pmk "$d" t 90 '# Block 90\n\nOriginal.\n'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'B21 corrects' <<<"$out"; then ok "'CORRIGENDUM [Bloque 90]' is a noun, not a correction declaration → exit 0"
else no "vocab-noun :: $(tr '\n' '|' <<<"$out")"; fi

# 14 — MULTIPLE TARGETS in one clause (#1835 item 3). FIRST / MIDDLE / LAST positions are all checked.
d="$TMP/multi-and"; blank "$d" 5 6
mk "$d" 60 '# Block 60\n\n> Corrects [Block 6] §6.3–6.4 and [Block 5] §5.4.\n'
out="$(run "$d")"
if grep -qE 'B60 corrects \[Block 6\] ' <<<"$out" && grep -qE 'B60 corrects \[Block 5\] ' <<<"$out"; then ok "'[Block 6] §6.3–6.4 and [Block 5] §5.4' → both targets checked"
else no "multi-and :: $(grep -E 'FAIL|WARN' <<<"$out" | tr '\n' '|')"; fi
# 14a — LIST EDGES: 3- and 4-element `and` lists reach FIRST, MIDDLE and LAST positions (`while`→`if` keeps only 2).
d="$TMP/multi-3"; blank "$d" 1 2 3 4
mk "$d" 64 '# Block 64\n\n> Corrects [Block 1] and [Block 2] and [Block 3].\n'
mk "$d" 65 '# Block 65\n\n> Corrects [Block 1] and [Block 2] and [Block 3] and [Block 4].\n'
out="$(run "$d")"; l_ok=1
for _n in 1 2 3; do grep -qE "B64 corrects \[Block $_n\] " <<<"$out" || l_ok=0; done
for _n in 1 2 3 4; do grep -qE "B65 corrects \[Block $_n\] " <<<"$out" || l_ok=0; done
if [ "$l_ok" = 1 ]; then ok "3- and 4-element 'and' lists → every position (first, middle, last) is a target"
else no "multi-3 :: $(grep -E 'FAIL|WARN' <<<"$out" | tr '\n' '|')"; fi
d="$TMP/multi-y"; blank "$d" 7 8
mk "$d" 62 '# Block 62\n\n> Corrige [Block 7] y [Bloque 8].\n'
out="$(run "$d")"
if grep -qE 'B62 corrects \[Block 7\] ' <<<"$out" && grep -qE 'B62 corrects \[Block 8\] ' <<<"$out"; then ok "Spanish 'y' joins two targets"
else no "multi-y :: $(grep -E 'FAIL|WARN' <<<"$out" | tr '\n' '|')"; fi
# 14b — NEGATIVE: prose between refs ends the list; a joined ref after a cross-reference word is not a target.
d="$TMP/multi-neg"; blank "$d" 6 7
mk "$d" 63 '# Block 63\n\n> Corrects [Block 6] and independently notes [Block 7].\n'
out="$(run "$d")"
if grep -qE 'B63 corrects \[Block 6\] ' <<<"$out" && ! grep -qE 'B63 corrects \[Block 7\]' <<<"$out"; then ok "'and independently notes [Block 7]' is prose, not a joined target"
else no "multi-neg :: $(grep -E 'FAIL|WARN' <<<"$out" | tr '\n' '|')"; fi

# 15 — NON-ASSERTIVE verbs (#1835 item 5): passive/conditional/past narrative declares nothing; surfaced as a note.
na_ok=1; na_bad=""
i=0
for _s in 'Se corrige [Block 8] en la siguiente iteración.' 'Si no se corrige [Block 8], el error persiste.' 'El bloque anterior corrigió [Block 8] en su momento.' 'Los autores corrigieron [Block 8] después.'; do
  i=$((i+1)); d="$TMP/na$i"; blank "$d" 8; mk "$d" 70 '# Block 70\n\n> %s\n' "$_s"
  out="$(run "$d")"
  { [ "$(code "$d")" = 0 ] && grep -qE 'note +1 correction verb\(s\) in a non-assertive form' <<<"$out"; } || { na_ok=0; na_bad="$na_bad [$_s]"; }
done
if [ "$na_ok" = 1 ]; then ok "'se corrige' / 'si no se corrige' / 'corrigió' / 'corrigieron' declare nothing (exit 0) and are counted in a note"
else no "non-assertive :: still declared:$na_bad"; fi
# 15b — POSITIVE CONTROL: assertive present-tense forms (incl. one whose word merely ENDS in 'se') still bind.
pa_ok=1
for _s in 'Corrige [Block 8] §2.' 'Este bloque corrige [Block 8] §2.' 'Aquel pase corrige [Block 8].'; do
  d="$TMP/pa"; rm -rf "$d"; blank "$d" 8; mk "$d" 71 '# Block 71\n\n> %s\n' "$_s"
  grep -qE 'B71 corrects \[Block 8\] ' <<<"$(run "$d")" || pa_ok=0
done
if [ "$pa_ok" = 1 ]; then ok "assertive 'Corrige/corrige' (not preceded by 'se') still declares the correction"
else no "non-assertive control: an assertive verb was dropped"; fi

# 16 — CORRIGENDUM AS DECLARATION (correction round): `CORRIGENDUM [`CERT`] al [Bloque 32]` (the real niagara-research
#      bloque107/108 shape) declares a correction; a BARE `CORRIGENDUM [Bloque N]` (noun right before the ref) stays a backlink.
cg_ok=1; cg_bad=""
for _s in 'CORRIGENDUM `[CERT]` al [Bloque 32] §2.' 'CORRIGENDUM al [Bloque 32].' 'Corrigenda a [Block 32].' 'CORRIGENDUM [CERT] to [Block 32].' 'corrigendum of `[CERT]` [Block 32].'; do
  d="$TMP/cg"; rm -rf "$d"; blank "$d" 32; mk "$d" 107 '# Block 107\n\n%s\n' "$_s"
  grep -qE 'FAIL +B107 corrects \[Block 32\] ' <<<"$(run "$d")" || { cg_ok=0; cg_bad="$cg_bad [$_s]"; }
done
if [ "$cg_ok" = 1 ]; then ok "'CORRIGENDUM [tag] al/a/to/of [Bloque N]' is a DECLARATION (true FAIL, not silently lost)"
else no "corrigendum-decl :: lost:$cg_bad"; fi
# 16b — both forms in one corpus: B82's bare backlink in block21 satisfies B82→21 AND does not declare B21→B82.
d="$TMP/cg-both"; pmk "$d" t 82 '# Block 82\n\n> Corrects [Block 21].\n'; pmk "$d" t 21 '# Block 21\n\nCORRIGENDUM [Bloque 82] — see there.\n'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && ! grep -qE 'B21 corrects' <<<"$out"; then ok "bare 'CORRIGENDUM [Bloque 82]' stays a backlink (B82→21 ok) and declares nothing"
else no "corrigendum-bare :: $(tr '\n' '|' <<<"$out")"; fi

# 17 — `+` and comma are NOT joiners (correction round): comma-only lists could false-bind a cross-reference, `+` joins
#      unrelated things. Only the FIRST ref of each is a target. `/` joins since #1868 (pinned in the precision suite); the
#      bloque717 evidence-citation list that made it unsafe is now typed AMBIG (object), asserted below.
d="$TMP/join-neg"; blank "$d" 1 2 3 537 538 545
mk "$d" 80 '# Block 80\n\n> Corrects [Block 1] + [Block 2].\n'
mk "$d" 81 '# Block 81\n\n> Corrects [Block 3] + [Block 2].\n'
mk "$d" 82 '# Block 82\n\n> Corrects [Block 3], [Block 2] is related.\n'
mk "$d" 83 "# Block 83\\n\\n> corrects this focus's bootstrap remittance — kitControl is DONE ([Block 537]/[Block 538]/[Block 545])\\n"
out="$(run "$d")"
if grep -qE 'B80 corrects \[Block 1\] ' <<<"$out" && ! grep -qE 'B80 corrects \[Block 2\]' <<<"$out" \
   && ! grep -qE 'B81 corrects \[Block 2\]' <<<"$out" && ! grep -qE 'B82 corrects \[Block 2\]' <<<"$out" \
   && grep -qE 'B82 corrects \[Block 3\] ' <<<"$out" \
   && ! grep -qE 'FAIL +B83 ' <<<"$out" && grep -qE 'AMBIG +B83 corrects \[Block 537\] .*object' <<<"$out"; then
  ok "'+' and a bare comma do not join targets: only the first ref binds; the real bloque717 citation list is AMBIG (object), not a FAIL"
else no "join-neg :: $(grep -E 'FAIL|WARN' <<<"$out" | tr '\n' '|')"; fi

# 18 — CORRIGENDUM NEVER VANISHES (round 3, §7): only the bare noun directly followed by a ref is a backlink. Every other
#      corrigendum either declares (an explicit PREPOSITION right before the ref, round 4) or is counted as unbound.
cgd_ok=1; cgd_bad=""
for _s in 'CORRIGENDUM for [Block 8]: §8.2 overstated.' 'CORRIGENDUM to the [Block 8]' 'CORRIGENDUM to `[CERT]` [Block 8]' 'Corrigenda of `[CERT]` [Bloque 8].'; do
  d="$TMP/cgd"; rm -rf "$d"; blank "$d" 8; mk "$d" 90 '# Block 90\n\n%s\n' "$_s"
  grep -qE 'FAIL +B90 corrects \[Block 8\] ' <<<"$(run "$d")" || { cgd_ok=0; cgd_bad="$cgd_bad [$_s]"; }
done
if [ "$cgd_ok" = 1 ]; then ok "corrigendum + for / to the / to <tag> / of + [Block 8] all DECLARE (no silent drop)"
else no "corrigendum-forms :: lost:$cgd_bad"; fi
# 18d — ROUND 4: a corrigendum NOUN declares only via an explicit preposition right before the ref. Every other form
#      (colon, em dash, parenthetical, "see", a ref later in the clause, prose) is a BACKLINK or prose: no FAIL, but it is
#      counted in the unbound note (accepted, surfaced false negative), never a declaration and never dropped silently.
# (a) forms living in the CORRECTED block 8, reciprocated by block 33 (a false FAIL here would be B8→33).
cgn_ok=1; cgn_bad=""; i=0
for _s in 'Corrigendum (see [Block 33]).' 'CORRIGENDUM: [Block 33] revises §8.2.' 'CORRIGENDUM — [Bloque 33]' 'Corrigendum: [Block 33] §2 was wrong.' 'CORRIGENDUM (to [Block 33])'; do
  i=$((i+1)); d="$TMP/cgn$i"; rm -rf "$d"; mk "$d" 8 '# Block 8\n\n> %s\n' "$_s"; mk "$d" 33 '# Block 33\n\n> Corrects [Block 8].\n'
  out="$(run "$d")"
  { [ "$(code "$d")" = 0 ] && ! grep -qE '^ *FAIL' <<<"$out" && grep -qE 'note +1 correction verb' <<<"$out"; } || { cgn_ok=0; cgn_bad="$cgn_bad [$_s]"; }
done
# (b) prose in a block with unannotated targets 12 / 5.
for _s in 'No corrigendum was needed for [Block 12].' 'The corrigendum policy in [Block 5] applies.'; do
  i=$((i+1)); d="$TMP/cgn$i"; rm -rf "$d"; blank "$d" 12 5; mk "$d" 90 '# Block 90\n\n%s\n' "$_s"
  out="$(run "$d")"
  { [ "$(code "$d")" = 0 ] && ! grep -qE '^ *FAIL' <<<"$out" && grep -qE 'note +1 correction verb' <<<"$out"; } || { cgn_ok=0; cgn_bad="$cgn_bad [$_s]"; }
done
if [ "$cgn_ok" = 1 ]; then ok "noun forms with ':' / '—' / '(' / 'see' / later ref / prose: exit 0, no FAIL, counted in the unbound note"
else no "corrigendum-noun-neg :: wrong:$cgn_bad"; fi
# 18b — a corrigendum with NO ref after it is counted in the unbound note, never dropped; the bare backlink adds nothing.
d="$TMP/cgd-unb"; blank "$d" 8; mk "$d" 91 '# Block 91\n\nThe corrigendum table lists nothing yet.\n'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'note +1 correction verb' <<<"$out"; then ok "ref-less corrigendum → surfaced in the unbound note (not silent)"
else no "corrigendum-unbound :: $(tr '\n' '|' <<<"$out")"; fi
d="$TMP/cgd-bare"; pmk "$d" t 82 '# Block 82\n\n> Corrects [Block 21].\n'; pmk "$d" t 21 '# Block 21\n\nCORRIGENDUM [Bloque 82] — see there.\n'
if ! grep -qE 'note +[0-9]+ correction verb' <<<"$(run "$d")"; then ok "bare backlink 'CORRIGENDUM [Bloque 82]' adds no unbound note"
else no "corrigendum-bare-note"; fi
# 18c — (round 3 item 4) `CORRIGENDUM [Bloque 33] al [Bloque 32]`: the target is the ref AFTER the preposition.
d="$TMP/cgd-two"; blank "$d" 32 33; mk "$d" 92 '# Block 92\n\nCORRIGENDUM [Bloque 33] al [Bloque 32].\n'
out="$(run "$d")"
if grep -qE 'B92 corrects \[Block 32\] ' <<<"$out" && ! grep -qE 'B92 corrects \[Block 33\]' <<<"$out"; then ok "block-ref 'tag' before the preposition is not the target: binds [Bloque 32], not 33"
else no "corrigendum-two :: $(grep -E 'FAIL|WARN' <<<"$out" | tr '\n' '|')"; fi

# 19 — (round 3 item 5) upper-case Ó under LC_ALL=C: tolower does not fold its bytes, yet `CORRIGIÓ` is still past tense.
d="$TMP/upper"; blank "$d" 8; mk "$d" 93 '# Block 93\n\nCORRIGIÓ [Bloque 8] hace tiempo.\n'; mk "$d" 94 '# Block 94\n\nCORRIGIERON [Bloque 8] hace tiempo.\n'
out="$(LC_ALL=C bash "$SUT" "$d" 2>&1)"
if ! grep -qE 'B9[34] corrects' <<<"$out" && grep -qE 'note +2 correction verb\(s\) in a non-assertive form' <<<"$out"; then ok "'CORRIGIÓ' / 'CORRIGIERON' (upper-case, C locale) are past tense → skipped and counted"
else no "upper-past :: $(tr '\n' '|' <<<"$out")"; fi

# NEGATIVE CONTROLS — each mutant disables ONE binding rule and must flip exactly the case that owns it.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  for _mf in mutant_chain mutant_tooth; do
    declare -F "$_mf" >/dev/null || { echo "FATAL: lib/mutant.sh did not define $_mf" >&2; exit 2; }
  done
  mk_mut(){ mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  CRASH="$(mutant_crash_re bash cmd tb awk)" || exit 2
  mkdir -p "$TMP/lib"; cp "$HERE/../lib/block-files.sh" "$TMP/lib/block-files.sh"

  echo "-- teeth: drop the postfix binding; the real blender fixture must lose both findings --"
  m="$TMP/vc.POSTFIX.sh"
  if mk_mut "teeth: postfix" "$SUT" "$m" 's/else if (!isnoun \&\& bd == "close")/else if (0)/'; then
    tt "teeth: no-postfix mutant misses B17→Block 1 (real shape)" 1 0 "$m" --orig "$SUT" \
      --good-has 'B17 corrects \[Block 1\] ' --bad-lacks 'B17 corrects \[Block 1\] |awk: ' -- bash @SUT@ "$TMP/real"
  fi

  echo "-- teeth: drop the ')' clause boundary; the parenthetical case must bind the wrong ref --"
  m="$TMP/vc.PAREN.sh"
  if mk_mut "teeth: paren" "$SUT" "$m" 's/if (d == 0) { bd = "close"; break } d--/d--/'; then
    tt "teeth: no-')'-boundary mutant stops binding Block 3 in the paren case" 1 1 "$m" --orig "$SUT" \
      --good-has 'B30 corrects \[Block 3\] ' --bad-lacks 'B30 corrects \[Block 3\] ' -- bash @SUT@ "$TMP/paren"
  fi

  echo "-- teeth: stop joining wrapped lines; the wrapped-forward case must lose its finding --"
  m="$TMP/vc.JOIN.sh"
  if mk_mut "teeth: join" "$SUT" "$m" 's/u = (u == "") ? line : u " " line/flush(); u = line/'; then
    tt "teeth: per-line mutant misses the verb/ref split across two lines" 1 0 "$m" --orig "$SUT" \
      --good-has 'B31 corrects \[Block 8\] ' --bad-lacks 'B31 corrects \[Block 8\] ' -- bash @SUT@ "$TMP/wrapfwd"
  fi

  echo "-- teeth: drop the bullet split; bullet 2's [Block 12] must become a false target --"
  m="$TMP/vc.BULLET.sh"
  if mk_mut "teeth: bullet" "$SUT" "$m" '/0-9\]+\[\.)\]/d'; then
    tt "teeth: no-bullet-split mutant binds the NEXT bullet's [Block 12]" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'B33 corrects \[Block 12\]' --bad-has 'B33 corrects \[Block 12\]' -- bash @SUT@ "$TMP/edges"
  fi

  echo "-- teeth: drop the paragraph (blank-line) split; next paragraph's ref must become a target --"
  m="$TMP/vc.PARA.sh"
  if mk_mut "teeth: para" "$SUT" "$m" 's/if (line ~ \/\^\[ \\t\]\*\$\/) { flush(); next }/if (line ~ \/^[ \\t]*$\/) { next }/'; then
    tt "teeth: no-blank-split mutant binds across the paragraph break" 0 1 "$m" --orig "$SUT" \
      --bad-has 'B35 corrects \[Block 8\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/para"
  fi

  echo "-- teeth: drop the conjunction boundary; ', and … [Block 5]' must become a false target --"
  m="$TMP/vc.CONJ.sh"
  if mk_mut "teeth: conj" "$SUT" "$m" '/else if (c == "," \&\&/d'; then
    tt "teeth: no-conjunction mutant binds Block 5" 0 1 "$m" --orig "$SUT" \
      --bad-has 'B36 corrects \[Block 5\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/conj"
  fi

  echo "-- teeth: drop the sentence boundary; the next sentence's ref must become a false target --"
  m="$TMP/vc.SENT.sh"
  if mk_mut "teeth: sentence" "$SUT" "$m" '/else if (c == "\." \&\&/d'; then
    tt "teeth: no-sentence-boundary mutant binds Block 52" 0 1 "$m" --orig "$SUT" \
      --bad-has 'B37 corrects \[Block 52\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/sent"
  fi

  echo "-- teeth: drop the bare-B suppressor; the later bracket must become a false target --"
  m="$TMP/vc.BARE.sh"
  if mk_mut "teeth: bare" "$SUT" "$m" 's/if (bn != "" \&\& (r == "" || BP < rs)) {/if (0) {/'; then
    tt "teeth: no-suppressor mutant binds [Block 34] behind 'B67'" 0 1 "$m" --orig "$SUT" \
      --bad-has 'B38 corrects \[Block 34\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/bare"
  fi

  echo "-- teeth: ignore the extractor's exit status; the failing-awk case must read as clean --"
  m="$TMP/vc.RC.sh"
  if mk_mut "teeth: awk rc" "$SUT" "$m" 's/if ! _vc_out="$(_vc_extract "$f")"; then/_vc_out="$(_vc_extract "$f")"; if false; then/'; then
    tt "teeth: rc-ignoring mutant reports ok on a dead awk (exit 0)" 1 0 "$m" --orig "$SUT" \
      --good-has 'degraded: extractor' --bad-has 'ok +every declared' --bad-lacks "$CRASH" -- env PATH="$TMP/stubdir/bin:$PATH" bash @SUT@ "$TMP/degr"
  fi

  if [ -n "$GD" ] && [ -n "$UTF" ]; then
    echo "-- teeth: drop LC_ALL=C; under gawk + UTF-8 the '·' boundary must vanish --"
    m="$TMP/vc.LOCALE.sh"
    if mk_mut "teeth: locale" "$SUT" "$m" 's/LC_ALL=C awk /awk /' 's/\\200-\\377//g'; then
      tt "teeth: locale-dependent mutant binds across the '·' (exit 1)" 0 1 "$m" --orig "$SUT" \
        --bad-has 'B40 corrects \[Block 8\] ' --bad-lacks "$CRASH" -- env LC_ALL="$UTF" PATH="$GD:$PATH" bash @SUT@ "$TMP/dot"
    fi
  else echo "  SKIP  locale tooth needs gawk and a UTF-8 locale"; fi

  echo "-- teeth: neuter the abbreviation list and the initial rule; 'e.g.' must end the clause --"
  m="$TMP/vc.ABBR.sh"
  if mk_mut "teeth: abbrev" "$SUT" "$m" 's/ab = " cf [^"]*"/ab = " "/' 's/return (tok ~ \/^\[a-z\]\$\/) || /return /'; then
    printf '# Block 41\n\n> This corrects the e.g. framing in [Block 8].\n' > "$TMP/abbr/t-block41.md"
    tt "teeth: no-abbreviation mutant ends the clause at 'e.g.' (loses the finding)" 1 0 "$m" --orig "$SUT" \
      --good-has 'B41 corrects \[Block 8\] ' --bad-lacks "B41 corrects|$CRASH" -- bash @SUT@ "$TMP/abbr"
  fi

  echo "-- teeth (#1835): resolve the target by number alone (last-wins across prefixes); the colliding focus must be checked --"
  m="$TMP/vc.PREFIX.sh"
  if mk_mut "teeth: prefix scope" "$SUT" "$m" 's#tgt="${numfile\["$_vc_own|$n"\]:-}"#tgt="${numany[$n]:-}"#'; then
    tt "teeth: number-only mutant checks zz-block1 for aa's B4 (false FAIL)" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B4 corrects \[Block 1\] but zz-block1' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/pfx-aa"
  fi
  # ORDER-INDEPENDENCE: a last-wins mutant only bites when the colliding prefix sorts AFTER the own one (pfx-aa); a
  # first-wins mutant only bites when it sorts BEFORE (pfx-zz). Both directions are pinned, so the prefix tooth cannot
  # pass on iteration order alone.
  m="$TMP/vc.PREFIX1.sh"
  if mk_mut "teeth: prefix scope (first-wins)" "$SUT" "$m" 's#tgt="${numfile\["$_vc_own|$n"\]:-}"#tgt="${numany[$n]:-}"#' \
       's#numany\["$_vc_n"\]="$f"#[ -n "${numany[$_vc_n]:-}" ] || numany["$_vc_n"]="$f"#'; then
    tt "teeth: first-wins number-only mutant checks aa-block1 for zz's B4 (false FAIL)" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B4 corrects \[Block 1\] but aa-block1' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/pfx-zz"
  fi

  echo "-- teeth (#1835 round 2): corrigendum+preposition must stay a declaration; '/' and '+' must not join targets --"
  m="$TMP/vc.CGDECL.sh"
  if mk_mut "teeth: corrigendum declaration" "$SUT" "$m" 's/^          isnoun = 1; rest = substr(l, ve)$/          isnoun = 1; rest = substr(l, ve); p = ve; continue/'; then
    tt "teeth: always-noun mutant loses 'CORRIGENDUM … of [Block 32]'" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B107 corrects \[Block 32\] ' --bad-lacks 'B107 corrects|awk: ' -- bash @SUT@ "$TMP/cg"
  fi
  m="$TMP/vc.PLUS.sh"
  if mk_mut "teeth: plus joiner" "$SUT" "$m" 's#(and|y|e|&|.\{2\})#(and|y|e|\&|\\/|\\+)#'; then
    tt "teeth: plus-joiner mutant binds [Block 2] behind '[Block 1] +'" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'B80 corrects \[Block 2\]' --bad-has 'B80 corrects \[Block 2\]' --bad-lacks 'awk: ' -- bash @SUT@ "$TMP/join-neg"
  fi
  m="$TMP/vc.COMMA.sh"
  if mk_mut "teeth: comma-only list" "$SUT" "$m" 's#(and|y|e|&|.\{2\})\[#(and|y|e|\&|\\/)?[#'; then
    tt "teeth: connector-optional mutant joins '[Block 3], [Block 2]' (comma-only list)" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'B82 corrects \[Block 2\]' --bad-has 'B82 corrects \[Block 2\]' --bad-lacks 'awk: ' -- bash @SUT@ "$TMP/join-neg"
  fi

  echo "-- teeth (#1835): shrink the backlink vocabulary back to corrected|corregido --"
  m="$TMP/vc.VOCAB.sh"
  vd="$TMP/vocabfix"; pmk "$vd" t 82 '# Block 82\n\n> Corrects [Block 21].\n'; pmk "$vd" t 21 '# Block 21\n\nOriginal.\n\n> CORRIGENDUM [Bloque 82]\n'
  if mk_mut "teeth: vocabulary" "$SUT" "$m" "s/^_vc_backlink_re=.*/_vc_backlink_re='corrected|corregido'/"; then
    tt "teeth: narrow-vocabulary mutant rejects the CORRIGENDUM backlink (false FAIL)" 0 1 "$m" --orig "$SUT" \
      --bad-has 'FAIL +B82 corrects \[Block 21\]' --bad-lacks "$CRASH" -- bash @SUT@ "$vd"
  fi

  echo "-- teeth (#1835): keep only the first ref of a clause; the second joined target must vanish --"
  m="$TMP/vc.MULTI.sh"
  if mk_mut "teeth: multi-target" "$SUT" "$m" 's/^          more(cl); done = 1; qcur = ""; qkind = ""$/          done = 1/'; then
    tt "teeth: first-ref-only mutant drops [Block 5] from '[Block 6] … and [Block 5]'" 1 1 "$m" --orig "$SUT" \
      --good-has 'B60 corrects \[Block 5\] ' --bad-has 'B60 corrects \[Block 6\] ' --bad-lacks 'B60 corrects \[Block 5\] |awk: ' -- bash @SUT@ "$TMP/multi-and"
  fi
  echo "-- teeth (#1835): drop the connector gate; prose-separated refs must become false targets --"
  m="$TMP/vc.MULTIGATE.sh"
  if mk_mut "teeth: connector gate" "$SUT" "$m" 's/if (g !~ \/\^.*\/) return/if (0) return/'; then
    tt "teeth: ungated mutant binds [Block 7] behind 'and independently notes'" 1 1 "$m" --orig "$SUT" \
      --good-lacks 'B63 corrects \[Block 7\]' --bad-has 'B63 corrects \[Block 7\]' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/multi-neg"
  fi

  echo "-- teeth (#1835): drop the passive guard; 'Se corrige [Block 8]' / 'si no se corrige' must declare --"
  m="$TMP/vc.PASSIVE.sh"
  if mk_mut "teeth: passive" "$SUT" "$m" 's/pre ~ \/(^|\[^a-z0-9_\\200-\\377\])se\[ \\t\]+\$\/ || //'; then
    tt "teeth: no-passive-guard mutant treats 'se corrige' as a declaration" 0 1 "$m" --orig "$SUT" \
      --good-has 'note +1 correction verb\(s\) in a non-assertive' --bad-has 'B70 corrects \[Block 8\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/na1"
    tt "teeth: no-passive-guard mutant treats 'si no se corrige' as a declaration" 0 1 "$m" --orig "$SUT" \
      --bad-has 'B70 corrects \[Block 8\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/na2"
  fi
  echo "-- teeth (#1835): drop the past-tense guard; 'corrigió' / 'corrigieron' must declare --"
  m="$TMP/vc.PAST.sh"
  if mk_mut "teeth: past tense" "$SUT" "$m" 's/ || tok == "corrigieron" || tok == "corrigio" || past) {/) {/'; then
    tt "teeth: no-past-guard mutant treats 'corrigió' as a declaration" 0 1 "$m" --orig "$SUT" \
      --bad-has 'B70 corrects \[Block 8\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/na3"
    tt "teeth: no-past-guard mutant treats 'corrigieron' as a declaration" 0 1 "$m" --orig "$SUT" \
      --bad-has 'B70 corrects \[Block 8\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/na4"
  fi
  echo "-- teeth (round 3): list edges, corrigendum never silent, two-ref corrigendum, upper-case Ó, ok-partial --"
  m="$TMP/vc.WHILE.sh"
  if mk_mut "teeth: while to if" "$SUT" "$m" '/function more(cl/,/^    }/ s/while (match(rest, /if (match(rest, /'; then
    tt "teeth: single-step list mutant keeps only 2 targets (loses [Block 3] of a 3-list)" 1 1 "$m" --orig "$SUT" \
      --good-has 'B64 corrects \[Block 3\] ' --bad-has 'B64 corrects \[Block 2\] ' --bad-lacks 'B64 corrects \[Block 3\] |awk: ' -- bash @SUT@ "$TMP/multi-3"
  fi
  m="$TMP/vc.CGDROP.sh"
  if mk_mut "teeth: corrigendum silent drop" "$SUT" "$m" 's/^          isnoun = 1; rest = substr(l, ve)$/          isnoun = 1; rest = substr(l, ve); p = ve; continue/'; then
    tt "teeth: silent-drop mutant loses 'CORRIGENDUM (to [Block 8])' (exit 1 to 0)" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B90 corrects \[Block 8\] ' --bad-lacks 'B90 corrects|awk: ' -- bash @SUT@ "$TMP/cgd"
    tt "teeth: silent-drop mutant omits the unbound note for a ref-less corrigendum" 0 0 "$m" --orig "$SUT" \
      --good-has 'note +1 correction verb' --bad-lacks 'note +1 correction verb|awk: ' -- bash @SUT@ "$TMP/cgd-unb"
  fi
  m="$TMP/vc.NOUNSCAN.sh"
  if mk_mut "teeth: noun clause scan" "$SUT" "$m" '/else if ((nd = noundecl(rest)) == 2)/d' '/else if (!nd) { print "U"/d'; then
    tt "teeth: noun-clause-scan mutant turns 'Corrigendum (see [Block 33])' into a false B8→33 FAIL" 0 1 "$m" --orig "$SUT" \
      --good-has 'note +1 correction verb' --bad-has 'FAIL +B8 corrects \[Block 33\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/cgn1"
    tt "teeth: noun-clause-scan mutant turns 'No corrigendum was needed for [Block 12]' into a false FAIL" 0 1 "$m" --orig "$SUT" \
      --good-has 'note +1 correction verb' --bad-has 'FAIL +B90 corrects \[Block 12\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/cgn6"
  fi
  m="$TMP/vc.CGTWO.sh"
  if mk_mut "teeth: corrigendum two refs" "$SUT" "$m" 's/ve += rl$/ve += 0/'; then
    tt "teeth: tag-skip mutant binds [Bloque 33] instead of 32" 1 1 "$m" --orig "$SUT" \
      --good-has 'B92 corrects \[Block 32\] ' --bad-has 'B92 corrects \[Block 33\]' --bad-lacks 'B92 corrects \[Block 32\] |awk: ' -- bash @SUT@ "$TMP/cgd-two"
  fi
  m="$TMP/vc.UPPERO.sh"
  if mk_mut "teeth: upper O acute" "$SUT" "$m" 's/ || substr(l, ve, 2) == "\\303\\223"//'; then
    # Since #1847 an unrecognised accented form is surfaced as unbound (exit 0), no longer bound as a verb: the tooth bites
    # on the missing non-assertive count instead of a FAIL.
    tt "teeth: lower-only mutant stops counting 'CORRIGIÓ' as past tense" 0 0 "$m" --orig "$SUT" \
      --good-has 'note +2 correction verb\(s\) in a non-assertive form' --bad-lacks 'note +2 correction verb\(s\) in a non-assertive form|awk: ' -- bash @SUT@ "$TMP/upper"
  fi
  m="$TMP/vc.PARTIAL.sh"
  if mk_mut "teeth: ok-partial" "$SUT" "$m" 's/unchecked=$((unchecked+1))/:/'; then
    tt "teeth: no-counter mutant prints the plain ok after an ambiguous WARN" 0 0 "$m" --orig "$SUT" \
      --good-has 'ok-partial' --good-lacks 'ok +every declared' --bad-has 'ok +every declared' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/pfx-amb"
    tt "teeth: no-counter mutant prints the plain ok after a missing-file WARN" 0 0 "$m" --orig "$SUT" \
      --good-has 'ok-partial' --bad-has 'ok +every declared' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/missing"
  fi

  echo "-- teeth (#1835): drop the noun exclusion; a 'CORRIGENDUM [Bloque 90]' line must become a declaration --"
  m="$TMP/vc.NOUN.sh"
  if mk_mut "teeth: corrigendum noun" "$SUT" "$m" 's/if (tok ~ \/^corrigend\/) {/if (0) {/'; then
    tt "teeth: no-noun-guard mutant reads the backlink line as B21→B90" 0 1 "$m" --orig "$SUT" \
      --bad-has 'B21 corrects \[Block 90\]' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/vocab-noun"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
