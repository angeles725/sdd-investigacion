package classfile

import (
	"bytes"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"testing"
)

// Teeth for zip.go: archive detection, the central directory, names, and reading one entry.

func openBytes(b []byte) (*archive, error) {
	r := bytes.NewReader(b)
	rec, ok := findEOCD(r, int64(len(b)))
	if !ok {
		return nil, errors.New("not an archive")
	}
	return openArchive(r, int64(len(b)), rec)
}

func mustOpen(t *testing.T, b []byte) *archive {
	t.Helper()
	a, err := openBytes(b)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return a
}

type eocdCase struct {
	name  string
	input []byte
	want  string // the CLASSFILE line
}

func eocdCases() []eocdCase {
	good := buildZip(twoClasses(), zopts{})
	fakeEOCD := append([]byte("PK\x05\x06"), make([]byte, 18)...) // a well-formed, empty end record
	z64 := buildZip(twoClasses(), zopts{zip64: true})
	rec64, loc64 := bytes.LastIndex(z64, []byte("PK\x06\x06")), bytes.LastIndex(z64, []byte("PK\x06\x07"))
	mutZ64 := func(f func(b []byte)) []byte {
		b := append([]byte(nil), z64...)
		f(b)
		return b
	}
	put64 := func(b []byte, off int, v uint64) { binary.LittleEndian.PutUint64(b[off:], v) }
	put32 := func(b []byte, off int, v uint32) { binary.LittleEndian.PutUint32(b[off:], v) }
	embed := func(commentLen int) []byte { // the end record's size field spells the end-record signature
		b := append([]byte(nil), good...)
		e := len(b) - eocdLen
		copy(b[e+12:], "PK\x05\x06")
		binary.LittleEndian.PutUint16(b[e+20:], uint16(commentLen))
		return b
	}
	extensible := func() []byte { // ZIP64 "extensible data" between the record and its locator
		b := append(append(append([]byte(nil), z64[:loc64]...), bytes.Repeat([]byte{0xEE}, 10)...), z64[loc64:]...)
		binary.LittleEndian.PutUint64(b[rec64+4:], 44+10)
		return b
	}()
	noRoom := func() []byte { // accepted as an archive if the room check before the ZIP64 record is dropped
		b := make([]byte, 130)
		copy(b[50:], "PK\x06\x07")
		binary.LittleEndian.PutUint64(b[58:], 74) // locator: record offset
		binary.LittleEndian.PutUint32(b[66:], 1)
		copy(b[70:], "PK\x05\x06")
		copy(b[74:], "PK\x06\x06") // the record starts inside the end record
		binary.LittleEndian.PutUint64(b[78:], 0xFFFFFFFFFFFFFFDC)
		binary.LittleEndian.PutUint16(b[90:], 38) // comment length: the rest of the record
		binary.LittleEndian.PutUint64(b[122:], 74)
		return b
	}()
	return []eocdCase{
		{"21 bytes can never hold an end record", append([]byte("PK\x05\x06"), make([]byte, 17)...), lineOneBad},
		{"exactly an end record", buildZip(nil, zopts{}), lineEmptyJar},
		{"comment of 65535 bytes still finds the record", buildZip(twoClasses(), zopts{comment: bytes.Repeat([]byte("c"), 65535)}), lineMixed},
		{"65536 trailing bytes are still inside the search window", append(append([]byte(nil), good...), make([]byte, 65536)...), lineMixed},
		{"65537 trailing bytes push the record out of the window", append(append([]byte(nil), good...), make([]byte, 65537)...), lineOneBad},
		{"the LAST signature wins: an empty record inside the comment", buildZip(twoClasses(), zopts{comment: fakeEOCD}), lineEmptyJar},
		{"a signature with fewer than 22 bytes after it is not an archive", append(append([]byte(nil), good...), "PK\x05\x06abc"...), lineOneBad},
		{"a record whose comment length is wrong still opens through the search", func() []byte {
			b := append([]byte(nil), good...)
			b[len(b)-2] = 3 // claims a 3-byte comment that is not there
			return b
		}(), lineMixed},
		{"ZIP64 locator signature missing: the 32-bit sentinels are used, and fail", mutZ64(func(b []byte) { b[loc64+3] = 0 }), unreadableInput("BadZipFile")},
		{"ZIP64: locator names another disk", mutZ64(func(b []byte) { put32(b, loc64+4, 1) }), lineOneBad},
		{"ZIP64: two disks", mutZ64(func(b []byte) { put32(b, loc64+16, 2) }), lineOneBad},
		{"ZIP64: locator points past the record", mutZ64(func(b []byte) { put64(b, loc64+8, uint64(rec64+1)) }), lineOneBad},
		{"ZIP64: record signature missing", mutZ64(func(b []byte) { b[rec64+3] = 0 }), lineOneBad},
		{"ZIP64: record size field wrong", mutZ64(func(b []byte) { put64(b, rec64+4, 45) }), lineOneBad},
		{"ZIP64: directory offset wrong", mutZ64(func(b []byte) { put64(b, rec64+48, binary.LittleEndian.Uint64(b[rec64+48:])+1) }), lineOneBad},
		{"ZIP64: offset + size overflows 64 bits back onto the record offset", mutZ64(func(b []byte) {
			put64(b, rec64+40, ^uint64(0))
			put64(b, rec64+48, uint64(rec64)+1)
		}), lineOneBad},
		{"ZIP64 with prepended data finds the record before the locator", buildZip(twoClasses(), zopts{zip64: true, prepend: bytes.Repeat([]byte("p"), 37)}), lineMixed},
		{"the end record's size field spells the signature: the real record still wins (fast path)", embed(0), unreadableInput("BadZipFile")},
		{"same, with a comment length (low byte): the search finds the inner signature and gives up", embed(1), lineOneBad},
		{"same, with a comment length (high byte)", embed(256), lineOneBad},
		{"ZIP64 end record with extensible data before its locator", extensible, lineMixed},
		{"ZIP64 archive without entries (record at offset 0)", buildZip(nil, zopts{zip64: true}), lineEmptyJar},
		{"archive without entries but with a comment", buildZip(nil, zopts{comment: []byte("hello")}), lineEmptyJar},
		{"ZIP64 locator too close to the start of the file for any record", noRoom, lineOneBad},
		{"ZIP64 locator without room for its record", append(append([]byte("PK\x06\x07\x00\x00\x00\x00"), make([]byte, 8)...), append([]byte{1, 0, 0, 0}, buildZip(nil, zopts{})...)...), lineOneBad},
	}
}

