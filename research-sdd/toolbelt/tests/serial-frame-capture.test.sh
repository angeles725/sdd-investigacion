#!/usr/bin/env bash
# serial-frame-capture.test.sh — shim contract of serial-frame-capture.sh (kit issue #2437).
#
# serial-frame-capture.sh is a compatibility shim over `rsdd serial frame-capture` (Go). The capture's
# behavior - the plan-only guard, sweep scoring, idle-gap framing, the frame cap, the text log, the termios
# configuration - is covered by the Go tests in research-sdd/rsdd/internal/serial (capture_test.go carries the
# guard-to-test table; scripted ports with a fake clock hold every timing rule, a pseudo-terminal holds the real
# port path, and a differential against the frozen pre-port script runs the plan-only and live paths). This
# suite checks what the shim itself owns: it forwards arguments, the exit code and stderr unchanged, and it
# degrades through rsdd-exec (typed, exit 2) when rsdd cannot run. It also keeps end-to-end cases through the
# real binary - all OFFLINE: no hardware, the live path runs against a pseudo-terminal - and, under
# --prove-teeth, mutation controls on the shim.
#
# Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/serial-frame-capture.sh"
ANALYZE="$TOOLBELT/serial-frame-analyze.sh"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== serial-frame-capture.test.sh =="

