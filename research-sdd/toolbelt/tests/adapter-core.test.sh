#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../lib/adapter_core.py"
[ -f "$SUT" ] || { echo "FATAL: adapter_core.py not found: $SUT" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# 1. identity: stable sha256+size; max_bytes rejection
if python3 - "$SUT" "$ROOT" <<'PY'
import hashlib,importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2]); f=r/'a.bin'; f.write_bytes(b'hello')
p,sz,d=ac.identity(f); assert sz==5 and d=='sha256:'+hashlib.sha256(b'hello').hexdigest()
p2,sz2,d2=ac.identity(f); assert (sz,d)==(sz2,d2)
try: ac.identity(f,max_bytes=3); raise AssertionError('should reject')
except ac.AdapterError: pass
PY
then ok "identity: stable sha256+size; max_bytes rejection"; else no "identity"; fi

# 2. stage_file: O_NOFOLLOW symlink refusal + staged identity match
if python3 - "$SUT" "$ROOT" <<'PY'
import hashlib,importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2]); src=r/'src.bin'; src.write_bytes(b'world')
ac.stage_file(src,r/'staged.bin','staged.bin',0o400)
_,sz,d=ac.identity(r/'staged.bin'); assert d=='sha256:'+hashlib.sha256(b'world').hexdigest()
lnk=r/'lnk.bin'; lnk.symlink_to(src)
try: ac.stage_file(lnk,r/'bad.bin','bad.bin',0o400); raise AssertionError('should reject symlink')
except ac.AdapterError: pass
PY
then ok "stage_file: staged identity match; O_NOFOLLOW symlink refusal"; else no "stage_file"; fi

# 3. stage_file: TOCTOU fstat-mismatch rejection via patched second fstat
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,os,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2]); src=r/'toctou.bin'; src.write_bytes(b'abc')
real=ac.os.fstat; n=[0]
def fake(fd):
    v=real(fd); n[0]+=1
    if n[0]==2:
        return os.stat_result((v.st_mode,v.st_ino,v.st_dev,v.st_nlink,v.st_uid,v.st_gid,v.st_size+1,v.st_atime,v.st_mtime,v.st_ctime))
    return v
ac.os.fstat=fake
try:
    ac.stage_file(src,r/'bad2.bin','bad2.bin',0o400); raise AssertionError('should detect TOCTOU')
except ac.AdapterError: pass
finally: ac.os.fstat=real
PY
then ok "stage_file: TOCTOU fstat-mismatch rejected"; else no "stage_file TOCTOU"; fi

# 4. require_private: fail-closed whitelist (rejects non-private, unknown FS; AdapterError on malformed)
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2])
for fs,mi in [('9p',f"1 0 8:1 / {r} rw - 9p p9 rw\n"),
              ('unknownfs',f"1 0 8:1 / {r} rw - unknownfs xyz rw\n"),
              ('malformed',"truncated-no-separator\n")]:
    try: ac.require_private(r,mountinfo=mi); raise AssertionError(f"should reject {fs}")
    except ac.AdapterError: pass
    except Exception as e: raise AssertionError(f"raw exception leaked for {fs}: {type(e).__name__}: {e}") from e
ac.require_private(r,mountinfo=f"1 0 8:1 / {r} rw - tmpfs t rw\n")
PY
then ok "require_private: rejects non-private+unknown FS; AdapterError on malformed (fail-closed)"; else no "require_private"; fi

# 5. sandbox: emitted bwrap argv includes all required security flags and no full-root bind
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys,os
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
sroot=pathlib.Path('/tmp/rsdd'); sroot.mkdir(mode=0o700,exist_ok=True)
if sroot.lstat().st_mode&0o077: sroot.chmod(0o700)
r=pathlib.Path(sys.argv[2]); bwrap=r/'bwrap'; bwrap.write_bytes(b''); bwrap.chmod(0o755)
argv=ac.sandbox(bwrap,{})
assert '--cap-drop' in argv and 'ALL' in argv, f"missing --cap-drop ALL: {argv}"
assert '--unshare-pid' in argv, f"missing --unshare-pid: {argv}"
assert '--unshare-net' in argv, f"missing --unshare-net: {argv}"
assert '--die-with-parent' in argv, f"missing --die-with-parent: {argv}"
assert ac.isolation_prefix is ac.sandbox, "isolation_prefix alias broken"
# SECURITY: full-root bind must NOT appear
pairs=list(zip(argv,argv[1:]))
assert not any(a=='--ro-bind' and b=='/' for a,b in pairs), f"full-root --ro-bind / found in: {argv}"
# /usr must be bound if it exists on this host
if os.path.exists('/usr'):
    assert any(b=='/usr' for a,b in pairs if a in ('--ro-bind','--ro-bind-try')), f"/usr not bound in: {argv}"
