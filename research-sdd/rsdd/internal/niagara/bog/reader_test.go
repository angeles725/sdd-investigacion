package bog

import (
	"bytes"
	"compress/flate"
	"errors"
	"hash/crc32"
	"runtime"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

func u32(v uint32) *uint32 { return &v }

func TestExtractContainers(t *testing.T) {
	tests := []struct {
		name      string
		data      []byte
		format    Format
		errSub    string // exact when errExact
		errExact  bool
		truncated bool
		textSub   string
	}{
		{name: "deflate zip with file.xml", data: bogtest.Bog(bogtest.ValidXML), format: "zip-xml", textSub: "PLAINSECRET"},
		{name: "plaintext xml", data: []byte(bogtest.ValidXML), format: "plaintext-xml", textSub: "bajaObjectGraph"},
		{name: "plaintext xml after leading whitespace", data: []byte("  \n\t<a/>"), format: "plaintext-xml", textSub: "<a/>"},
		{name: "stored member", data: bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte("<a/>"), Method: bogtest.Stored}), format: "zip-xml", textSub: "<a/>"},
		{name: "binary is neither", data: bogtest.Binary(), format: "unknown", errSub: "content is neither a ZIP nor XML", errExact: true},
		{name: "empty input is not xml", data: nil, format: "unknown", errSub: "content is neither a ZIP nor XML", errExact: true},
		{name: "a BOM before the markup is not whitespace", data: []byte("\xEF\xBB\xBF<a/>"), format: "unknown", errSub: "content is neither a ZIP nor XML", errExact: true},
		{name: "PK without a zip structure", data: []byte("PK\x03\x04 not really a zip"), format: "unknown", errSub: "not a valid ZIP: File is not a zip file", errExact: true},
		{name: "three bytes starting with PK stay plaintext", data: []byte("PK<"), format: "unknown", errSub: "content is neither a ZIP nor XML", errExact: true},
		{name: "zip without file.xml", data: bogtest.Zip(bogtest.Entry{Name: "other.xml", Data: []byte("<a/>")}), format: "unknown", errSub: "ZIP contains no file.xml entry", errExact: true},
		{name: "corrupt deflate stream", data: bogtest.CorruptDeflate(), format: "zip-xml", errSub: "ZIP entry read error: Error -3 while decompressing data: "},
		{name: "compressed bytes that end mid-stream fail the CRC, not the inflater", data: bogtest.TruncatedDeflate(), format: "zip-xml", errSub: "ZIP entry read error: Bad CRC-32 for file 'file.xml'", errExact: true},
		{name: "a stored member that claims more bytes than the file holds is a bare EOF", data: bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte("<a/>"), Method: bogtest.Stored, Size: u32(1 << 20), CSize: u32(1 << 20)}), format: "zip-xml", errSub: "ZIP entry read error: ", errExact: true},
		{name: "a deflate member whose compressed bytes run out at end of file is a bare EOF", data: bogtest.TruncatedDeflateForgedCSize(), format: "zip-xml", errSub: "ZIP entry read error: ", errExact: true},
		{name: "crc mismatch", data: bogtest.CRCMismatch(), format: "zip-xml", errSub: "ZIP entry read error: Bad CRC-32 for file 'file.xml'", errExact: true},
		{name: "encrypted member", data: bogtest.Encrypted(), format: "zip-xml", errSub: "ZIP entry read error: File 'file.xml' is encrypted, password required for extraction", errExact: true},
		{name: "unsupported compression method", data: bogtest.Method99(), format: "zip-xml", errSub: "ZIP entry read error: That compression method is not supported", errExact: true},
		{name: "strong encryption flag", data: bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte("<a/>"), Flags: 0x40}), format: "zip-xml", errSub: "ZIP entry read error: strong encryption (flag bit 6)", errExact: true},
		{name: "patched data flag", data: bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte("<a/>"), Flags: 0x20}), format: "zip-xml", errSub: "ZIP entry read error: compressed patched data (flag bit 5)", errExact: true},
		{name: "exact name beats an earlier suffix match", data: bogtest.Zip(
			bogtest.Entry{Name: "x/file.xml", Data: []byte("<first/>")}, bogtest.Entry{Name: "file.xml", Data: []byte("<second/>")}), format: "zip-xml", textSub: "<second/>"},
		{name: "suffix match when there is no exact name", data: bogtest.Zip(
			bogtest.Entry{Name: "readme", Data: []byte("x")}, bogtest.Entry{Name: "dir/file.xml", Data: []byte("<nested/>")}), format: "zip-xml", textSub: "<nested/>"},
		{name: "a name that only contains file.xml is not a match", data: bogtest.Zip(bogtest.Entry{Name: "file.xml.bak", Data: []byte("<a/>")}), format: "unknown", errSub: "ZIP contains no file.xml entry", errExact: true},
		{name: "duplicate names: the last entry wins", data: bogtest.Zip(
			bogtest.Entry{Name: "file.xml", Data: []byte("<old/>")}, bogtest.Entry{Name: "file.xml", Data: []byte("<new/>")}), format: "zip-xml", textSub: "<new/>"},
		{name: "a declared size below the real size stops the read and fails the CRC", data: bogtest.Zip(
			bogtest.Entry{Name: "file.xml", Data: []byte("<aaaaaaaaaaaaaaaa/>"), Size: u32(4)}), format: "zip-xml", errSub: "ZIP entry read error: Bad CRC-32 for file 'file.xml'", errExact: true},
		{name: "a declared size above the real size is harmless", data: bogtest.Zip(
			bogtest.Entry{Name: "file.xml", Data: []byte("<a/>"), Size: u32(9999)}), format: "zip-xml", textSub: "<a/>"},
		{name: "a name is terminated at its first NUL byte", data: bogtest.Zip(bogtest.Entry{Name: "file.xml\x00junk", Data: []byte("<nul/>")}), format: "zip-xml", textSub: "<nul/>"},
		{name: "invalid UTF-8 inside the xml is replaced, not an error", data: bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte("<a n='\xff'/>")}), format: "zip-xml", textSub: "�"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Extract(tt.data, MaxInflate)
			if got.Format != tt.format {
				t.Errorf("format = %q, want %q (err %q)", got.Format, tt.format, got.Err)
			}
			switch {
			case tt.errSub == "" && got.Err != "":
				t.Errorf("unexpected error %q", got.Err)
			case tt.errExact && got.Err != tt.errSub:
				t.Errorf("err = %q, want %q", got.Err, tt.errSub)
			case !tt.errExact && !strings.HasPrefix(got.Err, tt.errSub):
				t.Errorf("err = %q, want prefix %q", got.Err, tt.errSub)
			}
			if tt.textSub != "" && !strings.Contains(got.Text, tt.textSub) {
				t.Errorf("text %q does not contain %q", got.Text, tt.textSub)
			}
			if got.Err != "" && got.Text != "" {
				t.Errorf("an error result must carry no text, got %q", got.Text)
			}
		})
	}
}

