//go:build linux && !nodiff

package floss

// The differential half of the floss tests: the frozen legacy script (testdata/legacy/corroborate_floss.py) is
// the oracle, run by Python 3.12 (its argparse and json messages are what the port reproduces). The slow
// tests, so `make teeth` (-tags nodiff) leaves them out; the unit tests carry the mutation kills.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

const legacyScript = "testdata/legacy/corroborate_floss.py"

// oraclePython is the Python 3.12 interpreter that runs the legacy script.
func oraclePython(t *testing.T) string {
	t.Helper()
	for _, name := range []string{"python3.12", "python3"} {
		py, err := exec.LookPath(name)
		if err != nil {
			continue
		}
		out, err := exec.Command(py, "-I", "-c", "import sys; print('%d.%d' % sys.version_info[:2])").Output()
		if err == nil && strings.TrimSpace(string(out)) == "3.12" {
			return py
		}
	}
	skipOrFail(t, "the oracle needs Python 3.12 (python3.12 on PATH)")
	return ""
}

func absPath(t *testing.T, rel string) string {
	t.Helper()
	p, err := filepath.Abs(rel)
	must(t, err)
	return p
}

// pyRun runs an inline Python program in isolated mode with args, feeding stdin.
func pyRun(t *testing.T, py, program, stdin string, env []string, args ...string) (stdout, stderr string, code int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, py, append([]string{"-I", "-c", program}, args...)...)
	var o, e bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr, cmd.Env = strings.NewReader(stdin), &o, &e, env
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("python: %v", err)
	}
	return o.String(), e.String(), code
}

// ---------------------------------------------------------------- argparse

const argparseProgram = `
import contextlib, importlib.util, io, json, os, sys
toolbelt, legacy = sys.argv[1], sys.argv[2]
sys.path.insert(0, toolbelt)
spec = importlib.util.spec_from_file_location("legacy_floss", legacy)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
out = []
for case in json.load(sys.stdin):
    os.environ["COLUMNS"] = str(case["columns"])
    o, e = io.StringIO(), io.StringIO()
    res = {}
    try:
        with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
            ns = m._parser().parse_args(case["args"])
        res["ns"] = {"input": str(ns.input), "output": str(ns.output), "manifest_cli": str(ns.manifest_cli),
                     "timeout": str(ns.timeout), "max_strings": str(ns.max_strings), "max_string_len": str(ns.max_string_len)}
        res["code"] = 0
    except SystemExit as x:
        res["code"] = x.code
    res["out"], res["err"] = o.getvalue(), e.getvalue()
    out.append(res)
json.dump(out, sys.stdout)
`

