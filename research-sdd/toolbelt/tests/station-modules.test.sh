#!/usr/bin/env bash
# Test suite for station-modules.sh (station-modules.v1)
# TDD: tests written before implementation.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../station-modules.sh"
FIXTURES="$HERE/fixtures/station-modules"
mkdir -p "$FIXTURES"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ---------------------------------------------------------------------------
# Build hermetic fixtures (under tests/fixtures/, never inside a live target)
# ---------------------------------------------------------------------------
python3 - "$FIXTURES" <<'PY'
import io, json, os, sys, zipfile

out = sys.argv[1]

def mkdir(p):
    os.makedirs(p, exist_ok=True)

def write_bin(p, data):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb') as f:
        f.write(data)

def write_text(p, text):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w', encoding='utf-8') as f:
        f.write(text)

def make_zip_bog(path, xml_content):
    """Create a ZIP .bog with file.xml. Fixed date_time for determinism."""
    buf = io.BytesIO()
    zi = zipfile.ZipInfo('file.xml', date_time=(2024, 1, 1, 0, 0, 0))
    zi.compress_type = zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr(zi, xml_content)
    write_bin(path, buf.getvalue())

def make_jar(path, module_name, part_name, profile, version, types, deps):
    """Create a fake module JAR with META-INF/module.xml."""
    types_xml = ''.join(f'  <type name="{t}"/>\n' for t in types)
    deps_xml = ''.join(f'  <dependency name="{d}"/>\n' for d in deps)
    xml = (
        '<?xml version="1.0"?>\n'
        f'<module name="{part_name}" moduleName="{module_name}"'
        f' runtimeProfile="{profile}" vendor="Tridium"'
        f' vendorVersion="{version}">\n'
        f'{types_xml}'
        f'{deps_xml}'
        '</module>\n'
    )
    buf = io.BytesIO()
    zi = zipfile.ZipInfo('META-INF/module.xml', date_time=(2024, 1, 1, 0, 0, 0))
    zi.compress_type = zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr(zi, xml)
    write_bin(path, buf.getvalue())

# --- Station XML: references baja (b=baja) and testmodule (d=testmodule) ---
# baja-rt is present in the fake install; testmodule-rt is MISSING.
STATION_XML = """<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station' m='b=baja d=testmodule'>
  <p n='Services' h='2' t='b:ServiceContainer'>
   <p n='TestService' h='3' t='d:TestService'/>
  </p>
 </p>
</bajaObjectGraph>"""

make_zip_bog(os.path.join(out, 'valid.bog'), STATION_XML)
write_text(os.path.join(out, 'plaintext.bog'), STATION_XML)

# --- Empty station (no module references) ---
EMPTY_XML = """<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station'>
 </p>
</bajaObjectGraph>"""
make_zip_bog(os.path.join(out, 'empty_station.bog'), EMPTY_XML)

# --- Malformed bog (not ZIP, not XML) ---
write_bin(os.path.join(out, 'binary.bog'),
    bytes([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01] * 256))

# --- ZIP bomb: file.xml decompresses to > 32 MiB ---
_bomb_path = os.path.join(out, 'bomb.bog')
if not os.path.exists(_bomb_path):
    _cap = 32 * 1024 * 1024
    _content = b'A' * (_cap + 1)
    _buf = io.BytesIO()
    with zipfile.ZipFile(_buf, 'w', zipfile.ZIP_DEFLATED) as _z:
        _z.writestr('file.xml', _content)
    write_bin(_bomb_path, _buf.getvalue())

# --- Corrupted deflate ZIP (triggers zlib.error inside zf.open) ---
import struct as _struct

def _make_corrupt_deflate(path):
    _buf = io.BytesIO()
    _zi = zipfile.ZipInfo('file.xml', date_time=(2024, 1, 1, 0, 0, 0))
    _zi.compress_type = zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(_buf, 'w') as _z:
        _z.writestr(_zi, '<?xml version="1.0"?><root/>')
    _raw = bytearray(_buf.getvalue())
    # Corrupt the compressed data bytes
    fname_len = _struct.unpack_from('<H', _raw, 26)[0]
    extra_len = _struct.unpack_from('<H', _raw, 28)[0]
    data_start = 30 + fname_len + extra_len
    for i in range(data_start + 5, min(data_start + 20, len(_raw) - 20)):
        _raw[i] ^= 0xAA
    write_bin(path, bytes(_raw))

_make_corrupt_deflate(os.path.join(out, 'corrupt_deflate.bog'))

# --- Fake Niagara install: modules/ with some JARs ---
install_dir = os.path.join(out, 'fake_install')
modules_dir = os.path.join(install_dir, 'modules')
mkdir(modules_dir)

make_jar(
    os.path.join(modules_dir, 'baja-rt.jar'),
    module_name='baja', part_name='baja-rt', profile='rt', version='4.14.0',
    types=['Station', 'ServiceContainer'], deps=['nre-rt'],
)
make_jar(
    os.path.join(modules_dir, 'nre-rt.jar'),
    module_name='nre', part_name='nre-rt', profile='rt', version='4.14.0',
    types=['NetworkRuntime'], deps=[],
)
# testmodule-rt.jar is intentionally NOT created -> missing_parts will contain it

# --- Empty install (modules/ dir exists but is empty) ---
empty_install = os.path.join(out, 'empty_install')
mkdir(os.path.join(empty_install, 'modules'))

