#!/usr/bin/env bash
# Retired cases are pinned in Go: research-sdd/rsdd/internal/status/show/s6_scenarios_test.go (k-retyped-*) and s3_scenarios_test.go.
# research-sdd-status-retyped.test.sh — re-typed row left in the main Gap-backlog table (kit issue #1638).
#
# METHODOLOGY §8b: a re-typed gap leaves the main table in the same edit (it moves to the Blocked-gaps
# section). A row whose leading Status token is `re-typed`/`retyped` is uncounted BY DESIGN, but it must
# never be dropped silently (§7): research-sdd-status.sh and verify-state.sh both (a) classify it the same
# way, (b) emit an actionable `WARN: re-typed row ...` and (c) show a visible `re-typed in table : N` count.
# A parity block asserts both scripts agree on the count for the same rows (list edges: first/middle/last/
# single/none). No new blocked bucket for main-table rows: investigable_open is unchanged by these rows.
# The status half (visible count, actionable WARN, no new bucket, struck rows) is pinned by the k-retyped-* and retyped-row-warning
# scenarios of `rsdd status show`; this suite keeps the verify-state cases and the status-vs-verify-state parity.
# Usage: research-sdd-status-retyped.test.sh   Exit: 0 all held · 1 regression · 2 harness.
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

# 3. verify-state: same WARN + count, still consistent (rc 0)
d="$TMP/a3"; mkstate "$d" 1 "$PEND" "$R1"
vo="$(vs_out "$d")"; vrc=0; bash "$SUT_VS" "$d" >/dev/null 2>&1 || vrc=$?
grep -q '^   re-typed in table : 1' <<<"$vo" && ok "3a verify-state shows visible count" || no "3a verify-state count missing"
grep -q 'WARN   re-typed row still carries' <<<"$vo" && ok "3b verify-state WARN is actionable" || no "3b verify-state WARN missing"
[ "$vrc" = 0 ] && ok "3c re-typed row is a WARN, not a FAIL (rc 0)" || no "3c verify-state rc=$vrc"
# 4. none -> silent in both (byte-stable output for corpora without re-typed rows)
d="$TMP/none"; mkstate "$d" 1 "$PEND"
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
[ -z "$(vs_n "$d")" ] && ok "6b struck gap not counted (verify-state)" || no "6b struck row counted (verify-state)"

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
