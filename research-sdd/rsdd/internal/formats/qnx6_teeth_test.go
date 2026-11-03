package formats

// Mutation-killing tests for qnx6.go (kit issues #2561, #2592). Teeth runs with -tags nodiff, so none of these
// may depend on the legacy-script oracle: they drive the reader's own functions over small synthetic images
// built in the test, with no external tool. Every case names the mutation it pins.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"syscall"
	"testing"
)

// ---------------------------------------------------------------- image builder

type qtRoot struct {
	size   uint64
	ptrs   []uint32 // unlisted pointers are unused (0xFFFFFFFF)
	levels byte
}

type qtImage struct {
	poff, off, bs int
	inodeRN       qtRoot
	longRN        qtRoot
	blocks        map[uint32][]byte // block number -> content
	trim          int               // when > 0, the image is cut to this many bytes
}

func qtPut32(b []byte, o int, v uint32) { binary.LittleEndian.PutUint32(b[o:], v) }
func qtPut64(b []byte, o int, v uint64) { binary.LittleEndian.PutUint64(b[o:], v) }
func qtPut16(b []byte, o int, v uint16) { binary.LittleEndian.PutUint16(b[o:], v) }

func qtPutRoot(sb []byte, o int, r qtRoot) {
	qtPut64(sb, o, r.size)
	for i := 0; i < 16; i++ {
		p := uint32(qnxNoBlock)
		if i < len(r.ptrs) {
			p = r.ptrs[i]
		}
		qtPut32(sb, o+8+4*i, p)
	}
	sb[o+72] = r.levels
}

func (q qtImage) bytes() []byte {
	bs := q.bs
	if bs == 0 {
		bs = 512
	}
	end := q.poff + qnxSuperblockOffset + 0x1000
	for b, d := range q.blocks {
		end = max(end, q.poff+(int(b)+q.off)*bs+len(d))
	}
	img := make([]byte, end)
	sb := img[q.poff+qnxSuperblockOffset:]
	qtPut32(sb, 0, qnxMagic)
	qtPut32(sb, 48, uint32(bs))
	qtPut32(sb, 52, 4)
	qtPut32(sb, 60, 100)
	qtPutRoot(sb, 72, q.inodeRN)
	qtPutRoot(sb, 232, q.longRN)
	for b, d := range q.blocks {
		copy(img[q.poff+(int(b)+q.off)*bs:], d)
	}
	if q.trim > 0 {
		img = img[:q.trim]
	}
	return img
}