func TestParityArgparse(t *testing.T) {
	py := oraclePython(t)
	flags := []string{"--input", "--output", "--timeout", "--max-strings", "--max-string-len", "--manifest-cli", "--inp", "--out", "--ti",
		"--max-s", "--max-string", "--max-string-l", "--m", "--man", "-h", "--help", "--he", "-x", "-hh", "-hx", "--", "---input", "-",
		"--input=a", "--output=b//c", "--timeout=3", "--timeout=", "--manifest-cli=m", "--timeout=x", "--help=1", "--inp=q", "--max-strings=7"}
	values := []string{"a", "b/./c", "5", "-5", "1_0", " 7 ", "x", "", "0", "-0", "1.5", "a b", "-1.5", "//r", "٣", "+4", "9999999999999999999999"}
	rng := rand.New(rand.NewPCG(2484, 7))
	cols := []int{80, 80, 80, 40, 44, 60, 120, 200}
	type argCase struct {
		Args    []string `json:"args"`
		Columns int      `json:"columns"`
	}
	var cases []argCase
	pick := func() string {
		if rng.IntN(3) == 0 {
			return values[rng.IntN(len(values))]
		}
		return flags[rng.IntN(len(flags))]
	}
	cases = append(cases, argCase{[]string{"-h"}, 80}, argCase{nil, 80}, argCase{[]string{"-h"}, 40}, argCase{[]string{"-h"}, 30})
	for i := 0; i < 3000; i++ {
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
	in, _ := json.Marshal(cases)
	stdout, stderr, code := pyRun(t, py, argparseProgram, string(in), os.Environ(), absPath(t, "../../../../toolbelt"), absPath(t, legacyScript))
	if code != 0 {
		t.Fatalf("oracle: %s", stderr)
	}
	var want []struct {
		Code int               `json:"code"`
		Out  string            `json:"out"`
		Err  string            `json:"err"`
		NS   map[string]string `json:"ns"`
	}
	must(t, json.Unmarshal([]byte(stdout), &want))
	if len(want) != len(cases) {
		t.Fatalf("oracle returned %d results for %d cases", len(want), len(cases))
	}
	accepted, refused, helped := 0, 0, 0
	for i, c := range cases {
		var o, e bytes.Buffer
		opts, gotCode, done := parseArgs(c.Args, c.Columns-2, &o, &e)
		w := want[i]
		if gotCode != w.Code || o.String() != w.Out || e.String() != w.Err {
			t.Errorf("args %q columns %d:\nport   code=%d stdout=%q stderr=%q\nlegacy code=%d stdout=%q stderr=%q", c.Args, c.Columns, gotCode, o.String(), e.String(), w.Code, w.Out, w.Err)
			continue
		}
		switch {
		case !done:
			accepted++
			got := map[string]string{"input": opts.input, "output": opts.output, "manifest_cli": opts.manifestCLI,
				"timeout": opts.timeout.String(), "max_strings": opts.maxStrings.String(), "max_string_len": opts.maxStringLen.String()}
			if !reflect.DeepEqual(got, w.NS) {
				t.Errorf("args %q: port parsed %v, legacy %v", c.Args, got, w.NS)
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

// ---------------------------------------------------------------- JSON decoding

const jsonProgram = `
import json, sys
out = []
for h in json.load(sys.stdin):
    raw = bytes.fromhex(h)
    try:
        v = json.loads(raw)
        out.append({"ok": json.dumps(v, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"})
    except json.JSONDecodeError as e:
        out.append({"err": str(e)})
    except ValueError as e:
        out.append({"exc": type(e).__name__})
    except Exception as e:
        out.append({"exc": type(e).__name__})
json.dump(out, sys.stdout)
`

func TestParityJSONDecode(t *testing.T) {
	py := oraclePython(t)
	seeds := []string{
		`{"strings":{"static_strings":[{"string":"abc","offset":10,"encoding":"ASCII"},{"string":"d\u00e9f\ud83d\ude00","offset":2.5,"encoding":null}],"stack_strings":[],"tight_strings":[{"string":"x\n\t\"\\/","offset":-1e3}],"decoded_strings":[]}}`,
		"{\n  \"a\": [1, 2, {\"b\": \"c\"}],\n  \"d\": true, \"e\": false, \"f\": null,\n  \"g\": 12345678901234567890123, \"h\": 1.5E+3\n}\n",
		`[[],{},"",0,-0,0.0,1e5,[[["deep"]]]]`,
	}
	alphabet := []byte("{}[]\":,\\ \n\t0123456789-+.eEtrufalsn/bu\x00\x1f\x7f\xc3\xa9\xff")
	rng := rand.New(rand.NewPCG(2484, 11))
	var corpus [][]byte
	for _, s := range seeds {
		corpus = append(corpus, []byte(s))
		for i := 0; i <= len(s); i++ {
			corpus = append(corpus, []byte(s[:i]))
		}
	}
	for _, s := range []string{"", " ", "\ufeff{}", "\ufeff\ufeff{}", "-", "-0", "01", "1.", "1e", "1e+", "1.5.", "tru", "nul", "-I", "[1,]", "{,}", "\"\\u00\"", "\"\\ud83d\"", "\"\\ud83d\\u0041\"", "\"\\ude00\"", "\"\\uZZZZ\"", "\"\\x\"", "\"a\x01\""} {
		corpus = append(corpus, []byte(s))
	}
	for i := 0; i < 4000; i++ {
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
	hexes := make([]string, len(corpus))
	for i, b := range corpus {
		hexes[i] = fmt.Sprintf("%x", b)
	}
	in, _ := json.Marshal(hexes)
	stdout, stderr, code := pyRun(t, py, jsonProgram, string(in), nil)
	if code != 0 {
		t.Fatalf("oracle: %s", stderr)
	}
	var want []struct{ Ok, Err, Exc string }
	must(t, json.Unmarshal([]byte(stdout), &want))
	ok, bad, refused := 0, 0, 0
	for i, b := range corpus {
		v, err := decodePyJSON(b)
		w := want[i]
		var je *jsonError
		switch {
		case w.Err != "":
			bad++
			if err == nil || !asJSONError(err, &je) || je.Error() != w.Err {
				t.Errorf("%q: port (%#v, %v), legacy JSONDecodeError %q", b, v, err, w.Err)
			}
		case w.Exc != "":
			refused++
			// Python fails here either decoding the bytes or dumping the value (an out-of-range float).
			if asJSONError(err, &je) {
				t.Errorf("%q: legacy raised %s, port: %v", b, w.Exc, err)
			} else if err == nil {
				if _, jerr := jsonout.Canonical(v); jerr == nil {
					t.Errorf("%q: legacy raised %s, port decoded and encoded %#v", b, w.Exc, v)
				}
			}
		default:
			ok++
			if err != nil {
				if err == errUnsupportedText && strings.Contains(string(b), `\ud`) {
					continue // a lone surrogate: Python holds it, the port refuses it (documented)
				}
				t.Errorf("%q: legacy decoded, port: %v", b, err)
				continue
			}
			got, jerr := jsonout.Canonical(v)
			if jerr != nil || string(got) != w.Ok {
				t.Errorf("%q: port %q (%v), legacy %q", b, got, jerr, w.Ok)
			}
		}
	}
	if ok < 100 || bad < 500 || refused < 5 {
		t.Errorf("corpus exercised %d valid, %d malformed, %d refused: it must cover all three", ok, bad, refused)
	}
}
