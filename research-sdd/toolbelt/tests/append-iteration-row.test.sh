#!/usr/bin/env bash
# append-iteration-row.test.sh — suite for append-iteration-row.sh (kit issue #1606). Pins the contract in
# append-iteration-row.v1.md: dry-run default, atomic --apply, blank-line separation before the next heading,
# header/row cell-count validation, HTML-comment-blind heading/table detection (#1173), typed errors.
# Everything runs in trap-cleaned temp dirs; no real corpus is ever touched.
#
# Usage: append-iteration-row.test.sh                (run the suite)
#        append-iteration-row.test.sh --prove-teeth  (run suite + mutation controls)
# Exit: 0 = every assertion held · 1 = regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../append-iteration-row.sh"
TEMPLATE="$HERE/../../templates/RESEARCH-STATE.template.md"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$TEMPLATE" ] || { echo "FATAL: template not found: $TEMPLATE" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"
MUT="$(mktemp -d)"
trap 'rm -rf "$TMP" "$MUT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-66s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-66s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth || exit 2
mk_sed() { local l="$1" o="$2"; shift 2; mutant_chain "$l" "$SUT" "$o" "$@" || { fail=$((fail+1)); return 1; }; }
tooth() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

OUT=""; ERR=""; RC=0
run() {
  "$BASH_BIN" "$SUT" "$@" >"$TMP/o" 2>"$TMP/e"; RC=$?
  OUT="$(cat "$TMP/o")"; ERR="$(cat "$TMP/e")"
}
has()  { grep -qF -- "$1" <<<"$OUT"; }
ehas() { grep -qF -- "$1" <<<"$ERR"; }
# etyped TYPE [TEXT] — stderr is EXACTLY one line, `append-iteration-row: ERROR: TYPE ...` (contract: one typed line per failure).
etyped() { [ "$(grep -c . <<<"$ERR")" = 1 ] && grep -qF -- "append-iteration-row: ERROR: $1 ${2:-}" <<<"$ERR"; }

HDR='| # | Date | Gap closed | Block | Delegated? | New gaps |'
SEP='|---|---|---|---|---|---|'
R1='| 1 | 2026-01-01 | g1 | B1 | no | 0 |'
NEW='| 2 | 2026-01-02 | g2 | B2 | no | 1 |'
n=0
# mkf NAME — body on stdin; prints the path.
mkf() { n=$((n+1)); local f="$TMP/$n-$1.md"; cat > "$f"; printf '%s' "$f"; }
sum() { cksum < "$1"; }

echo "== append-iteration-row.test.sh (SUT: $(basename "$SUT")) =="

# ---- usage / absent / not regular -------------------------------------------------------------
run; { [ "$RC" = 2 ] && etyped USAGE; } && ok "no args -> exit 2, one typed line" || no "no args" "(rc=$RC $ERR)"
run --bogus a b; { [ "$RC" = 2 ] && etyped USAGE "unknown argument: --bogus"; } && ok "unknown flag -> exit 2 typed" || no "unknown flag" "(rc=$RC $ERR)"
run a b c; { [ "$RC" = 2 ] && etyped USAGE "too many arguments"; } && ok "three positionals -> exit 2" || no "too many" "(rc=$RC $ERR)"
run "$TMP/nope.md" "$R1"; { [ "$RC" = 2 ] && ehas "ABSENT-FILE"; } && ok "absent file -> exit 2 ABSENT-FILE" || no "absent file" "(rc=$RC $ERR)"
F="$(printf '## Iteration history\n\n%s\n%s\n' "$HDR" "$SEP" | mkf usage)"
run "$F" "   "; { [ "$RC" = 2 ] && etyped USAGE "row is empty"; } && ok "blank row -> exit 2" || no "blank row" "(rc=$RC $ERR)"
run "$F" "$(printf 'a\nb')"; { [ "$RC" = 2 ] && etyped USAGE "row must be a single line"; } && ok "multi-line row -> exit 2" || no "multi-line row" "(rc=$RC $ERR)"
ln -s "$F" "$TMP/link.md"
run "$TMP/link.md" "$R1"; { [ "$RC" = 2 ] && ehas "NOT-REGULAR-FILE"; } && ok "symlink target refused" || no "symlink" "(rc=$RC $ERR)"
mkdir "$TMP/adir"; run "$TMP/adir" "$R1"; { [ "$RC" = 2 ] && ehas "NOT-REGULAR-FILE"; } && ok "directory refused" || no "directory" "(rc=$RC $ERR)"

# ---- normal case: middle table, blank line + next heading -------------------------------------
F="$(printf '# T\n\n## Iteration history\n\n%s\n%s\n%s\n\n## Blocked gaps\n\n- x\n' "$HDR" "$SEP" "$R1" | mkf mid)"
s0="$(sum "$F")"; run "$F" "$NEW"
{ [ "$RC" = 0 ] && has "+$NEW"; } && ok "dry run prints the new row as an addition, exit 0" || no "dry run" "(rc=$RC $OUT)"
[ "$(sum "$F")" = "$s0" ] && ok "dry run never writes" || no "dry run wrote"
[ "$(grep -c '^-[^-]' <<<"$OUT")" = 0 ] && ok "diff removes nothing (additions only)" || no "diff has removals" "($OUT)"
ehas "dry run" && ok "dry run says so on stderr" || no "dry run notice" "($ERR)"

