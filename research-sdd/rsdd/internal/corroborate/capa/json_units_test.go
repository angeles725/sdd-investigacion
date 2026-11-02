package capa

// Unit tests of the JSON reader, the stdout reader and the inventory. They replace the Python unit cases
// T5, T6, T7 and T16 of the retired tests/capa.test.sh.

import (
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ---------------------------------------------------------------- python-compatible JSON

func TestDecodeJSONErrorsMatchPython(t *testing.T) {
	cases := map[string]string{
		`not json at all {{{{`: "Expecting value: line 1 column 1 (char 0)",
		`{"a": 1,}`:            "Expecting property name enclosed in double quotes: line 1 column 9 (char 8)",
		`{"a" 1}`:              "Expecting ':' delimiter: line 1 column 6 (char 5)",
		`{"a": 1 "b"}`:         "Expecting ',' delimiter: line 1 column 9 (char 8)",
		`[1,]`:                 "Expecting value: line 1 column 4 (char 3)",
		`[1 2]`:                "Expecting ',' delimiter: line 1 column 4 (char 3)",
		`{"a": "x`:             "Unterminated string starting at: line 1 column 7 (char 6)",
		"{\"a\": \"x\ny\"}":    "Invalid control character at: line 1 column 9 (char 8)",
		`{"a": "\q"}`:          "Invalid \\escape: line 1 column 8 (char 7)",
		`{"a": "\u12g4"}`:      "Invalid \\uXXXX escape: line 1 column 9 (char 8)",
		`{} extra`:             "Extra data: line 1 column 4 (char 3)",
		"{\n  \"a\": tru\n}":   "Expecting value: line 2 column 8 (char 9)",
		`-`:                    "Expecting value: line 1 column 1 (char 0)",
		`01`:                   "Extra data: line 1 column 2 (char 1)",
		`1.`:                   "Extra data: line 1 column 2 (char 1)",
		`{`:                    "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)",
		`[`:                    "Expecting value: line 1 column 2 (char 1)",
	}
	for doc, want := range cases {
		_, err := decodeJSON([]byte(doc))
		var je *jsonError
		if !errors.As(err, &je) || je.msg != want {
			t.Errorf("%q: got %v, want %q", doc, err, want)
		}
	}
}

func TestDecodeJSONValues(t *testing.T) {
	v, err := decodeJSON([]byte("\xef\xbb\xbf {\"a\": [1, -0, 2.50, 1e2, true, false, null, \"\\u00e9\\ud83d\\ude00\"], \"a\": 9}"))
	if err != nil {
		t.Fatal(err)
	}
	if m := v.(map[string]any); m["a"].(interface{ String() string }).String() != "9" {
		t.Fatalf("the later duplicate key wins: %v", m)
	}
	list, _ := decodeJSON([]byte(`[1, -0, 2.50, 1e2, "é😀", NaN, -Infinity]`))
	l := list.([]any)
	if l[0].(interface{ String() string }).String() != "1" || l[1].(interface{ String() string }).String() != "0" || l[2] != 2.5 || l[3] != 100.0 || l[4] != "é😀" {
		t.Fatalf("%#v", l)
	}
}

func TestDecodeJSONRefusesWhatPythonRaisesElsewhere(t *testing.T) {
	for _, doc := range []string{`"\ud800"`, strings.Repeat("[", 10000) + strings.Repeat("]", 10000), "\xff\xfe[\x00]\x00", "\xc3\x28"} {
		if _, err := decodeJSON([]byte(doc)); err == nil {
			t.Errorf("%.20q: want a crash", doc)
		} else {
			var c *crash
			if !errors.As(err, &c) {
				t.Errorf("%.20q: %v is not a crash", doc, err)
			}
		}
	}
}

// ---------------------------------------------------------------- stdout reader (T5, T7)

// T5: malformed JSON is (nil, message); an empty file is (nil, "").
func TestReadStdoutJSONMalformedAndEmpty(t *testing.T) {
	dir := t.TempDir()
	bad := filepath.Join(dir, "stdout.txt")
	os.WriteFile(bad, []byte("not json at all {{{{"), 0o644)
	v, msg, err := readStdoutJSON(bad)
	if err != nil || v != nil || msg != "malformed JSON in capa stdout: Expecting value: line 1 column 1 (char 0)" {
		t.Fatalf("malformed: %v %q %v", v, msg, err)
	}
	empty := filepath.Join(dir, "empty.txt")
	os.WriteFile(empty, nil, 0o644)
	if v, msg, err := readStdoutJSON(empty); v != nil || msg != "" || err != nil {
		t.Fatalf("empty: %v %q %v", v, msg, err)
	}
}

// T7: a symlink, a directory or a missing file at the stdout path is refused (O_NOFOLLOW + lstat/S_ISREG).
func TestReadStdoutJSONRefusesSymlinkAndNonRegular(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "real.txt")
	os.WriteFile(real, []byte("{}"), 0o644)
	link := filepath.Join(dir, "stdout.txt")
	os.Symlink(real, link)
	cases := map[string]string{
		link:                         "symlink detected at capa output path: " + link,
		dir:                          "capa stdout is not a regular file: " + dir,
		filepath.Join(dir, "absent"): "cannot stat capa stdout: " + filepath.Join(dir, "absent"),
	}
	for p, want := range cases {
		_, _, err := readStdoutJSON(p)
		var f *fail
		if !errors.As(err, &f) || f.msg != want {
			t.Errorf("%s: %v, want %q", p, err, want)
		}
	}
}

