package formats

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"math/bits"
	"os"
	"sort"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// Port of toolbelt/qnx6_read.py (kit issue #2417, epic #2270): a read-only QNX6 Power-Safe filesystem reader.
// `list` enumerates the tree into key-sorted JSON evidence (qnx6-evidence.v1); `extract` copies one file out.
//
// Exit codes (unchanged): list 0 complete, 1 parse or walk error (a status:failed document is written),
// 2 I/O error (no document); extract 0 ok, 1 parse error or path not found, 2 I/O error.
//
// Differences from the Python script, all in the direction of a typed failure instead of a crash:
//   - A pathological block position (>= 2**63, where Python's lseek raises an uncaught OverflowError) is a
//     parse error, so `list` writes a failed document instead of a traceback with no evidence.
//   - `extract` reports a parse error found while resolving the path or reading the file ("qnx6-read: parse
//     error: ...", exit 1, no output file) where the script died with a traceback (also exit 1).
//   - Usage errors print the Go flag package's message, not argparse's; the exit code (2) is the same.

const (
	qnxSchema           = "qnx6-evidence.v1"
	qnxSuperblockOffset = 0x2000 // the superblock is always at partition_offset + 0x2000
	qnxMagic            = 0x68191122
	qnxInodeSize        = 128
	qnxDirentSize       = 32
	qnxLongnameSentinel = 0xFF
	qnxMaxDepth         = 40
	qnxNoBlock          = 0xFFFFFFFF
)

// qnxParseError is a parse-level failure: Python's _QNX6Error and the struct.error an unpack of a short
// buffer raises. Both are reported the same way.
type qnxParseError struct{ msg string }

func (e *qnxParseError) Error() string { return e.msg }

// qnxIOError is an OSError raised by a seek or read (it has no file name).
type qnxIOError struct{ en syscall.Errno }

func (e *qnxIOError) Error() string { return osErrorText(e.en, "") }

func parseErrf(format string, a ...any) error { return &qnxParseError{fmt.Sprintf(format, a...)} }

// rootNode is a (size, pointers, levels) block-tree root.
type rootNode struct {
	size   uint64
	ptrs   [16]uint32
	levels int
}

type qnxInode struct {
	size   uint64
	mode   uint16
	ptrs   [16]uint32
	levels int
}

type qnxEntry struct {
	name string
	ino  uint32
}

type qnxReader struct {
	f         *os.File
	poff      int64
	bs        uint64
	off       uint64 // block offset, auto-detected
	inodeRN   rootNode
	longRN    rootNode
	inodeTab  []byte
	longfile  []byte
	blockSize uint32
	numInodes uint32
	numBlocks uint32
}

func newQNXReader(f *os.File, poff int64) *qnxReader { return &qnxReader{f: f, poff: poff, bs: 512} }

// readAt is os.lseek(pos) followed by os.read(n): a position before the file start is EINVAL, and a read never
// returns more bytes than the file holds, so a huge n is clamped to what exists instead of being allocated.
func (r *qnxReader) readAt(pos int64, n uint64) ([]byte, error) {
	if pos < 0 {
		return nil, &qnxIOError{syscall.EINVAL}
	}
	if n > 1<<20 {
		st, err := r.f.Stat()
		if err != nil {
			return nil, ioErrOf(err)
		}
		avail := uint64(0)
		if st.Size() > pos {
			avail = uint64(st.Size() - pos)
		}
		n = min(n, avail)
	}
	// lseek then read, as the script does: a position the kernel refuses to seek to is an OSError (EINVAL),
	// where a bare pread would just report end of file.
	if _, err := r.f.Seek(pos, io.SeekStart); err != nil {
		return nil, ioErrOf(err)
	}
	buf := make([]byte, n)
	got, err := io.ReadFull(r.f, buf)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return nil, ioErrOf(err)
	}
	return buf[:got], nil
}

func ioErrOf(err error) error {
	if en, ok := errnoOf(err); ok {
		return &qnxIOError{en}
	}
	return &qnxIOError{syscall.EIO}
}

// blockPos is poff + (blk + off) * bs, refusing a position Python could not seek to (>= 2**63).
func (r *qnxReader) blockPos(blk uint32) (int64, error) {
	hi, lo := bits.Mul64(uint64(blk)+r.off, r.bs)
	if hi != 0 || lo > math.MaxInt64 {
		return 0, parseErrf("block %d position is out of range", blk)
	}
	pos := int64(lo)
	if r.poff > 0 && pos > math.MaxInt64-r.poff {
		return 0, parseErrf("block %d position is out of range", blk)
	}
	return r.poff + pos, nil
}

