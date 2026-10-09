#!/usr/bin/env bash
# Test suite for serial-frame-capture.sh (serial-frame.v1)
#
# All tests are OFFLINE: no hardware, no real serial port required.
# Live-path tests use a stub pyserial module injected via PYTHONPATH.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../serial-frame-capture.sh"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Build stub pyserial (all Serial opens raise SerialException — simulates no hardware)
mkdir -p "$ROOT/pystubs-fail"
cat > "$ROOT/pystubs-fail/serial.py" << 'STUBEOF'
class SerialException(Exception):
    pass

class Serial:
    def __init__(self, port, baud, **kwargs):
        raise SerialException(f"stub: cannot open {port} at baud {baud}")
STUBEOF

# Build stub pyserial for capture (delivers one short frame, then simulates gap)
mkdir -p "$ROOT/pystubs-capture"
cat > "$ROOT/pystubs-capture/serial.py" << 'STUBEOF'
import time as _time

class SerialException(Exception):
    pass

class Serial:
    """Stub that delivers one 3-byte frame then returns empty (to trigger gap-framing)."""
    def __init__(self, port, baud, **kwargs):
        self._reads = 0
        self.timeout = kwargs.get('timeout', 0.02)

    def read(self, n):
        self._reads += 1
        if self._reads == 1:
            return b'\x81\x00\x17'  # one 3-byte frame
        _time.sleep(0.15)           # gap > gap_ms (8ms default) to trigger framing
        return b''

    def close(self):
        pass
STUBEOF

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"

# ---------------------------------------------------------------------------
# T1: sweep without --allow-live-probe → exit 3 (plan-only guard)
# ---------------------------------------------------------------------------
"$SUT" sweep --port /dev/null --output "$ROOT/t1.json" 2>/dev/null
_t1_code=$?
if [ "$_t1_code" -eq 3 ]; then
  ok "T1 plan-only guard (sweep): exit 3 without --allow-live-probe"
else
  no "T1 plan-only guard: expected exit 3, got $_t1_code"
fi

# ---------------------------------------------------------------------------
# T2: plan-only JSON schema correct (sweep mode)
# ---------------------------------------------------------------------------
if python3 - "$ROOT/t1.json" <<'PY' 2>/dev/null
import json, sys, os
p = sys.argv[1]
assert os.path.exists(p), f"plan-only JSON not written at: {p}"
d = json.load(open(p))
assert d.get('schema') == 'serial-frame.v1', f"wrong schema: {d.get('schema')!r}"
assert d.get('status') == 'plan-only', f"expected plan-only, got: {d.get('status')!r}"
assert d.get('tool') == 'serial-frame-capture', f"wrong tool: {d.get('tool')!r}"
assert d.get('mode') == 'sweep', f"expected sweep, got: {d.get('mode')!r}"
guard = d.get('guard', '')
assert guard, "guard field must be non-empty"
plan = d.get('plan', {})
assert plan.get('port') == '/dev/null', f"port not in plan: {plan.get('port')!r}"
assert isinstance(plan.get('baud_rates'), list) and len(plan['baud_rates']) > 0, \
    "plan.baud_rates must be a non-empty list"
PY
then ok "T2 plan-only JSON schema: required fields present (sweep)"
else no "T2 plan-only JSON schema"; fi

# ---------------------------------------------------------------------------
# T3: capture without --allow-live-probe → exit 3 (plan-only guard)
# ---------------------------------------------------------------------------
"$SUT" capture --port /dev/null --baud 19200 --output "$ROOT/t3.json" 2>/dev/null
_t3_code=$?
if [ "$_t3_code" -eq 3 ]; then
  ok "T3 plan-only guard (capture): exit 3 without --allow-live-probe"
else
  no "T3 plan-only guard (capture): expected exit 3, got $_t3_code"
fi