// file writes the image to a temp file and opens it.
func qtOpen(t *testing.T, img []byte) *os.File {
	t.Helper()
	p := filepath.Join(t.TempDir(), "img")
	if err := os.WriteFile(p, img, 0o600); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

func qtInode(size uint64, mode uint16, ptrs ...uint32) []byte {
	b := make([]byte, qnxInodeSize)
	qtPut64(b, 0, size)
	qtPut16(b, 32, mode)
	for i := 0; i < 16; i++ {
		p := uint32(qnxNoBlock)
		if i < len(ptrs) {
			p = ptrs[i]
		}
		qtPut32(b, 36+4*i, p)
	}
	return b
}

func qtDirent(ino uint32, name string) []byte {
	b := make([]byte, qnxDirentSize)
	qtPut32(b, 0, ino)
	b[4] = byte(len(name))
	copy(b[5:], name)
	return b
}

func qtCat(parts ...[]byte) []byte {
	var out []byte
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

const (
	qtDir  = 0x41ED
	qtFile = 0x81A4
)

// qtTree is a small filesystem: inode table in block 20, directory data in blocks >= 30.
func qtTree(inodes [][]byte, dirs map[uint32][]byte) qtImage {
	table := qtCat(inodes...)
	q := qtImage{inodeRN: qtRoot{size: uint64(len(table))}, blocks: map[uint32][]byte{}}
	for i := 0; i*512 < len(table); i++ { // the inode table: blocks 20, 21, ... (keep directory blocks >= 30)
		q.blocks[uint32(20+i)] = table[i*512 : min(len(table), (i+1)*512)]
		q.inodeRN.ptrs = append(q.inodeRN.ptrs, uint32(20+i))
	}
	for b, d := range dirs {
		q.blocks[b] = d
	}
	return q
}

func qtParse(t *testing.T, q qtImage) *qnxReader {
	t.Helper()
	r := newQNXReader(qtOpen(t, q.bytes()), int64(q.poff))
	if err := r.parse(); err != nil {
		t.Fatalf("parse: %v", err)
	}
	return r
}

func qtWalk(t *testing.T, r *qnxReader) ([]string, error) {
	t.Helper()
	var got []string
	truncated := false
	err := r.walk(1, "", 0, map[uint32]bool{}, &truncated, func(e walkEntry) { got = append(got, e.path) })
	return got, err
}

// ---------------------------------------------------------------- readAt

func TestQNXTeethReadAt(t *testing.T) {
	data := make([]byte, 100)
	for i := range data {
		data[i] = byte(i)
	}
	r := newQNXReader(qtOpen(t, data), 0)

	// pos 0 is the first byte; a position before the start is EINVAL (pins `pos < 0`).
	if got, err := r.readAt(0, 4); err != nil || !reflect.DeepEqual(got, data[:4]) {
		t.Errorf("readAt(0,4) = %v, %v", got, err)
	}
	_, err := r.readAt(-1, 4)
	var ioe *qnxIOError
	if !errors.As(err, &ioe) || ioe.en != syscall.EINVAL {
		t.Errorf("readAt(-1) = %v, want EINVAL", err)
	}
	// A count far beyond the file is clamped to what exists, never allocated (a 1 TiB make would abort).
	if got, err := r.readAt(90, 1<<40); err != nil || len(got) != 10 {
		t.Errorf("readAt(90, 1<<40) = %d bytes, %v; want 10", len(got), err)
	}
	if got, err := r.readAt(100, 8); err != nil || len(got) != 0 {
		t.Errorf("readAt at EOF = %d bytes, %v; want 0", len(got), err)
	}
	if got, err := r.readAt(98, 8); err != nil || !reflect.DeepEqual(got, data[98:]) {
		t.Errorf("readAt across EOF = %v, %v", got, err)
	}
}

// ---------------------------------------------------------------- blockPos

func TestQNXTeethBlockPosBounds(t *testing.T) {
	// lo == MaxInt64 is the last position Python can seek to (pins `lo > MaxInt64`).
	r := &qnxReader{bs: math.MaxInt64}
	if pos, err := r.blockPos(1); err != nil || pos != math.MaxInt64 {
		t.Errorf("blockPos at the limit = %d, %v", pos, err)
	}
	r = &qnxReader{bs: 1 << 63}
	if _, err := r.blockPos(1); err == nil || !strings.Contains(err.Error(), "out of range") {
		t.Errorf("blockPos(2**63) = %v, want out of range", err)
	}
	// poff + pos == MaxInt64 is fine, one more is not (pins `pos > MaxInt64-poff`).
	r = &qnxReader{bs: 1, poff: math.MaxInt64 - 5}
	if pos, err := r.blockPos(5); err != nil || pos != math.MaxInt64 {
		t.Errorf("blockPos(5) = %d, %v", pos, err)
	}
	if _, err := r.blockPos(6); err == nil || !strings.Contains(err.Error(), "out of range") {
		t.Errorf("blockPos(6) = %v, want out of range", err)
	}
	// A negative partition offset cannot overflow upwards, and the block offset is added before scaling.
	r = &qnxReader{bs: 4, poff: -10, off: 2}
	if pos, err := r.blockPos(8); err != nil || pos != 30 {
		t.Errorf("blockPos with negative poff = %d, %v; want 30", pos, err)
	}
}

// ---------------------------------------------------------------- parseRN

func TestQNXTeethParseRNReadsEveryPointer(t *testing.T) {
	sb := make([]byte, 0x131)
	qtPut64(sb, 72, 777)
	for i := 0; i < 16; i++ {
		qtPut32(sb, 80+4*i, uint32(1000+i))
	}
	sb[144] = 3
	rn := parseRN(sb, 72)
	if rn.size != 777 || rn.levels != 3 {
		t.Errorf("size/levels = %d/%d", rn.size, rn.levels)
	}
	for i, p := range rn.ptrs {
		if p != uint32(1000+i) {
			t.Errorf("ptrs[%d] = %d, want %d", i, p, 1000+i)
		}
	}
}

// ---------------------------------------------------------------- parse

func TestQNXTeethSuperblockLength(t *testing.T) {
	mk := func(n int) []byte {
		img := make([]byte, qnxSuperblockOffset+n)
		qtPut32(img, qnxSuperblockOffset, qnxMagic)
		qtPut32(img, qnxSuperblockOffset+48, 512)
		return img
	}
	// 0x131 bytes is the shortest readable superblock (pins `len(sb) < 0x131`); the tables are empty.
	if err := newQNXReader(qtOpen(t, mk(0x131)), 0).parse(); err != nil {
		t.Errorf("0x131-byte superblock refused: %v", err)
	}
	err := newQNXReader(qtOpen(t, mk(0x130)), 0).parse()
	if err == nil || err.Error() != "image too small to contain a QNX6 superblock" {
		t.Errorf("0x130-byte superblock = %v", err)
	}
}

func TestQNXTeethPartitionOffsetBound(t *testing.T) {
	f := qtOpen(t, make([]byte, 64))
	// MaxInt64-0x2000 is the last offset whose superblock position is representable: it is read, not refused
	// as out of range (pins `poff > MaxInt64-0x2000`).
	err := newQNXReader(f, math.MaxInt64-qnxSuperblockOffset).parse()
	if err != nil && strings.Contains(err.Error(), "partition offset is out of range") {
		t.Errorf("poff at the bound refused: %v", err)
	}
	err = newQNXReader(f, math.MaxInt64-qnxSuperblockOffset+1).parse()
	if err == nil || err.Error() != "partition offset is out of range" {
		t.Errorf("poff past the bound = %v", err)
	}
}

func TestQNXTeethDetectOffRange(t *testing.T) {
	root := qtInode(32, qtDir, 31)
	mk := func(off int) qtImage {
		q := qtTree([][]byte{root}, nil)
		q.off = off
		return q
	}
	// Candidates 0..39 are tried: 39 is found, 40 is not (pins `cand < 40`).
	if r := qtParse(t, mk(39)); r.off != 39 {
		t.Errorf("block offset = %d, want 39", r.off)
	}
	q := mk(40)
	err := newQNXReader(qtOpen(t, q.bytes()), 0).parse()
	if err == nil || !strings.HasPrefix(err.Error(), "cannot locate block offset") {
		t.Errorf("offset 40 = %v, want cannot locate", err)
	}
}

func TestQNXTeethDetectOffRootInode(t *testing.T) {
	try := func(size uint64) error {
		q := qtTree([][]byte{qtInode(size, qtDir, 31)}, nil)
		return newQNXReader(qtOpen(t, q.bytes()), 0).parse()
	}
	// The root directory must have 0 < size < 50,000,000 (pins both comparisons).
	for _, tc := range []struct {
		size uint64
		ok   bool
	}{{0, false}, {1, true}, {49_999_999, true}, {50_000_000, false}} {
		if err := try(tc.size); (err == nil) != tc.ok {
			t.Errorf("root size %d: err = %v, want ok=%v", tc.size, err, tc.ok)
		}
	}
	// 34 bytes (size + mode) are enough to judge the block, 33 are not (pins `len(raw) >= 34`).
	short := func(n int) error {
		q := qtTree([][]byte{qtInode(32, qtDir, 31)}, nil)
		q.inodeRN.size = 34
		q.trim = 20*512 + n
		return newQNXReader(qtOpen(t, q.bytes()), 0).parse()
	}
	if err := short(34); err != nil {
		t.Errorf("34-byte inode block refused: %v", err)
	}
	if err := short(33); err == nil {
		t.Error("33-byte inode block accepted")
	}
}

// ---------------------------------------------------------------- readRNFile

// qtRepeatLen reads a block tree whose sixteen pointers all name the same one-byte block (block size 1), in an
// image of size bytes, for a partition starting at poff. A tree can repeat a block, so only the cap on the read
// ends it: the result length is the cap.
func qtRepeatLen(t *testing.T, size int, poff int64, declared uint64) int {
	t.Helper()
	r := newQNXReader(qtOpen(t, bytes.Repeat([]byte{'X'}, size)), poff)
	r.bs = 1
	blk := uint32(0)
	if poff < 0 {
		blk = uint32(-poff) // lands on the first byte of the file
	}
	rn := rootNode{size: declared}
	for i := range rn.ptrs {
		rn.ptrs[i] = blk
	}
	got, err := r.readRNFile(rn)
	if err != nil {
		t.Fatalf("readRNFile(size %d, poff %d): %v", size, poff, err)
	}
	return len(got)
}

func TestQNXTeethReadRNFileIsCappedByTheImage(t *testing.T) {
	// The cap is the bytes the image holds from the partition start (size - poff, floored at 0), however the
	// partition sits relative to the file: pins every operator of that computation and the stop condition.
	for _, tc := range []struct {
		name     string
		size     int
		poff     int64
		declared uint64
		want     int
	}{
		{"partition inside the file", 7, 2, 1 << 20, 5},
		{"partition at the start", 7, 0, 1 << 20, 7},
		{"partition before the file", 7, -3, 1 << 20, 10},
		{"partition one byte before", 7, -1, 1 << 20, 8},
		{"partition at the end", 7, 7, 1 << 20, 0},
		{"partition past the end", 7, 9, 1 << 20, 0},
		{"declared size below the cap", 7, 2, 3, 3},
		{"declared size equals the cap", 7, 2, 5, 5},
		{"declared size above the cap", 7, 2, 6, 5},
	} {
		if got := qtRepeatLen(t, tc.size, tc.poff, tc.declared); got != tc.want {
			t.Errorf("%s: read %d bytes, want %d", tc.name, got, tc.want)
		}
	}
}

func TestQNXTeethReadRNFileEmptyAndTruncated(t *testing.T) {
	r := newQNXReader(qtOpen(t, make([]byte, 16)), 0)
	if got, err := r.readRNFile(rootNode{}); err != nil || got == nil || len(got) != 0 {
		t.Errorf("empty file = %v, %v", got, err)
	}
	// 600 bytes of leaves are cut to the declared 520.
	rn := rootNode{size: 520}
	for i := range rn.ptrs {
		rn.ptrs[i] = qnxNoBlock
	}
	img := bytes.Repeat([]byte{'Y'}, 3*512)
	rn.ptrs[0], rn.ptrs[1] = 0, 1
	r = newQNXReader(qtOpen(t, img), 0)
	if got, err := r.readRNFile(rn); err != nil || len(got) != 520 {
		t.Errorf("len = %d, %v; want 520", len(got), err)
	}
}

func TestQNXTeethDetectOffErrors(t *testing.T) {
	// A pointer that cannot be located is a parse error, reported as it is (not "cannot locate").
	r := newQNXReader(qtOpen(t, make([]byte, 64)), 0)
	r.bs = 1 << 33
	r.inodeRN = rootNode{size: 1}
	for i := range r.inodeRN.ptrs {
		r.inodeRN.ptrs[i] = qnxNoBlock
	}
	r.inodeRN.ptrs[0] = 0xFFFFFFFE
	if _, err := r.detectOff(); err == nil || !strings.Contains(err.Error(), "position is out of range") {
		t.Errorf("detectOff = %v, want the block position error", err)
	}
	// An I/O error on a candidate just moves on; with nothing readable the offset cannot be located.
	f := qtOpen(t, make([]byte, 4096))
	r = newQNXReader(f, 0)
	r.inodeRN = rootNode{size: 128, ptrs: [16]uint32{20}}
	f.Close()
	if _, err := r.detectOff(); err == nil || !strings.HasPrefix(err.Error(), "cannot locate block offset") {
		t.Errorf("detectOff on a closed file = %v, want cannot locate", err)
	}
}

func TestQNXTeethReadAtClosedFile(t *testing.T) {
	f := qtOpen(t, make([]byte, 16))
	r := newQNXReader(f, 0)
	f.Close()
	for _, n := range []uint64{4, 1 << 21} { // the large count goes through the size lookup first
		_, err := r.readAt(0, n)
		var ioe *qnxIOError
		if !errors.As(err, &ioe) {
			t.Errorf("readAt(%d) on a closed file = %v, want an I/O error", n, err)
		}
	}
}

// Reading /proc/self/mem at an unmapped address fails with EIO although the file reports size 0: a read of up
// to 1 MiB must reach the kernel (so the error surfaces, as the script's os.read does), and only a larger one
// is clamped to the size (pins `n > 1<<20`, both its boundary and its sense).
func TestQNXTeethReadAtReachesTheKernelUpToOneMiB(t *testing.T) {
	f, err := os.Open("/proc/self/mem")
	if err != nil {
		t.Skipf("no /proc/self/mem: %v", err)
	}
	defer f.Close()
	r := newQNXReader(f, 0)
	for _, n := range []uint64{1, 512, 1 << 20} {
		_, err := r.readAt(qnxSuperblockOffset, n)
		var ioe *qnxIOError
		if !errors.As(err, &ioe) || ioe.en != syscall.EIO {
			t.Errorf("readAt(%d) = %v, want EIO from the kernel", n, err)
		}
	}
	if got, err := r.readAt(qnxSuperblockOffset, 1<<20+1); err != nil || len(got) != 0 {
		t.Errorf("readAt(1 MiB + 1) = %d bytes, %v; want the size-clamped empty read", len(got), err)
	}
}

func TestQNXTeethReadAtDoesNotAllocateForAHugeCount(t *testing.T) {
	r := newQNXReader(qtOpen(t, make([]byte, 100)), 0)
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	// Far past the end: nothing is readable, and nothing may be allocated for the request.
	got, err := r.readAt(1<<30, 1<<40)
	runtime.ReadMemStats(&after)
	if err != nil || len(got) != 0 {
		t.Errorf("readAt = %d bytes, %v", len(got), err)
	}
	if d := after.TotalAlloc - before.TotalAlloc; d > 1<<20 {
		t.Errorf("readAt allocated %d bytes for a read past the end", d)
	}
}

func TestQNXTeethReadRNFileWithNoDataStillWalksEveryLeaf(t *testing.T) {
	// The partition starts at the end of the file: nothing is readable, but a pointer that cannot be located
	// is still an error (pins `real > 0`: a zero cap must not end the walk after the first leaf).
	r := newQNXReader(qtOpen(t, make([]byte, 512)), 512)
	r.bs = 1 << 33
	rn := rootNode{size: 1000}
	for i := range rn.ptrs {
		rn.ptrs[i] = qnxNoBlock
	}
	rn.ptrs[0], rn.ptrs[1] = 0, 0xFFFFFFFE
	_, err := r.readRNFile(rn)
	var pe *qnxParseError
	if !errors.As(err, &pe) || !strings.Contains(err.Error(), "out of range") {
		t.Errorf("err = %v, want a block position parse error", err)
	}
}

func TestQNXTeethEachLeafVisitsEveryIndirectPointer(t *testing.T) {
	img := make([]byte, 8*512)
	// Two indirect blocks (1 and 2), each holding one leaf pointer.
	qtPut32(img, 1*512, 3)
	for i := 1; i < 128; i++ {
		qtPut32(img, 1*512+4*i, qnxNoBlock)
		qtPut32(img, 2*512+4*i, qnxNoBlock)
	}
	qtPut32(img, 2*512, 4)
	r := newQNXReader(qtOpen(t, img), 0)
	ptrs := make([]uint32, 16)
	for i := range ptrs {
		ptrs[i] = qnxNoBlock
	}
	ptrs[0], ptrs[1] = 1, 2
	var seen []uint32
	stop, err := r.eachLeaf(ptrs, 1, func(blk uint32) (bool, error) { seen = append(seen, blk); return false, nil })
	if err != nil || stop || !reflect.DeepEqual(seen, []uint32{3, 4}) {
		t.Errorf("leaves = %v stop=%v err=%v; want [3 4]", seen, stop, err)
	}
	// A stop requested by the callback ends the whole walk.
	seen = nil
	stop, err = r.eachLeaf(ptrs, 1, func(blk uint32) (bool, error) { seen = append(seen, blk); return true, nil })
	if err != nil || !stop || !reflect.DeepEqual(seen, []uint32{3}) {
		t.Errorf("stopped walk: leaves = %v stop=%v err=%v; want [3] stop", seen, stop, err)
	}
}

// ---------------------------------------------------------------- longname

func TestQNXTeethLongname(t *testing.T) {
	long := make([]byte, 1024)
	copy(long, []byte{3, 0, 'a', 'b', 'c', 'X', 'Y', 'Z'})
	copy(long[512:], []byte{2, 0, 'd', 'e'})
	r := &qnxReader{bs: 512, longfile: long}
	for idx, want := range map[uint32]string{0: "abc", 1: "de"} { // idx scales by the block size
		if got, err := r.longname(idx); err != nil || got != want {
			t.Errorf("longname(%d) = %q, %v; want %q", idx, got, err, want)
		}
	}
	// The length prefix is honoured, and clamped to what the file holds.
	r = &qnxReader{bs: 512, longfile: []byte{9, 0, 'a', 'b'}}
	if got, err := r.longname(0); err != nil || got != "ab" {
		t.Errorf("clamped longname = %q, %v", got, err)
	}
	// A bare two-byte length prefix is a valid empty name; one byte less is out of range (pins `off+2 > len`).
	r = &qnxReader{bs: 512, longfile: []byte{0, 0}}
	if got, err := r.longname(0); err != nil || got != "" {
		t.Errorf("two-byte longfile = %q, %v", got, err)
	}
	r = &qnxReader{bs: 512, longfile: []byte{0}}
	if _, err := r.longname(0); err == nil || err.Error() != "longname index 0 out of range" {
		t.Errorf("one-byte longfile = %v", err)
	}
}

// ---------------------------------------------------------------- listdir / walk

func TestQNXTeethListdirIgnoresDataPastTheDeclaredSize(t *testing.T) {
	// The directory is 32 bytes (one entry); the block also holds a second entry after it, which must not be
	// listed (pins the entry-loop bound).
	dir := qtCat(qtDirent(2, "first"), qtDirent(3, "stray"))
	q := qtTree([][]byte{qtInode(32, qtDir, 31), qtInode(0, qtFile)}, map[uint32][]byte{31: dir})
	got, err := qtParse(t, q).listdir(1)
	if err != nil || len(got) != 1 || got[0].name != "first" {
		t.Errorf("listdir = %v, %v; want only 'first'", got, err)
	}
	// A size that is not a multiple of the entry size ignores the tail.
	q = qtTree([][]byte{qtInode(40, qtDir, 31), qtInode(0, qtFile)}, map[uint32][]byte{31: dir})
	got, err = qtParse(t, q).listdir(1)
	if err != nil || len(got) != 1 || got[0].name != "first" {
		t.Errorf("listdir (size 40) = %v, %v; want only 'first'", got, err)
	}
}

func TestQNXTeethListdirEmptyDirectory(t *testing.T) {
	q := qtTree([][]byte{qtInode(32, qtDir, 31), qtInode(0, qtDir)}, map[uint32][]byte{31: qtDirent(2, "d")})
	got, err := qtParse(t, q).listdir(2)
	if err != nil || len(got) != 0 {
		t.Errorf("empty directory = %v, %v", got, err)
	}
}

func TestQNXTeethWalkOrderAndSiblings(t *testing.T) {
	// root: b(dir 2), a(file 5), a(file 3), z(file 6); b holds x (4). The two files named a differ by size.
	inodes := [][]byte{
		qtInode(4*32, qtDir, 31), // 1 root
		qtInode(32, qtDir, 32),   // 2 b
		qtInode(3, qtFile),       // 3 a
		qtInode(0, qtFile),       // 4 x
		qtInode(5, qtFile),       // 5 a (second)
		qtInode(0, qtFile),       // 6 z
	}
	dirs := map[uint32][]byte{
		31: qtCat(qtDirent(2, "b"), qtDirent(5, "a"), qtDirent(3, "a"), qtDirent(6, "z")),
		32: qtDirent(4, "x"),
	}
	r := qtParse(t, qtTree(inodes, dirs))
	var got []string
	truncated := false
	err := r.walk(1, "", 0, map[uint32]bool{}, &truncated, func(e walkEntry) {
		got = append(got, fmt.Sprintf("%s:%d", e.path, e.size))
	})
	// Entries sort by name, then inode (3 before 5); a directory is followed by its content, then its siblings.
	want := []string{"/a:3", "/a:5", "/b:32", "/b/x:0", "/z:0"}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Errorf("walk = %v, %v; want %v", got, err, want)
	}
}

func TestQNXTeethWalkPropagatesAChildFailure(t *testing.T) {
	// b is a directory whose data block is missing: the walk fails instead of reporting it empty.
	inodes := [][]byte{qtInode(64, qtDir, 31), qtInode(32, qtDir, 99), qtInode(0, qtFile)}
	dirs := map[uint32][]byte{31: qtCat(qtDirent(2, "b"), qtDirent(3, "c"))}
	q := qtTree(inodes, dirs)
	got, err := qtWalk(t, qtParse(t, q))
	if err == nil || !strings.Contains(err.Error(), "directory data truncated") {
		t.Errorf("walk = %v, %v; want a truncated-directory failure", got, err)
	}
	if !reflect.DeepEqual(got, []string{"/b"}) {
		t.Errorf("entries before the failure = %v, want [/b]", got)
	}
}

// ---------------------------------------------------------------- writeThenClose

type qtFakeFile struct {
	writeErr, closeErr error
	closed             int
}

func (f *qtFakeFile) Write(p []byte) (int, error) { return len(p), f.writeErr }
func (f *qtFakeFile) Close() error                { f.closed++; return f.closeErr }

func TestQNXTeethWriteThenClose(t *testing.T) {
	werr, cerr := errors.New("write failed"), errors.New("close failed")
	for name, tc := range map[string]struct {
		w, c, want error
	}{
		"ok":                {nil, nil, nil},
		"write fails":       {werr, nil, werr},
		"close fails":       {nil, cerr, cerr},
		"write wins":        {werr, cerr, werr},
		"close not skipped": {nil, nil, nil},
	} {
		f := &qtFakeFile{writeErr: tc.w, closeErr: tc.c}
		if err := writeThenClose(f, []byte("x")); err != tc.want {
			t.Errorf("%s: err = %v, want %v", name, err, tc.want)
		}
		if f.closed != 1 {
			t.Errorf("%s: closed %d times, want once", name, f.closed)
		}
	}
}
