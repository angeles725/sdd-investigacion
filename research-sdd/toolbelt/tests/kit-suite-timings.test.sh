#!/usr/bin/env bash
# kit-suite-timings.test.sh — suite for maint/kit-suite-timings.sh (kit issue #2230): median / p90 / max per suite over the
# history run-all.sh appends, and the three typed input states (absent / empty / no-match).
#
# The frozen fixture tests/fixtures/suite-timings/history.log (18 rows: suite a x4 = 10..40, b x1 = 5, c = one failing 100 s
# row + one 2 s row, d x10 = 1..10, one garbage line) is the oracle input; expected numbers are worked by hand:
#   a  median 25.0  p90 40.0 (nearest rank ceil(0.9*4)=4)  max 40.0  runs 4
#   d  median  5.5  p90  9.0 (rank 9)                      max 10.0  runs 10
#   b  median  5.0  runs 1          c  median 2.0 runs 1 (the rc=1 row is not counted)
#
# Usage: kit-suite-timings.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 SUT missing.
# KIT_SUITE_TIMINGS_SUT overrides the SUT (used to prove RED against an absent/older script).
set -uo pipefail
HERE="$(cd -P -- "$(dirname "$0")" && pwd -P)"
SUT="${KIT_SUITE_TIMINGS_SUT:-$HERE/../maint/kit-suite-timings.sh}"
FIX="$HERE/fixtures/suite-timings/history.log"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
[ -f "$FIX" ] || { echo "FATAL: fixture not found: $FIX" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_sed || exit 2
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
MID='·'
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
OUT=""; RC=0
go() { local sut="$1"; shift; OUT="$(bash "$sut" "$@" 2>&1)"; RC=$?; }
row() { grep -E "  $1\$" <<<"$OUT"; }              # the report line of a suite (path suffix)
cols() { awk '{ print $1, $2, $3, $4 }' <<<"$1"; }   # median runs p90 max

# ---- 1: statistics --------------------------------------------------------------------------------------------------------
go "$SUT" --file "$FIX"
a="$(cols "$(row 'research-sdd/toolbelt/tests/a\.test\.sh')")"; d="$(cols "$(row 'research-sdd/toolbelt/tests/d\.test\.sh')")"
b="$(cols "$(row 'research-sdd/toolbelt/tests/b\.test\.sh')")"; c="$(cols "$(row 'research-sdd/install/tests/c\.test\.sh')")"
if [ "$RC" = 0 ] && [ "$a" = "25.0 4 40.0 40.0" ] && [ "$d" = "5.5 10 9.0 10.0" ] && [ "$b" = "5.0 1 5.0 5.0" ] && [ "$c" = "2.0 1 2.0 2.0" ]; then
  ok "stats: median/runs/p90/max of an even n, a 10-row n, a single row, and a suite whose failing row is not counted"
else no "stats wrong: rc=$RC a=[$a] d=[$d] b=[$b] c=[$c]"; fi
if grep -qF '— 18 row(s) read, 16 used' <<<"$OUT" && grep -qF '1 malformed skipped, 1 with rc != 0 not counted' <<<"$OUT"; then
  ok "accounting: rows read / used / malformed / failing are all reported (nothing silently dropped)"
else no "accounting line wrong: $(head -1 <<<"$OUT")"; fi
order="$(grep -E '  research-sdd/' <<<"$OUT" | awk '{ n = split($5, p, "/"); printf "%s ", p[n] }')"
[ "$order" = "a.test.sh d.test.sh b.test.sh c.test.sh " ] && ok "order: slowest median first" || no "order wrong: [$order]"

# ---- 2: filter and --top --------------------------------------------------------------------------------------------------
go "$SUT" --file "$FIX" --suite install/
if [ "$RC" = 0 ] && grep -qE '  research-sdd/install/tests/c\.test\.sh$' <<<"$OUT" && ! grep -qF 'a.test.sh' <<<"$OUT" && grep -qF "path contains 'install/'" <<<"$OUT"; then
  ok "--suite: only matching suites reported and the filter is named in the header"
else no "--suite wrong: rc=$RC [$OUT]"; fi
go "$SUT" --file "$FIX" --top 2
n="$(grep -cE '  research-sdd/' <<<"$OUT")"
[ "$RC" = 0 ] && [ "$n" = 2 ] && grep -qF 'a.test.sh' <<<"$OUT" && ok "--top 2: two lines, the slowest kept" || no "--top wrong: rc=$RC n=$n"

# ---- 3: the three states --------------------------------------------------------------------------------------------------
go "$SUT" --file "$TMP/nope.log"
{ [ "$RC" = 0 ] && grep -qF "ABSENT-INPUT — $TMP/nope.log not found" <<<"$OUT"; } && ok "absent: typed ABSENT-INPUT, exit 0" || no "absent wrong: rc=$RC [$OUT]"
: > "$TMP/empty.log"; go "$SUT" --file "$TMP/empty.log"
{ [ "$RC" = 0 ] && grep -qF 'EMPTY-INPUT' <<<"$OUT"; } && ok "empty: typed EMPTY-INPUT (distinct from absent), exit 0" || no "empty wrong: rc=$RC [$OUT]"
go "$SUT" --file "$FIX" --suite no-such-suite
{ [ "$RC" = 0 ] && grep -qF 'NO-MATCH — 18 row(s) read (1 malformed, 1 with rc != 0); none had rc 0 and a path containing '"'no-such-suite'" <<<"$OUT"; } \
  && ok "no-match: typed NO-MATCH with the row accounting (distinct from empty and absent)" || no "no-match wrong: rc=$RC [$OUT]"
printf '2026-10-01 aaa x.test.sh 9.0 1\n' > "$TMP/allfail.log"; go "$SUT" --file "$TMP/allfail.log"
{ [ "$RC" = 0 ] && grep -qF 'NO-MATCH' <<<"$OUT"; } && ok "no-match: a history of only failing runs is NO-MATCH, not a report of zeros" || no "all-failing wrong: rc=$RC [$OUT]"
go "$SUT" --file "$TMP"
{ [ "$RC" = 1 ] && grep -qF 'not a readable file' <<<"$OUT"; } && ok "unreadable: a directory as history exits 1 (operational failure)" || no "unreadable wrong: rc=$RC [$OUT]"

# ---- 4: default path and usage --------------------------------------------------------------------------------------------
mkdir -p "$TMP/state/research-sdd"; cp "$FIX" "$TMP/state/research-sdd/suite-timings.log"
OUT="$(XDG_STATE_HOME="$TMP/state" bash "$SUT" 2>&1)"; RC=$?
{ [ "$RC" = 0 ] && grep -qF "$TMP/state/research-sdd/suite-timings.log" <<<"$OUT" && grep -qF 'a.test.sh' <<<"$OUT"; } && ok "default: reads \${XDG_STATE_HOME}/research-sdd/suite-timings.log" || no "default path wrong: rc=$RC"
go "$SUT" --top 0; r1=$RC; go "$SUT" --bogus; r2=$RC; go "$SUT" --file; r3=$RC
{ [ "$r1" = 2 ] && [ "$r2" = 2 ] && [ "$r3" = 2 ]; } && ok "usage: bad --top, unknown flag and a missing value exit 2" || no "usage rcs: $r1 $r2 $r3"

# ---- teeth ----------------------------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: each mutant must turn its case red --"
  mut() { MUT=""; mkdir -p "$TMP/m-$1"; if mutant_sed "$SUT" "$TMP/m-$1/s.sh" "$2" 2>"$TMP/m-$1/err"; then MUT="$TMP/m-$1/s.sh"; else no "teeth-$1: no mutant: $(cat "$TMP/m-$1/err")"; fi; }
  mut median 's|(v\[s, c / 2\] + v\[s, c / 2 + 1\]) / 2|v[s, c / 2]|'
  if [ -n "$MUT" ]; then go "$MUT" --file "$FIX"; a="$(cols "$(row 'research-sdd/toolbelt/tests/a\.test\.sh')")"
    [ "$a" != "25.0 4 40.0 40.0" ] && ok "teeth-median: the lower-middle value for an even n changes a's median -> the stats case bites" || no "teeth-median: unchanged (THEATER)"; fi
  mut rank 's|if (r < 0.9 \* c) r++;||'
  if [ -n "$MUT" ]; then go "$MUT" --file "$FIX"; a="$(cols "$(row 'research-sdd/toolbelt/tests/a\.test\.sh')")"
    [ "$a" != "25.0 4 40.0 40.0" ] && ok "teeth-rank: a floored nearest rank changes the p90 of the 4-row suite a -> the stats case bites" || no "teeth-rank: unchanged (THEATER)"; fi
  mut rc0 's|  \$5 != 0 { failing++; next }||'
  if [ -n "$MUT" ]; then go "$MUT" --file "$FIX"; c="$(cols "$(row 'research-sdd/install/tests/c\.test\.sh')")"
    [ "$c" != "2.0 1 2.0 2.0" ] && ok "teeth-rc0: counting a failing run changes c's numbers -> the rc filter bites" || no "teeth-rc0: unchanged (THEATER)"; fi
  mut order 's|sort -k2,2nr -k6,6|sort -k6,6|'
  if [ -n "$MUT" ]; then go "$MUT" --file "$FIX"; order="$(grep -E '  research-sdd/' <<<"$OUT" | awk '{ n = split($5, p, "/"); printf "%s ", p[n] }')"
    [ "$order" != "a.test.sh d.test.sh b.test.sh c.test.sh " ] && ok "teeth-order: sorting by name changes the order -> the order case bites" || no "teeth-order: unchanged (THEATER)"; fi
  mut state 's|^if \[ ! -s "\$file" \]; then$|if false; then|'
  if [ -n "$MUT" ]; then go "$MUT" --file "$TMP/empty.log"
    grep -qF 'EMPTY-INPUT' <<<"$OUT" && no "teeth-state: EMPTY-INPUT still reported (THEATER)" || ok "teeth-state: removing the empty-file branch loses the typed state -> the empty case bites"; fi
  mut bad 's|NF != 5 \|\| \$4 !~ /\^\[0-9\]+(\\\.\[0-9\]+)?\$/ \|\| \$5 !~ /\^\[0-9\]+\$/ { bad++; next }||'
  if [ -n "$MUT" ]; then go "$MUT" --file "$FIX"
    grep -qF '1 malformed skipped' <<<"$OUT" && no "teeth-bad: malformed still counted (THEATER)" || ok "teeth-bad: dropping row validation loses the malformed count -> the accounting case bites"; fi
fi

echo "== $pass passed $MID $fail failed =="
[ "$fail" -eq 0 ] || exit 1
