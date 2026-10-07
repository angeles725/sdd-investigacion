#!/usr/bin/env bash
# focus-prefix-range.test.sh — FOCUSES.md block-scope cell grammar: `B<a>–B<b>` RANGE (kit #906).
#
# lib/focus-prefix.sh derive_focus_range reads a numeric block range from the un-suffixed root row's FOCUSES.md cell
# (en dash or hyphen), returned DISTINCTLY from a prefix; block_range_filter keeps the canonical block files whose number
# lies in it; research-sdd-status.sh (--sync-state + display) and verify-state.sh (CHECK A) count covered_blocks through
# that one helper. Doctrine: METHODOLOGY §16 "Block-scope cell grammar".
# Usage: focus-prefix-range.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$HERE/.."
LIB="$TB/lib/focus-prefix.sh"; BF="$TB/lib/block-files.sh"; VS="$TB/verify-state.sh"; ST="$TB/research-sdd-status.sh"
[ -f "$LIB" ] && [ -f "$BF" ] && [ -f "$VS" ] && [ -f "$ST" ] || { echo "FATAL: SUT not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== focus-prefix-range.test.sh =="
# shellcheck source=lib/focus-prefix.sh
. "$LIB"
# shellcheck source=lib/block-files.sh
. "$BF"
if ! declare -F derive_focus_range >/dev/null 2>&1 || ! declare -F block_range_filter >/dev/null 2>&1; then
  no "lib/focus-prefix.sh does not define derive_focus_range / block_range_filter"; echo "== $pass passed · $fail failed =="; exit 1
fi

# focuses DIR ROW... — DIR/FOCUSES.md (niagara layout: 5 data cells, the block cell last) with the given raw rows
focuses() { local d="$1"; shift; mkdir -p "$d"
  { echo '# Focus index'; echo; echo '| Focus | Estado | RESEARCH-STATE | Ámbito | Bloques |'; echo '|---|---|---|---|---|'
    local r; for r in "$@"; do echo "$r"; done; } > "$d/FOCUSES.md"; : > "$d/RESEARCH-STATE.md"; }
RT='`RESEARCH-STATE.md`'
fr() { derive_focus_range "$1/RESEARCH-STATE.md"; }

# --- 1. derive_focus_range: forms ---------------------------------------------------------------------------------
focuses "$TMP/f1" "| (base) | stopped | $RT | Framework base | B1–B130 |"
[ "$(fr "$TMP/f1")" = "1-130" ] && ok "1a en-dash range B1–B130 -> 1-130" || no "1a got '$(fr "$TMP/f1")'"
focuses "$TMP/f2" "| (base) | stopped | $RT | Framework base | B2-B9 |"
[ "$(fr "$TMP/f2")" = "2-9" ] && ok "1b ASCII-hyphen range B2-B9 -> 2-9" || no "1b got '$(fr "$TMP/f2")'"
focuses "$TMP/f3" "| (base) | stopped | $RT | Framework base | \`B3–B3\` |"
[ "$(fr "$TMP/f3")" = "3-3" ] && ok "1c single-block range, backticked -> 3-3 (a == b is legal)" || no "1c got '$(fr "$TMP/f3")'"
focuses "$TMP/f4" "| (base) | stopped | $RT | Framework base | **B4–B8** |"
[ "$(fr "$TMP/f4")" = "4-8" ] && ok "1d bold-decorated range -> 4-8" || no "1d got '$(fr "$TMP/f4")'"
# 2. row position: first / middle / last / only
focuses "$TMP/p1" "| (base) | stopped | $RT | x | B1–B5 |" "| other | active | \`RESEARCH-STATE-o.md\` | y | o- |" "| third | active | \`RESEARCH-STATE-t.md\` | y | t- |"
[ "$(fr "$TMP/p1")" = "1-5" ] && ok "2a range row FIRST" || no "2a got '$(fr "$TMP/p1")'"
focuses "$TMP/p2" "| other | active | \`RESEARCH-STATE-o.md\` | y | o- |" "| (base) | stopped | $RT | x | B1–B5 |" "| third | active | \`RESEARCH-STATE-t.md\` | y | t- |"
[ "$(fr "$TMP/p2")" = "1-5" ] && ok "2b range row MIDDLE" || no "2b got '$(fr "$TMP/p2")'"
focuses "$TMP/p3" "| other | active | \`RESEARCH-STATE-o.md\` | y | o- |" "| (base) | stopped | $RT | x | B1–B5 |"
[ "$(fr "$TMP/p3")" = "1-5" ] && ok "2c range row LAST" || no "2c got '$(fr "$TMP/p3")'"
# 3. a range-shaped cell on ANOTHER row never scopes the root
focuses "$TMP/o1" "| other | active | \`RESEARCH-STATE-o.md\` | y | B1–B5 |" "| (base) | stopped | $RT | x | free text |"
[ -z "$(fr "$TMP/o1")" ] && ok "3 a range on another row is not the root's" || no "3 got '$(fr "$TMP/o1")'"
# 4. distinct from a prefix: a range scopes NO prefix; a prefix scopes NO range; prefix wins on a shared row
[ -z "$(derive_focus_prefix "$TMP/f1/RESEARCH-STATE.md")" ] && ok "4a derive_focus_prefix returns empty for a range cell" || no "4a prefix='$(derive_focus_prefix "$TMP/f1/RESEARCH-STATE.md")'"
mkdir -p "$TMP/x2"; { echo '| Focus | Status | State | Block prefix |'; echo '|---|---|---|---|'; echo "| (base) | stopped | $RT | base- |"; } > "$TMP/x2/FOCUSES.md"; : > "$TMP/x2/RESEARCH-STATE.md"
[ "$(derive_focus_prefix "$TMP/x2/RESEARCH-STATE.md")" = "base-" ] && [ -z "$(fr "$TMP/x2")" ] && ok "4b a prefix cell is a prefix and no range (4-col layout)" || no "4b prefix='$(derive_focus_prefix "$TMP/x2/RESEARCH-STATE.md")' range='$(fr "$TMP/x2")'"
focuses "$TMP/x3" "| (base) | stopped | $RT | base- | B1–B9 |"
[ "$(derive_focus_prefix "$TMP/x3/RESEARCH-STATE.md")" = "base-" ] && ok "4c prefix and range on one row: the prefix is still returned (callers prefer it)" || no "4c prefix='$(derive_focus_prefix "$TMP/x3/RESEARCH-STATE.md")'"
# 5. the typed MALFORMED state is distinct from absent: a > b, and unreadable range-shaped cells
focuses "$TMP/m1" "| (base) | stopped | $RT | x | B9–B3 |"
case "$(fr "$TMP/m1")" in '!'*) ok "5a B9–B3 (a > b) -> typed malformed '$(fr "$TMP/m1")'" ;; *) no "5a got '$(fr "$TMP/m1")'" ;; esac
# 6. absent / no scope: no FOCUSES.md, no root row, a non-root state file, free text
mkdir -p "$TMP/n1"; : > "$TMP/n1/RESEARCH-STATE.md"
[ -z "$(fr "$TMP/n1")" ] && ok "6a no FOCUSES.md -> empty" || no "6a got '$(fr "$TMP/n1")'"
focuses "$TMP/n2" "| other | active | \`RESEARCH-STATE-o.md\` | y | o- |"
[ -z "$(fr "$TMP/n2")" ] && ok "6b no root row -> empty" || no "6b got '$(fr "$TMP/n2")'"
focuses "$TMP/n3" "| (base) | stopped | $RT | x | B1–B130 |"; : > "$TMP/n3/RESEARCH-STATE-o.md"
[ -z "$(derive_focus_range "$TMP/n3/RESEARCH-STATE-o.md")" ] && ok "6c a RESEARCH-STATE-<focus>.md never reads a range (its prefix comes from its filename)" || no "6c got a range for a suffixed state file"
focuses "$TMP/n4" "| (base) | stopped | $RT | x | B1–B130 extra words |"
[ -z "$(fr "$TMP/n4")" ] && ok "6d a range with trailing words is not range-shaped -> empty" || no "6d got '$(fr "$TMP/n4")'"

