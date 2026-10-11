#!/usr/bin/env bash
# verify-session-budget.test.sh — harness for verify-session-budget.sh (kit issue #2129).
# Fixture targets live under tests/fixtures/verify-session-budget/ (stub SessionStart hooks that emit
# known character counts). Pins: per-hook chars, TRUNCATED (> 10,000), OVER BUDGET (aggregate >= 8,000),
# JSON-shaped output, typed degraded/absent-input/empty-input states, and that the target is
# byte-identical (content AND mtime) after the run, including a hook that tries to write.
# Usage: verify-session-budget.test.sh [--prove-teeth]
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-session-budget.sh"
FIXSRC="$HERE/fixtures/verify-session-budget"
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== verify-session-budget.test.sh =="

[ -f "$SUT" ] || { no "0 SUT not found: $SUT"; echo "== $pass passed · $fail failed =="; exit 1; }
command -v bwrap >/dev/null 2>&1 || { echo "SKIP-AS-FAIL: bwrap absent, sandbox cases cannot run" >&2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"

snap() { ( cd "$1" && find . -printf '%p %y %s %T@\n' | LC_ALL=C sort; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) ; }

run() { # run SUT against a fixture dir, with a short hook timeout; sets OUT, RC
  OUT="$(RSDD_BUDGET_HOOK_TIMEOUT="${HOOK_TO:-10}" bash "$1" ${2:+"$2"} 2>&1)"; RC=$?
}

has() { grep -qE -- "$2" <<<"$1"; }

check_suite() { # $1 = SUT path used by every case; runs on a FRESH COPY of the fixtures (a mutant may leak writes)
  local S="$1" FIX; FIX="$(mktemp -d "$TMP/fix.XXXXXX")"; cp -a "$FIXSRC/." "$FIX/"
  # --- mixed: per-hook numbers, TRUNCATED, JSON, no mutation -------------------------------------
  snap "$FIX/mixed" > "$TMP/before"
  run "$S" "$FIX/mixed"
  snap "$FIX/mixed" > "$TMP/after"
  has "$OUT" 'hook\[1\] chars=500 status=ok' && ok "1 plain 500-char hook measured as 500 ok" || no "1 plain500 line missing: [$OUT]"
  has "$OUT" 'hook\[2\] chars=10500 status=TRUNCATED' && ok "2 10,500-char hook is TRUNCATED" || no "2 TRUNCATED line missing: [$OUT]"
  has "$OUT" 'hook\[3\] chars=500 status=ok' && ok "3 JSON additionalContext+systemMessage counted (300+200)" || no "3 json line missing: [$OUT]"
  has "$OUT" 'hook\[4\] chars=5 status=ok' && ok "4 writing hook still measured (5 chars)" || no "4 writer line missing: [$OUT]"
  has "$OUT" 'aggregate: 11505 chars .*OVER BUDGET' && ok "5 aggregate 11505 flagged OVER BUDGET" || no "5 aggregate line wrong: [$OUT]"
  [ "$RC" = 0 ] && ok "6 findings are WARN-only (exit 0)" || no "6 exit $RC want 0"
  cmp -s "$TMP/before" "$TMP/after" && ok "7 target byte-identical (content+mtime) after run" || no "7 target CHANGED: $(diff "$TMP/before" "$TMP/after" | head -5)"
  [ ! -e "$FIX/mixed/.claude/.hook-wrote-this" ] && [ ! -e "$FIX/mixed/stray-root-file" ] && ok "8 hook writes never reached the target" || no "8 hook write leaked into the target"
  # --- degraded ------------------------------------------------------------------------------------
  HOOK_TO=1 run "$S" "$FIX/degraded"
  has "$OUT" 'hook\[1\] chars=100 status=ok' && ok "9 healthy hook still measured beside degraded ones" || no "9 ok100 missing: [$OUT]"
  has "$OUT" 'hook\[2\] .*status=degraded\(timeout' && ok "10 hanging hook is degraded(timeout)" || no "10 hang not degraded: [$OUT]"
  has "$OUT" 'hook\[3\] .*status=degraded\(exit 1' && ok "11 failing hook is degraded(exit 1), partial output not counted" || no "11 fail not degraded: [$OUT]"
  has "$OUT" 'hook\[4\] .*status=degraded\(' && ok "12 unresolvable hook is degraded" || no "12 missing not degraded: [$OUT]"
  has "$OUT" 'hook\[2\] chars=0' && no "13 degraded hook reported as chars=0" || ok "13 degraded hook is never counted as 0 chars"
  has "$OUT" 'aggregate: 100 chars .*partial: 3 degraded' && ok "14 aggregate is marked partial with the degraded count" || no "14 aggregate partial wrong: [$OUT]"
  [ "$RC" = 0 ] && ok "15 degraded is WARN-only (exit 0)" || no "15 exit $RC want 0"
  # --- over: aggregate only -------------------------------------------------------------------------
  run "$S" "$FIX/over"
  has "$OUT" 'TRUNCATED' && no "16 no single hook should be TRUNCATED: [$OUT]" || ok "16 no TRUNCATED when every hook is under 10,000"
  has "$OUT" 'aggregate: 9000 chars .*OVER BUDGET' && ok "17 aggregate 9000 (3x3000) OVER BUDGET" || no "17 aggregate wrong: [$OUT]"
  # --- typed input states ---------------------------------------------------------------------------
  run "$S" "$FIX/empty"
  has "$OUT" 'state: empty-input' && ok "18 no SessionStart hooks -> empty-input" || no "18 empty state wrong: [$OUT]"
  run "$S" "$FIX/absent"
  has "$OUT" 'state: absent-input' && ok "19 missing settings -> absent-input" || no "19 absent state wrong: [$OUT]"
  run "$S" "$TMP/no-such-dir"
  [ "$RC" = 2 ] && ok "20 nonexistent target dir is a usage error (exit 2)" || no "20 exit $RC want 2"
  run "$S"
  [ "$RC" = 2 ] && ok "21 no argument is a usage error (exit 2)" || no "21 exit $RC want 2"
}

check_suite "$SUT"

# ---- Teeth ------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  echo "-- teeth: each mutant must turn at least one case RED --"
  tooth() { # tooth LABEL SED_EXPR
    local label="$1" expr="$2" m="$TMP/mut-$RANDOM.sh" before_fail
    rm -f -- "$m"
    mutant_chain_or_count fail "$label" "$SUT" "$m" "$expr" || return 0
    mkdir -p "$TMP/mutkit/lib"; cp "$m" "$TMP/mutkit/verify-session-budget.sh"; chmod +x "$TMP/mutkit/verify-session-budget.sh"
    [ -d "$HERE/../lib" ] && cp -R "$HERE/../lib/." "$TMP/mutkit/lib/" 2>/dev/null
    before_fail=$fail
    local p0=$pass
    check_suite "$TMP/mutkit/verify-session-budget.sh" >"$TMP/mut.log" 2>&1
    # check_suite bumps pass/fail for the mutant; roll those counters back and judge by the log.
    local mf; mf="$(grep -c '^  FAIL  ' "$TMP/mut.log")"
    pass=$p0; fail=$before_fail
    if [ "$mf" -gt 0 ]; then ok "teeth: $label -> $mf case(s) went RED"; else no "teeth: $label stayed fully GREEN (no bite)"; fi
  }
  tooth "truncation threshold 10000 -> 20000" 's/^cap=10000/cap=20000/'
  tooth "budget 8000 -> 80000" 's/^budget=8000/budget=80000/'
  tooth "non-zero exit not degraded" 's/elif \[ "\$rc" != 0 \]/elif false/'
  tooth "degraded counted as 0 chars (timeout path)" 's/status=degraded(timeout/status=ok(timeout/'
  tooth "sandbox bind dropped (hooks write to the real target)" 's/--bind "\$_sb_dotclaude" "\$target\/.claude"/--bind "$target\/.claude" "$target\/.claude"/'
  tooth "json systemMessage ignored" 's/(\.systemMessage \/\/ "")/("")/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
