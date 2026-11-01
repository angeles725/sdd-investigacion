package bog

import (
	"archive/zip"
	"bytes"
	"compress/flate"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Format names the container a .bog arrived in. The values are part of the bog-nav.v1 evidence schema.
type Format string

const (
	// FormatZip is a ZIP archive whose file.xml entry holds the Baja XML (a station backup).
	FormatZip Format = "zip-xml"
	// FormatPlaintext is bare Baja XML (platform and defaults files).
	FormatPlaintext Format = "plaintext-xml"
	// FormatUnknown is anything the reader could not classify.
	FormatUnknown Format = "unknown"
)

// MaxInflate is the cap on the inflated size of a ZIP's file.xml (32 MiB), the zip-bomb bound every Niagara
// reader shares.
const MaxInflate = 32 * 1024 * 1024

// Extracted is the outcome of looking inside one .bog.
//
// Err is empty on success. A non-empty Err means the XML text was not produced (Text is empty); Format then
// still says what the reader got as far as recognising, and Truncated is true only when the inflate cap fired.
type Extracted struct {
	Format    Format
	Text      string
	Err       string
	Truncated bool
}

// Lines is the Text split the way str.splitlines() does, ready for Parse.
func (e Extracted) Lines() []string { return SplitLines(e.Text) }

// Extract classifies data as a ZIP (first two bytes "PK" and at least four bytes) or bare XML and returns the
// decoded Baja XML. It never trusts a size field: the ZIP member is read through a length-bounded reader that
// stops at maxInflate+1 bytes, so a forged central directory cannot make it allocate more than the cap. The
// error strings match the legacy reader's, including the ones taken from CPython's zipfile module.
func Extract(data []byte, maxInflate int) Extracted {
	if len(data) >= 4 && data[0] == 'P' && data[1] == 'K' {
		return extractZip(data, maxInflate)
	}
	text := DecodeReplace(data)
	if !strings.HasPrefix(strings.TrimLeftFunc(text, IsSpace), "<") {
		return Extracted{Format: FormatUnknown, Err: "content is neither a ZIP nor XML"}
	}
	return Extracted{Format: FormatPlaintext, Text: text}
}

func extractZip(data []byte, maxInflate int) Extracted {
	z, err := OpenZip(data)
	if err != nil {
		return Extracted{Format: FormatUnknown, Err: "not a valid ZIP: " + err.Error()}
	}
	return z.ExtractFile(maxInflate)
}

// ExtractFile is Extract for an archive that is already open: the member called file.xml, or else the first
// member whose name ends in file.xml, read under the inflate cap with Extract's error strings.
func (z *Zip) ExtractFile(maxInflate int) Extracted {
	want := ""
	for _, n := range z.names {
		if n == "file.xml" {
			want = n
			break
		}
	}
	if want == "" {
		for _, n := range z.names {
			if strings.HasSuffix(n, "file.xml") {
				want = n
				break
			}
		}
	}
	if want == "" {
		return Extracted{Format: FormatUnknown, Err: "ZIP contains no file.xml entry"}
	}

	body, truncated, err := z.ReadMember(want, maxInflate)
	if err != nil {
		return Extracted{Format: FormatZip, Err: "ZIP entry read error: " + err.Error()}
	}
	if truncated {
		return Extracted{Format: FormatZip, Truncated: true,
			Err: fmt.Sprintf("bog XML exceeded inflate cap (%d bytes); file.xml was not parsed", maxInflate)}
	}
	return Extracted{Format: FormatZip, Text: DecodeReplace(body)}
}

// ErrNotZip is the failure of OpenZip. Its text is CPython's BadZipFile message for the most common fault, which
// is what the legacy tools print; Go reports every central-directory fault as one error, so the finer CPython
// messages ("Bad magic number for central directory", ...) are not distinguished.
var ErrNotZip = errors.New("File is not a zip file")

// Zip is a ZIP archive held in memory: the shared member reader of the Niagara tools. A .bog (file.xml), a
// module JAR (module.xml) and a distribution archive are all read through it, always under an inflate cap.
type Zip struct {
	zr    *zip.Reader
	names []string
}

// OpenZip reads the central directory of data.
func OpenZip(data []byte) (*Zip, error) { return OpenZipAt(bytes.NewReader(data), int64(len(data))) }

// OpenZipAt reads the central directory of the size-byte archive in r. Member reads touch only the bytes of the
// member, so an archive on disk is never held in memory.
func OpenZipAt(r io.ReaderAt, size int64) (*Zip, error) {
	zr, err := zip.NewReader(r, size)
	if err != nil && err != zip.ErrInsecurePath {
		return nil, ErrNotZip
	}
	z := &Zip{zr: zr, names: make([]string, len(zr.File))}
	for i, f := range zr.File {
		z.names[i] = zipName(memberName(f))
	}
	return z, nil
}

// Names lists the member names in central-directory order, each cut at its first NUL byte (ZipInfo's
// sanitised name), directories included.
func (z *Zip) Names() []string { return append([]string(nil), z.names...) }

// ErrNoMember is returned by ReadMember for a name that is not in the archive.
var ErrNoMember = errors.New("no such member")

// MemberError is a member that could not be read; its text is the CPython zipfile message the legacy tools
// embed after "ZIP entry read error: ".
type MemberError struct{ Msg string }

func (e *MemberError) Error() string { return e.Msg }

// ReadMember inflates the member called name, reading at most maxInflate+1 bytes whatever sizes the headers
// claim. When the member is larger than maxInflate, truncated is true and body is nil. If several members share
// the name the last one wins, like ZipFile.NameToInfo.
func (z *Zip) ReadMember(name string, maxInflate int) (body []byte, truncated bool, err error) {
	var entry *zip.File
	for i, n := range z.names {
		if n == name {
			entry = z.zr.File[i]
		}
	}
	if entry == nil {
		return nil, false, ErrNoMember
	}
	return readEntry(entry, name, maxInflate)
}

// zipName is ZipInfo's sanitised file name: terminated at the first NUL byte.
func zipName(n string) string {
	if i := strings.IndexByte(n, 0); i >= 0 {
		return n[:i]
	}
	return n
}

const (
	flagEncrypted        = 0x1
	flagCompressedPatch  = 0x20
	flagStrongEncryption = 0x40
)

// countReader counts the compressed bytes a decoder consumed.
type countReader struct {
	r io.Reader
	n int64
}

func (c *countReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	return n, err
}

// readEntry reads at most maxInflate+1 inflated bytes of f and reports (body, truncated, errMessage). The
// checks and their order follow CPython's ZipFile.open and ZipExtFile: local header, flag bits, encryption,
// compression method, then a read limited to the central directory's declared size whose CRC-32 is checked
// whenever the member's end was reached.
func readEntry(f *zip.File, name string, maxInflate int) ([]byte, bool, error) {
	raw, err := f.OpenRaw()
	if err != nil {
		if err == zip.ErrFormat {
			return nil, false, &MemberError{Msg: "Bad magic number for file header"}
		}
		return nil, false, &MemberError{Msg: "Truncated file header"}
	}
	switch {
	case f.Flags&flagCompressedPatch != 0:
		return nil, false, &MemberError{Msg: "compressed patched data (flag bit 5)"}
	case f.Flags&flagStrongEncryption != 0:
		return nil, false, &MemberError{Msg: "strong encryption (flag bit 6)"}
	case f.Flags&flagEncrypted != 0:
		return nil, false, &MemberError{Msg: fmt.Sprintf("File %s is encrypted, password required for extraction", pyRepr(name))}
	}

	cr := &countReader{r: raw}
	var src io.Reader
	switch f.Method {
	case zip.Store:
		src = cr
	case zip.Deflate:
		src = flate.NewReader(cr)
	default:
		return nil, false, &MemberError{Msg: "That compression method is not supported"}
	}

	left := f.UncompressedSize64
	limit := uint64(maxInflate) + 1
	want := min(left, limit)
	var buf bytes.Buffer
	sum := crc32.NewIEEE()
	n, err := io.Copy(io.MultiWriter(&buf, sum), io.LimitReader(src, int64(want)))
	// short: the file ended before the member's declared compressed bytes did. CPython then raises a bare
	// EOFError (an empty message) the moment it needs more input; a member whose compressed bytes were all
	// consumed simply ends there and the CRC decides.
	short := cr.n < int64(f.CompressedSize64)
	switch {
	case err == nil:
		if f.Method == zip.Store && uint64(n) < want && short {
			return nil, false, &MemberError{}
		}
	case err == io.ErrUnexpectedEOF && short:
		return nil, false, &MemberError{}
	case err == io.ErrUnexpectedEOF:
		// The compressed bytes ran out mid-stream: the member ends here and the CRC decides.
	default:
		return nil, false, &MemberError{Msg: "Error -3 while decompressing data: " + err.Error()}
	}
	reachedEnd := uint64(n) < want || uint64(n) == left
	if reachedEnd && sum.Sum32() != f.CRC32 {
		return nil, false, &MemberError{Msg: fmt.Sprintf("Bad CRC-32 for file %s", pyRepr(name))}
	}
	if uint64(buf.Len()) > uint64(maxInflate) {
		return nil, true, nil
	}
	return buf.Bytes(), false, nil
}

// pyRepr renders s like Python's repr(str): single quotes unless the text holds a single and no double quote,
// with the usual escapes.
func pyRepr(s string) string { return reprString(s, false) }

// PyReprPath is repr() of a path as Python holds it: the bytes of a name that are not valid UTF-8 are
// surrogate-escaped (os.fsdecode), so they print as \udcXX. It is the filename in the text of an OSError.
func PyReprPath(s string) string { return reprString(s, true) }

func reprString(s string, escapeInvalid bool) string {
	q := '\''
	if strings.ContainsRune(s, '\'') && !strings.ContainsRune(s, '"') {
		q = '"'
	}
	var b strings.Builder
	b.WriteRune(q)
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 && escapeInvalid {
			fmt.Fprintf(&b, `\udc%02x`, s[i])
			i++
			continue
		}
		i += size
		switch {
		case r == q || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case unicode.IsPrint(r):
			b.WriteRune(r)
		case r < 0x100:
			fmt.Fprintf(&b, `\x%02x`, r)
		case r < 0x10000:
			fmt.Fprintf(&b, `\u%04x`, r)
		default:
			fmt.Fprintf(&b, `\U%08x`, r)
		}
	}
	b.WriteRune(q)
	return b.String()
}