# --- 7. block_range_filter: edges ----------------------------------------------------------------------------------
paths=$'/c/x-bloque1.md\n/c/x-bloque2.md\n/c/x-bloque3.md\n/c/x-block4.md\n/c/x-bloque5-suffix.md\n/c/x-bloque10.md'
cnt() { printf '%s\n' "$paths" | block_range_filter "$1" "$2" | wc -l | tr -d ' '; }
[ "$(cnt 2 4)" = 3 ] && ok "7a [2,4] keeps 2,3,4 (both bounds inclusive; block/bloque, mid edge)" || no "7a got $(cnt 2 4)"
[ "$(cnt 1 1)" = 1 ] && ok "7b [1,1] first element only" || no "7b got $(cnt 1 1)"
[ "$(cnt 10 10)" = 1 ] && ok "7c [10,10] last element, two digits (10 is not 1)" || no "7c got $(cnt 10 10)"
[ "$(cnt 5 5)" = 1 ] && ok "7d a -suffix block file is read by its number" || no "7d got $(cnt 5 5)"
[ "$(cnt 6 9)" = 0 ] && ok "7e empty range hit -> 0" || no "7e got $(cnt 6 9)"
[ "$(cnt 0 99)" = 6 ] && ok "7f a wide range keeps every canonical block file" || no "7f got $(cnt 0 99)"
[ "$(printf '%s\n' "$paths" | block_range_filter -n 2 4 | tr '\n' ' ')" = "2 3 4 " ] && ok "7g -n prints the block numbers" || no "7g got '$(printf '%s\n' "$paths" | block_range_filter -n 2 4 | tr '\n' ' ')'"
mkdir -p "$TMP/dup"; : > "$TMP/dup/a-bloque2.md"; : > "$TMP/dup/b-block2.md"; : > "$TMP/dup/a-bloque3.md"; : > "$TMP/dup/a-bloque9.md"
[ "$(focus_range_block_count "$TMP/dup" 2-4)" = 2 ] && ok "7h two families sharing B2 count once (distinct ids: 2,3 -> 2)" || no "7h got $(focus_range_block_count "$TMP/dup" 2-4)"

