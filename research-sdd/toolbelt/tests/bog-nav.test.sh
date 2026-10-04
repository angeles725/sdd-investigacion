#!/usr/bin/env bash
# Test suite for bog-nav.sh (bog-nav.v1)
# TDD: tests written before implementation.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../bog-nav.sh"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# Fixtures are generated into the TEMP root, never into the live tests/fixtures dir (kit issue #1156,
# CLAUDE.md §8): zlib output differs across versions, so regenerating the committed copies changed
# their bytes on the CI runner and the run-all kit-tree guard rightly flagged it.
FIXTURES="$ROOT/fixtures/bog-nav"
mkdir -p "$FIXTURES" || { echo "FATAL: cannot create $FIXTURES" >&2; exit 2; }

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
    """Create a deflate-compressed ZIP .bog with a single file.xml entry.

    Uses a fixed date_time=(2024,1,1,0,0,0) so every rebuild produces
    identical bytes — avoids dirtying the working tree on re-runs.
    """
    buf = io.BytesIO()
    zi = zipfile.ZipInfo('file.xml', date_time=(2024, 1, 1, 0, 0, 0))
    zi.compress_type = zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr(zi, xml_content)
    write_bin(path, buf.getvalue())

# --- valid ZIP config.bog with known components, links, and a secret slot ---
# Password slot holds PLAINSECRET — must never appear in emitted JSON (T3 / secrets discipline)
VALID_XML = """<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station' m='b=baja c=control'>
  <p n='Services' h='2' t='b:ServiceContainer'>
  </p>
  <p n='Logic' h='3' t='c:BooleanWritable'>
   <p n='Password' v='PLAINSECRET'/>
   <p n='Link' t='b:Link'>
    <p n='sourceOrd' v='h:2'/>
    <p n='sourceSlotName' v='out'/>
    <p n='targetSlotName' v='in10'/>
   </p>
  </p>
 </p>
</bajaObjectGraph>"""

make_zip_bog(os.path.join(out, 'valid.bog'), VALID_XML)

# --- plaintext XML bog (no ZIP wrapper) ---
write_text(os.path.join(out, 'plaintext.bog'), VALID_XML)

# --- empty XML bog (valid ZIP, no components) ---
make_zip_bog(os.path.join(out, 'empty.bog'),
    "<?xml version='1.0'?><bajaObjectGraph version='4.0'></bajaObjectGraph>")

# --- malformed bog (not XML, not ZIP) ---
write_bin(os.path.join(out, 'binary.bog'),
    bytes([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03] * 256))

# --- zip-bomb fixture: file.xml decompressed > 32 MiB ---
# Build once; subsequent runs reuse it.
_bomb_path = os.path.join(out, 'bomb.bog')
if not os.path.exists(_bomb_path):
    _cap = 32 * 1024 * 1024
    _content = b'A' * (_cap + 1)  # 32 MiB + 1 byte
    _buf = io.BytesIO()
    with zipfile.ZipFile(_buf, 'w', zipfile.ZIP_DEFLATED) as _z:
        _z.writestr('file.xml', _content)
    write_bin(_bomb_path, _buf.getvalue())

# --- forged-header bomb: file_size in central directory is inflated ---
# A real zip-bomb: the ZIP central directory declares a large file_size
# but the actual deflate stream also exceeds the cap.
# For simplicity, we use the same bomb.bog (real oversized content).
# The test confirms bounded read via the real content path.

# --- bigbomb.bog: file.xml inflates to ~1 GiB (all zeros), ~1 MiB on disk ---
# Used for M_BOMB mutation: mutant read() OOMs under ulimit; original bounded.
# Stream-compress to avoid holding 1 GiB in memory during fixture build.
_bigbomb_path = os.path.join(out, 'bigbomb.bog')
if not os.path.exists(_bigbomb_path):
    _BIG_SIZE = 1 * 1024 * 1024 * 1024  # 1 GiB uncompressed
    _BIG_CHUNK = b'\x00' * 65536
    _big_buf = io.BytesIO()
    _big_zi = zipfile.ZipInfo('file.xml', date_time=(2024, 1, 1, 0, 0, 0))
    _big_zi.compress_type = zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(_big_buf, 'w') as _big_zf:
        with _big_zf.open(_big_zi, 'w') as _big_entry:
            _rem = _BIG_SIZE
            while _rem > 0:
                _n = min(len(_BIG_CHUNK), _rem)
                _big_entry.write(_BIG_CHUNK[:_n])
                _rem -= _n
    write_bin(_bigbomb_path, _big_buf.getvalue())

