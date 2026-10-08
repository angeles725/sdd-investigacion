#!/usr/bin/env bash
# verify-block-backpointer.test.sh — RED-FIRST harness for the §14 back-pointer check in verify-block.sh (kit #1962).
#
# Contract under test: when a block says, in ONE sentence, a correction act (refut* / corrig* / correg* / correcci* /
# supersed* / corrects|corrected|correcting|correction, case-insensitive, Spanish + English) AND cites an EARLIER block
# (`[Block N]`, `Block N`, `Bloque N`, `bloqueN`, `BN`; bare `RN` only in an R-numbered corpus whose H1 is `# Block R<n>`),
# the cited block's file is resolved in the same corpus (lib/block-files.sh predicate, same prefix first, SAME SERIES: an
# `R5` cite resolves only to a file whose H1 is `# Block R5`, a numeric cite only to a non-R file) and verify-block.sh
# reports a candidate `BACKPTR?` when that block holds no back-pointer to the checked block (in the checked block's own
# series: bare `R<n>` is a pointer only in the R series). ADVISORY: the exit code never changes. The default
# (--backptr=high) prints a per-line finding only for the high-confidence shape and counts the rest; --backptr=all lists
# everything; --backptr=off skips the section. Typed non-verdicts (never silent): file not found (INFO), several candidates
# (BACKPTR-AMBIGUOUS), unreadable / failed scan / missing helper (DEGRADED). Every sentence a filter suppresses is COUNTED in
# the summary. The EPHEMERAL! default-FAIL (#1660) is untouched.
#
# Usage: verify-block-backpointer.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-block.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# run <block>: every candidate listed (--backptr=all). rund <block>: the DEFAULT output (--backptr=high).
run(){ bash "${2:-$SUT}" --backptr=all "$1" 2>/dev/null; }
rund(){ bash "$SUT" "$1" 2>/dev/null; }
mkblk(){ # mkblk <file> <N> <body-lines...> : header legend + body
  local f="$1" n="$2"; shift 2
  { echo "# Block $n — t"; echo; echo "> Type: evidence. Method: [CERT] = x."; echo; echo "---"; echo; printf '%s\n' "$@"; } > "$f"; }
mkrblk(){ # mkrblk <file> <N> <body-lines...> : an R-series block (H1 `# Block R<N>`)
  local f="$1" n="$2"; shift 2
  { echo "# Block R$n — t"; echo; printf '%s\n' "$@"; } > "$f"; }
warns(){ grep -cE '^ +BACKPTR\? ' <<<"$1"; }

echo "== verify-block-backpointer.test.sh =="

# 1 — REFUT + [Block 5] in block 11, block 5 has no pointer to 11 → candidate naming both, exit unchanged (0).
c="$TMP/c1"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Claim A is the home of blocks."
mkblk "$c/x-block11.md" 11 "The manifest REFUTES the home claim of [Block 5] for good."
out="$(rund "$c/x-block11.md")"; bash "$SUT" "$c/x-block11.md" >/dev/null 2>&1; rc=$?
if grep -qE '^ +BACKPTR\? +line [0-9]+: possible correction of block 5 \(x-block5\.md\); verify by hand, then consider a back-pointer to B11 in x-block5\.md' <<<"$out" && [ "$rc" = 0 ]; then ok "REFUT + [Block 5], no pointer → non-imperative BACKPTR? (default mode), exit 0"
else no "missing candidate or rc=$rc :: $(grep -i backptr <<<"$out")"; fi

# 2 — the old block carries 'corregido en [Block 11]' → pointer found, no candidate.
c="$TMP/c2"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Claim A. Corregido en [Block 11]."
mkblk "$c/x-block11.md" 11 "The manifest REFUTES the home claim of [Block 5] for good."
out="$(rund "$c/x-block11.md")"
if [ "$(warns "$out")" = 0 ] && grep -qE 'backptr-ok +line [0-9]+: block 5' <<<"$out"; then ok "pointer present → backptr-ok, no candidate"
else no "pointer present but flagged/unreported :: $(grep -i backptr <<<"$out")"; fi

# 3 — verb families and citation forms, one fixture each (--backptr=all); every one must be found exactly once.
i=0
while IFS='|' read -r label sentence; do
  i=$((i+1)); c="$TMP/f$i"; mkdir -p "$c"
  mkblk "$c/x-block5.md" 5 "Plain claim."
  mkblk "$c/x-block11.md" 11 "$sentence"
  out="$(run "$c/x-block11.md")"
  if [ "$(warns "$out")" = 1 ]; then ok "form: $label"; else no "form not detected: $label :: $(grep -i backptr <<<"$out")"; fi
