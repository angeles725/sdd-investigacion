package bog

import (
	"archive/zip"
	"bytes"
	"compress/flate"
	"fmt"
	"hash/crc32"
	"io"
	"strings"
	"unicode"
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
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil && err != zip.ErrInsecurePath {
		// CPython distinguishes several central-directory faults; Go reports them all as ErrFormat, so every
		// one maps to the message of the most common fault (no end record).
		return Extracted{Format: FormatUnknown, Err: "not a valid ZIP: File is not a zip file"}
	}
	names := make([]string, len(zr.File))
	for i, f := range zr.File {
		names[i] = zipName(f.Name)
	}
	want := ""
	for _, n := range names {
		if n == "file.xml" {
			want = n
			break
		}
	}
	if want == "" {
		for _, n := range names {
			if strings.HasSuffix(n, "file.xml") {
				want = n
				break
			}
		}
	}
	if want == "" {
		return Extracted{Format: FormatUnknown, Err: "ZIP contains no file.xml entry"}
	}
	var entry *zip.File
	for i, n := range names { // NameToInfo semantics: the last entry with a name wins
		if n == want {
			entry = zr.File[i]
		}
	}

	body, truncated, msg := readEntry(entry, want, maxInflate)
	if msg != "" {
		return Extracted{Format: FormatZip, Err: "ZIP entry read error: " + msg}
	}
	if truncated {
		return Extracted{Format: FormatZip, Truncated: true,
			Err: fmt.Sprintf("bog XML exceeded inflate cap (%d bytes); file.xml was not parsed", maxInflate)}
	}
	return Extracted{Format: FormatZip, Text: DecodeReplace(body)}
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
func readEntry(f *zip.File, name string, maxInflate int) ([]byte, bool, string) {
	raw, err := f.OpenRaw()
	if err != nil {
		if err == zip.ErrFormat {
			return nil, false, "Bad magic number for file header"
		}
		return nil, false, "Truncated file header"
	}
	switch {
	case f.Flags&flagCompressedPatch != 0:
		return nil, false, "compressed patched data (flag bit 5)"
	case f.Flags&flagStrongEncryption != 0:
		return nil, false, "strong encryption (flag bit 6)"
	case f.Flags&flagEncrypted != 0:
		return nil, false, fmt.Sprintf("File %s is encrypted, password required for extraction", pyRepr(name))
	}

	cr := &countReader{r: raw}
	var src io.Reader
	switch f.Method {
	case zip.Store:
		src = cr
	case zip.Deflate:
		src = flate.NewReader(cr)
	default:
		return nil, false, "That compression method is not supported"
	}

	left := f.UncompressedSize64
	limit := uint64(maxInflate) + 1
	want := min(left, limit)
	var buf bytes.Buffer
	sum := crc32.NewIEEE()
	n, err := io.Copy(io.MultiWriter(&buf, sum), io.LimitReader(src, int64(want)))
	if err != nil {
		switch {
		case err == io.ErrUnexpectedEOF && cr.n >= int64(f.CompressedSize64):
			// The compressed bytes ran out mid-stream: the member ends here and the CRC decides.
		case err == io.ErrUnexpectedEOF:
			return nil, false, "" // CPython raises a bare EOFError: an empty message
		default:
			return nil, false, "Error -3 while decompressing data: " + err.Error()
		}
	}
	reachedEnd := uint64(n) < want || uint64(n) == left
	if reachedEnd && sum.Sum32() != f.CRC32 {
		return nil, false, fmt.Sprintf("Bad CRC-32 for file %s", pyRepr(name))
	}
	if uint64(buf.Len()) > uint64(maxInflate) {
		return nil, true, ""
	}
	return buf.Bytes(), false, ""
}

// pyRepr renders s like Python's repr(str): single quotes unless the text holds a single and no double quote,
// with the usual escapes.
func pyRepr(s string) string {
	q := '\''
	if strings.ContainsRune(s, '\'') && !strings.ContainsRune(s, '"') {
		q = '"'
	}
	var b strings.Builder
	b.WriteRune(q)
	for _, r := range s {
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
