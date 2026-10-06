#!/usr/bin/env bash
# Test suite for qnx6-read.sh (qnx6-evidence.v1)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../qnx6-read.sh"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# Fixtures are generated into the TEMP root, never into the live tests/fixtures dir (kit issue #1299
# item 6, CLAUDE.md section 8): the kit-tree guard only tolerates identical-byte rewrites.
FIXTURES="$ROOT/fixtures/qnx6-read"
mkdir -p "$FIXTURES" || { echo "FATAL: cannot create $FIXTURES" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Build QNX6 fixture images programmatically (never inside a live target dir)
# OFF=1: physical address = (block_ptr + 1) * 512
# Inode table: block_ptr=3 → byte 2048
# Root dir data: block_ptr=4 → byte 2560
# Superblock: byte 8192 (0x2000)
# ---------------------------------------------------------------------------
python3 - "$FIXTURES" <<'PY'
import struct, sys, os

out = sys.argv[1]
BS = 512
CONTENT = b'hello-world\n'

def make_base_sb(num_inodes):
    sb = bytearray(4096)
    struct.pack_into('<I',    sb,   0, 0x68191122)
    struct.pack_into('<IIII', sb,  48, BS, num_inodes, 0, 26)
    struct.pack_into('<Q', sb, 72, num_inodes * 128)
    struct.pack_into('<I', sb, 80, 3)
    for i in range(1, 16):
        struct.pack_into('<I', sb, 80 + i*4, 0xffffffff)
    sb[144] = 0
    struct.pack_into('<Q', sb, 232, 0)
    for i in range(16):
        struct.pack_into('<I', sb, 240 + i*4, 0xffffffff)
    sb[304] = 0
    return sb

def make_inode(di_size, di_mode, ptr0=0xffffffff):
    e = bytearray(128)
    struct.pack_into('<Q', e,  0, di_size)
    struct.pack_into('<H', e, 32, di_mode)
    struct.pack_into('<I', e, 36, ptr0)
    for i in range(1, 16):
        struct.pack_into('<I', e, 36 + i*4, 0xffffffff)
    e[100] = 0
    return e

def make_dirent(de_ino, name_bytes):
    e = bytearray(32)
    struct.pack_into('<I', e, 0, de_ino)
    e[4] = len(name_bytes)
    e[5:5+len(name_bytes)] = name_bytes
    return e

# valid.img: root dir with one regular file entry; file has real content at block 5
img = bytearray(13312)
img[8192:8192+4096] = make_base_sb(2)
img[2048:2048+128] = make_inode(32, 0x4000, ptr0=4)           # inode 1: root dir
img[2176:2176+128] = make_inode(len(CONTENT), 0x8000, ptr0=5) # inode 2: file with content
img[2560:2560+32]  = make_dirent(2, b'file')                   # root dir → inode 2
img[3072:3072+len(CONTENT)] = CONTENT                         # file data at block 5
with open(os.path.join(out, 'valid.img'), 'wb') as f:
    f.write(bytes(img))

# empty.img: valid QNX6 but root dir slot has de_ino=0 (skipped → no entries)
img2 = bytearray(13312)
img2[8192:8192+4096] = make_base_sb(1)
img2[2048:2048+128] = make_inode(32, 0x4000, ptr0=4)  # di_size=32 needed by _detect_off
# root dir block: de_ino=0 everywhere → listdir returns []
with open(os.path.join(out, 'empty.img'), 'wb') as f:
    f.write(bytes(img2))

# bad_magic.img: wrong magic, everything else zeros
img3 = bytearray(13312)
struct.pack_into('<I', img3, 8192, 0xdeadbeef)
with open(os.path.join(out, 'bad_magic.img'), 'wb') as f:
    f.write(bytes(img3))

# bad_inode.img: valid QNX6 with 2 inodes; root dir dirent → inode 999 (OOB)
img_bi = bytearray(13312)
img_bi[8192:8192+4096] = make_base_sb(2)
img_bi[2048:2048+128] = make_inode(32, 0x4000, ptr0=4)  # root dir
img_bi[2176:2176+128] = make_inode(0, 0x8000)            # inode 2 (unused)
img_bi[2560:2560+32]  = make_dirent(999, b'ghost')        # ← out-of-range inode!
with open(os.path.join(out, 'bad_inode.img'), 'wb') as f:
    f.write(bytes(img_bi))

# indirect_eof.img: valid magic, inode table levels=1, indirect block ptr past EOF
img_ie = bytearray(13312)
sb_ie = bytearray(4096)
struct.pack_into('<I',    sb_ie,   0, 0x68191122)
struct.pack_into('<IIII', sb_ie,  48, BS, 2, 0, 26)
struct.pack_into('<Q', sb_ie, 72, 2 * 128)   # inode table size
struct.pack_into('<I', sb_ie, 80, 200)        # ptr0 = block 200 (way past EOF)
for i in range(1, 16):
    struct.pack_into('<I', sb_ie, 80 + i*4, 0xffffffff)
sb_ie[144] = 1   # levels=1
struct.pack_into('<Q', sb_ie, 232, 0)
for i in range(16):
    struct.pack_into('<I', sb_ie, 240 + i*4, 0xffffffff)
sb_ie[304] = 0
img_ie[8192:8192+4096] = sb_ie
with open(os.path.join(out, 'indirect_eof.img'), 'wb') as f:
    f.write(bytes(img_ie))

# cyclic.img: two inodes each with TWO dirents pointing to the other (branching cycle)
# Without visited-inode set: exponential entries → OOM. With fix: 4 entries, terminates.
img_cy = bytearray(13312)
img_cy[8192:8192+4096] = make_base_sb(2)
img_cy[2048:2048+128] = make_inode(64, 0x4000, ptr0=4)  # inode 1: root, 2 entries → inode 2
img_cy[2176:2176+128] = make_inode(64, 0x4000, ptr0=5)  # inode 2: subdir, 2 entries → inode 1
img_cy[2560:2560+32]  = make_dirent(2, b'a')             # root dir → inode 2 as 'a'
img_cy[2592:2592+32]  = make_dirent(2, b'b')             # root dir → inode 2 as 'b'
img_cy[3072:3072+32]  = make_dirent(1, b'x')             # inode 2 → inode 1 as 'x' (cycle!)
img_cy[3104:3104+32]  = make_dirent(1, b'y')             # inode 2 → inode 1 as 'y' (cycle!)
with open(os.path.join(out, 'cyclic.img'), 'wb') as f:
    f.write(bytes(img_cy))

# deep.img: 42 nested directories — hits depth cap at depth=41; must emit truncated:true
# Block layout: off=1, BS=512
# Inode table: levels=1; indirect block at block_ptr=3 (byte 2048)
# Inode data blocks: block_ptrs 4..14 (11 blocks, bytes 2560..7679)
# Dir data blocks: block_ptrs 23..64 (bytes 12288..33280), skipping superblock area (blocks 15-22)
N_DEEP = 42
n_inode_data_blocks = (N_DEEP * 128 + BS - 1) // BS   # = 11
deep_size = (23 + N_DEEP + 1) * BS  # = 33792
img_dp = bytearray(deep_size)

sb_dp = bytearray(4096)
struct.pack_into('<I',    sb_dp,   0, 0x68191122)
num_blocks_dp = 23 + N_DEEP + 2   # = 67 (includes all blocks used)
struct.pack_into('<IIII', sb_dp,  48, BS, N_DEEP, 0, num_blocks_dp)
struct.pack_into('<Q', sb_dp, 72, N_DEEP * 128)   # inode table size
struct.pack_into('<I', sb_dp, 80, 3)               # ptr0 = indirect block at block_ptr 3
for i in range(1, 16):
    struct.pack_into('<I', sb_dp, 80 + i*4, 0xffffffff)
sb_dp[144] = 1   # levels=1
struct.pack_into('<Q', sb_dp, 232, 0)
for i in range(16):
    struct.pack_into('<I', sb_dp, 240 + i*4, 0xffffffff)
sb_dp[304] = 0
img_dp[8192:8192+4096] = sb_dp

# Indirect block at byte 2048 (block_ptr=3): pointers to inode data blocks 4..14
for i in range(128):
    val = (4 + i) if i < n_inode_data_blocks else 0xffffffff
    struct.pack_into('<I', img_dp, 2048 + i*4, val)

# Inode table data: inodes 1..N_DEEP in data blocks 4..14
for ino in range(1, N_DEEP + 1):
    blk_idx   = (ino - 1) // 4
    off_in_blk = ((ino - 1) % 4) * 128
    byte_off  = (4 + blk_idx + 1) * BS + off_in_blk
    dir_data_ptr = 22 + ino   # dir data blocks at 23..64
    img_dp[byte_off:byte_off + 128] = make_inode(32, 0x4000, ptr0=dir_data_ptr)

# Dir data blocks at block_ptrs 23..64: each dir has one dirent → next inode
for ino in range(1, N_DEEP + 1):
    dir_data_ptr = 22 + ino
    dir_byte = (dir_data_ptr + 1) * BS
    if ino < N_DEEP:
        img_dp[dir_byte:dir_byte + 32] = make_dirent(ino + 1, b'd')
    # else: last dir is empty (no dirent) — depth cap triggers when descending into it

with open(os.path.join(out, 'deep.img'), 'wb') as f:
    f.write(bytes(img_dp))

# oom.img: valid superblock with num_blocks=0x7FFFFFFF; the LONGFILE root-node
# (always read unconditionally during parse()) has a 3-level indirect tree and a
# declared size of 0x80000000 (2 GB).  With the old cap
# (min(size, num_blocks*bs) ≈ 2 GB) the loop tries to accumulate 2 GB and takes
# ~40 s → detectable by a 5-second timeout.  With the fstat-based cap
# (min(size, file_size-offset) ≈ 14 KB) the loop stops after ~28 iterations.
# Inode 1 is a plain small directory so _detect_off (which checks di_size < 50 M)
# succeeds and parse proceeds to the longfile read.
# Layout (off=1, bs=512):
#   block 3 (byte 2048): inode table — inode 1: size=32, mode=dir, ptr0=8, levels=0
#   block 4 (byte 2560): L3 indirect: all 128 pointers → block 5
#   block 5 (byte 3072): L2 indirect: all 128 pointers → block 6
#   block 6 (byte 3584): L1 indirect: all 128 pointers → block 7
#   block 7 (byte 4096): data block (512 bytes = leaf for longfile tree)
#   block 8 (byte 4608): root-dir data (32 zeros = one empty dirent slot)
OOM_IMG_SIZE = 0x3000  # 12288 bytes (covers all blocks through block 23)
img_oom = bytearray(OOM_IMG_SIZE)

sb_oom = bytearray(4096)
struct.pack_into('<I',    sb_oom,   0, 0x68191122)
struct.pack_into('<IIII', sb_oom,  48, BS, 1, 0, 0x7FFFFFFF)  # num_blocks inflated
# Inode root-node: size=128 (1 inode), ptr0=3, levels=0
struct.pack_into('<Q', sb_oom, 72, 128)
struct.pack_into('<I', sb_oom, 80, 3)
for i in range(1, 16):
    struct.pack_into('<I', sb_oom, 80 + i*4, 0xffffffff)
sb_oom[144] = 0  # levels=0
# Longfile root-node: size=0x80000000 (2 GB), ptr0=4, levels=3  ← CRAFTED
struct.pack_into('<Q', sb_oom, 232, 0x80000000)
struct.pack_into('<I', sb_oom, 240, 4)
for i in range(1, 16):
    struct.pack_into('<I', sb_oom, 240 + i*4, 0xffffffff)
sb_oom[304] = 3  # levels=3 for longfile
img_oom[8192:8192+4096] = sb_oom

# Inode table at block 3 (byte 2048): inode 1 — small dir (size=32, passes _detect_off)
inode_oom = bytearray(128)
struct.pack_into('<Q', inode_oom,  0, 32)     # size = 32 (one dirent slot)
struct.pack_into('<H', inode_oom, 32, 0x4000) # mode = directory
struct.pack_into('<I', inode_oom, 36, 8)      # ptr0 → block 8 (root-dir data)
for i in range(1, 16):
    struct.pack_into('<I', inode_oom, 36 + i*4, 0xffffffff)
inode_oom[100] = 0  # levels=0
img_oom[2048:2048+128] = inode_oom

# Block 4 (byte 2560): L3 indirect — all 128 pointers → block 5
for i in range(128):
    struct.pack_into('<I', img_oom, 2560 + i*4, 5)

# Block 5 (byte 3072): L2 indirect — all 128 pointers → block 6
for i in range(128):
    struct.pack_into('<I', img_oom, 3072 + i*4, 6)

# Block 6 (byte 3584): L1 indirect — all 128 pointers → block 7
for i in range(128):
    struct.pack_into('<I', img_oom, 3584 + i*4, 7)

# Block 7 (byte 4096): 512-byte data leaf (zeros — longfile leaf content)
# (already zeroed)

# Block 8 (byte 4608): root-dir data block — 32 zeros (de_ino=0 everywhere → empty)
# (already zeroed)

with open(os.path.join(out, 'oom.img'), 'wb') as f:
    f.write(bytes(img_oom))

# truncated_dir.img: valid QNX6 with root dir inode claiming size=32 (one dirent)
# but its data block pointer (block 99) is past the end of the image.
# _read_rn_file returns b'' because _rawblk past EOF returns b''.
# Without the truncation check → silent zero (status:complete, entries=[]).
# With the check → _QNX6Error → status:failed.
img_tr = bytearray(13312)
img_tr[8192:8192+4096] = make_base_sb(1)
inode_tr = bytearray(128)
struct.pack_into('<Q', inode_tr,  0, 32)   # size=32 (one dirent worth)
struct.pack_into('<H', inode_tr, 32, 0x4000)
struct.pack_into('<I', inode_tr, 36, 99)   # ptr0 → block 99 (past EOF)
for i in range(1, 16):
    struct.pack_into('<I', inode_tr, 36 + i*4, 0xffffffff)
inode_tr[100] = 0  # levels=0
img_tr[2048:2048+128] = inode_tr
with open(os.path.join(out, 'truncated_dir.img'), 'wb') as f:
    f.write(bytes(img_tr))

PY

# ---------------------------------------------------------------------------
# T1: absent input → exit 2, no JSON produced
# ---------------------------------------------------------------------------
_t1_exit=0
"$SUT" list --input "$ROOT/no-such.img" --output "$ROOT/t1.json" 2>/dev/null \
  || _t1_exit=$?
if [ "$_t1_exit" -eq 2 ] && [ ! -f "$ROOT/t1.json" ]; then
  ok "T1 absent input: exit 2, no JSON"
else
  no "T1 absent input: expected exit 2 + no JSON, got exit $_t1_exit"
fi

# ---------------------------------------------------------------------------
# T2: symlink input → exit 2 (O_NOFOLLOW guard)
# ---------------------------------------------------------------------------
ln -sf "$FIXTURES/valid.img" "$ROOT/sym.img"
_t2_exit=0
"$SUT" list --input "$ROOT/sym.img" --output "$ROOT/t2.json" 2>/dev/null \
  || _t2_exit=$?
if [ "$_t2_exit" -eq 2 ]; then
  ok "T2 symlink input: exit 2 (O_NOFOLLOW)"
else
  no "T2 symlink input: expected exit 2, got $_t2_exit"
fi

# ---------------------------------------------------------------------------
# T3: bad magic → exit 1, status:failed, errors populated
# ---------------------------------------------------------------------------
_t3_exit=0
"$SUT" list --input "$FIXTURES/bad_magic.img" --output "$ROOT/t3.json" 2>/dev/null \
  || _t3_exit=$?
if [ "$_t3_exit" -eq 1 ]; then
  if python3 - "$ROOT/t3.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'qnx6-evidence.v1'
assert d['status'] == 'failed'
assert len(d.get('errors', [])) > 0
PY
  then
    ok "T3 bad magic: exit 1, status:failed, errors list non-empty"
  else
    no "T3 bad magic: exit 1 but JSON missing or invalid"
  fi
else
  no "T3 bad magic: expected exit 1, got $_t3_exit"
fi

# ---------------------------------------------------------------------------
# T4: valid QNX6 → exit 0, status:complete, entries, exact path correct
# ---------------------------------------------------------------------------
_t4_exit=0
"$SUT" list --input "$FIXTURES/valid.img" --output "$ROOT/t4.json" 2>/dev/null \
  || _t4_exit=$?
if [ "$_t4_exit" -eq 0 ]; then
  if python3 - "$ROOT/t4.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'qnx6-evidence.v1'
assert d['status'] == 'complete'
assert d['summary']['total_entries'] > 0
e = d['entries'][0]
assert e['path'] == '/file', f"expected path '/file', got {e['path']!r}"
assert 'type' in e and 'size_bytes' in e and 'mode' in e
assert d['filesystem']['filesystem_type'] == 'QNX6 Power-Safe'
assert isinstance(d['filesystem']['block_size'], int)
assert d['input']['partition_offset'] == 0
assert isinstance(d['input']['sha256'], str) and len(d['input']['sha256']) == 64
assert d['errors'] == []
PY
  then
    ok "T4 valid QNX6: exit 0, all fields correct, path=='/file'"
  else
    no "T4 valid QNX6: exit 0 but JSON validation failed"
  fi
else
  no "T4 valid QNX6: expected exit 0, got $_t4_exit"
fi

# ---------------------------------------------------------------------------
# T5: empty FS → exit 0, status:complete, total_entries=0 (anti-silent-zero)
# ---------------------------------------------------------------------------
_t5_exit=0
"$SUT" list --input "$FIXTURES/empty.img" --output "$ROOT/t5.json" 2>/dev/null \
  || _t5_exit=$?
if [ "$_t5_exit" -eq 0 ]; then
  if python3 - "$ROOT/t5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete'
assert d['summary']['total_entries'] == 0
assert d['entries'] == []
PY
  then
    ok "T5 empty FS: exit 0, status:complete, total_entries=0"
  else
    no "T5 empty FS: exit 0 but JSON validation failed"
  fi
else
  no "T5 empty FS: expected exit 0, got $_t5_exit"
fi

# ---------------------------------------------------------------------------
# T6: extract subcommand → exit 0, correct byte content extracted
# ---------------------------------------------------------------------------
_t6_exit=0
"$SUT" extract --input "$FIXTURES/valid.img" --fs-path /file \
  --output "$ROOT/extracted" 2>/dev/null || _t6_exit=$?
if [ "$_t6_exit" -eq 0 ] && python3 - "$ROOT/extracted" <<'PY' 2>/dev/null
import sys
data = open(sys.argv[1], 'rb').read()
assert data == b'hello-world\n', f"expected b'hello-world\\n', got {data!r}"
PY
then
  ok "T6 extract: exit 0, correct byte content"
else
  no "T6 extract: expected exit 0 + correct content, got exit $_t6_exit"
fi

# ---------------------------------------------------------------------------
# T7: extract missing path → exit 1
# ---------------------------------------------------------------------------
_t7_exit=0
"$SUT" extract --input "$FIXTURES/valid.img" --fs-path /no-such-file \
  --output "$ROOT/t7out" 2>/dev/null || _t7_exit=$?
if [ "$_t7_exit" -eq 1 ]; then
  ok "T7 extract missing path: exit 1"
else
  no "T7 extract missing path: expected exit 1, got $_t7_exit"
fi

# ---------------------------------------------------------------------------
# T8: root dirent → out-of-range inode → exit 1, status:failed JSON emitted
# (BLOCKER 3a: walk() error must not escape as a raw traceback with no JSON)
# ---------------------------------------------------------------------------
_t8_exit=0
"$SUT" list --input "$FIXTURES/bad_inode.img" --output "$ROOT/t8.json" 2>/dev/null \
  || _t8_exit=$?
if [ "$_t8_exit" -eq 1 ] && python3 - "$ROOT/t8.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"expected 'failed', got {d['status']!r}"
assert len(d.get('errors', [])) > 0, "errors list must be non-empty"
PY
then
  ok "T8 bad inode: exit 1, status:failed JSON written"
else
  no "T8 bad inode: expected exit 1 + status:failed JSON, got exit $_t8_exit (no JSON or wrong status)"
fi

# ---------------------------------------------------------------------------
# T9: inode table uses indirect block past EOF → struct.error during parse
#     → exit 1, status:failed JSON emitted (not a traceback)
# ---------------------------------------------------------------------------
_t9_exit=0
"$SUT" list --input "$FIXTURES/indirect_eof.img" --output "$ROOT/t9.json" 2>/dev/null \
  || _t9_exit=$?
if [ "$_t9_exit" -eq 1 ] && python3 - "$ROOT/t9.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"expected 'failed', got {d['status']!r}"
assert len(d.get('errors', [])) > 0, "errors list must be non-empty"
PY
then
  ok "T9 indirect EOF: exit 1, status:failed JSON written"
else
  no "T9 indirect EOF: expected exit 1 + status:failed JSON, got exit $_t9_exit (no JSON or wrong status)"
fi

# ---------------------------------------------------------------------------
# T10: cyclic dir (branching: each inode points to the other with 2 entries)
#      → must TERMINATE with bounded output (visited-inode set prevents OOM)
# ---------------------------------------------------------------------------
_t10_exit=0
timeout 10 "$SUT" list --input "$FIXTURES/cyclic.img" --output "$ROOT/t10.json" \
  2>/dev/null || _t10_exit=$?
if [ "$_t10_exit" -eq 0 ] && python3 - "$ROOT/t10.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"status must be 'complete', got {d['status']!r}"
n = d['summary']['total_entries']
assert n < 100, f"expected bounded entries (<100), got {n}"
PY
then
  ok "T10 cyclic dir: terminates, status:complete, bounded entries"
else
  no "T10 cyclic dir: expected bounded completion (exit 0, <100 entries), got exit $_t10_exit"
fi

# ---------------------------------------------------------------------------
# T11: deep chain (42 dirs) → depth cap fires → truncated:true in JSON
# ---------------------------------------------------------------------------
_t11_exit=0
"$SUT" list --input "$FIXTURES/deep.img" --output "$ROOT/t11.json" 2>/dev/null \
  || _t11_exit=$?
if [ "$_t11_exit" -eq 0 ] && python3 - "$ROOT/t11.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"status must be 'complete', got {d['status']!r}"
assert d.get('truncated') is True, f"expected truncated:true, got {d.get('truncated')!r}"
PY
then
  ok "T11 deep chain: exit 0, truncated:true"
else
  no "T11 deep chain: expected exit 0 + truncated:true, got exit $_t11_exit"
fi

# ---------------------------------------------------------------------------
# T12: --output pointing at a symlink → exit 2, victim not overwritten
# ---------------------------------------------------------------------------
echo "victim-content" > "$ROOT/victim.txt"
ln -sf "$ROOT/victim.txt" "$ROOT/out_sym.json"
_t12_exit=0
"$SUT" list --input "$FIXTURES/valid.img" --output "$ROOT/out_sym.json" \
  2>/dev/null || _t12_exit=$?
_victim_ok=0
[ "$(cat "$ROOT/victim.txt" 2>/dev/null)" = "victim-content" ] && _victim_ok=1
if [ "$_t12_exit" -eq 2 ] && [ "$_victim_ok" -eq 1 ]; then
  ok "T12 output symlink: exit 2, victim not overwritten"
else
  no "T12 output symlink: expected exit 2 + victim intact, got exit $_t12_exit (victim_ok=$_victim_ok)"
fi

# ---------------------------------------------------------------------------
# T13: non-regular input (FIFO) → exit 2, no hang (#518 S_ISREG guard)
# ---------------------------------------------------------------------------
mkfifo "$ROOT/fifo.img"
_t13_exit=0
timeout 5 "$SUT" list --input "$ROOT/fifo.img" --output "$ROOT/t13.json" \
  2>/dev/null || _t13_exit=$?
if [ "$_t13_exit" -eq 2 ] && [ ! -f "$ROOT/t13.json" ]; then
  ok "T13 FIFO input: exit 2, no JSON, no hang"
else
  no "T13 FIFO input: expected exit 2 + no JSON (no hang), got exit $_t13_exit"
fi

# ---------------------------------------------------------------------------
# T14: crafted num_blocks=0x7FFFFFFF + 3-level longfile tree → no hang
#      (#514 MINOR-1: fstat-based cap must stop the read at file_size, not 2 GB)
# Pre-fix: longfile _read_rn_file loops ~4 M iterations → timeout in 5 s.
# Post-fix: loop stops after ~28 iterations → exits in << 1 s.
# ---------------------------------------------------------------------------
_t14_exit=0
# Pre-fix: ~2M leaf-block iterations (longfile 3-level tree) takes ~4 s → exits 124.
# Post-fix: fstat cap stops the loop at ~28 iterations → completes in << 1 s.
timeout 2 "$SUT" list --input "$FIXTURES/oom.img" --output "$ROOT/t14.json" \
  2>/dev/null || _t14_exit=$?
# Must complete within the timeout: exit 0 or 1 (not 124).
# If exit 1, a valid JSON file must be present (no raw traceback).
if [ "$_t14_exit" -eq 0 ] || { [ "$_t14_exit" -eq 1 ] && python3 - "$ROOT/t14.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert 'status' in d
PY
}; then
  ok "T14 crafted num_blocks: exit $_t14_exit, no hang, clean result"
else
  no "T14 crafted num_blocks: expected exit 0 or 1 (no hang), got exit $_t14_exit"
fi

# ---------------------------------------------------------------------------
# T15: truncated directory data block → typed error (§7 anti-silent-zero)
#      (#514 MINOR-2: status:failed, not status:complete with total_entries=0)
# ---------------------------------------------------------------------------
_t15_exit=0
"$SUT" list --input "$FIXTURES/truncated_dir.img" --output "$ROOT/t15.json" \
  2>/dev/null || _t15_exit=$?
if [ "$_t15_exit" -eq 1 ] && python3 - "$ROOT/t15.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"expected 'failed', got {d['status']!r}"
assert len(d.get('errors', [])) > 0, "errors list must be non-empty"
PY
then
  ok "T15 truncated dir: exit 1, status:failed, errors non-empty (not silent-zero)"
else
  no "T15 truncated dir: expected exit 1 + status:failed, got exit $_t15_exit"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
# Hermeticity (kit issue #1299 item 6): fixtures are built in $ROOT; a rewrite of anything under
# research-sdd/ is caught by the run-all kit-tree guard (no per-suite assertion: the live fixture dir
# no longer exists, so one would be vacuous).
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: qnx6 mutation controls --"
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

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/qnx6_read.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  qnx6_read.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi
# Mutants live under $ROOT (a mktemp dir, removed by the single EXIT trap above), one dir each.
# Only the single mutated file is copied: qnx6_read.py imports only the stdlib (qnx6_read.py:23-31)
# and has no __file__-relative resource.
MUTBASE="$ROOT/mut"; mkdir -p "$MUTBASE"
MUTPY=""

# mut_build LABEL ID SED_EXPR — builds $MUTBASE/ID/qnx6_read.py through mutant_chain (empty,
# identical, dead-stage, placement refusals) plus a Python syntax check. On refusal the tooth is
# counted ONCE here and never runs; returns 1.
mut_build(){
  local label="$1" id="$2" expr="$3"
  MUTPY="$MUTBASE/$id/qnx6_read.py"; mkdir -p "$MUTBASE/$id"
  if ! MUTANT_SYNTAX=none mutant_chain "$label" "$ORIG_PY" "$MUTPY" "$expr"; then
    mut_no "$label: mutant refused by lib/mutant.sh (refusal counted here once; tooth not run)"; return 1
  fi
  if ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$MUTPY" 2>/dev/null; then
    mut_no "$label: mutant is not valid Python (refusal counted here once; tooth not run)"; return 1
  fi
}

# Wrapper run against the original and the mutant. Each run gets a FRESH output dir (removed by the
# wrapper's own trap) and prints typed RC=/STATUS=/fact lines, so the control observes the same
# artifact the base test asserts on.
Q_WRAP='py="$1"; in="$2"; fact="$3"; to="$4"; orig="$5"; [ "$py" = "$orig" ] && to=60; o="$(mktemp -d)" || exit 99
trap "rm -rf \"$o\"" EXIT
case "$fact" in
  fifo) mkfifo "$o/in.img"; in="$o/in.img" ;;
  victim) echo victim-m9 > "$o/v"; ln -s "$o/v" "$o/out" ;;
