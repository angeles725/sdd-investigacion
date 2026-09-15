#!/usr/bin/env bash
# Test suite for serial-frame-analyze.sh (serial-frame.v1)
#
# All tests are OFFLINE: no hardware or serial port required.
# Static fixtures are read from tests/fixtures/serial-frame-analyze/.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../serial-frame-analyze.sh"
FIXTURES="$HERE/fixtures/serial-frame-analyze"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }
[ -d "$FIXTURES" ] || { echo "FATAL: fixtures directory not found: $FIXTURES" >&2; exit 2; }
for _f in basic.log basic_b.log checksum.log empty.log crc-modbus.log crc-ccitt.log malformed.log; do
  [ -f "$FIXTURES/$_f" ] || { echo "FATAL: fixture missing: $FIXTURES/$_f" >&2; exit 2; }
done

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ---------------------------------------------------------------------------
# T1: absent input → exit 2, no JSON produced
# ---------------------------------------------------------------------------
_t1_exit=0
"$SUT" stats --input "$ROOT/no-such.log" --output "$ROOT/t1.json" 2>/dev/null \
  || _t1_exit=$?
if [ "$_t1_exit" -eq 2 ] && [ ! -f "$ROOT/t1.json" ]; then
  ok "T1 absent input: exit 2, no JSON"
else
  no "T1 absent input: expected exit 2 + no JSON, got exit $_t1_exit (json_exists=$([ -f "$ROOT/t1.json" ] && echo yes || echo no))"
fi

# ---------------------------------------------------------------------------
# T2: symlink input → exit 2 (O_NOFOLLOW guard)
# ---------------------------------------------------------------------------
ln -sf "$FIXTURES/basic.log" "$ROOT/sym.log"
_t2_exit=0
"$SUT" stats --input "$ROOT/sym.log" --output "$ROOT/t2.json" 2>/dev/null \
  || _t2_exit=$?
if [ "$_t2_exit" -eq 2 ]; then
  ok "T2 symlink input: exit 2 (O_NOFOLLOW)"
else
  no "T2 symlink input: expected exit 2, got $_t2_exit"
fi

# ---------------------------------------------------------------------------
# T3: empty log (no frames) → exit 0, status:complete, frame_count=0
# Anti-silent-zero: proves the tool opened and scanned the file
# ---------------------------------------------------------------------------
_t3_exit=0
"$SUT" stats --input "$FIXTURES/empty.log" --output "$ROOT/t3.json" 2>/dev/null \
  || _t3_exit=$?
if [ "$_t3_exit" -eq 0 ]; then
  if python3 - "$ROOT/t3.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'serial-frame.v1', f"wrong schema: {d['schema']!r}"
assert d['status'] == 'complete', f"expected complete, got {d['status']!r}"
assert d['summary']['frame_count'] == 0, f"expected 0, got {d['summary']['frame_count']}"
assert d['mode'] == 'stats', f"expected stats, got {d['mode']!r}"
PY
  then ok "T3 empty log: exit 0, status:complete, frame_count=0"
  else no "T3 empty log: exit 0 but JSON validation failed"; fi
else
  no "T3 empty log: expected exit 0, got $_t3_exit"
fi

# ---------------------------------------------------------------------------
# T4: valid log (stats mode) → exit 0, correct schema fields and sha256
# ---------------------------------------------------------------------------
_t4_exit=0
"$SUT" stats --input "$FIXTURES/basic.log" --output "$ROOT/t4.json" 2>/dev/null \
  || _t4_exit=$?
if [ "$_t4_exit" -eq 0 ]; then
  if python3 - "$ROOT/t4.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'serial-frame.v1'
assert d['status'] == 'complete'
assert d['mode'] == 'stats'
assert d['tool'] == 'serial-frame-analyze'
# sha256 must be a 64-char hex string
sha = d['input']['sha256']
assert isinstance(sha, str) and len(sha) == 64, f"sha256 must be 64 chars, got {len(sha)}"
assert d['summary']['frame_count'] == 4, f"expected 4 frames, got {d['summary']['frame_count']}"
assert d['summary']['distinct_lengths'] == 2, f"expected 2 distinct lengths"
assert d['results']['most_common_length'] == 3
hist = d['results']['length_histogram']
assert isinstance(hist, list) and len(hist) > 0
assert 'variability' in d['results']
PY
  then ok "T4 valid stats: exit 0, correct fields, sha256 is 64 chars"
  else no "T4 valid stats: exit 0 but JSON validation failed"; fi