[ -f "$SUT" ] && [ -x "$SUT" ] && [ -f "$TOOLBELT/lib/rsdd-exec.sh" ] || { echo "FATAL: absent-input: shim or lib/rsdd-exec.sh" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A stand-in rsdd: prints one argument per line, says something on stderr and exits with a chosen code.
STUB="$TMP/rsdd-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do printf 'ARG[%s]\n' "$a"; done
echo "stub-stderr" >&2
exit "${STUB_RC:-7}"
EOF
chmod +x "$STUB"

# shim_run SHIM [args...] -> SOUT SERR SRC
shim_run() { SOUT="$(RSDD_BIN="$STUB" STUB_RC="${STUB_RC:-7}" bash "$1" "${@:2}" 2>"$TMP/serr")"; SRC=$?; SERR="$(cat "$TMP/serr")"; }

# 1. arguments, exit code and stderr pass through
shim_run "$SUT" capture --port 'a b' --baud 19200 --allow-live-probe --output ''
want=$'ARG[serial]\nARG[frame-capture]\nARG[capture]\nARG[--port]\nARG[a b]\nARG[--baud]\nARG[19200]\nARG[--allow-live-probe]\nARG[--output]\nARG[]'
if [ "$SOUT" = "$want" ]; then ok "1 arguments reach rsdd verbatim after 'serial frame-capture' (spaces and an empty argument kept)"
else no "1 arguments (out=[$SOUT])"; fi
if [ "$SRC" -eq 7 ]; then ok "1 exit code of rsdd is the shim's exit code"; else no "1 exit code (rc=$SRC)"; fi
if [ "$SERR" = "stub-stderr" ]; then ok "1 stderr of rsdd passes through"; else no "1 stderr (err=[$SERR])"; fi

# 2. rsdd cannot run: typed degraded state, never a clean 0, no evidence
out="$(RSDD_BIN="$TMP/does-not-exist" bash "$SUT" sweep --port /dev/null --output "$TMP/degraded.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && [ ! -e "$TMP/degraded.json" ]; then
  ok "2 rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, no evidence written"
else no "2 degrade (rc=$rc out=[$out])"; fi

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/serial-frame-capture.sh"
out="$(bash "$TMP/nolib/serial-frame-capture.sh" sweep --port x --output y 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no Python, no capture logic left behind.
if grep -qF 'rsdd_exec serial frame-capture "$@"' "$SUT" && ! grep -qE 'python3|serial-frame_capture|pyserial' "$SUT" && [ ! -e "$TOOLBELT/serial-frame_capture.py" ]; then
  ok "4 shim body is 'rsdd_exec serial frame-capture \"\$@\"' with no python3 / serial-frame_capture.py left"
else no "4 shim body"; fi

# ---- End to end through the real binary --------------------------------------
# $RSDD_BIN wins; otherwise one binary is built into the suite temp dir (never into the tree). Without Go the
# end-to-end group is a typed SKIP (FAIL under RSDD_REQUIRE_GO=1): the shim checks above never need it.
real_rsdd=""
if [ -n "${RSDD_BIN:-}" ] && [ -x "${RSDD_BIN:-}" ]; then real_rsdd="$RSDD_BIN"
elif command -v go >/dev/null 2>&1; then
  if ( cd "$TOOLBELT/../rsdd" && CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS='' GOWORK=off go build -o "$TMP/rsdd" ./cmd/rsdd ) >"$TMP/build.log" 2>&1; then real_rsdd="$TMP/rsdd"
  else echo "FATAL: cannot build rsdd" >&2; tail -n 20 "$TMP/build.log" >&2; exit 2; fi
fi
if [ -z "$real_rsdd" ]; then
  if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then no "e2e: rsdd-unavailable: go not in PATH and no executable RSDD_BIN (RSDD_REQUIRE_GO=1)"
  else echo "SKIP e2e (rsdd-unavailable: go not in PATH and no executable RSDD_BIN; set RSDD_REQUIRE_GO=1 to fail instead)"; fi
else
  q() { RSDD_BIN="$real_rsdd" bash "$SUT" "$@"; }
  W="$TMP/e2e"; mkdir -m 700 "$W"

  # 5. sweep without --allow-live-probe: exit 3 and the plan document, no port opened
  rc=0; q sweep --port /dev/null --output "$W/t5.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 3 ] && python3 - "$W/t5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'serial-frame.v1' and d['status'] == 'plan-only' and d['tool'] == 'serial-frame-capture'
assert d['mode'] == 'sweep' and d['guard'] and d['plan']['port'] == '/dev/null'
assert d['plan']['baud_rates'] == [2400, 4800, 9600, 19200, 38400, 57600, 115200]
PY
  then ok "5 sweep plan-only: exit 3, plan document with the baud list"; else no "5 sweep plan-only (rc=$rc)"; fi

  # 6. capture without --allow-live-probe: exit 3 and the capture plan
  rc=0; q capture --port /dev/null --baud 19200 --output "$W/t6.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 3 ] && python3 - "$W/t6.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'plan-only' and d['mode'] == 'capture'
assert d['plan']['baud'] == 19200 and d['plan']['seconds'] == 30.0 and d['plan']['gap_ms'] == 8.0
PY
  then ok "6 capture plan-only: exit 3, plan document with baud, seconds and gap"; else no "6 capture plan-only (rc=$rc)"; fi

  # 7. usage errors: non-zero and no document
  rc=0; q sweep --output "$W/t7.json" 2>/dev/null || rc=$?
  rc2=0; q capture --port /dev/null --output "$W/t7b.json" 2>/dev/null || rc2=$?
  if [ "$rc" -eq 2 ] && [ "$rc2" -eq 2 ] && [ ! -e "$W/t7.json" ] && [ ! -e "$W/t7b.json" ]; then ok "7 missing --port / --baud: exit 2, no document"; else no "7 usage (rc=$rc/$rc2)"; fi

  # 8. --allow-live-probe after the subcommand, no port to open: every baud fails -> exit 1, status failed
  rc=0; q sweep --port "$W/ttySTUB0" --allow-live-probe --output "$W/t8.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 1 ] && python3 - "$W/t8.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed' and d['mode'] == 'sweep'
assert len(d['results']['baud_rates']) == 7 and all('error' in r for r in d['results']['baud_rates'])
PY
  then ok "8 sweep on an absent port: exit 1, status failed, an error per baud"; else no "8 sweep failure (rc=$rc)"; fi

  # 8b. the guard holds with a port that is not there
  rc=0; q sweep --port "$W/ttySTUB0" --output "$W/t8b.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 3 ]; then ok "8b guard: without --allow-live-probe the exit is 3 plan-only"; else no "8b guard (rc=$rc)"; fi

  # 9. capture on an absent port: exit 2 and no document
  rc=0; q capture --port "$W/ttySTUB0" --baud 9600 --allow-live-probe --output "$W/t9.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$W/t9.json" ]; then ok "9 capture on an absent port: exit 2, no document"; else no "9 capture absent port (rc=$rc)"; fi

  # 10. pipeline round trip over a pseudo-terminal: capture --log, then serial-frame-analyze reads the log back
  rc=0; RSDD_BIN="$real_rsdd" python3 - "$SUT" "$W/t10.log" "$W/t10.json" <<'PY' || rc=$?
