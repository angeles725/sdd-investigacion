#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../scan-firmware.sh"
TOOLBELT="$(dirname "$HERE")"
# --prove-teeth child runs point the python-level cases at a mutant copy of firmware_carve.py.
FC="$HERE/../firmware_carve.py"
if [ "${1:-}" = "--teeth-child" ]; then
  [ -f "${2:-}" ] || { echo "FATAL: --teeth-child needs an existing staged SUT file, got [${2:-}]" >&2; exit 2; }
  FC="$2"; echo "TEETH-CHILD: SUT=$FC"
fi
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
if python3 - "$FC" "$ROOT" <<'PY'
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
if python3 - "$FC" "$ROOT" <<'PY'
import importlib.util,mmap,pathlib,struct,sys
s=importlib.util.spec_from_file_location('f',sys.argv[1]); f=importlib.util.module_from_spec(s); s.loader.exec_module(f); root=pathlib.Path(sys.argv[2])
p=root/'headers'; h=bytearray(160); struct.pack_into('<5I6H8Q',h,0,0x73717368,1,0,4096,0,1,12,0,1,4,0,0,160,128,0xffffffffffffffff,96,120,0xffffffffffffffff,0xffffffffffffffff); p.write_bytes(h*10000)
with p.open('r+b') as stream:
 data=mmap.mmap(stream.fileno(),0)
 try: f.candidates(data,2,3,10**12); raise AssertionError("candidate-count cap not enforced")
 except f.CarveError as exc: assert 'caps' in str(exc)
 data.close()
for flags,offset in ((0,48),(0x80,88)):
 q=bytearray(h); struct.pack_into('<H',q,24,flags); struct.pack_into('<Q',q,offset,0xffffffffffffffff)
 p.write_bytes(q)
 with p.open('r+b') as stream:
  data=mmap.mmap(stream.fileno(),0); assert not f.candidates(data,2,3,1024), "required SquashFS table accepted when absent"; data.close()
PY
then ok "repeated candidates stay bounded and required SquashFS tables fail closed"; else no "bounded traversal and SquashFS tables"; fi
if python3 - "$FC" "$ROOT" <<'PY'
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
if ! "$SUT" extract "$ROOT/firmware.bin" "$ROOT/legacy" 2>"$ROOT/legacy.err" && grep -q 'removed.*carve' "$ROOT/legacy.err"; then ok "unsafe legacy extraction is unreachable and gives migration guidance"; else no "legacy migration"; fi
if python3 - "$FC" <<'PY'
import contextlib,importlib.util,io,sys
s=importlib.util.spec_from_file_location('f',sys.argv[1]); f=importlib.util.module_from_spec(s); s.loader.exec_module(f)
buf=io.StringIO(); f.os.geteuid=lambda:0
with contextlib.redirect_stderr(buf): r=f.main(['--input','x','--output','y'])
assert r==2, f"expected exit 2 for root, got {r}"
assert "root or set-id" in buf.getvalue(), f"expected 'root or set-id' in stderr, got: {buf.getvalue()!r}"
PY
then ok "root execution fails closed"; else no "caller safety"; fi
if python3 - "$FC" <<'PY'
import contextlib,importlib.util,io,sys
s=importlib.util.spec_from_file_location('f',sys.argv[1]); f=importlib.util.module_from_spec(s); s.loader.exec_module(f)
buf=io.StringIO(); f.os.geteuid=lambda:0
with contextlib.redirect_stderr(buf):
    r=f.main(['--input','x','--output','y','--worker','--stage','/tmp','--input-record','{}','--bwrap-path','/usr/bin/bwrap','--bwrap-sha256','sha256:abc'])
