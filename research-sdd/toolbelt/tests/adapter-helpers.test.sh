#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../lib/adapter_helpers.py"
[ -f "$SUT" ] || { echo "FATAL: adapter_helpers.py not found: $SUT" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
LOAD='import importlib.util,pathlib
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m'

# B-1  pcap_magic_check — valid pcap LE µs + pcapng accepted; garbage raises PcapMagicError
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
f=r/'v.pcap'; f.write_bytes(b'\xd4\xc3\xb2\xa1'+b'\x00'*20); ah.pcap_magic_check(f)
f2=r/'v.pcapng'; f2.write_bytes(b'\x0a\x0d\x0d\x0a'+b'\x00'*20); ah.pcap_magic_check(f2)
fg=r/'g.bin'; fg.write_bytes(b'\xde\xad\xbe\xef'+b'\x00'*20)
try: ah.pcap_magic_check(fg); raise AssertionError("should reject garbage")
except ah.PcapMagicError: pass
PY
then ok "pcap_magic_check: pcap LE+pcapng accepted; garbage raises PcapMagicError"; else no "pcap_magic_check: valid+garbage"; fi

# B-2  pcap_magic_check — symlink rejected (O_NOFOLLOW)
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
t=r/'lnk_tgt.pcap'; t.write_bytes(b'\xd4\xc3\xb2\xa1'+b'\x00'*20)
lnk=r/'lnk.pcap'; lnk.symlink_to(t)
try: ah.pcap_magic_check(lnk); raise AssertionError("should reject symlink")
except ah.PcapMagicError: pass
PY
then ok "pcap_magic_check: symlink raises PcapMagicError (O_NOFOLLOW)"; else no "pcap_magic_check: symlink rejected"; fi

# B-3  pcap_magic_check — BE big-endian variant accepted
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
f=r/'be.pcap'; f.write_bytes(b'\xa1\xb2\xc3\xd4'+b'\x00'*20); ah.pcap_magic_check(f)
PY
then ok "pcap_magic_check: BE variant accepted"; else no "pcap_magic_check: BE variant"; fi

# C-1  squashfs_superblock — synthetic valid superblock parses correctly
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,struct,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1])
# Valid SquashFS v4 LE superblock: no fragments, no export table
MAGIC=0x73717368; bs=131072; log=17; bu=ah.SQFS_SB_SIZE+1024; SEN=0xffffffffffffffff
sb=struct.pack(ah.SQFS_SB_FMT,
    MAGIC,10,0,bs,0,              # 5I: magic,inodes,mtime,block,frags
    1,log,0,2,4,0,                # 6H: comp,log,flags,ids,major,minor
    42,bu,                        # 8Q: root_inode,bytes_used
    ah.SQFS_SB_SIZE,SEN,ah.SQFS_SB_SIZE,ah.SQFS_SB_SIZE,SEN,SEN)  # id,xattr,inode,dir,frag,export
data=sb+b'\x00'*(bu-len(sb))
r=ah.squashfs_superblock(data,0)
assert r is not None,'should parse valid superblock'
assert r['major']==4 and r['minor']==0 and r['inodes']==10 and r['block_size']==bs
PY
then ok "squashfs_superblock: synthetic valid superblock parses correctly"; else no "squashfs_superblock: valid parse"; fi

# C-2  squashfs_superblock — junk / wrong magic returns None
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,struct,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1])
assert ah.squashfs_superblock(b'\x00'*200,0) is None,'all-zeros must return None'
SEN=0xffffffffffffffff; bu=ah.SQFS_SB_SIZE+100
sb=struct.pack(ah.SQFS_SB_FMT,
    0xDEADBEEF,10,0,131072,0,1,17,0,2,4,0,
    42,bu,ah.SQFS_SB_SIZE,SEN,ah.SQFS_SB_SIZE,ah.SQFS_SB_SIZE,SEN,SEN)
assert ah.squashfs_superblock(sb+b'\x00'*100,0) is None,'wrong magic must return None'
PY
then ok "squashfs_superblock: junk+wrong magic return None"; else no "squashfs_superblock: junk returns None"; fi

