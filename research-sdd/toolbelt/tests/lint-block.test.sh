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
run --bogus "$FX/r3-first.md"; [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'unknown option' \
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
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'NO-MATCH' && printf '%s' "$OUT" | grep -qF 'cert-hw-live-items=5' \
   && printf '%s' "$OUT" | grep -qF 'selfverify-sections=1'; then
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
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'r6-trigger-clauses=2' && ok "6d R6 cleared by a cited raw path; both trigger clauses were counted (looked at)" || no "6d R6 clean (rc=$RC out=[$OUT])"
run "$FX/r6-split.md"
[ "$RC" -eq 0 ] && ok "6e R6: block ref and 'does not mention' in DIFFERENT clauses is not a finding" || no "6e R6 split (rc=$RC out=[$OUT])"

printf '# Block 19 — synthetic\n\nNote the flag ([Block 429]) is filtered out of the sheet \xe2\x80\x94 wire layout never shows as a property.\n\n[Block 5] is cited here as provenance for a long and unrelated explanation that goes on well past the allowed distance before this block never mentions anything.\n' > "$TMP/r6-dash.md"
run "$TMP/r6-dash.md"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'r6-trigger-clauses=0' && ok "6f R6: verdict separated from [Block N] by a dash / by >80 chars is NOT a comparison claim" || no "6f R6 dash/distance (rc=$RC out=[$OUT])"

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
[ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qE '^R0 .*waiver names no rule id' && ok "7c malformed waiver (no rule id) -> R0" || no "7c malformed (rc=$RC out=[$OUT])"
run "$FX/waiver-wrongrule.md"
[ "$RC" -eq 1 ] && [ "$(reported R3 "$OUT" "$FX/waiver-wrongrule.md")" = "$(lines_of ROW-BAD "$FX/waiver-wrongrule.md")" ] && ok "7d a waiver for a DIFFERENT rule does not waive R3" || no "7d wrong rule (rc=$RC out=[$OUT])"
run "$FX/waiver-adjacent.md"
[ "$RC" -eq 1 ] && [ "$(reported R3 "$OUT" "$FX/waiver-adjacent.md")" = "$(lines_of ROW-BAD "$FX/waiver-adjacent.md")" ] && ok "7e a waiver covers ONLY its own row; the neighbour row still fires" || no "7e adjacent (rc=$RC out=[$OUT])"

# 8. Typed states in FAIL mode
run "$FX/empty.md"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'EMPTY-INPUT' && printf '%s' "$OUT" | grep -qF 'empty=1' && ok "8a empty file -> EMPTY-INPUT (not NO-MATCH), exit 0" || no "8a empty (rc=$RC out=[$OUT])"
run "$FX/blank.md"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'EMPTY-INPUT' && ok "8b whitespace-only file -> EMPTY-INPUT" || no "8b blank (rc=$RC out=[$OUT])"
run "$FX/does-not-exist.md"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'ABSENT-INPUT' && ok "8c absent file -> ABSENT-INPUT, exit 2" || no "8c absent (rc=$RC out=[$OUT])"
run "$FX/does-not-exist.md" "$FX/r3-first.md"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'ABSENT-INPUT' && printf '%s' "$OUT" | grep -qE '^R3 .*r3-first.md' && ok "8d absent + good file: the good file is still linted, final exit stays 2" || no "8d absent+good (rc=$RC out=[$OUT])"
printf 'bad \377\376 bytes\n' > "$TMP/bad-utf8.md"
run "$TMP/bad-utf8.md" "$FX/r3-first.md"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'UNREADABLE' && printf '%s' "$OUT" | grep -qE '^R3 .*r3-first.md' && ok "8e undecodable file -> UNREADABLE, exit 2, other files still linted" || no "8e unreadable (rc=$RC out=[$OUT])"
run "$FX/corpus"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'is a directory' && ok "8f directory in FAIL mode -> exit 2 (corpora need --audit)" || no "8f dir in FAIL (rc=$RC out=[$OUT])"

# 9. Multi-file FAIL mode reports every file
run "$FX/r3-first.md" "$FX/r3-last.md" "$FX/r6-single.md"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qE '^R3 .*r3-first.md' && printf '%s' "$OUT" | grep -qE '^R3 .*r3-last.md' \
   && printf '%s' "$OUT" | grep -qE '^R6 .*r6-single.md' && printf '%s' "$OUT" | grep -qF 'files=3'; then
  ok "9 multi-file FAIL run reports every file's findings and files=3"
else no "9 multi-file (rc=$RC out=[$OUT])"; fi

# 10. --audit: report-only over a corpus directory
run --audit "$FX/corpus"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'SUMMARY AUDIT files=3 ' && printf '%s' "$OUT" | grep -qF 'R3=2' \
   && printf '%s' "$OUT" | grep -qF 'R6=1' && printf '%s' "$OUT" | grep -qF 'findings=3' \
   && ! printf '%s' "$OUT" | grep -qE '^R[036] .*notes.md' && printf '%s' "$OUT" | grep -qF 'UNCLASSIFIED: 1'; then
  ok "10a --audit corpus: exit 0 with findings, nested bloque file found, decoy notes.md never scanned but reported UNCLASSIFIED (files=3 R3=2 R6=1)"
else no "10a audit corpus (rc=$RC out=[$OUT])"; fi
run --audit "$FX/corpus-empty"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'has no canonical block files' && ! printf '%s' "$OUT" | grep -qF 'NO-MATCH' && ok "10b --audit dir with no block files -> EMPTY-INPUT (distinct from NO-MATCH), exit 0" || no "10b audit empty (rc=$RC out=[$OUT])"
run --audit "$FX/corpus-nomatch"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'NO-MATCH' && printf '%s' "$OUT" | grep -qF 'files=1 ' && ok "10c --audit clean corpus -> NO-MATCH with files=1 (looked, found nothing)" || no "10c audit nomatch (rc=$RC out=[$OUT])"
run --audit "$TMP/no-such-dir"
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'ABSENT-INPUT' && ok "10d --audit absent path -> ABSENT-INPUT, exit 2" || no "10d audit absent (rc=$RC out=[$OUT])"
run --audit "$FX/r3-first.md"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '^R3 ' && ok "10e --audit on a single file reports findings, still exit 0" || no "10e audit file (rc=$RC out=[$OUT])"
mkdir -p "$TMP/.claude/wt" "$TMP/pruned/node_modules/m" "$TMP/pruned/.claude"
cp -R "$FX/corpus" "$TMP/.claude/wt/corpus"
cp "$FX/corpus-nomatch/demo-block1.md" "$TMP/pruned/node_modules/m/vendored-block1.md"
cp "$FX/corpus-nomatch/demo-block1.md" "$TMP/pruned/.claude/hidden-block2.md"
cp "$FX/corpus-nomatch/demo-block1.md" "$TMP/pruned/real-block3.md"
run --audit "$TMP/.claude/wt/corpus"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'SUMMARY AUDIT files=3 ' \
  && ok "10g corpus living UNDER a .claude/ ancestor is still scanned (prune is by basename below the root)" || no "10g .claude ancestor (rc=$RC out=[$OUT])"
run --audit "$TMP/pruned"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'SUMMARY AUDIT files=1 ' \
  && ok "10h node_modules/ and .claude/ SUBTREES below the root are pruned (files=1)" || no "10h prune (rc=$RC out=[$OUT])"
run "$FX/corpus-nomatch/demo-block1.md"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'SUMMARY LINT' && ok "10f FAIL mode on a clean block -> exit 0, SUMMARY LINT" || no "10f fail clean (rc=$RC out=[$OUT])"

# 11. DEGRADED: no python3 on PATH -> exit 2, never a clean pass
mkdir -p "$TMP/nopy-bin"
for t in dirname mktemp rm cat find sort grep sed; do p="$(command -v "$t")" && ln -sf "$p" "$TMP/nopy-bin/$t"; done
OUT="$(PATH="$TMP/nopy-bin" "$BASH" "$SUT" "$FX/r3-first.md" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'DEGRADED' && ok "11 python3 absent -> DEGRADED, exit 2 (not a confident 0)" || no "11 degraded (rc=$RC out=[$OUT])"

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
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'cert-hw-live-items=5' && ok "14b path-shaped durable forms (dir/, 3 segments, dir+file:line, canonical block file, dir+ext) clear an ephemeral row" || no "14b durable forms (rc=$RC out=[$OUT])"
run "$FX/r3-hyphen.md"; want="$(lines_of ROW-BAD "$FX/r3-hyphen.md")"; got="$(reported R3 "$OUT" "$FX/r3-hyphen.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "14c U+2011 hyphen in 'Self-verify' and in the marker, lower-case [cert-hw] are recognised ($want)" || no "14c hyphen variants (rc=$RC want=[$want] got=[$got])"
run "$FX/r3-quoted.md"; want="$(lines_of ROW-BAD "$FX/r3-quoted.md")"; got="$(reported R3 "$OUT" "$FX/r3-quoted.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "14d Self-verify heading + table inside a blockquote are linted (dequoting)" || no "14d blockquote (rc=$RC want=[$want] got=[$got])"
run "$FX/r3-tilde.md"
[ "$RC" -eq 0 ] && ok "14e ~~~ fenced table is skipped" || no "14e tilde fence (rc=$RC out=[$OUT])"
run "$FX/r3-fence-mismatch.md"
[ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qF 'WARN' && ok "14f a ~~~ line does not close a \`\`\` fence (CommonMark); no spurious WARN" || no "14f fence mismatch (rc=$RC out=[$OUT])"
run "$FX/r3-unclosed.md"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '^WARN .*r3-unclosed.md:5: unclosed' && printf '%s' "$OUT" | grep -qF 'warn=1' && ok "14g unclosed fence -> WARN with its line (5) and warn=1 in SUMMARY, not a silent skip" || no "14g unclosed fence (rc=$RC out=[$OUT])"
run "$FX/r3-header.md"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'cert-hw-live-items=1' && ok "14h a table HEADER row carrying marker text is not inspected as an item (items=1)" || no "14h header row (rc=$RC out=[$OUT])"
run "$FX/r3-hashtag.md"; want="$(lines_of ROW-BAD "$FX/r3-hashtag.md")"; got="$(reported R3 "$OUT" "$FX/r3-hashtag.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "14i '#1 priority' is not a heading: the Self-verify section continues past it" || no "14i hashtag (rc=$RC want=[$want] got=[$got])"
run "$FX/waiver-fenced.md"
[ "$RC" -eq 0 ] && ok "14j waiver-shaped tokens inside a fence are not parsed (no R0)" || no "14j fenced waiver (rc=$RC out=[$OUT])"
run "$FX/waiver-alias.md"; want="$(lines_of ROW-BAD "$FX/waiver-alias.md")"
[ "$RC" -eq 1 ] && [ "$(reported R3 "$OUT" "$FX/waiver-alias.md")" = "$want" ] && [ "$(reported R0 "$OUT" "$FX/waiver-alias.md")" = "$want" ] \
  && ok "14k reference alias <!-- lint-ok: R3 reason --> waives with a reason; without one: R0 + R3 still fires" || no "14k alias (rc=$RC out=[$OUT])"
run "$FX/waiver-unknown.md"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qE '^R0 .*unknown rule R9' && printf '%s' "$OUT" | grep -qE '^R0 .*upper-case' \
   && [ "$(reported R3 "$OUT" "$FX/waiver-unknown.md")" = "$(lines_of LOW-BAD "$FX/waiver-unknown.md")" ]; then
  ok "14l waiver for an unknown rule id -> R0; lower-case id -> R0 'upper-case' and does not waive"
else no "14l unknown/lower waiver (rc=$RC out=[$OUT])"; fi
run "$FX/r6-verbs.md"; want="$(lines_of -BAD "$FX/r6-verbs.md")"; got="$(reported R6 "$OUT" "$FX/r6-verbs.md")"
[ "$RC" -eq 1 ] && [ "$got" = "$want" ] && ok "14m R6 verb forms: never mentioned / did not cite / never references / do not include / didn't show" || no "14m R6 verbs (rc=$RC want=[$want] got=[$got])"
mkdir -p "$TMP/nolib"; cp "$SUT" "$HELPER" "$TMP/nolib/"
OUT="$(bash "$TMP/nolib/lint-block.sh" "$FX/r3-first.md" 2>&1)"; RC=$?
[ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'block_file_filter' && ok "14n failed load of lib/block-files.sh -> exit 2 (never 1 = findings)" || no "14n lib load failure (rc=$RC out=[$OUT])"
run --audit "$FX/corpus-unclassified"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'UNCLASSIFIED: 2' && printf '%s' "$OUT" | grep -qF 'notes.md' && printf '%s' "$OUT" | grep -qF 'files=1 ' \
  && ok "14o --audit reports non-canonical .md files as UNCLASSIFIED: 2 (with paths), not silently dropped" || no "14o unclassified (rc=$RC out=[$OUT])"
run --audit "$FX/corpus-empty"
printf '%s' "$OUT" | grep -qF 'UNCLASSIFIED: 1' && printf '%s' "$OUT" | grep -qF 'has no canonical block files' && ok "14p block-less dir: EMPTY-INPUT plus UNCLASSIFIED: 1" || no "14p empty+unclassified (rc=$RC out=[$OUT])"
run "$FX/r3-prose.md"
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'cert-hw-live-items=1' && ok "14q prose paragraph that merely MENTIONS a marker and a /tmp path is not an item (only table rows / list items are); the real bullet is counted" || no "14q prose (rc=$RC out=[$OUT])"

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
  if tooth_build D lint_block.py 's#^    return bool(R3_EXT_RE.search(segs\[-1\])) or len(segs) >= 3#    return False#'; then
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
    printf '%s' "$MOUT" | grep -qF 'cert-hw-live-items=5' && no "teeth P: counter mutant still reports 5 — THEATER" \
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
    printf '%s' "$MOUT" | grep -qF 'notes.md' && ok "teeth R: filter dropped -> decoy notes.md SCANNED -> case 10a has teeth" || no "teeth R: decoy not scanned — THEATER :: out=[$MOUT]"
  fi
  # S: wrapper — python3 probe disabled -> no DEGRADED report
  if tooth_build S lint-block.sh 's#command -v python3 >/dev/null 2>&1#command -v dirname >/dev/null 2>\&1#'; then
    MOUT="$(PATH="$TMP/nopy-bin" "$BASH" "$MT/lint-block.sh" "$FX/r3-first.md" 2>&1)"; MRC=$?
    printf '%s' "$MOUT" | grep -qF 'DEGRADED' && no "teeth S: probe mutant still reports DEGRADED — THEATER" || ok "teeth S: python3 probe disabled -> no DEGRADED signal -> case 11 has teeth"
  fi
  # U: wrapper — prune by absolute-path substring again -> a corpus under a .claude/ ancestor vanishes
  if tooth_build U lint-block.sh 's#-o -name \.claude#-o -path "*/.claude/*"#'; then
    mrun --audit "$TMP/.claude/wt/corpus"
    printf '%s' "$MOUT" | grep -qF 'SUMMARY AUDIT files=3 ' && no "teeth U: substring prune mutant still scans the corpus — THEATER" || ok "teeth U: substring prune -> corpus under .claude/ silently skipped -> case 10g has teeth"
  fi
  # V: wrapper — node_modules no longer pruned
  if tooth_build V lint-block.sh 's#-name node_modules -o ##'; then
    mrun --audit "$TMP/pruned"
    printf '%s' "$MOUT" | grep -qF 'SUMMARY AUDIT files=1 ' && no "teeth V: node_modules mutant still reports files=1 — THEATER" || ok "teeth V: node_modules not pruned -> vendored block scanned -> case 10h has teeth"
  fi
  # ---- Review round 1 teeth ----
  # tooth_set NAME FILE SED FIXTURE RULE -> mutant must NOT report exactly the lines the suite
  # asserts for that fixture (tag ROW-BAD, or TAG given as 6th arg).
  tooth_set() {
    local name="$1" file="$2" expr="$3" fx="$4" rule="$5" tag="${6:-ROW-BAD}" want got
    tooth_build "$name" "$file" "$expr" || return 0
    mrun "$fx"
    want="$(lines_of "$tag" "$fx")"; got="$(reported "$rule" "$MOUT" "$fx")"
    if ! printf '%s' "$MOUT" | grep -qF 'SUMMARY'; then no "teeth $name: mutant crashed instead of linting (wrong-reason bite) :: out=[$MOUT]"
    elif [ "$got" != "$want" ]; then ok "teeth $name: mutant reports [$got] instead of [$want] -> the exact-set assertion has teeth"
    else no "teeth $name: mutant still reports the asserted set [$want] — THEATER"; fi
  }
  tooth_set V1 lint_block.py 's#if R3_BLOCKFILE_RE.search(tok):#if re.search(r"(?:block|bloque|B)[- ]?[0-9]+", tok, re.I):#' "$FX/r3-slashtokens.md" R3
  tooth_set V2 lint_block.py 's#or len(segs) >= 3$#or len(segs) >= 2#' "$FX/r3-slashtokens.md" R3
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
    printf '%s' "$MOUT" | grep -qF 'WARN' && no "teeth X2: mutant still warns — THEATER" || ok "teeth X2: unclosed-fence WARN removed -> hidden content is silent again -> case 14g has teeth"
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
  if tooth_build Z3 lint_block.py 's#^                if rule not in RULE_IDS:#                if False:#'; then
    mrun "$FX/waiver-unknown.md"
    printf '%s' "$MOUT" | grep -qE '^R0 .*unknown rule R9' && no "teeth Z3: mutant still reports the unknown rule — THEATER" || ok "teeth Z3: unknown-rule check removed -> R9 waiver accepted silently -> case 14l has teeth"
  fi
  tooth_set Z4 lint_block.py 's#^                if raw_id != rule:#                if False:#' "$FX/waiver-unknown.md" R3 LOW-BAD
  tooth_set Q1 lint_block.py 's#|cite|reference)#)#' "$FX/r6-verbs.md" R6 -BAD
  tooth_set Q2 lint_block.py 's#(?:s|ed|d)?\\b",#s?\\b",#' "$FX/r6-verbs.md" R6 -BAD
  if tooth_build B2 lint-block.sh '/failed to define block_file_filter/{n;s/exit 2/exit 1/}'; then
    rm -rf "$TMP/mt/B2/lib"
    mrun "$FX/r3-first.md"
    [ "$MRC" -eq 1 ] && ok "teeth B2: loader failure exits 1 (= findings) -> case 14n has teeth" || no "teeth B2: mutant exited $MRC — THEATER"
  fi
  if tooth_build U2 lint-block.sh 's#block_file_filter -v < "\$tmp/all" > "\$tmp/unclass"#: > "$tmp/unclass"#'; then
    mrun --audit "$FX/corpus-unclassified"
    printf '%s' "$MOUT" | grep -qF 'UNCLASSIFIED' && no "teeth U2: mutant still reports UNCLASSIFIED — THEATER" || ok "teeth U2: unclassified listing removed -> non-canonical files dropped silently -> case 14o has teeth"
  fi
  if tooth_build P2 lint_block.py 's#if u.kind not in ("row", "item") or u.line not in sv:#if u.kind not in ("row", "item", "para") or u.line not in sv:#'; then
    mrun "$FX/r3-prose.md"
    [ "$MRC" -eq 1 ] && ok "teeth P2: prose paragraphs inspected -> explanatory text FALSE-FLAGS (measured: niagara5 block26:359) -> case 14q has teeth" || no "teeth P2: mutant still clean (rc=$MRC) — THEATER"
  fi
  # T: wrapper — EMPTY-INPUT for a block-less directory removed
  if tooth_build T lint-block.sh 's#echo "EMPTY-INPUT: \$p has no canonical block files"#true#'; then
    mrun --audit "$FX/corpus-empty"
    printf '%s' "$MOUT" | grep -qF 'has no canonical block files' && no "teeth T: mutant still reports EMPTY-INPUT — THEATER" || ok "teeth T: empty-corpus signal removed -> case 10b has teeth"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
