package classfile

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"io"
	"math/bits"
	"sort"
	"strings"
	"unicode/utf8"
)

// A minimal reader for the one slice of the ZIP format classfile-facts needs, mirroring the behaviour of
// Python 3.12's zipfile (the interpreter CI runs) where that behaviour is observable in the CLASSFILE line:
// which inputs are archives at all, which fail to open (and under which exception class), the sorted .class
// names, each entry's declared size, and what reading an entry yields or fails with. Nothing here extracts
// to disk or follows a path inside the archive.

const (
	eocdLen          = 22
	endSearchWindow  = 1<<16 + eocdLen // how far back from the end the record is searched for (CPython 3.12)
	eocd64LocatorLen = 20
	eocd64Len        = 56
	cdHeaderLen      = 46
	localHeaderLen   = 30
	maxExtractMajor  = 63 // zipfile.MAX_EXTRACT_VERSION: a newer "version needed" is NotImplementedError

	flagEncrypted = 0x1
	flagPatched   = 0x20
	flagStrongEnc = 0x40
	flagUTF8Name  = 0x800

	methodStored   = 0
	methodDeflated = 8

	sigEOCD        = "PK\x05\x06"
	sigEOCD64      = "PK\x06\x06"
	sigEOCD64Loc   = "PK\x06\x07"
	sigCentralDir  = "PK\x01\x02"
	sigLocalHeader = "PK\x03\x04"

	zip64Sentinel32 = 0xFFFFFFFF
)

// pyError is an exception the legacy helper catches and prints as reason=unreadable-input(<class>).
type pyError struct{ class string }

func (e *pyError) Error() string { return e.class }

// errCrash marks the exceptions the legacy helper does NOT catch (it dies with a traceback and exit 1).
var errCrash = errors.New("an entry name is not valid UTF-8")

var cp437Runes = []rune(cp437High)

type zipEntry struct {
	orig    string // central-directory name as decoded (Python's ZipInfo.orig_filename)
	name    string // orig cut at the first NUL, or the Info-ZIP unicode path when one applies
	flags   uint16
	method  uint16
	crc     uint32
	extAttr uint32 // external_attr: the Unix mode is its high 16 bits
	csize   uint64
	usize   uint64
	hoff    int64 // header offset plus the prepended-data correction
	endOff  int64 // where the next local header (or the central directory) starts
}

type archive struct {
	r       io.ReaderAt
	size    int64
	entries []*zipEntry
	byName  map[string]*zipEntry // the LAST entry of a name wins, as in ZipFile.NameToInfo
}

type eocd struct {
	size, offset uint64
	location     int64
}

// readAt returns up to n bytes at off; a read past the end (or a failing read) is simply short.
func readAt(r io.ReaderAt, off int64, n int) []byte {
	buf := make([]byte, n)
	got, _ := r.ReadAt(buf, off)
	return buf[:got]
}

// readPadded is readAt zero-filled to n: for reads the format guarantees are in range.
func readPadded(r io.ReaderAt, off int64, n int) []byte {
	buf := make([]byte, n)
	_, _ = r.ReadAt(buf, off)
	return buf
}

func le16(b []byte) uint16 { return binary.LittleEndian.Uint16(b) }
func le32(b []byte) uint32 { return binary.LittleEndian.Uint32(b) }
func le64(b []byte) uint64 { return binary.LittleEndian.Uint64(b) }

// findEOCD is zipfile.is_zipfile plus the end record it found: false means "not an archive".
func findEOCD(r io.ReaderAt, size int64) (eocd, bool) {
	tail := readAt(r, size-eocdLen, eocdLen)
	if len(tail) == eocdLen && string(tail[:4]) == sigEOCD && tail[20] == 0 && tail[21] == 0 {
		return withZip64(r, eocdOf(tail, size-eocdLen))
	}
	// Either not an archive, or one with a comment (up to 64 KiB): look for the last end-record signature.
	from := max(size-endSearchWindow, 0)
	data := readAt(r, from, int(size-from))
	at := bytes.LastIndex(data, []byte(sigEOCD))
	if at < 0 || len(data)-at < eocdLen {
		return eocd{}, false
	}
	return withZip64(r, eocdOf(data[at:at+eocdLen], from+int64(at)))
}

