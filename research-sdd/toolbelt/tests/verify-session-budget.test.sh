#!/usr/bin/env bash
# verify-session-budget.test.sh — shim-contract harness for verify-session-budget.sh (kit issues #2129, #2174), now a
# shim to `rsdd budget session` (kit issue #2364).
#
# The behaviour itself (per-source SessionStart selection, matcher rules, character counting, the 10,000 / 8,000
# boundaries, typed degraded states, the bwrap containment argv, the pi / gentle-shell harness) is pinned in Go:
# research-sdd/rsdd/internal/budget (unit, golden, differential-against-the-frozen-script and divergence tests; run by
# `make test` and by rsdd-go.test.sh). This suite keeps only what a bash caller can break: the SHIM — argument and
# exit-code pass-through, the toolbelt directory it hands the binary, a missing lib, an unusable binary — plus the
# frozen pre-port output of the fixtures that need no sandbox, run end to end through the shim.
# --prove-teeth mutates the SHIM (each mutant must lose its case); the Go source has its own mutation gate.
#
# Usage: verify-session-budget.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-session-budget.sh"
FIXSRC="$HERE/fixtures/verify-session-budget"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
has(){ grep -qE -- "$2" <<<"$1"; }

# The Go binary the shim execs: the caller's RSDD_BIN, else one build into the temp dir.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$TMP/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$TMP/rsdd"
fi

# stage_shim DEST_TOOLBELT [SHIM] — a sandbox toolbelt holding the shim (the real one, or a mutant) and lib/rsdd-exec.sh.
stage_shim() { mkdir -p "$1"; cp "${2:-$SUT}" "$1/verify-session-budget.sh"; chmod +x "$1/verify-session-budget.sh"; mkdir -p "$1/lib" && cp "$HERE/../lib/rsdd-exec.sh" "$1/lib/" || exit 2; }   # stage-libs-ok: the shim needs only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case 7

echo "== verify-session-budget.test.sh =="
FIX="$TMP/fix"; mkdir -p "$FIX"; cp -a "$FIXSRC/." "$FIX/"; FIXR="$(cd "$FIX" && pwd -P)"
BW_OK=0
if command -v bwrap >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 && bwrap --ro-bind / / true >/dev/null 2>&1; then BW_OK=1; fi
if [ "$BW_OK" != 1 ] && [ "${RSDD_REQUIRE_BWRAP:-}" = 1 ]; then no "0 RSDD_REQUIRE_BWRAP=1 but no usable unprivileged bwrap (sandbox cases would SKIP)"; fi

# 1-3 — the frozen pre-port output, byte for byte, of the fixtures that need no sandbox (fixture path written @FIX@).
for t in empty absent badjson; do
  got="$(RSDD_BUDGET_HOOK_TIMEOUT=10 bash "$SUT" "$FIX/$t" 2>&1)"; rc=$?
  got="${got//$FIXR/@FIX@}"
  if [ "$rc" = 0 ] && [ "$got" = "$(cat "$FIXSRC/_frozen/$t.out")" ]; then ok "1 the shim prints the frozen pre-port output on '$t' (exit 0)"
  else no "1 '$t' differs from the frozen output (rc=$rc): $(diff <(cat "$FIXSRC/_frozen/$t.out") <(printf '%s\n' "$got") | head -4)"; fi
done

# 4 — a hook run end to end through the shim (needs a usable unprivileged bwrap; otherwise ONE typed SKIP, not a pass).
if [ "$BW_OK" = 1 ]; then
  got="$(RSDD_BUDGET_HOOK_TIMEOUT=10 bash "$SUT" "$FIX/mixed" 2>&1)"; rc=$?; got="${got//$FIXR/@FIX@}"
  if [ "$rc" = 0 ] && [ "$got" = "$(cat "$FIXSRC/_frozen/mixed.out")" ]; then ok "4 the shim runs hooks in the sandbox and prints the frozen output on 'mixed'"
  else no "4 'mixed' differs from the frozen output (rc=$rc): $(diff <(cat "$FIXSRC/_frozen/mixed.out") <(printf '%s\n' "$got") | head -4)"; fi
else printf '  SKIP  4 hook run through the shim (no usable bwrap)\n'; fi

# 5 — usage errors pass through: exit 2, usage on stderr, nothing on stdout.
out5="$(bash "$SUT" 2>"$TMP/err5")"; rc5=$?
out5b="$(bash "$SUT" --harness nope "$FIX/empty" 2>"$TMP/err5b")"; rc5b=$?
out5c="$(bash "$SUT" "$TMP/no-such-dir" 2>"$TMP/err5c")"; rc5c=$?
if [ "$rc5" = 2 ] && [ "$rc5b" = 2 ] && [ "$rc5c" = 2 ] && [ -z "$out5$out5b$out5c" ] \
   && grep -q '^usage: verify-session-budget.sh \[--harness claude|pi|both\] <target-dir>$' "$TMP/err5" "$TMP/err5b" "$TMP/err5c"; then
  ok "5 no argument, an unknown --harness and a missing target are usage errors (exit 2, usage on stderr)"
else no "5 usage: rc=$rc5/$rc5b/$rc5c out=[$out5$out5b$out5c] err=[$(cat "$TMP/err5" "$TMP/err5b" "$TMP/err5c" 2>&1)]"; fi