# --- corrupt ZIP forms: each triggers a different exception inside zf.open/f.read ---
# Used by T12-T15 to verify the zip-read guard (BLOCKER fix).
import struct as _struct

def _make_corrupt_zip(path, corrupt_fn):
    """Build a valid ZIP then apply a byte-level corruption via corrupt_fn."""
    _buf = io.BytesIO()
    _zi = zipfile.ZipInfo('file.xml', date_time=(2024, 1, 1, 0, 0, 0))
    _zi.compress_type = zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(_buf, 'w') as _z:
        _z.writestr(_zi, '<?xml version="1.0"?><root/>')
    _raw = bytearray(_buf.getvalue())
    corrupt_fn(_raw)
    write_bin(path, bytes(_raw))

def _corrupt_deflate(raw):
    """Corrupt the compressed data bytes → zlib.error on f.read()."""
    fname_len = _struct.unpack_from('<H', raw, 26)[0]
    extra_len = _struct.unpack_from('<H', raw, 28)[0]
    data_start = 30 + fname_len + extra_len
    for i in range(data_start + 5, min(data_start + 20, len(raw) - 20)):
        raw[i] ^= 0xAA

def _corrupt_crc(raw):
    """Flip CRC bytes in LFH and CD → BadZipFile after read completes."""
    # Local file header CRC at offset 14
    raw[14] ^= 0xFF; raw[15] ^= 0xFF
    # Central directory CRC at offset 16 within CD entry
    _cd = raw.find(b'PK\x01\x02')
    if _cd >= 0:
        raw[_cd + 16] ^= 0xFF; raw[_cd + 17] ^= 0xFF

def _set_encrypted(raw):
    """Set encryption bit in both LFH and CD general purpose bit flag → RuntimeError on open."""
    raw[6] |= 0x01  # bit 0 = encrypted in local file header
    _cd = raw.find(b'PK\x01\x02')
    if _cd >= 0:
        raw[_cd + 8] |= 0x01  # bit 0 = encrypted in central directory entry

def _set_method99(raw):
    """Change compression method to 99 (unsupported) → NotImplementedError."""
    _struct.pack_into('<H', raw, 8, 99)  # LFH compression method
    _cd = raw.find(b'PK\x01\x02')
    if _cd >= 0:
        _struct.pack_into('<H', raw, _cd + 10, 99)  # CD compression method

_make_corrupt_zip(os.path.join(out, 'corrupt_deflate.bog'), _corrupt_deflate)
_make_corrupt_zip(os.path.join(out, 'crc_mismatch.bog'), _corrupt_crc)
_make_corrupt_zip(os.path.join(out, 'encrypted.bog'), _set_encrypted)
_make_corrupt_zip(os.path.join(out, 'method99.bog'), _set_method99)

# --- self_closing_mix.bog: 7 components (4 self-closing, 3 open) ---
# T16: verifies self-closing elements WITH handles are recorded.
SELF_CLOSING_XML = """<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station' m='b=baja'>
  <p n='A' h='2' t='b:Container'>
   <p n='Leaf1' h='3' t='b:Folder'/>
   <p n='Leaf2' h='4' t='b:Folder'/>
   <p n='Container2' h='5' t='b:Container'>
    <p n='Leaf3' h='6' t='b:Folder'/>
   </p>
  </p>
  <p n='B' h='7' t='b:Container'/>
 </p>
</bajaObjectGraph>"""
make_zip_bog(os.path.join(out, 'self_closing_mix.bog'), SELF_CLOSING_XML)

# --- nested_a.bog: non-self-closing <a>...</a> element around components ---
# T17: verifies <a> push/pop balance so subsequent component paths are correct.
NESTED_A_XML = """<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station' m='b=baja'>
  <p n='A' h='2' t='b:Container'>
   <a n='someAction'>
    <p n='arg' v='value'/>
   </a>
  </p>
  <p n='B' h='3' t='b:Container'>
  </p>
 </p>
</bajaObjectGraph>"""
make_zip_bog(os.path.join(out, 'nested_a.bog'), NESTED_A_XML)
PY

# ---------------------------------------------------------------------------
# T1: absent input → exit 2, no JSON produced
# ---------------------------------------------------------------------------
_t1_exit=0
"$SUT" --input "$ROOT/no-such-file.bog" --output "$ROOT/t1.json" 2>/dev/null \
  || _t1_exit=$?
if [ "$_t1_exit" -eq 2 ] && [ ! -f "$ROOT/t1.json" ]; then
  ok "T1 absent input: exit 2, no JSON"