PY
then ok "sandbox: security flags present; full-root bind absent; /usr bound"; else no "sandbox flags"; fi

# 6. run_bounded: wall-timeout kill; output-cap truncation
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2]); eng=r/'engine'; eng.mkdir(exist_ok=True)
run,errs=ac.run_bounded(['sleep','60'],r,{'PATH':'/usr/bin:/bin'},timeout=1,max_bytes=1_000_000,max_processes=0)
assert 'timeout' in errs, f"expected timeout in errors: {errs}"
for f in ('stdout.txt','stderr.txt'): (eng/f).unlink(missing_ok=True)
run2,errs2=ac.run_bounded(['python3','-c',"print('A'*10000)"],r,{'PATH':'/usr/bin:/bin'},timeout=10,max_bytes=100,max_processes=0)
assert (eng/'stdout.txt').stat().st_size<=100, f"output not capped: {(eng/'stdout.txt').stat().st_size}"
assert any('cap' in e for e in errs2), f"expected cap error in: {errs2}"
PY
then ok "run_bounded: wall-timeout; output-cap truncation"; else no "run_bounded"; fi

# 7. publish: renameat2 RENAME_NOREPLACE refuses collision; destination preserved
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2])
stage=r/'stage2'; stage.mkdir(); dest=r/'dest2'; dest.mkdir()
try: ac.publish(stage,dest); raise AssertionError('should refuse existing destination')
except (ac.AdapterError,OSError): pass
assert dest.exists(), "destination was removed"
PY
then ok "publish: RENAME_NOREPLACE refuses collision; destination preserved"; else no "publish"; fi

# 8. sandbox: ro_inputs are bound; full-root still absent with ro_inputs
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys,os
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
sroot=pathlib.Path('/tmp/rsdd'); sroot.mkdir(mode=0o700,exist_ok=True)
if sroot.lstat().st_mode&0o077: sroot.chmod(0o700)
r=pathlib.Path(sys.argv[2]); bwrap=r/'bwrap2'; bwrap.write_bytes(b''); bwrap.chmod(0o755)
inp=r/'input_sample.bin'; inp.write_bytes(b'data')
argv=ac.sandbox(bwrap,{},ro_inputs=[str(inp)])
pairs=list(zip(argv,argv[1:]))
# full-root bind still absent
assert not any(a=='--ro-bind' and b=='/' for a,b in pairs), f"full-root bind found with ro_inputs: {argv}"
# input path must appear as --ro-bind src dst (both entries are the same path)
assert any(b==str(inp) for a,b in pairs if a in ('--ro-bind','--ro-bind-try')), f"ro_input {inp} not bound in: {argv}"
PY
then ok "sandbox: ro_inputs bound; full-root still absent"; else no "sandbox ro_inputs"; fi

# 9. stage_file: no partial target after error; retry does not hit FileExistsError
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,os,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2]); src=r/'clean_src.bin'; src.write_bytes(b'abc')
target=r/'clean_tgt.bin'
# Inject a TOCTOU-style failure AFTER the target is created (2nd fstat call returns mutated size)
real=ac.os.fstat; n=[0]
def fake(fd):
    v=real(fd); n[0]+=1
    if n[0]==2:
        return os.stat_result((v.st_mode,v.st_ino,v.st_dev,v.st_nlink,
                               v.st_uid,v.st_gid,v.st_size+1,
                               v.st_atime,v.st_mtime,v.st_ctime))
    return v
