#!/usr/bin/env bash
# Test suite for niagara-hdb-read.sh (niagara-hdb.v1)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../niagara-hdb-read.sh"
FIXTURES="$HERE/fixtures/niagara-hdb-read"
mkdir -p "$FIXTURES"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ---------------------------------------------------------------------------
# Build .hdb fixture files programmatically (never inside a live target dir)
# Format: magic(4BE) + version(4BE) + config_xml_len(4BE) + xml_bytes + record_region
# ---------------------------------------------------------------------------
python3 - "$FIXTURES" <<'PY'
import struct, sys, os

out = sys.argv[1]
MAGIC = b'\xa1\x06\xf1\x1e'  # 0xA106F11E big-endian

VALID_XML = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<bajaObjectGraph version="4.0" reversibleEncodingKeySource="none" >\n'
    '<p m="h=history" t="h:HistoryConfig">\n'
    ' <p n="id" t="h:HistoryId" v="/test/TrendRecord"/>\n'
    ' <p n="recordType" t="b:TypeSpec" v="history:NumericTrendRecord"/>\n'
    ' <p n="schema" t="h:HistorySchema"'
    ' v="timestamp,baja:AbsTime;value,baja:Double"/>\n'
    ' <p n="timeZone" t="b:TimeZone" v="UTC;0;0"/>\n'
    ' <p n="source" t="b:OrdList" v="station:|slot:/test/sensor"/>\n'
    '</p>\n'
    '</bajaObjectGraph>\n'
).encode('utf-8')

def make_hdb(xml_bytes=VALID_XML, version=2, clen_override=None, extra=b''):
    clen = clen_override if clen_override is not None else len(xml_bytes)
    hdr = MAGIC + struct.pack(">I", version) + struct.pack(">I", clen)
    return hdr + xml_bytes + extra

# valid.hdb — standard numeric trend record, minimal record region
with open(os.path.join(out, 'valid.hdb'), 'wb') as f:
    f.write(make_hdb(extra=b'\x00' * 64))

# bad_magic.hdb — wrong magic, everything else zeros
bad_magic = b'\xde\xad\xbe\xef' + struct.pack(">I", 2) + struct.pack(">I", 0)
with open(os.path.join(out, 'bad_magic.hdb'), 'wb') as f:
    f.write(bad_magic)

# truncated.hdb — valid magic + version, clen claims 9999 bytes, file has only 4 extra
clen_lie = 9999
hdr = MAGIC + struct.pack(">I", 2) + struct.pack(">I", clen_lie)
with open(os.path.join(out, 'truncated.hdb'), 'wb') as f:
    f.write(hdr + b'\x00' * 4)

# zero_length.hdb — empty file, must fail header check
with open(os.path.join(out, 'zero_length.hdb'), 'wb') as f:
    pass  # 0 bytes

# header_only.hdb — valid magic, version=2, clen=0, no XML, no record region
with open(os.path.join(out, 'header_only.hdb'), 'wb') as f:
    f.write(MAGIC + struct.pack(">I", 2) + struct.pack(">I", 0))

# clen_cap.hdb — clen = 1 MiB + 1 (just over _MAX_CONFIG_BYTES=1<<20), file is large
# enough that the relative file-size bound passes, so only the absolute cap fires.
# Created as a sparse file to minimise disk usage.
_CAP = 1 << 20  # must match _MAX_CONFIG_BYTES in niagara_hdb_read.py
_clen_cap = _CAP + 1
with open(os.path.join(out, 'clen_cap.hdb'), 'wb') as f:
    f.write(MAGIC + struct.pack(">I", 2) + struct.pack(">I", _clen_cap))
    # Extend to hold the full XML region + 10-byte record region (sparse)
    f.truncate(12 + _clen_cap + 10)

# clen_max.hdb — clen = 0xFFFFFFFF (4 GiB), small file.
# Absolute cap must fire before any allocation attempt.
# M4 mutant (cap→if False) tries os.read(fd, 0xFFFFFFFF) → MemoryError under ulimit.
with open(os.path.join(out, 'clen_max.hdb'), 'wb') as f:
    f.write(MAGIC + struct.pack(">I", 2) + struct.pack(">I", 0xFFFFFFFF))
    f.write(b'\x00' * 4)  # 16-byte file total
