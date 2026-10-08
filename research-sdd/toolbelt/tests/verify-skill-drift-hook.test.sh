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
#   M  timeout-137-as-timeout  137 mapped to 124 on the timeout path -> a real exit 137 reads as 'timed out' (a second M
#                              mutant: pid vars not cleared after their wait -> the EXIT trap signals reaped pids)
#   N  no-mktemp-skip          mktemp failing with timeout present skips instead of running bounded
#   O  done-marker-order       the done marker is not written before waiting on the watchdog -> it is never told to stop
#   P  no-done-recheck         the watchdog signals the verify pid without re-checking the done marker -> a reaped pid is signalled
#   L  watchdog-not-stopped    watchdog neither told to stop, waited for, nor killed -> a polling subshell outlives a fast finish (pgrep, no wait)
#   Q  vt-unvalidated          the timeout value reaches $(( )) -> command substitution runs at session start
#   R  bound-too-short         the poll bound shrinks below vt -> a verify within the bound reads as timed out
#   S  watchdog-not-reaped     the done marker IS written but the hook neither waits for nor kills the watchdog -> it is still
#                              running when the hook returns (pid-recording `sleep` shim, `kill -0` after return; distinct from L)
#   T  probe-rc-dropped        the fractional-sleep probe ignores sleep's exit status -> a sleep rejecting 0.1 kills a healthy verify
#   V  probe-always-falls-back the probe threshold is unreachable -> a working fractional sleep silently loses the 0.1 s poll
#   U  probe-elapsed-dropped   the probe ignores elapsed time -> a sleep that accepts 0.1 but returns at once kills a healthy verify
#   W  probe-single-sample     the probe takes ONE elapsed sample -> a load-inflated sample on a sleep that returns at once kills a healthy verify (#1978)
#   I  skip-silent             the "skipped: no timeout available" branch removed → an unbounded/unreported run
#
# Usage: verify-skill-drift-hook.test.sh [--prove-teeth]
# Exit: 0 = all held · 1 = regression

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../verify-skill-drift-hook.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found: $HOOK" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