# ---------------------------------------------------------------------------
# T4: plan-only capture JSON has correct plan fields
# ---------------------------------------------------------------------------
if python3 - "$ROOT/t3.json" <<'PY' 2>/dev/null
import json, sys, os
p = sys.argv[1]
assert os.path.exists(p), f"plan-only JSON not written at: {p}"
d = json.load(open(p))
assert d.get('schema') == 'serial-frame.v1'
assert d.get('status') == 'plan-only'
assert d.get('mode') == 'capture'
plan = d.get('plan', {})
assert plan.get('port') == '/dev/null'
assert plan.get('baud') == 19200, f"expected baud 19200, got {plan.get('baud')!r}"
assert isinstance(plan.get('seconds'), (int, float)), \
    f"plan.seconds must be numeric: {plan.get('seconds')!r}"
PY
then ok "T4 plan-only JSON schema: capture fields correct"
else no "T4 plan-only JSON schema (capture)"; fi

# ---------------------------------------------------------------------------
# T5: missing --port → non-zero exit (argparse error)
# ---------------------------------------------------------------------------
if ! "$SUT" sweep --output "$ROOT/t5.json" 2>/dev/null; then
  ok "T5 missing --port: non-zero exit"
else
  no "T5 missing --port: expected non-zero exit, got 0"
fi

# ---------------------------------------------------------------------------
# T6: missing --baud for capture → non-zero exit (argparse error)
# ---------------------------------------------------------------------------
if ! "$SUT" capture --port /dev/null --output "$ROOT/t6.json" 2>/dev/null; then
  ok "T6 missing --baud: non-zero exit"
else
  no "T6 missing --baud: expected non-zero exit, got 0"
fi

# ---------------------------------------------------------------------------
# T7: missing --output → non-zero exit (argparse error)
# ---------------------------------------------------------------------------
if ! "$SUT" sweep --port /dev/null 2>/dev/null; then
  ok "T7 missing --output: non-zero exit"
else
  no "T7 missing --output: expected non-zero exit, got 0"
fi

# ---------------------------------------------------------------------------
# T8: --allow-live-probe after subcommand (BLOCKER 4 fix) + sweep §7
#
# With the fix, --allow-live-probe is registered on each subparser so the
# documented usage "sweep --allow-live-probe" works. The stub causes all
# baud opens to fail → sweep §7 fix makes this exit 1 / status:failed.
# Asserts: no argparse "unrecognized arguments" error; exit 1; status:failed.
# ---------------------------------------------------------------------------
_t8_stderr="$ROOT/t8_stderr.txt"
_t8_exit=0
PYTHONPATH="$ROOT/pystubs-fail" "$SUT" sweep --port /dev/ttySTUB0 \
  --allow-live-probe --output "$ROOT/t8.json" 2>"$_t8_stderr" || _t8_exit=$?
if grep -q "unrecognized" "$_t8_stderr" 2>/dev/null; then
  no "T8 BLOCKER4: --allow-live-probe not accepted after subcommand: $(head -1 "$_t8_stderr")"
elif [ "$_t8_exit" -eq 1 ] && python3 - "$ROOT/t8.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"expected status:failed (sweep §7), got {d['status']!r}"
assert d.get('mode') == 'sweep', f"expected mode:sweep"
assert d.get('tool') == 'serial-frame-capture'
PY
then ok "T8 --allow-live-probe after subcommand + sweep §7: exit 1, status:failed"
else
  no "T8 flag position / sweep §7: expected exit 1 + status:failed, got exit $_t8_exit (stderr: $(head -1 "$_t8_stderr" 2>/dev/null || echo none))"
fi

# ---------------------------------------------------------------------------
# T8b: guard still active without --allow-live-probe (even with stub on PYTHONPATH)
# ---------------------------------------------------------------------------
_t8b_exit=0
PYTHONPATH="$ROOT/pystubs-fail" "$SUT" sweep --port /dev/ttySTUB0 \
  --output "$ROOT/t8b.json" 2>/dev/null || _t8b_exit=$?
if [ "$_t8b_exit" -eq 3 ] && python3 - "$ROOT/t8b.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'plan-only', f"expected plan-only, got {d['status']!r}"
PY
then ok "T8b guard: without --allow-live-probe, exits 3 plan-only (stub on PYTHONPATH irrelevant)"
else no "T8b guard: expected exit 3 + plan-only, got exit $_t8b_exit"; fi

