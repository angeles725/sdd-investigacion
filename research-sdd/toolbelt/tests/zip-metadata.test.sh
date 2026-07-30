#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../zip-metadata.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
python3 - "$ROOT" <<'PY'
import pathlib,struct,sys
r=pathlib.Path(sys.argv[1])
def make(path, entries=(), disk=0, sentinel=False, truncate=0):
 body=bytearray(); central=bytearray()
 for raw,flags,method,payload in entries:
  off=len(body); crc=0x12345678
  body+=struct.pack('<I5H3I2H',0x04034b50,20,flags,method,0,0,crc,len(payload),len(payload),len(raw),0)+raw+payload
  central+=struct.pack('<I6H3I5H2I',0x02014b50,20,20,flags,method,0,0,crc,len(payload),len(payload),len(raw),0,0,0,0,0,off)+raw
 count=len(entries); cd=len(body); body+=central
 end=struct.pack('<I4H2IH',0x06054b50,disk,disk,count,0xffff if sentinel else count,len(central),cd,0)
 path.write_bytes((body+end)[:-truncate] if truncate else body+end)
make(r/'empty.zip')
make(r/'mixed.zip',[(b'ok.txt',0,0,b'PAYLOAD-NOT-METADATA'),(b'../evil',1,99,b'SECRET'),(b'\\root',0,8,b'X'),(b'/abs',0,0,b'Y'),(b'dup',0,0,b'A'),(b'dup',0,0,b'B'),(b'nul\0x',0,0,b'C')])
make(r/'multi.zip',[],1); make(r/'zip64.zip',[],0,True); make(r/'truncated.zip',[],0,False,1)
d=bytearray((r/'mixed.zip').read_bytes()); i=d.find(b'PK\x01\x02'); d[i:i+4]=b'BAD!'; (r/'malformed.zip').write_bytes(d)
PY
run(){ "$SUT" --input "$1" --output "$2" "${@:3}"; }
if run "$ROOT/empty.zip" "$ROOT/empty" && run "$ROOT/mixed.zip" "$ROOT/a" && run "$ROOT/mixed.zip" "$ROOT/b" \
 && cmp -s "$ROOT/a/zip-metadata.v1.json" "$ROOT/b/zip-metadata.v1.json"; then ok "empty, mixed, and deterministic inventories"; else no "valid inventories"; fi
if python3 - "$ROOT/a" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads((p/'zip-metadata.v1.json').read_bytes()); e=d['entries']
assert d['schema']=='zip-metadata.v1' and len(e)==7 and d['payload_bytes_read']==0
assert e[1]['encrypted'] and e[1]['method']==99 and e[1]['safety']['traversal']
assert e[2]['safety']['backslash'] and e[3]['safety']['absolute']
assert e[4]['safety']['duplicate'] and e[5]['safety']['duplicate'] and e[6]['safety']['nul']
assert {x.name for x in p.iterdir()}=={'input','stdout.txt','stderr.txt','zip-metadata.v1.json','analysis-manifest.v1.json'}
PY
then ok "dangerous, duplicate, encrypted, and unknown-method metadata is marked only"; else no "metadata contract"; fi
if python3 "$HERE/../analysis_manifest.py" verify --root "$ROOT/a" "$ROOT/a/analysis-manifest.v1.json" >/dev/null; then ok "analysis manifest verifies"; else no "manifest verification"; fi
if ! run "$ROOT/truncated.zip" "$ROOT/truncated" 2>/dev/null && ! run "$ROOT/malformed.zip" "$ROOT/malformed" 2>/dev/null && ! run "$ROOT/multi.zip" "$ROOT/multi" 2>/dev/null \
 && ! run "$ROOT/zip64.zip" "$ROOT/zip64" 2>/dev/null; then ok "truncated, malformed, multi-disk, and ZIP64 fail closed"; else no "invalid formats"; fi
if ! run "$ROOT/mixed.zip" "$ROOT/cd-cap" --max-central-directory-bytes 10 2>/dev/null \
 && ! run "$ROOT/mixed.zip" "$ROOT/entry-cap" --max-entries 2 2>/dev/null \
 && ! run "$ROOT/mixed.zip" "$ROOT/input-cap" --max-input-bytes 4 2>/dev/null && ! run "$ROOT/mixed.zip" "$ROOT/field-cap" --max-field-bytes 3 2>/dev/null \
 && ! run "$ROOT/mixed.zip" "$ROOT/report-cap" --max-report-bytes 100 2>/dev/null; then ok "all byte, field, entry, and report caps fail closed"; else no "caps"; fi
