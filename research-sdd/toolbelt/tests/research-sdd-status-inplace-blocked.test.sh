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
  local d="$1" bullets=() kgd="${KGDECL:-0}"; shift
  while [ "${1:-}" = "--section-blocked" ] || [ "${1:-}" = "--raw-bullet" ]; do
    if [ "$1" = "--section-blocked" ]; then bullets+=("- $2 — needs: a tool"); else bullets+=("- $2"); fi
    shift 2
  done
  mkdir -p "$d"
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: %s\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n<!-- /research-state.v1 -->\n\n' "$kgd"
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    local r; for r in "$@"; do echo "$r"; done
    echo
    if [ "${#bullets[@]}" -gt 0 ]; then echo "## Blocked gaps"; echo; local b; for b in "${bullets[@]}"; do echo "$b"; done; echo; fi
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

# 7. fleet form (fluke-177x-datos shape): the in-place row and the Blocked-gaps bullet share only the leading gap ID
#    (`AB.`), not the text → counted ONCE (as blocked_open), never subtracted a second time
DUALID='| low | AB. Builders de config del equipo (TBL_X/Y) — offsets de campo | binario X.exe | blocked-on-tool: necesita decompilar X.exe · tried: y |'
IDBULLET='**AB. Offsets de campo de las tablas de config** (TBL_X/Y) — needs: a decompiler'
d="$TMP/f"; mkstate "$d" --raw-bullet "$IDBULLET" "$PEND" "$DONE" "$DUALID"
o="$(sync_out "$d")"
[ "$(env_val "$d" blocked_open)" = 1 ] && [ "$(env_val "$d" gaps_closed)" = 1 ] && ok "7a ID-matched dual-listing counted once (bo=1, gc=1)" || no "7a bo=$(env_val "$d" blocked_open) gc=$(env_val "$d" gaps_closed) (want 1/1)"
grep -q 'in-place blocked' <<<"$o" && no "7b spurious in-place WARN for an ID-matched dual-listed row" || ok "7b no in-place WARN when the ID is dual-listed"
# 7c. a plain-word first token is NOT an ID: no accidental dual-match (row stays in the bucket; the bullet is bo)
d="$TMP/f2"; mkstate "$d" --raw-bullet 'Builders de otra cosa — needs: tool' "$PEND" "$DONE" '| low | Builders de config — x | web | blocked (requires-tool) |'
sync_out "$d" >/dev/null
[ "$(env_val "$d" gaps_closed)" = 0 ] && [ "$(env_val "$d" blocked_open)" = 1 ] && ok "7c plain-word first token is not an ID (bo=1, row bucketed, gc=0)" || no "7c gc=$(env_val "$d" gaps_closed) bo=$(env_val "$d" blocked_open) (want 0/1)"
# 8. KG-LB-KEEP path (declared known_gaps larger than the derived total): the derived closed count also excludes the row
UNC="| high | a | b | c | d | e |"
d="$TMP/g"; KGDECL=10 mkstate "$d" "$PEND" "$DONE" "$B1" "$UNC"
o="$(sync_out "$d")"
[ "$(env_val "$d" known_gaps)" = 10 ] && [ "$(env_val "$d" gaps_closed)" = 1 ] && ok "8 KG-LB-KEEP: kg=10 kept, gaps_closed=1 (row not closed)" || no "8 kg=$(env_val "$d" known_gaps) gc=$(env_val "$d" gaps_closed) (want 10/1)"
# 9. blocked: / blocked, are recognised DONE-TOKENS and bucketed — never "unrecognised"
d="$TMP/h"; mkstate "$d" "$PEND" '| low | colon | web | blocked: needs tool |' '| low | comma | web | blocked, see below |'
o="$(sync_out "$d")"
grep -q 'unrecognised Status token \[blocked' <<<"$o" && no "9a blocked:/blocked, called unrecognised" || ok "9a blocked:/blocked, are recognised tokens"
grep -q '2 in-place blocked row' <<<"$o" && [ "$(env_val "$d" gaps_closed)" = 0 ] && ok "9b both bucketed (gc=0, WARN count 2)" || no "9b gc=$(env_val "$d" gaps_closed): $o"
# 10. GC-CLAMP message includes the in-place bucket in the printed sum
d="$TMP/i"; mkstate "$d" --section-blocked "zzz one" --section-blocked "yyy two" "$PEND" "$B1"
o="$(sync_out "$d")"
grep -q 'in-place-blocked = 4;' <<<"$o" && ok "10 GC-CLAMP WARN sum includes in-place blocked (= 4)" || no "10 clamp sum wrong: $o"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; cp "$TB"/*.sh "$t/"; printf '%s' "$t"; }
  fx_a() { mkstate "$TMP/m" "$PEND" "$DONE" "$B1"; }
  fx_c() { mkstate "$TMP/m" --section-blocked "blk-first" "$PEND" "$DONE" "$B1"; }
  fx_d() { mkstate "$TMP/m" "$PEND" "$DONE" "$B2"; }
  fx_e() { mkstate "$TMP/m" --raw-bullet "$IDBULLET" "$PEND" "$DONE" "$DUALID"; }
  fx_f() { KGDECL=10 mkstate "$TMP/m" "$PEND" "$DONE" "$B1" "$UNC"; }
  # tooth NAME SEDEXPR FIXTURE_FN WANT_GC WANT_KG — mutant must run rc==0, write known_gaps, and yield EXACTLY the wrong gaps_closed
  tooth() {
    local name="$1" expr="$2" fx="$3" want_gc="$4" want_kg="$5" t rc=0
    t="$(mk_tree "$name")"; rm -rf "$TMP/m"
    if ! mutant_sed "$ST" "$t/research-sdd-status.sh" "$expr" >/dev/null 2>&1; then no "teeth $name: mutant unbuildable"; return; fi
    "$fx"
    bash "$t/research-sdd-status.sh" "$TMP/m" --sync-state >"$TMP/m.out" 2>&1 || rc=$?
    if [ "$rc" != 0 ]; then no "teeth $name: mutant crashed rc=$rc — a crash is not a bite"; return; fi
    [ "$(env_val "$TMP/m" known_gaps)" = "$want_kg" ] || { no "teeth $name: known_gaps=$(env_val "$TMP/m" known_gaps) (want $want_kg) — run did not reach the write"; return; }
    [ "$(env_val "$TMP/m" gaps_closed)" = "$want_gc" ] && ok "teeth $name: mutant yields exactly gaps_closed=$want_gc" || no "teeth $name: gaps_closed=$(env_val "$TMP/m" gaps_closed) (want mutant $want_gc) — THEATER"
  }
  tooth A '/INPLACE-GC-SUBTRACT/ s/ - \${_ipb:-0}//' fx_a 2 3
  tooth C '/INPLACE-DUAL-GUARD/ s/is_blocked "\$gap" \&\& continue/:/' fx_c 0 3
  tooth D '/INPLACE-BLOCKED-TOKENS/ s/blocked-on-\*|//' fx_d 2 3
  tooth E '/INPLACE-DUAL-ID-CASE/ s/continue/:/' fx_e 0 3
  tooth F '/_gc_d=\$((/ s/ - \${_ipb:-0}//' fx_f 2 10
fi
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