PY

# ---------------------------------------------------------------------------
# T1: absent input → exit 2, no JSON produced
# ---------------------------------------------------------------------------
_t1_exit=0
"$SUT" --input "$ROOT/no-such.hdb" --output "$ROOT/t1.json" 2>/dev/null \
  || _t1_exit=$?
if [ "$_t1_exit" -eq 2 ] && [ ! -f "$ROOT/t1.json" ]; then
  ok "T1 absent input: exit 2, no JSON"
else
  no "T1 absent input: expected exit 2 + no JSON, got exit $_t1_exit"
fi

# ---------------------------------------------------------------------------
# T2: symlink input → exit 2 (O_NOFOLLOW guard)
# ---------------------------------------------------------------------------
ln -sf "$FIXTURES/valid.hdb" "$ROOT/sym.hdb"
_t2_exit=0
"$SUT" --input "$ROOT/sym.hdb" --output "$ROOT/t2.json" 2>/dev/null \
  || _t2_exit=$?
if [ "$_t2_exit" -eq 2 ]; then
  ok "T2 symlink input: exit 2 (O_NOFOLLOW)"
else
  no "T2 symlink input: expected exit 2, got $_t2_exit"
fi

# ---------------------------------------------------------------------------
# T3: bad magic → exit 1, status:failed, errors populated
# ---------------------------------------------------------------------------
_t3_exit=0
"$SUT" --input "$FIXTURES/bad_magic.hdb" --output "$ROOT/t3.json" 2>/dev/null \
  || _t3_exit=$?
if [ "$_t3_exit" -eq 1 ]; then
  if python3 - "$ROOT/t3.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'niagara-hdb.v1', f"bad schema: {d.get('schema')!r}"
assert d['status'] == 'failed', f"bad status: {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors list must be non-empty"
PY
  then
    ok "T3 bad magic: exit 1, status:failed, errors non-empty"
  else
    no "T3 bad magic: exit 1 but JSON missing or invalid"
  fi
else
  no "T3 bad magic: expected exit 1, got $_t3_exit"
fi

# ---------------------------------------------------------------------------
# T4: valid .hdb → exit 0, status:complete, EXACT field values asserted
# Fixture values (deterministic): config_xml_bytes=477, size_bytes=553, sha256 below.
# ---------------------------------------------------------------------------
_t4_exit=0
"$SUT" --input "$FIXTURES/valid.hdb" --output "$ROOT/t4.json" 2>/dev/null \
  || _t4_exit=$?
if [ "$_t4_exit" -eq 0 ]; then
  if python3 - "$ROOT/t4.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'niagara-hdb.v1', f"bad schema: {d.get('schema')!r}"
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
assert d['errors'] == [], f"unexpected errors: {d.get('errors')}"
hc = d['history_config']
assert hc['history_id'] == '/test/TrendRecord', \
    f"bad history_id: {hc.get('history_id')!r}"
assert hc['record_type'] == 'history:NumericTrendRecord', \
    f"bad record_type: {hc.get('record_type')!r}"
assert hc['reversible_encoding'] == 'none', \
    f"bad encoding: {hc.get('reversible_encoding')!r}"
fields = hc['schema_fields']
assert len(fields) == 2, f"expected 2 fields, got {len(fields)}: {fields}"
assert fields[0] == {'name': 'timestamp', 'type': 'baja:AbsTime'}, \
    f"bad field[0]: {fields[0]}"
assert fields[1] == {'name': 'value', 'type': 'baja:Double'}, \
    f"bad field[1]: {fields[1]}"
s = d['summary']
assert s['field_count'] == 2, f"bad field_count: {s.get('field_count')}"
assert s['version'] == 2, f"bad version: {s.get('version')}"
# Exact equality against deterministic fixture values (not presence-only)
assert s['config_xml_bytes'] == 477, \
    f"expected config_xml_bytes=477, got {s.get('config_xml_bytes')}"
assert s['record_region_bytes'] == 64, f"bad record_region: {s.get('record_region_bytes')}"
inp = d['input']
assert isinstance(inp['sha256'], str) and len(inp['sha256']) == 64, \
    f"bad sha256: {inp.get('sha256')!r}"