assert r==2, f"expected exit 2 for root, got {r}"
assert "root or set-id" in buf.getvalue(), f"expected 'root or set-id' in stderr, got: {buf.getvalue()!r}"
PY
then ok "--worker root execution fails closed (guard hoisted above worker branch)"; else no "--worker caller safety"; fi
if python3 - "$FC" "$ROOT" <<'PY'
import importlib.util,pathlib,sys,time
s=importlib.util.spec_from_file_location('f',sys.argv[1]); f=importlib.util.module_from_spec(s); s.loader.exec_module(f); root=pathlib.Path(sys.argv[2])
f.run_worker(['/usr/bin/python3','-c','import resource; assert resource.getrlimit(resource.RLIMIT_AS)[0]==67108864'],root,2,1,67108864)
for command,timeout,processes in ((['/bin/sh','-c','sleep 2'],.05,4),(['/bin/sh','-c',f'(sleep .5; touch {root}/LEAK)& sleep 2'],2,0)):
 try: f.run_worker(command,root,timeout,processes); raise AssertionError()
 except f.CarveError: pass
time.sleep(.7); assert not (root/'LEAK').exists()
PY
then ok "memory, timeout, and process caps constrain the worker tree"; else no "process cleanup"; fi
if python3 - "$FC" <<'PY'
import importlib.util, sys, argparse
s = importlib.util.spec_from_file_location('f', sys.argv[1])
f = importlib.util.module_from_spec(s); s.loader.exec_module(f)
called = [False]
def _spy():
    called[0] = True
    raise f.CarveError("self-guard-sentinel")
f.refuse_privileged_execution = _spy
args = argparse.Namespace()
try:
    f.worker(args)
    raise AssertionError("worker() returned without raising from privilege guard")
except f.CarveError as e:
    assert "self-guard-sentinel" in str(e), f"wrong CarveError: {e!r}"
except Exception as e:
    raise AssertionError(f"guard was not first: got {type(e).__name__}: {e}") from e
