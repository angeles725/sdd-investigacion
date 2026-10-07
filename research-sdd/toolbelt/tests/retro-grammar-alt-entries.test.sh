#!/usr/bin/env bash
# retro-grammar-alt-entries.test.sh — lib/retro-grammar.sh retro_grammar_alt_entry_rows: the record shape
# (id, change, target, evidence, type, priority) of the three fleet forms the seeder could not classify, with
# the first / middle / last / single item pinned, and the shapes that must yield NOTHING (kit issues #1895
# #1932 #1933 #1934 #1938 #1939). The seeder-level behaviour is in stage-retro-issues-delta-forms.test.sh.
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

# rows <lib> <fixture>: the records, \037 shown as | so the assertions read.
# shellcheck disable=SC1090  # the lib under test (or its mutant) is chosen at run time
rows() { ( . "$1"; retro_grammar_alt_entry_rows "$FIX/$2" ) | tr '\037' '|'; }
nth() { sed -n "${1}p" <<<"$2"; }

c_numbered() {
  local o; o="$(rows "$1" numbered-prose.md)"
  [ "$(wc -l <<<"$o")" = 3 ] \
    && [[ "$(nth 1 "$o")" == "1|Saturation → pivot to application, and the honest checkpoint is a valid loop output|METHODOLOGY §8 (stopping) note|"* ]] \
    && [[ "$(nth 2 "$o")" == "2|"* ]] && [[ "$(nth 3 "$o")" == "3|Decompiler-obfuscation is a WALL, not evidence|§6/§21|"*"||" ]] && return 0
  echo "$o"; return 1
}
c_single() {
  local o; o="$(rows "$1" numbered-single.md)"
  [[ "$o" == "1|A single numbered proposal is still a delta item||"*"||" ]] && [ "$(wc -l <<<"$o")" = 1 ] && return 0
  echo "$o"; return 1
}
c_h2() {
  local o; o="$(rows "$1" h2-delta.md)"
  [ "$(wc -l <<<"$o")" = 3 ] \
    && [ "$(nth 1 "$o")" = "A|Structure-only binary inspection recipe for secret-bearing artifacts||||HIGH" ] \
    && [ "$(nth 2 "$o")" = "B|Inline-over-delegate override for secrets-sensitive artifacts||||MEDIUM" ] \
    && [ "$(nth 3 "$o")" = "C|Extend the REFUTE vs CLARIFY-SCOPE rule to threat-model scoping||||LOW" ] && return 0
  echo "$o"; return 1
}
c_h3() {
  local o; o="$(rows "$1" h3-proposals.md)"
  [ "$(wc -l <<<"$o")" = 3 ] && [[ "$(nth 1 "$o")" == "1|Retro-debt counter in the loop state|"* ]] \
    && [[ "$(nth 3 "$o")" == "3|Cadence hook|"* ]] && return 0
  echo "$o"; return 1
}
c_none() {   # shapes that must yield nothing: a lessons bullet list, a numbered Evidence list, a table-only retro
  local f o
  for f in lessons-bullets.md evidence-only.md lettered-table.md; do
    o="$(rows "$1" "$f")"
    [ -z "$o" ] || { echo "$f -> $o"; return 1; }
  done
  return 0
}
# shellcheck disable=SC1090
c_absent() { ( . "$1"; retro_grammar_alt_entry_rows "$ROOT/does-not-exist.md" >/dev/null 2>&1 ); [ $? = 1 ]; }

CHECKS="c_numbered c_single c_h2 c_h3 c_none c_absent"
for c in $CHECKS; do
  if why="$($c "$LIB")"; then ok "$c" "()"; else no "$c" "$why"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant must turn its check RED --"
  tooth() {
    local chk="$1" label="$2" m="$ROOT/mut-$2.sh" why
    shift 2
    if ! mutant_chain "mut-$label" "$LIB" "$m" "$@" >"$ROOT/mutant.log" 2>&1; then no "teeth $label: mutant unbuildable" "$(cat "$ROOT/mutant.log")"; return; fi
    if why="$($chk "$m" 2>&1)"; then no "teeth $label: $chk must fail against the mutant" "check is THEATER"
    else ok "teeth $label: mutant breaks $chk" "()"; fi
  }
  tooth c_numbered gate-open   '/ALT_NUMBERED_GATE/s/.*/      1 {/'
  tooth c_numbered item-off    '/ALT_NUMBERED_ITEM/s/if (match(/if (0 \&\& match(/'
  tooth c_h2       h2-off      '/ALT_H2_DELTA/s/.*/        if (0) {/'
  tooth c_h2       med-raw     '/ALT_PRIORITY_MED/s/.*/                  if (0) pr = "MEDIUM"/'
  tooth c_h3       h3-off      '/ALT_H3_PROPOSALS/s/.*/        if (0) mode="h3"/'
  tooth c_numbered title-keeps-dot 's/sub(\/\[.:\[:space:\]\]+\$\/, "", t)/t=t/'
  echo "-- prove-teeth done --"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