done <<'FORMS'
corrige + Bloque N|Esto corrige el Bloque 5 en lo esencial.
corregido + bloqueN|El valor fue corregido respecto a bloque5 tras medir.
refutada + BN|Premisa refutada: contradice B5 directamente.
supersedes + Block N|This supersedes Block 5 for the timing claim.
corrected + [Block N]|We corrected the earlier figure in [Block 5].
CORRIGE upper-case|CORRIGE B5 aqui.
FORMS

# 4 — verb and citation in DIFFERENT sentences → not a correction citation → no finding.
c="$TMP/c4"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain claim."
mkblk "$c/x-block11.md" 11 "We REFUTE the old timing guess. See B5 for the setup."
out="$(run "$c/x-block11.md")"
if [ "$(warns "$out")" = 0 ] && ! grep -qE 'BACKPTR-AMBIGUOUS|backptr-ok' <<<"$out"; then ok "verb and cite in different sentences → no finding"
else no "cross-sentence pairing :: $(grep -i backptr <<<"$out")"; fi

# 5 — block N file not found → typed INFO, not silent and not a candidate.
c="$TMP/c5"; mkdir -p "$c"
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright."
out="$(rund "$c/x-block11.md")"
if grep -qE '^ +INFO +backptr: line [0-9]+ cites block 5 .*not found' <<<"$out" && [ "$(warns "$out")" = 0 ]; then ok "block file not found → typed INFO"
else no "not-found state :: $(grep -i backptr <<<"$out")"; fi

# 6 — two other-prefix candidates for block 5 → typed ambiguous, no candidate.
c="$TMP/c6"; mkdir -p "$c"
mkblk "$c/a-block5.md" 5 "Plain."; mkblk "$c/b-bloque5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright."
out="$(rund "$c/x-block11.md")"
if grep -qE '^ +BACKPTR-AMBIGUOUS +line [0-9]+: block 5 .*a-block5\.md.*b-bloque5\.md' <<<"$out" && [ "$(warns "$out")" = 0 ]; then ok "multiple candidates → BACKPTR-AMBIGUOUS"
else no "ambiguous state :: $(grep -i backptr <<<"$out")"; fi

# 7 — same-prefix candidate wins over an other-prefix one (no ambiguity).
c="$TMP/c7"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."; mkblk "$c/other-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright."
out="$(rund "$c/x-block11.md")"
if [ "$(warns "$out")" = 1 ] && ! grep -q 'BACKPTR-AMBIGUOUS' <<<"$out" && grep -q 'x-block5\.md' <<<"$out"; then ok "same-prefix candidate preferred"
else no "prefix preference :: $(grep -i backptr <<<"$out")"; fi

# 8 — unreadable candidate → typed DEGRADED (skipped when the process can read a mode-000 file, e.g. root).
c="$TMP/c8"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."; chmod 000 "$c/x-block5.md"
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright."
if [ -r "$c/x-block5.md" ]; then ok "unreadable state: skipped (this process can read a mode-000 file)"
else
  out="$(rund "$c/x-block11.md")"
  if grep -qE '^ +DEGRADED +backptr: line [0-9]+: block 5 .*is unreadable' <<<"$out" && [ "$(warns "$out")" = 0 ]; then ok "unreadable candidate → typed DEGRADED"
  else no "degraded state :: $(grep -i backptr <<<"$out")"; fi
fi

# 9 — self-cite and forward cite (same series) are skipped and counted as forward=N, not silent.
c="$TMP/c9"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain." "Block B11 later refutes this claim, and this claim supersedes B5 itself."
mkblk "$c/x-block11.md" 11 "Plain."
out="$(run "$c/x-block5.md")"
if [ "$(warns "$out")" = 0 ] && grep -qE 'forward=[1-9]' <<<"$out"; then ok "self/forward cites skipped and counted (forward=N)"
else no "forward/self handling :: $(grep -i backptr <<<"$out")"; fi

# 10 — B11 is not satisfied by B110 / 5.11 / B11a (boundary on the pointer match).
c="$TMP/c10"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Seen again in B110 and in section 5.11, also B11a."
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright."
out="$(run "$c/x-block11.md")"
if [ "$(warns "$out")" = 1 ]; then ok "B110 / 5.11 / B11a are not a pointer to B11"
else no "pointer boundary leaked :: $(grep -i backptr <<<"$out")"; fi

# 11 — no correction sentence → typed '(none' line stating what was looked at (not a silent zero).
c="$TMP/c11"; mkdir -p "$c"
mkblk "$c/x-block11.md" 11 "Plain statement about B5."
out="$(run "$c/x-block11.md")"
if grep -qE '^ +\(none — no correction sentence cites an earlier block' <<<"$out"; then ok "no correction sentence → explicit (none …)"
else no "none line :: $(grep -iE 'backptr|back-pointer' <<<"$out")"; fi