# --- type_mismatch.bog: baja IS in fake_install but references UnknownType ---
# baja-rt.jar has types [Station, ServiceContainer]; UnknownType is absent.
# After the fix: module installed → missing_parts empty, types_unresolved=['UnknownType']
TYPE_MISMATCH_XML = """<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station' m='b=baja'>
  <p n='Test' h='2' t='b:UnknownType'/>
 </p>
</bajaObjectGraph>"""
make_zip_bog(os.path.join(out, 'type_mismatch.bog'), TYPE_MISMATCH_XML)

# --- hyphen_alias.bog: alias with a hyphen (honbac-util) in t= attribute ---
# Old regex [A-Za-z0-9_]+: misses honbac-util:BACnetNetwork.
# After the fix: honBACnetUtilities appears in modules with types_referenced.
HYPHEN_ALIAS_XML = """<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' m='b=baja honbac-util=honBACnetUtilities'>
  <p n='Station' h='2' t='b:Station'/>
  <p n='BACnet' h='3' t='honbac-util:BACnetNetwork'/>
 </p>
</bajaObjectGraph>"""
make_zip_bog(os.path.join(out, 'hyphen_alias.bog'), HYPHEN_ALIAS_XML)

# --- bigbomb.bog: file.xml inflates to ~1 GiB (all zeros), tiny on disk ---
# Used for M_BOMB mutation: mutant read() OOMs under ulimit; original bounded.
_bigbomb_path = os.path.join(out, 'bigbomb.bog')
if not os.path.exists(_bigbomb_path):
    _big_content = b'\x00' * (1024 * 1024 * 1024)  # 1 GiB zeros
    _big_buf = io.BytesIO()
    with zipfile.ZipFile(_big_buf, 'w', zipfile.ZIP_DEFLATED) as _z:
        _z.writestr('file.xml', _big_content)
    write_bin(_bigbomb_path, _big_buf.getvalue())

print("Fixtures built OK")
PY

# ---------------------------------------------------------------------------
# T1: absent bog input → exit 2, no JSON
# ---------------------------------------------------------------------------
_t1_exit=0
"$SUT" --input "$ROOT/no-such.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t1.json" 2>/dev/null || _t1_exit=$?
if [ "$_t1_exit" -eq 2 ] && [ ! -f "$ROOT/t1.json" ]; then
  ok "T1 absent input: exit 2, no JSON"
else
  no "T1 absent input: expected exit 2 + no JSON, got exit $_t1_exit"
fi

# ---------------------------------------------------------------------------
# T2: symlink bog input → exit 2 (O_NOFOLLOW)
# ---------------------------------------------------------------------------
ln -sf "$FIXTURES/valid.bog" "$ROOT/sym.bog"
_t2_exit=0
"$SUT" --input "$ROOT/sym.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t2.json" 2>/dev/null || _t2_exit=$?
if [ "$_t2_exit" -eq 2 ]; then
  ok "T2 symlink input: exit 2 (O_NOFOLLOW)"
else
  no "T2 symlink input: expected exit 2, got $_t2_exit"
fi

# ---------------------------------------------------------------------------
# T3: absent install root → exit 2
# ---------------------------------------------------------------------------
_t3_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --install "$ROOT/no_such_install" \
  --output "$ROOT/t3.json" 2>/dev/null || _t3_exit=$?
if [ "$_t3_exit" -eq 2 ] && [ ! -f "$ROOT/t3.json" ]; then
  ok "T3 absent install root: exit 2, no JSON"
else
  no "T3 absent install root: expected exit 2 + no JSON, got exit $_t3_exit"
fi

# ---------------------------------------------------------------------------
# T4: valid ZIP bog + fake install → exit 0, status:complete
#     missing_parts contains testmodule-rt (proves instrument looked and found gap)
# ---------------------------------------------------------------------------
_t4_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t4.json" 2>/dev/null || _t4_exit=$?
if [ "$_t4_exit" -eq 0 ]; then
  if python3 - "$ROOT/t4.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'station-modules.v1', f"bad schema: {d.get('schema')!r}"
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
assert d['input']['format'] == 'zip-xml', f"bad format: {d['input'].get('format')!r}"
s = d['summary']
# Instrument must prove it looked: jars_scanned > 0
assert s['jars_scanned'] > 0, f"jars_scanned must be > 0, got {s.get('jars_scanned')}"
# baja is present in install; testmodule is missing
assert s['modules_referenced'] > 0, f"modules_referenced must be > 0"
mp = d.get('missing_parts', {})
assert len(mp) > 0, f"missing_parts must be non-empty (testmodule-rt absent from install)"
assert any('testmodule' in k for k in mp), \
    f"testmodule-related key must be in missing_parts, got {list(mp)!r}"
PY
  then
    ok "T4 valid ZIP bog: exit 0, schema/status/counts correct, testmodule-rt missing"
  else
    no "T4 valid ZIP bog: exit 0 but JSON validation failed"
  fi
else
  no "T4 valid ZIP bog: expected exit 0, got $_t4_exit"
fi

# ---------------------------------------------------------------------------
# T5: valid bog — baja module is installed; baja appears in modules dict
# ---------------------------------------------------------------------------
_t5_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t5.json" 2>/dev/null || _t5_exit=$?
if [ "$_t5_exit" -eq 0 ]; then
  if python3 - "$ROOT/t5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete'