ac.os.fstat=fake
try:
    ac.stage_file(src,target,'clean_tgt.bin',0o400)
    raise AssertionError('should detect TOCTOU')
except ac.AdapterError: pass
finally: ac.os.fstat=real
# Partial target must be cleaned up
assert not target.exists(), f"partial target still exists after error: {target}"
# Retry (without patch) must succeed — no FileExistsError
src_r,tgt_r=ac.stage_file(src,target,'clean_tgt.bin',0o400)
assert target.exists(), "retry stage_file must create target"
PY
then ok "stage_file: partial target cleaned up on error; retry succeeds"; else no "stage_file cleanup"; fi

# 10. run: module-level alias points to run_bounded
if python3 - "$SUT" <<'PY'
import importlib.util,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
assert hasattr(ac,'run'), "run alias missing from adapter_core"
assert ac.run is ac.run_bounded, f"run alias must be run_bounded, got: {ac.run}"
PY
then ok "run: module-level alias points to run_bounded"; else no "run alias"; fi

# 11. executable: AdapterError for missing configured path; returns resolved path for real binary
if python3 - "$SUT" <<'PY'
import importlib.util,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
search='/bin:/usr/bin'
# Failure: configured path does not exist -> AdapterError (not raw OSError/FileNotFoundError)
try:
    ac.executable('true','/nonexistent/__no_such_binary_xyz__',search)
    raise AssertionError('should raise AdapterError')
except ac.AdapterError: pass
except Exception as e: raise AssertionError(f"expected AdapterError, got {type(e).__name__}: {e}") from e
# Success: no configured path override -> returns resolved path for real binary
path,record=ac.executable('true',None,search)
assert path.is_file(), f"resolved path not a file: {path}"
assert 'sha256' in record and record['sha256'].startswith('sha256:'), f"bad record: {record}"
PY
then ok "executable: AdapterError on missing configured path; returns path for real binary"; else no "executable"; fi

# 12. require_private: distinct message for no-match vs found-but-disallowed-fs
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2])
# No-match case: path is under no mount in the supplied mountinfo
try:
    ac.require_private(pathlib.Path('/xyz_no_such_path_abc'),
                       mountinfo="1 0 8:1 / /tmp rw - tmpfs t rw\n")
    raise AssertionError('should reject no-match path')
except ac.AdapterError as e:
    assert 'no known mount point' in str(e), f"no-match error must say 'no known mount point', got: {e!r}"
# Found-but-disallowed case: path IS covered by a mount but the FS type is not private
try:
    ac.require_private(r, mountinfo=f"1 0 8:1 / / rw - 9p p9 rw\n1 0 8:1 / {r} rw - 9p p9 rw\n")
    raise AssertionError('should reject non-private fs')
except ac.AdapterError as e:
    msg=str(e)
    assert 'no known mount point' not in msg, f"disallowed-fs error wrongly says no-match: {msg!r}"
    assert 'private' in msg.lower() or 'Linux-private' in msg, f"disallowed-fs error must mention private fs: {msg!r}"
PY
then ok "require_private: distinct no-match vs disallowed-fs messages"; else no "require_private distinct messages"; fi

# 13. sandbox: ro_inputs=['/'] raises AdapterError — root re-widening guard
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
sroot=pathlib.Path('/tmp/rsdd'); sroot.mkdir(mode=0o700,exist_ok=True)
if sroot.lstat().st_mode&0o077: sroot.chmod(0o700)
r=pathlib.Path(sys.argv[2]); bwrap=r/'bwrap13'; bwrap.write_bytes(b''); bwrap.chmod(0o755)
try:
    ac.sandbox(bwrap,{},ro_inputs=['/'])
    raise AssertionError('should raise AdapterError for ro_inputs=["/"]')
except ac.AdapterError: pass
PY
then ok "sandbox: ro_inputs='/' raises AdapterError"; else no "sandbox ro_inputs='/' guard"; fi