func (r *qnxReader) rawblk(blk uint32) ([]byte, error) {
	pos, err := r.blockPos(blk)
	if err != nil {
		return nil, err
	}
	return r.readAt(pos, r.bs)
}

// eachLeaf is _leaf_blks: it calls fn for every leaf block number of the tree, depth first, skipping unused
// pointers. fn returns true to stop; eachLeaf then returns true. The first error ends the walk.
func (r *qnxReader) eachLeaf(ptrs []uint32, levels int, fn func(blk uint32) (stop bool, err error)) (bool, error) {
	for _, p := range ptrs {
		if p == qnxNoBlock {
			continue
		}
		if levels == 0 {
			if stop, err := fn(p); stop || err != nil {
				return stop, err
			}
			continue
		}
		raw, err := r.rawblk(p)
		if err != nil {
			return false, err
		}
		n := int(r.bs / 4)
		if len(raw) < 4*n {
			return false, parseErrf("unpack_from requires a buffer of at least %d bytes for unpacking %d bytes at offset 0 (actual buffer size is %d)", 4*n, 4*n, len(raw))
		}
		sub := make([]uint32, n)
		for i := range sub {
			sub[i] = binary.LittleEndian.Uint32(raw[4*i:])
		}
		if stop, err := r.eachLeaf(sub, levels-1, fn); stop || err != nil {
			return stop, err
		}
	}
	return false, nil
}

func parseRN(sb []byte, off int) rootNode {
	rn := rootNode{size: binary.LittleEndian.Uint64(sb[off:]), levels: int(sb[off+72])}
	for i := range rn.ptrs {
		rn.ptrs[i] = binary.LittleEndian.Uint32(sb[off+8+4*i:])
	}
	return rn
}

// parse reads the superblock and loads the index tables.
func (r *qnxReader) parse() error {
	if r.poff > math.MaxInt64-qnxSuperblockOffset {
		return parseErrf("partition offset is out of range")
	}
	sb, err := r.readAt(r.poff+qnxSuperblockOffset, 0x1000)
	if err != nil {
		return err
	}
	if len(sb) < 0x131 {
		return parseErrf("image too small to contain a QNX6 superblock")
	}
	if magic := binary.LittleEndian.Uint32(sb); magic != qnxMagic {
		return parseErrf("bad magic 0x%08x (expected 0x%08x); not a QNX6 Power-Safe image", magic, uint32(qnxMagic))
	}
	bs := binary.LittleEndian.Uint32(sb[48:])
	r.numInodes = binary.LittleEndian.Uint32(sb[52:])
	r.numBlocks = binary.LittleEndian.Uint32(sb[60:])
	if bs < 512 {
		return parseErrf("invalid block size %d in superblock", bs)
	}
	r.bs, r.blockSize = uint64(bs), bs
	r.inodeRN, r.longRN = parseRN(sb, 72), parseRN(sb, 232)
	if r.off, err = r.detectOff(); err != nil {
		return err
	}
	if r.inodeTab, err = r.readRNFile(r.inodeRN); err != nil {
		return err
	}
	r.longfile, err = r.readRNFile(r.longRN)
	return err
}

// detectOff tries candidate block offsets until the root inode looks like a directory. Only the first leaf of
// the inode table is inspected per candidate, and a seek/read OSError just moves on to the next candidate.
func (r *qnxReader) detectOff() (uint64, error) {
	rn := r.inodeRN
	if rn.size == 0 {
		return 0, nil
	}
	saved := r.off
	for cand := uint64(0); cand < 40; cand++ {
		r.off = cand
		found := false
		_, err := r.eachLeaf(rn.ptrs[:], rn.levels, func(blk uint32) (bool, error) {
			raw, err := r.rawblk(blk)
			if err != nil {
				return true, err
			}
			if len(raw) >= 34 {
				diSize := binary.LittleEndian.Uint64(raw)
				diMode := binary.LittleEndian.Uint16(raw[32:])
				if diMode&0xF000 == 0x4000 && diSize > 0 && diSize < 50_000_000 {
					found = true
				}
			}
			return true, nil // only the first leaf is looked at
		})
		var ioe *qnxIOError
		switch {
		case errors.As(err, &ioe):
			continue
		case err != nil:
			return 0, err
		case found:
			return cand, nil
		}
	}
	r.off = saved
	return 0, parseErrf("cannot locate block offset; image may be corrupt or use an unsupported layout")
}

