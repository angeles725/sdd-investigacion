#!/usr/bin/env bash
# lint-block.test.sh — suite for lint-block.sh + lint_block.py (kit issue #1206, slice 1).
#
# Covers: R3 (ephemeral evidence) at the FIRST / MIDDLE / LAST / SINGLE row positions plus its
# negatives (durable, mixed, file:line, non-hardware marker, outside Self-verify, fenced, bullets,
# other column layout); R6 (cross-block comparison) at paragraph/row/first-line/last-line/single-line
# positions plus its negatives (raw path cited, trigger and block ref in different clauses); the
# waiver token (valid, no reason, malformed, wrong rule, adjacent unit); FAIL vs --audit semantics;
# the typed §7 states (ABSENT-INPUT, EMPTY-INPUT, NO-MATCH, DEGRADED, UNREADABLE); read-only; and a
# mutation control per rule and per mode under --prove-teeth (lib/mutant.sh, kit #943).
#
# Fixtures are synthetic (tests/fixtures/lint-block/) — never copied client content.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../lint-block.sh"
HELPER="$HERE/../lint_block.py"
FX="$HERE/fixtures/lint-block"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== lint-block.test.sh =="

LAST_CASE_NUM="$(grep -oE '^# [0-9]+\. ' "$0" | tr -dc '0-9\n' | sort -n | tail -1)"
if [ -z "$LAST_CASE_NUM" ]; then echo "harness error: no '# <N>. ' case headings in $0" >&2; exit 2; fi
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# lines_of TAG FILE -> sorted, space-joined line numbers whose text contains TAG
lines_of() { grep -nF -- "$1" "$2" | cut -d: -f1 | sort -n | tr '\n' ' ' | sed 's/ $//'; }
# reported RULE OUTPUT FILE -> sorted, space-joined line numbers reported for RULE in FILE
reported() { printf '%s\n' "$2" | grep -E "^$1 .*/$(basename "$3"):[0-9]+:" | sed -E 's/^[^:]*[^ ]*\/[^/:]*:([0-9]+):.*/\1/' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
run() { OUT="$(bash "$SUT" "$@" 2>&1)"; RC=$?; }

# 1. Existence + executable + helper
if [ -f "$SUT" ] && [ -x "$SUT" ] && [ -f "$HELPER" ]; then ok "1 lint-block.sh (+x) and lint_block.py exist"
else no "1 lint-block.sh / lint_block.py missing or not executable"; fi
if [ ! -f "$SUT" ] || [ ! -f "$HELPER" ]; then
  for n in $(seq 2 "$LAST_CASE_NUM"); do no "$n (skipped: SUT missing)"; done
  echo "== $pass passed · $fail failed =="; exit 2
fi

# 2. Usage errors
run; [ "$RC" -eq 2 ] && ok "2a no arguments -> exit 2" || no "2a no arguments (rc=$RC)"
run --bogus "$FX/r3-first.md"; [ "$RC" -eq 2 ] && grep -qF 'unknown option' <<< "$OUT" \
  && ok "2b unknown option -> exit 2" || no "2b unknown option (rc=$RC out=[$OUT])"

# 3. R3 at FIRST / MIDDLE / LAST / SINGLE row positions: exact line of the ROW-BAD row, rc 1
for f in r3-first r3-middle r3-last r3-single; do
  run "$FX/$f.md"
  want="$(lines_of ROW-BAD "$FX/$f.md")"; got="$(reported R3 "$OUT" "$FX/$f.md")"
  if [ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ]; then ok "3 R3 $f -> reported exactly line $want, exit 1"
  else no "3 R3 $f (rc=$RC want=[$want] got=[$got] out=[$OUT])"; fi
done

# 4. R3 negatives: durable / mixed / file:line / block ref / non-hardware marker / no path -> clean,
#    AND the coverage counter proves the rows were looked at (6 rows, 5 carry cert-hw/live markers).
run "$FX/r3-clean.md"
if [ "$RC" -eq 0 ] && grep -qF 'NO-MATCH' <<< "$OUT" && grep -qF 'cert-hw-live-items=5' <<< "$OUT" \
   && grep -qF 'selfverify-sections=1' <<< "$OUT"; then
  ok "4 R3 clean fixture -> exit 0, NO-MATCH, coverage counters prove rows were inspected"
else no "4 R3 clean fixture (rc=$RC out=[$OUT])"; fi

# 5. R3 other shapes
run "$FX/r3-bullets.md"; want="$(lines_of ROW-BAD "$FX/r3-bullets.md")"; got="$(reported R3 "$OUT" "$FX/r3-bullets.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "5a bullet-form Self-verify item flagged on its own line" || no "5a bullets (rc=$RC want=[$want] got=[$got])"
run "$FX/r3-scratchpad.md"; want="$(lines_of ROW-BAD "$FX/r3-scratchpad.md")"; got="$(reported R3 "$OUT" "$FX/r3-scratchpad.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "5b scratchpad-only and \$TMPDIR-only evidence flagged (2 rows)" || no "5b scratchpad (rc=$RC want=[$want] got=[$got])"
run "$FX/r3-outside.md"
[ "$RC" -eq 0 ] && ok "5c ephemeral row OUTSIDE a Self-verify section is not an R3 finding" || no "5c outside section (rc=$RC out=[$OUT])"
run "$FX/r3-fenced.md"
[ "$RC" -eq 0 ] && ok "5d quoted table inside a fenced code block is not linted" || no "5d fenced (rc=$RC out=[$OUT])"
run "$FX/r3-twocol.md"; want="$(lines_of ROW-BAD "$FX/r3-twocol.md")"; got="$(reported R3 "$OUT" "$FX/r3-twocol.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "5e different column layout: evidence = cells after the marker cell" || no "5e layout (rc=$RC want=[$want] got=[$got])"

# 6. R6 positions and negatives
run "$FX/r6-bad.md"; want="$(lines_of PARA-BAD "$FX/r6-bad.md") $(lines_of ROW-BAD "$FX/r6-bad.md")"; got="$(reported R6 "$OUT" "$FX/r6-bad.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "6a R6 paragraph + table row flagged on the right lines ($want)" || no "6a R6 (rc=$RC want=[$want] got=[$got])"
run "$FX/r6-edges.md"; want="$(lines_of FIRST-LINE-BAD "$FX/r6-edges.md") $(lines_of LAST-LINE-BAD "$FX/r6-edges.md")"; got="$(reported R6 "$OUT" "$FX/r6-edges.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "6b R6 first line and last line (no trailing newline) of the file ($want)" || no "6b R6 edges (rc=$RC want=[$want] got=[$got])"
run "$FX/r6-single.md"
[ "$RC" -eq 1 ] && [ "$(reported R6 "$OUT" "$FX/r6-single.md")" = "1" ] && ok "6c R6 single-line file flagged at line 1" || no "6c R6 single (rc=$RC out=[$OUT])"
run "$FX/r6-clean.md"
[ "$RC" -eq 0 ] && grep -qF 'r6-trigger-clauses=2' <<< "$OUT" && ok "6d R6 cleared by a cited raw path; both trigger clauses were counted (looked at)" || no "6d R6 clean (rc=$RC out=[$OUT])"
run "$FX/r6-split.md"
[ "$RC" -eq 0 ] && ok "6e R6: block ref and 'does not mention' in DIFFERENT clauses is not a finding" || no "6e R6 split (rc=$RC out=[$OUT])"

printf '# Block 19 — synthetic\n\nNote the flag ([Block 429]) is filtered out of the sheet \xe2\x80\x94 wire layout never shows as a property.\n\n[Block 5] is cited here as provenance for a long and unrelated explanation that goes on well past the allowed distance before this block never mentions anything.\n' > "$TMP/r6-dash.md"
run "$TMP/r6-dash.md"
[ "$RC" -eq 0 ] && grep -qF 'r6-trigger-clauses=0' <<< "$OUT" && ok "6f R6: verdict separated from [Block N] by a dash / by >80 chars is NOT a comparison claim" || no "6f R6 dash/distance (rc=$RC out=[$OUT])"

printf '# Block 20 — synthetic\n\n[Block 55]%ss own probe (quoted in full, [Block 55] \xc2\xa755.2) does not mention the warning. DOT-BAD\n' "'" > "$TMP/r6-dot.md"
run "$TMP/r6-dot.md"
[ "$RC" -eq 1 ] && [ "$(reported R6 "$OUT" "$TMP/r6-dot.md")" = "$(lines_of DOT-BAD "$TMP/r6-dot.md")" ] && ok "6g R6: a '.' inside a token (section number 55.2) is not a sentence boundary" || no "6g R6 dotted token (rc=$RC out=[$OUT])"

# 7. Waivers
run "$FX/waiver-ok.md"
[ "$RC" -eq 0 ] && ok "7a valid waivers (R3 row, R6 paragraph) suppress their rule -> exit 0" || no "7a waiver-ok (rc=$RC out=[$OUT])"
run "$FX/waiver-noreason.md"; want="$(lines_of ROW-BAD "$FX/waiver-noreason.md" | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//')"
if [ "$RC" -eq 1 ] && [ "$(reported R0 "$OUT" "$FX/waiver-noreason.md")" = "$want" ] && [ "$(reported R3 "$OUT" "$FX/waiver-noreason.md")" = "$want" ]; then
  ok "7b waiver without reason / empty reason -> R0 finding AND the original R3 still fires (fail closed)"
else no "7b no-reason (rc=$RC want=[$want] out=[$OUT])"; fi
run "$FX/waiver-malformed.md"
[ "$RC" -eq 1 ] && grep -qE '^R0 .*waiver names no rule id' <<< "$OUT" && ok "7c malformed waiver (no rule id) -> R0" || no "7c malformed (rc=$RC out=[$OUT])"
run "$FX/waiver-wrongrule.md"
[ "$RC" -eq 1 ] && [ "$(reported R3 "$OUT" "$FX/waiver-wrongrule.md")" = "$(lines_of ROW-BAD "$FX/waiver-wrongrule.md")" ] && ok "7d a waiver for a DIFFERENT rule does not waive R3" || no "7d wrong rule (rc=$RC out=[$OUT])"
run "$FX/waiver-adjacent.md"
[ "$RC" -eq 1 ] && [ "$(reported R3 "$OUT" "$FX/waiver-adjacent.md")" = "$(lines_of ROW-BAD "$FX/waiver-adjacent.md")" ] && ok "7e a waiver covers ONLY its own row; the neighbour row still fires" || no "7e adjacent (rc=$RC out=[$OUT])"

# 8. Typed states in FAIL mode
run "$FX/empty.md"
[ "$RC" -eq 0 ] && grep -qF 'EMPTY-INPUT' <<< "$OUT" && grep -qF 'empty=1' <<< "$OUT" && ok "8a empty file -> EMPTY-INPUT (not NO-MATCH), exit 0" || no "8a empty (rc=$RC out=[$OUT])"
run "$FX/blank.md"
[ "$RC" -eq 0 ] && grep -qF 'EMPTY-INPUT' <<< "$OUT" && ok "8b whitespace-only file -> EMPTY-INPUT" || no "8b blank (rc=$RC out=[$OUT])"
run "$FX/does-not-exist.md"
[ "$RC" -eq 2 ] && grep -qF 'ABSENT-INPUT' <<< "$OUT" && ok "8c absent file -> ABSENT-INPUT, exit 2" || no "8c absent (rc=$RC out=[$OUT])"
run "$FX/does-not-exist.md" "$FX/r3-first.md"
[ "$RC" -eq 2 ] && grep -qF 'ABSENT-INPUT' <<< "$OUT" && grep -qE '^R3 .*r3-first.md' <<< "$OUT" && ok "8d absent + good file: the good file is still linted, final exit stays 2" || no "8d absent+good (rc=$RC out=[$OUT])"
printf 'bad \377\376 bytes\n' > "$TMP/bad-utf8.md"
run "$TMP/bad-utf8.md" "$FX/r3-first.md"
[ "$RC" -eq 2 ] && grep -qF 'UNREADABLE' <<< "$OUT" && grep -qE '^R3 .*r3-first.md' <<< "$OUT" && ok "8e undecodable file -> UNREADABLE, exit 2, other files still linted" || no "8e unreadable (rc=$RC out=[$OUT])"
run "$FX/corpus"
[ "$RC" -eq 2 ] && grep -qF 'is a directory' <<< "$OUT" && ok "8f directory in FAIL mode -> exit 2 (corpora need --audit)" || no "8f dir in FAIL (rc=$RC out=[$OUT])"

# 9. Multi-file FAIL mode reports every file
run "$FX/r3-first.md" "$FX/r3-last.md" "$FX/r6-single.md"
if [ "$RC" -eq 1 ] && grep -qE '^R3 .*r3-first.md' <<< "$OUT" && grep -qE '^R3 .*r3-last.md' <<< "$OUT" \
   && grep -qE '^R6 .*r6-single.md' <<< "$OUT" && grep -qF 'files=3' <<< "$OUT"; then
  ok "9 multi-file FAIL run reports every file's findings and files=3"
else no "9 multi-file (rc=$RC out=[$OUT])"; fi

# 10. --audit: report-only over a corpus directory
run --audit "$FX/corpus"
if [ "$RC" -eq 0 ] && grep -qF 'SUMMARY AUDIT files=3 ' <<< "$OUT" && grep -qF 'R3=2' <<< "$OUT" \
   && grep -qF 'R6=1' <<< "$OUT" && grep -qF 'findings=3' <<< "$OUT" \
   && ! grep -qE '^R[036] .*notes.md' <<< "$OUT" && grep -qF 'UNCLASSIFIED: 1' <<< "$OUT"; then
  ok "10a --audit corpus: exit 0 with findings, nested bloque file found, decoy notes.md never scanned but reported UNCLASSIFIED (files=3 R3=2 R6=1)"
else no "10a audit corpus (rc=$RC out=[$OUT])"; fi
run --audit "$FX/corpus-empty"
[ "$RC" -eq 0 ] && grep -qF 'has no canonical block files' <<< "$OUT" && ! grep -qF 'NO-MATCH' <<< "$OUT" && ok "10b --audit dir with no block files -> EMPTY-INPUT (distinct from NO-MATCH), exit 0" || no "10b audit empty (rc=$RC out=[$OUT])"
run --audit "$FX/corpus-nomatch"
[ "$RC" -eq 0 ] && grep -qF 'NO-MATCH' <<< "$OUT" && grep -qF 'files=1 ' <<< "$OUT" && ok "10c --audit clean corpus -> NO-MATCH with files=1 (looked, found nothing)" || no "10c audit nomatch (rc=$RC out=[$OUT])"
run --audit "$TMP/no-such-dir"
[ "$RC" -eq 2 ] && grep -qF 'ABSENT-INPUT' <<< "$OUT" && ok "10d --audit absent path -> ABSENT-INPUT, exit 2" || no "10d audit absent (rc=$RC out=[$OUT])"
run --audit "$FX/r3-first.md"
[ "$RC" -eq 0 ] && grep -qE '^R3 ' <<< "$OUT" && ok "10e --audit on a single file reports findings, still exit 0" || no "10e audit file (rc=$RC out=[$OUT])"
mkdir -p "$TMP/.claude/wt" "$TMP/pruned/node_modules/m" "$TMP/pruned/.claude"
cp -R "$FX/corpus" "$TMP/.claude/wt/corpus"
cp "$FX/corpus-nomatch/demo-block1.md" "$TMP/pruned/node_modules/m/vendored-block1.md"
cp "$FX/corpus-nomatch/demo-block1.md" "$TMP/pruned/.claude/hidden-block2.md"
cp "$FX/corpus-nomatch/demo-block1.md" "$TMP/pruned/real-block3.md"
run --audit "$TMP/.claude/wt/corpus"
[ "$RC" -eq 0 ] && grep -qF 'SUMMARY AUDIT files=3 ' <<< "$OUT" \
  && ok "10g corpus living UNDER a .claude/ ancestor is still scanned (prune is by basename below the root)" || no "10g .claude ancestor (rc=$RC out=[$OUT])"
run --audit "$TMP/pruned"
[ "$RC" -eq 0 ] && grep -qF 'SUMMARY AUDIT files=1 ' <<< "$OUT" \
  && ok "10h node_modules/ and .claude/ SUBTREES below the root are pruned (files=1)" || no "10h prune (rc=$RC out=[$OUT])"
run "$FX/corpus-nomatch/demo-block1.md"
[ "$RC" -eq 0 ] && grep -qF 'SUMMARY LINT' <<< "$OUT" && ok "10f FAIL mode on a clean block -> exit 0, SUMMARY LINT" || no "10f fail clean (rc=$RC out=[$OUT])"

# 11. DEGRADED: no python3 on PATH -> exit 2, never a clean pass
mkdir -p "$TMP/nopy-bin"
for t in dirname mktemp rm cat find sort grep sed; do p="$(command -v "$t")" && ln -sf "$p" "$TMP/nopy-bin/$t"; done
OUT="$(PATH="$TMP/nopy-bin" "$BASH" "$SUT" "$FX/r3-first.md" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && grep -qF 'DEGRADED' <<< "$OUT" && ok "11 python3 absent -> DEGRADED, exit 2 (not a confident 0)" || no "11 degraded (rc=$RC out=[$OUT])"

# 12. Read-only: a linting run leaves the fixture tree byte-identical
before="$(cd "$FX" && find . -type f -print0 | sort -z | xargs -0 sha1sum | sha1sum)"
run --audit "$FX/corpus" >/dev/null; run "$FX/r3-first.md" >/dev/null
after="$(cd "$FX" && find . -type f -print0 | sort -z | xargs -0 sha1sum | sha1sum)"
[ "$before" = "$after" ] && ok "12 read-only: fixture tree unchanged after audit + fail runs" || no "12 fixture tree was modified by the linter"

# 13. Helper CLI guards
OUT="$(python3 "$HELPER" --files-from /etc/hostname 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && ok "13 helper rejects --files-from <non-stdin> -> exit 2" || no "13 helper arg guard (rc=$RC out=[$OUT])"

# 14. Review round 1 (kit #1206): durable-evidence strictness, hyphen variants, fences, headings,
#     waiver aliases/unknown ids, R6 verb forms, loader exit code, UNCLASSIFIED reporting.
run "$FX/r3-slashtokens.md"; want="$(lines_of ROW-BAD "$FX/r3-slashtokens.md")"; got="$(reported R3 "$OUT" "$FX/r3-slashtokens.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "14a ephemeral-only rows with binary/sha256, 3/3, N/A, and/or, bare out.txt:12, [Block 12]/B12 are ALL flagged ($want)" || no "14a slash tokens (rc=$RC want=[$want] got=[$got])"
run "$FX/r3-durable2.md"
[ "$RC" -eq 0 ] && grep -qF 'cert-hw-live-items=5' <<< "$OUT" && ok "14b path-shaped durable forms (dir/, 3 segments, dir+file:line, canonical block file, dir+ext) clear an ephemeral row" || no "14b durable forms (rc=$RC out=[$OUT])"
run "$FX/r3-hyphen.md"; want="$(lines_of ROW-BAD "$FX/r3-hyphen.md")"; got="$(reported R3 "$OUT" "$FX/r3-hyphen.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "14c U+2011 hyphen in 'Self-verify' and in the marker, lower-case [cert-hw] are recognised ($want)" || no "14c hyphen variants (rc=$RC want=[$want] got=[$got])"
run "$FX/r3-quoted.md"; want="$(lines_of ROW-BAD "$FX/r3-quoted.md")"; got="$(reported R3 "$OUT" "$FX/r3-quoted.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "14d Self-verify heading + table inside a blockquote are linted (dequoting)" || no "14d blockquote (rc=$RC want=[$want] got=[$got])"
run "$FX/r3-tilde.md"
[ "$RC" -eq 0 ] && ok "14e ~~~ fenced table is skipped" || no "14e tilde fence (rc=$RC out=[$OUT])"
run "$FX/r3-fence-mismatch.md"
[ "$RC" -eq 0 ] && ! grep -qF 'WARN' <<< "$OUT" && ok "14f a ~~~ line does not close a \`\`\` fence (CommonMark); no spurious WARN" || no "14f fence mismatch (rc=$RC out=[$OUT])"
run "$FX/r3-unclosed.md"
[ "$RC" -eq 0 ] && grep -qE '^WARN .*r3-unclosed.md:5: unclosed' <<< "$OUT" && grep -qF 'warn=1' <<< "$OUT" && ok "14g unclosed fence -> WARN with its line (5) and warn=1 in SUMMARY, not a silent skip" || no "14g unclosed fence (rc=$RC out=[$OUT])"
run "$FX/r3-header.md"
[ "$RC" -eq 0 ] && grep -qF 'cert-hw-live-items=1' <<< "$OUT" && ok "14h a table HEADER row carrying marker text is not inspected as an item (items=1)" || no "14h header row (rc=$RC out=[$OUT])"
run "$FX/r3-hashtag.md"; want="$(lines_of ROW-BAD "$FX/r3-hashtag.md")"; got="$(reported R3 "$OUT" "$FX/r3-hashtag.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "14i '#1 priority' is not a heading: the Self-verify section continues past it" || no "14i hashtag (rc=$RC want=[$want] got=[$got])"
run "$FX/waiver-fenced.md"
[ "$RC" -eq 0 ] && ok "14j waiver-shaped tokens inside a fence are not parsed (no R0)" || no "14j fenced waiver (rc=$RC out=[$OUT])"
run "$FX/waiver-alias.md"; want="$(lines_of ROW-BAD "$FX/waiver-alias.md")"
[ "$RC" -eq 1 ] && [ "$(reported R3 "$OUT" "$FX/waiver-alias.md")" = "$want" ] && [ "$(reported R0 "$OUT" "$FX/waiver-alias.md")" = "$want" ] \
  && ok "14k reference alias <!-- lint-ok: R3 reason --> waives with a reason; without one: R0 + R3 still fires" || no "14k alias (rc=$RC out=[$OUT])"
run "$FX/waiver-unknown.md"
if [ "$RC" -eq 1 ] && grep -qE '^R0 .*unknown rule R99' <<< "$OUT" && grep -qE '^R0 .*upper-case' <<< "$OUT" \
   && [ "$(reported R3 "$OUT" "$FX/waiver-unknown.md")" = "$(lines_of LOW-BAD "$FX/waiver-unknown.md")" ]; then
  ok "14l waiver for an unknown rule id -> R0; lower-case id -> R0 'upper-case' and does not waive"
else no "14l unknown/lower waiver (rc=$RC out=[$OUT])"; fi
run "$FX/r6-verbs.md"; want="$(lines_of -BAD "$FX/r6-verbs.md")"; got="$(reported R6 "$OUT" "$FX/r6-verbs.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "14m R6 verb forms: never mentioned / did not cite / never references / do not include / didn't show" || no "14m R6 verbs (rc=$RC want=[$want] got=[$got])"
mkdir -p "$TMP/nolib"; cp "$SUT" "$HELPER" "$TMP/nolib/"
OUT="$(bash "$TMP/nolib/lint-block.sh" "$FX/r3-first.md" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && grep -qF 'block_file_filter' <<< "$OUT" && ok "14n failed load of lib/block-files.sh -> exit 2 (never 1 = findings)" || no "14n lib load failure (rc=$RC out=[$OUT])"
run --audit "$FX/corpus-unclassified"
[ "$RC" -eq 0 ] && grep -qF 'UNCLASSIFIED: 2' <<< "$OUT" && grep -qF 'notes.md' <<< "$OUT" && grep -qF 'files=1 ' <<< "$OUT" \
  && ok "14o --audit reports non-canonical .md files as UNCLASSIFIED: 2 (with paths), not silently dropped" || no "14o unclassified (rc=$RC out=[$OUT])"
run --audit "$FX/corpus-empty"
grep -qF 'UNCLASSIFIED: 1' <<< "$OUT" && grep -qF 'has no canonical block files' <<< "$OUT" && ok "14p block-less dir: EMPTY-INPUT plus UNCLASSIFIED: 1" || no "14p empty+unclassified (rc=$RC out=[$OUT])"
run "$FX/r3-prose.md"
[ "$RC" -eq 0 ] && grep -qF 'cert-hw-live-items=1' <<< "$OUT" && ok "14q prose paragraph that merely MENTIONS a marker and a /tmp path is not an item (only table rows / list items are); the real bullet is counted" || no "14q prose (rc=$RC out=[$OUT])"
run "$FX/waiver-reserved.md"
if [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -cE '^INFO .*waiver for inactive pack rule R(9|1) \(not enforced by the generic core\)')" = "2" ] \
   && grep -qF 'inactive-waivers=2' <<< "$OUT" && grep -qF 'findings=0' <<< "$OUT"; then
  ok "15a waivers naming RESERVED pack rule ids (R9, R1 alias) are INFO, not R0: exit 0, inactive-waivers=2"
else no "15a reserved waivers (rc=$RC out=[$OUT])"; fi
run "$FX/waiver-reserved-bad.md"; want="$(lines_of BAD "$FX/waiver-reserved-bad.md")"
if [ "$RC" -eq 1 ] && [ "$(reported R0 "$OUT" "$FX/waiver-reserved-bad.md")" = "$want" ] && grep -qF 'inactive-waivers=0' <<< "$OUT" \
   && grep -qE '^R0 .*unknown rule R99' <<< "$OUT" && grep -qE '^R0 .*unknown rule R10' <<< "$OUT"; then
  ok "15b unknown ids (R99, R10), a reason-less reserved waiver and a lower-case reserved id all stay R0 (4 findings, inactive-waivers=0)"
else no "15b reserved-bad (rc=$RC want=[$want] out=[$OUT])"; fi
run "$FX/r6-code.md"
[ "$RC" -eq 0 ] && grep -qF 'r6-trigger-clauses=0' <<< "$OUT" && ok "16a R6: 'never references/referenced' (code sense: constant, API) is NOT a comparison claim" || no "16a R6 code sense (rc=$RC out=[$OUT])"
run "$FX/r3-words.md"; want="$(lines_of ROW-BAD "$FX/r3-words.md")"; got="$(reported R3 "$OUT" "$FX/r3-words.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "16b R3: read/write/execute, N4.14/N5.0 (digit-only extension) and runs/3.14 do not clear a row ($want)" || no "16b word tokens (rc=$RC want=[$want] got=[$got])"
run "$FX/r3-fence-short.md"
[ "$RC" -eq 0 ] && ! grep -qF 'WARN' <<< "$OUT" && ok "16c a closing fence SHORTER than its opener does not close it (4-backtick fence holds a 3-backtick line)" || no "16c short closer (rc=$RC out=[$OUT])"
mkdir -p "$TMP/pruned2/.venv" "$TMP/pruned2/venv" "$TMP/pruned2/lib/site-packages" "$TMP/pruned2/.atl"
for d in .venv venv lib/site-packages .atl; do cp "$FX/corpus-nomatch/demo-block1.md" "$TMP/pruned2/$d/vendored-block1.md"; printf '# n\n' > "$TMP/pruned2/$d/notes.md"; done
cp "$FX/corpus-nomatch/demo-block1.md" "$TMP/pruned2/real-block2.md"
run --audit "$TMP/pruned2"
[ "$RC" -eq 0 ] && grep -qF 'SUMMARY AUDIT files=1 ' <<< "$OUT" && ! grep -qF 'UNCLASSIFIED' <<< "$OUT" && ok "16d .venv, venv, site-packages and .atl subtrees are pruned: not scanned and not counted as UNCLASSIFIED" || no "16d tool-dir prune (rc=$RC out=[$OUT])"

# 17. Slice 2 (kit #1365 item 3): inline `[CERT-hw] (<ephemeral path>)` evidence OUTSIDE Self-verify
run "$FX/r3-inline.md"; want="$(lines_of INLINE-BAD "$FX/r3-inline.md")"; got="$(reported R3 "$OUT" "$FX/r3-inline.md")"
if [ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] && grep -qF 'cert-inline-items=10' <<< "$OUT"; then
  ok "17a inline marker + ephemeral-only parenthetical flagged on the exact lines ($want): paragraph, list item, table row, nested paren, last line; durable/no-path/no-group/later-aside negatives clear (incl. prose-only group); 10 groups inspected"
else no "17a inline (rc=$RC want=[$want] got=[$got] out=[$OUT])"; fi
run "$FX/r3-inline-single.md"
[ "$RC" -eq 1 ] && [ "$(reported R3 "$OUT" "$FX/r3-inline-single.md")" = "1" ] && ok "17b inline R3 on a single-line file flagged at line 1" || no "17b inline single (rc=$RC out=[$OUT])"
run "$FX/r3-inline-waived.md"; want="$(lines_of INLINE-BAD "$FX/r3-inline-waived.md")"; got="$(reported R3 "$OUT" "$FX/r3-inline-waived.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "17c inline R3: a valid waiver waives its paragraph; wrong-rule and reason-less waivers do not ($want)" || no "17c inline waiver (rc=$RC want=[$want] got=[$got] out=[$OUT])"
run "$FX/r3-inline-selfverify.md"; got="$(reported R3 "$OUT" "$FX/r3-inline-selfverify.md")"
want="$(lines_of ROW-BAD "$FX/r3-inline-selfverify.md") $(lines_of INLINE-BAD "$FX/r3-inline-selfverify.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && grep -qE 'cert-inline-items=1($| )' <<< "$OUT" && ok "17d Self-verify rows/items reported once (no duplicate from the inline pass); Self-verify prose stays out of scope; only the unit outside the section is an inline hit ($want)" || no "17d no-dup (rc=$RC want=[$want] got=[$got] out=[$OUT])"
run "$FX/r3-inline-fenced.md"
[ "$RC" -eq 0 ] && grep -qE 'cert-inline-items=1($| )' <<< "$OUT" && ok "17e inline marker inside a code fence is not linted; the real clean group is counted" || no "17e inline fenced (rc=$RC out=[$OUT])"
run --audit "$FX/r3-inline.md"
[ "$RC" -eq 0 ] && grep -qF 'R3=6' <<< "$OUT" && ok "17f --audit over inline findings stays report-only (exit 0, R3=6)" || no "17f inline audit (rc=$RC out=[$OUT])"

run "$FX/r3-inline-sep.md"; want="$(lines_of SEP-BAD "$FX/r3-inline-sep.md")"; got="$(reported R3 "$OUT" "$FX/r3-inline-sep.md")"
[ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] && grep -qE 'cert-inline-items=5( |$)' <<< "$OUT" && ok "17g optional separator between marker and group: colon, em dash, en dash, hyphen and backtick+colon flagged ($want); comma, semicolon and a double separator do not match (5 groups inspected)" || no "17g separators (rc=$RC want=[$want] got=[$got] out=[$OUT])"
run "$FX/r3-inline-cap.md"; want="$(lines_of CAP-BAD "$FX/r3-inline-cap.md")"; got="$(reported R3 "$OUT" "$FX/r3-inline-cap.md")"
[ "$RC" -eq 1 ] && [ -n "$want" ] && [ "$got" = "$want" ] && grep -qE 'cert-inline-items=1( |$)' <<< "$OUT" && ok "17h group of exactly 400 characters is flagged ($want); a 401-character group is not matched and not counted" || no "17h cap (rc=$RC want=[$want] got=[$got] out=[$OUT])"

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for lint-block.sh / lint_block.py --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  TOOLBELT="$HERE/.."

  # mk_tree NAME -> fresh copy of wrapper + helper + lib in $TMP/mt/NAME; echoes the dir
  mk_tree() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib"
    cp "$TOOLBELT/lint-block.sh" "$TOOLBELT/lint_block.py" "$d/"
    cp "$TOOLBELT/lib/block-files.sh" "$d/lib/"
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

  # A: R3 ephemeral trigger neutered -> the ROW-BAD row must false-pass
  if tooth_build A lint_block.py 's#^R3_EPHEMERAL_RE = .*#R3_EPHEMERAL_RE = re.compile(r"NEVER_MATCHES_XYZ")#'; then
    mrun "$FX/r3-first.md"
    [ "$MRC" -eq 0 ] && ok "teeth A: R3 trigger neutered -> ephemeral row FALSE-PASSES -> case 3 has teeth" || no "teeth A: mutant still flagged (rc=$MRC) — THEATER"
  fi
  # B: durable test no longer excludes ephemeral tokens (a /tmp path "counts" as durable)
  if tooth_build B lint_block.py 's#^    if R3_EPHEMERAL_RE.search(tok):#    if False:#'; then
    mrun "$FX/r3-first.md"
    [ "$MRC" -eq 0 ] && ok "teeth B: ephemeral path counted as durable -> row FALSE-PASSES -> durable-exclusion has teeth" || no "teeth B: mutant still flagged (rc=$MRC) — THEATER"
  fi
  # C: evidence taken from cells BEFORE the marker instead of after -> /tmp in provenance is missed
  if tooth_build C lint_block.py 's#cells\[idx + 1:\]#cells[:idx]#'; then
    mrun "$FX/r3-middle.md"
    [ "$MRC" -eq 0 ] && ok "teeth C: evidence cells = before-marker -> row FALSE-PASSES -> evidence-column logic has teeth" || no "teeth C: mutant still flagged (rc=$MRC) — THEATER"
  fi
  # D: R3 durable alternatives dropped -> the mixed row in r3-clean false-flags
  if tooth_build D lint_block.py 's#^    return any(R3_EXT_RE.search(x) for x in segs)#    return False#'; then
    mrun "$FX/r3-clean.md"
    [ "$MRC" -eq 1 ] && ok "teeth D: durable detection removed -> clean fixture FALSE-FLAGS -> negative cases have teeth" || no "teeth D: mutant still clean (rc=$MRC) — THEATER"
  fi
  # E: Self-verify section scoping dropped -> the row outside the section false-flags
  if tooth_build E lint_block.py 's#if u.kind not in ("row", "item") or u.line not in sv:#if u.kind not in ("row", "item"):#'; then
    mrun "$FX/r3-outside.md"
    [ "$MRC" -eq 1 ] && ok "teeth E: section scoping removed -> outside-section row FALSE-FLAGS -> case 5c has teeth" || no "teeth E: mutant still clean (rc=$MRC) — THEATER"
  fi
  # F: fenced-code skipping disabled -> the quoted table false-flags
  if tooth_build F lint_block.py 's#^        if i in fenced:$#        if False:#'; then
    mrun "$FX/r3-fenced.md"
    [ "$MRC" -eq 1 ] && ok "teeth F: fence skipping disabled -> quoted table FALSE-FLAGS -> case 5d has teeth" || no "teeth F: mutant still clean (rc=$MRC) — THEATER"
  fi
  # G: R6 claim pattern neutered
  if tooth_build G lint_block.py 's#\\\[Block\\s\*\\d+\\\]#NEVER_MATCHES_XYZ#'; then
    mrun "$FX/r6-single.md"
    [ "$MRC" -eq 0 ] && ok "teeth G: R6 trigger neutered -> comparison FALSE-PASSES -> case 6 has teeth" || no "teeth G: mutant still flagged (rc=$MRC) — THEATER"
  fi
  # H: R6 sentence/clause boundary dropped from the gap class -> split-clause fixture false-flags
  if tooth_build H lint_block.py 's#\[^\.;—#[^—#'; then
    mrun "$FX/r6-split.md"
    [ "$MRC" -eq 1 ] && ok "teeth H: sentence boundary dropped -> split-clause fixture FALSE-FLAGS -> case 6e has teeth" || no "teeth H: mutant still clean (rc=$MRC) — THEATER"
  fi
  # H2: R6 dash boundary dropped -> the dash fixture false-flags
  if tooth_build H2 lint_block.py 's#—–##'; then
    mrun "$TMP/r6-dash.md"
    [ "$MRC" -eq 1 ] && ok "teeth H2: dash boundary dropped -> 'filtered out - never shows' FALSE-FLAGS -> case 6f has teeth" || no "teeth H2: mutant still clean (rc=$MRC) — THEATER"
  fi
  # H3: R6 distance cap dropped -> the long-distance fixture false-flags
  if tooth_build H3 lint_block.py 's#{0,80}?#*?#'; then
    mrun "$TMP/r6-dash.md"
    [ "$MRC" -eq 1 ] && ok "teeth H3: distance cap dropped -> far-apart reference FALSE-FLAGS -> case 6f has teeth" || no "teeth H3: mutant still clean (rc=$MRC) — THEATER"
  fi
  # H4: dotted-token tolerance dropped -> a section number ends the claim (false negative)
  if tooth_build H4 lint_block.py 's#|\\.(?=\\S)##'; then
    mrun "$TMP/r6-dot.md"
    [ "$MRC" -eq 0 ] && ok "teeth H4: dotted-token tolerance dropped -> claim after 'section 55.2' FALSE-PASSES -> case 6g has teeth" || no "teeth H4: mutant still flagged (rc=$MRC) — THEATER"
  fi
  # I: R6 raw-path clearing neutered -> the cited-path fixture false-flags
  if tooth_build I lint_block.py 's#^        if R6_RAW_PATH_RE.search(u.text):#        if False:#'; then
    mrun "$FX/r6-clean.md"
    [ "$MRC" -eq 1 ] && ok "teeth I: R6 raw-path clearing neutered -> cited fixture FALSE-FLAGS -> case 6d has teeth" || no "teeth I: mutant still clean (rc=$MRC) — THEATER"
  fi
  # J: waiver reason requirement dropped -> a reason-less waiver suppresses
  if tooth_build J lint_block.py 's#^                if not reason:#                if False:#'; then
    mrun "$FX/waiver-noreason.md"
    [ "$MRC" -eq 0 ] && ok "teeth J: reason requirement dropped -> reason-less waiver SUPPRESSES -> case 7b has teeth" || no "teeth J: mutant still flagged (rc=$MRC) — THEATER"
  fi
  # K: waiver rule match ignored -> a waiver for another rule suppresses
  if tooth_build K lint_block.py 's#return any(r == rule and first <= ln <= last#return any(first <= ln <= last#'; then
    mrun "$FX/waiver-wrongrule.md"
    [ "$MRC" -eq 0 ] && ok "teeth K: waiver rule id ignored -> wrong-rule waiver SUPPRESSES -> case 7d has teeth" || no "teeth K: mutant still flagged (rc=$MRC) — THEATER"
  fi
  # L: waiver line range ignored -> a waiver on one row waives its neighbour
  if tooth_build L lint_block.py 's#first <= ln <= last for ln, r in#True for ln, r in#'; then
    mrun "$FX/waiver-adjacent.md"
    [ "$MRC" -eq 0 ] && ok "teeth L: waiver range ignored -> neighbour row SUPPRESSED -> case 7e has teeth" || no "teeth L: mutant still flagged (rc=$MRC) — THEATER"
  fi
  # M: FAIL-mode exit code neutered
  if tooth_build M lint_block.py 's#return 1 if total else 0#return 0#'; then
    mrun "$FX/r3-first.md"
    [ "$MRC" -eq 0 ] && ok "teeth M: FAIL exit code neutered -> findings exit 0 -> FAIL-mode assertions have teeth" || no "teeth M: mutant still exited $MRC — THEATER"
  fi
  # N: --audit no longer report-only
  if tooth_build N lint_block.py 's#^    if audit:$#    if False:#'; then
    mrun --audit "$FX/corpus"
    [ "$MRC" -eq 1 ] && ok "teeth N: --audit exit neutered -> audit exits 1 on findings -> case 10a has teeth" || no "teeth N: mutant still exited $MRC — THEATER"
  fi
  # O: unreadable file no longer fails the run
  if tooth_build O lint_block.py 's#^    if unreadable:$#    if False:#'; then
    mrun "$TMP/bad-utf8.md"
    [ "$MRC" -eq 0 ] && ok "teeth O: unreadable no longer fails -> undecodable file passes -> case 8e has teeth" || no "teeth O: mutant still exited $MRC — THEATER"
  fi
  # P: coverage counter neutered (looked-at proof lies)
  if tooth_build P lint_block.py 's#doc.cov\["cert_hw_live_items"\] += 1#doc.cov["cert_hw_live_items"] += 0#'; then
    mrun "$FX/r3-clean.md"
    grep -qF 'cert-hw-live-items=5' <<< "$MOUT" && no "teeth P: counter mutant still reports 5 — THEATER" \
      || ok "teeth P: coverage counter neutered -> summary no longer proves rows were inspected -> case 4 has teeth"
  fi
  # Q: wrapper — absent path no longer fails
  if tooth_build Q lint-block.sh '/ABSENT-INPUT/{n;s/rc_ops=2/rc_ops=0/}'; then
    mrun "$FX/does-not-exist.md" "$FX/r3-clean.md"
    [ "$MRC" -eq 0 ] && ok "teeth Q: ABSENT-INPUT exit neutered -> absent path passes -> case 8c/8d have teeth" || no "teeth Q: mutant still exited $MRC — THEATER"
  fi
  # R: wrapper — canonical block-file filter dropped -> decoy notes.md scanned
  if tooth_build R lint-block.sh 's#block_file_filter < "\$tmp/all" > "\$tmp/found"#cat < "$tmp/all" > "$tmp/found"#'; then
    mrun --audit "$FX/corpus"
    grep -qF 'notes.md' <<< "$MOUT" && ok "teeth R: filter dropped -> decoy notes.md SCANNED -> case 10a has teeth" || no "teeth R: decoy not scanned — THEATER :: out=[$MOUT]"
  fi
  # S: wrapper — python3 probe disabled -> no DEGRADED report
  if tooth_build S lint-block.sh 's#command -v python3 >/dev/null 2>&1#command -v dirname >/dev/null 2>\&1#'; then
    MOUT="$(PATH="$TMP/nopy-bin" "$BASH" "$MT/lint-block.sh" "$FX/r3-first.md" 2>&1)"; MRC=$?
    grep -qF 'DEGRADED' <<< "$MOUT" && no "teeth S: probe mutant still reports DEGRADED — THEATER" || ok "teeth S: python3 probe disabled -> no DEGRADED signal -> case 11 has teeth"
  fi
  # U: wrapper — prune by absolute-path substring again -> a corpus under a .claude/ ancestor vanishes
  if tooth_build U lint-block.sh 's#-o -name \.claude#-o -path "*/.claude/*"#'; then
    mrun --audit "$TMP/.claude/wt/corpus"
    grep -qF 'SUMMARY AUDIT files=3 ' <<< "$MOUT" && no "teeth U: substring prune mutant still scans the corpus — THEATER" || ok "teeth U: substring prune -> corpus under .claude/ silently skipped -> case 10g has teeth"
  fi
  # V: wrapper — node_modules no longer pruned
  if tooth_build V lint-block.sh 's#-name node_modules -o ##'; then
    mrun --audit "$TMP/pruned"
    grep -qF 'SUMMARY AUDIT files=1 ' <<< "$MOUT" && no "teeth V: node_modules mutant still reports files=1 — THEATER" || ok "teeth V: node_modules not pruned -> vendored block scanned -> case 10h has teeth"
  fi
  # ---- Review round 1 teeth ----
  # tooth_set NAME FILE SED FIXTURE RULE -> mutant must NOT report exactly the lines the suite
  # asserts for that fixture (tag ROW-BAD, or TAG given as 6th arg).
  tooth_set() {
    local name="$1" file="$2" expr="$3" fx="$4" rule="$5" tag="${6:-ROW-BAD}" want got
    tooth_build "$name" "$file" "$expr" || return 0
    mrun "$fx"
    want="$(lines_of "$tag" "$fx")"; got="$(reported "$rule" "$MOUT" "$fx")"
    if ! grep -qF 'SUMMARY' <<< "$MOUT"; then no "teeth $name: mutant crashed instead of linting (wrong-reason bite) :: out=[$MOUT]"
    elif [ "$got" != "$want" ]; then ok "teeth $name: mutant reports [$got] instead of [$want] -> the exact-set assertion has teeth"
    else no "teeth $name: mutant still reports the asserted set [$want] — THEATER"; fi
  }
  tooth_set V1 lint_block.py 's#if R3_BLOCKFILE_RE.search(tok):#if re.search(r"(?:block|bloque|B)[- ]?[0-9]+", tok, re.I):#' "$FX/r3-slashtokens.md" R3
  tooth_set V2 lint_block.py 's#^    return any(R3_EXT_RE.search(x) for x in segs)#    return len(segs) >= 2#' "$FX/r3-slashtokens.md" R3
  tooth_set V3 lint_block.py 's#^    if len(segs) < 2:#    if len(segs) < 1:#' "$FX/r3-slashtokens.md" R3
  if tooth_build V4 lint_block.py 's#^    if tok.endswith("/") and segs:#    if False:#'; then
    mrun "$FX/r3-durable2.md"
    [ "$MRC" -eq 1 ] && ok "teeth V4: trailing-slash rule removed -> \`evidence/\` no longer clears a row -> case 14b has teeth" || no "teeth V4: mutant still clean (rc=$MRC) — THEATER"
  fi
  tooth_set W1 lint_block.py 's#^_HY = .*#_HY = "[- ]"#' "$FX/r3-hyphen.md" R3
  tooth_set W2 lint_block.py '/^R3_MARKER_RE/s/, re.IGNORECASE//' "$FX/r3-hyphen.md" R3
  if tooth_build X1 lint_block.py 's#set(st) == {open_ch}#set(st) <= set("`~")#'; then
    mrun "$FX/r3-fence-mismatch.md"
    [ "$MRC" -eq 1 ] && ok "teeth X1: any fence char closes -> ~~~ inside a \`\`\` fence leaks the row -> case 14f has teeth" || no "teeth X1: mutant still clean (rc=$MRC) — THEATER"
  fi
  if tooth_build X2 lint_block.py 's#^    if open_ch is not None:#    if False:#'; then
    mrun "$FX/r3-unclosed.md"
    grep -qF 'WARN' <<< "$MOUT" && no "teeth X2: mutant still warns — THEATER" || ok "teeth X2: unclosed-fence WARN removed -> hidden content is silent again -> case 14g has teeth"
  fi
  if tooth_build X3 lint_block.py 's#`{3,}|~{3,}#`{3,}#'; then
    mrun "$FX/r3-tilde.md"
    [ "$MRC" -eq 1 ] && ok "teeth X3: ~~~ fence recognition removed -> tilde-fenced row FALSE-FLAGS -> case 14e has teeth" || no "teeth X3: mutant still clean (rc=$MRC) — THEATER"
  fi
  tooth_set Y1 lint_block.py 's#^    return BLOCKQUOTE_RE.sub("", line, count=1)#    return line#' "$FX/r3-quoted.md" R3
  if tooth_build Y2 lint_block.py 's#units.append(Unit(prev.text, prev.line, "header"))#units.append(Unit(prev.text, prev.line, "row"))#'; then
    mrun "$FX/r3-header.md"
    [ "$MRC" -eq 1 ] && ok "teeth Y2: header row demoted to a plain row -> its legend text FALSE-FLAGS -> case 14h has teeth" || no "teeth Y2: mutant still clean (rc=$MRC) — THEATER"
  fi
  tooth_set Y3 lint_block.py 's#^HEADING_RE = .*#HEADING_RE = re.compile(r"^\s*(\#{1,6})\s*(.*)$")#' "$FX/r3-hashtag.md" R3
  if tooth_build Z1 lint_block.py 's#^            if i in self.fenced:#            if False:#'; then
    mrun "$FX/waiver-fenced.md"
    [ "$MRC" -eq 1 ] && ok "teeth Z1: fence check dropped in waiver parsing -> quoted tokens become R0 -> case 14j has teeth" || no "teeth Z1: mutant still clean (rc=$MRC) — THEATER"
  fi
  tooth_set Z2 lint_block.py 's#alias = m.group(1).lower() == "ok"#alias = False#' "$FX/waiver-alias.md" R3
  if tooth_build Z3 lint_block.py 's#^                if rule not in RULE_IDS and not inactive:#                if False:#'; then
    mrun "$FX/waiver-unknown.md"
    grep -qE '^R0 .*unknown rule R99' <<< "$MOUT" && no "teeth Z3: mutant still reports the unknown rule — THEATER" || ok "teeth Z3: unknown-rule check removed -> R99 waiver accepted silently -> case 14l has teeth"
  fi
  tooth_set Z4 lint_block.py 's#^                if raw_id != rule:#                if False:#' "$FX/waiver-unknown.md" R3 LOW-BAD
  tooth_set Q1 lint_block.py 's#|cite)#)#' "$FX/r6-verbs.md" R6 -BAD
  tooth_set Q2 lint_block.py 's#(?:s|ed|d)?\\b",#s?\\b",#' "$FX/r6-verbs.md" R6 -BAD
  if tooth_build B2 lint-block.sh '/failed to define block_file_filter/{n;s/exit 2/exit 1/}'; then
    rm -rf "$TMP/mt/B2/lib"
    mrun "$FX/r3-first.md"
    [ "$MRC" -eq 1 ] && ok "teeth B2: loader failure exits 1 (= findings) -> case 14n has teeth" || no "teeth B2: mutant exited $MRC — THEATER"
  fi
  if tooth_build U2 lint-block.sh 's#block_file_filter -v < "\$tmp/all" > "\$tmp/unclass"#: > "$tmp/unclass"#'; then
    mrun --audit "$FX/corpus-unclassified"
    grep -qF 'UNCLASSIFIED' <<< "$MOUT" && no "teeth U2: mutant still reports UNCLASSIFIED — THEATER" || ok "teeth U2: unclassified listing removed -> non-canonical files dropped silently -> case 14o has teeth"
  fi
  if tooth_build P2 lint_block.py 's#if u.kind not in ("row", "item") or u.line not in sv:#if u.kind not in ("row", "item", "para") or u.line not in sv:#'; then
    mrun "$FX/r3-prose.md"
    [ "$MRC" -eq 1 ] && ok "teeth P2: prose paragraphs inspected -> explanatory text FALSE-FLAGS (measured: niagara5 block26:359) -> case 14q has teeth" || no "teeth P2: mutant still clean (rc=$MRC) — THEATER"
  fi
  if tooth_build R1 lint_block.py 's#^RESERVED_PACK_RULE_IDS = .*#RESERVED_PACK_RULE_IDS = ()#'; then
    mrun "$FX/waiver-reserved.md"
    [ "$MRC" -eq 1 ] && ok "teeth R1: reserved set emptied -> pack-rule waivers become R0 (block123 shape fails FAIL mode) -> case 15a has teeth" || no "teeth R1: mutant still exits $MRC — THEATER"
  fi
  if tooth_build R2 lint_block.py 's#^RESERVED_PACK_RULE_IDS = .*#RESERVED_PACK_RULE_IDS = tuple("R%d" % n for n in range(1, 200))#'; then
    mrun "$FX/waiver-reserved-bad.md"
    grep -qE '^R0 .*unknown rule R99' <<< "$MOUT" && no "teeth R2: mutant still reports R99 unknown — THEATER" || ok "teeth R2: reserved set widened to R1..R199 -> R99 silently accepted -> case 15b has teeth"
  fi
  if tooth_build R3 lint_block.py 's#^                if not reason:#                if False:#'; then
    mrun "$FX/waiver-reserved-bad.md"
    [ "$(reported R0 "$MOUT" "$FX/waiver-reserved-bad.md")" = "$(lines_of BAD "$FX/waiver-reserved-bad.md")" ] && no "teeth R3: mutant still flags the reason-less reserved waiver — THEATER" || ok "teeth R3: reason check dropped -> reason-less reserved waiver accepted -> case 15b has teeth"
  fi
  if tooth_build K1 lint_block.py 's#|cite)(?:s|ed|d)?#|cite|reference)(?:s|ed|d)?#'; then
    mrun "$FX/r6-code.md"
    [ "$MRC" -eq 1 ] && ok "teeth K1: 'reference' re-added to the verbs -> code-sense hits FALSE-FLAG (niagara5 block39:419) -> case 16a has teeth" || no "teeth K1: mutant still clean (rc=$MRC) — THEATER"
  fi
  tooth_set K2 lint_block.py 's#^    return any(R3_EXT_RE.search(x) for x in segs)#    return len(segs) >= 2#' "$FX/r3-words.md" R3
  tooth_set K3 lint_block.py 's#^R3_EXT_RE = .*#R3_EXT_RE = re.compile(r"\.[A-Za-z0-9]{1,6}(?::\d+(?:-\d+)?)?$")#' "$FX/r3-words.md" R3
  if tooth_build K4 lint_block.py 's#len(st) >= open_len#len(st) >= 1#'; then
    mrun "$FX/r3-fence-short.md"
    [ "$MRC" -eq 1 ] && ok "teeth K4: closer length ignored -> short fence line closes the block early -> case 16c has teeth" || no "teeth K4: mutant still clean (rc=$MRC) — THEATER"
  fi
  for _n in .venv venv site-packages .atl; do
    if tooth_build "K5$_n" lint-block.sh "s#-o -name $_n##"; then
      mrun --audit "$TMP/pruned2"
      grep -qF 'SUMMARY AUDIT files=1 ' <<< "$MOUT" && no "teeth K5 $_n: mutant still prunes it — THEATER" || ok "teeth K5 $_n: prune name removed -> vendored tree scanned/counted -> case 16d has teeth"
    fi
  done
  # ---- Slice 2 (kit #1365 item 3) teeth: inline [CERT-hw] (<ephemeral>) outside Self-verify ----
  tooth_set I1 lint_block.py 's#R3_INLINE_GROUP_RE.match(u.text, m.end())#R3_INLINE_GROUP_RE.search(u.text, m.end())#' "$FX/r3-inline.md" R3 INLINE-BAD
  tooth_set I2 lint_block.py '/SENTINEL-R3-INLINE-BEGIN/,/SENTINEL-R3-INLINE-END/ s#if any(_is_durable_token(t) for t in R3_TOKEN_RE.findall(evidence)):#if False:#' "$FX/r3-inline.md" R3 INLINE-BAD
  tooth_set I3 lint_block.py '/SENTINEL-R3-INLINE-BEGIN/,/SENTINEL-R3-INLINE-END/ s#if doc.waived("R3", u):#if False:#' "$FX/r3-inline-waived.md" R3 INLINE-BAD
  tooth_set I4 lint_block.py '/SENTINEL-R3-INLINE-BEGIN/,/SENTINEL-R3-INLINE-END/ s#if not R3_EPHEMERAL_RE.search(evidence):#if False:#' "$FX/r3-inline.md" R3 INLINE-BAD
  tooth_set I5 lint_block.py 's#{0,400}#{0,5}#' "$FX/r3-inline.md" R3 INLINE-BAD
  tooth_set I6 lint_block.py 's#R3_INLINE_GROUP_RE = re.compile(r"`?\\s\*#R3_INLINE_GROUP_RE = re.compile(r"(?!)`?\\s*#' "$FX/r3-inline-single.md" R3 INLINE-BAD
  if tooth_build I7 lint_block.py '/SENTINEL-R3-INLINE-BEGIN/,/SENTINEL-R3-INLINE-END/ s#or u.line in sv:#or False:#'; then
    mrun "$FX/r3-inline-selfverify.md"
    want="$(lines_of ROW-BAD "$FX/r3-inline-selfverify.md") $(lines_of INLINE-BAD "$FX/r3-inline-selfverify.md")"; got="$(reported R3 "$MOUT" "$FX/r3-inline-selfverify.md")"
    [ "$got" != "$want" ] && ok "teeth I7: Self-verify exclusion dropped from the inline pass -> rows reported twice / prose swept in [$got] -> case 17d has teeth" || no "teeth I7: mutant still reports exactly [$want] — THEATER"
  fi
  if tooth_build I8 lint_block.py 's#doc.cov\["cert_inline_items"\] += 1#doc.cov["cert_inline_items"] += 0#'; then
    mrun "$FX/r3-inline-fenced.md"
    grep -qE 'cert-inline-items=1( |$)' <<< "$MOUT" && no "teeth I8: counter mutant still reports 1 — THEATER" || ok "teeth I8: inline counter neutered -> summary no longer proves groups were inspected -> case 17e has teeth"
  fi
  tooth_set S1 lint_block.py '/^R3_INLINE_GROUP_RE/ s#\[:—–-\]?##' "$FX/r3-inline-sep.md" R3 SEP-BAD
  tooth_set S2 lint_block.py '/^R3_INLINE_GROUP_RE/ s#\[:—–-\]#[:–-]#' "$FX/r3-inline-sep.md" R3 SEP-BAD
  tooth_set S3 lint_block.py '/^R3_INLINE_GROUP_RE/ s#\[:—–-\]#[—–-]#' "$FX/r3-inline-sep.md" R3 SEP-BAD
  tooth_set S4 lint_block.py '/^R3_INLINE_GROUP_RE/ s#\[:—–-\]#[:—–]#' "$FX/r3-inline-sep.md" R3 SEP-BAD
  tooth_set S5 lint_block.py '/^R3_INLINE_GROUP_RE/ s#\[:—–-\]#[:—–,;-]#' "$FX/r3-inline-sep.md" R3 SEP-BAD
  tooth_set S6 lint_block.py '/^R3_INLINE_GROUP_RE/ s#\[:—–-\]?#[:—–-]*#' "$FX/r3-inline-sep.md" R3 SEP-BAD
  tooth_set C1 lint_block.py '/^R3_INLINE_GROUP_RE/ s#{0,400}#{0,399}#' "$FX/r3-inline-cap.md" R3 CAP-BAD
  tooth_set C2 lint_block.py '/^R3_INLINE_GROUP_RE/ s#{0,400}#{0,4000}#' "$FX/r3-inline-cap.md" R3 CAP-BAD
  tooth_set C3 lint_block.py '/^R3_INLINE_GROUP_RE/ s#{0,400}#*#' "$FX/r3-inline-cap.md" R3 CAP-BAD
  # T: wrapper — EMPTY-INPUT for a block-less directory removed
  if tooth_build T lint-block.sh 's#echo "EMPTY-INPUT: \$p has no canonical block files"#true#'; then
    mrun --audit "$FX/corpus-empty"
    grep -qF 'has no canonical block files' <<< "$MOUT" && no "teeth T: mutant still reports EMPTY-INPUT — THEATER" || ok "teeth T: empty-corpus signal removed -> case 10b has teeth"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
