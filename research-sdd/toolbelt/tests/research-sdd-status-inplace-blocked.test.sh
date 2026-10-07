#!/usr/bin/env bash
# research-sdd-status-inplace-blocked.test.sh — an in-place `blocked (requires-…)` / `blocked-on-…` Gap-backlog
# row must never be counted as CLOSED on the KG-BACKLOG path (kit issue #1915).
#
# --sync-state derives gaps_closed = known_gaps − (investigable + requires_execution + blocked + deferred). A row
# whose Status is blocked/blocked-on-* is excluded from investigable_open (DONE-TOKENS) but blocked_open is
# derived only from the Blocked-gaps sections, so the row fell into NO open bucket and inflated gaps_closed
# (§7 false confidence). Fix: a typed separate bucket (`in-place blocked`) is subtracted from gaps_closed and
# named in an actionable WARN; blocked_open itself is unchanged (verify-state CHECK C parity).
# Usage: research-sdd-status-inplace-blocked.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$HERE/.."
ST="$TB/research-sdd-status.sh"
[ -f "$ST" ] || { echo "FATAL: SUT not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== research-sdd-status-inplace-blocked.test.sh =="

# mkstate DIR [--section-blocked NAME] ROW... — corpus with zeroed declared counters and the given raw rows.
mkstate() {
  local d="$1" secname=""; shift
  if [ "${1:-}" = "--section-blocked" ]; then secname="$2"; shift 2; fi
  mkdir -p "$d"
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n<!-- /research-state.v1 -->\n\n'
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    local r; for r in "$@"; do echo "$r"; done
    echo
    if [ -n "$secname" ]; then echo "## Blocked gaps"; echo; echo "- $secname — needs: a tool"; echo; fi
    echo "## Stop control"; echo
  } > "$d/RESEARCH-STATE.md"
}
SUT="$ST"
sync_out(){ bash "$SUT" "$1" --sync-state 2>&1; }
env_val(){ sed -n "s/^$2: \([0-9][0-9]*\)\$/\1/p" "$1/RESEARCH-STATE.md" | head -1; }
PEND='| high | live gap | web | pending |'
DONE='| low | done gap | web | ✅ covered |'
B1='| medium | blk-first | web | blocked (requires-hardware) |'
B2='| low | blk-mid | web | blocked-on-tool: needs a decompiler |'
B3='| low | blk-last | web | blocked |'
BSTRUCK='| low | ~~blk-struck~~ | web | blocked (requires-x) |'
BCLOSED='| low | blk-closed | web | blocked ✅ closed |'

