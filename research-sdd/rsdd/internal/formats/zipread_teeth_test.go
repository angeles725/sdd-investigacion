package formats

import (
	"bytes"
	"errors"
	"hash/crc32"
	"io"
	"testing"
)

// shortReader answers every ReadAt with fewer bytes than asked and the configured error.
type shortReader struct{ err error }

func (s shortReader) ReadAt(p []byte, _ int64) (int, error) { return len(p) - 1, s.err }

func TestReadFullShortReads(t *testing.T) {
	boom := errors.New("boom")
	for name, c := range map[string]struct {
		err  error
		want string
	}{
		"short with no error":       {nil, "truncated ZIP structure"},
		"short with EOF":            {io.EOF, "truncated ZIP structure"},
		"short with unexpected EOF": {io.ErrUnexpectedEOF, "truncated ZIP structure"},
	} {
		if _, err := readFull(shortReader{c.err}, 10, 0); zipErrorMessage(err) != c.want {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := readFull(shortReader{boom}, 10, 0); err != boom {
		t.Errorf("a real read error must pass through unchanged, got %v", err)
	}
}

func TestDosTimestampFieldBounds(t *testing.T) {
	date := func(month, day int) uint16 { return uint16(month<<5 | day) }
	tm := func(h, m, s int) uint16 { return uint16(h<<11 | m<<5 | s/2) }
	for name, c := range map[string]struct {
		date, tm uint16
		want     string // "" is invalid
	}{
		"first month":    {date(1, 1), 0, "1980-01-01T00:00:00"},
		"last month":     {date(12, 31), tm(23, 59, 58), "1980-12-31T23:59:58"},
		"month zero":     {date(0, 1), 0, ""},
		"month thirteen": {date(13, 1), 0, ""},
		"month fifteen":  {date(15, 1), 0, ""},
		"day zero":       {date(1, 0), 0, ""},
		"hour 24":        {date(1, 1), tm(24, 0, 0), ""},
		"hour 31":        {date(1, 1), tm(31, 0, 0), ""},
		"minute 60":      {date(1, 1), tm(0, 60, 0), ""},
		"minute 63":      {date(1, 1), tm(0, 63, 0), ""},
		"second 58":      {date(1, 1), tm(0, 0, 58), "1980-01-01T00:00:58"},
		"second 60":      {date(1, 1), tm(0, 0, 60), ""},
		"second 62":      {date(1, 1), tm(0, 0, 62), ""},
	} {
		got, ok := dosTimestamp(c.date, c.tm)
		if ok != (c.want != "") || got != c.want {
			t.Errorf("%s: dosTimestamp = %q,%v want %q", name, got, ok, c.want)
		}
	}
}

func TestHasDrivePrefixBounds(t *testing.T) {
	for name, c := range map[string]struct {
		in            string
		bare, withSep bool
	}{
		"empty":                  {"", false, false},
		"one letter":             {"a", false, false},
		"two characters":         {"a:", true, false},
		"lower a":                {"a:/x", true, true},
		"lower z backslash":      {"z:\\x", true, true},
		"upper A":                {"A:/x", true, true},
		"upper Z":                {"Z:x", true, false},
		"before a (backtick)":    {"`:x", false, false},
		"after z (brace)":        {"{:x", false, false},
		"before A (at)":          {"@:x", false, false},
		"after Z (bracket)":      {"[:x", false, false},
		"digit":                  {"1:/x", false, false},
		"no colon":               {"ab/x", false, false},
		"three characters":       {"a:/", true, true},
		"third is not a divider": {"a:b", true, false},
	} {
		if got := hasDrivePrefix(c.in, false); got != c.bare {
			t.Errorf("%s: hasDrivePrefix(%q, false) = %v", name, c.in, got)
		}
		if got := hasDrivePrefix(c.in, true); got != c.withSep {
			t.Errorf("%s: hasDrivePrefix(%q, true) = %v", name, c.in, got)
		}
	}
}

func TestReadZipDirectoryCapBoundaries(t *testing.T) {
	one := buildZip([]zfx{{name: []byte("a"), payload: []byte("a")}}, zipOpts{})
	none := buildZip(nil, zipOpts{})
	const cdBytes = 46 + 1 // one record with a one-byte name
	for name, c := range map[string]struct {
		data []byte
		caps ZipCaps
		want string
	}{
		"entries at the cap":       {one, ZipCaps{MaxCentralDirectory: 1 << 20, MaxEntries: 1, MaxField: 65536}, ""},
		"entries over the cap":     {buildZip([]zfx{{name: []byte("a")}, {name: []byte("b")}}, zipOpts{}), ZipCaps{MaxCentralDirectory: 1 << 20, MaxEntries: 1, MaxField: 65536}, "entry count exceeds max-entries"},
		"no entries, zero cap":     {none, ZipCaps{MaxCentralDirectory: 1, MaxEntries: 0, MaxField: 1}, ""},
		"directory at the cap":     {one, ZipCaps{MaxCentralDirectory: cdBytes, MaxEntries: 1, MaxField: 65536}, ""},
		"directory over the cap":   {one, ZipCaps{MaxCentralDirectory: cdBytes - 1, MaxEntries: 1, MaxField: 65536}, "central directory exceeds max-central-directory-bytes"},
		"empty directory, cap 0":   {none, ZipCaps{MaxCentralDirectory: 0, MaxEntries: 1, MaxField: 1}, ""},
		"name at the field cap":    {one, ZipCaps{MaxCentralDirectory: 1 << 20, MaxEntries: 1, MaxField: 1}, ""},
		"name over the field cap":  {buildZip([]zfx{{name: []byte("ab")}}, zipOpts{}), ZipCaps{MaxCentralDirectory: 1 << 20, MaxEntries: 1, MaxField: 1}, "central-directory field exceeds max-field-bytes"},
		"extra over the field cap": {buildZip([]zfx{{name: []byte("a"), extra: []byte{9, 9, 0, 0}}}, zipOpts{}), ZipCaps{MaxCentralDirectory: 1 << 20, MaxEntries: 1, MaxField: 3}, "central-directory field exceeds max-field-bytes"},
		"extra at the field cap":   {buildZip([]zfx{{name: []byte("a"), extra: []byte{9, 9, 0, 0}}}, zipOpts{}), ZipCaps{MaxCentralDirectory: 1 << 20, MaxEntries: 1, MaxField: 4}, ""},
	} {
		_, err := ReadZipDirectory(bytes.NewReader(c.data), int64(len(c.data)), c.caps, nil)
		if got := zipErrorMessage(err); got != c.want {
			t.Errorf("%s: error %q, want %q", name, got, c.want)
		}
	}
}

func TestReadZipDirectoryLocatorAtOffset20(t *testing.T) {
	locator := []byte("PK\x06\x07")
	// 20 prefix bytes ending the locator slot: the locator sits at offset 0, the EOCD at exactly 20.
	at20 := append(append([]byte(nil), locator...), bytes.Repeat([]byte{0}, 16)...)
	data := buildZip(nil, zipOpts{prefix: at20})
	if _, err := ReadZipDirectory(bytes.NewReader(data), int64(len(data)), testCaps, nil); zipErrorMessage(err) != "ZIP64 is unsupported" {
		t.Errorf("locator at 0, EOCD at 20: %v", err)
	}
	// One byte less of prefix: no room for a locator, the same bytes are just a stub.
	data = buildZip(nil, zipOpts{prefix: at20[:19]})
	d, err := ReadZipDirectory(bytes.NewReader(data), int64(len(data)), testCaps, nil)
	if err != nil || d.EOCDOffset != 19 {
		t.Errorf("EOCD at 19: %v %+v", err, d)
	}
}

func TestReadLocalHeaderDataOffset(t *testing.T) {
	extra := []byte{0x55, 0x54, 0x01, 0x00, 0x07} // kind 0x5455, one data byte
	payloads := [][]byte{[]byte("first payload"), []byte("second one")}
	for _, prefix := range [][]byte{nil, []byte("stub!")} {
		data := buildZip([]zfx{
			{name: []byte("alpha.txt"), payload: payloads[0], extra: extra},
			{name: []byte("be"), payload: payloads[1], extra: append(append([]byte(nil), extra...), extra...)},
		}, zipOpts{prefix: prefix})
		r := bytes.NewReader(data)
		d, err := ReadZipDirectory(r, int64(len(data)), testCaps, nil)
		if err != nil {
			t.Fatal(err)
		}
		for i := range d.Entries {
			l, err := d.ReadLocalHeader(r, &d.Entries[i])
			if err != nil {
				t.Fatal(err)
			}
			if want := int64(bytes.Index(data, payloads[i])); l.DataOffset != want {
				t.Errorf("prefix %q entry %d: DataOffset = %d, want %d", prefix, i, l.DataOffset, want)
			}
			if got, err := d.ReadMember(r, &d.Entries[i], 1<<20); err != nil || !bytes.Equal(got, payloads[i]) {
				t.Errorf("prefix %q entry %d: ReadMember = %q, %v", prefix, i, got, err)
			}
		}
	}
}

// A member reader must never ask the source for more than the bytes still owed, whatever buffer it is
// handed: a DEFLATE stream that inflates past its declared size must stop at the size.
func TestMemberReaderNeverReadsPastDeclaredSize(t *testing.T) {
	full := []byte("0123456789")
	declared := full[:5]
	data := buildZip([]zfx{{
		name: []byte("x"), method: ZipMethodDeflate, payload: deflateBytes(t, full), size: uint32(len(declared)),
		crc: crc32.ChecksumIEEE(declared),
	}}, zipOpts{})
	r := bytes.NewReader(data)
	d, err := ReadZipDirectory(r, int64(len(data)), testCaps, nil)
	if err != nil {
		t.Fatal(err)
	}
	l, err := d.ReadLocalHeader(r, &d.Entries[0])
	if err != nil {
		t.Fatal(err)
	}
	rd, err := d.OpenMember(r, &d.Entries[0], l)
	if err != nil {
		t.Fatal(err)
	}
	one := make([]byte, 1)
	if n, err := rd.Read(one); n != 1 || err != nil || one[0] != '0' {
		t.Fatalf("first read = %d, %v, %q", n, err, one)
	}
	big := make([]byte, 100)
	n, err := rd.Read(big)
	if n != 4 || err != nil || string(big[:n]) != "1234" {
		t.Fatalf("second read = %d, %v, %q; want exactly the 4 remaining bytes", n, err, big[:n])
	}
	if _, err := rd.Read(big); zipErrorMessage(err) != "payload exceeds its declared size" {
		t.Errorf("after the declared size: %v", err)
	}
}
