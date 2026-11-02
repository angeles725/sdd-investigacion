package floss

// The frozen oracle. The Python 3.12 outputs the port reproduces (argparse messages, json.loads errors) are
// recorded once as gzip'd JSON goldens under testdata/goldens, and replayed here with no Python, no tool and no
// sandbox. The differential tests (parity_linux_test.go, !nodiff) regenerate them with RSDD_UPDATE_GOLDENS=1 and
// otherwise assert goldens == oracle, so the replay cannot drift from the real interpreter. `make teeth` builds
// with -tags nodiff and never runs the oracle: these replays are what gives the argparse emulation and the JSON
// scanner their mutation kills, on any machine.

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"math/rand/v2"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

const (
	argparseGolden = "testdata/goldens/argparse.json.gz"
	jsonGolden     = "testdata/goldens/json.json.gz"
)

type argCase struct {
	Args    []string `json:"args"`
	Columns int      `json:"columns"`
}

// argResult is what the oracle's parser did with one argCase.
type argResult struct {
	Code int               `json:"code"`
	Out  string            `json:"out"`
	Err  string            `json:"err"`
	NS   map[string]string `json:"ns,omitempty"`
}

// jsonResult is what json.loads did with one hex-encoded document: Ok is the canonical re-encoding, Err the
// JSONDecodeError text, Exc the type of any other exception.
type jsonResult struct {
	Ok  string `json:"ok,omitempty"`
	Err string `json:"err,omitempty"`
	Exc string `json:"exc,omitempty"`
}

// argparseCorpus is the deterministic command-line corpus (a seeded generator, so the goldens are stable).
func argparseCorpus() []argCase {
	flags := []string{"--input", "--output", "--timeout", "--max-strings", "--max-string-len", "--manifest-cli", "--inp", "--out", "--ti",
		"--max-s", "--max-string", "--max-string-l", "--m", "--man", "-h", "--help", "--he", "-x", "-hh", "-hx", "--", "---input", "-",
		"--input=a", "--output=b//c", "--timeout=3", "--timeout=", "--manifest-cli=m", "--timeout=x", "--help=1", "--inp=q", "--max-strings=7",
		"-i", "-ia", "-o", "-t5", "-m", "--input=", "--=", "--=x", "-=", "-5", "--5", "-1.5", "-h=1", "-hxh", "--max", "--max-string-"}
	values := []string{"a", "b/./c", "5", "-5", "1_0", " 7 ", "x", "", "0", "-0", "1.5", "a b", "-1.5", "//r", "٣", "+4", "9999999999999999999999",
		"1__0", "_1", "1_", "0x10", "١٢", "5\n", "\t5", "-a b", "--a b", "- 5", "1e3"}
	rng := rand.New(rand.NewPCG(2484, 7))
	cols := []int{80, 80, 80, 40, 44, 60, 120, 200, 20, 10, 2}
	var cases []argCase
	pick := func() string {
		if rng.IntN(3) == 0 {
			return values[rng.IntN(len(values))]
		}
		return flags[rng.IntN(len(flags))]
	}
	cases = append(cases, argCase{[]string{"-h"}, 80}, argCase{nil, 80}, argCase{[]string{"-h"}, 40}, argCase{[]string{"-h"}, 30},
		argCase{[]string{"-h"}, 120}, argCase{[]string{"-h"}, 10}, argCase{[]string{"--input", "i", "--output", "o", "--manifest-cli", "m"}, 80})
	// Every width: the usage and help wrapping have a boundary at each one of them.
	for w := 2; w <= 160; w++ {
		cases = append(cases, argCase{[]string{"-h"}, w}, argCase{nil, w}, argCase{[]string{"--input", "i", "--bogus"}, w})
	}
	for i := 0; i < 3200; i++ {
		var args []string
		if rng.IntN(2) == 0 { // a mostly valid command line, then noise
			args = []string{"--input", "i", "--output", "o", "--manifest-cli", "m"}
			rng.Shuffle(3, func(a, b int) {
				args[2*a], args[2*b] = args[2*b], args[2*a]
				args[2*a+1], args[2*b+1] = args[2*b+1], args[2*a+1]
			})
		}
		for k := rng.IntN(5); k > 0; k-- {
			args = append(args, pick())
		}
		cases = append(cases, argCase{args, cols[rng.IntN(len(cols))]})
	}
	return cases
}