modules = d.get('modules', {})
assert 'baja' in modules, f"baja must be in modules, got {sorted(modules)!r}"
baja = modules['baja']
assert 'baja-rt' in baja.get('installed_parts', []), \
    f"baja-rt must be in installed_parts for baja, got {baja.get('installed_parts')!r}"
# Types referenced from the station XML
assert 'Station' in baja.get('types_referenced', []) or \
       'ServiceContainer' in baja.get('types_referenced', []), \
    f"baja types_referenced must include Station or ServiceContainer"
PY
  then
    ok "T5 baja module installed: baja-rt in installed_parts, types referenced"
  else
    no "T5 baja module installed: JSON validation failed"
  fi
else
  no "T5 baja module installed: expected exit 0, got $_t5_exit"
fi

# ---------------------------------------------------------------------------
# T6: empty station bog (no module references) → exit 0, status:complete,
#     modules_referenced=0 (proves instrument looked — §7 anti-silent-zero)
# ---------------------------------------------------------------------------
_t6_exit=0
"$SUT" --input "$FIXTURES/empty_station.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t6.json" 2>/dev/null || _t6_exit=$?
if [ "$_t6_exit" -eq 0 ]; then
  if python3 - "$ROOT/t6.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
s = d['summary']
assert s['modules_referenced'] == 0, \
    f"modules_referenced must be 0 for empty station, got {s.get('modules_referenced')}"
assert s['missing_parts'] == 0, \
    f"missing_parts must be 0 for empty station, got {s.get('missing_parts')}"
# Schema proves instrument ran
assert d['schema'] == 'station-modules.v1'
PY
  then
    ok "T6 empty station: exit 0, status:complete, modules_referenced=0 (proves looked)"
  else
    no "T6 empty station: exit 0 but JSON validation failed"
  fi
else
  no "T6 empty station: expected exit 0, got $_t6_exit"
fi

# ---------------------------------------------------------------------------
# T7: plaintext XML bog → exit 0, status:complete, format=plaintext-xml
# ---------------------------------------------------------------------------
_t7_exit=0
"$SUT" --input "$FIXTURES/plaintext.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t7.json" 2>/dev/null || _t7_exit=$?
if [ "$_t7_exit" -eq 0 ]; then
  if python3 - "$ROOT/t7.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
assert d['input']['format'] == 'plaintext-xml', \
    f"bad format: {d['input'].get('format')!r}"
PY
  then
    ok "T7 plaintext bog: exit 0, format=plaintext-xml"
  else
    no "T7 plaintext bog: exit 0 but JSON validation failed"
  fi
else
  no "T7 plaintext bog: expected exit 0, got $_t7_exit"
fi

# ---------------------------------------------------------------------------
# T8: binary (non-XML, non-ZIP) bog → exit 1, status:failed JSON
# ---------------------------------------------------------------------------
_t8_exit=0
"$SUT" --input "$FIXTURES/binary.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t8.json" 2>/dev/null || _t8_exit=$?
if [ "$_t8_exit" -eq 1 ]; then
  if python3 - "$ROOT/t8.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"binary bog must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for failed status"
PY
  then
    ok "T8 binary bog: exit 1, status:failed, errors non-empty"
  else
    no "T8 binary bog: exit 1 but JSON validation failed"
  fi
else
  no "T8 binary bog: expected exit 1, got $_t8_exit"
fi

# ---------------------------------------------------------------------------
# T9: ZIP bomb (file.xml > 32 MiB) → exit 1, status:failed (bounded read)
# ---------------------------------------------------------------------------
_t9_exit=0
"$SUT" --input "$FIXTURES/bomb.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t9.json" 2>/dev/null || _t9_exit=$?
if [ "$_t9_exit" -eq 1 ]; then
  if python3 - "$ROOT/t9.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"bomb must be failed, got {d.get('status')!r}"
assert d.get('truncated') is True, f"bomb must set truncated=True"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for bomb"
PY
  then
    ok "T9 ZIP bomb (>32 MiB): exit 1, status:failed, truncated:true"
  else
    no "T9 ZIP bomb: exit 1 but JSON validation failed"
  fi
else
  no "T9 ZIP bomb: expected exit 1, got $_t9_exit"
fi

# ---------------------------------------------------------------------------
# T10: corrupted deflate ZIP → exit 1, status:failed JSON (zip-read guard)
# ---------------------------------------------------------------------------
_t10_exit=0
"$SUT" --input "$FIXTURES/corrupt_deflate.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t10.json" 2>/dev/null || _t10_exit=$?
if [ "$_t10_exit" -eq 1 ] && [ -f "$ROOT/t10.json" ]; then
  if python3 - "$ROOT/t10.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"corrupt ZIP must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for corrupt ZIP"
PY
  then
    ok "T10 corrupt deflate: exit 1, status:failed JSON (zip-read guard)"
  else
    no "T10 corrupt deflate: exit 1, JSON present but validation failed"
  fi
else
  no "T10 corrupt deflate: expected exit 1 + JSON, got exit=$_t10_exit json=$([ -f "$ROOT/t10.json" ] && echo present || echo absent)"
fi

