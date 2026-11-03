#!/usr/bin/env bash
# verify-corrections-residuals.test.sh — residual precision classes for verify-corrections.sh (#1874).
#
# Companion to verify-corrections-precision.test.sh (#1868). The classes below were MEASURED on real corpora after #1875
# (niagara-research, 2026-10-06) or deferred by the #1868 PR gate. The headline fixture `real-1874/` carries the cited real
# lines VERBATIM (copied read-only from niagara-research; the targets themselves are never edited):
#   1. noun backlink      `**CORRECCIÓN (2026-07-26) — [Block 292].**` in the corrected block      -> accepted backlink
#   2. joined-list postfix `[Block 50]/[Block 51] (**corrige** el framework …)`                   -> first ref checked, the rest AMBIG
#   3. negations          `corrects nothing in B21`, `Corrects no claim in B402`, `no corrige`     -> declare nothing
#   4. bracketed ref after a leading bare ref  `Corrects B6 and [Block 12] §3`                     -> checked (advisory), never vanishes
#   5. soft-slug FAIL     a FAIL that resulted from the soft-slug fallback names the way out
#   6. possessive in an aside `Corrects, per this run's review, the claim in [Block 8]`            -> plain declaration
#   7. code identifier    `Corrects \`decode_frame\` [Block 8]`                                    -> strict lookup, not a hard slug
#   (The old case 8, the same corpus under mawk, is gone: the port has no awk. The mutants of the old awk program are
#   replaced by `make teeth` on the Go source; the cases run through the shim against the real Go binary, RSDD_BIN.)
#
# Usage: verify-corrections-residuals.test.sh   Exit: 0 all held · 1 regression · 2 harness.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-corrections.sh"
FIX="$HERE/fixtures/verify-corrections"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -d "$FIX/real-1874" ] || { echo "FATAL: fixture dir missing: $FIX/real-1874" >&2; exit 2; }
# The Go binary the shim execs: the caller's RSDD_BIN, else one build into the temp dir.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  _vc_bin_dir="$(mktemp -d)"; trap 'rm -rf "${_vc_bin_dir:-}"' EXIT   # cleaned even when the build below fails
  ( cd "$HERE/../../rsdd" && go build -o "$_vc_bin_dir/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$_vc_bin_dir/rsdd"
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" "${_vc_bin_dir:-}"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
run(){ bash "$SUT" "$1" 2>&1; }
code(){ bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }
# pmk <dir> <prefix> <num> <printf-format> [args] — write <prefix>-block<num>.md (no trailing newline added).
pmk(){ mkdir -p "$1"; printf "$4" "${@:5}" > "$1/$2-block$3.md"; }
# pblank <dir> <prefix> <num>... — unannotated target blocks.
pblank(){ local d="$1" p="$2"; shift 2; local n; mkdir -p "$d"; for n in "$@"; do printf '# Block %s\n\nOriginal claim.\n' "$n" > "$d/$p-block$n.md"; done; }

echo "== verify-corrections-residuals.test.sh (SUT: $(basename "$SUT")) =="
REAL="$TMP/real"; cp -r "$FIX/real-1874" "$REAL"
rout="$(run "$REAL")"

# 1 — NOUN BACKLINK (real niagara-mental-model-bloque189.md:94-96,128). B292 declares `Corrects [Block 189]`; B189 carries
#     `**CORRECCIÓN (2026-07-26) — [Block 292].**`. Reciprocated: no FAIL for the pair.
if ! grep -qE 'FAIL +B292 ' <<<"$rout"; then ok "real B292→B189: 'CORRECCIÓN (date) — [Block 292]' is an accepted backlink (no false FAIL)"
else no "real noun backlink :: $(grep -E 'B292' <<<"$rout" | tr '\n' '|')"; fi
# 1b — SHAPE IS STRICT: the noun must be followed directly by the ref of the correcting block. A noun naming ANOTHER block, a bare
#      word `correction` in prose, or the noun with the right ref only later in the line are NOT backlinks.
nb_ok=1; nb_bad=""; i=0
for _s in '> **CORRECCIÓN (2026-07-26) — [Block 99].** body.' 'A correction of the earlier claim was considered, see B4.' \
          '> Correction: the claim was revised; see the history of [Block 4] for details.' '> Correction (2026-01-01) of B4 is pending.' \
          'Correction: [Block 4] was wrong about the default.' 'Correction — [Block 4] was wrong about the default.' 'A miscorrection — [Block 4].' \
          'Correction — [Block 4]: the default was wrong.' 'Correction — [Block 4], which overstated the default.'; do
  i=$((i+1)); d="$TMP/nb-neg$i"; pblank "$d" t 8; pmk "$d" t 4 '# Block 4\n\n> Corrects [Block 8] §1.\n'
  printf '\n%s\n' "$_s" >> "$d/t-block8.md"
  grep -qE 'FAIL +B4 corrects \[Block 8\] ' < <(run "$d") || { nb_ok=0; nb_bad="$nb_bad [$i]"; }
done
if [ "$nb_ok" = 1 ]; then ok "noun backlink shape is strict: another block's ref / prose / a later ref are not backlinks (the pair still FAILs)"
else no "noun-neg :: $nb_bad"; fi
# 1c — the accepted noun shapes, in FIRST / MIDDLE / LAST line position (no trailing newline on the last), Spanish + English,
#      with and without the parenthetical tag, separator and bold markers.
nb_ok=1; nb_bad=""; i=0
for _s in '**CORRECCIÓN (2026-07-26) — [Block 4].** body' 'Correction (2026-01-01) — [Block 4].' '> Corrección — [Bloque 4] §4.2' 'CORRECTION [Block 4].' 'correcci\303\263n - [Block 04]'; do
  i=$((i+1))
  for _pos in first middle last; do
    d="$TMP/nb-pos$i$_pos"; mkdir -p "$d"; pmk "$d" t 4 '# Block 4\n\n> Corrects [Block 8] §1.\n'
    case "$_pos" in
      first)  printf "$_s\n\nOriginal.\n" > "$d/t-block8.md" ;;
      middle) printf "# Block 8\n\n$_s\n\nTail.\n" > "$d/t-block8.md" ;;
      last)   printf "# Block 8\n\n$_s" > "$d/t-block8.md" ;;
    esac
    [ "$(code "$d")" = 0 ] || { nb_ok=0; nb_bad="$nb_bad [$i/$_pos]"; }
  done