# ---- no blank line before the next heading (the #1606 incident shape) --------------------------
F="$(printf '## Iteration history\n\n%s\n%s\n%s\n## Blocked gaps\n\n- x\n' "$HDR" "$SEP" "$R1" | mkf glue)"
run --apply "$F" "$NEW"
want="$(printf '## Iteration history\n\n%s\n%s\n%s\n%s\n\n## Blocked gaps\n\n- x\n' "$HDR" "$SEP" "$R1" "$NEW")"
{ [ "$RC" = 0 ] && [ "$(cat "$F")" = "$want" ]; } && ok "table directly followed by heading: blank line inserted, no glue" || no "glue case" "($(cat "$F"))"

# ---- list edges: empty table, single row, last in file (newline / no newline) -----------------
F="$(printf '## Iteration history\n\n%s\n%s\n\n## Next\n' "$HDR" "$SEP" | mkf empty)"
run --apply "$F" "$NEW"
want="$(printf '## Iteration history\n\n%s\n%s\n%s\n\n## Next\n' "$HDR" "$SEP" "$NEW")"
{ [ "$RC" = 0 ] && [ "$(cat "$F")" = "$want" ]; } && ok "empty table (header+separator only): row lands after the separator" || no "empty table" "($(cat "$F"))"
F="$(printf '## Iteration history\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf lastnl)"
run --apply "$F" "$NEW"
want="$(printf '## Iteration history\n%s\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" "$NEW")"
{ [ "$RC" = 0 ] && [ "$(cat "$F")" = "$want" ] && [ -z "$(tail -c1 "$F")" ]; } && ok "table last in file (trailing newline): appended, single trailing newline" || no "last in file" "($(cat "$F"))"
F="$(printf '## Iteration history\n%s\n%s\n%s' "$HDR" "$SEP" "$R1" | mkf lastnonl)"
run --apply "$F" "$NEW"
{ [ "$RC" = 0 ] && [ "$(cat "$F")" = "$want" ] && [ "$(wc -l < "$F")" = 5 ]; } && ok "table last in file, no trailing newline: row never glued to the last row" || no "last, no newline" "($(cat "$F"))"
F="$(printf '## Iteration history\n%s\n%s\n' "$HDR" "$SEP" | mkf emptylast)"
run --apply "$F" "$NEW"
[ "$RC" = 0 ] && [ "$(wc -l < "$F")" = 4 ] && ok "empty table last in file" || no "empty table last" "($(cat "$F"))"

# ---- row normalisation and verbatim content ---------------------------------------------------
F="$(printf '## Iteration history\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf norm)"
run "$F" '2 | d | g | B2 | no | 1'
has '+| 2 | d | g | B2 | no | 1 |' && ok "row without outer pipes is normalised" || no "normalise" "($OUT)"
run "$F" '| 2 | a \| b & c \\ d | g | B2 | no | 1 |'
{ [ "$RC" = 0 ] && has '+| 2 | a \| b & c \\ d | g | B2 | no | 1 |'; } && ok "escaped pipe is one cell; & and backslashes kept verbatim" || no "verbatim" "(rc=$RC $OUT)"

# ---- cell-count validation --------------------------------------------------------------------
run "$F" '| 2 | d | g | B2 | no |'; { [ "$RC" = 7 ] && etyped CELL-COUNT-MISMATCH "row has 5 cell(s), the table header has 6"; } && ok "too few cells -> exit 7 typed" || no "too few" "(rc=$RC $ERR)"
run "$F" '| 2 | d | g | B2 | no | 1 | 9 |'; [ "$RC" = 7 ] && ok "too many cells -> exit 7" || no "too many cells" "(rc=$RC $ERR)"
[ -z "$OUT" ] && ok "a refused row prints no diff" || no "diff on refusal" "($OUT)"

# ---- heading / table state errors (§7: distinct typed states) ----------------------------------
F2="$(printf '# T\n\n## Coverage\n\n%s\n%s\n' "$HDR" "$SEP" | mkf nohead)"
run "$F2" "$NEW"; { [ "$RC" = 4 ] && etyped NO-HEADING; } && ok "heading absent -> exit 4 NO-HEADING" || no "no heading" "(rc=$RC $ERR)"
F2="$(printf '## Iteration history\n\nno table here\n\n## Next\n\n%s\n%s\n' "$HDR" "$SEP" | mkf notable)"
run "$F2" "$NEW"; { [ "$RC" = 5 ] && etyped NO-TABLE; } && ok "no table before the next heading -> exit 5 NO-TABLE (later table not used)" || no "no table" "(rc=$RC $ERR)"
F2="$(printf '## Iteration history\n\n%s\n%s\n' "$HDR" "$R1" | mkf nosep)"
run "$F2" "$NEW"; { [ "$RC" = 6 ] && etyped MALFORMED-TABLE; } && ok "header without separator row -> exit 6 MALFORMED-TABLE" || no "no separator" "(rc=$RC $ERR)"
F2="$(printf '## Iteration history\n\n%s\n' "$HDR" | mkf hdronly)"
run "$F2" "$NEW"; [ "$RC" = 6 ] && ok "header as the last line (no separator) -> exit 6" || no "header last" "(rc=$RC $ERR)"
F2="$(printf '## Iteration history\n\n%s\n%s\n\n## Iteration history\n\n%s\n%s\n' "$HDR" "$SEP" "$HDR" "$SEP" | mkf dup)"
s1="$(sum "$F2")"; run --apply "$F2" "$NEW"; { [ "$RC" = 8 ] && etyped AMBIGUOUS-HEADING && [ "$(sum "$F2")" = "$s1" ]; } && ok "two headings -> exit 8, file untouched even with --apply" || no "ambiguous" "(rc=$RC $ERR)"

