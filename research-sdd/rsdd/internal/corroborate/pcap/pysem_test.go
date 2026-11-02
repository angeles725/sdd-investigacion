package pcap

import (
	"math"
	"math/big"
	"strings"
	"testing"
	"time"
)

// Each expected value below is what CPython 3.12 answers for the same input.

func TestPyReprQuotesAndEscapes(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"plain", `'plain'`},
		{"it's", `"it's"`},
		{`say "hi"`, `'say "hi"'`},
		{`it's "x"`, `'it\'s "x"'`},
		{`back\slash`, `'back\\slash'`},
		{"a\nb\rc\td", `'a\nb\rc\td'`},
		{"\x01\x1f\x7f", `'\x01\x1f\x7f'`},
		{"café", "'café'"},
		{"\U00000085\U000000a0", `'\x85\xa0'`},
		{"\U0000200b\U00003000\U0000e000", `'\` + `u200b\` + `u3000\` + `ue000'`},
		{"\U0001f600", "'\U0001f600'"},
		{"\U000e0001\U0010ffff", `'\U000e0001\U0010ffff'`},
		{"bad\xffbyte", `'bad\udcffbyte'`},
		{"", `''`},
	} {
		if got := pyRepr(c.in); got != c.want {
			t.Errorf("pyRepr(%q) = %s, want %s", c.in, got, c.want)
		}
	}
}

func TestPyListRepr(t *testing.T) {
	if got := pyListRepr([]string{"a", "b'", ""}); got != `['a', "b'", '']` {
		t.Errorf("got %s", got)
	}
	if got := pyListRepr(nil); got != "[]" {
		t.Errorf("empty list = %s", got)
	}
}