esac
if [ "$fact" = extract ]; then
  timeout "$to" python3 "$py" extract --input "$in" --fs-path /file --output "$o/out" 2>/dev/null; rc=$?
else
  timeout "$to" python3 "$py" list --input "$in" --output "$o/out" 2>/dev/null; rc=$?
fi
echo "RC=$rc"
echo "STATUS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"status\"])" "$o/out" 2>/dev/null || echo none)"
case "$fact" in
  extract) echo "CONTENT=$(python3 -c "import sys; print(open(sys.argv[1],\"rb\").read())" "$o/out" 2>/dev/null)" ;;
  path) echo "PATH=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[\"entries\"][0][\"path\"])" "$o/out" 2>/dev/null)" ;;
  trunc) echo "TRUNC=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(\"truncated\"))" "$o/out" 2>/dev/null)" ;;
  victim) echo "VICTIM=$(head -c 40 "$o/v" | tr "\n" " ")" ;;
esac
exit "$rc"'
# qt LABEL GOOD_RC BAD_RC [--good-has RE ...] -- FIXTURE FACT MUTANT_TIMEOUT_SECONDS (the original always gets 60 s; only the mutant is bounded tightly)
qt(){
  local label="$1" g="$2" b="$3"; shift 3
  local -a opts=()
  while [ "${1:-}" != -- ]; do opts+=("$1" "$2"); shift 2; done
  shift
  if mutant_tooth "$label" "$g" "$b" "$MUTPY" --orig "$ORIG_PY" "${opts[@]}" -- bash -c "$Q_WRAP" _ @SUT@ "$1" "$2" "$3" "$ORIG_PY"; then
    MUT_PASS=$((MUT_PASS+1))
  else
    MUT_FAIL=$((MUT_FAIL+1))
  fi
}

