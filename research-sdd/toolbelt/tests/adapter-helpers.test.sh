#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../lib/adapter_helpers.py"
[ -f "$SUT" ] || { echo "FATAL: adapter_helpers.py not found: $SUT" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

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


# C-4  squashfs_superblock — negative offset must return None (not a bogus valid superblock)
# Without offset<0 guard, squashfs_superblock(data, -SQFS_SB_SIZE) passes the bounds check
# (0 <= data_len), the magic check (data[-96:-92]=='hsqs'), and struct.unpack_from reads
# the superblock from the end of the buffer — returning a dict instead of None.
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,struct,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1])
MAGIC=0x73717368; bs=131072; log=17; bu=ah.SQFS_SB_SIZE+1024; SEN=0xffffffffffffffff
sb=struct.pack(ah.SQFS_SB_FMT,
    MAGIC,10,0,bs,0,1,log,0,2,4,0,42,bu,
    ah.SQFS_SB_SIZE,SEN,ah.SQFS_SB_SIZE,ah.SQFS_SB_SIZE,SEN,SEN)
data=b'\xde\xad'*512+sb  # 1024 padding bytes + valid 96-byte superblock; total=1120
# Primary RED: offset=-SQFS_SB_SIZE; without guard, bounds=0<=1120, magic='hsqs', struct succeeds
assert ah.squashfs_superblock(data,-ah.SQFS_SB_SIZE) is None,\
    'offset=-SQFS_SB_SIZE must return None (not a bogus valid superblock from the end of buf)'
# Triangulation: small negative offset; struct.error path also must return None
assert ah.squashfs_superblock(data,-10) is None,'offset=-10 must return None'
PY
then ok "squashfs_superblock: negative offset returns None (not bogus superblock)"; else no "squashfs_superblock: negative offset guard"; fi

# A-4  emit_evidence — unsafe schema strings raise ManifestError (path traversal guard)
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
cli=r/'ok2_cli.py'; cli.write_text('import sys\nsys.exit(0)\n')
def try_bad_schema(schema,tag):
    stg=r/f'st_{tag}'; (stg/'engine').mkdir(parents=True,exist_ok=True)
    try:
        ah.emit_evidence(stage=stg,schema=schema,domain={},
                         input_identity={},isolation={},limitations=[],errors=[],
                         manifest_spec={'dummy':1},manifest_cli=cli,
                         destination=r/f'dst_{tag}',timeout=10)
        raise AssertionError(f'schema={schema!r} should raise ManifestError')
    except ah.ManifestError: pass
try_bad_schema('../evil','pt1')   # path-traversal: parent dir
try_bad_schema('a/b','pt2')       # slash in schema
try_bad_schema('.hidden','pt3')   # leading dot
try_bad_schema('a\x00b','pt4')   # NUL byte
PY
then ok "emit_evidence: unsafe schema raises ManifestError (path traversal guard)"; else no "emit_evidence: unsafe schema guard"; fi

# A-5  emit_evidence — reserved domain key raises ManifestError; non-reserved accepted
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
cli=r/'ok3_cli.py'; cli.write_text('import sys\nsys.exit(0)\n')
for key in ('status','schema','input','isolation','limitations','errors'):
    stg=r/f'st_rk_{key}'; (stg/'engine').mkdir(parents=True,exist_ok=True)
    try:
        ah.emit_evidence(stage=stg,schema='t.v1',domain={key:'x'},
                         input_identity={},isolation={},limitations=[],errors=[],
                         manifest_spec={'dummy':1},manifest_cli=cli,
                         destination=r/f'dst_rk_{key}',timeout=10)
        raise AssertionError(f'domain key {key!r} should raise ManifestError')
    except ah.ManifestError: pass
PY
then ok "emit_evidence: reserved domain key raises ManifestError"; else no "emit_evidence: reserved key guard"; fi


# A-6  warn_evidence — stderr pointer format; detail included / excluded cleanly
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util, io, pathlib, sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
dest=r/'a6_dst'

# sub-case 1: detail non-empty → schema + path + detail all appear in stderr
buf=io.StringIO(); _s=sys.stderr; sys.stderr=buf
ah.warn_evidence(schema='test-schema.v1', destination=dest, detail='analyzer-exit:1')
sys.stderr=_s
out=buf.getvalue()
assert 'test-schema.v1' in out, f"schema missing: {out!r}"
assert str(dest/'test-schema.v1.json') in out, f"evidence path missing: {out!r}"
assert 'analyzer-exit:1' in out, f"detail missing: {out!r}"

