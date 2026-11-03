#!/usr/bin/env bash
# serial-frame-analyze.test.sh — shim contract of serial-frame-analyze.sh (kit issue #2437).
#
# serial-frame-analyze.sh is a compatibility shim over `rsdd serial frame-analyze` (Go). The analyzer's
# behavior - the frame grammar, the three anti-silent-zero states, both caps, the checksum search, the evidence
# schema - is covered by the Go tests in research-sdd/rsdd/internal/serial (analyze_test.go carries the
# guard-to-test table; a golden replay and a differential against the frozen pre-port script run over the
# fixtures, error paths and seeded random logs). This suite checks what the shim itself owns: it forwards
# arguments, the exit code and stderr unchanged, and it degrades through rsdd-exec (typed, exit 2) when rsdd
# cannot run. It also keeps a few end-to-end cases through the real binary and, under --prove-teeth, mutation
# controls on the shim.
#
# Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$HERE/.."
SUT="$TOOLBELT/serial-frame-analyze.sh"
FIX="$TOOLBELT/../rsdd/internal/serial/testdata/frames"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== serial-frame-analyze.test.sh =="

[ -f "$SUT" ] && [ -x "$SUT" ] && [ -f "$TOOLBELT/lib/rsdd-exec.sh" ] || { echo "FATAL: absent-input: shim or lib/rsdd-exec.sh" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
[ -d "$FIX" ] || { echo "FATAL: absent-input: fixtures directory $FIX" >&2; exit 2; }
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
shim_run "$SUT" stats --input 'a b.log' --output ''
want=$'ARG[serial]\nARG[frame-analyze]\nARG[stats]\nARG[--input]\nARG[a b.log]\nARG[--output]\nARG[]'
if [ "$SOUT" = "$want" ]; then ok "1 arguments reach rsdd verbatim after 'serial frame-analyze' (spaces and an empty argument kept)"
else no "1 arguments (out=[$SOUT])"; fi
if [ "$SRC" -eq 7 ]; then ok "1 exit code of rsdd is the shim's exit code"; else no "1 exit code (rc=$SRC)"; fi
if [ "$SERR" = "stub-stderr" ]; then ok "1 stderr of rsdd passes through"; else no "1 stderr (err=[$SERR])"; fi

# 2. rsdd cannot run: typed degraded state, never a clean 0, no evidence
out="$(RSDD_BIN="$TMP/does-not-exist" bash "$SUT" stats --input x --output "$TMP/degraded.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && [ ! -e "$TMP/degraded.json" ]; then
  ok "2 rsdd cannot run -> typed 'degraded: rsdd-unavailable', exit 2, no evidence written"
else no "2 degrade (rc=$rc out=[$out])"; fi

# 3. A shim whose lib/rsdd-exec.sh is missing says so and exits 2.
mkdir -p "$TMP/nolib"; cp "$SUT" "$TMP/nolib/serial-frame-analyze.sh"
out="$(bash "$TMP/nolib/serial-frame-analyze.sh" stats --input x --output y 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'degraded: rsdd-unavailable' <<< "$out" && grep -qF 'rsdd-exec.sh missing beside' <<< "$out"; then
  ok "3 library missing -> 'rsdd-exec.sh missing beside <shim>', exit 2"
else no "3 missing lib (rc=$rc out=[$out])"; fi

# 4. The shim is the template and nothing else: no Python, no analyzer logic left behind.
if grep -qF 'rsdd_exec serial frame-analyze "$@"' "$SUT" && ! grep -qE 'python3|serial-frame_analyze|hashlib' "$SUT" && [ ! -e "$TOOLBELT/serial-frame_analyze.py" ]; then
  ok "4 shim body is 'rsdd_exec serial frame-analyze \"\$@\"' with no python3 / serial-frame_analyze.py left"
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

  # 5. absent input: exit 2 and no evidence
  rc=0; q stats --input "$W/no-such.log" --output "$W/t5.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$W/t5.json" ]; then ok "5 absent input: exit 2, no evidence"; else no "5 absent input (rc=$rc)"; fi

  # 6. symlink input: exit 2 (O_NOFOLLOW)
  ln -s "$FIX/basic.log" "$W/sym.log"
  rc=0; q stats --input "$W/sym.log" --output "$W/t6.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$W/t6.json" ]; then ok "6 symlink input: exit 2, no evidence"; else no "6 symlink input (rc=$rc)"; fi

  # 7. empty log: exit 0, complete, frame_count 0 (the tool looked and found nothing)
  rc=0; q stats --input "$FIX/empty.log" --output "$W/t7.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && python3 - "$W/t7.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'serial-frame.v1' and d['status'] == 'complete' and d['mode'] == 'stats'
assert d['summary']['frame_count'] == 0 and d['results']['most_common_length'] is None
PY
  then ok "7 empty log: exit 0, status complete, frame_count 0"; else no "7 empty log (rc=$rc)"; fi

  # 8. stats of a valid log: fields and the sha256 of the file
  rc=0; q stats --input "$FIX/basic.log" --output "$W/t8.json" 2>/dev/null || rc=$?
  sha="$(sha256sum "$FIX/basic.log" | cut -d' ' -f1)"
  if [ "$rc" -eq 0 ] && python3 - "$W/t8.json" "$sha" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['tool'] == 'serial-frame-analyze' and d['input']['sha256'] == sys.argv[2]
assert d['summary']['frame_count'] == 4 and d['summary']['distinct_lengths'] == 2
assert d['results']['most_common_length'] == 3 and d['results']['variability'][0]['is_constant'] is True
PY
  then ok "8 stats: exit 0, 4 frames, sha256 of the file, constant header byte"; else no "8 stats (rc=$rc)"; fi

  # 9. diff: the changed byte position
  rc=0; q diff --input-a "$FIX/basic.log" --input-b "$FIX/basic_b.log" --output "$W/t9.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && python3 - "$W/t9.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