func TestFindEOCD(t *testing.T) {
	t.Parallel()
	for _, tc := range eocdCases() {
		t.Run(tc.name, func(t *testing.T) {
			out, errw, code := run(t, tc.input, nil)
			if code != 0 || out != tc.want || errw != "" {
				t.Fatalf("code=%d stdout %q want %q stderr %q", code, out, tc.want, errw)
			}
		})
	}
}

type nameCase struct {
	name    string
	entries []zent
	want    []string // class names in order, or nil
	errCls  string
}

func nameCases() []nameCase {
	named := func(name string, extra []byte) zent {
		e := ent(name, c65, 0)
		e.cextra = extra
		return e
	}
	return []nameCase{
		{"sorted by code point, not directory order", []zent{ent("b.class", c65, 0), ent("B.class", c65, 0), ent("a.class", c65, 0)}, []string{"B.class", "a.class", "b.class"}, ""},
		{"duplicates are listed twice", []zent{ent("a.class", c65, 0), ent("a.class", c52, 0)}, []string{"a.class", "a.class"}, ""},
		{"unicode path replaces the name when version and CRC match", []zent{named("x.txt", unicodePath(1, []byte("x.txt"), "y.class"))}, []string{"y.class"}, ""},
		{"unicode path with the wrong CRC is ignored", []zent{named("x.class", unicodePath(1, []byte("other"), "y.txt"))}, []string{"x.class"}, ""},
		{"unicode path with another version is ignored", []zent{named("x.class", unicodePath(2, []byte("x.class"), "y.txt"))}, []string{"x.class"}, ""},
		{"unicode path that is empty keeps the name", []zent{named("x.class", unicodePath(1, []byte("x.class"), ""))}, []string{"x.class"}, ""},
		{"unicode path is cut at a NUL too", []zent{named("x.txt", unicodePath(1, []byte("x.txt"), "y.class\x00.txt"))}, []string{"y.class"}, ""},
		{"unicode path that is not UTF-8", []zent{named("x.class", unicodePath(1, []byte("x.class"), "\xff"))}, nil, "BadZipFile"},
		{"unicode path field shorter than 5 bytes", []zent{named("x.class", extraField(0x7075, []byte{1, 2, 3, 4}))}, nil, "BadZipFile"},
		{"unicode path field of exactly 5 bytes", []zent{named("x.class", extraField(0x7075, cat([]byte{1}, binary.LittleEndian.AppendUint32(nil, crc32.ChecksumIEEE([]byte("x.class"))))))}, []string{"x.class"}, ""},
		{"extra field running past its block", []zent{named("x.class", cat(u16le(0x1234), u16le(9), []byte{1, 2}))}, nil, "BadZipFile"},
		{"extra field exactly filling its block", []zent{named("x.class", cat(u16le(0x1234), u16le(2), []byte{1, 2}))}, []string{"x.class"}, ""},
		{"1-3 trailing extra bytes are ignored", []zent{named("x.class", []byte{9, 9, 9})}, []string{"x.class"}, ""},
		{"unknown extra tags are skipped before a known one", []zent{named("x.txt", cat(extraField(0xcafe, []byte{1, 2, 3}), unicodePath(1, []byte("x.txt"), "y.class")))}, []string{"y.class"}, ""},
		{"a size sentinel without any ZIP64 extra field is left as is", []zent{func() zent { e := named("x.class", nil); e.usize = 0xFFFFFFFF; return e }()}, []string{"x.class"}, ""},
		{"ZIP64 compressed size missing", []zent{func() zent { e := named("x.class", zip64Extra(5)); e.usize, e.csize = 0xFFFFFFFF, 0xFFFFFFFF; return e }()}, nil, "BadZipFile"},
		{"ZIP64 header offset missing", []zent{func() zent {
			e := named("x.class", zip64Extra(5))
			e.usize, e.hoffAdd = 0xFFFFFFFF, 0xFFFFFFFF
			return e
		}()}, nil, "BadZipFile"},
		{"ZIP64 extra field of 7 bytes is too short", []zent{func() zent { e := named("x.class", extraField(1, make([]byte, 7))); e.usize = 0xFFFFFFFF; return e }()}, nil, "BadZipFile"},
		{"empty ZIP64 field next to a size sentinel", []zent{func() zent { e := named("x.class", extraField(1, nil)); e.usize = 0xFFFFFFFF; return e }()}, nil, "BadZipFile"},
		{"empty unicode-path field", []zent{named("x.class", extraField(0x7075, nil))}, nil, "BadZipFile"},
		{"extra field one byte longer than its block", []zent{named("x.class", cat(u16le(0x1234), u16le(3), []byte{1, 2}))}, nil, "BadZipFile"},
		{"unicode path of a single character replaces the name", []zent{named("x.class", unicodePath(1, []byte("x.class"), "y"))}, []string{}, ""},
		{"ZIP64 field is not consulted when no size is a sentinel", []zent{named("x.class", extraField(1, nil))}, []string{"x.class"}, ""},
	}
}