else
  no "T1 absent input: expected exit 2 + no JSON, got exit $_t1_exit"
fi

# ---------------------------------------------------------------------------
# T2: symlink input → exit 2 (O_NOFOLLOW)
# ---------------------------------------------------------------------------
ln -sf "$FIXTURES/valid.bog" "$ROOT/sym.bog"
_t2_exit=0
"$SUT" --input "$ROOT/sym.bog" --output "$ROOT/t2.json" 2>/dev/null \
  || _t2_exit=$?
if [ "$_t2_exit" -eq 2 ]; then
  ok "T2 symlink input: exit 2 (O_NOFOLLOW)"
else
  no "T2 symlink input: expected exit 2, got $_t2_exit"
fi

# ---------------------------------------------------------------------------
# T3: valid ZIP config.bog → exit 0, status:complete, components > 0, links >= 0
# ---------------------------------------------------------------------------
_t3_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --output "$ROOT/t3.json" 2>/dev/null \
  || _t3_exit=$?
if [ "$_t3_exit" -eq 0 ]; then
  if python3 - "$ROOT/t3.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'bog-nav.v1', f"bad schema: {d.get('schema')!r}"
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
assert d['input']['format'] == 'zip-xml', f"bad format: {d['input'].get('format')!r}"
s = d['summary']
assert s['components'] == 3, f"expected 3 components, got {s.get('components')}"
assert s['links'] == 1, f"expected 1 link, got {s.get('links')}"
assert 'b' in s['prefixes'], f"missing 'b' prefix, got {s.get('prefixes')}"
# Verify no secret values — PLAINSECRET (a real slot value in the fixture)
# must never appear anywhere in the emitted JSON (not just absent from a key).
import json as _json_mod
_full = _json_mod.dumps(d)
assert 'PLAINSECRET' not in _full, f"secret slot value must not appear anywhere in JSON output"
PY
  then
    ok "T3 valid ZIP bog: exit 0, schema/status/format/counts correct, no slot values"
  else
    no "T3 valid ZIP bog: exit 0 but JSON validation failed"
  fi
else
  no "T3 valid ZIP bog: expected exit 0, got $_t3_exit"
fi

# ---------------------------------------------------------------------------
# T4: plaintext XML bog → exit 0, status:complete, format=plaintext-xml
# ---------------------------------------------------------------------------
_t4_exit=0
"$SUT" --input "$FIXTURES/plaintext.bog" --output "$ROOT/t4.json" 2>/dev/null \
  || _t4_exit=$?
if [ "$_t4_exit" -eq 0 ]; then
  if python3 - "$ROOT/t4.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
assert d['input']['format'] == 'plaintext-xml', f"bad format: {d['input'].get('format')!r}"
s = d['summary']
assert s['components'] == 3, f"expected 3 components, got {s.get('components')}"
PY
  then
    ok "T4 plaintext XML bog: exit 0, format=plaintext-xml, components=3"
  else
    no "T4 plaintext XML bog: exit 0 but JSON validation failed"
  fi
else
  no "T4 plaintext XML bog: expected exit 0, got $_t4_exit"
fi

# ---------------------------------------------------------------------------
# T5: empty bog (valid XML, no components) → exit 0, status:complete, components=0
#     (proves instrument looked — §7 anti-silent-zero)
# ---------------------------------------------------------------------------
_t5_exit=0
"$SUT" --input "$FIXTURES/empty.bog" --output "$ROOT/t5.json" 2>/dev/null \
  || _t5_exit=$?
if [ "$_t5_exit" -eq 0 ]; then
  if python3 - "$ROOT/t5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
s = d['summary']
assert s['components'] == 0, f"expected components=0, got {s.get('components')}"
assert s['links'] == 0, f"expected links=0, got {s.get('links')}"
# Schema must still be present (proves instrument looked)
assert d['schema'] == 'bog-nav.v1'
PY
  then
    ok "T5 empty bog: exit 0, status:complete, components=0 (proves instrument looked)"
  else
    no "T5 empty bog: exit 0 but JSON validation failed"
  fi
else
  no "T5 empty bog: expected exit 0, got $_t5_exit"
fi

# ---------------------------------------------------------------------------
# T6: binary (non-XML, non-ZIP) bog → exit 1, status:failed
# ---------------------------------------------------------------------------
_t6_exit=0
"$SUT" --input "$FIXTURES/binary.bog" --output "$ROOT/t6.json" 2>/dev/null \
  || _t6_exit=$?
if [ "$_t6_exit" -eq 1 ]; then
  if python3 - "$ROOT/t6.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"binary bog must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for failed status"
