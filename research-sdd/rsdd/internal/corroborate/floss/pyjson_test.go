package floss

import (
	"encoding/json"
	"math"
	"reflect"
	"testing"
)

// Messages are what Python 3.12's json.loads(bytes) raises; the oracle test in parity_linux_test.go re-derives
// them from the real interpreter on a random corpus.
func TestDecodePyJSONErrorsMatchPython(t *testing.T) {
	cases := []struct{ in, want string }{
		{"not json at all {{{{", "Expecting value: line 1 column 1 (char 0)"},
		{"   ", "Expecting value: line 1 column 4 (char 3)"},
		{"{", "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)"},
		{"[", "Expecting value: line 1 column 2 (char 1)"},
		{`{"a"`, "Expecting ':' delimiter: line 1 column 5 (char 4)"},
		{`{"a":`, "Expecting value: line 1 column 6 (char 5)"},
		{`{"a":1`, "Expecting ',' delimiter: line 1 column 7 (char 6)"},
		{`{"a":1,`, "Expecting property name enclosed in double quotes: line 1 column 8 (char 7)"},
		{`{"a":1 "b"`, "Expecting ',' delimiter: line 1 column 8 (char 7)"},
		{`{a:1}`, "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)"},
		{`[1,]`, "Expecting value: line 1 column 4 (char 3)"},
		{`[1 2]`, "Expecting ',' delimiter: line 1 column 4 (char 3)"},
		{`{"a":1}x`, "Extra data: line 1 column 8 (char 7)"},
		{`01`, "Extra data: line 1 column 2 (char 1)"},
		{`-`, "Expecting value: line 1 column 1 (char 0)"},
		{`"abc`, "Unterminated string starting at: line 1 column 1 (char 0)"},
		{`"a\qb"`, "Invalid \\escape: line 1 column 3 (char 2)"},
		{`"a\u12"`, "Invalid \\uXXXX escape: line 1 column 4 (char 3)"},
		{`"a\u12zz"`, "Invalid \\uXXXX escape: line 1 column 4 (char 3)"},
		{"\"a\tb\"", "Invalid control character at: line 1 column 3 (char 2)"},
		{"\n\n  {\"a\": tru}", "Expecting value: line 3 column 9 (char 10)"},
		{"{\"a\":\n[1,\n 2,, 3]}", "Expecting value: line 3 column 4 (char 13)"},
		{`1.`, "Extra data: line 1 column 2 (char 1)"},
		{"\xef\xbb\xbf\xef\xbb\xbf{}", "Expecting value: line 1 column 1 (char 0)"},
		{"{\"k\": \"\u00e9\U0001F600\" , \"b\": }", "Expecting value: line 1 column 19 (char 18)"},
		{"[\"\u00e9\", x]", "Expecting value: line 1 column 7 (char 6)"},
		{`"abc\`, "Unterminated string starting at: line 1 column 1 (char 0)"},
		{`"\u`, "Invalid \\uXXXX escape: line 1 column 3 (char 2)"},
		{`"\u0041"x`, "Extra data: line 1 column 9 (char 8)"},
		{`{"a" 1}`, "Expecting ':' delimiter: line 1 column 6 (char 5)"},
		{`{,}`, "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)"},
		{`{"a":1,}`, "Expecting property name enclosed in double quotes: line 1 column 8 (char 7)"},
		{`tru`, "Expecting value: line 1 column 1 (char 0)"},
		{`[1,2`, "Expecting ',' delimiter: line 1 column 5 (char 4)"},
	}
	for _, c := range cases {
		v, err := decodePyJSON([]byte(c.in))
		var je *jsonError
		if err == nil || !asJSONError(err, &je) || je.Error() != c.want {
			t.Errorf("%q: got (%v, %v), want JSONDecodeError %q", c.in, v, err, c.want)
		}
	}
}

func asJSONError(err error, target **jsonError) bool {
	je, ok := err.(*jsonError)
	if ok {
		*target = je
	}
	return ok
}

func TestDecodePyJSONValues(t *testing.T) {
	cases := []struct {
		in   string
		want any
	}{
		{`{}`, map[string]any{}},
		{" \t\r\n[1, 2.5, -0, 1e2, \"x\", true, false, null]\n", []any{json.Number("1"), json.Number("2.5"), json.Number("-0"), json.Number("1e2"), "x", true, false, nil}},
		{`{"a":{"b":[]},"a":1}`, map[string]any{"a": json.Number("1")}}, // the last duplicate key wins
		{`"\u00e9\ud83d\ude00\n\/"`, "\u00e9\U0001F600\n/"},
		{"\xef\xbb\xbf{\"k\":\"v\"}", map[string]any{"k": "v"}}, // one UTF-8 BOM is skipped (utf-8-sig)
		{`[Infinity,-Infinity]`, []any{math.Inf(1), math.Inf(-1)}},
	}
	for _, c := range cases {
		got, err := decodePyJSON([]byte(c.in))
		if err != nil || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%q: got (%#v, %v), want %#v", c.in, got, err, c.want)
		}
	}
	nan, err := decodePyJSON([]byte(`NaN`))
	if f, ok := nan.(float64); err != nil || !ok || !math.IsNaN(f) {
		t.Errorf("NaN: got (%#v, %v)", nan, err)
	}
}

func TestDecodePyJSONRefusesWhatPythonWouldDecodeDifferently(t *testing.T) {
	// Invalid UTF-8, UTF-16 and UTF-32 payloads and lone surrogates are not JSONDecodeError in Python (the legacy
	// script crashes with a traceback); the port refuses them with a typed error of its own.
	for _, in := range []string{"{\"a\":\"\xff\"}", "\xff\xfe{\x00}\x00", "\x00{\x00}\x00", "\"\\ud800\""} {
		_, err := decodePyJSON([]byte(in))
		var je *jsonError
		if err == nil || asJSONError(err, &je) {
			t.Errorf("%q: want a non-JSONDecodeError refusal, got %v", in, err)
		}
	}
}