# ---------------------------------------------------------------------------
# T11: --output symlink → exit 2, victim not overwritten
# ---------------------------------------------------------------------------
echo "victim" > "$ROOT/victim.txt"
ln -sf "$ROOT/victim.txt" "$ROOT/out_sym.json"
_t11_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/out_sym.json" 2>/dev/null || _t11_exit=$?
_victim_ok=0
[ "$(cat "$ROOT/victim.txt" 2>/dev/null)" = "victim" ] && _victim_ok=1
if [ "$_t11_exit" -eq 2 ] && [ "$_victim_ok" -eq 1 ]; then
  ok "T11 output symlink: exit 2, victim not overwritten"
else
  no "T11 output symlink: expected exit 2 + victim intact, got exit $_t11_exit (victim_ok=$_victim_ok)"
fi

# ---------------------------------------------------------------------------
# T12: --output pre-existing → exit 2 (O_CREAT|O_EXCL)
# ---------------------------------------------------------------------------
echo "existing" > "$ROOT/pre_existing.json"
_t12_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/pre_existing.json" 2>/dev/null || _t12_exit=$?
if [ "$_t12_exit" -eq 2 ]; then
  ok "T12 pre-existing output: exit 2 (O_CREAT|O_EXCL refused)"
else
  no "T12 pre-existing output: expected exit 2, got $_t12_exit"
fi

# ---------------------------------------------------------------------------
# T13: FIFO bog input → exit 2, no hang (O_NONBLOCK guard)
# ---------------------------------------------------------------------------
_t13_fifo="$ROOT/input.fifo"
mkfifo "$_t13_fifo" 2>/dev/null || true
_t13_exit=0
timeout 5 "$SUT" --input "$_t13_fifo" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t13.json" 2>/dev/null || _t13_exit=$?
if [ "$_t13_exit" -eq 2 ]; then
  ok "T13 FIFO input: exit 2, no hang (O_NONBLOCK guard)"
elif [ "$_t13_exit" -eq 124 ]; then
  no "T13 FIFO input: HUNG (timeout 5 s fired — O_NONBLOCK missing)"
else
  no "T13 FIFO input: expected exit 2, got $_t13_exit"
fi

# ---------------------------------------------------------------------------
# T14: input sha256 and size_bytes present in JSON
# ---------------------------------------------------------------------------
_t14_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t14.json" 2>/dev/null || _t14_exit=$?
if [ "$_t14_exit" -eq 0 ]; then
  if python3 - "$ROOT/t14.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
sha = d.get('input', {}).get('sha256', '')
assert len(sha) == 64, f"sha256 must be 64-char hex, got {sha!r}"
assert all(c in '0123456789abcdef' for c in sha), f"sha256 not hex"
size = d.get('input', {}).get('size_bytes', 0)
assert size > 0, f"size_bytes must be > 0, got {size}"
PY
  then
    ok "T14 input metadata: sha256 and size_bytes present and valid"
  else
    no "T14 input metadata: JSON validation failed"
  fi
else
  no "T14 input metadata: expected exit 0, got $_t14_exit"
fi

# ---------------------------------------------------------------------------
# T15: absent modules/ dir → status:failed, missing_parts EMPTY (not false all-missing)
# ---------------------------------------------------------------------------
_t15_no_mod_install="$ROOT/no_modules_install"
mkdir -p "$_t15_no_mod_install"  # NO modules/ subdir
_t15_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --install "$_t15_no_mod_install" \
  --output "$ROOT/t15.json" 2>/dev/null || _t15_exit=$?
_t15_ok=false
if [ "$_t15_exit" -eq 2 ] && [ ! -f "$ROOT/t15.json" ]; then
  _t15_ok=true
elif [ "$_t15_exit" -eq 1 ] && [ -f "$ROOT/t15.json" ]; then
  python3 - "$ROOT/t15.json" <<'PY' 2>/dev/null && _t15_ok=true
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for install error"
# KEY: absent modules/ must NOT produce a false "all modules missing" report
mp = d.get('missing_parts', {})
assert len(mp) == 0, f"absent modules/ must not produce false missing_parts, got {list(mp)!r}"
PY
fi
if $_t15_ok; then
  ok "T15 absent modules/ dir: install error reported, no false all-missing"
else
  _t15_mp="$([ -f "$ROOT/t15.json" ] && python3 -c \
    "import json; d=json.load(open('$ROOT/t15.json')); print(len(d.get('missing_parts',{})))" \
    2>/dev/null || echo 'no JSON')"
  no "T15 absent modules/ dir: expected install error, got exit=$_t15_exit missing_parts=$_t15_mp"
fi

# ---------------------------------------------------------------------------
# T16: unreadable modules/ dir → status:failed, no false all-missing
#      (skip as root where chmod 000 can still be read)
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  ok "T16 unreadable modules/ dir: SKIP (running as root, chmod 000 has no effect)"
else
  _t16_unread_install="$ROOT/unreadable_install"
  mkdir -p "$_t16_unread_install/modules"
  chmod 000 "$_t16_unread_install/modules"
  _t16_exit=0
  "$SUT" --input "$FIXTURES/valid.bog" --install "$_t16_unread_install" \
    --output "$ROOT/t16.json" 2>/dev/null || _t16_exit=$?
  chmod 755 "$_t16_unread_install/modules"  # restore for cleanup
  _t16_ok=false
  if [ "$_t16_exit" -eq 2 ] && [ ! -f "$ROOT/t16.json" ]; then
    _t16_ok=true
  elif [ "$_t16_exit" -eq 1 ] && [ -f "$ROOT/t16.json" ]; then
    python3 - "$ROOT/t16.json" <<'PY' 2>/dev/null && _t16_ok=true
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty"
mp = d.get('missing_parts', {})
assert len(mp) == 0, f"unreadable modules/ must not produce false missing_parts, got {list(mp)!r}"
PY
  fi
  if $_t16_ok; then
    ok "T16 unreadable modules/ dir: install error reported, no false all-missing"
  else
    _t16_mp="$([ -f "$ROOT/t16.json" ] && python3 -c \
      "import json; d=json.load(open('$ROOT/t16.json')); print(len(d.get('missing_parts',{})))" \
      2>/dev/null || echo 'no JSON')"
    no "T16 unreadable modules/ dir: expected install error, got exit=$_t16_exit missing_parts=$_t16_mp"
  fi