assert inp['size_bytes'] == 553, \
    f"expected size_bytes=553, got {inp.get('size_bytes')}"
PY
  then
    ok "T4 valid .hdb: exit 0, status:complete, all fields correct (exact equality)"
  else
    no "T4 valid .hdb: exit 0 but JSON validation failed"
  fi
else
  no "T4 valid .hdb: expected exit 0, got $_t4_exit"
fi

# ---------------------------------------------------------------------------
# T5: truncated file (clen claims 9999 but only 4 bytes follow header)
#     → exit 1, status:failed JSON emitted (not a raw traceback)
# ---------------------------------------------------------------------------
_t5_exit=0
"$SUT" --input "$FIXTURES/truncated.hdb" --output "$ROOT/t5.json" 2>/dev/null \
  || _t5_exit=$?
if [ "$_t5_exit" -eq 1 ]; then
  if python3 - "$ROOT/t5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"expected 'failed', got {d['status']!r}"
assert len(d.get('errors', [])) > 0, "errors list must be non-empty"
PY
  then
    ok "T5 truncated .hdb: exit 1, status:failed, JSON emitted"
  else
    no "T5 truncated .hdb: exit 1 but JSON missing or invalid"
  fi
else
  no "T5 truncated .hdb: expected exit 1, got $_t5_exit"
fi

# ---------------------------------------------------------------------------
# T6: --output pointing at a symlink → exit 2, victim not overwritten
# ---------------------------------------------------------------------------
echo "victim-content" > "$ROOT/victim.txt"
ln -sf "$ROOT/victim.txt" "$ROOT/out_sym.json"
_t6_exit=0
"$SUT" --input "$FIXTURES/valid.hdb" --output "$ROOT/out_sym.json" \
  2>/dev/null || _t6_exit=$?
_victim_ok=0
[ "$(cat "$ROOT/victim.txt" 2>/dev/null)" = "victim-content" ] && _victim_ok=1
if [ "$_t6_exit" -eq 2 ] && [ "$_victim_ok" -eq 1 ]; then
  ok "T6 output symlink: exit 2, victim not overwritten"
else
  no "T6 output symlink: expected exit 2 + victim intact, got exit $_t6_exit (victim_ok=$_victim_ok)"
fi

# ---------------------------------------------------------------------------
# T7: zero-length input → exit 1, status:failed (too small for header)
# ---------------------------------------------------------------------------
_t7_exit=0
"$SUT" --input "$FIXTURES/zero_length.hdb" --output "$ROOT/t7.json" 2>/dev/null \
  || _t7_exit=$?
if [ "$_t7_exit" -eq 1 ]; then
  if python3 - "$ROOT/t7.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"expected 'failed', got {d['status']!r}"
assert len(d.get('errors', [])) > 0, "errors list must be non-empty"
PY
  then
    ok "T7 zero-length input: exit 1, status:failed"
  else
    no "T7 zero-length input: exit 1 but JSON missing or invalid"
  fi
else
  no "T7 zero-length input: expected exit 1, got $_t7_exit"
fi

# ---------------------------------------------------------------------------
# T8: clen=0 header-only → exit 0, status:complete (no XML bytes, no record region)
# ---------------------------------------------------------------------------
_t8_exit=0
"$SUT" --input "$FIXTURES/header_only.hdb" --output "$ROOT/t8.json" 2>/dev/null \
  || _t8_exit=$?
if [ "$_t8_exit" -eq 0 ]; then
  if python3 - "$ROOT/t8.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"expected 'complete', got {d['status']!r}"
assert d['errors'] == [], f"unexpected errors: {d.get('errors')}"
s = d['summary']
assert s['config_xml_bytes'] == 0, f"expected 0, got {s.get('config_xml_bytes')}"
assert s['record_region_bytes'] == 0, f"expected 0, got {s.get('record_region_bytes')}"
assert s['version'] == 2, f"expected 2, got {s.get('version')}"
PY
  then
    ok "T8 clen=0 header-only: exit 0, status:complete"
  else
    no "T8 clen=0 header-only: exit 0 but JSON validation failed"
  fi
else
  no "T8 clen=0 header-only: expected exit 0, got $_t8_exit"
fi