else
  no "T4 valid stats: expected exit 0, got $_t4_exit"
fi

# ---------------------------------------------------------------------------
# T5: diff mode → exit 0, shared_types present
# ---------------------------------------------------------------------------
_t5_exit=0
"$SUT" diff --input-a "$FIXTURES/basic.log" --input-b "$FIXTURES/basic_b.log" \
  --output "$ROOT/t5.json" 2>/dev/null || _t5_exit=$?
if [ "$_t5_exit" -eq 0 ]; then
  if python3 - "$ROOT/t5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'serial-frame.v1'
assert d['status'] == 'complete'
assert d['mode'] == 'diff'
assert 'shared_types' in d['results']
# Both logs share length=3 (first_byte=0x81) and length=5 (first_byte=0x81)
types = d['results']['shared_types']
assert len(types) >= 1, "expected at least 1 shared frame type"
# For len=3 shared type, pos 2 must appear in changed_positions
len3 = next((t for t in types if t['length'] == 3), None)
assert len3 is not None, "expected len=3 shared type"
assert 2 in len3['changed_positions'], f"pos 2 should differ: {len3['changed_positions']}"
# pos 0 (0x81 in both) must NOT be in changed_positions
assert 0 not in len3['changed_positions'], f"pos 0 should be constant: {len3['changed_positions']}"
assert d['summary']['frame_count_a'] == 4
assert d['summary']['frame_count_b'] == 4
PY
  then ok "T5 diff mode: exit 0, shared_types correct"
  else no "T5 diff mode: exit 0 but JSON validation failed"; fi
else
  no "T5 diff mode: expected exit 0, got $_t5_exit"
fi

# ---------------------------------------------------------------------------
# T6: checksum mode → exit 0, algorithms list present, at least 2 algorithms
# ---------------------------------------------------------------------------
_t6_exit=0
"$SUT" checksum --input "$FIXTURES/basic.log" --output "$ROOT/t6.json" 2>/dev/null \
  || _t6_exit=$?
if [ "$_t6_exit" -eq 0 ]; then
  if python3 - "$ROOT/t6.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'serial-frame.v1'
assert d['status'] == 'complete'
assert d['mode'] == 'checksum'
algos = d['results']['algorithms']
assert isinstance(algos, list), "algorithms must be a list"
assert len(algos) >= 2, f"expected at least 2 algorithms, got {len(algos)}"
# Each algorithm entry must have required fields
for a in algos:
    assert 'name' in a
    assert 'hit_count' in a
    assert 'total_frames' in a
    assert 'candidate' in a
PY
  then ok "T6 checksum mode: exit 0, algorithms list present"
  else no "T6 checksum mode: exit 0 but JSON validation failed"; fi
else
  no "T6 checksum mode: expected exit 0, got $_t6_exit"
fi

# ---------------------------------------------------------------------------
# T7: output pointing at a symlink → exit 2, victim not overwritten
# ---------------------------------------------------------------------------
echo "victim-content" > "$ROOT/victim.txt"
ln -sf "$ROOT/victim.txt" "$ROOT/out_sym.json"
_t7_exit=0
"$SUT" stats --input "$FIXTURES/basic.log" --output "$ROOT/out_sym.json" \
  2>/dev/null || _t7_exit=$?
_victim_ok=0
[ "$(cat "$ROOT/victim.txt" 2>/dev/null)" = "victim-content" ] && _victim_ok=1
if [ "$_t7_exit" -eq 2 ] && [ "$_victim_ok" -eq 1 ]; then
  ok "T7 output symlink: exit 2, victim not overwritten"
else
  no "T7 output symlink: expected exit 2 + victim intact, got exit $_t7_exit (victim_ok=$_victim_ok)"
fi

# ---------------------------------------------------------------------------
# T8: exact frame count assertion (stats mode, 4 frames)
# Doubles as the mutation target for M2 (frame_count zeroed)
# ---------------------------------------------------------------------------
if python3 - "$ROOT/t4.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
n = d['summary']['frame_count']
assert n == 4, f"expected exactly 4 frames, got {n}"
PY
then ok "T8 exact frame_count=4 (stats)"
else no "T8 exact frame_count: expected 4, see t4.json"; fi

