//go:build unix

package formats

// Mutation-killing tests for squashfs.go and squashfs_unix.go (kit issues #2561, #2592). Teeth runs with
// -tags nodiff, so none of these depend on the legacy-script oracle; they call the package's functions
// directly with no external tool (no bwrap, unsquashfs or Python). Every case names the mutation it pins.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// ---------------------------------------------------------------- superblock

// sqSB is the set of superblock fields sqfsValidSuperblock reads.
type sqSB struct {
	inodes, block, fragments        uint32
	comp, log, flags, ids, maj, min uint16
	used                            uint64
	id, xattr, inode, dir, frag, ex uint64
}

func sqValid() sqSB {
	return sqSB{inodes: 1, block: 131072, log: 17, comp: 1, ids: 1, maj: 4, used: 200,
		id: 100, xattr: sqfsNoTable, inode: 100, dir: 100, frag: sqfsNoTable, ex: sqfsNoTable}
}

func (s sqSB) bytes() []byte {
	b := make([]byte, sqfsSBSize)
	copy(b, sqfsMagic)
	le := binary.LittleEndian
	le.PutUint32(b[4:], s.inodes)
	le.PutUint32(b[12:], s.block)
	le.PutUint32(b[16:], s.fragments)
	le.PutUint16(b[20:], s.comp)
	le.PutUint16(b[22:], s.log)
	le.PutUint16(b[24:], s.flags)
	le.PutUint16(b[26:], s.ids)
	le.PutUint16(b[28:], s.maj)
	le.PutUint16(b[30:], s.min)
	le.PutUint64(b[40:], s.used)
	for i, v := range []uint64{s.id, s.xattr, s.inode, s.dir, s.frag, s.ex} {
		le.PutUint64(b[48+8*i:], v)
	}
	return b
}

// valid judges the superblock as the whole file (offset 0, size == used).
func (s sqSB) valid() bool { return sqfsValidSuperblock(s.bytes(), 0, int64(s.used)) }

func TestSquashfsTeethSuperblockBase(t *testing.T) {
	if !sqValid().valid() {
		t.Fatal("the baseline superblock is refused")
	}
}

func TestSquashfsTeethTableBounds(t *testing.T) {
	// Every table must lie in [96, used) or be absent. Pins both comparisons of validTable.
	setters := map[string]func(*sqSB, uint64){
		"id": func(s *sqSB, v uint64) { s.id = v }, "xattr": func(s *sqSB, v uint64) { s.xattr = v },
		"inode": func(s *sqSB, v uint64) { s.inode = v }, "dir": func(s *sqSB, v uint64) { s.dir = v },
		"frag": func(s *sqSB, v uint64) { s.frag = v }, "export": func(s *sqSB, v uint64) { s.ex = v },
	}
	for name, set := range setters {
		for _, tc := range []struct {
			v  uint64
			ok bool
		}{{sqfsSBSize - 1, false}, {sqfsSBSize, true}, {199, true}, {200, false}, {sqfsNoTable - 1, false}} {
			s := sqValid()
			set(&s, tc.v)
			if got := s.valid(); got != tc.ok {
				t.Errorf("%s table = %d: valid = %v, want %v", name, tc.v, got, tc.ok)
			}
		}
	}
}

func TestSquashfsTeethRequiredTables(t *testing.T) {
	for name, set := range map[string]func(*sqSB){
		"id": func(s *sqSB) { s.id = sqfsNoTable }, "inode": func(s *sqSB) { s.inode = sqfsNoTable },
		"dir":                   func(s *sqSB) { s.dir = sqfsNoTable },
		"frag (fragments != 0)": func(s *sqSB) { s.fragments = 1 },
		"export (flag set)":     func(s *sqSB) { s.flags = sqfsFlagExportable },
	} {
		s := sqValid()
		set(&s)
		if s.valid() {
			t.Errorf("%s absent but accepted", name)
		}
	}
	s := sqValid() // optional tables may be absent; the fragment and export tables count only when announced
	s.fragments, s.frag, s.flags, s.ex = 1, 150, sqfsFlagExportable, 150
	if !s.valid() {
		t.Error("announced fragment and export tables refused")
	}
}