# 6 — the shim hands the binary its OWN directory (the pi helper and the default kit are found from it): a staged copy
#     reports ITS kit, and the arguments (--harness pi, the target) arrive in order.
KIT6="$TMP/kit6"; stage_shim "$KIT6/toolbelt"
out6="$(env -u RSDD_BUDGET_KIT bash "$KIT6/toolbelt/verify-session-budget.sh" --harness pi "$FIX/pi-none" 2>&1)"; rc6=$?
if [ "$rc6" = 0 ] && has "$out6" "^verify-session-budget: $FIXR/pi-none\$" && has "$out6" '^harness: pi ' && has "$out6" "^kit: $(cd "$KIT6" && pwd -P)\$"; then
  ok "6 the shim passes --toolbelt <its own directory> and its arguments through (staged kit reported, pi harness selected)"
else no "6 toolbelt hand-off: rc=$rc6 [$out6]"; fi

# 7 — the shim's own lib missing → a typed degraded line, rc 2, nothing on stdout (never a silent pass).
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/verify-session-budget.sh"
out7="$(bash "$TMP/nolib/verify-session-budget.sh" "$FIX/empty" 2>"$TMP/err7")"; rc7=$?
if [ "$rc7" = 2 ] && [ -z "$out7" ] && grep -q "^degraded: rsdd-unavailable — rsdd-exec.sh missing beside $TMP/nolib/verify-session-budget.sh\$" "$TMP/err7"; then
  ok "7 missing rsdd-exec.sh → typed degraded line, rc 2"
else no "7 missing lib: rc=$rc7 out=[$out7] err=[$(cat "$TMP/err7")]"; fi

# 8 — an unusable RSDD_BIN → typed degraded line, rc 2 (the measurement could not run: not a pass).
out8="$(RSDD_BIN="$TMP/does-not-exist" bash "$SUT" "$FIX/empty" 2>"$TMP/err8")"; rc8=$?
if [ "$rc8" = 2 ] && [ -z "$out8" ] && grep -q '^degraded: rsdd-unavailable — RSDD_BIN not executable: ' "$TMP/err8"; then
  ok "8 unusable RSDD_BIN → typed degraded line, rc 2"
else no "8 unusable binary: rc=$rc8 out=[$out8] err=[$(cat "$TMP/err8")]"; fi

# 9 — the shim is run through a symlink (the idiom installed corpora use): it still finds its lib and its toolbelt.
ln -s "$KIT6/toolbelt/verify-session-budget.sh" "$TMP/link-to-shim.sh"
out9="$(bash "$TMP/link-to-shim.sh" "$FIX/empty" 2>&1)"; rc9=$?
if [ "$rc9" = 0 ] && has "$out9" '^state: empty-input'; then ok "9 a symlinked shim resolves its own directory"; else no "9 symlinked shim: rc=$rc9 [$out9]"; fi

# NEGATIVE CONTROL — each shim mutation must lose its case.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  mk_mut(){ rm -f -- "$3"; mutant_chain_or_count fail "$@" || return 1; }
  echo "-- teeth: each shim mutation must lose its case --"

  # A: the toolbelt hand-off dropped → the binary cannot find its helper/kit: case 6 loses the staged kit line.
  if mk_mut "teeth A: --toolbelt dropped" "$SUT" "$TMP/mutA.sh" 's/ --toolbelt "\$_RSDD_SELF"//'; then
    stage_shim "$TMP/mA/toolbelt" "$TMP/mutA.sh"
    outa="$(env -u RSDD_BUDGET_KIT bash "$TMP/mA/toolbelt/verify-session-budget.sh" --harness pi "$FIX/pi-none" 2>&1)"
    if ! has "$outa" "^kit: $(cd "$TMP/mA" && pwd -P)\$"; then ok "teeth A: no --toolbelt → the staged kit is not reported, case 6 would go RED"; else no "teeth A: mutant still reports the staged kit"; fi
  fi
  # B: the arguments are dropped → usage error where a report was expected: case 1 / 6.
  if mk_mut "teeth B: arguments dropped" "$SUT" "$TMP/mutB.sh" 's/ "\$@"$//'; then
    stage_shim "$TMP/mB/toolbelt" "$TMP/mutB.sh"
    bash "$TMP/mB/toolbelt/verify-session-budget.sh" "$FIX/empty" >/dev/null 2>&1; mrc=$?
    if [ "$mrc" = 2 ]; then ok "teeth B: arguments dropped → usage error (rc 2), case 1 would go RED"; else no "teeth B: mutant rc=$mrc (want 2)"; fi
  fi
  # C: the wrong command → the report is gone, case 1 loses its frozen output.
  if mk_mut "teeth C: wrong command" "$SUT" "$TMP/mutC.sh" 's/budget session/budget sessions/'; then
    stage_shim "$TMP/mC/toolbelt" "$TMP/mutC.sh"
    bash "$TMP/mC/toolbelt/verify-session-budget.sh" "$FIX/empty" >"$TMP/outC" 2>&1; mrc=$?
    if [ "$mrc" != 0 ] && ! has "$(cat "$TMP/outC")" '^state: empty-input'; then ok "teeth C: wrong command → no report, case 1 would go RED"; else no "teeth C: mutant still prints the report"; fi
  fi
  # D: the missing-lib guard stripped → no typed degraded line → case 7.
  if mk_mut "teeth D: guard removed" "$SUT" "$TMP/mutD.sh" 's/ 2>\/dev\/null || { printf .*exit 2; }//'; then
    mkdir -p "$TMP/mD"; cp "$TMP/mutD.sh" "$TMP/mD/verify-session-budget.sh"
    bash "$TMP/mD/verify-session-budget.sh" "$FIX/empty" >/dev/null 2>"$TMP/errD"; mrc=$?
    if ! grep -q 'rsdd-exec.sh missing beside' "$TMP/errD"; then ok "teeth D: unguarded shim no longer announces a missing lib → case 7 would go RED"; else no "teeth D: mutant still announces"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
