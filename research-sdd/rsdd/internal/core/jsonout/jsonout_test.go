package jsonout

import (
	"bytes"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
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

func TestEveryGoldenHasACase(t *testing.T) {
	in := loadCases(t)
	files, err := filepath.Glob(filepath.Join("testdata", "*.golden"))
	if err != nil {
		t.Fatal(err)
	}
	if want := len(in.Cases) * 3; len(files) != want {
		t.Fatalf("%d golden files for %d cases, want %d", len(files), len(in.Cases), want)
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

func TestGoNativeValuesMatchTheJSONNumberPath(t *testing.T) {
	floats := []float64{0, 1, -1, 0.1, 1.5, 100000, 1e15, 1e16, 1e-4, 1e-5, 1e-7, 5e-324, 1.7976931348623157e308,
		123456789012345680000, 0.30000000000000004, -2.5e-10, math.Copysign(0, -1)}
	for _, f := range floats {
		native, err := Canonical(f)
		if err != nil {
			t.Fatal(err)
		}
		viaNumber, err := Canonical(json.Number(strings.TrimSpace(string(mustPyRepr(t, f)))))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(native, viaNumber) {
			t.Errorf("float64(%v): native %q vs json.Number %q", f, native, viaNumber)
		}
	}
	got, err := Canonical(map[string]any{"i": 3, "i8": int8(-8), "u": uint64(18446744073709551615), "f32": float32(0.5), "n": nil, "b": true})
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"b":true,"f32":0.5,"i":3,"i8":-8,"n":null,"u":18446744073709551615}` + "\n"; string(got) != want {
		t.Errorf("got %q want %q", got, want)
	}
}

// mustPyRepr formats f with the encoder itself; used only to feed the json.Number path with a valid literal.
func mustPyRepr(t *testing.T, f float64) []byte {
	t.Helper()
	b, err := Canonical(f)
	if err != nil {
		t.Fatal(err)
	}
	return b
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