ln -s "$ROOT/mixed.zip" "$ROOT/link.zip"; mkdir "$ROOT/collision" "$ROOT/.occupied.stage"; echo keep >"$ROOT/collision/keep"; echo stage >"$ROOT/.occupied.stage/keep"
if ! run "$ROOT/link.zip" "$ROOT/link-out" 2>/dev/null && ! run "$ROOT/mixed.zip" "$ROOT/collision" 2>/dev/null \
 && ! run "$ROOT/mixed.zip" "$ROOT/occupied" 2>/dev/null && [ -f "$ROOT/collision/keep" ] && [ -f "$ROOT/.occupied.stage/keep" ] && [ ! -e "$ROOT/link-out" ]; then ok "symlink and collision failures publish nothing"; else no "path failures"; fi
if python3 - "$HERE/../zip_metadata.py" "$ROOT/mixed.zip" <<'PY'
import importlib.util,os,pathlib,sys
s=importlib.util.spec_from_file_location('z',sys.argv[1]); z=importlib.util.module_from_spec(s); s.loader.exec_module(z); p=pathlib.Path(sys.argv[2])
fd=os.open(p,os.O_RDONLY); size=os.fstat(fd).st_size; calls=[]; real=z.os.pread
z.os.pread=lambda f,n,o:(calls.append((o,n)) or real(f,n,o))
try: z.inventory(fd,size,16*1024*1024,10000,65536)
finally: os.close(fd); z.os.pread=real
payload_end=p.read_bytes().find(b'PK\x01\x02'); assert calls and all(o>=payload_end for o,n in calls)
fd=os.open(p,os.O_RDONLY); before=os.fstat(fd); real=z.os.pread; changed=[False]
def mutate(f,n,o):
 data=real(f,n,o)
 if not changed[0]: os.utime(p,None); changed[0]=True
 return data
z.os.pread=mutate
try:
 z.inventory(fd,size,16*1024*1024,10000,65536); z.ensure_stable(before,os.fstat(fd)); raise AssertionError()
except z.ZipMetadataError: pass
finally: os.close(fd)
z.os.pread=real; original=z.inventory
def changed(*args):
 result=original(*args); current=p.stat(); os.utime(p,ns=(current.st_atime_ns,current.st_mtime_ns+1000000000)); return result
z.inventory=changed; out=p.parent/'mutated-out'; manifest=pathlib.Path(sys.argv[1]).with_name('analysis_manifest.py')
assert z.main(['--input',str(p),'--output',str(out),'--manifest-cli',str(manifest)])==2 and not out.exists()
PY
then ok "instrumentation proves payload exclusion and mutation rejection without publication"; else no "read boundary and mutation"; fi

# root refusal — geteuid()==0 rejected (root check absent in partial guard → RED before upgrade)
# RED: current guard only checks set-id; geteuid==0 is NOT refused → message absent → test fails.
if python3 - "$HERE/../zip_metadata.py" <<'PY'
import importlib.util, io, sys
from contextlib import redirect_stderr
spec = importlib.util.spec_from_file_location("zip_metadata", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.os.geteuid = lambda: 0
buf = io.StringIO()
with redirect_stderr(buf):
    result = m.main(['--input', 'x', '--output', 'y', '--manifest-cli', 'z'])
assert result == 2, f"expected exit 2 for root, got {result}"
msg = buf.getvalue()
assert "root or set-id" in msg, f"expected 'root or set-id' in stderr, got: {msg!r}"
PY
then ok "root execution (geteuid==0) refused — 'root or set-id' in stderr (full guard, fail-closed)"
else no "root refusal"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth-traversal: set safety.traversal=False; expect metadata-contract assertion to go red --"
  mutant_py="$ROOT/zip_metadata.MUTANT.py"
  sed 's/"traversal": "\.\." in parts,/"traversal": False,/' \
    "$HERE/../zip_metadata.py" > "$mutant_py"
  if ! grep -qF '"traversal": False, "backslash"' "$mutant_py"; then
    no "teeth-traversal: mutant build failed (source line not found)"
  else
    python3 - "$mutant_py" "$ROOT/mixed.zip" "$HERE/.." >/dev/null 2>&1 <<'PY'
import importlib.util, os, sys
sys.path.insert(0, sys.argv[3])
s = importlib.util.spec_from_file_location('zm', sys.argv[1])
zm = importlib.util.module_from_spec(s); s.loader.exec_module(zm)
fd = os.open(sys.argv[2], os.O_RDONLY)
try:
    parsed, _ = zm.inventory(fd, os.fstat(fd).st_size, 16*1024*1024, 10000, 65536)
    assert parsed['entries'][1]['safety']['traversal']
finally:
    os.close(fd)
PY
    mgot=$?
    if [ "$mgot" -ne 0 ]; then
      ok "teeth-traversal: traversal=False → entries[1].safety.traversal assertion goes red"
    else
      no "teeth-traversal: mutant exit 0 — traversal assertion has no teeth"
    fi
  fi
fi
echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