# sub-case 2: detail empty → pointer still emitted but no empty parentheses
buf2=io.StringIO(); sys.stderr=buf2
ah.warn_evidence(schema='test-schema.v1', destination=dest, detail='')
sys.stderr=_s
out2=buf2.getvalue()
assert 'test-schema.v1' in out2, f"schema missing on empty detail: {out2!r}"
assert '()' not in out2, f"empty () must not appear: {out2!r}"
assert str(dest/'test-schema.v1.json') in out2, f"evidence path missing on empty detail: {out2!r}"
PY
then ok "A-6: warn_evidence: stderr pointer with/without detail; no empty ()"; else no "A-6: warn_evidence pointer format"; fi

# A-7  emit_evidence — auto-fires warn_evidence when errors non-empty; silent when empty
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util, io, pathlib, sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
stub=r/'ok_a7.py'; stub.write_text('import sys\nsys.exit(0)\n')

# sub-case 1: errors non-empty → stderr pointer
stage=r/'st_a7e'; (stage/'engine').mkdir(parents=True)
dest=r/'dst_a7e'
buf=io.StringIO(); _s=sys.stderr; sys.stderr=buf
try:
    ah.emit_evidence(stage=stage,schema='my-schema.v1',domain={},
                     input_identity={},isolation={},limitations=[],
                     errors=['analyzer-exit:1'],
                     manifest_spec={'dummy':1},manifest_cli=pathlib.Path(stub),
                     destination=dest,timeout=10)
finally:
    sys.stderr=_s
out=buf.getvalue()
assert 'my-schema.v1' in out, f"schema missing from stderr: {out!r}"
assert str(dest/'my-schema.v1.json') in out, f"evidence path missing from stderr: {out!r}"

# sub-case 2: errors empty → no stderr output
stage2=r/'st_a7ok'; (stage2/'engine').mkdir(parents=True)
dest2=r/'dst_a7ok'
buf2=io.StringIO(); sys.stderr=buf2
try:
    ah.emit_evidence(stage=stage2,schema='my-schema.v1',domain={},
                     input_identity={},isolation={},limitations=[],
                     errors=[],
                     manifest_spec={'dummy':1},manifest_cli=pathlib.Path(stub),
                     destination=dest2,timeout=10)
finally:
    sys.stderr=_s
assert buf2.getvalue()=='', f"stderr must be empty on no errors: {buf2.getvalue()!r}"
PY
then ok "A-7: emit_evidence auto-fires warn_evidence on errors; silent on empty errors"; else no "A-7: emit_evidence warn_evidence integration"; fi

# ---------------------------------------------------------------------------
# D-1  venv_root_for + bind_venv — synthetic venv happy path
# ---------------------------------------------------------------------------
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
venv=r/'deep'/'venvs'/'mytool'
(venv/'bin').mkdir(parents=True); exe=venv/'bin'/'mytool'; exe.write_text('')
(venv/'pyvenv.cfg').write_text('[python]\nversion=3.11\n')
root=ah.venv_root_for(exe)
assert root==venv, f"expected {venv}, got {root}"
out=ah.bind_venv(['bwrap','--'],exe)
assert out[-1]=='--', f"must end with '--': {out}"
assert '--ro-bind' in out, f"--ro-bind missing: {out}"
parts=venv.parts
for i in range(1,len(parts)):
    stub=str(pathlib.Path(*parts[:i+1]))
    assert stub in out, f"--dir stub missing for {stub!r}: {out}"
PY
then ok "D-1: venv_root_for + bind_venv happy path (stubs+ro-bind+trailing --)"; else no "D-1: venv happy path"; fi

# D-2  /home/<user>/bin/tool → VenvBindError via shape check (no FS needed)
if python3 - "$SUT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1])
try:
    ah.venv_root_for(pathlib.Path('/home/someuser/bin/tool'))
    raise AssertionError('should raise VenvBindError for /home/someuser')
except ah.VenvBindError: pass
PY
then ok "D-2: /home/<user> raises VenvBindError (shape check, no FS)"; else no "D-2: /home/<user> shape guard"; fi

