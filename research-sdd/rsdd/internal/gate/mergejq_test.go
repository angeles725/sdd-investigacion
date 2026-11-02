package gate

import (
	"encoding/json"
	"math"
	"testing"
)

// Unit tests of the jq emulation (mergejq.go) and of the awk helpers the path-filter scanner relies on.
// Expected values are what jq 1.8 prints for the same input.

func raw(s string) json.RawMessage { return json.RawMessage(s) }

func TestJQType(t *testing.T) {
	for in, want := range map[string]string{
		"": "null", "null": "null", "true": "boolean", "false": "boolean", `"x"`: "string", "5": "number", "-1.5": "number",
		"[1]": "array", `{"a":1}`: "object", "  [1]": "array",
	} {
		if got := jqType(raw(in)); got != want {
			t.Errorf("jqType(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestJQIndexAndPath(t *testing.T) {
	obj := raw(`{"a":{"b":[1,2]},"n":null,"s":"x"}`)
	if v, ok := jqIndex(obj, "s"); !ok || string(v) != `"x"` {
		t.Errorf("object field: %s %v", v, ok)
	}
	if v, ok := jqIndex(obj, "missing"); !ok || string(v) != "null" {
		t.Errorf("absent key must be null: %s %v", v, ok)
	}
	if v, ok := jqIndex(raw("null"), "a"); !ok || string(v) != "null" {
		t.Errorf("null input must index to null: %s %v", v, ok)
	}
	for _, bad := range []string{"5", `"x"`, "[1]", "true"} {
		if _, ok := jqIndex(raw(bad), "a"); ok {
			t.Errorf("indexing %s must be a jq error", bad)
		}
	}
	if v, ok := jqPath(obj, "a", "b"); !ok || string(v) != "[1,2]" {
		t.Errorf("path: %s %v", v, ok)
	}
	if _, ok := jqPath(obj, "s", "x"); ok {
		t.Error("a string cannot be indexed: the path must fail")
	}
	if v, ok := jqPath(obj, "n", "x", "y"); !ok || string(v) != "null" {
		t.Errorf("null propagates through a path: %s %v", v, ok)
	}
}

func TestJQScalars(t *testing.T) {
	if !jqAbsent(raw("null")) || !jqAbsent(raw(" false ")) || jqAbsent(raw("true")) || jqAbsent(raw("0")) || jqAbsent(raw(`""`)) {
		t.Error("jqAbsent: only null and false are replaced by `//`")
	}
	if s, ok := jqString(raw(`"aé\n"`)); !ok || s != "aé\n" {
		t.Errorf("jqString = %q %v", s, ok)
	}
	if _, ok := jqString(raw("5")); ok {
		t.Error("a number is not a string")
	}
	if _, ok := jqString(raw(`"\q"`)); ok {
		t.Error("an invalid escape must not decode")
	}
	if f, ok := jqNumber(raw(" 12.5 ")); !ok || f != 12.5 {
		t.Errorf("jqNumber = %v %v", f, ok)
	}
	if _, ok := jqNumber(raw(`"5"`)); ok {
		t.Error("a string is not a number")
	}
	if got := jqRaw(raw(`"x y"`)); got != "x y" {
		t.Errorf("jqRaw string = %q", got)
	}
	if got := jqRaw(raw(" 7 ")); got != "7" {
		t.Errorf("jqRaw number = %q", got)
	}
	if got := jqRaw(raw(`{"a":[1,2]}`)); got != "{\n  \"a\": [\n    1,\n    2\n  ]\n}" {
		t.Errorf("jqRaw object = %q", got)
	}
	if got := jqRaw(raw("[]")); got != "[]" {
		t.Errorf("jqRaw empty array = %q", got)
	}
	if got := jqToString(raw(`{"a": [1, 2]}`)); got != `{"a":[1,2]}` {
		t.Errorf("jqToString = %q", got)
	}
	if got := jqToString(raw(`"s"`)); got != "s" {
		t.Errorf("jqToString string = %q", got)
	}
}

func TestJQEachAndOptKey(t *testing.T) {
	vals, ok := jqStream(`{"a":"x"} 5 {"a":null} {"a":false} {"a":"y"} {"a":["z"]}`)
	if !ok || len(vals) != 6 {
		t.Fatalf("stream: %d values ok=%v", len(vals), ok)
	}
	// 5 raises "cannot index number" and contributes nothing; null and false are absent
	if got := jqEach(vals, jqOptKey("a")); got != "x\ny\n[\n  \"z\"\n]" {
		t.Errorf("jqEach = %q", got)
	}
	if got := jqEach(nil, jqOptKey("a")); got != "" {
		t.Errorf("empty stream = %q", got)
	}
}

func TestJQStream(t *testing.T) {
	if v, ok := jqStream("\xef\xbb\xbf{\"a\":1}"); !ok || len(v) != 1 {
		t.Errorf("a leading BOM is skipped: %d %v", len(v), ok)
	}
	if v, ok := jqStream("{\"a\":1}\x00 {\"b\":2}"); !ok || len(v) != 2 {
		t.Errorf("NULs are dropped: %d %v", len(v), ok)
	}
	if v, ok := jqStream("{\"a\":1} garbage"); ok || len(v) != 1 {
		t.Errorf("values before a parse error are kept and ok is false: %d %v", len(v), ok)
	}
	if v, ok := jqSlurp(""); !ok || len(v) != 0 {
		t.Errorf("empty input slurps to no values: %d %v", len(v), ok)
	}
}

func TestJQOrder(t *testing.T) {
	ordered := []string{
		"null", "false", "true", "-3", "0", "2.5", `""`, `"a"`, `"b"`, "[]", "[1]", "[1,2]", "[2]", "{}", `{"a":1}`, `{"a":2}`, `{"a":1,"b":0}`, `{"b":0}`,
	}
	for i := range ordered {
		for j := range ordered {
			want := cmpInt(i, j)
			if got := jqCmp(raw(ordered[i]), raw(ordered[j])); got != want {
				t.Errorf("jqCmp(%s, %s) = %d, want %d", ordered[i], ordered[j], got, want)
			}
		}
	}
	if jqCmp(raw("1"), raw("1.0")) != 0 || jqCmp(raw(`{"a":1,"b":2}`), raw(`{"b":2,"a":1}`)) != 0 {
		t.Error("equal values must compare equal (number spelling and key order do not matter)")
	}
}

func TestCmpHelpers(t *testing.T) {
	nan := math.NaN()
	for _, c := range []struct {
		a, b float64
		want int
	}{{1, 2, -1}, {2, 1, 1}, {1, 1, 0}, {nan, 1, -1}, {1, nan, 1}, {nan, nan, 0}, {math.Inf(-1), 0, -1}} {
		if got := cmpFloat(c.a, c.b); got != c.want {
			t.Errorf("cmpFloat(%v, %v) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
	if cmpInt(1, 2) != -1 || cmpInt(2, 1) != 1 || cmpInt(3, 3) != 0 {
		t.Error("cmpInt")
	}
	got := sortedKeys(map[string]json.RawMessage{"b": nil, "a": nil, "c": nil})
	if len(got) != 3 || got[0] != "a" || got[1] != "b" || got[2] != "c" {
		t.Errorf("sortedKeys = %v", got)
	}
}

func TestAwkVar(t *testing.T) {
	for in, want := range map[string]string{
		`plain`: `plain`, `a\nb`: "a\nb", `a\tb`: "a\tb", `a\rb`: "a\rb", `a\ab`: "a\ab", `a\bb`: "a\bb", `a\fb`: "a\fb", `a\vb`: "a\vb",
		`a\\b`: `a\b`, `a\qb`: `aqb`, `a\/b`: `a/b`, `end\`: `end\`, `\`: `\`, `\n\n`: "\n\n",
	} {
		if got := awkVar(in); got != want {
			t.Errorf("awkVar(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPatternGrammar(t *testing.T) {
	for p, want := range map[string]bool{
		"docs/**": true, "docs/*.md": true, "a/b/c": true, "a-b_c.d@e": true, "**": false, "a/**/b": false, "**/x": false,
		"docs/[a-z]": false, "a b": false, "a?": false, "a{b}": false, "a+": false, "": false, "x/**/**": false, "a**b": false,
	} {
		if got := pfPatOK(p); got != want {
			t.Errorf("pfPatOK(%q) = %v, want %v", p, got, want)
		}
	}
}