done
if [ "$nb_ok" = 1 ]; then ok "noun backlink accepted in 5 shapes × first/middle/last line (exit 0)"; else no "noun-pos :: $nb_bad"; fi

# 2 — JOINED-LIST POSTFIX (real niagara-mental-model-bloque153.md:24-25). The correction clause sits in the parenthetical that
#     follows the WHOLE list `[Block 50]/[Block 51]`: the FIRST ref is checked, every later ref of that list is a typed AMBIG.
if ! grep -qE 'FAIL +B153 ' <<<"$rout" && grep -qE '^ *AMBIG +B153 corrects \[Block 51\] ' <<<"$rout"; then
  ok "real B153: '[Block 50]/[Block 51] (corrige …)' → no false FAIL on B51, typed AMBIG instead"
else no "real joined-list :: $(grep -E 'B153' <<<"$rout" | tr '\n' '|')"; fi
# 2b — the FIRST ref is still really checked (a gap on it FAILs), in both list shapes; the non-first one never FAILs.
jl_ok=1; jl_bad=""; i=0
for _j in '[Block 5]/[Block 6]' '[Block 5] and [Block 6]'; do
  i=$((i+1)); d="$TMP/jl$i"; pblank "$d" t 5 6; pmk "$d" t 9 '# Block 9\n\n> See %s (corrige the framework version).\n' "$_j"
  out="$(run "$d")"
  { grep -qE 'FAIL +B9 corrects \[Block 5\] ' <<<"$out" && ! grep -qE 'FAIL +B9 corrects \[Block 6\] ' <<<"$out" \
    && grep -qE '^ *AMBIG +B9 corrects \[Block 6\] ' <<<"$out"; } || { jl_ok=0; jl_bad="$jl_bad [$i]"; }
done
if [ "$jl_ok" = 1 ]; then ok "postfix over a joined list: first ref FAILs on a gap, later refs are AMBIG (never FAIL)"; else no "joined :: $jl_bad"; fi
# 2c — a SINGLE ref before the parenthetical is unchanged (FAIL), and a 3-list marks refs 2 and 3 (list edges).
d="$TMP/jl-one"; pblank "$d" t 5; pmk "$d" t 9 '# Block 9\n\n> See [Block 5] (corrige the framework version).\n'
d3="$TMP/jl-three"; pblank "$d3" t 5 6 7; pmk "$d3" t 9 '# Block 9\n\n> See [Block 5]/[Block 6]/[Block 7] (corrige the framework version).\n'
o3="$(run "$d3")"
if grep -qE 'FAIL +B9 corrects \[Block 5\] ' < <(run "$d") \
   && grep -qE 'FAIL +B9 corrects \[Block 5\] ' <<<"$o3" && grep -qE '^ *AMBIG +B9 corrects \[Block 6\] ' <<<"$o3" && grep -qE '^ *AMBIG +B9 corrects \[Block 7\] ' <<<"$o3"; then
  ok "single postfix ref still FAILs; a 3-list checks ref 1 and marks refs 2 and 3 AMBIG"