# ---------------------------------------------------------------------------
# T9: variability — pos 0 constant (all 0x81), pos 2 variable for len=3
# ---------------------------------------------------------------------------
if python3 - "$ROOT/t4.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
var = d['results']['variability']
assert len(var) == 3, f"expected 3 positions for len=3, got {len(var)}"
pos0 = var[0]
assert pos0['position'] == 0
assert pos0['is_constant'] is True, f"pos 0 must be constant, got {pos0}"
pos2 = var[2]
assert pos2['position'] == 2
assert pos2['is_constant'] is False, f"pos 2 must not be constant, got {pos2}"
PY
then ok "T9 variability: pos 0 constant, pos 2 variable"
else no "T9 variability: assertion failed (see t4.json)"; fi

# ---------------------------------------------------------------------------
# T10: CRC16-Modbus LE candidate detected (protects 0xA001 polynomial)
# ---------------------------------------------------------------------------
_t10_exit=0
"$SUT" checksum --input "$FIXTURES/crc-modbus.log" --output "$ROOT/t10.json" 2>/dev/null \
  || _t10_exit=$?
if [ "$_t10_exit" -eq 0 ]; then
  if python3 - "$ROOT/t10.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete'
algos = d['results']['algorithms']
# Must find crc16-modbus little-endian as a candidate
modbus_le = next(
    (a for a in algos if a['name'] == 'crc16-modbus' and a.get('little_endian') is True),
    None,
)
assert modbus_le is not None, f"crc16-modbus LE not in algorithms: {[a['name'] for a in algos]}"
assert modbus_le['candidate'] is True, f"crc16-modbus LE must be candidate: {modbus_le}"
PY
  then ok "T10 CRC16-Modbus LE: detected as candidate (0xA001 polynomial)"
  else no "T10 CRC16-Modbus LE: not detected (JSON failed validation)"; fi
else
  no "T10 CRC16-Modbus LE: expected exit 0, got $_t10_exit"
fi

# ---------------------------------------------------------------------------
# T11: malformed input (len mismatch) → exit 1, status:failed, errors non-empty
# BLOCKER 3: the status:failed/exit-1 path must be implemented
# ---------------------------------------------------------------------------
_t11_exit=0
"$SUT" stats --input "$FIXTURES/malformed.log" --output "$ROOT/t11.json" 2>/dev/null \
  || _t11_exit=$?
if [ "$_t11_exit" -eq 1 ]; then
  if python3 - "$ROOT/t11.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'serial-frame.v1', f"wrong schema: {d['schema']!r}"
assert d['status'] == 'failed', f"expected failed, got {d['status']!r}"
assert isinstance(d.get('errors'), list) and len(d['errors']) > 0, \
    f"errors must be non-empty list, got {d.get('errors')!r}"
assert d['tool'] == 'serial-frame-analyze'
PY
  then ok "T11 malformed input: exit 1, status:failed, errors non-empty (BLOCKER 3)"
  else no "T11 malformed input: exit 1 but JSON failed validation"; fi
else
  no "T11 malformed input: expected exit 1, got $_t11_exit (BLOCKER 3 not implemented)"
fi

# ---------------------------------------------------------------------------
# T12: CRC16-CCITT BE candidate detected (protects 0x1021 polynomial)
# ---------------------------------------------------------------------------
_t12_exit=0
"$SUT" checksum --input "$FIXTURES/crc-ccitt.log" --output "$ROOT/t12.json" 2>/dev/null \
  || _t12_exit=$?
if [ "$_t12_exit" -eq 0 ]; then
  if python3 - "$ROOT/t12.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete'
algos = d['results']['algorithms']
# Must find crc16-ccitt big-endian (little_endian=False) as a candidate
ccitt_be = next(
    (a for a in algos if a['name'] == 'crc16-ccitt' and a.get('little_endian') is False),
    None,
)
assert ccitt_be is not None, f"crc16-ccitt BE not in algorithms: {[a['name'] for a in algos]}"
assert ccitt_be['candidate'] is True, f"crc16-ccitt BE must be candidate: {ccitt_be}"
PY
  then ok "T12 CRC16-CCITT BE: detected as candidate (0x1021 polynomial)"
  else no "T12 CRC16-CCITT BE: not detected (JSON failed validation)"; fi