// jsonCorpus is the deterministic document corpus: every prefix of a few seeds, edge documents, and seeded mutants.
func jsonCorpus() [][]byte {
	seeds := []string{
		`{"strings":{"static_strings":[{"string":"abc","offset":10,"encoding":"ASCII"},{"string":"d\u00e9f\ud83d\ude00","offset":2.5,"encoding":null}],"stack_strings":[],"tight_strings":[{"string":"x\n\t\"\\/","offset":-1e3}],"decoded_strings":[]}}`,
		"{\n  \"a\": [1, 2, {\"b\": \"c\"}],\n  \"d\": true, \"e\": false, \"f\": null,\n  \"g\": 12345678901234567890123, \"h\": 1.5E+3\n}\n",
		`[[],{},"",0,-0,0.0,1e5,[[["deep"]]]]`,
		"\ufeff[NaN, Infinity, -Infinity, 1E400, -1e-400]",
		"[\"\\u0041\\u00e9\\u20ac\\ud83d\\ude00\\uD83D\\uDE00\", \"\\b\\f\\n\\r\\t\\/\\\\\"]",
	}
	alphabet := []byte("{}[]\":,\\ \n\t0123456789-+.eEtrufalsn/bu\x00\x1f\x7f\xc3\xa9\xff\xef\xbb\xbfNIx")
	rng := rand.New(rand.NewPCG(2484, 11))
	var corpus [][]byte
	for _, s := range seeds {
		corpus = append(corpus, []byte(s))
		for i := 0; i <= len(s); i++ {
			corpus = append(corpus, []byte(s[:i]))
		}
	}
	for _, s := range []string{"", " ", "\ufeff{}", "\ufeff\ufeff{}", "-", "-0", "01", "1.", "1e", "1e+", "1.5.", "tru", "nul", "-I", "[1,]", "{,}", "\"\\u00\"", "\"\\ud83d\"", "\"\\ud83d\\u0041\"", "\"\\ude00\"", "\"\\uZZZZ\"", "\"\\x\"", "\"a\x01\"",
		"\x00\x00\x00{", "{\x00\x00\x00", "\xff\xfe{\x00}\x00", "\xfe\xff\x00{\x00}", "\xef\xbb\xbf{}", "\xef\xbb", "\xc3", "\xc3\x28", "\"\xff\"", "NaN", "Infinity", "-Infinity", "-Inf", "[-]", "{\"a\"}", "{\"a\":}", "{1:2}", "[1 2]", "\"abc", "{\"a\":1,}", "{\"a\":1 \"b\":2}"} {
		corpus = append(corpus, []byte(s))
	}
	for _, parts := range [][]string{{"u:d7ff"}, {"u:e000"}, {"u:d800"}, {"u:dbff"}, {"u:dc00"}, {"u:dfff"}, {"u:d83d", "u:de00"}, {"u:dbff", "u:dc00"},
		{"u:d800", "u:dc00"}, {"u:d83d", "u:dfff"}, {"u:d800", "u:e000"}, {"u:d83d", "u:0041"}, {"u:d83d", "x"}, {"u:d83d", "u:de00", "u:d83d"}} {
		corpus = append(corpus, []byte(jsonStr(parts...)), []byte(`"`+jsonStrBody(parts...)), []byte(`[`+jsonStr(parts...)+`]`))
	}
	for i := 0; i < 5000; i++ {
		b := []byte(seeds[rng.IntN(len(seeds))])
		for k := 1 + rng.IntN(3); k > 0 && len(b) > 0; k-- {
			pos := rng.IntN(len(b))
			switch rng.IntN(4) {
			case 0:
				b[pos] = alphabet[rng.IntN(len(alphabet))]
			case 1:
				b = append(b[:pos], b[pos+1:]...)
			case 2:
				b = append(b[:pos], append([]byte{alphabet[rng.IntN(len(alphabet))]}, b[pos:]...)...)
			default:
				b = b[:pos]
			}
		}
		corpus = append(corpus, b)
	}
	return corpus
}

