#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../scan-firmware.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"; rm -f "$ROOT-parent-link"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" carve "$ROOT/firmware.bin" "$1" "${@:2}"; }

# Tool-availability guard — skip gracefully when required tools are absent.
for _cmd in bwrap binwalk; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "SKIP: firmware-carve tests (missing: $_cmd)"
    echo "== 0 passed · 0 failed =="
    exit 0
  fi
done

python3 - "$ROOT/firmware.bin" <<'PY'
import binascii,struct,sys
p=sys.argv[1]; data=b'UIMAGE-PAYLOAD'; h=bytearray(64)
struct.pack_into('>7I4B',h,0,0x27051956,0,0,len(data),0,0,binascii.crc32(data)&0xffffffff,5,2,2,0); h[32:36]=b'test'
struct.pack_into('>I',h,4,binascii.crc32(h)&0xffffffff)
s=bytearray(160); struct.pack_into('<5I6H8Q',s,0,0x73717368,1,0,4096,0,1,12,0,1,4,0,0,160,128,0xffffffffffffffff,96,120,0xffffffffffffffff,0xffffffffffffffff)
open(p,'wb').write(b'PFX!'+h+data+b'GAP!'+s)
PY
if run "$ROOT/a" && run "$ROOT/b" && cmp -s "$ROOT/a/firmware-carve.v1.json" "$ROOT/b/firmware-carve.v1.json" \
  && cmp -s "$ROOT/a/carves/00000004-uimage.bin" "$ROOT/b/carves/00000004-uimage.bin"; then ok "validated uImage and SquashFS ranges carve deterministically"; else no "deterministic carve"; fi
if python3 - "$ROOT/a" <<'PY'
import hashlib,json,os,pathlib,stat,sys
p=pathlib.Path(sys.argv[1]); d=json.load(open(p/'firmware-carve.v1.json'))
assert d['schema']=='firmware-carve.v1' and [x['kind'] for x in d['carves']]==['uimage','squashfs-v4-le']
assert d['isolation']=={'bubblewrap':True,'network_access':False,'payload_execution':False,'static_only':True,'vm_boundary':False}
assert 'disposable VM' in d['limitations'][0] and d['caps']['max_carves']==16
expected={'firmware-carve.v1.json','carves/00000004-uimage.bin',d['carves'][1]['path']}; assert {str(x.relative_to(p)) for x in p.rglob('*') if x.is_file()}==expected
for x in p.rglob('*'):
 assert not x.is_symlink() and x.stat().st_uid==os.getuid() and stat.S_IMODE(x.stat().st_mode)==(0o700 if x.is_dir() else 0o400)
for x in d['carves']:
 q=p/x['path']; assert q.stat().st_size==x['size'] and 'sha256:'+hashlib.sha256(q.read_bytes()).hexdigest()==x['sha256']
PY
then ok "manifest, isolation, ownership, modes, and closed tree are truthful"; else no "published contract"; fi
if python3 - "$HERE/../firmware_carve.py" "$ROOT" <<'PY'
import importlib.util,json,os,pathlib,shutil,sys
s=importlib.util.spec_from_file_location('f',sys.argv[1]); f=importlib.util.module_from_spec(s); s.loader.exec_module(f); root=pathlib.Path(sys.argv[2])
stage=root/'hardlink-stage'; shutil.copytree(root/'a',stage); shutil.copyfile(root/'firmware.bin',stage/'input.bin'); (stage/'input.bin').chmod(0o400)
report=json.loads((stage/'firmware-carve.v1.json').read_bytes()); os.link(stage/report['carves'][0]['path'],root/'external-hardlink')
try: f.validate_tree(stage,report,stage/'input.bin')
except f.CarveError as exc: assert 'hardlink' in str(exc)
else: f.publish(stage,root/'hardlink-out'); raise AssertionError()
assert not (root/'hardlink-out').exists() and (root/'external-hardlink').exists()
PY
then ok "external hardlinks fail closed without publication"; else no "hardlink safety"; fi
if python3 - "$HERE/../firmware_carve.py" "$ROOT" <<'PY'
import importlib.util,mmap,pathlib,struct,sys
s=importlib.util.spec_from_file_location('f',sys.argv[1]); f=importlib.util.module_from_spec(s); s.loader.exec_module(f); root=pathlib.Path(sys.argv[2])
p=root/'headers'; h=bytearray(160); struct.pack_into('<5I6H8Q',h,0,0x73717368,1,0,4096,0,1,12,0,1,4,0,0,160,128,0xffffffffffffffff,96,120,0xffffffffffffffff,0xffffffffffffffff); p.write_bytes(h*10000)
with p.open('r+b') as stream:
 data=mmap.mmap(stream.fileno(),0)
 try: f.candidates(data,2,3,1024); raise AssertionError()
 except f.CarveError as exc: assert 'caps' in str(exc)
 data.close()
for flags,offset in ((0,48),(0x80,88)):
 q=bytearray(h); struct.pack_into('<H',q,24,flags); struct.pack_into('<Q',q,offset,0xffffffffffffffff)
 p.write_bytes(q)
 with p.open('r+b') as stream:
  data=mmap.mmap(stream.fileno(),0); assert not f.candidates(data,2,3,1024); data.close()