# 12 — non-canonical file name → explicit skipped line.
{ echo "# t"; echo "corrects B5"; } > "$TMP/legend.md"
out="$(run "$TMP/legend.md")"
if grep -qE 'back-pointer.*skipped.*not a canonical block file' <<<"$out"; then ok "non-canonical file name → skipped, stated"
else no "non-canonical state :: $(grep -iE 'back-pointer' <<<"$out")"; fi

# 13 — bare R5 only counts in an R-numbered corpus (H1 `# Block R<n>`); elsewhere it is e.g. a register name.
c="$TMP/c13"; mkdir -p "$c"
mkrblk "$c/r-block5.md" 5 "Plain."
mkrblk "$c/r-block11.md" 11 "This corrige R5.1 in full."
out="$(run "$c/r-block11.md")"
c2="$TMP/c13b"; mkdir -p "$c2"
mkrblk "$c2/r-block5.md" 5 "Plain."
mkblk "$c2/r-block11.md" 11 "This corrects the value held in R5 after the call."
out2="$(run "$c2/r-block11.md")"
if [ "$(warns "$out")" = 1 ] && [ "$(warns "$out2")" = 0 ]; then ok "bare RN only in an R-numbered corpus"
else no "R-form scoping :: R-corpus=$(warns "$out") plain=$(warns "$out2")"; fi

# 14 — a wrapped paragraph keeps verb and cite in one sentence; a fenced code block is ignored.
c="$TMP/c14"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "The probe refutes the premise" "recorded in B5 earlier." "" '```' "we correct B6 inside code" '```'
out="$(run "$c/x-block11.md")"
if [ "$(warns "$out")" = 1 ] && ! grep -q 'block 6' <<<"$out"; then ok "wrapped sentence joined; fenced code ignored"
else no "paragraph/fence handling :: $(grep -i backptr <<<"$out")"; fi

# 15 — EPHEMERAL! interaction: default FAIL (rc 1) unchanged, opt-out WARN (rc 0) unchanged; BACKPTR? never moves rc.
c="$TMP/c15"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright." 'Probe at `/tmp/session/run.log` shows it.'
out="$(rund "$c/x-block11.md")"; bash "$SUT" "$c/x-block11.md" >/dev/null 2>&1; rc_def=$?
out_w="$(bash "$SUT" --ephemeral=warn "$c/x-block11.md" 2>/dev/null)"; bash "$SUT" --ephemeral=warn "$c/x-block11.md" >/dev/null 2>&1; rc_w=$?
if [ "$rc_def" = 1 ] && grep -q 'EPHEMERAL!' <<<"$out" && [ "$rc_w" = 0 ] && grep -q 'EPHEMERAL?' <<<"$out_w" \
   && [ "$(warns "$out")" = 1 ] && [ "$(warns "$out_w")" = 1 ]; then ok "EPHEMERAL! FAIL default / opt-out WARN unchanged; BACKPTR? never moves rc"
else no "ephemeral interaction: rc_def=$rc_def rc_warn=$rc_w :: $(grep -E 'EPHEMERAL|BACKPTR' <<<"$out")"; fi

# 16 — candidate resolved in the target dir when the checked block lives in a sub-directory.
c="$TMP/c16"; mkdir -p "$c/notes"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/notes/x-block11.md" 11 "This corrects [Block 5] outright."
out="$(bash "$SUT" --backptr=all "$c/notes/x-block11.md" "$c" 2>/dev/null)"
if [ "$(warns "$out")" = 1 ]; then ok "candidate resolved in the target dir"
else no "target-dir resolution :: $(grep -i backptr <<<"$out")"; fi

# 17 — adverb / adjective / noun forms are not correction acts: "correctly", "correcto", "corrigendum" (noun= counted).
c="$TMP/c17"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "It resolves correctly on the modules of [Block 5]." "" "El FE correcto se ve en B5." "" "Hay un corrigendum de B5 abajo."
out="$(run "$c/x-block11.md")"
if [ "$(warns "$out")" = 0 ] && grep -qE '^ +\(none — ' <<<"$out" && grep -qE 'noun=1' <<<"$out"; then ok "correctly / correcto / corrigendum are not correction acts; noun=1 counted"
else no "adverb/adjective/noun handling :: $(grep -i back-pointer <<<"$out")"; fi