# The elapsed half of the hook's sleep probe (and H4o's early-kill check) needs $EPOCHREALTIME (bash 5+) in the bash under test.
HAVE_ERT=""; [ -n "$("$BASH_BIN" -c 'printf %s "${EPOCHREALTIME:-}"' 2>/dev/null)" ] && HAVE_ERT=1
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Sandbox: the hook copy + a stub drift script (rc/out from env) + a stub install --verify (rc/out from env).
SB="$ROOT/sb"; mkdir -p "$SB"
cp "$HOOK" "$SB/verify-skill-drift-hook.sh"
mkdir -p "$SB/lib" && cp "$HERE/../lib/hook-emit.sh" "$SB/lib/hook-emit.sh"   # the hook (and its HOOK_U copy) source lib/hook-emit.sh beside themselves (#1877)
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
# Stalled grandchild holding stdout: the bound must still hold on BOTH paths. The property is "the hook does not wait for the
# grandchild" (20 s), not an absolute 4 s: this WSL host stalls ANY timed wait (sleep, `read -t`, no fork involved) for ~3.7 s about
# once per ~250 waits (#1770), so a tight bound flaked ~3%. The ceiling is the 1 s timeout + that measured stall, doubled for margin.
# Ceiling = vt (1 s) + 2 x the longest stall measured on this host (3.7 s, #1770) + 1.6 s of process-start slack = 10 s; it must stay
# well under the 20 s grandchild, which is what the defect would wait for (tooth K reuses H4E_MAX).
H4E_MAX=10
for _path in timeout watchdog; do
  _nb=""; [ "$_path" = watchdog ] && _nb=1
  _s=$SECONDS
  HOUT_G="$(PATH="$SHIMPATH" RESEARCH_SDD_NO_TIMEOUT_BIN="$_nb" STUB_VERIFY_SLEEP=30 STUB_VERIFY_GRANDCHILD=20 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
  _e=$((SECONDS - _s))
  if [ "$_e" -le "$H4E_MAX" ] && grep -q 'timed out' <<<"$HOUT_G"; then ok "H4e($_path): stalled grandchild holding stdout -> hook returns in ${_e}s, reported 'timed out'"
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
# after 1 s = one integer-fallback poll (a leaked watchdog subshell polls for up to vt seconds; one that dies within the first check
# is no leak). The hook waits for its watchdog, so the real hook leaves nothing at +0 s; the +1 s recheck catches a slow death.
if command -v pgrep >/dev/null 2>&1; then
  HOOK_U="$SB/verify-skill-drift-hook.leak-1759.sh"; cp "$HOOK" "$HOOK_U"
  # Decoy (#1978): a process of ANOTHER checkout/suite instance whose command line carries the same basename. The probes below
  # match the FULL sandbox path ($HOOK_U, unique per run), so a concurrent run of this suite (parallel gate, second session)
  # is invisible to them; matching the bare basename counted its processes as leaks (and pkill'd them).
  DECOY_DIR="$ROOT/decoy"; mkdir -p "$DECOY_DIR"
  ( exec -a "$DECOY_DIR/verify-skill-drift-hook.leak-1759.sh" "$BASH_BIN" -c 'sleep 30' ) >/dev/null 2>&1 & DECOY_PID=$!
  for _i in $(seq 10); do
    RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=30 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$HOOK_U" >/dev/null 2>&1
  done
  _l1="$(pgrep -f "$HOOK_U" 2>/dev/null | wc -l)"; sleep 1
  _l2="$(pgrep -f "$HOOK_U" 2>/dev/null | wc -l)"
  if [ "$_l1" = 0 ] && [ "$_l2" = 0 ]; then ok "H4g: no descendant of the hook copy survives 10 fast finishes (checked at 0 s and +1 s; a same-basename process elsewhere is not counted)"
  else no "H4g: hook descendants survive a fast finish (now=$_l1 after1s=$_l2) :: $(pgrep -af "$HOOK_U" 2>/dev/null | cut -c1-200 | tr '\n' ';')"; pkill -f "$HOOK_U" 2>/dev/null; fi
  kill "$DECOY_PID" 2>/dev/null; wait "$DECOY_PID" 2>/dev/null
  # The watchdog is now a polling subshell of the hook itself (no separate sleeper): none may outlive a fast finish.
  for _i in $(seq 10); do
    RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=30 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$HOOK_SB" >/dev/null 2>&1
  done
  _left=0; for _p in $(pgrep -f "$HOOK_SB" 2>/dev/null); do [ "$_p" = "$$" ] || _left=$((_left+1)); done
  if [ "$_left" = 0 ]; then ok "H4j: no watchdog subshell of the sandbox hook survives 10 fast finishes"; else no "H4j: $_left process(es) still running the hook after 10 fast finishes :: $(pgrep -af "$HOOK_SB" 2>/dev/null | cut -c1-200 | tr '\n' ';')"; pkill -f "$HOOK_SB" 2>/dev/null; fi
fi
# RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT is validated before any arithmetic: invalid -> default 10 s + a typed note, never evaluated.
for _path in timeout watchdog; do
  _nb=""; [ "$_path" = watchdog ] && _nb=1
  for _v in '' '.5' '10s' '1m' '0' '-3' '1234567' 'a[$(touch '"$ROOT"'/vt-pwned)]'; do
    HOUT_V="$(PATH="$SHIMPATH" RESEARCH_SDD_NO_TIMEOUT_BIN="$_nb" RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT="$_v" STUB_VERIFY_OUT="$BEHIND" RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>&1)"
    case "$_v" in '') _vre='verify: invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT (empty), using 10s' ;; *) _vre='verify: invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=.*using 10s' ;; esac
    if grep -q "$_vre" <<<"$HOUT_V" && grep -q 'status=behind' <<<"$HOUT_V" && ! grep -qE 'syntax error|operand' <<<"$HOUT_V"; then ok "H4l($_path): invalid timeout [$_v] -> default + typed note, findings kept"
    else no "H4l($_path): invalid timeout [$_v] mishandled; out=[$HOUT_V]"; fi
  done
  [ ! -e "$ROOT/vt-pwned" ] && ok "H4m($_path): a command-substitution timeout value is never executed" || no "H4m($_path): command substitution in the timeout value was EXECUTED"
  HOUT_V="$(PATH="$SHIMPATH" RESEARCH_SDD_NO_TIMEOUT_BIN="$_nb" RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=007 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>&1)"
  [ -z "$HOUT_V" ] && ok "H4n($_path): zero-padded decimal '007' is valid (not octal, no note)" || no "H4n($_path): '007' rejected; out=[$HOUT_V]"