func TestSquashfsTeethCompressionAndBlockBounds(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  func(*sqSB)
		ok   bool
	}{
		{"compression 0", func(s *sqSB) { s.comp = 0 }, false},
		{"compression 1", func(s *sqSB) { s.comp = 1 }, true},
		{"compression 6", func(s *sqSB) { s.comp = 6 }, true},
		{"compression 7", func(s *sqSB) { s.comp = 7 }, false},
		{"block 4096", func(s *sqSB) { s.log, s.block = 12, 4096 }, true},
		{"block 2048", func(s *sqSB) { s.log, s.block = 11, 2048 }, false},
		{"block 1 MiB", func(s *sqSB) { s.log, s.block = 20, 1<<20 }, true},
		{"block 2 MiB", func(s *sqSB) { s.log, s.block = 21, 1<<21 }, false},
		{"block 2 GiB", func(s *sqSB) { s.log, s.block = 31, 1<<31 }, false},
		{"log 32, block 0", func(s *sqSB) { s.log, s.block = 32, 0 }, false},
		{"log 64, block 0", func(s *sqSB) { s.log, s.block = 64, 0 }, false},
		{"block not 1<<log", func(s *sqSB) { s.log, s.block = 17, 131073 }, false},
		{"no inodes", func(s *sqSB) { s.inodes = 0 }, false},
		{"no ids", func(s *sqSB) { s.ids = 0 }, false},
		{"major 3", func(s *sqSB) { s.maj = 3 }, false},
		{"minor 1", func(s *sqSB) { s.min = 1 }, false},
	} {
		s := sqValid()
		tc.set(&s)
		if got := s.valid(); got != tc.ok {
			t.Errorf("%s: valid = %v, want %v", tc.name, got, tc.ok)
		}
	}
}

func TestSquashfsTeethUsedBounds(t *testing.T) {
	// offset + used <= size: exact fit is valid, one byte short is not, at a nonzero offset too (pins `used >
	// size-offset` and the subtraction).
	sb := sqValid().bytes()
	for _, off := range []int64{0, 10, 4096} {
		if !sqfsValidSuperblock(sb, off, off+200) {
			t.Errorf("offset %d: exact fit refused", off)
		}
		if sqfsValidSuperblock(sb, off, off+199) {
			t.Errorf("offset %d: used past the end accepted", off)
		}
	}
	// A tiny used value is refused whatever the tables say.
	for _, used := range []uint64{0, 1, sqfsSBSize - 1, sqfsSBSize} {
		s := sqValid()
		s.used, s.id, s.inode, s.dir = used, sqfsSBSize, sqfsSBSize, sqfsSBSize
		if s.valid() {
			t.Errorf("used = %d accepted", used)
		}
	}
	s := sqValid()
	s.used, s.id, s.inode, s.dir = sqfsSBSize+1, sqfsSBSize, sqfsSBSize, sqfsSBSize
	if !s.valid() {
		t.Error("used = 97 with tables at 96 refused")
	}
}

// ---------------------------------------------------------------- findSquashfsOffset

// sqImage is n zero bytes with the baseline superblock at each given offset.
func sqImage(n int, at ...int) []byte {
	img := make([]byte, n)
	for _, o := range at {
		copy(img[o:], sqValid().bytes())
	}
	return img
}

func TestSquashfsTeethFindOffsetNotFound(t *testing.T) {
	off, err := findSquashfsOffset(bytes.NewReader(make([]byte, 4096)), 4096)
	var se *sqfsError
	if off != -1 || !errors.As(err, &se) || se.msg != sqfsNoSuperblock {
		t.Errorf("empty scan = %d, %v; want -1 and %q", off, err, sqfsNoSuperblock)
	}
}

type failingReaderAt struct{ err error }

func (r failingReaderAt) ReadAt([]byte, int64) (int, error) { return 0, r.err }