# 18 — cross-reference lists (3+ distinct blocks; 2 under a "Connects" lead) are skipped and counted; a 2-block correction counts.
c="$TMP/c18"; mkdir -p "$c"
for n in 1 2 3 4; do mkblk "$c/x-block$n.md" "$n" "Plain."; done
mkblk "$c/x-block11.md" 11 "Connects B1 · B2 · B3 · B4, one row corrected."
out="$(run "$c/x-block11.md")"
mkblk "$c/x-block12.md" 12 "This corrects B1 and B2."
out2="$(run "$c/x-block12.md")"
mkblk "$c/x-block13.md" 13 "Connects B1 and B2, one row corrected."
out3="$(run "$c/x-block13.md")"
mkblk "$c/x-block14.md" 14 "The probe corrects B1, B2 and B3 together."
out4="$(run "$c/x-block14.md")"
if [ "$(warns "$out")" = 0 ] && grep -qE 'list=1' <<<"$out" && [ "$(warns "$out2")" = 2 ] \
   && [ "$(warns "$out3")" = 0 ] && [ "$(warns "$out4")" = 0 ]; then ok "cross-reference lists skipped and counted (list=N); a 2-block correction still counts"
else no "list handling: 4-cite=$(warns "$out") 2-cite=$(warns "$out2") connects2=$(warns "$out3") 3-cite=$(warns "$out4") :: $(grep -i 'back-pointer' <<<"$out")"; fi

# 19 — the CORRECTOR is not the corrected: "corrected by [Block 3]" / "corregido en B4" name the fixer, not a target.
c="$TMP/c19"; mkdir -p "$c"
for n in 3 4; do mkblk "$c/x-block$n.md" "$n" "Plain."; done
mkblk "$c/x-block11.md" 11 "The 8 panels rule was corrected by [Block 3]." "" "Segun la nota, valor corregido en B4."
out="$(run "$c/x-block11.md")"
if [ "$(warns "$out")" = 0 ] && ! grep -q 'backptr-ok' <<<"$out" && grep -qE 'corrector=[12]' <<<"$out"; then ok "cite after 'corrected by' / 'corregido en' is the corrector, skipped and counted"
else no "corrector handling :: $(grep -i backptr <<<"$out")"; fi

# 20 — negations assert the absence; passive / third-party / self corrections are not THIS block's act; each is counted.
#      "not only corrects" and a word merely ENDING in "no" (piano) are NOT negations.
c="$TMP/c20"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "No §14 correction: this corroborates [Block 5]."
mkblk "$c/x-block12.md" 12 "Nothing here refutes B5."
mkblk "$c/x-block13.md" 13 "The figure of B5 was corrected earlier."
mkblk "$c/x-block14.md" 14 "This is the lesson again (B5 self-correction)."
mkblk "$c/x-block15.md" 15 "This block corrects nothing in B5."
mkblk "$c/x-block16.md" 16 "This not only corrects B5 but extends it."
mkblk "$c/x-block17.md" 17 "The piano refutes B5 on the bench."
mkblk "$c/x-block18.md" 18 "Here we later corrected [Block 5] outright."
out="$(run "$c/x-block11.md")"; out2="$(run "$c/x-block12.md")"; out3="$(run "$c/x-block13.md")"; out4="$(run "$c/x-block14.md")"; out5="$(run "$c/x-block15.md")"
out6="$(run "$c/x-block16.md")"; out7="$(run "$c/x-block17.md")"; out8="$(run "$c/x-block18.md")"
if [ "$(warns "$out")" = 0 ] && [ "$(warns "$out2")" = 0 ] && [ "$(warns "$out3")" = 0 ] && [ "$(warns "$out4")" = 0 ] && [ "$(warns "$out5")" = 0 ] \
   && grep -q 'neg=1' <<<"$out" && grep -q 'neg=1' <<<"$out2" && grep -q 'passive=1' <<<"$out3" && grep -q 'self=1' <<<"$out4" && grep -q 'neg=1' <<<"$out5"; then
  ok "negated / passive / self corrections are not a correction act; each suppressed sentence counted (neg/passive/self)"
else no "negation handling: no=$(warns "$out") nothing=$(warns "$out2") passive=$(warns "$out3") self=$(warns "$out4") corrects-nothing=$(warns "$out5")"; fi
if [ "$(warns "$out6")" = 1 ] && [ "$(warns "$out7")" = 1 ]; then ok "'not only corrects' and 'piano refutes' are NOT negations"
else no "negation false-positive guard: not-only=$(warns "$out6") piano=$(warns "$out7")"; fi
if [ "$(warns "$out8")" = 1 ]; then ok "'later'/'also' are not passive auxiliaries (a later correcting sentence still counts)"
else no "passive filter too wide: $(warns "$out8") :: $(grep -i back-pointer <<<"$out8")"; fi

# 21 — proximity: a verb 60+ characters away from the cite belongs to another clause; counted as far=N.
c="$TMP/c21"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "We refute the timing guess here and then go on to describe at considerable length the unrelated setup of the lab bench, which only echoes B5."
out="$(run "$c/x-block11.md")"
mkblk "$c/x-block12.md" 12 "We refute the timing guess of B5 here."
out2="$(run "$c/x-block12.md")"
if [ "$(warns "$out")" = 0 ] && [ "$(warns "$out2")" = 1 ] && grep -q 'far=1' <<<"$out"; then ok "verb must sit within 60 characters of the cite (far=N counted)"
else no "proximity: far=$(warns "$out") near=$(warns "$out2")"; fi