else
  no "T12 CRC16-CCITT BE: expected exit 0, got $_t12_exit"
fi

# ---------------------------------------------------------------------------
# T13: twos-comp8 candidate (baseline — makes M7 attributable)
# Running checksum on checksum.log must find twos-comp8 (skip=0) as candidate.
# If this test is red, twos-comp8 is broken; M7 is attributable to this case.
# ---------------------------------------------------------------------------
_t13_exit=0
"$SUT" checksum --input "$FIXTURES/checksum.log" --output "$ROOT/t13.json" 2>/dev/null \
  || _t13_exit=$?
if [ "$_t13_exit" -eq 0 ]; then
  if python3 - "$ROOT/t13.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete'
algos = d['results']['algorithms']
twos = next(
    (a for a in algos if a['name'] == 'twos-comp8' and a.get('skip_first', 0) == 0),
    None,
)
assert twos is not None, f"twos-comp8 not in algorithms: {[a['name'] for a in algos]}"
assert twos['candidate'] is True, f"twos-comp8 must be candidate: {twos}"
PY
  then ok "T13 twos-comp8: detected as candidate on checksum.log (baseline for M7)"
  else no "T13 twos-comp8: assertion failed (checksum.log or twos-comp8 broken)"; fi
else
  no "T13 twos-comp8: expected exit 0, got $_t13_exit"
fi

# ---------------------------------------------------------------------------
# T14: non-hex token (no len=) → exit 1, status:failed, errors non-empty
# §7 / BLOCKER-1: lines without len= must be parse errors, not silent skips.
# Currently RED: tool silently continues and emits status:complete, frame_count:0.
# ---------------------------------------------------------------------------
printf '   0.000000  len=3  81 00 zz\n' > "$ROOT/garbage1.log"
_t14_exit=0
"$SUT" stats --input "$ROOT/garbage1.log" --output "$ROOT/t14.json" 2>/dev/null \
  || _t14_exit=$?
if [ "$_t14_exit" -eq 1 ]; then
  if python3 - "$ROOT/t14.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'serial-frame.v1', f"wrong schema: {d['schema']!r}"
assert d['status'] == 'failed', f"expected failed, got {d['status']!r}"
assert isinstance(d.get('errors'), list) and len(d['errors']) > 0, \
    f"errors must be non-empty list, got {d.get('errors')!r}"
assert d['tool'] == 'serial-frame-analyze'
PY
  then ok "T14 bad-hex token: exit 1, status:failed, errors non-empty (BLOCKER-1)"
  else no "T14 bad-hex token: exit 1 but JSON failed validation"; fi
else
  no "T14 bad-hex token: expected exit 1, got $_t14_exit (BLOCKER-1: garbage reads as empty)"
fi

# ---------------------------------------------------------------------------
# T15: comma-separated line (no len=) → exit 1, status:failed, errors non-empty
# §7 / BLOCKER-1: unrecognized format must not silently pass as empty input.
# ---------------------------------------------------------------------------
printf '   0.000000  81,00,ff\n' > "$ROOT/garbage2.log"
_t15_exit=0
"$SUT" stats --input "$ROOT/garbage2.log" --output "$ROOT/t15.json" 2>/dev/null \
  || _t15_exit=$?
if [ "$_t15_exit" -eq 1 ]; then
  if python3 - "$ROOT/t15.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"expected failed, got {d['status']!r}"
assert isinstance(d.get('errors'), list) and len(d['errors']) > 0
PY
  then ok "T15 comma-separated: exit 1, status:failed, errors non-empty (BLOCKER-1)"
  else no "T15 comma-separated: exit 1 but JSON failed validation"; fi
else
  no "T15 comma-separated: expected exit 1, got $_t15_exit (BLOCKER-1: garbage reads as empty)"
fi

# ---------------------------------------------------------------------------
# T16: 2 KB of non-hex prose text → exit 1, status:failed, errors non-empty
# §7 / BLOCKER-1: a corpus of plain text must not be indistinguishable from empty.
# ---------------------------------------------------------------------------
python3 -c "print('The quick brown fox jumps over the lazy dog. ' * 50)" \
  > "$ROOT/garbage3.log"
