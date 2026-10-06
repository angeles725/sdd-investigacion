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
#   8. every case is also run under mawk when it is installed (the ambient awk may be gawk).
#
# Usage: verify-corrections-residuals.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-corrections.sh"
FIX="$HERE/fixtures/verify-corrections"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -d "$FIX/real-1874" ] || { echo "FATAL: fixture dir missing: $FIX/real-1874" >&2; exit 2; }
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
          '> Correction: the claim was revised; see the history of [Block 4] for details.' '> Correction (2026-01-01) of B4 is pending.'; do
  i=$((i+1)); d="$TMP/nb-neg$i"; pblank "$d" t 8; pmk "$d" t 4 '# Block 4\n\n> Corrects [Block 8] §1.\n'
  printf '\n%s\n' "$_s" >> "$d/t-block8.md"
  grep -qE 'FAIL +B4 corrects \[Block 8\] ' < <(run "$d") || { nb_ok=0; nb_bad="$nb_bad [$i]"; }
done
if [ "$nb_ok" = 1 ]; then ok "noun backlink shape is strict: another block's ref / prose / a later ref are not backlinks (the pair still FAILs)"
else no "noun-neg :: $nb_bad"; fi
# 1c — the accepted noun shapes, in FIRST / MIDDLE / LAST line position (no trailing newline on the last), Spanish + English,
#      with and without the parenthetical tag, separator and bold markers.
nb_ok=1; nb_bad=""; i=0
for _s in '**CORRECCIÓN (2026-07-26) — [Block 4].** body' 'Correction (2026-01-01): [Block 4] revised this.' '> Corrección — [Bloque 4] §4.2' 'CORRECTION [Block 4].' 'correcci\303\263n - [Block 04]'; do
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

# 3 — NEGATIONS (real niagara-mental-model-bloque406.md:406, bloque408.md:538): declare nothing, not even AMBIG.
if ! grep -qE 'B406|B408' <<<"$(grep -E '^ *(FAIL|AMBIG|WARN)' <<<"$rout")" && grep -qE 'negated' <<<"$rout"; then
  ok "real B406/B408: 'corrects nothing in B21' / 'Corrects no claim in B402' → no FAIL/AMBIG/WARN, counted in a typed note"
else no "real negation :: $(grep -E 'B406|B408|negat' <<<"$rout" | tr '\n' '|')"; fi
ng_ok=1; ng_bad=""; i=0
for _s in 'This corrects nothing in [Block 8].' 'Corrects no claim in [Block 8].' 'No corrige nada en [Block 8].' 'Esto no corrige [Block 8].' 'It never corrects [Block 8].' 'Corrige ninguna afirmación de [Block 8].'; do
  i=$((i+1)); d="$TMP/neg$i"; pblank "$d" t 8; pmk "$d" t 4 '# Block 4\n\n> %s\n' "$_s"
  out="$(run "$d")"
  { [ "$(code "$d")" = 0 ] && ! grep -qE '^ *(FAIL|AMBIG|WARN)' <<<"$out" && grep -qE 'ok +every declared' <<<"$out"; } || { ng_ok=0; ng_bad="$ng_bad [$i]"; }
done
if [ "$ng_ok" = 1 ]; then ok "6 negation shapes (EN/ES, leading and trailing) declare nothing: exit 0, plain ok, no FAIL/AMBIG/WARN"; else no "neg :: $ng_bad"; fi
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

# 8 — the same corpus under mawk (the ambient awk may be gawk). Skipped, loudly, when mawk is absent.
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$TMP/mawkbin"; ln -sf "$(command -v mawk)" "$TMP/mawkbin/awk"
  mout="$(PATH="$TMP/mawkbin:$PATH" bash "$SUT" "$REAL" 2>&1)"
  if [ "$mout" = "$rout" ]; then ok "real-1874 under mawk ($(basename "$(readlink -f "$TMP/mawkbin/awk")")): output byte-identical to the ambient awk"
  else no "mawk differs :: $(diff <(echo "$rout") <(echo "$mout") | head -4 | tr '\n' '|')"; fi
else
  echo "  SKIP  mawk not installed: the mawk run is NOT verifiable here"
fi