PY
  then
    ok "T6 binary bog: exit 1, status:failed, errors non-empty"
  else
    no "T6 binary bog: exit 1 but JSON validation failed"
  fi
else
  no "T6 binary bog: expected exit 1, got $_t6_exit"
fi

# ---------------------------------------------------------------------------
# T7: --output symlink → exit 2, victim file not overwritten
# ---------------------------------------------------------------------------
echo "victim-content" > "$ROOT/victim.txt"
ln -sf "$ROOT/victim.txt" "$ROOT/out_sym.json"
_t7_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --output "$ROOT/out_sym.json" \
  2>/dev/null || _t7_exit=$?
_victim_ok=0
[ "$(cat "$ROOT/victim.txt" 2>/dev/null)" = "victim-content" ] && _victim_ok=1
if [ "$_t7_exit" -eq 2 ] && [ "$_victim_ok" -eq 1 ]; then
  ok "T7 output symlink: exit 2, victim not overwritten"
else
  no "T7 output symlink: expected exit 2 + victim intact, got exit $_t7_exit (victim_ok=$_victim_ok)"
fi

# ---------------------------------------------------------------------------
# T8: --output pre-existing file → exit 2 (O_CREAT|O_EXCL guard)
# ---------------------------------------------------------------------------
echo "existing" > "$ROOT/pre_existing.json"
_t8_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --output "$ROOT/pre_existing.json" \
  2>/dev/null || _t8_exit=$?
if [ "$_t8_exit" -eq 2 ]; then
  ok "T8 pre-existing output: exit 2 (O_CREAT|O_EXCL refused)"
else
  no "T8 pre-existing output: expected exit 2, got $_t8_exit"
fi

# ---------------------------------------------------------------------------
# T9: valid bog — value assertions on known component paths
#     (REAL TEETH: checks that the parser found specific paths and link resolution)
# ---------------------------------------------------------------------------
_t9_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --output "$ROOT/t9.json" 2>/dev/null \
  || _t9_exit=$?
if [ "$_t9_exit" -eq 0 ]; then
  if python3 - "$ROOT/t9.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete'
comps = {c['path']: c for c in d['components']}
# The root component has path 'Station' (n='Station' at depth 0)
assert 'Station' in comps, f"root Station component missing, paths={sorted(comps)!r}"
assert 'Station/Services' in comps, f"Services missing, paths={sorted(comps)!r}"
assert 'Station/Logic' in comps, f"Logic missing, paths={sorted(comps)!r}"
# Type check
assert comps['Station']['type'] == 'b:Station', f"Station type wrong: {comps['Station']['type']!r}"
# Link check: source resolved to Station/Services, target=Station/Logic.in10
links = d['links']
assert len(links) == 1, f"expected 1 link, got {len(links)}"
lk = links[0]
assert lk['src_resolved'] is True, f"link src_resolved must be True, got {lk.get('src_resolved')}"
assert 'Station/Services' in lk['source'], f"link source wrong: {lk.get('source')!r}"
assert 'in10' in lk['target'], f"link target must contain in10: {lk.get('target')!r}"
PY
  then
    ok "T9 value assertions: paths, type, link resolved correctly"
  else
    no "T9 value assertions: JSON validation failed"
  fi
else
  no "T9 value assertions: expected exit 0, got $_t9_exit"
fi

# ---------------------------------------------------------------------------
# T10: sha256 is present and non-empty in input metadata
#      (evidence integrity field)
# ---------------------------------------------------------------------------
_t10_exit=0
"$SUT" --input "$FIXTURES/valid.bog" --output "$ROOT/t10.json" 2>/dev/null \
  || _t10_exit=$?
if [ "$_t10_exit" -eq 0 ]; then
  if python3 - "$ROOT/t10.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
sha = d.get('input', {}).get('sha256', '')
assert len(sha) == 64, f"sha256 must be 64-char hex, got {sha!r}"
assert all(c in '0123456789abcdef' for c in sha), f"sha256 not hex: {sha!r}"
size = d.get('input', {}).get('size_bytes', 0)
assert size > 0, f"size_bytes must be > 0, got {size}"
PY
  then
    ok "T10 input metadata: sha256 and size_bytes present and valid"
  else
    no "T10 input metadata: JSON validation failed"
  fi
else
  no "T10 input metadata: expected exit 0, got $_t10_exit"
fi

# ---------------------------------------------------------------------------
# T11: ZIP bomb — file.xml > 32 MiB inflate cap → exit 1, status:failed, truncated:true
#      Verifies bounded read fires. M_BOUND mutation removes the guard.
# ---------------------------------------------------------------------------
_t11_exit=0
"$SUT" --input "$FIXTURES/bomb.bog" --output "$ROOT/t11.json" 2>/dev/null \
  || _t11_exit=$?
