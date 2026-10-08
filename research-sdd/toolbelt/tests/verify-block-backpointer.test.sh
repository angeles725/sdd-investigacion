#!/usr/bin/env bash
# verify-block-backpointer.test.sh — RED-FIRST harness for the §14 back-pointer check in verify-block.sh (kit #1962).
#
# Contract under test: when a block says, in ONE sentence, a correction verb (REFUT* / corrig* / correg* /
# correct* / supersed*, case-insensitive, Spanish + English) AND cites an EARLIER block (`[Block N]`, `Block N`,
# `Bloque N`, `bloqueN`, `BN`; bare `RN` only in an R-numbered corpus whose H1 is `# Block R<n>`), the cited
# block's file is resolved in the same corpus (lib/block-files.sh predicate, same prefix first) and verify-block.sh
# prints a typed `BACKPTR?` WARN when that block holds no back-pointer to the checked block. ADVISORY: the exit
# code never changes. Typed non-verdicts (never silent): file not found (INFO), several candidates
# (BACKPTR-AMBIGUOUS), unreadable (DEGRADED). The EPHEMERAL! default-FAIL (#1660) is untouched.
#
# Usage: verify-block-backpointer.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-block.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# run <block> [sut]: prints stdout; the exit code is left in RC (so call it as `out="$(run ...)"; rc` via runrc).
run(){ bash "${2:-$SUT}" "$1" 2>/dev/null; }
mkblk(){ # mkblk <file> <N> <body-lines...> : header legend + body
  local f="$1" n="$2"; shift 2
  { echo "# Block $n — t"; echo; echo "> Type: evidence. Method: [CERT] = x."; echo; echo "---"; echo; printf '%s\n' "$@"; } > "$f"; }
warns(){ grep -cE '^ +BACKPTR\? ' <<<"$1"; }

echo "== verify-block-backpointer.test.sh =="

# 1 — REFUT + [Block 5] in block 11, block 5 has no pointer to 11 → WARN naming both, exit unchanged (0).
c="$TMP/c1"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Claim A is the home of blocks."
mkblk "$c/x-block11.md" 11 "The manifest REFUTES the home claim of [Block 5] for good."
out="$(run "$c/x-block11.md")"; bash "$SUT" "$c/x-block11.md" >/dev/null 2>&1; rc=$?
if grep -qE '^ +BACKPTR\? +line [0-9]+: .*block 5 .*x-block5\.md.*B11' <<<"$out" && [ "$rc" = 0 ]; then ok "REFUT + [Block 5], no pointer → BACKPTR? WARN, exit 0"
else no "missing WARN or rc=$rc :: $(grep -i backptr <<<"$out")"; fi

# 2 — the old block carries 'corregido en [Block 11]' → pointer found, no WARN.
c="$TMP/c2"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Claim A. Corregido en [Block 11]."
mkblk "$c/x-block11.md" 11 "The manifest REFUTES the home claim of [Block 5] for good."
out="$(run "$c/x-block11.md")"
if [ "$(warns "$out")" = 0 ] && grep -qE 'backptr-ok +line [0-9]+: block 5' <<<"$out"; then ok "pointer present → backptr-ok, no WARN"
else no "pointer present but flagged/unreported :: $(grep -i backptr <<<"$out")"; fi

# 3 — verb families and citation forms, one fixture each; every one must WARN exactly once.
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

# 5 — block N file not found → typed INFO, not silent and not a WARN.
c="$TMP/c5"; mkdir -p "$c"
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright."
out="$(run "$c/x-block11.md")"
if grep -qE '^ +INFO +backptr: line [0-9]+ cites block 5 .*not found' <<<"$out" && [ "$(warns "$out")" = 0 ]; then ok "block file not found → typed INFO"
else no "not-found state :: $(grep -i backptr <<<"$out")"; fi

# 6 — two other-prefix candidates for block 5 → typed ambiguous, no WARN.
c="$TMP/c6"; mkdir -p "$c"
mkblk "$c/a-block5.md" 5 "Plain."; mkblk "$c/b-bloque5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright."
out="$(run "$c/x-block11.md")"
if grep -qE '^ +BACKPTR-AMBIGUOUS +line [0-9]+: block 5 .*a-block5\.md.*b-bloque5\.md' <<<"$out" && [ "$(warns "$out")" = 0 ]; then ok "multiple candidates → BACKPTR-AMBIGUOUS"
else no "ambiguous state :: $(grep -i backptr <<<"$out")"; fi