else no "jl-one/three :: $(tr '\n' '|' <<<"$o3")"; fi
# 2d — a FORWARD joined list is unchanged: the verb precedes the list, so EVERY ref is a declaration.
d="$TMP/jl-fwd"; pblank "$d" t 5 6; pmk "$d" t 9 '# Block 9\n\n> Corrects [Block 5]/[Block 6] §1.\n'
out="$(run "$d")"
if grep -qE 'FAIL +B9 corrects \[Block 5\] ' <<<"$out" && grep -qE 'FAIL +B9 corrects \[Block 6\] ' <<<"$out"; then ok "forward joined list: every ref still checked (FAIL x2)"
else no "jl-fwd :: $(tr '\n' '|' <<<"$out")"; fi

# 2e — the backward walk of a postfix list stops at a sentence break (`. `, `;`, `·`): `Per [Block 3]. And [Block 1] (which corrects §2)`
#      declares [Block 1] only; [Block 3] is a different sentence.
sb_ok=1; sb_bad=""; i=0
for _s in 'Per [Block 3]. And [Block 1] (which corrects §2).' 'Per [Block 3]; and [Block 1] (which corrects §2).' 'Per [Block 3] · and [Block 1] (which corrects §2).'; do
  i=$((i+1)); d="$TMP/sb$i"; pblank "$d" t 1 3; pmk "$d" t 9 '# Block 9\n\n> %s\n' "$_s"
  out="$(run "$d")"
  { grep -qE 'FAIL +B9 corrects \[Block 1\] ' <<<"$out" && ! grep -qE 'B9 corrects \[Block 3\]' <<<"$out"; } || { sb_ok=0; sb_bad="$sb_bad [$i]"; }
done
if [ "$sb_ok" = 1 ]; then ok "postfix list walk stops at '. ' / ';' / '·': the earlier sentence's ref is not the declaration"; else no "sentence-break :: $sb_bad"; fi

# 3 — NEGATIONS (real niagara-mental-model-bloque406.md:406, bloque408.md:538): declare nothing, not even AMBIG.
if ! grep -qE 'B406|B408' <<<"$(grep -E '^ *(FAIL|AMBIG|WARN)' <<<"$rout")" && grep -qE 'negated.*: B406, B408' <<<"$rout" && grep -qE 'ok-partial +3 declared' <<<"$rout"; then
  ok "real B406/B408: 'corrects nothing in B21' / 'Corrects no claim in B402' → no FAIL/AMBIG/WARN; a note names B406, B408 and ok-partial counts them"
else no "real negation :: $(grep -E 'B406|B408|negat' <<<"$rout" | tr '\n' '|')"; fi
ng_ok=1; ng_bad=""; i=0
for _s in 'This corrects nothing in [Block 8].' 'Corrects no claim in [Block 8].' 'No corrige nada en [Block 8].' 'Esto no corrige [Block 8].' 'It never corrects [Block 8].' 'Corrige ninguna afirmación de [Block 8].'; do
  i=$((i+1)); d="$TMP/neg$i"; pblank "$d" t 8; pmk "$d" t 4 '# Block 4\n\n> %s\n' "$_s"
  out="$(run "$d")"
  { [ "$(code "$d")" = 0 ] && ! grep -qE '^ *(FAIL|AMBIG|WARN)' <<<"$out" && grep -qE 'negated.*: B4$' <<<"$out" && grep -qE 'ok-partial +1 declared' <<<"$out"; } || { ng_ok=0; ng_bad="$ng_bad [$i]"; }