func TestDecodeReplaceMaximalSubparts(t *testing.T) {
	const r = "�"
	for _, c := range []struct {
		in   []byte
		want string
	}{
		{[]byte("plain é"), "plain é"},
		{[]byte{'a', 0xff, 'b'}, "a" + r + "b"},
		{[]byte{0x80}, r},
		{[]byte{0xc0, 0xaf}, r + r},
		{[]byte{0xc1, 0x80}, r + r},
		{[]byte{0xc2}, r},
		{[]byte{0xc2, 'A'}, r + "A"},
		{[]byte{0xe0, 0x80}, r + r},
		{[]byte{0xe0, 0xa0}, r},
		{[]byte{0xe0, 0xa0, 'A'}, r + "A"},
		{[]byte{0xe1, 0x80, 'A'}, r + "A"},
		{[]byte{0xe1}, r},
		{[]byte{0xed, 0xa0, 0x80}, r + r + r},
		{[]byte{0xed, 0x9f}, r},
		{[]byte{0xee, 0x80}, r},
		{[]byte{0xef, 0x80, 'A'}, r + "A"},
		{[]byte{0xf0, 0x80}, r + r},
		{[]byte{0xf0, 0x90}, r},
		{[]byte{0xf0, 0x90, 0x80}, r},
		{[]byte{0xf1, 0x80, 0x80, 'A'}, r + "A"},
		{[]byte{0xf3, 0x80}, r},
		{[]byte{0xf4, 0x90}, r + r},
		{[]byte{0xf4, 0x8f, 0xbf}, r},
		{[]byte{0xf5}, r},
		{[]byte{0xf5, 0x80}, r + r},
		{[]byte{'x', 0xe2, 0x82, 'y', 0xff}, "x" + r + "y" + r},
	} {
		if got := decodeReplace(c.in); got != c.want {
			t.Errorf("decodeReplace(% x) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestIllFormedLenIsAtLeastOne(t *testing.T) {
	for _, c := range []struct {
		in   []byte
		want int
	}{
		{[]byte{0xff}, 1}, {[]byte{0x80, 0x80}, 1}, {[]byte{0xe0, 0xa0, 0x80, 0x41}, 3}, {[]byte{0xe0, 0xa0, 0x41}, 2},
		{[]byte{0xf0, 0x90, 0x80, 0x80}, 4}, {[]byte{0xc2, 0x80}, 2},
	} {
		if got := illFormedLen(c.in); got != c.want {
			t.Errorf("illFormedLen(% x) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestParseFloatLikePythonFloat(t *testing.T) {
	for _, c := range []struct {
		in   string
		want float64
		ok   bool
	}{
		{"1.5", 1.5, true}, {".5", .5, true}, {"5.", 5, true}, {"-2e3", -2000, true}, {"1_0.5_5", 10.55, true}, {"+7", 7, true},
		{"inf", math.Inf(1), true}, {"+INF", math.Inf(1), true}, {"-Infinity", math.Inf(-1), true},
		{"1e400", math.Inf(1), true}, {"-1e400", math.Inf(-1), true},
		{"1e", 0, false}, {"1__0", 0, false}, {"_1", 0, false}, {"1_", 0, false}, {"abc", 0, false}, {"", 0, false}, {"infx", 0, false}, {"1.5.5", 0, false},
	} {
		got, ok := parseFloat(c.in)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("parseFloat(%q) = %v, %v; want %v, %v", c.in, got, ok, c.want, c.ok)
		}
	}
	for _, in := range []string{"nan", "-NaN", "+nan"} {
		if got, ok := parseFloat(in); !ok || !math.IsNaN(got) {
			t.Errorf("parseFloat(%q) = %v, %v; want NaN", in, got, ok)
		}
	}
}

func TestParseIntLikePythonInt(t *testing.T) {
	for _, c := range []struct {
		in   string
		want string
		ok   bool
	}{
		{"42", "42", true}, {"+1_000", "1000", true}, {"-0", "0", true}, {"007", "7", true},
		{"99999999999999999999999", "99999999999999999999999", true},
		{"", "", false}, {"1__0", "", false}, {"_1", "", false}, {"1_", "", false}, {"+", "", false}, {"1.0", "", false}, {"0x10", "", false},
	} {
		got, ok := parseInt(c.in)
		if ok != c.ok || (ok && got.String() != c.want) {
			t.Errorf("parseInt(%q) = %v, %v; want %s, %v", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestAsciiDigitsAndNumber(t *testing.T) {
	for in, want := range map[string]bool{"": false, "0": true, "007": true, "12a": false, "a12": false, "٣": false, "1 2": false, "/": false, ":": false} {
		if got := asciiDigits(in); got != want {
			t.Errorf("asciiDigits(%q) = %v, want %v", in, got, want)
		}
	}
	for in, want := range map[string]string{"0": "0", "007": "7", "10": "10", "00000000000000000000001": "1"} {
		if got := string(number(in)); got != want {
			t.Errorf("number(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestFromHexAndIsHexDigits(t *testing.T) {
	for _, c := range []struct {
		in   string
		want string
		ok   bool
	}{
		{"4142", "AB", true}, {"41 42\t\n\r\v\f", "AB", true}, {"aBcD", "\xab\xcd", true}, {"", "", true}, {"  ", "", true},
		{"4", "", false}, {"41 4", "", false}, {"4g", "", false}, {"g4", "", false}, {"4 1", "", false}, {"é4", "", false},
		{"0/", "", false}, {"0:", "", false}, {"0@", "", false}, {"0`", "", false}, {"0G", "", false}, {"0g", "", false},
	} {
		got, ok := fromHex(c.in)
		if ok != c.ok || (ok && string(got) != c.want) {
			t.Errorf("fromHex(%q) = %q, %v; want %q, %v", c.in, got, ok, c.want, c.ok)
		}
	}
	for in, want := range map[string]bool{"": false, "0123456789abcdefABCDEF": true, "g": false, "12 3": false, "/": false, ":": false, "@": false, "`": false, "G": false, "F": true, "f": true, "9": true, "0": true, "A": true, "a": true} {
		if got := isHexDigits(in); got != want {
			t.Errorf("isHexDigits(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestIsoZ(t *testing.T) {
	base := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		t    time.Time
		want string
	}{
		{base, "2026-11-02T12:00:00Z"},
		{base.Add(500 * time.Nanosecond), "2026-11-02T12:00:00Z"}, // below a microsecond: no fraction, as isoformat()
		{base.Add(1 * time.Microsecond), "2026-11-02T12:00:00.000001Z"},
		{base.Add(123456 * time.Microsecond), "2026-11-02T12:00:00.123456Z"},
		{base.In(time.FixedZone("x", 3600)), "2026-11-02T12:00:00Z"},
	} {
		if got := isoZ(c.t); got != c.want {
			t.Errorf("isoZ(%v) = %s, want %s", c.t, got, c.want)
		}
	}
}

func TestFirstNFollowsPythonSlices(t *testing.T) {
	ids := streamIDsOf(0, 1, 2, 3, 4)
	for _, c := range []struct {
		n    string
		want string
	}{
		{"0", ""}, {"1", "0"}, {"3", "0,1,2"}, {"5", "0,1,2,3,4"}, {"6", "0,1,2,3,4"}, {"99999999999999999999", "0,1,2,3,4"},
		{"-1", "0,1,2,3"}, {"-4", "0"}, {"-5", ""}, {"-6", ""}, {"-99999999999999999999", ""},
	} {
		var got []string
		for _, id := range firstN(ids, bigOf(t, c.n)) {
			got = append(got, id.String())
		}
		if strings.Join(got, ",") != c.want {
			t.Errorf("firstN(5 ids, %s) = %v, want %s", c.n, got, c.want)
		}
	}
}

func TestParseConversationsOrdersTiesByTheSecondEndpoint(t *testing.T) {
	text := "================\nTCP Conversations\n" +
		"10.0.0.1:1 <-> 10.0.0.9:9   1 2 3 4 5 6\n" +
		"10.0.0.1:1 <-> 10.0.0.3:3   1 2 3 4 5 6\n" +
		"10.0.0.1:1 <-> 10.0.0.5:5   1 2 3 4 5 6\n"
	var got []string
	for _, c := range parseConversations(text, "tcp") {
		got = append(got, c.EndpointB)
	}
	if strings.Join(got, " ") != "10.0.0.3:3 10.0.0.5:5 10.0.0.9:9" {
		t.Errorf("order = %v", got)
	}
}

func streamIDsOf(ns ...int64) []*big.Int {
	out := make([]*big.Int, len(ns))
	for i, n := range ns {
		out[i] = big.NewInt(n)
	}
	return out
}

func bigOf(t *testing.T, s string) *big.Int {
	t.Helper()
	n, ok := new(big.Int).SetString(s, 10)
	if !ok {
		t.Fatalf("bad integer %q", s)
	}
	return n
}
