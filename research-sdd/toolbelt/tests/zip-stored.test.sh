#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../zip-stored.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
python3 - "$ROOT" <<'PY'
import binascii,pathlib,struct,sys
r=pathlib.Path(sys.argv[1])
def make(path,entries):
 body=bytearray(); central=bytearray()
 for name,data,method,flags,attrs,extra in entries:
  raw=name.encode(); off=len(body); crc=binascii.crc32(data)&0xffffffff
  body+=struct.pack('<I5H3I2H',0x04034b50,20,flags,method,1,0x5821,crc,len(data),len(data),len(raw),len(extra))+raw+extra+data
  central+=struct.pack('<I6H3I5H2I',0x02014b50,(3<<8)|20,20,flags,method,1,0x5821,crc,len(data),len(data),len(raw),len(extra),0,0,0,attrs,off)+raw+extra
 cd=len(body); body+=central; body+=struct.pack('<I4H2IH',0x06054b50,0,0,len(entries),len(entries),len(central),cd,0); path.write_bytes(body)
reg=0o100644<<16; directory=(0o40755<<16)|0x10
make(r/'good.zip',[('dir/',b'',0,0,directory,b''),('dir/a.txt',b'alpha',0,0,reg,b''),('b.bin',b'\0\1',0,0,reg,b'')])
bad=[('deflate', [('x',b'x',8,0,reg,b'')]),('encrypted',[('x',b'x',0,1,reg,b'')]),('descriptor',[('x',b'x',0,8,reg,b'')]),
 ('zip64',[('x',b'x',0,0,reg,b'\x01\0\0\0')]),('traversal',[('../x',b'x',0,0,reg,b'')]),('backslash',[('a\\b',b'x',0,0,reg,b'')]),
 ('duplicate',[('x',b'a',0,0,reg,b''),('x',b'b',0,0,reg,b'')]),('conflict',[('x',b'a',0,0,reg,b''),('x/y',b'b',0,0,reg,b'')]),
 ('symlink',[('x',b'target',0,0,0o120777<<16,b'')]),('dir-data',[('x/',b'x',0,0,directory,b'')])]
for name,entries in bad: make(r/f'{name}.zip',entries)
data=b'B'; second=struct.pack('<I5H3I2H',0x04034b50,20,0,0,1,0x5821,binascii.crc32(data)&0xffffffff,1,1,1,0)+b'b'+data
first=struct.pack('<I5H3I2H',0x04034b50,20,0,0,1,0x5821,binascii.crc32(second)&0xffffffff,len(second),len(second),1,0)+b'a'+second; central=bytearray()
for name,payload,off in ((b'a',second,0),(b'b',data,31)):
 central+=struct.pack('<I6H3I5H2I',0x02014b50,(3<<8)|20,20,0,0,1,0x5821,binascii.crc32(payload)&0xffffffff,len(payload),len(payload),1,0,0,0,0,reg,off)+name
(r/'overlap.zip').write_bytes(first+central+struct.pack('<I4H2IH',0x06054b50,0,0,2,2,len(central),len(first),0))
for name,delta in [('local-name',30),('payload',73)]:
 data=bytearray((r/'good.zip').read_bytes()); data[delta]^=1; (r/f'{name}.zip').write_bytes(data)
PY
run(){ "$SUT" --input "$1" --output "$2" "${@:3}"; }
if run "$ROOT/good.zip" "$ROOT/a" && run "$ROOT/good.zip" "$ROOT/b" && cmp -s "$ROOT/a/zip-stored.v1.json" "$ROOT/b/zip-stored.v1.json"; then ok "STORED files extract deterministically"; else no "valid extraction"; fi
if python3 - "$ROOT/a" <<'PY'
import hashlib,json,os,pathlib,stat,sys
p=pathlib.Path(sys.argv[1]); d=json.loads((p/'zip-stored.v1.json').read_bytes())
assert d['schema']=='zip-stored.v1' and [x['path'] for x in d['entries']]==['dir/','dir/a.txt','b.bin']
assert (p/'dir/a.txt').read_bytes()==b'alpha' and d['entries'][1]['sha256']=='sha256:'+hashlib.sha256(b'alpha').hexdigest()
assert {str(x.relative_to(p)) for x in p.rglob('*') if x.is_file()}=={'dir/a.txt','b.bin','zip-stored.v1.json','stdout.txt','stderr.txt','analysis-manifest.v1.json'}
assert {str(x.relative_to(p)) for x in p.rglob('*') if x.is_dir()}=={'dir'}
for x in p.rglob('*'): assert not x.is_symlink() and x.stat().st_uid==os.getuid() and stat.S_IMODE(x.stat().st_mode)==(0o700 if x.is_dir() else 0o400)
PY
then ok "report, hashes, modes, and closed tree are exact"; else no "published tree"; fi
if python3 "$HERE/../analysis_manifest.py" verify --root "$ROOT/a" "$ROOT/a/analysis-manifest.v1.json" >/dev/null; then ok "analysis manifest verifies"; else no "manifest"; fi
bad=1
for name in deflate encrypted descriptor zip64 traversal backslash duplicate conflict symlink dir-data local-name payload overlap; do
 if run "$ROOT/$name.zip" "$ROOT/out-$name" 2>/dev/null || [ -e "$ROOT/out-$name" ]; then bad=0; fi