import os, pty, subprocess, sys, termios, time
shim, log, out = sys.argv[1:4]
master, slave = pty.openpty()
port = os.ttyname(slave)
proc = subprocess.Popen(["bash", shim, "capture", "--port", port, "--baud", "19200", "--seconds", "1.5",
                         "--allow-live-probe", "--log", log, "--output", out], stderr=subprocess.DEVNULL)
# Wait until rsdd has put the port in raw mode: a fresh pty is canonical, where 0x17 is VWERASE and the
# first frame would be erased. A fixed sleep raced on loaded hosts.
deadline = time.monotonic() + 10
while termios.tcgetattr(slave)[3] & termios.ICANON:
    if time.monotonic() > deadline or proc.poll() is not None:
        sys.exit(9)
    time.sleep(0.02)
os.write(master, b"\x81\x00\x17")
time.sleep(0.4); os.write(master, b"\x82\x01")
sys.exit(proc.wait())
PY
  if [ "$rc" -eq 0 ] && python3 - "$W/t10.json" "$W/t10.log" <<'PY' 2>/dev/null
import json, re, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete' and d['summary']['frame_count'] == 2
assert [f['hex'] for f in d['frames']] == ['810017', '8201']
lines = [l for l in open(sys.argv[2]).read().splitlines() if l.strip()]
assert len(lines) == 2 and all(re.search(r'len=\d+\s+[0-9a-f ]+$', l) for l in lines), lines
PY
  then
    arc=0; RSDD_BIN="$real_rsdd" bash "$ANALYZE" stats --input "$W/t10.log" --output "$W/t10_ana.json" 2>/dev/null || arc=$?
    if [ "$arc" -eq 0 ] && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['status']=='complete' and d['summary']['frame_count']==2" "$W/t10_ana.json" 2>/dev/null; then
      ok "10 pty round trip: capture --log -> 2 frames, serial-frame-analyze reads the log (status complete)"
    else no "10 pty round trip: analyze failed (exit $arc)"; fi
  else no "10 pty round trip: capture failed (rc=$rc)"; fi

  # 11. an existing output is never overwritten: exit 2 and the victim is intact
  echo victim-content > "$W/victim.json"
  rc=0; q sweep --port /dev/null --output "$W/victim.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ "$(cat "$W/victim.json")" = "victim-content" ]; then ok "11 existing output: exit 2, content intact"; else no "11 existing output (rc=$rc)"; fi
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for serial-frame-capture.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/serial-frame-capture.sh" "$2" 2>/dev/null; then MS="$d/serial-frame-capture.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec serial frame-capture "\$@"#rsdd_exec serial frame-capture#'; then
    shim_run "$MS" sweep --port x
    [ "$SOUT" != $'ARG[serial]\nARG[frame-capture]\nARG[sweep]\nARG[--port]\nARG[x]' ] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec serial frame-capture#rsdd_exec serial frame-captur#'; then
    shim_run "$MS" sweep
    [ "$SOUT" != $'ARG[serial]\nARG[frame-capture]\nARG[sweep]' ] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard replaced by exit 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/serial-frame-capture.sh"
    out="$(bash "$TMP/mt/C-nolib/serial-frame-capture.sh" sweep --port x --output y 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered (plan-only 3 would read as success)
  if mk D 's#^rsdd_exec serial frame-capture "\$@"#( rsdd_exec serial frame-capture "$@" ); exit 0#'; then
    shim_run "$MS" sweep
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the end-to-end group is real: a shim pointed at the analyzer fails the plan-only case
  if [ -n "$real_rsdd" ] && mk E 's#^rsdd_exec serial frame-capture#rsdd_exec serial frame-analyze#'; then
    rc=0; RSDD_BIN="$real_rsdd" bash "$MS" sweep --port /dev/null --output "$TMP/e2e/t_e.json" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 3 ]; then no "teeth E: the wrong command still produced a plan — THEATER"
    else ok "teeth E: wrong command -> the end-to-end plan-only goes red"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