done
if [ "$ng_ok" = 1 ]; then ok "6 negation shapes (EN/ES, leading and trailing) declare nothing: exit 0, no FAIL/AMBIG/WARN, named in the note and counted in ok-partial"; else no "neg :: $ng_bad"; fi
# 3a — SWALLOWED DECLARATIONS (Opus gate): `no`/`nothing` right after the verb that does NOT negate it must stay a declaration.
sw_ok=1; sw_bad=""; i=0
for _s in 'Corrects no longer valid claim in [Block 21].' 'Corrects nothing but the date in [Block 21].' 'Corrige no solo [Bloque 21] sino también [Bloque 22].' \
          'Corrects no fewer than three claims in [Block 21].' 'Corrige nada excepto la fecha de [Block 21].' 'Corrects none other than [Block 21].' \
          'No corrige nada salvo la fecha de [Bloque 21].' 'No corrige nada excepto la fecha de [Bloque 21].' 'It never corrects anything but the date in [Block 21].'; do
  i=$((i+1)); d="$TMP/swal$i"; pblank "$d" t 21 22; pmk "$d" t 4 '# Block 4\n\n> %s\n' "$_s"
  out="$(run "$d")"
  { grep -qE 'FAIL +B4 corrects \[Block 21\] ' <<<"$out" && ! grep -q 'negated' <<<"$out"; } || { sw_ok=0; sw_bad="$sw_bad [$i]"; }
done
if [ "$sw_ok" = 1 ]; then ok "9 shapes where no/nothing does not negate the verb ('no longer', 'nothing but', 'no solo', 'no fewer', 'excepto', 'No corrige nada salvo', 'never … anything but') stay declarations (FAIL)"; else no "swallowed :: $sw_bad"; fi
# 3b — a negation word that does NOT negate the verb must not hide a real declaration.
nn_ok=1; nn_bad=""; i=0
for _s in 'Corrects [Block 8] §1, no longer valid.' 'No further notes; corrects [Block 8] §1.' 'Corrige [Block 8], nada más.'; do
  i=$((i+1)); d="$TMP/nneg$i"; pblank "$d" t 8; pmk "$d" t 4 '# Block 4\n\n> %s\n' "$_s"
  grep -qE 'FAIL +B4 corrects \[Block 8\] ' < <(run "$d") || { nn_ok=0; nn_bad="$nn_bad [$i]"; }
done
if [ "$nn_ok" = 1 ]; then ok "a 'no'/'nada' elsewhere in the sentence does not suppress a real declaration (still FAIL)"; else no "non-neg :: $nn_bad"; fi

# 4 — A BRACKETED REF AFTER A LEADING BARE REF (#1868 gate, deferred). `Corrects B6 and [Block 12] §3` took the bare path and
#     [Block 12] vanished. It is now checked as an advisory (never a refusal): unreciprocated → typed AMBIG, reciprocated → silent.
bm_ok=1; bm_bad=""; i=0
for _s in 'Corrects B6 and [Block 12] §3.' 'Corrects B6/[Block 12].' 'Corrige B6 y [Bloque 12] §3.'; do
  i=$((i+1)); d="$TMP/bm$i"; pblank "$d" t 6 12; pmk "$d" t 4 '# Block 4\n\n> %s\n' "$_s"
  out="$(run "$d")"
  { grep -qE '^ *AMBIG +B4 corrects \[Block 12\] .*bracketed' <<<"$out" && ! grep -qE '^ *FAIL' <<<"$out" && [ "$(code "$d")" = 0 ]; } || { bm_ok=0; bm_bad="$bm_bad [$i]"; }
done
if [ "$bm_ok" = 1 ]; then ok "bare B6 + joined [Block 12] (3 shapes): [Block 12] is a typed AMBIG, never silent, never a refusal"; else no "bare+bracket :: $bm_bad"; fi
d="$TMP/bm-rec"; pblank "$d" t 6; pmk "$d" t 12 '# Block 12\n\nOriginal.\n\n> corrected in B4.\n'; pmk "$d" t 4 '# Block 4\n\n> Corrects B6 and [Block 12] §3.\n'
out="$(run "$d")"
if ! grep -qE 'AMBIG +B4 corrects \[Block 12\]' <<<"$out" && grep -qE 'AMBIG +B4 corrects \[Block 6\] ' <<<"$out"; then ok "the joined bracketed ref IS checked: reciprocated → silent (the bare B6 still AMBIG)"
else no "bm-rec :: $(tr '\n' '|' <<<"$out")"; fi
# 4b — a bracket that is a cross-reference (words between) is still NOT a target (the #1868 shape must not regress).
d="$TMP/bm-xref"; pblank "$d" t 6 34; pmk "$d" t 4 '# Block 4\n\n> Corrects my own B6 §6.7, which walked into a trap [Block 34] had described.\n'
if ! grep -qE 'Block 34' < <(run "$d"); then ok "a cross-reference bracket after prose is not swept into the bare list"; else no "bm-xref :: $(run "$d" | tr '\n' '|')"; fi