# ---------------------------------------------------------------------------
# T9: --output points at a pre-existing regular file → exit 2 (O_EXCL guard)
# ---------------------------------------------------------------------------
echo "existing-output" > "$ROOT/pre_existing.json"
_t9_exit=0
"$SUT" --input "$FIXTURES/valid.hdb" --output "$ROOT/pre_existing.json" \
  2>/dev/null || _t9_exit=$?
if [ "$_t9_exit" -eq 2 ]; then
  ok "T9 pre-existing output: exit 2 (O_CREAT|O_EXCL refused)"
else
  no "T9 pre-existing output: expected exit 2, got $_t9_exit"
fi

# ---------------------------------------------------------------------------
# T10: FIFO input → exit 2 within ~3 s (S_ISREG guard — RED before fix)
# Without the O_NONBLOCK+S_ISREG fix the tool blocks at open() and hangs.
# timeout exits 124 on timeout; we expect exit 2.
# ---------------------------------------------------------------------------
mkfifo "$ROOT/test.fifo"
_t10_exit=0
timeout 3 "$SUT" --input "$ROOT/test.fifo" --output "$ROOT/t10.json" \
  2>/dev/null || _t10_exit=$?
if [ "$_t10_exit" -eq 2 ]; then
  ok "T10 FIFO input: exit 2 within timeout (S_ISREG guard)"
else
  no "T10 FIFO input: expected exit 2, got $_t10_exit (124=timeout/hang, other=wrong exit)"
fi

# ---------------------------------------------------------------------------
# T11: clen just over _MAX_CONFIG_BYTES with sufficient file bytes
#      → exit 1, status:failed (absolute cap — RED before fix)
# Without the cap, the tool reads the full region (zeros), parses empty XML,
# and exits 0 status:complete.
# ---------------------------------------------------------------------------
_t11_exit=0
"$SUT" --input "$FIXTURES/clen_cap.hdb" --output "$ROOT/t11.json" 2>/dev/null \
  || _t11_exit=$?
if [ "$_t11_exit" -eq 1 ]; then
  if python3 - "$ROOT/t11.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"expected 'failed', got {d['status']!r}"
assert len(d.get('errors', [])) > 0, "errors list must be non-empty"
PY
  then
    ok "T11 absolute clen cap: exit 1, status:failed"
  else
    no "T11 absolute clen cap: exit 1 but JSON missing or invalid"
  fi
else
  no "T11 absolute clen cap: expected exit 1, got $_t11_exit"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: niagara-hdb mutation controls --"
# ---------------------------------------------------------------------------
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/niagara_hdb_read.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  niagara_hdb_read.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi
MUTDIR="$(mktemp -d)"

# --- M1: Remove os.O_NOFOLLOW guard on input --------------------------------
# Expected: symlink input is followed instead of rejected → T2 assertion fails
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/os\.O_RDONLY | _O_NOFOLLOW/os.O_RDONLY/' "$MUTDIR/niagara_hdb_read.py"
if ! python3 -m py_compile "$MUTDIR/niagara_hdb_read.py" 2>/dev/null; then
  mut_no "M1 O_NOFOLLOW input: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_hdb_read.py"; then
  mut_no "M1 O_NOFOLLOW input: sed had no effect"
else
  _m1_exit=0
  python3 "$MUTDIR/niagara_hdb_read.py" \
    --input "$ROOT/sym.hdb" --output "$ROOT/m1.json" 2>/dev/null || _m1_exit=$?
  if [ "$_m1_exit" -ne 2 ]; then
    mut_ok "M1 O_NOFOLLOW input removal detected (exit $_m1_exit, not 2)"
  else
    mut_no "M1 O_NOFOLLOW input: mutation NOT detected (still exits 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M2: Invert magic check -------------------------------------------------
# Expected: valid .hdb is now rejected → T4 assertion fails
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/if header\[:4\] != _MAGIC:/if header[:4] == _MAGIC:  # MUTANT/' \
  "$MUTDIR/niagara_hdb_read.py"
if ! python3 -m py_compile "$MUTDIR/niagara_hdb_read.py" 2>/dev/null; then
  mut_no "M2 magic-check: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_hdb_read.py"; then
  mut_no "M2 magic-check: sed had no effect"