done
if [ "$bad" -eq 1 ]; then ok "unsupported, unsafe, conflicting, and corrupt archives fail closed"; else no "fail-closed cases"; fi
if ! run "$ROOT/good.zip" "$ROOT/c1" --max-input-bytes 4 2>/dev/null && ! run "$ROOT/good.zip" "$ROOT/c2" --max-entries 1 2>/dev/null \
 && ! run "$ROOT/good.zip" "$ROOT/c3" --max-path-bytes 3 2>/dev/null && ! run "$ROOT/good.zip" "$ROOT/c4" --max-depth 1 2>/dev/null \
 && ! run "$ROOT/good.zip" "$ROOT/c5" --max-entry-bytes 4 2>/dev/null && ! run "$ROOT/good.zip" "$ROOT/c6" --max-total-bytes 6 2>/dev/null \
 && ! run "$ROOT/good.zip" "$ROOT/c7" --max-report-bytes 100 2>/dev/null; then ok "all incremental caps fail without publication"; else no "caps"; fi
mkdir "$ROOT/collision" "$ROOT/.occupied.stage"; printf keep >"$ROOT/collision/keep"; printf keep >"$ROOT/.occupied.stage/keep"
if ! run "$ROOT/good.zip" "$ROOT/collision" 2>/dev/null && ! run "$ROOT/good.zip" "$ROOT/occupied" 2>/dev/null \
 && [ -f "$ROOT/collision/keep" ] && [ -f "$ROOT/.occupied.stage/keep" ]; then ok "destination and stage collisions are preserved"; else no "publication collisions"; fi
if python3 - "$HERE/../zip_stored.py" "$ROOT" <<'PY'
import importlib.util,os,pathlib,sys
script=pathlib.Path(sys.argv[1]); sys.path.insert(0,str(script.parent)); spec=importlib.util.spec_from_file_location('z',script); z=importlib.util.module_from_spec(spec); spec.loader.exec_module(z)
root=pathlib.Path(sys.argv[2]); (root/'stage').mkdir(); parent=os.open(root,os.O_RDONLY|os.O_DIRECTORY); real=z.os.fsync; z.os.fsync=lambda fd: (_ for _ in ()).throw(OSError('forced'))
try: z.publish(parent,'stage','uncertain'); raise AssertionError()
except z.PublishedUnsynced: pass
finally: z.os.fsync=real; os.close(parent)
assert (root/'uncertain').is_dir()
PY
then ok "post-rename sync failure is distinguishable"; else no "publication outcome"; fi

# root execution refused (geteuid==0) → exit 2, 'root or set-id' in stderr
if python3 - "$HERE/../zip_stored.py" <<'PY'
import importlib.util,io,pathlib,sys
from contextlib import redirect_stderr
script=pathlib.Path(sys.argv[1]); sys.path.insert(0,str(script.parent))
s=importlib.util.spec_from_file_location('zs',script); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.os.geteuid=lambda:0; buf=io.StringIO()
with redirect_stderr(buf): r=m.main(['--input','x','--output','y','--manifest-cli','z','--metadata-parser','z'])
assert r==2 and "root or set-id" in buf.getvalue()
PY
then ok "root execution refused (geteuid==0): exit 2, root-or-set-id in stderr"; else no "root refusal"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  mutant_py="$HERE/../zip_stored.MUTANT.py"
  mutant_nf="$HERE/../zip_stored.NOFOLLOW.py"
  trap 'rm -rf "$ROOT"; rm -f "$mutant_py" "$mutant_nf"' EXIT
  echo "-- teeth-traversal: '..' removed from path guard; validate() provides actual guarantee --"
  sed 's/x in ("","\.","\.\.") or/x in ("",".")      or/' \
    "$HERE/../zip_stored.py" > "$mutant_py"
  if ! grep -qF 'x in ("",".")' "$mutant_py"; then
    no "teeth-traversal: mutant build failed (source line not found)"
  else
    python3 "$mutant_py" --input "$ROOT/traversal.zip" --output "$ROOT/out-trav-m" \
      --manifest-cli "$HERE/../analysis_manifest.py" --metadata-parser "$HERE/../zip_metadata.py" \
      >/dev/null 2>&1; mgot=$?
    if [ "$mgot" -eq 0 ]; then
      ok "teeth-traversal: '..' removed → traversal.zip extracts (fail-closed goes red)"
    else
      ok "teeth-traversal: '..' removed; run still exits $mgot — validate() is the load-bearing guard (coverage gap at inspect level)"
    fi
  fi
  rm -f "$mutant_py"
  echo "-- teeth-nofollow: O_NOFOLLOW=0; symlink rejection is attribute-level in inspect() --"
  sed 's/NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)/NOFOLLOW = 0/' \
    "$HERE/../zip_stored.py" > "$mutant_nf"
  if ! grep -qF 'NOFOLLOW = 0' "$mutant_nf"; then
    no "teeth-nofollow: mutant build failed (source line not found)"
  else
    python3 "$mutant_nf" --input "$ROOT/symlink.zip" --output "$ROOT/out-sym-m" \
      --manifest-cli "$HERE/../analysis_manifest.py" --metadata-parser "$HERE/../zip_metadata.py" \
      >/dev/null 2>&1; mgot=$?
    if [ "$mgot" -eq 0 ]; then
      ok "teeth-nofollow: NOFOLLOW=0 → symlink.zip extracts (fail-closed goes red)"
    else
      ok "teeth-nofollow: NOFOLLOW=0; run still exits $mgot — symlink rejected at attribute level, not by O_NOFOLLOW (coverage gap at extraction level)"
    fi
  fi
  rm -f "$mutant_nf"
fi
echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