# --- M1: Remove os.O_NOFOLLOW guard on input: the symlink input is followed, not rejected (T2)
if mut_build "M1 O_NOFOLLOW input" M1 's/os\.O_RDONLY | _O_NOFOLLOW/os.O_RDONLY/'; then
  qt "M1 O_NOFOLLOW input removal" 2 0 --good-has '^STATUS=none$' --bad-has '^STATUS=complete$' \
    -- "$ROOT/sym.img" list 5
fi

# --- M2: Invert magic check: a valid image is now rejected (T4)
if mut_build "M2 magic-check" M2 's/if magic != _MAGIC:/if magic == _MAGIC:  # MUTANT/'; then
  qt "M2 magic-check inversion" 0 1 --good-has '^STATUS=complete$' --bad-has '^STATUS=failed$' \
    -- "$FIXTURES/valid.img" list 5
fi

# --- M3: Zero out extracted bytes (T6)
if mut_build "M3 write-zero" M3 's/os\.write(out_fd, data)/os.write(out_fd, b"")/'; then
  qt "M3 write-zero" 0 0 --good-has "CONTENT=b'hello-world\\\\n'" --bad-has "CONTENT=b''" \
    -- "$FIXTURES/valid.img" extract 5
fi

# --- M4: Drop the slash in path construction: '/file' becomes 'file'
if mut_build "M4 path-slash" M4 "s/path = base + '\/' + name/path = base + name/"; then
  qt "M4 path-slash" 0 0 --good-has '^PATH=/file$' --bad-has '^PATH=file$' \
    -- "$FIXTURES/valid.img" path 5