else
  _m2_exit=0
  python3 "$MUTDIR/niagara_hdb_read.py" \
    --input "$FIXTURES/valid.hdb" --output "$ROOT/m2.json" 2>/dev/null || _m2_exit=$?
  if [ "$_m2_exit" -ne 0 ]; then
    mut_ok "M2 magic-check inversion detected (valid .hdb rejected, exit $_m2_exit)"
  else
    mut_no "M2 magic-check: mutation NOT detected (still exits 0)"
  fi
fi
rm -rf "$MUTDIR"

# --- M3: Clear schema_fields list (always return []) -----------------------
# Expected: field_count becomes 0, not 2 → T4 assertion on field_count fails
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i "s/result\['schema_fields'\] = fields/result['schema_fields'] = []  # MUTANT/" \
  "$MUTDIR/niagara_hdb_read.py"
if ! python3 -m py_compile "$MUTDIR/niagara_hdb_read.py" 2>/dev/null; then
  mut_no "M3 schema-fields: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_hdb_read.py"; then
  mut_no "M3 schema-fields: sed had no effect"
else
  _m3_exit=0
  python3 "$MUTDIR/niagara_hdb_read.py" \
    --input "$FIXTURES/valid.hdb" --output "$ROOT/m3.json" 2>/dev/null || _m3_exit=$?
  _m3_count="-1"
  if [ -f "$ROOT/m3.json" ]; then
    _m3_count="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m3.json')); print(d['summary']['field_count'])" \
      2>/dev/null || echo "-1")"
  fi
  if [ "$_m3_count" != "2" ]; then
    mut_ok "M3 schema-fields cleared: field_count='$_m3_count' not 2 — DETECTED"
  else
    mut_no "M3 schema-fields: mutation NOT detected (field_count still 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M4: Remove absolute clen cap (DoS / OOM guard) ------------------------
# clen_max.hdb has clen=0xFFFFFFFF; original must exit 1 + emit JSON.
# Mutant (cap check → if False:) has no bound; under ulimit -v the
# os.read(fd, 0xFFFFFFFF) call fails with MemoryError → no JSON produced.
MUTDIR="$(mktemp -d)"

# First verify original behaviour under restricted memory
_m4_orig_exit=0
(ulimit -v 1000000; python3 "$ORIG_PY" \
  --input "$FIXTURES/clen_max.hdb" --output "$ROOT/m4_orig.json" 2>/dev/null) \
  || _m4_orig_exit=$?
_m4_orig_status=""
if [ -f "$ROOT/m4_orig.json" ]; then
  _m4_orig_status="$(python3 -c \
    "import json; print(json.load(open('$ROOT/m4_orig.json'))['status'])" \
    2>/dev/null || echo "")"
fi

if [ "$_m4_orig_exit" -eq 1 ] && [ "$_m4_orig_status" = "failed" ]; then
  # Build mutant: replace absolute cap guard with if False:
  cp -a "$SUT_DIR/." "$MUTDIR/"
  sed -i 's/if clen > _MAX_CONFIG_BYTES:/if False:  # MUTANT-M4/' \
    "$MUTDIR/niagara_hdb_read.py"
  if ! python3 -m py_compile "$MUTDIR/niagara_hdb_read.py" 2>/dev/null; then
    mut_no "M4 clen cap: mutant failed py_compile"
  elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_hdb_read.py"; then
    mut_no "M4 clen cap: sed had no effect (guard pattern not found)"
  else
    _m4_mut_exit=0
    (ulimit -v 1000000; python3 "$MUTDIR/niagara_hdb_read.py" \
      --input "$FIXTURES/clen_max.hdb" --output "$ROOT/m4_mut.json" 2>/dev/null) \
      || _m4_mut_exit=$?
    if [ ! -f "$ROOT/m4_mut.json" ]; then
      mut_ok "M4 clen cap: mutant crashed (no JSON emitted) — DETECTED"
    else
      mut_no "M4 clen cap: mutant produced JSON — NOT detected (cap guard not effective)"
    fi
  fi
else
  mut_no "M4 clen cap: original did not produce exit 1 + status:failed \
(exit=$_m4_orig_exit status=${_m4_orig_status:-missing}); fix Fix-2 first"
fi
rm -rf "$MUTDIR"

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