func eocdOf(rec []byte, location int64) eocd {
	return eocd{size: uint64(le32(rec[12:])), offset: uint64(le32(rec[16:])), location: location}
}

// withZip64 replaces the end record's values with the ZIP64 end record's when a ZIP64 locator precedes it.
// Every inconsistency is "not an archive" (the legacy is_zipfile swallows BadZipFile and OSError).
func withZip64(r io.ReaderAt, rec eocd) (eocd, bool) {
	at := rec.location - eocd64LocatorLen // negative when the file is too short: the padded read then sees no locator
	loc := readPadded(r, at, eocd64LocatorLen)
	if string(loc[:4]) != sigEOCD64Loc {
		return rec, true
	}
	reloff := le64(loc[8:])
	if le32(loc[4:]) != 0 || le32(loc[16:]) > 1 {
		return eocd{}, false // spans multiple disks
	}
	at -= eocd64Len
	if at < 0 || reloff > uint64(at) {
		return eocd{}, false
	}
	extra := uint64(at) - reloff
	data := readPadded(r, int64(reloff), eocd64Len)
	if !bytes.HasPrefix(data, []byte(sigEOCD64)) && reloff != uint64(at) {
		// Prepended data: assume no "zip64 extensible data" and read the record right before the locator.
		extra = 0
		data = readPadded(r, at, eocd64Len)
	}
	if !bytes.HasPrefix(data, []byte(sigEOCD64)) {
		return eocd{}, false
	}
	dirsize, diroffset := le64(data[40:]), le64(data[48:])
	sum, carry := bits.Add64(diroffset, dirsize, 0)
	if carry != 0 || sum != reloff || le64(data[4:]) != eocd64Len-12+extra {
		return eocd{}, false
	}
	return eocd{size: dirsize, offset: diroffset, location: at - int64(extra)}, true
}

func decodeName(raw []byte, utf8Flag bool) (string, error) {
	if utf8Flag {
		if !utf8.Valid(raw) {
			return "", errCrash
		}
		return string(raw), nil
	}
	var sb []rune
	for _, c := range raw {
		if c < 0x80 {
			sb = append(sb, rune(c))
		} else {
			sb = append(sb, cp437Runes[c&0x7f]) // c >= 0x80 here, so c&0x7f == c-0x80 (a byte subtraction the mutants cannot tell from c+0x80)
		}
	}
	return string(sb), nil
}

// sanitize cuts a name at its first NUL byte, as ZipInfo does.
func sanitize(name string) string {
	if i := strings.IndexByte(name, 0); i >= 0 {
		return name[:i]
	}
	return name
}

var errBad = &pyError{"BadZipFile"}

// decodeExtra applies the ZIP64 (0x0001) and Info-ZIP unicode path (0x7075) extra fields to e.
func decodeExtra(e *zipEntry, extra []byte, nameCRC uint32, hoff *uint64) error {
	for len(extra) >= 4 {
		tp, ln := le16(extra), int(le16(extra[2:]))
		if ln+4 > len(extra) {
			return errBad
		}
		data := extra[4 : 4+ln]
		switch tp {
		case 0x0001:
			for _, f := range []struct {
				field *uint64
				when  func() bool
			}{
				{&e.usize, func() bool { return e.usize == zip64Sentinel32 || e.usize == ^uint64(0) }},
				{&e.csize, func() bool { return e.csize == zip64Sentinel32 }},
				{hoff, func() bool { return *hoff == zip64Sentinel32 }},
			} {
				if !f.when() {
					continue
				}
				if len(data) < 8 {
					return errBad
				}
				*f.field, data = le64(data), data[8:]
			}
		case 0x7075:
			if len(data) < 5 {
				return errBad
			}
			if data[0] == 1 && le32(data[1:]) == nameCRC {
				if !utf8.Valid(data[5:]) {
					return errBad
				}
				if len(data) > 5 {
					e.name = sanitize(string(data[5:]))
				}
			}
		}
		extra = extra[ln+4:]
	}
	return nil
}

