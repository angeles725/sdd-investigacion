package jsonout

import (
	"bytes"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"testing"
)

type inputFile struct {
	Cases []struct {
		Name string          `json:"name"`
		Doc  json.RawMessage `json:"doc"`
	} `json:"cases"`
}

func loadCases(t *testing.T) inputFile {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "inputs.json"))
	if err != nil {
		t.Fatalf("inputs.json must exist: %v", err)
	}
	var in inputFile
	if err := json.Unmarshal(b, &in); err != nil {
		t.Fatal(err)
	}
	if len(in.Cases) < 10 {
		t.Fatalf("only %d cases", len(in.Cases))
	}
	return in
}

// decode parses a JSON text keeping numbers verbatim (json.Number), so float/int spelling is preserved.
func decode(t *testing.T, raw []byte) any {
	t.Helper()
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

func golden(t *testing.T, name, mode string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name+"."+mode+".golden"))
	if err != nil {
		t.Fatalf("golden missing (run python3 -I testdata/regen.py): %v", err)
	}
	return b
}

func TestMatchesPythonBytes(t *testing.T) {
	modes := []struct {
		mode string
		fn   func(any) ([]byte, error)
	}{
		{"canonical", Canonical},
		{"unicode", CanonicalUnicode},
		{"indented", Indented},
	}
	in := loadCases(t)
	for _, c := range in.Cases {
		v := decode(t, c.Doc)
		for _, m := range modes {
			t.Run(c.Name+"/"+m.mode, func(t *testing.T) {
				got, err := m.fn(v)
				if err != nil {
					t.Fatal(err)
				}
				want := golden(t, c.Name, m.mode)
				if !bytes.Equal(got, want) {
					t.Fatalf("bytes differ from Python\n got: %q\nwant: %q", got, want)
				}
			})
		}
	}
}

func TestGoldenFilesAreExactlyTheCasesTimesModes(t *testing.T) {
	in := loadCases(t)
	want := map[string]bool{}
	for _, c := range in.Cases {
		for _, m := range []string{"canonical", "unicode", "indented"} {
			want[c.Name+"."+m+".golden"] = true
		}
	}
	files, err := filepath.Glob(filepath.Join("testdata", "*.golden"))
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, f := range files {
		got[filepath.Base(f)] = true
	}
	for name := range want {
		if !got[name] {
			t.Errorf("missing golden %s (run python3 -I testdata/regen.py)", name)
		}
	}
	for name := range got {
		if !want[name] {
			t.Errorf("orphan golden %s has no case in inputs.json", name)
		}
	}
}

func TestASCIIModeIsPureASCIIAndUnicodeModeIsNot(t *testing.T) {
	v := map[string]any{"k": "é😀"}
	a, _ := Canonical(v)
	if got := string(a); got != "{\"k\":\"\\u00e9\\ud83d\\ude00\"}\n" {
		t.Errorf("ascii: %q", got)
	}
	u, _ := CanonicalUnicode(v)
	if got := string(u); got != "{\"k\":\"é😀\"}\n" {
		t.Errorf("unicode: %q", got)
	}
}

func TestHTMLCharactersAreNotEscaped(t *testing.T) {
	for name, fn := range map[string]func(any) ([]byte, error){"canonical": Canonical, "unicode": CanonicalUnicode, "indented": Indented} {
		b, err := fn("<a> & </a>")
		if err != nil || !strings.Contains(string(b), "<a> & </a>") {
			t.Errorf("%s: %q, %v", name, b, err)
		}
	}
}

// pythonFloatReprs were produced by python3 -I -c 'print(json.dumps(f))' for each float64, so the table is
// independent of the encoder under test.
var pythonFloatReprs = []struct {
	f    float64
	want string
}{
	{0, "0.0"}, {1, "1.0"}, {-1, "-1.0"}, {0.1, "0.1"}, {1.5, "1.5"}, {100000, "100000.0"},
	{1e15, "1000000000000000.0"}, {1e16, "1e+16"}, {1e-4, "0.0001"}, {1e-5, "1e-05"}, {1e-7, "1e-07"},
	{5e-324, "5e-324"}, {1.7976931348623157e308, "1.7976931348623157e+308"},
	{123456789012345680000, "1.2345678901234568e+20"}, {0.30000000000000004, "0.30000000000000004"},
	{-2.5e-10, "-2.5e-10"}, {math.Copysign(0, -1), "-0.0"}, {2.5e-5, "2.5e-05"},
	{9007199254740992, "9007199254740992.0"}, {1e22, "1e+22"}, {123456789.123456789, "123456789.12345679"},
	{0.5, "0.5"},
}

