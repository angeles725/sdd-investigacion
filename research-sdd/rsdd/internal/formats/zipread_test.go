package formats

import (
	"bytes"
	"errors"
	"hash/crc32"
	"io"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

var testCaps = ZipCaps{MaxCentralDirectory: 1 << 20, MaxEntries: 1000, MaxField: 65536}

// recordingReader remembers every ReadAt, to prove which byte ranges the reader touched.
type recordingReader struct {
	r     io.ReaderAt
	reads [][2]int64 // offset, length
}

func (c *recordingReader) ReadAt(p []byte, off int64) (int, error) {
	c.reads = append(c.reads, [2]int64{off, int64(len(p))})
	return c.r.ReadAt(p, off)
}

func zipErrorMessage(err error) string {
	var ze *ZipError
	if errors.As(err, &ze) {
		return ze.Msg
	}
	if err == nil {
		return ""
	}
	return "NOT A ZipError: " + err.Error()
}

func TestReadZipDirectoryNeverReadsPayload(t *testing.T) {
	data := metaFixtures()["mixed.zip"]
	rec := &recordingReader{r: bytes.NewReader(data)}
	d, err := ReadZipDirectory(rec, int64(len(data)), testCaps, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := d.Metadata(rec); err != nil {
		t.Fatal(err)
	}
	payloadEnd := int64(bytes.Index(data, []byte("PK\x01\x02")))
	if len(rec.reads) == 0 {
		t.Fatal("nothing was read")
	}
	for _, r := range rec.reads {
		if r[0] < payloadEnd {
			t.Errorf("read of %d bytes at %d starts before the central directory at %d", r[1], r[0], payloadEnd)
		}
	}
	if len(d.Entries) != 7 || d.Entries[0].Name != "ok.txt" || d.CentralOffset != payloadEnd {
		t.Errorf("directory = %+v", d)
	}
}

func TestReadZipDirectoryEOCDSearch(t *testing.T) {
	entry := []zfx{{name: []byte("a"), payload: []byte("a")}}
	// A comment holding a fake EOCD signature forces the backward scan past it.
	fake := bytes.Repeat([]byte("PK\x05\x06"), 3)
	for name, o := range map[string]zipOpts{
		"no comment":       {},
		"comment":          {comment: []byte("hello")},
		"signature inside": {comment: append([]byte("x"), fake...)},
		"max comment":      {comment: bytes.Repeat([]byte("c"), 65535)},
	} {
		data := buildZip(entry, o)
		d, err := ReadZipDirectory(bytes.NewReader(data), int64(len(data)), testCaps, nil)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		if string(d.EOCDComment()) != string(o.comment) || len(d.Entries) != 1 {
			t.Errorf("%s: comment %d bytes, %d entries", name, len(d.EOCDComment()), len(d.Entries))
		}
	}
	short := []byte("PK\x05\x06")
	if _, err := ReadZipDirectory(bytes.NewReader(short), int64(len(short)), testCaps, nil); zipErrorMessage(err) != "truncated EOCD" {
		t.Errorf("tiny file: %v", err)
	}
	garbage := bytes.Repeat([]byte{7}, 100)
	if _, err := ReadZipDirectory(bytes.NewReader(garbage), 100, testCaps, nil); zipErrorMessage(err) != "EOCD not found" {
		t.Errorf("no signature: %v", err)
	}
}

func TestReadZipDirectoryRejections(t *testing.T) {
	good := buildZip([]zfx{{name: []byte("a"), payload: []byte("a")}}, zipOpts{})
	le := func(b []byte, off int, v uint32, n int) []byte {
		c := append([]byte(nil), b...)
		for i := 0; i < n; i++ {
			c[off+i] = byte(v >> (8 * i))
		}
		return c
	}
	eocd := len(good) - 22
	cd := bytes.Index(good, []byte("PK\x01\x02"))
	for _, c := range []struct {
		name string
		data []byte
		caps ZipCaps
		want string
	}{
		{"multi-disk", le(good, eocd+4, 1, 2), testCaps, "multi-disk or spanned ZIP is unsupported"},
		{"cd disk", le(good, eocd+6, 1, 2), testCaps, "multi-disk or spanned ZIP is unsupported"},
		{"count mismatch between disk and total", le(good, eocd+8, 2, 2), testCaps, "multi-disk or spanned ZIP is unsupported"},
		{"zip64 count", le(le(good, eocd+8, 0xffff, 2), eocd+10, 0xffff, 2), testCaps, "ZIP64 is unsupported"},
		{"zip64 size", le(good, eocd+12, 0xffffffff, 4), testCaps, "ZIP64 is unsupported"},
		{"zip64 offset", le(good, eocd+16, 0xffffffff, 4), testCaps, "ZIP64 is unsupported"},
		{"entries cap", good, ZipCaps{MaxCentralDirectory: 1 << 20, MaxEntries: 0, MaxField: 65536}, "entry count exceeds max-entries"},
		{"cd cap", good, ZipCaps{MaxCentralDirectory: 1, MaxEntries: 10, MaxField: 65536}, "central directory exceeds max-central-directory-bytes"},
		{"impossible range", le(good, eocd+16, uint32(len(good)+100), 4), testCaps, "impossible central-directory range"},
		{"bad signature", le(good, cd, 0, 1), testCaps, "invalid central-directory signature"},
		{"field cap", good, ZipCaps{MaxCentralDirectory: 1 << 20, MaxEntries: 10, MaxField: 0}, "central-directory field exceeds max-field-bytes"},
		{"name beyond range", le(good, cd+28, 40, 2), testCaps, "central-directory field exceeds declared range"},
		{"start disk", le(good, cd+34, 1, 2), testCaps, "ZIP64 or spanned entry is unsupported"},
		{"local offset", le(good, cd+42, 0xffffffff, 4), testCaps, "ZIP64 or spanned entry is unsupported"},
		{"local offset past cd", le(good, cd+42, uint32(cd), 4), testCaps, "impossible local-header offset"},
	} {
		_, err := ReadZipDirectory(bytes.NewReader(c.data), int64(len(c.data)), c.caps, nil)
		if got := zipErrorMessage(err); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
	// Extra-field handling in the central directory.
	for name, c := range map[string]struct {
		extra []byte
		want  string
	}{
		"zip64 extra": {[]byte{1, 0, 0, 0}, "ZIP64 is unsupported"},
		"cut header":  {[]byte{9, 0}, "malformed extra field"},
		"cut body":    {[]byte{9, 0, 5, 0, 1}, "malformed extra field"},
		"fine":        {[]byte{9, 0, 1, 0, 7}, ""},
	} {
		data := buildZip([]zfx{{name: []byte("a"), payload: []byte("a"), extra: c.extra}}, zipOpts{})
		_, err := ReadZipDirectory(bytes.NewReader(data), int64(len(data)), testCaps, nil)
		if got := zipErrorMessage(err); got != c.want {
			t.Errorf("%s: got %q, want %q", name, got, c.want)
		}
	}
}

func TestReadZipDirectoryOnEntryHook(t *testing.T) {
	data := metaFixtures()["mixed.zip"]
	var seen []string
	_, err := ReadZipDirectory(bytes.NewReader(data), int64(len(data)), testCaps, func(e *ZipEntry) error {
		if e.Safety.Duplicate {
			t.Error("Duplicate is decided after the loop, the hook must see false")
		}
		seen = append(seen, e.Name)
		if len(seen) == 3 {
			return &ZipError{Msg: "stop here"}
		}
		return nil
	})
	if zipErrorMessage(err) != "stop here" || len(seen) != 3 {
		t.Errorf("err %v after %v", err, seen)
	}
}

func TestZipDosTimestamp(t *testing.T) {
	if got, ok := dosTimestamp(0x5821, 1); !ok || got != "2024-01-01T00:00:02" {
		t.Errorf("valid stamp = %q %v", got, ok)
	}
	for name, c := range map[string][2]uint16{"month 0": {0x5801, 0}, "month 13": {0x59a1, 0}, "day 0": {0x5820, 0}, "hour 24": {0x5821, 24 << 11}, "minute 60": {0x5821, 60 << 5}, "second 60": {0x5821, 30}} {
		if got, ok := dosTimestamp(c[0], c[1]); ok {
			t.Errorf("%s accepted as %q", name, got)
		}
	}
	if _, ok := dosTimestamp(0x5821, 23<<11|59<<5|29); !ok {
		t.Error("the last valid second of the day was rejected")
	}
}

// memberFixture builds an archive with one member of each kind and returns the directory with its reader.
func memberFixture(t *testing.T, payload []byte, deflated bool, mutate func(*zfx)) (*ZipDirectory, *bytes.Reader, ZipEntry) {
	t.Helper()
	e := zfx{name: []byte("m"), payload: payload}
	if deflated {
		e.method, e.payload, e.size = 8, deflateBytes(t, payload), uint32(len(payload))
		e.crc = crc32.ChecksumIEEE(payload)
	}
	if mutate != nil {
		mutate(&e)
	}
	data := buildZip([]zfx{e}, zipOpts{})
	r := bytes.NewReader(data)
	d, err := ReadZipDirectory(r, int64(len(data)), testCaps, nil)
	if err != nil {
		t.Fatal(err)
	}
	return d, r, d.Entries[0]
}

func TestReadMemberStoredAndDeflate(t *testing.T) {
	text := bytes.Repeat([]byte("the quick brown fox "), 200)
	for _, deflated := range []bool{false, true} {
		d, r, e := memberFixture(t, text, deflated, nil)
		got, err := d.ReadMember(r, &e, 1<<20)
		if err != nil || !bytes.Equal(got, text) {
			t.Errorf("deflated=%v: %d bytes, %v", deflated, len(got), err)
		}
		if _, err := d.ReadMember(r, &e, int64(len(text))-1); zipErrorMessage(err) != "entry exceeds max-entry-bytes" {
			t.Errorf("deflated=%v: size cap: %v", deflated, err)
		}
		if got, err := d.ReadMember(r, &e, int64(len(text))); err != nil || len(got) != len(text) {
			t.Errorf("deflated=%v: a cap equal to the size must pass: %v", deflated, err)
		}
	}
	d, r, e := memberFixture(t, nil, false, nil)
	if got, err := d.ReadMember(r, &e, 10); err != nil || len(got) != 0 {
		t.Errorf("empty member: %q %v", got, err)
	}
}

func TestReadMemberRejectsCorruption(t *testing.T) {
	text := []byte("hello hello hello hello")
	for name, c := range map[string]struct {
		deflated bool
		mutate   func(*zfx)
		want     string
	}{
		"stored crc":        {false, func(e *zfx) { e.crc, e.fakeCRC = 0xdeadbeef, true }, "payload CRC32 mismatch"},
		"deflate crc":       {true, func(e *zfx) { e.crc, e.fakeCRC = 0xdeadbeef, true }, "payload CRC32 mismatch"},
		"empty crc":         {false, func(e *zfx) { e.payload = nil; e.crc, e.fakeCRC = 1, true }, "payload CRC32 mismatch"},
		"deflate too long":  {true, func(e *zfx) { e.size = 3 }, "payload exceeds its declared size"},
		"deflate too short": {true, func(e *zfx) { e.size += 50 }, "truncated payload"},
		"deflate garbage":   {true, func(e *zfx) { e.payload = bytes.Repeat([]byte{0xff}, 20) }, "corrupt deflate payload"},
		"stored sizes":      {false, func(e *zfx) { e.size = 5 }, "invalid STORED or directory size"},
		"method":            {false, func(e *zfx) { e.method = 12 }, "unsupported compression method 12"},
	} {
		d, r, e := memberFixture(t, text, c.deflated, c.mutate)
		_, err := d.ReadMember(r, &e, 1<<20)
		if got := zipErrorMessage(err); !strings.HasPrefix(got, c.want) {
			t.Errorf("%s: got %q, want prefix %q", name, got, c.want)
		}
	}
}

func TestOpenMemberRangeAndTruncation(t *testing.T) {
	d, r, e := memberFixture(t, []byte("abcdef"), false, nil)
	l, err := d.ReadLocalHeader(r, &e)
	if err != nil {
		t.Fatal(err)
	}
	if l.DataOffset != 30+1 || l.CRC32 != e.CRC32 || string(l.NameRaw) != "m" {
		t.Errorf("local = %+v", l)
	}
	bad := e
	bad.Compressed, bad.Uncompressed = uint32(d.CentralOffset), uint32(d.CentralOffset)
	if _, err := d.OpenMember(r, &bad, l); zipErrorMessage(err) != "payload range crosses central directory" {
		t.Errorf("range: %v", err)
	}
	// A payload that the underlying reader cuts short is a truncation, not a CRC error.
	cut := bytes.NewReader(mustRead(t, r)[:l.DataOffset+3])
	rd, err := d.OpenMember(cut, &e, l)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadAll(rd); zipErrorMessage(err) != "truncated payload" {
		t.Errorf("cut payload: %v", err)
	}
	// Reading past the end keeps returning the same error.
	if n, err := rd.Read(make([]byte, 4)); n != 0 || zipErrorMessage(err) != "truncated payload" {
		t.Errorf("sticky error: %d %v", n, err)
	}
}

func mustRead(t *testing.T, r *bytes.Reader) []byte {
	t.Helper()
	b := make([]byte, r.Size())
	if _, err := r.ReadAt(b, 0); err != nil && !errors.Is(err, io.EOF) {
		t.Fatal(err)
	}
	return b
}

func TestReadLocalHeaderRejections(t *testing.T) {
	good := buildZip([]zfx{{name: []byte("a"), payload: []byte("a")}}, zipOpts{})
	r := bytes.NewReader(good)
	d, err := ReadZipDirectory(r, int64(len(good)), testCaps, nil)
	if err != nil {
		t.Fatal(err)
	}
	e := d.Entries[0]
	sig := append([]byte(nil), good...)
	sig[0] = 'X'
	if _, err := d.ReadLocalHeader(bytes.NewReader(sig), &e); zipErrorMessage(err) != "invalid local-header signature" {
		t.Errorf("signature: %v", err)
	}
	for name, c := range map[string]struct {
		extra []byte
		want  string
	}{
		"zip64":    {[]byte{1, 0, 0, 0}, "ZIP64 or malformed local extra field"},
		"cut body": {[]byte{9, 0, 9, 0, 1}, "ZIP64 or malformed local extra field"},
		"cut head": {[]byte{9, 0}, "malformed local extra field"},
		"harmless": {[]byte{9, 0, 1, 0, 7}, ""},
	} {
		// The central record stays clean (offset 0 is the same in both); only the local header carries the extra.
		withExtra := buildZip([]zfx{{name: []byte("a"), payload: []byte("a"), extra: c.extra}}, zipOpts{})
		if _, err := d.ReadLocalHeader(bytes.NewReader(withExtra), &e); zipErrorMessage(err) != c.want {
			t.Errorf("%s: got %q, want %q", name, zipErrorMessage(err), c.want)
		}
	}
	if _, err := d.ReadLocalHeader(bytes.NewReader(good[:10]), &e); zipErrorMessage(err) != "truncated ZIP structure" {
		t.Errorf("short header: %v", err)
	}
}

func TestZipDirectoryRegistered(t *testing.T) {
	want := map[string]bool{"zip-metadata": false, "zip-stored": false}
	for _, c := range Commands {
		if c.Group != "formats" {
			t.Errorf("%s is in group %q", c.Name, c.Group)
		}
		if _, ok := want[c.Name]; ok {
			want[c.Name] = true
			if c.Run == nil || c.Summary == "" {
				t.Errorf("%s has no Run or Summary", c.Name)
			}
		}
	}
	for n, ok := range want {
		if !ok {
			t.Errorf("command %s is not registered", n)
		}
	}
	if err := cli.Validate(Commands); err != nil {
		t.Error(err)
	}
}