# ---- HTML-comment blindness (#1173) -----------------------------------------------------------
F2="$(printf '<!-- doc\n## Iteration history\n%s\n%s\n-->\n\n## Coverage\n' "$HDR" "$SEP" | mkf cmtonly)"
run "$F2" "$NEW"; { [ "$RC" = 4 ] && etyped NO-HEADING; } && ok "heading only inside a comment -> NO-HEADING (not matched)" || no "comment heading" "(rc=$RC $ERR)"
F2="$(printf '<!-- ex\n## Iteration history\n%s\n%s\n| 0 | x | x | x | x | 0 |\n-->\n## Iteration history\n\n%s\n%s\n%s\n\n## Blocked gaps\n' "$HDR" "$SEP" "$HDR" "$SEP" "$R1" | mkf cmtreal)"
run "$F2" "$NEW"; { [ "$RC" = 0 ] && grep -qxF "+$NEW" <<<"$OUT" && grep -q '^ | 1 | 2026-01-01' <<<"$OUT"; } && ok "commented example heading ignored; the real table gets the row" || no "comment then real" "(rc=$RC $OUT)"
F2="$(printf '## Iteration history\n\n<!--\n%s\n%s\n| 0 | x | x | x | x | 0 |\n-->\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$HDR" "$SEP" "$R1" | mkf cmttab)"
run "$F2" "$NEW"; { [ "$RC" = 0 ] && grep -qxF " $R1" <<<"$OUT" && grep -qxF "+$NEW" <<<"$OUT"; } && ok "a table inside a comment under the heading is skipped" || no "comment table" "(rc=$RC $OUT)"
F2="$(printf '## Iteration history (old)\n%s\n%s\n' "$HDR" "$SEP" | mkf cmtsuffix)"
run "$F2" "$NEW"; [ "$RC" = 4 ] && ok "heading with trailing text is not the exact heading" || no "suffix heading" "(rc=$RC $ERR)"

# ---- the real template: row goes after the placeholder row, before ## Blocked gaps ----------------
cp "$TEMPLATE" "$TMP/tpl.md"
run "$TMP/tpl.md" '| 2 | <date> | <gap> | B2 | <tier> | <n> |'
{ [ "$RC" = 0 ] && has '+| 2 | <date>' && ! grep -qxF "+" <<<"$OUT" && grep -q '^ ## Blocked gaps' <<<"$OUT"; } && ok "real template: row after the placeholder row, existing blank line kept (no extra one) before the next heading" || no "template" "(rc=$RC $OUT)"
run --apply "$TMP/tpl.md" '| 2 | <date> | <gap> | B2 | <tier> | <n> |'
{ [ "$RC" = 0 ] && awk '/^## Blocked gaps \(each/ { if (prev == "") good = 1 } { prev = $0 } END { exit !good }' "$TMP/tpl.md"; } \
  && ok "applied template: real heading preceded by a blank line, not by the new row" || no "template apply" "(rc=$RC)"

# ---- --apply: written, atomic residue-free, mode kept, equals the dry-run diff -------------------
F="$(printf '## Iteration history\n\n%s\n%s\n%s\n\n## Next\n' "$HDR" "$SEP" "$R1" | mkf apply)"
chmod 640 "$F"; cp "$F" "$TMP/apply.orig"
run "$F" "$NEW"; printf '%s\n' "$OUT" > "$TMP/apply.diff"
run --apply "$F" "$NEW"
{ [ "$RC" = 0 ] && ehas "appended 1 row"; } && ok "--apply exits 0 and reports it" || no "apply rc" "(rc=$RC $ERR)"
! compgen -G "$TMP/.air.*" >/dev/null && ok "no staging file left behind" || no "staging residue" "($(ls -A "$TMP"))"
if command -v patch >/dev/null 2>&1; then
  (cd "$TMP" && patch -s -o apply.patched apply.orig < apply.diff) >/dev/null 2>&1 && cmp -s "$TMP/apply.patched" "$F" && ok "applied file == dry-run diff applied to the original" || no "apply != diff"
fi
[ "$(stat -c '%a' "$F" 2>/dev/null || stat -f '%Lp' "$F")" = 640 ] && ok "file mode preserved by --apply" || no "mode" "()"
run --apply "$F" "$NEW"; [ "$RC" = 0 ] && [ "$(grep -cxF "$NEW" "$F")" = 2 ] && ok "a second apply appends a second row" || no "second apply" "(rc=$RC)"

