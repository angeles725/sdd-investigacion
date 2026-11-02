package floss

// Edge tests that need no Python, tool or sandbox: each pins one boundary the goldens or the end-to-end tests do
// not reach on their own, so `make teeth` (-tags nodiff, a bare CI runner) kills the mutants on it.

import (
	"errors"
	"io"
	"strings"
	"testing"
	"testing/iotest"
	"unicode"
)

func TestParsePyIntDigitLimitIsExclusiveAt4300(t *testing.T) {
	if v, ok := parsePyInt(strings.Repeat("1", 4300)); !ok || len(v.String()) != 4300 {
		t.Errorf("4300 digits: want accepted, got ok=%v", ok)
	}
	if _, ok := parsePyInt(strings.Repeat("1", 4301)); ok {
		t.Error("4301 digits: want refused (Python 3.12 int() limit), got accepted")
	}
	if v, ok := parsePyInt("1_" + strings.Repeat("0", 4299)); !ok || len(v.String()) != 4300 {
		t.Errorf("4300 digits with an underscore: want accepted, got ok=%v", ok)
	}
}

func TestPySpaceCoversTheAsciiSeparators(t *testing.T) {
	for r := rune(0x1b); r <= 0x20; r++ {
		want := r >= 0x1c // U+001C..U+001F and the space; U+001B is not white space
		if got := pySpace(r); got != want {
			t.Errorf("pySpace(%U) = %v, want %v", r, got, want)
		}
	}
	for _, r := range []rune{'\t', '\n', 0x85, 0xa0, 0x2028, 'a', '0'} {
		if got := pySpace(r); got != unicode.IsSpace(r) {
			t.Errorf("pySpace(%U) = %v, want %v", r, got, unicode.IsSpace(r))
		}
	}
	if got := pyStrip("\x1c\x1fa b\x1d "); got != "a b" {
		t.Errorf("pyStrip = %q, want %q", got, "a b")
	}
}

type fakeRead struct {
	n   int
	err error
}

func (f fakeRead) Read(p []byte) (int, error) {
	for i := 0; i < f.n && i < len(p); i++ {
		p[i] = 'x'
	}
	return f.n, f.err
}

func TestReadFirst(t *testing.T) {
	boom := errors.New("boom")
	cases := []struct {
		name    string
		r       io.Reader
		size    int64
		want    string
		wantErr error
	}{
		{"a read error with nothing read is an error", fakeRead{0, boom}, 4, "", boom},
		{"a read error after some bytes is ignored", fakeRead{3, boom}, 4, "xxx", nil},
		{"an EOF with nothing read is an empty read", fakeRead{0, io.EOF}, 4, "", nil},
		{"a clean read", fakeRead{3, nil}, 4, "xxx", nil},
		{"the buffer holds one byte more than the file", strings.NewReader("abcdef"), 3, "abcd", nil},
		{"an empty size still reads a byte", strings.NewReader("abc"), 0, "a", nil},
		{"an error reader", iotest.ErrReader(boom), 2, "", boom},
	}
	for _, c := range cases {
		got, err := readFirst(c.r, c.size)
		if !errors.Is(err, c.wantErr) || string(got) != c.want {
			t.Errorf("%s: got (%q, %v), want (%q, %v)", c.name, got, err, c.want, c.wantErr)
		}
	}
}


// jsonStr builds a JSON string literal from escapes and plain text: the part "u:d83d" is the escape for U+D83D.
func jsonStr(parts ...string) string {
	return `"` + jsonStrBody(parts...) + `"`
}

func jsonStrBody(parts ...string) string {
	var b strings.Builder
	for _, p := range parts {
		if h, ok := strings.CutPrefix(p, "u:"); ok {
			b.WriteString(string(rune(92)) + "u" + h)
		} else {
			b.WriteString(p)
		}
	}
	return b.String()
}

