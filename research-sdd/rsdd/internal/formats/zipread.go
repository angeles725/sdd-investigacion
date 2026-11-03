package formats

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
	"errors"
	"fmt"
	"hash"
	"hash/crc32"
	"io"
	"strings"
)

// This file is a small reusable classic-ZIP reader: the central directory (with the EOCD search), the local
// header, and a bounded, CRC-checked member reader for STORED and DEFLATE entries. It is the port of
// zip_metadata.inventory and of the local-header handling of zip_stored.inspect (the retired Python tools, frozen
// under testdata/zip/legacy); the two commands in zipmetadata.go and zipstored.go are thin callers.
//
// Follow-up: internal/niagara/bog (PR #2404) carries a second zip member reader built on archive/zip. The
// two should be folded into ONE shared reader (this one, or that one); the exported surface here is the
// candidate: ReadZipDirectory, ReadLocalHeader, OpenMember and ReadMember.
//
// The reader is deliberately stricter than archive/zip: it never trusts a ZIP64 record, a spanned archive,
// an offset outside the declared central-directory range, or a size it was not told it may allocate.

// ZipError is a structural or policy rejection of an archive; Msg is the legacy message verbatim.
type ZipError struct{ Msg string }

func (e *ZipError) Error() string { return e.Msg }

func zipErr(format string, a ...any) error { return &ZipError{Msg: fmt.Sprintf(format, a...)} }

// ZipCaps bounds one directory read. Every value must be positive; the caller checks that.
type ZipCaps struct {
	MaxCentralDirectory int64 // bytes of central directory
	MaxEntries          int64
	MaxField            int64 // bytes of any name, extra field or comment
}

// ZipSafety are the name markers of the metadata report; they describe a name, they never authorize one.
type ZipSafety struct {
	Absolute, Traversal, Backslash, NUL, Duplicate bool
}

// ZipEntry is one central-directory record.
type ZipEntry struct {
	Index        int
	Name         string // decoded; undecodable bytes are replaced
	NameEncoding string // "utf-8" or "cp437"
	NameRaw      []byte
	MadeBy       uint16
	Needed       uint16
	Flags        uint16
	Method       uint16
	DosTime      uint16
	DosDate      uint16
	CRC32        uint32
	Compressed   uint32
	Uncompressed uint32
	Internal     uint16
	External     uint32
	LocalOffset  uint32 // as declared, before the archive prefix is added
	Safety       ZipSafety
}

// ZipDirectory is the parsed central directory of one archive.
type ZipDirectory struct {
	Entries       []ZipEntry
	PrefixBytes   int64 // bytes before the archive proper (self-extracting stub)
	CentralOffset int64 // absolute offset of the first central-directory record
	CentralSize   int64
	EOCDOffset    int64
	EOCD          []byte // the end record including its comment
}

// EOCDComment is the archive comment.
func (d *ZipDirectory) EOCDComment() []byte { return d.EOCD[22:] }

// readFull is pread with the legacy truncation error: a short read is "truncated ZIP structure".
func readFull(r io.ReaderAt, size, off int64) ([]byte, error) {
	if size == 0 {
		return []byte{}, nil
	}
	if off < 0 {
		return nil, zipErr("truncated ZIP structure")
	}
	buf := make([]byte, size)
	n, err := r.ReadAt(buf, off)
	if n == len(buf) {
		return buf, nil
	}
	if err == nil || errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return nil, zipErr("truncated ZIP structure")
	}
	return nil, err
}

var (
	zipEOCDSig    = []byte("PK\x05\x06")
	zipLocatorSig = []byte("PK\x06\x07")
)

func findEOCD(r io.ReaderAt, size int64) (int64, []byte, error) {
	if size < 22 {
		return 0, nil, zipErr("truncated EOCD")
	}
	fixed, err := readFull(r, 22, size-22)
	if err != nil {
		return 0, nil, err
	}
	if bytes.Equal(fixed[:4], zipEOCDSig) && binary.LittleEndian.Uint16(fixed[20:]) == 0 {
		return size - 22, fixed, nil
	}
	length := min(size, 65557)
	tail, err := readFull(r, length, size-length)
	if err != nil {
		return 0, nil, err
	}
	start := len(tail)
	for {
		start = bytes.LastIndex(tail[:start], zipEOCDSig)
		if start < 0 {
			return 0, nil, zipErr("EOCD not found")
		}
		if start+22 <= len(tail) && start+22+int(binary.LittleEndian.Uint16(tail[start+20:])) == len(tail) {
			return size - length + int64(start), tail[start:], nil
		}
	}
}