// ---------------------------------------------------------------- inventory (T6, T16)

// T6: no document, no rules and an empty rules object are all an empty complete inventory.
func TestBuildInventoryEmpty(t *testing.T) {
	for _, doc := range []any{nil, map[string]any{}, map[string]any{"rules": map[string]any{}}} {
		inv, lims, err := buildInventory(doc, big.NewInt(100))
		if err != nil || inv.totalCount != 0 || inv.totalSampled != 0 || inv.truncated || len(inv.items) != 0 || len(lims) != 0 {
			t.Errorf("%v: %+v %v %v", doc, inv, lims, err)
		}
	}
}

// T16b: a non-dict "rules" is reported as schema drift naming its type.
func TestBuildInventoryNonDictRules(t *testing.T) {
	for rules, typ := range map[string]any{"list": []any{"x"}, "str": "s", "NoneType": nil, "bool": true, "float": 1.5} {
		inv, lims, err := buildInventory(map[string]any{"rules": typ}, big.NewInt(100))
		want := "capa JSON 'rules' is not a dict (schema drift): '" + rules + "'"
		if err != nil || inv.totalCount != 0 || len(lims) != 1 || lims[0] != want {
			t.Errorf("%s: %v %v %v", rules, inv, lims, err)
		}
	}
}

func TestBuildInventoryCapAndOrder(t *testing.T) {
	rules := map[string]any{}
	for _, n := range []string{"b", "a", "c"} {
		rules[n] = map[string]any{"meta": map[string]any{"namespace": "ns/" + map[string]string{"a": "2", "b": "1", "c": "1"}[n]}, "matches": []any{}}
	}
	inv, lims, err := buildInventory(map[string]any{"rules": rules}, big.NewInt(2))
	if err != nil || inv.totalCount != 3 || inv.totalSampled != 2 || !inv.truncated {
		t.Fatalf("%+v %v", inv, err)
	}
	if inv.items[0]["name"] != "b" || inv.items[1]["name"] != "c" {
		t.Fatalf("sorted by (namespace, name): %v", inv.items)
	}
	if len(lims) != 1 || lims[0] != "inventory truncated: capability cap 2 reached (total_count=3)" {
		t.Fatalf("limitations %v", lims)
	}
	huge, _ := new(big.Int).SetString("1"+strings.Repeat("0", 40), 10)
	if inv, lims, _ := buildInventory(map[string]any{"rules": rules}, huge); inv.truncated || inv.totalSampled != 3 || len(lims) != 0 {
		t.Errorf("a cap larger than the list never truncates: %+v %v", inv, lims)
	}
}