# ---------------------------------------------------------------------------
# T9: capture --log produces text log; analyze reads it back (pipeline round-trip)
# Stub delivers one 3-byte frame; capture writes --log; analyze stats reads log.
# ---------------------------------------------------------------------------
_t9_cap_exit=0
PYTHONPATH="$ROOT/pystubs-capture" "$SUT" capture \
  --port /dev/ttySTUB0 --baud 19200 --seconds 0.5 \
  --allow-live-probe \
  --log "$ROOT/t9.log" \
  --output "$ROOT/t9_cap.json" 2>/dev/null || _t9_cap_exit=$?
if [ "$_t9_cap_exit" -eq 0 ] && [ -f "$ROOT/t9.log" ]; then
  # Run analyze on the captured log
  _t9_ana_exit=0
  "$HERE/../serial-frame-analyze.sh" stats \
    --input "$ROOT/t9.log" --output "$ROOT/t9_ana.json" 2>/dev/null || _t9_ana_exit=$?
  if [ "$_t9_ana_exit" -eq 0 ] && python3 - "$ROOT/t9_ana.json" "$ROOT/t9.log" <<'PY' 2>/dev/null
import json, sys
ana = json.load(open(sys.argv[1]))
assert ana['status'] == 'complete', f"analyze status must be complete, got {ana['status']!r}"
assert ana['summary']['frame_count'] >= 1, "at least 1 frame expected in pipeline round-trip"
# Verify text log format: each non-comment line must match t_rel len=N HH...
with open(sys.argv[2]) as f:
    for line in f:
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        import re
        assert re.search(r'len=\d+\s+[0-9a-f ]+$', stripped, re.I), \
            f"text log line does not match canonical format: {stripped!r}"
PY
  then ok "T9 pipeline round-trip: capture --log + analyze → status:complete"
  else no "T9 pipeline round-trip: analyze failed or JSON invalid (exit $_t9_ana_exit)"; fi
else
  no "T9 capture --log: expected exit 0 + log file, got exit $_t9_cap_exit (log_exists=$([ -f "$ROOT/t9.log" ] && echo yes || echo no))"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: serial-frame-capture mutation controls --"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth mutant_crash_re || exit 2
# ---------------------------------------------------------------------------
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

ORIG_PY="$SUT_DIR/serial-frame_capture.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  serial-frame_capture.py not found: $ORIG_PY"
  pass=$((pass + MUT_PASS)); fail=$((fail + MUT_FAIL + 1))
  echo "== $pass passed · $fail failed =="; exit 1
fi

# Each tooth is a mutant_tooth: a probe runs the ORIGINAL and the MUTANT and prints typed facts; the original must
# exit GOOD_RC and print its fact, the mutant must exit exactly BAD_RC, print the mutated fact and no crash signature.
# A traceback (rc 1, a missing or unreadable JSON, an ImportError) is therefore a refused mutant, never a bite.
CRASH_RE="$(mutant_crash_re py)" || exit 2
# _sfc_mutant LABEL SED_EXPR : build the mutant into $MUTDIR; rc 1 (and a FAIL(mut) line) when it cannot be built.
_sfc_mutant() {
  MUTDIR="$(mktemp -d)"; cp -a "$SUT_DIR/." "$MUTDIR/"
  # lib/mutant.sh refuses a no-op, empty or live-tree mutant (python source: no bash -n).
  if ! MUTANT_SYNTAX=none mutant_chain "$1" "$ORIG_PY" "$MUTDIR/serial-frame_capture.py" "$2"; then
    mut_no "$1: mutant refused by lib/mutant.sh (reason on the FAIL line above)"; rm -rf "$MUTDIR"; return 1
  fi
  if ! python3 -m py_compile "$MUTDIR/serial-frame_capture.py" 2>/dev/null; then
    mut_no "$1: mutant failed py_compile"; rm -rf "$MUTDIR"; return 1
  fi
}
# _sfc_tooth LABEL GOOD_RC BAD_RC GOOD_HAS BAD_HAS PROBE_SCRIPT : the probe is `bash -c PROBE_SCRIPT _ @SUT@ OUTJSON`.
_sfc_tooth() {
  local label="$1" grc="$2" brc="$3" ghas="$4" bhas="$5" probe="$6"
  if mutant_tooth "$label" "$grc" "$brc" "$MUTDIR/serial-frame_capture.py" --orig "$ORIG_PY" \
       --good-has "$ghas" --bad-has "$bhas" --bad-lacks "$CRASH_RE" -- \
       env "PYSTUB=$ROOT/pystubs-fail" bash -c "$probe" _ @SUT@ "$ROOT/mut_probe.json"; then MUT_PASS=$((MUT_PASS+1)); else MUT_FAIL=$((MUT_FAIL+1)); fi
}
# M1 probe: plan-only guard. Original exits 3; the mutant exits 0.
_P1='rm -f "$2"; python3 "$1" sweep --port /dev/null --output "$2" 2>&1; rc=$?; echo "SFC-EXIT=$rc"; exit "$rc"'
# M2/M3 probes print the typed fact "SFC-STATUS=<status in the written JSON>" (a missing JSON prints no STATUS line).
_P2='rm -f "$2"; python3 "$1" sweep --port /dev/null --output "$2" 2>&1; python3 -c "import json,sys; print(\"SFC-STATUS=\" + json.load(open(sys.argv[1]))[\"status\"])" "$2"'
_P3='rm -f "$2"; PYTHONPATH="$PYSTUB" python3 "$1" sweep --port /dev/ttySTUB0 --allow-live-probe --output "$2" 2>&1; rc=$?; python3 -c "import json,sys; print(\"SFC-STATUS=\" + json.load(open(sys.argv[1]))[\"status\"])" "$2"; exit "$rc"'

