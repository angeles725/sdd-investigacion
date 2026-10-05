#!/usr/bin/env bash
# research-sdd-status-retyped.test.sh — re-typed row left in the main Gap-backlog table (kit issue #1638).
#
# METHODOLOGY §8b: a re-typed gap leaves the main table in the same edit (it moves to the Blocked-gaps
# section). A row whose leading Status token is `re-typed`/`retyped` is uncounted BY DESIGN, but it must
# never be dropped silently (§7): research-sdd-status.sh and verify-state.sh both (a) classify it the same
# way, (b) emit an actionable `WARN: re-typed row ...` and (c) show a visible `re-typed in table : N` count.
# A parity block asserts both scripts agree on the count for the same rows (list edges: first/middle/last/
# single/none). No new blocked bucket for main-table rows: investigable_open is unchanged by these rows.
# Usage: research-sdd-status-retyped.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$HERE/.."
ST="$TB/research-sdd-status.sh"; VS="$TB/verify-state.sh"
[ -f "$ST" ] && [ -f "$VS" ] || { echo "FATAL: SUT not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== research-sdd-status-retyped.test.sh =="

# mkstate DIR INV ROW... — corpus whose declared investigable_open is INV, with the given raw table rows.
mkstate() {
  local d="$1" inv="$2"; shift 2; mkdir -p "$d"
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: %s\ninvestigable_open: %s\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n<!-- /research-state.v1 -->\n\n' "$((inv+$#))" "$inv"
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    local r; for r in "$@"; do echo "$r"; done
    echo; echo "## Stop control"; echo
    echo "- **Open gaps — read-only investigable**: $inv"
    echo "- **Open gaps — requires-execution**: 0"
    echo "- **Open gaps — blocked**: 0"
  } > "$d/RESEARCH-STATE.md"
}
SUT_ST="$ST"; SUT_VS="$VS"
st_out(){ bash "$SUT_ST" "$1" 2>&1; }
vs_out(){ bash "$SUT_VS" "$1" 2>&1; }
st_n(){ st_out "$1" | sed -n 's/^  re-typed in table : \([0-9][0-9]*\).*/\1/p'; }
vs_n(){ vs_out "$1" | sed -n 's/^   re-typed in table : \([0-9][0-9]*\).*/\1/p'; }
PEND='| high | live gap | web | pending |'
R1='| medium | rt-first | web | re-typed [Block 141] — blocked-pending-native-gate |'
R2='| low | rt-mid | web | **retyped** (moved) |'
R3='| low | rt-last | web | Re-Typed |'