fi

# ---------------------------------------------------------------------------
# T17: modules/ is a symlink escaping the install root → install error, no false all-missing
# ---------------------------------------------------------------------------
_t17_escape_target="$ROOT/escape_target"
mkdir -p "$_t17_escape_target"
_t17_symlink_install="$ROOT/symlink_install"
mkdir -p "$_t17_symlink_install"
ln -sf "$_t17_escape_target" "$_t17_symlink_install/modules"
_t17_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --install "$_t17_symlink_install" \
  --output "$ROOT/t17.json" 2>/dev/null || _t17_exit=$?
_t17_ok=false
if [ "$_t17_exit" -eq 2 ] && [ ! -f "$ROOT/t17.json" ]; then
  _t17_ok=true
elif [ "$_t17_exit" -eq 1 ] && [ -f "$ROOT/t17.json" ]; then
  python3 - "$ROOT/t17.json" <<'PY' 2>/dev/null && _t17_ok=true
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for symlink escape"
mp = d.get('missing_parts', {})
assert len(mp) == 0, f"escaped modules/ must not produce false missing_parts, got {list(mp)!r}"
PY
fi
if $_t17_ok; then
  ok "T17 modules/ symlink escape: install error reported, no false all-missing"
else
  _t17_mp="$([ -f "$ROOT/t17.json" ] && python3 -c \
    "import json; d=json.load(open('$ROOT/t17.json')); print(len(d.get('missing_parts',{})))" \
    2>/dev/null || echo 'no JSON')"
  no "T17 modules/ symlink escape: expected install error, got exit=$_t17_exit missing_parts=$_t17_mp"
fi

# ---------------------------------------------------------------------------
# T18: module IS installed (baja-rt present) but referenced type not in any part
#      → type-not-resolved, NOT a missing-part (false alarm fixed)
# ---------------------------------------------------------------------------
_t18_exit=0
"$SUT" --input "$FIXTURES/type_mismatch.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t18.json" 2>/dev/null || _t18_exit=$?
if [ "$_t18_exit" -eq 0 ]; then
  if python3 - "$ROOT/t18.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
modules = d.get('modules', {})
baja = modules.get('baja', {})
# baja IS installed — must NOT appear in missing_parts
mp = d.get('missing_parts', {})
assert 'baja-rt' not in mp, \
    f"baja-rt must NOT be in missing_parts (baja IS installed), got {list(mp)!r}"
assert len(mp) == 0, f"missing_parts must be empty when module is installed, got {list(mp)!r}"
# UnknownType must appear in types_unresolved (version/profile mismatch)
tu = baja.get('types_unresolved', [])
assert 'UnknownType' in tu, \
    f"UnknownType must be in types_unresolved (not missing_parts), got {tu!r}"
# baja-rt must appear in installed_parts (module IS installed)
ip = baja.get('installed_parts', [])
assert 'baja-rt' in ip, f"baja-rt must be in installed_parts, got {ip!r}"
PY
  then
    ok "T18 module installed, type unresolved: no false alarm in missing_parts, types_unresolved correct"
  else
    no "T18 module installed, type unresolved: JSON validation failed"
  fi
else
  no "T18 module installed, type unresolved: expected exit 0, got $_t18_exit"
fi

# ---------------------------------------------------------------------------
# T19: hyphenated alias (honbac-util:BACnetNetwork) → resolved, types_referenced populated
# ---------------------------------------------------------------------------
_t19_exit=0
"$SUT" --input "$FIXTURES/hyphen_alias.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t19.json" 2>/dev/null || _t19_exit=$?
if [ "$_t19_exit" -eq 0 ]; then
  if python3 - "$ROOT/t19.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
modules = d.get('modules', {})
# honBACnetUtilities must be tracked via the hyphenated alias honbac-util
assert 'honBACnetUtilities' in modules, \
    f"honBACnetUtilities must be in modules (via hyphenated alias), got {sorted(modules)!r}"
hon = modules['honBACnetUtilities']
# BACnetNetwork must appear in types_referenced (hyphenated alias resolved)
tr = hon.get('types_referenced', [])
assert 'BACnetNetwork' in tr, \
    f"BACnetNetwork must be in types_referenced (hyphenated alias), got {tr!r}"
# unresolved_aliases must be 0 (alias was declared in m=)
s = d.get('summary', {})
assert 'unresolved_aliases' in s, "unresolved_aliases must be in summary"
assert s['unresolved_aliases'] == 0, \
    f"unresolved_aliases must be 0, got {s.get('unresolved_aliases')!r}"
