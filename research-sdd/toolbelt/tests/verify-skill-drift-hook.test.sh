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
#   F  kit-degraded-admitted   regex admits `kit status=degraded` → every tarball/no-upstream kit warns each session
#   G  timeout-removed         the `timeout` wrapper removed → a hung install --verify hangs session start
#   H  watchdog-no-kill        the pure-bash fallback never kills the hung run → no 'timed out' (no-timeout-binary path)
#   J  watchdog-137-as-timeout the watchdog sentinel replaced by "any rc>=128" -> a real exit 137 reads as 'timed out'
#   K  timeout-pipe-capture    the timeout path captured via command substitution -> a stalled grandchild defeats the bound
#   M  timeout-137-as-timeout  137 mapped to 124 on the timeout path -> a real exit 137 reads as 'timed out'
#   N  no-mktemp-skip          mktemp failing with timeout present skips instead of running bounded
#   O  trap-after-sleeper      watchdog TERM trap installed after the sleeper starts -> early kill orphans it
#   L  sleeper-not-killed      the watchdog sleeper outlives a fast finish -> a stray sleep per session
#   Q  vt-unvalidated          the timeout value reaches $(( )) -> command substitution runs at session start
#   R  bound-too-short         the poll bound shrinks below vt -> a verify within the bound reads as timed out
#   S  watchdog-leaked         the watchdog subshell survives a fast finish (checked again after 1 s)
#   I  skip-silent             the "skipped: no timeout available" branch removed → an unbounded/unreported run
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
# A grandchild that inherits stdout and outlives the stub (git rev-list / a hashing pipe on a slow FS).
[ -z "${STUB_VERIFY_GRANDCHILD:-}" ] || sleep "$STUB_VERIFY_GRANDCHILD" &
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
# PATH shim providing `timeout` (GNU semantics: optional -k N, rc 124 on expiry) so the timeout path is
# pinned on every platform, including hosts without the binary. Kills only its direct child, like the real one.
SHIM="$ROOT/shim"; mkdir -p "$SHIM"
cat > "$SHIM/timeout" <<'EOS'
#!/usr/bin/env bash
[ "${1:-}" = "-k" ] && shift 2
d="$1"; shift
"$@" & p=$!
fl="${TMPDIR:-/tmp}/shim-timeout-fired.$$"; rm -f "$fl"
( sleep "$d"; : >"$fl"; kill "$p" 2>/dev/null ) >/dev/null 2>&1 & w=$!
wait "$p"; rc=$?
kill "$w" 2>/dev/null
if [ -e "$fl" ]; then rm -f "$fl"; exit 124; fi
exit "$rc"
EOS
chmod +x "$SB"/*.sh "$SHIM/timeout"
SHIMPATH="$SHIM:$PATH"
# mktemp that always fails (plus the timeout shim): the hook must still run bounded, not skip.
SHIM2="$ROOT/shim2"; mkdir -p "$SHIM2"; cp "$SHIM/timeout" "$SHIM2/timeout"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM2/mktemp"; chmod +x "$SHIM2/mktemp" "$SHIM2/timeout"
SHIM2PATH="$SHIM2:$PATH"
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
HOUT_T="$(PATH="$SHIMPATH" STUB_VERIFY_SLEEP=5 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
grep -q 'timed out' <<<"$HOUT_T" && ok "H4c: a hung install --verify is cut off and reported (typed 'timed out'; timeout binary when present)" || no "H4c: hung --verify not bounded/reported; out=[$HOUT_T]"
HOUT_W="$(STUB_VERIFY_SLEEP=5 RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
grep -q 'timed out' <<<"$HOUT_W" && ok "H4c2: pure-bash watchdog path (no timeout binary) also cuts off and reports a hung --verify" || no "H4c2: watchdog path did not bound/report; out=[$HOUT_W]"
# Stalled grandchild holding stdout: the bound must still hold on BOTH paths (timeout ~1 s + slack).
for _path in timeout watchdog; do
  _nb=""; [ "$_path" = watchdog ] && _nb=1
  _s=$SECONDS
  HOUT_G="$(PATH="$SHIMPATH" RESEARCH_SDD_NO_TIMEOUT_BIN="$_nb" STUB_VERIFY_SLEEP=30 STUB_VERIFY_GRANDCHILD=6 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
  _e=$((SECONDS - _s))
  if [ "$_e" -le 4 ] && grep -q 'timed out' <<<"$HOUT_G"; then ok "H4e($_path): stalled grandchild holding stdout -> hook returns in ${_e}s, reported 'timed out'"
  else no "H4e($_path): bound not enforced (elapsed ${_e}s) out=[$HOUT_G]"; fi
done
# A real exit 137 from install is not a kill by the bound (any timeout value, including 1).
for _path in timeout watchdog; do
  _nb=""; [ "$_path" = watchdog ] && _nb=1
  HOUT_R="$(PATH="$SHIMPATH" RESEARCH_SDD_NO_TIMEOUT_BIN="$_nb" RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1 STUB_VERIFY_RC=137 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
  grep -q 'exited 137 with no typed line' <<<"$HOUT_R" && ! grep -q 'timed out' <<<"$HOUT_R" && ok "H4f($_path): real exit 137 from install is reported as an exit, not 'timed out'" || no "H4f($_path): 137 misread; out=[$HOUT_R]"
done
# timeout present but mktemp failing: still a bounded run that reports findings, with a typed note.
HOUT_M="$(PATH="$SHIM2PATH" STUB_VERIFY_OUT="$BEHIND" RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
grep -q 'status=behind' <<<"$HOUT_M" && grep -q 'not bounded' <<<"$HOUT_M" && ! grep -q skipped <<<"$HOUT_M" && ok "H4i: mktemp failing with timeout present → bounded run still reports findings (+ typed grandchild note)" || no "H4i: mktemp failure regressed; out=[$HOUT_M]"
HOUT_M2="$(PATH="$SHIM2PATH" STUB_VERIFY_SLEEP=5 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
grep -q 'timed out' <<<"$HOUT_M2" && ok "H4i2: mktemp failing with timeout present → hung --verify still bounded" || no "H4i2: not bounded without mktemp; out=[$HOUT_M2]"
# Fast finish leaves no descendant of the hook behind: a uniquely named hook copy is greppable, and the check is repeated
# after 1 s (a leaked watchdog subshell polls for up to vt seconds; one that dies within the first check is no leak).
if command -v pgrep >/dev/null 2>&1; then
  HOOK_U="$SB/verify-skill-drift-hook.leak-1759.sh"; cp "$HOOK" "$HOOK_U"
  for _i in $(seq 10); do
    RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=30 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$HOOK_U" >/dev/null 2>&1
  done
  _l1="$(pgrep -f 'verify-skill-drift-hook.leak-1759.sh' 2>/dev/null | wc -l)"; sleep 1
  _l2="$(pgrep -f 'verify-skill-drift-hook.leak-1759.sh' 2>/dev/null | wc -l)"
  if [ "$_l1" = 0 ] && [ "$_l2" = 0 ]; then ok "H4g: no descendant of the hook survives 10 fast finishes (checked at 0 s and +1 s)"
  else no "H4g: hook descendants survive a fast finish (now=$_l1 after1s=$_l2)"; pkill -f 'verify-skill-drift-hook.leak-1759.sh' 2>/dev/null; fi
  # The watchdog is now a polling subshell of the hook itself (no separate sleeper): none may outlive a fast finish.
  _left=0; for _p in $(pgrep -f "$HOOK_SB" 2>/dev/null); do [ "$_p" = "$$" ] || _left=$((_left+1)); done
  if [ "$_left" = 0 ]; then ok "H4j: no watchdog subshell survives 20 fast finishes"; else no "H4j: $_left process(es) still running the hook after 20 fast finishes"; pkill -f "$HOOK_SB" 2>/dev/null; fi
fi
# RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT is validated before any arithmetic: invalid -> default 10 s + a typed note, never evaluated.
for _path in timeout watchdog; do
  _nb=""; [ "$_path" = watchdog ] && _nb=1
  for _v in '' '.5' '10s' '1m' '0' '-3' '1234567' 'a[$(touch '"$ROOT"'/vt-pwned)]'; do
    HOUT_V="$(PATH="$SHIMPATH" RESEARCH_SDD_NO_TIMEOUT_BIN="$_nb" RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT="$_v" STUB_VERIFY_OUT="$BEHIND" RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>&1)"
    if grep -q 'verify: invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=.*using 10s' <<<"$HOUT_V" && grep -q 'status=behind' <<<"$HOUT_V" && ! grep -qE 'syntax error|operand' <<<"$HOUT_V"; then ok "H4l($_path): invalid timeout [$_v] -> default + typed note, findings kept"
    else no "H4l($_path): invalid timeout [$_v] mishandled; out=[$HOUT_V]"; fi
  done
  [ ! -e "$ROOT/vt-pwned" ] && ok "H4m($_path): a command-substitution timeout value is never executed" || no "H4m($_path): command substitution in the timeout value was EXECUTED"
  HOUT_V="$(PATH="$SHIMPATH" RESEARCH_SDD_NO_TIMEOUT_BIN="$_nb" RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=007 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>&1)"
  [ -z "$HOUT_V" ] && ok "H4n($_path): zero-padded decimal '007' is valid (not octal, no note)" || no "H4n($_path): '007' rejected; out=[$HOUT_V]"
done
# Deadline granularity: a verify taking ~vt-0.3 s with vt=1 must never be reported timed out (SECONDS-based deadlines could).
_ft=0
for _i in $(seq 10); do
  HOUT_Q="$(RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1 STUB_VERIFY_SLEEP=0.7 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
  grep -q 'timed out' <<<"$HOUT_Q" && _ft=$((_ft+1))
done
[ "$_ft" = 0 ] && ok "H4o: a 0.7 s verify under a 1 s bound is never reported timed out (10 runs)" || no "H4o: $_ft/10 false timeouts"
# After a NORMAL finish the EXIT trap must signal nothing (both children were reaped; their pids may be reused). A
# `kill` function exported into the hook records every call.
KLOG="$ROOT/kill.log"; : >"$KLOG"
KLOG="$KLOG" RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" -c 'kill() { printf "%s\n" "$*" >>"$KLOG"; builtin kill "$@"; }; export -f kill; exec bash "$1"' _ "$HOOK_SB" >/dev/null 2>&1
if [ ! -s "$KLOG" ]; then ok "H4k: no signal is sent after a normal finish (EXIT trap does not touch reaped pids)"; else no "H4k: kill called after normal finish: $(tr '\n' ';' <"$KLOG")"; fi
# An inherited extra_skip must not force the skip path.
HOUT_X="$(extra_skip=1 STUB_VERIFY_OUT="$BEHIND" RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
grep -q 'status=behind' <<<"$HOUT_X" && ! grep -q skipped <<<"$HOUT_X" && ok "H4h: inherited extra_skip env does not force the skip path" || no "H4h: env extra_skip leaked; out=[$HOUT_X]"
run_hook 0 0 "$BEHIND"
HOUT_N="$(RESEARCH_SDD_NO_TIMEOUT_BIN=1 STUB_VERIFY_OUT="$BEHIND" RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
grep -q 'status=behind' <<<"$HOUT_N" && ok "H4c3: watchdog path still returns the findings of a fast --verify" || no "H4c3: watchdog path lost the findings; out=[$HOUT_N]"
# No timeout binary AND no mktemp → never an unbounded run: a typed 'skipped' line.
NOMK="$ROOT/nomk"; mkdir -p "$NOMK"
for _t in dirname grep cut head cat jq rm sleep bash; do _p="$(command -v "$_t" 2>/dev/null)"; case "$_p" in /*) ln -sf "$_p" "$NOMK/$_t" ;; esac; done
HOUT_S="$(PATH="$NOMK" RESEARCH_SDD_NO_TIMEOUT_BIN=1 STUB_VERIFY_SLEEP=3 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
grep -q 'skipped: no timeout available' <<<"$HOUT_S" && ok "H4d: no timeout binary and no mktemp → typed 'skipped', never an unbounded run" || no "H4d: expected typed skip; out=[$HOUT_S]"

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
  _mk "G" "$SUT" "$MB/m-g.sh" 's/timeout "\$vt" "\$vcmd"/"$vcmd"/' \
    && _tt "teeth: timeout wrapper removed → a hung --verify hangs session start (observed via wall-clock cap)" 0 0 "$MB/m-g.sh" \
       --good-has 'timed out' --bad-lacks "$_CRASH|timed out" -- "$_ENV" "PATH=$SHIMPATH" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_SLEEP=3" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1" "$BASH_BIN" "$SB/decode.sh" @SUT@
  _mk "H" "$SUT" "$MB/m-h.sh" 's/: >"\$vf.fired"; \[ -e "\$vf.done" \] || kill "\$vpid" 2>\/dev\/null;/:;/' \
    && _tt "teeth: watchdog never kills the hung run → the no-timeout-binary path is unbounded and silent" 0 0 "$MB/m-h.sh" \
       --good-has 'timed out' --bad-lacks "$_CRASH|timed out" -- "$_ENV" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_SLEEP=3" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1" "$BASH_BIN" "$SB/decode.sh" @SUT@
  _mk "J" "$SUT" "$MB/m-j.sh" 's/if \[ -e "\$vf.fired" \]; then/if [ "$vrc" -ge 128 ]; then/' \
    && _tt "teeth: sentinel replaced by rc>=128 -> a real exit 137 reads as a timeout" 0 0 "$MB/m-j.sh" \
       --good-has 'exited 137' --bad-lacks "$_CRASH|exited 137" -- "$_ENV" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_RC=137" "$BASH_BIN" "$SB/decode.sh" @SUT@
  _mk "K" "$SUT" "$MB/m-k.sh" 's|^      timeout "\$vt" "\$vcmd" --verify </dev/null >"\$vf" 2>&1; vrc=\$?|      vout="$(timeout "$vt" "$vcmd" --verify 2>\&1)"; vrc=$?; echo "$vout" >"$vf"|' \
    && _tt "teeth: timeout path captured via command substitution -> a stalled grandchild defeats the bound" 0 0 "$MB/m-k.sh" \
       --good-has '^fast$' --bad-has '^slow$' --bad-lacks "$_CRASH" -- "$_ENV" "PATH=$SHIMPATH" "STUB_VERIFY_SLEEP=30" "STUB_VERIFY_GRANDCHILD=8" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" \
       "$BASH_BIN" -c 's=$SECONDS; bash "$1" "$2" >/dev/null 2>&1; [ $((SECONDS - s)) -le 4 ] && echo fast || echo slow' _ "$SB/decode.sh" @SUT@
  _mk "M" "$SUT" "$MB/m-m.sh" 's/\(timeout "\$vt" "\$vcmd" --verify <\/dev\/null >"\$vf" 2>&1; vrc=\$?\)/\1; [ "$vrc" -eq 137 ] \&\& vrc=124/' \
    && _tt "teeth: 137 mapped to a timeout on the timeout path -> a real exit 137 reads as 'timed out'" 0 0 "$MB/m-m.sh" \
       --good-has 'exited 137' --bad-lacks "$_CRASH|exited 137" -- "$_ENV" "PATH=$SHIMPATH" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_RC=137" "$BASH_BIN" "$SB/decode.sh" @SUT@
  _mk "N" "$SUT" "$MB/m-n.sh" 's/^      vnote=.*$/      extra_skip=1/' \
    && _tt "teeth: no-mktemp fallback replaced by a skip -> findings lost when mktemp fails but timeout exists" 0 0 "$MB/m-n.sh" \
       --good-has 'status=behind' --bad-lacks "$_CRASH|status=behind" -- "$_ENV" "PATH=$SHIM2PATH" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_OUT=$BEHIND" "$BASH_BIN" "$SB/decode.sh" @SUT@
  # The lost-signal race (#1759) cannot be forced from outside, so teeth O and P pin the DESIGN statically (the mutants are
  # the same file with the pinned line changed): the done marker must be written BEFORE the watchdog is waited for, and the
  # watchdog must re-check it immediately before signalling the verify pid.
  _mk "O" "$SUT" "$MB/m-o.sh" '/^    : >"\$vf.done"/d' \
    && _tt "teeth: done marker not written before waiting on the watchdog -> the watchdog is never told to stop" 0 0 "$MB/m-o.sh" \
       --good-has '^order-ok$' --bad-has '^order-bad$' --bad-lacks "$_CRASH" -- "$_ENV" \
       "$BASH_BIN" -c 'd=$(grep -n "SENTINEL-VERIFY-DONE" "$1" | cut -d: -f1); w=$(grep -n "^    wait .[$]wpid" "$1" | cut -d: -f1); if [ -n "$d" ] && [ -n "$w" ] && [ "$d" -lt "$w" ]; then echo order-ok; else echo order-bad; fi' _ @SUT@
  _mk "P" "$SUT" "$MB/m-p.sh" 's/ \[ -e "\$vf.done" \] || kill "\$vpid"/ kill "$vpid"/' \
    && _tt "teeth: no done re-check before signalling the verify pid -> a just-reaped pid can be signalled" 0 0 "$MB/m-p.sh" \
       --good-has '^recheck-ok$' --bad-has '^recheck-bad$' --bad-lacks "$_CRASH" -- "$_ENV" \
       "$BASH_BIN" -c 'if grep -qF "[ -e \"\$vf.done\" ] || kill" "$1"; then echo recheck-ok; else echo recheck-bad; fi' _ @SUT@
  # M: pid variables not cleared after their wait -> the EXIT trap signals reaped pids (observed through the kill recorder).
  _mk "M" "$SUT" "$MB/m-m2.sh" 's/; vpid=""$//;s/; wpid=""$//' \
    && _tt "teeth: pid vars not cleared after wait -> EXIT trap signals reaped pids" 0 0 "$MB/m-m2.sh" \
       --good-has '^no-kill$' --bad-has '^killed$' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "KLOG=$ROOT/kill-m.log" \
       "$BASH_BIN" -c ': >"$KLOG"; kill() { printf "%s\n" "$*" >>"$KLOG"; builtin kill "$@"; }; export -f kill; bash "$1" >/dev/null 2>&1; if [ -s "$KLOG" ]; then echo killed; else echo no-kill; fi' _ @SUT@
  if command -v pgrep >/dev/null 2>&1; then
    # L: watchdog never told to stop and never killed -> a polling subshell outlives a fast finish (until its deadline).
    _mk "L" "$SUT" "$MB/m-l.sh" 's/^    : >"\$vf.done".*$/    :/;s/^    wait "\$wpid" 2>\/dev\/null; wpid=""$/    :/;s/\[ -n "\$wpid" \] \&\& kill "\$wpid" 2>\/dev\/null; //' \
      && _tt "teeth: watchdog neither stopped nor killed -> a polling subshell outlives a fast finish" 0 0 "$MB/m-l.sh" \
         --good-has '^clean$' --bad-has '^leaked$' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=86312" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" \
         "$BASH_BIN" -c 'bash "$1" >/dev/null 2>&1; n=0; for p in $(pgrep -f "$1"); do [ "$p" = "$$" ] || { n=$((n+1)); kill "$p"; }; done; if [ "$n" -gt 0 ]; then echo leaked; else echo clean; fi' _ @SUT@
  fi
  # Q: validation neutralised -> the timeout value reaches arithmetic and executes a command substitution.
  _mk "Q" "$SUT" "$MB/m-q.sh" 's/\*\[!0-9\]\*|???????\*) vt="" ;;/__never__) vt="" ;;/;s/vt="\$((10#\$RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT))"; \[ "\$vt" -ge 1 \] || vt=""/vt="$RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"; vmax=$((vt * 10))/' \
    && _tt "teeth: timeout value unvalidated -> command substitution executes at session start" 0 0 "$MB/m-q.sh" \
       --good-has '^safe$' --bad-has '^pwned$' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "PW=$ROOT/vt-pwned-q" \
       "$BASH_BIN" -c 'rm -f "$PW"; RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT="a[\$(touch $PW)]" bash "$1" >/dev/null 2>&1; if [ -e "$PW" ]; then echo pwned; else echo safe; fi' _ @SUT@
  # R: bound shorter than vt -> a verify finishing inside the bound can be reported timed out.
  _mk "R" "$SUT" "$MB/m-r.sh" 's/vmax=\$((vt \* 10))/vmax=$((vt * 4))/' \
    && _tt "teeth: bound shorter than vt -> a verify within the bound is reported timed out" 0 0 "$MB/m-r.sh" \
       --good-has '^0$' --bad-lacks "$_CRASH|^0$" -- "$_ENV" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1" "STUB_VERIFY_SLEEP=0.7" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" \
       "$BASH_BIN" -c 'bash "$1" "$2" 2>/dev/null | grep -c "timed out"; :' _ "$SB/decode.sh" @SUT@
  if command -v pgrep >/dev/null 2>&1; then
    # S: the watchdog subshell is leaked after a fast finish (done marker never written, never waited, never killed).
    _mk "S" "$SUT" "$MB/m-s.sh" 's/^    : >"\$vf.done".*$/    :/;s/^    wait "\$wpid" 2>\/dev\/null; wpid=""$/    :/;s/\[ -n "\$wpid" \] \&\& kill "\$wpid" 2>\/dev\/null; //' \
      && _tt "teeth: leaked watchdog subshell is a surviving descendant after +1 s" 0 0 "$MB/m-s.sh" \
         --good-has '^clean$' --bad-has '^leaked$' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=30" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" \
         "$BASH_BIN" -c 'bash "$1" >/dev/null 2>&1; sleep 1; n=0; for p in $(pgrep -f "$1"); do [ "$p" = "$$" ] || { n=$((n+1)); kill "$p"; }; done; if [ "$n" -gt 0 ]; then echo leaked; else echo clean; fi' _ @SUT@
  fi
  _mk "I" "$SUT" "$MB/m-i.sh" 's/^    extra_skip=1 /    : /' \
    && _tt "teeth: skip branch unreported → with no timeout and no mktemp the hook says nothing" 0 0 "$MB/m-i.sh" \
       --good-has 'skipped: no timeout available' --bad-lacks "$_CRASH|skipped" -- "$_ENV" "PATH=$NOMK" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_SLEEP=1" "$BASH_BIN" "$SB/decode.sh" @SUT@
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