# C-3  squashfs_superblock — offset support (superblock not at byte 0)
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,struct,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1])
MAGIC=0x73717368; bs=131072; log=17; bu=ah.SQFS_SB_SIZE+512; SEN=0xffffffffffffffff
sb=struct.pack(ah.SQFS_SB_FMT,
    MAGIC,5,0,bs,0,1,log,0,1,4,0,42,bu,
    ah.SQFS_SB_SIZE,SEN,ah.SQFS_SB_SIZE,ah.SQFS_SB_SIZE,SEN,SEN)
prefix=b'\xde\xad'*64   # 128 bytes of garbage before the superblock
data=prefix+sb+b'\x00'*(bu-len(sb))
r=ah.squashfs_superblock(data,len(prefix))
assert r is not None,'should parse valid superblock at non-zero offset'
assert r['inodes']==5
PY
then ok "squashfs_superblock: non-zero offset parsing"; else no "squashfs_superblock: offset"; fi

# A-1  emit_evidence — ManifestError on nonzero manifest-CLI exit
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
stub=r/'fail_cli.py'; stub.write_text('import sys\nsys.exit(2)\n')
stage=r/'st_fail'; (stage/'engine').mkdir(parents=True)
(stage/'engine'/'stdout.txt').write_bytes(b''); (stage/'engine'/'stderr.txt').write_bytes(b'')
dest=r/'dst_fail'
try:
    ah.emit_evidence(stage=stage,schema='t.v1',domain={},
                     input_identity={},isolation={},limitations=[],errors=[],
                     manifest_spec={'dummy':1},manifest_cli=pathlib.Path(stub),
                     destination=dest,timeout=10)
    raise AssertionError('should raise ManifestError')
except ah.ManifestError: pass
PY
then ok "emit_evidence: ManifestError on nonzero manifest-CLI exit"; else no "emit_evidence: nonzero exit"; fi

# A-2  emit_evidence — timeout= mandatory; sleep stub killed, ManifestError raised fast
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys,time
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
stub=r/'sleep_cli.py'; stub.write_text('import time\ntime.sleep(9999)\n')
stage=r/'st_sleep'; (stage/'engine').mkdir(parents=True)
dest=r/'dst_sleep'
t0=time.monotonic()
try:
    ah.emit_evidence(stage=stage,schema='t.v1',domain={},
                     input_identity={},isolation={},limitations=[],errors=[],
                     manifest_spec={'dummy':1},manifest_cli=pathlib.Path(stub),
                     destination=dest,timeout=1)
    raise AssertionError('should raise ManifestError on timeout')
except ah.ManifestError:
    elapsed=time.monotonic()-t0
    assert elapsed<5,f'must time out within 5s, took {elapsed:.1f}s'
PY
then ok "emit_evidence: sleep stub killed by timeout (ManifestError <5s)"; else no "emit_evidence: timeout enforcement"; fi

# A-3  emit_evidence — evidence file written with correct schema + domain merge
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,json,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
stub=r/'ok_cli.py'; stub.write_text('import sys\nsys.exit(0)\n')
stage=r/'st_ok'; (stage/'engine').mkdir(parents=True)
dest=r/'dst_ok'
ah.emit_evidence(stage=stage,schema='my-schema.v1',domain={'tool_key':'tool_val'},
                 input_identity={'source':{},'staged':{}},
                 isolation={'launcher':{},'profile':{}},
                 limitations=['L1'],errors=[],
                 manifest_spec={'dummy':1},manifest_cli=pathlib.Path(stub),
                 destination=dest,timeout=10)
ev=json.loads((dest/'my-schema.v1.json').read_bytes())
assert ev['schema']=='my-schema.v1',f"wrong schema: {ev.get('schema')}"
assert ev['tool_key']=='tool_val',f"domain not merged: {ev}"
assert ev['limitations']==['L1']
assert ev['status']=='complete'
PY
then ok "emit_evidence: evidence file written with schema+domain+limitations; status=complete"; else no "emit_evidence: evidence file"; fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
