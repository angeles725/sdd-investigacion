#!/usr/bin/env bash
# verify-state-inplace-blocked.test.sh — verify-state CHECK H must count in-place blocked backlog rows (kit #1915).
#
# research-sdd-status.sh --sync-state (PR #1948) subtracts OPEN in-place blocked rows (leading Status token `blocked`,
# `blocked:`, `blocked,`, `blocked-on-*`; not dual-listed under a Blocked-gaps section by gap ID) from gaps_closed.
# The envelope has no field for that bucket, so CHECK H's declared identity
#   gaps_closed + investigable_open + blocked_open + deferred_open + requires_execution_open == known_gaps
# came up short by the bucket (a false stale-denominator WARN on a freshly synced corpus). verify-state now derives the
# SAME bucket from disk via the shared lib/focus-prefix.sh helper and adds it to the identity sum.
# Usage: verify-state-inplace-blocked.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$HERE/.."
VS="$TB/verify-state.sh"; ST="$TB/research-sdd-status.sh"
[ -f "$VS" ] && [ -f "$ST" ] || { echo "FATAL: SUT not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The Go binary the verify-state shim execs: the caller's RSDD_BIN, else one build into the temp dir.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$TMP/rsdd"
fi
RSDD_HOOK_WIRING_CEILING="$(dirname "$TMP")"; export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== verify-state-inplace-blocked.test.sh =="

# mkstate DIR GC KG INV BO [--raw-bullet TEXT]... ROW... — corpus with the given DECLARED envelope and raw backlog rows.
mkstate() {
  local d="$1" gc="$2" kg="$3" inv="$4" bo="$5" bullets=(); shift 5
  while [ "${1:-}" = "--raw-bullet" ]; do bullets+=("- $2"); shift 2; done
  mkdir -p "$d"
  { echo "# T — Research State"; echo
    printf '<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: %s\nknown_gaps: %s\ninvestigable_open: %s\nrequires_execution_open: 0\nblocked_open: %s\ndeferred_open: 0\n<!-- /research-state.v1 -->\n\n' "$gc" "$kg" "$inv" "$bo"
    echo "## Gap-backlog (prioritized)"; echo
    echo "| Priority | Gap | Artifact type / source | Status |"; echo "|---|---|---|---|"
    local r; for r in "$@"; do echo "$r"; done
    echo
    if [ "${#bullets[@]}" -gt 0 ]; then echo "## Blocked gaps"; echo; local b; for b in "${bullets[@]}"; do echo "$b"; done; echo; fi
    echo "## Stop control"; echo
  } > "$d/RESEARCH-STATE.md"
}
vs_out(){ bash "$VS" "$1" 2>/dev/null; }
stale(){ grep -qE 'WARN.*sum of declared counters.*stale denominator' <<<"$1"; }
PEND='| high | live gap | web | pending |'
DONE='| low | done gap | web | ✅ covered |'
B1='| medium | blk-first | web | blocked (requires-hardware) |'
B2='| low | blk-mid | web | blocked-on-tool: needs a decompiler |'
B3='| low | blk-last | web | blocked |'
BSTRUCK='| low | ~~blk-struck~~ | web | blocked (requires-x) |'
BCLOSED='| low | blk-closed | web | blocked ✅ closed |'
DUALID='| low | AB. Builders de config del equipo — offsets | binario X.exe | blocked-on-tool: necesita decompilar · tried: y |'

# 1. single in-place blocked row: identity holds only WITH the bucket (gc=1 inv=1 ipb=1 → kg=3)
d="$TMP/a"; mkstate "$d" 1 3 1 0 "$PEND" "$DONE" "$B1"
o="$(vs_out "$d")"
if stale "$o"; then no "1a false stale-denominator WARN on a synced in-place blocked corpus: $(grep -i 'stale denom' <<<"$o")"; else ok "1a identity holds with the in-place bucket (no WARN)"; fi
# 1b/1c. the bucket is not a free pass: a wrong kg still WARNs, and the WARN names the in-place term
d="$TMP/a2"; mkstate "$d" 1 9 1 0 "$PEND" "$DONE" "$B1"
o="$(vs_out "$d")"
if stale "$o"; then ok "1b a genuinely stale kg=9 still WARNs"; else no "1b stale kg not caught: $o"; fi
if grep -q 'in_place_blocked' <<<"$o"; then ok "1c the WARN names the in-place term"; else no "1c WARN does not name the in-place term: $(grep -i 'stale denom' <<<"$o")"; fi
# 2. first / middle / last forms together (gc=1 inv=1 ipb=3 → kg=5)
d="$TMP/b"; mkstate "$d" 1 5 1 0 "$B1" "$PEND" "$B2" "$DONE" "$B3"
o="$(vs_out "$d")"
if stale "$o"; then no "2 first/mid/last: false WARN: $(grep -i 'stale denom' <<<"$o")"; else ok "2 first/mid/last in-place rows all counted (ipb=3)"; fi
# 3. none: nothing changes (gc=1 inv=1 → kg=2); and an identity short by one is still caught
d="$TMP/c"; mkstate "$d" 1 2 1 0 "$PEND" "$DONE"
o="$(vs_out "$d")"
if stale "$o"; then no "3a false WARN with no in-place rows"; else ok "3a no in-place rows: identity holds, silent"; fi
d="$TMP/c2"; mkstate "$d" 1 3 1 0 "$PEND" "$DONE"
o="$(vs_out "$d")"
if stale "$o"; then ok "3b no in-place rows + kg off by one: WARN (bucket adds nothing)"; else no "3b missed: $o"; fi
# 4. struck / ✅-closed blocked rows are closed → not in the bucket (gc=3 inv=1 → kg=4)
d="$TMP/d"; mkstate "$d" 3 4 1 0 "$PEND" "$BSTRUCK" "$BCLOSED" "$DONE"
o="$(vs_out "$d")"
if stale "$o"; then no "4 struck/closed blocked rows leaked into the bucket: $(grep -i 'stale denom' <<<"$o")"; else ok "4 struck/✅ blocked rows stay closed"; fi
# 5. dual-listed by exact name AND by gap ID: counted once, as blocked_open (bo=1 gc=1 inv=1 → kg=3)
d="$TMP/e"; mkstate "$d" 1 3 1 1 --raw-bullet "blk-first — needs: a tool" "$PEND" "$DONE" "$B1"
o="$(vs_out "$d")"
if stale "$o"; then no "5a exact-name dual-listing double counted: $(grep -i 'stale denom' <<<"$o")"; else ok "5a exact-name dual-listed row counted once"; fi
d="$TMP/e2"; mkstate "$d" 1 3 1 1 --raw-bullet '**AB. Offsets de campo** (X) — needs: a decompiler' "$PEND" "$DONE" "$DUALID"
o="$(vs_out "$d")"
if stale "$o"; then no "5b ID-matched dual-listing double counted: $(grep -i 'stale denom' <<<"$o")"; else ok "5b ID-matched dual-listed row counted once"; fi
# 5c. a needs-less bullet raises no bucket, so it must NOT suppress the row (bo=0 gc=1 inv=1 ipb=1 → kg=3)
d="$TMP/e3"; mkstate "$d" 1 3 1 0 --raw-bullet '**AB. Offsets de campo** (X) — no clause here' "$PEND" "$DONE" "$DUALID"
o="$(vs_out "$d")"
if stale "$o"; then no "5c needs-less bullet wrongly suppressed the in-place row: $(grep -i 'stale denom' <<<"$o")"; else ok "5c needs-less bullet does not suppress the row"; fi
# 6. ROUND-TRIP: a fresh status --sync-state, then verify-state, must agree for each shape
d="$TMP/rt1"; mkstate "$d" 0 0 0 0 "$PEND" "$DONE" "$B1"
d="$TMP/rt2"; mkstate "$d" 0 0 0 0 "$B1" "$PEND" "$B2" "$DONE" "$B3"
d="$TMP/rt3"; mkstate "$d" 0 0 0 0 "$PEND" "$BSTRUCK" "$BCLOSED" "$DONE"
for n in 1 2 3; do
  d="$TMP/rt$n"; bash "$ST" "$d" --sync-state >/dev/null 2>&1
  o="$(vs_out "$d")"
  if stale "$o"; then no "6.$n round-trip: verify-state disagrees with a fresh --sync-state: $(grep -i 'stale denom' <<<"$o")"; else ok "6.$n round-trip: --sync-state then verify-state agree"; fi
done

# --prove-teeth: both consumers are Go commands now (verify-state, kit #2457; research-sdd-status, kit #2549), so the
# lib mutants of the former teeth C (INPLACE-DUAL-GUARD), I (INPLACE-DUAL-ID-CASE), T (INPLACE-BLOCKED-TOKENS) and N
# (the needs-clause grep) have no shell code to bite. Their controls are Go tests: internal/core/kit InplaceBlockedCount
# (inplace_test.go) and the internal/status/show scenarios s8a-ib-5-dual-listed-by-exact-name-counted-once,
# s8a-ib-7a-id-matched-dual-listing-counted-once, s8a-ib-7c-plain-word-first-token-is-not-an-id,
# s8a-ib-11-1/11-2/11-3 (the AB./AB/ab: ID case folds) and s8a-ib-12-needs-less-bullet-does-not-suppress-the-row, plus
# bl-inplace-suite, bl-inplace-dual-id, bl-inplace-id-case and bl-inplace-no-needs. This suite runs black-box only.
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