if [ "$_t11_exit" -eq 1 ]; then
  if python3 - "$ROOT/t11.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"bomb must be failed, got {d.get('status')!r}"
assert d.get('truncated') is True, f"bomb must set truncated=True, got {d.get('truncated')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for bomb"
PY
  then
    ok "T11 ZIP bomb (>32 MiB): exit 1, status:failed, truncated:true (bounded read)"
  else
    no "T11 ZIP bomb: exit 1 but JSON validation failed"
  fi
else
  no "T11 ZIP bomb: expected exit 1, got $_t11_exit"
fi

# ---------------------------------------------------------------------------
# T12: corrupted deflate stream → exit 1, status:failed JSON (BLOCKER fix)
# RED before fix: uncaught zlib.error traceback → exit 1, no JSON
# ---------------------------------------------------------------------------
_t12_exit=0
"$SUT" --input "$FIXTURES/corrupt_deflate.bog" --output "$ROOT/t12.json" 2>/dev/null \
  || _t12_exit=$?
if [ "$_t12_exit" -eq 1 ] && [ -f "$ROOT/t12.json" ]; then
  if python3 - "$ROOT/t12.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"corrupt deflate must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for corrupt deflate"
PY
  then
    ok "T12 corrupt deflate: exit 1, status:failed JSON (zip-read guard)"
  else
    no "T12 corrupt deflate: exit 1, JSON present but validation failed"
  fi
else
  no "T12 corrupt deflate: expected exit 1 + JSON, got exit=$_t12_exit json=$([ -f "$ROOT/t12.json" ] && echo present || echo absent)"
fi

# ---------------------------------------------------------------------------
# T13: CRC mismatch → exit 1, status:failed JSON (BLOCKER fix)
# RED before fix: uncaught BadZipFile traceback → exit 1, no JSON
# ---------------------------------------------------------------------------
_t13_exit=0
"$SUT" --input "$FIXTURES/crc_mismatch.bog" --output "$ROOT/t13.json" 2>/dev/null \
  || _t13_exit=$?
if [ "$_t13_exit" -eq 1 ] && [ -f "$ROOT/t13.json" ]; then
  if python3 - "$ROOT/t13.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"CRC mismatch must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for CRC mismatch"
PY
  then
    ok "T13 CRC mismatch: exit 1, status:failed JSON (zip-read guard)"
  else
    no "T13 CRC mismatch: exit 1, JSON present but validation failed"
  fi
else
  no "T13 CRC mismatch: expected exit 1 + JSON, got exit=$_t13_exit json=$([ -f "$ROOT/t13.json" ] && echo present || echo absent)"
fi

# ---------------------------------------------------------------------------
# T14: encrypted ZIP entry → exit 1, status:failed JSON (BLOCKER fix)
# RED before fix: uncaught RuntimeError traceback → exit 1, no JSON
# ---------------------------------------------------------------------------
_t14_exit=0
"$SUT" --input "$FIXTURES/encrypted.bog" --output "$ROOT/t14.json" 2>/dev/null \
  || _t14_exit=$?
if [ "$_t14_exit" -eq 1 ] && [ -f "$ROOT/t14.json" ]; then
  if python3 - "$ROOT/t14.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"encrypted entry must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for encrypted entry"
PY
  then
    ok "T14 encrypted entry: exit 1, status:failed JSON (zip-read guard)"
  else
    no "T14 encrypted entry: exit 1, JSON present but validation failed"
  fi
else
  no "T14 encrypted entry: expected exit 1 + JSON, got exit=$_t14_exit json=$([ -f "$ROOT/t14.json" ] && echo present || echo absent)"
fi

# ---------------------------------------------------------------------------
# T15: compression method 99 (unsupported) → exit 1, status:failed JSON (BLOCKER fix)
# RED before fix: uncaught NotImplementedError traceback → exit 1, no JSON
# ---------------------------------------------------------------------------
_t15_exit=0
"$SUT" --input "$FIXTURES/method99.bog" --output "$ROOT/t15.json" 2>/dev/null \
  || _t15_exit=$?
if [ "$_t15_exit" -eq 1 ] && [ -f "$ROOT/t15.json" ]; then
  if python3 - "$ROOT/t15.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"method-99 must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for method-99"
PY
  then
    ok "T15 method-99 (unsupported compression): exit 1, status:failed JSON (zip-read guard)"
  else
    no "T15 method-99: exit 1, JSON present but validation failed"
  fi