# D-3  /usr/bin/tool → root /usr blocked → VenvBindError
if python3 - "$SUT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1])
try:
    ah.venv_root_for(pathlib.Path('/usr/bin/tool'))
    raise AssertionError('should raise VenvBindError for /usr/bin/tool')
except ah.VenvBindError: pass
PY
then ok "D-3: /usr/bin/tool raises VenvBindError (blocked exact root)"; else no "D-3: /usr blocked root"; fi

# D-4  bin/tool exists but no pyvenv.cfg → VenvBindError
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
nv=r/'nopyvenv'; (nv/'bin').mkdir(parents=True)
exe=nv/'bin'/'tool'; exe.write_text('')
try:
    ah.venv_root_for(exe)
    raise AssertionError('should raise VenvBindError when pyvenv.cfg absent')
except ah.VenvBindError: pass
PY
then ok "D-4: no pyvenv.cfg raises VenvBindError"; else no "D-4: missing pyvenv.cfg guard"; fi

# D-5  etc_ro_bind_try: allowed entries emitted; blocked entry raises VenvBindError
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
venv=r/'v5'; (venv/'bin').mkdir(parents=True); exe=venv/'bin'/'tool'; exe.write_text('')
(venv/'pyvenv.cfg').write_text('[python]\nversion=3.11\n')
out=ah.bind_venv(['bwrap','--'],exe,etc_ro_bind_try=('/etc/passwd','/etc/group'))
assert out.count('--ro-bind-try')>=2, f"expected >=2 --ro-bind-try: {out}"
assert '/etc/passwd' in out and '/etc/group' in out, f"entries missing: {out}"
try:
    ah.bind_venv(['bwrap','--'],exe,etc_ro_bind_try=('/etc/shadow',))
    raise AssertionError('should raise VenvBindError for /etc/shadow')
except ah.VenvBindError: pass
PY
then ok "D-5: allowed /etc entries emitted; /etc/shadow raises VenvBindError"; else no "D-5: etc_ro_bind_try guard"; fi

# D-6  writable: sandbox path not under /tmp/rsdd/ → VenvBindError; valid pair emitted
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
venv=r/'v6'; (venv/'bin').mkdir(parents=True); exe=venv/'bin'/'tool'; exe.write_text('')
(venv/'pyvenv.cfg').write_text('[python]\nversion=3.11\n')
wdir=r/'tmpwrite'; wdir.mkdir()
try:
    ah.bind_venv(['bwrap','--'],exe,writable=[(wdir,'/var/other')])
    raise AssertionError('should raise VenvBindError for sandbox_path not under /tmp/rsdd/')
except ah.VenvBindError: pass
out=ah.bind_venv(['bwrap','--'],exe,writable=[(wdir,'/tmp/rsdd/myout')])
assert '--dir' in out and '/tmp/rsdd/myout' in out, f"--dir missing: {out}"
assert '--bind' in out and str(wdir) in out, f"--bind missing: {out}"
assert out[-1]=='--', f"must end with '--': {out}"
PY
then ok "D-6: bad sandbox_path raises VenvBindError; valid writable pair emitted"; else no "D-6: writable guard"; fi

# D-7  prefix not ending '--' → VenvBindError (raises even before FS checks)
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
venv=r/'v7'; (venv/'bin').mkdir(parents=True); exe=venv/'bin'/'tool'; exe.write_text('')
(venv/'pyvenv.cfg').write_text('[python]\nversion=3.11\n')
try:
    ah.bind_venv(['bwrap','--chdir','/tmp/rsdd/work'],exe)
    raise AssertionError('should raise VenvBindError for prefix not ending "--"')
except ah.VenvBindError: pass
PY
then ok "D-7: prefix not ending '--' raises VenvBindError"; else no "D-7: prefix guard"; fi

# ---------------------------------------------------------------------------
# E-1  run_truncation — cap-error detection correctness
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util,pathlib,sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1])
for cap in ('timeout','output-cap','process-cap'):
    fired,lims=ah.run_truncation([cap],'floss')
    assert fired==True, f"expected True for {cap!r}, got {fired}"
    assert len(lims)==1, f"expected 1 limitation for {cap!r}: {lims}"
    assert cap in lims[0] and 'truncated' in lims[0], f"bad limitation for {cap!r}: {lims}"