t3 = next(t for t in d['results']['shared_types'] if t['length'] == 3)
assert t3['changed_positions'] == [2] and t3['first_byte_hex'] == '81'
PY
  then ok "9 diff: exit 0, byte position 2 changed in the 3-byte frames"; else no "9 diff (rc=$rc)"; fi

  # 10. checksum: CRC16-Modbus (little endian) validates on every frame
  rc=0; q checksum --input "$FIX/crc-modbus.log" --output "$W/t10.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] && python3 - "$W/t10.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
c = [a for a in d['results']['algorithms'] if a['candidate']]
assert any(a['name'] == 'crc16-modbus' and a['little_endian'] is True and a['skip_first'] == 0 for a in c), c
PY
  then ok "10 checksum: exit 0, crc16-modbus (LE) is a candidate"; else no "10 checksum (rc=$rc)"; fi

  # 11. malformed log: exit 1 and a failed document (never a clean 0)
  rc=0; q stats --input "$FIX/malformed.log" --output "$W/t11.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 1 ] && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['status']=='failed' and d['errors']" "$W/t11.json" 2>/dev/null; then
    ok "11 malformed log: exit 1, status failed, errors non-empty"; else no "11 malformed log (rc=$rc)"; fi

  # 12. an existing output is never overwritten: exit 2 and the victim is intact
  echo victim-content > "$W/victim.json"
  rc=0; q stats --input "$FIX/basic.log" --output "$W/victim.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ "$(cat "$W/victim.json")" = "victim-content" ]; then ok "12 existing output: exit 2, content intact"; else no "12 existing output (rc=$rc)"; fi

  # 13. a FIFO input is refused without blocking
  mkfifo "$W/fifo.log"
  rc=0; timeout 10 bash -c 'RSDD_BIN="$1" bash "$2" stats --input "$3" --output "$4"' _ "$real_rsdd" "$SUT" "$W/fifo.log" "$W/t13.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$W/t13.json" ]; then ok "13 FIFO input: exit 2, no evidence, no hang"; else no "13 FIFO input (rc=$rc)"; fi

  # 14. a usage error is exit 2
  rc=0; q stats --output "$W/t14.json" 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ] && [ ! -e "$W/t14.json" ]; then ok "14 missing --input: exit 2, no evidence"; else no "14 missing --input (rc=$rc)"; fi
fi

# ---- Teeth (mutation proof) -------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for serial-frame-analyze.sh (shim) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # mk NAME SEDEXPR -> a mutant shim with the lib beside it in $TMP/mt/NAME; sets MS or returns 1
  mk() {
    local d="$TMP/mt/$1"
    mkdir -p "$d/lib" && cp "$TOOLBELT/lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh; staging every lib would hide the missing-lib case
    if mutant_sed "$SUT" "$d/serial-frame-analyze.sh" "$2" 2>/dev/null; then MS="$d/serial-frame-analyze.sh"; return 0; fi
    no "teeth $1: could not build mutant (pattern not found / refused by lib/mutant.sh)"; return 1
  }
  # A: arguments no longer forwarded
  if mk A 's#^rsdd_exec serial frame-analyze "\$@"#rsdd_exec serial frame-analyze#'; then
    shim_run "$MS" stats --input x
    [ "$SOUT" != $'ARG[serial]\nARG[frame-analyze]\nARG[stats]\nARG[--input]\nARG[x]' ] && ok "teeth A: arguments dropped -> forwarding check goes red" || no "teeth A: mutant still forwards — THEATER"
  fi
  # B: wrong subcommand
  if mk B 's#^rsdd_exec serial frame-analyze#rsdd_exec serial frame-analyz#'; then
    shim_run "$MS" stats
    [ "$SOUT" != $'ARG[serial]\nARG[frame-analyze]\nARG[stats]' ] && ok "teeth B: wrong command name -> forwarding check goes red" || no "teeth B: mutant still forwards — THEATER"
  fi
  # C: the degraded path swallowed (library guard replaced by exit 0)
  if mk C 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#'; then
    mkdir -p "$TMP/mt/C-nolib"; cp "$MS" "$TMP/mt/C-nolib/serial-frame-analyze.sh"
    out="$(bash "$TMP/mt/C-nolib/serial-frame-analyze.sh" stats --input x --output y 2>&1)"; rc=$?
    [ "$rc" -ne 2 ] && ok "teeth C: missing-library guard exits 0 -> case 3 goes red" || no "teeth C: mutant still exits 2 — THEATER"
  fi
  # D: the exit code is laundered
  if mk D 's#^rsdd_exec serial frame-analyze "\$@"#( rsdd_exec serial frame-analyze "$@" ); exit 0#'; then
    shim_run "$MS" stats
    [ "$SRC" -ne 7 ] && ok "teeth D: exit code laundered to 0 -> exit-code check goes red" || no "teeth D: mutant still forwards rc 7 — THEATER"
  fi
  # E: the end-to-end group is real: a shim pointed at the capture command fails case 8
  if [ -n "$real_rsdd" ] && mk E 's#^rsdd_exec serial frame-analyze#rsdd_exec serial frame-capture#'; then
    if RSDD_BIN="$real_rsdd" bash "$MS" stats --input "$FIX/basic.log" --output "$TMP/e2e/t_e.json" >/dev/null 2>&1; then no "teeth E: the wrong command still analysed — THEATER"
    else ok "teeth E: wrong command -> the end-to-end stats goes red"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