else
  no "T15 method-99: expected exit 1 + JSON, got exit=$_t15_exit json=$([ -f "$ROOT/t15.json" ] && echo present || echo absent)"
fi

# ---------------------------------------------------------------------------
# T16: self-closing components WITH handles are recorded
#      fixture has 7 handles (4 self-closing, 3 open) → components:7
# RED before fix: self-closing with h silently dropped → only 3 components
# ---------------------------------------------------------------------------
_t16_exit=0
"$SUT" --input "$FIXTURES/self_closing_mix.bog" --output "$ROOT/t16.json" 2>/dev/null \
  || _t16_exit=$?
if [ "$_t16_exit" -eq 0 ]; then
  if python3 - "$ROOT/t16.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"expected complete, got {d.get('status')!r}"
s = d['summary']
assert s['components'] == 7, \
    f"expected 7 components (4 self-closing + 3 open), got {s.get('components')}"
comps = {c['path'] for c in d['components']}
# Self-closing leaves must be present
assert 'Station/A/Leaf1' in comps, f"Leaf1 missing; comps={sorted(comps)!r}"
assert 'Station/A/Leaf2' in comps, f"Leaf2 missing; comps={sorted(comps)!r}"
assert 'Station/A/Container2/Leaf3' in comps, f"Leaf3 missing; comps={sorted(comps)!r}"
assert 'Station/B' in comps, f"B missing; comps={sorted(comps)!r}"
PY
  then
    ok "T16 self-closing components: 7 handles recorded (self-closing + open mix)"
  else
    no "T16 self-closing components: JSON validation failed"
  fi
else
  no "T16 self-closing components: expected exit 0, got $_t16_exit"
fi

# ---------------------------------------------------------------------------
# T17: <a>...</a> stack balance — subsequent component paths correct
# RED before fix: </a> pops a component frame → B gets path 'B' not 'Station/B'
# ---------------------------------------------------------------------------
_t17_exit=0
"$SUT" --input "$FIXTURES/nested_a.bog" --output "$ROOT/t17.json" 2>/dev/null \
  || _t17_exit=$?
if [ "$_t17_exit" -eq 0 ]; then
  if python3 - "$ROOT/t17.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"expected complete, got {d.get('status')!r}"
comps = {c['path']: c for c in d['components']}
assert 'Station' in comps, f"Station missing; paths={sorted(comps)!r}"
assert 'Station/A' in comps, f"A missing; paths={sorted(comps)!r}"
# B must have path 'Station/B', not 'B' (stack-balance bug would give 'B')
assert 'Station/B' in comps, \
    f"B must have path 'Station/B', got paths={sorted(comps)!r}"
assert 'B' not in comps, \
    f"orphaned 'B' path must not exist (stack imbalance bug), got paths={sorted(comps)!r}"
PY
  then
    ok "T17 <a> stack balance: B has correct path 'Station/B'"
  else
    no "T17 <a> stack balance: JSON validation failed"
  fi
else
  no "T17 <a> stack balance: expected exit 0, got $_t17_exit"
fi

# ---------------------------------------------------------------------------
# T18: FIFO input → exit 2, no hang (O_NONBLOCK guard)
# RED before fix: no O_NONBLOCK → process hangs → timeout exits 124
# ---------------------------------------------------------------------------
_t18_fifo="$ROOT/input.fifo"
mkfifo "$_t18_fifo" 2>/dev/null || true
_t18_exit=0
timeout 5 "$SUT" --input "$_t18_fifo" --output "$ROOT/t18.json" 2>/dev/null \
  || _t18_exit=$?
if [ "$_t18_exit" -eq 2 ]; then
  ok "T18 FIFO input: exit 2, no hang (O_NONBLOCK guard)"
elif [ "$_t18_exit" -eq 124 ]; then
  no "T18 FIFO input: HUNG (timeout 5 s fired — O_NONBLOCK missing)"
else
  no "T18 FIFO input: expected exit 2, got $_t18_exit"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
# Hermetic (kit issue #1156): fixtures live in the temp root; the live tests/fixtures dir must not
# be (re)created by this suite.
if [ ! -e "$HERE/fixtures/bog-nav" ]; then ok "hermetic: suite did not create tests/fixtures/bog-nav in the live tree"
else no "hermetic: suite (re)created tests/fixtures/bog-nav in the live tree"; fi
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: bog-nav mutation controls --"
# ---------------------------------------------------------------------------
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