func TestGoNativeFloatsMatchPythonRepr(t *testing.T) {
	for _, c := range pythonFloatReprs {
		got, err := Canonical(c.f)
		if err != nil || string(got) != c.want+"\n" {
			t.Errorf("float64(%v): got %q, %v; want %q", c.f, got, err, c.want)
		}
		viaNumber, err := Canonical(json.Number(c.want))
		if err != nil || string(viaNumber) != c.want+"\n" {
			t.Errorf("json.Number(%q): got %q, %v", c.want, viaNumber, err)
		}
	}
}

func TestGoNativeIntegersAndScalars(t *testing.T) {
	got, err := Canonical(map[string]any{"i": 3, "i8": int8(-8), "u": uint64(18446744073709551615), "f32": float32(0.5), "n": nil, "b": true})
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"b":true,"f32":0.5,"i":3,"i8":-8,"n":null,"u":18446744073709551615}` + "\n"; string(got) != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestReflectedContainers(t *testing.T) {
	got, err := Canonical(map[string][]string{"b": {"x", "y"}, "a": nil})
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"a":[],"b":["x","y"]}` + "\n"; string(got) != want {
		t.Errorf("got %q want %q", got, want)
	}
	got, err = Canonical([2]int{1, 2})
	if err != nil || string(got) != "[1,2]\n" {
		t.Errorf("array: %q %v", got, err)
	}
}

func TestRejectsUnsupportedValues(t *testing.T) {
	type s struct{ A int }
	bad := map[string]any{
		"nan":          math.NaN(),
		"inf":          math.Inf(1),
		"neg inf":      math.Inf(-1),
		"struct":       s{1},
		"int keys":     map[int]string{1: "a"},
		"bad utf8":     "a\xffb",
		"bad utf8 key": map[string]any{"a\xff": 1},
		"chan":         make(chan int),
		"bad number":   json.Number("1.2.3"),
		"empty number": json.Number(""),
	}
	for name, v := range bad {
		if b, err := Canonical(v); err == nil {
			t.Errorf("%s: expected an error, got %q", name, b)
		}
	}
}

func TestJSONNumberForms(t *testing.T) {
	cases := map[string]string{"-0": "0", "007": "", "1": "1", "1.0": "1.0", "1E2": "100.0", "1e-7": "1e-07",
		"123456789012345678901234567890": "123456789012345678901234567890", "-0.0": "-0.0"}
	for in, want := range cases {
		b, err := Canonical(json.Number(in))
		if want == "" {
			if err == nil {
				t.Errorf("%q: expected an error, got %q", in, b)
			}
			continue
		}
		if err != nil || string(b) != want+"\n" {
			t.Errorf("%q: got %q, %v; want %q", in, b, err, want)
		}
	}
}

func TestRejectsBytesLikePythonDoes(t *testing.T) {
	// json.dumps(b"x") raises TypeError; Go would otherwise render a list of ints (or base64 elsewhere).
	for name, v := range map[string]any{
		"[]byte":            []byte("x"),
		"nested []byte":     map[string]any{"k": []byte("x")},
		"[]uint8 in a list": []any{[]uint8{1, 2}},
		"[N]byte":           [2]byte{1, 2},
	} {
		if b, err := Canonical(v); err == nil || !strings.Contains(err.Error(), "bytes") {
			t.Errorf("%s: got %q, %v; want an error naming bytes", name, b, err)
		}
	}
	if b, err := Canonical([]int{1, 2}); err != nil || string(b) != "[1,2]\n" {
		t.Errorf("[]int must still work: %q %v", b, err)
	}
}