fired,lims=ah.run_truncation(['analyzer-exit:1'],'floss')
assert fired==False and lims==[], f"analyzer-exit:1 must not be truncation: {fired},{lims}"
fired,lims=ah.run_truncation([],'floss')
assert fired==False and lims==[], f"empty errors must not be truncation: {fired},{lims}"
PY
then ok "E-1: run_truncation fires on timeout/output-cap/process-cap; not on analyzer-exit or empty"; else no "E-1: run_truncation"; fi

# ---------------------------------------------------------------------------
# F-1  assert_safe_bind_root — reject set (blocked roots, shallow paths, home dir)
#      Blocked: /, /home, /home/<user> (3 parts), /root, /usr, /tmp, ~ itself.
#      Note: the function performs one FS access (realpath of ~) for the belt check.
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, pathlib, os, sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1])

# BindScopeError must exist
assert hasattr(ah,'BindScopeError'), "BindScopeError class missing from adapter_helpers"
# assert_safe_bind_root must exist
assert hasattr(ah,'assert_safe_bind_root'), "assert_safe_bind_root function missing"

# --- reject set ---
must_reject = [
    pathlib.Path('/'),
    pathlib.Path('/home'),
    pathlib.Path('/home/someuser'),     # 3 parts — /home/<user>
    pathlib.Path('/root'),
    pathlib.Path('/usr'),
    pathlib.Path('/tmp'),
    pathlib.Path('/etc'),
    pathlib.Path('/bin'),
    pathlib.Path('/sbin'),
    pathlib.Path('/lib'),
    pathlib.Path('/lib64'),
    pathlib.Path('/proc'),
    pathlib.Path('/sys'),
    pathlib.Path('/dev'),
    pathlib.Path('/run'),
    pathlib.Path(os.path.realpath(os.path.expanduser('~'))),  # home itself
]
for p in must_reject:
    try:
        ah.assert_safe_bind_root(p)
        raise AssertionError(f'should reject {str(p)!r}')
    except ah.BindScopeError:
        pass

# --- accept set (safe deep paths) ---
must_accept = [
    pathlib.Path('/home/x/.local/share/y'),          # 5 parts — deep /home path
    pathlib.Path('/home/linuxbrew/.linuxbrew/Cellar/python/3.11'),  # 6 parts — brew keg
    pathlib.Path('/opt/myapp/venvs/capa'),            # 5 parts — non-home deep
]
for p in must_accept:
    try:
        ah.assert_safe_bind_root(p)
    except ah.BindScopeError as exc:
        raise AssertionError(f'should accept {str(p)!r}: {exc}')
PY
then ok "F-1: assert_safe_bind_root: reject set blocked, accept set passes"; else no "F-1: assert_safe_bind_root"; fi

# ---------------------------------------------------------------------------
# F-2  assert_safe_bind_root — triangulation: additional edge cases
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, pathlib, sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1])

# /home/<user>/<subdir> (4 parts) must be ACCEPTED
ah.assert_safe_bind_root(pathlib.Path('/home/alice/venvs'))

# /root/<something> (3 parts) must be ACCEPTED (only /root itself is blocked)
ah.assert_safe_bind_root(pathlib.Path('/root/myvenv'))

# /a/b/c (3 parts, not /home, not blocked exact) must be ACCEPTED
ah.assert_safe_bind_root(pathlib.Path('/a/b/c'))

# /home (2 parts) must be REJECTED (blocked exact AND depth)
try:
    ah.assert_safe_bind_root(pathlib.Path('/home'))
    raise AssertionError('/home must be rejected')
except ah.BindScopeError:
    pass

# Confirm BindScopeError is a subclass of AdapterError
# (adapter_helpers re-exports AdapterError from adapter_core)
assert hasattr(ah, 'AdapterError'), "AdapterError not re-exported by adapter_helpers"
assert issubclass(ah.BindScopeError, ah.AdapterError), \
    f"BindScopeError must be a subclass of AdapterError"
PY
then ok "F-2: assert_safe_bind_root: edge cases + BindScopeError subclass of AdapterError"; else no "F-2: assert_safe_bind_root edge cases"; fi