func TestSurrogateEscapeBoundaries(t *testing.T) {
	decodes := []struct {
		doc  string
		want rune
		tail string
	}{
		{jsonStr("u:d7ff"), 0xd7ff, ""}, // the last code point below the surrogates
		{jsonStr("u:e000"), 0xe000, ""}, // the first one above them
		{jsonStr("u:d83d", "u:de00"), 0x1f600, ""},
		{jsonStr("u:dbff", "u:dfff"), 0x10ffff, ""}, // the highest pair
		{jsonStr("u:d800", "u:dc00"), 0x10000, ""},  // the lowest pair
		{jsonStr("u:D83D", "u:DE00", "x"), 0x1f600, "x"},
		{jsonStr("u:d83d", "u:dfff"), 0x1f7ff, ""},
		{jsonStr("u:dbff", "u:dc00"), 0x10fc00, ""},
	}
	for _, c := range decodes {
		v, err := decodePyJSON([]byte(c.doc))
		if err != nil || v != string(c.want)+c.tail {
			t.Errorf("%s: got (%#v, %v), want %q", c.doc, v, err, string(c.want)+c.tail)
		}
	}
	// Lone surrogates: Python holds them, this port refuses them (documented).
	for _, parts := range [][]string{{"u:d800"}, {"u:dbff"}, {"u:dc00"}, {"u:dfff"}, {"u:d800", "u:d800"}, {"u:dbff", "u:dbff"},
		{"u:d800", "u:e000"}, {"u:d83d", "u:de00", "u:d83d"}, {"u:d83d", "u:0041"}, {"u:d83d", "x"}, {"u:de00", "u:d83d"}} {
		doc := jsonStr(parts...)
		if _, err := decodePyJSON([]byte(doc)); !errors.Is(err, errUnsupportedText) {
			t.Errorf("%s: want errUnsupportedText (a lone surrogate), got %v", doc, err)
		}
	}
	// A pair cut off by the end of the document is the invalid escape Python reports.
	const invalid = "Invalid " + `\` + "uXXXX escape: line 1 column "
	truncated := []struct {
		doc  string
		want string
	}{
		{`"` + jsonStrBody("u:d83d", "u:de00"), invalid + "9 (char 8)"},
		{`"` + jsonStrBody("u:d83d", "u:00"), invalid + "9 (char 8)"},
		{`"` + jsonStrBody("u:d83d"), invalid + "3 (char 2)"},
	}
	for _, c := range truncated {
		_, err := decodePyJSON([]byte(c.doc))
		var je *jsonError
		if !asJSONError(err, &je) || je.Error() != c.want {
			t.Errorf("%s: got %v, want %q", c.doc, err, c.want)
		}
	}
}

func TestErrorPositionCountsLinesUpToTheDocumentEnd(t *testing.T) {
	cases := map[string]string{
		"{\n\n  \"a\" 1}": "Expecting ':' delimiter: line 3 column 7 (char 9)",
		"[1,\n2,\n":       "Expecting value: line 3 column 1 (char 7)",
		"\n":              "Expecting value: line 2 column 1 (char 1)",
		"[\n":             "Expecting value: line 2 column 1 (char 2)",
	}
	for doc, want := range cases {
		_, err := decodePyJSON([]byte(doc))
		var je *jsonError
		if !asJSONError(err, &je) || je.Error() != want {
			t.Errorf("%q: got %v, want %q", doc, err, want)
		}
	}
}

func TestClampIntSignsOfHugeNumbers(t *testing.T) {
	huge := "1" + strings.Repeat("0", 40)
	if got := clampInt(huge); got != 1<<63-1 {
		t.Errorf("clampInt(+huge) = %d, want MaxInt64", got)
	}
	if got := clampInt("-" + huge); got != -1<<63 {
		t.Errorf("clampInt(-huge) = %d, want MinInt64", got)
	}
	if got := clampInt("0"); got != 0 {
		t.Errorf("clampInt(0) = %d, want 0", got)
	}
}

func TestInventoryEqualOffsetsKeepTheirOrder(t *testing.T) {
	// Python sorts by (offset, value) and the sort is stable: entries equal on both keep their input order, so
	// the encoding of the first one wins the first slot. 1 and 1.0 are the same offset.
	doc := `{"strings":{"static_strings":[` +
		`{"string":"same","offset":1,"encoding":"first"},` +
		`{"string":"same","offset":1.0,"encoding":"second"},` +
		`{"string":"same","offset":1,"encoding":"third"}]}}`
	inv, _, err := buildInventory(decode(t, doc), caps(10, 10))
	if err != nil {
		t.Fatal(err)
	}
	var got []any
	for _, s := range strs(cat(t, inv, "static_strings")) {
		got = append(got, s["encoding"])
	}
	if len(got) != 3 || got[0] != "first" || got[1] != "second" || got[2] != "third" {
		t.Errorf("equal entries reordered: %v", got)
	}
}

func TestInventoryValueLengthCapIsInclusive(t *testing.T) {
	doc := `{"strings":{"static_strings":[{"string":"abcd","offset":1},{"string":"abcde","offset":2}]}}`
	inv, lims, err := buildInventory(decode(t, doc), caps(10, 4))
	if err != nil {
		t.Fatal(err)
	}
	got := strs(cat(t, inv, "static_strings"))
	if got[0]["value"] != "abcd" || got[1]["value"] != "abcd" {
		t.Errorf("values = %v, %v; want abcd (exactly at the cap, kept) and abcd (one over, cut)", got[0]["value"], got[1]["value"])
	}
	if got[1]["sha256"] != digest("abcd") {
		t.Errorf("the digest must cover the cut value, got %v", got[1]["sha256"])
	}
	if len(lims) != 1 {
		t.Errorf("limitations = %v, want one (the over-long value)", lims)
	}
	// Exactly at the cap: nothing is cut, so no limitation.
	inv, lims, err = buildInventory(decode(t, `{"strings":{"static_strings":[{"string":"abcd","offset":1}]}}`), caps(10, 4))
	if err != nil || len(lims) != 0 || strs(cat(t, inv, "static_strings"))[0]["value"] != "abcd" {
		t.Errorf("a value exactly at the cap: got %v, %v, %v", inv, lims, err)
	}
}