# NEGATIVE CONTROLS — each mutant disables ONE rule and must flip exactly the case that owns it.
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

  echo "-- teeth (#1874 item 1): noun backlink --"
  m="$TMP/vc.NONOUN.sh"
  if mk_mut "teeth: noun backlink" "$SUT" "$m" 's/^_vc_noun_re=.*/_vc_noun_re="NOUN-SHAPE-NEVER-MATCHES-ZZZ"/'; then
    tt "teeth: noun-blind mutant FAILs the real B292→B189 pair" 0 1 "$m" --orig "$SUT" \
      --good-lacks 'FAIL +B292 ' --bad-has 'FAIL +B292 corrects \[Block 189\]' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
  fi
  m="$TMP/vc.LOOSENOUN.sh"
  if mk_mut "teeth: noun ref pinned" "$SUT" "$m" 's/\${_vc_noun_re}\${c}/${_vc_noun_re}[0-9]+/'; then
    tt "teeth: a noun backlink naming ANY block is accepted by the loose mutant (the pair stops failing)" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B4 corrects \[Block 8\]' --bad-lacks "$CRASH|FAIL +B4" -- bash @SUT@ "$TMP/nb-neg1"
  fi

  echo "-- teeth (#1874 item 2): joined-list postfix --"
  m="$TMP/vc.NOLIST.sh"
  if mk_mut "teeth: postfix list" "$SUT" "$m" 's/if (cls == "") cls = "list"; emit(lrn\[k\]); cls = sv/emit(lrn[k]); cls = sv/'; then
    tt "teeth: list-blind mutant FAILs the real B153→B51 (every ref of the list is a declaration)" 0 1 "$m" --orig "$SUT" \
      --good-lacks 'FAIL +B153 ' --bad-has 'FAIL +B153 corrects \[Block 51\]' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
  fi
  m="$TMP/vc.LASTONLY.sh"
  if mk_mut "teeth: postfix first ref" "$SUT" "$m" 's/emit(lrn\[first\])$/emit(lrn[nn])/'; then
    tt "teeth: last-ref mutant loses the FIRST ref of the list (no FAIL on [Block 5])" 1 1 "$m" --orig "$SUT" \
      --good-has 'FAIL +B9 corrects \[Block 5\]' --bad-lacks "$CRASH|FAIL +B9 corrects \[Block 5\]" -- bash @SUT@ "$TMP/jl1"
  fi

  echo "-- teeth (#1874 item 3): negations --"
  m="$TMP/vc.NONEG.sh"
  if mk_mut "teeth: negation" "$SUT" "$m" 's/if (!isnoun \&\& (pre ~/if (0 \&\& (pre ~/'; then
    tt "teeth: negation-blind mutant reads 'corrects nothing in B21' as a declaration again" 0 0 "$m" --orig "$SUT" \
      --good-lacks 'B406 corrects' --bad-has 'AMBIG +B406 corrects \[Block 21\]' --bad-lacks "$CRASH" -- bash @SUT@ "$REAL"
  fi
  m="$TMP/vc.NEGPRE.sh"
  if mk_mut "teeth: leading negation" "$SUT" "$m" 's/(no|nunca|never|tampoco)\[ \\t\]+\$/(zzzz)[ \\t]+$/'; then
    tt "teeth: pre-verb-blind mutant loses 'Esto no corrige [Block 8]'" 0 1 "$m" --orig "$SUT" \
      --good-has 'ok +every declared' --bad-has 'FAIL +B4 corrects \[Block 8\]' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/neg4"
  fi

  echo "-- teeth (#1874 item 4): bracketed ref after a leading bare ref --"
  m="$TMP/vc.NOMIXED.sh"
  if mk_mut "teeth: mixed list" "$SUT" "$m" 's/sv = cls; cls = "mixed"; emit(gm); cls = sv/sv = cls/'; then
    tt "teeth: mixed-blind mutant lets [Block 12] vanish again" 0 0 "$m" --orig "$SUT" \
      --good-has 'AMBIG +B4 corrects \[Block 12\]' --bad-lacks "$CRASH|AMBIG +B4 corrects \[Block 12\]" -- bash @SUT@ "$TMP/bm1"
  fi

  echo "-- teeth (#1874 item 5): soft-slug hint --"
  m="$TMP/vc.NOHINT.sh"
  if mk_mut "teeth: soft hint" "$SUT" "$m" 's/\${_vc_soft:+ — hint:/${_vc_never:+ — hint:/'; then
    tt "teeth: hint-less mutant drops the FOCUSES.md pointer from the FAIL" 1 1 "$m" --orig "$SUT" \
      --good-has 'FOCUSES.md row' --bad-lacks "$CRASH|FOCUSES.md row" -- bash @SUT@ "$TMP/soft"
  fi

  echo "-- teeth (#1874 item 6): possessive anchoring --"
  m="$TMP/vc.UNANCHORED.sh"
  if mk_mut "teeth: possessive anchor" "$SUT" "$m" 's/if (pre ~ \/\^\[ \\t\]\*(this|that|the|our|my)/if (pre ~ \/(^|[^a-z0-9_\\200-\\377])(this|that|the|our|my)/'; then
    tt "teeth: unanchored mutant turns the aside possessive into AMBIG object" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B4 corrects \[Block 8\]' --bad-has 'AMBIG +B4 corrects \[Block 8\]' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/poss"
  fi

  echo "-- teeth (#1874 item 7): code identifier --"
  m="$TMP/vc.HARDLEAD.sh"
  if mk_mut "teeth: lead kind" "$SUT" "$m" 's/qkind = "lead"/qkind = "hard"/'; then
    tt "teeth: hard-lead mutant turns Corrects \`decode_frame\` [Block 8] back into AMBIG cross-focus" 1 0 "$m" --orig "$SUT" \
      --good-has 'FAIL +B4 corrects \[Block 8\]' --bad-has 'AMBIG +B4 .*cross-focus' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/code"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