# 14. sandbox: ro_inputs=['/home/...'] raises AdapterError — prefix check independent of existence
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
sroot=pathlib.Path('/tmp/rsdd'); sroot.mkdir(mode=0o700,exist_ok=True)
if sroot.lstat().st_mode&0o077: sroot.chmod(0o700)
r=pathlib.Path(sys.argv[2]); bwrap=r/'bwrap14'; bwrap.write_bytes(b''); bwrap.chmod(0o755)
# Must reject /home/... regardless of whether the path exists on this host
try:
    ac.sandbox(bwrap,{},ro_inputs=['/home/someuser/secret'])
    raise AssertionError('should raise AdapterError for ro_inputs=["/home/..."]')
except ac.AdapterError: pass
PY
then ok "sandbox: ro_inputs='/home/...' raises AdapterError (prefix rule, existence-independent)"; else no "sandbox ro_inputs prefix guard"; fi

# 15. sandbox: legit temp-dir path in ro_inputs is bound; does not raise
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
sroot=pathlib.Path('/tmp/rsdd'); sroot.mkdir(mode=0o700,exist_ok=True)
if sroot.lstat().st_mode&0o077: sroot.chmod(0o700)
r=pathlib.Path(sys.argv[2]); bwrap=r/'bwrap15'; bwrap.write_bytes(b''); bwrap.chmod(0o755)
inp=r/'legit_input.bin'; inp.write_bytes(b'payload')
argv=ac.sandbox(bwrap,{},ro_inputs=[str(inp)])
pairs=list(zip(argv,argv[1:]))
assert any(b==str(inp) for a,b in pairs if a in ('--ro-bind','--ro-bind-try')), f"legit ro_input not bound: {argv}"
PY
then ok "sandbox: legit ro_input path is bound without error"; else no "sandbox legit ro_input"; fi

# 16. sandbox: /etc/resolv.conf and /etc/nsswitch.conf absent from emitted argv
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
sroot=pathlib.Path('/tmp/rsdd'); sroot.mkdir(mode=0o700,exist_ok=True)
if sroot.lstat().st_mode&0o077: sroot.chmod(0o700)
r=pathlib.Path(sys.argv[2]); bwrap=r/'bwrap16'; bwrap.write_bytes(b''); bwrap.chmod(0o755)
argv=ac.sandbox(bwrap,{})
assert '/etc/resolv.conf' not in argv, f"/etc/resolv.conf must not appear in argv: {argv}"
assert '/etc/nsswitch.conf' not in argv, f"/etc/nsswitch.conf must not appear in argv: {argv}"
# Dynamic-loader + TLS entries must remain
assert '/etc/ld.so.cache' in argv, f"/etc/ld.so.cache must still be present: {argv}"
PY
then ok "sandbox: resolv.conf+nsswitch.conf absent; dynamic-loader entries present"; else no "sandbox dns entries removed"; fi

# 17. sandbox: symlink ro_input → --ro-bind uses realpath, not symlink path (TOCTOU fix)
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
sroot=pathlib.Path('/tmp/rsdd'); sroot.mkdir(mode=0o700,exist_ok=True)
if sroot.lstat().st_mode&0o077: sroot.chmod(0o700)
r=pathlib.Path(sys.argv[2]); bw=r/'bw17'; bw.write_bytes(b''); bw.chmod(0o755)
t=r/'rf17.bin'; t.write_bytes(b'x'); lnk=r/'lnk17.lnk'; lnk.symlink_to(t)
argv=ac.sandbox(bw,{},ro_inputs=[str(lnk)]); pairs=list(zip(argv,argv[1:]))
assert any(b==str(t) for a,b in pairs if a=='--ro-bind'), f"realpath not in --ro-bind: {argv}"
assert not any(b==str(lnk) for a,b in pairs if a=='--ro-bind'), f"symlink path in --ro-bind (must be realpath): {argv}"
PY
then ok "sandbox: symlink ro_input binds realpath not symlink path"; else no "sandbox symlink realpath bind"; fi

# 18. sandbox: /run and /run/user/<uid> in ro_inputs raise AdapterError
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
sroot=pathlib.Path('/tmp/rsdd'); sroot.mkdir(mode=0o700,exist_ok=True)
if sroot.lstat().st_mode&0o077: sroot.chmod(0o700)
r=pathlib.Path(sys.argv[2]); bw=r/'bw18'; bw.write_bytes(b''); bw.chmod(0o755)
for bad in ['/run','/run/user/1000']:
    try: ac.sandbox(bw,{},ro_inputs=[bad]); raise AssertionError(f'should reject {bad}')
    except ac.AdapterError: pass