# 7 — same-prefix candidate wins over an other-prefix one (no ambiguity).
c="$TMP/c7"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."; mkblk "$c/other-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright."
out="$(run "$c/x-block11.md")"
if [ "$(warns "$out")" = 1 ] && ! grep -q 'BACKPTR-AMBIGUOUS' <<<"$out" && grep -q 'x-block5\.md' <<<"$out"; then ok "same-prefix candidate preferred"
else no "prefix preference :: $(grep -i backptr <<<"$out")"; fi

# 8 — unreadable candidate → typed DEGRADED (skipped when the process can read a mode-000 file, e.g. root).
c="$TMP/c8"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."; chmod 000 "$c/x-block5.md"
mkblk "$c/x-block11.md" 11 "This corrects [Block 5] outright."
if [ -r "$c/x-block5.md" ]; then ok "unreadable state: skipped (this process can read a mode-000 file)"
else
  out="$(run "$c/x-block11.md")"
  if grep -qE '^ +DEGRADED +backptr: line [0-9]+: block 5 .*unreadable' <<<"$out" && [ "$(warns "$out")" = 0 ]; then ok "unreadable candidate → typed DEGRADED"
  else no "degraded state :: $(grep -i backptr <<<"$out")"; fi
fi
chmod 644 "$c/x-block5.md"

# 9 — self-cite and forward cite are skipped (the correction goes to an EARLIER block), and counted, not silent.
c="$TMP/c9"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain." "Block B11 later refutes this claim, and this claim supersedes B5 itself."
mkblk "$c/x-block11.md" 11 "Plain."
out="$(run "$c/x-block5.md")"
if [ "$(warns "$out")" = 0 ] && grep -qE 'skipped [1-9][0-9]* (self|forward)' <<<"$out"; then ok "self/forward cites skipped and counted"
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
mkblk "$c/r-block5.md" 5 "Plain."
{ echo "# Block R11 — t"; echo; echo "This corrige R5.1 in full."; } > "$c/r-block11.md"
out="$(run "$c/r-block11.md")"
c2="$TMP/c13b"; mkdir -p "$c2"
mkblk "$c2/r-block5.md" 5 "Plain."
{ echo "# Block 11 — t"; echo; echo "This corrects the value held in R5 after the call."; } > "$c2/r-block11.md"
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
out="$(run "$c/x-block11.md")"; bash "$SUT" "$c/x-block11.md" >/dev/null 2>&1; rc_def=$?
out_w="$(bash "$SUT" --ephemeral=warn "$c/x-block11.md" 2>/dev/null)"; bash "$SUT" --ephemeral=warn "$c/x-block11.md" >/dev/null 2>&1; rc_w=$?
if [ "$rc_def" = 1 ] && grep -q 'EPHEMERAL!' <<<"$out" && [ "$rc_w" = 0 ] && grep -q 'EPHEMERAL?' <<<"$out_w" \
   && [ "$(warns "$out")" = 1 ] && [ "$(warns "$out_w")" = 1 ]; then ok "EPHEMERAL! FAIL default / opt-out WARN unchanged; BACKPTR? never moves rc"
else no "ephemeral interaction: rc_def=$rc_def rc_warn=$rc_w :: $(grep -E 'EPHEMERAL|BACKPTR' <<<"$out")"; fi

# 16 — candidate resolved in the target dir when the checked block lives in a sub-directory.
c="$TMP/c16"; mkdir -p "$c/notes"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/notes/x-block11.md" 11 "This corrects [Block 5] outright."
out="$(bash "$SUT" "$c/notes/x-block11.md" "$c" 2>/dev/null)"
if [ "$(warns "$out")" = 1 ]; then ok "candidate resolved in the target dir"
else no "target-dir resolution :: $(grep -i backptr <<<"$out")"; fi

