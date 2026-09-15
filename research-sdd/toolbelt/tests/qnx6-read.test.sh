#!/usr/bin/env bash
# Test suite for qnx6-read.sh (qnx6-evidence.v1)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../qnx6-read.sh"
FIXTURES="$HERE/fixtures/qnx6-read"
mkdir -p "$FIXTURES"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

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
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
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

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/qnx6_read.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  qnx6_read.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi
MUTDIR="$(mktemp -d)"

# --- M1: Remove os.O_NOFOLLOW guard on input --------------------------------
# Expected: symlink input is followed instead of rejected → T2 assertion fails
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/os\.O_RDONLY | _O_NOFOLLOW/os.O_RDONLY/' "$MUTDIR/qnx6_read.py"
if ! python3 -m py_compile "$MUTDIR/qnx6_read.py" 2>/dev/null; then
  mut_no "M1 O_NOFOLLOW input: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/qnx6_read.py"; then
  mut_no "M1 O_NOFOLLOW input: sed had no effect"
else
  _m1_exit=0
  python3 "$MUTDIR/qnx6_read.py" list \
    --input "$ROOT/sym.img" --output "$ROOT/m1.json" 2>/dev/null || _m1_exit=$?
  if [ "$_m1_exit" -ne 2 ]; then
    mut_ok "M1 O_NOFOLLOW input removal detected (exit $_m1_exit, not 2)"
  else
    mut_no "M1 O_NOFOLLOW input: mutation NOT detected (still exits 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M2: Invert magic check -------------------------------------------------
# Expected: valid image is now rejected → T4 assertion fails
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/if magic != _MAGIC:/if magic == _MAGIC:  # MUTANT/' \
  "$MUTDIR/qnx6_read.py"
if ! python3 -m py_compile "$MUTDIR/qnx6_read.py" 2>/dev/null; then
  mut_no "M2 magic-check: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/qnx6_read.py"; then
  mut_no "M2 magic-check: sed had no effect"
else
  _m2_exit=0
  python3 "$MUTDIR/qnx6_read.py" list \
    --input "$FIXTURES/valid.img" --output "$ROOT/m2.json" 2>/dev/null || _m2_exit=$?
  if [ "$_m2_exit" -ne 0 ]; then
    mut_ok "M2 magic-check inversion detected (valid image rejected, exit $_m2_exit)"
  else
    mut_no "M2 magic-check: mutation NOT detected (still exits 0)"
  fi
fi
rm -rf "$MUTDIR"

# --- M3: Zero out extracted bytes -------------------------------------------
# Expected: extracted file is empty instead of b'hello-world\n' → T6 fails
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/os\.write(out_fd, data)/os.write(out_fd, b"")/' "$MUTDIR/qnx6_read.py"
if ! python3 -m py_compile "$MUTDIR/qnx6_read.py" 2>/dev/null; then
  mut_no "M3 write-zero: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/qnx6_read.py"; then
  mut_no "M3 write-zero: sed had no effect (check that cmd_extract uses os.write(out_fd, data))"
else
  _m3_exit=0
  python3 "$MUTDIR/qnx6_read.py" extract \
    --input "$FIXTURES/valid.img" --fs-path /file \
    --output "$ROOT/m3_out" 2>/dev/null || _m3_exit=$?
  _m3_content=""
  [ -f "$ROOT/m3_out" ] && _m3_content="$(python3 -c "print(open('$ROOT/m3_out','rb').read())" 2>/dev/null)"
  if [ "$_m3_exit" -eq 0 ] && [ "$_m3_content" != "b'hello-world\\n'" ]; then
    mut_ok "M3 write-zero detected (extracted content is not b'hello-world\\n')"
  else
    mut_no "M3 write-zero: mutation NOT detected (content still correct or non-zero exit)"
  fi
fi
rm -rf "$MUTDIR"

# --- M4: Drop slash in path construction ------------------------------------
# Expected: path = base + name drops the '/' separator → '/file' becomes 'file'
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i "s/path = base + '\/' + name/path = base + name/" "$MUTDIR/qnx6_read.py"
if ! python3 -m py_compile "$MUTDIR/qnx6_read.py" 2>/dev/null; then
  mut_no "M4 path-slash: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/qnx6_read.py"; then
  mut_no "M4 path-slash: sed had no effect"
else
  _m4_exit=0
  python3 "$MUTDIR/qnx6_read.py" list \
    --input "$FIXTURES/valid.img" --output "$ROOT/m4.json" 2>/dev/null || _m4_exit=$?
  _m4_path=""
  if [ -f "$ROOT/m4.json" ]; then
    _m4_path="$(python3 -c "import json; d=json.load(open('$ROOT/m4.json')); print(d['entries'][0]['path'])" 2>/dev/null)"
  fi
  if [ "$_m4_path" != "/file" ]; then
    mut_ok "M4 path-slash detected (path is '$_m4_path', not '/file')"
  else
    mut_no "M4 path-slash: mutation NOT detected (path still '/file')"
  fi
fi
rm -rf "$MUTDIR"

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