// readRNFile reads a block-tree file. The read is capped at the real size of the image (from the partition
// start), so a crafted superblock with an inflated size or block count cannot drive an unbounded read.
func (r *qnxReader) readRNFile(rn rootNode) ([]byte, error) {
	if rn.size == 0 {
		return []byte{}, nil
	}
	limit := rn.size
	if st, err := r.f.Stat(); err == nil {
		real := uint64(0)
		switch {
		case r.poff >= 0 && st.Size() > r.poff:
			real = uint64(st.Size() - r.poff)
		case r.poff < 0:
			real = uint64(st.Size()) + uint64(-(r.poff + 1)) + 1 // saturating enough: only the min below matters
		}
		if real > 0 {
			limit = min(rn.size, real)
		}
	}
	buf := []byte{}
	_, err := r.eachLeaf(rn.ptrs[:], rn.levels, func(blk uint32) (bool, error) {
		raw, err := r.rawblk(blk)
		if err != nil {
			return true, err
		}
		buf = append(buf, raw...)
		return uint64(len(buf)) >= limit, nil
	})
	if err != nil {
		return nil, err
	}
	if uint64(len(buf)) > rn.size {
		buf = buf[:rn.size]
	}
	return buf, nil
}

func (r *qnxReader) inode(ino uint32) (qnxInode, error) {
	if ino == 0 {
		return qnxInode{}, parseErrf("inode %d out of range", ino)
	}
	off := (uint64(ino) - 1) * qnxInodeSize
	if off+qnxInodeSize > uint64(len(r.inodeTab)) {
		return qnxInode{}, parseErrf("inode %d out of range", ino)
	}
	e := r.inodeTab[off : off+qnxInodeSize]
	n := qnxInode{
		size: binary.LittleEndian.Uint64(e), mode: binary.LittleEndian.Uint16(e[32:]), levels: int(e[100]),
	}
	for i := range n.ptrs {
		n.ptrs[i] = binary.LittleEndian.Uint32(e[36+4*i:])
	}
	return n, nil
}

// latin1 decodes bytes as latin-1 (every byte is its own code point).
func latin1(b []byte) string {
	rs := make([]rune, len(b))
	for i, c := range b {
		rs[i] = rune(c)
	}
	return string(rs)
}

func (r *qnxReader) longname(idx uint32) (string, error) {
	off := uint64(idx) * r.bs
	if off+2 > uint64(len(r.longfile)) {
		return "", parseErrf("longname index %d out of range", idx)
	}
	ln := uint64(binary.LittleEndian.Uint16(r.longfile[off:]))
	end := min(off+2+ln, uint64(len(r.longfile)))
	return latin1(r.longfile[off+2 : end]), nil
}

func (r *qnxReader) listdir(ino uint32) ([]qnxEntry, error) {
	node, err := r.inode(ino)
	if err != nil {
		return nil, err
	}
	data, err := r.readRNFile(rootNode{node.size, node.ptrs, node.levels})
	if err != nil {
		return nil, err
	}
	// A short read is a parse error, never an empty directory (anti-silent-zero).
	if node.size > 0 && uint64(len(data)) < node.size {
		return nil, parseErrf("directory data truncated: inode %d declared %d bytes but only %d were readable (image truncated or block past EOF)", ino, node.size, len(data))
	}
	var entries []qnxEntry
	for o := 0; o+qnxDirentSize <= len(data); o += qnxDirentSize {
		e := data[o : o+qnxDirentSize]
		deIno := binary.LittleEndian.Uint32(e)
		if deIno == 0 {
			continue
		}
		var name string
		if sz := int(e[4]); sz == qnxLongnameSentinel {
			if name, err = r.longname(binary.LittleEndian.Uint32(e[8:])); err != nil {
				return nil, err
			}
		} else {
			name = latin1(e[5:min(5+sz, qnxDirentSize)])
		}
		if name == "." || name == ".." {
			continue
		}
		entries = append(entries, qnxEntry{name, deIno})
	}
	return entries, nil
}

type walkEntry struct {
	path  string
	mode  uint16
	size  uint64
	isDir bool
}