# 17 — adverb / adjective / noun forms are not correction acts (fleet sweep): "correctly", "correcto", "corrigendum".
c="$TMP/c17"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "It resolves correctly on the modules of [Block 5]." "" "El FE correcto se ve en B5." "" "Hay un corrigendum de B5 abajo."
out="$(run "$c/x-block11.md")"
if [ "$(warns "$out")" = 0 ] && grep -qE '^ +\(none — ' <<<"$out"; then ok "correctly / correcto / corrigendum are not correction acts"
else no "adverb/adjective/noun handling :: $(grep -i backptr <<<"$out")"; fi

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
if [ "$(warns "$out")" = 0 ] && grep -qE '1 cross-reference-list sentence' <<<"$out" && [ "$(warns "$out2")" = 2 ] \
   && [ "$(warns "$out3")" = 0 ] && [ "$(warns "$out4")" = 0 ]; then ok "cross-reference lists skipped and counted; a 2-block correction still counts"
else no "list handling: 4-cite=$(warns "$out") 2-cite=$(warns "$out2") connects2=$(warns "$out3") 3-cite=$(warns "$out4") :: $(grep -i 'back-pointer' <<<"$out")"; fi

# 19 — the CORRECTOR is not the corrected: "corrected by [Block 3]" / "corregido en B3" name the fixer, not a target.
c="$TMP/c19"; mkdir -p "$c"
for n in 3 4; do mkblk "$c/x-block$n.md" "$n" "Plain."; done
mkblk "$c/x-block11.md" 11 "The 8 panels rule was corrected by [Block 3]." "" "Segun la nota, valor corregido en B4."
out="$(run "$c/x-block11.md")"
if [ "$(warns "$out")" = 0 ] && ! grep -q 'backptr-ok' <<<"$out"; then ok "cite after 'corrected by' / 'corregido en' is the corrector, skipped"
else no "corrector handling :: $(grep -i backptr <<<"$out")"; fi

# 20 — negations assert the absence of a correction; passive / third-party / self corrections are not THIS block's act.
c="$TMP/c20"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "No §14 correction: this corroborates [Block 5]."
mkblk "$c/x-block12.md" 12 "Nothing here refutes B5."
mkblk "$c/x-block13.md" 13 "The figure of B5 was corrected earlier."
mkblk "$c/x-block14.md" 14 "This is the lesson again (B5 self-correction)."
mkblk "$c/x-block15.md" 15 "This block corrects nothing in B5."
out="$(run "$c/x-block11.md")"; out2="$(run "$c/x-block12.md")"; out3="$(run "$c/x-block13.md")"; out4="$(run "$c/x-block14.md")"; out5="$(run "$c/x-block15.md")"
if [ "$(warns "$out")" = 0 ] && [ "$(warns "$out2")" = 0 ] && [ "$(warns "$out3")" = 0 ] && [ "$(warns "$out4")" = 0 ] && [ "$(warns "$out5")" = 0 ]; then ok "negated / passive / self corrections are not a correction act"
else no "negation handling: no=$(warns "$out") nothing=$(warns "$out2") passive=$(warns "$out3") self=$(warns "$out4") corrects-nothing=$(warns "$out5")"; fi