# ---------------------------------------------------------------------------
# G-1  venv_root_for — exception chaining: VenvBindError.__cause__ is BindScopeError
#      RED until venv_root_for uses `raise VenvBindError(...) from exc`.
# ---------------------------------------------------------------------------
if python3 - "$SUT" <<'PY'
import importlib.util, pathlib, sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1])
# /home/<user>/bin/tool → root = /home/<user> → shape-rejects → VenvBindError
# After fix: VenvBindError.__cause__ must be a BindScopeError (exception chaining)
try:
    ah.venv_root_for(pathlib.Path('/home/someuser/bin/tool'))
    raise AssertionError('should raise VenvBindError')
except ah.VenvBindError as exc:
    cause = exc.__cause__
    assert cause is not None, \
        f'VenvBindError.__cause__ must be set (use raise ... from exc), got None'
    assert isinstance(cause, ah.BindScopeError), \
        f'__cause__ must be BindScopeError, got {type(cause).__name__}'
PY
then ok "G-1: venv_root_for exception chaining: VenvBindError.__cause__ is BindScopeError"; else no "G-1: exception chaining"; fi

# ---------------------------------------------------------------------------
# G-2  bind_venv — writable sandbox_path is normalized with normpath before check
#      RED until bind_venv applies os.path.normpath(sandbox_path) before startswith.
# ---------------------------------------------------------------------------
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util, pathlib, sys
def load(p):
    s=importlib.util.spec_from_file_location(pathlib.Path(p).stem,p)
    m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
ah=load(sys.argv[1]); r=pathlib.Path(sys.argv[2])
venv=r/'v_np'; (venv/'bin').mkdir(parents=True); exe=venv/'bin'/'tool'; exe.write_text('')
(venv/'pyvenv.cfg').write_text('[python]\nversion=3.11\n')
wdir=r/'tmpwrite_np'; wdir.mkdir()
# "/tmp/rsdd/../etc/evil" starts with "/tmp/rsdd/" literally but normpath resolves
# to "/tmp/etc/evil" — must be REJECTED after normpath guard
try:
    ah.bind_venv(['bwrap','--'],exe,writable=[(wdir,'/tmp/rsdd/../etc/evil')])
    raise AssertionError('path-traversal via .. must be rejected after normpath')
except ah.VenvBindError:
    pass  # correct
# double-slash "/tmp/rsdd//subdir" must normalize to "/tmp/rsdd/subdir" and PASS
out=ah.bind_venv(['bwrap','--'],exe,writable=[(wdir,'/tmp/rsdd//subdir')])
assert '/tmp/rsdd/subdir' in out, f'normalized path must appear in output: {out}'
assert out[-1]=='--', f"must end with '--': {out}"
PY
then ok "G-2: bind_venv writable: normpath rejects ../ traversal; double-slash normalizes"; else no "G-2: writable normpath guard"; fi

# ── Prove-teeth (--prove-teeth) ──────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  # teeth-normpath: removing normpath lets /tmp/rsdd/../etc/evil pass; G-2 assertion fires
  python3 - "$SUT" "$ROOT" <<'PY'
import sys, types
from pathlib import Path
sut = Path(sys.argv[1]); src = sut.read_text()
old = "sandbox_path = os.path.normpath(sandbox_path)"
if old not in src:
    print("MUTANT-SETUP-FAIL: normpath target not found -- SUT changed?", file=sys.stderr)
    sys.exit(2)
mut = src.replace(old, "sandbox_path = sandbox_path  # MUTANT: normpath removed", 1)
m = types.ModuleType("adapter_helpers"); m.__file__ = str(sut)
exec(compile(mut, str(sut), "exec"), m.__dict__); ah = m
r = Path(sys.argv[2])
venv = r / "pt_v"; (venv / "bin").mkdir(parents=True, exist_ok=True)
(venv / "bin" / "tool").write_text(""); (venv / "pyvenv.cfg").write_text("[python]\nversion=3.11\n")
wdir = r / "pt_w"; wdir.mkdir(exist_ok=True)
try:
    ah.bind_venv(["bwrap", "--"], venv / "bin" / "tool",
                 writable=[(wdir, "/tmp/rsdd/../etc/evil")])
    sys.exit(1)   # traversal accepted -- G-2 assertion fires -- has teeth
except ah.VenvBindError:
    sys.exit(0)   # guard still fires without normpath -- no teeth