# ---- inline comments on table rows (RDD round 1) ----------------------------------------------
F2="$(printf '## Iteration history\n\n%s <!-- hdr -->\n%s\n%s <!-- a | b | c -->\n| 2 | d | g | B2 | no | 1 | <!-- mid -->\n| 3 | d | g | B3 | no | 1 |<!-- last -->\n\n## Next\n' "$HDR" "$SEP" "$R1" | mkf inl)"
run "$F2" "$NEW"
{ [ "$RC" = 0 ] && grep -qxF "+$NEW" <<<"$OUT" && grep -q '^ | 3 | d | g | B3 | no | 1 |<!-- last -->' <<<"$OUT"; } && ok "inline comments on header, middle and last rows: row lands after the LAST row" || no "inline comments" "(rc=$RC $OUT)"
run --apply "$F2" "$NEW"
[ "$(grep -n -xF "$NEW" "$F2" | cut -d: -f1)" = 8 ] && ok "inline-comment table: applied row is line 8, right after the last table row" || no "inline apply" "($(cat "$F2"))"
F2="$(printf '## Iteration history\n\n%s\n%s <!-- x -->\n%s\n' "$HDR" "$SEP" "$R1" | mkf inlsep)"
run "$F2" "$NEW"; [ "$RC" = 0 ] && ok "separator row with an inline comment is accepted" || no "inline separator" "(rc=$RC $ERR)"

# ---- a row that carries a comment delimiter is refused ------------------------------------------
F2="$(printf '## Iteration history\n\n%s\n%s\n' "$HDR" "$SEP" | mkf cmtrow)"
s1="$(sum "$F2")"
run --apply "$F2" '| 2 | d | g | B2 | no | 1 | <!-- oops'
{ [ "$RC" = 2 ] && etyped INVALID-ROW && [ "$(sum "$F2")" = "$s1" ]; } && ok "row opening a comment -> exit 2 INVALID-ROW, file untouched" || no "row with <!--" "(rc=$RC $ERR)"
run "$F2" '| 2 | d | g | B2 | no | --> |'; { [ "$RC" = 2 ] && etyped INVALID-ROW; } && ok "row containing --> -> exit 2 INVALID-ROW" || no "row with -->" "(rc=$RC $ERR)"

# ---- lost update: target changed between read and write ------------------------------------------
printf '#!/bin/sh\nprintf "concurrent\\n" >> "$1"\n' > "$TMP/hook.sh"; chmod +x "$TMP/hook.sh"
F2="$(printf '## Iteration history\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf race)"
AIR_PRE_MV_HOOK="$TMP/hook.sh" run --apply "$F2" "$NEW"
{ [ "$RC" = 10 ] && etyped CONCURRENT-MODIFICATION && [ "$(tail -1 "$F2")" = concurrent ] && ! grep -qxF "$NEW" "$F2"; } \
  && ok "target changed before mv -> exit 10 CONCURRENT-MODIFICATION, concurrent write preserved, row not written" || no "lost update" "(rc=$RC $ERR)"
! compgen -G "$TMP/.air.*" >/dev/null && ok "no staging file left after CONCURRENT-MODIFICATION" || no "staging residue (race)"
F2="$(printf '## Iteration history\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf norace)"
AIR_PRE_MV_HOOK=/bin/true run --apply "$F2" "$NEW"; { [ "$RC" = 0 ] && grep -qxF "$NEW" "$F2"; } && ok "an unchanged target still applies with the hook present" || no "hook no-op" "(rc=$RC $ERR)"

# ---- #1793: CRLF files are refused with a typed error, never misreported as NO-HEADING ------------
# Fleet survey (2026-10-05): 201 RESEARCH-STATE*.md files, 0 contain a CR -> refuse rather than carry a CRLF code path.
F2="$(printf '## Iteration history\r\n\r\n%s\r\n%s\r\n%s\r\n' "$HDR" "$SEP" "$R1" | mkf crlf)"; s1="$(sum "$F2")"
run --apply "$F2" "$NEW"
{ [ "$RC" = 11 ] && etyped CRLF-LINE-ENDINGS && [ "$(sum "$F2")" = "$s1" ]; } && ok "CRLF file with a valid heading -> exit 11 CRLF-LINE-ENDINGS, untouched" || no "crlf" "(rc=$RC $ERR)"
F2="$(printf '## Iteration history\n\n%s\n%s\n%s\n\n## Next\n\nstray\r\n' "$HDR" "$SEP" "$R1" | mkf crmixed)"
run "$F2" "$NEW"; { [ "$RC" = 11 ] && etyped CRLF-LINE-ENDINGS; } && ok "a single CR anywhere (mixed endings) is refused the same way" || no "mixed crlf" "(rc=$RC $ERR)"
F2="$(printf '# T\r\n\r\n## Coverage\r\n' | mkf crnohead)"
run "$F2" "$NEW"; { [ "$RC" = 11 ]; } && ok "CRLF without the heading is still CRLF-LINE-ENDINGS (the line-ending error wins)" || no "crlf no heading" "(rc=$RC $ERR)"