PY
  then
    ok "T19 hyphenated alias: BACnetNetwork in types_referenced, unresolved_aliases=0"
  else
    no "T19 hyphenated alias: JSON validation failed"
  fi
else
  no "T19 hyphenated alias: expected exit 0, got $_t19_exit"
fi

# ---------------------------------------------------------------------------
# T20: plaintext bog over 32 MiB cap → exit 1, status:failed, truncated:true
# ---------------------------------------------------------------------------
python3 -c "
import sys
with open('$ROOT/plaintext_bomb.bog', 'wb') as f:
    # XML-ish start (passes XML detection) + content exceeding 32 MiB cap
    header = b'<?xml version=\"1.0\"?><r>'
    f.write(header + b'A' * (32 * 1024 * 1024))
" 2>/dev/null
_t20_exit=0
"$SUT" --input "$ROOT/plaintext_bomb.bog" --install "$FIXTURES/fake_install" \
  --output "$ROOT/t20.json" 2>/dev/null || _t20_exit=$?
if [ "$_t20_exit" -eq 1 ]; then
  if python3 - "$ROOT/t20.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"plaintext bomb must be failed, got {d.get('status')!r}"
assert d.get('truncated') is True, f"plaintext bomb must set truncated=True, got {d.get('truncated')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for plaintext bomb"
PY
  then
    ok "T20 plaintext cap (>32 MiB): exit 1, status:failed, truncated:true"
  else
    no "T20 plaintext cap: exit 1 but JSON validation failed"
  fi
else
  no "T20 plaintext cap: expected exit 1, got $_t20_exit"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: station-modules mutation controls --"
# ---------------------------------------------------------------------------
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/station_modules.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  station_modules.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi
MUTDIR="$(mktemp -d)"

# --- M1: Remove O_NOFOLLOW from _open_ro (symlink guard removed) ---
# Expected: symlink input followed → exit 0 (not 2) → T2 DETECTED
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/os\.O_RDONLY | _O_NOFOLLOW | _O_NONBLOCK/os.O_RDONLY | _O_NONBLOCK/' \
  "$MUTDIR/station_modules.py"
if ! python3 -m py_compile "$MUTDIR/station_modules.py" 2>/dev/null; then
  mut_no "M1 symlink guard: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/station_modules.py"; then
  mut_no "M1 symlink guard: sed had no effect (pattern not found)"
else
  _m1_exit=0
  python3 "$MUTDIR/station_modules.py" \
    --input "$ROOT/sym.bog" --install "$FIXTURES/fake_install" \
    --output "$ROOT/m1.json" 2>/dev/null || _m1_exit=$?
  if [ "$_m1_exit" -ne 2 ]; then
    mut_ok "M1 symlink guard removal detected (exit $_m1_exit, not 2)"
  else
    mut_no "M1 symlink guard: mutation NOT detected (still exits 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M2: Remove bounded-read guard (zip-bomb allowed) ---
# Expected: bomb.bog parsed without truncation → status not (failed+truncated) → T9 DETECTED
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/if len(data) > _MAX_BOG_INFLATE:/if False:  # MUTANT-M2/' \
  "$MUTDIR/station_modules.py"
if ! python3 -m py_compile "$MUTDIR/station_modules.py" 2>/dev/null; then
  mut_no "M2 bounded-read removed: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/station_modules.py"; then
  mut_no "M2 bounded-read removed: sed had no effect (pattern not found)"
else
  _m2_exit=0
  python3 "$MUTDIR/station_modules.py" \
    --input "$FIXTURES/bomb.bog" --install "$FIXTURES/fake_install" \
    --output "$ROOT/m2.json" 2>/dev/null || _m2_exit=$?
  _m2_status=""
  _m2_trunc=""
  if [ -f "$ROOT/m2.json" ]; then
    _m2_status="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m2.json')); print(d.get('status',''))" \
      2>/dev/null || echo "")"
    _m2_trunc="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m2.json')); print(d.get('truncated',''))" \
      2>/dev/null || echo "")"
  fi
  # Original: exit 1, status:failed, truncated:True
  # Mutant: truncated should NOT be True (bomb was not bounded)
  if [ "$_m2_status" != "failed" ] || [ "$_m2_trunc" != "True" ]; then
    mut_ok "M2 bounded-read removed: got status='$_m2_status' trunc='$_m2_trunc' — DETECTED"
  else
    mut_no "M2 bounded-read removed: mutation NOT detected (still failed+truncated)"
  fi
fi
rm -rf "$MUTDIR"

# --- M3: Never add to missing_parts (module-absent check bypassed) ---
# Mutation: change "if not inst:" to "if False:" so the code never enters the
# module-absent branch and missing_parts stays empty.
# Expected: testmodule-rt absent from missing_parts → T4 DETECTED
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/if not inst:/if False:  # MUTANT-M3/' \
  "$MUTDIR/station_modules.py"
if ! python3 -m py_compile "$MUTDIR/station_modules.py" 2>/dev/null; then
  mut_no "M3 missing_parts tracking removed: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/station_modules.py"; then
  mut_no "M3 missing_parts tracking removed: sed had no effect (pattern not found)"