fi

# --- M5: Replace the walk-error append with pass: walk errors silently ignored (T8)
if mut_build "M5 walk-error" M5 's/errors.append(f"walk error: {exc}")/pass  # MUTANT_M5/'; then
  qt "M5 walk-error removal" 1 0 --good-has '^STATUS=failed$' --bad-has '^STATUS=complete$' \
    -- "$FIXTURES/bad_inode.img" list 5
fi

# --- M6: Remove the visited-inode guard: cyclic.img never terminates (T10) → timeout rc 124
if mut_build "M6 cycle-guard" M6 's/if ino in visited:/if False:  # MUTANT_M6/'; then
  qt "M6 cycle-guard removal" 0 124 --good-has '^STATUS=complete$' --bad-has '^STATUS=none$' \
    -- "$FIXTURES/cyclic.img" list 5
fi

# --- M7: Restore the old num_blocks-based cap (fstat cap removed): oom.img read times out
if mut_build "M7 fstat-cap" M7 's/real_file_bytes = max(0, os.fstat(self._fd).st_size - self._poff)/real_file_bytes = self.num_blocks * self._bs  # MUTANT_M7/'; then
  qt "M7 fstat-cap removal" 0 124 --good-has '^STATUS=complete$' --bad-has '^STATUS=none$' \
    -- "$FIXTURES/oom.img" list 2