# ---- #1793: headings, tables and comment openers inside fenced code blocks are ignored --------------
FENCE='```'
F2="$(printf '%s\n## Iteration history\n%s\n%s\n%s\n' "$FENCE" "$HDR" "$SEP" "$FENCE" | mkf fnohead)"
run "$F2" "$NEW"; { [ "$RC" = 4 ] && etyped NO-HEADING; } && ok "heading only inside a fenced block -> NO-HEADING" || no "fenced heading" "(rc=$RC $ERR)"
F2="$(printf '%s\n## Iteration history\n%s\n%s\n| 0 | x | x | x | x | 0 |\n%s\n\n## Iteration history\n\n%s\n%s\n%s\n\n## Next\n' "$FENCE" "$HDR" "$SEP" "$FENCE" "$HDR" "$SEP" "$R1" | mkf freal)"
run "$F2" "$NEW"; { [ "$RC" = 0 ] && grep -qxF "+$NEW" <<<"$OUT" && grep -qxF " $R1" <<<"$OUT"; } && ok "fenced example heading ignored (no AMBIGUOUS-HEADING); real table gets the row" || no "fenced then real" "(rc=$RC $OUT)"
F2="$(printf '## Iteration history\n\n%s\n## Foo\n%s\n\n%s\n%s\n%s\n' "$FENCE" "$FENCE" "$HDR" "$SEP" "$R1" | mkf fmid)"
run "$F2" "$NEW"; { [ "$RC" = 0 ] && grep -qxF "+$NEW" <<<"$OUT"; } && ok "a heading inside a fence does not end the section; the table after the fence is used" || no "fence mid" "(rc=$RC $ERR)"
F2="$(printf '%s\n<!--\n%s\n## Iteration history\n\n%s\n%s\n%s\n' "$FENCE" "$FENCE" "$HDR" "$SEP" "$R1" | mkf fcmt)"
run "$F2" "$NEW"; { [ "$RC" = 0 ] && grep -qxF "+$NEW" <<<"$OUT"; } && ok "a comment opener inside a fence does not open a comment" || no "fence comment" "(rc=$RC $ERR)"
F2="$(printf '~~~\n```\n## Iteration history\n~~~\n## Iteration history\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf ftilde)"
run "$F2" "$NEW"; { [ "$RC" = 0 ] && grep -qxF "+$NEW" <<<"$OUT"; } && ok "a ~~~ fence is not closed by a backtick fence; closes on ~~~" || no "tilde fence" "(rc=$RC $ERR)"
F2="$(printf '%s\n## Iteration history\n\n%s\n%s\n%s\n' "$FENCE" "$HDR" "$SEP" "$R1" | mkf funclosed)"; s1="$(sum "$F2")"
run --apply "$F2" "$NEW"
{ [ "$RC" = 12 ] && etyped UNCLOSED-FENCE && [ "$(sum "$F2")" = "$s1" ]; } && ok "unclosed fence that hides the heading -> exit 12 UNCLOSED-FENCE, not NO-HEADING" || no "unclosed fence" "(rc=$RC $ERR)"
F2="$(printf '## Iteration history\n\n%s\n%s\n%s\n%s\n' "$FENCE" "$HDR" "$SEP" "$R1" | mkf fnotable)"; s1="$(sum "$F2")"
run --apply "$F2" "$NEW"
{ [ "$RC" = 12 ] && etyped UNCLOSED-FENCE && [ "$(sum "$F2")" = "$s1" ]; } && ok "unclosed fence between the heading and its table -> exit 12, not NO-TABLE" || no "fence hides table" "(rc=$RC $ERR)"
F2="$(printf '## Iteration history\n\nno table\n\n## Next\n\n%s\ncode\n' "$FENCE" | mkf fcase1)"
run "$F2" "$NEW"; { [ "$RC" = 5 ] && etyped NO-TABLE; } && ok "unrelated unclosed fence after the NEXT heading -> still exit 5 NO-TABLE" || no "fence case 1" "(rc=$RC $ERR)"
F2="$(printf '# T\n\n## Coverage\n\n%s\ncode\n' "$FENCE" | mkf fcase2)"
run "$F2" "$NEW"; { [ "$RC" = 4 ] && etyped NO-HEADING; } && ok "no heading anywhere, trailing unrelated unclosed fence -> still exit 4 NO-HEADING" || no "fence case 2" "(rc=$RC $ERR)"
F2="$(printf '# T\n\n%s\ncode\n## Iteration history\n' "$FENCE" | mkf fcase3)"
run "$F2" "$NEW"; { [ "$RC" = 12 ] && etyped UNCLOSED-FENCE; } && ok "unclosed fence that swallows the heading, after another heading -> exit 12" || no "fence case 3" "(rc=$RC $ERR)"
F2="$(printf '## Iteration history\n\n%s\n%s\n%s\n\n%s\ntail\n' "$HDR" "$SEP" "$R1" "$FENCE" | mkf ftail)"
run "$F2" "$NEW"; { [ "$RC" = 0 ] && grep -qxF "+$NEW" <<<"$OUT"; } && ok "an unclosed fence AFTER the table does not block the append" || no "tail fence" "(rc=$RC $ERR)"

# ---- #1793: trailing-backslash handling agrees with the cell counter ------------------------------
F="$(printf '## Iteration history\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf esc)"
run "$F" '| 2 | d | g | B2 | no | a \\|'
{ [ "$RC" = 0 ] && grep -qxF '+| 2 | d | g | B2 | no | a \\|' <<<"$OUT"; } && ok "row ending in an escaped backslash then a real pipe is complete (no extra pipe)" || no "escaped backslash end" "(rc=$RC $OUT $ERR)"
run "$F" '2 | d | g | B2 | no | a \|'
grep -qxF '+| 2 | d | g | B2 | no | a \| |' <<<"$OUT" && ok "row ending in an escaped pipe still gets its closing pipe" || no "escaped pipe end" "(rc=$RC $OUT)"
run "$F" '2 | d | g | B2 | no | a \\\|'
grep -qxF '+| 2 | d | g | B2 | no | a \\\| |' <<<"$OUT" && ok "three trailing backslashes (odd) = escaped pipe: closing pipe added" || no "odd backslashes" "(rc=$RC $OUT)"