# 22 — TWO SERIES in one corpus (C1): R5 resolves only to the `# Block R5` file, 5 only to the numeric file; the forward
#      test compares within one series.
c="$TMP/c22"; mkdir -p "$c"
mkrblk "$c/niagara-reflow-block5.md" 5 "Plain R claim."
mkblk "$c/niagara-mental-model-bloque5.md" 5 "Plain numeric claim."
mkrblk "$c/niagara-reflow-block11.md" 11 "This corrige [Block R5] outright."
mkblk "$c/niagara-mental-model-bloque11.md" 11 "This corrects [Block 5] outright."
mkblk "$c/other-block11.md" 11 "This corrects [Block 5] outright."
o1="$(run "$c/niagara-reflow-block11.md")"; o2="$(run "$c/niagara-mental-model-bloque11.md")"; o3="$(run "$c/other-block11.md")"
if [ "$(warns "$o1")" = 1 ] && grep -q 'block R5 (niagara-reflow-block5\.md)' <<<"$o1" && ! grep -q 'AMBIGUOUS' <<<"$o1" \
   && [ "$(warns "$o2")" = 1 ] && grep -q 'block 5 (niagara-mental-model-bloque5\.md)' <<<"$o2" \
   && [ "$(warns "$o3")" = 1 ] && grep -q 'block 5 (niagara-mental-model-bloque5\.md)' <<<"$o3"; then ok "R5 → the R file, 5 → the numeric file (same- and other-prefix), never ambiguous across series"
else no "series resolution :: R=$(grep -i backptr <<<"$o1") N=$(grep -i backptr <<<"$o2") other=$(grep -i backptr <<<"$o3")"; fi
c="$TMP/c23"; mkdir -p "$c"
mkrblk "$c/n-block5.md" 5 "Plain R claim."
mkblk "$c/n-bloque5.md" 5 "Plain numeric claim."
mkrblk "$c/n-block11.md" 11 "This corrige [Block R5] outright."
o1="$(run "$c/n-block11.md")"
if [ "$(warns "$o1")" = 1 ] && grep -q 'n-block5\.md' <<<"$o1" && ! grep -q 'AMBIGUOUS' <<<"$o1"; then ok "same prefix, two series: the series filter removes the other series' file"
else no "same-prefix series filter :: $(grep -i backptr <<<"$o1")"; fi
c="$TMP/c24"; mkdir -p "$c"
mkblk "$c/x-block3.md" 3 "This corrects [Block R9] outright, and also corrects [Block 9] later on."
mkrblk "$c/x-block9.md" 9 "Plain R claim."
o1="$(run "$c/x-block3.md")"
if [ "$(warns "$o1")" = 1 ] && grep -q 'block R9' <<<"$o1" && grep -q 'forward=1' <<<"$o1"; then ok "forward test is per series: [Block R9] from numeric block 3 is checked, [Block 9] is forward"
else no "cross-series forward test :: $(grep -iE 'backptr|back-pointer' <<<"$o1")"; fi

# 25 — pointer search (C2): bare R<self> is a pointer ONLY in an R-numbered corpus; a register mention R11 is not one.
c="$TMP/c25"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "The register R11 holds the value."
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright."
o1="$(run "$c/x-block11.md")"
c="$TMP/c25r"; mkdir -p "$c"
mkrblk "$c/r-block5.md" 5 "Seen again in R11 later."
mkrblk "$c/r-block11.md" 11 "This corrige [Block R5] outright."
o2="$(run "$c/r-block11.md")"
c="$TMP/c25s"; mkdir -p "$c"
mkrblk "$c/r-block5.md" 5 "Seen again in B11 only, a numeric-series pointer."
mkrblk "$c/r-block11.md" 11 "This corrige [Block R5] outright."
o3="$(run "$c/r-block11.md")"
if [ "$(warns "$o1")" = 1 ] && [ "$(warns "$o2")" = 0 ] && grep -q 'backptr-ok' <<<"$o2" && [ "$(warns "$o3")" = 1 ]; then ok "bare R<self> is a pointer only in R mode; a numeric B<self> does not point an R block"
else no "pointer series: nonR-register=$(warns "$o1") R-mode=$(warns "$o2") R-with-B=$(warns "$o3")"; fi