func TestExtractInflateCapIsLengthBounded(t *testing.T) {
	const capBytes = 1024
	exact := bogtest.Bog(strings.Repeat("A", capBytes))
	if got := Extract(exact, capBytes); got.Err != "" || got.Truncated || len(got.Text) != capBytes {
		t.Errorf("a member of exactly the cap must pass: err=%q truncated=%v len=%d", got.Err, got.Truncated, len(got.Text))
	}
	over := bogtest.Bog(strings.Repeat("A", capBytes+1))
	got := Extract(over, capBytes)
	want := "bog XML exceeded inflate cap (1024 bytes); file.xml was not parsed"
	if got.Err != want || !got.Truncated || got.Format != "zip-xml" || got.Text != "" {
		t.Errorf("over-cap result = %+v, want truncated zip-xml with %q", got, want)
	}
	if got := Extract(bogtest.Bomb(MaxInflate), MaxInflate); !got.Truncated || !strings.Contains(got.Err, "33554432") {
		t.Errorf("the real 32 MiB cap did not fire: %+v", got.Err)
	}
}

func TestExtractBoundedReadDoesNotTrustTheDeclaredSize(t *testing.T) {
	// 192 MiB of zeros deflate to a few hundred KiB; the central directory declares the honest size, a forged
	// one is covered above. The reader must stop at the cap instead of materialising the stream.
	var payload bytes.Buffer
	zw, _ := flate.NewWriter(&payload, flate.BestSpeed)
	zeros := make([]byte, 1<<20)
	for i := 0; i < 192; i++ {
		_, _ = zw.Write(zeros)
	}
	_ = zw.Close()
	data := bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: nil, Raw: payload.Bytes(), CRC: u32(crc32.ChecksumIEEE(nil)), Size: u32(192 << 20)})

	var before, after runtime.MemStats
	runtime.GC()
	runtime.ReadMemStats(&before)
	got := Extract(data, 1<<20)
	runtime.ReadMemStats(&after)
	if !got.Truncated {
		t.Fatalf("expected truncation, got %+v", got.Err)
	}
	if grew := after.TotalAlloc - before.TotalAlloc; grew > 24<<20 {
		t.Errorf("reading a bomb under a 1 MiB cap allocated %d MiB; the read is not length-bounded", grew>>20)
	}
}

func TestZipSharedMemberReader(t *testing.T) {
	data := bogtest.Zip(
		bogtest.Entry{Name: "a/", Data: nil},
		bogtest.Entry{Name: "module.xml", Data: []byte("<module/>")},
		bogtest.Entry{Name: "x\x00hidden", Data: []byte("<x/>")},
	)
	z, err := OpenZip(data)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(z.Names(), "|"); got != "a/|module.xml|x" {
		t.Errorf("Names() = %q, want the central-directory order with NUL-cut names", got)
	}
	body, truncated, err := z.ReadMember("module.xml", 1<<10)
	if err != nil || truncated || string(body) != "<module/>" {
		t.Errorf("ReadMember = %q, %v, %v", body, truncated, err)
	}
	if _, _, err := z.ReadMember("missing", 1<<10); err != ErrNoMember {
		t.Errorf("a missing member = %v, want ErrNoMember", err)
	}
	if body, truncated, err := z.ReadMember("module.xml", 4); err != nil || !truncated || body != nil {
		t.Errorf("a 9-byte member under a 4-byte cap = %q, %v, %v; want truncated and no body", body, truncated, err)
	}
	var me *MemberError
	z2, _ := OpenZip(bogtest.Encrypted())
	if _, _, err := z2.ReadMember("file.xml", 1<<10); !errors.As(err, &me) || !strings.Contains(me.Msg, "encrypted") {
		t.Errorf("an encrypted member = %v, want a *MemberError", err)
	}
	if _, err := OpenZip([]byte("PK\x03\x04 junk")); err != ErrNotZip {
		t.Errorf("OpenZip(junk) = %v, want ErrNotZip", err)
	}
}