# ---- #1793: --apply replaces the inode, so a hard-linked target is refused -------------------------
F="$(printf '## Iteration history\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf hl)"
ln "$F" "$F.link"; s1="$(sum "$F")"
run --apply "$F" "$NEW"
{ [ "$RC" = 13 ] && etyped HARD-LINKED && [ "$(sum "$F")" = "$s1" ] && [ "$(sum "$F.link")" = "$s1" ]; } && ok "--apply on a hard-linked file -> exit 13 HARD-LINKED, both names untouched" || no "hard link" "(rc=$RC $ERR)"
printf '#!/bin/sh\nln "$1" "$1.late"\n' > "$TMP/linkhook.sh"; chmod +x "$TMP/linkhook.sh"
F2="$(printf '## Iteration history\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf relink)"; s1="$(sum "$F2")"
AIR_PRE_MV_HOOK="$TMP/linkhook.sh" run --apply "$F2" "$NEW"
{ [ "$RC" = 13 ] && etyped HARD-LINKED && [ "$(sum "$F2")" = "$s1" ] && [ "$(sum "$F2.late")" = "$s1" ]; } && ok "link created after staging, before mv -> exit 13 HARD-LINKED (re-check), nothing written" || no "relink" "(rc=$RC $ERR)"
! compgen -G "$TMP/.air.*" >/dev/null && ok "no staging file left after the re-check refusal" || no "staging residue (relink)"
run "$F" "$NEW"; [ "$RC" = 0 ] && grep -qxF "+$NEW" <<<"$OUT" && ok "a dry run on a hard-linked file still works (it writes nothing)" || no "hard link dry" "(rc=$RC $ERR)"

# ---- degraded probe ---------------------------------------------------------------------------
SHIM="$TMP/shim"; mkdir "$SHIM"
for t in diff mktemp mv cp cat dirname rm cmp ls; do p="$(type -P "$t")" && ln -s "$p" "$SHIM/$t"; done
F="$(printf '## Iteration history\n%s\n%s\n' "$HDR" "$SEP" | mkf degr)"
OUT="$(PATH="$SHIM" "$BASH_BIN" "$SUT" "$F" "$NEW" 2>&1)"; RC=$?
{ [ "$RC" = 3 ] && has "DEGRADED: awk not found"; } && ok "missing awk -> typed DEGRADED, exit 3" || no "degraded" "(rc=$RC $OUT)"
# SHIM2: everything but cmp (a missing cmp must be DEGRADED, never a false CONCURRENT-MODIFICATION)
SHIM2="$TMP/shim2"; mkdir "$SHIM2"
for t in awk diff mktemp mv cp cat dirname rm ls; do p="$(type -P "$t")" && ln -s "$p" "$SHIM2/$t"; done
F="$(printf '## Iteration history\n%s\n%s\n' "$HDR" "$SEP" | mkf nocmp)"; s1="$(sum "$F")"
OUT="$(PATH="$SHIM2" "$BASH_BIN" "$SUT" --apply "$F" "$NEW" 2>&1)"; RC=$?
{ [ "$RC" = 3 ] && has "DEGRADED: cmp not found" && [ "$(sum "$F")" = "$s1" ]; } && ok "missing cmp -> typed DEGRADED exit 3, file untouched" || no "cmp probe" "(rc=$RC $OUT)"
# SHIM3: a cmp that errors (rc 2) must be a typed write failure, not "changed, re-run"
SHIM3="$TMP/shim3"; mkdir "$SHIM3"
for t in awk diff mktemp mv cp cat dirname rm ls; do p="$(type -P "$t")" && ln -s "$p" "$SHIM3/$t"; done
printf '#!/bin/sh\nexit 2\n' > "$SHIM3/cmp"; chmod +x "$SHIM3/cmp"
OUT="$(PATH="$SHIM3" "$BASH_BIN" "$SUT" --apply "$F" "$NEW" 2>&1)"; RC=$?
{ [ "$RC" = 9 ] && has "WRITE-FAILED cmp could not compare" && ! has CONCURRENT && [ "$(sum "$F")" = "$s1" ]; } && ok "cmp error (rc 2) -> exit 9 WRITE-FAILED, not CONCURRENT-MODIFICATION" || no "cmp error" "(rc=$RC $OUT)"

# ---- --help is the only usage text; failures are one typed line ----------------------------------
run --help; { [ "$RC" = 0 ] && has "Usage:" && [ -z "$ERR" ]; } && ok "--help prints usage on stdout, exit 0, stderr empty" || no "help" "(rc=$RC $OUT / $ERR)"
run "$TMP/nope.md" "$R1"; etyped ABSENT-FILE && ok "ABSENT-FILE is exactly one typed line" || no "absent one line" "($ERR)"

