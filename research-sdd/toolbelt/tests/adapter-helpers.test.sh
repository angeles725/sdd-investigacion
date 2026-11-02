#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../lib/adapter_helpers.py"
[ -f "$SUT" ] || { echo "FATAL: adapter_helpers.py not found: $SUT" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# The Go port (rsdd/internal/core/adapter/helpers, kit issue #2391) replaced the cases for emit_evidence, warn_evidence,
# run_truncation, assert_safe_bind_root, venv_root_for and bind_venv (A-*, D-*, E-*, F-*, G-*): its parity tests
# drive this very module. What Go cannot cover stays here: the two dead functions the port drops
# (pcap_magic_check B-*, squashfs_superblock C-*) and how the live importers reach this module (I-1).

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

# I-1  importer surface — the two import forms the 18 importers use resolve every name they take
# surface_check TOOLBELT_DIR: exit 0 when both forms import cleanly from that tree.
surface_check() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path
tb = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(tb))            # `from lib.adapter_helpers import ...` (corroborate_*.py, pcap_flows.py)
from lib.adapter_helpers import (BindScopeError, ManifestError, VenvBindError, assert_safe_bind_root,
                                 bind_venv, emit_evidence, run_truncation, warn_evidence,
                                 _PCAP_MAGIC, _PCAPNG_MAGIC)
sys.path.insert(0, str(tb / "lib"))    # `from adapter_helpers import ...` (*_plan.py, gate.py, vm_run.py)
from adapter_helpers import assert_safe_bind_root as a2, BindScopeError as b2
import adapter_core
assert a2 is not None and b2 is not None
for cls in (BindScopeError, ManifestError, VenvBindError):
    assert issubclass(cls, adapter_core.AdapterError), cls
assert len(_PCAP_MAGIC) == 4 and len(_PCAPNG_MAGIC) == 4
PY
}
if surface_check "$HERE/.."; then ok "I-1: both importer forms resolve every imported name; error classes are AdapterErrors"; else no "I-1: importer surface"; fi

# ── Prove-teeth (--prove-teeth) ──────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  # Mutants are built in bash through lib/mutant.sh (refuses empty / byte-identical / live-tree /
  # symlink OUT). MUTANT_SYNTAX=none because the SUT is Python; a py compile check replaces `bash -n`.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_py_replace || exit 2
  # _ah_mutant LABEL OLD NEW OUT -- replace the first OLD in the SUT with NEW through the shared
  # lib/mutant.sh builder. rc 2 = anchor absent (SUT changed), rc 3 = refused by the helper or not
  # valid Python; the refusal text goes to stderr.
  _ah_mutant() { mutant_py_replace "$1" "$SUT" "$2" "$3" "$4"; }
  # teeth-nofollow: removing O_NOFOLLOW lets symlinks through; B-2 assertion fires
  _ah_mutant teeth-nofollow 'flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)' \
    'flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)  # MUTANT: O_NOFOLLOW removed' "$ROOT/m-nofollow.py"
  if [ $? -ne 0 ]; then (exit 2); else python3 - "$SUT" "$ROOT" "$ROOT/m-nofollow.py" <<'PY'
import sys, types
from pathlib import Path
sut = Path(sys.argv[1]); mut = Path(sys.argv[3]).read_text()
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
  fi
  case $? in
    1) ok "teeth-nofollow: O_NOFOLLOW removal -> symlink accepted -> B-2 assertion fires (has teeth)" ;;
    0) no "teeth-nofollow: B-2 stayed green with O_NOFOLLOW removed -- assertion has NO teeth" ;;
    *) no "teeth-nofollow: mutation target not found (SUT changed?)" ;;
  esac

  # teeth-surface: renaming run_truncation in a copy of the toolbelt lib makes the I-1 check fail
  _ah_mutant teeth-surface 'def run_truncation(' 'def run_truncation_mutant(' "$ROOT/m-surface.py"
  if [ $? -ne 0 ]; then (exit 2); else
    mkdir -p "$ROOT/m-surface/lib" && cp "$HERE/../lib/adapter_core.py" "$ROOT/m-surface/lib/" && cp "$ROOT/m-surface.py" "$ROOT/m-surface/lib/adapter_helpers.py"  # stage-libs-ok: the import check loads only adapter_core and the mutated adapter_helpers
    if surface_check "$ROOT/m-surface" 2>/dev/null; then (exit 0); else (exit 1); fi
  fi
  case $? in
    1) ok "teeth-surface: renaming run_truncation -> the importer import fails -> I-1 fires (has teeth)" ;;
    0) no "teeth-surface: run_truncation rename stayed importable -- NO teeth" ;;
    *) no "teeth-surface: mutation target not found (SUT changed?)" ;;
  esac
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