func TestOpenArchiveNames(t *testing.T) {
	t.Parallel()
	for _, tc := range nameCases() {
		t.Run(tc.name, func(t *testing.T) {
			a, err := openBytes(buildZip(tc.entries, zopts{}))
			if tc.errCls != "" {
				var pe *pyError
				if !errors.As(err, &pe) || pe.class != tc.errCls {
					t.Fatalf("err = %v, want %s", err, tc.errCls)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			got := a.classNames()
			if len(got) != len(tc.want) {
				t.Fatalf("names = %q, want %q", got, tc.want)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Fatalf("names = %q, want %q", got, tc.want)
				}
			}
		})
	}
}

func TestZip64FieldsAreApplied(t *testing.T) {
	t.Parallel()
	e := ent("x.class", c65, 0)
	e.usize, e.csize, e.hoffAdd = 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF
	e.cextra = zip64Extra(uint64(len(c65)), uint64(len(c65)), 0)
	// hoff of the only entry is really 0: the 64-bit field says so, the 32-bit sentinel does not.
	a := mustOpen(t, buildZip([]zent{e}, zopts{}))
	got := a.byName["x.class"]
	if got.usize != uint64(len(c65)) || got.csize != uint64(len(c65)) || got.hoff != 0 {
		t.Fatalf("usize=%d csize=%d hoff=%d", got.usize, got.csize, got.hoff)
	}
	if data, err := a.read(got); err != nil || !bytes.Equal(data, c65) {
		t.Fatalf("read: %v", err)
	}
	// Only the fields holding a sentinel consume extra bytes, in order: here just the compressed size.
	e2 := ent("y.class", c65, 0)
	e2.csize, e2.cextra = 0xFFFFFFFF, zip64Extra(uint64(len(c65)))
	a = mustOpen(t, buildZip([]zent{e2}, zopts{}))
	if got := a.byName["y.class"]; got.csize != uint64(len(c65)) || got.usize != uint64(len(c65)) {
		t.Fatalf("csize=%d usize=%d", got.csize, got.usize)
	}
	// A second ZIP64 field re-reads the size when the first one left the 64-bit sentinel in place.
	e3 := ent("z.class", c65, 0)
	e3.usize, e3.cextra = 0xFFFFFFFF, cat(zip64Extra(^uint64(0)), zip64Extra(uint64(len(c65))))
	a = mustOpen(t, buildZip([]zent{e3}, zopts{}))
	if got := a.byName["z.class"]; got.usize != uint64(len(c65)) {
		t.Fatalf("usize=%d", got.usize)
	}
}

func TestDecodeName(t *testing.T) {
	t.Parallel()
	if len(cp437Runes) != 128 {
		t.Fatalf("cp437 table has %d entries", len(cp437Runes))
	}
	for in, want := range map[string]string{"abc": "abc", "\x80": "\U000000c7", "\x82": "\U000000e9", "\x9e": "\U000020a7", "\xe1": "\U000000df", "\xff": "\U000000a0", "a\xb0b": "a\U00002591b"} {
		if got, err := decodeName([]byte(in), false); err != nil || got != want {
			t.Errorf("cp437 %q = %q, %v; want %q", in, got, err, want)
		}
	}
	if got, err := decodeName([]byte("\xc3\xa9"), true); err != nil || got != "\U000000e9" {
		t.Errorf("utf8 = %q, %v", got, err)
	}
	for _, bad := range []string{"\xff", "\xc3", "\xed\xa0\x80", "\xc0\x80", "\xf4\x90\x80\x80"} {
		if _, err := decodeName([]byte(bad), true); !errors.Is(err, errCrash) {
			t.Errorf("utf8 %q: %v, want the crash error", bad, err)
		}
	}
	if got := sanitize("a\x00b"); got != "a" {
		t.Errorf("sanitize = %q", got)
	}
	if got := sanitize("ab"); got != "ab" {
		t.Errorf("sanitize = %q", got)
	}
}

// ---- reading one entry ---------------------------------------------------------------------------------------

type readCase struct {
	name   string
	target zent
	filler []zent // entries after the target (they set its end offset)
	opts   zopts
	check  func(t *testing.T, data []byte, err error)
}

func readCases() []readCase {
	crcOf := crc32.ChecksumIEEE
	// Raw deflate streams built by hand: a stored block "abc" that is not the final block, then a final empty one.
	abcBlock := []byte{0, 3, 0, 0xfc, 0xff, 'a', 'b', 'c'}
	withUsize := func(e zent, n int) zent { e.usize = uint32(n); return e }
	deflated := func(comp []byte, usize int, crc uint32) zent {
		e := ent("e.class", nil, 8)
		e.comp, e.csize, e.usize, e.crc = comp, uint32(len(comp)), uint32(usize), crc
		return e
	}
	with := func(f func(*zent)) zent {
		e := ent("e.class", c65, 0)
		f(&e)
		return e
	}
	ok := func(want []byte) func(t *testing.T, data []byte, err error) {
		return func(t *testing.T, data []byte, err error) {
			t.Helper()
			if err != nil || !bytes.Equal(data, want) {
				t.Fatalf("got %d bytes, err %v; want %d bytes", len(data), err, len(want))
			}
		}
	}
	bad := func(t *testing.T, _ []byte, err error) {
		t.Helper()
		if !errors.Is(err, errBadEntry) {
			t.Fatalf("err = %v, want errBadEntry", err)
		}
	}
	return []readCase{
		{"stored", ent("e.class", c65, 0), nil, zopts{}, ok(c65)},
		{"deflated", ent("e.class", c65, 8), nil, zopts{}, ok(c65)},
		{"empty stored", ent("e.class", nil, 0), nil, zopts{}, ok(nil)},
		{"empty deflated", ent("e.class", nil, 8), nil, zopts{}, ok(nil)},
		{"stored CRC mismatch", with(func(e *zent) { e.crc ^= 1 }), nil, zopts{}, bad},
		{"deflated CRC mismatch", func() zent { e := ent("e.class", c65, 8); e.crc ^= 1; return e }(), nil, zopts{}, bad},
		{"stored: declared size below the data keeps a prefix", withUsize(with(func(e *zent) { e.crc = crcOf(c65[:10]) }), 10), nil, zopts{}, ok(c65[:10])},
		{"stored: declared size above the data keeps everything", withUsize(ent("e.class", c65, 0), len(c65)+50), nil, zopts{}, ok(c65)},
		{"stored: size above the data but a CRC of a prefix fails", withUsize(with(func(e *zent) { e.crc = crcOf(c65[:10]) }), len(c65)+50), nil, zopts{}, bad},
		{"deflated: declared size below the output keeps a prefix", func() zent { e := ent("e.class", c65, 8); e.usize = 10; e.crc = crcOf(c65[:10]); return e }(), nil, zopts{}, ok(c65[:10])},
		{"deflated: declared size far below a multi-chunk output keeps only the prefix", func() zent {
			big := bytes.Repeat([]byte{7}, 100000)
			e := ent("e.class", big, 8)
			e.usize, e.crc = 10, crcOf(big[:10])
			return e
		}(), nil, zopts{}, ok(bytes.Repeat([]byte{7}, 10))},
		{"deflated: declared size above the output keeps everything", func() zent { e := ent("e.class", c65, 8); e.usize += 50; return e }(), nil, zopts{}, ok(c65)},
		{"deflated: damage after the kept prefix is still damage", deflated(append(append([]byte(nil), abcBlock...), 0x07), 3, crcOf([]byte("abc"))), nil, zopts{}, bad},
		{"deflated: input ends before the final block, CRC of the output", deflated(abcBlock, 10, crcOf([]byte("abc"))), nil, zopts{}, ok([]byte("abc"))},
		{"deflated: input ends before the final block, declared size reached", deflated(abcBlock, 3, crcOf([]byte("abc"))), nil, zopts{}, ok([]byte("abc"))},
		{"deflated: input ends before the final block, CRC wrong", deflated(abcBlock, 10, crcOf([]byte("abd"))), nil, zopts{}, bad},
		{"deflated: invalid block type", deflated([]byte{0x07, 0, 0}, 3, 0), nil, zopts{}, bad},
		{"deflated: stored block with a bad length complement", deflated([]byte{1, 3, 0, 0, 0, 'a', 'b', 'c'}, 3, crcOf([]byte("abc"))), nil, zopts{}, bad},
		{"deflated: final block ends the data, trailing bytes are ignored", deflated(append(append([]byte(nil), 1, 3, 0, 0xfc, 0xff, 'a', 'b', 'c'), 0xde, 0xad), 3, crcOf([]byte("abc"))), nil, zopts{}, ok([]byte("abc"))},
		{"deflated: no input at all and the CRC of nothing", deflated(nil, 3, 0), nil, zopts{}, ok(nil)},
		{"deflated: no input at all and another CRC", deflated(nil, 3, 1), nil, zopts{}, bad},
		{"method 1 (shrunk)", with(func(e *zent) { e.method = 1 }), nil, zopts{}, bad},
		{"method 9 (deflate64)", with(func(e *zent) { e.method = 9 }), nil, zopts{}, bad},
		{"method 12 (bzip2) reads as unreadable", with(func(e *zent) { e.method = 12 }), nil, zopts{}, bad},
		{"method 14 (LZMA) reads as unreadable", with(func(e *zent) { e.method = 14 }), nil, zopts{}, bad},
		{"method 99", with(func(e *zent) { e.method = 99 }), nil, zopts{}, bad},
		{"encrypted", with(func(e *zent) { e.cflags = 1 }), nil, zopts{}, bad},
		{"patched data flag", with(func(e *zent) { e.cflags = 0x20 }), nil, zopts{}, bad},
		{"strong encryption flag", with(func(e *zent) { e.cflags = 0x40 }), nil, zopts{}, bad},
		{"unrelated flag bits are fine", with(func(e *zent) { e.cflags = 0x2 | 0x4 | 0x8 | 0x10 | 0x80 | 0x100 | 0x400 }), nil, zopts{}, ok(c65)},
		{"local signature wrong", with(func(e *zent) { e.lsig = []byte("PK\x03\x05") }), nil, zopts{}, bad},
		{"local header beyond the file", with(func(e *zent) { e.hoffAdd = 1 << 20 }), nil, zopts{}, bad},
		{"local name differs", with(func(e *zent) { e.lname = []byte("f.class") }), nil, zopts{}, bad},
		{"local name has another length", with(func(e *zent) { e.lname = []byte("ee.class") }), nil, zopts{}, bad},
		{"entry data starting beyond the end of the file", with(func(e *zent) { e.lextraDecl = 60000 }), []zent{func() zent { e := ent("z.class", c52, 0); e.hoffAdd = 1 << 20; return e }()}, zopts{}, bad},
		{"local extra field is skipped", with(func(e *zent) { e.lextra = bytes.Repeat([]byte{7}, 13) }), nil, zopts{}, ok(c65)},
		{"local name decoded as UTF-8 by its own flag", with(func(e *zent) {
			e.name, e.lname, e.lflags = []byte("\x82.class"), []byte("\xc3\xa9.class"), 0x800
		}), nil, zopts{}, ok(c65)},
		{"local name flagged UTF-8 but invalid is the helper's crash", with(func(e *zent) { e.lname, e.lflags = []byte("\xff.class"), 0x800 }), nil, zopts{}, func(t *testing.T, _ []byte, err error) {
			t.Helper()
			if !errors.Is(err, errCrash) {
				t.Fatalf("err = %v, want the crash error", err)
			}
		}},
		{"entry data running into the next header", with(func(e *zent) { e.csize++ }), []zent{ent("z.class", c52, 0)}, zopts{}, bad},
		{"entry data running into the central directory", with(func(e *zent) { e.csize++ }), nil, zopts{}, bad},
		{"gap bytes before the next header are allowed", with(func(e *zent) { e.gap = []byte("xxxxx") }), []zent{ent("z.class", c52, 0)}, zopts{}, ok(c65)},
		{"stored: declared compressed size beyond the file but the size is covered", with(func(e *zent) { e.csize = 100000 }), []zent{func() zent { e := ent("z.class", c52, 0); e.hoffAdd = 1 << 20; return e }()}, zopts{}, ok(c65)},
		{"stored: declared compressed size beyond the file and the size is not covered", with(func(e *zent) { e.csize, e.usize = 100000, 100000 }), []zent{func() zent { e := ent("z.class", c52, 0); e.hoffAdd = 1 << 20; return e }()}, zopts{}, bad},
		{"negative offset after the prepended-data correction", with(func(*zent) {}), nil, zopts{eocdMut: func(r []byte) { r[16] += 10 }}, bad},
	}
}

func TestReadEntry(t *testing.T) {
	t.Parallel()
	for _, tc := range readCases() {
		t.Run(tc.name, func(t *testing.T) {
			entries := append([]zent{tc.target}, tc.filler...)
			a := mustOpen(t, buildZip(entries, tc.opts))
			e := a.entries[0]
			data, err := a.read(e)
			tc.check(t, data, err)
		})
	}
}

func TestReadEntryDuplicateOffsets(t *testing.T) {
	t.Parallel()
	first, second := ent("a.class", c65, 0), ent("b.class", c52, 0)
	second.hoffAdd = -(30 + len("a.class") + len(c65)) // b points at a's local header
	a := mustOpen(t, buildZip([]zent{first, second}, zopts{}))
	if _, err := a.read(a.byName["a.class"]); err != nil {
		t.Errorf("first of two entries at one offset: %v", err)
	}
	if _, err := a.read(a.byName["b.class"]); !errors.Is(err, errBadEntry) {
		t.Errorf("later of two entries at one offset: %v, want errBadEntry", err)
	}
	// Entries are ordered by offset, not by directory position: the end of an entry is the next HIGHER offset.
	z, y := ent("z.class", c65, 0), ent("y.class", c52, 0)
	a = mustOpen(t, buildZip([]zent{z, y}, zopts{}))
	if a.byName["z.class"].endOff != a.byName["y.class"].hoff || a.byName["y.class"].endOff <= a.byName["y.class"].hoff {
		t.Errorf("end offsets: z=%d y=%d (y starts at %d)", a.byName["z.class"].endOff, a.byName["y.class"].endOff, a.byName["y.class"].hoff)
	}
}

func TestReadEntryAtTheEndOfTheFile(t *testing.T) {
	t.Parallel()
	crcOf := crc32.ChecksumIEEE
	n := len(c65)
	type tc struct {
		name string
		tail []byte
		back int
		mut  func(e *zent)
		want []byte // nil: the read must fail
	}
	for _, c := range []tc{
		{"stored: file holds less than declared, declared size covered", c65, n, func(e *zent) { e.csize, e.usize, e.crc = uint32(n)+100, uint32(n), crcOf(c65) }, c65},
		{"stored: file holds less than declared, declared size not covered", c65, n, func(e *zent) { e.csize, e.usize, e.crc = uint32(n)+100, uint32(n)+1, crcOf(c65) }, nil},
		{"stored: data starts at the last byte", c65, 1, func(e *zent) { e.csize, e.usize, e.crc = 1, 1, crcOf(c65[n-1:]) }, c65[n-1:]},
		{"stored: data starts at the end of the file, nothing declared to read", c65, 0, func(e *zent) { e.csize, e.usize, e.crc = 1, 0, 0 }, nil},
		{"stored: data starts at the end of the file, nothing to read at all", c65, 0, func(e *zent) { e.csize, e.usize, e.crc = 0, 0, 0 }, []byte{}},
		{"deflated: stream cut by the end of the file, output is the declared size", storedBlock(c65), n + 5, func(e *zent) {
			e.method, e.csize, e.usize, e.crc = 8, uint32(n)+500, uint32(n), crcOf(c65)
		}, c65},
		{"deflated: stream cut by the end of the file, output is short of the declared size", storedBlock(c65), n + 5, func(e *zent) {
			e.method, e.csize, e.usize, e.crc = 8, uint32(n)+500, uint32(n)+1, crcOf(c65)
		}, nil},
		{"deflated: stream cut by the end of the file, output is past the declared size", storedBlock(c65), n + 5, func(e *zent) {
			e.method, e.csize, e.usize, e.crc = 8, uint32(n)+500, 10, crcOf(c65[:10])
		}, c65[:10]},
		{"deflated: stream cut where the whole declared stream was read", storedBlock(c65), n + 5, func(e *zent) {
			e.method, e.csize, e.usize, e.crc = 8, uint32(n)+5, uint32(n)+1, crcOf(c65)
		}, c65},
	} {
		t.Run(c.name, func(t *testing.T) {
			a := mustOpen(t, atTail(c.tail, c.back, c.mut))
			data, err := a.read(a.entries[0])
			if c.want == nil {
				if !errors.Is(err, errBadEntry) {
					t.Fatalf("read = %d bytes, %v; want errBadEntry", len(data), err)
				}
				return
			}
			if err != nil || !bytes.Equal(data, c.want) {
				t.Fatalf("read = %d bytes, %v; want %d bytes", len(data), err, len(c.want))
			}
		})
	}
}

// spyReader records every ReadAt request so a test can pin the offset and length findEOCD asks for.
type spyReader struct {
	*bytes.Reader
	reqs [][2]int64
}

func (s *spyReader) ReadAt(p []byte, off int64) (int, error) {
	s.reqs = append(s.reqs, [2]int64{off, int64(len(p))})
	return s.Reader.ReadAt(p, off)
}

// The comment search reads exactly the last endSearchWindow bytes of a large file, no more.
func TestFindEOCDSearchWindowLength(t *testing.T) {
	t.Parallel()
	zb := buildZip([]zent{ent("a.class", c65, 0)}, zopts{comment: bytes.Repeat([]byte{'x'}, 100)})
	b := append(bytes.Repeat([]byte{0}, 3*endSearchWindow), zb...)
	size := int64(len(b))
	spy := &spyReader{Reader: bytes.NewReader(b)}
	if _, ok := findEOCD(spy, size); !ok {
		t.Fatal("archive with a comment behind a large prefix not found")
	}
	want := [2]int64{size - endSearchWindow, endSearchWindow}
	for _, r := range spy.reqs {
		if r == want {
			return
		}
	}
	t.Errorf("no read of %d bytes at %d; requests (offset, length): %v", want[1], want[0], spy.reqs)
}

// A name that starts with NUL sanitizes to the empty string; the cut applies at index 0 too.
func TestSanitizeCutsAtLeadingNUL(t *testing.T) {
	t.Parallel()
	for in, want := range map[string]string{"\x00abc": "", "a\x00bc": "a", "abc": "abc", "": ""} {
		if got := sanitize(in); got != want {
			t.Errorf("sanitize(%q) = %q, want %q", in, got, want)
		}
	}
	a := mustOpen(t, buildZip([]zent{ent("\x00x.class", c65, 0)}, zopts{}))
	if _, ok := a.byName[""]; !ok || len(a.entries) != 1 || a.entries[0].orig != "\x00x.class" {
		t.Errorf("entry names: byName=%v orig=%q", a.byName, a.entries[0].orig)
	}
}

// The central directory walk counts each entry's comment, so the loop ends at the directory's declared size.
func TestOpenArchiveCountsEntryComments(t *testing.T) {
	t.Parallel()
	one := ent("a.class", c65, 0)
	one.ccomment = []byte("a comment")
	two := ent("b.class", c52, 0)
	two.ccomment = []byte("another comment")
	a, err := openBytes(buildZip([]zent{one, two}, zopts{}))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if got := a.classNames(); len(got) != 2 || got[0] != "a.class" || got[1] != "b.class" {
		t.Errorf("class names = %v", got)
	}
}

func TestCappedKeepsTheFirstLimitBytes(t *testing.T) {
	t.Parallel()
	c := &capped{limit: 5}
	for _, p := range []string{"ab", "cde", "fg", ""} { // under, exactly to the limit, over, empty
		if n, err := c.Write([]byte(p)); n != len(p) || err != nil {
			t.Fatalf("Write(%q) = %d, %v", p, n, err)
		}
	}
	if string(c.buf) != "abcde" {
		t.Errorf("buf = %q, want abcde", c.buf)
	}
}