# 1. status: WARN actionable + visible count; the old generic WARN no longer names re-typed
d="$TMP/a"; mkstate "$d" 1 "$PEND" "$R1"
o="$(st_out "$d")"
sy="$(bash "$SUT_ST" "$d" --sync-state 2>&1)"
grep -q '^  re-typed in table : 1' <<<"$o" && ok "1a status shows visible re-typed count" || no "1a status count line missing"
grep -q 'unrecognised Status token \[re-typed\]' <<<"$sy" && no "1c --sync-state still emits the generic unrecognised WARN" || ok "1c --sync-state no longer calls re-typed 'unrecognised'"
grep -q 'WARN: re-typed row still carries' <<<"$sy" && ok "1d --sync-state emits the actionable WARN" || no "1d --sync-state WARN missing"
# 2. no new bucket: investigable stays 1
d="$TMP/a2"; mkstate "$d" 1 "$PEND" "$R1"
grep -qE 'investigable=1 ' <<<"$(st_out "$d")" && ok "2 investigable unchanged (no new bucket)" || no "2 investigable shifted"
# 3. verify-state: same WARN + count, still consistent (rc 0)
d="$TMP/a3"; mkstate "$d" 1 "$PEND" "$R1"
vo="$(vs_out "$d")"; vrc=0; bash "$SUT_VS" "$d" >/dev/null 2>&1 || vrc=$?
grep -q '^   re-typed in table : 1' <<<"$vo" && ok "3a verify-state shows visible count" || no "3a verify-state count missing"
grep -q 'WARN   re-typed row still carries' <<<"$vo" && ok "3b verify-state WARN is actionable" || no "3b verify-state WARN missing"
[ "$vrc" = 0 ] && ok "3c re-typed row is a WARN, not a FAIL (rc 0)" || no "3c verify-state rc=$vrc"
# 4. none -> silent in both (byte-stable output for corpora without re-typed rows)
d="$TMP/none"; mkstate "$d" 1 "$PEND"
grep -qi 're-typed' <<<"$(st_out "$d")$(bash "$SUT_ST" "$d" --sync-state 2>&1)" && no "4a status leaked a re-typed line" || ok "4a status silent with none"
grep -qi 're-typed' <<<"$(vs_out "$d")" && no "4b verify-state leaked a re-typed line" || ok "4b verify-state silent with none"
# 5. parity across list edges: first / middle / last / single / three
parity() { # LABEL WANT ROW...
  local lab="$1" want="$2" s v; shift 2
  local dd="$TMP/par-$lab"; mkstate "$dd" 1 "$@"
  s="$(st_n "$dd")"; v="$(vs_n "$dd")"; s="${s:-0}"; v="${v:-0}"
  if [ "$s" = "$want" ] && [ "$v" = "$want" ]; then ok "5.$lab parity: status=$s verify-state=$v want=$want"
  else no "5.$lab parity: status='$s' verify-state='$v' want=$want"; fi
}
# warnset SCRIPT-OUTPUT — the per-row re-typed WARN lines, prefix-normalised, sorted: the set both scripts must agree on.
warnset() { grep 're-typed row still carries' <<<"$1" | sed -E 's/^ *WARN:? *//' | sort -u; }
wparity() { # LABEL WANT-ROWS ROW... — per-row WARN sets identical and one WARN per re-typed row, each naming its gap
  local lab="$1" want="$2" ws wv; shift 2
  local dd="$TMP/wpar-$lab"; mkstate "$dd" 1 "$@"
  ws="$(warnset "$(bash "$SUT_ST" "$dd" --sync-state 2>&1)")"; wv="$(warnset "$(vs_out "$dd")")"
  if [ "$ws" = "$wv" ] && [ "$(grep -c '\[gap: rt-' <<<"$wv")" = "$want" ]; then ok "5w.$lab per-row WARN sets identical ($want row(s), each names its gap)"
  else no "5w.$lab per-row WARN sets differ :: status=[$ws] verify=[$wv]"; fi
}
wparity single 1 "$R1"
wparity first 1 "$R1" "$PEND"
wparity mid 1 "$PEND" "$R2" "$PEND"
wparity last 1 "$PEND" "$R3"
wparity three 3 "$R1" "$PEND" "$R2" "$R3"
parity single 1 "$R1"
parity first 1 "$R1" "$PEND"
parity mid 1 "$PEND" "$R2" "$PEND"
parity last 1 "$PEND" "$R3"
parity three 3 "$R1" "$PEND" "$R2" "$R3"
# 6. struck-through re-typed row is a resolved row: not counted, not warned
d="$TMP/struck"; mkstate "$d" 1 "$PEND" '| low | ~~old gap~~ | web | re-typed |'
[ -z "$(st_n "$d")" ] && ok "6a struck gap not counted (status)" || no "6a struck row counted (status)"
[ -z "$(vs_n "$d")" ] && ok "6b struck gap not counted (verify-state)" || no "6b struck row counted (verify-state)"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  d="$TMP/a"
  t="$(mk_tree A)"
  if mutant_sed "$ST" "$t/research-sdd-status.sh" '/RETYPED-WARN/ s/printf .*/: ;;  # RETYPED-WARN [NEUTERED]/' >/dev/null 2>&1; then
    grep -q 'WARN: re-typed row still carries' <<<"$(bash "$t/research-sdd-status.sh" "$d" --sync-state 2>&1)" && no "teeth A: WARN still emitted — THEATER" || ok "teeth A: status WARN neutered -> case 1d bites"
  else no "teeth A: mutant unbuildable"; fi
  t="$(mk_tree B)"
  if mutant_sed "$ST" "$t/research-sdd-status.sh" '/RETYPED-COUNT/ s/n=\$((n+1))/:/' >/dev/null 2>&1; then
    grep -q '^  re-typed in table : 1' <<<"$(bash "$t/research-sdd-status.sh" "$d" 2>&1)" && no "teeth B: still counts — THEATER" || ok "teeth B: status counter frozen -> case 1a/5 bite"
  else no "teeth B: mutant unbuildable"; fi
  t="$(mk_tree C)"
  if mutant_sed "$VS" "$t/verify-state.sh" '/RETYPED-COUNT/ s/n=\$((n+1))/:/' >/dev/null 2>&1; then
    grep -q 're-typed in table : 1' <<<"$(bash "$t/verify-state.sh" "$d" 2>&1)" && no "teeth C: still counts — THEATER" || ok "teeth C: verify-state counter frozen -> case 3a bites"
  else no "teeth C: mutant unbuildable"; fi
  t="$(mk_tree D)"
  if mutant_sed "$VS" "$t/verify-state.sh" '/RETYPED-TOKENS/ s/|retyped\*//' >/dev/null 2>&1; then
    v="$(bash "$t/verify-state.sh" "$TMP/par-mid" 2>&1 | sed -n 's/^   re-typed in table : \([0-9]*\).*/\1/p')"
    [ "${v:-0}" != "$(st_n "$TMP/par-mid")" ] && ok "teeth D: token drift breaks parity -> case 5.mid bites" || no "teeth D: parity unchanged — THEATER"
  else no "teeth D: mutant unbuildable"; fi
  t="$(mk_tree F)"
  if mutant_sed "$VS" "$t/verify-state.sh" '/RETYPED-WARN/ s/\[gap: \${_rt_gap}\]/[gap: ?]/' >/dev/null 2>&1; then
    grep -q '\[gap: rt-first\]' <<<"$(bash "$t/verify-state.sh" "$TMP/wpar-three" 2>&1)" && no "teeth F: gap still named — THEATER" || ok "teeth F: verify-state WARN stops naming the gap -> case 5w bites"
  else no "teeth F: mutant unbuildable"; fi
  t="$(mk_tree E)"
  if mutant_sed "$VS" "$t/verify-state.sh" '/RETYPED-WARN/ s/echo .*/:  # RETYPED-WARN [NEUTERED]/' >/dev/null 2>&1; then
    grep -q 'WARN   re-typed row still carries' <<<"$(bash "$t/verify-state.sh" "$d" 2>&1)" && no "teeth E: WARN still emitted — THEATER" || ok "teeth E: verify-state WARN neutered -> case 3b bites"
  else no "teeth E: mutant unbuildable"; fi
fi
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