PY
then ok "sandbox: /run and /run/user/1000 rejected as ro_inputs"; else no "sandbox /run blocked"; fi

# 19. identity(): os.fstat OSError must become AdapterError (not raw OSError)
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,os,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2]); f=r/'id_fstat_eio.bin'; f.write_bytes(b'hello')
real=ac.os.fstat; n=[0]
def fake(fd):
    n[0]+=1
    if n[0]==1:
        raise OSError(5,"Input/output error")
    return real(fd)
ac.os.fstat=fake
try:
    ac.identity(f)
    raise AssertionError('identity should raise, did not')
except ac.AdapterError: pass
except OSError as e: raise AssertionError(f"raw OSError escaped identity fstat: {e}") from e
finally: ac.os.fstat=real
PY
then ok "identity: os.fstat OSError becomes AdapterError"; else no "identity os.fstat OSError escape"; fi

# 20. identity(): os.read OSError must become AdapterError (triangulate — different injection point)
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,os,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2]); f=r/'id_read_eio.bin'; f.write_bytes(b'hello')
real=ac.os.read
def fake(fd,n_bytes):
    raise OSError(5,"Input/output error")
ac.os.read=fake
try:
    ac.identity(f)
    raise AssertionError('identity should raise, did not')
except ac.AdapterError: pass
except OSError as e: raise AssertionError(f"raw OSError escaped identity read: {e}") from e
finally: ac.os.read=real
PY
then ok "identity: os.read OSError becomes AdapterError"; else no "identity os.read OSError escape"; fi

# 21. stage_file(): os.read OSError → AdapterError; partial target cleaned up
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,os,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2]); src=r/'sf_read_src.bin'; src.write_bytes(b'hello')
target=r/'sf_read_tgt.bin'
real=ac.os.read; n=[0]
def fake(fd,n_bytes):
    n[0]+=1
    if n[0]==1:
        raise OSError(5,"Input/output error")
    return real(fd,n_bytes)
ac.os.read=fake
raised=False
try:
    ac.stage_file(src,target,'sf_read_tgt.bin',0o400)
    raise AssertionError('stage_file should raise, did not')
except ac.AdapterError: raised=True
except OSError as e: raise AssertionError(f"raw OSError escaped stage_file read: {e}") from e
finally: ac.os.read=real
assert raised,"stage_file did not raise AdapterError"
assert not target.exists(),f"partial target not cleaned up: {target}"
PY
then ok "stage_file: os.read OSError becomes AdapterError; target cleaned up"; else no "stage_file os.read OSError escape"; fi

# 22. stage_file(): os.fstat OSError → AdapterError (triangulate — different injection point)
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,os,pathlib,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
r=pathlib.Path(sys.argv[2]); src=r/'sf_fstat_src.bin'; src.write_bytes(b'hello')
real=ac.os.fstat; n=[0]
def fake(fd):
    n[0]+=1
    if n[0]==1:
        raise OSError(5,"Input/output error")
    return real(fd)
ac.os.fstat=fake
try:
    ac.stage_file(src,r/'sf_fstat_tgt.bin','sf_fstat_tgt.bin',0o400)
    raise AssertionError('stage_file should raise, did not')
except ac.AdapterError: pass
except OSError as e: raise AssertionError(f"raw OSError escaped stage_file fstat: {e}") from e
finally: ac.os.fstat=real
PY
then ok "stage_file: os.fstat OSError becomes AdapterError"; else no "stage_file os.fstat OSError escape"; fi

# 23. refuse_privileged_execution: raises AdapterError for geteuid==0; no-op for normal
# RED: fails before helper is added to adapter_core (AttributeError on missing function).
if python3 - "$SUT" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location('ac', sys.argv[1])
ac = importlib.util.module_from_spec(s); s.loader.exec_module(ac)
# 23a: function must be exported
assert hasattr(ac, 'refuse_privileged_execution'), "refuse_privileged_execution missing from adapter_core"
# 23b: raises AdapterError when geteuid==0 (simulated root)
real_geteuid = ac.os.geteuid
ac.os.geteuid = lambda: 0
try:
    ac.refuse_privileged_execution()
    raise AssertionError("must raise AdapterError when geteuid==0")