# 21 — proximity: a verb 60+ characters away from the cite belongs to another clause.
c="$TMP/c21"; mkdir -p "$c"
mkblk "$c/x-block5.md" 5 "Plain."
mkblk "$c/x-block11.md" 11 "We refute the timing guess here and then go on to describe at considerable length the unrelated setup of the lab bench, which only echoes B5."
out="$(run "$c/x-block11.md")"
mkblk "$c/x-block12.md" 12 "We refute the timing guess of B5 here."
out2="$(run "$c/x-block12.md")"
if [ "$(warns "$out")" = 0 ] && [ "$(warns "$out2")" = 1 ]; then ok "verb must sit within 60 characters of the cite"
else no "proximity: far=$(warns "$out") near=$(warns "$out2")"; fi

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
  # teeth <mode> <sentinel> <label> <fixture> <sed-expr> <regex>
  #   lose: the original prints <regex>, the mutant must NOT.   gain: the original lacks it, the mutant must print it.
  teeth(){
    local mode="$1" s="$2" l="$3" fx="$4" ex="$5" re="$6" m="$TMP/vb.mut-$3.sh"
    if ! grep -q "# $s" "$SUT"; then no "teeth-$l: sentinel $s missing from the SUT"; return; fi
    mk_mut "teeth-$l" "$SUT" "$m" "$ex" || return
    if [ "$mode" = lose ]; then
      tt "teeth-$l" 0 0 "$m" --orig "$SUT" --good-has "$re" --bad-lacks "$re|$CRASH" -- bash @SUT@ "$fx"
    else
      tt "teeth-$l" 0 0 "$m" --orig "$SUT" --good-lacks "$re" --bad-has "$re" -- bash @SUT@ "$fx"
    fi
  }
  echo "-- teeth: each defence neutered; the matching fixture must change verdict --"
  teeth lose BP-VERBS verbs "$TMP/c1/x-block11.md" '/# BP-VERBS/ s/refut|corrig/zzzzzz|zzzzzz/' '^ +BACKPTR\? '
  teeth lose BP-POINTER pointer "$TMP/c1/x-block11.md" '/# BP-POINTER/ s/if grep -Eq /if true; : /' '^ +BACKPTR\? '
  teeth lose BP-NOTFOUND notfound "$TMP/c5/x-block11.md" '/# BP-NOTFOUND/ s/INFO    backptr:/note/' '^ +INFO +backptr: line'
  teeth lose BP-AMBIG ambig "$TMP/c6/x-block11.md" '/# BP-AMBIG/ s/-gt 1/-gt 99/' '^ +BACKPTR-AMBIGUOUS'
  teeth gain BP-FORWARD forward "$TMP/c9/x-block5.md" '/# BP-FORWARD/ s/>= self/> 99999/' '^ +(BACKPTR\?|INFO +backptr:|BACKPTR-AMBIGUOUS)'
  teeth gain BP-POINTER boundary "$TMP/c10/x-block11.md" '/# BP-POINTER/ s/(\[^0-9A-Za-z_]|/(.|/' '^ +backptr-ok'
  teeth gain BP-LIST list "$TMP/c18/x-block11.md" '/# BP-LIST/ s/nd >= 3 ||/0 \&\&/' '^ +BACKPTR\? '
  teeth gain BP-LIST list3 "$TMP/c18/x-block14.md" '/# BP-LIST/ s/nd >= 3 ||/nd >= 99 ||/' '^ +BACKPTR\? '
  teeth gain BP-CORRIGEND corrigend "$TMP/c17/x-block11.md" '/# BP-CORRIGEND/ s/corrigend\[a-z\]\*/zzzzzz/' '^ +(BACKPTR\? |INFO +backptr:|backptr-ok)'
  teeth gain BP-CORRECTOR corrector "$TMP/c19/x-block11.md" '/# BP-CORRECTOR/ s/ctx ~ /ctx ~ \/zzzz\/ \&\& ctx ~ /' '^ +BACKPTR\? '
  teeth gain BP-NEG neg "$TMP/c20/x-block11.md" '/# BP-NEG:/ s/(no|not a|without|ninguna?)/(zzzz)/' '^ +BACKPTR\? '
  teeth gain BP-NEG2 neg2 "$TMP/c20/x-block12.md" '/# BP-NEG2/ s/(nothing|without|never|not|no|nada)/(zzzzzzz)/' '^ +BACKPTR\? '
  teeth gain BP-SELF self "$TMP/c20/x-block14.md" '/# BP-SELF/ s/self-correct\[a-z\]\*|auto/zzzzzz|auto/' '^ +BACKPTR\? '
  teeth gain BP-NEG3 neg3 "$TMP/c20/x-block15.md" '/# BP-NEG3/ s/nothing|nada/zzzzzzz|zzzz/' '^ +BACKPTR\? '
  teeth gain BP-PASSIVE passive "$TMP/c20/x-block13.md" '/# BP-PASSIVE/ s/(was|were|been/(zzzz|zzzz|zzzz/' '^ +BACKPTR\? '
  teeth gain BP-PROXIMITY proximity "$TMP/c21/x-block11.md" '/# BP-PROXIMITY/ s/gap <= 60/gap <= 9999/' '^ +BACKPTR\? '
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