// walk visits every entry reachable from ino. visited holds the inodes already descended into (a repeated one
// is not entered again, which stops cyclic directories); truncated is set when the depth cap fires. emit is
// called before descending, so a failure leaves the entries seen so far with the caller.
func (r *qnxReader) walk(ino uint32, base string, depth int, visited map[uint32]bool, truncated *bool, emit func(walkEntry)) error {
	if depth > qnxMaxDepth {
		*truncated = true
		return nil
	}
	if visited[ino] {
		return nil
	}
	visited[ino] = true
	entries, err := r.listdir(ino)
	if err != nil {
		return err
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].name != entries[j].name {
			return entries[i].name < entries[j].name
		}
		return entries[i].ino < entries[j].ino
	})
	for _, e := range entries {
		path := base + "/" + e.name
		node, err := r.inode(e.ino)
		if err != nil {
			return err
		}
		isDir := node.mode&0xF000 == 0x4000
		emit(walkEntry{path, node.mode, node.size, isDir})
		if isDir {
			if err := r.walk(e.ino, path, depth+1, visited, truncated, emit); err != nil {
				return err
			}
		}
	}
	return nil
}

// resolve finds fsPath from the root; ok is false when a component is missing.
func (r *qnxReader) resolve(fsPath string) (ino uint32, node qnxInode, ok bool, err error) {
	ino = 1
	for _, part := range splitNonEmpty(fsPath, '/') {
		entries, err := r.listdir(ino)
		if err != nil {
			return 0, qnxInode{}, false, err
		}
		found := false
		for _, e := range entries {
			if e.name == part {
				ino, found = e.ino, true
				break
			}
		}
		if !found {
			return 0, qnxInode{}, false, nil
		}
	}
	node, err = r.inode(ino)
	return ino, node, err == nil, err
}

func splitNonEmpty(s string, sep byte) []string {
	var out []string
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == sep {
			if i > start {
				out = append(out, s[start:i])
			}
			start = i + 1
		}
	}
	return out
}

// ---------------------------------------------------------------- I/O and command

// qnxOpen opens the image read-only, refusing symlinks and non-regular files (no blocking on a FIFO).
// A refusal is returned as the text after "qnx6-read: <path>: ".
func qnxOpen(path string) (*os.File, string) {
	fd, _, err := fsx.OpenRO(path)
	if err != nil {
		switch {
		case errors.Is(err, fsx.ErrNotRegular):
			return nil, "not a regular file (rejected)"
		case errors.Is(err, syscall.ELOOP):
			return nil, "is a symbolic link (rejected)"
		}
		if en, ok := errnoOf(err); ok {
			return nil, strerror(en)
		}
		return nil, err.Error()
	}
	return os.NewFile(uintptr(fd), path), ""
}

// writeNew creates path exclusively (never through a symlink, never over an existing file) and writes data.
func writeNew(path string, data []byte) error {
	fd, err := fsx.OpenWONew(path)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(fd), path)
	_, werr := f.Write(data)
	cerr := f.Close()
	if werr != nil {
		return werr
	}
	return cerr
}

// ioFailure turns an I/O error into the "I/O error: ..." text of the Python OSError handler.
func ioFailure(err error) string {
	var qe *qnxIOError
	var pe *os.PathError
	switch {
	case errors.As(err, &qe):
		return qe.Error()
	case errors.As(err, &pe):
		if en, ok := errnoOf(pe.Err); ok {
			return osErrorText(en, pe.Path)
		}
	}
	if en, ok := errnoOf(err); ok {
		return osErrorText(en, "")
	}
	return err.Error()
}

const qnx6Usage = `usage: qnx6-read {list,extract} ...

Read-only QNX6 Power-Safe filesystem reader.

  list     --input IMAGE [--partition-offset BYTES] --output JSON
           enumerate the filesystem tree to JSON evidence
  extract  --input IMAGE --fs-path PATH [--partition-offset BYTES] --output FILE
           extract a single file from the filesystem
`

// QNX6Read is `rsdd formats qnx6-read`.
func QNX6Read(args []string, s cli.Stdio) int {
	a, code, done := parseQNX6Args(args, s)
	if done {
		return code
	}
	fd := (*os.File)(nil)
	fail := func(code int, format string, v ...any) int {
		fmt.Fprintf(s.Err, "qnx6-read: "+format+"\n", v...)
		return code
	}
	input := pyPathJoin(s.Cwd, a.input)
	output := pyPathJoin(s.Cwd, a.output)
	fd, why := qnxOpen(input)
	if fd == nil {
		return fail(2, "%s: %s", a.input, why)
	}
	defer fd.Close()
	if a.cmd == "list" {
		return qnxList(fd, a, output, s)
	}
	return qnxExtract(fd, a, output, s)
}