_t16_exit=0
"$SUT" stats --input "$ROOT/garbage3.log" --output "$ROOT/t16.json" 2>/dev/null \
  || _t16_exit=$?
if [ "$_t16_exit" -eq 1 ]; then
  if python3 - "$ROOT/t16.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"expected failed, got {d['status']!r}"
assert isinstance(d.get('errors'), list) and len(d['errors']) > 0
PY
  then ok "T16 prose text: exit 1, status:failed, errors non-empty (BLOCKER-1)"
  else no "T16 prose text: expected exit 1, got $_t16_exit (BLOCKER-1: garbage reads as empty)"; fi
else
  no "T16 prose text: expected exit 1, got $_t16_exit (BLOCKER-1: garbage reads as empty)"
fi

# ---------------------------------------------------------------------------
# T17: truly zero-byte file → exit 0, status:complete, frame_count=0 (EMPTY)
# §7 / BLOCKER-1: empty-input must be distinguishable from garbage-input.
# ---------------------------------------------------------------------------
: > "$ROOT/zero.log"
_t17_exit=0
"$SUT" stats --input "$ROOT/zero.log" --output "$ROOT/t17.json" 2>/dev/null \
  || _t17_exit=$?
if [ "$_t17_exit" -eq 0 ]; then
  if python3 - "$ROOT/t17.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"expected complete, got {d['status']!r}"
assert d['summary']['frame_count'] == 0
PY
  then ok "T17 zero-byte file: exit 0, status:complete, frame_count=0 (EMPTY, distinct from GARBAGE)"
  else no "T17 zero-byte file: exit 0 but JSON failed validation"; fi
else
  no "T17 zero-byte file: expected exit 0, got $_t17_exit"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: serial-frame-analyze mutation controls --"
# ---------------------------------------------------------------------------
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/serial-frame_analyze.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  serial-frame_analyze.py not found: $ORIG_PY"
  pass=$((pass + MUT_PASS)); fail=$((fail + MUT_FAIL + 1))
  echo "== $pass passed · $fail failed =="; exit 1
fi

MUTDIR="$(mktemp -d)"

# --- M1: Remove O_NOFOLLOW from input open -----------------------------------
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/os\.O_RDONLY | _O_NOFOLLOW/os.O_RDONLY/' "$MUTDIR/serial-frame_analyze.py"
if ! python3 -m py_compile "$MUTDIR/serial-frame_analyze.py" 2>/dev/null; then
  mut_no "M1 O_NOFOLLOW input: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/serial-frame_analyze.py"; then
  mut_no "M1 O_NOFOLLOW input: sed had no effect"
else
  _m1_exit=0
  python3 "$MUTDIR/serial-frame_analyze.py" stats \
    --input "$ROOT/sym.log" --output "$ROOT/m1.json" 2>/dev/null || _m1_exit=$?
  if [ "$_m1_exit" -ne 2 ]; then
    mut_ok "M1 O_NOFOLLOW input removal detected (exit $_m1_exit, not 2)"
  else
    mut_no "M1 O_NOFOLLOW input: mutation NOT detected (still exits 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M2: Zero out frame_count in output --------------------------------------
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/"frame_count": len(frames),/"frame_count": 0,  # MUTANT-M2/' "$MUTDIR/serial-frame_analyze.py"
if ! python3 -m py_compile "$MUTDIR/serial-frame_analyze.py" 2>/dev/null; then
  mut_no "M2 frame_count zero: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/serial-frame_analyze.py"; then
  mut_no "M2 frame_count zero: sed had no effect"
else
  _m2_exit=0
  python3 "$MUTDIR/serial-frame_analyze.py" stats \
    --input "$FIXTURES/basic.log" --output "$ROOT/m2.json" 2>/dev/null || _m2_exit=$?
  if [ "$_m2_exit" -eq 0 ] && python3 - "$ROOT/m2.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['summary']['frame_count'] == 4, "frame_count not 4"
PY
  then
    mut_no "M2 frame_count zero: mutation NOT detected (count still 4?)"
  else
    mut_ok "M2 frame_count zero detected: T8 would catch this"
  fi
fi
rm -rf "$MUTDIR"