// A cycle made only of pointers or interfaces never enters list() or object(), so the container bound
// alone cannot stop it: Go cannot recover from the resulting stack overflow (#2293).
// The test lowers the goroutine stack ceiling from Go's 1 GB default to 64 MB (a legit MaxDepth chain uses
// well under 2 MB), so a guard that stops counting dies at 64 MB instead of growing a 1 GB stack: the
// gremlins mutant e.indirections-- reached 1 GB RSS per test binary before this cap.
func TestIndirectionOnlyCyclesAreBounded(t *testing.T) {
	defer debug.SetMaxStack(debug.SetMaxStack(64 << 20))
	for name, mk := range map[string]func() any{
		"self-referential pointer": func() any { var p any; p = &p; return p },
		"interface cycle":          func() any { var a, b any; a = &b; b = &a; return a },
	} {
		if b, err := Canonical(mk()); err == nil || !strings.Contains(err.Error(), "indirection") {
			t.Errorf("%s: must be rejected with an indirection error, got %d bytes, %v", name, len(b), err)
		}
	}
	var leaf any = "leaf"
	p := &leaf
	for i := 1; i < MaxDepth; i++ {
		q := any(p)
		p = &q
	}
	if b, err := Canonical(p); err != nil || string(b) != "\"leaf\"\n" {
		t.Errorf("a %d-pointer chain must encode as its leaf: %q %v", MaxDepth, b, err)
	}
	q := any(p)
	if b, err := Canonical(&q); err == nil || !strings.Contains(err.Error(), "indirection") {
		t.Errorf("a %d-pointer chain must be rejected, got %d bytes, %v", MaxDepth+1, len(b), err)
	}
	// The bound is per path, not per value: many sibling pointers, each one hop deep, must encode.
	siblings := make([]any, 2*MaxDepth)
	for i := range siblings {
		s := "x"
		siblings[i] = &s
	}
	if b, err := Canonical(siblings); err != nil || len(b) != len(`"x",`)*2*MaxDepth+2 {
		t.Errorf("%d sibling pointers must encode: %d bytes, %v", 2*MaxDepth, len(b), err)
	}
}

// TestMapDepthIsBoundedAtTheSameLimitAsLists pins object's own depth guard: a map nested exactly
// MaxDepth deep encodes and one level more is rejected, independent of list's guard.
func TestMapDepthIsBoundedAtTheSameLimitAsLists(t *testing.T) {
	nest := func(n int) any {
		var v any = "leaf"
		for i := 0; i < n; i++ {
			v = map[string]any{"k": v}
		}
		return v
	}
	if _, err := Canonical(nest(MaxDepth)); err != nil {
		t.Errorf("map depth %d must encode: %v", MaxDepth, err)
	}
	if b, err := Canonical(nest(MaxDepth + 1)); err == nil || !strings.Contains(err.Error(), "depth") {
		t.Errorf("map depth %d must be rejected, got %d bytes, %v", MaxDepth+1, len(b), err)
	}
}

func TestDepthIsBounded(t *testing.T) {
	nest := func(n int) any {
		var v any = "leaf"
		for i := 0; i < n; i++ {
			v = []any{v}
		}
		return v
	}
	if _, err := Canonical(nest(MaxDepth)); err != nil {
		t.Errorf("depth %d must encode: %v", MaxDepth, err)
	}
	if b, err := Canonical(nest(MaxDepth + 1)); err == nil || !strings.Contains(err.Error(), "depth") {
		t.Errorf("depth %d must be rejected, got %d bytes, %v", MaxDepth+1, len(b), err)
	}
	for name, mk := range map[string]func() any{
		"self-referential list": func() any { a := make([]any, 1); a[0] = a; return a },
		"self-referential map":  func() any { m := map[string]any{}; m["m"] = m; return m },
		"cycle through a typed slice": func() any {
			a := make([]any, 1)
			a[0] = map[string]any{"k": a}
			return a
		},
	} {
		if b, err := Canonical(mk()); err == nil || !strings.Contains(err.Error(), "depth") {
			t.Errorf("%s: got %d bytes, %v; want a depth error, not a stack overflow", name, len(b), err)
		}
	}
}