fi

# --- M8: Remove truncated[0] = True: depth-cap truncation flag suppressed (T11)
if mut_build "M8 truncated-flag" M8 's/truncated\[0\] = True/pass  # MUTANT_M8/'; then
  qt "M8 truncated-flag removal" 0 0 --good-has '^TRUNC=True$' --bad-has '^TRUNC=False$' \
    -- "$FIXTURES/deep.img" trunc 5
fi

# --- M9: Remove O_EXCL and O_NOFOLLOW from the output write: the symlinked victim is overwritten (T12)
if mut_build "M9 output-guards" M9 's/os\.O_WRONLY | os\.O_CREAT | os\.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC/os.O_WRONLY | os.O_CREAT | _O_CLOEXEC/'; then
  qt "M9 output-guards removal" 2 0 --good-has '^VICTIM=victim-m9 $' --bad-lacks '^VICTIM=victim-m9 $' \
    -- "$FIXTURES/valid.img" victim 5
fi

# --- M10: Remove O_NONBLOCK from the input open: a FIFO input blocks → timeout rc 124 (T13)
# Only rc 2 vs 124 distinguishes the sides here (both print STATUS=none); the input is a per-run FIFO.
if mut_build "M10 O_NONBLOCK" M10 's/os\.O_RDONLY | _O_NOFOLLOW | _O_NONBLOCK/os.O_RDONLY | _O_NOFOLLOW/'; then
  qt "M10 O_NONBLOCK removal" 2 124 --good-has '^STATUS=none$' --bad-has '^STATUS=none$' \
    -- "(unused: fifo mode builds its own input)" fifo 3
fi

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
