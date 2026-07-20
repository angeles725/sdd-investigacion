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

# 5. sandbox: emitted bwrap argv includes all required security flags
if python3 - "$SUT" "$ROOT" <<'PY'
import importlib.util,pathlib,sys
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
PY
then ok "sandbox: --cap-drop ALL --unshare-pid --unshare-net --die-with-parent present"; else no "sandbox flags"; fi

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

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