# ---- last row opens a comment that closes on a later line ----------------------------------------
F2="$(printf '## Iteration history\n\n%s\n%s\n%s\n| 2 | d | g | B2 | no | 1 | <!-- start\nhidden\n-->\n\n## Next\n' "$HDR" "$SEP" "$R1" | mkf mlc)"; s1="$(sum "$F2")"
run --apply "$F2" "$NEW"
{ [ "$RC" = 6 ] && etyped MALFORMED-TABLE "last table row at line 6 opens an HTML comment" && [ "$(sum "$F2")" = "$s1" ]; } && ok "last row opening a multi-line comment -> exit 6, file untouched" || no "multiline comment" "(rc=$RC $ERR)"
F2="$(printf '## Iteration history\n\n%s\n%s\n%s <!-- one-line -->\n\n## Next\n' "$HDR" "$SEP" "$R1" | mkf slc)"
run "$F2" "$NEW"; [ "$RC" = 0 ] && ok "a comment that closes on the same line is still fine" || no "single-line comment last" "(rc=$RC $ERR)"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  mt() {   # mt LABEL SED-EXPR GOOD-RC BAD-RC [tooth flags...] -- ARGV...
    local label="$1" expr="$2" grc="$3" brc="$4"; shift 4
    local m; m="$MUT/m-$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '_').sh"
    mk_sed "$label" "$m" "$expr" && tooth "teeth: $label" "$grc" "$brc" "$m" "$@"
  }
  W="$(printf '## Iteration history\n\n%s\n%s\n%s\n## Blocked gaps\n' "$HDR" "$SEP" "$R1" | mkf tw)"
  C="$(printf '<!-- ex\n## Iteration history\n%s\n%s\n-->\n' "$HDR" "$SEP" | mkf tc)"
  D="$(printf '## Iteration history\n\n%s\n%s\n\n## Iteration history\n\n%s\n%s\n' "$HDR" "$SEP" "$HDR" "$SEP" | mkf td)"
  S2="$(printf '## Iteration history\n\n%s\n%s\n' "$HDR" "$R1" | mkf ts)"
  L="$TMP/teeth-link.md"; ln -s "$W" "$L"

  mt "blank line before the next heading dropped" 's/^  if (last < NR && .*print ""$/  ;/' 0 0 \
    --good-has '^\+$' --bad-lacks '^\+$' -- "$BASH_BIN" @SUT@ "$W" "$NEW"
  mt "comment-blind detection disabled" 's/V\[NR\] = visible(\$0)/V[NR] = $0/' 4 0 -- "$BASH_BIN" @SUT@ "$C" "$NEW"
  mt "cell-count check disabled" 's/if (want != got)/if (0)/' 7 0 -- "$BASH_BIN" @SUT@ "$W" '| 1 | 2 |'
  mt "separator-row check disabled" 's/^  if (!(hdr < NR && istab(hdr + 1) && .*) {$/  if (0) {/' 6 0 -- "$BASH_BIN" @SUT@ "$S2" "$NEW"
  mt "ambiguous-heading check disabled" 's/if (hc > 1)/if (0)/' 8 0 -- "$BASH_BIN" @SUT@ "$D" "$NEW"
  mt "no-heading check disabled" 's/if (hc == 0)/if (0)/' 4 5 -- "$BASH_BIN" @SUT@ "$C" "$NEW"
  mt "symlink refusal removed" 's/^\[ -L "\$FILE" \] && .*$/:/' 2 0 -- "$BASH_BIN" @SUT@ "$L" "$NEW"
  mt "outer-pipe normalisation removed" 's/if (substr(row, 1, 1) != "|") row = "| " row//' 0 0 \
    --good-has '^\+\| 1 \| 2 \|' --bad-lacks '^\+\| 1 \| 2 \|' -- "$BASH_BIN" @SUT@ "$W" '1 | 2 | 3 | 4 | 5 | 6'
  mt "--apply no longer writes (mv dropped)" 's/^mv -f -- "\$STAGE" "\$FILE" || /true || /' 0 0 \
    --good-has 'ZZNEW' --bad-lacks 'ZZNEW' -- "$BASH_BIN" -c 'cp "$2" "$2.w" && bash "$1" --apply "$2.w" "$3" 2>/dev/null; cat "$2.w"' _ @SUT@ "$W" '| ZZNEW | d | g | B | n | 0 |'
  I="$(printf '## Iteration history\n\n%s <!-- hdr -->\n%s\n%s <!-- c -->\n' "$HDR" "$SEP" "$R1" | mkf ti)"
  mt "inline-comment rows treated as non-rows" 's/^function istab(i) .*/function istab(i) { return (V[i] == L[i]) \&\& (L[i] ~ \/^\\|\/) }/' 0 6 -- "$BASH_BIN" @SUT@ "$I" "$NEW"
  mt "typed prefix dropped from awk errors" 's/print "append-iteration-row: ERROR: NO-HEADING/print "NO-HEADING/' 4 4 \
    --good-has 'append-iteration-row: ERROR: NO-HEADING' --bad-lacks 'append-iteration-row: ERROR: NO-HEADING' -- "$BASH_BIN" @SUT@ "$C" "$NEW"
  mt "second shell error line restored" 's/^    4|5|6|7|8|11|12) exit "\$rc" ;;/    4|5|6|7|8|11|12) _err "awk rc=$rc"; exit "$rc" ;;/' 4 4 \
    --good-lacks 'awk rc=' --bad-has 'awk rc=' -- "$BASH_BIN" @SUT@ "$C" "$NEW"
  mt "comment-delimiter row guard removed" 's/^case "\$ROW" in \*.<!--.\*.*$/:/' 2 7 -- "$BASH_BIN" @SUT@ "$W" '| 2 | d | g | B2 | no | 1 | <!-- oops'
  cp "$W" "$W.race"
  mt "unchanged-check (cmp) removed" 's/^cmp -s -- "\$FILE" "\$TMPD\/orig"$/true/' 10 0 -- env "AIR_PRE_MV_HOOK=$TMP/hook.sh" "$BASH_BIN" @SUT@ --apply "$W.race" "$NEW"
  M="$(printf '## Iteration history\n\n%s\n%s\n| 2 | d | g | B2 | no | 1 | <!-- start\nhidden\n-->\n' "$HDR" "$SEP" | mkf tm)"
  cp "$W" "$W.cmp"
  mt "cmp dropped from REQUIRED_TOOLS" 's/ dirname cmp rm ls"/ dirname rm ls"/' 3 9 -- env "PATH=$SHIM2" "$BASH_BIN" @SUT@ --apply "$W.cmp" "$NEW"
  mt "cmp error treated as success" 's/^\[ "\$crc" -eq 0 \] || .*$/:/' 9 0 -- env "PATH=$SHIM3" "$BASH_BIN" @SUT@ --apply "$W.cmp" "$NEW"
  mt "multi-line-comment-after-last-row guard removed" 's/^  if (ES\[last\]) .*$/  ;/' 6 0 -- "$BASH_BIN" @SUT@ "$M" "$NEW"
  mt "usage text restored on typed usage error" 's/(try --help)"; exit 2; }$/(try --help)"; _usage >\&2; exit 2; }/' 2 2 \
    --good-lacks 'Usage:' --bad-has 'Usage:' -- "$BASH_BIN" @SUT@
  mt "awk probe dropped from REQUIRED_TOOLS" 's/^REQUIRED_TOOLS="awk /REQUIRED_TOOLS="/' 3 9 -- env "PATH=$SHIM" "BASH_BIN=$BASH_BIN" "$BASH_BIN" @SUT@ "$W" "$NEW"
  CR="$(printf '## Iteration history\r\n\r\n%s\r\n%s\r\n%s\r\n' "$HDR" "$SEP" "$R1" | mkf tcr)"
  mt "CRLF refusal removed" 's/^  if (cr) {.*$/  ;/' 11 4 -- "$BASH_BIN" @SUT@ "$CR" "$NEW"
  FH="$(printf '%s\n## Iteration history\n%s\n%s\n%s\n' '```' "$HDR" "$SEP" '```' | mkf tfh)"
  mt "fenced lines treated as visible" 's/^  if (fl) { V\[NR\] = ""; ES\[NR\] = 0 } else /  if (0) { V[NR] = ""; ES[NR] = 0 } else /' 4 0 -- "$BASH_BIN" @SUT@ "$FH" "$NEW"
  FU="$(printf '%s\n## Iteration history\n\n%s\n%s\n' '```' "$HDR" "$SEP" | mkf tfu)"
  mt "unclosed-fence error removed" 's/if (hc == 0 \&\& infence \&\& hid)/if (0)/' 12 4 -- "$BASH_BIN" @SUT@ "$FU" "$NEW"
  FT="$(printf '~~~\n```\n## Iteration history\n~~~\n## Iteration history\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf tft)"
  mt "fence close ignores the fence character" 's/c == fch \&\& FN >= fn/FN >= fn/' 0 12 -- "$BASH_BIN" @SUT@ "$FT" "$NEW"
  mt "closing-pipe rule ignores backslash parity" 's/nb % 2 == 1/nb > 0/' 0 7 -- "$BASH_BIN" @SUT@ "$W" '| 2 | d | g | B2 | no | a \\|'
  mt "closing-pipe rule drops the escaped-pipe case" 's/ || nb % 2 == 1//' 0 0 \
    --good-has 'a \\\| \|$' --bad-lacks 'a \\\| \|$' -- "$BASH_BIN" @SUT@ "$W" '2 | d | g | B2 | no | a \|'
  HLW="$(printf '## Iteration history\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf thl)"; ln "$HLW" "$HLW.link"
  FN2="$(printf '## Iteration history\n\n%s\n%s\n%s\n%s\n' '```' "$HDR" "$SEP" "$R1" | mkf tfn)"
  mt "unclosed-fence-before-table error removed" 's/^  if (!hdr \&\& infence \&\& .*$/  ;/' 12 5 -- "$BASH_BIN" @SUT@ "$FN2" "$NEW"
  RL="$(printf '## Iteration history\n\n%s\n%s\n%s\n' "$HDR" "$SEP" "$R1" | mkf trl)"
  FC1="$(printf '## Iteration history\n\nno table\n\n## Next\n\n%s\ncode\n' '```' | mkf tfc1)"
  mt "NO-TABLE blames any unclosed fence (position test dropped)" 's/ \&\& fence_start > h \&\& (nh == 0 || fence_start < nh)//' 5 12 -- "$BASH_BIN" @SUT@ "$FC1" "$NEW"
  FC2="$(printf '# T\n\n## Coverage\n\n%s\ncode\n' '```' | mkf tfc2)"
  mt "NO-HEADING blames any unclosed fence (hidden-heading test dropped)" 's/ \&\& infence \&\& hid) {/ \&\& infence) {/' 4 12 -- "$BASH_BIN" @SUT@ "$FC2" "$NEW"
  mt "pre-mv link re-check removed" '/SENTINEL-RELINK-CHECK/{n;s/.*/:/;}' 13 0 -- "$BASH_BIN" -c 'f="$(mktemp -p "$3")"; cp "$2" "$f"; AIR_PRE_MV_HOOK="$4" bash "$1" --apply "$f" "$5"' _ @SUT@ "$RL" "$TMP" "$TMP/linkhook.sh" "$NEW"
  mt "hard-link refusal removed" 's/^  \[ "\$_links" -le 1 \] || .*$/  :/' 13 0 -- "$BASH_BIN" @SUT@ --apply "$HLW" "$NEW"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