assert called[0], "refuse_privileged_execution was never called by worker()"
PY
then ok "worker(): calls refuse_privileged_execution() before accessing args (self-guard)"; else no "worker() self-guard"; fi
# ---------------------------------------------------------------------------
# --prove-teeth: mutation controls (kit issue #2053). Each mutant is a staged copy of the REAL
# firmware_carve.py (lib/ symlinked beside it); the whole suite is re-run with --teeth-child
# pointing the python-level cases at the mutant, and the named case must FAIL.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- teeth: mutation controls (hardlinks, bounded traversal, SquashFS tables, root guards, worker self-guard) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain_or_count mutant_tooth mutant_crash_re || exit 2
  _FC_REAL="$TOOLBELT/firmware_carve.py"
  _MUT="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$_MUT"; rm -f "$ROOT-parent-link"' EXIT
  _builds_failed=0
  _CRASH_ALL="$(mutant_crash_re imp)|SyntaxError|IndentationError|NameError|AttributeError|TypeError|KeyError|UnboundLocalError|is not defined|No module named|cannot import name|has no attribute|object is not (callable|subscriptable|iterable)|positional argument|unexpected keyword argument|invalid syntax|referenced before assignment|unsupported operand"; _CRASH="$_CRASH_ALL"
  # str(e) forms: a python case that prints nok(label, str(e)) drops the exception class, so a NameError
  # mutant shows only "name 'X' is not defined". The message forms below refuse it (kit issue #2066).
  _tooth_fc() { # LABEL BAD_CASE_LABEL SED_EXPR...
    local label="$1" want="$2" d; shift 2
    d="$_MUT/${label%%:*}"; mkdir -p "$d"; ln -s "$TOOLBELT/lib" "$d/lib"
    # The mutant is python: skip only the bash -n check; every other refusal still applies.
    MUTANT_SYNTAX=none mutant_chain_or_count _builds_failed "$label" "$_FC_REAL" "$d/firmware_carve.py" "$@" || return 1
    mutant_tooth "$label: case goes RED with the mutant" 0 1 "$d/firmware_carve.py" --orig "$_FC_REAL" \
      --bad-has "$want" --bad-lacks "$_CRASH" -- \
      bash "$HERE/firmware-carve.test.sh" --teeth-child @SUT@
  }
  _t() { if _tooth_fc "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  _t "fc-hardlink: external hardlink check disabled" "FAIL  hardlink safety" \
    's/if meta.st_nlink != 1: raise/if False: raise/'
  _t "fc-caps: candidate count/files cap disabled" "AssertionError: candidate-count cap not enforced" \
    's/if len(found) >= max_carves or len(found) + 2 > max_files: raise/if False: raise/'
  _t "fc-tables: required SquashFS tables accepted when absent" "AssertionError: required SquashFS table accepted when absent" \
    's/and all(x != 0xffffffffffffffff for x in required):/and True:/'
  _t "fc-root-main: main() root guard removed" "expected exit 2 for root|'root or set-id' in stderr" \
    's/^        refuse_privileged_execution()$/        pass/'
  # Control (kit issue #2066): a NameError mutant must be REFUSED by the crash filter, never counted as a bite.
  # The machinery half runs the real NameError mutant end to end; the message-form half greps the crash filter against a
  # FIXED string ("name 'zzz_undefined' is not defined"), not against real mutant output.
  _ctl_out="$(_tooth_fc "fc-ctl-nameerror: max_carves misspelled (NameError)" "FAIL  " \
    's/if len(found) >= max_carves or len(found) + 2 > max_files: raise/if len(found) >= max_carvesX or len(found) + 2 > max_files: raise/' 2>&1)"; _ctl_rc=$?
  if [ "$_ctl_rc" -ne 0 ] && grep -qF "mutant output still matches" <<<"$_ctl_out" \
     && grep -qE "$_CRASH" <<<"name 'zzz_undefined' is not defined"; then
    echo "  PASS  fc-ctl-nameerror: a NameError mutant is refused by the crash filter (class and str(e) message forms)"; pass=$((pass+1))
  else
    echo "  FAIL  fc-ctl-nameerror: NameError mutant was not refused (rc=$_ctl_rc): $(tr '\n' ' ' <<<"$_ctl_out" | head -c 200)"; fail=$((fail+1))
  fi
  # Control (kit issue #2066, Opus S1): a NameError on the ROOT path used to hide behind the bare `FAIL  caller safety`
  # label (sys.stderr was swapped, not redirected, so the traceback was swallowed). It must now be refused.
  _ctl2_out="$(_tooth_fc "fc-ctl-nameerror-root: root-path NameError (guard call misspelled)" "FAIL  caller safety|expected exit 2 for root" \
    's/^        refuse_privileged_execution()$/        refuse_privileged_executionX()/' 2>&1)"; _ctl2_rc=$?
  if [ "$_ctl2_rc" -ne 0 ] && grep -qF "mutant output still matches" <<<"$_ctl2_out"; then
    echo "  PASS  fc-ctl-nameerror-root: a NameError on the root path is refused (traceback no longer swallowed)"; pass=$((pass+1))
  else
    echo "  FAIL  fc-ctl-nameerror-root: root-path NameError mutant was not refused (rc=$_ctl2_rc): $(tr '\n' ' ' <<<"$_ctl2_out" | head -c 200)"; fail=$((fail+1))
  fi
  # With the worker() guard gone, the self-guard case reports a legitimate AttributeError ("guard was not
  # first: got AttributeError"), so the teeth below drop that class from the crash filter. Their bite
  # patterns stay specific: the case's own FAIL label / exact assertion text.
  # Carve-out kept minimal: only the AttributeError class and its "has no attribute" message form are dropped.
  _CRASH="${_CRASH_ALL/|AttributeError/}"; _CRASH="${_CRASH/|has no attribute/}"
  _t "fc-root-worker: root guard removed from main() and worker()" "expected exit 2 for root|'root or set-id' in stderr" \
    's/^        refuse_privileged_execution()$/        pass/' 's/^    refuse_privileged_execution()  #.*/    pass/'
  _t "fc-self-guard: worker() self-guard removed" "AssertionError: guard was not first: got AttributeError" \
    's/^    refuse_privileged_execution()  #.*/    pass/'
  rm -rf "$_MUT"
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