# --- 8. integration: status --sync-state and verify-state count the range ---------------------------------------------
mkcorpus() { local d="$1" cb="$2"; mkdir -p "$d"
  { echo '# Focus index'; echo; echo '| Focus | Estado | RESEARCH-STATE | Ámbito | Bloques |'; echo '|---|---|---|---|---|'
    echo "| (base) | stopped | $RT | base | B2–B4 |"
    echo '| ops | active | `RESEARCH-STATE-ops.md` | ops | ops- |'; } > "$d/FOCUSES.md"
  local f; for f in 1 2 3 4 5 6; do : > "$d/x-bloque$f.md"; done; : > "$d/ops-block1.md"; : > "$d/y-block2.md"  # y-block2 shares id B2 with x-bloque2
  local s; for s in RESEARCH-STATE.md RESEARCH-STATE-ops.md; do  local v="$cb"; [ "$s" = RESEARCH-STATE-ops.md ] && v=1
    { echo "# T — Research State"; echo
      printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: %s\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n<!-- /research-state.v1 -->\n\n' "$v"
      echo "## Gap-backlog (prioritized)"; echo; echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"; echo
      echo "## Stop control"; echo; } > "$d/$s"
  done; }
env_val(){ sed -n "s/^$2: \([0-9][0-9]*\)\$/\1/p" "$1" | head -1; }
d="$TMP/c1"; mkcorpus "$d" 0
o="$(bash "$ST" "$d" --sync-state --root 2>&1)"
[ "$(env_val "$d/RESEARCH-STATE.md" covered_blocks)" = 3 ] && ok "8a --sync-state --root writes covered_blocks=3 (distinct ids 2..4; y-block2 shares B2 with x-bloque2)" || no "8a covered_blocks=$(env_val "$d/RESEARCH-STATE.md" covered_blocks): $o"
grep -q 'CORPUS-WIDE' <<<"$o" && no "8b the corpus-wide WARN still fires for a range-scoped root: $o" || ok "8b no corpus-wide WARN for a range-scoped root"
d="$TMP/c2"; mkcorpus "$d" 3
o="$(bash "$VS" "$d" 2>/dev/null)"
grep -qE 'FAIL +envelope covered_blocks=3 != ' <<<"$o" && no "8c verify-state FAILs a correct range-scoped covered_blocks=3: $(grep 'covered_blocks=3 !=' <<<"$o" | head -1)" || ok "8c verify-state accepts covered_blocks=3 for the range"
d="$TMP/c3"; mkcorpus "$d" 7
o="$(bash "$VS" "$d" 2>/dev/null)"
grep -qE 'FAIL +envelope covered_blocks=7 != 3 block file' <<<"$o" && ok "8d verify-state FAILs the corpus-wide 7 (range says 3)" || no "8d the stale corpus-wide count was not caught: $(grep 'covered_blocks' <<<"$o" | head -2)"
d="$TMP/c4"; mkcorpus "$d" 0
o="$(bash "$ST" "$d" --root 2>&1)"
grep -q '3 on disk' <<<"$o" && ok "8e the status display counts 3 on disk for the root" || no "8e display: $(grep 'covered blocks' <<<"$o")"
# 8f. malformed range: scopes nothing and says so (never a silent corpus-wide count)
d="$TMP/c5"; mkcorpus "$d" 7; sed -i 's/B2–B4/B9–B3/' "$d/FOCUSES.md"
o="$(bash "$VS" "$d" 2>/dev/null)"
grep -q 'B9–B3' <<<"$o" && ok "8f verify-state names the unreadable range cell" || no "8f malformed range not reported: $(grep -i focuses <<<"$o" | head -2)"
o="$(bash "$ST" "$d" --sync-state --root 2>&1)"
grep -q 'B9–B3' <<<"$o" && ok "8g --sync-state names the unreadable range cell" || no "8g malformed range not reported: $o"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  # lib_tooth NAME SEDEXPR WANT_ASSERT_DESC CHECK... — mutate the lib, source it fresh in a subshell, run one probe
  lib_tooth() {
    local name="$1" expr="$2" probe="$3" want="$4" t got
    t="$(mk_tree "$name")"
    if ! mutant_sed "$LIB" "$t/lib/focus-prefix.sh" "$expr" >/dev/null 2>&1; then no "teeth $name: mutant unbuildable"; return; fi
    got="$(bash -c ". '$t/lib/focus-prefix.sh'; . '$BF'; $probe" 2>&1)"
    if [ "$got" = "$want" ]; then ok "teeth $name: mutant yields the wrong '$got'"; else no "teeth $name: got '$got' (want mutant '$want') — THEATER"; fi
  }
  P_RANGE="derive_focus_range '$TMP/f1/RESEARCH-STATE.md'"
  P_FILT="printf '%s\n' '/c/x-bloque1.md' '/c/x-bloque2.md' '/c/x-bloque3.md' '/c/x-bloque4.md' | block_range_filter 2 3 | wc -l | tr -d ' '"
  lib_tooth E '/RANGE-ENDASH/ s/–/~/' "$P_RANGE" '!B1–B130'
  lib_tooth L '/RANGE-LO-BOUND/ s/>=/>/' "$P_FILT" 1
  lib_tooth D '/RANGE-DISTINCT/ s/sort -un/sort/' "focus_range_block_count '$TMP/dup' 2-4" 3
  lib_tooth H '/RANGE-HI-BOUND/ s/<=/</' "$P_FILT" 1
  lib_tooth M '/RANGE-MALFORMED/ s/"!"/""/' "derive_focus_range '$TMP/m1/RESEARCH-STATE.md'" 'B9–B3'
  lib_tooth R '/RANGE-ROOT-ONLY/ s/RESEARCH-STATE.md/RESEARCH-STATE-o.md/' "$P_RANGE" ""
  # site_tooth NAME FILE SEDEXPR MODE(sync|display|verify) CB MALFORMED(0|1) PATTERN — the mutated TOOL must print PATTERN
  # (the wrong behaviour); each pattern is also what the unmutated tool does NOT print on the same fixture (asserted above).
  site_tooth() {
    local name="$1" file="$2" expr="$3" mode="$4" cb="$5" mal="$6" pat="$7" t d o
    t="$(mk_tree "$name")"; d="$MT/fx-$name"; rm -rf "$d"; mkcorpus "$d" "$cb"
    [ "$mal" = 1 ] && sed -i 's/B2–B4/B9–B3/' "$d/FOCUSES.md"
    if ! mutant_sed "$TB/$file" "$t/$file" "$expr" >/dev/null 2>&1; then no "teeth $name: mutant unbuildable"; return; fi
    case "$mode" in
      sync) o="$(bash "$t/research-sdd-status.sh" "$d" --sync-state --root 2>&1)"; o="$o $(env_val "$d/RESEARCH-STATE.md" covered_blocks)" ;;
      display) o="$(bash "$t/research-sdd-status.sh" "$d" --root 2>&1)" ;;
      verify) o="$(bash "$t/verify-state.sh" "$d" 2>/dev/null)" ;;
    esac
    if [ "${pat#ABSENT:}" != "$pat" ]; then
      if grep -qF -- "${pat#ABSENT:}" <<<"$o"; then no "teeth $name: '${pat#ABSENT:}' still shown — THEATER"; else ok "teeth $name: mutant no longer shows '${pat#ABSENT:}'"; fi
    elif grep -qF -- "$pat" <<<"$o"; then ok "teeth $name: mutant shows the wrong '$pat'"; else no "teeth $name: '$pat' not shown — THEATER: $(head -c 200 <<<"$o")"; fi
  }
  site_tooth SY research-sdd-status.sh '/RANGE-SYNC-COUNT/ s/cb=.*/cb=99/' sync 0 0 ' 99'
  site_tooth DI research-sdd-status.sh '/RANGE-DISPLAY-COUNT/ s/ondisk=.*/ondisk=99/' display 0 0 '99 on disk'
  site_tooth VE verify-state.sh '/RANGE-VERIFY-COUNT/ s/ondisk=.*/ondisk=99/' verify 3 0 'covered_blocks=3 != 99'
  site_tooth WS research-sdd-status.sh '/RANGE-MALFORMED-WARN/ s/ >&2; _sfrange/ >\/dev\/null; _sfrange/' sync 0 1 'ABSENT:B9–B3'
  site_tooth WV verify-state.sh '/RANGE-MALFORMED-WARN/ s/echo "   WARN   FOCUSES.md/: "   WARN   FOCUSES.md/' verify 7 1 'ABSENT:B9–B3'
fi
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