# 1. single in-place blocked row: gaps_closed counts ONLY the closed row
d="$TMP/a"; mkstate "$d" "$PEND" "$DONE" "$B1"
o="$(sync_out "$d")"
[ "$(env_val "$d" gaps_closed)" = 1 ] && ok "1a single in-place blocked row is not counted closed (gaps_closed=1)" || no "1a gaps_closed=$(env_val "$d" gaps_closed) (want 1)"
[ "$(env_val "$d" known_gaps)" = 3 ] && ok "1b known_gaps still counts the row (3)" || no "1b known_gaps=$(env_val "$d" known_gaps)"
grep -q 'sync-state: WARN: .*1 in-place blocked row' <<<"$o" && ok "1c typed actionable WARN names the in-place bucket" || no "1c WARN missing: $o"
# 2. first / middle / last forms together (edges)
d="$TMP/b"; mkstate "$d" "$B1" "$PEND" "$B2" "$DONE" "$B3"
o="$(sync_out "$d")"
[ "$(env_val "$d" gaps_closed)" = 1 ] && ok "2a first/mid/last in-place rows all excluded from closed (gaps_closed=1)" || no "2a gaps_closed=$(env_val "$d" gaps_closed) (want 1)"
grep -q '3 in-place blocked row' <<<"$o" && ok "2b WARN count is 3" || no "2b WARN count wrong: $o"
# 3. none: no WARN, closed unchanged
d="$TMP/c"; mkstate "$d" "$PEND" "$DONE"
o="$(sync_out "$d")"
[ "$(env_val "$d" gaps_closed)" = 1 ] && ok "3a no in-place rows → gaps_closed=1" || no "3a gaps_closed=$(env_val "$d" gaps_closed)"
grep -q 'in-place blocked' <<<"$o" && no "3b spurious in-place WARN" || ok "3b no WARN when absent"
# 4. struck / ✅-closed blocked rows are closed → not in the bucket
d="$TMP/d"; mkstate "$d" "$PEND" "$BSTRUCK" "$BCLOSED"
o="$(sync_out "$d")"
[ "$(env_val "$d" gaps_closed)" = 2 ] && ok "4a struck/✅ blocked rows stay closed (gaps_closed=2)" || no "4a gaps_closed=$(env_val "$d" gaps_closed) (want 2)"
# 5. a row ALSO listed under ## Blocked gaps is counted once (blocked_open), not twice
d="$TMP/e"; mkstate "$d" --section-blocked "blk-first" "$PEND" "$DONE" "$B1"
o="$(sync_out "$d")"
[ "$(env_val "$d" blocked_open)" = 1 ] && [ "$(env_val "$d" gaps_closed)" = 1 ] && ok "5 dual-listed row counted once (bo=1, gc=1)" || no "5 bo=$(env_val "$d" blocked_open) gc=$(env_val "$d" gaps_closed)"
# 6. blocked_open itself unchanged for the in-place form (verify-state CHECK C parity)
d="$TMP/a"; [ "$(env_val "$d" blocked_open)" = 0 ] && ok "6 blocked_open stays section-derived (0)" || no "6 blocked_open=$(env_val "$d" blocked_open)"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  fresh() { rm -rf "$TMP/m"; mkstate "$TMP/m" "$PEND" "$DONE" "$B1"; }
  # A: the gc subtraction is load-bearing
  t="$(mk_tree A)"; fresh
  if mutant_sed "$ST" "$t/research-sdd-status.sh" '/INPLACE-GC-SUBTRACT/ s/- \${_ipb:-0}//' >/dev/null 2>&1; then
    bash "$t/research-sdd-status.sh" "$TMP/m" --sync-state >/dev/null 2>&1
    [ "$(env_val "$TMP/m" gaps_closed)" = 1 ] && no "teeth A: gc unchanged — THEATER" || ok "teeth A: subtraction removed -> case 1a bites"
  else no "teeth A: mutant unbuildable"; fi
  # B: the WARN is load-bearing
  t="$(mk_tree B)"; fresh
  if mutant_sed "$ST" "$t/research-sdd-status.sh" '/INPLACE-BLOCKED-WARN/ s/printf .*/: ;;  # INPLACE-BLOCKED-WARN [NEUTERED]/' >/dev/null 2>&1 \
     || mutant_sed "$ST" "$t/research-sdd-status.sh" '/INPLACE-BLOCKED-WARN/ s/printf .*/:  # INPLACE-BLOCKED-WARN [NEUTERED]/' >/dev/null 2>&1; then
    grep -q 'in-place blocked' <<<"$(bash "$t/research-sdd-status.sh" "$TMP/m" --sync-state 2>&1)" && no "teeth B: WARN still emitted — THEATER" || ok "teeth B: WARN neutered -> case 1c bites"
  else no "teeth B: mutant unbuildable"; fi
  # C: the dual-listed guard is load-bearing (double count)
  t="$(mk_tree C)"; rm -rf "$TMP/m"; mkstate "$TMP/m" --section-blocked "blk-first" "$PEND" "$DONE" "$B1"
  if mutant_sed "$ST" "$t/research-sdd-status.sh" '/INPLACE-DUAL-GUARD/ s/is_blocked "\$gap" && continue/:/' >/dev/null 2>&1; then
    bash "$t/research-sdd-status.sh" "$TMP/m" --sync-state >/dev/null 2>&1
    [ "$(env_val "$TMP/m" gaps_closed)" = 1 ] && no "teeth C: still 1 — THEATER" || ok "teeth C: dual guard removed -> case 5 bites"
  else no "teeth C: mutant unbuildable"; fi
  # D: the token set is load-bearing (blocked-on-* dropped)
  t="$(mk_tree D)"; rm -rf "$TMP/m"; mkstate "$TMP/m" "$PEND" "$DONE" "$B2"
  if mutant_sed "$ST" "$t/research-sdd-status.sh" '/INPLACE-BLOCKED-TOKENS/ s/blocked-on-\*|//' >/dev/null 2>&1; then
    bash "$t/research-sdd-status.sh" "$TMP/m" --sync-state >/dev/null 2>&1
    [ "$(env_val "$TMP/m" gaps_closed)" = 1 ] && no "teeth D: still 1 — THEATER" || ok "teeth D: token dropped -> case 2 bites"
  else no "teeth D: mutant unbuildable"; fi
fi
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