PY
then ok "repeated candidates stay bounded and required SquashFS tables fail closed"; else no "bounded traversal and SquashFS tables"; fi
if python3 - "$HERE/../firmware_carve.py" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('f',sys.argv[1]); f=importlib.util.module_from_spec(s); s.loader.exec_module(f); root=pathlib.Path(sys.argv[2]); stage=root/'publish-stage'; stage.mkdir(); destination=root/'published-unsynced'
real=f.os.fsync; f.os.fsync=lambda fd: (_ for _ in ()).throw(OSError('forced'))
try: f.publish(stage,destination); raise AssertionError()
except f.PublishedUnsynced as exc: assert str(destination) in str(exc)
finally: f.os.fsync=real
assert destination.is_dir()
try: f.publish(destination,root/'published-unsynced'); raise AssertionError()
except f.CarveError: pass
PY
then ok "post-rename sync failure acknowledges destination and retry is no-replace"; else no "publish outcome"; fi

cp "$ROOT/firmware.bin" "$ROOT/bad-crc.bin"; printf X | dd of="$ROOT/bad-crc.bin" bs=1 seek=72 conv=notrunc status=none
cp "$ROOT/firmware.bin" "$ROOT/bad-range.bin"; python3 - "$ROOT/bad-range.bin" <<'PY'
import struct,sys
p=sys.argv[1]; b=bytearray(open(p,'rb').read()); o=b.find(b'hsqs'); struct.pack_into('<Q',b,o+40,len(b)+1); open(p,'wb').write(b)
PY
if "$SUT" carve "$ROOT/bad-crc.bin" "$ROOT/crc" && [ "$(find "$ROOT/crc/carves" -type f | wc -l)" -eq 1 ] \
  && "$SUT" carve "$ROOT/bad-range.bin" "$ROOT/range" && [ "$(find "$ROOT/range/carves" -type f | wc -l)" -eq 1 ] \
  && printf unsupported >"$ROOT/unsupported" && ! "$SUT" carve "$ROOT/unsupported" "$ROOT/unsupported-out" 2>/dev/null; then ok "invalid CRC, ranges, and unsupported inputs fail closed"; else no "format validation"; fi
if ! run "$ROOT/cap" --max-input-bytes 4 2>/dev/null && ! run "$ROOT/count" --max-carves 1 2>/dev/null \
  && ! run "$ROOT/bytes" --max-output-bytes 64 2>/dev/null && ! run "$ROOT/files" --max-files 2 2>/dev/null \
  && [ ! -e "$ROOT/cap" ] && [ ! -e "$ROOT/count" ] && [ ! -e "$ROOT/bytes" ] && [ ! -e "$ROOT/files" ]; then ok "input, count, byte, and file caps fail without publication"; else no "caps"; fi
ln -s "$ROOT/firmware.bin" "$ROOT/link.bin"; mkdir "$ROOT/.occupied.stage"; echo keep >"$ROOT/.occupied.stage/sentinel"
mkfifo "$ROOT/device"; mkdir "$ROOT/not-file" "$ROOT/unsafe"; chmod 777 "$ROOT/unsafe"; ln -s "$ROOT" "$ROOT-parent-link"
if ! "$SUT" carve "$ROOT/link.bin" "$ROOT/link-out" 2>/dev/null && ! "$SUT" carve "$ROOT/device" "$ROOT/device-out" 2>/dev/null && ! "$SUT" carve "$ROOT/not-file" "$ROOT/type-out" 2>/dev/null \
  && ! run "$ROOT/occupied" 2>/dev/null && [ -f "$ROOT/.occupied.stage/sentinel" ] && ! run "$ROOT/a" 2>/dev/null && ! run "$ROOT/unsafe/out" 2>/dev/null \
  && ! run "$ROOT-parent-link/out" 2>/dev/null; then ok "links, devices, types, unsafe parents, and collisions fail closed"; else no "path safety"; fi
if ! "$SUT" extract "$ROOT/firmware.bin" "$ROOT/legacy" 2>"$ROOT/legacy.err" && grep -q 'removed.*carve' "$ROOT/legacy.err" \
  && ! grep -Eq 'binwalk[[:space:]]+-e|--run-as=root' "$SUT"; then ok "unsafe legacy extraction is unreachable and gives migration guidance"; else no "legacy migration"; fi
if python3 - "$HERE/../firmware_carve.py" <<'PY'
import importlib.util,io,sys
s=importlib.util.spec_from_file_location('f',sys.argv[1]); f=importlib.util.module_from_spec(s); s.loader.exec_module(f)
buf=io.StringIO(); f.os.geteuid=lambda:0; sys.stderr=buf; r=f.main(['--input','x','--output','y']); sys.stderr=sys.__stderr__
assert r==2 and "root or set-id" in buf.getvalue()
PY
then ok "root execution fails closed"; else no "caller safety"; fi
if python3 - "$HERE/../firmware_carve.py" "$ROOT" <<'PY'
import importlib.util,pathlib,sys,time
s=importlib.util.spec_from_file_location('f',sys.argv[1]); f=importlib.util.module_from_spec(s); s.loader.exec_module(f); root=pathlib.Path(sys.argv[2])
f.run_worker(['/usr/bin/python3','-c','import resource; assert resource.getrlimit(resource.RLIMIT_AS)[0]==67108864'],root,2,1,67108864)
for command,timeout,processes in ((['/bin/sh','-c','sleep 2'],.05,4),(['/bin/sh','-c',f'(sleep .5; touch {root}/LEAK)& sleep 2'],2,0)):
 try: f.run_worker(command,root,timeout,processes); raise AssertionError()
 except f.CarveError: pass
time.sleep(.7); assert not (root/'LEAK').exists()
PY
then ok "memory, timeout, and process caps constrain the worker tree"; else no "process cleanup"; fi
echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