else
  _m3_exit=0
  python3 "$MUTDIR/station_modules.py" \
    --input "$FIXTURES/valid.bog" --install "$FIXTURES/fake_install" \
    --output "$ROOT/m3.json" 2>/dev/null || _m3_exit=$?
  _m3_mp=""
  if [ -f "$ROOT/m3.json" ]; then
    _m3_mp="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m3.json')); print(len(d.get('missing_parts',{})))" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m3_mp" = "0" ]; then
    mut_ok "M3 missing_parts removed: missing_parts=0 — DETECTED"
  else
    mut_no "M3 missing_parts removed: mutation NOT detected (missing_parts=$_m3_mp, expected 0)"
  fi
fi
rm -rf "$MUTDIR"

# --- M4: Narrow zip-read exception guard (BLOCKER mutation) ---
# Mutation: except Exception → except (zipfile.BadZipFile,)
# Expected: zlib.error escapes as traceback → no JSON emitted → T10 DETECTED
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
python3 - "$MUTDIR/station_modules.py" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f: src = f.read()
# Replace the broad except in the ZIP entry read block
src = re.sub(
    r'(        except Exception as exc:\n            try:\n                zf\.close\(\))',
    r'        except (zipfile.BadZipFile,) as exc:  # MUTANT-M4\n            try:\n                zf.close()',
    src, count=1)
with open(path, 'w') as f: f.write(src)
PYEOF
if ! python3 -m py_compile "$MUTDIR/station_modules.py" 2>/dev/null; then
  mut_no "M4 zip-read guard narrowed: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/station_modules.py"; then
  mut_no "M4 zip-read guard narrowed: Python edit had no effect"
else
  _m4_exit=0
  python3 "$MUTDIR/station_modules.py" \
    --input "$FIXTURES/corrupt_deflate.bog" --install "$FIXTURES/fake_install" \
    --output "$ROOT/m4.json" 2>/dev/null || _m4_exit=$?
  if [ "$_m4_exit" -eq 1 ] && [ ! -f "$ROOT/m4.json" ]; then
    mut_ok "M4 zip-read guard narrowed: zlib.error escapes → no JSON — DETECTED"
  else
    mut_no "M4 zip-read guard narrowed: mutation NOT detected (exit=$_m4_exit json=$([ -f "$ROOT/m4.json" ] && echo present || echo absent))"
  fi
fi
rm -rf "$MUTDIR"

# --- M5: Install-error check removed → false all-missing fires on absent modules/ ---
# Mutation: change "if install_error:" to "if False:" so install errors are silently
# ignored and the module-check runs with empty parts, producing "all missing" output.
# Expected: absent modules/ install → exit 0, missing_parts non-empty → T15 DETECTED
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/if install_error:/if False:  # MUTANT-M5/' \
  "$MUTDIR/station_modules.py"
if ! python3 -m py_compile "$MUTDIR/station_modules.py" 2>/dev/null; then
  mut_no "M5 install-error check removed: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/station_modules.py"; then
  mut_no "M5 install-error check removed: sed had no effect (pattern not found)"
else
  _m5_no_mod_install="$(mktemp -d)"
  # no modules/ subdir: simulates broken --install path
  _m5_exit=0
  python3 "$MUTDIR/station_modules.py" \
    --input "$FIXTURES/valid.bog" --install "$_m5_no_mod_install" \
    --output "$ROOT/m5.json" 2>/dev/null || _m5_exit=$?
  rm -rf "$_m5_no_mod_install"
  _m5_mp=""
  if [ -f "$ROOT/m5.json" ]; then
    _m5_mp="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m5.json')); print(len(d.get('missing_parts',{})))" \
      2>/dev/null || echo "")"
  fi
  # Mutant: exit 0 with all modules "missing" (false alarm)
  # Detection: exit 0 AND missing_parts non-empty (the false all-missing state)
  if [ "$_m5_exit" -eq 0 ] && [ -n "$_m5_mp" ] && [ "$_m5_mp" -gt 0 ] 2>/dev/null; then
    mut_ok "M5 install-error check removed: exit=$_m5_exit missing_parts=$_m5_mp — DETECTED (false all-missing)"
  else
    mut_no "M5 install-error check removed: mutation NOT detected (exit=$_m5_exit missing_parts=$_m5_mp)"
  fi
fi
rm -rf "$MUTDIR"

# --- M6: Module-vs-type fix reverted → false alarm on installed module ---
# Mutation: in the installed-module (else) branch, also add to missing_parts
# when a type is not found in any part (the old hardcode behavior).
# Expected: baja IS installed but baja-rt still added to missing_parts → T18 DETECTED
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
python3 - "$MUTDIR/station_modules.py" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f: src = f.read()
# In the else (installed) branch, add to missing_parts for unresolved types
# (reverting the fix: makes it behave like the old hardcoded {mod}-rt addition)
src = src.replace(
    'types_unresolved.append(tn)\n                                    total_types_unresolved += 1',
    'types_unresolved.append(tn)\n                                    total_types_unresolved += 1\n'
    '                                    missing_parts.setdefault(f"{mod}-rt", f"type {tn} not in installed parts (MUTANT-M6)")',
)
with open(path, 'w') as f: f.write(src)
PYEOF
if ! python3 -m py_compile "$MUTDIR/station_modules.py" 2>/dev/null; then
  mut_no "M6 module-vs-type reverted: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/station_modules.py"; then
  mut_no "M6 module-vs-type reverted: Python edit had no effect"
