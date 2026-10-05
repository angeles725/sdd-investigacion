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
mk(){ mkdir -p "$1"; printf "$3" > "$1/t-block$2.md"; }
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
mk "$d" 36 "# Block 36\n\n> **Block type: EVIDENCE.** CORRECTS the backlog's statement of G4, and\n> independently corroborates [Block 5].\n"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'note +1 correction verb' <<<"$out"; then
  ok "', and <other verb> [Block 5]' → Block 5 is not a target; the unbound verb is surfaced as a note"
else no "conj :: $(tr '\n' '|' <<<"$out")"; fi

# 7 — sentence boundary: the ref after the verb's own sentence is not its target.
d="$TMP/sent"; blank "$d" 52
mk "$d" 37 '# Block 37\n\n- **[Block 53]** — both bounded it; this block\n  corrects that — it is in the jar we hold. The property read ([Block 52]) may also live here.\n'
if [ "$(code "$d")" = 0 ]; then ok "ref in the NEXT sentence is not a target → exit 0"
else no "sent :: $(run "$d" | grep -E 'FAIL' | tr '\n' '|')"; fi

# 8 — bare B<N> leads the clause: the later bracket is not the target (nor is it guessed); note emitted.
d="$TMP/bare"; blank "$d" 34
mk "$d" 38 '# Block 38\n\n# x — and §14 CORRECTS my own B67 §67.7, which walked into a trap [Block 34] had described\n'
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && grep -qE 'note +1 correction verb' <<<"$out"; then
  ok "bare 'B67' leads the clause → later [Block 34] not a target; surfaced as a note, not dropped silently"
else no "bare :: $(tr '\n' '|' <<<"$out")"; fi

# NEGATIVE CONTROLS — each mutant disables ONE binding rule and must flip exactly the case that owns it.
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

  echo "-- teeth: drop the postfix binding; the real blender fixture must lose both findings --"
  m="$TMP/vc.POSTFIX.sh"
  if mk_mut "teeth: postfix" "$SUT" "$m" 's/else if (!done \&\& bd == "close")/else if (0)/'; then
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
  if mk_mut "teeth: bare" "$SUT" "$m" 's/if (bp <= RSTART) r = ""/if (0) r = ""/'; then
    tt "teeth: no-suppressor mutant binds [Block 34] behind 'B67'" 0 1 "$m" --orig "$SUT" \
      --bad-has 'B38 corrects \[Block 34\] ' --bad-lacks "$CRASH" -- bash @SUT@ "$TMP/bare"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