PY
  case $? in
    1) ok "teeth-normpath: normpath removal -> traversal accepted -> G-2 assertion fires (has teeth)" ;;
    0) no "teeth-normpath: G-2 stayed green with normpath removed -- assertion has NO teeth" ;;
    *) no "teeth-normpath: mutation target not found (SUT changed?)" ;;
  esac

  # teeth-nofollow: removing O_NOFOLLOW lets symlinks through; B-2 assertion fires
  python3 - "$SUT" "$ROOT" <<'PY'
import sys, types
from pathlib import Path
sut = Path(sys.argv[1]); src = sut.read_text()
old = 'flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)'
if old not in src:
    print("MUTANT-SETUP-FAIL: O_NOFOLLOW flags line not found -- SUT changed?", file=sys.stderr)
    sys.exit(2)
mut = src.replace(old, 'flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)  # MUTANT: O_NOFOLLOW removed', 1)
m = types.ModuleType("adapter_helpers"); m.__file__ = str(sut)
exec(compile(mut, str(sut), "exec"), m.__dict__); ah = m
r = Path(sys.argv[2])
tgt = r / "pt_tgt.pcap"; tgt.write_bytes(b"\xd4\xc3\xb2\xa1" + b"\x00" * 20)
lnk = r / "pt_lnk.pcap"
if not lnk.exists():
    lnk.symlink_to(tgt)
try:
    ah.pcap_magic_check(lnk)
    sys.exit(1)   # symlink accepted -- B-2 assertion fires -- has teeth
except ah.PcapMagicError:
    sys.exit(0)   # guard still fires without O_NOFOLLOW -- no teeth
PY
  case $? in
    1) ok "teeth-nofollow: O_NOFOLLOW removal -> symlink accepted -> B-2 assertion fires (has teeth)" ;;
    0) no "teeth-nofollow: B-2 stayed green with O_NOFOLLOW removed -- assertion has NO teeth" ;;
    *) no "teeth-nofollow: mutation target not found (SUT changed?)" ;;
  esac

  # teeth-warn-evidence: dropping `if errors:` guard in emit_evidence causes
  # the empty-errors assertion to fail (stderr non-empty when it should be silent).
  python3 - "$SUT" "$ROOT" <<'PY'
import sys, types, io
from pathlib import Path
sut = Path(sys.argv[1]); src = sut.read_text()
# Target: the `if errors:` guard that gates warn_evidence inside emit_evidence
old = "    if errors:\n        warn_evidence(schema=schema, destination=destination, detail=\", \".join(errors))"
if old not in src:
    print("MUTANT-SETUP-FAIL: if-errors guard not found in emit_evidence -- SUT changed?", file=sys.stderr)
    sys.exit(2)
mut = src.replace(old,
    "    warn_evidence(schema=schema, destination=destination, detail=\", \".join(errors))  # MUTANT: guard removed",
    1)
m = types.ModuleType("adapter_helpers"); m.__file__ = str(sut)
exec(compile(mut, str(sut), "exec"), m.__dict__); ah = m
r = Path(sys.argv[2])
stub = r / "ok_teeth.py"; stub.write_text("import sys\nsys.exit(0)\n")
stage = r / "st_teeth"; (stage / "engine").mkdir(parents=True, exist_ok=True)
dest = r / "dst_teeth"
buf = io.StringIO(); _s = sys.stderr; sys.stderr = buf
try:
    ah.emit_evidence(stage=stage, schema="my-schema.v1", domain={},
                     input_identity={}, isolation={}, limitations=[],
                     errors=[],
                     manifest_spec={"dummy": 1}, manifest_cli=stub,
                     destination=dest, timeout=10)
finally:
    sys.stderr = _s
if buf.getvalue() != "":
    sys.exit(1)   # spurious stderr emitted -- A-7 empty-case assertion would fire -- has teeth
else:
    sys.exit(0)   # guard still silent without if-errors -- no teeth
PY
  case $? in
    1) ok "teeth-warn-evidence: if-errors removal -> spurious stderr -> A-7 empty-case fires (has teeth)" ;;
    0) no "teeth-warn-evidence: A-7 empty-case stayed green with guard removed -- NO teeth" ;;
    *) no "teeth-warn-evidence: mutation target not found (SUT changed?)" ;;
  esac
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
