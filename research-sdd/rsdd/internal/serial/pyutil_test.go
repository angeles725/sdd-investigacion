package serial

import (
	"reflect"
	"syscall"
	"testing"
	"unicode"
)

func TestPyRepr(t *testing.T) {
	for in, want := range map[string]string{
		`/tmp/a b`:       `'/tmp/a b'`,
		`it's`:           `"it's"`,
		`say "hi" it's`:  `'say "hi" it\'s'`,
		"tab\there":      `'tab\there'`,
		"nl\n":           `'nl\n'`,
		"cr\r":           `'cr\r'`,
		`back\slash`:     `'back\\slash'`,
		"\x01":           `'\x01'`,
		"\x7f":           `'\x7f'`,
		"café":           "'café'",
		"\x80":           `'\udc80'`,
		"\u00a0":         `'\xa0'`,
		"zero\u200bwith": "'zero\\u200bwith'",
		"\U000e0001":     `'\U000e0001'`,
		"�":              "'�'",
	} {
		if got := pyRepr(in); got != want {
			t.Errorf("pyRepr(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestOSErrorText(t *testing.T) {
	for _, tc := range []struct {
		en   syscall.Errno
		name string
		want string
	}{
		{syscall.EEXIST, "/x", "[Errno 17] File exists: '/x'"},
		{syscall.ENOENT, "", "[Errno 2] No such file or directory"},
		{syscall.ENOTTY, "it's", `[Errno 25] Inappropriate ioctl for device: "it's"`},
	} {
		if got := osErrorText(tc.en, tc.name); got != tc.want {
			t.Errorf("got %q, want %q", got, tc.want)
		}
	}
	if en, ok := errnoOf(&unwrapper{syscall.EACCES}); !ok || en != syscall.EACCES {
		t.Errorf("errnoOf through a wrapper = %v %v", en, ok)
	}
	if _, ok := errnoOf(nil); ok {
		t.Error("errnoOf(nil) found an errno")
	}
}

type unwrapper struct{ en syscall.Errno }

func (u *unwrapper) Error() string { return "wrapped" }
func (u *unwrapper) Unwrap() error { return u.en }

func TestPySplitLines(t *testing.T) {
	for in, want := range map[string][]string{
		"":                         nil,
		"a":                        {"a"},
		"a\n":                      {"a"},
		"\n":                       {""},
		"a\nb":                     {"a", "b"},
		"a\r\nb\rc":                {"a", "b", "c"},
		"a\r\n\r\nb":               {"a", "", "b"},
		"a\vb\fc\x1cd\x1de\x1ef":   {"a", "b", "c", "d", "e", "f"},
		"a\u0085b\u2028c\u2029d":   {"a", "b", "c", "d"},
		"a\x1fb":                   {"a\x1fb"},
		"a\n\n  ":                  {"a", "", "  "},
		"x\u200by":                 {"x\u200by"},
		"tail\r":                   {"tail"},
		"\r\n":                     {""},
		"a\xe2\x82\nb":             {"a\xe2\x82", "b"},
		"one\u2028":                {"one"},
		"\u2028\u2028":             {"", ""},
		"a\rb\n\rc":                {"a", "b", "", "c"},
		"keep\ttab and \u00a0nbsp": {"keep\ttab and \u00a0nbsp"},
	} {
		if got := pySplitLines(in); !reflect.DeepEqual(got, want) {
			t.Errorf("pySplitLines(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPyStrip(t *testing.T) {
	for in, want := range map[string]string{
		"  a  ":                         "a",
		"\t\n\v\f\r a \x1c\x1d\x1e\x1f": "a",
		"\u00a0\u2003a\u3000":           "a",
		"\u0085a\u2028":                 "a",
		"a b":                           "a b",
		"":                              "",
		"\u200ba\u200b":                 "\u200ba\u200b",
	} {
		if got := pyStrip(in); got != want {
			t.Errorf("pyStrip(%q) = %q, want %q", in, got, want)
		}
	}
	for r := rune(0); r <= 0x40; r++ {
		want := r == ' ' || (r >= 9 && r <= 13) || (r >= 0x1c && r <= 0x1f)
		if isPySpace(r) != want {
			t.Errorf("isPySpace(%U) = %v", r, !want)
		}
	}
}

func TestPyDecodeReplace(t *testing.T) {
	for _, tc := range []struct {
		in, want string
	}{
		{"plain", "plain"},
		{"caf\xc3\xa9", "café"},
		{"\xe2\x82", "�"},       // truncated 3-byte sequence: one replacement
		{"\xe2\x82x", "�x"},     // ... then the next character survives
		{"\x80", "�"},           // lone continuation byte
		{"\xc0\xaf", "��"},      // overlong lead is never valid
		{"\xed\xa0\x80", "���"}, // surrogate
		{"\xf0\x90\x80", "�"},   // truncated 4-byte
		{"\xf0\x90\x80x", "�x"},
		{"\xf4\x90\x80\x80", "����"}, // above U+10FFFF
		{"\xe0\x80\x80", "���"},      // overlong 3-byte
		{"\xc2", "�"},
		{"\xc2x", "�x"},
		{"\xff\xfe", "��"},
		{"\xef\xbf\xbd", "�"}, // a real U+FFFD stays one
		{"\xf0\x9f\x98\x80", "\U0001f600"},
		{"\xe1\x80", "�"},
		{"\xe1\x80\x41", "�A"},
		{"\xf1\x80\x80", "�"},
		{"\xf1\x80\x80\x41", "�A"},
		{"\xed\x9f\xbf", "퟿"},
		{"\xf4\x8f\xbf\xbf", "\U0010ffff"},
		{"\xf0\x8f\x80\x80", "����"},
	} {
		if got := pyDecodeReplace([]byte(tc.in)); got != tc.want {
			t.Errorf("pyDecodeReplace(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestDigits(t *testing.T) {
	for in, want := range map[string]string{
		"0": "0", "000": "0", "007": "7", "42": "42", "٣": "3", "٠٠٣": "3",
		"۱۰": "10", "９": "9", "\U0001d7d8\U0001d7d9": "1", "\U0001d7ff": "9",
		"99999999999999999999": "99999999999999999999",
	} {
		if got := decimalString(in); got != want {
			t.Errorf("decimalString(%q) = %q, want %q", in, got, want)
		}
	}
	for _, r := range []rune{'0', '5', '9', 0x0660, 0x0669, 0x1d7ce, 0x1d7ff} {
		if !unicode.Is(unicode.Nd, r) {
			t.Fatalf("%U is not Nd", r)
		}
	}
}

func TestPyParseInt(t *testing.T) {
	for in, want := range map[string]string{
		"19200": "19200", " 7 ": "7", "+5": "5", "-5": "-5", "1_000": "1000", "007": "7",
		"123456789012345678901234567890": "123456789012345678901234567890",
	} {
		v, ok := pyParseInt(in)
		if !ok || v.String() != want {
			t.Errorf("pyParseInt(%q) = %v %v, want %s", in, v, ok, want)
		}
	}
	for _, in := range []string{"", "x", "1.5", "1__0", "_1", "1_", "0x10", "--1", "1e3", "- 1", " "} {
		if _, ok := pyParseInt(in); ok {
			t.Errorf("pyParseInt(%q) accepted", in)
		}
	}
}

func TestPyParseFloat(t *testing.T) {
	for in, want := range map[string]float64{
		"4": 4, "4.0": 4, ".5": 0.5, "5.": 5, "-1.5": -1.5, "+2": 2, "1e3": 1000, "1E-2": 0.01, "1_0.5": 10.5,
		" 3 ": 3, "0": 0, "1.5e+2": 150,
	} {
		v, ok := pyParseFloat(in)
		if !ok || v != want {
			t.Errorf("pyParseFloat(%q) = %v %v, want %v", in, v, ok, want)
		}
	}
	for _, in := range []string{"", ".", "x", "inf", "-inf", "nan", "Infinity", "1e999", "0x1p3", "1__0", "e5", "1e", "1.2.3", "--1"} {
		if _, ok := pyParseFloat(in); ok {
			t.Errorf("pyParseFloat(%q) accepted", in)
		}
	}
}

func TestRoundDigits(t *testing.T) {
	for _, tc := range []struct {
		x    float64
		nd   int
		want float64
	}{
		{2.0 / 3.0, 4, 0.6667}, {1.0 / 3.0, 4, 0.3333}, {0.12345, 4, 0.1235}, {0.00015, 4, 0.0001}, {0.5, 0, 0}, {1.5, 0, 2}, {2.5, 0, 2},
		{0.0000123456789, 6, 0.000012}, {1.0000005, 6, 1.000001}, {1, 4, 1},
	} {
		if got := roundDigits(tc.x, tc.nd); got != tc.want {
			t.Errorf("roundDigits(%v, %d) = %v, want %v", tc.x, tc.nd, got, tc.want)
		}
	}
}