func dosTimestamp(date, tm uint16) (string, bool) {
	year, month, day := 1980+int(date>>9), int(date>>5)&15, int(date)&31
	hour, minute, second := int(tm>>11), int(tm>>5)&63, int(tm&31)*2
	if !(1 <= month && month <= 12 && 1 <= day && day <= 31 && hour < 24 && minute < 60 && second < 60) {
		return "", false
	}
	return fmt.Sprintf("%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second), true
}

// ReadZipDirectory parses the central directory of the archive behind r (size bytes). onEntry, when non-nil,
// runs after each record is built (its Duplicate marker still false) and may reject it, which is how the
// report-size cap is enforced incrementally. No entry payload and no local header is read.
func ReadZipDirectory(r io.ReaderAt, size int64, caps ZipCaps, onEntry func(*ZipEntry) error) (*ZipDirectory, error) {
	eocdOffset, eocd, err := findEOCD(r, size)
	if err != nil {
		return nil, err
	}
	le := binary.LittleEndian
	disk, cdDisk, diskEntries, entries := le.Uint16(eocd[4:]), le.Uint16(eocd[6:]), le.Uint16(eocd[8:]), le.Uint16(eocd[10:])
	cdSize, cdOffset, comment := int64(le.Uint32(eocd[12:])), int64(le.Uint32(eocd[16:])), int64(le.Uint16(eocd[20:]))
	if disk != 0 || cdDisk != 0 || diskEntries != entries {
		return nil, zipErr("multi-disk or spanned ZIP is unsupported")
	}
	if diskEntries == 0xffff || entries == 0xffff || cdSize == 0xffffffff || cdOffset == 0xffffffff {
		return nil, zipErr("ZIP64 is unsupported")
	}
	if eocdOffset >= 20 {
		loc, err := readFull(r, 4, eocdOffset-20)
		if err != nil {
			return nil, err
		}
		if bytes.Equal(loc, zipLocatorSig) {
			return nil, zipErr("ZIP64 is unsupported")
		}
	}
	if int64(entries) > caps.MaxEntries {
		return nil, zipErr("entry count exceeds max-entries")
	}
	if cdSize > caps.MaxCentralDirectory {
		return nil, zipErr("central directory exceeds max-central-directory-bytes")
	}
	if comment > caps.MaxField {
		return nil, zipErr("EOCD comment exceeds max-field-bytes")
	}
	prefix := eocdOffset - cdSize - cdOffset
	if prefix < 0 || cdOffset+prefix < 0 || cdOffset+prefix+cdSize != eocdOffset {
		return nil, zipErr("impossible central-directory range")
	}
	actual := cdOffset + prefix
	dir := &ZipDirectory{PrefixBytes: prefix, CentralOffset: actual, CentralSize: cdSize, EOCDOffset: eocdOffset, EOCD: eocd}
	position := actual
	dir.Entries = make([]ZipEntry, 0, entries)
	for index := 0; index < int(entries); index++ {
		if position+46 > eocdOffset {
			return nil, zipErr("truncated central-directory header")
		}
		h, err := readFull(r, 46, position)
		if err != nil {
			return nil, err
		}
		if !bytes.Equal(h[:4], []byte("PK\x01\x02")) {
			return nil, zipErr("invalid central-directory signature")
		}
		e := ZipEntry{
			Index: index, MadeBy: le.Uint16(h[4:]), Needed: le.Uint16(h[6:]), Flags: le.Uint16(h[8:]), Method: le.Uint16(h[10:]),
			DosTime: le.Uint16(h[12:]), DosDate: le.Uint16(h[14:]), CRC32: le.Uint32(h[16:]),
			Compressed: le.Uint32(h[20:]), Uncompressed: le.Uint32(h[24:]),
		}
		nlen, xlen, clen := int64(le.Uint16(h[28:])), int64(le.Uint16(h[30:])), int64(le.Uint16(h[32:]))
		startDisk := le.Uint16(h[34:])
		e.Internal, e.External, e.LocalOffset = le.Uint16(h[36:]), le.Uint32(h[38:]), le.Uint32(h[42:])
		if max(nlen, xlen, clen) > caps.MaxField {
			return nil, zipErr("central-directory field exceeds max-field-bytes")
		}
		end := position + 46 + nlen + xlen + clen
		if end > eocdOffset {
			return nil, zipErr("central-directory field exceeds declared range")
		}
		fields, err := readFull(r, nlen+xlen+clen, position+46)
		if err != nil {
			return nil, err
		}
		raw, extra := fields[:nlen], fields[nlen:nlen+xlen]
		if err := scanExtra(extra, "malformed extra field", true); err != nil {
			return nil, err
		}
		if startDisk != 0 || e.Compressed == 0xffffffff || e.Uncompressed == 0xffffffff || e.LocalOffset == 0xffffffff {
			return nil, zipErr("ZIP64 or spanned entry is unsupported")
		}
		if int64(e.LocalOffset)+prefix < 0 || int64(e.LocalOffset)+prefix >= actual {
			return nil, zipErr("impossible local-header offset")
		}
		e.NameRaw = append([]byte(nil), raw...)
		if e.Flags&0x800 != 0 {
			e.NameEncoding, e.Name = "utf-8", zipDecodeUTF8Replace(raw)
		} else {
			e.NameEncoding, e.Name = "cp437", zipDecodeCP437(raw)
		}
		parts := splitOnSeparators(e.Name)
		e.Safety = ZipSafety{
			Absolute:  strings.HasPrefix(e.Name, "/") || strings.HasPrefix(e.Name, "\\") || hasDrivePrefix(e.Name, true),
			Traversal: contains(parts, ".."),
			Backslash: bytes.IndexByte(raw, '\\') >= 0,
			NUL:       bytes.IndexByte(raw, 0) >= 0,
		}
		if onEntry != nil {
			if err := onEntry(&e); err != nil {
				return nil, err
			}
		}
		dir.Entries = append(dir.Entries, e)
		position = end
	}
	if position != eocdOffset {
		return nil, zipErr("central-directory size or entry count mismatch")
	}
	counts := map[string]int{}
	for _, e := range dir.Entries {
		counts[e.Name]++
	}
	for i := range dir.Entries {
		dir.Entries[i].Safety.Duplicate = counts[dir.Entries[i].Name] > 1
	}
	return dir, nil
}

// Metadata is the staged "central directory plus EOCD" byte string.
func (d *ZipDirectory) Metadata(r io.ReaderAt) ([]byte, error) {
	cd, err := readFull(r, d.CentralSize, d.CentralOffset)
	if err != nil {
		return nil, err
	}
	return append(cd, d.EOCD...), nil
}

// scanExtra walks an extra-field area. A truncated record is malformed; a ZIP64 record (kind 1) is
// unsupported. central selects the legacy message of the central-directory scan.
func scanExtra(extra []byte, malformed string, central bool) error {
	for cursor := 0; cursor < len(extra); {
		if cursor+4 > len(extra) {
			return zipErr("%s", malformed)
		}
		kind, length := binary.LittleEndian.Uint16(extra[cursor:]), int(binary.LittleEndian.Uint16(extra[cursor+2:]))
		cursor += 4
		if cursor+length > len(extra) {
			if central {
				return zipErr("malformed extra field")
			}
			return zipErr("ZIP64 or malformed local extra field")
		}
		if kind == 1 {
			if central {
				return zipErr("ZIP64 is unsupported")
			}
			return zipErr("ZIP64 or malformed local extra field")
		}
		cursor += length
	}
	return nil
}

func hasDrivePrefix(name string, needSeparator bool) bool {
	if len(name) < 2 || name[1] != ':' || !(name[0] >= 'a' && name[0] <= 'z' || name[0] >= 'A' && name[0] <= 'Z') {
		return false
	}
	if !needSeparator {
		return true
	}
	return len(name) >= 3 && (name[2] == '\\' || name[2] == '/')
}

func contains(parts []string, want string) bool {
	for _, p := range parts {
		if p == want {
			return true
		}
	}
	return false
}

// splitOnSeparators is re.split(r"[\\/]", s): empty parts are kept.
func splitOnSeparators(s string) []string {
	var parts []string
	last := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '/' || s[i] == '\\' {
			parts = append(parts, s[last:i])
			last = i + 1
		}
	}
	return append(parts, s[last:])
}