# --- M1: change sys.exit(3) to sys.exit(0) in the plan-only guard -----------
if _sfc_mutant "M1 guard-exit" 's/sys\.exit(3)/sys.exit(0)  # MUTANT-M1/'; then
  _sfc_tooth "M1 guard-exit: plan-only guard exits 0 instead of 3" 3 0 'SFC-EXIT=3' 'SFC-EXIT=0' "$_P1"
  rm -rf "$MUTDIR"
fi

# --- M2: change plan status to a wrong value ---------------------------------
if _sfc_mutant "M2 plan-status" 's/"status": "plan-only",/"status": "broken-plan",  # MUTANT-M2/'; then
  _sfc_tooth "M2 plan-status: plan JSON status is broken-plan" 0 0 'SFC-STATUS=plan-only' 'SFC-STATUS=broken-plan' "$_P2"
  rm -rf "$MUTDIR"
fi

# --- M3: Remove sweep §7 exit-1 (status:failed → status:complete) -----------
# Target the sweep_status ternary sentinel comment.  No inline comment added to
# avoid eating syntax (see analyze M6/M8 lesson).
if _sfc_mutant "M3 sweep-§7" 's/else "failed"  # sweep-all-fail/else "complete"/'; then
  _sfc_tooth "M3 sweep-§7: all-baud failure reports status complete" 1 0 'SFC-STATUS=failed' 'SFC-STATUS=complete' "$_P3"
  rm -rf "$MUTDIR"
fi

# --- Control: a CRASH mutant must be REFUSED by the same machinery ----------------------------------------------
# sys.exit(undefined_name) makes the plan-only guard raise NameError: it exits 1, which this control EXPECTS as the bad rc, so
# only the --bad-lacks crash screen (Traceback in the output) can refuse it - removing that screen turns this control red.
if _sfc_mutant "ctl guard-crash" 's/sys\.exit(3)/sys.exit(undefined_name_ctl)/'; then
  _ctl_out="$(_sfc_tooth "ctl guard-crash: M1 probe on a crashing mutant" 3 1 'SFC-EXIT=3' 'SFC-EXIT=' "$_P1")"
  if grep -qF "THEATER" <<<"$_ctl_out"; then
    # _sfc_tooth ran in a subshell: its counters did not move, so the refusal is the PASS here.
    mut_ok "ctl guard-crash: a crashing mutant with the expected bad rc is refused by the crash screen alone"
  else
    mut_no "ctl guard-crash: a crashing mutant was NOT refused: $(tr '\n' ' ' <<<"$_ctl_out" | head -c 200)"
  fi
  rm -rf "$MUTDIR"
fi

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
