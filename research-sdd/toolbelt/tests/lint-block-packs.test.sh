#!/usr/bin/env bash
# lint-block-packs.test.sh — suite for the PYTHON rule packs behind `lint-block --pack NAME` (kit issue #1365 item 1).
#
# The generic core (R0 R3 R6, listing, typed states) was ported to Go (`rsdd lint block`, kit issue #2392) and is
# covered by the Go tests in research-sdd/rsdd/internal/lint. The packs (jvm, multi-version, native-binary,
# child-gap) are still Python until U3.2 (kit issue #2393), and `--pack` runs are handed to lint_block.py, so their
# rules, loader and mutation controls stay here. This suite drives the frozen pre-port wrapper (kept as the Go
# differential's legacy copy) against the live lint_block.py + packs, so it needs no Go toolchain. U3.2 replaces this
# whole file with Go tests.
#
# Fixtures are synthetic (tests/fixtures/lint-block/) — never copied client content.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
HELPER="$TOOLBELT/lint_block.py"
LEGACY="$HERE/../../rsdd/internal/lint/testdata/legacy"
FX="$HERE/fixtures/lint-block"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== lint-block-packs.test.sh =="

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
[ -f "$LEGACY/lint-block.sh" ] || { echo "FATAL: absent-input: frozen wrapper $LEGACY/lint-block.sh" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The engine under test: the frozen wrapper next to the live helper, packs and lib (what lint-block.sh was before the port).
ENG="$TMP/engine"; mkdir -p "$ENG/lib"
cp "$LEGACY/lint-block.sh" "$HELPER" "$ENG/"; cp "$TOOLBELT/lib/block-files.sh" "$ENG/lib/"; cp -r "$TOOLBELT/lint-block-packs" "$ENG/"   # stage-libs-ok: the frozen legacy wrapper sources only lib/block-files.sh, staged beside the frozen engine
chmod +x "$ENG/lint-block.sh"
SUT="$ENG/lint-block.sh"

# lines_of TAG FILE -> sorted, space-joined line numbers whose text contains TAG
lines_of() { grep -nF -- "$1" "$2" | cut -d: -f1 | sort -n | tr '\n' ' ' | sed 's/ $//'; }
# reported RULE OUTPUT FILE -> sorted, space-joined line numbers reported for RULE in FILE
reported() { printf '%s\n' "$2" | grep -E "^$1 .*/$(basename "$3"):[0-9]+:" | sed -E 's/^[^:]*[^ ]*\/[^/:]*:([0-9]+):.*/\1/' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
run() { OUT="$(bash "$SUT" "$@" 2>&1)"; RC=$?; }

LAST_CASE_NUM="$(grep -oE '^# [0-9]+\. ' "$0" | tr -dc '0-9\n' | sort -n | tail -1)"
if [ -z "$LAST_CASE_NUM" ]; then echo "harness error: no '# <N>. ' case headings in $0" >&2; exit 2; fi

# 18. Slice 3 (kit #1365 item 1): the --pack loader. Packs are OPT-IN; without --pack the run is the generic core only.
run "$FX/pack-jvm.md"
if grep -qE '^R0 ' <<< "$OUT" && [ -z "$(reported R1 "$OUT" "$FX/pack-jvm.md")" ] && [ -z "$(reported R5 "$OUT" "$FX/pack-jvm.md")" ] \
   && [ -z "$(reported R7 "$OUT" "$FX/pack-jvm.md")" ] && ! grep -qF 'packs=' <<< "$OUT" && ! grep -qE 'R[157]=' <<< "$OUT"; then
  ok "18a no --pack: pack rules R1/R5/R7 are not enforced and the SUMMARY carries no pack fields (core output unchanged)"
else no "18a no-pack baseline (rc=$RC out=[$OUT])"; fi
run --pack nosuch "$FX/pack-jvm.md"
[ "$RC" -eq 2 ] && grep -qF 'unknown pack nosuch' <<< "$OUT" && grep -qF 'jvm' <<< "$OUT" && grep -qF 'multi-version' <<< "$OUT" && grep -qF 'native-binary' <<< "$OUT" \
  && ok "18b unknown pack -> exit 2 naming the available packs (never a silent core-only run)" || no "18b unknown pack (rc=$RC out=[$OUT])"
run --pack "Bad_Name" "$FX/pack-jvm.md"; [ "$RC" -eq 2 ] && grep -qF 'invalid pack name' <<< "$OUT" && ok "18c --pack with a path-like name -> exit 2 'invalid pack name'" || no "18c pack operand (rc=$RC out=[$OUT])"
run "$FX/pack-jvm.md" --pack; [ "$RC" -eq 2 ] && grep -qF -- '--pack needs a name' <<< "$OUT" && ok "18d --pack with no operand -> exit 2" || no "18d no operand (rc=$RC out=[$OUT])"
for emp in "" "," ",,"; do
  run --audit --pack "$emp" "$FX/pack-single.md"
  [ "$RC" -eq 2 ] && grep -qF -- '--pack needs a name' <<< "$OUT" && ! grep -qF 'SUMMARY' <<< "$OUT" && ok "18n empty pack list ('$emp') -> exit 2, nothing linted" || no "18n empty pack list '$emp' (rc=$RC out=[$OUT])"
  run --audit "--pack=$emp" "$FX/pack-single.md"
  [ "$RC" -eq 2 ] && ! grep -qF 'SUMMARY' <<< "$OUT" && ok "18n --pack=$emp form -> exit 2, nothing linted" || no "18n --pack=$emp (rc=$RC out=[$OUT])"
done
run --pack ../x "$FX/pack-jvm.md"; [ "$RC" -eq 2 ] && grep -qF 'invalid pack name' <<< "$OUT" && ok "18e path traversal in a pack name is refused (exit 2)" || no "18e traversal (rc=$RC out=[$OUT])"
run --audit --pack jvm,multi-version --pack=native-binary --pack jvm "$FX/pack-single.md"
if [ "$RC" -eq 0 ] && grep -qF 'packs=jvm,multi-version,native-binary ' <<< "$OUT"; then
  ok "18f comma list, --pack=NAME form and a repeated pack all load; each pack loads once (packs=jvm,multi-version,native-binary)"
else no "18f forms (rc=$RC out=[$OUT])"; fi
mkdir -p "$TMP/pk-crash" "$TMP/pk-ok" "$TMP/pk-nobuild" "$TMP/pk-syntax" "$TMP/pk-norules" "$TMP/pk-collide" "$TMP/pk-badid" "$TMP/pk-raise"
printf 'def build(api):\n    return [("R1", lambda doc: [(1, "R1", "synthetic")])]\n' > "$TMP/pk-ok/demo.py"
printf 'X = 1\n' > "$TMP/pk-nobuild/demo.py"
printf 'def build(api:\n' > "$TMP/pk-syntax/demo.py"
printf 'def build(api):\n    return []\n' > "$TMP/pk-norules/demo.py"
printf 'def build(api):\n    return [("R3", lambda doc: [])]\n' > "$TMP/pk-collide/demo.py"
printf 'def build(api):\n    return [("R42", lambda doc: [])]\n' > "$TMP/pk-badid/demo.py"
printf 'def build(api):\n    raise RuntimeError("boom")\n' > "$TMP/pk-raise/demo.py"
LINT_BLOCK_PACKS_DIR="$TMP/pk-ok" run --pack demo "$FX/pack-single.md"
[ "$RC" -eq 1 ] && grep -qE '^R1 .*pack-single.md:1: synthetic' <<< "$OUT" && grep -qF 'packs=demo' <<< "$OUT" \
  && ok "18g LINT_BLOCK_PACKS_DIR selects the pack directory; a pack rule registers and fires (FAIL mode exit 1)" || no "18g custom pack dir (rc=$RC out=[$OUT])"
for bad in nobuild:'defines no build' syntax:'failed to load' norules:'registered no rules' collide:'already active' badid:'not a reserved pack rule id' raise:'failed to load'; do
  d="${bad%%:*}"; want="${bad#*:}"
  LINT_BLOCK_PACKS_DIR="$TMP/pk-$d" run --audit --pack demo "$FX/pack-single.md"
  if [ "$RC" -eq 2 ] && grep -qF -- "$want" <<< "$OUT" && ! grep -qF 'SUMMARY' <<< "$OUT"; then ok "18h broken pack ($d) -> exit 2 '$want', nothing linted (no SUMMARY, never a clean zero)"
  else no "18h broken pack $d (rc=$RC out=[$OUT])"; fi
done
LINT_BLOCK_PACKS_DIR="$TMP/no-such-dir" run --audit --pack demo "$FX/pack-single.md"
[ "$RC" -eq 2 ] && grep -qF 'DEGRADED' <<< "$OUT" && ok "18i absent packs directory -> DEGRADED, exit 2" || no "18i absent dir (rc=$RC out=[$OUT])"
printf 'def build(api):\n    def boom(doc):\n        raise RuntimeError("boom")\n    return [("R1", boom)]\n' > "$TMP/pk-crash/demo.py"
LINT_BLOCK_PACKS_DIR="$TMP/pk-crash" run --audit --pack demo "$FX/pack-single.md"
[ "$RC" -eq 2 ] && grep -qF 'RULE-CRASH' <<< "$OUT" && grep -qF 'crashed=1' <<< "$OUT" && ok "18l a pack rule that raises -> RULE-CRASH on stderr, crashed=1 in SUMMARY and exit 2 (never exit 1 = findings, never a clean zero)" || no "18l rule crash (rc=$RC out=[$OUT])"
run --audit --pack nosuch "$FX/corpus-empty"
[ "$RC" -eq 2 ] && grep -qF 'unknown pack nosuch' <<< "$OUT" && ok "18m a bad pack fails even when the corpus is empty (packs validated before any listing)" || no "18m bad pack + empty corpus (rc=$RC out=[$OUT])"
run --pack jvm "$FX/pack-single.md"
[ "$RC" -eq 1 ] && ok "18j pack finding in FAIL mode exits 1" || no "18j pack FAIL exit (rc=$RC out=[$OUT])"
run --audit --pack jvm "$FX/pack-single.md"
[ "$RC" -eq 0 ] && grep -qF 'R1=1' <<< "$OUT" && ok "18k --audit with a pack finding stays report-only (exit 0, R1=1)" || no "18k pack audit (rc=$RC out=[$OUT])"

# 19. JVM pack: R1 syntax adoption / R5 permission dispatch / R7 constant inlining
run --pack jvm "$FX/pack-jvm.md"
want="$(lines_of R1- "$FX/pack-jvm.md")"; got="$(reported R1 "$OUT" "$FX/pack-jvm.md")"
[ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] && ok "19a R1 flagged on the exact lines ($want): first line, list item, claim in a later clause than the evidence, reason-less waiver; javap evidence, no-verb, valid waiver and fence clear" || no "19a R1 (rc=$RC want=[$want] got=[$got] out=[$OUT])"
want="$(lines_of R5- "$FX/pack-jvm.md")"; got="$(reported R5 "$OUT" "$FX/pack-jvm.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "19b R5 flagged on the exact lines ($want): table row and paragraph; dispatch: clause and non-permission 'bypass' clear" || no "19b R5 (want=[$want] got=[$got])"
want="$(lines_of R7- "$FX/pack-jvm.md")"; got="$(reported R7 "$OUT" "$FX/pack-jvm.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "19c R7 flagged on the exact lines ($want) incl. the last line without a trailing newline; compile-time-constant evidence, valid waiver, wrong-rule waiver (still flagged) and fence handled" || no "19c R7 (want=[$want] got=[$got])"
want="$(lines_of R1-NOREASON "$FX/pack-jvm.md")"
[ "$(reported R0 "$OUT" "$FX/pack-jvm.md")" = "$want" ] && ok "19d a reason-less R1 waiver is R0 AND the R1 finding still fires (fail closed)" || no "19d reason-less pack waiver (out=[$OUT])"
if grep -qF 'packs=jvm ' <<< "$OUT" && grep -qE 'r1-triggers=6( |$)' <<< "$OUT" && grep -qE 'r5-triggers=3( |$)' <<< "$OUT" && grep -qE 'r7-triggers=5( |$)' <<< "$OUT" && ! grep -qF 'inactive-waivers=1' <<< "$OUT"; then
  ok "19e SUMMARY proves what each rule looked at (packs=jvm r1-triggers=6 r5-triggers=3 r7-triggers=5); waivers for now-active ids are not 'inactive'"
else no "19e jvm coverage (out=[$OUT])"; fi
run --pack jvm "$FX/pack-single.md"
[ "$RC" -eq 1 ] && [ "$(reported R1 "$OUT" "$FX/pack-single.md")" = "1" ] && ok "19f R1 on a single-line file without a trailing newline flagged at line 1" || no "19f single (rc=$RC out=[$OUT])"
run --audit --pack jvm "$FX/pack-r8.md"
if [ "$RC" -eq 0 ] && [ -z "$(reported R8 "$OUT" "$FX/pack-r8.md")" ] && grep -qE '^INFO .*waiver for inactive pack rule R8' <<< "$OUT" && grep -qF 'inactive-waivers=1' <<< "$OUT"; then
  ok "19g a pack enforces only ITS rules: R8 text under --pack jvm is not an R8 finding and its R8 waiver stays INFO (inactive)"
else no "19g pack isolation (rc=$RC out=[$OUT])"; fi

# 20. Multi-version pack: R8 baseline attribution
run --pack multi-version "$FX/pack-r8.md"
want="$(lines_of R8- "$FX/pack-r8.md")"; got="$(reported R8 "$OUT" "$FX/pack-r8.md")"
[ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] && ok "20a R8 flagged on the exact lines ($want): item, claim after its baseline clause, 'absent from N4', singular 'class', table row, last line; 4.15/PowerB baseline, no-surface and valid waiver clear" || no "20a R8 (rc=$RC want=[$want] got=[$got] out=[$OUT])"
grep -qE 'r8-triggers=8( |$)' <<< "$OUT" && grep -qF 'packs=multi-version' <<< "$OUT" && ok "20b SUMMARY names the pack and its trigger count (r8-triggers=8)" || no "20b r8 coverage (out=[$OUT])"

# 21. Native-binary pack: R9 sha256 + address anchor + two instruments
run --pack native-binary "$FX/pack-r9.md"
want="$(lines_of R9- "$FX/pack-r9.md")"; got="$(reported R9 "$OUT" "$FX/pack-r9.md")"
[ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] && ok "21a R9 flagged on the exact lines ($want): nothing cited, one instrument, no anchor, no sha256 only, rule id R2 is not an instrument, plain-prose 'nm' (not an instrument), table row; complete claim, \`nm\` in a code span, [CERT-doc], no marker, .sys package, waiver clear" || no "21a R9 (rc=$RC want=[$want] got=[$got] out=[$OUT])"
grep -qE 'r9-triggers=11( |$)' <<< "$OUT" && ok "21b SUMMARY names the pack and its trigger count (r9-triggers=11)" || no "21b r9 coverage (out=[$OUT])"
grep -qE '^R9 .*pack-r9.md:[0-9]+: native-binary claim: no sha256' <<< "$OUT" && grep -qE 'no address anchor' <<< "$OUT" && grep -qE '1 of 2 instruments' <<< "$OUT" && ok "21c each R9 finding names WHICH requirement is missing" || no "21c r9 messages (out=[$OUT])"

# 22. Review advisories (kit #1517): CFR is a decompiler, not clearing evidence; pack-shape guard; R5/R8/R9 regex hygiene
run --pack jvm "$FX/pack-adv-jvm.md"
want="$(lines_of ADV-R1-BAD "$FX/pack-adv-jvm.md")"; got="$(reported R1 "$OUT" "$FX/pack-adv-jvm.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "22a R1: 'CFR output' does not clear an adoption claim (a decompiler resugars; only javap/bytecode/docSource do) ($want)" || no "22a CFR (want=[$want] got=[$got])"
want="$(lines_of ADV-R5-BAD "$FX/pack-adv-jvm.md")"; got="$(reported R5 "$OUT" "$FX/pack-adv-jvm.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "22b R5: lower-case ordinary word 'context' is not permission scope; a bare capitalised 'Context' (no 'null') and a bare lower-case 'cx' are, while upper-case 'CX' is not ($want)" || no "22b R5 context case (want=[$want] got=[$got])"
run --pack multi-version "$FX/pack-adv-r8.md"
want="$(lines_of ADV-R8-BAD "$FX/pack-adv-r8.md")"; got="$(reported R8 "$OUT" "$FX/pack-adv-r8.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "22c R8: '14.15' and '4.150' are not a 4.15 baseline; 4.15, N4.15 and PowerB still clear ($want)" || no "22c R8 baseline boundary (want=[$want] got=[$got])"
run --pack native-binary "$FX/pack-adv-r9.md"
want="$(lines_of ADV-R9-BAD "$FX/pack-adv-r9.md")"; got="$(reported R9 "$OUT" "$FX/pack-adv-r9.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "22d R9: 'offset decade' (an English word made of hex letters) is not an address anchor; 'offset 1a2b3c' and 'RVA: dead1' still are ($want)" || no "22d R9 anchor hexword (want=[$want] got=[$got])"
mkdir -p "$TMP/pk-shape"
printf 'def build(api):\n    return [("R1",)]\n' > "$TMP/pk-shape/demo.py"
LINT_BLOCK_PACKS_DIR="$TMP/pk-shape" run --audit --pack demo "$FX/pack-single.md"
if [ "$RC" -eq 2 ] && grep -qF 'malformed rule' <<< "$OUT" && ! grep -qF 'Traceback' <<< "$OUT" && ! grep -qF 'SUMMARY' <<< "$OUT"; then ok "22e a pack rule that is not a (rule_id, callable) pair -> exit 2 'malformed rule', no traceback, nothing linted"
else no "22e pack shape guard (rc=$RC out=[$OUT])"; fi
mkdir -p "$TMP/pk-gen" "$TMP/pk-noniter" "$TMP/pk-listpair"
printf 'def build(api):\n    yield ("R1", lambda doc: [(1, "R1", "synthetic")])\n' > "$TMP/pk-gen/demo.py"
printf 'def build(api):\n    return None\n' > "$TMP/pk-noniter/demo.py"
printf 'def build(api):\n    return [["R1", lambda doc: [(1, "R1", "synthetic")]]]\n' > "$TMP/pk-listpair/demo.py"
LINT_BLOCK_PACKS_DIR="$TMP/pk-gen" run --pack demo "$FX/pack-single.md"
[ "$RC" -eq 1 ] && grep -qE '^R1 .*pack-single.md:1: synthetic' <<< "$OUT" && ok "22f a generator-returning build() registers its rules and fires" || no "22f generator pack (rc=$RC out=[$OUT])"
LINT_BLOCK_PACKS_DIR="$TMP/pk-listpair" run --pack demo "$FX/pack-single.md"
[ "$RC" -eq 1 ] && grep -qE '^R1 .*pack-single.md:1: synthetic' <<< "$OUT" && ok "22g a [rule_id, callable] list pair is accepted like a tuple" || no "22g list pair (rc=$RC out=[$OUT])"
LINT_BLOCK_PACKS_DIR="$TMP/pk-noniter" run --audit --pack demo "$FX/pack-single.md"
[ "$RC" -eq 2 ] && grep -qF 'failed to load' <<< "$OUT" && ! grep -qF 'Traceback' <<< "$OUT" && ! grep -qF 'SUMMARY' <<< "$OUT" && ok "22h a non-iterable build() return -> exit 2, nothing linted" || no "22h non-iterable (rc=$RC out=[$OUT])"

# 23. R5 (kit #1548 / #1607): quoted gap text is skipped; an inline cited-absence form clears
run --pack jvm "$FX/pack-r5-quote.md"
want="$(grep -nE 'R5Q-[A-Z-]*BAD' "$FX/pack-r5-quote.md" | cut -d: -f1 | sort -n | tr '\n' ' ' | sed 's/ $//')"; got="$(reported R5 "$OUT" "$FX/pack-r5-quote.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "23a R5: unit made only of '>' blockquote lines (gap-text restatement) is skipped; a mixed quoted/unquoted unit, plain prose and a clause without cited absence still flag; an inline cited-absence clears ($want)" || no "23a R5 blockquote / cited-absence (want=[$want] got=[$got])"
grep -qE 'r5-quoted-skipped=3( |$)' <<< "$OUT" && ok "23b SUMMARY proves the skip (r5-quoted-skipped=3): only the two gap-referencing quoted units were skipped; a block's own '> Finding:' callout, empty / placeholder cited-absence and dispatch clauses still flag" || no "23b r5-quoted-skipped (out=[$OUT])"
run --pack jvm "$FX/pack-single.md"
grep -qE 'r5-quoted-skipped=0( |$)' <<< "$OUT" && ok "23c the skip counter is printed even when it is 0 (a bare absence cannot be read as 'looked, none')" || no "23c zero counter (out=[$OUT])"

# 24. Calibration (kit #1548): R1 prose false positives, R5 'auth' breadth, R8 negation/question, R9 heading-only units
run --pack jvm "$FX/pack-cal-jvm.md"
want="$(lines_of CAL-R1-BAD "$FX/pack-cal-jvm.md")"; got="$(reported R1 "$OUT" "$FX/pack-cal-jvm.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "24a R1: 'var-length', 'for each' and 'sealed envelope' (English prose) are not syntax-adoption features; \`var\`, the var keyword, sealed interfaces and for-each still are ($want)" || no "24a R1 prose false positives (want=[$want] got=[$got])"
want="$(lines_of CAL-R5-BAD "$FX/pack-cal-jvm.md")"; got="$(reported R5 "$OUT" "$FX/pack-cal-jvm.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "24b R5: 'authored' is not permission scope and the Access policy action name 'Bypass' is not a bypass finding; authentication, authorization, unauthenticated, deauthorize, OAuth, auth and authz, 'Bypass ... fails open', a lower-case verb 'bypass', a Bypass outside Access wording (items 25-29, 32-34) still are; a lone capitalised Bypass next to Access wording is the pinned residual trade-off (item 31) ($want)" || no "24b R5 auth breadth (want=[$want] got=[$got])"
run --pack multi-version "$FX/pack-cal-r8.md"
want="$(lines_of CAL-R8-BAD "$FX/pack-cal-r8.md")"; got="$(reported R8 "$OUT" "$FX/pack-cal-r8.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "24c R8: a negated ('not new in N5'), question ('Is ... N5-only?') or 'whether' clause is not an attribution claim; affirmative claims still flag ($want)" || no "24c R8 negation/question (want=[$want] got=[$got])"
run --pack native-binary "$FX/pack-cal-r9.md"
want="$(grep -nE 'CAL-R9-(HEADING-|ROW-|EMPTY-|PARENT-)?BAD' "$FX/pack-cal-r9.md" | cut -d: -f1 | sort -n | tr '\n' ' ' | sed 's/ $//')"; got="$(reported R9 "$OUT" "$FX/pack-cal-r9.md")"
[ "$got" = "$want" ] && [ -n "$want" ] && ok "24d R9: a heading claim is judged over its whole section: an evidence-less body and an empty body flag at the heading, an evidence-bearing body clears; paragraph and row claims still flag ($want)" || no "24d R9 heading-only (want=[$want] got=[$got])"
grep -qE 'r9-triggers=6( |$)' <<< "$OUT" && ok "24e SUMMARY counts the heading claims as R9 triggers (r9-triggers=6: 4 headings, 1 paragraph, 1 row)" || no "24e r9-triggers (out=[$OUT])"

# 25. Child-gap pack (kit #1214 / #1365): R4 coverage-check / measured-by at open time
run --pack child-gap "$FX/pack-r4.md"
want="$(lines_of R4- "$FX/pack-r4.md")"; got="$(reported R4 "$OUT" "$FX/pack-r4.md")"
[ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] && ok "25a R4 flagged on the exact lines ($want): first and last bullet, placeholder clause, query without result, empty arrow result, number without measured-by, stub measured-by; arrow and code-span forms, a 'none' result, a continuation-line clause, line refs / dates / versions, a prose clause, a waiver, a fenced bullet and a bullet outside the section clear" || no "25a R4 (rc=$RC want=[$want] got=[$got] out=[$OUT])"
grep -qE 'r4-triggers=14( |$)' <<< "$OUT" && grep -qF 'packs=child-gap' <<< "$OUT" && ok "25b SUMMARY names the pack and counts every bullet it inspected (r4-triggers=14)" || no "25b r4 coverage (out=[$OUT])"
grep -qE 'child gap B61-G1: ABSENT' <<< "$OUT" && grep -qE 'child gap B61-G4: MALFORMED .*placeholder' <<< "$OUT" && grep -qE 'child gap B61-G5: MALFORMED .*no result' <<< "$OUT" && grep -qE 'child gap B61-G8: MEASURE - states 247' <<< "$OUT" && grep -qE 'child gap B61-G9: MEASURE .*measured-by' <<< "$OUT" && ok "25c findings are typed ABSENT / MALFORMED / MEASURE and name the gap id" || no "25c typed messages (out=[$OUT])"
run --pack child-gap "$FX/pack-r4-single.md"
[ "$RC" -eq 1 ] && [ "$(reported R4 "$OUT" "$FX/pack-r4-single.md")" = "$(lines_of R4- "$FX/pack-r4-single.md")" ] && grep -qE 'r4-triggers=1( |$)' <<< "$OUT" && ok "25d a single-bullet section is judged (r4-triggers=1)" || no "25d single bullet (rc=$RC out=[$OUT])"
run --audit --pack child-gap "$FX/pack-r4-nosection.md"
[ "$RC" -eq 0 ] && grep -qE 'R4=0' <<< "$OUT" && grep -qE 'r4-triggers=0( |$)' <<< "$OUT" && grep -qF 'NO-MATCH' <<< "$OUT" && ok "25e no child-gap section -> no finding, and the SUMMARY says r4-triggers=0 (a typed zero, not a silent one)" || no "25e no section (rc=$RC out=[$OUT])"
run --pack jvm "$FX/pack-r4.md"
[ "$(reported R4 "$OUT" "$FX/pack-r4.md")" = "" ] && ok "25f without --pack child-gap R4 is not enforced (opt-in)" || no "25f opt-in (out=[$OUT])"

# 26. R4 section model (kit #1214 review): sub-headings, bold-line labels, excluded headings, r4-unscoped
run --pack child-gap "$FX/pack-r4-scope.md"
want="$(lines_of R4- "$FX/pack-r4-scope.md")"; got="$(reported R4 "$OUT" "$FX/pack-r4-scope.md")"
[ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] && ok "26a bullets under ### / #### sub-headings, under a bold-line 'Child gaps opened' label and after an excluded sub-heading are judged ($want); a heading-started section runs to the next same-or-higher heading" || no "26a R4 scope (rc=$RC want=[$want] got=[$got] out=[$OUT])"
grep -qE 'r4-triggers=5( |$)' <<< "$OUT" && grep -qE 'r4-unscoped=4( |$)' <<< "$OUT" && ok "26b SUMMARY counts 5 judged bullets and 4 gap bullets outside any judged section (next section, 'Closed child gaps', after a label section, 'Resolved child gaps' sub-heading)" || no "26b scope counters (out=[$OUT])"
run --audit --pack child-gap "$FX/pack-r4-nosection.md"
grep -qE 'r4-triggers=0 r4-unscoped=1( |$)' <<< "$OUT" && ok "26c a gap bullet under an unrecognised heading reads r4-triggers=0 r4-unscoped=1, never a silent clean" || no "26c unscoped (out=[$OUT])"
run --audit --pack jvm "$FX/pack-r4-scope.md"
grep -qE 'r4-unscoped' <<< "$OUT" && no "26d r4-unscoped printed without the child-gap pack (out=[$OUT])" || ok "26d without --pack child-gap the SUMMARY has no r4 fields"

# 27. R4 clause grammar (kit #1214 review): padded placeholders, trailing prose, decimals/units, result placeholders, nested clauses
run --pack child-gap "$FX/pack-r4-clause.md"
want="$(lines_of R4- "$FX/pack-r4-clause.md")"; got="$(reported R4 "$OUT" "$FX/pack-r4-clause.md")"
[ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] && ok "27a R4 clause grammar flags exactly ($want): padded placeholders, a number in trailing prose, trailing prose as the result, 12.5% / 2.5x / 3k, a figure inside [Block N, ...], pending / missing / tbd results, a nested placeholder; the ASCII arrow, a real prose clause, versions / refs, and nested clauses clear" || no "27a R4 clauses (rc=$RC want=[$want] got=[$got] out=[$OUT])"
grep -qE 'r4-triggers=18( |$)' <<< "$OUT" && grep -qE 'r4-unscoped=0( |$)' <<< "$OUT" && ok "27b SUMMARY counts the 18 bullets and no unscoped bullet" || no "27b clause counters (out=[$OUT])"
grep -qE 'child gap B65-G2: MALFORMED .*placeholder' <<< "$OUT" && grep -qE 'child gap B65-G5: MEASURE - states 247' <<< "$OUT" && grep -qE 'child gap B65-G6: MALFORMED .*no result' <<< "$OUT" && grep -qE 'child gap B65-G7: MEASURE - states 12.5%' <<< "$OUT" && grep -qE 'child gap B65-G9: MEASURE - states 3k' <<< "$OUT" && ok "27c messages name the state and the figure (247, 12.5%, 3k)" || no "27c messages (out=[$OUT])"

# 28. R4 round 2 (kit #1214 review): anchored heading exclusion, list-item label, setext end; ';' / digit-led clause ends (27a, 27c)
run --pack child-gap "$FX/pack-r4-scope2.md"
want="$(lines_of R4- "$FX/pack-r4-scope2.md")"; got="$(reported R4 "$OUT" "$FX/pack-r4-scope2.md")"
[ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] && ok "28a 'Child gaps opened (none resolved yet)' and '### Gaps not yet closed' stay judged, a '- Child gaps opened:' list-item label starts a section ($want); 'No child gaps' is excluded and a setext heading ends a label section" || no "28a R4 scope2 (rc=$RC want=[$want] got=[$got] out=[$OUT])"
grep -qE 'r4-triggers=3( |$)' <<< "$OUT" && grep -qE 'r4-unscoped=2( |$)' <<< "$OUT" && ok "28b SUMMARY counts 3 judged bullets and 2 unscoped (the excluded heading and the post-setext bullet)" || no "28b scope2 counters (out=[$OUT])"

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for the pack loader and packs (lint_block.py, lint-block-packs/*.py) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  TOOLBELT="$HERE/.."

  # mk_tree NAME -> fresh copy of wrapper + helper + lib in $TMP/mt/NAME; echoes the dir
  mk_tree() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/block-files.sh" "$d/lib/"   # stage-libs-ok: the legacy wrapper sources only this one lib
    cp "$LEGACY/lint-block.sh" "$TOOLBELT/lint_block.py" "$d/"
    cp -r "$TOOLBELT/lint-block-packs" "$d/"
    chmod +x "$d/lint-block.sh"
    printf '%s' "$d"
  }
  # tooth NAME FILE SEDEXPR -> builds the mutant tree; sets MT (dir) or returns 1
  tooth_build() {
    local name="$1" file="$2" expr="$3" d
    d="$(mk_tree "$name")"
    if MUTANT_SYNTAX=none mutant_sed "$TOOLBELT/$file" "$d/$file" "$expr" 2>/dev/null; then
      # A mutant that does not even parse "bites" for the wrong reason: refuse it (python files).
      case "$file" in
        *.py) python3 -c 'import ast,sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$d/$file" 2>/dev/null \
                || { no "teeth $name: mutant is not valid python (wrong-reason bite refused)"; return 1; } ;;
      esac
      MT="$d"; return 0
    fi
    no "teeth $name: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # mrun ARGS... -> run the mutant wrapper
  mrun() { MOUT="$(bash "$MT/lint-block.sh" "$@" 2>&1)"; MRC=$?; }

  # ---- Slice 3 (kit #1365 item 1) teeth: pack loader + jvm / multi-version / native-binary packs ----
  # ptooth NAME FILE SED FIXTURE RULE TAG PACK -> the mutant must NOT report exactly the asserted line set
  ptooth() {
    local name="$1" file="$2" expr="$3" fx="$4" rule="$5" tag="$6" pack="$7" want got
    tooth_build "$name" "$file" "$expr" || return 0
    mrun --pack "$pack" "$fx"
    want="$(lines_of "$tag" "$fx")"; got="$(reported "$rule" "$MOUT" "$fx")"
    if ! grep -qF 'SUMMARY' <<< "$MOUT"; then no "teeth $name: mutant crashed instead of linting (wrong-reason bite) :: out=[$MOUT]"
    elif [ "$got" != "$want" ]; then ok "teeth $name: mutant reports [$got] instead of [$want] -> pack assertion has teeth"
    else no "teeth $name: mutant still reports the asserted set [$want] — THEATER"; fi
  }
  # loader: bad-name pattern neutered -> path traversal no longer reported as an invalid name
  if tooth_build PL1 lint_block.py 's#^PACK_NAME_RE = .*#PACK_NAME_RE = re.compile(r"^.*$")#'; then
    mrun --pack ../x "$FX/pack-single.md"; grep -qF 'invalid pack name' <<< "$MOUT" && no "teeth PL1: mutant still refuses the name — THEATER" || ok "teeth PL1: name pattern neutered -> traversal reaches the filesystem lookup -> case 18e has teeth"
  fi
  if tooth_build PL2 lint_block.py 's#^        if name in LOADED_PACKS:#        if False:#'; then
    mrun --audit --pack jvm --pack jvm "$FX/pack-single.md"
    [ "$MRC" -eq 2 ] && ok "teeth PL2: per-name dedup removed -> a repeated pack collides with itself -> case 18f has teeth" || no "teeth PL2: mutant still exited $MRC — THEATER"
  fi
  for spec in 'PL3|s#^            if rid in RULE_IDS:#            if False:#|collide|already active' \
              'PL4|s#^            if rid not in RESERVED_PACK_RULE_IDS:#            if False:#|badid|not a reserved pack rule id' \
              'PL5|s#^        if not rules:#        if False:#|norules|registered no rules' \
              'PL6|s#^            if build is None:#            if False:#|nobuild|defines no build' \
              'PL7|s#^    if not os.path.isdir(base):#    if False:#|nodir|DEGRADED'; do
    IFS='|' read -r tname texpr tdir twant <<< "$spec"
    if tooth_build "$tname" lint_block.py "$texpr"; then
      pdir="$TMP/pk-$tdir"; [ "$tdir" = nodir ] && pdir="$TMP/no-such-dir"
      MOUT="$(LINT_BLOCK_PACKS_DIR="$pdir" bash "$MT/lint-block.sh" --audit --pack demo "$FX/pack-single.md" 2>&1)"; MRC=$?
      if [ "$MRC" -eq 2 ] && grep -qF -- "$twant" <<< "$MOUT"; then no "teeth $tname: mutant still reports '$twant' — THEATER"
      else ok "teeth $tname: guard removed -> '$twant' no longer reported (rc=$MRC) -> case 18h/18i has teeth"; fi
    fi
  done
  if tooth_build PL8 lint_block.py 's#^            crashed += 1#            crashed += 0#'; then
    MOUT="$(LINT_BLOCK_PACKS_DIR="$TMP/pk-crash" bash "$MT/lint-block.sh" --audit --pack demo "$FX/pack-single.md" 2>&1)"; MRC=$?
    [ "$MRC" -eq 0 ] && ok "teeth PL8: crash counter neutered -> a crashing pack rule exits 0 (clean zero) -> case 18l has teeth" || no "teeth PL8: mutant still exited $MRC — THEATER"
  fi
  if tooth_build PL9 lint_block.py 's#^    if LOADED_PACKS:#    if False:#'; then
    mrun --audit --pack jvm "$FX/pack-single.md"
    grep -qF 'packs=jvm' <<< "$MOUT" && no "teeth PL9: mutant still prints packs= — THEATER" || ok "teeth PL9: pack fields dropped from SUMMARY -> coverage no longer provable -> cases 18f/19e have teeth"
  fi
  ptooth N10 lint-block-packs/native-binary.py 's#if name == "R2":#if False:#' "$FX/pack-r9.md" R9 R9- native-binary
  if tooth_build PL10 lint_block.py 's#            if not names or val.startswith("-"):#            if val.startswith("-"):#'; then
    mrun --audit --pack , "$FX/pack-single.md"
    [ "$MRC" -eq 2 ] && no "teeth PL10: empty-name check removed but ',' still rejected — THEATER" || ok "teeth PL10: empty-name check removed -> '--pack ,' runs core-only silently (rc=$MRC) -> case 18n has teeth"
  fi
  if tooth_build PL11 lint_block.py 's#crashed_cov = f" crashed={crashed}" if crashed else ""#crashed_cov = ""#'; then
    MOUT="$(LINT_BLOCK_PACKS_DIR="$TMP/pk-crash" bash "$MT/lint-block.sh" --audit --pack demo "$FX/pack-single.md" 2>&1)"
    grep -qF 'crashed=' <<< "$MOUT" && no "teeth PL11: mutant still reports crashed= — THEATER" || ok "teeth PL11: crashed= dropped from SUMMARY -> case 18l has teeth"
  fi
  # kit #1517 advisories: each new guard has its own mutant
  ptooth J8 lint-block-packs/jvm.py 's#r"\\bdocSource\\b", r"\\bbytecode\\b"#r"\\bdocSource\\b", r"\\bCFR\\b", r"\\bbytecode\\b"#' "$FX/pack-adv-jvm.md" R1 ADV-R1-BAD jvm
  ptooth J9 lint-block-packs/jvm.py 's#^    r"|\\bContext\\b|\\bcx\\b")#    r"|(?i:\\bContext\\b)|\\bcx\\b")#' "$FX/pack-adv-jvm.md" R5 ADV-R5-BAD jvm
  ptooth J11 lint-block-packs/jvm.py 's#|\\bcx\\b")#|(?i:\\bcx\\b)")#' "$FX/pack-adv-jvm.md" R5 ADV-R5-BAD jvm
  ptooth J12 lint-block-packs/jvm.py 's#^    r"|\\bContext\\b|\\bcx\\b")#    r"|\\bcx\\b")#' "$FX/pack-adv-jvm.md" R5 ADV-R5-BAD jvm
  ptooth J13 lint-block-packs/jvm.py 's#|\\bContext\\b|\\bcx\\b")#|\\bContext\\b")#' "$FX/pack-adv-jvm.md" R5 ADV-R5-BAD jvm
  ptooth J10 lint-block-packs/jvm.py 's#|\\bnull\[\\s-\]+context\\b##' "$FX/pack-adv-jvm.md" R5 ADV-R5-BAD jvm
  ptooth M5 lint-block-packs/multi-version.py 's#(?<!\[\\d.\])##' "$FX/pack-adv-r8.md" R8 ADV-R8-BAD multi-version
  ptooth M6 lint-block-packs/multi-version.py 's#4\\.15(?!\\d)#4\\.15#' "$FX/pack-adv-r8.md" R8 ADV-R8-BAD multi-version
  ptooth N11 lint-block-packs/native-binary.py 's#(?=\[0-9A-Fa-f\]\*\\d)##' "$FX/pack-adv-r9.md" R9 ADV-R9-BAD native-binary
  # kit #1548 / #1607: quoted-gap skip and inline cited-absence
  r5q_want="$(grep -nE 'R5Q-[A-Z-]*BAD' "$FX/pack-r5-quote.md" | cut -d: -f1 | sort -n | tr '\n' ' ' | sed 's/ $//')"
  if tooth_build RQ1 lint_block.py 's#if quoted_skip_re is not None and u.quoted and#if False and u.quoted and#'; then
    mrun --pack jvm "$FX/pack-r5-quote.md"; got="$(reported R5 "$MOUT" "$FX/pack-r5-quote.md")"
    [ "$got" = "$r5q_want" ] && no "teeth RQ1: quoted skip disabled but R5 set unchanged [$got] — THEATER" || ok "teeth RQ1: quoted skip disabled -> R5 reports [$got] instead of [$r5q_want] -> case 23a has teeth"
  fi
  if tooth_build RQ2 lint-block-packs/jvm.py 's#|cited-absence##'; then
    mrun --pack jvm "$FX/pack-r5-quote.md"; got="$(reported R5 "$MOUT" "$FX/pack-r5-quote.md")"
    [ "$got" = "$r5q_want" ] && no "teeth RQ2: cited-absence form removed but R5 set unchanged [$got] — THEATER" || ok "teeth RQ2: cited-absence form removed -> R5 reports [$got] -> case 23a has teeth"
  fi
  if tooth_build RQ3 lint_block.py 's#doc.cov\[qkey\] += 1#pass#'; then
    mrun --pack jvm "$FX/pack-r5-quote.md"
    grep -qE 'r5-quoted-skipped=3( |$)' <<< "$MOUT" && no "teeth RQ3: skip counter dropped but SUMMARY still shows 3 — THEATER" || ok "teeth RQ3: skip counter dropped -> r5-quoted-skipped=3 vanishes -> case 23b has teeth"
  fi
  if tooth_build RQ4 lint_block.py 's#doc.cov\[qkey\] += 0#pass#'; then
    mrun --pack jvm "$FX/pack-single.md"
    grep -qE 'r5-quoted-skipped=0( |$)' <<< "$MOUT" && no "teeth RQ4: zero-initialisation dropped but SUMMARY still prints 0 — THEATER" || ok "teeth RQ4: zero-init dropped -> counter silently absent at 0 -> case 23c has teeth"
  fi
  # kit #1548 calibration: each narrowed vocabulary / filter has its own mutant
  ptooth CR1 lint-block-packs/jvm.py 's#r"`var`", r"\\bvar\\s+(?:keyword|declarations?|inference)\\b", #r"\\bvar\\b", #' "$FX/pack-cal-jvm.md" R1 CAL-R1-BAD jvm
  ptooth CR2 lint-block-packs/jvm.py 's#r"\\bsealed\\s+(?:classes|class|interfaces|interface|hierarch\\w\*|types?)\\b",#r"\\bsealed\\b",#' "$FX/pack-cal-jvm.md" R1 CAL-R1-BAD jvm
  ptooth CR3 lint-block-packs/jvm.py 's#r"for-each", #r"for-each", r"for\\s+each", #' "$FX/pack-cal-jvm.md" R1 CAL-R1-BAD jvm
  ptooth CR4 lint-block-packs/jvm.py 's#|\\bo?auth\\d?\\b|\\bauthn\\b|\\bauthz\\b|\\b(?:un|de)?(?:authenticat|authoriz|authoris)\\w\*#|\\bauth\\w*\\b#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR17 lint-block-packs/jvm.py 's#|\\b(?:un|de)?(?:authenticat|authoriz|authoris)\\w\*#|\\bauthenticat\\w*|\\bauthoriz\\w*|\\bauthoris\\w*#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR5 lint-block-packs/multi-version.py 's#if not R8_WHETHER_RE.search(before) and not R8_NEGATION_RE.search(before):#if True:#' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR6 lint-block-packs/multi-version.py 's#(?:is|are|was|were|does|did)#(?:xx)#' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR7 lint-block-packs/multi-version.py 's#if not R8_WHETHER_RE.search(before) and #if #' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR10 lint-block-packs/multi-version.py 's#R8_WHETHER_RE.search(before)#R8_WHETHER_RE.search(clause)#' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR30 lint-block-packs/jvm.py 's#^R5_ACCESS_ACTION_RE = .*#R5_ACCESS_ACTION_RE = re.compile(r"(?!)")#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR31 lint-block-packs/jvm.py 's#re.compile(r"\\bBypass\\b|#re.compile(r"\\bBypass[a-z]*\\b|#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR32 lint-block-packs/jvm.py 's#re.compile(r"\\bBypass\\b|#re.compile(r"(?i:\\bbypass\\b)|#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR33 lint-block-packs/jvm.py 's#^    if R5_ACCESS_CTX_RE.search(clause):#    if True:#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR34 lint-block-packs/jvm.py 's#^    if R5_ACCESS_CTX_RE.search(clause):#    if False:#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR35 lint-block-packs/jvm.py 's#`bypass`(?=\\s+(?:policy|policies|action|rule)s?\\b)#`bypass`#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR36 lint-block-packs/jvm.py 's#|`bypass`(?=\\s+(?:policy|policies|action|rule)s?\\b)")#")#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR37 lint-block-packs/jvm.py 's#sub("\\x00", clause)#sub("", clause)#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR38 lint-block-packs/jvm.py 's#|(?<!\\\[)\\bBlock\\b(?!\\s\*\\d)|#|(?<!\\\[)\\bBlock\\b|#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR39 lint-block-packs/jvm.py 's#|(?<!\\\[)\\bBlock\\b(?!\\s\*\\d)|#|\\bBlock\\b(?!\\s*\\d)|#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR40 lint-block-packs/jvm.py 's#\\bBypass\\s+actions?\\b|\\baction:|#\\baction\\b|#' "$FX/pack-cal-jvm.md" R5 CAL-R5-BAD jvm
  ptooth CR11 lint-block-packs/jvm.py 's#r"\\brecords?\\s\*/\\s\*sealed\\b", ##' "$FX/pack-cal-jvm.md" R1 CAL-R1-BAD jvm
  cal_r9_want="$(grep -nE 'CAL-R9-(HEADING-|ROW-|EMPTY-|PARENT-)?BAD' "$FX/pack-cal-r9.md" | cut -d: -f1 | sort -n | tr '\n' ' ' | sed 's/ $//')"
  if tooth_build CR8 lint-block-packs/native-binary.py 's#text = section_text(doc, u)#text = u.text#'; then
    mrun --pack native-binary "$FX/pack-cal-r9.md"; got="$(reported R9 "$MOUT" "$FX/pack-cal-r9.md")"
    [ "$got" = "$cal_r9_want" ] && no "teeth CR8: heading judged on its own text but R9 set unchanged [$got] — THEATER" || ok "teeth CR8: heading judged on its own text -> R9 reports [$got] instead of [$cal_r9_want] -> case 24d has teeth"
  fi
  if tooth_build CR9 lint-block-packs/native-binary.py 's#h.kind == "heading" and h.line > heading.line#False#'; then
    mrun --pack native-binary "$FX/pack-cal-r9.md"; got="$(reported R9 "$MOUT" "$FX/pack-cal-r9.md")"
    [ "$got" = "$cal_r9_want" ] && no "teeth CR9: section end ignores the next heading but R9 set unchanged [$got] — THEATER" || ok "teeth CR9: section runs past the next heading -> R9 reports [$got] -> case 24d has teeth"
  fi
  # positional R8 filters and R5 clearing content (kit #1548 review round)
  ptooth CR12 lint-block-packs/multi-version.py 's#if part\[2\] or R8_QUESTION_OPEN_RE#if "?" in clause or R8_QUESTION_OPEN_RE#' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR13 lint-block-packs/multi-version.py 's#not(?!\\s+(?:only|just|merely|simply|solely)\\b)#not#' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR14 lint-block-packs/multi-version.py 's#\\bwhether\\b(?!\\s+or\\s+not\\b)#\\bwhether\\b#' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR15 lint-block-packs/multi-version.py 's#\.rsplit(",", 1)\[-1\]##' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR16 lint-block-packs/multi-version.py 's#before = clause\[start:t.start()\]#before = clause[:t.start()]#' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR18 lint-block-packs/multi-version.py 's#fine = spans_of(clause, R8_QUESTION_END_RE)#fine = spans_of(clause, R8_SENTENCE_END_RE)#' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR19 lint-block-packs/multi-version.py 's#|\[()\]##' "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  ptooth CR20 lint-block-packs/multi-version.py "s#isn't it|aren't they|doesn't it|don't they|right|no#xx#" "$FX/pack-cal-r8.md" R8 CAL-R8-BAD multi-version
  r5q_bad_want="$r5q_want"
  if tooth_build RQ5 lint-block-packs/jvm.py 's#r"^\\s\*Gap\\b|#r".|#'; then
    mrun --pack jvm "$FX/pack-r5-quote.md"; got="$(reported R5 "$MOUT" "$FX/pack-r5-quote.md")"
    [ "$got" = "$r5q_bad_want" ] && no "teeth RQ5: any blockquote skipped but R5 set unchanged [$got] — THEATER" || ok "teeth RQ5: every quoted unit skipped -> own '> Finding:' callout vanishes ([$got]) -> case 23a has teeth"
  fi
  if tooth_build RQ6 lint-block-packs/jvm.py 's#todo|tbd|tba|tbc|xxx|##'; then
    mrun --pack jvm "$FX/pack-r5-quote.md"; got="$(reported R5 "$MOUT" "$FX/pack-r5-quote.md")"
    [ "$got" = "$r5q_bad_want" ] && no "teeth RQ6: placeholder content accepted but R5 set unchanged [$got] — THEATER" || ok "teeth RQ6: placeholder reject removed -> TODO / ? clear R5 ([$got]) -> case 23a has teeth"
  fi
  if tooth_build RQ8 lint-block-packs/jvm.py 's#nil|null|unknown|unresolved|#nil|null|#;s#pending|unclear#unclear#'; then
    mrun --pack jvm "$FX/pack-r5-quote.md"; got="$(reported R5 "$MOUT" "$FX/pack-r5-quote.md")"
    [ "$got" = "$r5q_bad_want" ] && no "teeth RQ8: unresolved/pending accepted but R5 set unchanged [$got] — THEATER" || ok "teeth RQ8: unresolved/pending placeholders accepted -> they clear R5 ([$got]) -> case 23a has teeth"
  fi
  if tooth_build RQ9 lint-block-packs/jvm.py 's#(?=\\S\*\[A-Za-z0-9\]{3,})##'; then
    mrun --pack jvm "$FX/pack-r5-quote.md"; got="$(reported R5 "$MOUT" "$FX/pack-r5-quote.md")"
    [ "$got" = "$r5q_bad_want" ] && no "teeth RQ9: alphanumeric requirement dropped but R5 set unchanged [$got] — THEATER" || ok "teeth RQ9: '---' / '...' accepted as content -> they clear R5 ([$got]) -> case 23a has teeth"
  fi
  if tooth_build RQ10 lint-block-packs/jvm.py 's#\^\\s\*Gap\\b|#\\bgaps?\\b|#'; then
    mrun --pack jvm "$FX/pack-r5-quote.md"; got="$(reported R5 "$MOUT" "$FX/pack-r5-quote.md")"
    [ "$got" = "$r5q_bad_want" ] && no "teeth RQ10: bare word gap qualifies but R5 set unchanged [$got] — THEATER" || ok "teeth RQ10: plain 'gap' in prose skips a callout -> R5 reports [$got] -> case 23a has teeth"
  fi
  if tooth_build RQ11 lint-block-packs/jvm.py 's#\\bG\\d+\\s\*:#\\bG\\d+\\b#'; then
    mrun --pack jvm "$FX/pack-r5-quote.md"; got="$(reported R5 "$MOUT" "$FX/pack-r5-quote.md")"
    [ "$got" = "$r5q_bad_want" ] && no "teeth RQ11: bare G7 qualifies but R5 set unchanged [$got] — THEATER" || ok "teeth RQ11: bare 'G7' in prose skips a callout -> R5 reports [$got] -> case 23a has teeth"
  fi
  if tooth_build RQ7 lint-block-packs/jvm.py 's#\\S{3,}#\\S*#;s#(?=\\S\*\[A-Za-z0-9\]{3,})##'; then
    mrun --pack jvm "$FX/pack-r5-quote.md"; got="$(reported R5 "$MOUT" "$FX/pack-r5-quote.md")"
    [ "$got" = "$r5q_bad_want" ] && no "teeth RQ7: empty clearing clause accepted but R5 set unchanged [$got] — THEATER" || ok "teeth RQ7: content requirement dropped -> empty cited-absence clears R5 ([$got]) -> case 23a has teeth"
  fi
  if tooth_build L1 lint_block.py 's#if not (isinstance(rule,#if False and not (isinstance(rule,#'; then
    MOUT="$(LINT_BLOCK_PACKS_DIR="$TMP/pk-shape" bash "$MT/lint-block.sh" --audit --pack demo "$FX/pack-single.md" 2>&1)"; MRC=$?
    grep -qF 'malformed rule' <<< "$MOUT" && no "teeth L1: mutant still reports 'malformed rule' — THEATER" || ok "teeth L1: shape guard removed -> malformed pack entry no longer reported cleanly (rc=$MRC) -> case 22e has teeth"
  fi
  if tooth_build L2 lint_block.py 's#rules = list(build(api))#rules = build(api)#'; then
    MOUT="$(LINT_BLOCK_PACKS_DIR="$TMP/pk-gen" bash "$MT/lint-block.sh" --pack demo "$FX/pack-single.md" 2>&1)"; MRC=$?
    [ "$MRC" -eq 1 ] && no "teeth L2: mutant still fires on a generator pack — THEATER" || ok "teeth L2: build() result not materialised -> generator pack silently registers nothing/crashes (rc=$MRC) -> case 22f has teeth"
  fi
  if tooth_build L3 lint_block.py 's#isinstance(rule, (tuple, list))#isinstance(rule, tuple)#'; then
    MOUT="$(LINT_BLOCK_PACKS_DIR="$TMP/pk-listpair" bash "$MT/lint-block.sh" --pack demo "$FX/pack-single.md" 2>&1)"; MRC=$?
    [ "$MRC" -eq 1 ] && no "teeth L3: mutant still accepts a list pair — THEATER" || ok "teeth L3: list pairs rejected (rc=$MRC) -> case 22g has teeth"
  fi
  if tooth_build L4 lint_block.py 's#raise PackError(f"pack {name} failed to load: {type(exc).__name__}: {exc}")#rules = [("R1", lambda d: [])]#'; then
    MOUT="$(LINT_BLOCK_PACKS_DIR="$TMP/pk-noniter" bash "$MT/lint-block.sh" --audit --pack demo "$FX/pack-single.md" 2>&1)"; MRC=$?
    [ "$MRC" -eq 2 ] && no "teeth L4: mutant still exits 2 — THEATER" || ok "teeth L4: non-iterable return no longer fails closed (rc=$MRC) -> case 22h has teeth"
  fi
  # core claim-rule factory
  ptooth F1 lint_block.py 's#if is_cleared(clause) or doc.waived(rule_id, u):#if is_cleared(clause):#' "$FX/pack-jvm.md" R1 R1- jvm
  ptooth F2 lint_block.py 's#^CLAIM_KINDS = .*#CLAIM_KINDS = ("para", "item", "heading")#' "$FX/pack-jvm.md" R5 R5- jvm
  ptooth F3 lint_block.py 's#\]\])\[\.;!?\]#]])[;!?]#' "$FX/pack-jvm.md" R1 R1- jvm
  if tooth_build F4 lint_block.py 's#                doc.cov\[covkey\] += 1#                doc.cov[covkey] += 0#'; then
    mrun --pack jvm "$FX/pack-jvm.md"
    grep -qE 'r1-triggers=6( |$)' <<< "$MOUT" && no "teeth F4: mutant still reports r1-triggers=6 — THEATER" || ok "teeth F4: trigger counter neutered -> SUMMARY no longer proves what R1 looked at -> case 19e has teeth"
  fi
  # jvm pack
  ptooth J1 lint-block-packs/jvm.py 's#r"\\bjavap\\b", ##' "$FX/pack-jvm.md" R1 R1- jvm
  ptooth J2 lint-block-packs/jvm.py 's#r"text\\s+block", ##' "$FX/pack-jvm.md" R1 R1- jvm
  ptooth J3 lint-block-packs/jvm.py 's#R5_CLEARED_RE.search, "permission#lambda c: False, "permission#' "$FX/pack-jvm.md" R5 R5- jvm
  ptooth J4 lint-block-packs/jvm.py 's# and R5_PERM_CONTEXT_RE.search(c)# and True#' "$FX/pack-jvm.md" R5 R5- jvm
  ptooth J5 lint-block-packs/jvm.py 's#r"compile-time constant", ##' "$FX/pack-jvm.md" R7 R7- jvm
  ptooth J6 lint-block-packs/jvm.py 's#r"\\bhardcod\\w\*\\b.{0,80}\\binstead of\\b.{0,40}\\bconstant\\b",##' "$FX/pack-jvm.md" R7 R7- jvm
  ptooth J7 lint-block-packs/jvm.py 's#r"\\bsealed\\s+(?:classes|class|interfaces|interface|hierarch\\w\*|types?)\\b",##' "$FX/pack-jvm.md" R1 R1- jvm
  # multi-version pack
  ptooth M1 lint-block-packs/multi-version.py 's#^R8_BASELINE_RE = .*#R8_BASELINE_RE = re.compile(r"(?!)")#' "$FX/pack-r8.md" R8 R8- multi-version
  ptooth M2 lint-block-packs/multi-version.py 's#\\bclass(?:es)?\\b#\\bclasses?\\b#' "$FX/pack-r8.md" R8 R8- multi-version
  ptooth M3 lint-block-packs/multi-version.py 's#\\bmodules?\\b|##' "$FX/pack-r8.md" R8 R8- multi-version
  ptooth M4 lint-block-packs/multi-version.py 's#|absent from N4"#"#' "$FX/pack-r8.md" R8 R8- multi-version
  # native-binary pack
  ptooth N1 lint-block-packs/native-binary.py 's#^            if not R9_SHA256_RE.search(text):#            if False:#' "$FX/pack-r9.md" R9 R9- native-binary
  ptooth N2 lint-block-packs/native-binary.py 's#^            if not R9_ANCHOR_RE.search(text):#            if False:#' "$FX/pack-r9.md" R9 R9- native-binary
  ptooth N3 lint-block-packs/native-binary.py 's#^            if n < 2:#            if n < 1:#' "$FX/pack-r9.md" R9 R9- native-binary
  ptooth N4 lint-block-packs/native-binary.py 's#for span in R9_CODE_SPAN_RE.findall(text):#for span in []:#' "$FX/pack-r9.md" R9 R9- native-binary
  ptooth N5 lint-block-packs/native-binary.py 's#"readelf", "objdump"#"readelf", "nm", "objdump"#' "$FX/pack-r9.md" R9 R9- native-binary
  ptooth N6 lint-block-packs/native-binary.py 's#^R9_MARKER_RE = .*#R9_MARKER_RE = re.compile(r"\\[CERT[-a-z]*\\]")#' "$FX/pack-r9.md" R9 R9- native-binary
  ptooth N7 lint-block-packs/native-binary.py 's#(?:dll|so#(?:dll|sys|so#' "$FX/pack-r9.md" R9 R9- native-binary
  ptooth N8 lint-block-packs/native-binary.py 's#^            if doc.waived("R9", u):#            if False:#' "$FX/pack-r9.md" R9 R9- native-binary
  if tooth_build N9 lint-block-packs/native-binary.py 's#doc.cov\["r9_triggers"\] += 1#doc.cov["r9_triggers"] += 0#'; then
    mrun --pack native-binary "$FX/pack-r9.md"
    grep -qE 'r9-triggers=11( |$)' <<< "$MOUT" && no "teeth N9: mutant still reports r9-triggers=11 — THEATER" || ok "teeth N9: R9 counter neutered -> SUMMARY no longer proves the units were inspected -> case 21b has teeth"
  fi
  # child-gap pack
  ptooth G1 lint-block-packs/child-gap.py 's#^                waived = any(.*#                waived = False#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G2 lint-block-packs/child-gap.py 's#out.append(("ABSENT", "no `coverage-check:` clause"))#pass#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G3 lint-block-packs/child-gap.py 's#elif len(plain.split()) >= 4:#elif len(plain.split()) >= 99:#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G4 lint-block-packs/child-gap.py 's#or RESULT_PLACEHOLDER_RE.match(result):#or PLACEHOLDER_RE.match(result):#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G5 lint-block-packs/child-gap.py 's#^    if not re.search(r"\[A-Za-z0-9\]{2,}", result) or RESULT_PLACEHOLDER_RE.match(result):#    if False:#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G6 lint-block-packs/child-gap.py 's#(?<!\[\\w.:\])#(?<![\\w.])#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G7 lint-block-packs/child-gap.py 's#^    prose = DATE_RE.sub(" ", prose)#    prose = prose#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G8 lint-block-packs/child-gap.py 's#if j in doc.fenced or not nxt.strip() or HEADING_LINE_RE.match(nxt):#if True:#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G9 lint-block-packs/child-gap.py 's#^            if i in doc.fenced:#            if False:#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G10 lint-block-packs/child-gap.py 's#if scope is None and excluded is None and SECTION_RE.search(title) \\#if scope is None and excluded is None and True \\#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G11 lint-block-packs/child-gap.py 's#^    number = stated_number(prose)#    number = None#' "$FX/pack-r4.md" R4 R4- child-gap
  ptooth G12 lint-block-packs/child-gap.py 's#^            if not re.search(r"\[A-Za-z0-9\]{2,}", mbody) or PLACEHOLDER_RE.match(mbody):#            if False:#' "$FX/pack-r4.md" R4 R4- child-gap
  if tooth_build G13 lint-block-packs/child-gap.py 's#doc.cov\["r4_triggers"\] += 1#doc.cov["r4_triggers"] += 0#'; then
    mrun --pack child-gap "$FX/pack-r4.md"
    grep -qE 'r4-triggers=14( |$)' <<< "$MOUT" && no "teeth G13: mutant still reports r4-triggers=14 — THEATER" || ok "teeth G13: R4 counter neutered -> SUMMARY no longer proves the bullets were inspected -> case 25b has teeth"
  fi
  # child-gap pack, review round (kit #1214): section model, clause end, number grammar, result placeholders
  ptooth G14 lint-block-packs/child-gap.py 's#^RESULT_SEP_RE = .*#RESULT_SEP_RE = re.compile(r"→")#' "$FX/pack-r4-clause.md" R4 R4- child-gap
  ptooth G15 lint-block-packs/child-gap.py 's#if m.group(2) and not m.group(3):#if m.group(2):#' "$FX/pack-r4-clause.md" R4 R4- child-gap
  ptooth G16 lint-block-packs/child-gap.py 's#(%|\[xXkKmM\]|\[kKmMgG\]\[bB\])?(?!\\w)#(\\b\\B)?(?!\\w)#' "$FX/pack-r4-clause.md" R4 R4- child-gap
  ptooth G17 lint-block-packs/child-gap.py 's#^        se = SENTENCE_END_RE.search(masked, m.end(), end)#        se = None#' "$FX/pack-r4-clause.md" R4 R4- child-gap
  ptooth G18 lint-block-packs/child-gap.py 's#^    pieces.append(text\[pos:\])#    pieces.append("")#' "$FX/pack-r4-clause.md" R4 R4- child-gap
  ptooth G19 lint-block-packs/child-gap.py 's#^    elif PROSE_PLACEHOLDER_RE.search(plain):#    elif False:#' "$FX/pack-r4-clause.md" R4 R4- child-gap
  ptooth G20 lint-block-packs/child-gap.py 's#or RESULT_PLACEHOLDER_RE.match(result):#:#' "$FX/pack-r4-clause.md" R4 R4- child-gap
  ptooth G21 lint-block-packs/child-gap.py 's#if im and len(im.group(1)) <= indent:#if im:#' "$FX/pack-r4-clause.md" R4 R4- child-gap
  ptooth G22 lint-block-packs/child-gap.py 's#scope\[0\] == "label" or level <= scope\[1\]#scope[0] == "label" or True#' "$FX/pack-r4-scope.md" R4 R4- child-gap
  ptooth G23 lint-block-packs/child-gap.py 's#^            if scope is None and LABEL_RE.match(raw):#            if False:#' "$FX/pack-r4-scope.md" R4 R4- child-gap
  ptooth G24 lint-block-packs/child-gap.py 's#and not EXCLUDED_TITLE_RE.search(title):#:#' "$FX/pack-r4-scope.md" R4 R4- child-gap
  ptooth G25 lint-block-packs/child-gap.py 's#^                    excluded = None$#                    pass#' "$FX/pack-r4-scope.md" R4 R4- child-gap
  if tooth_build G26 lint-block-packs/child-gap.py 's#doc.cov\["r4_unscoped"\] += 1#doc.cov["r4_unscoped"] += 0#'; then
    mrun --pack child-gap "$FX/pack-r4-scope.md"
    grep -qE 'r4-unscoped=4( |$)' <<< "$MOUT" && no "teeth G26: mutant still reports r4-unscoped=4 — THEATER" || ok "teeth G26: unscoped counter neutered -> a gap outside every judged section reads clean -> case 26b has teeth"
  fi
  # round 2: ';' / digit-led clause ends, anchored heading exclusion, list-item label, setext end
  ptooth G27 lint-block-packs/child-gap.py 's#^SENTENCE_END_RE = .*#SENTENCE_END_RE = re.compile(r"[.!?](?=\\s+[A-Z`\\[(0-9]|\\s*$)")#' "$FX/pack-r4-clause.md" R4 R4- child-gap
  ptooth G28 lint-block-packs/child-gap.py 's#^SENTENCE_END_RE = .*#SENTENCE_END_RE = re.compile(r"[.!?](?=\\s+[A-Z`\\[(]|\\s*$)|;")#' "$FX/pack-r4-clause.md" R4 R4- child-gap
  ptooth G29 lint-block-packs/child-gap.py 's#(?<!not )(?<!not yet )##' "$FX/pack-r4-scope2.md" R4 R4- child-gap
  ptooth G30 lint-block-packs/child-gap.py 's#\\b(?:closed|resolved)\\W\*\$",#\\b(?:closed|resolved)\\b",#' "$FX/pack-r4-scope2.md" R4 R4- child-gap
  ptooth G31 lint-block-packs/child-gap.py 's#(?:\[-\*+\]\\s+)?##' "$FX/pack-r4-scope2.md" R4 R4- child-gap
  ptooth G32 lint-block-packs/child-gap.py 's#^            if underlined and scope is not None and scope\[0\] == "label":#            if False:#' "$FX/pack-r4-scope2.md" R4 R4- child-gap
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