# 26 — confidence and modes: default prints only the high-confidence shape and counts the rest; all lists; off skips; bad value → 2.
c="$TMP/c26"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."; mkblk "$c/x-block6.md" 6 "Plain."
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright." "" "We refute the idea in B6 here."
od="$(rund "$c/x-block11.md")"; oa="$(run "$c/x-block11.md")"
oo="$(bash "$SUT" --backptr=off "$c/x-block11.md" 2>/dev/null)"; bash "$SUT" --backptr=bogus "$c/x-block11.md" >/dev/null 2>&1; rcb=$?
if [ "$(warns "$od")" = 1 ] && grep -q 'block 5' <<<"$od" && grep -qE '1 low-confidence candidate\(s\) \(--backptr=all to list\)' <<<"$od" \
   && [ "$(warns "$oa")" = 2 ] && ! grep -q 'low-confidence' <<<"$oa" \
   && [ "$(warns "$oo")" = 0 ] && grep -q 'back-pointer check off' <<<"$oo" && [ "$rcb" = 2 ]; then ok "default = high-confidence lines + one low-confidence count; all lists both; off skips; bad value rc 2"
else no "modes: default=$(warns "$od") all=$(warns "$oa") off=$(warns "$oo") bad-rc=$rcb :: $(grep -i back-pointer <<<"$od")"; fi

# 27 — DEGRADED paths: the helper missing, and a candidate directory that cannot be listed.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/verify-block.sh"
out="$(bash "$TMP/nolib/verify-block.sh" "$TMP/c1/x-block11.md" 2>/dev/null)"
if grep -qE '^ +DEGRADED backptr: helper lib/block-files\.sh unavailable' <<<"$out" && [ "$(warns "$out")" = 0 ]; then ok "helper missing → typed DEGRADED"
else no "helper-missing state :: $(grep -i backptr <<<"$out")"; fi
mkdir -p "$TMP/c27b" "$TMP/c27t"
mkblk "$TMP/c27b/x-block11.md" 11 "This corrects [Block 5] outright."
chmod 111 "$TMP/c27t"
if ls "$TMP/c27t" >/dev/null 2>&1; then ok "scan-failure state: skipped (this process can list a mode-111 directory)"
else
  out="$(bash "$SUT" "$TMP/c27b/x-block11.md" "$TMP/c27t" 2>/dev/null)"
  if grep -qE '^ +DEGRADED backptr: line [0-9]+: block 5 .*scan under .* failed' <<<"$out" && ! grep -q 'INFO    backptr' <<<"$out"; then ok "unlistable directory → typed DEGRADED, not 'not found'"
  else no "scan-failure state :: $(grep -i backptr <<<"$out")"; fi
fi

# 28 — token boundaries: a cite glued to a word on either side (AB5, B5x) is not a cite.
c="$TMP/c28"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "This corrects AB5 outright."
mkblk "$c/x-block12.md" 12 "This corrects B5x outright."
o1="$(run "$c/x-block11.md")"; o2="$(run "$c/x-block12.md")"
if [ "$(warns "$o1")" = 0 ] && [ "$(warns "$o2")" = 0 ]; then ok "AB5 and B5x are not cites"
else no "token boundaries: AB5=$(warns "$o1") B5x=$(warns "$o2")"; fi

# 29 — confidence direction (default mode): the act BEFORE a keyword cite is high; an act AFTER it is the cite's own
#      ("[Block 95] §95.9's correction") and stays a count, except as a list-item tail ("[Block 5] — corregido en …").
c="$TMP/c29"; mkdir -p "$c"
for n in 5 6 7; do mkblk "$c/x-block$n.md" "$n" "Plain."; done
mkblk "$c/x-block11.md" 11 "The result matches [Block 5] §5.9's correction exactly."
mkblk "$c/x-block12.md" 12 "- **[Block 6]** — corregido en §12.5"
mkblk "$c/x-block13.md" 13 "### Corrección al Bloque 7 (naming)"
o1="$(rund "$c/x-block11.md")"; o2="$(rund "$c/x-block12.md")"; o3="$(rund "$c/x-block13.md")"
if [ "$(warns "$o1")" = 0 ] && grep -q '1 low-confidence candidate' <<<"$o1" && [ "$(warns "$o2")" = 1 ] && [ "$(warns "$o3")" = 1 ]; then ok "act before the cite or as a list-item tail = high; a trailing noun belongs to the cite = low"
else no "confidence direction: noun-after=$(warns "$o1") tail=$(warns "$o2") heading=$(warns "$o3")"; fi