func TestSquashfsTeethFindOffsetReportsAReadError(t *testing.T) {
	boom := errors.New("disk on fire")
	if off, err := findSquashfsOffset(failingReaderAt{boom}, 4096); off != -1 || !errors.Is(err, boom) {
		t.Errorf("read failure = %d, %v; want -1 and the read error", off, err)
	}
}

func TestSquashfsTeethFindOffsetAcrossChunks(t *testing.T) {
	const chunk = sqfsScanChunk
	for _, at := range []int{0, 7, chunk - 4, chunk - 3, chunk - 2, chunk - 1, chunk, chunk + 1} {
		img := sqImage(chunk+512, at)
		if off, err := findSquashfsOffset(bytes.NewReader(img), int64(len(img))); err != nil || off != int64(at) {
			t.Errorf("superblock at %d: found %d, %v", at, off, err)
		}
	}
	// A failed candidate before the chunk end does not hide a valid one after it.
	img := sqImage(chunk+512, chunk+8)
	copy(img[chunk-100:], sqfsMagic)
	if off, err := findSquashfsOffset(bytes.NewReader(img), int64(len(img))); err != nil || off != chunk+8 {
		t.Errorf("after a bad candidate: %d, %v", off, err)
	}
}

// strictReaderAt fails the test on a read that starts at or past the end of the data.
type strictReaderAt struct {
	t    *testing.T
	data []byte
}

func (r strictReaderAt) ReadAt(p []byte, off int64) (int, error) {
	if off >= int64(len(r.data)) {
		r.t.Errorf("ReadAt(%d bytes at %d) past the end of %d bytes", len(p), off, len(r.data))
		return 0, io.EOF
	}
	n := copy(p, r.data[off:])
	if n < len(p) {
		return n, io.EOF
	}
	return n, nil
}

func TestSquashfsTeethFindOffsetNeverReadsPastTheEnd(t *testing.T) {
	// Exactly one chunk, and a magic near the end that cannot hold a superblock.
	img := make([]byte, sqfsScanChunk)
	copy(img[len(img)-50:], sqfsMagic)
	if off, err := findSquashfsOffset(strictReaderAt{t, img}, int64(len(img))); err == nil {
		t.Errorf("accepted a truncated superblock at %d", off)
	}
	// A superblock that ends exactly at the end of the data is read whole (here it is invalid: used > 96).
	tail := sqImage(96, 0)
	if _, err := findSquashfsOffset(strictReaderAt{t, tail}, 96); err == nil {
		t.Error("a bare 96-byte superblock was accepted")
	}
	// A valid superblock whose image ends exactly at its `used` size.
	exact := sqImage(200, 0)
	if off, err := findSquashfsOffset(strictReaderAt{t, exact}, 200); err != nil || off != 0 {
		t.Errorf("exact-fit image = %d, %v", off, err)
	}
}

// ---------------------------------------------------------------- tree entries and hashing

func TestSquashfsTeethTreeEntryMap(t *testing.T) {
	file := treeEntry{Path: "a/b", Type: "file", Mode: 0o644, Size: 3, SHA256: "sha256:ff"}
	if got, want := file.toMap(), map[string]any{"path": "a/b", "type": "file", "mode": 0o644, "size": int64(3), "sha256": "sha256:ff"}; !reflect.DeepEqual(got, want) {
		t.Errorf("file map = %v, want %v", got, want)
	}
	dir := treeEntry{Path: "a", Type: "directory", Mode: 0o755, Size: 9, SHA256: "ignored"}
	if got, want := dir.toMap(), map[string]any{"path": "a", "type": "directory", "mode": 0o755}; !reflect.DeepEqual(got, want) {
		t.Errorf("directory map = %v, want %v", got, want)
	}
}