# 5 — SOFT-SLUG FAIL HINT. `Corrects [Block 5] in `integration`` with no focus named `integration` falls back to the own prefix and FAILs;
#     the FAIL line says how to resolve it. A FAIL with no qualifier carries no hint.
d="$TMP/soft"; pblank "$d" t 5; pmk "$d" t 4 '# Block 4\n\n> Corrects [Block 5] in `integration`.\n'
out="$(run "$d")"
_f="$(grep -E '^ *FAIL +B4 corrects \[Block 5\] ' <<<"$out")"   # no producer | grep pipe (SIGPIPE lint, #1444)
if grep -q 'FOCUSES.md row' <<<"$_f" && grep -q 'integration' <<<"$_f"; then ok "soft-slug fallback FAIL names the slug and the fix (FOCUSES.md row or the word focus)"
else no "soft-hint :: $(tr '\n' '|' <<<"$out")"; fi
d="$TMP/nosoft"; pblank "$d" t 5; pmk "$d" t 4 '# Block 4\n\n> Corrects [Block 5] §1.\n'
if ! grep -q 'FOCUSES.md row' < <(run "$d"); then ok "a plain FAIL (no qualifier) carries no focus hint"; else no "no-soft :: $(run "$d" | tr '\n' '|')"; fi

# 6 — POSSESSIVE IN AN ASIDE. `Corrects, per this run's review, the claim in [Block 8]`: the possessive is not the verb's object.
d="$TMP/poss"; pblank "$d" t 8; pmk "$d" t 4 '# Block 4\n\n> Corrects, per this run'"'"'s review, the claim in [Block 8] §1.\n'
if grep -qE 'FAIL +B4 corrects \[Block 8\] ' < <(run "$d") && ! grep -qE 'AMBIG' < <(run "$d"); then ok "possessive in an aside is not the object: plain declaration (FAIL, no AMBIG object)"
else no "poss-aside :: $(run "$d" | tr '\n' '|')"; fi
# 6b — the OBJECT-position possessive stays AMBIG (the #1868 class must not regress), also when the verb is Spanish / has a leading space.
ob_ok=1; ob_bad=""; i=0
for _s in "Corrects this focus's remittance in [Block 8]." "Corrects the caller's mislabel in [Block 8]." "corrects our session's claim about [Block 8]."; do
  i=$((i+1)); d="$TMP/obj$i"; pblank "$d" t 8; pmk "$d" t 4 '# Block 4\n\n> %s\n' "$_s"
  grep -qE '^ *AMBIG +B4 corrects \[Block 8\] .*non-block object' < <(run "$d") || { ob_ok=0; ob_bad="$ob_bad [$i]"; }
done
if [ "$ob_ok" = 1 ]; then ok "object-position process-noun possessives still AMBIG (object)"; else no "obj :: $ob_bad"; fi

# 7 — CODE IDENTIFIER BEFORE A REF. `Corrects `decode_frame` [Block 8]`: a backticked token that names no prefix / FOCUSES row is a
#     code identifier, not a focus slug → strict lookup (FAIL), not AMBIG cross-focus. A token that DOES resolve still qualifies.
d="$TMP/code"; pblank "$d" t 8; pmk "$d" t 4 '# Block 4\n\n> Corrects `decode_frame` [Block 8] §1.\n'
out="$(run "$d")"
if grep -qE 'FAIL +B4 corrects \[Block 8\] ' <<<"$out" && ! grep -qE 'AMBIG' <<<"$out"; then ok "unresolvable leading backtick token → strict lookup (FAIL), not AMBIG cross-focus"
else no "code-ident :: $(tr '\n' '|' <<<"$out")"; fi
d="$TMP/code-res"; pmk "$d" aa 4 '# Block 4\n\n> Corrects `zz` [Block 1] §1.\n'; pblank "$d" aa 1; pblank "$d" zz 1
if grep -qE 'FAIL +B4 corrects \[Block 1\] but zz-block1\.md ' < <(run "$d"); then ok "a leading backtick token that names a prefix still qualifies (zz-block1)"
else no "code-res :: $(run "$d" | tr '\n' '|')"; fi
d="$TMP/code-hard"; pblank "$d" aa 1; pmk "$d" aa 4 '# Block 4\n\n> Corrects [Block 1] of the `ghost` focus.\n'
if grep -qE '^ *AMBIG +B4 corrects \[Block 1\] .*cross-focus' < <(run "$d"); then ok "an explicit 'focus' word with an unresolvable slug stays a typed AMBIG"
else no "code-hard :: $(run "$d" | tr '\n' '|')"; fi


echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