// ZipLocal is a local file header with its raw name; DataOffset is the absolute offset of the payload.
type ZipLocal struct {
	Needed, Flags, Method, DosTime, DosDate uint16
	CRC32, Compressed, Uncompressed         uint32
	NameRaw                                 []byte
	DataOffset                              int64
}

// ReadLocalHeader reads and checks the local header the entry declares. It validates the signature and the
// extra-field area but not that the header agrees with the central record; the caller decides what must
// match.
func (d *ZipDirectory) ReadLocalHeader(r io.ReaderAt, e *ZipEntry) (ZipLocal, error) {
	local := d.PrefixBytes + int64(e.LocalOffset)
	h, err := readFull(r, 30, local)
	if err != nil {
		return ZipLocal{}, err
	}
	le := binary.LittleEndian
	if le.Uint32(h) != 0x04034b50 {
		return ZipLocal{}, zipErr("invalid local-header signature")
	}
	l := ZipLocal{
		Needed: le.Uint16(h[4:]), Flags: le.Uint16(h[6:]), Method: le.Uint16(h[8:]), DosTime: le.Uint16(h[10:]), DosDate: le.Uint16(h[12:]),
		CRC32: le.Uint32(h[14:]), Compressed: le.Uint32(h[18:]), Uncompressed: le.Uint32(h[22:]),
	}
	nlen, xlen := int64(le.Uint16(h[26:])), int64(le.Uint16(h[28:]))
	fields, err := readFull(r, nlen+xlen, local+30)
	if err != nil {
		return ZipLocal{}, err
	}
	l.NameRaw = fields[:nlen]
	if err := scanExtra(fields[nlen:], "malformed local extra field", false); err != nil {
		return ZipLocal{}, err
	}
	l.DataOffset = local + 30 + nlen + xlen
	return l, nil
}