else
  _m6_exit=0
  python3 "$MUTDIR/station_modules.py" \
    --input "$FIXTURES/type_mismatch.bog" --install "$FIXTURES/fake_install" \
    --output "$ROOT/m6.json" 2>/dev/null || _m6_exit=$?
  _m6_mp=""
  if [ -f "$ROOT/m6.json" ]; then
    _m6_mp="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m6.json')); print(len(d.get('missing_parts',{})))" \
      2>/dev/null || echo "")"
  fi
  # Mutant: baja-rt added to missing_parts even though baja IS installed → false alarm
  if [ -n "$_m6_mp" ] && [ "$_m6_mp" -gt 0 ] 2>/dev/null; then
    mut_ok "M6 module-vs-type reverted: missing_parts=$_m6_mp (false alarm) — DETECTED"
  else
    mut_no "M6 module-vs-type reverted: mutation NOT detected (missing_parts=$_m6_mp, expected > 0)"
  fi
fi
rm -rf "$MUTDIR"

# --- M_PTXT: Plaintext bounded-read removed (read cap bypassed) ---
# Mutation: disable the plaintext cap check so a 32 MiB+ plaintext bog is
# read fully and parsed as (empty) XML → exit 0 instead of exit 1 (truncated).
# Expected: plaintext_bomb.bog (>32 MiB) → mutant exits 0, original exits 1 → DETECTED
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/if len(raw) > _MAX_BOG_INFLATE:/if False:  # MUTANT-MPTXT/' \
  "$MUTDIR/station_modules.py"
if ! python3 -m py_compile "$MUTDIR/station_modules.py" 2>/dev/null; then
  mut_no "M_PTXT plaintext cap removed: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/station_modules.py"; then
  mut_no "M_PTXT plaintext cap removed: sed had no effect (pattern not found)"
else
  _mptxt_exit=0
  python3 "$MUTDIR/station_modules.py" \
    --input "$ROOT/plaintext_bomb.bog" --install "$FIXTURES/fake_install" \
    --output "$ROOT/mptxt.json" 2>/dev/null || _mptxt_exit=$?
  _mptxt_status=""
  if [ -f "$ROOT/mptxt.json" ]; then
    _mptxt_status="$(python3 -c \
      "import json; d=json.load(open('$ROOT/mptxt.json')); print(d.get('status',''))" \
      2>/dev/null || echo "")"
  fi
  # Original: exit 1, status:failed (cap fired)
  # Mutant: exit 0, status:complete (full content read, parsed as empty XML)
  if [ "$_mptxt_exit" -eq 0 ] && [ "$_mptxt_status" = "complete" ]; then
    mut_ok "M_PTXT plaintext cap removed: exit=0 status=complete — DETECTED"
  else
    mut_no "M_PTXT plaintext cap removed: mutation NOT detected (exit=$_mptxt_exit status=$_mptxt_status)"
  fi
fi
rm -rf "$MUTDIR"

# --- M_BOMB: unbounded ZIP read (read(CAP+1) → read()) on 1 GiB fixture ---
# Requires bigbomb.bog to exist (built once by fixture generator).
# Under ulimit -v 720896 (704 MiB), read() on 1 GiB → MemoryError (caught by
# except Exception → truncated:False), while read(CAP+1) stops at 33 MiB →
# cap check fires → truncated:True.
# Skip gracefully if bigbomb.bog absent or ulimit unsupported.
if [ ! -f "$FIXTURES/bigbomb.bog" ]; then
  mut_no "M_BOMB unbounded read: bigbomb.bog not found — SKIP (build fixture first)"
elif ! ( ulimit -v 720896 2>/dev/null ); then
  mut_no "M_BOMB unbounded read: ulimit -v not supported — SKIP"
else
  MUTDIR="$(mktemp -d)"
  cp -a "$SUT_DIR/." "$MUTDIR/"
  sed -i 's/f\.read(_MAX_BOG_INFLATE + 1)/f.read()  # MUTANT-MBOMB/' \
    "$MUTDIR/station_modules.py"
  if ! python3 -m py_compile "$MUTDIR/station_modules.py" 2>/dev/null; then
    mut_no "M_BOMB unbounded read: mutant failed py_compile"
  elif cmp -s "$ORIG_PY" "$MUTDIR/station_modules.py"; then
    mut_no "M_BOMB unbounded read: sed had no effect (pattern not found)"
  else
    _mbomb_exit=0
    _mbomb_trunc=""
    # Run mutant under VM limit; MemoryError → caught by except Exception → truncated=False
    (ulimit -v 720896 && python3 "$MUTDIR/station_modules.py" \
       --input "$FIXTURES/bigbomb.bog" --install "$FIXTURES/fake_install" \
       --output "$ROOT/mbomb.json" 2>/dev/null) \
      || _mbomb_exit=$?
    if [ -f "$ROOT/mbomb.json" ]; then
      _mbomb_trunc="$(python3 -c \
        "import json; d=json.load(open('$ROOT/mbomb.json')); print(d.get('truncated',''))" \
        2>/dev/null || echo "")"
    fi
    if [ "$_mbomb_trunc" != "True" ]; then
      mut_ok "M_BOMB unbounded read: truncated='$_mbomb_trunc' not True — DETECTED"
    else
      mut_no "M_BOMB unbounded read: mutation NOT detected (still truncated:True)"
    fi
  fi
  rm -rf "$MUTDIR"
fi

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