# --- M3: Remove O_EXCL from output open --------------------------------------
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/ | os\.O_EXCL//' "$MUTDIR/serial-frame_analyze.py"
if ! python3 -m py_compile "$MUTDIR/serial-frame_analyze.py" 2>/dev/null; then
  mut_no "M3 O_EXCL output guard: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/serial-frame_analyze.py"; then
  mut_no "M3 O_EXCL output guard: sed had no effect"
else
  echo "pre-existing" > "$ROOT/m3_existing.json"
  _m3_exit=0
  python3 "$MUTDIR/serial-frame_analyze.py" stats \
    --input "$FIXTURES/basic.log" --output "$ROOT/m3_existing.json" 2>/dev/null || _m3_exit=$?
  if [ "$_m3_exit" -ne 2 ]; then
    mut_ok "M3 O_EXCL output removal detected (exit $_m3_exit, overwrote existing)"
  else
    mut_no "M3 O_EXCL output: mutation NOT detected (still exits 2 with pre-existing file)"
  fi
fi
rm -rf "$MUTDIR"

# --- M4: Change sha256 algorithm (sha256 → md5, 64-char → 32-char) -----------
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/hashlib\.sha256()/hashlib.md5()  # MUTANT-M4/' "$MUTDIR/serial-frame_analyze.py"
if ! python3 -m py_compile "$MUTDIR/serial-frame_analyze.py" 2>/dev/null; then
  mut_no "M4 sha256 algo: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/serial-frame_analyze.py"; then
  mut_no "M4 sha256 algo: sed had no effect"
else
  _m4_exit=0
  python3 "$MUTDIR/serial-frame_analyze.py" stats \
    --input "$FIXTURES/basic.log" --output "$ROOT/m4.json" 2>/dev/null || _m4_exit=$?
  if [ "$_m4_exit" -eq 0 ] && python3 - "$ROOT/m4.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
sha = d['input']['sha256']
assert len(sha) == 64, f"sha256 must be 64 chars, got {len(sha)}"
PY
  then
    mut_no "M4 sha256 algo: mutation NOT detected (still 64 chars?)"
  else
    mut_ok "M4 sha256 algo change detected: T4 would catch this"
  fi
fi
rm -rf "$MUTDIR"

# --- M5: Mutate CRC16-Modbus polynomial (0xA001 → 0xB001) -------------------
# Expected: crc16-modbus LE is NO LONGER a candidate for crc-modbus.log (T10 catches it)
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/0xA001/0xB001/' "$MUTDIR/serial-frame_analyze.py"
if ! python3 -m py_compile "$MUTDIR/serial-frame_analyze.py" 2>/dev/null; then
  mut_no "M5 Modbus-poly: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/serial-frame_analyze.py"; then
  mut_no "M5 Modbus-poly: sed had no effect"
else
  _m5_exit=0
  python3 "$MUTDIR/serial-frame_analyze.py" checksum \
    --input "$FIXTURES/crc-modbus.log" --output "$ROOT/m5.json" 2>/dev/null || _m5_exit=$?
  if python3 - "$ROOT/m5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
algos = d['results']['algorithms']
modbus_le = next(
    (a for a in algos if a['name'] == 'crc16-modbus' and a.get('little_endian') is True),
    None,
)
# T10 assertion: crc16-modbus LE must be a candidate — this SHOULD fail for the mutant
assert modbus_le is not None and modbus_le['candidate'] is True, "not a candidate"
PY
  then
    mut_no "M5 Modbus-poly: mutation NOT detected (still a candidate with wrong poly)"
  else
    mut_ok "M5 Modbus-poly mutation detected: T10 assertion fires (0xB001 ≠ 0xA001)"
  fi
fi
rm -rf "$MUTDIR"

# --- M6: Mutate CRC16-CCITT polynomial (0x1021 → 0x2022) --------------------
# Expected: crc16-ccitt BE is NO LONGER a candidate for crc-ccitt.log (T12 catches it)
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
# Replace only the polynomial value (not the 0xFFFF init); no inline comment (avoids
# eating the closing ) that makes a compound expression uncompilable — bacnet lesson).
sed -i 's/0x1021/0x2022/' "$MUTDIR/serial-frame_analyze.py"
if ! python3 -m py_compile "$MUTDIR/serial-frame_analyze.py" 2>/dev/null; then
  mut_no "M6 CCITT-poly: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/serial-frame_analyze.py"; then
  mut_no "M6 CCITT-poly: sed had no effect"
