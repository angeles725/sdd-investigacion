#!/usr/bin/env bash
# verify-skill-drift-hook.test.sh — the install --verify half of the SessionStart hook (W1).
#
# The hook calls research-sdd-install.sh --verify and surfaces ONLY findings (status=drift|degraded|
# behind), capped at 4 lines x 170 chars so the SessionStart budget (kit-session-cost spec) holds.
# The SKILL.md-drift half is pinned by verify-skill-drift.test.sh; here the drift script is a stub.
#
# TEETH (--prove-teeth): every mutant is a temp copy built by tests/lib/mutant.sh.
#   A  behind-filter-dropped   regex loses `behind` → a stale kit checkout is silent
#   B  cap-removed             `head -4` dropped → unbounded SessionStart output
#   C  width-cap-removed       `cut -c1-170` dropped → over-long lines pass through
#   D  silent-failure          the exit-code fallback removed → a --verify crash with no typed line is silent
#   E  unrunnable-silent       the not-executable branch removed → a missing install script is mislabelled
#
# Usage: verify-skill-drift-hook.test.sh [--prove-teeth]
# Exit: 0 = all held · 1 = regression

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../verify-skill-drift-hook.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found: $HOOK" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Sandbox: the hook copy + a stub drift script (rc/out from env) + a stub install --verify (rc/out from env).
SB="$ROOT/sb"; mkdir -p "$SB"
cp "$HOOK" "$SB/verify-skill-drift-hook.sh"
cat > "$SB/verify-skill-drift.sh" <<'EOF'
#!/usr/bin/env bash
[ -z "${STUB_DRIFT_OUT:-}" ] || printf '%s\n' "$STUB_DRIFT_OUT"
exit "${STUB_DRIFT_RC:-0}"
EOF
cat > "$SB/install-verify-stub.sh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--verify" ] || { echo "stub: expected --verify" >&2; exit 64; }
[ -z "${STUB_VERIFY_SLEEP:-}" ] || sleep "$STUB_VERIFY_SLEEP"
[ -z "${STUB_VERIFY_OUT:-}" ] || printf '%s\n' "$STUB_VERIFY_OUT"
exit "${STUB_VERIFY_RC:-0}"
EOF
# decode.sh <hook> — run the hook and print its context as plain lines (JSON additionalContext decoded).
cat > "$SB/decode.sh" <<'EOF'
#!/usr/bin/env bash
out="$(bash "$1" 2>/dev/null)"; rc=$?
if command -v jq >/dev/null 2>&1 && jq -e . >/dev/null 2>&1 <<<"$out"; then jq -r '.hookSpecificOutput.additionalContext' <<<"$out"
else printf '%s' "$out"; fi
exit "$rc"
EOF
chmod +x "$SB"/*.sh
HOOK_SB="$SB/verify-skill-drift-hook.sh"

# run_hook <drift_rc> <verify_rc> <verify_out> [install cmd] — sets HOUT (decoded stdout) and HRC.
run_hook() {
  HOUT="$(STUB_DRIFT_RC="$1" STUB_VERIFY_RC="$2" STUB_VERIFY_OUT="$3" \
    RESEARCH_SDD_INSTALL_VERIFY_CMD="${4:-$SB/install-verify-stub.sh}" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"; HRC=$?
}
MATCH=$'verify harness=claude status=match bundle_sha256=abc files=3\nverify harness=pi status=absent (not installed)\nverify kit status=current ref=origin/main behind=0 (local ref, no fetch)'
BEHIND='verify kit status=behind ref=origin/main behind=47 (local ref, no fetch — may understate) fix: git -C /k pull --ff-only'

echo "-- hook: install --verify findings --"
run_hook 0 0 "$MATCH"
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && ok "H1: all in-sync + verify match/absent/current → completely silent" || no "H1: expected silent; rc=$HRC out=[$HOUT]"

run_hook 0 0 "$MATCH"$'\n'"$BEHIND"
if [ "$HRC" = 0 ] && grep -q 'status=behind' <<<"$HOUT" && grep -q 'behind=47' <<<"$HOUT" && grep -q 'WARN' <<<"$HOUT"; then ok "H2: stale kit checkout → WARN carrying the typed behind line"
else no "H2: behind not surfaced; rc=$HRC out=[$HOUT]"; fi
if grep -qE 'status=(match|absent|current)' <<<"$HOUT"; then no "H3: non-findings leaked into the output :: $HOUT"
else ok "H3: match/absent/current lines are not repeated (short output)"; fi
if command -v jq >/dev/null 2>&1; then
  RAW="$(STUB_VERIFY_OUT="$BEHIND" RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$HOOK_SB" 2>/dev/null)"
  jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' <<<"$RAW" >/dev/null 2>&1 \
    && ok "H3b: raw output is valid SessionStart JSON" || no "H3b: raw output is not valid SessionStart JSON"
fi

KDEG='verify kit status=degraded reason=git not found; cannot tell whether the kit checkout is behind its upstream'
run_hook 0 0 "$KDEG"
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && ok "H4: kit 'degraded' (tarball/no upstream) is NOT a session-start finding — it stays visible in install --verify only" || no "H4: kit degraded leaked into the hook; rc=$HRC out=[$HOUT]"
run_hook 0 2 'verify harness=pi status=degraded reason=installed files present but no bundle record'
grep -q 'harness=pi status=degraded' <<<"$HOUT" && ok "H4b: a HARNESS degraded line is still surfaced (never a silent pass)" || no "H4b: harness degraded not surfaced; out=[$HOUT]"
HOUT_T="$(STUB_VERIFY_SLEEP=5 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
if command -v timeout >/dev/null 2>&1; then
  grep -q 'timed out' <<<"$HOUT_T" && ok "H4c: a hung install --verify is cut off and reported (typed 'timed out')" || no "H4c: hung --verify not bounded/reported; out=[$HOUT_T]"
fi

run_hook 0 1 'verify harness=claude status=drift drifted=skills/research-sdd/SKILL.md (modified)'
grep -q 'status=drift' <<<"$HOUT" && ok "H5: bundle drift line is surfaced" || no "H5: bundle drift not surfaced; out=[$HOUT]"

run_hook 0 2 ''
grep -q 'exited 2 with no typed line' <<<"$HOUT" && ok "H6: --verify failing with no typed line is still surfaced (anti-silent-zero)" || no "H6: silent failure; rc=$HRC out=[$HOUT]"

run_hook 0 0 "$MATCH" "$SB/does-not-exist.sh"
grep -q 'could not run' <<<"$HOUT" && ok "H7: missing/unrunnable install script → typed 'could not run', not silence" || no "H7: unrunnable install script was silent; out=[$HOUT]"

LONG="$(printf 'verify harness=claude status=degraded reason=%0300d\n' 0)"
MANY="$(for _i in 1 2 3 4 5 6 7 8; do printf '%s\n' "$LONG"; done)"
run_hook 0 2 "$MANY"
nl="$(grep -c 'status=degraded' <<<"$HOUT")"
maxw="$(grep 'status=degraded' <<<"$HOUT" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
if [ "$nl" = 4 ] && [ "$maxw" -le 170 ]; then ok "H8: 8 over-long findings → capped at 4 lines of at most 170 chars"
else no "H8: cap not enforced (lines=$nl maxwidth=$maxw)"; fi
[ "${#HOUT}" -lt 1200 ] && ok "H9: capped output stays under the SessionStart headroom (${#HOUT} chars)" || no "H9: output too large (${#HOUT} chars)"

HOUT2="$(STUB_DRIFT_RC=1 STUB_DRIFT_OUT='verify-skill-drift: diverged harness=claude' STUB_VERIFY_RC=0 STUB_VERIFY_OUT="$BEHIND" \
  RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
if grep -q 'diverged harness=claude' <<<"$HOUT2" && grep -q 'status=behind' <<<"$HOUT2"; then ok "H10: SKILL.md drift and kit staleness are reported together"
else no "H10: combined report lost a half; out=[$HOUT2]"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: hook mutants (lib/mutant.sh) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh" || { echo "FATAL: mutant helper missing" >&2; exit 2; }
  SUT="$HOOK_SB"; MB="$ROOT/mb"; mkdir -p "$MB"; cp "$SB/verify-skill-drift.sh" "$SB/install-verify-stub.sh" "$SB/decode.sh" "$MB/"   # mutants run beside their own stubs, NOT beside the SUT (mutant.sh refuses that)
  _CRASH='syntax error|unbound variable|command not found'
  _mk() { mutant_chain "$@" || fail=$((fail+1)); }
  _tt() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  _ENV="$(command -v env)"
  # Mutants live in the sandbox beside the stubs (the hook finds its drift script via its own dir).
  _mk "A" "$SUT" "$MB/m-a.sh" 's/|kit status=behind)/)/' \
    && _tt "teeth: behind dropped from the filter → a stale kit checkout is silent" 0 0 "$MB/m-a.sh" \
       --good-has 'status=behind' --bad-lacks "$_CRASH|status=behind" -- "$_ENV" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_OUT=$BEHIND" "$BASH_BIN" "$SB/decode.sh" @SUT@
  _mk "B" "$SUT" "$MB/m-b.sh" 's/ | head -4)"/)"/' \
    && _tt "teeth: line cap removed → the finding count is no longer 4 (SessionStart flood)" 0 0 "$MB/m-b.sh" \
       --good-has '^4$' --bad-has '^8$' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_RC=2" "STUB_VERIFY_OUT=$MANY" \
       "$BASH_BIN" -c 'bash "$1" "$2" | grep -c "status=degraded"' _ "$SB/decode.sh" @SUT@
  _mk "C" "$SUT" "$MB/m-c.sh" 's/ | cut -c1-170//' \
    && _tt "teeth: width cap removed → over-long findings pass through" 0 0 "$MB/m-c.sh" \
       --good-lacks '0{250}' --bad-has '0{250}' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_RC=2" "STUB_VERIFY_OUT=$LONG" "$BASH_BIN" "$SB/decode.sh" @SUT@
  _mk "D" "$SUT" "$MB/m-d.sh" 's/if \[ -z "\$extra" \] \&\& \[ "\$vrc" -ne 0 \]; then/if false; then/' \
    && _tt "teeth: exit-code fallback removed → a crashing --verify is silent" 0 0 "$MB/m-d.sh" \
       --good-has 'exited 2 with no typed line' --bad-lacks "$_CRASH|exited 2" -- "$_ENV" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_RC=2" "$BASH_BIN" "$SB/decode.sh" @SUT@
  _mk "E" "$SUT" "$MB/m-e.sh" 's/^if \[ -x "\$vcmd" \]; then/if true; then/' \
    && _tt "teeth: not-executable branch removed → a missing install script is mislabelled" 0 0 "$MB/m-e.sh" \
       --good-has 'could not run' --bad-lacks "$_CRASH|could not run" -- "$_ENV" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/nope.sh" "$BASH_BIN" "$SB/decode.sh" @SUT@
  _mk "F" "$SUT" "$MB/m-f.sh" 's/kit status=behind)/kit status=(behind|degraded))/' \
    && _tt "teeth: kit degraded admitted → every tarball/no-upstream kit warns on every session" 0 0 "$MB/m-f.sh" \
       --good-lacks 'status=degraded' --bad-has 'kit status=degraded' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_OUT=$KDEG" "$BASH_BIN" "$SB/decode.sh" @SUT@
  _mk "G" "$SUT" "$MB/m-g.sh" 's/timeout "\${RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT:-10}" "\$vcmd"/"$vcmd"/' \
    && _tt "teeth: timeout wrapper removed → a hung --verify hangs session start (observed via wall-clock cap)" 0 0 "$MB/m-g.sh" \
       --good-has 'timed out' --bad-lacks "$_CRASH|timed out" -- "$_ENV" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_SLEEP=3" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1" "$BASH_BIN" "$SB/decode.sh" @SUT@
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