type qnx6Args struct {
	cmd, input, output, fsPath string
	poff                       int64
}

func qnxList(f *os.File, a qnx6Args, output string, s cli.Stdio) int {
	st, err := f.Stat()
	if err != nil {
		fmt.Fprintf(s.Err, "qnx6-read: I/O error: %s\n", ioFailure(ioErrOf(err)))
		return 2
	}
	sum, err := fsx.SHA256FD(int(f.Fd()))
	if err != nil {
		fmt.Fprintf(s.Err, "qnx6-read: I/O error: %s\n", ioFailure(ioErrOf(err)))
		return 2
	}
	rdr := newQNXReader(f, a.poff)
	var errs []string
	if err := rdr.parse(); err != nil {
		var ioe *qnxIOError
		if errors.As(err, &ioe) {
			fmt.Fprintf(s.Err, "qnx6-read: I/O error: %s\n", ioe)
			return 2
		}
		errs = append(errs, err.Error())
	}
	entries := []any{}
	dirs, files := 0, 0
	truncated := false
	if len(errs) == 0 {
		err := rdr.walk(1, "", 0, map[uint32]bool{}, &truncated, func(e walkEntry) {
			typ := "file"
			if e.isDir {
				typ = "dir"
				dirs++
			} else {
				files++
			}
			entries = append(entries, map[string]any{"mode": int(e.mode), "path": e.path, "size_bytes": e.size, "type": typ})
		})
		if err != nil {
			var ioe *qnxIOError
			if errors.As(err, &ioe) {
				fmt.Fprintf(s.Err, "qnx6-read: I/O error: %s\n", ioe)
				return 2
			}
			errs = append(errs, "walk error: "+err.Error())
		}
	}
	fsInfo := map[string]any{"filesystem_type": "QNX6 Power-Safe", "block_size": nil, "num_blocks": nil, "num_inodes": nil}
	status := "complete"
	if len(errs) == 0 {
		fsInfo["block_size"], fsInfo["num_blocks"], fsInfo["num_inodes"] = rdr.blockSize, rdr.numBlocks, rdr.numInodes
	} else {
		status = "failed"
	}
	errList := []any{}
	for _, e := range errs {
		errList = append(errList, e)
	}
	result := map[string]any{
		"entries":    entries,
		"errors":     errList,
		"filesystem": fsInfo,
		"input":      map[string]any{"partition_offset": a.poff, "sha256": sum, "size_bytes": st.Size()},
		"limitations": []any{
			"Directory tree enumerated recursively up to depth 40.",
			"Filenames decoded as latin-1 with replacement on error.",
		},
		"schema":    qnxSchema,
		"status":    status,
		"summary":   map[string]any{"dirs": dirs, "files": files, "total_entries": dirs + files},
		"truncated": truncated,
	}
	body, err := jsonout.Indented(result)
	if err != nil {
		fmt.Fprintf(s.Err, "qnx6-read: I/O error: %v\n", err)
		return 2
	}
	if err := writeNew(output, body); err != nil {
		fmt.Fprintf(s.Err, "qnx6-read: I/O error: %s\n", ioFailure(err))
		return 2
	}
	if len(errs) > 0 {
		return 1
	}
	return 0
}

func qnxExtract(f *os.File, a qnx6Args, output string, s cli.Stdio) int {
	rdr := newQNXReader(f, a.poff)
	parseFail := func(err error) int {
		var ioe *qnxIOError
		if errors.As(err, &ioe) {
			fmt.Fprintf(s.Err, "qnx6-read: I/O error: %s\n", ioe)
			return 2
		}
		fmt.Fprintf(s.Err, "qnx6-read: parse error: %s\n", err)
		return 1
	}
	if err := rdr.parse(); err != nil {
		return parseFail(err)
	}
	_, node, ok, err := rdr.resolve(a.fsPath)
	if err != nil {
		return parseFail(err)
	}
	if !ok {
		fmt.Fprintf(s.Err, "qnx6-read: %s: path not found in image\n", a.fsPath)
		return 1
	}
	data, err := rdr.readRNFile(rootNode{node.size, node.ptrs, node.levels})
	if err != nil {
		return parseFail(err)
	}
	if err := writeNew(output, data); err != nil {
		fmt.Fprintf(s.Err, "qnx6-read: I/O error: %s\n", ioFailure(err))
		return 2
	}
	return 0
}