except ac.AdapterError as e:
    assert "refusing root or set-id" in str(e), f"wrong message: {e!r}"
finally:
    ac.os.geteuid = real_geteuid
# 23c: no-op for normal (non-root, non-set-id) — must not raise
ac.refuse_privileged_execution()
PY
then ok "refuse_privileged_execution: exported; geteuid==0 → AdapterError with correct message; no-op for normal"; else no "refuse_privileged_execution"; fi


# 24. refuse_privileged_execution: SUID set-id branch (getuid!=geteuid, geteuid!=0) → AdapterError
if python3 - "$SUT" <<'PY'
import importlib.util,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
real_eu=ac.os.geteuid; real_u=ac.os.getuid
ac.os.geteuid=lambda:1000; ac.os.getuid=lambda:999
try:
    ac.refuse_privileged_execution(); raise AssertionError("must raise for set-id")
except ac.AdapterError as e:
    assert "refusing root or set-id" in str(e),f"wrong message: {e!r}"
finally:
    ac.os.geteuid=real_eu; ac.os.getuid=real_u
PY
then ok "refuse_privileged_execution: SUID branch (getuid!=geteuid, geteuid!=0) → AdapterError"; else no "refuse_privileged_execution SUID"; fi

# 25. refuse_privileged_execution: SGID branch (getgid!=getegid, geteuid==getuid!=0) → AdapterError
if python3 - "$SUT" <<'PY'
import importlib.util,sys
s=importlib.util.spec_from_file_location('ac',sys.argv[1]); ac=importlib.util.module_from_spec(s); s.loader.exec_module(ac)
real_eu=ac.os.geteuid; real_u=ac.os.getuid; real_eg=ac.os.getegid; real_g=ac.os.getgid
ac.os.geteuid=lambda:1000; ac.os.getuid=lambda:1000; ac.os.getegid=lambda:2000; ac.os.getgid=lambda:1000
try:
    ac.refuse_privileged_execution(); raise AssertionError("must raise for SGID set-id")
except ac.AdapterError as e:
    assert "refusing root or set-id" in str(e),f"wrong message: {e!r}"
finally:
    ac.os.geteuid=real_eu; ac.os.getuid=real_u; ac.os.getegid=real_eg; ac.os.getgid=real_g
PY
then ok "refuse_privileged_execution: SGID branch (getgid!=getegid, geteuid==getuid!=0) → AdapterError"; else no "refuse_privileged_execution SGID"; fi

# 26. Convention: every adapter with an args.worker dispatch branch must call
#     refuse_privileged_execution() in main() BEFORE that dispatch.
#     Anti-vacuity guard: if no adapters are discovered the assertion fails.
if python3 - "$HERE/.." <<'PY'
import sys
from pathlib import Path

toolbelt = Path(sys.argv[1])
adapters = [p for p in sorted(toolbelt.glob("*.py")) if "args.worker" in p.read_text()]

assert len(adapters) > 0, (
    f"vacuity: no adapter with args.worker dispatch found under {toolbelt} — "
    "glob broken or all adapters moved"
)

for path in adapters:
    src = path.read_text()
    main_start = src.find("def main(")
    assert main_start >= 0, f"{path.name}: no main() found"
    guard_pos = src.find("refuse_privileged_execution", main_start)
    dispatch_pos = src.find("args.worker", main_start)
    assert guard_pos >= 0, (
        f"{path.name}: refuse_privileged_execution not called in main()"
    )
    assert dispatch_pos >= 0, (
        f"{path.name}: args.worker dispatch not found in main()"
    )
    assert guard_pos < dispatch_pos, (
        f"{path.name}: guard (pos {guard_pos}) must precede "
        f"args.worker dispatch (pos {dispatch_pos})"
    )
PY
then ok "convention: all adapters with --worker dispatch call guard before dispatch in main()"; else no "adapter --worker guard convention"; fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