// openArchive reads the central directory of an archive findEOCD accepted.
func openArchive(r io.ReaderAt, size int64, rec eocd) (*archive, error) {
	// A directory that would start before the file does reads as nothing here, and the loop below fails it.
	start := rec.location - int64(rec.size)
	concat := int64(uint64(rec.location) - rec.size - rec.offset) // non-zero when the archive is appended to other data
	dir := readAt(r, start, int(min(rec.size, uint64(size))))
	a := &archive{r: r, size: size, byName: map[string]*zipEntry{}}
	for total := uint64(0); total < rec.size; {
		if len(dir) < cdHeaderLen {
			return nil, errBad // truncated central directory
		}
		hdr := dir[:cdHeaderLen]
		dir = dir[cdHeaderLen:]
		if string(hdr[:4]) != sigCentralDir {
			return nil, errBad
		}
		rawName := take(&dir, int(le16(hdr[28:])))
		extra := take(&dir, int(le16(hdr[30:])))
		take(&dir, int(le16(hdr[32:]))) // entry comment
		flags := le16(hdr[8:])
		orig, err := decodeName(rawName, flags&flagUTF8Name != 0)
		if err != nil {
			return nil, err
		}
		e := &zipEntry{
			orig: orig, name: sanitize(orig), flags: flags, method: le16(hdr[10:]), crc: le32(hdr[16:]), extAttr: le32(hdr[38:]),
			csize: uint64(le32(hdr[20:])), usize: uint64(le32(hdr[24:])),
		}
		if hdr[6] > maxExtractMajor {
			return nil, &pyError{"NotImplementedError"}
		}
		hoff := uint64(le32(hdr[42:]))
		if err := decodeExtra(e, extra, crc32.ChecksumIEEE(rawName), &hoff); err != nil {
			return nil, err
		}
		e.hoff = int64(hoff) + concat
		a.entries = append(a.entries, e)
		a.byName[e.name] = e
		total += uint64(cdHeaderLen) + uint64(le16(hdr[28:])) + uint64(le16(hdr[30:])) + uint64(le16(hdr[32:]))
	}
	// _end_offset: an entry's data may not run into the next local header (zip-bomb overlap guard). Ties keep
	// directory order, so of two entries at one offset the later one is the one that overlaps.
	order := append([]*zipEntry(nil), a.entries...)
	sort.SliceStable(order, func(i, j int) bool { return order[i].hoff > order[j].hoff })
	end := start
	for _, e := range order {
		e.endOff, end = end, e.hoff
	}
	return a, nil
}

// take removes up to n bytes from the front of *b (a short buffer gives a short result, like BytesIO.read).
func take(b *[]byte, n int) []byte {
	n = min(n, len(*b))
	out := (*b)[:n]
	*b = (*b)[n:]
	return out
}

// classNames is namelist() filtered to .class entries, in Python's sort order.
func (a *archive) classNames() []string {
	var names []string
	for _, e := range a.entries {
		if strings.HasSuffix(e.name, ".class") {
			names = append(names, e.name)
		}
	}
	sort.Strings(names)
	return names
}

// errBadEntry says an entry could not be read: a damaged or unsupported entry, a seek before the start of the
// file, an encrypted one. The legacy helper tells these apart internally (corrupt-entry, unreadable-entry) but
// both end as one unreadable class in the CLASSFILE line, so one error carries them here.
var errBadEntry = errors.New("entry is unreadable")