else
  _m6_exit=0
  python3 "$MUTDIR/serial-frame_analyze.py" checksum \
    --input "$FIXTURES/crc-ccitt.log" --output "$ROOT/m6.json" 2>/dev/null || _m6_exit=$?
  if python3 - "$ROOT/m6.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
algos = d['results']['algorithms']
ccitt_be = next(
    (a for a in algos if a['name'] == 'crc16-ccitt' and a.get('little_endian') is False),
    None,
)
# T12 assertion: crc16-ccitt BE must be a candidate — SHOULD fail for the mutant
assert ccitt_be is not None and ccitt_be['candidate'] is True, "not a candidate"
PY
  then
    mut_no "M6 CCITT-poly: mutation NOT detected (still a candidate with wrong poly)"
  else
    mut_ok "M6 CCITT-poly mutation detected: T12 assertion fires (0x2022 ≠ 0x1021)"
  fi
fi
rm -rf "$MUTDIR"

# --- M7: Flip twos-comp sign (negate → identity) ----------------------------
# Expected: twos-comp8 is NO LONGER a candidate for checksum.log (T6 candidate check fails)
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
# Replace the negation (-sum(b)) with plain sum(b).  No inline comment: the lambda
# appears mid-expression and a trailing # would eat the closing comma (see M6 lesson).
sed -i 's/(-sum(b))/(sum(b))/' "$MUTDIR/serial-frame_analyze.py"
if ! python3 -m py_compile "$MUTDIR/serial-frame_analyze.py" 2>/dev/null; then
  mut_no "M7 twos-comp sign: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/serial-frame_analyze.py"; then
  mut_no "M7 twos-comp sign: sed had no effect"
else
  _m7_exit=0
  python3 "$MUTDIR/serial-frame_analyze.py" checksum \
    --input "$FIXTURES/checksum.log" --output "$ROOT/m7.json" 2>/dev/null || _m7_exit=$?
  if python3 - "$ROOT/m7.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
algos = d['results']['algorithms']
twos = next((a for a in algos if a['name'] == 'twos-comp8' and a.get('skip_first', 0) == 0), None)
# The fixture is designed for twos-comp8 — must be candidate with correct sign
assert twos is not None and twos['candidate'] is True, "twos-comp8 not a candidate"
PY
  then
    mut_no "M7 twos-comp sign: mutation NOT detected (still a candidate with wrong sign)"
  else
    mut_ok "M7 twos-comp sign flip detected: checksum.log candidate check fires"
  fi
fi
rm -rf "$MUTDIR"

# --- M8: Remove status:failed path (suppress error collection) ---------------
# Expected: malformed input returns status:complete instead of status:failed (T11 catches)
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
# Change "failed",  # sweep-all-fail → "complete",  to keep valid Python (comma intact).
# Inline comments after the value eat the comma and break the dict — use the full
# "failed",  # sweep-all-fail sentinel so sed targets only the right occurrence.
sed -i 's/"status": "failed",  # sweep-all-fail/"status": "complete",  # MUTANT-M8/' \
  "$MUTDIR/serial-frame_analyze.py"
if ! python3 -m py_compile "$MUTDIR/serial-frame_analyze.py" 2>/dev/null; then
  mut_no "M8 status-failed path: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/serial-frame_analyze.py"; then
  mut_no "M8 status-failed path: sed had no effect (status:failed not yet implemented)"
else
  _m8_exit=0
  python3 "$MUTDIR/serial-frame_analyze.py" stats \
    --input "$FIXTURES/malformed.log" --output "$ROOT/m8.json" 2>/dev/null || _m8_exit=$?
  if python3 - "$ROOT/m8.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
# T11 assertion: status must be 'failed' — SHOULD fail for mutant (it emits 'complete')
assert d['status'] == 'failed', "status not failed"
PY
  then
    mut_no "M8 status-failed path: mutation NOT detected (T11 assertion did not fire)"
  else
    mut_ok "M8 status-failed removal detected: T11 assertion fires"
  fi
fi
rm -rf "$MUTDIR"

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