# Shared helper (kit issue #1299): sourced ONLY on this branch, each function we call is checked.
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || { echo "FATAL: cannot source lib/mutant.sh" >&2; exit 2; }
for _fn in mutant_chain mutant_tooth; do
  declare -F "$_fn" >/dev/null || { echo "FATAL: lib/mutant.sh lacks $_fn" >&2; exit 2; }
done
export MUTANT_SYNTAX=none   # the mutants are Python; syntax is checked with ast.parse in mut_build

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/bog_nav.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  bog_nav.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi

# Mutants live under $ROOT (a mktemp dir, removed by the single EXIT trap above), one dir each.
# Only the single mutated file is copied: bog_nav.py imports only the stdlib (see its import block)
# and has no __file__-relative resource.
MUTBASE="$ROOT/mut"; mkdir -p "$MUTBASE"
MUTPY=""

# mut_build LABEL ID SED_EXPR — builds $MUTBASE/ID/bog_nav.py through mutant_chain (empty, identical,
# dead-stage, placement refusals) plus a Python syntax check. On refusal the tooth is counted ONCE
# here and never runs; returns 1.
mut_build(){
  local label="$1" id="$2" expr="$3"
  MUTPY="$MUTBASE/$id/bog_nav.py"; mkdir -p "$MUTBASE/$id"
  if ! mutant_chain "$label" "$ORIG_PY" "$MUTPY" "$expr"; then
    mut_no "$label: mutant refused by lib/mutant.sh (refusal counted here once; tooth not run)"; return 1
  fi
  if ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$MUTPY" 2>/dev/null; then
    mut_no "$label: mutant is not valid Python (refusal counted here once; tooth not run)"; return 1
  fi
}

# Wrapper run against the original and the mutant. Each run gets a FRESH output dir (removed by the
# wrapper's own trap) and prints typed RC=/JSON=/FACT= lines, so the control observes the same
# artifact the base test asserts on (the --output JSON).
cat > "$MUTBASE/wrap.sh" <<'WRAP'
py="$1"; in="$2"; fact="$3"; to="$4"; orig="$5"
[ "$py" = "$orig" ] && to=60
o="$(mktemp -d)" || exit 99
trap 'rm -rf "$o"' EXIT
[ "$fact" = fifo ] && { mkfifo "$o/in.fifo" || exit 99; in="$o/in.fifo"; }
[ "$fact" = bomb ] && { ulimit -v 720896 || exit 98; }
timeout "$to" python3 "$py" --input "$in" --output "$o/out.json" 2>/dev/null; rc=$?
echo "RC=$rc"
if [ -f "$o/out.json" ]; then echo "JSON=present"; else echo "JSON=absent"; fi
j(){ python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$o/out.json" 2>/dev/null || echo none; }
case "$fact" in
  trunc|bomb) echo "FACT=$(j 'd.get("status")')/$(j 'd.get("truncated")')" ;;
  comps) echo "FACT=$(j 'd["summary"]["components"]')" ;;
  resolved) echo "FACT=$(j 'd["links"][0]["src_resolved"]')" ;;
  bpath) echo "FACT=$(j '"Station/B" in {c["path"] for c in d["components"]}')" ;;
esac
exit "$rc"
WRAP
# qt LABEL GOOD_RC BAD_RC [--good-has RE ...] -- INPUT FACT MUTANT_TIMEOUT_SECONDS (the original
# always gets 60 s; only the mutant is bounded tightly). GOOD_RC/BAD_RC are the wrapper's exit
# codes, i.e. the exit code of bog_nav.py itself.
qt(){
  local label="$1" g="$2" b="$3"; shift 3
  local -a opts=()
  while [ "${1:-}" != -- ]; do opts+=("$1" "$2"); shift 2; done
  shift
  if mutant_tooth "$label" "$g" "$b" "$MUTPY" --orig "$ORIG_PY" "${opts[@]}" -- bash "$MUTBASE/wrap.sh" @SUT@ "$1" "$2" "$3" "$ORIG_PY"; then
    MUT_PASS=$((MUT_PASS+1))
  else
    MUT_FAIL=$((MUT_FAIL+1))
  fi
}

# --- M1: Remove O_NOFOLLOW from _open_ro (symlink guard removed): the symlink input is followed (T2)
if mut_build "M1 symlink guard" M1 's/os\.O_RDONLY | _O_NOFOLLOW | _O_NONBLOCK/os.O_RDONLY | _O_NONBLOCK/'; then
  qt "M1 symlink guard removal" 2 0 --good-has '^JSON=absent$' --bad-has '^JSON=present$' \
    -- "$ROOT/sym.bog" none 5
fi