done
# Deadline granularity: a verify taking ~vt-0.3 s with vt=1 must never be reported timed out EARLY (SECONDS-based deadlines could).
# "Early" is measured, not assumed: on this host a timed wait occasionally stalls ~3.7 s (#1770), so the 0.7 s stub can itself run past
# the 1 s bound and then 'timed out' is correct. A false timeout is therefore a 'timed out' reported while the hook's own wall time
# was still under the 1 s bound (nothing could legitimately have expired). Measured over 200 runs: wall p50 724 ms, p95 758 ms.
# Without $EPOCHREALTIME the wall time is unavailable and any 'timed out' counts (the old, stricter assertion).
_ft=0
for _i in $(seq 10); do
  _t0="${EPOCHREALTIME:-0}"
  HOUT_Q="$(RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1 STUB_VERIFY_SLEEP=0.7 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
  _t1="${EPOCHREALTIME:-0}"
  if grep -q 'timed out' <<<"$HOUT_Q"; then
    if [ -z "$HAVE_ERT" ] || [ $(( ${_t1//[.,]/} - ${_t0//[.,]/} )) -lt 1000000 ]; then _ft=$((_ft+1)); fi
  fi
done
[ "$_ft" = 0 ] && ok "H4o: a 0.7 s verify under a 1 s bound is never reported timed out before the bound elapsed (10 runs)" || no "H4o: $_ft/10 timeouts reported before the 1 s bound elapsed"
# Fractional-sleep probe (#1771): a `sleep` that cannot do fractions must not make the watchdog burn its whole count at once.
# Shim A rejects fractions at once (exit 2, like a POSIX-only sleep); shim B accepts them but returns at once (rc 0); shim C
# rejects them only on the FIRST FIVE calls per caller PID (each after a real 0.1 s, so every elapsed sample of the probe passes) and at once
# afterwards: only the exit-status half of the probe can catch it (tooth T). The mark is keyed on the caller's PPID, and PIDs get
# reused between two runs, so tooth T clears $SHIMC/mark.* inside its own command: before EVERY run (good and mutant), never once.
REALSLEEP="$(command -v sleep)"
SHIMA="$ROOT/shimA"; SHIMB="$ROOT/shimB"; SHIMC="$ROOT/shimC"; mkdir -p "$SHIMA" "$SHIMB" "$SHIMC"
printf '#!/usr/bin/env bash\ncase "${1:-}" in *[!0-9]*) echo "sleep: invalid time interval" >&2; exit 2 ;; esac\nexec %s "$@"\n' "$REALSLEEP" > "$SHIMA/sleep"
printf '#!/usr/bin/env bash\ncase "${1:-}" in *[!0-9]*) exit 0 ;; esac\nexec %s "$@"\n' "$REALSLEEP" > "$SHIMB/sleep"
printf '#!/usr/bin/env bash\ncase "${1:-}" in *[!0-9]*) n=0; for m in 1 2 3 4 5; do [ -e "%s/mark.$PPID.$m" ] && n=$m; done; if [ "$n" -lt 5 ]; then : >"%s/mark.$PPID.$((n+1))"; %s 0.1; fi; echo "sleep: invalid time interval" >&2; exit 2 ;; esac\nexec %s "$@"\n' "$SHIMC" "$SHIMC" "$REALSLEEP" "$REALSLEEP" > "$SHIMC/sleep"
chmod +x "$SHIMA/sleep" "$SHIMB/sleep" "$SHIMC/sleep"
# The elapsed half of the probe needs $EPOCHREALTIME (bash 5+); on an older BASH_BIN shim B is undetectable by design, so it is
# a typed SKIP (never silent) there. Shim A (rejects fractions) is caught by the exit-status half on every bash.
for _sh in A B; do
  if [ "$_sh" = B ] && [ -z "$HAVE_ERT" ]; then printf '  SKIP  H4p(B)/H4q(B): %s has no EPOCHREALTIME, the elapsed half of the probe cannot run\n' "$BASH_BIN"; continue; fi
  case "$_sh" in A) _pp="$SHIMA" ;; *) _pp="$SHIMB" ;; esac
  HOUT_P="$(PATH="$_pp:$PATH" RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=3 STUB_VERIFY_SLEEP=1 STUB_VERIFY_OUT="$BEHIND" RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
  grep -q 'status=behind' <<<"$HOUT_P" && ! grep -q 'timed out' <<<"$HOUT_P" && ok "H4p($_sh): fraction-less sleep -> a 1 s verify under a 3 s bound is not killed" || no "H4p($_sh): healthy verify killed by the watchdog; out=[$HOUT_P]"
  HOUT_P="$(PATH="$_pp:$PATH" RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1 STUB_VERIFY_SLEEP=5 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
  grep -q 'timed out' <<<"$HOUT_P" && ok "H4q($_sh): fraction-less sleep -> a hung verify is still cut off and reported (integer fallback)" || no "H4q($_sh): hung verify not bounded with a fraction-less sleep; out=[$HOUT_P]"
done
# Load robustness of the probe (#1978): a sleep that returns at once can still show a >=50 ms gap between the two $EPOCHREALTIME reads
# when the box is descheduling the probe (CPU contention), which a single sample reads as "fractions work" and the healthy verify
# is then killed by 30 instant polls. Shim E models exactly that: the FIRST FOUR fractional sleeps per caller PID take a real 0.1 s
# (so probe samples 1-4 are inflated, no luck needed), the fifth returns at once: the probe must keep sampling to the last. The mark is keyed
# on the caller's PPID and cleared before EVERY run (PID reuse), like shim C.
SHIME="$ROOT/shimE"; mkdir -p "$SHIME"
printf '#!/usr/bin/env bash\ncase "${1:-}" in *[!0-9]*) n=0; for m in 1 2 3 4; do [ -e "%s/mark.$PPID.$m" ] && n=$m; done; if [ "$n" -lt 4 ]; then : >"%s/mark.$PPID.$((n+1))"; %s 0.1; fi; exit 0 ;; esac\nexec %s "$@"\n' "$SHIME" "$SHIME" "$REALSLEEP" "$REALSLEEP" > "$SHIME/sleep"; chmod +x "$SHIME/sleep"
if [ -z "$HAVE_ERT" ]; then printf '  SKIP  H4p(E): %s has no EPOCHREALTIME, the elapsed half of the probe cannot run\n' "$BASH_BIN"
else
  rm -f "$SHIME"/mark.*
  HOUT_P="$(PATH="$SHIME:$PATH" RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=3 STUB_VERIFY_SLEEP=1 STUB_VERIFY_OUT="$BEHIND" RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" "$HOOK_SB" 2>/dev/null)"
  grep -q 'status=behind' <<<"$HOUT_P" && ! grep -q 'timed out' <<<"$HOUT_P" && ok "H4p(E): a sleep that returns at once but showed ONE slow probe sample (load) is still detected -> healthy verify not killed" || no "H4p(E): a single load-inflated probe sample fooled the probe; out=[$HOUT_P]"
fi
# A WORKING fractional sleep must KEEP the 0.1 s poll (otherwise every healthy session start silently gains up to 1 s). Shim D
# logs each sleep argument then runs the real sleep: the probe and the polls are '0.1', the integer fallback polls with '1'.
# Deterministic (no timing): the stub's own sleep is 0.3, so a '1' in the log can only come from the hook's fallback.
SHIMD="$ROOT/shimD"; mkdir -p "$SHIMD"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${1:-}" >>"$SLEEPLOG"\nexec %s "$@"\n' "$REALSLEEP" > "$SHIMD/sleep"; chmod +x "$SHIMD/sleep"
if [ -z "$HAVE_ERT" ]; then printf '  SKIP  H4r: %s has no EPOCHREALTIME, the probe cannot run\n' "$BASH_BIN"
else
  SLEEPLOG="$ROOT/sleep.log"; : >"$SLEEPLOG"
  SLEEPLOG="$SLEEPLOG" PATH="$SHIMD:$PATH" RESEARCH_SDD_NO_TIMEOUT_BIN=1 RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=3 STUB_VERIFY_SLEEP=0.3 RESEARCH_SDD_INSTALL_VERIFY_CMD="$SB/install-verify-stub.sh" "$BASH_BIN" "$HOOK_SB" >/dev/null 2>&1
  _n01="$(grep -cx '0.1' "$SLEEPLOG")"; _n1="$(grep -cx '1' "$SLEEPLOG")"
  [ "$_n01" -ge 2 ] && [ "$_n1" = 0 ] && ok "H4r: a working fractional sleep keeps the 0.1 s poll (probe + polls = $_n01 x '0.1', no integer fallback)" || no "H4r: poll period regressed (0.1 x $_n01, 1 x $_n1): $(tr '\n' ' ' <"$SLEEPLOG")"
fi
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
  SUT="$HOOK_SB"; MB="$ROOT/mb"; mkdir -p "$MB" "$MB/lib"; cp "$HERE/../lib/hook-emit.sh" "$MB/lib/hook-emit.sh"; cp "$SB/verify-skill-drift.sh" "$SB/install-verify-stub.sh" "$SB/decode.sh" "$MB/"   # mutants run beside their own stubs, NOT beside the SUT (mutant.sh refuses that)
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
       --good-has '^fast$' --bad-has '^slow$' --bad-lacks "$_CRASH" -- "$_ENV" "PATH=$SHIMPATH" "STUB_VERIFY_SLEEP=30" "STUB_VERIFY_GRANDCHILD=20" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" \
       "$BASH_BIN" -c 's=$SECONDS; bash "$2" "$3" >/dev/null 2>&1; [ $((SECONDS - s)) -le "$1" ] && echo fast || echo slow' _ "$H4E_MAX" "$SB/decode.sh" @SUT@
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
  _mk "R" "$SUT" "$MB/m-r.sh" 's/vmax=\$((vt \* vper))/vmax=$((vt * 4))/' \
    && _tt "teeth: bound shorter than vt -> a verify within the bound is reported timed out" 0 0 "$MB/m-r.sh" \
       --good-has '^0$' --bad-lacks "$_CRASH|^0$" -- "$_ENV" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=2" "STUB_VERIFY_SLEEP=1.8" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" \
       "$BASH_BIN" -c 'bash "$1" "$2" 2>/dev/null | grep -c "timed out"; :' _ "$SB/decode.sh" @SUT@
  # (R's verify takes 1.8 s under vt=2: the probe's five samples add 0.5 s before the poll count starts, so the mutant's 8 polls end at
  # ~1.3 s (0.5 s below the verify) while the real bound ends at ~2.5 s (0.7 s above it).)
  # S: the done marker IS written, but the hook neither waits for nor kills the watchdog (distinct from L, which also drops the marker).
  # The watchdog then notices the marker within one poll, i.e. AFTER the hook returned. Deterministic, no pgrep: shim S rejects the
  # 0.1 probe (so the watchdog polls with an integer `sleep 1`, still mid-poll when the 0.3 s verify ends) and records its caller's
  # pid, i.e. the watchdog subshell; afterwards `kill -0` says whether that pid outlived the hook. An empty log prints 'nolog' (never
  # a silent 'clean'). Measured on 200 runs: real hook 0 leaked, mutant 200 leaked, 0 empty logs.
  SHIMS="$ROOT/shimS"; mkdir -p "$SHIMS"
  printf '#!/usr/bin/env bash\n[ -z "${PIDLOG:-}" ] || echo "$PPID" >>"$PIDLOG"\ncase "${1:-}" in 0.1) exit 2 ;; esac\nexec %s "$@"\n' "$REALSLEEP" > "$SHIMS/sleep"; chmod +x "$SHIMS/sleep"
  _mk "S" "$SUT" "$MB/m-s.sh" 's/^    wait "\$wpid" 2>\/dev\/null; wpid=""$/    :/;s/\[ -n "\$wpid" \] \&\& kill "\$wpid" 2>\/dev\/null; //' \
    && _tt "teeth: watchdog stopped by marker but never reaped -> it is still running when the hook returns" 0 0 "$MB/m-s.sh" \
       --good-has '^clean$' --bad-has '^leaked$' --bad-lacks "$_CRASH" -- "$_ENV" "PATH=$SHIMS:$PATH" "PIDLOG=$ROOT/pids-s.log" "STUB_VERIFY_SLEEP=0.3" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=30" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" \
       "$BASH_BIN" -c ': >"$PIDLOG"; bash "$1" >/dev/null 2>&1; [ -s "$PIDLOG" ] || { echo nolog; exit 0; }; a=0; for p in $(sort -u "$PIDLOG"); do if kill -0 "$p" 2>/dev/null; then a=1; kill "$p" 2>/dev/null; fi; done; if [ "$a" = 1 ]; then echo leaked; else echo clean; fi' _ @SUT@
  # T/U: the fractional-sleep probe (#1771). T drops the exit-status half (shim C rejects fractions slowly), U the elapsed half (shim B returns at once).
  _mk "T" "$SUT" "$MB/m-t.sh" 's/sleep 0.1 2>\/dev\/null || { vsl=1; vper=1; }/sleep 0.1 2>\/dev\/null || :/' \
    && _tt "teeth: probe ignores sleep's exit status -> a sleep rejecting fractions kills a healthy verify" 0 0 "$MB/m-t.sh" \
       --good-has 'status=behind' --bad-lacks "$_CRASH|status=behind" -- "$_ENV" "PATH=$SHIMC:$PATH" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=3" "STUB_VERIFY_SLEEP=1" "STUB_VERIFY_OUT=$BEHIND" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "$BASH_BIN" -c 'rm -f "$1"/mark.*; exec bash "$2" "$3"' _ "$SHIMC" "$SB/decode.sh" @SUT@
  if [ -z "$HAVE_ERT" ]; then printf '  SKIP  teeth U: %s has no EPOCHREALTIME, the elapsed half of the probe cannot run\n' "$BASH_BIN"; else
  _mk "U" "$SUT" "$MB/m-u.sh" 's/\] || { vsl=1; vper=1; }   # SENTINEL-SLEEP-PROBE-ELAPSED/] || :/' \
    && _tt "teeth: probe ignores elapsed time -> a sleep that returns at once kills a healthy verify" 0 0 "$MB/m-u.sh" \
       --good-has 'status=behind' --bad-lacks "$_CRASH|status=behind" -- "$_ENV" "PATH=$SHIMB:$PATH" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=3" "STUB_VERIFY_SLEEP=1" "STUB_VERIFY_OUT=$BEHIND" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "$BASH_BIN" "$SB/decode.sh" @SUT@
  fi
  if [ -z "$HAVE_ERT" ]; then printf '  SKIP  teeth W: %s has no EPOCHREALTIME, the elapsed half of the probe cannot run\n' "$BASH_BIN"; else
  _mk "W" "$SUT" "$MB/m-w.sh" 's/for vn in 1 2 3 4 5; do/for vn in 5; do/' \
    && _tt "teeth: probe takes one elapsed sample -> a load-inflated sample on a sleep that returns at once kills a healthy verify" 0 0 "$MB/m-w.sh" \
       --good-has 'status=behind' --bad-lacks "$_CRASH|status=behind" -- "$_ENV" "PATH=$SHIME:$PATH" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=3" "STUB_VERIFY_SLEEP=1" "STUB_VERIFY_OUT=$BEHIND" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "$BASH_BIN" -c 'rm -f "$1"/mark.*; exec bash "$2" "$3"' _ "$SHIME" "$SB/decode.sh" @SUT@
  fi
  # V: probe always falls back (threshold unreachable) -> a working fractional sleep silently loses the 0.1 s poll.
  if [ -z "$HAVE_ERT" ]; then printf '  SKIP  teeth V: %s has no EPOCHREALTIME, the probe cannot run\n' "$BASH_BIN"; else
  _mk "V" "$SUT" "$MB/m-v.sh" 's/-ge 50000 \]/-ge 50000000000 ]/' \
    && _tt "teeth: probe always falls back -> a working fractional sleep loses the 0.1 s poll (every session start +<=1 s)" 0 0 "$MB/m-v.sh" \
       --good-has '^fractional$' --bad-has '^integer$' --bad-lacks "$_CRASH" -- "$_ENV" "SLEEPLOG=$ROOT/sleep-v.log" "PATH=$SHIMD:$PATH" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=3" "STUB_VERIFY_SLEEP=0.3" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" \
       "$BASH_BIN" -c ': >"$SLEEPLOG"; bash "$1" >/dev/null 2>&1; if grep -qx 1 "$SLEEPLOG"; then echo integer; else echo fractional; fi' _ @SUT@
  fi
  _mk "I" "$SUT" "$MB/m-i.sh" 's/^    extra_skip=1 /    : /' \
    && _tt "teeth: skip branch unreported → with no timeout and no mktemp the hook says nothing" 0 0 "$MB/m-i.sh" \
       --good-has 'skipped: no timeout available' --bad-lacks "$_CRASH|skipped" -- "$_ENV" "PATH=$NOMK" "RESEARCH_SDD_NO_TIMEOUT_BIN=1" "RESEARCH_SDD_INSTALL_VERIFY_CMD=$SB/install-verify-stub.sh" "STUB_VERIFY_SLEEP=1" "$BASH_BIN" "$SB/decode.sh" @SUT@
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