// checkArgs runs every case through parseArgs and compares code, stdout, stderr and the parsed namespace.
func checkArgs(t *testing.T, cases []argCase, want []argResult) {
	t.Helper()
	if len(want) != len(cases) {
		t.Fatalf("%d results for %d cases", len(want), len(cases))
	}
	accepted, refused, helped := 0, 0, 0
	for i, c := range cases {
		var o, e bytes.Buffer
		opts, gotCode, done := parseArgs(c.Args, c.Columns-2, &o, &e)
		w := want[i]
		if gotCode != w.Code || o.String() != w.Out || e.String() != w.Err {
			t.Errorf("args %q columns %d:\nport   code=%d stdout=%q stderr=%q\nwant   code=%d stdout=%q stderr=%q", c.Args, c.Columns, gotCode, o.String(), e.String(), w.Code, w.Out, w.Err)
			continue
		}
		switch {
		case !done:
			accepted++
			got := map[string]string{"input": opts.input, "output": opts.output, "manifest_cli": opts.manifestCLI,
				"timeout": opts.timeout.String(), "max_strings": opts.maxStrings.String(), "max_string_len": opts.maxStringLen.String()}
			if !reflect.DeepEqual(got, w.NS) {
				t.Errorf("args %q: port parsed %v, want %v", c.Args, got, w.NS)
			}
		case gotCode == 0:
			helped++
		default:
			refused++
		}
	}
	if accepted < 100 || refused < 100 || helped < 20 {
		t.Errorf("corpus exercised %d accepted, %d refused, %d help: it must cover all three", accepted, refused, helped)
	}
}

// checkJSON decodes every document and compares it with json.loads: the same error text, or the same value.
func checkJSON(t *testing.T, corpus [][]byte, want []jsonResult) {
	t.Helper()
	if len(want) != len(corpus) {
		t.Fatalf("%d results for %d documents", len(want), len(corpus))
	}
	ok, bad, refused, skipped := 0, 0, 0, 0
	for i, b := range corpus {
		v, err := decodePyJSON(b)
		w := want[i]
		var je *jsonError
		if err == errUnsupportedText && unsupportedInput(b) {
			skipped++
			continue
		}
		switch {
		case w.Err != "":
			bad++
			if err == nil || !asJSONError(err, &je) || je.Error() != w.Err {
				t.Errorf("%q: port (%#v, %v), want JSONDecodeError %q", b, v, err, w.Err)
			}
		case w.Exc != "":
			refused++
			// Python fails here either decoding the bytes or dumping the value (an out-of-range float).
			if asJSONError(err, &je) {
				t.Errorf("%q: want %s, port: %v", b, w.Exc, err)
			} else if err == nil {
				if _, jerr := jsonout.Canonical(v); jerr == nil {
					t.Errorf("%q: want %s, port decoded and encoded %#v", b, w.Exc, v)
				}
			}
		default:
			ok++
			if err != nil {
				t.Errorf("%q: decoded by json.loads, port: %v", b, err)
				continue
			}
			got, jerr := jsonout.Canonical(v)
			if jerr != nil || string(got) != w.Ok {
				t.Errorf("%q: port %q (%v), want %q", b, got, jerr, w.Ok)
			}
		}
	}
	if ok < 100 || bad < 500 || refused < 5 || skipped < 5 {
		t.Errorf("corpus exercised %d valid, %d malformed, %d refused, %d unsupported: it must cover all four", ok, bad, refused, skipped)
	}
}

// unsupportedInput reports the documented deviation: text Python decodes (UTF-16/32, invalid UTF-8, a lone
// surrogate escape) and this port refuses with errUnsupportedText.
func unsupportedInput(b []byte) bool {
	s := string(b)
	return !utf8.Valid(b) || bytes.IndexByte(b, 0) >= 0 || strings.Contains(s, `\ud`) || strings.Contains(s, `\uD`)
}

func readGolden(t *testing.T, path string, into any) {
	t.Helper()
	f, err := os.Open(path)
	must(t, err)
	defer f.Close()
	zr, err := gzip.NewReader(f)
	must(t, err)
	raw, err := io.ReadAll(zr)
	must(t, err)
	must(t, json.Unmarshal(raw, into))
}

func TestGoldenArgparse(t *testing.T) {
	var want []argResult
	readGolden(t, argparseGolden, &want)
	checkArgs(t, argparseCorpus(), want)
}

func TestGoldenJSONDecode(t *testing.T) {
	var want []jsonResult
	readGolden(t, jsonGolden, &want)
	checkJSON(t, jsonCorpus(), want)
}

// writeGolden stores v as gzip'd JSON (used by the oracle tests under RSDD_UPDATE_GOLDENS=1).
func writeGolden(t *testing.T, path string, v any) {
	t.Helper()
	raw, err := json.Marshal(v)
	must(t, err)
	var buf bytes.Buffer
	zw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	must(t, err)
	_, err = zw.Write(raw)
	must(t, err)
	must(t, zw.Close())
	must(t, os.MkdirAll(filepath.Dir(path), 0o755))
	must(t, os.WriteFile(path, buf.Bytes(), 0o644))
}