# --- M2: Remove bounded-read guard (zip-bomb allowed): T11 wants status failed AND truncated True
if mut_build "M2 bounded-read removed" M2 's/if len(data) > _MAX_BOG_INFLATE:/if False:  # MUTANT-M2/'; then
  qt "M2 bounded-read removed" 1 0 --good-has '^FACT=failed/True$' --bad-has '^FACT=complete/False$' \
    -- "$FIXTURES/bomb.bog" trunc 30
fi

# --- M3: Component store removed: T9 expects 3 components
if mut_build "M3 component-store removed" M3 's/handle_map\[h\] = comp$/pass  # MUTANT-M3/'; then
  qt "M3 component-store removed" 0 0 --good-has '^FACT=3$' --bad-has '^FACT=0$' \
    -- "$FIXTURES/valid.bog" comps 5
fi

# --- M4: src_resolved forced False: T9 expects True
if mut_build "M4 src_resolved forced False" M4 "s/'src_resolved': src is not None,/'src_resolved': src is None,  # MUTANT-M4/"; then
  qt "M4 src_resolved forced False" 0 0 --good-has '^FACT=True$' --bad-has '^FACT=False$' \
    -- "$FIXTURES/valid.bog" resolved 5
fi

# --- M5: Narrow the zip-entry read guard (except Exception -> except (zipfile.BadZipFile,)): zlib.error
# escapes as a traceback, so no JSON (T12/T14/T15). Only the zip-entry handler is followed by
# `try: zf.close()`, so the three-line block anchors the substitution; a mismatch leaves the file
# unchanged and mutant_chain refuses it.
if mut_build "M5 zip-read guard narrowed" M5 '/^        except Exception as exc:$/{N;/\n            try:$/{N;/\n                zf\.close()$/s/except Exception as exc:/except (zipfile.BadZipFile,) as exc:  # MUTANT-M5/;};}'; then
  qt "M5 zip-read guard narrowed" 1 1 --good-has '^JSON=present$' --bad-has '^JSON=absent$' \
    --bad-lacks 'integer expression expected|syntax error|unbound variable|ImportError|ModuleNotFoundError' \
    -- "$FIXTURES/corrupt_deflate.bog" none 5
fi

# --- M6: Self-closing component branch disabled: T16 expects 7 components
if mut_build "M6 self-closing disabled" M6 's/if h is not None and is_self_cls:/if h is not None and False:  # MUTANT-M6/'; then
  qt "M6 self-closing disabled" 0 0 --good-has '^FACT=7$' --bad-has '^FACT=3$' \
    -- "$FIXTURES/self_closing_mix.bog" comps 5
fi

# --- M7: <a>-tag stack push removed: T17 expects path Station/B
if mut_build "M7 a-tag stack push removed" M7 's/if not is_self_cls:$/if False:  # MUTANT-M7/'; then
  qt "M7 a-tag stack push removed" 0 0 --good-has '^FACT=True$' --bad-has '^FACT=False$' \
    -- "$FIXTURES/nested_a.bog" bpath 5
fi

# --- M_FIFO: O_NONBLOCK removed: a FIFO input with no writer hangs (T18); 124 = the mutant's timeout
if mut_build "M_FIFO O_NONBLOCK removed" MF 's/os\.O_RDONLY | _O_NOFOLLOW | _O_NONBLOCK/os.O_RDONLY | _O_NOFOLLOW/'; then
  qt "M_FIFO O_NONBLOCK removed" 2 124 -- none fifo 3
fi

# --- M_BOMB: unbounded ZIP read (read(CAP+1) -> read()) on the 1 GiB fixture. Under ulimit -v
# 720896 (704 MiB) read() raises MemoryError, so the cap check never sets truncated True. Both runs
# execute under the same VM limit inside the wrapper. Skipped (counted as failure) when the fixture
# is absent or ulimit -v is unsupported.
if [ ! -f "$FIXTURES/bigbomb.bog" ]; then
  mut_no "M_BOMB unbounded read: bigbomb.bog not found — SKIP (build fixture first)"
elif ! ( ulimit -v 720896 2>/dev/null ); then
  mut_no "M_BOMB unbounded read: ulimit -v not supported — SKIP"
elif mut_build "M_BOMB unbounded read" MB 's/f\.read(_MAX_BOG_INFLATE + 1)/f.read()  # MUTANT-MBOMB/'; then
  qt "M_BOMB unbounded read" 1 1 --good-has '^FACT=failed/True$' --bad-has '^FACT=failed/False$' \
    -- "$FIXTURES/bigbomb.bog" bomb 60
fi

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