// Compression methods OpenMember can decode.
const (
	ZipMethodStored  = 0
	ZipMethodDeflate = 8
)

// memberReader yields exactly the entry's declared uncompressed size, then verifies the CRC-32. A short
// payload is "truncated payload", extra output is a size mismatch, and a CRC mismatch surfaces at EOF.
type memberReader struct {
	src      io.Reader
	crc      hash.Hash32
	want     uint32
	size     int64
	read     int64
	deflated bool
	err      error
}

func (m *memberReader) Read(p []byte) (int, error) {
	if m.err != nil {
		return 0, m.err
	}
	if m.read == m.size {
		return 0, m.finish()
	}
	if remaining := m.size - m.read; int64(len(p)) > remaining {
		p = p[:remaining]
	}
	n, err := m.src.Read(p)
	m.crc.Write(p[:n])
	m.read += int64(n)
	switch {
	case err == nil, errors.Is(err, io.EOF) && m.read == m.size:
		return n, nil
	case errors.Is(err, io.EOF):
		m.err = zipErr("truncated payload")
	default:
		m.err = m.classify(err)
	}
	return n, m.err
}

func (m *memberReader) classify(err error) error {
	if errors.Is(err, io.ErrUnexpectedEOF) {
		return zipErr("truncated payload")
	}
	if m.deflated {
		return zipErr("corrupt deflate payload: %v", err)
	}
	return err
}

// finish runs once the declared size was delivered.
func (m *memberReader) finish() error {
	if m.deflated {
		var probe [1]byte
		if n, _ := m.src.Read(probe[:]); n != 0 {
			m.err = zipErr("payload exceeds its declared size")
			return m.err
		}
	}
	if m.crc.Sum32() != m.want {
		m.err = zipErr("payload CRC32 mismatch")
		return m.err
	}
	m.err = io.EOF
	return io.EOF
}

// OpenMember returns a reader over the entry's decoded payload at l.DataOffset. Only STORED and DEFLATE are
// supported; anything else is a ZipError. The reader delivers exactly e.Uncompressed bytes, never more, and
// ends with an error rather than io.EOF if the payload is short or its CRC-32 differs from the central
// record. The caller bounds e.Uncompressed before opening (ReadMember does).
func (d *ZipDirectory) OpenMember(r io.ReaderAt, e *ZipEntry, l ZipLocal) (io.Reader, error) {
	if l.DataOffset+int64(e.Compressed) > d.CentralOffset {
		return nil, zipErr("payload range crosses central directory")
	}
	section := io.NewSectionReader(r, l.DataOffset, int64(e.Compressed))
	m := &memberReader{crc: crc32.NewIEEE(), want: e.CRC32, size: int64(e.Uncompressed)}
	switch e.Method {
	case ZipMethodStored:
		if e.Compressed != e.Uncompressed {
			return nil, zipErr("invalid STORED or directory size")
		}
		m.src = section
	case ZipMethodDeflate:
		m.src, m.deflated = flate.NewReader(section), true
	default:
		return nil, zipErr("unsupported compression method %d", e.Method)
	}
	return m, nil
}

// ReadMember reads one whole member into memory. maxBytes bounds the decoded size before anything is
// allocated.
func (d *ZipDirectory) ReadMember(r io.ReaderAt, e *ZipEntry, maxBytes int64) ([]byte, error) {
	if int64(e.Uncompressed) > maxBytes {
		return nil, zipErr("entry exceeds max-entry-bytes")
	}
	l, err := d.ReadLocalHeader(r, e)
	if err != nil {
		return nil, err
	}
	rd, err := d.OpenMember(r, e, l)
	if err != nil {
		return nil, err
	}
	return io.ReadAll(rd)
}