// entryError is errBadEntry carrying the Python exception class zipfile raises for it: BadZipFile,
// NotImplementedError, EOFError and "error" (zlib.error) are what read_class_facts calls corrupt-entry;
// RuntimeError (an encrypted entry) and OSError (a seek before the start of the file) are unreadable-entry.
type entryError struct{ class string }

func (e *entryError) Error() string        { return "entry is unreadable: " + e.class }
func (e *entryError) Is(target error) bool { return target == errBadEntry }

func bad(class string) error { return &entryError{class} }

// read returns the bytes of an entry the way ZipFile.read does: header checks, then the data, truncated to the
// declared size and verified against the declared CRC-32. Only stored and deflated entries are decoded; any
// other method reads as corrupt (the legacy helper also decodes bzip2 and LZMA, which jars do not use).
func (a *archive) read(e *zipEntry) ([]byte, error) {
	if e.hoff < 0 {
		return nil, bad("OSError") // seek before the start of the file
	}
	hdr := readAt(a.r, e.hoff, localHeaderLen)
	if len(hdr) != localHeaderLen || string(hdr[:4]) != sigLocalHeader {
		return nil, bad("BadZipFile")
	}
	fname := readAt(a.r, e.hoff+localHeaderLen, int(le16(hdr[26:])))
	pos := e.hoff + localHeaderLen + int64(len(fname)) + int64(le16(hdr[28:]))
	if e.flags&(flagPatched|flagStrongEnc) != 0 {
		return nil, bad("NotImplementedError")
	}
	local, err := decodeName(fname, le16(hdr[6:])&flagUTF8Name != 0)
	if err != nil {
		return nil, errCrash
	}
	if local != e.orig {
		return nil, bad("BadZipFile")
	}
	if end, carry := bits.Add64(uint64(pos), e.csize, 0); carry != 0 || end > uint64(e.endOff) {
		return nil, bad("BadZipFile") // overlapped entries (possible zip bomb)
	}
	if e.flags&flagEncrypted != 0 {
		return nil, bad("RuntimeError")
	}
	avail := max(a.size-pos, 0)
	got := min(e.csize, uint64(avail)) // compressed bytes the file really holds
	if e.csize > 0 && got == 0 {
		return nil, bad("EOFError") // the file ends before the entry's data
	}
	var data []byte
	switch e.method {
	case methodStored:
		// One read returns `got` bytes. It is the whole entry when everything declared was there or the declared
		// uncompressed size is already covered; otherwise the next read finds the file exhausted.
		if e.csize != got && e.usize > got {
			return nil, bad("EOFError")
		}
		data = readAt(a.r, pos, int(min(e.usize, got)))
	case methodDeflated:
		var out capped
		out.limit = e.usize
		_, err := io.Copy(&out, flate.NewReader(io.NewSectionReader(a.r, pos, int64(got))))
		// Input that ends before the final block is fine when the whole declared stream was read (the output
		// so far is CRC-checked) or the declared size was reached; a damaged stream is not.
		if err != nil {
			if !errors.Is(err, io.ErrUnexpectedEOF) {
				return nil, bad("error") // zlib.error
			}
			if e.csize != got && uint64(len(out.buf)) < e.usize {
				return nil, bad("EOFError")
			}
		}
		data = out.buf
	default:
		return nil, bad("NotImplementedError")
	}
	if crc32.ChecksumIEEE(data) != e.crc {
		return nil, bad("BadZipFile")
	}
	return data, nil
}

// capped keeps the first `limit` bytes written to it and discards the rest, so a decompression bomb costs
// time, not memory.
type capped struct {
	buf   []byte
	limit uint64
}

func (c *capped) Write(p []byte) (int, error) {
	// Keeps min(len(p), room) bytes: the old len(p) <= room split was the same copy in both arms at equality.
	c.buf = append(c.buf, p[:min(uint64(len(p)), c.limit-uint64(len(c.buf)))]...)
	return len(p), nil
}
