#!/usr/bin/env bash
# retro-grammar-alt-entries.test.sh — lib/retro-grammar.sh retro_grammar_alt_entry_rows (+ heads mode,
# retro_grammar_dup_ids, rg_delta_id / rg_table_id_skip): the record shape (id, change, target, evidence, type,
# priority) of the delta forms the seeder could not classify, with the first / middle / last / single item pinned,
# the title rules, and the shapes that must yield NOTHING (kit issues #1895 #1932 #1933 #1934 #1938 #1939).
# The seeder- and reconcile-level behaviour is in stage-retro-issues-delta-forms.test.sh and
# reconcile-issues-delta-forms.test.sh. Every tooth asserts the failure TEXT it must produce, not just "red".
#
# Usage: retro-grammar-alt-entries.test.sh                (run the suite)
#        retro-grammar-alt-entries.test.sh --prove-teeth  (run suite + mutation teeth)
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/retro-grammar.sh"
FIX="$HERE/fixtures/stage-retro-issues"
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB" >&2; exit 2; }
[ -d "$FIX" ] || { echo "FATAL: fixtures not found: $FIX" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-72s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-72s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
[ "${1:-}" = "--prove-teeth" ] && { . "$HERE/lib/mutant.sh"; }

# rows <lib> <fixture> [heads]: the output, \037 shown as | so the assertions read.
# shellcheck disable=SC1090  # the lib under test (or its mutant) is chosen at run time
rows() { ( . "$1"; retro_grammar_alt_entry_rows "$FIX/$2" ${3:+"$3"} ) | tr '\037' '|'; }
nth() { sed -n "${1}p" <<<"$2"; }
rep() { local i="$1" n="$2" s=""; while [ "$i" -gt 0 ]; do s="$s$n"; i=$((i-1)); done; printf '%s' "$s"; }

c_numbered() {
  local o; o="$(rows "$1" numbered-prose.md)"
  [ "$(wc -l <<<"$o")" = 3 ] \
    && [[ "$(nth 1 "$o")" == "1|Saturation → pivot to application, and the honest checkpoint is a valid loop output|METHODOLOGY §8 (stopping) note|"* ]] \
    && [[ "$(nth 2 "$o")" == "2|"* ]] && [[ "$(nth 3 "$o")" == "3|Decompiler-obfuscation is a WALL, not evidence|§6/§21|"*"||" ]] && return 0
  echo "numbered-prose -> $o"; return 1
}
c_single() {
  local o; o="$(rows "$1" numbered-single.md)"
  [[ "$o" == "1|A single numbered proposal is still a delta item||"*"||" ]] && [ "$(wc -l <<<"$o")" = 1 ] && return 0
  echo "numbered-single -> $o"; return 1
}
c_h2() {
  local o; o="$(rows "$1" h2-delta.md)"
  [ "$(wc -l <<<"$o")" = 3 ] \
    && [ "$(nth 1 "$o")" = "A|Structure-only binary inspection recipe for secret-bearing artifacts||||HIGH" ] \
    && [ "$(nth 2 "$o")" = "B|Inline-over-delegate override for secrets-sensitive artifacts||||MEDIUM" ] \
    && [ "$(nth 3 "$o")" = "C|Extend the REFUTE vs CLARIFY-SCOPE rule to threat-model scoping||||LOW" ] && return 0
  echo "h2-delta -> $o"; return 1
}
c_h3() {
  local o; o="$(rows "$1" h3-proposals.md)"
  [ "$(wc -l <<<"$o")" = 3 ] && [[ "$(nth 1 "$o")" == "1|Retro-debt counter in the loop state|"* ]] \
    && [[ "$(nth 3 "$o")" == "3|Cadence hook|"* ]] && return 0
  echo "h3-proposals -> $o"; return 1
}
c_none() {   # shapes that must yield nothing: a lessons bullet list, a numbered Evidence list, a table-only retro
  local f o
  for f in lessons-bullets.md evidence-only.md lettered-table.md header-hyphen.md; do
    o="$(rows "$1" "$f")"
    [ -z "$o" ] || { echo "$f -> $o"; return 1; }
  done
  return 0
}
c_absent() {
  # shellcheck disable=SC1090
  ( . "$1"; retro_grammar_alt_entry_rows "$ROOT/does-not-exist.md" >/dev/null 2>&1 ); [ $? = 1 ]
}
c_rejected_h3() {   # numbered lists under ### Considered and rejected / ### Evidence inside the delta section are not deltas
  local o; o="$(rows "$1" rejected-h3.md)"
  [ "$(wc -l <<<"$o")" = 2 ] && [[ "$(nth 1 "$o")" == "1|Adopt the real proposal one|"* ]] \
    && [[ "$(nth 2 "$o")" == "2|Adopt the real proposal two|"* ]] && return 0
  echo "rejected-h3 -> $o"; return 1
}
c_blank_flush() {   # a closing paragraph after a blank line is not part of the last item: its PROPOSED marker is not the target
  local o; o="$(rows "$1" trailing-paragraph.md)"
  [ "$(wc -l <<<"$o")" = 2 ] && [[ "$(nth 2 "$o")" == "2|Item without a target||Body text only.||" ]] && return 0
  echo "trailing-paragraph -> $o"; return 1
}
c_proposed_target() {
  local o; o="$(rows "$1" trailing-paragraph.md)"
  [[ "$(nth 1 "$o")" == "1|Item with a target|METHODOLOGY §3 markers|"* ]] && return 0
  echo "trailing-paragraph -> $o"; return 1
}
c_title_edges() {
  local o x98 b98 t2 t3
  o="$(rows "$1" title-edges.md)"
  x98="Unclosed bold $(rep 84 x)"; b98="$(rep 98 B)"
  [ "$(wc -l <<<"$o")" = 7 ] || { echo "count: $o"; return 1; }
  printf '%s\n' "$o" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || { echo "invalid UTF-8 in the records (a title cut split a character)"; return 1; }
  [[ "$(nth 1 "$o")" == "1|e.g. foo bar baz is the working title of a delta that has no sentence end at all||||" ]] || { echo "item1: $(nth 1 "$o")"; return 1; }
  t2="$(nth 2 "$o")"; t3="$(nth 3 "$o")"
  [[ "$t2" == "2|$x98||→ tail words after the arrow follow here||" ]] || { echo "item2 (unclosed bold, cap on a character boundary): $t2"; return 1; }
  [[ "$t3" == "3|$b98||→ more words after the arrow Second sentence stays in the evidence.||" ]] || { echo "item3 (over-100 first sentence keeps its remainder): $t3"; return 1; }
  [[ "$(nth 4 "$o")" == "4|Plain sentence one is short||The remainder of the line is the evidence of this item.||" ]] || { echo "item4: $(nth 4 "$o")"; return 1; }
  [[ "$(nth 5 "$o")" == "5|See e.g. The Rules document for background and other long reasons||||" ]] || { echo "item5 (abbreviation): $(nth 5 "$o")"; return 1; }
  [[ "$(nth 6 "$o")" == "6|use vim. then more steps follow in the same item||||" ]] || { echo "item6 (lowercase after the period): $(nth 6 "$o")"; return 1; }
  [[ "$(nth 7 "$o")" == "7|Bold title with colon||body text||" ]] || { echo "item7 (trailing colon stripped): $(nth 7 "$o")"; return 1; }
  return 0
}
c_heads() {
  local o
  o="$(rows "$1" mixed-prose-and-list.md heads)"
  [ "$o" = "### Proposals (propose-never-apply) — cheapest first" ] || { echo "mixed heads: $o"; return 1; }
  o="$(rows "$1" numbered-prose.md heads)"
  [ "$o" = "## Proposed kit deltas" ] || { echo "numbered heads: $o"; return 1; }
  o="$(rows "$1" lessons-bullets.md heads)"
  [ -z "$o" ] || { echo "lessons heads: $o"; return 1; }
  return 0
}
c_dups() {
  local o d
  o="$(rows "$1" dup-ids.md)"
  [ "$(wc -l <<<"$o")" = 4 ] || { echo "dup-ids rows: $o"; return 1; }
  # shellcheck disable=SC1090
  d="$( . "$1"; printf '1\n2\n1\n2\n3\n' | retro_grammar_dup_ids | tr '\n' ' ')"
  [ "$d" = "1 2 " ] || { echo "dup ids: [$d]"; return 1; }
  # shellcheck disable=SC1090
  d="$( . "$1"; printf '1\n2\n3\n' | retro_grammar_dup_ids | tr '\n' ' ')"
  [ -z "$d" ] || { echo "no dups expected: [$d]"; return 1; }
  return 0
}
c_id_rule() {   # ONE rule for table first cells and `## Delta <ID>` tokens
  local o
  # shellcheck disable=SC1090
  o="$( . "$1"; printf '%s\n' "$_RG_AWK_ID_FN" > "$ROOT/idfn.awk"; for t in A Z R1 SO2 D12 SPKI-A AB-1 ID DELTA TOTAL RATIONALE ITEM-IDX9 ABCDEFGHI lower a1 '#'; do
      printf '%s=' "$t"; awk -f "$ROOT/idfn.awk" -e 'BEGIN { printf "%d/%d\n", rg_delta_id("'"$t"'"), rg_table_id_skip("'"$t"'") }' 2>/dev/null || awk -f "$ROOT/idfn.awk" -f /dev/stdin <<<'BEGIN { printf "%d/%d\n", rg_delta_id("'"$t"'"), rg_table_id_skip("'"$t"'") }'; done | tr '\n' ' ')"
  [ "$o" = "A=1/0 Z=1/0 R1=1/0 SO2=1/0 D12=1/0 SPKI-A=1/0 AB-1=1/0 ID=0/1 DELTA=0/1 TOTAL=0/1 RATIONALE=0/1 ITEM-IDX9=0/0 ABCDEFGHI=0/1 lower=0/1 a1=0/0 #=0/1 " ] && return 0
  echo "[$o]"; return 1
}