func TestSquashfsTeethWalkTreeSortsByPath(t *testing.T) {
	root := t.TempDir()
	for _, p := range []string{"z", "b/y", "b/x", "a"} {
		full := filepath.Join(root, p)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(p), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	entries, err := walkTree(root, 100, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, e := range entries {
		got = append(got, e.Path)
	}
	if want := []string{"a", "b", "b/x", "b/y", "z"}; !reflect.DeepEqual(got, want) {
		t.Errorf("paths = %v, want %v", got, want)
	}
}

func TestSquashfsTeethHashHookRunsOncePerHashedChunk(t *testing.T) {
	dir := t.TempDir()
	empty, small := filepath.Join(dir, "empty"), filepath.Join(dir, "small")
	if err := os.WriteFile(empty, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(small, []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	var calls int
	hashHook = func() { calls++ }
	t.Cleanup(func() { hashHook = nil })
	// The end-of-file read returns no data and is not a hashed chunk.
	for name, tc := range map[string]struct {
		path  string
		calls int
	}{"empty file": {empty, 0}, "one chunk": {small, 1}} {
		calls = 0
		if _, err := hashNoFollow(tc.path, name); err != nil {
			t.Fatal(err)
		}
		if calls != tc.calls {
			t.Errorf("%s: hook ran %d times, want %d", name, calls, tc.calls)
		}
	}
}

func TestSquashfsTeethTreeBytesAndCap(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "d"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"a", "b"} {
		if err := os.WriteFile(filepath.Join(root, f), []byte("12345"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// With the limit at 5 the first file brings the total to exactly 5, which is not over: the second is
	// still counted (pins `total > over`).
	if got := treeBytes(root, 5); got != 10 {
		t.Errorf("treeBytes(limit 5) = %d, want 10", got)
	}
	if got := treeBytes(root, 100); got != 10 {
		t.Errorf("treeBytes(limit 100) = %d, want 10", got)
	}
	// Exactly the cap is inside it; one byte more is over (pins the watchdog comparison).
	if overCap(root, 10) {
		t.Error("a tree of exactly the cap is over it")
	}
	if !overCap(root, 9) {
		t.Error("a tree one byte over the cap is not over it")
	}
	if overCap(filepath.Join(root, "missing"), 0) {
		t.Error("a missing tree counts as over the cap")
	}
}

// ---------------------------------------------------------------- mountinfo

func TestSquashfsTeethRequirePrivateFieldCount(t *testing.T) {
	// Five fields before " - " is the minimum (pins `len(lf) < 5`).
	if err := requirePrivate("/mnt/x", "36 35 0:30 / /mnt - tmpfs tmpfs rw\n"); err != nil {
		t.Errorf("five-field line refused: %v", err)
	}
	err := requirePrivate("/mnt/x", "36 35 0:30 / - tmpfs tmpfs rw\n")
	if err == nil || !strings.HasPrefix(err.Error(), "malformed mountinfo line (too few left fields)") {
		t.Errorf("four-field line = %v", err)
	}
}

func TestSquashfsTeethRequirePrivateTieGoesToTheFirstMount(t *testing.T) {
	both := "1 0 0:1 / /mnt - tmpfs tmpfs rw\n2 0 0:2 / /mnt - nfs srv:/x rw\n"
	if err := requirePrivate("/mnt/x", both); err != nil {
		t.Errorf("first mount (tmpfs) should win the tie: %v", err)
	}
	swapped := "2 0 0:2 / /mnt - nfs srv:/x rw\n1 0 0:1 / /mnt - tmpfs tmpfs rw\n"
	if err := requirePrivate("/mnt/x", swapped); err == nil || err.Error() != "output must reside on a Linux-private filesystem" {
		t.Errorf("first mount (nfs) should win the tie: %v", err)
	}
	// A deeper mount beats a shallower one whatever the order.
	deeper := "1 0 0:1 / /mnt/x - nfs srv:/x rw\n2 0 0:2 / /mnt - tmpfs tmpfs rw\n"
	if err := requirePrivate("/mnt/x/y", deeper); err == nil {
		t.Error("the deeper nfs mount should decide")
	}
}

// ---------------------------------------------------------------- bwrap argv

func hasRun(argv []string, run ...string) bool {
	for i := 0; i+len(run) <= len(argv); i++ {
		if reflect.DeepEqual(argv[i:i+len(run)], run) {
			return true
		}
	}
	return false
}

func TestSquashfsTeethBwrapArgv(t *testing.T) {
	argv := bwrapArgv("/b/bwrap", "/u/unsquashfs", "/stage", 0)
	existing := 0
	for _, d := range []string{"/usr", "/bin", "/sbin", "/lib", "/lib64"} {
		_, err := os.Stat(d)
		if got := hasRun(argv, "--ro-bind", d, d); got != (err == nil) {
			t.Errorf("--ro-bind %s present = %v, but exists = %v", d, got, err == nil)
		}
		if err == nil {
			existing++
		}
	}
	if existing == 0 {
		t.Fatal("none of the standard directories exists on this host")
	}
	if !hasRun(argv, "--bind", "/stage", "/work") || argv[0] != "/b/bwrap" {
		t.Errorf("argv = %v", argv)
	}
	tail := []string{"/u/unsquashfs", "-no-progress", "-quiet", "-d", "/work/extracted", "/work/input.sqfs"}
	if !reflect.DeepEqual(argv[len(argv)-len(tail):], tail) {
		t.Errorf("tail = %v, want %v", argv[len(argv)-len(tail):], tail)
	}
	// -offset appears only for a positive offset, right before the input.
	if hasRun(argv, "-offset") || containsStr(argv, "-offset") {
		t.Errorf("offset 0 passed -offset: %v", argv)
	}
	withOff := bwrapArgv("/b/bwrap", "/u/unsquashfs", "/stage", 7)
	if tail := []string{"-d", "/work/extracted", "-offset", "7", "/work/input.sqfs"}; !reflect.DeepEqual(withOff[len(withOff)-len(tail):], tail) {
		t.Errorf("offset 7 argv tail = %v", withOff[len(withOff)-len(tail):])
	}
}

func containsStr(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------- small helpers

func TestSquashfsTeethIsoZ(t *testing.T) {
	base := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	for name, tc := range map[string]struct {
		ns   int
		want string
	}{
		"whole second":      {0, "2026-01-02T03:04:05Z"},
		"under a microsec":  {500, "2026-01-02T03:04:05Z"},
		"one microsecond":   {1000, "2026-01-02T03:04:05.000001Z"},
		"fraction":          {123456000, "2026-01-02T03:04:05.123456Z"},
		"sub-micro dropped": {1500, "2026-01-02T03:04:05.000001Z"},
	} {
		if got := isoZ(base.Add(time.Duration(tc.ns))); got != tc.want {
			t.Errorf("%s: %s, want %s", name, got, tc.want)
		}
	}
	if got := isoZ(time.Date(2026, 1, 2, 5, 4, 5, 0, time.FixedZone("x", 2*3600))); got != "2026-01-02T03:04:05Z" {
		t.Errorf("zone not converted to UTC: %s", got)
	}
}

func TestSquashfsTeethSnippet(t *testing.T) {
	if got := snippetOf([]byte("\n  hi \xff there  \n")); got != "hi � there" {
		t.Errorf("snippet = %q", got)
	}
	// A real U+FFFD in the input is one character, not three bytes of damage.
	if got := snippetOf([]byte("a�b")); got != "a�b" {
		t.Errorf("snippet of a real U+FFFD = %q", got)
	}
	// The cut is 512 characters, multi-byte ones included.
	got := snippetOf(bytes.Repeat([]byte("é"), 600))
	if n := len([]rune(got)); n != 512 {
		t.Errorf("snippet has %d characters, want 512", n)
	}
}

func TestSquashfsTeethStagedOffsetSizes(t *testing.T) {
	small := filepath.Join(t.TempDir(), "in")
	cases := map[int]string{
		sqfsSBSize - 1: "input too small for a SquashFS superblock",
		sqfsSBSize:     sqfsNoSuperblock, // 96 bytes are enough to be judged, and refused
	}
	for n, want := range cases {
		if err := os.WriteFile(small, make([]byte, n), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := stagedOffset(small)
		if err == nil || err.Error() != want {
			t.Errorf("%d bytes: err = %v, want %q", n, err, want)
		}
	}
}

// ---------------------------------------------------------------- file writers

type sqFakeFile struct {
	writeErr, syncErr, closeErr error
	synced, closed              int
}

func (f *sqFakeFile) Write(p []byte) (int, error) { return len(p), f.writeErr }
func (f *sqFakeFile) Sync() error                 { f.synced++; return f.syncErr }
func (f *sqFakeFile) Close() error                { f.closed++; return f.closeErr }

func TestSquashfsTeethWriteSyncClose(t *testing.T) {
	werr, serr, cerr := errors.New("write"), errors.New("sync"), errors.New("close")
	for name, tc := range map[string]struct {
		f      sqFakeFile
		want   error
		synced int
	}{
		"ok":               {sqFakeFile{}, nil, 1},
		"write fails":      {sqFakeFile{writeErr: werr}, werr, 0},
		"sync fails":       {sqFakeFile{syncErr: serr}, serr, 1},
		"close fails":      {sqFakeFile{closeErr: cerr}, cerr, 1},
		"sync beats close": {sqFakeFile{syncErr: serr, closeErr: cerr}, serr, 1},
	} {
		f := tc.f
		if err := writeSyncClose(&f, []byte("x")); err != tc.want {
			t.Errorf("%s: err = %v, want %v", name, err, tc.want)
		}
		if f.closed != 1 || f.synced != tc.synced {
			t.Errorf("%s: closed %d (want 1), synced %d (want %d)", name, f.closed, f.synced, tc.synced)
		}
	}
}

func openFDs(t *testing.T) int {
	t.Helper()
	ents, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		t.Skipf("no /proc/self/fd: %v", err)
	}
	return len(ents)
}

func TestSquashfsTeethCreateEmpty(t *testing.T) {
	p := filepath.Join(t.TempDir(), "empty")
	before := openFDs(t)
	if err := createEmpty(p); err != nil {
		t.Fatal(err)
	}
	if after := openFDs(t); after != before {
		t.Errorf("createEmpty leaked %d descriptor(s)", after-before)
	}
	if fi, err := os.Stat(p); err != nil || fi.Size() != 0 {
		t.Errorf("created file: %v, %v", fi, err)
	}
	// An existing file is never reused.
	if err := createEmpty(p); !errors.Is(err, os.ErrExist) {
		t.Errorf("second createEmpty = %v, want already exists", err)
	}
}

// ---------------------------------------------------------------- output path handling

func sqTeethRun(t *testing.T, cwd string, args ...string) (rc int, stderr string) {
	t.Helper()
	var out, errb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: func(string) string { return "" },
		Environ: func() []string { return nil }, Clock: time.Now, Cwd: cwd}
	oc, om := currentCreds, readMountinfo
	currentCreds = func() creds { return creds{1000, 1000, 1000, 1000} }
	readMountinfo = func() (string, error) { return "1 0 0:1 / / rw - tmpfs tmpfs rw\n", nil }
	t.Cleanup(func() { currentCreds, readMountinfo = oc, om })
	rc = SquashfsExtract(append([]string{"--input", "in", "--manifest-cli", "m", "--output"}, args...), s)
	return rc, errb.String()
}

func TestSquashfsTeethEmptyOutputNameIsRefused(t *testing.T) {
	// "." names no destination: refused as unsafe, not an index panic on the empty path.
	cwd := t.TempDir()
	rc, stderr := sqTeethRun(t, cwd, ".")
	if rc != 2 || stderr != "squashfs-extract: unsafe output destination\n" {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
}

func TestSquashfsTeethReportsTheFirstMissingParent(t *testing.T) {
	cwd := t.TempDir()
	rc, stderr := sqTeethRun(t, cwd, filepath.Join(cwd, "missing1", "missing2", "out"))
	if rc != 2 || !strings.Contains(stderr, "No such file or directory") ||
		!strings.Contains(stderr, filepath.Join(cwd, "missing1")+"'") || strings.Contains(stderr, "missing2") {
		t.Errorf("rc = %d stderr = %q; want the first missing parent named", rc, stderr)
	}
}