# 30 — wider negations: "no cross-block correction (unlike [Block 5])", "rather than correcting [Block 5]".
c="$TMP/c30"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "There is no cross-block INFER correction (unlike [Block 5])."
mkblk "$c/x-block12.md" 12 "It sharpens the contrast rather than correcting [Block 5] itself."
o1="$(run "$c/x-block11.md")"; o2="$(run "$c/x-block12.md")"
if [ "$(warns "$o1")" = 0 ] && [ "$(warns "$o2")" = 0 ] && grep -q 'neg=1' <<<"$o1" && grep -q 'neg=1' <<<"$o2"; then ok "'no … correction' with intervening words and 'rather than correcting' are negations (neg counted)"
else no "wider negations: o1=$(warns "$o1") o2=$(warns "$o2")"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  for _mf in mutant_chain mutant_tooth; do
    declare -F "$_mf" >/dev/null || { echo "FATAL: lib/mutant.sh did not define $_mf" >&2; exit 2; }
  done
  mk_mut(){ mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  # the mutants live in $TMP, so the SUT's lib/ must resolve beside them (as verify-block.test.sh does)
  ln -s "$HERE/../lib" "$TMP/lib"
  CRASH='integer expression expected|syntax error|unbound variable|command not found|Traceback'
  # teeth <mode> <sentinel> <label> <fixture> <sed-expr> <regex> [flag] [target]
  #   lose: the original prints <regex>, the mutant must NOT.   gain: the original lacks it, the mutant must print it.
  #   flag defaults to --backptr=all (every candidate listed); pass "-" for the DEFAULT (high) mode.
  teeth(){
    local mode="$1" s="$2" l="$3" fx="$4" ex="$5" re="$6" fl="${7:---backptr=all}" tg="${8:-}" m="$TMP/vb.mut-$3.sh"
    local -a av=(bash @SUT@); [ "$fl" = "-" ] || av+=("$fl"); av+=("$fx"); [ -z "$tg" ] || av+=("$tg")
    if ! grep -q "# $s" "$SUT"; then no "teeth-$l: sentinel $s missing from the SUT"; return; fi
    mk_mut "teeth-$l" "$SUT" "$m" "$ex" || return
    if [ "$mode" = lose ]; then
      tt "teeth-$l" 0 0 "$m" --orig "$SUT" --good-has "$re" --bad-lacks "$re|$CRASH" -- "${av[@]}"
    else
      tt "teeth-$l" 0 0 "$m" --orig "$SUT" --good-lacks "$re" --bad-has "$re" -- "${av[@]}"
    fi
  }
  echo "-- teeth: each defence neutered; the matching fixture must change verdict --"
  teeth lose BP-VERBS verbs "$TMP/c1/x-block11.md" '/# BP-VERBS/ s/refut|corrig/zzzzzz|zzzzzz/' '^ +BACKPTR\? '
  teeth lose BP-POINTER pointer "$TMP/c1/x-block11.md" '/# BP-POINTER/ s/elif grep -Eq /elif true; : /' '^ +BACKPTR\? '
  teeth gain BP-BOUNDARY boundary "$TMP/c10/x-block11.md" '/# BP-BOUNDARY/ s/(\[^0-9A-Za-z_]|/(.|/' '^ +backptr-ok'
  teeth lose BP-POINTER rmodeptr "$TMP/c25/x-block11.md" '/# BP-BOUNDARY/ s/|B)0\*/|[BR])0*/' '^ +BACKPTR\? '
  teeth lose BP-NOTFOUND notfound "$TMP/c5/x-block11.md" '/# BP-NOTFOUND/ s/INFO    backptr:/note/' '^ +INFO +backptr: line'
  teeth lose BP-AMBIG ambig "$TMP/c6/x-block11.md" '/# BP-AMBIG/ s/-gt 1/-gt 99/' '^ +BACKPTR-AMBIGUOUS'
  teeth gain BP-FORWARD forward "$TMP/c9/x-block5.md" '/# BP-FORWARD/ s/>= self/> 99999/' '^ +(BACKPTR\?|INFO +backptr:|BACKPTR-AMBIGUOUS)'
  teeth lose BP-FORWARD forwardseries "$TMP/c24/x-block3.md" '/# BP-FORWARD/ s/ds\[i\] == selfser && //' '^ +BACKPTR\? .*block R9'
  teeth gain BP-LIST list "$TMP/c18/x-block11.md" '/# BP-LIST/ s/nd >= 3 ||/0 \&\&/' '^ +BACKPTR\? '
  teeth gain BP-LIST list3 "$TMP/c18/x-block14.md" '/# BP-LIST/ s/nd >= 3 ||/nd >= 99 ||/' '^ +BACKPTR\? '
  teeth gain BP-CORRIGEND corrigend "$TMP/c17/x-block11.md" '/# BP-CORRIGEND/ s/corrigend\[a-z\]\*/zzzzzz/' '^ +(BACKPTR\? |INFO +backptr:|backptr-ok)'
  teeth gain BP-CORRECTOR corrector "$TMP/c19/x-block11.md" '/# BP-CORRECTOR/ s/ctx ~ /ctx ~ \/zzzz\/ \&\& ctx ~ /' '^ +BACKPTR\? '
  teeth gain BP-NEG neg "$TMP/c20/x-block11.md" '/# BP-NEG:/ s/(no|not a|without|ninguna?)/(zzzz)/' '^ +BACKPTR\? '
  teeth gain BP-NEG2 neg2 "$TMP/c20/x-block12.md" '/# BP-NEG2/ s/(nothing|without|never|rather than/(zzzzzzz|zzzzzzz|zzzzzzz|zzzzzzzzzzz/' '^ +BACKPTR\? '
  teeth gain BP-NEG3 neg3 "$TMP/c20/x-block15.md" '/# BP-NEG3/ s/nothing|nada/zzzzzzz|zzzz/' '^ +BACKPTR\? '
  teeth lose BP-NEG2 notonly "$TMP/c20/x-block16.md" '/# BP-NEG2/ s/\[^a-z\]not (only|just|merely)/[^a-z]zzz (only|just|merely)/' '^ +BACKPTR\? '
  teeth lose BP-NEG2 leftbound "$TMP/c20/x-block17.md" '/# BP-NEG2/ s/"\[^a-z\](nothing/"(nothing/' '^ +BACKPTR\? '
  teeth gain BP-SELF self "$TMP/c20/x-block14.md" '/# BP-SELF/ s/self-correct\[a-z\]\*|auto/zzzzzz|auto/' '^ +BACKPTR\? '
  teeth gain BP-PASSIVE passive "$TMP/c20/x-block13.md" '/# BP-PASSIVE/ s/(was|were|been/(zzzz|zzzz|zzzz/' '^ +BACKPTR\? '
  teeth lose BP-PASSIVE passiveaux "$TMP/c20/x-block18.md" '/# BP-PASSIVE/ s/(was|were|been|/(was|were|been|later|/' '^ +BACKPTR\? '
  teeth gain BP-PROXIMITY proximity "$TMP/c21/x-block11.md" '/# BP-PROXIMITY/ s/mg > 60/mg > 99999/' '^ +BACKPTR\? '
  teeth gain BP-RMODE rmode "$TMP/c13b/r-block11.md" '/# BP-RMODE/ s/!rmode/0/' '^ +BACKPTR\? '
  teeth gain BP-PRETOK pretok "$TMP/c28/x-block11.md" '/# BP-PRETOK/ s/isw(pre)/0/' '^ +BACKPTR\? '
  teeth gain BP-POSTTOK posttok "$TMP/c28/x-block12.md" '/# BP-POSTTOK/ s/post ~ \/\[A-Za-z_\]\//post ~ \/zzzzzz\//' '^ +BACKPTR\? '
  teeth gain BP-PREFIX prefix "$TMP/c7/x-block11.md" '/# BP-PREFIX/ s/pass" = same/pass" = nosuch/' '^ +BACKPTR-AMBIGUOUS'
  teeth gain BP-SERIES series "$TMP/c23/n-block11.md" '/# BP-SERIES/ s/!= "\$_vb_bp_ser"/!= "$_vb_bp_fs"/' '^ +BACKPTR-AMBIGUOUS'
  teeth gain BP-CONF confdir "$TMP/c29/x-block11.md" '/# BP-CONF/ s/(before ||/(1 ||/' '^ +BACKPTR\? ' -
  teeth gain BP-NEG negwide "$TMP/c30/x-block11.md" '/# BP-NEG:/ s/(\[^\[:space:]]+\[\[:space:]]+)?(\[^\[:space:]]+\[\[:space:]]+)?(correction/(correction/' '^ +BACKPTR\? '
  teeth lose BP-CONF conf "$TMP/c26/x-block11.md" '/# BP-CONF/ s/mg <= 25/mg <= 0/' '^ +BACKPTR\? .*block 5' -
  if ls "$TMP/c27t" >/dev/null 2>&1; then echo "  (teeth-scanbad skipped: this process can list a mode-111 directory)"
  else teeth gain BP-SCANBAD scanbad "$TMP/c27b/x-block11.md" '/# BP-SCANBAD/ s/scanbad" = 1/scanbad" = 99/' '^ +INFO +backptr: line' - "$TMP/c27t"; fi
  teeth gain BP-GREPRC greprc "$TMP/c1/x-block11.md" '/# BP-POINTER/ s/"\$_vb_bp_old" 2>/"$_vb_bp_old.nope" 2>/' '^ +DEGRADED backptr: line [0-9]+: block 5 .*could not be read by grep'
  if [ -r "$TMP/c8/x-block5.md" ]; then echo "  (teeth-unreadable skipped: this process can read a mode-000 file)"
  else teeth gain BP-UNREADABLE unreadable "$TMP/c8/x-block11.md" '/# BP-UNREADABLE/ s/\[ ! -r "\$_vb_bp_old" \]/false/' 'could not be read by grep'; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