# check <function> <lib>: runs one check, returns its rc and prints its failure text.
CHECKS="c_numbered c_single c_h2 c_h3 c_none c_absent c_rejected_h3 c_blank_flush c_proposed_target c_title_edges c_heads c_dups c_id_rule"
for c in $CHECKS; do
  if why="$($c "$LIB")"; then ok "$c" "()"; else no "$c" "$why"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant must turn its check RED, and the failure text must be the expected one --"
  # tooth <check> <label> <expected-failure-text> <sed-stage>...
  tooth() {
    local chk="$1" label="$2" want="$3" m="$ROOT/mut-$2.sh" why
    shift 3
    if ! mutant_chain "mut-$label" "$LIB" "$m" "$@" >"$ROOT/mutant.log" 2>&1; then no "teeth $label: mutant unbuildable" "$(cat "$ROOT/mutant.log")"; return; fi
    if why="$($chk "$m" 2>&1)"; then no "teeth $label: $chk must fail against the mutant" "check is THEATER"
    elif ! grep -qF -- "$want" <<<"$why"; then no "teeth $label: $chk failed for the WRONG reason" "wanted [$want] got [${why:0:300}]"
    else ok "teeth $label: mutant breaks $chk with [${want:0:40}]" "()"; fi
  }
  tooth c_none        gate-open       'evidence-only.md ->' '/ALT_NUMBERED_GATE/s/.*/      1 {/'
  tooth c_numbered    item-off        'numbered-prose ->' '/ALT_NUMBERED_ITEM/s/if (match(/if (0 \&\& match(/'
  tooth c_h2          h2-off          'h2-delta ->' '/ALT_H2_DELTA/s/.*/        if (0) {/'
  tooth c_h2          med-raw         '|MED' '/ALT_PRIORITY_MED/s/.*/                  if (0) pr = "MEDIUM"/'
  tooth c_h3          h3-off          'h3-proposals ->' '/ALT_H3_PROPOSALS/s/.*/        if (0) mode="h3"/'
  tooth c_rejected_h3 h3-reset-off    'rejected-h3 ->' '/ALT_H3_RESET/s/.*/        flush()/'
  tooth c_blank_flush blank-flush-off 'trailing-paragraph -> ' '/ALT_BLANK_FLUSH/s/.*/        blank = blank/'
  tooth c_proposed_target proposed-off 'trailing-paragraph -> ' '/ALT_PROPOSED_TARGET/s/.*/        if (0) {/'
  tooth c_title_edges title-strip-off 'item7 (trailing colon stripped)' '/ALT_TITLE_STRIP/s/.*/        t = t/'
  tooth c_title_edges abbrev-off      'item5 (abbreviation)' '/ALT_SENT_ABBREV/s/.*/          skip = skip/'
  tooth c_title_edges lowercase-off   'item6 (lowercase after the period)' '/ALT_SENT_LOWER/s/.*/          skip = skip/'
  tooth c_title_edges cut-splits-utf8 'invalid UTF-8' '/ALT_CUT_BACKOFF/s/.*/        k = k/'
  tooth c_title_edges no-cap          'item2 (unclosed bold, cap on a character boundary)' '/ALT_TITLE_CAP/s/.*/        if (0) { k = 0 }/'
  tooth c_heads       heads-all       'mixed heads:' '/ALT_HEADS_UNIQ/s/.*/          if (want == "heads") { print src }/'
  tooth c_dups        dup-off         'dup ids:' 's/retro_grammar_dup_ids() { sort | uniq -d; }/retro_grammar_dup_ids() { sort -u; }/'
  tooth c_id_rule     id-bare-word    'ID=1/0' 's/if (tok !~ \/\[0-9-\]\/ \&\& length(tok) > 1) return 0/if (0) return 0/'
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
